//! Explicit native cases supplement the existing userland THREAD/WORK/SIMD
//! checks. Only exact own generations and work receipts establish cleanup.
const std = @import("std");
const r4os = @import("r4os");
const cli = @import("../../cli.zig");
const Output = @import("../../output.zig").Output;
const abi = r4os.abi;
const Report = abi.ProgramKernelSchedulerCheck;
const sentinel: u64 = 0x5a5a_a5a5_5a5a_a5a5;
const Guarded = extern struct { value: Report = .{}, tail: [2]u64 = .{ sentinel, sentinel } };

fn headerContract(dev: *const r4os.r4dev.Context) bool {
    for (0..7) |index| {
        var invalid: Report = .{};
        var selected: u32 = abi.kernel_scheduler_check_case_all;
        switch (index) {
            0 => invalid.version = 0,
            1 => invalid.size -= 1,
            2 => selected = 0,
            3 => selected = 0x8000_0000,
            4 => selected = abi.kernel_scheduler_check_case_workers | abi.kernel_scheduler_check_case_idle,
            5 => selected = abi.kernel_scheduler_check_case_idle | abi.kernel_scheduler_check_case_all,
            else => selected = abi.kernel_scheduler_check_case_workers | abi.kernel_scheduler_check_case_all,
        }
        invalid.run_id = sentinel;
        const before = invalid;
        if (dev.kernelSchedulerCheck(selected, &invalid) != -1 or !std.mem.eql(u8, std.mem.asBytes(&invalid), std.mem.asBytes(&before))) return false;
    }
    return true;
}
fn invoke(dev: *const r4os.r4dev.Context, selected: u32, out: *Report) bool {
    var guarded: Guarded = .{};
    guarded.value.size = @sizeOf(Guarded);
    const rc = dev.kernelSchedulerCheck(selected, &guarded.value);
    out.* = guarded.value;
    return rc == 1 and guarded.tail[0] == sentinel and guarded.tail[1] == sentinel and
        out.version == abi.kernel_scheduler_check_version and out.size == @sizeOf(Report) and out.selected == selected;
}
fn passed(r: Report) bool {
    if (r.status != abi.kernel_scheduler_check_status_passed or r.run_id == 0 or r.passed != r.selected or
        r.failed != 0 or r.unavailable != 0 or r.isolated != 15 or r.cleanup_errors != 0 or
        r.live_tasks != 0 or r.live_work != 0 or r.tasks_created == 0 or r.tasks_created != r.tasks_reaped or
        r.work_submitted != r.work_released) return false;
    if (r.selected & abi.kernel_scheduler_check_case_sync != 0 and (r.event_iterations != 200 or r.if_checks != 4)) return false;
    if (r.selected & abi.kernel_scheduler_check_case_unwind != 0 and r.unwind_checks != 2) return false;
    if (r.selected & abi.kernel_scheduler_check_case_directed != 0 and r.role_mask != 15) return false;
    if (r.selected & abi.kernel_scheduler_check_case_deadlines != 0 and r.deadline_tasks != 65) return false;
    // Native fairness owns three real deadline tickets (one cancelled),
    // while FPU owns two and its continuation witness owns four. Every
    // selected case must retain its exact receipts, including cancellation.
    const expected_work: u64 = @as(u64, if (r.selected & abi.kernel_scheduler_check_case_fairness != 0) 3 else 0) +
        @as(u64, if (r.selected & abi.kernel_scheduler_check_case_fpu != 0) 6 else 0);
    if (r.work_submitted != expected_work) return false;
    return true;
}

fn admissionInvoke(dev: *const r4os.r4dev.Context, result: *Report) bool {
    return invoke(dev, abi.kernel_scheduler_check_case_sync, result);
}
fn admissionBusy(result: Report) bool {
    return result.status == abi.kernel_scheduler_check_status_busy and result.run_id == 0 and
        result.passed == 0 and result.failed == 0 and result.tasks_created == 0 and
        result.live_tasks == 0 and result.live_work == 0;
}
const Admission = @import("../admission.zig").Probe(Report, admissionInvoke, passed, admissionBusy);

pub fn run(app: *r4os.App, args: []const u8, out: *Output) i32 {
    const all = abi.kernel_scheduler_check_case_all;
    const selected: u32 = if (cli.same(args, "/KERNEL")) all else if (cli.same(args, "/KERNEL:SYNC") or cli.same(args, "/KERNEL:ADMISSION")) abi.kernel_scheduler_check_case_sync | (if (cli.same(args, "/KERNEL:SYNC")) abi.kernel_scheduler_check_case_unwind else @as(u32, 0)) else if (cli.same(args, "/KERNEL:SCHED")) abi.kernel_scheduler_check_case_directed | abi.kernel_scheduler_check_case_fairness | abi.kernel_scheduler_check_case_inheritance | abi.kernel_scheduler_check_case_deadlines else if (cli.same(args, "/KERNEL:FPU")) abi.kernel_scheduler_check_case_fpu else if (cli.same(args, "/KERNEL:WORKERS")) abi.kernel_scheduler_check_case_workers else if (cli.same(args, "/KERNEL:IDLE")) abi.kernel_scheduler_check_case_idle else {
        out.unavailable("thread", "use /KERNEL[:SYNC|SCHED|FPU|ADMISSION|WORKERS|IDLE] without other check options");
        return 2;
    };
    const dev = app.devicesLowLevel() orelse {
        out.unavailable("thread", "R4DEV missing");
        return 2;
    };
    if (!dev.hasFn("scheduler_kernel_check")) {
        out.unavailable("thread", "native scheduler check missing");
        return 2;
    }
    if (!headerContract(&dev)) {
        out.message("thread", "SPECTRA THREAD kernel: header contract FAILED", false);
        return 1;
    }
    if (cli.same(args, "/KERNEL:ADMISSION")) return Admission.run(app, &dev, out, "kernel_scheduler", "thread", "SPECTRA THREAD kernel admission: ok (one owner, one busy, actual join)");
    var result: Report = .{};
    const valid = invoke(&dev, selected, &result);
    out.record("kernel_scheduler", "thread", 0, result);
    out.message("thread", "Isolated boot cases: timer reprogramming, deterministic 64+1 timeout batch, reserve OOM injection, global boot priority latency.", false);
    if (valid and result.status == abi.kernel_scheduler_check_status_busy) {
        out.unavailable("thread", "another native check owns the session");
        return 1;
    }
    if (valid and result.status == abi.kernel_scheduler_check_status_cancelled) return 4;
    if (valid and result.unavailable != 0) {
        out.unavailable("thread", "selected hardware contract unavailable; see case mask");
        return 2;
    }
    const ok = valid and passed(result);
    out.message("thread", if (ok) "SPECTRA THREAD kernel: ok" else "SPECTRA THREAD kernel: FAILED", false);
    return if (ok) 0 else 1;
}
