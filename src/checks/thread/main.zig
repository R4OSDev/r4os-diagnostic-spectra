const r4os = @import("r4os");

var global_sys: ?r4os.r4sys.Context = null;
var shared_counter: u64 = 0;
var exit_worker_arg: usize = 0;
var timeout_release: bool = false;
var worker_identity: r4os.abi.ProgramJoinHandle = .{};
var exit_peer_ready: bool = false;
var exit_notification: u64 = 0;

const dynamic_arg = "/DYNAMICTASKS";
const dynamic_concurrency: usize = 160;
const dynamic_churn_cycles: u32 = 10_000;
const inventory_restart_limit: u32 = 16;
const inventory_would_block_retry_limit: u32 = 64;
const baseline_stable_samples: u32 = 8;
const baseline_stable_sample_limit: u32 = 4096;
const global_memory_block_growth_limit: u64 = 16;
const global_memory_byte_growth_limit: u64 = 4 * 1024 * 1024;
var dynamic_release: bool = false;
var dynamic_started: [dynamic_concurrency]bool = .{false} ** dynamic_concurrency;
var dynamic_progress: [dynamic_concurrency]u32 = .{0} ** dynamic_concurrency;

const DynamicBaseline = struct {
    task_count: u32,
    main_task_id: u32,
    fpu_state_bytes: u32,
    fpu_task_state_count: u32,
    fpu_task_init_count: u64,
    fpu_task_state_bytes: u64,
    memory_active_blocks: u64,
    memory_error_blocks: u64,
    memory_physical_bytes: u64,
    memory_reserved_bytes: u64,
    memory_committed_bytes: u64,
    memory_free_physical_bytes: u64,
    memory_app_stack_blocks: u64,
    memory_r4x_owner_blocks: u64,
    memory_overflow: u32,
    instance_reserved_bytes: u64,
    instance_committed_bytes: u64,
    instance_resident_bytes: u64,
    instance_stack_reserved_bytes: u64,
    instance_stack_committed_bytes: u64,
};

