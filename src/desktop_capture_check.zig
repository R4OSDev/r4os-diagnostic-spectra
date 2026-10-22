//! Public leases/assertions stay in Spectra; synthetic publisher and the real
//! screenshot worker stay in the isolated Desktop owner.
const std = @import("std");
const r = @import("r4os");
const a = r.abi;
const wire = @import("desktop_check");

pub fn run(check: anytype, app: *r.App) !void {
    const desk = app.desktop() orelse return error.CaptureUnavailable;
    var stats: a.RemoteFrameCaptureStats = .{};
    if (desk.remoteFrameCaptureStats(&stats) != 0 or stats.consumers != 0 or stats.leases != 0 or stats.live_bytes != 0)
        return error.CaptureBusy;
    if (desk.remoteFrameAcquire() != 1) return error.CaptureAcquire;
    check.capture_demand = true;
    var info: a.RemoteFrameInfo = .{};
    const start = check.sys.ticks();
    while (desk.remoteFrameSnapshotAcquire(0, &info, &check.capture_leases[0]) != 0) {
        try check.pause(20);
        if (check.sys.ticks() -% start > check.sys.ticksFromMilliseconds(5000)) return error.CaptureTimeout;
    }
    if (info.frame_pixels < 16 or check.capture_leases[0].capacity_pixels < info.frame_pixels or check.capture_leases[0].pixels_addr == 0)
        return error.CaptureGeometry;
    const width = info.width; const height = info.height;
    const original: [*]const u32 = @ptrFromInt(check.capture_leases[0].pixels_addr);
    const old = original[0..16].*;
    const pixels = [_]u32{ 0xff0000, 0x00ff00, 0x0000ff, 0xffffff };
    check.capture_override = true; // A timed-out RPC may already have run.
    _ = try check.call(.capture, .{}, 2, 0);
    if (desk.remoteFrameSnapshotAcquire(0, &info, &check.capture_leases[1]) != 0 or info.width != 2 or info.height != 2) return error.CaptureResize;
    _ = try check.call(.capture, .{}, 3, 0);
    if (desk.remoteFrameSnapshotAcquire(0, &info, &check.capture_leases[2]) != 0 or
        check.capture_leases[2].epoch == check.capture_leases[1].epoch or !std.mem.eql(u32, &old, original[0..16]) or
        !std.mem.eql(u32, &pixels, @as([*]const u32, @ptrFromInt(check.capture_leases[1].pixels_addr))[0..4])) return error.CaptureImmutableReset;
    _ = try check.call(.capture, .{}, 4, 0);
    if (desk.remoteFrameSnapshotAcquire(0, &info, &check.capture_leases[3]) != a.remote_frame_error_unavailable or check.capture_leases[3].id != 0)
        return error.CaptureSnapshotLimit;
    if (desk.remoteFrameSnapshotRelease(&check.capture_leases[1]) != 0) return error.CaptureRelease;
    check.capture_leases[1] = .{};
    if (desk.remoteFrameSnapshotAcquire(0, &info, &check.capture_leases[3]) != 0 or info.width != 4 or info.height != 1) return error.CaptureSnapshotReuse;
    if (desk.remoteFrameCaptureStats(&stats) != 0 or stats.consumers != 1 or stats.leases != 3 or stats.snapshots > 3) return error.CaptureBounds;
    if (@import("remote_frame_check.zig").exitCheck(&check.sys, &desk, check.out, stats) != 0) return error.CaptureExitOwned;
    if (!check.releaseCapture(&desk)) return error.CaptureCleanup;
    const retired_start = check.sys.ticks();
    while (true) {
        if (desk.remoteFrameCaptureStats(&stats) != 0) return error.CaptureStats;
        if (stats.consumers == 0 and stats.leases == 0 and stats.live_bytes == 0 and stats.snapshot_bytes == 0) break;
        try check.pause(20);
        if (check.sys.ticks() -% retired_start >= check.sys.ticksFromMilliseconds(3000)) return error.CaptureRetirement;
    }
    check.out.record("capture", "DESKTOP", 0, .{ .width = width, .height = height, .immutable_across_resize_reset = true,
        .snapshot_limit = @as(u32, 3), .snapshot_reuse = true, .retired = stats });

    var path_buffer: [128:0]u8 = undefined;
    const path = try wire.screenshotPath(&path_buffer, .{ .instance = check.caller.instance_id, .generation = check.caller.generation });
    var part_buffer: [140:0]u8 = undefined;
    const part = try std.fmt.bufPrintZ(&part_buffer, "{s}.PART", .{path});
    if (check.sys.exists(path) or check.sys.exists(part)) return error.ScreenshotFileConflict;
    check.screenshot_intent = true;
    _ = try check.call(.screenshot, .{}, 0, 0);
    const save_start = check.sys.ticks();
    const saved = while (true) {
        const reply = try check.call(.screenshot_status, .{}, 0, 0);
        if (reply.screenshot_state == 2) break reply;
        try check.pause(50);
        if (check.sys.ticks() -% save_start >= check.sys.ticksFromMilliseconds(15000)) return error.ScreenshotTimeout;
    };
    var header: [54]u8 = undefined;
    const file = check.sys.fileInfo(path) orelse return error.ScreenshotMissing;
    if (check.sys.fileReadAt(path, 0, &header) != header.len or header[0] != 'B' or header[1] != 'M' or
        saved.screenshot_bytes != 54 + @as(u64, width) * height * 4 or file.size != saved.screenshot_bytes or
        std.mem.readInt(u32, header[2..6], .little) != file.size or std.mem.readInt(u32, header[18..22], .little) != width or
        std.mem.readInt(i32, header[22..26], .little) != -@as(i32, @intCast(height))) return error.ScreenshotBitmap;
    if (!check.releaseScreenshot()) return error.ScreenshotCleanup;
    if (desk.remoteFrameCaptureStats(&stats) != 0 or stats.consumers != 0 or stats.leases != 0 or
        stats.live_bytes != 0 or stats.snapshot_bytes != 0) return error.ScreenshotCaptureRetirement;
    check.out.record("screenshot", "DESKTOP", 0, .{ .width = width, .height = height, .bytes = saved.screenshot_bytes,
        .real_worker_joined = true, .bmp_header_checked = true, .own_file_removed = true, .retired = stats });
}
