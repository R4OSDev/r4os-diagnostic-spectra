//! Fixed per-CPU work, shared start gate, active warmup and complete joins.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const cli = @import("cli.zig");
const Output = @import("output.zig").Output;
pub const model = @import("standard_model.zig");
const presentation = @import("standard_output.zig");
const parallel = @import("standard_parallel.zig");
const workloads = @import("standard_workloads.zig");
var sys: r4os.r4sys.Context = undefined;
var net: ?r4os.r4net.Context = null;
var samples: [5][6]model.Sample = undefined;
var metrics: [5]model.Metric = undefined;
var cleanup_failed = false;
var run_deadline: u64 = 0;
var observer_overhead_ns: ?u64 = null;
var cpu_count: u32 = 0;
const Error = error{ Cancelled, Timeout, MissingApi };
fn now() Error!u64 {
    return sys.monotonicNanoseconds() orelse error.MissingApi;
}
fn check(deadline: u64) Error!void {
    if (sys.programShouldClose()) return error.Cancelled;
    if (try now() >= deadline) return error.Timeout;
}
fn ticks(ms: u64) u64 {
    return workloads.ticks(&sys, ms);
}
fn clock() ?a.MonotonicClockInfo {
    return workloads.clock(&sys);
}
fn observerCost() ?u64 {
    var minimum: ?u64 = null;
    for (0..64) |_| {
        const start = clock() orelse return null;
        const end = clock() orelse return null;
        if (end.source != start.source or end.generation != start.generation or end.instant_ns <= start.instant_ns) return null;
        const elapsed = end.instant_ns - start.instant_ns;
        minimum = if (minimum) |old| @min(old, elapsed) else elapsed;
    }
    return minimum;
}
fn takeSample(index: usize, deadline: u64) model.Sample {
    var capacity: a.CpuCapacity = .{};
    if (sys.cpuCapacity(&capacity) != a.thread_ok or capacity.available_cpus != cpu_count) return .{ .workers = cpu_count, .reason = "cpu-capacity-changed" };
    const result = parallel.sample(&sys, net, index, cpu_count, deadline, observer_overhead_ns);
    cleanup_failed = cleanup_failed or result.retained;
    return result.sample;
}
fn activeWarmup(index: usize, deadline: u64) model.Sample {
    var total: model.Sample = .{};
    var batches: u64 = 0;
    while (batches < model.warmup_min_batches or total.elapsed_ns < model.warmup_min_ns) {
        check(deadline) catch |err| {
            total.reason = @errorName(err);
            return total;
        };
        const part = takeSample(index, deadline);
        if (batches == 0) {
            total = part;
        } else {
            const same_clock = part.clock_source == total.clock_source and part.clock_generation == total.clock_generation;
            total.elapsed_ns += part.elapsed_ns;
            total.operations += part.operations;
            total.bytes += part.bytes;
            total.clock_resolution_ns = @max(total.clock_resolution_ns, part.clock_resolution_ns);
            total.completed_workers = part.completed_workers;
            total.reason = if (same_clock) part.reason else "warmup-clock-changed";
        }
        // Failed warmup also retains earlier completed batches and the final
        // partial batch. It never becomes a successful metric or index.
        if (total.reason != null or cleanup_failed) return total;
        if (part.operations != model.batchOperations(index, cpu_count) or part.bytes != model.processedBytes(index, cpu_count)) {
            total.reason = "warmup-work-mismatch";
            return total;
        }
        batches += 1;
    }
    return total;
}
pub fn run(app: *r4os.App, request: *const cli.Request, out: *Output) i32 {
    const config = @import("standard_reference.zig").parseOptions(request.args()) catch {
        out.unavailable("standard", "use /AREA:id, /BASELINE or /REFERENCE:path /COMPAREKEY:key, and /SETTLE:0..5000");
        return 2;
    };
    sys = app.system();
    net = app.networkLowLevel();
    cleanup_failed = false;
    if (out.detail == null) {
        out.unavailable("standard", "instrumentation-mode-unavailable");
        return 1;
    }
    for (&samples) |*area| area.* = .{model.Sample{}} ** 6;
    metrics = .{model.Metric{}} ** 5;
    var capacity: a.CpuCapacity = .{};
    if (sys.cpuCapacity(&capacity) != 0 or capacity.available_cpus == 0) {
        out.unavailable("standard", "schedulable CPU capacity unavailable");
        return 1;
    }
    cpu_count = capacity.available_cpus;
    const reference = @import("standard_reference.zig").load(app, config, out.detail);
    const beginning = clock() orelse {
        out.unavailable("standard", "valid nondegraded clock required");
        return 1;
    };
    run_deadline = beginning.instant_ns +| model.suite_timeout_ns * model.timeoutScale(cpu_count);
    var settle: u32 = config.settle_ms;
    while (settle != 0 and !sys.programShouldClose()) {
        const step: u32 = @min(settle, 100);
        sys.sleepTicks(ticks(step));
        settle -= step;
    }
    var exit_code: i32 = 0;
    observer_overhead_ns = observerCost();
    for (&samples, 0..) |*area, index| {
        if (config.area) |selected| if (index != selected) continue;
        for (area, 0..) |*sample, repetition| {
            if (cleanup_failed) {
                sample.reason = "prior-cleanup-unconfirmed";
                exit_code = 1;
                continue;
            }
            check(run_deadline) catch |err| {
                sample.reason = @errorName(err);
                exit_code = if (err == error.Cancelled) 4 else 1;
                continue;
            };
            const budget = model.batch_timeout_ns * model.timeoutScale(cpu_count) * (if (repetition == 0) model.warmup_min_batches else 1);
            const deadline = @min(run_deadline, (now() catch run_deadline) +| budget);
            sample.* = if (repetition == 0) activeWarmup(index, deadline) else takeSample(index, deadline);
            const batches = sample.operations / model.batchOperations(index, cpu_count);
            const work_valid = if (repetition == 0)
                batches >= model.warmup_min_batches and sample.operations % model.batchOperations(index, cpu_count) == 0 and sample.bytes == model.processedBytes(index, cpu_count) * batches and sample.elapsed_ns >= model.warmup_min_ns
            else
                sample.operations == model.batchOperations(index, cpu_count) and sample.bytes == model.processedBytes(index, cpu_count);
            if (sample.reason != null or !work_valid or cleanup_failed) {
                if (sample.reason == null) sample.reason = "work-count-mismatch";
                exit_code = 1;
            }
            if (sample.reason) |why| if (std.mem.eql(u8, why, "Cancelled")) {
                exit_code = 4;
            };
        }
        metrics[index] = model.aggregate(area, model.batchOperations(index, cpu_count));
        if (metrics[index].reason != null) exit_code = 1;
    }
    if (sys.programShouldClose()) exit_code = 4;
    presentation.render(out, &samples, &metrics, reference, config, exit_code, beginning, cpu_count);
    return exit_code;
}