pub fn r4_app_main(app: *r4os.App) i32 {
    var sys = app.system();
    const resources = app.resources();
    global_sys = sys;

    if (argsEqual(app.args(), "/PLACEMENT")) return @import("placement.zig").parent(app);
    if (argsEqual(app.args(), "/PLACEMENTBSP") or @import("std").mem.startsWith(u8, app.args(), "/PLACEMENTBSP:")) return @import("placement.zig").bsp(app);
    if (@import("std").mem.startsWith(u8, app.args(), "/PLACEMENTWORKER:")) return @import("placement.zig").child(app, app.args());

    if (argsEqual(app.args(), "/PROCESSEXIT")) return processExitProfile(&sys);
    if (argsEqual(app.args(), "/EXITMAIN")) return processExitChild(&sys, false);
    if (argsEqual(app.args(), "/EXITWORKER")) return processExitChild(&sys, true);

    sys.println("SPECTRA THREAD");
    if (!resources.available()) return fail(&sys, "SPECTRA THREAD resource facade missing");
    if (argsEqual(app.args(), dynamic_arg)) {
        const devices = app.devices() orelse return fail(&sys, "SPECTRA THREAD dynamic R4DEV facade missing");
        return dynamicTaskProfile(&sys, &devices);
    }

    const main_id = sys.threadCurrent();
    if (main_id == 0) return fail(&sys, "SPECTRA THREAD main id missing");
    var main_info: r4os.abi.ProgramThreadInfo = .{};
    if (sys.threadStatus(main_id, &main_info) != r4os.abi.thread_ok) return fail(&sys, "SPECTRA THREAD main status failed");
    if ((main_info.flags & r4os.abi.thread_flag_main) == 0) return fail(&sys, "SPECTRA THREAD main flag missing");
    var main_identity: r4os.abi.ProgramJoinHandle = .{};
    if (sys.threadCurrentHandle(&main_identity) != r4os.abi.thread_ok or
        !validJoinHandle(main_identity) or main_identity.thread_id != main_id or
        main_identity.instance_id != main_info.instance_id)
        return fail(&sys, "SPECTRA THREAD main identity missing");
    var repeated_identity: r4os.abi.ProgramJoinHandle = .{};
    sys.taskYield();
    if (sys.threadCurrentHandle(&repeated_identity) != r4os.abi.thread_ok or
        !sameIdentity(main_identity, repeated_identity))
        return fail(&sys, "SPECTRA THREAD main identity changed across yield");
    var wrong_generation = main_identity;
    wrong_generation.thread_generation += 1;
    var rejected_info: r4os.abi.ProgramThreadInfo = .{};
    if (sys.threadHandleStatus(&wrong_generation, &rejected_info) != r4os.abi.thread_error_not_found)
        return fail(&sys, "SPECTRA THREAD wrong generation accepted");
    sys.println("SPECTRA THREAD phase=main");

    var self_exit: i32 = 0;
    if (sys.threadJoin(main_id, 0, &self_exit) != r4os.abi.thread_error_self_join) return fail(&sys, "SPECTRA THREAD self join accepted");
    var invalid_id: u32 = 0;
    if (sys.threadCreateRaw(workerMain, 1, 0, 0x80000000, &invalid_id) != r4os.abi.thread_error_unsupported) return fail(&sys, "SPECTRA THREAD invalid flags accepted");

    var worker = switch (resources.createThread(workerMain, 7, 0)) {
        .handle => |handle| handle,
        .failure => return fail(&sys, "SPECTRA THREAD worker create failed"),
    };
    const worker_id = worker.handle.thread_id;
    const created_identity = worker.handle;
    const worker_info = switch (worker.status()) {
        .value => |info| info,
        .failure => return fail(&sys, "SPECTRA THREAD worker status failed"),
    };
    if ((worker_info.flags & r4os.abi.thread_flag_joinable) == 0 or worker_info.stack_reserved_bytes == 0) return fail(&sys, "SPECTRA THREAD worker contract failed");
    switch (worker.join(r4os.time_contract.timeoutForever())) {
        .exited => |code| if (code != 47) return fail(&sys, "SPECTRA THREAD worker exit mismatch"),
        else => return fail(&sys, "SPECTRA THREAD worker join failed"),
    }
    if (worker.valid() or @as(*volatile u64, &shared_counter).* != 21) return fail(&sys, "SPECTRA THREAD worker lifecycle mismatch");
    if (!sameIdentity(created_identity, worker_identity) or
        worker_identity.thread_generation == main_identity.thread_generation or
        worker_identity.instance_generation != main_identity.instance_generation)
        return fail(&sys, "SPECTRA THREAD worker identity differs from create handle");
    if (sys.threadHandleStatus(&worker_identity, &rejected_info) != r4os.abi.thread_error_not_found)
        return fail(&sys, "SPECTRA THREAD borrowed identity retained joined worker");
    sys.println("SPECTRA THREAD identity generation / yield / retirement: OK");
    switch (worker.join(r4os.time_contract.timeoutPoll())) {
        .failure => |raw| if (raw != r4os.abi.err_closed) return fail(&sys, "SPECTRA THREAD double join status mismatch"),
        else => return fail(&sys, "SPECTRA THREAD double join accepted"),
    }
    sys.println("SPECTRA THREAD phase=worker");

    var exit_worker = switch (resources.createThread(workerExitMain, 33, 128 * 1024)) {
        .handle => |handle| handle,
        .failure => return fail(&sys, "SPECTRA THREAD exit worker create failed"),
    };
    const exit_id = exit_worker.handle.thread_id;
    switch (exit_worker.join(r4os.time_contract.timeoutForever())) {
        .exited => |code| if (code != 93) return fail(&sys, "SPECTRA THREAD explicit exit mismatch"),
        else => return fail(&sys, "SPECTRA THREAD exit worker join failed"),
    }
    if (@as(*volatile usize, &exit_worker_arg).* != 33) return fail(&sys, "SPECTRA THREAD explicit exit arg mismatch");
    sys.println("SPECTRA THREAD phase=exit");

    @as(*volatile bool, &timeout_release).* = false;
    var timeout_worker = switch (resources.createThread(timeoutWorkerMain, 0, 0)) {
        .handle => |handle| handle,
        .failure => return fail(&sys, "SPECTRA THREAD timeout worker create failed"),
    };
    switch (timeout_worker.join(r4os.time_contract.timeoutPoll())) {
        .timed_out => {},
        else => return fail(&sys, "SPECTRA THREAD poll timeout missing"),
    }
    if (!timeout_worker.valid()) return fail(&sys, "SPECTRA THREAD timeout consumed handle");
    sys.println("SPECTRA THREAD phase=timeout-poll");
    @as(*volatile bool, &timeout_release).* = true;
    switch (timeout_worker.join(r4os.time_contract.timeoutForever())) {
        .exited => |code| if (code != 61) return fail(&sys, "SPECTRA THREAD timeout worker exit mismatch"),
        else => return fail(&sys, "SPECTRA THREAD timeout worker join failed"),
    }
    sys.println("SPECTRA THREAD phase=timeout-join");

    var stress: u32 = 0;
    while (stress < 80) : (stress += 1) {
        var handle = switch (resources.createThread(stressWorkerMain, stress, 0)) {
            .handle => |value| value,
            .failure => return fail(&sys, "SPECTRA THREAD stress create leaked slots"),
        };
        switch (handle.join(r4os.time_contract.timeoutForever())) {
            .exited => |code| if (code != @as(i32, @intCast(stress))) return fail(&sys, "SPECTRA THREAD stress exit mismatch"),
            else => return fail(&sys, "SPECTRA THREAD stress join failed"),
        }
        if ((stress + 1) % 20 == 0) {
            sys.write("SPECTRA THREAD phase=stress count=");
            sys.printU64(stress + 1);
            sys.println("");
        }
    }

    sys.write("SPECTRA THREAD main=");
    sys.printU64(main_id);
    sys.write(" worker=");
    sys.printU64(worker_id);
    sys.write(" exit=");
    sys.printU64(exit_id);
    sys.println("");
    sys.println("SPECTRA THREAD result: OK");
    return 0;
}

