const std = @import("std");
const r = @import("r4os");
const a = r.abi;
const oracle = @import("checks/remote_frame.zig");
const Output = @import("output.zig").Output;
pub const child_argument = "/REMOTEFRAME-EXIT-CHILD";
const executable = "C:\\R4OS\\SOFTWARE\\TERMINAL\\DIAG\\SPECTRA.R4X";

pub fn child(app: *r.App) i32 {
    const sys = app.system();
    const desk = app.desktop() orelse return 1;
    const result = oracle.run(&sys, &desk, true);
    return result.exit_code;
}

pub fn run(app: *r.App, args: []const u8, out: *Output) i32 {
    const exit_owned = std.ascii.eqlIgnoreCase(args, "/EXITOWNED");
    if (args.len != 0 and !exit_owned) return 2;
    @import("check_context.zig").emit(app, out, "REMOTEFRAME");
    const sys = app.system();
    const desk = app.desktop() orelse {
        out.unavailable("REMOTEFRAME", "R4DESK unavailable");
        return 1;
    };
    const result = if (exit_owned) exitCheck(&sys, &desk, out, null) else blk: {
        const value = oracle.run(&sys, &desk, false);
        out.record("check", "REMOTEFRAME", 0, value);
        break :blk value.exit_code;
    };
    out.record("result", "REMOTEFRAME", 0, .{ .exit_code = result, .success = result == 0 });
    return result;
}

fn same(x: a.ProgramProcessHandle, y: a.ProgramProcessHandle) bool {
    return x.instance_id != 0 and x.instance_id == y.instance_id and x.generation == y.generation;
}
fn cleanChild(sys: *const r.r4sys.Context, handle: *const a.ProgramProcessHandle) bool {
    _ = sys.programHandleRequestClose(handle);
    var done: a.ProgramProcessCompletion = .{};
    if (sys.programHandleWait(handle, sys.ticksFromMilliseconds(1000), &done) != a.program_handle_ok) {
        _ = sys.programHandleKill(handle);
        if (sys.programHandleWait(handle, sys.ticksFromMilliseconds(3000), &done) != a.program_handle_ok) return false;
    }
    return same(done.handle, handle.*) and done.sequence != 0 and sys.programHandleReap(handle, &done) == a.program_handle_ok;
}
pub fn exitCheck(sys: *const r.r4sys.Context, desk: *const r.r4desk.Context, out: *Output, owned_baseline: ?a.RemoteFrameCaptureStats) i32 {
    var before: a.RemoteFrameCaptureStats = .{};
    const expected = owned_baseline orelse a.RemoteFrameCaptureStats{};
    if (desk.remoteFrameCaptureStats(&before) != 0 or before.consumers != expected.consumers or before.leases != expected.leases) {
        out.unavailable("REMOTEFRAME", "exit-owned requires no existing capture consumers or leases");
        return 1;
    }
    if (sys.programShouldClose()) return 4;
    var handle: a.ProgramProcessHandle = .{};
    if (sys.programSpawnHandle(executable, child_argument, .console, &handle) != a.program_handle_ok or handle.instance_id == 0) {
        out.unavailable("REMOTEFRAME", "exit-owned child spawn failed");
        return 1;
    }
    var done: a.ProgramProcessCompletion = .{};
    const start = sys.ticks();
    var failure: ?[]const u8 = null;
    var cancelled = false;
    while (true) {
        if (sys.programShouldClose()) { failure = "cancelled"; cancelled = true; break; }
        const code = sys.programHandleWait(&handle, sys.ticksFromMilliseconds(100), &done);
        if (code == a.program_handle_ok) break;
        if (code != a.program_handle_error_timeout) { failure = "child-wait"; break; }
        if (sys.ticks() -% start >= sys.ticksFromMilliseconds(15000)) { failure = "child-timeout"; break; }
    }
    if (failure) |reason| {
        const cleaned = cleanChild(sys, &handle);
        out.record("check", "REMOTEFRAME", 0, .{ .reason = reason, .cleanup_ok = cleaned, .child = handle });
        return if (cancelled and cleaned) 4 else 1;
    }
    const completed = same(done.handle, handle) and done.sequence != 0 and done.exit_code == 0;
    const sequence = done.sequence;
    const reaped = sys.programHandleReap(&handle, &done) == a.program_handle_ok and same(done.handle, handle) and done.sequence == sequence;
    if (!reaped) {
        out.record("check", "REMOTEFRAME", 0, .{ .reason = @as([]const u8, "reap-unacknowledged"), .child = handle });
        return 1;
    }
    var after: a.RemoteFrameCaptureStats = .{};
    const cleanup_start = sys.ticks();
    var retired = false;
    while (sys.ticks() -% cleanup_start < sys.ticksFromMilliseconds(3000)) {
        if (desk.remoteFrameCaptureStats(&after) == 0 and after.consumers == before.consumers and after.leases == before.leases and
            (if (owned_baseline != null) after.epoch == before.epoch and after.snapshot_bytes == before.snapshot_bytes
                else after.live_bytes == 0 and after.snapshot_bytes == 0)) { retired = true; break; }
        sys.sleepTicks(1);
    }
    out.record("exit-owned", "REMOTEFRAME", 0, .{ .child = handle, .completion_sequence = sequence,
        .child_exit_code = done.exit_code, .reaped = reaped, .owner_resources_retired = retired, .before = before, .after = after });
    return if (completed and retired) 0 else 1;
}
