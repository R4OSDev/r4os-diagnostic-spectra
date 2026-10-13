const std = @import("std");
const r4os = @import("r4os");
const directory = "\\boot\\FGROW079";
const original = "directory original";
const replacement = "directory replacement";
const filler = "directory neighbor";
const backup = directory ++ "\\BACKUP.R4U";
const final = directory ++ "\\AFTER.BIN";
const long_name = "L" ** 251 ++ ".BIN";
const long_path = directory ++ "\\" ++ long_name;

const Disk = struct {
    storage: r4os.storage.Context,
    volume: r4os.abi.StorageVolumeInfo,
    fat_start: u32,
    fat_sectors: u32,
    fat_count: u8,
    cluster_bytes: usize,

    fn value(self: *const Disk, cluster: u32) !u32 {
        var result: ?u32 = null;
        for (0..self.fat_count) |mirror| {
            var sector: [512]u8 = undefined;
            const lba = @as(u64, self.fat_start) + mirror * self.fat_sectors + cluster / 128;
            if (cluster / 128 >= self.fat_sectors or self.storage.read(&self.volume.target, lba, &sector) != 0) return error.ReadFat;
            const entry = std.mem.readInt(u32, sector[(cluster % 128) * 4 ..][0..4], .little) & 0x0fffffff;
            if (result) |prior| {
                if (prior != entry) return error.Mirrors;
            }
            result = entry;
        }
        return result orelse error.Mirrors;
    }
    fn chain(self: *const Disk, first: u32, expected: usize, out: *[4]u32) !void {
        if (expected == 0 or expected > out.len) return error.Count;
        var cluster = first;
        for (out[0..expected], 0..) |*slot, index| {
            if (cluster < 2 or cluster >= 0x0ffffff0) return error.Cluster;
            for (out[0..index]) |seen| if (seen == cluster) return error.Cycle;
            slot.* = cluster;
            const next = try self.value(cluster);
            if (index + 1 == expected) {
                if (next < 0x0ffffff8) return error.ChainLength;
            } else cluster = next;
        }
    }
};

fn path(out: *[64]u8, prefix: u8, index: usize) ![:0]const u8 {
    return std.fmt.bufPrintZ(out, directory ++ "\\{c}{d:0>7}.BIN", .{ prefix, index });
}
fn matches(ctx: *const r4os.r4sys.Context, name: [*:0]const u8, bytes: []const u8) bool {
    var actual: [64]u8 = undefined;
    const count = ctx.fileRead(name, &actual);
    return count == bytes.len and std.mem.eql(u8, actual[0..bytes.len], bytes);
}