fn dynamicTaskProfile(sys: *r4os.r4sys.Context, devices: *const r4os.Devices) i32 {
    sys.println("SPECTRA THREAD dynamic begin");
    @as(*volatile bool, &dynamic_release).* = false;
    @memset(dynamic_started[0..], false);
    @memset(dynamic_progress[0..], 0);

    var handles: [dynamic_concurrency]r4os.abi.ProgramJoinHandle = .{r4os.abi.ProgramJoinHandle{}} ** dynamic_concurrency;
    var ids: [dynamic_concurrency]u32 = .{0} ** dynamic_concurrency;
    var task_ids: [dynamic_concurrency]u32 = .{0} ** dynamic_concurrency;
    var index: usize = 0;
    while (index < ids.len) : (index += 1) {
        const status = sys.threadCreateHandle(dynamicWorkerMain, index, 0, 0, &handles[index]);
        if (status != r4os.abi.thread_ok or !validJoinHandle(handles[index])) return fail(sys, "SPECTRA THREAD dynamic concurrent create failed");
        ids[index] = handles[index].thread_id;
        if (idSeen(ids[0..index], ids[index])) return fail(sys, "SPECTRA THREAD dynamic duplicate concurrent thread id");
        if ((index + 1) % 32 == 0) {
            sys.write("SPECTRA THREAD dynamic create progress=");
            sys.printU64(index + 1);
            sys.println("");
        }
    }

    var wait_rounds: u32 = 0;
    while (startedCount() != dynamic_concurrency and wait_rounds < 20_000) : (wait_rounds += 1) {
        sys.taskYield();
        if (wait_rounds != 0 and wait_rounds % 1000 == 0) {
            sys.write("SPECTRA THREAD dynamic start progress rounds=");
            sys.printU64(wait_rounds);
            sys.write(" started=");
            sys.printU64(startedCount());
            sys.println("");
        }
    }
    if (startedCount() != dynamic_concurrency) return fail(sys, "SPECTRA THREAD dynamic concurrent start timeout");
    sys.println("SPECTRA THREAD dynamic phase=started");

    var runnable: u32 = 0;
    var blocked: u32 = 0;
    index = 0;
    while (index < ids.len) : (index += 1) {
        var info: r4os.abi.ProgramThreadInfo = .{};
        if (sys.threadHandleStatus(&handles[index], &info) != r4os.abi.thread_ok) return fail(sys, "SPECTRA THREAD dynamic live status failed");
        if (info.task_id == 0 or idSeen(task_ids[0..index], info.task_id)) return fail(sys, "SPECTRA THREAD dynamic duplicate concurrent task id");
        task_ids[index] = info.task_id;
        if (info.state == r4os.abi.thread_state_ready or info.state == r4os.abi.thread_state_running) runnable += 1 else blocked += 1;
    }

    @as(*volatile bool, &dynamic_release).* = true;
    var concurrent_post_join: u32 = 0;
    index = 0;
    while (index < ids.len) : (index += 1) {
        var exit_code: i32 = -1;
        if (sys.threadHandleJoin(&handles[index], r4os.abi.thread_wait_forever, &exit_code) != r4os.abi.thread_ok or
            exit_code != @as(i32, @intCast(index & 0x7FFF))) return fail(sys, "SPECTRA THREAD dynamic concurrent join failed");
        if (!joinedThreadIsGone(sys, ids[index])) return fail(sys, "SPECTRA THREAD dynamic concurrent joined id still addressable");
        concurrent_post_join += 1;
        if (@as(*volatile u32, &dynamic_progress[index]).* == 0) return fail(sys, "SPECTRA THREAD dynamic worker made no progress");
        if (index != 0 and index % 20 == 0) {
            sys.write("SPECTRA THREAD dynamic join progress=");
            sys.printU64(index);
            sys.println("");
        }
    }
    sys.println("SPECTRA THREAD dynamic phase=joined");

    // The 160-thread phase is also the allocator/registry warm phase. Capture
    // the baseline only after every ProgramThread was joined and its public ID
    // stopped resolving. Repeated identical ownership samples avoid measuring
    // a transient service task, while the later global-byte comparison remains
    // bounded rather than demanding flakey whole-system equality.
    const main_thread_id = sys.threadCurrent();
    if (main_thread_id == 0) return fail(sys, "SPECTRA THREAD dynamic main thread id missing");
    var main_info: r4os.abi.ProgramThreadInfo = .{};
    if (sys.threadStatus(main_thread_id, &main_info) != r4os.abi.thread_ok or main_info.instance_id == 0 or main_info.task_id == 0)
        return fail(sys, "SPECTRA THREAD dynamic main thread baseline missing");
    const baseline_before = captureStableBaseline(sys, devices, main_info.instance_id) orelse
        return fail(sys, "SPECTRA THREAD dynamic warm baseline unstable");
    sys.write("SPECTRA THREAD dynamic warm joined=");
    sys.printU64(dynamic_concurrency);
    sys.write(" postJoinGone=");
    sys.printU64(concurrent_post_join);
    sys.println(" baseline=captured");

    var churn: u32 = 0;
    var churn_post_join: u32 = 0;
    while (churn < dynamic_churn_cycles) : (churn += 1) {
        if (churn != 0 and churn % 1000 == 0) {
            sys.write("SPECTRA THREAD dynamic churn progress=");
            sys.printU64(churn);
            sys.println("");
        }
        var handle: r4os.abi.ProgramJoinHandle = .{};
        if (sys.threadCreateHandle(stressWorkerMain, churn & 0x7FFF, 0, 0, &handle) != r4os.abi.thread_ok or !validJoinHandle(handle))
            return fail(sys, "SPECTRA THREAD dynamic churn create failed");
        const id = handle.thread_id;
        var live_info: r4os.abi.ProgramThreadInfo = .{};
        if (sys.threadHandleStatus(&handle, &live_info) != r4os.abi.thread_ok or
            live_info.task_id == 0 or
            live_info.task_id == baseline_before.main_task_id or
            live_info.stack_reserved_bytes == 0 or
            live_info.stack_committed_bytes == 0) return fail(sys, "SPECTRA THREAD dynamic churn live identity invalid");
        var exit_code: i32 = -1;
        if (sys.threadHandleJoin(&handle, r4os.abi.thread_wait_forever, &exit_code) != r4os.abi.thread_ok or
            exit_code != @as(i32, @intCast(churn & 0x7FFF))) return fail(sys, "SPECTRA THREAD dynamic churn join failed");
        if (!joinedThreadIsGone(sys, id)) return fail(sys, "SPECTRA THREAD dynamic churn joined id still addressable");
        churn_post_join += 1;
    }

    const baseline_after = captureStableBaseline(sys, devices, main_info.instance_id) orelse
        return fail(sys, "SPECTRA THREAD dynamic final baseline unstable");
    if (!dynamicBaselineMatches(baseline_before, baseline_after)) {
        printDynamicBaseline(sys, baseline_before, baseline_after);
        return fail(sys, "SPECTRA THREAD dynamic baseline drift");
    }

    sys.write("SPECTRA THREAD dynamic concurrency live=");
    sys.printU64(dynamic_concurrency);
    sys.write(" runnable=");
    sys.printU64(runnable);
    sys.write(" blocked=");
    sys.printU64(blocked);
    sys.println(" stable=OK");
    printDynamicBaseline(sys, baseline_before, baseline_after);
    sys.write("SPECTRA THREAD dynamic churn=");
    sys.printU64(dynamic_churn_cycles);
    sys.write(" createReap=OK postJoinGone=");
    sys.printU64(churn_post_join);
    sys.println(" baseline=OK");
    sys.println("SPECTRA THREAD dynamic result: OK");
    sys.println("SPECTRA THREAD result: OK");
    return 0;
}

