//! Product launch mailbox + actual large R4X load. No fake worker, delay or
//! source/image patch; existing APPDEF scene input/frames remain active.
const std = @import("std");
const r = @import("r4os");
const a = r.abi;
const w = @import("desktop_launch");
const scene = @import("desktop_check");
const service_path = "C:\\R4OS\\SOFTWARE\\TERMINAL\\DIAG\\SVCAPPD.R4X";
const image = "C:\\R4OS\\SOFTWARE\\TERMINAL\\DIAG\\SPECTRA.R4X";

pub fn run(check: anytype, _: *r.App) !void {
    var sys = check.sys;
    var slow: a.ServiceInfo = .{};
    if (sys.serviceInstall("SVCSTALL", service_path, "/HOLD /STALLENDPOINT", a.service_start_manual, "Async Desktop launch fixture", &slow) != 0) return error.LaunchFixtureInstall;
    defer _ = sys.serviceRemove("SVCSTALL");
    if (sys.serviceStart("SVCSTALL", &slow) != 0) return error.LaunchFixtureStart;
    defer _ = sys.serviceStop("SVCSTALL", &slow, 2000);
    const ready_at = sys.ticks();
    while (true) {
        if (sys.serviceStatus("SVCSTALL", &slow) == 0 and slow.handle != 0) break;
        if (sys.ticks() -% ready_at >= 3000) return error.LaunchFixtureEndpoint;
        try check.pause(1);
    }
    if (sys.serviceOpen("SVCSTALL", &slow) != 0) return error.LaunchFixtureOpen;
    defer _ = sys.serviceClose(slow.handle);
    var broker: a.ServiceInfo = .{};
    if (sys.serviceOpen("WINSVC", &broker) != 0) return error.LaunchBrokerOpen;
    defer _ = sys.serviceClose(broker.handle);
    var broker_owner: a.ProgramProcessHandle = .{};
    if (sys.programOpenHandle(broker.instance_id, &broker_owner) != 0) return error.LaunchBrokerIdentity;
    var request: w.Message = .{
        .broker = .{ .instance = broker_owner.instance_id, .generation = broker_owner.generation },
        .request = .{ .instance = check.caller.instance_id, .generation = check.caller.generation },
        .deadline = sys.ticks() +| 20000,
        .policy = 1, // canonical Console policy, checked against DeskRun producer.
    };
    try w.copy(&request.path, image);
    var args: [128]u8 = undefined;
    try w.copy(&request.args, try std.fmt.bufPrint(&args, "CHECK ASYNC_IO /KILLWAIT {d}", .{slow.handle}));
    try w.copy(&request.title, "Async loader check");
    var receipt = try exchange(&sys, broker.handle, w.submit, request);
    var child: a.ProgramProcessHandle = .{};
    var resolved = false;
    defer if (!resolved and !drainProduct(check, &sys, broker.handle, request, child)) {
        check.launch_cleanup_ack = false;
        check.out.unavailable("DESKTOP", "Product launch child/request has no exact cleanup acknowledgment");
    };
    var observations: u32 = 0;
    var scene_inputs: u32 = 0;
    var frame_overlap = false;
    var before_frames: u64 = 0;
    var after_frames: u64 = 0;
    while (!receipt.done()) {
        try check.checkDeadline();
        const before = try check.call(.launch_status, .{}, 0, 0);
        if (before.y > 0) {
            observations += 1;
            const target: scene.Identity = .{ .instance = check.handles[0].instance_id, .generation = check.handles[0].generation };
            _ = check.call(.drag, target, if (scene_inputs % 2 == 0) @as(i32, 1) else -1, 0) catch |err| {
                if (err != error.BusyOrUserActivity) return err;
                receipt = try exchange(&sys, broker.handle, w.status, request);
                if (receipt.process.valid()) child = .{ .instance_id = receipt.process.instance, .generation = receipt.process.generation };
                continue;
            };
            scene_inputs += 1;
            const after = try check.call(.launch_status, .{}, 0, 0);
            if (after.y > 0 and after.redraws > before.redraws) {
                frame_overlap = true;
                before_frames = before.redraws;
                after_frames = after.redraws;
            }
        }
        receipt = try exchange(&sys, broker.handle, w.status, request);
        if (receipt.process.valid()) child = .{ .instance_id = receipt.process.instance, .generation = receipt.process.generation };
        if (sys.ticks() >= request.deadline and !receipt.done()) return error.LaunchReceiptTimeout;
    }
    if (receipt.process.valid()) child = .{ .instance_id = receipt.process.instance, .generation = receipt.process.generation };
    if (receipt.code != .ok or receipt.phase != .window or child.instance_id == 0 or receipt.window == 0) return error.LaunchProductReceipt;
    const duplicate = try exchange(&sys, broker.handle, w.submit, request);
    if (!duplicate.sameKey(receipt) or !duplicate.process.eql(receipt.process) or duplicate.window != receipt.window or duplicate.phase != receipt.phase) return error.LaunchDuplicate;
    const settled = try check.call(.launch_status, .{}, 0, 0);
    if (settled.x != 0 or settled.y != 0) return error.LaunchWorkerNotJoined;
    const observed_child = child;
    if (!retireHosted(&sys, child)) return error.LaunchDesktopReap;
    child = .{};
    resolved = true;
    check.out.record("async-launch", "DESKTOP", 0, .{
        .path = @as([]const u8, image),
        .process = observed_child,
        .window = receipt.window,
        .productive_spawn_observations = observations,
        .scene_inputs_during_spawn = scene_inputs,
        .frame_overlap = frame_overlap,
        .frames_before = before_frames,
        .frames_after = after_frames,
        .same_key_submit = @as([]const u8, "same process/window"),
        .workers_joined = true,
        .reap_owner = @as([]const u8, "Desktop"),
        .physical_input_or_visibility = @as(?bool, null),
    });
    if (observations == 0 or scene_inputs == 0 or !frame_overlap) return error.NoDesktopFramesDuringProductiveLoad;
    try guiHelper(check, &sys, "CALC.R4X", "");
    try guiHelper(check, &sys, "EXPLORER.R4X", "C:\\");
}
fn exchange(sys: *const r.r4sys.Context, handle: u32, op: u16, request: w.Message) !w.Message {
    var bytes: [w.size]u8 = undefined;
    var response: [w.size]u8 = undefined;
    w.encode(&bytes, request);
    var header: a.ServiceMessageHeader = .{};
    const got = sys.serviceCall(handle, op, &bytes, &header, &response, 3000);
    if (got != w.size or header.status != 0) return error.LaunchTransport;
    const value = try w.decode(&response);
    if (!value.sameKey(request)) return error.LaunchKey;
    return value;
}
fn retireHosted(sys: *const r.r4sys.Context, child: a.ProgramProcessHandle) bool {
    _ = sys.programHandleKill(&child);
    return waitHostedGone(sys, child);
}
fn waitHostedGone(sys: *const r.r4sys.Context, child: a.ProgramProcessHandle) bool {
    const start = sys.ticks();
    while (sys.ticks() -% start < 4000) {
        var info: a.ProgramInstanceInfo = .{};
        const status = sys.programHandleStatus(&child, &info);
        if (status == a.program_handle_error_not_found or status == a.program_handle_error_stale) return true;
        if (status != 0) return false;
        sys.sleepTicks(1);
    }
    return false;
}

