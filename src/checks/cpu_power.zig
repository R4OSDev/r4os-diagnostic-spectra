//! Explicit two-point refresh on each available CPU. Workers are owned,
//! exactly placed and joined before their shared result can be reused.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const Output = @import("../output.zig").Output;
const display = @import("../cpu_power.zig");
const Atomic = std.atomic.Value(u32);
const sentinel: u64 = 0x8526_9876_abcd_4321;
var sys: r4os.r4sys.Context = undefined;
var dev: r4os.r4dev.Context = undefined;
var gate: Atomic = .init(0);
var done: Atomic = .init(0);
const Job = struct { first: a.CpuPowerInfo = .{}, second: a.CpuPowerInfo = .{}, performance: a.CpuPerformanceInfo = .{}, checks: u32 = 0, rejected_registers: u32 = 0, performance_checks: u32 = 0, checksum: u64 = 0 };
var job: Job = .{};
fn now() u64 {
    return sys.monotonicNanoseconds() orelse 0;
}
fn equal(comptime T: type, x: T, y: T) bool {
    return std.mem.eql(u8, std.mem.asBytes(&x), std.mem.asBytes(&y));
}
fn current(cpu: u32) bool {
    var handle: a.ProgramJoinHandle = .{};
    var placement: a.ThreadPlacementInfo = .{};
    return sys.threadCurrentHandle(&handle) == 0 and sys.threadPlacementGet(&handle, &placement, &.{}) == 0 and
        placement.home_cpu == cpu and placement.running_cpu == cpu and placement.request_revision == placement.applied_revision and
        placement.flags & a.thread_placement_flag_parallel != 0;
}
fn capture(cpu: u32, epoch: u64, out: *a.CpuPowerInfo) bool {
    var guarded = extern struct { value: a.CpuPowerInfo = .{}, tail: u64 = sentinel }{};
    guarded.value.size = @sizeOf(@TypeOf(guarded));
    if (dev.cpuPowerCapture(cpu, epoch, &guarded.value) != 0 or guarded.tail != sentinel) return false;
    const value = guarded.value;
    if (value.version != 1 or value.size != @sizeOf(a.CpuPowerInfo) or value.cpu_index != cpu or value.epoch != epoch or
        value.flags & (a.cpu_power_flag_installed | a.cpu_power_flag_sampled) != a.cpu_power_flag_installed | a.cpu_power_flag_sampled or
        value.provider_generation == 0 or value.sequence == 0 or value.captured_ns == 0 or value.clock_generation == 0) return false;
    out.* = value;
    job.checks += 1;
    return true;
}
fn cases(cpu: u32) i32 {
    if (!current(cpu)) return 11;
    var cap: a.CpuCapabilitiesInfo = .{};
    if (dev.cpuCapabilities(cpu, &cap) != 0) return 12;
    // Explicit inspection is read-only. Normal diagnostics never enable HWP
    // or change an actual local request, even on supported native hardware.
    var performance = extern struct { value: a.CpuPerformanceInfo = .{}, tail: u64 = sentinel }{};
    performance.value.size = @sizeOf(@TypeOf(performance));
    var request: a.CpuPerformanceRequest = .{ .cpu_index = cpu, .epoch = cap.epoch };
    if (dev.cpuPerformance(&request, &performance.value) != 0 or performance.tail != sentinel or
        performance.value.size != @sizeOf(a.CpuPerformanceInfo) or performance.value.cpu_index != cpu or
        performance.value.epoch != cap.epoch or performance.value.provider_generation == 0) return 24;
    job.performance = performance.value;
    job.performance_checks += 1;
    const unchanged = performance.value;
    request.reserved0 = 1;
    if (dev.cpuPerformance(&request, &performance.value) != a.cpu_capabilities_error_invalid or
        !equal(a.CpuPerformanceInfo, unchanged, performance.value) or performance.tail != sentinel) return 25;
    request.reserved0 = 0;
    request.epoch = if (cap.epoch < std.math.maxInt(u64)) cap.epoch + 1 else cap.epoch - 1;
    if (dev.cpuPerformance(&request, &performance.value) != a.cpu_capabilities_error_epoch or
        !equal(a.CpuPerformanceInfo, unchanged, performance.value)) return 26;
    request.epoch = cap.epoch;
    if (cap.flags & a.cpu_capabilities_flag_hypervisor_present != 0) {
        if (unchanged.state != a.cpu_performance_state_unsupported or unchanged.valid_mask != 0 or
            unchanged.lease != 0 or unchanged.flags & a.cpu_performance_flag_virtual == 0) return 27;
        request.operation = a.cpu_performance_op_apply;
        request.minimum = 10;
        request.maximum = 200;
        if (dev.cpuPerformance(&request, &performance.value) != a.cpu_capabilities_error_unsupported or
            !equal(a.CpuPerformanceInfo, unchanged, performance.value)) return 28;
        request = .{ .cpu_index = cpu, .epoch = cap.epoch, .operation = a.cpu_performance_op_enable, .flags = a.cpu_performance_request_flag_sticky_enable };
        if (dev.cpuPerformance(&request, &performance.value) != a.cpu_capabilities_error_unsupported or
            !equal(a.CpuPerformanceInfo, unchanged, performance.value)) return 29;
        job.performance_checks += 2;
    }
    job.performance_checks += 2;
    for (0..2) |index| {
        var value: a.CpuPowerInfo = .{ .sequence = sentinel };
        if (index == 0) value.version = 0 else value.size -= 1;
        const before = value;
        if (dev.cpuPowerInfo(cpu, cap.epoch, &value) != a.cpu_capabilities_error_invalid or
            dev.cpuPowerCapture(cpu, cap.epoch, &value) != a.cpu_capabilities_error_invalid or !equal(a.CpuPowerInfo, before, value)) return 13;
        job.checks += 2;
    }
    if (!capture(cpu, cap.epoch, &job.first)) return 14;
    const begun = now();
    var checksum: u64 = cpu + 1;
    var iterations: u32 = 0;
    while (now() -| begun < 20_000_000 and iterations < 10_000_000) : (iterations += 1) {
        checksum = (checksum *% 6364136223846793005) +% 1442695040888963407;
        std.atomic.spinLoopHint();
    }
    if (now() -| begun < 20_000_000) return 23;
    job.checksum = checksum;
    if (!capture(cpu, cap.epoch, &job.second) or !current(cpu)) return 15;
    if (job.second.sequence <= job.first.sequence or job.second.captured_ns <= job.first.captured_ns or
        job.second.provider_generation != job.first.provider_generation or job.second.clock_generation != job.first.clock_generation or
        job.second.clock_source != job.first.clock_source) return 16;
    if (cap.flags & a.cpu_capabilities_flag_hypervisor_present != 0) {
        if (job.second.profile != a.cpu_power_profile_virtual or job.second.state != a.cpu_power_state_virtual or
            job.second.valid_mask != 0 or job.first.valid_mask != 0 or job.second.unsupported_mask != 0xfff) return 17;
        // Real VM calls prove every new model gate refuses before instruction.
        // They never promote an ignored/zero MSR to a physical sensor.
        for (8..22) |id| {
            var raw: a.CpuRegisterInfo = .{ .value = sentinel };
            const before = raw;
            if (dev.cpuRegisterRead(cpu, cap.epoch, @intCast(id), &raw) != a.cpu_capabilities_error_unsupported or !equal(a.CpuRegisterInfo, before, raw)) return 18;
            job.rejected_registers += 1;
        }
    }
    var passive = extern struct { value: a.CpuPowerInfo = .{}, tail: u64 = sentinel }{};
    passive.value.size = @sizeOf(@TypeOf(passive));
    if (dev.cpuPowerInfo(cpu, cap.epoch, &passive.value) != 0 or passive.tail != sentinel or !equal(a.CpuPowerInfo, passive.value, job.second)) return 19;
    job.checks += 1;
    var refused: a.CpuPowerInfo = .{ .sequence = sentinel };
    const before = refused;
    const stale = if (cap.epoch < std.math.maxInt(u64)) cap.epoch + 1 else cap.epoch - 1;
    if (dev.cpuPowerInfo(cpu, stale, &refused) != a.cpu_capabilities_error_epoch or
        dev.cpuPowerCapture(cpu, stale, &refused) != a.cpu_capabilities_error_epoch or !equal(a.CpuPowerInfo, before, refused)) return 20;
    job.checks += 2;
    if (cap.configured_cpus > 1) {
        const other = (cpu + 1) % cap.configured_cpus;
        var peer: a.CpuCapabilitiesInfo = .{};
        if (dev.cpuCapabilities(other, &peer) != 0) return 21;
        const expected = if (peer.flags & a.cpu_capabilities_flag_schedulable != 0) a.cpu_capabilities_error_context else a.cpu_capabilities_error_offline;
        if (dev.cpuPowerCapture(other, peer.epoch, &refused) != expected or !equal(a.CpuPowerInfo, before, refused)) return 21;
        job.checks += 1;
    }
    var after: a.CpuCapabilitiesInfo = .{};
    if (dev.cpuCapabilities(cpu, &after) != 0 or after.epoch != cap.epoch or
        (cap.flags & a.cpu_capabilities_flag_hypervisor_present != 0 and after.recovered_msr_faults != cap.recovered_msr_faults)) return 22;
    return 0;
}
fn worker(raw: u64) callconv(.c) i32 {
    defer done.store(1, .release);
    const begun = now();
    while (gate.load(.acquire) == 0) {
        if (now() -| begun > 5_000_000_000) return 10;
        sys.sleepTicks(1);
    }
    if (gate.load(.acquire) != 1) return 9;
    return cases(@intCast(raw));
}
pub fn run(app: *r4os.App, out: *Output) i32 {
    sys = app.system();
    dev = app.devicesLowLevel() orelse return 2;
    inline for (.{ "cpu_power_info", "cpu_power_capture", "cpu_performance", "cpu_capabilities", "cpu_register_read" }) |name| if (!dev.hasFn(name)) return 2;
    var first: a.CpuCapabilitiesInfo = .{};
    if (dev.cpuCapabilities(0, &first) != 0 or first.configured_cpus == 0 or first.configured_cpus > 64) return 2;
    var created: u32 = 0;
    var reaped: u32 = 0;
    for (0..first.configured_cpus) |index| {
        var cap: a.CpuCapabilitiesInfo = .{};
        if (dev.cpuCapabilities(@intCast(index), &cap) != 0) return 1;
        if (cap.flags & a.cpu_capabilities_flag_schedulable == 0) continue;
        job = .{};
        gate.store(0, .release);
        done.store(0, .release);
        var handle: a.ProgramJoinHandle = .{};
        if (sys.computeWorkerCreate(worker, index, 256 * 1024, &handle) != 0) return 1;
        created += 1;
        const mask = [_]u64{@as(u64, 1) << @as(u6, @intCast(index))};
        const request: a.ThreadPlacementRequest = .{ .preferred_cpu = @intCast(index), .work_class = a.thread_placement_class_batch };
        var prepared = sys.threadPlacementSet(&handle, &request, &mask) == 0;
        const begun = now();
        while (prepared) {
            var placement: a.ThreadPlacementInfo = .{};
            if (sys.threadPlacementGet(&handle, &placement, &.{}) != 0) {
                prepared = false;
                break;
            }
            if (placement.request_revision == placement.applied_revision and placement.home_cpu == index) break;
            if (now() -| begun > 5_000_000_000) {
                prepared = false;
                break;
            }
            sys.sleepTicks(1);
        }
        gate.store(if (prepared) 1 else 2, .release);
        var code: i32 = -1;
        const joined = sys.threadHandleJoin(&handle, sys.ticksFromMilliseconds(5000), &code);
        if (joined != 0) {
            out.record("cpu_power_retained", "cpu_power", index, .{ .joined = joined, .created = created, .reaped = reaped });
            _ = sys.programExit(26, a.program_exit_reason_failed);
            while (true) sys.sleepTicks(1);
        }
        reaped += 1;
        out.record("cpu_power_check", "cpu_power", index, .{ .result = code, .prepared = prepared, .checks = job.checks, .rejected_registers = job.rejected_registers, .performance_checks = job.performance_checks, .performance = job.performance, .first = job.first, .second = job.second, .checksum = job.checksum });
        if (!prepared or code != 0 or done.load(.acquire) == 0) {
            out.message("cpu_power", "SPECTRA CPUPOWER: FAILED", false);
            return 1;
        }
        display.record(out, job.second, sys.monotonicNanoseconds());
    }
    if (created == 0) return 2;
    out.record("cpu_power_completed", "cpu_power", 0, .{ .configured_cpus = first.configured_cpus, .available_cpus = created, .created = created, .reaped = reaped, .captures = created * 2, .atomic_across_cpus = false });
    out.message("cpu_power", "SPECTRA CPUPOWER: ok (two local captures per CPU, exact epochs, passive cache, HWP inspection/refusals, unavailable VM sensors, actual joins)", false);
    return 0;
}
