//! Passive enumeration of the same boot catalog used by SDK and SysInfo.
const r4os = @import("r4os");
const Output = @import("output.zig").Output;
const abi = r4os.abi;
pub fn collect(dev: *const r4os.r4dev.Context, out: *Output) bool {
    if (!dev.hasFn("cpu_topology") or !dev.hasFn("cpu_cache_topology")) {
        out.unavailable("smp", "CPU topology catalog not available");
        return true;
    }
    var first: abi.CpuTopologyInfo = .{};
    const rc = dev.cpuTopology(0, &first);
    if (rc != abi.cpu_topology_result_ok) {
        out.unavailable("smp", "CPU topology catalog not ready");
        return rc == abi.cpu_topology_result_busy or rc == abi.cpu_topology_result_end;
    }
    if (first.configured_cpus == 0) {
        out.message("smp", "CPU topology catalog invalid", false);
        return false;
    }
    for (0..first.configured_cpus) |index| {
        var info: abi.CpuTopologyInfo = .{};
        if (dev.cpuTopology(@intCast(index), &info) != abi.cpu_topology_result_ok or info.version != 1 or
            info.size != @sizeOf(abi.CpuTopologyInfo) or info.cpu_index != index or info.configured_cpus != first.configured_cpus) return false;
        out.record("cpu_topology", "smp", index, info);
        for (0..info.cache_count) |ordinal| {
            var cache: abi.CpuCacheTopologyInfo = .{};
            if (dev.cpuCacheTopology(@intCast(index), @intCast(ordinal), &cache) != abi.cpu_topology_result_ok or
                cache.version != 1 or cache.size != @sizeOf(abi.CpuCacheTopologyInfo) or cache.cpu_index != index or
                cache.cache_index != ordinal or cache.start_epoch != info.start_epoch) return false;
            out.record("cpu_cache_topology", "smp", ordinal, cache);
        }
    }
    out.message("smp", "CPU topology uses full boot identities and opaque package/core keys; advertised domain bounds are not schedulable capacity. Unknown geometry keeps the flat fallback.", false);
    return true;
}
