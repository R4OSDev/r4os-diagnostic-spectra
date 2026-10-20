//! Passive retained receipts and explicit, sequential, CPU-bound pure work.
//! STANDARD's workloads, reference, timing and scores are independent of PMU.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const d = @import("pmu_decode.zig");
const Output = @import("output.zig").Output;
const Atomic = std.atomic.Value(u32);
const sentinel: u64 = 0x8534_1234_abcd_5678;

fn valid(info: a.CpuPmuInfo, cpu: usize) bool {
    return info.version == 1 and info.size == @sizeOf(a.CpuPmuInfo) and info.cpu_index == cpu and
        info.epoch != 0 and info.flags & ~@as(u32, 255) == 0 and info.event_mask & ~@as(u32, 63) == 0 and
        info.reserved0[0] == 0 and info.reserved0[1] == 0;
}
fn receipt(value: a.CpuPmuResult, out: *Output) bool {
    if (value.version != 1 or value.size != @sizeOf(a.CpuPmuResult) or value.epoch == 0 or
        value.generation == 0 or value.sequence == 0 or value.sequence & 1 != 0 or value.event_id > 5 or
        value.flags & ~@as(u32, 16383) != 0 or value.reserved0 != 0) return false;
    for (value.reserved1) |v| if (v != 0) return false;
    const decoded = d.decode(.{
        .profile = value.profile,
        .status = value.status,
        .flags = value.flags,
        .width = value.counter_width,
        .before = value.raw_before,
        .after = value.raw_after,
        .delta = value.delta_modulo,
        .callback_result = value.callback_result,
        .original_if = value.original_if,
        .final_if = value.final_if,
    });
    out.record("cpu_pmu_raw", "pmu", value.cpu_index, value);
    out.record("cpu_pmu_event", "pmu", value.cpu_index, .{
        .cpu_index = value.cpu_index,
        .epoch = value.epoch,
        .generation = value.generation,
        .event_id = value.event_id,
        .event_name = d.eventName(value.profile, value.event_id),
        .profile = value.profile,
        .signature = value.signature,
        .state = decoded.state,
        .scope_name = @as([]const u8, "local thread counter; includes wrapper and possible NMI/SMI"),
        .iterations = value.iterations,
        .counter_width = value.counter_width,
        .raw_before = decoded.raw_before,
        .raw_after = decoded.raw_after,
        .modulo_delta = decoded.modulo_delta,
        .absolute_count = decoded.absolute_count,
        .window_ns = @as(?u64, if (value.flags & a.cpu_pmu_result_flag_within_budget != 0 and value.end_ns >= value.begin_ns) value.end_ns - value.begin_ns else null),
        .restored = value.flags & a.cpu_pmu_result_flag_restored != 0,
    });
    return decoded.state != .inconsistent;
}
fn information(info: a.CpuPmuInfo, out: *Output) void {
    out.record("cpu_pmu_info_raw", "pmu", info.cpu_index, info);
    out.record("cpu_pmu_availability", "pmu", info.cpu_index, .{
        .cpu_index = info.cpu_index,
        .epoch = info.epoch,
        .profile = info.profile,
        .signature = info.signature,
        .reason = info.reason,
        .reason_name = d.reasonName(info.reason),
        .virtual = info.flags & a.cpu_pmu_flag_virtual != 0,
        .qualified = info.flags & a.cpu_pmu_flag_qualified != 0,
        .counter_width = @as(?u32, if (info.counter_width != 0) info.counter_width else null),
        .fixed_width = @as(?u32, if (info.fixed_width != 0) info.fixed_width else null),
        .absolute_count = @as(?u64, null),
    });
}
pub fn collect(devices: *const r4os.r4dev.Context, out: *Output) bool {
    if (!devices.hasFn("cpu_pmu_info") or !devices.hasFn("cpu_pmu_result")) {
        out.unavailable("pmu", "counter provider unavailable");
        return true;
    }
    var first: a.CpuPmuInfo = .{};
    if (devices.cpuPmuInfo(0, &first) != 0 or first.configured_cpus == 0) return false;
    for (0..first.configured_cpus) |cpu| {
        var info: a.CpuPmuInfo = .{};
        if (devices.cpuPmuInfo(@intCast(cpu), &info) != 0 or !valid(info, cpu)) return false;
        information(info, out);
        if (info.flags & a.cpu_pmu_flag_last_result != 0) {
            var value: a.CpuPmuResult = .{};
            const rc = devices.cpuPmuResult(@intCast(cpu), info.last_epoch, info.last_generation, &value);
            // A concurrent new measurement can replace the one retained slot.
            if (rc == a.cpu_capabilities_error_epoch or rc == a.cpu_capabilities_error_busy) {
                out.unavailable("pmu", "retained generation changed during passive copy");
                continue;
            }
            if (rc != 0 or value.cpu_index != cpu or value.epoch != info.last_epoch or
                value.generation != info.last_generation or !receipt(value, out)) return false;
        }
    }
    out.message("pmu", "Passive counter metadata and last exact receipt. No counter instruction or workload is started. Missing values remain null; AMD legacy deltas are modulo only.", false);
    return true;
}

