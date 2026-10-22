//! Identity/clock scope for explicit work; no new clock or instrumentation.
const r = @import("r4os");
const Output = @import("output.zig").Output;
pub fn emit(app: *r.App, out: *Output, group: []const u8) void {
    const sys = app.system();
    var clock: r.abi.MonotonicClockInfo = .{};
    const status = sys.monotonicClock(&clock);
    out.record("context", group, 0, .{ .contract_version = @as(u32, 1), .instance_id = app.raw.instance_id,
        .clock = if (status > 0 and clock.generation != 0) @as(?r.abi.MonotonicClockInfo, clock) else null,
        .clock_status = status, .tick_hz = sys.monotonicHz(), .explicit_work = true,
        .physical_visibility = @as(?bool, null), .cursor_latency_ns = @as(?u64, null) });
}
