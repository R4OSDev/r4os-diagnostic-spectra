//! Explicit existing-AP lifecycle and real module continuation consumers.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const Output = @import("../output.zig").Output;
const Atomic = std.atomic.Value(u32);
const tail_value: u64 = 0x8585_2323_a5a5_5a5a;
const proof_text = "BSP-LIFECYCLE-OK";
var system: r4os.r4sys.Context = undefined;
var devices: r4os.r4dev.Context = undefined;
var context_go: Atomic = .init(0);
var run_go: Atomic = .init(0);
var run_entered: Atomic = .init(0);
var release: Atomic = .init(0);
var wait_go: Atomic = .init(0);
var wait_entered: Atomic = .init(0);
var notification: u64 = 0;
var expected: [4]u64 align(32) = .{ 0x1122_3344_5566_7788, 0x8877_6655_4433_2211, 0xa5a5_5a5a_9191_7272, 0x7fee_dead_beef_2301 };
var observed: [4]u64 align(32) = .{0} ** 4;
fn now() u64 { return system.monotonicNanoseconds() orelse 0; }
fn waitAtomic(flag: *Atomic) bool {
    const begun = now();
    while (flag.load(.acquire) == 0) {
        if (now() -| begun > 5_000_000_000) return false;
        system.sleepTicks(1);
    }
    return true;
}
fn running(_: u64) callconv(.c) i32 {
    if (!waitAtomic(&run_go)) return 10;
    if (!contextRefused()) return 14;
    // No C call lies between YMM load/store: caller-saved ABI clobbers cannot
    // masquerade as a context-save failure. IRQs force the real migration.
    asm volatile (
        \\vmovdqu (%[input]), %%ymm0
        \\movl $1, (%[entered])
        \\1:
        \\pause
        \\cmpl $0, (%[stop])
        \\je 1b
        \\vmovdqu %%ymm0, (%[output])
        \\vzeroupper
        :
        : [input] "r" (&expected), [output] "r" (&observed),
          [entered] "r" (&run_entered.raw), [stop] "r" (&release.raw),
        : .{ .ymm0 = true, .memory = true, .cc = true }
    );
    return if (std.mem.eql(u64, &expected, &observed)) 0 else 11;
}
fn contextRefused() bool {
    var before: a.CpuLifecycleInfo = .{};
    if (!query(&devices, 1, &before)) return false;
    var output: a.CpuLifecycleInfo = .{ .epoch = tail_value };
    const saved = output;
    const code = devices.cpuLifecycle(a.cpu_lifecycle_op_offline, 1, before.epoch, &output);
    var after: a.CpuLifecycleInfo = .{};
    return code == a.cpu_lifecycle_error_context and std.meta.eql(output, saved) and query(&devices, 1, &after) and
        after.epoch == before.epoch and after.capacity_generation == before.capacity_generation and after.state == a.cpu_lifecycle_state_online;
}
fn contextWorker(_: u64) callconv(.c) i32 {
    if (!waitAtomic(&context_go)) return 15;
    return if (contextRefused()) 0 else 16;
}
fn waiting(_: u64) callconv(.c) i32 {
    if (!waitAtomic(&wait_go)) return 12;
    wait_entered.store(1, .release);
    return if (system.notificationWait(notification, 0, a.thread_wait_forever) == a.notification_ok) 0 else 13;
}
fn query(dev: *const r4os.r4dev.Context, cpu: u32, out: *a.CpuLifecycleInfo) bool {
    out.* = .{};
    return dev.cpuLifecycle(a.cpu_lifecycle_op_query, cpu, 0, out) == a.cpu_lifecycle_ok;
}
fn invalid(dev: *const r4os.r4dev.Context, cpu: u32, epoch: u64, out: *Output) bool {
    for (0..2) |i| {
        var info: a.CpuLifecycleInfo = .{ .epoch = tail_value };
        var report: a.ProgramKernelCpuLifecycleCheck = .{ .new_epoch = tail_value };
        if (i == 0) { info.version = 0; report.version = 0; } else { info.size -= 1; report.size -= 1; }
        const before_info = info; const before_report = report;
        const irc = dev.cpuLifecycle(a.cpu_lifecycle_op_query, cpu, 0, &info);
        const rrc = dev.kernelCpuLifecycleCheck(&report);
        const same_info = std.mem.eql(u8, std.mem.asBytes(&info), std.mem.asBytes(&before_info));
        const same_report = std.mem.eql(u8, std.mem.asBytes(&report), std.mem.asBytes(&before_report));
        if (irc != a.cpu_lifecycle_error_invalid or rrc != -1 or !same_info or !same_report) {
            out.record("cpu_lifecycle_invalid_header", "smp", i, .{ .info_result = irc, .report_result = rrc, .info_unchanged = same_info, .report_unchanged = same_report });
            return false;
        }
    }
    for ([_]struct { op: u32, index: u32, epoch: u64, code: i32 }{
        .{ .op = 99, .index = cpu, .epoch = epoch, .code = a.cpu_lifecycle_error_invalid },
        .{ .op = a.cpu_lifecycle_op_offline, .index = 0, .epoch = 1, .code = a.cpu_lifecycle_error_index },
        .{ .op = a.cpu_lifecycle_op_offline, .index = cpu, .epoch = epoch + 1, .code = a.cpu_lifecycle_error_epoch },
    }) |bad| {
        var info: a.CpuLifecycleInfo = .{ .epoch = tail_value };
        const before = info;
        const code = dev.cpuLifecycle(bad.op, bad.index, bad.epoch, &info);
        if (code != bad.code or !std.meta.eql(info, before)) {
            out.record("cpu_lifecycle_invalid_mutation", "smp", 0, .{ .operation = bad.op, .cpu = bad.index, .epoch = bad.epoch, .expected = bad.code, .actual = code, .output_unchanged = std.meta.eql(info, before) });
            return false;
        }
    }
    var info: a.CpuLifecycleInfo = .{ .epoch = tail_value };
    const before = info;
    const saved = asm volatile ("pushfq; popq %[value]" : [value] "=r" (-> u64) :: .{ .memory = true });
    asm volatile ("cli" ::: .{ .memory = true });
    const code = dev.cpuLifecycle(a.cpu_lifecycle_op_offline, cpu, epoch, &info);
    const after = asm volatile ("pushfq; popq %[value]" : [value] "=r" (-> u64) :: .{ .memory = true });
    if (saved & (1 << 9) != 0) asm volatile ("sti" ::: .{ .memory = true });
    const ok = code == a.cpu_lifecycle_error_context and after & (1 << 9) == 0 and std.meta.eql(info, before);
    if (!ok) out.record("cpu_lifecycle_invalid_if", "smp", 0, .{ .result = code, .if_still_off = after & (1 << 9) == 0, .output_unchanged = std.meta.eql(info, before) });
    return ok;
}
fn placement(handle: *const a.ProgramJoinHandle, cpu: u32, hard: bool) bool {
    const request: a.ThreadPlacementRequest = .{ .flags = if (hard) 0 else a.thread_placement_flag_default_cpus,
        .preferred_cpu = cpu, .work_class = a.thread_placement_class_batch };
    const words = [_]u64{@as(u64, 1) << @intCast(cpu)};
    return system.threadPlacementSet(handle, &request, if (hard) &words else &.{}) == a.thread_ok;
}
fn adopted(handle: *const a.ProgramJoinHandle, cpu: u32, physical: bool) bool {
    const begun = now();
    while (now() -| begun <= 5_000_000_000) {
        var p: a.ThreadPlacementInfo = .{};
        if (system.threadPlacementGet(handle, &p, &.{}) != a.thread_ok) return false;
        if (p.request_revision == p.applied_revision and p.home_cpu == cpu and (!physical or p.running_cpu == cpu)) return true;
        system.sleepTicks(1);
    }
    return false;
}
fn blocked(handle: *const a.ProgramJoinHandle) bool {
    var info: a.ProgramThreadInfo = .{};
    if (system.threadHandleStatus(handle, &info) != a.thread_ok) return false;
    const begun = now();
    restart: while (now() -| begun <= 5_000_000_000) {
        var cursor: a.ProgramInventoryCursor = .{};
        var summary: a.ProgramInventorySummary = .{};
        if (system.programInventoryBegin(&cursor, &summary) != a.program_handle_ok) continue;
        while (true) {
            var tasks: [16]a.ProgramTaskSnapshot = undefined;
            var page: a.ProgramInventoryPageInfo = .{};
            if (system.programInventoryTasks(&cursor, &tasks, &page) != a.program_handle_ok or page.status == a.program_inventory_status_restart) continue :restart;
            if (page.returned > tasks.len) return false;
            for (tasks[0..page.returned]) |task| if (task.task_id == info.task_id and task.owner_instance_id == handle.instance_id and task.instance_generation == handle.instance_generation and task.state == 3) return true;
            if (page.has_more == 0) break;
        }
        system.sleepTicks(1);
    }
    return false;
}
fn finish(handle: *const a.ProgramJoinHandle) ?i32 {
    var code: i32 = -1;
    if (system.threadHandleJoin(handle, system.ticksFromMilliseconds(5000), &code) != a.thread_ok) return null;
    return code;
}
fn bspComputeContext() bool {
    context_go.store(0, .release);
    var handle: a.ProgramJoinHandle = .{};
    if (system.computeWorkerCreate(contextWorker, 0, 256 * 1024, &handle) != a.thread_ok) return false;
    const prepared = placement(&handle, 0, true) and adopted(&handle, 0, false);
    context_go.store(1, .release);
    const code = finish(&handle) orelse {
        _ = system.programExit(23, a.program_exit_reason_failed);
        while (true) system.sleepTicks(1);
    };
    return prepared and code == 0;
}
fn consumers(dev: *const r4os.r4dev.Context, cpu: u32, out: *Output) bool {
    var handles: [2]a.ProgramJoinHandle = .{ .{}, .{} };
    var live: [2]bool = .{false, false};
    var joined: [2]bool = .{false, false};
    var restore_epoch: ?u64 = null;
    var online_attempted = false;
    run_go.store(0, .release); run_entered.store(0, .release); release.store(0, .release);
    wait_go.store(0, .release); wait_entered.store(0, .release); observed = .{0} ** 4;
    if (system.notificationCreate(&notification) != a.notification_ok) return false;
    defer {
        release.store(1, .release); run_go.store(1, .release); wait_go.store(1, .release);
        _ = system.notificationNotify(notification, 1);
        var clean = true;
        for (&handles, 0..) |*handle, i| if (live[i] and !joined[i]) { clean = (finish(handle) != null) and clean; };
        if (!clean) {
            // Exact static worker state and module code stay resident until
            // ordinary terminal process cleanup has really stopped all peers.
            _ = system.programExit(23, a.program_exit_reason_failed);
            while (true) system.sleepTicks(1);
        }
        _ = system.notificationClose(notification);
        if (!online_attempted) if (restore_epoch) |epoch| {
            var restored: a.CpuLifecycleInfo = .{};
            const code = dev.cpuLifecycle(a.cpu_lifecycle_op_online, cpu, epoch, &restored);
            out.record("cpu_lifecycle_cleanup_online", "smp", 0, .{ .result = code, .info = restored });
        };
    }
    const entries = [_]a.ThreadEntryFn{ running, waiting };
    for (entries, 0..) |entry, i| {
        if (system.computeWorkerCreate(entry, 0, 256 * 1024, &handles[i]) != a.thread_ok) return false;
        live[i] = true;
        if (!placement(&handles[i], cpu, true) or !adopted(&handles[i], cpu, false)) return false;
    }
    run_go.store(1, .release); wait_go.store(1, .release);
    if (!waitAtomic(&run_entered) or !waitAtomic(&wait_entered) or !blocked(&handles[1])) return false;
    if (!placement(&handles[0], cpu, false) or !adopted(&handles[0], cpu, true) or
        !placement(&handles[1], cpu, false) or !adopted(&handles[1], cpu, false) or !blocked(&handles[1])) return false;
    var before: a.CpuLifecycleInfo = .{};
    if (!query(dev, cpu, &before)) return false;
    var guard = extern struct { info: a.CpuLifecycleInfo = .{}, tail: u64 = tail_value }{};
    guard.info.size = @sizeOf(@TypeOf(guard));
    const rc = dev.cpuLifecycle(a.cpu_lifecycle_op_offline, cpu, before.epoch, &guard.info);
    if (rc == a.cpu_lifecycle_ok) restore_epoch = before.epoch;
    out.record("cpu_lifecycle_offline", "smp", 0, .{ .result = rc, .info = guard.info });
    if (rc != a.cpu_lifecycle_ok or guard.tail != tail_value or guard.info.state != a.cpu_lifecycle_state_offline or
        guard.info.available_cpus + 1 != before.available_cpus or guard.info.tasks_migrated < 2 or
        guard.info.parked_epoch != before.epoch or guard.info.stopped_epoch != before.epoch or guard.info.irq_epoch != before.epoch) return false;
    // The ordinary notification, true join, module SIMD continuation and real
    // read-only device completion must progress with this AP still offline.
    release.store(1, .release);
    if (system.notificationNotify(notification, 1) != a.notification_ok) return false;
    for (&handles, 0..) |*handle, i| {
        const code = finish(handle) orelse return false;
        joined[i] = true;
        if (code != 0) return false;
    }
    var io: a.ProgramKernelNvmeCheck = .{};
    const io_rc = dev.kernelNvmeCheck(&io);
    out.record("cpu_lifecycle_io", "smp", 0, io);
    const io_ok = io_rc == 1 and io.status == a.kernel_nvme_check_status_passed;
    var online: a.CpuLifecycleInfo = .{};
    online_attempted = true;
    const online_rc = dev.cpuLifecycle(a.cpu_lifecycle_op_online, cpu, before.epoch, &online);
    out.record("cpu_lifecycle_online", "smp", 0, .{ .result = online_rc, .info = online });
    return io_ok and online_rc == a.cpu_lifecycle_ok and online.state == a.cpu_lifecycle_state_online and online.epoch == before.epoch + 1 and
        online.installed_epoch == online.epoch and online.available_cpus == before.available_cpus and online.capacity_generation > before.capacity_generation;
}
pub fn run(app: *r4os.App, out: *Output) i32 {
    system = app.system();
    const dev = app.devicesLowLevel() orelse return 2;
    devices = dev;
    if (!dev.hasFn("cpu_lifecycle") or !dev.hasFn("kernel_cpu_lifecycle_check")) { out.unavailable("smp", "CPU lifecycle provider unavailable"); return 2; }
    var info: a.CpuLifecycleInfo = .{};
    if (!query(&dev, 1, &info) or info.available_cpus < 3) { out.unavailable("smp", "native lifecycle check requires three available CPUs"); return 2; }
    if (!invalid(&dev, 1, info.epoch, out)) { out.message("smp", "SPECTRA CPU lifecycle header/epoch/IF contract: FAILED", false); return 1; }
    var guard = extern struct { report: a.ProgramKernelCpuLifecycleCheck = .{}, tail: u64 = tail_value }{};
    guard.report.size = @sizeOf(@TypeOf(guard));
    const rc = dev.kernelCpuLifecycleCheck(&guard.report);
    const n = guard.report;
    out.record("cpu_lifecycle_native", "smp", 0, n);
    const native_ok = rc == 1 and guard.tail == tail_value and n.status == a.cpu_lifecycle_check_status_passed and n.passed == a.cpu_lifecycle_check_case_all and
        n.failed == 0 and n.cleanup_errors == 0 and n.tasks_created == n.tasks_reaped and n.tasks_created == 5 and n.if_checks == 3 and
        n.new_epoch == n.old_epoch + 1 and n.parked_epoch == n.old_epoch and n.stopped_epoch == n.old_epoch and n.available_offline + 1 == n.available_before and n.available_after == n.available_before;
    if (!native_ok) { out.message("smp", "SPECTRA CPU lifecycle native: FAILED", false); return 1; }
    const ok = bspComputeContext() and consumers(&dev, 1, out);
    out.message("smp", if (ok) "SPECTRA CPU lifecycle: ok (native Busy/IF/TLB, real module YMM/wait migration, I/O and fresh epochs)" else "SPECTRA CPU lifecycle: FAILED", false);
    return if (ok) 0 else 1;
}

