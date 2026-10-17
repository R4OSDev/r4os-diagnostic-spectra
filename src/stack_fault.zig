//! Passive display of the latest resident failure per CPU, not a trace.
const r4os = @import("r4os");
const abi = r4os.abi;
const Output = @import("output.zig").Output;

fn kindName(kind: u32) []const u8 {
    return switch (kind) {
        abi.stack_fault_kind_program_main => "R4X main",
        abi.stack_fault_kind_program_thread => "R4X thread",
        abi.stack_fault_kind_kernel_task => "kernel task",
        abi.stack_fault_kind_exception => "exception",
        else => "unavailable",
    };
}
fn reasonName(reason: u32) []const u8 {
    return switch (reason) {
        abi.stack_fault_reason_reserve_exhausted => "program reserve exhausted",
        abi.stack_fault_reason_kernel_guard => "kernel stack guard",
        abi.stack_fault_reason_physical_budget => "physical budget exhausted",
        abi.stack_fault_reason_vm_commit => "VM commit failed",
        abi.stack_fault_reason_growth_forbidden => "growth forbidden in current kernel context",
        abi.stack_fault_reason_protection => "stack protection fault",
        abi.stack_fault_reason_vm_guard => "VM guard update failed",
        abi.stack_fault_reason_continuation_headroom => "insufficient resident fault continuation headroom",
        else => "unknown",
    };
}

pub fn collect(dev: *const r4os.r4dev.Context, out: *Output) bool {
    var cpu: u32 = 0;
    var failures: u32 = 0;
    while (true) : (cpu += 1) {
        var info: abi.ProgramStackFaultInfo = .{};
        const status = dev.stackFault(cpu, &info);
        if (status == 0) break;
        if (status != 1) {
            out.record("unavailable", "stack_fault", cpu, .{ .status = status, .reason = @as([]const u8, "source absent or no coherent snapshot") });
            return false;
        }
        if (info.sequence == 0) continue;
        failures += 1;
        const task = info.flags & abi.stack_fault_flag_task != 0;
        const instance = info.flags & abi.stack_fault_flag_instance != 0;
        const thread = info.flags & abi.stack_fault_flag_thread != 0;
        const bounds = info.flags & abi.stack_fault_flag_bounds != 0;
        out.record("snapshot", "stack_fault", cpu, .{
            .version = info.version, .cpu_index = info.cpu_index, .sequence = info.sequence,
            .flags = info.flags, .stack_kind = info.stack_kind, .stack_kind_name = kindName(info.stack_kind),
            .reason = info.reason, .reason_name = reasonName(info.reason), .vm_error = info.vm_error,
            .exception_vector = info.exception_vector,
            .task_id = if (task) @as(?u32, info.task_id) else null,
            .task_generation = if (task) @as(?u64, info.task_generation) else null,
            .instance_id = if (instance) @as(?u32, info.instance_id) else null,
            .instance_generation = if (instance) @as(?u64, info.instance_generation) else null,
            .thread_id = if (thread) @as(?u32, info.thread_id) else null,
            .thread_generation = if (thread) @as(?u64, info.thread_generation) else null,
            .fault_address = info.fault_address, .interrupted_rsp = info.interrupted_rsp,
            .page_fault_error = info.page_fault_error,
            .reserve_base = if (bounds) @as(?u64, info.reserve_base) else null,
            .reserve_bytes = if (bounds) @as(?u64, info.reserve_bytes) else null,
            .committed_base = if (bounds) @as(?u64, info.committed_base) else null,
            .committed_bytes = if (bounds) @as(?u64, info.committed_bytes) else null,
            .guard_base = if (bounds) @as(?u64, info.guard_base) else null,
            .guard_bytes = if (bounds) @as(?u64, info.guard_bytes) else null,
            .stack_top = if (bounds) @as(?u64, info.stack_top) else null,
            .image_base = if (instance) @as(?u64, info.image_base) else null,
            .image_bytes = if (instance) @as(?u64, info.image_bytes) else null,
            .memory_tag = if (instance) @as(?[16]u8, info.memory_tag) else null,
        });
    }
    out.record("inventory", "stack_fault", 0, .{ .cpu_slots = cpu, .recorded_failures = failures,
        .scope = @as([]const u8, "latest per CPU until overwrite or reboot; no high-water measurement") });
    return true;
}