fn captureStableBaseline(sys: *r4os.r4sys.Context, devices: *const r4os.Devices, instance_id: u32) ?DynamicBaseline {
    var previous = captureBaseline(sys, devices, instance_id) orelse return null;
    var stable_samples: u32 = 0;
    var attempts: u32 = 0;
    while (attempts < baseline_stable_sample_limit) : (attempts += 1) {
        sys.taskYield();
        const current = captureBaseline(sys, devices, instance_id) orelse return null;
        if (dynamicOwnershipSnapshotEqual(previous, current)) {
            stable_samples += 1;
            if (stable_samples == baseline_stable_samples) return current;
        } else {
            stable_samples = 0;
        }
        previous = current;
    }
    return null;
}

fn captureBaseline(sys: *r4os.r4sys.Context, devices: *const r4os.Devices, instance_id: u32) ?DynamicBaseline {
    const performance = devices.performance().summary() orelse return null;
    const memory = devices.memory().summary() orelse return null;
    const instance = findProgramInstance(sys, instance_id) orelse return null;
    var main_info: r4os.abi.ProgramThreadInfo = .{};
    if (sys.threadStatus(0, &main_info) != r4os.abi.thread_ok or main_info.instance_id != instance_id or main_info.task_id == 0) return null;
    return .{
        .task_count = performance.task_count,
        .main_task_id = main_info.task_id,
        .fpu_state_bytes = performance.fpu_state_bytes,
        .fpu_task_state_count = performance.fpu_task_state_count,
        .fpu_task_init_count = performance.fpu_task_init_count,
        .fpu_task_state_bytes = performance.fpu_task_state_bytes,
        .memory_active_blocks = memory.active_blocks,
        .memory_error_blocks = memory.error_blocks,
        .memory_physical_bytes = memory.physical_bytes,
        .memory_reserved_bytes = memory.reserved_bytes,
        .memory_committed_bytes = memory.committed_bytes,
        .memory_free_physical_bytes = memory.free_physical_bytes,
        .memory_app_stack_blocks = memory.by_kind[r4os.abi.memory_kind_app_stack],
        .memory_r4x_owner_blocks = memory.by_owner[r4os.abi.memory_owner_r4x_instance],
        .memory_overflow = memory.overflow,
        .instance_reserved_bytes = instance.memory_reserved_bytes,
        .instance_committed_bytes = instance.memory_committed_bytes,
        .instance_resident_bytes = instance.memory_resident_bytes,
        .instance_stack_reserved_bytes = instance.stack_reserved_bytes,
        .instance_stack_committed_bytes = instance.stack_committed_bytes,
    };
}

