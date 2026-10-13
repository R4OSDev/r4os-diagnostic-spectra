//! Explicit, bounded A/B workload for kernel instrumentation. No history sink.
const r4os = @import("r4os");
const std = @import("std");

const repetitions = 5;
const Phase = enum { clock, runtime_yield, vm, thread_stack, metadata_query, lock_query, summary_query, driver_work, console_output };
const phases = std.meta.tags(Phase);
const Sample = struct { elapsed_ns: u64 = 0, operations: u64 = 0, ok: bool = false };
var sink: u64 = 0;

pub fn run(app: *r4os.App, work_context: *anyopaque, work: *const fn (*anyopaque) bool) i32 {
    const sys = app.system();
    const devices = app.devices() orelse return 1;
    const performance = devices.performance();
    const mode = performance.instrumentation() orelse return 1;
    var cpus: r4os.abi.CpuCapacity = .{};
    if (sys.cpuCapacity(&cpus) < 0 or cpus.available_cpus != 4) {
        sys.println("OBSERVER requires four online CPUs");
        return 2;
    }
    if ((mode.clock_flags & r4os.abi.monotonic_clock_flag_valid) == 0) return 1;
    sys.println("OBSERVER begin workload=kernel-instrumentation-v1 repetitions=5 warmups=1");
    var samples: [phases.len][repetitions]Sample = .{.{Sample{}} ** repetitions} ** phases.len;
    var ok = true;
    for (phases, 0..) |phase, phase_index| {
        // A complete untimed warmup also exercises cleanup before recording.
        if (perform(app, phase, work_context, work) == 0) {
            ok = false;
            continue;
        }
        for (&samples[phase_index]) |*sample| {
            const start = sys.monotonicNanoseconds() orelse return 1;
            const operations = perform(app, phase, work_context, work);
            const end = sys.monotonicNanoseconds() orelse return 1;
            sample.* = .{ .elapsed_ns = end -| start, .operations = operations, .ok = operations != 0 and end > start };
            ok = sample.ok and ok;
        }
    }
    // Query and print only after all workload samples. Counters must remain
    // available in base mode while optional fields stay completely untouched.
    var index: u32 = 0;
    while (index < mode.lock_count) : (index += 1) {
        const info = performance.lock(index) orelse return 1;
        ok = info.index == index and info.max_hold_cycles <= info.hold_cycles and ok;
        if (mode.mode == 0) ok = info.hold_cycles == 0 and info.wait_spins == 0 and ok;
    }
    if (performance.lock(mode.lock_count) != null) ok = false;
    index = 0;
    while (index < mode.stack_group_count) : (index += 1) {
        const info = performance.stack(index) orelse return 1;
        if (mode.mode == 0) ok = info.high_water_max_bytes == 0 and info.create_cycles_total == 0 and info.release_cycles_total == 0 and ok;
    }
    if (performance.stack(mode.stack_group_count) != null) ok = false;
    var observer_reads: u64 = 0;
    for (0..32) |irq| {
        const info = performance.irqTiming(@intCast(irq)) orelse return 1;
        observer_reads +|= info.observer_reads;
    }
    if (mode.mode == 0) ok = observer_reads == 0 and ok else ok = observer_reads > 0 and ok;
    const after = performance.instrumentation() orelse return 1;
    ok = mode.clock_source == after.clock_source and mode.clock_generation == after.clock_generation and ok;
    for (phases, 0..) |phase, phase_index| {
        for (samples[phase_index], 0..) |sample, sample_index| {
            sys.write("{\"schema\":\"r4os.instrumentation.ab\",\"schema_version\":1,\"phase\":\"");
            sys.write(@tagName(phase));
            sys.write("\",\"mode\":\"");
            sys.write(if (mode.mode == 1) "detailed" else "base");
            sys.write("\",\"sample\":");
            sys.printU64(sample_index);
            number(&sys, "elapsed_ns", sample.elapsed_ns);
            number(&sys, "operations", sample.operations);
            number(&sys, "clock_source", mode.clock_source);
            number(&sys, "clock_generation", mode.clock_generation);
            number(&sys, "clock_resolution_ns", mode.clock_resolution_ns);
            number(&sys, "irq_observer_reads", observer_reads);
            sys.write(",\"ok\":");
            sys.write(if (sample.ok) "true" else "false");
            sys.println("}");
        }
    }
    sys.println(if (ok) "OBSERVER result: OK" else "OBSERVER result: FAILED");
    return if (ok) 0 else 1;
}

fn number(sys: *const r4os.r4sys.Context, name: []const u8, value: u64) void {
    sys.write(",\"");
    sys.write(name);
    sys.write("\":\"");
    sys.printU64(value);
    sys.write("\"");
}

fn perform(app: *r4os.App, phase: Phase, context: *anyopaque, work: *const fn (*anyopaque) bool) u64 {
    const sys = app.system();
    const resources = app.resources();
    const devices = app.devices() orelse return 0;
    const performance = devices.performance();
    switch (phase) {
        .clock => {
            for (0..5000) |_| sink +%= sys.monotonicNanoseconds() orelse return 0;
            return 5000;
        },
        .runtime_yield => {
            for (0..256) |_| sys.taskYield();
            return 256;
        },
        .vm => {
            for (0..32) |_| {
                var region = switch (resources.reserveVm(16384, 4096, r4os.abi.vm_region_flags_default)) {
                    .region => |value| value,
                    .failure => return 0,
                };
                defer if (region.valid()) {
                    _ = region.release();
                };
                if (region.commit(0, 16384) != r4os.abi.vm_ok) return 0;
                const bytes: [*]volatile u8 = @ptrFromInt(region.last_info.base);
                for (0..4) |page| bytes[page * 4096] = @intCast(page);
                if (bytes[3 * 4096] != 3) return 0;
                if (region.release() != r4os.abi.vm_ok) return 0;
            }
            return 32;
        },
        .thread_stack => {
            for (0..8) |index| {
                var thread = switch (resources.createThread(worker, index, 256 * 1024)) {
                    .handle => |value| value,
                    .failure => return 0,
                };
                switch (thread.join(r4os.time_contract.timeoutFinite(.{ .nanoseconds = 5_000_000_000 }))) {
                    .exited => |code| if (code != @as(i32, @intCast(index))) return 0,
                    else => return 0,
                }
            }
            return 8;
        },
        .metadata_query => {
            for (0..64) |_| sink +%= (performance.instrumentation() orelse return 0).clock_generation;
            return 64;
        },
        .lock_query => {
            for (0..64) |_| sink +%= (performance.lock(0) orelse return 0).acquisitions;
            return 64;
        },
        .summary_query => {
            for (0..16) |_| sink +%= (performance.summary() orelse return 0).task_count;
            return 16;
        },
        .driver_work => return if (work(context)) 8 else 0,
        .console_output => {
            for (0..8) |_| sys.println("OBSERVER output-cost 0123456789 abcdefghijklmnopqrstuvwxyz 0123456");
            return 8;
        },
    }
}

fn worker(arg: u64) callconv(.c) i32 {
    var buffer: [8192]u8 = undefined;
    const bytes: *volatile [8192]u8 = &buffer;
    for (0..buffer.len) |index| bytes[index] = @truncate(index);
    if (bytes[4095] != 255) return -1;
    return @intCast(arg);
}
