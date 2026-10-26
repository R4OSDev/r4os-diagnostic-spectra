//! Explicit owned-fixture checks; processing has cooperative checkpoints.
//! Counter overlap is software evidence, not physical parallel-I/O latency.
const r = @import("r4os");
const fixture = @import("page_cache_budget.zig");
const mut_path = "C:\\TEMP\\PGMUT47.BIN";

fn process(sys: *const r.r4sys.Context, page: []const u8, seed: u64) u64 {
    var digest = seed;
    for (0..512) |round| {
        for (page) |byte| digest = (digest *% 0x100000001b3) ^ (byte +% @as(u64, round));
        if (round % 8 == 0) sys.sleepTicks(0);
    }
    return digest;
}
fn snapshot(dev: *const r.r4dev.Context) !r.abi.ProgramPerformanceSummary {
    return dev.performanceSummary() orelse error.CacheSummary;
}
pub fn run(sys: *const r.r4sys.Context, dev: *const r.r4dev.Context, comptime reclaim: anytype) !void {
    const allocator = sys.allocator();
    const page = try allocator.alloc(u8, 4096);
    defer allocator.free(page);
    if (!fixture.read(sys, 0, page)) return error.PrivatePatternedFixture;
    if (!reclaim(dev).ok) return error.ColdPreparation;
    const before = try snapshot(dev);
    var digest: u64 = 0;
    var processing_completions: u64 = 0;
    for (0..32) |index| {
        if (!fixture.read(sys, index * 4096, page)) return error.SequentialBytes;
        const loaded = try snapshot(dev);
        digest = process(sys, page, digest);
        const processed = try snapshot(dev);
        if (processed.fs_cache_read_ahead_pages_issued > loaded.fs_cache_read_ahead_pages_issued) processing_completions += 1;
    }
    const sequence = try snapshot(dev);
    const hits = sequence.fs_cache_read_ahead_hits -| before.fs_cache_read_ahead_hits;
    const issued = sequence.fs_cache_read_ahead_pages_issued -| before.fs_cache_read_ahead_pages_issued;
    if (hits == 0 or issued == 0 or processing_completions == 0 or sequence.fs_cache_read_ahead_window_max_pages > 4) {
        sys.write("SPECTRA FILESYSTEM readahead sequence: hits=");
        sys.printU64(hits);
        sys.write(" issued=");
        sys.printU64(issued);
        sys.write(" processing=");
        sys.printU64(processing_completions);
        sys.println("");
        return error.NoReadAheadOverlap;
    }
    if (!reclaim(dev).ok) return error.RandomColdPreparation;
    const random_before = try snapshot(dev);
    for ([_]u32{ 512, 4, 1024, 16, 2048, 32 }) |index| {
        if (!fixture.read(sys, @as(u64, index) * 4096, page)) return error.RandomBytes;
        digest = process(sys, page, digest);
    }
    const random_after = try snapshot(dev);
    if (random_after.fs_cache_read_ahead_pages_scheduled != random_before.fs_cache_read_ahead_pages_scheduled) return error.RandomScheduledIo;
    // Establish exactly one unused future page, then observe its retirement.
    if (!reclaim(dev).ok) return error.ExpiryColdPreparation;
    if (!fixture.read(sys, 4000 * 4096, page)) return error.ExpiryPrime;
    const pending = try snapshot(dev);
    if (!fixture.read(sys, 4001 * 4096, page)) return error.ExpiryPrime;
    var ready = pending;
    for (0..64) |_| {
        digest = process(sys, page, digest);
        ready = try snapshot(dev);
        if (ready.fs_cache_read_ahead_pages_issued > pending.fs_cache_read_ahead_pages_issued) break;
        sys.sleepTicks(1);
    }
    if (ready.fs_cache_read_ahead_pages_issued <= pending.fs_cache_read_ahead_pages_issued) return error.UnusedPageNotCompleted;
    sys.sleepTicks(sys.ticksFromMilliseconds(600));
    const expired = try snapshot(dev);
    if (expired.fs_cache_read_ahead_window_pages != 0 or expired.fs_cache_payload_frames >= ready.fs_cache_payload_frames) return error.UnusedPageNotRetired;
    // Fresh owned mutation fixture; never overwrite the read-only40MB input.
    var info: r.abi.FileInfo = .{};
    if (sys.fileInfoRaw(mut_path, &info) > 0) return error.MutationFixtureExists;
    const content = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(content);
    @memset(content, 0x3c);
    var owned = true;
    defer {
        if (owned) {
            _ = sys.fileDelete(mut_path);
        }
    }
    if (sys.fileWrite(mut_path, content) != content.len) return error.MutationCreate;
    if (sys.fileReadAt(mut_path, 0, page) != page.len or sys.fileReadAt(mut_path, 4096, page) != page.len) return error.MutationPrime;
    digest = process(sys, page, digest);
    @memset(page, 0xa5);
    @memset(content[8192..12288], 0xa5);
    if (sys.fileWrite(mut_path, content) != content.len) return error.MutationWrite;
    @memset(page, 0);
    if (sys.fileReadAt(mut_path, 8192, page) != page.len) return error.MutationRead;
    for (page) |value| if (value != 0xa5) return error.StaleMutationData;
    if (sys.fileDelete(mut_path) < 0 or sys.fileInfoRaw(mut_path, &info) > 0) return error.MutationCleanup;
    owned = false;
    sys.write("SPECTRA FILESYSTEM readahead: OK chunks=32 processing_with_checkpoints=");
    sys.printU64(processing_completions);
    sys.write(" issued_pages=");
    sys.printU64(issued);
    sys.write(" useful_hits=");
    sys.printU64(hits);
    sys.write(" random_scheduled=0 expiry_payload=");
    sys.printU64(ready.fs_cache_payload_frames);
    sys.write("->");
    sys.printU64(expired.fs_cache_payload_frames);
    sys.write(" mutation=fresh digest=");
    sys.printU64(digest);
    sys.println(" physical_parallelism=unqualified");
}