fn findProgramInstance(sys: *r4os.r4sys.Context, instance_id: u32) ?r4os.abi.ProgramInstanceInfo {
    var attempt: u32 = 0;
    restart: while (attempt < inventory_restart_limit) : (attempt += 1) {
        var cursor: r4os.abi.ProgramInventoryCursor = .{};
        var summary: r4os.abi.ProgramInventorySummary = .{};
        if (!beginProgramInventory(sys, &cursor, &summary)) return null;
        while (true) {
            var entries: [@as(usize, r4os.abi.program_inventory_page_max)]r4os.abi.ProgramInstanceSnapshot = undefined;
            var page: r4os.abi.ProgramInventoryPageInfo = .{};
            if (!readProgramInventoryPage(sys, &cursor, entries[0..], &page)) return null;
            if (page.status == r4os.abi.program_inventory_status_restart) continue :restart;
            if (page.returned > entries.len or page.snapshot_generation != cursor.snapshot_generation) return null;
            for (entries[0..@intCast(page.returned)]) |entry| {
                if (entry.info.id == instance_id) return entry.info;
            }
            if (page.status == r4os.abi.program_inventory_status_complete) return null;
            if (page.status != r4os.abi.program_inventory_status_more or page.returned == 0) return null;
        }
    }
    return null;
}

fn beginProgramInventory(
    sys: *r4os.r4sys.Context,
    cursor: *r4os.abi.ProgramInventoryCursor,
    summary: *r4os.abi.ProgramInventorySummary,
) bool {
    var retry: u32 = 0;
    while (retry <= inventory_would_block_retry_limit) : (retry += 1) {
        cursor.* = .{};
        summary.* = .{};
        const status = sys.programInventoryBegin(cursor, summary);
        if (status == r4os.abi.program_handle_ok) return true;
        if (status != r4os.abi.program_handle_error_would_block or retry == inventory_would_block_retry_limit)
            return false;
        sys.sleepTicks(1);
    }
    return false;
}

fn readProgramInventoryPage(
    sys: *r4os.r4sys.Context,
    cursor: *r4os.abi.ProgramInventoryCursor,
    entries: []r4os.abi.ProgramInstanceSnapshot,
    page: *r4os.abi.ProgramInventoryPageInfo,
) bool {
    var retry: u32 = 0;
    while (retry <= inventory_would_block_retry_limit) : (retry += 1) {
        const cursor_before = cursor.*;
        page.* = .{};
        const status = sys.programInventoryPrograms(cursor, entries, page);
        if (status == r4os.abi.program_handle_ok) return true;
        cursor.* = cursor_before;
        page.* = .{};
        if (status != r4os.abi.program_handle_error_would_block or retry == inventory_would_block_retry_limit)
            return false;
        sys.sleepTicks(1);
    }
    return false;
}

fn joinedThreadIsGone(sys: *r4os.r4sys.Context, thread_id: u32) bool {
    // R4DEV exposes memory-block/VM aggregates, but no kernel-heap live/used
    // allocation counter (memory_kind_kernel_heap is only heap backing). The
    // public retirement proof is therefore threadStatus(NOT_FOUND): the kernel
    // keeps a ProgramThread whose heap free failed linked and status-visible.
    var stale_info: r4os.abi.ProgramThreadInfo = .{};
    return sys.threadStatus(thread_id, &stale_info) == r4os.abi.thread_error_not_found;
}

