//! Every participant owns its VM regions, joins, notification pair and file.
//! Only immutable API bindings and the pool's atomic stop flag are shared.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const model = @import("standard_model.zig");
const child_path = "C:\\R4OS\\SOFTWARE\\TERMINAL\\DIAG\\SPECTRA\\STDCHILD.R4X";
pub const Error = error{ Cancelled, Timeout, MissingApi, WorkFailed, CleanupFailed };

pub fn clock(sys: *const r4os.r4sys.Context) ?a.MonotonicClockInfo {
    var value: a.MonotonicClockInfo = .{};
    if (sys.monotonicClock(&value) <= 0 or value.flags & a.monotonic_clock_flag_valid == 0 or
        value.flags & a.monotonic_clock_flag_degraded != 0 or value.resolution_ns == 0) return null;
    return value;
}
pub fn ticks(sys: *const r4os.r4sys.Context, ms: u64) u64 {
    return @max(1, sys.ticksFromMilliseconds(ms));
}

pub const Context = struct {
    sys: *const r4os.r4sys.Context,
    net: ?r4os.r4net.Context,
    stop: *bool,
    deadline: u64,
    index: u32,
    result: model.Sample = .{},
    cleanup_failed: bool = false,
    notifications: [3]u64 = .{ 0, 0, 0 },
    peer_handle: a.ProgramJoinHandle = .{},
    peer_created: bool = false,
    peer_stop: bool = false,
    file_path: [80:0]u8 = .{0} ** 80,
    write_bytes: []u8 = &.{},
    read_bytes: []u8 = &.{},

    pub fn check(self: *Context) Error!void {
        if (@atomicLoad(bool, self.stop, .acquire) or self.sys.programShouldClose()) return error.Cancelled;
        if ((self.sys.monotonicNanoseconds() orelse return error.MissingApi) >= self.deadline) return error.Timeout;
    }
    fn wait(self: *Context, handle: u64, observed: u64) Error!void {
        while (true) {
            if (@atomicLoad(bool, &self.peer_stop, .acquire)) return error.Cancelled;
            try self.check();
            const rc = self.sys.notificationWait(handle, observed, ticks(self.sys, 100));
            if (rc == a.notification_ok) return;
            if (rc != a.notification_timeout) return error.WorkFailed;
        }
    }
    fn peer(raw: u64) callconv(.c) i32 {
        const self: *Context = @ptrFromInt(raw);
        if (self.sys.notificationNotify(self.notifications[2], 1) != a.notification_ok) return 1;
        for (0..model.operation_counts[0]) |i| {
            self.wait(self.notifications[0], i) catch return 1;
            if (self.sys.notificationNotify(self.notifications[1], 1) != a.notification_ok) return 1;
        }
        return 0;
    }
    pub fn prepare(self: *Context, area: usize) Error!void {
        if (area != 0) return;
        for (&self.notifications) |*handle| if (self.sys.notificationCreate(handle) != a.notification_ok) return error.WorkFailed;
        if (self.sys.threadCreateHandle(peer, @intFromPtr(self), 0, 0, &self.peer_handle) != a.thread_ok) return error.WorkFailed;
        self.peer_created = true;
        // Readiness is established before the shared pool start clock/gate.
        try self.wait(self.notifications[2], 0);
    }
    pub fn cleanup(self: *Context) void {
        @atomicStore(bool, &self.peer_stop, true, .release);
        if (self.notifications[0] != 0) _ = self.sys.notificationNotify(self.notifications[0], 1);
        if (self.peer_created) {
            var code: i32 = -1;
            if (self.sys.threadHandleJoin(&self.peer_handle, ticks(self.sys, 2000), &code) != a.thread_ok) {
                self.cleanup_failed = true;
                self.result.reason = "peer-cleanup-unconfirmed";
                return; // Exact peer/notifications remain resident.
            }
            if (self.result.reason == null and code != 0) self.result.reason = "peer-exit-failed";
        }
        for (self.notifications) |handle| if (handle != 0 and self.sys.notificationClose(handle) != a.notification_ok) {
            self.cleanup_failed = true;
            self.result.reason = "notification-close-failed";
        };
    }
    pub fn run(self: *Context, area: usize) void {
        self.result = .{};
        const work = switch (area) {
            0 => self.scheduler(),
            1 => self.memory(),
            2 => self.ipc(),
            3 => self.lifecycle(),
            4 => self.filesystem(),
            else => unreachable,
        };
        work catch |err| {
            self.result.reason = @errorName(err);
            @atomicStore(bool, self.stop, true, .release);
            return;
        };
        self.result.reason = null;
    }
    fn scheduler(self: *Context) Error!void {
        for (0..model.operation_counts[0]) |i| {
            try self.check();
            if (self.sys.notificationNotify(self.notifications[0], 1) != a.notification_ok) return error.WorkFailed;
            try self.wait(self.notifications[1], i);
            self.result.operations += 1;
        }
    }
    fn memory(self: *Context) Error!void {
        for (0..model.operation_counts[1]) |_| {
            try self.check();
            const region = self.sys.vmReserve(128 * 1024, 4096, 0) orelse return error.WorkFailed;
            var released = false;
            defer if (!released and self.sys.vmRelease(region.id) != a.vm_ok) {
                self.cleanup_failed = true;
            };
            if (self.sys.vmCommit(region.id, 0, 128 * 1024) != a.vm_ok) return error.WorkFailed;
            const bytes: [*]volatile u8 = @ptrFromInt(region.base);
            for (0..32) |page| {
                if (bytes[page * 4096] != 0) return error.WorkFailed;
                bytes[page * 4096] = @intCast(page + 1);
            }
            for (0..32) |page| if (bytes[page * 4096] != page + 1) return error.WorkFailed;
            const live = self.sys.vmQuery(region.id) orelse return error.WorkFailed;
            if (live.fault_count != 32 or live.failed_faults != 0 or live.resident_bytes != 128 * 1024) return error.WorkFailed;
            if (self.sys.vmRelease(region.id) != a.vm_ok) {
                self.cleanup_failed = true;
                return error.CleanupFailed;
            }
            released = true;
            if (self.sys.vmQuery(region.id) != null) return error.CleanupFailed;
            self.result.operations += 1;
            self.result.bytes += 128 * 1024;
        }
    }
    fn ipc(self: *Context) Error!void {
        const net = self.net orelse return error.MissingApi;
        var response: [a.ipc_max_message_size]u8 = undefined;
        for (0..model.operation_counts[2]) |i| {
            try self.check();
            const request = self.index *% 16384 +% @as(u32, @intCast(i));
            const got = net.netServiceRequest(a.ipc_channel_net_dns, a.net_service_op_dns_status_result, request, "", &response);
            if (got < a.net_service_header_size or got > response.len) return error.WorkFailed;
            var status: i32 = -1;
            const payload = net.netServicePayload(response[0..@intCast(got)], &status) orelse return error.WorkFailed;
            if (status != a.net_service_result_ok or payload.len == 0) return error.WorkFailed;
            self.result.operations += 1;
            self.result.bytes += a.net_service_header_size;
        }
    }
    fn lifecycle(self: *Context) Error!void {
        for (0..model.operation_counts[3]) |_| {
            try self.check();
            var handle: a.ProgramProcessHandle = .{};
            if (self.sys.programSpawnHandle(child_path, "", .auto, &handle) != a.program_handle_ok) return error.WorkFailed;
            var reaped = false;
            defer if (!reaped) {
                _ = self.sys.programHandleRequestClose(&handle);
                var completion: a.ProgramProcessCompletion = .{};
                if (self.sys.programHandleWait(&handle, ticks(self.sys, 1000), &completion) != a.program_handle_ok) {
                    _ = self.sys.programHandleKill(&handle);
                    _ = self.sys.programHandleWait(&handle, ticks(self.sys, 1000), &completion);
                }
                if (self.sys.programHandleReap(&handle, &completion) != a.program_handle_ok) self.cleanup_failed = true;
            };
            var completion: a.ProgramProcessCompletion = .{};
            if (self.sys.programHandleWait(&handle, ticks(self.sys, 5000), &completion) != a.program_handle_ok) return error.Timeout;
            if (completion.exit_code != 17 or handle.instance_id != completion.handle.instance_id or handle.generation != completion.handle.generation or
                completion.flags & (a.program_completion_flag_ready | a.program_completion_flag_owner) != (a.program_completion_flag_ready | a.program_completion_flag_owner)) return error.WorkFailed;
            if (self.sys.programHandleReap(&handle, &completion) != a.program_handle_ok) return error.CleanupFailed;
            reaped = true;
            var info: a.ProgramInstanceInfo = .{};
            if (self.sys.programHandleStatus(&handle, &info) != a.program_handle_error_not_found) return error.CleanupFailed;
            self.result.operations += 1;
        }
    }
    fn filesystem(self: *Context) Error!void {
        if (self.sys.exists(&self.file_path)) return error.WorkFailed;
        for (0..model.operation_counts[4]) |_| {
            try self.check();
            if (self.sys.fileStreamBegin(&self.file_path, a.file_stream_open_create) < 0) return error.WorkFailed;
            var finished = false;
            var deleted = false;
            defer {
                if (!finished) _ = self.sys.fileStreamAbort(&self.file_path);
                if (!deleted and self.sys.exists(&self.file_path) and self.sys.fileDelete(&self.file_path) <= 0) self.cleanup_failed = true;
            }
            if (self.sys.fileStreamWrite(&self.file_path, 0, self.write_bytes, 0) != self.write_bytes.len or
                self.sys.fileStreamFinish(&self.file_path, self.write_bytes.len, 0) < 0) return error.WorkFailed;
            finished = true;
            if (self.sys.fileRead(&self.file_path, self.read_bytes) != self.read_bytes.len or !std.mem.eql(u8, self.write_bytes, self.read_bytes)) return error.WorkFailed;
            if (self.sys.fileDelete(&self.file_path) <= 0 or self.sys.exists(&self.file_path)) return error.CleanupFailed;
            deleted = true;
            self.result.operations += 1;
            self.result.bytes += self.write_bytes.len * 2;
        }
    }
};
