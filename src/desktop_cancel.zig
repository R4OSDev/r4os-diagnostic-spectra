//! Explicit cancellation case of the same Desktop body, with a real owned
//! child. No second GUI fixture or alternative check implementation.
const std = @import("std");
const r = @import("r4os");
const a = r.abi;
const Output = @import("output.zig").Output;
var snapshot: a.WindowServiceSnapshot = .{};

fn windowCount(sys: *const r.r4sys.Context) !u32 {
    var service: a.ServiceInfo = .{};
    if (sys.serviceOpen(a.window_service_name, &service) != 0) return error.WindowServiceUnavailable;
    var header: a.ServiceMessageHeader = .{};
    const got = sys.serviceCall(service.handle, a.window_service_op_snapshot, "", &header, std.mem.asBytes(&snapshot), sys.ticksFromMilliseconds(1000));
    if (sys.serviceClose(service.handle) != 0) return error.ConnectionCloseUnacknowledged;
    if (got != @sizeOf(a.WindowServiceSnapshot) or header.status != 0) return error.WindowSnapshot;
    return snapshot.status.window_count;
}

pub fn run(app: *r.App, out: *Output) i32 {
    @import("check_context.zig").emit(app, out, "DESKTOP-CANCEL");
    const sys = app.system();
    if ((windowCount(&sys) catch 1) != 0) {
        out.unavailable("DESKTOP-CANCEL", "requires a quiet Desktop without existing windows");
        return 1;
    }
    var self: a.ProgramProcessHandle = .{};
    if (sys.programOpenHandle(@intCast(app.raw.instance_id), &self) != 0) return 1;
    var child: a.ProgramProcessHandle = .{};
    var reaped = false;
    var path_storage: [96:0]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_storage, "C:\\TEMP\\DCANCEL{X:0>8}-{X:0>16}.OUT", .{ self.instance_id, self.generation }) catch return 1;
    if (sys.exists(path)) { out.unavailable("DESKTOP-CANCEL", "own output path already exists"); return 1; }
    var command_storage: [192:0]u8 = undefined;
    const command = std.fmt.bufPrintZ(&command_storage, "CHECK DESKTOP {s} /EXPORT:{s}", .{ if (out.format == .json) @as([]const u8, "/JSON") else "", path }) catch return 1;
    if (sys.programSpawnHandle("C:\\R4OS\\SOFTWARE\\TERMINAL\\DIAG\\SPECTRA.R4X", command, .console, &child) != 0) return 1;
    var result: i32 = 0;
    var reason: []const u8 = "cooperative child exit, exact reap and resource retirement";
    const start = sys.ticks();
    var observed: u32 = 0;
    while (sys.ticks() -% start < sys.ticksFromMilliseconds(5000) and !sys.programShouldClose()) {
        observed = windowCount(&sys) catch break;
        if (observed >= 2) break;
        sys.sleepTicks(1);
    }
    if (observed < 2) { result = 1; reason = "two real owned GUI windows unavailable"; }
    if (sys.programShouldClose()) { result = 4; reason = "controller cancelled"; }
    if (sys.programHandleRequestClose(&child) != 0) { result = 1; reason = "child close unacknowledged"; }
    var done: a.ProgramProcessCompletion = .{};
    if (sys.programHandleWait(&child, sys.ticksFromMilliseconds(15000), &done) != 0) {
        result = 1; reason = "cooperative child timeout";
        _ = sys.programHandleKill(&child);
        _ = sys.programHandleWait(&child, sys.ticksFromMilliseconds(5000), &done);
    }
    if (done.sequence != 0 and done.handle.instance_id == child.instance_id and done.handle.generation == child.generation) {
        const sequence = done.sequence;
        reaped = sys.programHandleReap(&child, &done) == 0 and done.sequence == sequence and
            done.handle.instance_id == child.instance_id and done.handle.generation == child.generation;
    }
    if (!reaped or done.exit_code != 4) { result = 1; reason = "expected real cancelled completion/reap missing"; }
    var empty = false;
    const cleanup_start = sys.ticks();
    while (reaped and sys.ticks() -% cleanup_start < sys.ticksFromMilliseconds(3000)) {
        const count = windowCount(&sys) catch break;
        if (count == 0) { empty = true; break; }
        sys.sleepTicks(1);
    }
    var stats: a.RemoteFrameCaptureStats = .{};
    const desk = app.desktop();
    const capture_empty = if (desk) |d| d.remoteFrameCaptureStats(&stats) == 0 and stats.consumers == 0 and
        stats.leases == 0 and stats.live_bytes == 0 and stats.snapshot_bytes == 0 else false;
    if (!empty or !capture_empty) { result = 1; reason = "owned GUI/capture resources not retired"; }
    if (reaped) {
        // Preserve the child's exact versioned records, including its genuine
        // expected Exit4, separately from this controller's result.
        const info = sys.fileInfo(path);
        if (info) |file| {
            if (file.size == 0 or file.size > 64 * 1024) { result = 1; reason = "child export bounds"; }
            else {
                var buffer: [4096]u8 = undefined;
                var offset: u64 = 0;
                while (offset < file.size) {
                    const count: usize = @intCast(@min(buffer.len, file.size - offset));
                    if (sys.fileReadAt(path, @intCast(offset), buffer[0..count]) != count) { result = 1; reason = "child export read"; break; }
                    out.write(buffer[0..count]); offset += count;
                }
            }
            if (sys.fileDelete(path) < 0) { result = 1; reason = "own export deletion unacknowledged"; }
        } else { result = 1; reason = "child export missing"; }
    }
    out.record("result", "DESKTOP-CANCEL", 0, .{ .exit_code = result, .success = result == 0, .reason = reason,
        .child = child, .child_exit_code = done.exit_code, .completion_sequence = done.sequence, .reaped = reaped,
        .windows_observed = observed, .windows_retired = empty, .capture_retired = capture_empty });
    return result;
}
