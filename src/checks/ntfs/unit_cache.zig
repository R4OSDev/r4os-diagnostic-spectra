//! Bounded disposable Windows-NTFS unit-cache checks, then original initialized
//! oracles. Cold/hot IO-copy counters and data are separate from timing scores.
const std = @import("std");
const r4os = @import("r4os");
const abi = r4os.abi;
const mounts = @import("../filesystem/fixture_mount.zig");
const line = "R4OS NTFS compression test line. ";
const Work = struct { sys: *const r4os.r4sys.Context, path: [*:0]const u8, ready: *u32, ready_event: u64, start_event: u64, index: usize };
fn content(data: []const u8, offset: usize) bool {
    for (data, 0..) |byte, index| if (byte != line[(offset + index) % line.len]) return false;
    return true;
}
fn probe(sys: *const r4os.r4sys.Context, path: [*:0]const u8, offset: u32) bool {
    var output: [96]u8 = .{0xa5} ** 96;
    const count = sys.fileReadAt(path, offset, output[8..73]);
    if (count != 65 or !content(output[8..73], offset)) return false;
    for (output[0..8]) |byte| if (byte != 0xa5) return false;
    for (output[73..]) |byte| if (byte != 0xa5) return false;
    return true;
}
fn worker(raw: u64) callconv(.c) i32 {
    const w: *const Work = @ptrFromInt(raw);
    _ = @atomicRmw(u32, w.ready, .Add, 1, .release);
    _ = w.sys.notificationNotify(w.ready_event, 1);
    if (w.sys.notificationWait(w.start_event, 0, abi.thread_wait_forever) != abi.notification_ok) return 1;
    for (0..32) |index| if (!probe(w.sys, w.path, @intCast((w.index * 197 + index * 991) % 60000))) return 2;
    return 0;
}
fn parallel(sys: *const r4os.r4sys.Context, path: [*:0]const u8) !void {
    var start: u64 = 0;
    var event: u64 = 0;
    if (sys.notificationCreate(&start) != abi.notification_ok) return error.Start;
    if (sys.notificationCreate(&event) != abi.notification_ok) {
        _ = sys.notificationClose(start);
        return error.Ready;
    }
    var ready: u32 = 0;
    var work: [2]Work = undefined;
    var handles: [2]abi.ProgramJoinHandle = undefined;
    var spawned: usize = 0;
    while (spawned < work.len) : (spawned += 1) {
        work[spawned] = .{ .sys = sys, .path = path, .ready = &ready, .ready_event = event, .start_event = start, .index = spawned };
        if (sys.threadCreateHandle(worker, @intFromPtr(&work[spawned]), 0, 0, &handles[spawned]) != abi.thread_ok) break;
    }
    var ok = spawned == work.len;
    while (@atomicLoad(u32, &ready, .acquire) < spawned) {
        var sequence: u64 = 0;
        if (sys.notificationQuery(event, &sequence) != abi.notification_ok) {
            ok = false;
            break;
        }
        if (@atomicLoad(u32, &ready, .acquire) >= spawned) break;
        if (sys.notificationWait(event, sequence, abi.thread_wait_forever) != abi.notification_ok) {
            ok = false;
            break;
        }
    }
    if (sys.notificationNotify(start, 2) != abi.notification_ok) ok = false;
    for (handles[0..spawned]) |*handle| {
        var result: i32 = -1;
        if (sys.threadHandleJoin(handle, abi.thread_wait_forever, &result) != abi.thread_ok) {
            sys.println("SPECTRA NTFS unit-cache join failed; retaining live state");
            while (true) sys.sleepTicks(1);
        }
        if (result != 0) ok = false;
    }
    if (sys.notificationClose(event) != abi.notification_ok) ok = false;
    if (sys.notificationClose(start) != abi.notification_ok) ok = false;
    if (!ok) return error.Parallel;
}
fn fixture(sys: *const r4os.r4sys.Context) ?u8 {
    var selected: u8 = 0;
    for ('D'..'Z' + 1) |value| {
        const letter: u8 = @intCast(value);
        const volume = mounts.mounted(sys, letter) orelse continue;
        if (volume.filesystem != abi.storage_filesystem_ntfs) continue;
        var text: [96]u8 = undefined;
        const marker_path = std.fmt.bufPrintZ(&text, "{c}:\\BASIC\\HELLO.TXT", .{letter}) catch return null;
        var marker: [24]u8 = undefined;
        const marker_text = "R4OS-INIT-0847";
        if (sys.fileRead(marker_path.ptr, &marker) != marker.len or !std.mem.eql(u8, marker[0..marker_text.len], marker_text)) continue;
        for (marker[marker_text.len..]) |byte| if (byte != 0) return null;
        if (selected != 0) return null;
        selected = letter;
    }
    return if (selected == 0) null else selected;
}
fn changes(sys: *const r4os.r4sys.Context, path: [*:0]const u8, backup: [*:0]const u8) !void {
    if (sys.exists(backup)) return error.BackupOccupied;
    const original = sys.fileInfo(path) orelse return error.Original;
    if (sys.base.fileMove(path, backup) <= 0) return error.Rename;
    var moved = true;
    var created = false;
    defer {
        if (created) _ = sys.fileDelete(path);
        if (moved) _ = sys.base.fileMove(backup, path);
    }
    const retained = sys.fileInfo(backup) orelse return error.Renamed;
    if (retained.first_cluster != original.first_cluster or retained.size != original.size or !probe(sys, backup, 17)) return error.RenameData;
    const replacement = "unit-cache replacement with a new file identity";
    if (sys.fileWrite(path, replacement) != replacement.len) return error.Replace;
    created = true;
    var out: [96]u8 = undefined;
    if (sys.fileRead(path, &out) != replacement.len or !std.mem.eql(u8, out[0..replacement.len], replacement)) return error.ReplaceData;
    if (!probe(sys, backup, 31)) return error.OldIdentity;
    if (sys.fileDelete(path) <= 0) return error.DeleteReplacement;
    created = false;
    if (sys.base.fileMove(backup, path) <= 0) return error.Restore;
    moved = false;
    if (!probe(sys, path, 17)) return error.RestoredData;
}
fn check(sys: *const r4os.r4sys.Context, dev: *const r4os.r4dev.Context) !void {
    const letter = fixture(sys) orelse return error.PrivateFixtureRequired;
    var text: [2][96]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&text[0], "{c}:\\COMP\\COMPRESS.TXT", .{letter});
    const backup = try std.fmt.bufPrintZ(&text[1], "{c}:\\COMP\\UCOMP.TXT", .{letter});
    const volume = mounts.mounted(sys, letter) orelse return error.Volume;
    const cold_before = dev.performanceSummary() orelse return error.Metrics;
    if (!probe(sys, path.ptr, 7)) return error.ColdData;
    const warm_before = dev.performanceSummary() orelse return error.Metrics;
    for ([_]u32{ 1, 32, 64, 511, 4090, 65400 }) |offset| if (!probe(sys, path.ptr, offset)) return error.HotData;
    const warm_after = dev.performanceSummary() orelse return error.Metrics;
    const cold_copies = warm_before.fs_cache_read_caller_copy_bytes -| cold_before.fs_cache_read_caller_copy_bytes;
    const hot_copies = warm_after.fs_cache_read_caller_copy_bytes -| warm_before.fs_cache_read_caller_copy_bytes;
    if (cold_copies == 0 or hot_copies != 0) return error.HotInputCopies;
    // Existing explicit pressure path must evict unpinned decoded residency;
    // input read/copy and correct bytes resume on the next small read.
    _ = dev.memoryReclaimProbe(1) orelse return error.Reclaim;
    const reclaimed_before = dev.performanceSummary() orelse return error.Metrics;
    if (!probe(sys, path.ptr, 31)) return error.ReclaimedData;
    const reclaimed_after = dev.performanceSummary() orelse return error.Metrics;
    const reclaimed_copies = reclaimed_after.fs_cache_read_caller_copy_bytes -| reclaimed_before.fs_cache_read_caller_copy_bytes;
    if (reclaimed_copies == 0) return error.ReclaimResidency;
    try parallel(sys, path.ptr);
    try changes(sys, path.ptr, backup.ptr);
    // Real mount teardown/reuse must not retain an earlier slot's decoded unit.
    const storage = r4os.storage.Context{ .sys = sys };
    if (storage.unmount(&volume.reference) != 0) return error.Unmount;
    const target = try mounts.refreshedTarget(sys, volume.target);
    var fresh: abi.StorageVolumeRef = .{};
    if (storage.mount(&target, letter, &fresh) != 0 or storage.unmount(&volume.reference) != abi.storage_error_stale) return error.Remount;
    const current = mounts.mounted(sys, letter) orelse return error.RemountMissing;
    if (!std.meta.eql(fresh, current.reference) or !probe(sys, path.ptr, 31)) return error.RemountData;
    sys.write("SPECTRA NTFS unit-cache: OK coldCopy=");
    sys.printU64(cold_copies);
    sys.write(" hotCopy=");
    sys.printU64(hot_copies);
    sys.write(" reclaimedCopy=");
    sys.printU64(reclaimed_copies);
    sys.println(" parallel=2/64 joins=2 notifications=closed rename/replacement=restored mountGeneration=new bytes/canaries=yes");
}
pub fn run(app: *r4os.App) i32 {
    const sys = app.system();
    const dev = app.devicesLowLevel() orelse return abi.err_no_group;
    const files = app.files() orelse return abi.err_no_fn;
    check(&sys, &dev) catch |err| {
        sys.write("SPECTRA NTFS unit-cache: FAILED reason=");
        sys.println(@errorName(err));
        return 1;
    };
    const result = @import("initialized.zig").run(&sys, &files);
    sys.println(if (result == 0) "SPECTRA NTFS unit-cache result: OK" else "SPECTRA NTFS unit-cache result: FAILED");
    return result;
}
