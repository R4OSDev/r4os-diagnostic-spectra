//! Bounded kernel workloads. Output and broad metadata queries stay outside timers.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const cli = @import("cli.zig");
const Output = @import("output.zig").Output;
pub const model = @import("standard_model.zig");
const presentation = @import("standard_output.zig");
const child_path = "C:\\R4OS\\SOFTWARE\\TERMINAL\\DIAG\\SPECTRA\\STDCHILD.R4X";
var sys: r4os.r4sys.Context = undefined;
var net: ?r4os.r4net.Context = null;
var samples: [5][6]model.Sample = undefined;
var metrics: [5]model.Metric = undefined;
var write_bytes: [64 * 1024]u8 = undefined;
var read_bytes: [64 * 1024]u8 = undefined;
var file_path: [80:0]u8 = undefined;
var notify_handles: [3]u64 = .{ 0, 0, 0 };
var stop_worker: bool = false;
var worker_deadline: u64 = 0;
var cleanup_failed = false;
var run_deadline: u64 = 0;
var observer_overhead_ns: ?u64 = null;
const Error = error{ Cancelled, Timeout, MissingApi, WorkFailed, CleanupFailed };

fn now() Error!u64 {
    return sys.monotonicNanoseconds() orelse error.MissingApi;
}
fn check(deadline: u64) Error!void {
    if (sys.programShouldClose()) return error.Cancelled;
    if (try now() >= deadline) return error.Timeout;
}
fn ticks(ms: u64) u64 {
    return @max(1, sys.ticksFromMilliseconds(ms));
}
fn clock() ?a.MonotonicClockInfo {
    var value: a.MonotonicClockInfo = .{};
    if (sys.monotonicClock(&value) <= 0 or value.flags & a.monotonic_clock_flag_valid == 0 or
        value.flags & a.monotonic_clock_flag_degraded != 0 or value.resolution_ns == 0) return null;
    return value;
}
fn observerCost() ?u64 {
    var minimum: ?u64 = null;
    for (0..64) |_| {
        const start = clock() orelse return null;
        const end = clock() orelse return null;
        if (end.source != start.source or end.generation != start.generation or end.instant_ns <= start.instant_ns) return null;
        const elapsed = end.instant_ns - start.instant_ns;
        minimum = if (minimum) |old| @min(old, elapsed) else elapsed;
    }
    return minimum;
}
fn waitNotification(handle: u64, observed: u64, deadline: u64) Error!void {
    while (true) {
        if (@atomicLoad(bool, &stop_worker, .acquire)) return error.Cancelled;
        try check(deadline);
        const rc = sys.notificationWait(handle, observed, ticks(100));
        if (rc == a.notification_ok) return;
        if (rc != a.notification_timeout) return error.WorkFailed;
    }
}
fn peer(_: u64) callconv(.c) i32 {
    // Publish readiness before the caller starts its clock. The first request
    // is also the start gate; notification sequences retain an early signal.
    if (sys.notificationNotify(notify_handles[2], 1) != a.notification_ok) return 1;
    for (0..model.operation_counts[0]) |i| {
        waitNotification(notify_handles[0], i, worker_deadline) catch return 1;
        if (sys.notificationNotify(notify_handles[1], 1) != a.notification_ok) return 1;
    }
    return 0;
}
fn schedulerSample(deadline: u64) model.Sample {
    var result: model.Sample = .{};
    schedulerBody(deadline, &result);
    return result;
}
fn schedulerBody(deadline: u64, result: *model.Sample) void {
    notify_handles = .{ 0, 0, 0 };
    @atomicStore(bool, &stop_worker, false, .release);
    worker_deadline = deadline;
    var handle: a.ProgramJoinHandle = .{};
    var created = false;
    result.* = .{ .reason = "notification-create-failed" };
    defer {
        @atomicStore(bool, &stop_worker, true, .release);
        if (notify_handles[0] != 0) _ = sys.notificationNotify(notify_handles[0], 1);
        var code: i32 = -1;
        const joined = !created or sys.threadHandleJoin(&handle, ticks(2000), &code) == a.thread_ok;
        if (!joined) {
            // Keep exact notifications until the live worker/process cleanup.
            cleanup_failed = true;
            result.reason = "thread-cleanup-unconfirmed";
        } else {
            if (result.reason == null and code != 0) result.reason = "thread-exit-failed";
            for (notify_handles) |notification| if (notification != 0 and sys.notificationClose(notification) != a.notification_ok) {
                cleanup_failed = true;
                result.reason = "notification-close-failed";
            };
        }
    }
    for (&notify_handles) |*notification| if (sys.notificationCreate(notification) != a.notification_ok) return;
    if (sys.threadCreateHandle(peer, 0, 0, 0, &handle) != a.thread_ok) {
        result.reason = "thread-create-failed";
        return;
    }
    created = true;
    waitNotification(notify_handles[2], 0, deadline) catch |err| {
        result.reason = @errorName(err);
        return;
    };
    const start = clock() orelse {
        result.reason = "clock-unavailable";
        return;
    };
    for (0..model.operation_counts[0]) |i| {
        if (sys.notificationNotify(notify_handles[0], 1) != a.notification_ok) {
            result.reason = "notification-notify-failed";
            return;
        }
        waitNotification(notify_handles[1], i, deadline) catch |err| {
            result.reason = @errorName(err);
            return;
        };
        result.operations += 1;
    }
    finishSample(result, start);
}
fn finishSample(result: *model.Sample, start: a.MonotonicClockInfo) void {
    const end = clock() orelse {
        result.reason = "clock-unavailable";
        return;
    };
    result.clock_source = start.source;
    result.clock_generation = start.generation;
    result.clock_resolution_ns = @max(start.resolution_ns, end.resolution_ns);
    result.observer_overhead_ns = observer_overhead_ns;
    if (end.source != start.source or end.generation != start.generation or end.instant_ns <= start.instant_ns) {
        result.reason = "clock-changed-or-zero-interval";
        return;
    }
    result.elapsed_ns = end.instant_ns - start.instant_ns;
    result.reason = null;
}
fn memoryWork(result: *model.Sample, deadline: u64) Error!void {
    for (0..model.operation_counts[1]) |_| {
        try check(deadline);
        const region = sys.vmReserve(128 * 1024, 4096, 0) orelse return error.WorkFailed;
        var released = false;
        defer if (!released and sys.vmRelease(region.id) != a.vm_ok) {
            cleanup_failed = true;
        };
        if (sys.vmCommit(region.id, 0, 128 * 1024) != a.vm_ok) return error.WorkFailed;
        const memory: [*]volatile u8 = @ptrFromInt(region.base);
        for (0..32) |page| {
            if (memory[page * 4096] != 0) return error.WorkFailed;
            memory[page * 4096] = @intCast(page + 1);
        }
        for (0..32) |page| if (memory[page * 4096] != page + 1) return error.WorkFailed;
        const live = sys.vmQuery(region.id) orelse return error.WorkFailed;
        if (live.fault_count != 32 or live.failed_faults != 0 or live.resident_bytes != 128 * 1024) return error.WorkFailed;
        if (sys.vmRelease(region.id) != a.vm_ok) {
            cleanup_failed = true;
            return error.CleanupFailed;
        }
        released = true;
        if (sys.vmQuery(region.id) != null) return error.CleanupFailed;
        result.operations += 1;
        result.bytes += 128 * 1024;
    }
}
fn ipcWork(result: *model.Sample, deadline: u64) Error!void {
    const network = net orelse return error.MissingApi;
    var response: [a.ipc_max_message_size]u8 = undefined;
    for (0..model.operation_counts[2]) |i| {
        try check(deadline);
        const got = network.netServiceRequest(a.ipc_channel_net_dns, a.net_service_op_dns_status_result, 0x83030000 + @as(u32, @intCast(i)), "", &response);
        if (got < a.net_service_header_size or got > response.len) return error.WorkFailed;
        var status: i32 = -1;
        const payload = network.netServicePayload(response[0..@intCast(got)], &status) orelse return error.WorkFailed;
        if (status != a.net_service_result_ok or payload.len == 0) return error.WorkFailed;
        result.operations += 1;
        result.bytes += a.net_service_header_size;
    }
}
fn sameHandle(x: a.ProgramProcessHandle, y: a.ProgramProcessHandle) bool {
    return x.instance_id == y.instance_id and x.generation == y.generation and x.reserved == 0 and y.reserved == 0;
}
fn lifecycleWork(result: *model.Sample, deadline: u64) Error!void {
    for (0..model.operation_counts[3]) |_| {
        try check(deadline);
        var handle: a.ProgramProcessHandle = .{};
        if (sys.programSpawnHandle(child_path, "", .auto, &handle) != a.program_handle_ok) return error.WorkFailed;
        var reaped = false;
        defer if (!reaped) {
            _ = sys.programHandleRequestClose(&handle);
            var completion: a.ProgramProcessCompletion = .{};
            if (sys.programHandleWait(&handle, ticks(1000), &completion) != a.program_handle_ok) {
                _ = sys.programHandleKill(&handle);
                _ = sys.programHandleWait(&handle, ticks(1000), &completion);
            }
            if (sys.programHandleReap(&handle, &completion) != a.program_handle_ok) cleanup_failed = true;
        };
        var completion: a.ProgramProcessCompletion = .{};
        if (sys.programHandleWait(&handle, ticks(5000), &completion) != a.program_handle_ok) return error.Timeout;
        if (completion.exit_code != 17 or !sameHandle(handle, completion.handle) or
            completion.flags & (a.program_completion_flag_ready | a.program_completion_flag_owner) != (a.program_completion_flag_ready | a.program_completion_flag_owner)) return error.WorkFailed;
        if (sys.programHandleReap(&handle, &completion) != a.program_handle_ok) return error.CleanupFailed;
        reaped = true;
        var info: a.ProgramInstanceInfo = .{};
        if (sys.programHandleStatus(&handle, &info) != a.program_handle_error_not_found) return error.CleanupFailed;
        result.operations += 1;
    }
}
fn filesystemWork(result: *model.Sample, deadline: u64) Error!void {
    if (sys.exists(&file_path)) return error.WorkFailed; // Never replace an unrelated file.
    for (0..model.operation_counts[4]) |_| {
        try check(deadline);
        if (sys.fileStreamBegin(&file_path, a.file_stream_open_replace) < 0) return error.WorkFailed;
        var finished = false;
        var deleted = false;
        defer {
            if (!finished) _ = sys.fileStreamAbort(&file_path);
            if (!deleted and sys.exists(&file_path) and sys.fileDelete(&file_path) <= 0) cleanup_failed = true;
        }
        if (sys.fileStreamWrite(&file_path, 0, &write_bytes, 0) != write_bytes.len or
            sys.fileStreamFinish(&file_path, write_bytes.len, 0) < 0) return error.WorkFailed;
        finished = true;
        if (sys.fileRead(&file_path, &read_bytes) != read_bytes.len or !std.mem.eql(u8, &write_bytes, &read_bytes)) return error.WorkFailed;
        if (sys.fileDelete(&file_path) <= 0 or sys.exists(&file_path)) return error.CleanupFailed;
        deleted = true;
        result.operations += 1;
        result.bytes += write_bytes.len * 2;
    }
}
fn takeSample(index: usize, deadline: u64) model.Sample {
    if (index == 0) return schedulerSample(deadline);
    var result: model.Sample = .{};
    const start = clock() orelse return .{ .reason = "clock-unavailable" };
    const work = switch (index) {
        1 => memoryWork(&result, deadline),
        2 => ipcWork(&result, deadline),
        3 => lifecycleWork(&result, deadline),
        4 => filesystemWork(&result, deadline),
        else => unreachable,
    };
    work catch |err| {
        result.reason = @errorName(err);
        return result;
    };
    finishSample(&result, start);
    return result;
}
fn activeWarmup(index: usize, deadline: u64) model.Sample {
    var total: model.Sample = .{};
    var batches: u64 = 0;
    while (batches < model.warmup_min_batches or total.elapsed_ns < model.warmup_min_ns) {
        check(deadline) catch |err| {
            total.reason = @errorName(err);
            return total;
        };
        const part = takeSample(index, deadline);
        if (part.reason != null or cleanup_failed) return part;
        if (part.operations != model.operation_counts[index] or part.bytes != model.byte_counts[index]) return .{ .reason = "warmup-work-mismatch" };
        if (batches == 0) {
            total = part;
        } else {
            if (part.clock_source != total.clock_source or part.clock_generation != total.clock_generation) return .{ .reason = "warmup-clock-changed" };
            total.elapsed_ns += part.elapsed_ns;
            total.operations += part.operations;
            total.bytes += part.bytes;
            total.clock_resolution_ns = @max(total.clock_resolution_ns, part.clock_resolution_ns);
        }
        batches += 1;
    }
    return total;
}
pub fn run(app: *r4os.App, request: *const cli.Request, out: *Output) i32 {
    const config = @import("standard_reference.zig").parseOptions(request.args()) catch {
        out.unavailable("standard", "use /AREA:id, /BASELINE or /REFERENCE:path /COMPAREKEY:key, and /SETTLE:0..5000");
        return 2;
    };
    sys = app.system();
    net = app.networkLowLevel();
    cleanup_failed = false;
    if (out.detail == null) {
        out.unavailable("standard", "instrumentation-mode-unavailable");
        return 1;
    }
    for (&samples) |*area| area.* = .{model.Sample{}} ** 6;
    metrics = .{model.Metric{}} ** 5;
    var capacity: a.CpuCapacity = .{};
    if (sys.cpuCapacity(&capacity) != 0 or capacity.available_cpus != 4) {
        out.unavailable("standard", "standard profile requires four available CPUs");
        return 1;
    }
    var identity: a.ProgramJoinHandle = .{};
    if (sys.threadCurrentHandle(&identity) != a.thread_ok or identity.instance_id == 0) return 1;
    _ = std.fmt.bufPrintZ(&file_path, "C:\\TEMP\\SB{X:0>8}.BIN", .{identity.instance_id}) catch unreachable;
    for (&write_bytes, 0..) |*byte, i| byte.* = @truncate(i *% 131 +% 17);
    const reference = @import("standard_reference.zig").load(app, config, out.detail);
    const beginning = clock() orelse {
        out.unavailable("standard", "valid nondegraded clock required");
        return 1;
    };
    run_deadline = beginning.instant_ns +| 90_000_000_000;
    var settle: u32 = config.settle_ms;
    while (settle != 0 and !sys.programShouldClose()) {
        const step: u32 = @min(settle, 100);
        sys.sleepTicks(ticks(step));
        settle -= step;
    }
    var exit_code: i32 = 0;
    observer_overhead_ns = observerCost();
    for (&samples, 0..) |*area, index| {
        if (config.area) |selected| if (index != selected) continue;
        for (area, 0..) |*sample, repetition| {
            if (cleanup_failed) {
                sample.reason = "prior-cleanup-unconfirmed";
                exit_code = 1;
                continue;
            }
            check(run_deadline) catch |err| {
                sample.reason = @errorName(err);
                exit_code = if (err == error.Cancelled) 4 else 1;
                continue;
            };
            const deadline = @min(run_deadline, (now() catch run_deadline) +| 10_000_000_000);
            sample.* = if (repetition == 0) activeWarmup(index, deadline) else takeSample(index, deadline);
            const batches = sample.operations / model.operation_counts[index];
            const work_valid = if (repetition == 0)
                batches >= model.warmup_min_batches and sample.operations % model.operation_counts[index] == 0 and sample.bytes == model.byte_counts[index] * batches and sample.elapsed_ns >= model.warmup_min_ns
            else
                sample.operations == model.operation_counts[index] and sample.bytes == model.byte_counts[index];
            if (sample.reason != null or !work_valid or cleanup_failed) {
                if (sample.reason == null) sample.reason = "work-count-mismatch";
                exit_code = 1;
            }
            if (sample.reason) |why| if (std.mem.eql(u8, why, "Cancelled")) {
                exit_code = 4;
            };
        }
        metrics[index] = model.aggregate(area, model.operation_counts[index]);
        if (metrics[index].reason != null) exit_code = 1;
    }
    if (sys.programShouldClose()) exit_code = 4;
    presentation.render(out, &samples, &metrics, reference, config, exit_code, beginning);
    return exit_code;
}