fn validJoinHandle(handle: r4os.abi.ProgramJoinHandle) bool {
    return handle.thread_id != 0 and
        handle.instance_id != 0 and
        handle.thread_generation != 0 and
        handle.instance_generation != 0 and
        handle.reserved == 0;
}

fn sameIdentity(a: r4os.abi.ProgramJoinHandle, b: r4os.abi.ProgramJoinHandle) bool {
    return a.thread_id == b.thread_id and a.instance_id == b.instance_id and
        a.thread_generation == b.thread_generation and a.instance_generation == b.instance_generation and
        a.reserved == b.reserved;
}

fn idSeen(values: []const u32, wanted: u32) bool {
    for (values) |value| {
        if (value == wanted) return true;
    }
    return false;
}

fn dynamicOwnershipSnapshotEqual(a: DynamicBaseline, b: DynamicBaseline) bool {
    return a.task_count == b.task_count and
        a.main_task_id == b.main_task_id and
        a.fpu_task_state_count == b.fpu_task_state_count and
        a.memory_error_blocks == b.memory_error_blocks and
        a.memory_overflow == b.memory_overflow and
        a.instance_reserved_bytes == b.instance_reserved_bytes and
        a.instance_committed_bytes == b.instance_committed_bytes and
        a.instance_resident_bytes == b.instance_resident_bytes and
        a.instance_stack_reserved_bytes == b.instance_stack_reserved_bytes and
        a.instance_stack_committed_bytes == b.instance_stack_committed_bytes;
}

fn dynamicBaselineMatches(before: DynamicBaseline, after: DynamicBaseline) bool {
    const expected_fpu_bytes = @as(u64, dynamic_churn_cycles) * @as(u64, before.fpu_state_bytes);
    return before.fpu_state_bytes != 0 and
        before.task_count == after.task_count and
        before.main_task_id == after.main_task_id and
        before.fpu_task_state_count == after.fpu_task_state_count and
        after.fpu_task_init_count -| before.fpu_task_init_count >= dynamic_churn_cycles and
        after.fpu_task_state_bytes -| before.fpu_task_state_bytes >= expected_fpu_bytes and
        before.memory_error_blocks == after.memory_error_blocks and
        before.memory_overflow == 0 and
        after.memory_overflow == 0 and
        before.instance_reserved_bytes == after.instance_reserved_bytes and
        before.instance_committed_bytes == after.instance_committed_bytes and
        before.instance_resident_bytes == after.instance_resident_bytes and
        before.instance_stack_reserved_bytes == after.instance_stack_reserved_bytes and
        before.instance_stack_committed_bytes == after.instance_stack_committed_bytes and
        growthWithin(before.memory_app_stack_blocks, after.memory_app_stack_blocks, global_memory_block_growth_limit) and
        growthWithin(before.memory_r4x_owner_blocks, after.memory_r4x_owner_blocks, global_memory_block_growth_limit) and
        growthWithin(before.memory_active_blocks, after.memory_active_blocks, global_memory_block_growth_limit) and
        growthWithin(before.memory_physical_bytes, after.memory_physical_bytes, global_memory_byte_growth_limit) and
        growthWithin(before.memory_reserved_bytes, after.memory_reserved_bytes, global_memory_byte_growth_limit) and
        growthWithin(before.memory_committed_bytes, after.memory_committed_bytes, global_memory_byte_growth_limit) and
        dropWithin(before.memory_free_physical_bytes, after.memory_free_physical_bytes, global_memory_byte_growth_limit);
}

fn growthWithin(before: u64, after: u64, limit: u64) bool {
    return after <= before or after - before <= limit;
}

fn dropWithin(before: u64, after: u64, limit: u64) bool {
    return after >= before or before - after <= limit;
}

