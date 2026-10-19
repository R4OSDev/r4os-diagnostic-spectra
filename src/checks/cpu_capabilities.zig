//! Explicit bounded public-ABI consumer: one owned compute worker at a time,
//! exact placement and actual joins; no worker prints or retains caller output.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const Output = @import("../output.zig").Output;
const Atomic = std.atomic.Value(u32);
const sentinel: u64 = 0x8524_9876_abcd_4321;
var sys: r4os.r4sys.Context = undefined;
var dev: r4os.r4dev.Context = undefined;
var gate: Atomic = .init(0);
var done: Atomic = .init(0);
var words: [128]u64 = .{0} ** 128;
const Job = struct {
    cpu: u32 = 0,
    cap: a.CpuCapabilitiesInfo = .{},
    native: a.ProgramKernelCpuRegisterCheck = .{},
    checked_features: u32 = 0,
    raw_features: u32 = 0,
    required_features: u32 = 0,
    headers: u32 = 0,
    refused: u32 = 0,
    register_results: [7]i32 = .{0} ** 7,
    optional_faults: u32 = 0,
    register_values: [7]u64 = .{0} ** 7,
};
var job: Job = .{};
const Cpuid = struct { eax: u32, ebx: u32, ecx: u32, edx: u32 };
fn cpuid(leaf: u32, subleaf: u32) Cpuid {
    var eax: u32 = 0;
    var ebx: u32 = 0;
    var ecx: u32 = 0;
    var edx: u32 = 0;
    asm volatile ("cpuid"
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx),
        : [leaf] "{eax}" (leaf),
          [subleaf] "{ecx}" (subleaf),
    );
    return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
}
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
fn invalidHeaders(cpu: u32, epoch: u64) bool {
    for (0..2) |i| {
        var cap: a.CpuCapabilitiesInfo = .{ .epoch = sentinel };
        var feature: a.CpuFeatureInfo = .{ .epoch = sentinel };
        var reg: a.CpuRegisterInfo = .{ .value = sentinel };
        var check: a.ProgramKernelCpuRegisterCheck = .{ .epoch = sentinel };
        if (i == 0) {
            cap.version = 0;
            feature.version = 0;
            reg.version = 0;
            check.version = 0;
        } else {
            cap.size -= 1;
            feature.size -= 1;
            reg.size -= 1;
            check.size -= 1;
        }
        const bc = cap;
        const bf = feature;
        const br = reg;
        const bn = check;
        if (dev.cpuCapabilities(cpu, &cap) != a.cpu_capabilities_error_invalid or dev.cpuFeature(cpu, epoch, 0, &feature) != a.cpu_capabilities_error_invalid or
            dev.cpuRegisterRead(cpu, epoch, a.cpu_register_id_pat, &reg) != a.cpu_capabilities_error_invalid or
            dev.kernelCpuRegisterCheck(cpu, epoch, &check) != a.cpu_capabilities_error_invalid or
            !same(a.CpuCapabilitiesInfo, &bc, &cap) or !same(a.CpuFeatureInfo, &bf, &feature) or
            !same(a.CpuRegisterInfo, &br, &reg) or !same(a.ProgramKernelCpuRegisterCheck, &bn, &check)) return false;
        job.headers += 4;
    }
    return true;
}
fn rejected(cpu: u32, epoch: u64, id: u32, expected: i32) bool {
    var value: a.CpuRegisterInfo = .{ .value = sentinel };
    const before = value;
    if (dev.cpuRegisterRead(cpu, epoch, id, &value) != expected or !same(a.CpuRegisterInfo, &before, &value)) return false;
    job.refused += 1;
    return true;
}
fn cases(cpu: u32) i32 {
    if (!current(cpu)) return 11;
    var guarded = extern struct { value: a.CpuCapabilitiesInfo = .{}, tail: u64 = sentinel }{};
    guarded.value.size = @sizeOf(@TypeOf(guarded));
    if (dev.cpuCapabilities(cpu, &guarded.value) != a.cpu_capabilities_ok or guarded.tail != sentinel) return 12;
    const cap = guarded.value;
    job.cap = cap;
    if (cap.epoch == 0 or cap.cpu_index != cpu or cap.state != a.cpu_lifecycle_state_online or cap.capture_sequence == 0 or cap.capture_sequence & 1 != 0 or cap.feature_count == 0 or cap.feature_count > 256 or cap.size != @sizeOf(a.CpuCapabilitiesInfo)) return 13;
    var topology: a.CpuTopologyInfo = .{};
    if (dev.cpuTopology(cpu, &topology) != a.cpu_topology_result_ok or topology.apic_id != cap.apic_id or topology.start_epoch != cap.epoch) return 14;
    const base = cpuid(0, 0);
    const ext = cpuid(0x80000000, 0);
    var vendor: [12]u8 = undefined;
    std.mem.writeInt(u32, vendor[0..4], base.ebx, .little);
    std.mem.writeInt(u32, vendor[4..8], base.edx, .little);
    std.mem.writeInt(u32, vendor[8..12], base.ecx, .little);
    if (!std.mem.eql(u8, &vendor, &cap.vendor_name) or cap.max_basic_leaf != base.eax or cap.max_extended_leaf != ext.eax) return 15;
    const one = cpuid(1, 0);
    if ((one.ecx & (1 << 31) != 0) != (cap.flags & a.cpu_capabilities_flag_hypervisor_present != 0)) return 16;
    if (one.ecx & (1 << 31) != 0) {
        const hv = cpuid(0x40000000, 0);
        var name: [12]u8 = undefined;
        std.mem.writeInt(u32, name[0..4], hv.ebx, .little);
        std.mem.writeInt(u32, name[4..8], hv.ecx, .little);
        std.mem.writeInt(u32, name[8..12], hv.edx, .little);
        if (!std.mem.eql(u8, &name, &cap.hypervisor_name) or cap.raw_hypervisor_maximum != hv.eax) return 17;
    }
    const cr0 = asm volatile ("mov %%cr0, %[value]"
        : [value] "=r" (-> u64),
    );
    const cr4 = asm volatile ("mov %%cr4, %[value]"
        : [value] "=r" (-> u64),
    );
    if (cap.cr0 != cr0 or cap.cr4 != cr4) return 18;
    if (cap.os_read_flags & a.cpu_capabilities_os_xcr0 != 0) {
        var low: u32 = 0;
        var high: u32 = 0;
        asm volatile ("xgetbv"
            : [low] "={eax}" (low),
              [high] "={edx}" (high),
            : [zero] "{ecx}" (@as(u32, 0)),
        );
        if (cap.xcr0 != @as(u64, low) | (@as(u64, high) << 32)) return 19;
    }
    if (!invalidHeaders(cpu, cap.epoch)) return 20;
    var ids: [256]bool = .{false} ** 256;
    for (0..cap.feature_count) |i| {
        var feature = extern struct { value: a.CpuFeatureInfo = .{}, tail: u64 = sentinel }{};
        feature.value.size = @sizeOf(@TypeOf(feature));
        if (dev.cpuFeature(cpu, cap.epoch, @intCast(i), &feature.value) != a.cpu_capabilities_ok or feature.tail != sentinel) return 21;
        const f = feature.value;
        if (f.cpu_index != cpu or f.epoch != cap.epoch or f.feature_index != i or f.feature_id == 0 or f.feature_id >= ids.len or ids[f.feature_id] or f.use_state != a.cpu_feature_use_unknown or f.source_register > 3 or f.source_bit > 32) return 22;
        ids[f.feature_id] = true;
        if (f.flags & a.cpu_feature_flag_raw != 0) {
            const r = cpuid(f.source_leaf, f.source_subleaf);
            const raw = [_]u32{ r.eax, r.ebx, r.ecx, r.edx };
            if (f.raw_value != raw[f.source_register]) return 23;
            const present = if (f.source_bit == 32) f.raw_value & 255 != 0 else f.raw_value & (@as(u32, 1) << @intCast(f.source_bit)) != 0;
            if (f.hardware_state != (if (present) a.cpu_feature_hardware_present else a.cpu_feature_hardware_absent)) return 24;
            job.raw_features += 1;
        } else if (f.hardware_state != a.cpu_feature_hardware_unknown) return 25;
        if (f.flags & a.cpu_feature_flag_module_required != 0) {
            if (f.hardware_state != a.cpu_feature_hardware_present or (f.os_state != a.cpu_feature_os_enabled and f.os_state != a.cpu_feature_os_not_applicable)) return 26;
            job.required_features += 1;
        }
        if ((f.feature_id == a.cpu_feature_id_avx512f or f.feature_id == a.cpu_feature_id_amx_tile) and cap.xcr0 == 7 and f.os_state == a.cpu_feature_os_enabled) return 27;
        job.checked_features += 1;
    }
    var end: a.CpuFeatureInfo = .{ .epoch = sentinel };
    const before_end = end;
    if (dev.cpuFeature(cpu, cap.epoch, cap.feature_count, &end) != a.cpu_capabilities_end or !same(a.CpuFeatureInfo, &end, &before_end)) return 28;
    const stale = if (cap.epoch < std.math.maxInt(u64)) cap.epoch + 1 else cap.epoch - 1;
    if (dev.cpuFeature(cpu, stale, 0, &end) != a.cpu_capabilities_error_epoch or !same(a.CpuFeatureInfo, &end, &before_end) or
        !rejected(cpu, stale, a.cpu_register_id_pat, a.cpu_capabilities_error_epoch) or
        !rejected(cpu, cap.epoch, std.math.maxInt(u32), a.cpu_capabilities_error_unsupported)) return 29;
    if (cap.configured_cpus > 1) {
        const other = (cpu + 1) % cap.configured_cpus;
        var peer: a.CpuCapabilitiesInfo = .{};
        if (dev.cpuCapabilities(other, &peer) != a.cpu_capabilities_ok or !rejected(other, peer.epoch, a.cpu_register_id_pat, if (peer.flags & a.cpu_capabilities_flag_schedulable != 0) a.cpu_capabilities_error_context else a.cpu_capabilities_error_offline)) return 30;
    }
    const flags = asm volatile ("pushfq; popq %[value]"
        : [value] "=r" (-> u64),
        :
        : .{ .memory = true });
    asm volatile ("cli" ::: .{ .memory = true });
    var refused: a.CpuRegisterInfo = .{ .value = sentinel };
    const old_refused = refused;
    const critical = dev.cpuRegisterRead(cpu, cap.epoch, a.cpu_register_id_pat, &refused);
    const critical_flags = asm volatile ("pushfq; popq %[value]"
        : [value] "=r" (-> u64),
        :
        : .{ .memory = true });
    if (flags & (1 << 9) != 0) asm volatile ("sti" ::: .{ .memory = true });
    if (critical != a.cpu_capabilities_error_context or critical_flags & (1 << 9) != 0 or !same(a.CpuRegisterInfo, &refused, &old_refused)) return 31;
    job.refused += 1;
    const selectors = [_]u32{ a.cpu_register_id_efer, a.cpu_register_id_apic_base, a.cpu_register_id_pat, a.cpu_register_id_mtrr_cap, a.cpu_register_id_mperf, a.cpu_register_id_aperf, a.cpu_register_id_intel_platform_info };
    for (selectors, 0..) |id, i| {
        var result = extern struct { value: a.CpuRegisterInfo = .{ .value = sentinel }, tail: u64 = sentinel }{};
        result.value.size = @sizeOf(@TypeOf(result));
        const before = result;
        const rc = dev.cpuRegisterRead(cpu, cap.epoch, id, &result.value);
        job.register_results[i] = rc;
        if (result.tail != sentinel) return 32;
        if (rc == a.cpu_capabilities_ok) {
            if (result.value.epoch != cap.epoch or result.value.cpu_index != cpu or result.value.register_id != id or result.value.capture_sequence != cap.capture_sequence) return 33;
            if (id == a.cpu_register_id_efer and cap.os_read_flags & a.cpu_capabilities_os_efer != 0 and result.value.value != cap.efer) return 34;
            if (id == a.cpu_register_id_pat and cap.os_read_flags & a.cpu_capabilities_os_pat != 0 and result.value.value != cap.pat) return 35;
            job.register_values[i] = result.value.value;
        } else {
            if ((rc != a.cpu_capabilities_error_unsupported and rc != a.cpu_capabilities_error_fault) or !same(@TypeOf(result), &before, &result)) return 36;
            if (rc == a.cpu_capabilities_error_fault) job.optional_faults += 1;
        }
    }
    var checked = extern struct { value: a.ProgramKernelCpuRegisterCheck = .{}, tail: u64 = sentinel }{};
    checked.value.size = @sizeOf(@TypeOf(checked));
    if (dev.kernelCpuRegisterCheck(cpu, cap.epoch, &checked.value) != a.cpu_capabilities_ok or checked.tail != sentinel) return 37;
    job.native = checked.value;
    if (job.native.status != a.cpu_register_check_status_passed or job.native.passed != a.cpu_register_check_case_all or job.native.failed != 0 or job.native.faults != 4 or
        job.native.if_checks != 4 or job.native.reads != 2 or job.native.writes != 2 or job.native.cleanup_errors != 0 or job.native.epoch != cap.epoch) return 38;
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
fn offline(index: u32, out: *Output) i32 {
    var cap: a.CpuCapabilitiesInfo = .{};
    if (dev.cpuCapabilities(index, &cap) != a.cpu_capabilities_ok or cap.state != a.cpu_lifecycle_state_offline or cap.flags & (a.cpu_capabilities_flag_online | a.cpu_capabilities_flag_schedulable) != 0) return 1;
    var feature: a.CpuFeatureInfo = .{};
    if (dev.cpuFeature(index, cap.epoch, 0, &feature) != a.cpu_capabilities_ok or feature.epoch != cap.epoch) return 1;
    var reg: a.CpuRegisterInfo = .{ .value = sentinel };
    const before_reg = reg;
    var check: a.ProgramKernelCpuRegisterCheck = .{ .epoch = sentinel };
    const before_check = check;
    const r = dev.cpuRegisterRead(index, cap.epoch, a.cpu_register_id_pat, &reg);
    const n = dev.kernelCpuRegisterCheck(index, cap.epoch, &check);
    var after: a.CpuCapabilitiesInfo = .{};
    const ok = r == a.cpu_capabilities_error_offline and n == a.cpu_capabilities_error_offline and same(a.CpuRegisterInfo, &before_reg, &reg) and same(a.ProgramKernelCpuRegisterCheck, &before_check, &check) and
        dev.cpuCapabilities(index, &after) == a.cpu_capabilities_ok and after.epoch == cap.epoch and after.capture_sequence == cap.capture_sequence and after.recovered_msr_faults == cap.recovered_msr_faults;
    out.record("cpu_capabilities_offline", "smp", index, .{ .passed = ok, .capture = cap, .register_result = r, .check_result = n });
    out.message("smp", if (ok) "SPECTRA CPU capabilities offline: ok (passive data, no register instruction)" else "SPECTRA CPU capabilities offline: FAILED", false);
    return if (ok) 0 else 1;
}
pub fn run(app: *r4os.App, args: []const u8, out: *Output) i32 {
    sys = app.system();
    dev = app.devicesLowLevel() orelse return 2;
    inline for ([_][]const u8{ "cpu_capabilities", "cpu_feature", "cpu_register_read", "kernel_cpu_register_check", "cpu_topology" }) |name|
        if (!dev.hasFn(name)) {
            out.unavailable("smp", "CPU capability/register provider unavailable");
            return 2;
        };
    const prefix = "/FEATURES-OFFLINE:";
    if (std.ascii.startsWithIgnoreCase(args, prefix)) {
        const index = std.fmt.parseInt(u32, args[prefix.len..], 10) catch return 2;
        return offline(index, out);
    }
    var first: a.CpuCapabilitiesInfo = .{};
    if (dev.cpuCapabilities(0, &first) != a.cpu_capabilities_ok or first.configured_cpus == 0) return 2;
    const word_count = (@as(usize, first.configured_cpus) + 63) / 64;
    if (word_count > words.len) {
        out.unavailable("smp", "placement word capacity exceeded; no CPU truncation");
        return 2;
    }
    var created: u32 = 0;
    var reaped: u32 = 0;
    for (0..first.configured_cpus) |index| {
        var cap: a.CpuCapabilitiesInfo = .{};
        if (dev.cpuCapabilities(@intCast(index), &cap) != a.cpu_capabilities_ok or cap.flags & a.cpu_capabilities_flag_schedulable == 0) {
            out.unavailable("smp", "all configured CPUs must be online; use explicit offline observation separately");
            return 2;
        }
        job = .{ .cpu = @intCast(index) };
        gate.store(0, .release);
        done.store(0, .release);
        var handle: a.ProgramJoinHandle = .{};
        if (sys.computeWorkerCreate(worker, index, 256 * 1024, &handle) != a.thread_ok) return 1;
        created += 1;
        @memset(&words, 0);
        words[index / 64] = @as(u64, 1) << @intCast(index % 64);
        const request: a.ThreadPlacementRequest = .{ .preferred_cpu = @intCast(index), .work_class = a.thread_placement_class_batch };
        var prepared = sys.threadPlacementSet(&handle, &request, words[0..word_count]) == a.thread_ok;
        const begun = now();
        while (prepared) {
            var placement: a.ThreadPlacementInfo = .{};
            if (sys.threadPlacementGet(&handle, &placement, &.{}) != a.thread_ok) {
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
        if (joined != a.thread_ok) {
            out.record("cpu_capabilities_retained", "smp", index, .{ .joined = joined, .created = created, .reaped = reaped });
            // Static work and exact module lifetime remain until ordinary
            // process teardown really stops the peer; never reuse the job.
            _ = sys.programExit(24, a.program_exit_reason_failed);
            while (true) sys.sleepTicks(1);
        }
        reaped += 1;
        if (done.load(.acquire) == 0) return 1;
        out.record("cpu_capability_check", "smp", index, .{ .cpu = job.cpu, .result = code, .prepared = prepared, .capture = job.cap, .features = job.checked_features, .raw_features = job.raw_features, .required_features = job.required_features, .header_checks = job.headers, .refusals = job.refused, .register_results = job.register_results, .register_values = job.register_values, .optional_faults = job.optional_faults, .native = job.native });
        if (!prepared or code != 0) {
            out.message("smp", "SPECTRA CPU capabilities: FAILED", false);
            return 1;
        }
    }
    out.record("cpu_capabilities_completed", "smp", 0, .{ .configured_cpus = first.configured_cpus, .created = created, .reaped = reaped });
    out.message("smp", "SPECTRA CPU capabilities: ok (local CPUID/controls, exact epochs, scoped registers and real #GP/IF recovery on every CPU)", false);
    return 0;
}
