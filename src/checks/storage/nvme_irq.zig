//! Exact read-only hardware request, separate from passive status or legacy VM cases.
const std = @import("std");
const r4os = @import("r4os");
const abi = r4os.abi;
const cli = @import("../../cli.zig");
const Output = @import("../../output.zig").Output;
const Report = abi.ProgramKernelNvmeCheck;
const sentinel: u64 = 0x5a5a_a5a5_5a5a_a5a5;
fn headers(dev: *const r4os.r4dev.Context) bool {
    for (0..2) |index| {
        var value: Report = .{};
        if (index == 0) value.version = 0 else value.size -= 1;
        value.run_id = sentinel;
        const before = value;
        if (dev.kernelNvmeCheck(&value) != -1 or !std.mem.eql(u8, std.mem.asBytes(&value), std.mem.asBytes(&before))) return false;
    }
    return true;
}
fn invoke(dev: *const r4os.r4dev.Context, result: *Report) bool {
    var guarded = extern struct { value: Report = .{}, tail: [2]u64 = .{ sentinel, sentinel } }{};
    guarded.value.size = @sizeOf(@TypeOf(guarded));
    const rc = dev.kernelNvmeCheck(&guarded.value);
    result.* = guarded.value;
    const reported = rc == 1 or (rc == 0 and result.status == abi.kernel_nvme_check_status_unavailable and result.unavailable_reason == abi.kernel_nvme_check_unavailable_context);
    return reported and guarded.tail[0] == sentinel and guarded.tail[1] == sentinel and result.version == abi.kernel_nvme_check_version and result.size == @sizeOf(Report);
}
fn clean(r: Report) bool {
    return r.cleanup_errors == 0 and r.retained_task_count == 0 and r.retained_device_pin_count == 0 and r.retained_buffer_count == 0;
}
fn passed(r: Report) bool {
    return r.status == abi.kernel_nvme_check_status_passed and r.flags == 3 and r.run_id != 0 and clean(r) and
        r.unavailable_reason == 0 and r.fail_stage == 0 and r.sector_size > 0 and r.sector_size <= 4096 and r.device_generation != 0 and
        r.native_receipt_flags == 15 and r.observation_flags == 15 and r.request_id != 0 and r.backend_handle != 0 and r.backend_handle == r.observed_handle and
        r.controller_generation != 0 and r.namespace_generation != 0 and r.namespace_id != 0 and r.queue_id != 0 and r.command_id <= 65535 and
        r.hardware_status == 0 and r.driver_result == 0 and r.completed_bytes == r.sector_size and
        (r.irq_mode == abi.storage_observation_irq_msi or r.irq_mode == abi.storage_observation_irq_msix) and
        r.irq_generation != 0 and r.work_sequence != 0 and r.finish_tick >= r.start_tick and r.callback_count == 1 and
        r.tasks_created == 1 and r.tasks_reaped == 1;
}
fn busy(r: Report) bool {
    return r.status == abi.kernel_nvme_check_status_busy and r.run_id == 0 and r.flags == 0 and clean(r) and r.tasks_created == 0 and r.tasks_reaped == 0 and r.request_id == 0 and r.backend_handle == 0 and r.callback_count == 0;
}
fn unavailable(r: Report) bool {
    return r.status == abi.kernel_nvme_check_status_unavailable and r.unavailable_reason != 0 and clean(r) and r.tasks_created == r.tasks_reaped;
}
pub fn run(app: *r4os.App, args: []const u8, out: *Output) i32 {
    if (!cli.same(args, "/NVMEIRQ")) {
        out.unavailable("storage", "use CHECK STORAGE /NVMEIRQ");
        return 2;
    }
    const dev = app.devicesLowLevel() orelse {
        out.unavailable("storage", "R4DEV unavailable");
        return 2;
    };
    if (!dev.hasFn("storage_nvme_check")) {
        out.unavailable("storage", "native NVMe source unavailable");
        return 2;
    }
    if (!headers(&dev)) {
        out.message("storage", "SPECTRA STORAGE NVMe header contract: FAILED", false);
        return 1;
    }
    var result: Report = .{};
    const valid = invoke(&dev, &result);
    if (valid and result.flags & abi.kernel_nvme_check_flag_partial_snapshot != 0) {
        out.record("incomplete", "storage", 0, .{ .run_id = result.run_id, .status = result.status, .reason = @as([]const u8, "read or release not fully acknowledged; resident work/backing retained") });
        return 1;
    }
    out.record("kernel_nvme", "storage", 0, result);
    out.message("storage", "One read-only request; passive before/after counters and historical status are descriptive. Native ticket and driver CQE/IRQ-worker/DMA-release receipts determine success.", false);
    if (valid and unavailable(result)) {
        out.unavailable("storage", "NVMe device, observation, IRQ or caller context unavailable; see reason");
        return 2;
    }
    if (valid and busy(result)) {
        out.unavailable("storage", "another NVMe probe owns or retains the session");
        return 1;
    }
    if (valid and result.status == abi.kernel_nvme_check_status_cancelled) return 4;
    const ok = valid and passed(result);
    out.message("storage", if (ok) "SPECTRA STORAGE NVMe IRQ: ok" else "SPECTRA STORAGE NVMe IRQ: FAILED", false);
    return if (ok) 0 else 1;
}