fn printDynamicBaseline(sys: *r4os.r4sys.Context, before: DynamicBaseline, after: DynamicBaseline) void {
    sys.write("SPECTRA THREAD dynamic baseline task=");
    printPair(sys, before.task_count, after.task_count);
    sys.write(" fpu=");
    printPair(sys, before.fpu_task_state_count, after.fpu_task_state_count);
    sys.write(" fpuInitDelta=");
    sys.printU64(after.fpu_task_init_count -| before.fpu_task_init_count);
    sys.write(" fpuBytesDelta=");
    sys.printU64(after.fpu_task_state_bytes -| before.fpu_task_state_bytes);
    sys.println("");
    sys.write("SPECTRA THREAD dynamic memory instanceReserved=");
    printPair(sys, before.instance_reserved_bytes, after.instance_reserved_bytes);
    sys.write(" instanceCommitted=");
    printPair(sys, before.instance_committed_bytes, after.instance_committed_bytes);
    sys.write(" instanceResident=");
    printPair(sys, before.instance_resident_bytes, after.instance_resident_bytes);
    sys.write(" stackReserved=");
    printPair(sys, before.instance_stack_reserved_bytes, after.instance_stack_reserved_bytes);
    sys.write(" stackCommitted=");
    printPair(sys, before.instance_stack_committed_bytes, after.instance_stack_committed_bytes);
    sys.println(" exact=OK");
    sys.write("SPECTRA THREAD dynamic memory global appStack=");
    printPair(sys, before.memory_app_stack_blocks, after.memory_app_stack_blocks);
    sys.write(" r4xOwner=");
    printPair(sys, before.memory_r4x_owner_blocks, after.memory_r4x_owner_blocks);
    sys.write(" blocks=");
    printPair(sys, before.memory_active_blocks, after.memory_active_blocks);
    sys.write(" physical=");
    printPair(sys, before.memory_physical_bytes, after.memory_physical_bytes);
    sys.write(" reserved=");
    printPair(sys, before.memory_reserved_bytes, after.memory_reserved_bytes);
    sys.write(" committed=");
    printPair(sys, before.memory_committed_bytes, after.memory_committed_bytes);
    sys.println(" drift=bounded");
}

fn printPair(sys: *r4os.r4sys.Context, before: anytype, after: @TypeOf(before)) void {
    sys.printU64(@intCast(before));
    sys.write("/");
    sys.printU64(@intCast(after));
}

fn dynamicWorkerMain(arg: u64) callconv(.c) i32 {
    var sys = global_sys orelse return 100;
    const index: usize = @intCast(arg);
    if (index >= dynamic_concurrency) return 101;
    @as(*volatile bool, &dynamic_started[index]).* = true;
    while (!@as(*volatile bool, &dynamic_release).*) {
        @as(*volatile u32, &dynamic_progress[index]).* +%= 1;
        switch (index & 3) {
            0 => sys.taskYield(),
            1 => sys.sleepTicks(1),
            2 => sys.sleepTicks(2),
            else => {
                var spin: u32 = 0;
                while (spin < 256) : (spin += 1) @as(*volatile u32, &dynamic_progress[index]).* +%= 1;
                sys.taskYield();
            },
        }
    }
    return @intCast(index & 0x7FFF);
}

fn startedCount() usize {
    var count: usize = 0;
    var index: usize = 0;
    while (index < dynamic_started.len) : (index += 1) {
        if (@as(*volatile bool, &dynamic_started[index]).*) count += 1;
    }
    return count;
}

fn argsEqual(args: []const u8, expected: []const u8) bool {
    if (args.len != expected.len) return false;
    for (args, expected) |a, b| {
        const folded = if (a >= 'a' and a <= 'z') a - ('a' - 'A') else a;
        if (folded != b) return false;
    }
    return true;
}

fn processExitProfile(sys: *r4os.r4sys.Context) i32 {
    const a = r4os.abi;
    // Invalid admission must not initiate teardown of this observer.
    if (sys.programExit(99, a.program_exit_reason_killed) != a.thread_error_invalid)
        return fail(sys, "SPECTRA THREAD process exit invalid reason accepted");
    const saved_flags = asm volatile ("pushfq; popq %[value]"
        : [value] "=r" (-> u64),
    );
    asm volatile ("cli" ::: .{ .memory = true });
    const critical_result = sys.programExit(99, a.program_exit_reason_failed);
    if (saved_flags & (1 << 9) != 0) asm volatile ("sti" ::: .{ .memory = true });
    if (critical_result != a.thread_error_busy)
        return fail(sys, "SPECTRA THREAD process exit critical context accepted");
    var ordinary: a.ProgramJoinHandle = .{};
    var ordinary_result: i32 = 0;
    if (sys.threadCreateHandle(workerExitMain, 33, 0, 0, &ordinary) != a.thread_ok or
        sys.threadHandleJoin(&ordinary, sys.monotonicHz() * 5, &ordinary_result) != a.thread_ok or ordinary_result != 93)
        return fail(sys, "SPECTRA THREAD ordinary thread exit changed");
    sys.println("SPECTRA THREAD process exit admission / thread-only exit: OK");
    var path: [1024]u8 = undefined;
    const len = sys.programModulePath(&path);
    if (len <= 0 or len >= path.len) return fail(sys, "SPECTRA THREAD process exit path missing");
    path[@intCast(len)] = 0;
    for ([_][*:0]const u8{ "/EXITMAIN", "/EXITWORKER" }, 0..) |args, i| {
        var handle: a.ProgramProcessHandle = .{};
        if (sys.programSpawnHandle(@ptrCast(&path), @import("../../route.zig").arguments("THREAD", args).ptr(), .console, &handle) != a.program_handle_ok)
            return fail(sys, "SPECTRA THREAD process exit spawn failed");
        var completion: a.ProgramProcessCompletion = .{};
        const timeout = sys.monotonicHz() * 5;
        if (sys.programHandleWait(&handle, timeout, &completion) != a.program_handle_ok) {
            _ = sys.programHandleKill(&handle);
            return fail(sys, "SPECTRA THREAD process exit completion timed out");
        }
        const code: i32 = if (i == 0) -71 else -72;
        const reason: u8 = if (i == 0) a.program_exit_reason_natural else a.program_exit_reason_failed;
        if (completion.exit_code != code or completion.exit_reason != reason)
            return fail(sys, "SPECTRA THREAD process exit completion differs");
        // Ready completion follows exact peer/Task/resource retirement.
        if (sys.programHandleReap(&handle, &completion) != a.program_handle_ok)
            return fail(sys, "SPECTRA THREAD process exit reap failed");
        sys.println(if (i == 0) "SPECTRA THREAD process exit main / peers retired: OK" else "SPECTRA THREAD process exit worker / peers retired: OK");
    }
    sys.println("SPECTRA THREAD process exit result: OK");
    return 0;
}

