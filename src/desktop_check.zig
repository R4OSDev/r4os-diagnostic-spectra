//! Spectra owns orchestration/assertions/children. Desktop owns scene actions.
const std = @import("std");
const r = @import("r4os");
const a = r.abi;
const wire = @import("desktop_check");
const Output = @import("output.zig").Output;
const cli = @import("cli.zig");
const paths = [_][*:0]const u8{ "C:\\R4OS\\SOFTWARE\\DESKTOP\\APPDEF.R4X", "C:\\R4OS\\SOFTWARE\\DESKTOP\\CLOCK.R4X" };
const item_id: u64 = 0x5350_4543_5452_4137;

pub const Check = struct {
    sys: r.r4sys.Context,
    out: *Output,
    connection: u32 = 0,
    connection_owner: a.ProgramProcessHandle = .{},
    retired_connections: u32 = 0,
    caller: a.ProgramProcessHandle = .{},
    desktop: wire.Identity = .{},
    handles: [2]a.ProgramProcessHandle = .{a.ProgramProcessHandle{}} ** 2,
    deadline: u64 = 0,
    session: bool = false,
    tray_owned: bool = false,
    tray_sequence: u64 = 0,
    request_item: u64 = item_id,
    resource_group: []const u8 = "DESKTOP",
    cancelled: bool = false,
    launch_cleanup_ack: bool = true,
    desk: ?r.r4desk.Context = null,
    capture_demand: bool = false,
    capture_override: bool = false,
    capture_leases: [4]a.RemoteFrameLease = .{a.RemoteFrameLease{}} ** 4,
    screenshot_intent: bool = false,
    replay_reports: [3]bool = .{false} ** 3,
    native_report: [128:0]u8 = .{0} ** 128,
    native_report_owned: bool = false,

    pub fn checkDeadline(self: *Check) !void {
        if (self.sys.programShouldClose()) {
            self.cancelled = true;
            return error.Cancelled;
        }
        if (self.sys.ticks() >= self.deadline) return error.Timeout;
        if (self.out.failed) return error.Output;
    }
    pub fn pause(self: *Check, milliseconds: u32) !void {
        var left = milliseconds;
        while (left != 0) {
            try self.checkDeadline();
            const step = @min(100, left);
            self.sys.sleepTicks(@max(1, self.sys.ticksFromMilliseconds(step)));
            left -= step;
        }
    }
    fn request(self: *Check, op: wire.Op, target: wire.Identity, dx: i32, dy: i32) !wire.Response {
        if (self.connection != 0) return error.UnclosedConnection;
        var service: a.ServiceInfo = .{};
        if (self.sys.serviceOpen(wire.service, &service) != 0 or service.handle == 0) return error.DesktopUnavailable;
        self.connection = service.handle;
        if (self.sys.programOpenHandle(service.instance_id, &self.connection_owner) != 0) {
            _ = self.closeConnection();
            return error.DesktopUnavailable;
        }
        var bytes: [wire.request_size]u8 = undefined;
        wire.encodeRequest(&bytes, .{ .op = op, .caller = id(self.caller), .target = target, .dx = dx, .dy = dy, .item = self.request_item, .deadline_tick = self.deadline });
        var response: [wire.response_size]u8 = undefined;
        var header: a.ServiceMessageHeader = .{};
        const got = self.sys.serviceCall(self.connection, wire.operation, &bytes, &header, &response, self.sys.ticksFromMilliseconds(3000));
        if (!self.closeConnection()) return error.ConnectionCloseUnacknowledged;
        if (got < 0 or header.status != 0 or got != response.len) {
            self.out.record("desktop-rpc-failure", self.resource_group, 0, .{ .operation = op, .target = target, .returned = got, .header_status = header.status, .expected_bytes = response.len, .rpc_budget_ms = @as(u32, 3000) });
        }
        if (got == a.service_api_result_timeout or header.status == a.service_api_result_timeout) return error.DesktopTimeout;
        if (got == a.service_api_result_busy or header.status == a.service_api_result_busy) return error.DesktopBrokerBusy;
        if (got == a.service_api_result_not_running or header.status == a.service_api_result_not_running) return error.DesktopUnavailable;
        if (got < 0 or header.status != 0 or got != response.len) return error.DesktopTransport;
        const value = try wire.decodeResponse(&response);
        if (value.op != op or !value.desktop.same(self.desktop) or value.target.instance != target.instance or value.target.generation != target.generation)
            return error.OwnerChanged;
        if (op == .snes_finish and value.result == wire.snes_finish_pending) return error.DesktopReportPending;
        if (value.result == a.service_api_result_busy) return error.BusyOrUserActivity;
        if (value.result == a.service_api_result_not_found) return error.NotFound;
        if (value.result == a.service_api_result_disabled) return error.RequiresIsolatedDesktopBoot;
        if (value.result != 0) {
            self.out.record("owner-refusal", self.resource_group, 0, .{ .operation = op, .status = value.result, .desktop = value.desktop });
            return error.DesktopWork;
        }
        return value;
    }
    fn closeConnection(self: *Check) bool {
        if (self.connection == 0) return true;
        const started = self.sys.ticks();
        while (true) {
            const status = self.sys.serviceClose(self.connection);
            if (status == 0) break;
            // A bad exact client handle plus the real retired provider
            // generation proves teardown. An alive/uncertain provider never
            // turns a failed Close into a successful resource receipt.
            if (status != a.service_api_result_bad_handle and status != a.service_api_result_not_found and status != a.service_api_result_not_running)
                return false;
            if (self.connection_owner.instance_id == 0 or self.connection_owner.generation == 0) return false;
            var owner: a.ProgramInstanceInfo = .{};
            const code = self.sys.programHandleStatus(&self.connection_owner, &owner);
            if (code == a.program_handle_error_stale or code == a.program_handle_error_not_found or
                (code == 0 and owner.state == @intFromEnum(a.ProgramInstanceState.done)))
            {
                self.retired_connections += 1;
                break;
            }
            // Endpoint retirement wakes the blocked caller before the
            // provider's process completion is necessarily published.
            if (self.sys.ticks() -% started >= self.sys.ticksFromMilliseconds(1000)) {
                self.out.record("connection-release", "DESKTOP", 0, .{ .handle = self.connection, .service = self.connection_owner, .close_status = status, .owner_status = code, .owner_state = owner.state });
                return false;
            }
            self.sys.sleepTicks(1);
        }
        self.connection = 0;
        self.connection_owner = .{};
        return true;
    }
    pub fn call(self: *Check, op: wire.Op, target: wire.Identity, dx: i32, dy: i32) !wire.Response {
        try self.checkDeadline();
        return self.request(op, target, dx, dy);
    }
    pub fn queryDesktop(self: *Check) !@import("desktop_diagnostics").Snapshot {
        var backend: @import("desktop_metrics.zig").Backend = .{ .sys = self.sys };
        const snapshot = @import("desktop_snapshot_client.zig").read(&backend) catch |err| {
            self.connection = backend.retained_handle;
            self.connection_owner = backend.retained_owner;
            return err;
        };
        return snapshot;
    }
    pub fn beginSession(self: *Check, op: wire.Op) !wire.Response {
        const snapshot = try self.queryDesktop();
        if (snapshot.flags & @import("desktop_diagnostics").owner_valid == 0) return error.DesktopUnavailable;
        self.desktop = .{ .instance = snapshot.desktop_instance, .generation = snapshot.desktop_generation };
        const result = try self.call(op, .{}, 0, 0);
        self.session = true;
        return result;
    }
    pub fn prepareSnes(self: *Check, options: wire.SnesOptions) !void {
        const previous = self.request_item;
        self.request_item = options.bits();
        defer self.request_item = previous;
        _ = try self.call(.snes_prepare, .{}, 0, 0);
    }
    fn window(self: *Check, index: usize) !wire.Response {
        const start = self.sys.ticks();
        while (true) {
            const result = self.call(.snapshot, id(self.handles[index]), 0, 0) catch |err| {
                if (err != error.NotFound) return err;
                if (self.sys.ticks() -% start >= self.sys.ticksFromMilliseconds(5000)) return error.WindowTimeout;
                try self.pause(50);
                continue;
            };
            if (result.gui_revision != 0 and result.flags & wire.geometry_matches != 0) return result;
            if (self.sys.ticks() -% start >= self.sys.ticksFromMilliseconds(5000)) return error.WindowGeometry;
            try self.pause(50);
        }
    }
    fn tray(self: *Check, operation: u16) !a.TrayServiceResponse {
        var service: a.ServiceInfo = .{};
        if (self.sys.serviceOpen(a.window_service_name, &service) != 0) return error.TrayUnavailable;
        var request_value: a.TrayServiceRequest = .{ .owner = self.caller, .item_id = item_id, .item_revision = 1, .item_flags = a.tray_item_flag_visible | a.tray_item_flag_enabled, .icon_width = a.tray_icon_width, .icon_height = a.tray_icon_height, .icon_format = a.tray_icon_format_argb32, .icon = @splat(0xff4080e0), .after_sequence = self.tray_sequence, .deadline_tick = self.sys.ticks() +| self.sys.ticksFromMilliseconds(500) };
        var reply: a.TrayServiceResponse = .{};
        var header: a.ServiceMessageHeader = .{};
        const got = self.sys.serviceCall(service.handle, operation, std.mem.asBytes(&request_value), &header, std.mem.asBytes(&reply), self.sys.ticksFromMilliseconds(1000));
        const closed = self.sys.serviceClose(service.handle);
        if (closed != 0) return error.TrayConnectionClose;
        if (got != @sizeOf(a.TrayServiceResponse) or header.status != 0 or reply.result != a.tray_result_ok or
            reply.magic != a.tray_service_response_magic or reply.version != a.tray_service_response_version or
            reply.size != @sizeOf(a.TrayServiceResponse) or !id(reply.owner).same(id(self.caller)) or reply.item_id != item_id)
            return error.TrayResponse;
        return reply;
    }
    pub fn closeChild(self: *Check, index: usize, allow_kill: bool) bool {
        const handle = &self.handles[index];
        if (handle.instance_id == 0) return true;
        _ = self.sys.programHandleRequestClose(handle);
        var done: a.ProgramProcessCompletion = .{};
        var waited = self.sys.programHandleWait(handle, self.sys.ticksFromMilliseconds(4000), &done);
        if (waited != 0 and allow_kill) {
            _ = self.sys.programHandleKill(handle);
            waited = self.sys.programHandleWait(handle, self.sys.ticksFromMilliseconds(3000), &done);
        }
        if (waited != 0 or !id(done.handle).same(id(handle.*)) or done.sequence == 0) return false;
        const sequence = done.sequence;
        const exit_code = done.exit_code;
        if (exit_code != 0) {
            // Capture the exact completed child's failure before Reap removes
            // its console, including failures before the normal wait/read.
            var bytes: [4096]u8 = undefined;
            var count: u32 = 0;
            const read_status = self.sys.programCompletionRead(handle, 0, &bytes, &count);
            if (read_status == 0 and count <= bytes.len) {
                self.out.message("desktop-child-failure", bytes[0..count], false);
            } else {
                self.out.record("desktop-child-output-unavailable", self.resource_group, index, .{ .handle = handle.*, .sequence = sequence, .exit_code = exit_code, .read_status = read_status, .reported_bytes = count });
            }
        }
        const reap_start = self.sys.ticks();
        while (true) {
            const status = self.sys.programHandleReap(handle, &done);
            if (status == 0) break;
            if (status != a.program_handle_error_would_block or self.sys.ticks() -% reap_start >= self.sys.ticksFromMilliseconds(3000)) return false;
            self.sys.sleepTicks(1);
        }
        if (!id(done.handle).same(id(handle.*)) or done.sequence != sequence) return false;
        self.out.record("completion", self.resource_group, index, .{ .handle = handle.*, .sequence = sequence, .exit_code = exit_code, .reaped = true });
        handle.* = .{};
        return allow_kill or exit_code == 0;
    }
    pub fn cleanup(self: *Check) bool {
        var ok = self.launch_cleanup_ack;
        self.deadline = self.sys.ticks() +| self.sys.ticksFromMilliseconds(10000);
        if (!self.closeConnection()) ok = false;
        if (self.desk) |desk| if (!self.releaseCapture(&desk)) {
            ok = false;
        };
        if (!self.releaseScreenshot()) ok = false;
        for (&self.replay_reports, 0..) |*owned, sequence| {
            if (!owned.*) continue;
            var buffer: [128:0]u8 = undefined;
            const path = wire.captureReportPath(&buffer, id(self.caller), sequence) catch {
                ok = false;
                continue;
            };
            if (self.sys.exists(path) and self.sys.fileDelete(path) < 0) {
                ok = false;
            } else owned.* = false;
        }
        if (self.tray_owned) {
            if (self.tray(a.tray_service_op_remove)) |_| self.tray_owned = false else |_| {
                ok = false;
            }
        }
        for (0..2) |index| if (!self.closeChild(index, true)) {
            ok = false;
        };
        if (self.native_report_owned) {
            if (self.handles[0].instance_id != 0 or self.handles[1].instance_id != 0) {
                ok = false; // A live/unreaped producer may still write its file.
            } else if (self.sys.exists(&self.native_report) and self.sys.fileDelete(&self.native_report) < 0) {
                ok = false;
            } else self.native_report_owned = false;
        }
        if (self.session) {
            const start = self.sys.ticks();
            while (self.session) {
                if (self.request(.end, .{}, 0, 0)) |_| self.session = false else |err| {
                    if (err != error.BusyOrUserActivity or self.sys.ticks() -% start >= self.sys.ticksFromMilliseconds(3000)) {
                        ok = false;
                        break;
                    }
                    self.sys.sleepTicks(1);
                }
            }
        }
        if (!self.closeConnection()) ok = false;
        return ok;
    }
    pub fn releaseCapture(self: *Check, desk: *const r.r4desk.Context) bool {
        var ok = true;
        for (&self.capture_leases) |*lease| if (lease.id != 0) {
            if (desk.remoteFrameSnapshotRelease(lease) == 0) lease.* = .{} else ok = false;
        };
        if (self.capture_demand) {
            if (desk.remoteFrameRelease() >= 0) self.capture_demand = false else ok = false;
        }
        if (self.capture_override) {
            if (self.request(.capture, .{}, 0, 0)) |_| self.capture_override = false else |_| {
                ok = false;
            }
        }
        return ok;
    }
    pub fn releaseScreenshot(self: *Check) bool {
        if (!self.screenshot_intent) return true;
        const start = self.sys.ticks();
        while (true) {
            const reply = self.request(.screenshot_cancel, .{}, 0, 0) catch return false;
            if (reply.screenshot_state == 0 or reply.screenshot_state == 2) break;
            if (self.sys.ticks() -% start >= self.sys.ticksFromMilliseconds(3000)) return false;
            self.sys.sleepTicks(1);
        }
        var buffer: [128:0]u8 = undefined;
        const path = wire.screenshotPath(&buffer, id(self.caller)) catch return false;
        var part_buffer: [140:0]u8 = undefined;
        const part = std.fmt.bufPrintZ(&part_buffer, "{s}.PART", .{path}) catch return false;
        if (self.sys.exists(path) and self.sys.fileDelete(path) < 0) return false;
        if (self.sys.exists(part) and self.sys.fileDelete(part) < 0) return false;
        self.screenshot_intent = false;
        return true;
    }
    fn work(self: *Check, app: *r.App, restart: bool, audio: bool, capture: bool, launch: bool, replay: bool) !void {
        for (paths) |path| if (!self.sys.exists(path)) return error.RequiredFullFixtureMissing;
        const begin = try self.beginSession(.begin);
        if ((restart or audio or capture) and begin.flags & wire.isolated == 0) return error.RequiresIsolatedDesktopBoot;
        self.out.record("owner", "DESKTOP", 0, .{ .contract_version = @as(u32, 2), .desktop = self.desktop, .caller = self.caller, .isolated_boot = begin.flags & wire.isolated != 0, .deadline_tick = self.deadline });
        for (paths, 0..) |path, index| {
            if (self.sys.programSpawnHandle(path, "", .gui, &self.handles[index]) != 0 or self.handles[index].instance_id == 0) return error.FixtureSpawn;
            _ = try self.call(.bind, id(self.handles[index]), 0, 0);
            _ = try self.window(index);
        }
        const initial = try self.window(0);
        const dx: i32 = if (initial.x >= 32) -32 else 32;
        const dy: i32 = if (initial.y >= 16) -16 else 16;
        const moved = try self.call(.drag, id(self.handles[0]), dx, dy);
        if (moved.x == initial.x or moved.y == initial.y or moved.flags & wire.geometry_matches == 0) {
            self.out.record("geometry-failure", "DESKTOP", 0, .{ .initial = initial, .moved = moved, .requested_dx = dx, .requested_dy = dy });
            return error.DragGeometry;
        }
        const resized = try self.call(.resize, id(self.handles[0]), 32, 24);
        if (resized.w <= moved.w or resized.h <= moved.h or resized.flags & wire.geometry_matches == 0) {
            self.out.record("geometry-failure", "DESKTOP", 0, .{ .moved = moved, .resized = resized });
            return error.ResizeGeometry;
        }
        for ([_]usize{ 0, 1, 0 }) |index| {
            const focused = try self.call(.focus, id(self.handles[index]), 0, 0);
            if (focused.flags & wire.focused == 0) return error.Focus;
        }
        if (launch) try @import("desktop_launch_check.zig").run(self, app);
        // Settle only our final focus/resize events, then compare the actual
        // static and ticking GUI revisions over the original two-second span.
        try self.pause(300);
        const idle = try self.window(0);
        const timer = try self.window(1);
        try self.pause(2100);
        const idle_after = try self.window(0);
        const timer_after = try self.window(1);
        if (idle_after.gui_revision != idle.gui_revision or timer_after.gui_revision == timer.gui_revision or
            idle_after.idle_timeouts <= idle.idle_timeouts) return error.IdleTwoProducers;
        self.out.record("windows", "DESKTOP", 0, .{ .initial = initial, .moved = moved, .resized = resized, .idle_revision_before = idle.gui_revision, .idle_revision_after = idle_after.gui_revision, .timer_revision_before = timer.gui_revision, .timer_revision_after = timer_after.gui_revision, .idle_timeouts = idle_after.idle_timeouts - idle.idle_timeouts });
        self.tray_owned = true; // A refused/ambiguous upsert still needs Remove.
        _ = try self.tray(a.tray_service_op_upsert);
        const started = self.sys.ticks();
        while (true) {
            _ = self.call(.tray, .{}, 0, 0) catch |err| {
                if (err != error.NotFound or self.sys.ticks() -% started >= self.sys.ticksFromMilliseconds(3000)) return err;
                try self.pause(50);
                continue;
            };
            break;
        }
        const event = try self.tray(a.tray_service_op_wait_event);
        if (event.flags & a.tray_response_flag_event == 0 or event.event.kind != a.tray_event_kind_primary or
            !id(event.event.owner).same(id(self.caller)) or event.event.item_id != item_id or event.event.sequence == 0) return error.TrayEvent;
        self.tray_sequence = event.event.sequence;
        _ = try self.tray(a.tray_service_op_remove);
        self.tray_owned = false;
        self.out.record("tray", "DESKTOP", 0, .{ .owner = self.caller, .item_id = item_id, .event = event.event, .remove_ack = true });
        const volume = try self.call(.volume, .{}, 0, 0);
        if (volume.flags & wire.volume_targets == 0) return error.VolumeTargets;
        if (audio) _ = try self.call(.audio, .{}, 0, 0);
        if (restart) {
            const old = try self.window(0);
            _ = try self.call(.restart, .{}, 0, 0);
            const restart_start = self.sys.ticks();
            while (true) {
                const current = self.window(0) catch |err| {
                    if (err != error.WindowGeometry and err != error.WindowTimeout and err != error.DesktopUnavailable and
                        err != error.DesktopTransport and err != error.DesktopTimeout) return err;
                    if (self.sys.ticks() -% restart_start >= self.sys.ticksFromMilliseconds(8000)) return error.RestartTimeout;
                    try self.pause(50);
                    continue;
                };
                if (current.restart_state == 3) return error.RestartRefused;
                if (current.restart_state == 2 and current.restart_result == 0 and current.flags & wire.service_available != 0 and current.service_handle != old.service_handle) {
                    self.out.record("restart", "DESKTOP", 0, .{ .old_service_handle = old.service_handle, .current = current });
                    break;
                }
                if (self.sys.ticks() -% restart_start >= self.sys.ticksFromMilliseconds(8000)) return error.RestartTimeout;
                try self.pause(50);
            }
        }
        for (0..2) |index| {
            _ = try self.call(.close, id(self.handles[index]), 0, 0);
            if (!self.closeChild(index, false)) return error.FixtureClose;
        }
        if (replay) try @import("desktop_replay_check.zig").run(app, self);
        if (capture) try @import("desktop_capture_check.zig").run(self, app);
        // Normal public capture, immutable readers and Exit-owned are one
        // shared public snapshot oracle, not copied private Desktop test bodies.
    }
};
fn id(handle: a.ProgramProcessHandle) wire.Identity {
    return .{ .instance = handle.instance_id, .generation = handle.generation };
}

