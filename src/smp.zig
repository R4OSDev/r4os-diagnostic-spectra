//! Passive only: actual remote ACK counters and current clock registrations.
const r4os = @import("r4os");
const Output = @import("output.zig").Output;
const sentinel: u64 = 0x5a5a_a5a5_5a5a_a5a5;
pub fn snapshot(dev: *const r4os.r4dev.Context, result: *r4os.abi.ProgramSmpTlbSnapshot) bool {
    var guarded = extern struct {
        value: r4os.abi.ProgramSmpTlbSnapshot = .{},
        tail: [2]u64 = .{ sentinel, sentinel },
    }{};
    guarded.value.size = @sizeOf(@TypeOf(guarded));
    const rc = dev.smpTlbSnapshot(&guarded.value);
    result.* = guarded.value;
    return rc == 1 and guarded.tail[0] == sentinel and guarded.tail[1] == sentinel and
        result.version == r4os.abi.smp_tlb_snapshot_version and result.size == @sizeOf(r4os.abi.ProgramSmpTlbSnapshot);
}
pub fn collect(dev: *const r4os.r4dev.Context, out: *Output) bool {
    var report: r4os.abi.ProgramSmpTlbSnapshot = .{};
    if (!dev.hasFn("performance_smp_tlb") or !snapshot(dev, &report)) {
        out.unavailable("smp", "passive SMP/TLB source absent or snapshot unavailable");
        return false;
    }
    out.record("smp_tlb", "smp", 0, report);
    out.message("smp", "Passive counters since boot; owner loads are not one atomic snapshot. No workload or historical check pass is implied.", false);
    const topology = @import("cpu_topology.zig").collect(dev, out);
    return @import("cpu_capabilities.zig").collect(dev, out, false) and topology;
}