/// Explicit fresh-directory probe on the internal boot FAT; no preexisting
/// fixture is removed or reused. All data operations use the filesystem API.
/// Raw reads only verify the directory chain and every FAT mirror.
pub fn run(ctx: *const r4os.r4sys.Context) !void {
    const storage: r4os.storage.Context = .{ .sys = ctx };
    var inventory: r4os.abi.StorageInventory = .{};
    var volume: r4os.abi.StorageVolumeInfo = .{};
    if (storage.inventory(&inventory) != 0 or storage.volume(inventory.generation, 26, &volume) != 1 or
        volume.letter != 0 or volume.filesystem != r4os.abi.storage_filesystem_fat32) return error.BootVolume;
    var bpb: [512]u8 = undefined;
    if (storage.read(&volume.target, 0, &bpb) != 0 or std.mem.readInt(u16, bpb[11..13], .little) != 512 or
        bpb[13] == 0 or bpb[13] > 16 or !std.math.isPowerOfTwo(bpb[13]) or bpb[16] == 0 or bpb[16] > 2) return error.Geometry;
    const disk: Disk = .{ .storage = storage, .volume = volume, .fat_start = std.mem.readInt(u16, bpb[14..16], .little), .fat_sectors = std.mem.readInt(u32, bpb[36..40], .little), .fat_count = bpb[16], .cluster_bytes = @as(usize, bpb[13]) * 512 };
    var info: r4os.abi.FileInfo = .{};
    if (ctx.fileInfoRaw(directory, &info) != 0) return error.FixtureExistsOrIo;
    if (ctx.dirCreate(directory) < 0 or ctx.fileInfoRaw(directory, &info) != 1 or info.is_dir == 0 or info.first_cluster < 2) return error.CreateDirectory;
    const first = info.first_cluster;
    const slots = disk.cluster_bytes / 32;
    const initial_count = slots - 2;
    var name_buffer: [64]u8 = undefined;
    var chains: [4]u32 = undefined;
    for (0..initial_count) |index| {
        const name = try path(&name_buffer, 'F', index);
        const bytes = if (index == 0) original else if (index == 1) replacement else filler;
        if (ctx.fileWrite(name.ptr, bytes) != bytes.len) return error.FillFirstCluster;
    }
    try disk.chain(first, 1, &chains);
    // Reproduce the real update failure: the directory is exactly full when
    // an atomic replacement needs its additional last-good ownership alias.
    const target = directory ++ "\\F0000000.BIN";
    const stage = directory ++ "\\F0000001.BIN";
    if (ctx.fileReplaceAtomic(target, stage, backup, r4os.r4sys.file_replace_atomic_flag_consume_stage) < 0 or
        !matches(ctx, target, replacement) or !matches(ctx, backup, original) or
        ctx.fileInfoRaw(stage, &info) != 0) return error.AtomicReplace;
    try disk.chain(first, 2, &chains);
    for (0..slots - 2) |index| {
        const name = try path(&name_buffer, 'E', index);
        if (ctx.fileWrite(name.ptr, filler) != filler.len) return error.FillSecondCluster;
    }
    // Two free slots at the tail; a maximum LFN needs another nineteen.
    // A 512-byte cluster therefore exercises two new clusters in one growth.
    if (ctx.fileWrite(long_path, filler) != filler.len or !matches(ctx, long_path, filler)) return error.LongName;
    const cluster_count = 2 + (19 * 32 + disk.cluster_bytes - 1) / disk.cluster_bytes;
    try disk.chain(first, cluster_count, &chains);
    if (ctx.fileAppend(final, "final") != 5 or !matches(ctx, final, "final")) return error.AppendAfterLongName;
    var names: [1024]u8 = undefined;
    var found_long = false;
    var listed: usize = 0;
    for (2..2 * slots + 2) |index| {
        @memset(&names, 0xff);
        const kind = ctx.dirEntry(directory, @intCast(index), &names);
        if (kind == r4os.r4sys.dir_entry_result_end) break;
        if (kind != 0) return error.Enumeration;
        const length = std.mem.indexOfScalar(u8, &names, 0) orelse return error.NameLength;
        if (std.mem.endsWith(u8, names[0..length], long_name)) found_long = true;
        listed += 1;
    }
    if (!found_long or listed != 2 * slots - 2) return error.EnumerationCount;
    for (0..initial_count) |index| {
        if (index == 1) continue;
        const name = try path(&name_buffer, 'F', index);
        if (!matches(ctx, name.ptr, if (index == 0) replacement else filler)) return error.NeighborChanged;
    }
    for (0..slots - 2) |index| {
        const name = try path(&name_buffer, 'E', index);
        if (!matches(ctx, name.ptr, filler)) return error.NeighborChanged;
    }
    // Cleanup only after every content and chain check succeeds.
    for (0..initial_count) |index| {
        if (index == 1) continue;
        const name = try path(&name_buffer, 'F', index);
        if (ctx.fileDelete(name.ptr) < 0) return error.CleanupFile;
    }
    for (0..slots - 2) |index| {
        const name = try path(&name_buffer, 'E', index);
        if (ctx.fileDelete(name.ptr) < 0) return error.CleanupFile;
    }
    for ([_][*:0]const u8{ backup, long_path, final }) |name| if (ctx.fileDelete(name) < 0) return error.CleanupFile;
    if (ctx.dirDelete(directory) < 0 or ctx.fileInfoRaw(directory, &info) != 0) return error.CleanupDirectory;
    for (chains[0..cluster_count]) |cluster| if (try disk.value(cluster) != 0) return error.LeakedDirectoryCluster;
    ctx.write("SPECTRA FILESYSTEM fat-directory: OK cluster-bytes=");
    ctx.printU64(disk.cluster_bytes);
    ctx.write(" clusters=");
    ctx.printU64(cluster_count);
    ctx.write(" files=");
    ctx.printU64(listed);
    ctx.println(" full-replace=OK lfn=255 mirrors=matched neighbors=preserved cleanup=complete");
}
