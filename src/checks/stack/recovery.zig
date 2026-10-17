//! Explicit controlled-exhaustion children. Ready process completion and reap
//! keep the existing kernel retirement contract; no global resource reset.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
var child_sys: ?r4os.r4sys.Context = null;
var peer_ready = false;
var notification: u64 = 0;
var checksum: u64 = 0;

fn same(args: []const u8, expected: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, args, " \t"), expected);
}
pub fn requested(args: []const u8) bool {
    return same(args, "/RECOVERY") or same(args, "/EXHAUSTMAIN") or same(args, "/EXHAUSTWORKER");
}
fn fail(sys: *r4os.r4sys.Context, message: []const u8) i32 {
    sys.print("SPECTRA STACK recovery FAILED: ");
    sys.println(message);
    return 1;
}
pub fn run(app: *r4os.App) i32 {
    var sys = app.system();
    child_sys = sys;
    if (same(app.args(), "/EXHAUSTMAIN")) return child(&sys, false);
    if (same(app.args(), "/EXHAUSTWORKER")) return child(&sys, true);
    const dev = app.devices() orelse return fail(&sys, "R4DEV unavailable");
    const performance = dev.performance();
    var path: [1024]u8 = undefined;
    const length = sys.programModulePath(&path);
    if (length <= 0 or length >= path.len) return fail(&sys, "module path unavailable");
    path[@intCast(length)] = 0;
    for ([_][*:0]const u8{ "/EXHAUSTMAIN", "/EXHAUSTWORKER" }, 0..) |args, index| {
        var handle: a.ProgramProcessHandle = .{};
        if (sys.programSpawnHandle(@ptrCast(&path), @import("../../route.zig").arguments("STACK", args).ptr(), .console, &handle) != a.program_handle_ok)
            return fail(&sys, "child spawn failed");
        var completion: a.ProgramProcessCompletion = .{};
        if (sys.programHandleWait(&handle, sys.monotonicHz() * 30, &completion) != a.program_handle_ok) {
            _ = sys.programHandleKill(&handle);
            return fail(&sys, "child retirement timed out");
        }
        if (completion.exit_code != -4096 or completion.exit_reason != a.program_exit_reason_failed)
            return fail(&sys, "failed completion differs");
        if (sys.programHandleReap(&handle, &completion) != a.program_handle_ok)
            return fail(&sys, "child reap failed");
        const kind: u32 = if (index == 0) a.stack_fault_kind_program_main else a.stack_fault_kind_program_thread;
        if (!exactFault(&performance, handle, kind)) return fail(&sys, "exact resident fault cause/identity missing");
        sys.println(if (index == 0) "SPECTRA STACK recovery main / peers retired: OK" else "SPECTRA STACK recovery worker / peers retired: OK");
    }
    sys.println("SPECTRA STACK recovery result: OK");
    return 0;
}
fn exactFault(dev: *const r4os.PerformanceView, handle: a.ProgramProcessHandle, kind: u32) bool {
    var cpu: u32 = 0;
    while (cpu < 64) : (cpu += 1) {
        var info: a.ProgramStackFaultInfo = .{};
        const status = dev.stackFault(cpu, &info);
        if (status == 0) break;
        if (status != 1) return false;
        const flags = a.stack_fault_flag_task | a.stack_fault_flag_thread | a.stack_fault_flag_instance | a.stack_fault_flag_bounds;
        if (info.instance_id == handle.instance_id and info.instance_generation == handle.generation and
            info.flags & flags == flags and info.sequence != 0 and info.stack_kind == kind and
            info.reason == a.stack_fault_reason_reserve_exhausted and info.vm_error == 0 and
            info.exception_vector == 14 and info.task_generation != 0 and info.thread_generation != 0 and
            info.guard_base == info.reserve_base and info.guard_bytes == 4096 and
            info.fault_address >= info.guard_base and info.fault_address - info.guard_base < info.guard_bytes)
            return true;
    }
    return false;
}
fn child(sys: *r4os.r4sys.Context, worker: bool) i32 {
    peer_ready = false;
    if (sys.notificationCreate(&notification) != a.notification_ok) return fail(sys, "notification create failed");
    var peer: a.ProgramJoinHandle = .{};
    if (sys.threadCreateHandle(peerMain, 0, 128 * 1024, 0, &peer) != a.thread_ok) return fail(sys, "peer create failed");
    while (!@atomicLoad(bool, &peer_ready, .acquire)) sys.taskYield();
    if (!worker) return exhaust(sys);
    var thread: a.ProgramJoinHandle = .{};
    if (sys.threadCreateHandle(exhaustWorker, 0, 128 * 1024, 0, &thread) != a.thread_ok) return fail(sys, "worker create failed");
    _ = sys.notificationWait(notification, 0, a.thread_wait_forever);
    return fail(sys, "main survived worker exhaustion");
}
fn peerMain(_: u64) callconv(.c) i32 {
    var sys = child_sys orelse return 1;
    @atomicStore(bool, &peer_ready, true, .release);
    _ = sys.notificationWait(notification, 0, a.thread_wait_forever);
    return 0;
}
fn exhaustWorker(_: u64) callconv(.c) i32 {
    var sys = child_sys orelse return 1;
    return exhaust(&sys);
}
fn exhaust(sys: *r4os.r4sys.Context) i32 {
    var info: a.ProgramThreadInfo = .{};
    if (sys.threadStatus(0, &info) != a.thread_ok or info.stack_reserved_bytes == 0 or info.stack_reserved_bytes > 32 * 1024 * 1024)
        return fail(sys, "unsupported bounded test reserve");
    consume(@intCast(info.stack_reserved_bytes / 4096 + 2));
    return fail(sys, "exhaustion returned");
}
noinline fn consume(depth: u32) void {
    var storage: [4096]u8 = undefined;
    asm volatile (""
        :
        : [storage] "r" (&storage),
        : .{ .memory = true });
    const bytes: [*]volatile u8 = @ptrCast(&storage);
    bytes[0] = @truncate(depth);
    bytes[storage.len - 1] = 0x5b;
    if (depth != 0) consume(depth - 1);
    checksum +%= @as(u64, bytes[0]) + bytes[storage.len - 1];
}
