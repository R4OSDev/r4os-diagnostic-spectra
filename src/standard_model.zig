//! Fixed work and scoring contract, independent of guest APIs/presentation.
const std = @import("std");
pub const suite_version = "spectra-standard-3";
pub const metric_version = "2";
pub const cpu_policy = "all-available-v1";
pub const scoring_version = "spectra-geomean-1";
pub const cache_state = "parallel-active-per-area-1s-3batches-v3";
pub const warmup_min_ns: u64 = 1_000_000_000;
pub const warmup_min_batches: u64 = 3;
pub const warmup_runs = 1;
pub const repetitions = 5;
pub const area_ids = [_][]const u8{ "scheduler_sync", "memory", "ipc", "lifecycle", "filesystem_io" };
pub const operation_counts = [_]u64{ 16384, 512, 16384, 32, 8 };
pub const byte_counts = [_]u64{ 0, 512 * 128 * 1024, 16384 * 24, 0, 8 * 64 * 1024 * 2 };
pub const workload_ids = [_][]const u8{ "allcpu-notification-ready-roundtrip-16384-v3", "allcpu-demand-vm-512x128k-v3", "allcpu-kernel-dns-status-16384-v3", "allcpu-owned-fixture-32-v3", "allcpu-ntfs-stream-8x64k-v3" };
pub fn batchOperations(area: usize, cpus: u32) u64 {
    return operation_counts[area] * cpus;
}
pub fn processedBytes(area: usize, cpus: u32) u64 {
    return byte_counts[area] * cpus;
}
pub const metric_id = "elapsed_ns_per_operation";
// Work grows with available CPUs. These are failure bounds, never speed gates.
// Warmup needs at least three whole batches; give it three batch budgets.
pub fn timeoutScale(cpus: u32) u64 {
    return @max(1, (@as(u64, cpus) + 3) / 4);
}
pub const batch_timeout_ns: u64 = 30_000_000_000;
pub const suite_timeout_ns: u64 = 300_000_000_000;
pub const launcher_timeout_ns: u64 = 360_000_000_000;
pub const Sample = struct {
    workers: u32 = 0,
    completed_workers: u32 = 0,
    elapsed_ns: u64 = 0,
    operations: u64 = 0,
    bytes: u64 = 0,
    clock_source: u32 = 0,
    clock_generation: u32 = 0,
    clock_resolution_ns: u64 = 0,
    observer_overhead_ns: ?u64 = null,
    reason: ?[]const u8 = "not-run",
};
pub const Metric = struct {
    count: u32 = 0,
    median_ns: u64 = 0,
    minimum_ns: u64 = 0,
    maximum_ns: u64 = 0,
    mad_ns: u64 = 0,
    reason: ?[]const u8 = "not-run",
};
pub fn aggregate(samples: *const [repetitions + warmup_runs]Sample, operations: u64) Metric {
    var values: [repetitions]u64 = undefined;
    for (samples, 0..) |sample, i| {
        if (sample.reason) |why| return .{ .reason = why };
        const work_valid = if (i == 0)
            sample.operations >= operations * warmup_min_batches and sample.operations % operations == 0 and sample.elapsed_ns >= warmup_min_ns
        else
            sample.operations == operations;
        if (!work_valid or sample.elapsed_ns == 0 or sample.clock_resolution_ns == 0 or
            @as(u128, sample.elapsed_ns) < @as(u128, sample.clock_resolution_ns) * 10)
            return .{ .reason = "insufficient-completed-work-or-clock-resolution" };
        if (i != 0) values[i - 1] = sample.elapsed_ns;
    }
    std.mem.sort(u64, &values, {}, std.sort.asc(u64));
    const median = values[repetitions / 2];
    var deviations: [repetitions]u64 = undefined;
    for (values, 0..) |value, i| deviations[i] = if (value >= median) value - median else median - value;
    std.mem.sort(u64, &deviations, {}, std.sort.asc(u64));
    return .{ .count = repetitions, .median_ns = median, .minimum_ns = values[0], .maximum_ns = values[repetitions - 1], .mad_ns = deviations[repetitions / 2], .reason = null };
}
pub fn score(reference: f64, current: f64) ?f64 {
    if (!std.math.isFinite(reference) or !std.math.isFinite(current) or reference <= 0 or current <= 0) return null;
    const result = 100 * reference / current;
    return if (std.math.isFinite(result) and result > 0) result else null;
}
pub fn overall(areas: [5]?f64) ?f64 {
    var sum: f64 = 0;
    for (areas) |area| {
        const value = area orelse return null;
        if (!std.math.isFinite(value) or value <= 0) return null;
        sum += @log(value / 100);
    }
    const value = 100 * @exp(sum / 5);
    return if (std.math.isFinite(value) and value > 0) value else null;
}
test "reference, relative speed and equal five-area weights" {
    try std.testing.expectApproxEqAbs(@as(f64, 100), score(100, 100).?, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 200), score(100, 50).?, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 50), score(100, 200).?, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 100), overall(.{ 200, 50, 100, 100, 100 }).?, 0.000001);
    try std.testing.expect(overall(.{ 100, 100, null, 100, 100 }) == null);
    try std.testing.expect(score(0, 100) == null);
    try std.testing.expect(score(100, std.math.nan(f64)) == null);
}
test "warmup, failures and unresolved intervals prevent usable metrics" {
    var samples = [_]Sample{.{ .elapsed_ns = 1000, .operations = 8, .clock_resolution_ns = 1, .reason = null }} ** 6;
    samples[0].operations = 8 * warmup_min_batches;
    samples[0].elapsed_ns = warmup_min_ns;
    samples[1].elapsed_ns = 800;
    samples[2].elapsed_ns = 900;
    samples[4].elapsed_ns = 1100;
    samples[5].elapsed_ns = 1200;
    const metric = aggregate(&samples, 8);
    try std.testing.expectEqual(@as(u64, 1000), metric.median_ns);
    try std.testing.expectEqual(@as(u64, 100), metric.mad_ns);
    samples[0].reason = "warmup-failed";
    try std.testing.expect(aggregate(&samples, 8).reason != null);
    samples[0].reason = null;
    samples[0].elapsed_ns = warmup_min_ns - 1;
    try std.testing.expect(aggregate(&samples, 8).reason != null);
    samples[0].elapsed_ns = warmup_min_ns;
    samples[3].clock_resolution_ns = 101;
    try std.testing.expect(aggregate(&samples, 8).reason != null);
}
