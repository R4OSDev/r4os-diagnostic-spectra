//! Explicit bounded kernel work; observations and own cleanup stay distinct.
const r4os = @import("r4os");
const std = @import("std");
const Output = @import("../../output.zig").Output;

fn headerContract(dev: *const r4os.r4dev.Context) bool {
    for (0..2) |index| {
        var invalid: r4os.abi.ProgramKernelHeapCheck = .{};
        if (index == 0) invalid.version = 0 else invalid.size -= 1;
        invalid.run_id = 0x5a5a_a5a5_5a5a_a5a5;
        const before = invalid;
        if (dev.kernelHeapCheck(&invalid) != -1 or !std.mem.eql(u8, std.mem.asBytes(&invalid), std.mem.asBytes(&before))) return false;
    }
    return true;
}

pub fn run(app: *r4os.App, out: *Output) i32 {
    const dev = app.devicesLowLevel() orelse {
        out.unavailable("memory", "R4DEV missing");
        return 2;
    };
    if (!dev.hasFn("memory_kernel_heap_check")) {
        out.unavailable("memory", "kernel heap check missing");
        return 2;
    }
    if (!headerContract(&dev)) {
        out.message("memory", "SPECTRA MEMORY kernel heap: header contract FAILED", false);
        return 1;
    }
    const sentinel: u64 = 0x5a5a_a5a5_5a5a_a5a5;
    var guarded = extern struct {
        value: r4os.abi.ProgramKernelHeapCheck = .{},
        canary: [2]u64 = .{ sentinel, sentinel },
    }{};
    guarded.value.size = @sizeOf(@TypeOf(guarded));
    const rc = dev.kernelHeapCheck(&guarded.value);
    const result = guarded.value;
    if (rc <= 0) {
        out.unavailable("memory", "kernel heap check not available in this context");
        return 1;
    }
    out.record("kernel_heap", "memory", 0, result);
    if (result.status == r4os.abi.kernel_heap_check_status_busy) {
        out.unavailable("memory", "another kernel heap check is active");
        return 1;
    }
    if (result.status == r4os.abi.kernel_heap_check_status_cancelled) {
        out.message("memory", "SPECTRA MEMORY kernel heap: cancelled", false);
        return 4;
    }
    const cleanup = result.flags & r4os.abi.kernel_heap_check_flag_cleanup_complete != 0 and
        result.owned_live_blocks == 0 and result.owned_live_bytes == 0 and
        result.vm_live_reservations == 0 and result.cleanup_errors == 0 and
        result.owned_allocations == result.owned_releases and result.vm_reservations == result.vm_releases;
    const passed = guarded.canary[0] == sentinel and guarded.canary[1] == sentinel and
        result.version == r4os.abi.kernel_heap_check_version and
        result.size == @sizeOf(r4os.abi.ProgramKernelHeapCheck) and
        result.status == r4os.abi.kernel_heap_check_status_passed and result.run_id != 0 and
        result.cases_completed == 7 and result.failed_case == 0 and result.churn_ops == 2000 and
        result.acceptance_iterations == 16 and result.expected_double_free_errors == 1 and
        result.expected_vm_errors == 2 and cleanup;
    out.message("memory", if (passed) "SPECTRA MEMORY kernel heap: ok" else "SPECTRA MEMORY kernel heap: FAILED", false);
    return if (passed) 0 else 1;
}
