//! Cached observations only. No register read or sampling work starts here.
const r4os = @import("r4os");
const a = r4os.abi;
const Output = @import("output.zig").Output;
pub fn state(value: u32) []const u8 {
    return switch (value) {
        a.cpu_power_state_no_provider => "provider unavailable",
        a.cpu_power_state_no_sample => "no sample",
        a.cpu_power_state_observed => "observed",
        a.cpu_power_state_stale => "stale",
        a.cpu_power_state_unsupported => "unsupported CPU model",
        a.cpu_power_state_virtual => "virtual; physical sensors unavailable",
        else => "unknown state",
    };
}
fn number(value: a.CpuPowerInfo, mask: u32, raw: u64) ?u64 {
    return if (value.valid_mask & mask == mask) raw else null;
}
pub fn record(out: *Output, value: a.CpuPowerInfo, reported_ns: ?u64) void {
    const package = a.cpu_power_valid_package_energy | a.cpu_power_valid_package_scope;
    const core = a.cpu_power_valid_core_energy | a.cpu_power_valid_core_scope;
    const sampled = value.flags & a.cpu_power_flag_sampled != 0;
    out.record("cpu_power", "cpu_power", value.cpu_index, .{
        .state_name = state(value.state),
        .provider_generation = value.provider_generation,
        .epoch = value.epoch,
        .sequence = value.sequence,
        .sampled = sampled,
        .reported_ns = reported_ns,
        .captured_ns = if (sampled) @as(?u64, value.captured_ns) else null,
        .age_ns = if (sampled and reported_ns != null and reported_ns.? >= value.captured_ns) @as(?u64, reported_ns.? - value.captured_ns) else null,
        .interval_ns = if (value.interval_ns != 0) @as(?u64, value.interval_ns) else null,
        .active_hz = number(value, a.cpu_power_valid_active_hz, value.active_hz),
        .reference_hz = number(value, a.cpu_power_valid_reference_hz, value.reference_hz),
        .temperature_millic = if (value.valid_mask & a.cpu_power_valid_temperature != 0) @as(?i32, value.temperature_millic) else null,
        .microcode_revision = if (value.valid_mask & a.cpu_power_valid_microcode != 0) @as(?u32, value.microcode_revision) else null,
        .thermal_current = if (value.valid_mask & a.cpu_power_valid_thermal_status != 0) @as(?u32, value.thermal_current) else null,
        .thermal_history = if (value.valid_mask & a.cpu_power_valid_thermal_status != 0) @as(?u32, value.thermal_history) else null,
        .package_counter_uj = if (value.cpu_index == value.package_leader) number(value, package, value.package_energy_uj) else null,
        .core_domain_counter_uj = if (value.cpu_index == value.core_leader) number(value, core, value.core_energy_uj) else null,
        .energy_note = @as([]const u8, "finite counters on known domain leaders only; raw per-CPU values below; no total or watts"),
    });
    // Raw zeros are storage values. valid_mask alone admits interpretation;
    // the preceding user view represents every unavailable value as null.
    out.record("cpu_power_raw", "cpu_power_raw", value.cpu_index, value);
}
pub fn collect(dev: r4os.r4dev.Context, sys: r4os.r4sys.Context, out: *Output) bool {
    if (!dev.hasFn("cpu_power_info") or !dev.hasFn("cpu_capabilities")) {
        out.unavailable("cpu_power", "CPU observation provider unavailable");
        return true;
    }
    var first: a.CpuCapabilitiesInfo = .{};
    if (dev.cpuCapabilities(0, &first) != 0 or first.configured_cpus == 0) return false;
    for (0..first.configured_cpus) |index| {
        var cap: a.CpuCapabilitiesInfo = .{};
        var value: a.CpuPowerInfo = .{};
        if (dev.cpuCapabilities(@intCast(index), &cap) != 0 or dev.cpuPowerInfo(@intCast(index), cap.epoch, &value) != 0) {
            out.unavailable("cpu_power", "observation changing; retry the passive view");
            return false;
        }
        record(out, value, sys.monotonicNanoseconds());
        if (dev.hasFn("cpu_performance_hint")) {
            var hint: a.CpuPerformanceHintInfo = .{};
            if (dev.cpuPerformanceHint(@intCast(index), cap.epoch, &hint) != 0) return false;
            const valid = hint.flags & a.cpu_performance_hint_flag_valid != 0;
            out.record("cpu_performance_hint", "cpu_performance_hint", index, .{
                .state = hint.state,
                .epoch = hint.epoch,
                .provider_generation = hint.provider_generation,
                .sequence = hint.sequence,
                .rank = if (valid) @as(?u32, hint.rank) else null,
                .scale = if (valid) @as(?u32, hint.scale) else null,
                .scope_mask = hint.scope_mask,
                .core_mask = hint.core_mask,
                .group_ready = hint.flags & a.cpu_performance_hint_flag_group_ready != 0,
                .captured_ns = if (valid) @as(?u64, hint.captured_ns) else null,
                .expires_ns = if (valid) @as(?u64, hint.expires_ns) else null,
                .note = @as([]const u8, "unitless sampled performance ordering, maximum age1s; no frequency, capacity, efficiency or placement guarantee"),
            });
        }
    }
    return true;
}