fn drainProduct(check: anytype, sys: *const r.r4sys.Context, broker: u32, request: w.Message, known: a.ProgramProcessHandle) bool {
    if (known.instance_id != 0) return retireHosted(sys, known);
    const until = sys.ticks() +| 10000;
    while (sys.ticks() < until) {
        const status = exchange(sys, broker, w.status, request) catch return false;
        if (status.process.valid()) return retireHosted(sys, .{ .instance_id = status.process.instance, .generation = status.process.generation });
        if (status.done() and status.code != .timeout and status.code != .unknown and status.code != .transport) return true;
        if (status.done() and status.code == .timeout) {
            const owner = check.call(.launch_status, .{}, 0, 0) catch return false;
            if (owner.x == 0 and owner.y == 0) return true;
        }
        sys.sleepTicks(1);
    }
    return false;
}

fn guiHelper(check: anytype, sys: *const r.r4sys.Context, target: []const u8, arguments: []const u8) !void {
    var helper: a.ProgramProcessHandle = .{};
    var buffer: [128]u8 = undefined;
    const args = try std.fmt.bufPrintZ(&buffer, "/JSON /WAIT:10000 /WAITFRAME \"C:\\R4OS\\SOFTWARE\\DESKTOP\\{s}\" {s}", .{ target, arguments });
    if (sys.programSpawnHandle("C:\\R4OS\\SOFTWARE\\TERMINAL\\DESKRUN.R4X", args, .console, &helper) != 0) return error.GuiLaunchHelper;
    var helper_reaped = false;
    defer if (!helper_reaped) {
        _ = sys.programHandleKill(&helper);
        var done: a.ProgramProcessCompletion = .{};
        _ = sys.programHandleWait(&helper, 4000, &done);
        _ = sys.programHandleReap(&helper, &done);
    };
    var done: a.ProgramProcessCompletion = .{};
    if (sys.programHandleWait(&helper, 15000, &done) != 0) return error.GuiLaunchWait;
    var text: [1024]u8 = undefined;
    var length: u32 = 0;
    if (sys.programCompletionRead(&helper, 0, &text, &length) != 0 or length == 0 or length > text.len) return error.GuiLaunchOutput;
    var memory: [8192]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&memory);
    const Reply = struct { process_id: u32, process_generation: u64, errorlevel: i32, phase: []const u8, content: u64 };
    const parsed = try std.json.parseFromSlice(Reply, fixed.allocator(), std.mem.trim(u8, text[0..length], " \r\n\t"), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const value = parsed.value;
    if (value.process_id == 0 or value.process_generation == 0) return error.GuiLaunchIdentity;
    var child: a.ProgramProcessHandle = .{ .instance_id = value.process_id, .generation = value.process_generation };
    defer if (child.instance_id != 0 and !retireHosted(sys, child)) {
        check.launch_cleanup_ack = false;
    };
    if (done.exit_code != 0 or value.errorlevel != 0 or !std.mem.eql(u8, value.phase, "content") or value.content == 0) return error.GuiLaunchContent;
    if (sys.programHandleReap(&helper, &done) != 0) return error.GuiLaunchHelperReap;
    helper_reaped = true;
    var alive: a.ProgramInstanceInfo = .{};
    if (sys.programHandleStatus(&child, &alive) != 0 or alive.state == @intFromEnum(a.ProgramInstanceState.done)) return error.GuiChildLostWithHelper;
    const actual = child;
    if (sys.programHandleRequestClose(&child) != 0 or !waitHostedGone(sys, child)) return error.GuiLaunchDesktopReap;
    child = .{};
    check.out.record("async-gui-launch", "DESKTOP", 0, .{ .target = target, .helper = helper, .process = actual, .content_generation = value.content, .survives_helper_reap = true, .close_mode = @as([]const u8, "cooperative; Desktop reap"), .reap_owner = @as([]const u8, "Desktop"), .physical_visibility = @as(?bool, null) });
}
