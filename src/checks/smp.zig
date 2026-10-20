//! Explicit functional work supplements the passive SMP/TLB collector.
const std = @import("std");
const r4os = @import("r4os");
const abi = r4os.abi;
const cli = @import("../cli.zig");
const Output = @import("../output.zig").Output;
const Report = abi.ProgramKernelSmpCheck;
const sentinel: u64 = 0x5a5a_a5a5_5a5a_a5a5;
fn headers(dev: *const r4os.r4dev.Context) bool {
    for (0..2) |index| {
        var check: Report = .{};
        var view: abi.ProgramSmpTlbSnapshot = .{};
        if (index == 0) { check.version = 0; view.version = 0; }
        else { check.size -= 1; view.size -= 1; }
        check.run_id = sentinel; view.tlb_generation = sentinel;
        const before_check = check; const before_view = view;
        if (dev.kernelSmpCheck(&check) != -1 or dev.smpTlbSnapshot(&view) != -1 or
            !std.mem.eql(u8, std.mem.asBytes(&check), std.mem.asBytes(&before_check)) or
            !std.mem.eql(u8, std.mem.asBytes(&view), std.mem.asBytes(&before_view))) return false;
    }
    return true;
}
fn invoke(dev: *const r4os.r4dev.Context, result: *Report) bool {
    var guarded = extern struct { value: Report = .{}, tail: [2]u64 = .{ sentinel, sentinel } }{};
    guarded.value.size = @sizeOf(@TypeOf(guarded));
    const rc = dev.kernelSmpCheck(&guarded.value); result.* = guarded.value;
    return rc == 1 and guarded.tail[0] == sentinel and guarded.tail[1] == sentinel and
        result.version == abi.kernel_smp_check_version and result.size == @sizeOf(Report);
}
fn passed(r: Report) bool {
    const mask = r.online_mask;
    return r.status == abi.kernel_smp_check_status_passed and r.run_id != 0 and r.online_count >= 2 and
        r.online_count == @popCount(mask) and r.flags == (abi.kernel_smp_check_flag_work_complete | abi.kernel_smp_check_flag_cleanup_complete) and
        r.fail_stage == 0 and r.worker_failures == 0 and r.clock_regressions == 0 and r.tlb_failures == 0 and
        r.owner_failures == 0 and r.cleanup_errors == 0 and r.isolated_mask == 3 and
        r.placement_mask == mask and r.observed_mask == mask and r.tlb_ready_mask == mask and
        r.tlb_updated_mask == mask and r.owner_done_mask == mask and r.expected_checksum == r.actual_checksum and
        r.tlb_generation != 0 and r.tlb_target_mask != 0 and (r.tlb_acknowledgement_mask & r.tlb_target_mask) == r.tlb_target_mask and
        r.clock_source != 0 and r.clock_generation != 0 and (r.clock_registered_mask & mask) == mask and
        r.tasks_created == @as(u64, r.online_count) + 1 and r.tasks_created == r.tasks_reaped and
        r.retained_task_count == 0 and r.retained_frame_count == 0 and r.retained_range_count == 0 and
        r.retained_allocation_count == 0 and r.mutex_operations == @as(u64, r.online_count) * 64;
}
fn busy(r: Report) bool {
    return r.status == abi.kernel_smp_check_status_busy and r.run_id == 0 and r.flags == 0 and
        r.tasks_created == 0 and r.tasks_reaped == 0 and r.retained_task_count == 0 and r.retained_frame_count == 0 and
        r.retained_range_count == 0 and r.retained_allocation_count == 0;
}
const Admission = @import("admission.zig").Probe(Report, invoke, passed, busy);
pub fn run(app: *r4os.App, args: []const u8, out: *Output) i32 {
    if (cli.same(args, "/POWER")) return @import("cpu_power.zig").run(app, out);
    if (cli.same(args, "/FEATURES") or std.ascii.startsWithIgnoreCase(args, "/FEATURES-OFFLINE:")) return @import("cpu_capabilities.zig").run(app, args, out);
    if (cli.same(args, "/MCA")) return @import("../mca.zig").check(app, out);
    if (cli.same(args, "/MICROCODE")) return @import("../microcode.zig").check(app, out);
    if (cli.same(args, "/PMU")) return @import("../pmu.zig").run(app, out, false);
    if (cli.same(args, "/LIFECYCLE")) return @import("cpu_lifecycle.zig").launch(app, out);
    if (std.ascii.startsWithIgnoreCase(args, "/LIFECYCLEBSP:")) return @import("cpu_lifecycle.zig").foreground(app, args[14..], out);
    if (args.len != 0 and !cli.same(args, "/ADMISSION")) { out.unavailable("smp", "use CHECK SMP [/ADMISSION|/LIFECYCLE|/POWER|/FEATURES|/FEATURES-OFFLINE:n|/MCA|/MICROCODE|/PMU]"); return 2; }
    const dev = app.devicesLowLevel() orelse { out.unavailable("smp", "R4DEV unavailable"); return 2; };
    if (!dev.hasFn("smp_kernel_check") or !dev.hasFn("performance_smp_tlb")) { out.unavailable("smp", "native SMP source unavailable"); return 2; }
    if (!headers(&dev)) { out.message("smp", "SPECTRA SMP header contract: FAILED", false); return 1; }
    if (cli.same(args, "/ADMISSION")) {
        var view: abi.ProgramSmpTlbSnapshot = .{};
        if (!@import("../smp.zig").snapshot(&dev, &view)) { out.unavailable("smp", "passive SMP/TLB snapshot unavailable"); return 2; }
        if (view.schedulable_count < 2) { out.unavailable("smp", "requires at least two schedulable CPUs; no workload started"); return 2; }
        return Admission.run(app, &dev, out, "kernel_smp", "smp", "SPECTRA SMP admission: ok (one owner, one busy, actual join)");
    }
    var result: Report = .{};
    const valid = invoke(&dev, &result);
    if (valid and result.flags & abi.kernel_smp_check_flag_partial_snapshot != 0) {
        out.record("incomplete", "smp", 0, .{ .run_id = result.run_id, .status = result.status, .reason = @as([]const u8, "worker-owned facts not fully available; resources retained") });
        return 1;
    }
    out.record("kernel_smp", "smp", 0, result);
    out.message("smp", "Global timeout injection and heap/R4L/serial boot extras remain isolated; no speedup threshold or separate score.", false);
    if (valid and result.status == abi.kernel_smp_check_status_unavailable) { out.unavailable("smp", "requires at least two schedulable CPUs; no workload started"); return 2; }
    if (valid and result.status == abi.kernel_smp_check_status_busy) { out.unavailable("smp", "another SMP probe owns or retains the session"); return 1; }
    if (valid and result.status == abi.kernel_smp_check_status_cancelled) return 4;
    const ok = valid and passed(result);
    out.message("smp", if (ok) "SPECTRA SMP: ok" else "SPECTRA SMP: FAILED", false);
    return if (ok) 0 else 1;
}
