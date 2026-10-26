//! Explicit private-fixture work: real data growth/reuse/stream/reclaim, no
//! synthetic pressure override or physical latency/throughput assertion.
const r = @import("r4os");
const std = @import("std");
const path = "C:\\TEMP\\PGCACHE46.BIN";
const bytes = 40 * 1024 * 1024;
const hot_pages = 640;
const hot_bytes = hot_pages * 4096;
const magic = "R4OS_PGCACHE_46\n";

fn check(data: []const u8, offset: u64) bool {
    for (data, 0..) |value, index| {
        const absolute = offset + index;
        const expected: u8 = if (absolute < magic.len) magic[@intCast(absolute)] else @truncate((absolute % 4096) * 13 + (absolute / 4096) * 7);
        if (value != expected) return false;
    }
    return true;
}
pub fn read(sys: *const r.r4sys.Context, offset: u64, data: []u8) bool {
    const position = std.math.cast(u32, offset) orelse return false;
    return sys.fileReadAt(path, position, data) == data.len and check(data, offset);
}
fn delta(after: u64, before: u64) u64 {
    return after -| before;
}

pub fn run(sys: *const r.r4sys.Context, dev: *const r.r4dev.Context, comptime reclaim: anytype) !void {
    var info: r.abi.FileInfo = .{};
    if (sys.fileInfoRaw(path, &info) <= 0 or info.is_dir != 0 or info.size != bytes) return error.PrivateCacheFixture;
    const allocator = sys.allocator();
    const page = try allocator.alloc(u8, 4096);
    defer allocator.free(page);
    const stream = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(stream);
    if (!read(sys, 0, page)) return error.CacheFixtureHeader;
    const cold = reclaim(dev);
    if (!cold.ok) return error.CacheColdReclaim;
    for (0..hot_pages) |index| if (!read(sys, index * 4096, page)) return error.CachePrimeBytes;
    const prime = dev.performanceSummary() orelse return error.CachePrimeSummary;
    if (prime.fs_cache_capacity_max_pages != 8192 or prime.fs_cache_capacity_ram_limit_pages <= 512 or
        prime.fs_cache_entries_used <= 512 or prime.fs_cache_payload_frames <= 512 or prime.fs_cache_payload_bytes <= 2 * 1024 * 1024) return error.CacheDidNotGrow;
    var offset: u64 = hot_bytes;
    while (offset < bytes) : (offset += stream.len) if (!read(sys, offset, stream)) return error.CacheStreamBytes;
    const streamed = dev.performanceSummary() orelse return error.CacheStreamSummary;
    const evictions = delta(streamed.fs_cache_evictions, prime.fs_cache_evictions);
    if (evictions == 0) return error.CacheStreamDidNotEvict;
    for (0..hot_pages) |index| if (!read(sys, index * 4096, page)) return error.CacheReuseBytes;
    const reused = dev.performanceSummary() orelse return error.CacheReuseSummary;
    const misses = delta(reused.fs_cache_misses, streamed.fs_cache_misses);
    const hits = delta(reused.fs_cache_hits, streamed.fs_cache_hits);
    if (misses != 0 or hits < hot_pages * 8) {
        sys.write("SPECTRA FILESYSTEM cache-budget reuse: misses=");
        sys.printU64(misses);
        sys.write(" hits=");
        sys.printU64(hits);
        sys.println("");
        return error.CacheHotReuseLost;
    }
    const drained = reclaim(dev);
    if (!drained.ok or drained.fs_frames <= 512 or drained.entries_after > reused.fs_cache_capacity_min_pages) return error.CacheLargeReclaim;
    sys.write("SPECTRA FILESYSTEM cache-budget: OK hot_pages=");
    sys.printU64(hot_pages);
    sys.write(" prime_entries=");
    sys.printU64(prime.fs_cache_entries_used);
    sys.write(" prime_payload_bytes=");
    sys.printU64(prime.fs_cache_payload_bytes);
    sys.write(" ram_limit=");
    sys.printU64(prime.fs_cache_capacity_ram_limit_pages);
    sys.write(" stream_bytes=");
    sys.printU64(bytes - hot_bytes);
    sys.write(" evictions=");
    sys.printU64(evictions);
    sys.write(" hot_hits=");
    sys.printU64(hits);
    sys.write(" hot_misses=");
    sys.printU64(misses);
    sys.write(" reclaimed=");
    sys.printU64(drained.fs_frames);
    sys.write(" remain=");
    sys.printU64(drained.entries_after);
    sys.println("");
}
