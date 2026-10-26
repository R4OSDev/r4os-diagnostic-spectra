//! Explicit cold NTFS metadata owner check. An unchanged real queue request
//! across the peer call is the overlap witness, not just caller in_flight flags.
const r = @import("r4os");
const std = @import("std");
const mounts = @import("fixture_mount.zig");
const abi = r.abi;
const Work = struct {
    sys: *const r.r4sys.Context,
    done: u32 = 0,
    started: u32 = 0,
    info: ?abi.DriveInfo = null,
};
fn freeWorker(raw: u64) callconv(.c) i32 {
    const w: *Work = @ptrFromInt(raw);
    @atomicStore(u32, &w.started, 1, .release);
    w.info = w.sys.driveInfo(3);
    @atomicStore(u32, &w.done, 1, .release);
    return if (w.info != null) 0 else 1;
}
const WriteWork = struct { sys: *const r.r4sys.Context, path: [*:0]const u8, bytes: []const u8, started: u32 = 0, result: i32 = -1 };
fn writeWorker(raw: u64) callconv(.c) i32 {
    const w: *WriteWork = @ptrFromInt(raw);
    @atomicStore(u32, &w.started, 1, .release);
    w.result = w.sys.fileWrite(w.path, w.bytes);
    return if (w.result == w.bytes.len) 0 else 1;
}
fn join(sys: *const r.r4sys.Context, handle: *abi.ProgramJoinHandle) i32 {
    var code: i32 = -1;
    if (sys.threadHandleJoin(handle, abi.thread_wait_forever, &code) != abi.thread_ok) {
        sys.println("SPECTRA FILESYSTEM metadata-io join failed; retaining live owners");
        while (true) sys.sleepTicks(1);
    }
    return code;
}
pub fn run(sys: *const r.r4sys.Context, dev: *const r.r4dev.Context) !void {
    const volume = mounts.mounted(sys, 'D') orelse return error.MetadataMount;
    if (volume.filesystem != abi.storage_filesystem_ntfs) return error.MetadataNtfs;
    const storage = r.storage.Context{ .sys = sys };
    var paths: [13][64]u8 = undefined;
    var names: [13][*:0]const u8 = undefined;
    for (&paths, 0..) |*buffer, i| names[i] = (try std.fmt.bufPrintZ(buffer, "D:\\TEMP\\M048{d:0>2}.BIN", .{i})).ptr;
    for (names) |name| if (sys.exists(name)) return error.MetadataFixtureExists;
    var created: usize = 0;
    defer for (names[0..created]) |name| {
        _ = sys.fileDelete(name);
    };
    const tiny = "metadata48-owned";
    for (names[0..12]) |name| {
        created += 1;
        if (sys.fileWrite(name, tiny) != tiny.len) return error.MetadataFixtureCreate;
    }
    // Warm raw records but evict the first decoded entry from the8-record/
    // 8-path caches. Its peer lookup may use the ordinary shared scratch.
    var expected: abi.FileInfo = .{};
    for (names[0..12], 0..) |name, i| {
        var info: abi.FileInfo = .{};
        if (sys.fileInfoRaw(name, &info) <= 0 or info.size != tiny.len) return error.MetadataWarm;
        if (i == 0) expected = info;
    }
    sys.sleepTicks(sys.ticksFromMilliseconds(600));
    var lease: u64 = 0;
    if (storage.useBegin(names[0], &lease) != 0) return error.MetadataLease;
    defer if (lease != 0) {
        _ = storage.useEnd(&lease);
    };
    const allocator = sys.allocator();
    const writer_bytes = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(writer_bytes);
    @memset(writer_bytes, 0x6d);
    var work = Work{ .sys = sys };
    var handle: abi.ProgramJoinHandle = .{};
    if (sys.threadCreateHandle(freeWorker, @intFromPtr(&work), 0, 0, &handle) != abi.thread_ok) return error.MetadataThread;
    var joined = false;
    defer if (!joined) {
        _ = join(sys, &handle);
    };
    var overlap = false;
    var tracked_free = false;
    var request_id: u64 = 0;
    var peer_bytes: u64 = 0;
    var observations: u64 = 0;
    const deadline = sys.ticks() + sys.ticksFromMilliseconds(10000);
    while (@atomicLoad(u32, &work.done, .acquire) == 0 and sys.ticks() < deadline) {
        observations += 1;
        const a = dev.performanceStorage(volume.target.device.slot) orelse return error.MetadataStorage;
        const fs = dev.performanceSummary() orelse return error.MetadataSummary;
        if (@atomicLoad(u32, &work.started, .acquire) != 0 and fs.fs_active_requests > 0 and fs.fs_active_kind == 1) tracked_free = true;
        if (tracked_free and a.active_request_id != 0 and a.active_request_kind == 1 and fs.fs_active_requests > 0) {
            var info: abi.FileInfo = .{};
            const result = sys.fileInfoRaw(names[0], &info);
            const b = dev.performanceStorage(volume.target.device.slot) orelse return error.MetadataStorage;
            const after = dev.performanceSummary() orelse return error.MetadataSummary;
            if (result <= 0 or info.size != expected.size or info.first_cluster != expected.first_cluster) return error.MetadataPeerIdentity;
            if (a.active_request_id == b.active_request_id and b.active_request_kind == 1 and @atomicLoad(u32, &work.done, .acquire) == 0 and after.fs_active_requests > 0) {
                overlap = true;
                request_id = a.active_request_id;
                peer_bytes = info.size;
                break;
            }
        }
        sys.sleepTicks(0);
    }
    const busy = storage.unmount(&volume.reference) == abi.storage_error_busy;
    var writer = WriteWork{ .sys = sys, .path = names[12], .bytes = writer_bytes };
    var writer_handle: abi.ProgramJoinHandle = .{};
    const wrote_thread = sys.threadCreateHandle(writeWorker, @intFromPtr(&writer), 0, 0, &writer_handle) == abi.thread_ok;
    // All buffers, work and paths remain live through exact native joins.
    const free_code = join(sys, &handle);
    joined = true;
    const writer_code = if (wrote_thread) join(sys, &writer_handle) else -1;
    if (!wrote_thread) return error.MetadataWriterThread;
    created = 13;
    if (free_code != 0 or writer_code != 0) return error.MetadataWorker;
    const free = work.info orelse return error.MetadataFree;
    const after = sys.driveInfo(3) orelse return error.MetadataFreeAfter;
    if (free.reserved & abi.drive_info_flag_free_valid == 0 or after.reserved & abi.drive_info_flag_free_valid == 0 or
        after.free_clusters >= free.free_clusters or writer.result != writer_bytes.len) return error.MetadataMutationCount;
    const readback = try allocator.alloc(u8, writer_bytes.len);
    defer allocator.free(readback);
    if (sys.fileRead(names[12], readback) != readback.len or !std.mem.allEqual(u8, readback, 0x6d)) return error.MetadataWriterData;
    if (!busy) return error.MetadataUnmount;
    sys.write("SPECTRA FILESYSTEM metadata-io ");
    sys.write(if (overlap) "overlap=YES" else "overlap=NO");
    sys.write(" same_active_request=");
    sys.printU64(request_id);
    sys.write(" peer_bytes=");
    sys.printU64(peer_bytes);
    sys.write(" observations=");
    sys.printU64(observations);
    sys.write(" free=");
    sys.printU64(free.free_clusters);
    sys.write("->");
    sys.printU64(after.free_clusters);
    sys.println(" writer_data=yes unmount_busy=explicit-lease joins=actual hardware_parallelism=unqualified");
    if (!overlap) return error.MetadataNoOverlap;
}