/// A headless shell may launch this audited module as a parallel background
/// instance. Reuse the existing explicit role0 foreground path, whose main
/// Task is permanently BSP-only; a transient hard-CPU0 policy is insufficient.
pub fn launch(app: *r4os.App, out: *Output) i32 {
    const sys = app.system();
    var identity: a.ProgramJoinHandle = .{};
    var info: a.ThreadPlacementInfo = .{};
    if (sys.threadCurrentHandle(&identity) != a.thread_ok or sys.threadPlacementGet(&identity, &info, &.{}) != a.thread_ok) return 1;
    if (info.flags & a.thread_placement_flag_parallel == 0) return run(app, out);
    system = sys;
    if (!placement(&identity, 0, true) or !adopted(&identity, 0, true)) return 1;
    var path_buffer: [96:0]u8 = .{0} ** 96;
    const path = std.fmt.bufPrintZ(&path_buffer, "C:\\TEMP\\CL{X:0>8}-{X:0>16}.OUT", .{ identity.instance_id, identity.instance_generation }) catch return 1;
    if (sys.exists(path)) { out.unavailable("smp", "CPU lifecycle foreground proof already exists"); return 1; }
    var terminal = false;
    defer if (terminal and sys.exists(path)) { _ = sys.fileDelete(path); };
    var arguments: [192:0]u8 = .{0} ** 192;
    const args = std.fmt.bufPrintZ(&arguments, "CHECK SMP /LIFECYCLEBSP:{s} /JSON", .{path}) catch return 1;
    const result = sys.programRun(@import("../route.zig").path, args);
    terminal = result == 0;
    if (!terminal) { out.record("cpu_lifecycle_foreground_launch", "smp", 0, .{ .result = result }); return 1; }
    // programRun acknowledges completion, not the child's exit code. Only the
    // child's success-only file, committed after all actual joins, is proof.
    var bytes: [64]u8 = undefined;
    const size = sys.fileRead(path, &bytes);
    const ok = size == proof_text.len and std.mem.eql(u8, bytes[0..proof_text.len], proof_text);
    out.record("cpu_lifecycle_foreground", "smp", 0, .{ .completed = terminal, .success_acknowledged = ok });
    return if (ok) 0 else 1;
}
pub fn foreground(app: *r4os.App, path: []const u8, out: *Output) i32 {
    if (path.len == 0 or path.len >= 96 or !std.mem.startsWith(u8, path, "C:\\TEMP\\CL")) return 2;
    var name: [96:0]u8 = .{0} ** 96;
    @memcpy(name[0..path.len], path);
    const code = run(app, out);
    if (code != 0) return code;
    const sys = app.system();
    if (sys.fileStreamBegin(&name, a.file_stream_open_create) != 0) return 1;
    if (sys.fileStreamWrite(&name, 0, proof_text, 0) != proof_text.len or sys.fileStreamFinish(&name, proof_text.len, 0) != 0) {
        _ = sys.fileStreamAbort(&name);
        return 1;
    }
    return 0;
}