fn processExitChild(sys: *r4os.r4sys.Context, from_worker: bool) i32 {
    const a = r4os.abi;
    exit_peer_ready = false;
    if (sys.notificationCreate(&exit_notification) != a.notification_ok)
        return fail(sys, "SPECTRA THREAD process exit notification failed");
    var peer: a.ProgramJoinHandle = .{};
    if (sys.threadCreateHandle(processExitPeer, 0, 0, 0, &peer) != a.thread_ok)
        return fail(sys, "SPECTRA THREAD process exit peer failed");
    while (!@atomicLoad(bool, &exit_peer_ready, .acquire)) sys.taskYield();
    if (!from_worker) {
        _ = sys.programExit(-71, a.program_exit_reason_natural);
        return fail(sys, "SPECTRA THREAD process exit main returned");
    }
    var worker: a.ProgramJoinHandle = .{};
    if (sys.threadCreateHandle(processExitWorker, 0, 0, 0, &worker) != a.thread_ok)
        return fail(sys, "SPECTRA THREAD process exit worker failed");
    _ = sys.notificationWait(exit_notification, 0, a.thread_wait_forever);
    return fail(sys, "SPECTRA THREAD process exit main survived worker");
}
fn processExitPeer(_: u64) callconv(.c) i32 {
    var sys = global_sys orelse return 1;
    var identity: r4os.abi.ProgramJoinHandle = .{};
    const placement: r4os.abi.ThreadPlacementRequest = .{ .work_class = r4os.abi.thread_placement_class_batch, .preferred_cpu = 0 };
    if (sys.threadCurrentHandle(&identity) != r4os.abi.thread_ok or sys.threadPlacementSet(&identity, &placement, &.{1}) != r4os.abi.thread_ok) return 1;
    @atomicStore(bool, &exit_peer_ready, true, .release);
    _ = sys.notificationWait(exit_notification, 0, r4os.abi.thread_wait_forever);
    return fail(&sys, "SPECTRA THREAD process exit peer survived");
}
fn processExitWorker(_: u64) callconv(.c) i32 {
    var sys = global_sys orelse return 1;
    _ = sys.programExit(-72, r4os.abi.program_exit_reason_failed);
    return fail(&sys, "SPECTRA THREAD process exit worker returned");
}

fn workerMain(arg: u64) callconv(.c) i32 {
    var sys = global_sys orelse return 10;
    var self: r4os.abi.ProgramThreadInfo = .{};
    if (sys.threadStatus(0, &self) != r4os.abi.thread_ok) return 11;
    if (sys.threadCurrentHandle(&worker_identity) != r4os.abi.thread_ok or
        !validJoinHandle(worker_identity) or worker_identity.thread_id != self.thread_id) return 12;
    var i: usize = 0;
    while (i < arg) : (i += 1) {
        @as(*volatile u64, &shared_counter).* += 3;
        sys.sleepTicks(1);
    }
    return 40 + @as(i32, @intCast(arg));
}

fn workerExitMain(arg: u64) callconv(.c) i32 {
    var sys = global_sys orelse return 20;
    @as(*volatile usize, &exit_worker_arg).* = arg;
    sys.threadExit(60 + @as(i32, @intCast(arg)));
}

fn timeoutWorkerMain(_: u64) callconv(.c) i32 {
    var sys = global_sys orelse return 21;
    while (!@as(*volatile bool, &timeout_release).*) sys.taskYield();
    return 61;
}

fn stressWorkerMain(arg: u64) callconv(.c) i32 {
    return @intCast(arg);
}

fn fail(sys: *r4os.r4sys.Context, msg: []const u8) i32 {
    sys.println(msg);
    sys.println("SPECTRA THREAD result: FAILED");
    return 1;
}
