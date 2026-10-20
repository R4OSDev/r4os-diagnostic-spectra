const std = @import("std");
const r4os = @import("r4os");
const payload = "Unicode filename identity\r\n\x00\xff";
const source_name = "aaaaaaaaaaaa🙂-ä-€-𐐷.txt"; // high surrogate crosses first LFN slot
const target_name = "bbbbbbbbbbbbbbbbbbbbbbbbb🙂-改名.txt"; // crosses second slot

fn same(ctx: *const r4os.r4sys.Context, path: [*:0]const u8) bool {
    var bytes: [64]u8 = undefined;
    return ctx.fileRead(path, &bytes) == payload.len and std.mem.eql(u8, bytes[0..payload.len], payload);
}
fn listed(ctx: *const r4os.r4sys.Context, dir: [*:0]const u8, wanted: []const u8) !void {
    var found: usize = 0;
    var ended = false;
    // Public dirEntry0/1 are qualified directory/parent paths (kind1).
    // Real entries start2 and also return qualified paths, not basenames.
    for (2..14) |index| {
        var bytes: [768]u8 = @splat(0x5a);
        const rc = ctx.dirEntry(dir, @intCast(index), &bytes);
        if (rc == r4os.r4sys.dir_entry_result_end) { ended = true; break; }
        if (rc != 0) return error.Enumeration;
        const end = std.mem.indexOfScalar(u8, &bytes, 0) orelse return error.NameLength;
        const begin = if (std.mem.lastIndexOfScalar(u8, bytes[0..end], '\\')) |separator| separator + 1 else 0;
        const name = bytes[begin..end];
        if (std.mem.eql(u8, name, wanted)) found += 1;
    }
    if (!ended or found != 1) return error.LosslessEnumeration;
}
fn exercise(ctx: *const r4os.r4sys.Context, dev: *const r4os.r4dev.Context, comptime dir: [:0]const u8, ntfs: bool) !void {
    var info: r4os.abi.FileInfo = .{};
    if (ctx.fileInfoRaw(dir.ptr, &info) != 0) return error.FixtureExistsOrIo;
    if (ctx.dirCreate(dir.ptr) < 0) return error.CreateDirectory;
    const source = dir ++ "\\" ++ source_name;
    const target = dir ++ "\\" ++ target_name;
    const ascii = dir ++ "\\a.txt";
    const bad_a = dir ++ "\\\xc1\xa1.txt";
    const bad_slash = dir ++ "\\\xe0\x80\xafghost.txt";
    if (ctx.fileWrite(source, payload) != payload.len or !same(ctx, source)) return error.CreateUnicode;
    try listed(ctx, dir.ptr, source_name);
    const prior = ctx.fileInfo(source) orelse return error.SourceInfo;
    if (ctx.fileRename(source, target) <= 0 or ctx.fileInfoRaw(source, &info) != 0 or !same(ctx, target)) return error.RenameUnicode;
    const after = ctx.fileInfo(target) orelse return error.TargetInfo;
    if (ntfs and (prior.first_cluster != after.first_cluster or prior.created_date != after.created_date or prior.created_time != after.created_time)) return error.NtfsIdentity;
    try listed(ctx, dir.ptr, target_name);
    if (ctx.fileWrite(ascii, payload) != payload.len) return error.AsciiControl;
    // These calls must reject before persistent mutation, even while an ASCII
    // name exists which the former overlong decoder could accidentally select.
    const before_bad = dev.performanceSummary() orelse return error.Metrics;
    var rejected = true;
    for ([_][*:0]const u8{ bad_a, bad_slash, dir ++ "\\\xed\xa0\x80.txt", dir ++ "\\\xf4\x90\x80\x80.txt" }) |bad| {
        rejected = ctx.fileInfoRaw(bad, &info) < 0 and rejected;
        rejected = ctx.fileWrite(bad, "MUTATED") < 0 and rejected;
        rejected = ctx.fileDelete(bad) < 0 and rejected;
        rejected = ctx.fileRename(target, bad) < 0 and rejected;
        rejected = ctx.dirCreate(bad) < 0 and rejected;
    }
    const after_bad = dev.performanceSummary() orelse return error.Metrics;
    if (!rejected or after_bad.storage_write_ops != before_bad.storage_write_ops or
        after_bad.fs_cache_write_through_requests != before_bad.fs_cache_write_through_requests or
        after_bad.fs_cache_deferred_write_requests != before_bad.fs_cache_deferred_write_requests or
        after_bad.fat32_dir_entry_updates != before_bad.fat32_dir_entry_updates or
        !same(ctx, ascii) or !same(ctx, target)) return error.BadNameMutation;
    try listed(ctx, dir.ptr, target_name);
    if (ctx.fileDelete(target) < 0 or ctx.fileDelete(ascii) < 0 or ctx.dirDelete(dir.ptr) < 0 or ctx.fileInfoRaw(dir.ptr, &info) != 0) return error.Cleanup;
    ctx.write("SPECTRA FILESYSTEM names: "); ctx.write(if (ntfs) "NTFS" else "FAT32");
    ctx.println(" OK create/list/open/rename/delete supplementary=yes malformed=20 rejected writes=0");
}

/// Explicit fresh private paths on NTFS and the internal boot FAT only.
/// No foreign raw entry is rewritten and no preexisting fixture is reused.
pub fn run(ctx: *const r4os.r4sys.Context, dev: *const r4os.r4dev.Context) !void {
    const storage: r4os.storage.Context = .{ .sys = ctx };
    var inventory: r4os.abi.StorageInventory = .{};
    var boot: r4os.abi.StorageVolumeInfo = .{};
    if (storage.inventory(&inventory) != 0 or storage.volume(inventory.generation, 26, &boot) != 1 or
        boot.letter != 0 or boot.filesystem != r4os.abi.storage_filesystem_fat32) return error.BootVolume;
    try exercise(ctx, dev, "C:\\TEMP\\UNAME08541", true);
    try exercise(ctx, dev, "\\boot\\UNAME08541", false);
}
