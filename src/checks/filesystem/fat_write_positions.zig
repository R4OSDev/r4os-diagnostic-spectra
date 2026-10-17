//! Bounded private FAT overwrite/cursor cases, with independent FAT links.
const std = @import("std");
const r4os = @import("r4os");
const abi = r4os.abi;
const mounts = @import("fixture_mount.zig");
const bytes = 1024 * 1024;
const piece = 8192;

fn seed(buffer: []u8, value: usize) void {
    for (buffer, 0..) |*byte, index| byte.* = @intCast((index * 7 + index / 251 + value) & 255);
}
fn overwrite(sys: *const r4os.r4sys.Context, path: [*:0]const u8, offset: usize, data: []const u8) !i32 {
    var request: u32 = 0;
    if (sys.ioFileWriteAt(path, offset, data, 0, &request) != abi.io_ok or request == 0) return error.Submit;
    var info: abi.ProgramIoInfo = .{};
    if (sys.ioWait(request, abi.io_wait_forever, &info) != abi.io_ok) {
        // The buffer belongs to live work until a real completion receipt.
        sys.println("SPECTRA FILESYSTEM write-positions wait failed; retaining live buffer");
        while (true) sys.sleepTicks(1);
    }
    if (sys.ioClose(request) != abi.io_ok) return error.RequestClose;
    if (info.request_id != request or info.requested_bytes != data.len) return error.CompletionIdentity;
    return info.result;
}
fn patch(sys: *const r4os.r4sys.Context, path: [*:0]const u8, expected: []u8, offset: usize, data: []const u8) !void {
    if (try overwrite(sys, path, offset, data) != data.len) return error.Write;
    @memcpy(expected[offset..][0..data.len], data);
}
fn verify(sys: *const r4os.r4sys.Context, path: [*:0]const u8, expected: []const u8, scratch: []u8) !void {
    const info = sys.fileInfo(path) orelse return error.Info;
    if (info.size != expected.len) return error.Size;
    var offset: usize = 0;
    while (offset < expected.len) {
        const count = @min(scratch.len, expected.len - offset);
        if (sys.fileReadAt(path, @intCast(offset), scratch[0..count]) != count or
            !std.mem.eql(u8, scratch[0..count], expected[offset..][0..count])) return error.Content;
        offset += count;
    }
}
fn fatLink(storage: r4os.storage.Context, volume: abi.StorageVolumeInfo, bpb: *const [512]u8, cluster: u32) !u32 {
    const reserved = std.mem.readInt(u16, bpb[14..16], .little);
    const sectors = std.mem.readInt(u32, bpb[36..40], .little);
    if (bpb[16] != 2 or cluster / 128 >= sectors) return error.Geometry;
    var result: ?u32 = null;
    for (0..2) |mirror| {
        var sector: [512]u8 = undefined;
        const lba = @as(u64, reserved) + mirror * sectors + cluster / 128;
        if (storage.read(&volume.target, lba, &sector) != 0) return error.RawFat;
        const value = std.mem.readInt(u32, sector[(cluster % 128) * 4 ..][0..4], .little) & 0x0fffffff;
        if (result) |old| if (old != value) return error.FatMirror;
        result = value;
    }
    return result orelse error.FatMirror;
}
fn shape(sys: *const r4os.r4sys.Context, volume: abi.StorageVolumeInfo, path: [*:0]const u8, fragmented: bool) !void {
    const storage = r4os.storage.Context{ .sys = sys };
    var bpb: [512]u8 = undefined;
    if (storage.read(&volume.target, 0, &bpb) != 0 or std.mem.readInt(u16, bpb[11..13], .little) != 512 or bpb[13] != 1) return error.FixtureGeometry;
    const info = sys.fileInfo(path) orelse return error.ShapeInfo;
    var cluster = info.first_cluster;
    for (0..piece / 512) |index| {
        const next = try fatLink(storage, volume, &bpb, cluster);
        if (next < 2 or next >= 0x0ffffff0) return error.ShapeChain;
        if (index + 1 < piece / 512 and next != cluster + 1) return error.FirstRun;
        if (index + 1 == piece / 512 and (next != cluster + 1) != fragmented) return error.FragmentShape;
        cluster = next;
    }
}
fn phase(sys: *const r4os.r4sys.Context, dev: *const r4os.r4dev.Context, letter: u8, fragmented: bool) !void {
    var text: [2][64]u8 = undefined;
    const file = try std.fmt.bufPrintZ(&text[0], "{c}:\\TEMP\\FWPOS.BIN", .{letter});
    const blocker = try std.fmt.bufPrintZ(&text[1], "{c}:\\TEMP\\FWPOSB.BIN", .{letter});
    if (sys.exists(file.ptr) or sys.exists(blocker.ptr)) return error.FixtureOccupied;
    defer {
        _ = sys.fileDelete(file.ptr);
        _ = sys.fileDelete(blocker.ptr);
    }
    const allocator = sys.allocator();
    const expected = try allocator.alloc(u8, bytes);
    defer allocator.free(expected);
    const patch_bytes = try allocator.alloc(u8, piece);
    defer allocator.free(patch_bytes);
    const scratch = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(scratch);
    seed(expected, 31);
    @memset(patch_bytes, 0xa5);
    if (fragmented) {
        if (sys.fileWrite(file.ptr, expected[0..piece]) != piece or sys.fileWrite(blocker.ptr, patch_bytes) != piece) return error.Create;
        var offset: usize = piece;
        while (offset < bytes) : (offset += piece) {
            if (sys.fileAppend(file.ptr, expected[offset..][0..piece]) != piece or sys.fileAppend(blocker.ptr, patch_bytes) != piece) return error.FragmentCreate;
        }
    } else {
        if (sys.fileWrite(file.ptr, expected) != bytes) return error.Create;
        @memset(scratch, 0xa5);
        if (sys.fileStreamBegin(blocker.ptr, abi.file_stream_open_replace) != abi.file_stream_result_ok) return error.BlockerBegin;
        var offset: usize = 0;
        while (offset < bytes) : (offset += scratch.len) if (sys.fileStreamWrite(blocker.ptr, offset, scratch, 0) != scratch.len) return error.BlockerWrite;
        if (sys.fileStreamFinish(blocker.ptr, bytes, 0) != abi.file_stream_result_ok) return error.BlockerFinish;
    }
    var volume = mounts.mounted(sys, letter) orelse return error.Mount;
    try shape(sys, volume, file.ptr, fragmented);
    const before = dev.performanceSummary() orelse return error.Metrics;
    for (0..32) |index| {
        @memset(patch_bytes, @as(u8, @intCast(83 + index)));
        try patch(sys, file.ptr, expected, 512 * 1024 + index * piece + 127, patch_bytes);
    }
    const after = dev.performanceSummary() orelse return error.Metrics;
    const walks = after.fat32_cluster_walk_steps -| before.fat32_cluster_walk_steps;
    const hits = after.fat32_read_extent_cache_hits -| before.fat32_read_extent_cache_hits;
    if (walks == 0 or walks >= 4096 or hits < 31) return error.RepeatedSeek;
    @memset(patch_bytes, 19);
    const repeat_before = dev.performanceSummary() orelse return error.Metrics;
    try patch(sys, file.ptr, expected, 512 * 1024 + 127, patch_bytes);
    const repeat_after = dev.performanceSummary() orelse return error.Metrics;
    if (repeat_after.fat32_cluster_walk_steps -| repeat_before.fat32_cluster_walk_steps >= 64) return error.RepeatSeek;
    for ([_]usize{ 900123, 65537, 45001, 980123, 511, 700000 }) |offset| try patch(sys, file.ptr, expected, offset, patch_bytes);
    const rejected_before = dev.performanceSummary() orelse return error.Metrics;
    if (try overwrite(sys, file.ptr, bytes - 1, patch_bytes[0..2]) >= 0) return error.BoundsAccepted;
    const rejected_after = dev.performanceSummary() orelse return error.Metrics;
    if (rejected_before.fat32_read_extent_cache_stores != rejected_after.fat32_read_extent_cache_stores) return error.RejectedCursor;
    try verify(sys, file.ptr, expected, scratch);
    // Full readback has learned a wider first extent. A tiny overwrite at
    // its exact start must not reduce that mapping to a single point.
    try patch(sys, file.ptr, expected, 3, patch_bytes[0..31]);
    const coverage_before = dev.performanceSummary() orelse return error.Metrics;
    if (sys.fileReadAt(file.ptr, 512, scratch[0..31]) != 31 or !std.mem.eql(u8, scratch[0..31], expected[512..543])) return error.CoverageData;
    const coverage_after = dev.performanceSummary() orelse return error.Metrics;
    if (coverage_after.fat32_cluster_walk_steps != coverage_before.fat32_cluster_walk_steps) return error.CoverageLost;
    // Free/grow/replacement may reuse the old first cluster and size. The old
    // chain mappings must still be invalidated by their original owners.
    if (sys.fileWrite(file.ptr, expected[0..piece]) != piece) return error.Truncate;
    try patch(sys, file.ptr, expected[0..piece], 7, patch_bytes[0..513]);
    try verify(sys, file.ptr, expected[0..piece], scratch);
    seed(expected, 197);
    if (sys.fileWrite(file.ptr, expected) != bytes) return error.Replacement;
    try patch(sys, file.ptr, expected, 900123, patch_bytes);
    try verify(sys, file.ptr, expected, scratch);
    // Exact unmount/rebind clears residency and extent mappings; final bytes
    // are read back through the new mounted generation, not the old cursor.
    const storage = r4os.storage.Context{ .sys = sys };
    if (storage.unmount(&volume.reference) != 0) return error.Unmount;
    const target = try mounts.refreshedTarget(sys, volume.target);
    var fresh: abi.StorageVolumeRef = .{};
    if (storage.mount(&target, letter, &fresh) != 0 or storage.unmount(&volume.reference) != abi.storage_error_stale) return error.Remount;
    volume = mounts.mounted(sys, letter) orelse return error.Mount;
    if (!std.meta.eql(volume.reference, fresh)) return error.MountIdentity;
    try verify(sys, file.ptr, expected, scratch);
    const info = sys.fileInfo(blocker.ptr) orelse return error.BlockerInfo;
    if (info.size != bytes) return error.BlockerSize;
    var offset: usize = 0;
    while (offset < bytes) : (offset += scratch.len) {
        if (sys.fileReadAt(blocker.ptr, @intCast(offset), scratch) != scratch.len) return error.BlockerRead;
        for (scratch) |byte| if (byte != 0xa5) return error.BlockerContent;
    }
    sys.write("SPECTRA FILESYSTEM write-positions ");
    sys.write(if (fragmented) "fragmented" else "contiguous");
    sys.write(": OK writes=32 walk=");
    sys.printU64(walks);
    sys.write(" hits=");
    sys.printU64(hits);
    sys.println(" repeat/reverse/random=yes coverage=yes truncation/replacement=yes mirrors=yes remount=yes bytes=yes requests=closed");
}
pub fn run(sys: *const r4os.r4sys.Context, dev: *const r4os.r4dev.Context) bool {
    var selected: u8 = 0;
    for ('D'..'Z' + 1) |value| {
        const letter: u8 = @intCast(value);
        const volume = mounts.mounted(sys, letter) orelse continue;
        if (volume.filesystem != abi.storage_filesystem_fat32) continue;
        var text: [64]u8 = undefined;
        const path = std.fmt.bufPrintZ(&text, "{c}:\\TEMP\\FATTEST.R4S", .{letter}) catch return false;
        var marker: [64]u8 = undefined;
        const expected = "R4OS_FAT_FIXTURE=PRIVATE_TEST\n";
        if (sys.fileRead(path.ptr, &marker) != expected.len or !std.mem.eql(u8, marker[0..expected.len], expected)) continue;
        if (selected != 0) return false;
        selected = letter;
    }
    if (selected == 0) {
        sys.println("SPECTRA FILESYSTEM write-positions: FAILED missing private FAT fixture");
        return false;
    }
    for ([_]bool{ false, true }) |fragmented| phase(sys, dev, selected, fragmented) catch |err| {
        sys.write("SPECTRA FILESYSTEM write-positions: FAILED reason=");
        sys.println(@errorName(err));
        return false;
    };
    return true;
}
