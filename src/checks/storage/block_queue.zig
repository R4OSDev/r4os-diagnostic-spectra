//! Explicit synthetic blockqueue cases; shared presentation and admission proof.
const std = @import("std");
const r4os = @import("r4os");
const abi = r4os.abi;
const cli = @import("../../cli.zig");
const Output = @import("../../output.zig").Output;
const Report = abi.ProgramKernelBlockQueueCheck;
const sentinel: u64 = 0x5a5a_a5a5_5a5a_a5a5;
fn headers(dev: *const r4os.r4dev.Context) bool {
    for (0..2) |index| {
        var report: Report = .{};
        if (index == 0) report.version = 0 else report.size -= 1;
        report.run_id = sentinel;
        const before = report;
        if (dev.kernelBlockQueueCheck(&report) != -1 or !std.mem.eql(u8, std.mem.asBytes(&report), std.mem.asBytes(&before))) return false;
    }
    return true;
}
fn invoke(dev: *const r4os.r4dev.Context, result: *Report) bool {
    var guarded = extern struct { value: Report = .{}, tail: [2]u64 = .{ sentinel, sentinel } }{};
    guarded.value.size = @sizeOf(@TypeOf(guarded));
    const rc = dev.kernelBlockQueueCheck(&guarded.value);
    result.* = guarded.value;
    return rc == 1 and guarded.tail[0] == sentinel and guarded.tail[1] == sentinel and result.version == abi.kernel_block_queue_check_version and result.size == @sizeOf(Report);
}
fn passed(r: Report) bool {
    return r.status == abi.kernel_block_queue_check_status_passed and r.flags == 3 and r.run_id != 0 and
        r.selected_cases == 255 and r.attempted_cases == 255 and r.passed_cases == 255 and r.failed_cases == 0 and r.unavailable_cases == 0 and r.fail_stage == 0 and r.cleanup_errors == 0 and
        r.tasks_created == 13 and r.tasks_reaped == 13 and r.retained_task_count == 0 and
        r.controllers_registered == 4 and r.controllers_unregistered == 4 and r.retained_controller_count == 0 and
        r.async_submissions == 11 and r.async_completions == 11 and r.completion_receipts == 7 and
        r.duplicate_rejections == 1 and (r.duplicate_disposition == 2 or r.duplicate_disposition == 3) and r.late_rejections == 1 and
        r.cancel_requests == 2 and r.timeout_cancels == 1 and r.reset_cancels == 1 and r.resets == 1 and
        r.read_ops == 7 and r.write_ops == 1 and r.flush_ops == 1 and r.queue_high_water == 3 and r.in_flight_high_water == 2 and r.parallel_active_max == 2 and
        r.retained_request_count == 0 and r.retained_buffer_count == 0;
}
fn busy(r: Report) bool {
    return r.status == abi.kernel_block_queue_check_status_busy and r.run_id == 0 and r.flags == 0 and r.tasks_created == 0 and r.tasks_reaped == 0 and r.retained_task_count == 0 and r.controllers_registered == 0 and r.controllers_unregistered == 0 and r.retained_controller_count == 0 and r.async_submissions == 0 and r.retained_request_count == 0 and r.retained_buffer_count == 0;
}
const Admission = @import("../admission.zig").Probe(Report, invoke, passed, busy);
pub fn run(app: *r4os.App, args: []const u8, out: *Output) i32 {
    const admission = cli.same(args, "/BLOCKQUEUE:ADMISSION");
    if (!admission and !cli.same(args, "/BLOCKQUEUE")) {
        out.unavailable("storage", "use CHECK STORAGE /BLOCKQUEUE[:ADMISSION]");
        return 2;
    }
    const dev = app.devicesLowLevel() orelse {
        out.unavailable("storage", "R4DEV unavailable");
        return 2;
    };
    if (!dev.hasFn("storage_block_queue_check")) {
        out.unavailable("storage", "native blockqueue source unavailable");
        return 2;
    }
    if (!headers(&dev)) {
        out.message("storage", "SPECTRA STORAGE blockqueue header contract: FAILED", false);
        return 1;
    }
    if (admission) return Admission.run(app, &dev, out, "kernel_block_queue", "storage", "SPECTRA STORAGE blockqueue admission: ok (one owner, one busy, actual join)");
    var report: Report = .{};
    const valid = invoke(&dev, &report);
    if (valid and report.flags & abi.kernel_block_queue_check_flag_partial_snapshot != 0) {
        out.record("incomplete", "storage", 0, .{ .run_id = report.run_id, .status = report.status, .reason = @as([]const u8, "own work or release not fully acknowledged; resident state retained") });
        return 1;
    }
    out.record("kernel_block_queue", "storage", 0, report);
    out.message("storage", "Synthetic own controllers only; resident buffers are reusable after actual retirement. Global counters and physical-disk fault injection are not used.", false);
    if (valid and report.status == abi.kernel_block_queue_check_status_unavailable) {
        out.unavailable("storage", "native block workers/context unavailable; no work started");
        return 2;
    }
    if (valid and report.status == abi.kernel_block_queue_check_status_busy) {
        out.unavailable("storage", "another blockqueue probe owns or retains the session");
        return 1;
    }
    if (valid and report.status == abi.kernel_block_queue_check_status_cancelled) return 4;
    const ok = valid and passed(report);
    out.message("storage", if (ok) "SPECTRA STORAGE blockqueue: ok" else "SPECTRA STORAGE blockqueue: FAILED", false);
    return if (ok) 0 else 1;
}
