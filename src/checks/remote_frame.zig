//! Public RemoteFrame oracle migrated from RFDIAG; see Provenance/RemoteFrameDiag.
//! Both entry points use this body until the old module is retired.
const std = @import("std");
const r = @import("r4os");
const a = r.abi;
pub const Result = struct {
    exit_code: i32 = 1,
    reason: []const u8 = "unavailable",
    cleanup_ok: bool = true,
    held_until_exit: bool = false,
    info: ?a.RemoteFrameInfo = null,
    stats: ?a.RemoteFrameCaptureStats = null,
    head_pixels: u32 = 0,
    tail_pixels: u32 = 0,
    head_sum: u32 = 0,
    tail_sum: u32 = 0,
    wait_result: i32 = -1,
};

pub fn run(sys: *const r.r4sys.Context, desk: *const r.r4desk.Context, leave_owned: bool) Result {
    var result: Result = .{};
    if (sys.programShouldClose()) return .{ .exit_code = 4, .reason = "cancelled" };
    if (desk.remoteFrameAcquire() <= 0) return .{ .reason = "demand-acquire" };
    var lease: a.RemoteFrameLease = .{};
    var peer: a.RemoteFrameLease = .{};
    check(sys, desk, &lease, &peer, &result) catch |err| {
        result.reason = @errorName(err);
        result.exit_code = if (err == error.Cancelled) 4 else 1;
    };
    if (leave_owned and result.exit_code == 0) {
        // This exact success path intentionally borrows the demand and first
        // snapshot until the real process exits. No synthetic release/Exit.
        result.held_until_exit = true;
        return result;
    }
    if (peer.id != 0 and desk.remoteFrameSnapshotRelease(&peer) != 0) result.cleanup_ok = false;
    if (lease.id != 0 and desk.remoteFrameSnapshotRelease(&lease) != 0) result.cleanup_ok = false;
    if (desk.remoteFrameRelease() < 0) result.cleanup_ok = false;
    if (!result.cleanup_ok) {
        result.exit_code = 1;
        result.reason = "release-unacknowledged";
    }
    return result;
}

fn check(sys: *const r.r4sys.Context, desk: *const r.r4desk.Context, lease: *a.RemoteFrameLease, peer: *a.RemoteFrameLease, result: *Result) !void {
    const start = sys.ticks();
    const budget = sys.ticksFromMilliseconds(5000);
    var info: a.RemoteFrameInfo = .{};
    var peer_info: a.RemoteFrameInfo = .{};
    while (true) {
        if (sys.programShouldClose()) return error.Cancelled;
        if (sys.ticks() -% start >= budget) return error.SnapshotTimeout;
        if (desk.remoteFrameSnapshotAcquire(0, &info, lease) == 0) {
            // The publisher may advance between the two calls. Retry the
            // whole pair under the same deadline; never skip the oracle.
            if (desk.remoteFrameSnapshotAcquire(info.revision, &peer_info, peer) == 0) break;
            if (desk.remoteFrameSnapshotRelease(lease) != 0) return error.PairRelease;
            lease.* = .{};
        }
        sys.sleepTicks(1);
    }
    if (lease.id == 0 or lease.pixels_addr == 0 or lease.pixels_addr % @alignOf(u32) != 0 or lease.capacity_pixels < info.frame_pixels)
        return error.SnapshotLease;
    if (info.magic != a.remote_frame_magic or info.version != a.remote_frame_version) return error.FrameIdentity;
    const flags = a.remote_frame_flag_ready | a.remote_frame_flag_dirty_valid | a.remote_frame_flag_cursor_valid;
    if (info.flags & flags != flags) return error.FrameFlags;
    if (info.format != a.remote_frame_format_xrgb32 or info.bytes_per_pixel != 4) return error.FrameFormat;
    const count = @as(u64, info.width) * info.height;
    const bytes = std.math.mul(u64, count, 4) catch return error.FrameGeometry;
    if (info.width == 0 or info.height == 0 or info.stride_pixels != info.width or
        count != info.frame_pixels or bytes != info.frame_bytes or bytes > 64 * 1024 * 1024) return error.FrameGeometry;
    if (info.dirty_w == 0 or info.dirty_h == 0 or info.dirty_x < 0 or info.dirty_y < 0 or
        @as(u64, @intCast(info.dirty_x)) + info.dirty_w > info.width or
        @as(u64, @intCast(info.dirty_y)) + info.dirty_h > info.height) return error.DirtyBounds;
    const pixels: [*]const u32 = @ptrFromInt(lease.pixels_addr);
    const chunk: usize = @intCast(@min(64, count));
    const tail: usize = @intCast(count - chunk);
    const head_sum = checksum(pixels[0..chunk]);
    const tail_sum = checksum(pixels[tail..][0..chunk]);
    const same = peer.id != 0 and peer.id != lease.id and peer.pixels_addr == lease.pixels_addr and
        peer.epoch == lease.epoch and peer_info.revision == info.revision;
    const stale = peer.*;
    if (desk.remoteFrameSnapshotRelease(peer) != 0) return error.PeerRelease;
    peer.* = .{};
    if (!same or desk.remoteFrameSnapshotRelease(&stale) >= 0) return error.SnapshotSharing;
    if (sys.programShouldClose()) return error.Cancelled;
    var waited: a.RemoteFrameInfo = .{};
    const wait_result = desk.remoteFrameWait(info.revision, 1, &waited);
    if (wait_result < 0) return error.FrameWait;
    if (checksum(pixels[0..chunk]) != head_sum or checksum(pixels[tail..][0..chunk]) != tail_sum) return error.LeasedPixelsChanged;
    var stats: a.RemoteFrameCaptureStats = .{};
    if (desk.remoteFrameCaptureStats(&stats) != 0 or stats.leases == 0 or stats.leases > 64 or stats.snapshots > 3 or
        stats.live_bytes > 64 * 1024 * 1024 or stats.snapshot_bytes > 3 * 64 * 1024 * 1024) return error.SnapshotBounds;
    result.* = .{ .exit_code = 0, .reason = "snapshot-format-bounds-dirty-wait-immutable-multireader-stale-token",
        .info = info, .stats = stats, .head_pixels = @intCast(chunk), .tail_pixels = @intCast(chunk),
        .head_sum = head_sum, .tail_sum = tail_sum, .wait_result = wait_result };
}

fn checksum(pixels: []const u32) u32 {
    var sum: u32 = 0;
    for (pixels, 0..) |pixel, index| {
        sum +%= pixel ^ @as(u32, @intCast(index));
        sum = std.math.rotl(u32, sum, 5);
    }
    return sum;
}