var sys: r4os.r4sys.Context = undefined;
var dev: r4os.r4dev.Context = undefined;
var gate: Atomic = .init(0);
var done: Atomic = .init(0);
var words: [128]u64 = .{0} ** 128;
var data: [512]u64 = .{0} ** 512;
var callbacks: u32 = 0;
const Job = struct {
    info: a.CpuPmuInfo = .{},
    results: [6]a.CpuPmuResult = .{a.CpuPmuResult{}} ** 6,
    codes: [6]i32 = .{0} ** 6,
    headers: u32 = 0,
    refusals: u32 = 0,
    measured: u32 = 0,
    unavailable: u32 = 0,
    callback_count: u32 = 0,
};
var job: Job = .{};
fn now() u64 {
    return sys.monotonicNanoseconds() orelse 0;
}
fn same(comptime T: type, before: *const T, after: *const T) bool {
    return std.mem.eql(u8, std.mem.asBytes(before), std.mem.asBytes(after));
}
fn current(cpu: u32) bool {
    var handle: a.ProgramJoinHandle = .{};
    var placement: a.ThreadPlacementInfo = .{};
    return sys.threadCurrentHandle(&handle) == a.thread_ok and sys.threadPlacementGet(&handle, &placement, &.{}) == a.thread_ok and
        placement.running_cpu == cpu and placement.home_cpu == cpu and placement.request_revision == placement.applied_revision and
        placement.flags & a.thread_placement_flag_parallel != 0;
}
// A small volatile scalar workload with branches and one resident 4 KB buffer.
// Warmed before native admission. No syscall, allocation, clock, fault or yield.
noinline fn pureWork(context: u64, iterations: u32) callconv(.c) i32 {
    const count: *volatile u32 = &callbacks;
    count.* +%= 1;
    var x = context | 1;
    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        const index: usize = @intCast((x ^ i) & 511);
        const cell: *volatile u64 = &data[index];
        x = (x ^ cell.*) *% 6364136223846793005 +% i;
        if (x & 8 != 0) cell.* = x else {
            const peer: *volatile u64 = &data[(index + 17) & 511];
            peer.* = x ^ 0x1234_5678;
        }
    }
    return 0;
}
fn contracts(cpu: u32, epoch: u64) bool {
    for (0..2) |mode| {
        var info: a.CpuPmuInfo = .{};
        var result: a.CpuPmuResult = .{};
        if (mode == 0) {
            info.version = 0;
            result.version = 0;
        } else {
            info.size -= 1;
            result.size -= 1;
        }
        const bi = info;
        const br = result;
        if (dev.cpuPmuInfo(cpu, &info) != a.cpu_capabilities_error_invalid or
            dev.cpuPmuResult(cpu, epoch, 1, &result) != a.cpu_capabilities_error_invalid or
            dev.cpuPmuMeasure(cpu, epoch, 0, 1, pureWork, 1, &result) != a.cpu_capabilities_error_invalid or
            !same(a.CpuPmuInfo, &bi, &info) or !same(a.CpuPmuResult, &br, &result)) return false;
        job.headers += 3;
    }
    for (0..6) |mode| {
        var guarded = extern struct { value: a.CpuPmuResult = .{ .raw_after = sentinel }, tail: u64 = sentinel }{};
        guarded.value.size = @sizeOf(@TypeOf(guarded));
        const before = guarded;
        const rc = dev.cpuPmuMeasure(if (mode == 0) job.info.configured_cpus else cpu, if (mode == 1) epoch +% 1 else epoch, if (mode == 2) 6 else 0, if (mode == 3) 0 else if (mode == 4) a.cpu_pmu_max_iterations + 1 else 1, if (mode == 5) null else pureWork, 1, &guarded.value);
        const expected = if (mode == 0) a.cpu_capabilities_error_index else if (mode == 1) a.cpu_capabilities_error_epoch else a.cpu_capabilities_error_invalid;
        if (rc != expected or !same(@TypeOf(guarded), &before, &guarded)) return false;
        job.refusals += 1;
    }
    return callbacks == 0;
}
fn cases(cpu: u32) i32 {
    defer job.callback_count = callbacks;
    if (!current(cpu)) return 11;
    var guarded = extern struct { value: a.CpuPmuInfo = .{}, tail: u64 = sentinel }{};
    guarded.value.size = @sizeOf(@TypeOf(guarded));
    if (dev.cpuPmuInfo(cpu, &guarded.value) != 0 or guarded.tail != sentinel or !valid(guarded.value, cpu)) return 12;
    job.info = guarded.value;
    callbacks = 0;
    if (!contracts(cpu, job.info.epoch)) return 13;
    const qualified = job.info.flags & a.cpu_pmu_flag_qualified != 0 and job.info.flags & a.cpu_pmu_flag_virtual == 0;
    if (qualified) {
        for (&data, 0..) |*v, i| v.* = i *% 0x1234567 +% 1;
        _ = pureWork(1, 128);
        callbacks = 0;
    }
    for (0..6) |event| {
        if (sys.programShouldClose()) return 4;
        var measured = extern struct { value: a.CpuPmuResult = .{ .raw_after = sentinel }, tail: u64 = sentinel }{};
        measured.value.size = @sizeOf(@TypeOf(measured));
        const before = measured;
        const rc = dev.cpuPmuMeasure(cpu, job.info.epoch, @intCast(event), 128, pureWork, event + 1, &measured.value);
        job.codes[event] = rc;
        if (measured.tail != sentinel) return 14;
        if (!qualified or job.info.event_mask & (@as(u32, 1) << @intCast(event)) == 0) {
            if (rc != a.cpu_capabilities_error_unsupported or !same(@TypeOf(measured), &before, &measured)) return 15;
            job.unavailable += 1;
            continue;
        }
        if (rc != 0) return 16;
        const value = measured.value;
        if (value.cpu_index != cpu or value.epoch != job.info.epoch or value.event_id != event or value.profile != job.info.profile) return 17;
        job.results[event] = value;
        if (value.status != 0 or value.flags & a.cpu_pmu_result_flag_restored == 0) return 18;
        var copied: a.CpuPmuResult = .{};
        if (dev.cpuPmuResult(cpu, value.epoch, value.generation, &copied) != 0 or !same(a.CpuPmuResult, &value, &copied)) return 19;
        const prior = copied;
        if (dev.cpuPmuResult(cpu, value.epoch, value.generation +% 1, &copied) != a.cpu_capabilities_error_epoch or !same(a.CpuPmuResult, &prior, &copied)) return 20;
        job.measured += 1;
    }
    job.callback_count = callbacks;
    if (!qualified and callbacks != 0) return 21;
    return if (current(cpu)) 0 else 22;
}
fn worker(raw: u64) callconv(.c) i32 {
    defer done.store(1, .release);
    const begun = now();
    while (gate.load(.acquire) == 0) {
        if (now() -| begun > 5_000_000_000) return 10;
        sys.sleepTicks(1);
    }
    return if (gate.load(.acquire) == 1) cases(@intCast(raw)) else 9;
}
pub fn run(app: *r4os.App, out: *Output, bench: bool) i32 {
    sys = app.system();
    dev = app.devicesLowLevel() orelse return 2;
    inline for (.{ "cpu_pmu_info", "cpu_pmu_measure", "cpu_pmu_result" }) |name| if (!dev.hasFn(name)) {
        out.unavailable("pmu", "counter provider unavailable");
        return 2;
    };
    if (!d.checkFixtures()) return 1;
    var first: a.CpuPmuInfo = .{};
    if (dev.cpuPmuInfo(0, &first) != 0 or first.configured_cpus == 0) return 2;
    const word_count = (@as(usize, first.configured_cpus) + 63) / 64;
    if (word_count > words.len) {
        out.unavailable("pmu", "placement capacity exceeded; no CPU truncation");
        return 2;
    }
    var created: u32 = 0;
    var reaped: u32 = 0;
    var total: u32 = 0;
    for (0..first.configured_cpus) |cpu| {
        var info: a.CpuPmuInfo = .{};
        if (dev.cpuPmuInfo(@intCast(cpu), &info) != 0 or info.flags & a.cpu_pmu_flag_online == 0) {
            out.unavailable("pmu", "all configured CPUs must be online");
            return 2;
        }
        job = .{};
        gate.store(0, .release);
        done.store(0, .release);
        var handle: a.ProgramJoinHandle = .{};
        if (sys.computeWorkerCreate(worker, cpu, 256 * 1024, &handle) != a.thread_ok) return 1;
        created += 1;
        @memset(&words, 0);
        words[cpu / 64] = @as(u64, 1) << @intCast(cpu % 64);
        const request: a.ThreadPlacementRequest = .{ .preferred_cpu = @intCast(cpu), .work_class = a.thread_placement_class_batch };
        var prepared = sys.threadPlacementSet(&handle, &request, words[0..word_count]) == a.thread_ok;
        const begun = now();
        while (prepared) {
            var placement: a.ThreadPlacementInfo = .{};
            if (sys.threadPlacementGet(&handle, &placement, &.{}) != a.thread_ok) {
                prepared = false;
                break;
            }
            if (placement.request_revision == placement.applied_revision and placement.home_cpu == cpu) break;
            if (now() -| begun > 5_000_000_000) {
                prepared = false;
                break;
            }
            sys.sleepTicks(1);
        }
        gate.store(if (prepared) 1 else 2, .release);
        var code: i32 = -1;
        const joined = sys.threadHandleJoin(&handle, sys.ticksFromMilliseconds(5000), &code);
        if (joined != a.thread_ok) {
            out.record("cpu_pmu_retained", "pmu", cpu, .{ .joined = joined, .created = created, .reaped = reaped });
            _ = sys.programExit(24, a.program_exit_reason_failed);
            while (true) sys.sleepTicks(1);
        }
        reaped += 1;
        if (done.load(.acquire) == 0) return 1;
        information(job.info, out);
        out.record("cpu_pmu_check", "pmu", cpu, .{ .cpu_index = cpu, .result = code, .prepared = prepared, .header_checks = job.headers, .refusals = job.refusals, .measurement_results = job.codes, .measured = job.measured, .unavailable = job.unavailable, .callback_count = job.callback_count });
        for (job.results, job.codes) |value, rc| if (rc == 0 and value.generation != 0 and !receipt(value, out)) return 1;
        if (!prepared or code != 0) return if (code == 4) 4 else 1;
        total += job.measured;
    }
    out.record("cpu_pmu_completed", "pmu", 0, .{ .configured_cpus = first.configured_cpus, .created = created, .reaped = reaped, .synthetic_decoder_cases = d.fixture_count, .measured = total, .standard_modified = false });
    if (bench and total == 0) {
        out.unavailable("pmu", "no qualified native hardware counters; no workload or fake counts");
        return 2;
    }
    out.message("pmu", "SPECTRA PMU: ok (exact placement and joins; native receipts or explicit counter unavailability)", false);
    return 0;
}
