//! Explicit diagnostic-only cold cache preparation shared by existing cases.
const r4os = @import("r4os");

pub const PageCacheColdReclaim = struct {
    ok: bool = false,
    passes: u64 = 0,
    fs_frames: u64 = 0,
    failed_drains: u64 = 0,
    entries_before: u64 = 0,
    entries_after: u64 = 0,
};

pub fn toPolicyFloor(dev: *const r4os.r4dev.Context) PageCacheColdReclaim {
    var result = PageCacheColdReclaim{};
    var snapshot = dev.performanceSummary() orelse return result;
    result.entries_before = snapshot.fs_cache_entries_used;
    result.entries_after = result.entries_before;
    const floor: u64 = snapshot.fs_cache_capacity_min_pages;
    const speculation: u64 = snapshot.fs_cache_read_ahead_window_max_pages;
    if (floor == 0 or floor >= snapshot.fs_cache_capacity_max_pages) return result;

    // A reclaim request is capped at 64 frames by R4DEV. Cached kernel
    // stacks are reclaimed before filesystem pages, so allow several bounded
    // passes and use the observed cache residency as the stop condition.
    const max_passes = (snapshot.fs_cache_capacity_max_pages + 63) / 64 + 32;
    while (result.entries_after > floor and result.passes < max_passes) {
        const requested: u32 = @intCast(@min(@as(u64, 64), result.entries_after - floor));
        const probe = dev.memoryReclaimProbe(requested) orelse break;
        result.passes += 1;
        result.fs_frames +%= probe.fs_returned_frames;
        result.failed_drains +%= probe.failed_drains;
        const next = dev.performanceSummary() orelse break;
        const previous_entries = result.entries_after;
        snapshot = next;
        result.entries_after = snapshot.fs_cache_entries_used;
        if (result.entries_after >= previous_entries and probe.returned_frames == 0) break;
    }
    result.ok = result.failed_drains == 0 and result.entries_after <= floor + speculation;
    return result;
}
