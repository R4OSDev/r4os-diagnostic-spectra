//! Explicit private-directory qualification; no background scan or counters.
const std = @import("std");
const r4os = @import("r4os");
const abi = r4os.abi;
const mounts = @import("fixture_mount.zig");
const long_name = "l" ** 70 ++ "-🙂-ä.txt";
const payload = "scan";
const count_files = 18;

fn step(sys: *const r4os.r4sys.Context, path: [*:0]const u8, cursor: *abi.DirectoryBatchCursor, out: []abi.DirectoryBatchEntry) !i32 {
    for (0..64) |_| {
        const result = sys.directoryBatch(path, cursor, out);
        if (result != 0 or out.len == 0) return result;
        sys.sleepTicks(0);
    }
    return error.ProgressBound;
}
fn validate(sys: *const r4os.r4sys.Context, cursor: *abi.DirectoryBatchCursor) i32 {
    var empty: [0]abi.DirectoryBatchEntry = .{};
    return sys.directoryBatch("Z:\\IGNORED", cursor, &empty);
}
fn identity(full: []const u8) !usize {
    const begin = if (std.mem.lastIndexOfAny(u8, full, "\\/")) |pos| pos + 1 else 0;
    const name = full[begin..];
    if (std.mem.eql(u8, name, long_name)) return count_files - 1;
    var wanted: [16]u8 = undefined;
    for (0..count_files - 1) |index| {
        const text = try std.fmt.bufPrint(&wanted, "F{d:0>2}.TXT", .{index});
        if (std.mem.eql(u8, name, text)) return index;
    }
    return error.ForeignEntry;
}
fn cursorFor(sys: *const r4os.r4sys.Context, path: [*:0]const u8) !abi.DirectoryBatchCursor {
    var cursor: abi.DirectoryBatchCursor = .{};
    var entry: [1]abi.DirectoryBatchEntry = undefined;
    const raw = try step(sys, path, &cursor, &entry);
    if (raw < 0 and raw != -5) return error.Begin;
    return cursor;
}
fn exercise(sys: *const r4os.r4sys.Context, files: r4os.Files, comptime base: [:0]const u8, ntfs: bool) !void {
    var info: abi.FileInfo = .{};
    if (sys.fileInfoRaw(base.ptr, &info) != 0) return error.FixtureOccupied;
    if (sys.dirCreate(base.ptr) < 0) return error.CreateBase;
    var tree: [1024]u8 = @splat(0);
    @memcpy(tree[0..base.len], base);
    var length = base.len;
    for (0..9) |index| {
        tree[length] = '\\';
        tree[length + 1] = 'A' + @as(u8, @intCast(index));
        length += 2;
        tree[length] = 0;
        if (sys.dirCreate(@ptrCast(&tree)) < 0) return error.CreateDeep;
    }
    const deep = tree[0..length :0];
    var path_buffer: [1024]u8 = undefined;
    for (0..count_files - 1) |index| {
        const path = try std.fmt.bufPrintZ(&path_buffer, "{s}\\F{d:0>2}.TXT", .{ deep, index });
        if (sys.fileWrite(path.ptr, payload) != payload.len) return error.CreateFile;
    }
    const long_path = try std.fmt.bufPrintZ(&path_buffer, "{s}\\{s}", .{ deep, long_name });
    if (sys.fileWrite(long_path.ptr, payload) != payload.len) return error.CreateLong;
    var cursor: abi.DirectoryBatchCursor = .{};
    var records: [4]abi.DirectoryBatchEntry = undefined;
    var mask: u32 = 0;
    var batches: u32 = 0;
    var ended = false;
    for (0..64) |_| {
        const raw = try step(sys, if (batches == 0) deep.ptr else "Z:\\IGNORED", &cursor, &records);
        if (raw == -5) {
            ended = true;
            break;
        }
        if (raw < 1 or raw > records.len) return error.Batch;
        batches += 1;
        for (records[0..@intCast(raw)]) |*record| {
            const path = std.mem.sliceTo(&record.path, 0);
            const index = try identity(path);
            const bit = @as(u32, 1) << @as(u5, @intCast(index));
            if (mask & bit != 0) return error.Duplicate;
            mask |= bit;
            if (record.info.exists != 1 or record.info.is_dir != 0 or record.info.size != payload.len or
                sys.fileInfoRaw(@ptrCast(&record.path), &info) != 1 or info.size != record.info.size) return error.Metadata;
        }
    }
    if (!ended or mask != (1 << count_files) - 1 or batches != 5 or validate(sys, &cursor) != 0) return error.Completeness;
    var legacy_mask: u32 = 0;
    for (2..count_files + 3) |index| {
        var old_path: [1024]u8 = undefined;
        const raw = sys.dirEntry(deep.ptr, @intCast(index), &old_path);
        if (raw == -5) {
            if (index != count_files + 2) return error.LegacyCount;
            break;
        }
        if (raw != 0) return error.Legacy;
        const bit = @as(u32, 1) << @as(u5, @intCast(try identity(std.mem.sliceTo(&old_path, 0))));
        if (legacy_mask & bit != 0) return error.LegacyDuplicate;
        legacy_mask |= bit;
    }
    if (legacy_mask != mask) return error.LegacySet;
    // The SDK must not publish a second buffered record after mutation.
    var iterator = files.iterate(.{ .ptr = deep.ptr, .len = @intCast(deep.len) });
    var out: [1024]u8 = undefined;
    if (iterator.next(&out) != .entry or iterator.buffer_count < 2) return error.Iterator;
    const mutation = base ++ "\\A\\B\\C\\D\\E\\F\\G\\H\\I\\MUTATE.TXT";
    if (sys.fileWrite(mutation, payload) != payload.len) return error.Mutate;
    const stale = iterator.next(&out);
    if (stale != .failure or stale.failure != -10 or sys.fileDelete(mutation) < 0) return error.BufferedStale;
    // A publication elsewhere must revalidate the captured path without
    // spuriously discarding an unchanged target/parent pair.
    cursor = try cursorFor(sys, deep.ptr);
    const outside = base ++ "\\OUTSIDE.TXT";
    if (sys.fileWrite(outside, payload) != payload.len or validate(sys, &cursor) != 0 or sys.fileDelete(outside) < 0) return error.Unrelated;
    // Moving an ancestor leaves both watched node IDs intact. The global
    // publication must trigger path revalidation and reject the old path.
    cursor = try cursorFor(sys, deep.ptr);
    if (sys.fileRename(base ++ "\\A", base ++ "\\MOVED") <= 0) return error.MoveAncestor;
    const moved = validate(sys, &cursor);
    if (sys.fileRename(base ++ "\\MOVED", base ++ "\\A") <= 0) return error.RestoreAncestor;
    if (moved != -10) return error.AncestorStale;
    const victim = base ++ "\\VICTIM";
    const renamed = base ++ "\\RENAMED";
    if (sys.dirCreate(victim) < 0) return error.CreateVictim;
    cursor = try cursorFor(sys, victim);
    if (sys.fileRename(victim, renamed) <= 0 or validate(sys, &cursor) != -10) return error.RenameStale;
    cursor = try cursorFor(sys, renamed);
    if (sys.dirDelete(renamed) < 0 or sys.dirCreate(renamed) < 0 or validate(sys, &cursor) != -10 or sys.dirDelete(renamed) < 0) return error.ReuseStale;
    for (0..count_files - 1) |index| {
        const path = try std.fmt.bufPrintZ(&path_buffer, "{s}\\F{d:0>2}.TXT", .{ deep, index });
        if (sys.fileDelete(path.ptr) < 0) return error.DeleteFile;
    }
    const long_cleanup = try std.fmt.bufPrintZ(&path_buffer, "{s}\\{s}", .{ deep, long_name });
    if (sys.fileDelete(long_cleanup.ptr) < 0) return error.DeleteLong;
    for (0..9) |_| {
        if (sys.dirDelete(@ptrCast(&tree)) < 0) return error.DeleteDeep;
        length -= 2;
        tree[length] = 0;
    }
    if (sys.dirDelete(base.ptr) < 0) return error.DeleteBase;
    sys.write("SPECTRA FILESYSTEM directory-batch: ");
    sys.write(if (ntfs) "NTFS" else "FAT32");
    sys.println(" OK depth=9 files=18 batches=5 complete-paths=yes long-utf8=yes buffered-stale=rejected ancestor/rename/reuse=rejected unrelated=retained cleanup=complete");
}
const Work = struct {
    sys: r4os.r4sys.Context,
    path: [*:0]const u8,
    cursor: abi.DirectoryBatchCursor = .{},
    result: i32 = -1,
};
fn worker(raw: u64) callconv(.c) i32 {
    const work: *Work = @ptrFromInt(raw);
    var out: [1]abi.DirectoryBatchEntry = undefined;
    work.result = step(&work.sys, work.path, &work.cursor, &out) catch -9;
    return 0;
}
fn remount(sys: *const r4os.r4sys.Context) !void {
    const path = "D:\\TEMP\\DBREM08743";
    var info: abi.FileInfo = .{};
    if (sys.fileInfoRaw(path, &info) != 0 or sys.dirCreate(path) < 0) return error.RemountFixture;
    const volume = mounts.mounted(sys, 'D') orelse return error.MountMissing;
    const storage: r4os.storage.Context = .{ .sys = sys };
    var cursor = try cursorFor(sys, path);
    var work: Work = .{ .sys = sys.*, .path = path };
    var handle: abi.ProgramJoinHandle = .{};
    if (sys.threadCreateHandle(worker, @intFromPtr(&work), 0, 0, &handle) != abi.thread_ok) return error.Worker;
    var code: i32 = 0;
    if (sys.threadHandleJoin(&handle, abi.thread_wait_forever, &code) != abi.thread_ok or code != 0 or work.result != -5) return error.Join;
    if (validate(sys, &work.cursor) != -10) return error.ForeignOwner;
    // Both live inline cursors must own no mounted/kernel scan reference.
    if (storage.unmount(&volume.reference) != 0) return error.Unmount;
    // Unmount advances partition/layout identity. Reuse the existing exact
    // target refresh protocol; the old target must remain explicitly stale.
    const target = try mounts.refreshedTarget(sys, volume.target);
    var rejected: abi.StorageVolumeRef = .{};
    if (storage.mount(&volume.target, 'D', &rejected) != abi.storage_error_stale or rejected.generation != 0) return error.StaleTarget;
    var mounted: abi.StorageVolumeRef = .{};
    if (storage.mount(&target, 'D', &mounted) != 0) return error.Remount;
    if (mounted.generation == volume.reference.generation or validate(sys, &cursor) != -10) return error.MountStale;
    cursor = try cursorFor(sys, path);
    if (validate(sys, &cursor) != 0 or sys.dirDelete(path) < 0) return error.RemountCleanup;
    sys.println("SPECTRA FILESYSTEM directory-batch remount: OK exact-generation=yes foreign-owner=rejected caller-exit/join=yes inline-cursors-held=yes leases=none cleanup=complete");
}
/// /REMOUNT:D explicitly selects the private guest's secondary data volume.
/// C:/boot are never unmounted. No partition/format/raw-write operation occurs.
pub fn run(sys: *const r4os.r4sys.Context, files: r4os.Files, args: []const u8) !void {
    try exercise(sys, files, "C:\\TEMP\\DBATCH08743", true);
    try exercise(sys, files, "\\boot\\DBATCH08743", false);
    if (std.mem.indexOf(u8, args, "/REMOUNT:D") != null) try remount(sys);
}
