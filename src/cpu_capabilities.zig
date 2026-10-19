//! Passive bounded copies. Register access and native checks are explicit only.
const r4os = @import("r4os");
const a = r4os.abi;
const Output = @import("output.zig").Output;
pub fn collect(dev: *const r4os.r4dev.Context, out: *Output, details: bool) bool {
    if (!dev.hasFn("cpu_capabilities") or !dev.hasFn("cpu_feature")) {
        out.unavailable("smp", "CPU capability catalogue unavailable");
        return true;
    }
    var first: a.CpuCapabilitiesInfo = .{};
    if (dev.cpuCapabilities(0, &first) != a.cpu_capabilities_ok) {
        out.unavailable("smp", "CPU capability capture changing/unavailable");
        return false;
    }
    for (0..first.configured_cpus) |cpu| {
        var cap: a.CpuCapabilitiesInfo = .{};
        if (dev.cpuCapabilities(@intCast(cpu), &cap) != a.cpu_capabilities_ok or cap.cpu_index != cpu or cap.epoch == 0 or cap.capture_sequence == 0 or cap.capture_sequence & 1 != 0 or cap.feature_count > 256) return false;
        out.record("cpu_capabilities", "smp", cpu, cap);
        if (details) for (0..cap.feature_count) |index| {
            var feature: a.CpuFeatureInfo = .{};
            if (dev.cpuFeature(cap.cpu_index, cap.epoch, @intCast(index), &feature) != a.cpu_capabilities_ok or feature.epoch != cap.epoch) return false;
            out.record("cpu_feature", "smp", index, feature);
        };
    }
    out.message("smp", "Passive per-CPU capture; advertised hardware, enabled OS controls and unknown actual use are independent. Nominal MHz are not active frequency.", false);
    return true;
}