pub fn run(app: *r.App, args: []const u8, out: *Output) i32 {
    var navigation_options = std.mem.tokenizeAny(u8, args, " \t");
    while (navigation_options.next()) |option| if (cli.same(option, "/NAV")) return @import("explorer_navigation_check.zig").run(app, args, out);

    if (cli.same(args, "/CANCEL")) return @import("desktop_cancel.zig").run(app, out);
    var restart = false;
    var audio = false;
    var capture = false;
    var own_host = false;
    var launch = false;
    var replay = false;
    var tokens: cli.Tokens = .{ .input = args };
    while (tokens.next() catch return 2) |token| {
        if (cli.same(token, "/RESTART") and !restart) restart = true else if (cli.same(token, "/AUDIO") and !audio) audio = true else if (cli.same(token, "/CAPTURE") and !capture) capture = true else if (cli.same(token, "/HOST") and !own_host) own_host = true else if (cli.same(token, "/LAUNCH") and !launch) launch = true else if (cli.same(token, "/REPLAY") and !replay) replay = true else return 2;
    }
    if (launch and !own_host) return 2;
    @import("check_context.zig").emit(app, out, "DESKTOP");
    var check: Check = .{ .sys = app.system(), .out = out, .desk = app.desktop() };
    var host: @import("desktop_host_check.zig").Owner = .{};
    defer if (!host.retired and !host.finish(check.sys, out)) out.unavailable("DESKTOP", "owned host cleanup not acknowledged");
    if (own_host) host.start(check.sys) catch |err| {
        out.unavailable("DESKTOP", @errorName(err));
        out.record("result", "DESKTOP", 0, .{ .exit_code = @as(i32, 1), .success = false, .cleanup_acknowledged = host.finish(check.sys, out) });
        return 1;
    };
    check.deadline = check.sys.ticks() +| check.sys.ticksFromMilliseconds(60000);
    if (check.sys.programOpenHandle(@intCast(app.raw.instance_id), &check.caller) != 0) {
        out.unavailable("DESKTOP", "current caller identity unavailable");
        out.record("result", "DESKTOP", 0, .{ .exit_code = @as(i32, 1), .success = false, .cleanup_acknowledged = true });
        return 1;
    }
    var result: i32 = 0;
    check.work(app, restart, audio, capture, launch, replay) catch |err| {
        const cancelled = check.cancelled or check.sys.programShouldClose();
        result = if (cancelled) 4 else 1;
        out.unavailable("DESKTOP", if (cancelled) "Cancelled" else @errorName(err));
    };
    var cleaned = check.cleanup();
    if (!cleaned) result = 1;
    if (result == 0) {
        const capture_result = @import("remote_frame_check.zig").run(app, "", out);
        if (capture_result != 0) result = capture_result;
    }
    if (!host.finish(check.sys, out)) {
        cleaned = false;
        result = 1;
    }
    if (host.exit_code) |code| if (code != 0) {
        result = 1;
    };
    out.record("result", "DESKTOP", 0, .{ .exit_code = result, .success = result == 0, .cleanup_acknowledged = cleaned, .connections_retired_with_exact_service = check.retired_connections, .input_consumed_by_check = false, .physical_visibility = @as(?bool, null), .cursor_latency_ns = @as(?u64, null) });
    return result;
}
