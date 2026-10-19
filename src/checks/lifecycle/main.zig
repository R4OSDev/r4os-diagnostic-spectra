const route = @import("../../route.zig");
const r4os = @import("r4os");

const owner_r4x_instance: u8 = 3;
const kind_virtual_range: u8 = 4;
const kind_program_image: u8 = 5;
const kind_app_stack: u8 = 7;
const program_storage_arg = "/PROGRAMSTORAGE";
const program_registry_arg = "/PROGRAMREGISTRY";
const program_lifecycle_arg = "/PROGRAMLIFECYCLE";
const console_wait_arg = "/CONSOLEWAIT";
const console_wait_fixture_arg = "/CONSOLEWAITFIXTURE";
const program_inventory_arg = "/PROGRAMINVENTORY";
const dynamic_stress_arg = "/DYNAMICSTRESS";
const dynamic_stress_quick_arg = "/Q";
const dynamic_thread_hold_arg = "/DYNAMICTHREADHOLD";
const dynamic_churn_hold_arg = "/DYNAMICCHURNHOLD";
const lifecycle_foreground_arg = "/LIFECYCLEFG";
const lifecycle_exit_arg = "/LIFECYCLEEXIT";
const lifecycle_hold_arg = "/LIFECYCLEHOLD";
const lifecycle_host_arg = "/LIFECYCLEHOST";
const lifecycle_thread_exit_arg = "/LIFECYCLETHREADEXIT";
const gui_payload_hold_arg = "/GUIPAYLOADHOLD";
const gui_raster_chain_hold_arg = "/GUIRASTERCHAINHOLD";
const gui_frame_hold_arg = "/GUIFRAMEHOLD";
const registry_hold_arg = "/REGISTRYHOLD";
const app_heap_path = "C:\\R4OS\\SOFTWARE\\TERMINAL\\DIAG\\APPHEAPD.R4X";
const cstart_path = "C:\\R4OS\\SOFTWARE\\TERMINAL\\DIAG\\CSTARTD.R4X";
const cleanup_path = route.path;
const service_path = "C:\\R4OS\\SOFTWARE\\TERMINAL\\DIAG\\SVCAPPD.R4X";
const async_io_path = route.path;
const stall_service_name = "SVCSTALL";
const kill_wait_arg = "/KILLWAIT";
const churn_cycles: u32 = 18;
const kill_wait_cycles: u32 = 72;
const registry_concurrency_target: usize = 24;
const registry_hold_capacity: usize = 40;
const inventory_hold_count: usize = 80;
const inventory_restart_hold_count: usize = inventory_hold_count + 1;
// Acceptance floors for this diagnostic fixture, never runtime capacities.
const dynamic_stress_program_floor: usize = 128;
const dynamic_stress_cycle_floor: u32 = 10_000;
const dynamic_stress_quick_cycle_floor: u32 = 1_000;
const dynamic_stress_quick_settle_ticks: u32 = 2_000;
const dynamic_stress_full_settle_ticks: u32 = 10_000;
const dynamic_stress_fixture_kinds: usize = 5;
const dynamic_stress_handle_retry_limit: u32 = 64;
const inventory_handle_capacity: usize = dynamic_stress_program_floor;
const dynamic_stress_child_count: usize = 26;
const dynamic_stress_thread_child_count: usize = 26;
const dynamic_stress_completion_count: usize = dynamic_stress_program_floor + dynamic_stress_child_count;
// Production SSH/RDP traffic uses short-lived ownerless r4x-async-io Tasks.
// Task metadata and the eight-entry guarded-stack cache may lag within the
// concurrently admitted SSH workers. A separately bounded service VM range
// covers a TCP/RDP socket buffer crossing the same inventory sample.
const dynamic_stress_admin_task_slack: u64 = 8;
const dynamic_stress_admin_bytes_per_task: u64 = 64 * 1024;
const dynamic_stress_admin_active_blocks_per_task: u64 = 4;
const dynamic_stress_admin_service_vm_block_slack: u64 = 2;
const dynamic_stress_admin_service_vm_byte_slack: u64 = 128 * 1024;
const dynamic_stress_console_count: usize = 104;
const dynamic_stress_gui_count: usize = 25;
const dynamic_stress_service_count: usize = 25;
const inventory_page_capacity: usize = 7;
const inventory_restart_limit: u32 = 16;
const inventory_would_block_retry_limit: u32 = 64;
const inventory_boundary_mask_all: u16 = (1 << 9) - 1;
const inventory_boundaries = [_]usize{ 15, 16, 17, 31, 32, 33, 63, 64, 65 };
const task_state_blocked: u32 = 3;
const lifecycle_history_capacity: u32 = 16;
const lifecycle_ring_count: usize = 24;
const cleanup_lifecycle_timeout_ms: u64 = 10_000;
const lifecycle_ring_args = [_][*:0]const u8{
    "/LIFECYCLEEXIT -1 32",  "/LIFECYCLEEXIT 101 33", "/LIFECYCLEEXIT 102 34", "/LIFECYCLEEXIT 103 35",
    "/LIFECYCLEEXIT -2 36",  "/LIFECYCLEEXIT 105 37", "/LIFECYCLEEXIT 106 38", "/LIFECYCLEEXIT 107 39",
    "/LIFECYCLEEXIT -9 40",  "/LIFECYCLEEXIT 109 41", "/LIFECYCLEEXIT 110 42", "/LIFECYCLEEXIT 111 43",
    "/LIFECYCLEEXIT 112 44", "/LIFECYCLEEXIT 113 45", "/LIFECYCLEEXIT 114 46", "/LIFECYCLEEXIT 115 47",
    "/LIFECYCLEEXIT 116 48", "/LIFECYCLEEXIT 117 49", "/LIFECYCLEEXIT 118 50", "/LIFECYCLEEXIT 119 51",
    "/LIFECYCLEEXIT 120 52", "/LIFECYCLEEXIT 121 53", "/LIFECYCLEEXIT 122 54", "/LIFECYCLEEXIT 123 55",
};
const lifecycle_ring_codes = [_]i32{ -1, 101, 102, 103, -2, 105, 106, 107, -9, 109, 110, 111, 112, 113, 114, 115, 116, 117, 118, 119, 120, 121, 122, 123 };
const lifecycle_reap_order = [_]usize{ 7, 0, 23, 4, 19, 2, 15, 9, 21, 1, 12, 6, 18, 3, 22, 5, 16, 8, 20, 10, 14, 11, 17, 13 };
const dynamic_churn_exit_args = [_][*:0]const u8{
    "/LIFECYCLEEXIT -9 0",  "/LIFECYCLEEXIT -2 0",  "/LIFECYCLEEXIT -1 0",  "/LIFECYCLEEXIT 101 0",
    "/LIFECYCLEEXIT 107 0", "/LIFECYCLEEXIT 113 0", "/LIFECYCLEEXIT 119 0", "/LIFECYCLEEXIT 123 0",
};
const dynamic_churn_exit_codes = [_]i32{ -9, -2, -1, 101, 107, 113, 119, 123 };
const legacy_canary_byte: u8 = 0xA5;
const gui_raster_chain_tile_width: u32 = 128;
const gui_raster_chain_tile_height: u32 = 128;
const gui_raster_chain_tile_count: u32 = 6;
const gui_raster_chain_pixels = [_]u32{0x0031_6AC5} ** (gui_raster_chain_tile_width * gui_raster_chain_tile_height);
const gui_payload_pixels = [_]u32{
    0x0011_2233, 0x0044_5566,
    0x0077_8899, 0x00AA_BBCC,
};

var dynamic_hold_sys: ?r4os.r4sys.Context = null;
var dynamic_hold_release: bool = false;

const FrozenProgramRegistrySummaryV1 = extern struct {
    version: u32 = 1,
    size: u32 = 160,
    chunk_slots: u32 = 0,
    chunk_count: u32 = 0,
    slot_capacity: u32 = 0,
    free_slots: u32 = 0,
    reserved_slots: u32 = 0,
    live_slots: u32 = 0,
    done_slots: u32 = 0,
    retiring_slots: u32 = 0,
    pinned_slots: u32 = 0,
    warm_chunks: u32 = 0,
    last_admission_error: i32 = 0,
    flags: u32 = 0,
    peak_chunks: u64 = 0,
    peak_live: u64 = 0,
    growth_attempts: u64 = 0,
    growth_failures: u64 = 0,
    forced_failures: u64 = 0,
    publish_count: u64 = 0,
    rollback_count: u64 = 0,
    shrink_count: u64 = 0,
    id_collisions: u64 = 0,
    id_wraps: u64 = 0,
    live_id_hash: u64 = 0,
    live_address_hash: u64 = 0,
    reserved0: u64 = 0,
};

const FrozenProgramRegistrySelfTestResultV1 = extern struct {
    version: u32 = 1,
    size: u32 = 64,
    operation: u32 = 0,
    flags: u32 = 0,
    chunk_count_before: u32 = 0,
    slot_capacity_before: u32 = 0,
    free_slots_before: u32 = 0,
    reserved0: u32 = 0,
    growth_failures_before: u64 = 0,
    growth_failures_after: u64 = 0,
    forced_failures_before: u64 = 0,
    forced_failures_after: u64 = 0,
};

const LegacySummaryCanary = extern struct {
    payload: FrozenProgramRegistrySummaryV1 = .{},
    canary: [32]u8 = .{legacy_canary_byte} ** 32,
};

const LegacySelfTestCanary = extern struct {
    payload: FrozenProgramRegistrySelfTestResultV1 = .{},
    canary: [32]u8 = .{legacy_canary_byte} ** 32,
};

comptime {
    if (@sizeOf(FrozenProgramRegistrySummaryV1) != 160 or @alignOf(FrozenProgramRegistrySummaryV1) != 8)
        @compileError("frozen R4DEV ProgramRegistrySummary v1 ABI drift");
    if (@sizeOf(FrozenProgramRegistrySelfTestResultV1) != 64 or @alignOf(FrozenProgramRegistrySelfTestResultV1) != 8)
        @compileError("frozen R4DEV ProgramRegistrySelfTestResult v1 ABI drift");
    if (@offsetOf(LegacySummaryCanary, "canary") != 160 or @offsetOf(LegacySelfTestCanary, "canary") != 64)
        @compileError("R4DEV legacy canary is not adjacent to its payload");
    if (dynamic_stress_program_floor % dynamic_stress_fixture_kinds != 3 or
        dynamic_stress_console_count + dynamic_stress_gui_count + dynamic_stress_service_count !=
            dynamic_stress_program_floor + dynamic_stress_child_count)
        @compileError("dynamic stress fixture distribution drift");
    if (dynamic_churn_exit_args.len != dynamic_churn_exit_codes.len)
        @compileError("dynamic stress quiet exit fixture drift");
}

const StopMode = enum {
    request_close,
    kill,
};

const DynamicFixtureKind = enum(u8) {
    console_hold,
    child_spawn,
    thread_hold,
    gui_payload,
    service_hold,
};

const DynamicStressBaseline = struct {
    runtime: RuntimeBaseline,
    inventory: r4os.abi.ProgramInventorySummary,
    registry: r4os.abi.ProgramRegistrySummaryV2,
    self_instance: r4os.abi.ProgramInstanceInfo,
    self_owner: ResourceTotals,
};

const OwnedExecutionSignature = struct {
    task_count: u32 = 0,
    task_hash: u64 = 0xcbf29ce484222325,
    thread_count: u32 = 0,
    thread_hash: u64 = 0xcbf29ce484222325,
};

const ResourceTotals = struct {
    blocks: u64 = 0,
    program_images: u64 = 0,
    vm_ranges: u64 = 0,
    app_stacks: u64 = 0,
    reserved: u64 = 0,
    committed: u64 = 0,
    physical: u64 = 0,
    virtual: u64 = 0,
};

const DiagApi = struct {
    sys: r4os.r4sys.Context,
    desk: r4os.r4desk.Context,
    dev: r4os.r4dev.Context,
    draw: r4os.r4draw.Context,
    resources: r4os.Resources,

    fn init(app: *r4os.App) ?DiagApi {
        return .{
            .sys = app.system(),
            .desk = app.desktop() orelse return null,
            .dev = app.devicesLowLevel() orelse return null,
            .draw = app.drawing() orelse return null,
            .resources = app.resources(),
        };
    }
};

pub fn r4_app_main(app: *r4os.App) i32 {
    var ctx = DiagApi.init(app) orelse return r4os.abi.err_no_group;
    if (hasArg(ctx.sys.argsRaw(), registry_hold_arg)) return registryHold(&ctx);
    if (hasArg(ctx.sys.argsRaw(), lifecycle_foreground_arg)) return lifecycleForeground(&ctx);
    if (hasArg(ctx.sys.argsRaw(), lifecycle_exit_arg)) return lifecycleExit(&ctx);
    if (hasArg(ctx.sys.argsRaw(), dynamic_churn_hold_arg)) return dynamicChurnHold(&ctx);
    if (hasArg(ctx.sys.argsRaw(), lifecycle_hold_arg)) return lifecycleHold(&ctx);
    if (hasArg(ctx.sys.argsRaw(), console_wait_fixture_arg)) return consoleWaitFixture(&ctx);
    if (hasArg(ctx.sys.argsRaw(), lifecycle_host_arg)) return lifecycleHost(&ctx);
    if (hasArg(ctx.sys.argsRaw(), lifecycle_thread_exit_arg)) ctx.sys.threadExit(89);
    if (hasArg(ctx.sys.argsRaw(), dynamic_thread_hold_arg)) return dynamicThreadHold(&ctx);
    ctx.sys.println("SPECTRA LIFECYCLE");
    if (hasArg(ctx.sys.argsRaw(), "/WATCHCANCEL")) return testWatchCancellation(&ctx, false);
    if (hasArg(ctx.sys.argsRaw(), "/STANDARDCANCEL")) return testWatchCancellation(&ctx, true);

    if (hasArg(ctx.sys.argsRaw(), gui_payload_hold_arg)) return guiPayloadHold(&ctx);
    if (hasArg(ctx.sys.argsRaw(), gui_raster_chain_hold_arg)) return guiRasterChainHold(&ctx);
    if (hasArg(ctx.sys.argsRaw(), gui_frame_hold_arg)) return guiFrameHold(&ctx);
    if (!ctx.dev.hasFn("memory_summary")) return fail(&ctx, "memory snapshot missing");
    if (hasArg(ctx.sys.argsRaw(), dynamic_stress_arg)) {
        const quick = hasArg(ctx.sys.argsRaw(), dynamic_stress_quick_arg);
        if (!runDynamicExecutionStress(&ctx, quick)) return 1;
        ctx.sys.println("SPECTRA LIFECYCLE result: OK");
        return 0;
    }
    if (hasArg(ctx.sys.argsRaw(), program_registry_arg)) {
        if (!runDynamicProgramRegistry(&ctx)) return 1;
        ctx.sys.println("SPECTRA LIFECYCLE result: OK");
        return 0;
    }
    if (hasArg(ctx.sys.argsRaw(), program_lifecycle_arg)) {
        if (!runProgramLifecycle(&ctx)) return 1;
        ctx.sys.println("SPECTRA LIFECYCLE result: OK");
        return 0;
    }
    if (hasArg(ctx.sys.argsRaw(), console_wait_arg)) {
        if (!testLifecycleConsoleInputWaits(&ctx)) return 1;
        ctx.sys.println("SPECTRA LIFECYCLE consolewait result: OK");
        return 0;
    }
    if (hasArg(ctx.sys.argsRaw(), program_inventory_arg)) {
        if (!runProgramTaskInventory(&ctx)) {
            ctx.sys.println("SPECTRA LIFECYCLE result: FAILED");
            return 1;
        }
        ctx.sys.println("SPECTRA LIFECYCLE result: OK");
        return 0;
    }
    if (hasArg(ctx.sys.argsRaw(), program_storage_arg)) {
        if (!runProgramInstanceStorage(&ctx)) return 1;
        const storage_summary = ctx.dev.memorySummary() orelse return fail(&ctx, "programstorage summary unavailable");
        if (storage_summary.overflow != 0) return fail(&ctx, "programstorage summary overflow");
        ctx.sys.println("SPECTRA LIFECYCLE result: OK");
        return 0;
    }
    if (hasArg(ctx.sys.argsRaw(), "/ASYNCQUICK")) {
        var fixture: r4os.abi.ServiceInfo = .{};
        if (ctx.sys.serviceInstall(stall_service_name, service_path, "/HOLD /STALLENDPOINT", r4os.abi.service_start_manual, "Async I/O cancellation fixture", &fixture) != r4os.abi.service_api_result_ok) return 1;
        defer _ = ctx.sys.serviceRemove(stall_service_name);
        if (ctx.sys.serviceStart(stall_service_name, &fixture) != r4os.abi.service_api_result_ok) return 1;
        defer _ = ctx.sys.serviceStop(stall_service_name, &fixture, 2000);
        if (!testLifecycleAsyncThreads(&ctx)) return 1;
        ctx.sys.println("SPECTRA LIFECYCLE asyncquick result: OK");
        return 0;
    }
    if (!testNormalExit(&ctx)) return 1;
    if (!testRequestCloseCleanup(&ctx)) return 1;
    if (!testKillCleanup(&ctx)) return 1;
    if (!stressProcessLifecycle(&ctx)) return 1;

    const summary = ctx.dev.memorySummary() orelse return fail(&ctx, "summary unavailable");
    if (summary.overflow != 0) return fail(&ctx, "summary overflow");

    ctx.sys.println("SPECTRA LIFECYCLE result: OK");
    return 0;
}

fn lifecycleForeground(ctx: *DiagApi) i32 {
    const exit_code = argumentI32(ctx.sys.argsRaw(), 1) orelse 73;
    const output_len = argumentU32(ctx.sys.argsRaw(), 2) orelse 256;
    writeLifecycleOutput(ctx, output_len);
    ctx.sys.write("SPECTRA LIFECYCLE lifecycle foreground exit=");
    ctx.sys.printI32(exit_code);
    ctx.sys.write(" output=");
    ctx.sys.printU64(output_len);
    ctx.sys.println(" ready=OK");
    return exit_code;
}

fn lifecycleExit(ctx: *DiagApi) i32 {
    const exit_code = argumentI32(ctx.sys.argsRaw(), 1) orelse 0;
    const output_len = argumentU32(ctx.sys.argsRaw(), 2) orelse 0;
    writeLifecycleOutput(ctx, output_len);
    return exit_code;
}

fn lifecycleHold(ctx: *DiagApi) i32 {
    ctx.sys.println("SPECTRA LIFECYCLE lifecycle hold ready=OK");
    while (!ctx.sys.programShouldClose()) ctx.sys.sleepTicks(1);
    return 0;
}

fn dynamicChurnHold(ctx: *DiagApi) i32 {
    while (!ctx.sys.programShouldClose()) ctx.sys.sleepTicks(1);
    return 0;
}

const InventoryScanStats = struct {
    count: u32 = 0,
    total: u32 = 0,
    boundary_mask: u16 = 0,
    found: [inventory_handle_capacity]bool = .{false} ** inventory_handle_capacity,
};

const InventoryScanSet = struct {
    programs: InventoryScanStats,
    tasks: InventoryScanStats,
    threads: InventoryScanStats,
};

fn runProgramTaskInventory(ctx: *DiagApi) bool {
    if (!ctx.sys.hasFn("program_inventory_begin") or
        !ctx.sys.hasFn("program_inventory_programs") or
        !ctx.sys.hasFn("program_inventory_tasks") or
        !ctx.sys.hasFn("program_inventory_threads") or
        !ctx.dev.hasFn("execution_inventory_summary"))
        return programInventoryFail(ctx, "inventory API missing");

    ctx.sys.println("SPECTRA LIFECYCLE programinventory begin");
    const cold = readExecutionInventory(ctx) orelse return programInventoryFail(ctx, "cold summary unavailable");

    // First drive the exact same 80-instance shape once.  Dynamic registry,
    // task, stack and ProgramThread backing storage is therefore warm before
    // the baseline used for the measured wave is captured.
    var warm_handles: [inventory_hold_count]r4os.abi.ProgramProcessHandle =
        [_]r4os.abi.ProgramProcessHandle{.{}} ** inventory_hold_count;
    defer cleanupLifecycleHandles(ctx, warm_handles[0..]);
    if (!spawnInventoryHolds(ctx, warm_handles[0..]))
        return programInventoryFail(ctx, "warm hold spawn failed");
    if (!waitInventoryMinimum(ctx, cold, inventory_hold_count, 5000))
        return programInventoryFail(ctx, "warm hold population missing");
    if (!releaseInventoryHolds(ctx, warm_handles[0..]))
        return programInventoryFail(ctx, "warm hold cleanup failed");
    if (!waitInventoryBaseline(ctx, cold, 5000))
        return programInventoryFail(ctx, "cold counts not restored after warmup");

    const baseline = readExecutionInventory(ctx) orelse return programInventoryFail(ctx, "warm baseline unavailable");
    ctx.sys.write("SPECTRA LIFECYCLE programinventory warm programs=");
    ctx.sys.printU64(baseline.program_total);
    ctx.sys.write(" tasks=");
    ctx.sys.printU64(baseline.task_total);
    ctx.sys.write(" threads=");
    ctx.sys.printU64(baseline.thread_total);
    ctx.sys.write(" completions=");
    ctx.sys.printU64(baseline.completion_total);
    ctx.sys.println(" baseline=OK");

    var handles: [inventory_restart_hold_count]r4os.abi.ProgramProcessHandle =
        [_]r4os.abi.ProgramProcessHandle{.{}} ** inventory_restart_hold_count;
    defer cleanupLifecycleHandles(ctx, handles[0..]);
    if (!spawnInventoryHolds(ctx, handles[0..inventory_hold_count]))
        return programInventoryFail(ctx, "measured hold spawn failed");
    if (!waitInventoryMinimum(ctx, baseline, inventory_hold_count, 5000))
        return programInventoryFail(ctx, "80-way population missing");

    // Start an immutable view, mutate all three registries by spawning one
    // more real process, and prove that the old cursor reports RESTART while
    // retaining its caller-owned position.
    var stale_cursor: r4os.abi.ProgramInventoryCursor = .{};
    var stale_summary: r4os.abi.ProgramInventorySummary = .{};
    if (!beginProgramInventory(ctx, &stale_cursor, &stale_summary))
        return programInventoryFail(ctx, "restart begin failed");
    const stale_after = stale_cursor.program_after_generation;
    if (!spawnInventoryHolds(ctx, handles[inventory_hold_count..inventory_restart_hold_count]))
        return programInventoryFail(ctx, "restart mutation spawn failed");
    var stale_entries: [inventory_page_capacity]r4os.abi.ProgramInstanceSnapshot =
        [_]r4os.abi.ProgramInstanceSnapshot{.{}} ** inventory_page_capacity;
    var stale_page: r4os.abi.ProgramInventoryPageInfo = .{};
    if (!readProgramInventoryPage(ctx, &stale_cursor, stale_entries[0..], &stale_page) or
        stale_page.status != r4os.abi.program_inventory_status_restart or
        stale_page.returned != 0 or stale_cursor.program_after_generation != stale_after)
        return programInventoryFail(ctx, "restart advanced stale cursor");
    ctx.sys.println("SPECTRA LIFECYCLE programinventory restart spawnAfterBegin=1 status=RESTART returned=0 cursor=unchanged");

    if (!waitInventoryMinimum(ctx, baseline, inventory_restart_hold_count, 5000))
        return programInventoryFail(ctx, "restart hold population missing");

    // The final child can become visible in all membership counters one tick
    // before its publish -> run transition settles.  That is a legitimate
    // epoch change: discard every partial page and bind a fresh cursor rather
    // than turning the required RESTART result into a diagnostic failure.
    const scans = scanStableInventory(ctx, handles[0..]) orelse
        return programInventoryFail(ctx, "stable pagination retries exhausted");
    const programs = scans.programs;
    const tasks = scans.tasks;
    const threads = scans.threads;
    if (!allInventoryChildrenFound(programs.found[0..handles.len]) or
        !allInventoryChildrenFound(tasks.found[0..handles.len]) or
        !allInventoryChildrenFound(threads.found[0..handles.len]))
        return programInventoryFail(ctx, "held child absent from an inventory");
    if (programs.boundary_mask != inventory_boundary_mask_all or
        tasks.boundary_mask != inventory_boundary_mask_all or
        threads.boundary_mask != inventory_boundary_mask_all)
        return programInventoryFail(ctx, "pagination boundary coverage missing");

    if (!executionInventoryViewsMatch(ctx))
        return programInventoryFail(ctx, "R4SYS/R4DEV summary mismatch");

    ctx.sys.write("SPECTRA LIFECYCLE programinventory held=");
    ctx.sys.printU64(inventory_restart_hold_count);
    ctx.sys.write(" programs=");
    ctx.sys.printU64(programs.count);
    ctx.sys.write(" tasks=");
    ctx.sys.printU64(tasks.count);
    ctx.sys.write(" threads=");
    ctx.sys.printU64(threads.count);
    ctx.sys.println(" generations=complete/unique children=all");
    ctx.sys.println("SPECTRA LIFECYCLE programinventory boundaries=15/16/17,31/32/33,63/64/65 programs=OK tasks=OK threads=OK");
    ctx.sys.println("SPECTRA LIFECYCLE programinventory r4dev sharedFields=all-match snapshotGeneration=request-local");

    if (!releaseInventoryHolds(ctx, handles[0..]))
        return programInventoryFail(ctx, "measured hold cleanup failed");
    if (!waitInventoryBaseline(ctx, baseline, 8000))
        return programInventoryFail(ctx, "warm baseline not restored");
    const final = readExecutionInventory(ctx) orelse return programInventoryFail(ctx, "final summary unavailable");
    if (!sameInventoryBaselineCounts(baseline, final))
        return programInventoryFail(ctx, "final summary drift");

    ctx.sys.write("SPECTRA LIFECYCLE programinventory cleanup programs=");
    ctx.sys.printU64(final.program_total);
    ctx.sys.write(" tasks=");
    ctx.sys.printU64(final.task_total);
    ctx.sys.write(" threads=");
    ctx.sys.printU64(final.thread_total);
    ctx.sys.write(" completions=");
    ctx.sys.printU64(final.completion_total);
    ctx.sys.println(" warmBaseline=OK");
    ctx.sys.println("SPECTRA LIFECYCLE programinventory result: OK");
    return true;
}

fn inventorySummaryValid(summary: r4os.abi.ProgramInventorySummary) bool {
    return summary.version == r4os.abi.program_inventory_version and
        summary.size >= @sizeOf(r4os.abi.ProgramInventorySummary) and
        summary.snapshot_generation != 0 and summary.program_epoch != 0 and
        summary.task_epoch != 0 and summary.thread_epoch != 0 and
        (summary.flags & r4os.abi.program_inventory_summary_flag_stable) != 0;
}

fn readExecutionInventory(ctx: *DiagApi) ?r4os.abi.ProgramInventorySummary {
    var attempt: u32 = 0;
    while (attempt < 64) : (attempt += 1) {
        var summary: r4os.abi.ProgramInventorySummary = .{};
        if (ctx.dev.executionInventorySummary(&summary) == r4os.abi.program_handle_ok and inventorySummaryValid(summary))
            return summary;
        ctx.sys.sleepTicks(1);
    }
    return null;
}

fn beginProgramInventory(
    ctx: *DiagApi,
    cursor: *r4os.abi.ProgramInventoryCursor,
    summary: *r4os.abi.ProgramInventorySummary,
) bool {
    var retry: u32 = 0;
    while (retry <= inventory_would_block_retry_limit) : (retry += 1) {
        cursor.* = .{};
        summary.* = .{};
        const status = ctx.sys.programInventoryBegin(cursor, summary);
        if (status == r4os.abi.program_handle_ok) return true;
        if (status != r4os.abi.program_handle_error_would_block or retry == inventory_would_block_retry_limit)
            return false;
        ctx.sys.sleepTicks(1);
    }
    return false;
}

fn readProgramInventoryPage(
    ctx: *DiagApi,
    cursor: *r4os.abi.ProgramInventoryCursor,
    entries: []r4os.abi.ProgramInstanceSnapshot,
    page: *r4os.abi.ProgramInventoryPageInfo,
) bool {
    var retry: u32 = 0;
    while (retry <= inventory_would_block_retry_limit) : (retry += 1) {
        const cursor_before = cursor.*;
        page.* = .{};
        const status = ctx.sys.programInventoryPrograms(cursor, entries, page);
        if (status == r4os.abi.program_handle_ok) return true;
        cursor.* = cursor_before;
        page.* = .{};
        if (status != r4os.abi.program_handle_error_would_block or retry == inventory_would_block_retry_limit)
            return false;
        ctx.sys.sleepTicks(1);
    }
    return false;
}

fn readTaskInventoryPage(
    ctx: *DiagApi,
    cursor: *r4os.abi.ProgramInventoryCursor,
    entries: []r4os.abi.ProgramTaskSnapshot,
    page: *r4os.abi.ProgramInventoryPageInfo,
) bool {
    var retry: u32 = 0;
    while (retry <= inventory_would_block_retry_limit) : (retry += 1) {
        const cursor_before = cursor.*;
        page.* = .{};
        const status = ctx.sys.programInventoryTasks(cursor, entries, page);
        if (status == r4os.abi.program_handle_ok) return true;
        cursor.* = cursor_before;
        page.* = .{};
        if (status != r4os.abi.program_handle_error_would_block or retry == inventory_would_block_retry_limit)
            return false;
        ctx.sys.sleepTicks(1);
    }
    return false;
}

fn readThreadInventoryPage(
    ctx: *DiagApi,
    cursor: *r4os.abi.ProgramInventoryCursor,
    entries: []r4os.abi.ProgramThreadSnapshot,
    page: *r4os.abi.ProgramInventoryPageInfo,
) bool {
    var retry: u32 = 0;
    while (retry <= inventory_would_block_retry_limit) : (retry += 1) {
        const cursor_before = cursor.*;
        page.* = .{};
        const status = ctx.sys.programInventoryThreads(cursor, entries, page);
        if (status == r4os.abi.program_handle_ok) return true;
        cursor.* = cursor_before;
        page.* = .{};
        if (status != r4os.abi.program_handle_error_would_block or retry == inventory_would_block_retry_limit)
            return false;
        ctx.sys.sleepTicks(1);
    }
    return false;
}

fn spawnInventoryHolds(ctx: *DiagApi, handles: []r4os.abi.ProgramProcessHandle) bool {
    for (handles) |*handle| {
        if (ctx.sys.programSpawnHandle(cleanup_path, route.arguments("LIFECYCLE", lifecycle_hold_arg).ptr(), .auto, handle) != r4os.abi.program_handle_ok)
            return false;
    }
    return true;
}

fn releaseInventoryHolds(ctx: *DiagApi, handles: []r4os.abi.ProgramProcessHandle) bool {
    for (handles) |*handle| {
        if (handle.instance_id == 0 or ctx.sys.programHandleRequestClose(handle) != r4os.abi.program_handle_ok)
            return false;
    }
    for (handles) |*handle| {
        var completion: r4os.abi.ProgramProcessCompletion = .{};
        if (ctx.sys.programHandleWait(handle, 10_000, &completion) != r4os.abi.program_handle_ok or
            !sameLifecycleHandle(handle.*, completion.handle) or
            ctx.sys.programHandleReap(handle, &completion) != r4os.abi.program_handle_ok)
            return false;
        handle.* = .{};
    }
    return true;
}

fn waitInventoryMinimum(ctx: *DiagApi, baseline: r4os.abi.ProgramInventorySummary, added: usize, max_ticks: u32) bool {
    var tick: u32 = 0;
    const delta: u32 = @intCast(added);
    while (tick < max_ticks) : (tick += 1) {
        const current = readExecutionInventory(ctx) orelse return false;
        if (current.program_total >= baseline.program_total +| delta and
            current.task_total >= baseline.task_total +| delta and
            current.thread_total >= baseline.thread_total +| delta)
            return true;
        ctx.sys.sleepTicks(1);
    }
    return false;
}

fn waitInventoryBaseline(ctx: *DiagApi, baseline: r4os.abi.ProgramInventorySummary, max_ticks: u32) bool {
    var tick: u32 = 0;
    while (tick < max_ticks) : (tick += 1) {
        const current = readExecutionInventory(ctx) orelse return false;
        if (sameInventoryBaselineCounts(baseline, current)) return true;
        ctx.sys.sleepTicks(1);
    }
    return false;
}

fn sameInventoryBaselineCounts(a: r4os.abi.ProgramInventorySummary, b: r4os.abi.ProgramInventorySummary) bool {
    // A production desktop has service and remote-admin workers which may
    // cross running/ready/blocked scheduler states between two snapshots.
    // Those states are not ownership and must not turn a fully reaped wave
    // into a leak. Object, lifecycle, completion and ProgramThread counts
    // remain exact; sameInventoryCounts below still compares every public
    // field when R4SYS and R4DEV views of one snapshot are checked.
    return a.program_total == b.program_total and a.program_active == b.program_active and
        a.program_done == b.program_done and a.program_retiring == b.program_retiring and
        a.program_reserved == b.program_reserved and a.completion_total == b.completion_total and
        a.task_total == b.task_total and
        a.thread_total == b.thread_total and a.thread_running == b.thread_running and
        a.thread_done == b.thread_done and a.thread_joining == b.thread_joining;
}

fn sameInventoryCounts(a: r4os.abi.ProgramInventorySummary, b: r4os.abi.ProgramInventorySummary) bool {
    return a.program_total == b.program_total and a.program_active == b.program_active and
        a.program_done == b.program_done and a.program_retiring == b.program_retiring and
        a.program_reserved == b.program_reserved and a.completion_total == b.completion_total and
        a.task_total == b.task_total and a.task_running == b.task_running and
        a.task_ready == b.task_ready and a.task_blocked == b.task_blocked and
        a.thread_total == b.thread_total and a.thread_running == b.thread_running and
        a.thread_done == b.thread_done and a.thread_joining == b.thread_joining;
}

fn sameExecutionInventory(a: r4os.abi.ProgramInventorySummary, b: r4os.abi.ProgramInventorySummary) bool {
    return a.version == b.version and a.size == b.size and
        a.program_epoch == b.program_epoch and a.task_epoch == b.task_epoch and
        a.thread_epoch == b.thread_epoch and sameInventoryCounts(a, b) and
        a.program_peak == b.program_peak and a.task_peak == b.task_peak and
        a.thread_peak == b.thread_peak and
        a.program_create_failures == b.program_create_failures and
        a.task_create_failures == b.task_create_failures and
        a.thread_create_failures == b.thread_create_failures and
        a.rollback_failures == b.rollback_failures and
        a.last_error == b.last_error and a.flags == b.flags and
        a.heap_active_blocks == b.heap_active_blocks and a.heap_used_bytes == b.heap_used_bytes;
}

fn executionInventoryViewsMatch(ctx: *DiagApi) bool {
    var attempt: u32 = 0;
    while (attempt < inventory_would_block_retry_limit) : (attempt += 1) {
        var cursor: r4os.abi.ProgramInventoryCursor = .{};
        var system_summary: r4os.abi.ProgramInventorySummary = .{};
        if (!beginProgramInventory(ctx, &cursor, &system_summary) or !inventorySummaryValid(system_summary))
            return false;
        const device_summary = readExecutionInventory(ctx) orelse return false;
        if (sameExecutionInventory(system_summary, device_summary)) return true;
        ctx.sys.sleepTicks(1);
    }
    return false;
}

fn scanStableInventory(
    ctx: *DiagApi,
    handles: []const r4os.abi.ProgramProcessHandle,
) ?InventoryScanSet {
    var attempt: u32 = 0;
    while (attempt < inventory_restart_limit) : (attempt += 1) {
        var cursor: r4os.abi.ProgramInventoryCursor = .{};
        var summary: r4os.abi.ProgramInventorySummary = .{};
        if (!beginProgramInventory(ctx, &cursor, &summary) or !inventorySummaryValid(summary)) {
            ctx.sys.sleepTicks(1);
            continue;
        }
        const programs = scanInventoryPrograms(ctx, &cursor, handles, summary.program_total) orelse {
            ctx.sys.sleepTicks(1);
            continue;
        };
        const tasks = scanInventoryTasks(ctx, &cursor, handles, summary.task_total) orelse {
            ctx.sys.sleepTicks(1);
            continue;
        };
        const threads = scanInventoryThreads(ctx, &cursor, handles, summary.thread_total) orelse {
            ctx.sys.sleepTicks(1);
            continue;
        };
        return .{ .programs = programs, .tasks = tasks, .threads = threads };
    }
    return null;
}

fn captureOwnedExecutionSignature(ctx: *DiagApi) ?OwnedExecutionSignature {
    var attempt: u32 = 0;
    restart: while (attempt < inventory_restart_limit) : (attempt += 1) {
        var cursor: r4os.abi.ProgramInventoryCursor = .{};
        var summary: r4os.abi.ProgramInventorySummary = .{};
        if (!beginProgramInventory(ctx, &cursor, &summary) or !inventorySummaryValid(summary)) {
            ctx.sys.sleepTicks(1);
            continue;
        }

        var signature: OwnedExecutionSignature = .{};
        var scanned_tasks: u32 = 0;
        var last_task_generation: u64 = 0;
        while (true) {
            var entries: [inventory_page_capacity]r4os.abi.ProgramTaskSnapshot =
                [_]r4os.abi.ProgramTaskSnapshot{.{}} ** inventory_page_capacity;
            var page: r4os.abi.ProgramInventoryPageInfo = .{};
            if (!readTaskInventoryPage(ctx, &cursor, entries[0..], &page)) return null;
            if (page.status == r4os.abi.program_inventory_status_restart) continue :restart;
            if (!inventoryPageValid(page, cursor.snapshot_generation, r4os.abi.program_inventory_kind_task, summary.task_total))
                return null;
            for (entries[0..@intCast(page.returned)]) |entry| {
                if (entry.version != r4os.abi.program_inventory_version or
                    entry.size < @sizeOf(r4os.abi.ProgramTaskSnapshot) or entry.task_id == 0 or
                    entry.generation <= last_task_generation)
                    return null;
                last_task_generation = entry.generation;
                scanned_tasks += 1;
                if (entry.owner_instance_id == 0) continue;
                signature.task_count += 1;
                signature.task_hash = mixOwnedExecutionHash(signature.task_hash, entry.task_id);
                signature.task_hash = mixOwnedExecutionHash(signature.task_hash, entry.generation);
                signature.task_hash = mixOwnedExecutionHash(signature.task_hash, entry.owner_instance_id);
                signature.task_hash = mixOwnedExecutionHash(signature.task_hash, entry.instance_generation);
            }
            if (page.next_generation != last_task_generation or cursor.task_after_generation != last_task_generation)
                return null;
            if (page.status == r4os.abi.program_inventory_status_complete) break;
            if (page.status != r4os.abi.program_inventory_status_more or page.returned == 0) return null;
        }
        if (scanned_tasks != summary.task_total) return null;

        var scanned_threads: u32 = 0;
        var last_thread_generation: u64 = 0;
        while (true) {
            var entries: [inventory_page_capacity]r4os.abi.ProgramThreadSnapshot =
                [_]r4os.abi.ProgramThreadSnapshot{.{}} ** inventory_page_capacity;
            var page: r4os.abi.ProgramInventoryPageInfo = .{};
            if (!readThreadInventoryPage(ctx, &cursor, entries[0..], &page)) return null;
            if (page.status == r4os.abi.program_inventory_status_restart) continue :restart;
            if (!inventoryPageValid(page, cursor.snapshot_generation, r4os.abi.program_inventory_kind_thread, summary.thread_total))
                return null;
            for (entries[0..@intCast(page.returned)]) |entry| {
                if (entry.version != r4os.abi.program_inventory_version or
                    entry.size < @sizeOf(r4os.abi.ProgramThreadSnapshot) or
                    entry.handle.thread_id == 0 or entry.handle.thread_generation <= last_thread_generation)
                    return null;
                last_thread_generation = entry.handle.thread_generation;
                scanned_threads += 1;
                if (entry.handle.instance_id == 0) continue;
                signature.thread_count += 1;
                signature.thread_hash = mixOwnedExecutionHash(signature.thread_hash, entry.handle.thread_id);
                signature.thread_hash = mixOwnedExecutionHash(signature.thread_hash, entry.handle.thread_generation);
                signature.thread_hash = mixOwnedExecutionHash(signature.thread_hash, entry.handle.instance_id);
                signature.thread_hash = mixOwnedExecutionHash(signature.thread_hash, entry.handle.instance_generation);
            }
            if (page.next_generation != last_thread_generation or cursor.thread_after_generation != last_thread_generation)
                return null;
            if (page.status == r4os.abi.program_inventory_status_complete) break;
            if (page.status != r4os.abi.program_inventory_status_more or page.returned == 0) return null;
        }
        if (scanned_threads != summary.thread_total) return null;
        return signature;
    }
    return null;
}

fn mixOwnedExecutionHash(hash: u64, value: anytype) u64 {
    var mixed: u64 = @intCast(value);
    mixed +%= 0x9e3779b97f4a7c15;
    mixed = (mixed ^ (mixed >> 30)) *% 0xbf58476d1ce4e5b9;
    mixed = (mixed ^ (mixed >> 27)) *% 0x94d049bb133111eb;
    mixed ^= mixed >> 31;
    return (hash ^ mixed) *% 0x100000001b3;
}

fn sameOwnedExecutionSignature(a: OwnedExecutionSignature, b: OwnedExecutionSignature) bool {
    return a.task_count == b.task_count and a.task_hash == b.task_hash and
        a.thread_count == b.thread_count and a.thread_hash == b.thread_hash;
}

fn scanInventoryPrograms(
    ctx: *DiagApi,
    cursor: *r4os.abi.ProgramInventoryCursor,
    handles: []const r4os.abi.ProgramProcessHandle,
    expected_total: u32,
) ?InventoryScanStats {
    var stats: InventoryScanStats = .{};
    var last_generation: u64 = 0;
    while (true) {
        var entries: [inventory_page_capacity]r4os.abi.ProgramInstanceSnapshot =
            [_]r4os.abi.ProgramInstanceSnapshot{.{}} ** inventory_page_capacity;
        var page: r4os.abi.ProgramInventoryPageInfo = .{};
        if (!readProgramInventoryPage(ctx, cursor, entries[0..], &page) or
            !inventoryPageValid(page, cursor.snapshot_generation, r4os.abi.program_inventory_kind_program, expected_total))
            return null;
        var index: usize = 0;
        while (index < page.returned) : (index += 1) {
            const entry = entries[index];
            if (entry.version != r4os.abi.program_inventory_version or
                entry.size < @sizeOf(r4os.abi.ProgramInstanceSnapshot) or
                entry.handle.instance_id == 0 or entry.handle.generation <= last_generation or
                entry.state_generation != entry.handle.generation or entry.info.id != entry.handle.instance_id)
                return null;
            last_generation = entry.handle.generation;
            markInventoryBoundary(&stats.boundary_mask, stats.count);
            markProgramChild(&stats.found, handles, entry.handle.instance_id, entry.handle.generation);
            stats.count += 1;
        }
        stats.total = page.total;
        if (page.next_generation != last_generation or cursor.program_after_generation != last_generation) return null;
        if (page.status == r4os.abi.program_inventory_status_complete) break;
        if (page.status != r4os.abi.program_inventory_status_more or page.returned == 0 or page.has_more == 0) return null;
    }
    if (stats.count != expected_total or stats.total != expected_total) return null;
    return stats;
}

fn scanInventoryTasks(
    ctx: *DiagApi,
    cursor: *r4os.abi.ProgramInventoryCursor,
    handles: []const r4os.abi.ProgramProcessHandle,
    expected_total: u32,
) ?InventoryScanStats {
    var stats: InventoryScanStats = .{};
    var last_generation: u64 = 0;
    while (true) {
        var entries: [inventory_page_capacity]r4os.abi.ProgramTaskSnapshot =
            [_]r4os.abi.ProgramTaskSnapshot{.{}} ** inventory_page_capacity;
        var page: r4os.abi.ProgramInventoryPageInfo = .{};
        if (!readTaskInventoryPage(ctx, cursor, entries[0..], &page) or
            !inventoryPageValid(page, cursor.snapshot_generation, r4os.abi.program_inventory_kind_task, expected_total))
            return null;
        var index: usize = 0;
        while (index < page.returned) : (index += 1) {
            const entry = entries[index];
            if (entry.version != r4os.abi.program_inventory_version or
                entry.size < @sizeOf(r4os.abi.ProgramTaskSnapshot) or
                entry.task_id == 0 or entry.generation <= last_generation)
                return null;
            last_generation = entry.generation;
            markInventoryBoundary(&stats.boundary_mask, stats.count);
            markProgramChild(&stats.found, handles, entry.owner_instance_id, entry.instance_generation);
            stats.count += 1;
        }
        stats.total = page.total;
        if (page.next_generation != last_generation or cursor.task_after_generation != last_generation) return null;
        if (page.status == r4os.abi.program_inventory_status_complete) break;
        if (page.status != r4os.abi.program_inventory_status_more or page.returned == 0 or page.has_more == 0) return null;
    }
    if (stats.count != expected_total or stats.total != expected_total) return null;
    return stats;
}

fn scanInventoryThreads(
    ctx: *DiagApi,
    cursor: *r4os.abi.ProgramInventoryCursor,
    handles: []const r4os.abi.ProgramProcessHandle,
    expected_total: u32,
) ?InventoryScanStats {
    var stats: InventoryScanStats = .{};
    var last_generation: u64 = 0;
    while (true) {
        var entries: [inventory_page_capacity]r4os.abi.ProgramThreadSnapshot =
            [_]r4os.abi.ProgramThreadSnapshot{.{}} ** inventory_page_capacity;
        var page: r4os.abi.ProgramInventoryPageInfo = .{};
        if (!readThreadInventoryPage(ctx, cursor, entries[0..], &page) or
            !inventoryPageValid(page, cursor.snapshot_generation, r4os.abi.program_inventory_kind_thread, expected_total))
            return null;
        var index: usize = 0;
        while (index < page.returned) : (index += 1) {
            const entry = entries[index];
            if (entry.version != r4os.abi.program_inventory_version or
                entry.size < @sizeOf(r4os.abi.ProgramThreadSnapshot) or
                entry.handle.thread_id == 0 or entry.handle.thread_generation <= last_generation or
                entry.state_generation != entry.handle.thread_generation or
                entry.info.thread_id != entry.handle.thread_id or entry.info.instance_id != entry.handle.instance_id)
                return null;
            last_generation = entry.handle.thread_generation;
            markInventoryBoundary(&stats.boundary_mask, stats.count);
            markProgramChild(&stats.found, handles, entry.handle.instance_id, entry.handle.instance_generation);
            stats.count += 1;
        }
        stats.total = page.total;
        if (page.next_generation != last_generation or cursor.thread_after_generation != last_generation) return null;
        if (page.status == r4os.abi.program_inventory_status_complete) break;
        if (page.status != r4os.abi.program_inventory_status_more or page.returned == 0 or page.has_more == 0) return null;
    }
    if (stats.count != expected_total or stats.total != expected_total) return null;
    return stats;
}

fn inventoryPageValid(page: r4os.abi.ProgramInventoryPageInfo, snapshot_generation: u64, kind: u32, total: u32) bool {
    return page.version == r4os.abi.program_inventory_version and
        page.size >= @sizeOf(r4os.abi.ProgramInventoryPageInfo) and
        page.snapshot_generation == snapshot_generation and page.kind == kind and
        page.total == total and page.returned <= inventory_page_capacity and
        (page.status == r4os.abi.program_inventory_status_more or page.status == r4os.abi.program_inventory_status_complete);
}

fn markProgramChild(
    found: *[inventory_handle_capacity]bool,
    handles: []const r4os.abi.ProgramProcessHandle,
    instance_id: u32,
    instance_generation: u64,
) void {
    for (handles, 0..) |handle, index| {
        if (handle.instance_id == instance_id and handle.generation == instance_generation) {
            found[index] = true;
            return;
        }
    }
}

fn markInventoryBoundary(mask: *u16, ordinal: u32) void {
    inline for (inventory_boundaries, 0..) |boundary, index| {
        if (ordinal == boundary) mask.* |= @as(u16, 1) << @intCast(index);
    }
}

fn allInventoryChildrenFound(found: []const bool) bool {
    for (found) |present| if (!present) return false;
    return true;
}

fn programInventoryFail(ctx: *DiagApi, message: []const u8) bool {
    ctx.sys.write("SPECTRA LIFECYCLE programinventory FAILED: ");
    ctx.sys.write(message);
    ctx.sys.write("\r\n");
    ctx.sys.println("SPECTRA LIFECYCLE programinventory result: FAILED");
    return false;
}

fn lifecycleHost(ctx: *DiagApi) i32 {
    const depth = argumentU32(ctx.sys.argsRaw(), 1) orelse return 64;
    if (depth == 0 or depth > 8) return 65;
    var child: r4os.abi.ProgramProcessHandle = .{};
    if (depth > 1) {
        var args_buffer: [32:0]u8 = .{0} ** 32;
        const args = formatLifecycleHostArgs(depth - 1, &args_buffer);
        // Only the root owns a concrete host. Descendants inherit that console
        // target, which gives the kernel a real generation-bound host link for
        // close/kill cascade while their Completion owner remains the immediate
        // spawning program.
        const started = ctx.sys.programSpawnHandle(cleanup_path, route.arguments("LIFECYCLE", args).ptr(), .auto, &child);
        if (started != r4os.abi.program_handle_ok) return 66;
    }
    ctx.sys.write("SPECTRA LIFECYCLE lifecycle host depth=");
    ctx.sys.printU64(depth);
    ctx.sys.println(" ready=OK");
    while (!ctx.sys.programShouldClose()) ctx.sys.sleepTicks(1);
    if (child.instance_id != 0) {
        _ = ctx.sys.programHandleRequestClose(&child);
        var completion: r4os.abi.ProgramProcessCompletion = .{};
        if (ctx.sys.programHandleWait(&child, 5000, &completion) == r4os.abi.program_handle_ok) {
            _ = ctx.sys.programHandleReap(&child, &completion);
        }
    }
    return 0;
}

fn formatLifecycleHostArgs(depth: u32, out: *[32:0]u8) [*:0]const u8 {
    const prefix = lifecycle_host_arg ++ " ";
    out.* = .{0} ** 32;
    @memcpy(out[0..prefix.len], prefix);
    var digits: [10]u8 = undefined;
    var value = depth;
    var count: usize = 0;
    while (true) {
        digits[count] = @intCast(value % 10);
        count += 1;
        value /= 10;
        if (value == 0) break;
    }
    var index: usize = 0;
    while (index < count) : (index += 1) out[prefix.len + index] = '0' + digits[count - index - 1];
    return @ptrCast(&out[0]);
}

fn writeLifecycleOutput(ctx: *DiagApi, requested: u32) void {
    const line = "lifecycle-completion-output-0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ\r\n";
    var remaining = requested;
    while (remaining != 0) {
        const count: usize = @intCast(@min(remaining, line.len));
        ctx.sys.write(line[0..count]);
        remaining -= @intCast(count);
    }
}

fn runProgramLifecycle(ctx: *DiagApi) bool {
    if (!ctx.dev.hasFn("program_registry_summary") or !ctx.dev.hasFn("program_registry_self_test") or
        !ctx.dev.hasFn("program_registry_summary_v2") or !ctx.dev.hasFn("program_registry_self_test_v2"))
        return programLifecycleFail(ctx, "R4DEV lifecycle telemetry missing");
    if (!ctx.sys.hasFn("program_spawn_handle") or !ctx.sys.hasFn("program_handle_wait") or
        !ctx.sys.hasFn("program_handle_reap") or !ctx.sys.hasFn("program_completion_read"))
        return programLifecycleFail(ctx, "R4SYS owned completion API missing");

    ctx.sys.println("SPECTRA LIFECYCLE programlifecycle begin");
    if (!testLegacyR4DevCanaries(ctx)) return false;
    if (!lifecycleWarmup(ctx)) return programLifecycleFail(ctx, "warmup failed");
    const baseline = captureRuntimeBaseline(ctx) orelse return programLifecycleFail(ctx, "baseline unavailable");
    const registry = readProgramRegistry(ctx) orelse return programLifecycleFail(ctx, "registry baseline unavailable");
    // The diagnostic itself and the deliberately running SVCSTALL fixture
    // have pending completions while this profile executes.  Quiescence is
    // therefore a return to the captured baseline, not a globally empty
    // completion list.
    if (registry.reserved_slots != 0 or registry.done_slots != 0 or
        registry.retiring_slots != 0 or registry.completion_ready != 0 or
        registry.retire_queued != 0)
        return programLifecycleFail(ctx, "baseline not quiescent");
    if (!testLifecycleCompletionRing(ctx, baseline, registry)) return false;
    if (!testLifecycleLegacyIdCompletion(ctx)) return false;
    if (!testLifecycleStaleReuse(ctx)) return false;
    if (!testLifecycleConsoleTrees(ctx)) return false;
    if (!testLifecycleConsoleInputWaits(ctx)) return false;
    if (!testLifecycleServices(ctx)) return false;
    if (!testLifecycleCurrentTaskRetire(ctx)) return false;
    if (!testLifecycleFailurePhases(ctx)) return false;
    // Keep the 72-cycle blocked-I/O stress last so deterministic structural,
    // ownership and failure-phase defects surface quickly during development.
    if (!testLifecycleAsyncThreads(ctx)) return false;
    if (!waitLifecycleBaseline(ctx, baseline, registry, 3000))
        return programLifecycleFail(ctx, "final lifecycle quiescence missing");
    const final = readProgramRegistry(ctx) orelse return programLifecycleFail(ctx, "final registry unavailable");
    ctx.sys.write("SPECTRA LIFECYCLE programlifecycle quiescence completion=");
    const baseline_completions = @as(u64, registry.completion_pending) + @as(u64, registry.completion_ready);
    const final_completions = @as(u64, final.completion_pending) + @as(u64, final.completion_ready);
    ctx.sys.printU64(final_completions -| baseline_completions);
    ctx.sys.write(" retire=");
    ctx.sys.printU64(final.retire_queued);
    ctx.sys.println(" async=0 owners=baseline heap=baseline pmm=baseline vm=baseline result=OK");
    ctx.sys.println("SPECTRA LIFECYCLE programlifecycle result: OK");
    return true;
}

fn testLegacyR4DevCanaries(ctx: *DiagApi) bool {
    var summary: LegacySummaryCanary = .{};
    if (ctx.dev.programRegistrySummary(@ptrCast(&summary.payload)) <= 0 or
        summary.payload.version != 1 or summary.payload.size != 160 or !legacyCanaryIntact(summary.canary[0..]))
        return programLifecycleFail(ctx, "R4DEV legacy summary canary overwritten");

    var self_test: LegacySelfTestCanary = .{};
    self_test.payload.operation = r4os.abi.program_registry_self_test_operation_reset;
    if (ctx.dev.programRegistrySelfTest(@ptrCast(&self_test.payload)) <= 0 or
        self_test.payload.version != 1 or self_test.payload.size != 64 or
        self_test.payload.operation != r4os.abi.program_registry_self_test_operation_reset or
        !legacyCanaryIntact(self_test.canary[0..]))
        return programLifecycleFail(ctx, "R4DEV legacy self-test canary overwritten");

    ctx.sys.println("SPECTRA LIFECYCLE programlifecycle r4devLegacyCanary summary=160 selftest=64 slots=29,30 guard=OK");
    return true;
}

fn legacyCanaryIntact(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != legacy_canary_byte) return false;
    return true;
}

fn lifecycleWarmup(ctx: *DiagApi) bool {
    const registry = readProgramRegistry(ctx) orelse return false;
    var handles: [lifecycle_ring_count]r4os.abi.ProgramProcessHandle =
        [_]r4os.abi.ProgramProcessHandle{.{}} ** lifecycle_ring_count;
    defer cleanupLifecycleHandles(ctx, handles[0..]);

    // Establish the deliberate two-chunk Registry floor and the Kernel-heap
    // high-water mark with exactly the same concurrent shape as the measured
    // ring. The following round must then return to this stable warm baseline;
    // a cold one-child baseline would misclassify retained allocator capacity
    // as a lifecycle leak.
    for (&handles) |*handle| {
        if (ctx.sys.programSpawnHandle(cleanup_path, route.arguments("LIFECYCLE", "/LIFECYCLEEXIT 0 0").ptr(), .auto, handle) != r4os.abi.program_handle_ok)
            return false;
    }
    for (&handles) |*handle| {
        var completion: r4os.abi.ProgramProcessCompletion = .{};
        if (ctx.sys.programHandleWait(handle, 10000, &completion) != r4os.abi.program_handle_ok or
            ctx.sys.programHandleReap(handle, &completion) != r4os.abi.program_handle_ok)
            return false;
        handle.* = .{};
    }
    return waitLifecycleRegistryBaseline(ctx, registry, 1000);
}

fn testLifecycleCompletionRing(ctx: *DiagApi, baseline: RuntimeBaseline, registry_before: r4os.abi.ProgramRegistrySummaryV2) bool {
    var handles: [lifecycle_ring_count]r4os.abi.ProgramProcessHandle =
        [_]r4os.abi.ProgramProcessHandle{.{}} ** lifecycle_ring_count;
    var completions: [lifecycle_ring_count]r4os.abi.ProgramProcessCompletion =
        [_]r4os.abi.ProgramProcessCompletion{.{}} ** lifecycle_ring_count;
    defer cleanupLifecycleHandles(ctx, handles[0..]);

    for (&handles, 0..) |*handle, index| {
        if (ctx.sys.programSpawnHandle(cleanup_path, route.arguments("LIFECYCLE", lifecycle_ring_args[index]).ptr(), .auto, handle) != r4os.abi.program_handle_ok)
            return programLifecycleFail(ctx, "ring spawn failed");
    }
    for (&handles, &completions, 0..) |*handle, *completion, index| {
        const wait_result = ctx.sys.programHandleWait(handle, 10000, completion);
        const expected_flags = r4os.abi.program_completion_flag_ready |
            r4os.abi.program_completion_flag_owner |
            r4os.abi.program_completion_flag_output;
        const actual_flags = completion.flags & expected_flags;
        const expected_output_length = 32 + @as(u32, @intCast(index));
        if (wait_result != r4os.abi.program_handle_ok or
            completion.exit_code != lifecycle_ring_codes[index] or
            !sameLifecycleHandle(handle.*, completion.handle) or
            actual_flags != expected_flags or
            completion.output_length != expected_output_length)
        {
            printLifecycleRingMismatch(
                ctx,
                index,
                wait_result,
                handle.*,
                completion.*,
                expected_flags,
                expected_output_length,
            );
            return programLifecycleFail(ctx, "ring completion mismatch");
        }

        var output: [96]u8 = .{0} ** 96;
        var read: u32 = 0;
        if (ctx.sys.programCompletionRead(handle, 0, output[0..], &read) != r4os.abi.program_handle_ok or
            read != completion.output_length or read == 0 or output[0] != 'l')
            return programLifecycleFail(ctx, "ring output retention mismatch");
        var repeated: r4os.abi.ProgramProcessCompletion = .{};
        if (ctx.sys.programHandleWait(handle, 0, &repeated) != r4os.abi.program_handle_ok or
            repeated.sequence != completion.sequence or repeated.exit_code != completion.exit_code)
            return programLifecycleFail(ctx, "wait consumed completion");
    }

    const wrapped = readProgramRegistry(ctx) orelse return programLifecycleFail(ctx, "ring summary unavailable");
    const ring_count_u32: u32 = @intCast(lifecycle_ring_count);
    const expected_count = @min(lifecycle_history_capacity, registry_before.history_count + ring_count_u32);
    const expected_head = (registry_before.history_head + ring_count_u32) % lifecycle_history_capacity;
    if (wrapped.completion_ready != registry_before.completion_ready + ring_count_u32 or
        wrapped.completion_pending != registry_before.completion_pending or
        wrapped.history_sequence != registry_before.history_sequence + @as(u64, ring_count_u32) or
        wrapped.history_count != expected_count or wrapped.history_head != expected_head)
        return programLifecycleFail(ctx, "ring Head/Count/sequence mismatch");

    for (lifecycle_reap_order) |index| {
        var reaped: r4os.abi.ProgramProcessCompletion = .{};
        if (ctx.sys.programHandleReap(&handles[index], &reaped) != r4os.abi.program_handle_ok or
            reaped.sequence != completions[index].sequence or reaped.exit_code != lifecycle_ring_codes[index])
            return programLifecycleFail(ctx, "shuffled reap mismatch");
        handles[index] = .{};
    }
    if (!waitLifecycleBaseline(ctx, baseline, registry_before, 3000)) {
        printLifecycleBaselineMismatch(ctx, baseline, registry_before);
        return programLifecycleFail(ctx, "ring baseline not restored");
    }

    ctx.sys.println("SPECTRA LIFECYCLE programlifecycle ring spawned=24 historyCount=16 negative=-1,-2,-9 order=OK output=OK reap=shuffled");
    return true;
}

fn printLifecycleRingMismatch(
    ctx: *DiagApi,
    index: usize,
    wait_result: i32,
    handle: r4os.abi.ProgramProcessHandle,
    completion: r4os.abi.ProgramProcessCompletion,
    expected_flags: u32,
    expected_output_length: u32,
) void {
    ctx.sys.write("SPECTRA LIFECYCLE programlifecycle ringMismatch index=");
    ctx.sys.printU64(@intCast(index));
    ctx.sys.write(" wait=");
    ctx.sys.printI32(wait_result);
    ctx.sys.write(" exit=");
    ctx.sys.printI32(completion.exit_code);
    ctx.sys.write(" expectedExit=");
    ctx.sys.printI32(lifecycle_ring_codes[index]);
    ctx.sys.write(" handle=");
    ctx.sys.printU64(handle.instance_id);
    ctx.sys.write("/");
    ctx.sys.printU64(handle.generation);
    ctx.sys.write(" completion=");
    ctx.sys.printU64(completion.handle.instance_id);
    ctx.sys.write("/");
    ctx.sys.printU64(completion.handle.generation);
    ctx.sys.write(" flags=");
    ctx.sys.printU64(completion.flags);
    ctx.sys.write(" expectedFlags=");
    ctx.sys.printU64(expected_flags);
    ctx.sys.write(" output=");
    ctx.sys.printU64(completion.output_length);
    ctx.sys.write("/");
    ctx.sys.printU64(expected_output_length);
    ctx.sys.println("");
}

fn testLifecycleLegacyIdCompletion(ctx: *DiagApi) bool {
    const baseline = captureRuntimeBaseline(ctx) orelse return programLifecycleFail(ctx, "legacy-ID baseline unavailable");
    const registry = readProgramRegistry(ctx) orelse return programLifecycleFail(ctx, "legacy-ID registry unavailable");

    const generic_raw = ctx.sys.programSpawn(cleanup_path, route.arguments("LIFECYCLE", "/LIFECYCLEEXIT 61 64").ptr(), .console);
    if (generic_raw <= 0) return programLifecycleFail(ctx, "legacy generic spawn failed");
    const generic_id: u32 = @intCast(generic_raw);
    if (!waitLegacyIdDoneWithOutput(ctx, generic_id, 61, "lifecycle-completion-output", 10000))
        return programLifecycleFail(ctx, "legacy generic done/output bridge failed");

    var force: r4os.abi.ProgramRegistrySelfTestResultV2 = .{
        .operation = r4os.abi.program_registry_self_test_operation_force_next_id,
        .requested_next_id = generic_id,
    };
    if (ctx.dev.programRegistrySelfTestV2(&force) <= 0 or force.lifecycle_result != r4os.abi.program_handle_ok or
        force.applied_next_id != generic_id)
        return programLifecycleFail(ctx, "legacy completion collision seam failed");
    const collision_raw = ctx.sys.programSpawn(cleanup_path, route.arguments("LIFECYCLE", "/LIFECYCLEEXIT 63 32").ptr(), .console);
    if (collision_raw <= 0 or collision_raw == generic_raw)
        return programLifecycleFail(ctx, "legacy completion ID collision was admitted");
    const collision_id: u32 = @intCast(collision_raw);
    if (!waitLegacyIdDoneWithOutput(ctx, collision_id, 63, "lifecycle-completion-output", 10000) or
        ctx.sys.programReapInstance(collision_id) != 63 or
        ctx.sys.programReapInstance(collision_id) != -1)
        return programLifecycleFail(ctx, "legacy collision child completion failed");

    if (ctx.sys.programReapInstance(generic_id) != 61 or
        ctx.sys.programReapInstance(generic_id) != -1 or
        legacyIdVisible(ctx, generic_id))
        return programLifecycleFail(ctx, "legacy generic reap failed");
    var after_reap: [8]u8 = .{0} ** 8;
    if (ctx.desk.consoleOutput(generic_id, after_reap[0..]) >= 0)
        return programLifecycleFail(ctx, "legacy generic output survived reap");

    const hosted_raw = ctx.sys.programSpawnWithConsoleHost(
        cleanup_path,
        route.arguments("LIFECYCLE", "/LIFECYCLEHOLD").ptr(),
        .console,
        .terminal_mode,
    );
    if (hosted_raw <= 0) return programLifecycleFail(ctx, "legacy hosted spawn failed");
    const hosted_id: u32 = @intCast(hosted_raw);
    if (ctx.sys.programReapInstance(hosted_id) != -2 or ctx.sys.programRequestClose(hosted_id) != 0 or
        !waitLegacyIdDoneWithOutput(ctx, hosted_id, 0, "SPECTRA LIFECYCLE lifecycle hold ready=OK", 10000) or
        ctx.sys.programReapInstance(hosted_id) != 0 or
        ctx.sys.programReapInstance(hosted_id) != -1 or
        legacyIdVisible(ctx, hosted_id))
        return programLifecycleFail(ctx, "legacy hosted done/output/reap bridge failed");

    if (!waitLifecycleBaseline(ctx, baseline, registry, 5000))
        return programLifecycleFail(ctx, "legacy-ID baseline not restored");
    ctx.sys.println("SPECTRA LIFECYCLE programlifecycle legacyId generic=done/output/reap hosted=pending-2/done/output/reap collision=blocked singleUse=OK baseline=OK");
    return true;
}

fn waitLegacyIdDoneWithOutput(ctx: *DiagApi, instance_id: u32, expected_exit: i32, needle: []const u8, max_ticks: u32) bool {
    var tick: u32 = 0;
    var last_visible = false;
    var last_state: u8 = 0;
    var last_exit: i32 = 0;
    while (tick < max_ticks) : (tick += 1) {
        var info: r4os.abi.ProgramInstanceInfo = .{};
        if (legacyIdInfo(ctx, instance_id, &info)) {
            last_visible = true;
            last_state = info.state;
            last_exit = info.exit_code;
        }
        if (last_visible and last_state == @intFromEnum(r4os.abi.ProgramInstanceState.done)) {
            if (last_exit != expected_exit) {
                printLegacyIdOutputMismatch(ctx, instance_id, last_state, last_exit, expected_exit, -1, 1);
                return false;
            }
            var output: [192]u8 = .{0} ** 192;
            const got = ctx.desk.consoleOutput(instance_id, output[0..]);
            if (got <= 0) {
                printLegacyIdOutputMismatch(ctx, instance_id, last_state, last_exit, expected_exit, got, 2);
                return false;
            }
            const used: usize = @intCast(got);
            if (!containsBytes(output[0..used], needle)) {
                printLegacyIdOutputMismatch(ctx, instance_id, last_state, last_exit, expected_exit, got, 3);
                return false;
            }
            return true;
        }
        ctx.sys.sleepTicks(1);
    }
    printLegacyIdOutputMismatch(ctx, instance_id, last_state, last_exit, expected_exit, -1, if (last_visible) 4 else 5);
    return false;
}

fn printLegacyIdOutputMismatch(
    ctx: *DiagApi,
    instance_id: u32,
    state: u8,
    exit_code: i32,
    expected_exit: i32,
    output_result: i32,
    reason: u32,
) void {
    ctx.sys.write("SPECTRA LIFECYCLE programlifecycle legacyMismatch id=");
    ctx.sys.printU64(instance_id);
    ctx.sys.write(" state=");
    ctx.sys.printU64(state);
    ctx.sys.write(" exit=");
    ctx.sys.printI32(exit_code);
    ctx.sys.write(" expectedExit=");
    ctx.sys.printI32(expected_exit);
    ctx.sys.write(" output=");
    ctx.sys.printI32(output_result);
    ctx.sys.write(" reason=");
    ctx.sys.printU64(reason);
    ctx.sys.write("\r\n");
}

fn legacyIdVisible(ctx: *DiagApi, instance_id: u32) bool {
    var info: r4os.abi.ProgramInstanceInfo = .{};
    // A transiently unavailable snapshot must not be mistaken for a completed
    // legacy reap.
    return inventoryProgramById(ctx, instance_id, &info) != 0;
}

fn legacyIdInfo(ctx: *DiagApi, instance_id: u32, out: *r4os.abi.ProgramInstanceInfo) bool {
    return inventoryProgramById(ctx, instance_id, out) == 1;
}

fn testLifecycleStaleReuse(ctx: *DiagApi) bool {
    const baseline = captureRuntimeBaseline(ctx) orelse return programLifecycleFail(ctx, "stale baseline unavailable");
    const registry = readProgramRegistry(ctx) orelse return programLifecycleFail(ctx, "stale registry unavailable");
    var old: r4os.abi.ProgramProcessHandle = .{};
    if (ctx.sys.programSpawnHandle(cleanup_path, route.arguments("LIFECYCLE", "/LIFECYCLEEXIT 31 0").ptr(), .auto, &old) != r4os.abi.program_handle_ok)
        return programLifecycleFail(ctx, "stale source spawn failed");
    var completion: r4os.abi.ProgramProcessCompletion = .{};
    if (ctx.sys.programHandleWait(&old, 10000, &completion) != r4os.abi.program_handle_ok or
        ctx.sys.programHandleReap(&old, &completion) != r4os.abi.program_handle_ok or completion.exit_code != 31)
        return programLifecycleFail(ctx, "stale source reap failed");

    var force: r4os.abi.ProgramRegistrySelfTestResultV2 = .{
        .operation = r4os.abi.program_registry_self_test_operation_force_next_id,
        .requested_next_id = old.instance_id,
    };
    if (ctx.dev.programRegistrySelfTestV2(&force) <= 0 or force.version != 2 or
        force.size < @sizeOf(r4os.abi.ProgramRegistrySelfTestResultV2) or
        force.operation != r4os.abi.program_registry_self_test_operation_force_next_id or
        force.lifecycle_result != r4os.abi.program_handle_ok or
        force.requested_next_id != old.instance_id or force.applied_next_id != old.instance_id or
        (force.flags & r4os.abi.program_registry_self_test_flag_allowed) == 0)
        return programLifecycleFail(ctx, "force next ID seam failed");

    var replacement: r4os.abi.ProgramProcessHandle = .{};
    defer cleanupLifecycleHandles(ctx, @as(*[1]r4os.abi.ProgramProcessHandle, @ptrCast(&replacement))[0..]);
    if (ctx.sys.programSpawnHandle(cleanup_path, route.arguments("LIFECYCLE", lifecycle_hold_arg).ptr(), .auto, &replacement) != r4os.abi.program_handle_ok or
        replacement.instance_id != old.instance_id or replacement.generation == old.generation)
        return programLifecycleFail(ctx, "forced replacement identity mismatch");

    var info: r4os.abi.ProgramInstanceInfo = .{};
    var stale_completion: r4os.abi.ProgramProcessCompletion = .{};
    if (ctx.sys.programHandleStatus(&old, &info) != r4os.abi.program_handle_error_stale or
        ctx.sys.programHandleRequestClose(&old) != r4os.abi.program_handle_error_stale or
        ctx.sys.programHandleKill(&old) != r4os.abi.program_handle_error_stale or
        ctx.sys.programHandleReap(&old, &stale_completion) != r4os.abi.program_handle_error_stale)
        return programLifecycleFail(ctx, "stale operation status mismatch");
    if (ctx.sys.programHandleStatus(&replacement, &info) != r4os.abi.program_handle_ok or info.id != replacement.instance_id)
        return programLifecycleFail(ctx, "stale handle touched replacement");
    if (ctx.sys.programHandleKill(&replacement) != r4os.abi.program_handle_ok or
        ctx.sys.programHandleWait(&replacement, 10000, &completion) != r4os.abi.program_handle_ok or
        ctx.sys.programHandleReap(&replacement, &completion) != r4os.abi.program_handle_ok or
        completion.exit_code != -9)
        return programLifecycleFail(ctx, "replacement cleanup failed");
    var missing_completion: r4os.abi.ProgramProcessCompletion = .{};
    var missing_output: [1]u8 = undefined;
    var missing_read: u32 = 0;
    if (ctx.sys.programHandleStatus(&replacement, &info) != r4os.abi.program_handle_error_not_found or
        ctx.sys.programHandleRequestClose(&replacement) != r4os.abi.program_handle_error_not_found or
        ctx.sys.programHandleKill(&replacement) != r4os.abi.program_handle_error_not_found or
        ctx.sys.programHandleWait(&replacement, 0, &missing_completion) != r4os.abi.program_handle_error_not_found or
        ctx.sys.programHandleReap(&replacement, &missing_completion) != r4os.abi.program_handle_error_not_found or
        ctx.sys.programCompletionRead(&replacement, 0, missing_output[0..], &missing_read) != r4os.abi.program_handle_error_not_found)
        return programLifecycleFail(ctx, "fully reaped operation status mismatch");
    replacement = .{};
    if (!waitLifecycleBaseline(ctx, baseline, registry, 3000))
        return programLifecycleFail(ctx, "stale baseline not restored");

    ctx.sys.println("SPECTRA LIFECYCLE programlifecycle stale idReuse=forced status=STALE close=STALE kill=STALE reap=STALE replacement=OK missing=NOT_FOUND wait=NOT_FOUND");
    return true;
}

fn testLifecycleAsyncThreads(ctx: *DiagApi) bool {
    const cycles: u32 = if (hasArg(ctx.sys.argsRaw(), "/ASYNCQUICK")) 3 else kill_wait_cycles;
    var endpoint: r4os.abi.ServiceInfo = .{};
    if (!waitForStallEndpoint(ctx, &endpoint, 3000))
        return programLifecycleFail(ctx, "lifecycle stall endpoint unavailable");
    var opened: r4os.abi.ServiceInfo = .{};
    if (ctx.sys.serviceOpen(stall_service_name, &opened) != r4os.abi.service_api_result_ok or
        opened.handle == 0 or opened.handle != endpoint.handle)
        return programLifecycleFail(ctx, "lifecycle stall endpoint open failed");
    var service_handle = opened.handle;
    defer if (service_handle != 0) {
        _ = ctx.sys.serviceClose(service_handle);
    };

    var expected_requests = opened.requests;
    const expected_responses = opened.responses;
    var expected_cancellations = opened.cancellations;
    if (hasArg(ctx.sys.argsRaw(), "/ASYNCQUICK")) {
        // Each child owns eight requests: four service workers are waiting
        // and four requests remain queued without a Task. Reuse the existing
        // exact process/thread/endpoint cleanup checks, without unrelated
        // global storage-accounting or long memory-churn acceptance.
        for (0..4) |_| {
            expected_requests += 4;
            expected_cancellations += 4;
            if (!runLifecycleKillWaitCycle(ctx, service_handle, opened.instance_id, expected_requests, expected_responses, expected_cancellations)) return false;
        }
        ctx.sys.println("SPECTRA LIFECYCLE asyncquick cycles=4 requests=8 running=4 queued=4 threads=3 owner=gone endpoint=empty");
        return true;
    }
    const cold = captureRuntimeBaseline(ctx) orelse return programLifecycleFail(ctx, "async cold baseline unavailable");
    expected_requests += 1;
    expected_cancellations += 1;
    if (!runLifecycleKillWaitCycle(ctx, service_handle, opened.instance_id, expected_requests, expected_responses, expected_cancellations))
        return false;
    const warm = captureRuntimeBaseline(ctx) orelse return programLifecycleFail(ctx, "async warm baseline unavailable");
    if (!sameTotals(cold.resources, warm.resources) or cold.instance_count != warm.instance_count or
        !sameStorageCurrent(cold.storage, warm.storage))
        return programLifecycleFail(ctx, "async warm owner baseline mismatch");

    var cycle: u32 = 0;
    while (cycle < cycles) : (cycle += 1) {
        const before = captureRuntimeBaseline(ctx) orelse return programLifecycleFail(ctx, "async cycle baseline unavailable");
        expected_requests += 1;
        expected_cancellations += 1;
        if (!runLifecycleKillWaitCycle(ctx, service_handle, opened.instance_id, expected_requests, expected_responses, expected_cancellations))
            return false;
        const after = captureRuntimeBaseline(ctx) orelse return programLifecycleFail(ctx, "async cycle final unavailable");
        if (!sameTotals(before.resources, after.resources) or !sameMemoryStable(before.memory, after.memory) or
            before.instance_count != after.instance_count or !sameStorageCurrent(before.storage, after.storage))
            return programLifecycleFail(ctx, "async/thread cycle baseline mismatch");
    }
    if (ctx.sys.serviceClose(service_handle) != r4os.abi.service_api_result_ok)
        return programLifecycleFail(ctx, "async service close failed");
    service_handle = 0;
    ctx.sys.write("SPECTRA LIFECYCLE programlifecycle async cycles=");
    ctx.sys.printU64(cycles);
    ctx.sys.println(" workers=3 blockedIo=OK cancel=OK baseline=OK");
    return true;
}

fn runLifecycleKillWaitCycle(
    ctx: *DiagApi,
    service_handle: u32,
    endpoint_id: u32,
    expected_requests: u64,
    expected_responses: u64,
    expected_cancellations: u64,
) bool {
    var args_buffer: [40:0]u8 = .{0} ** 40;
    const args = formatLifecycleKillWaitArgs(service_handle, &args_buffer);
    if (hasArg(ctx.sys.argsRaw(), "/ASYNCQUICK")) {
        const old_prefix = "/KILLWAITTHREADS ";
        const prefix = "/KILLPOOL ";
        var tail_len: usize = 0;
        while (args[old_prefix.len + tail_len] != 0) : (tail_len += 1) {}
        @memcpy(args_buffer[0..prefix.len], prefix);
        for (0..tail_len) |i| args_buffer[prefix.len + i] = args_buffer[old_prefix.len + i];
        args_buffer[prefix.len + tail_len] = 0;
    }
    var client = spawnPolicy(ctx, async_io_path, route.arguments("ASYNC_IO", args).ptr(), .auto) orelse
        return programLifecycleFail(ctx, "async/thread client spawn failed");
    defer cleanupProcess(ctx, &client);
    const client_id = client.instanceId();
    if (!waitForLifecycleClientIoWait(ctx, &client, endpoint_id, expected_requests, expected_responses, 3000))
        return programLifecycleFail(ctx, "async/thread io_wait not observed");
    if (client.kill() != r4os.abi.program_handle_ok)
        return programLifecycleFail(ctx, "async/thread client kill failed");
    switch (client.wait(finiteTimeout(5000))) {
        .exited => |code| if (code != -9) return programLifecycleFail(ctx, "async/thread kill exit mismatch"),
        else => return programLifecycleFail(ctx, "async/thread client reap failed"),
    }
    if (instanceExists(ctx, client_id) or ownerResourceBlocks(ctx, client_id) != 0)
        return programLifecycleFail(ctx, "async/thread owner survived kill");
    if (!waitForStallQueueDrained(ctx, endpoint_id, expected_requests, expected_responses, expected_cancellations, 3000))
        return programLifecycleFail(ctx, "async/thread service cancellation missing");
    return true;
}

fn waitForLifecycleClientIoWait(
    ctx: *DiagApi,
    client: *const r4os.ProcessHandle,
    endpoint_id: u32,
    expected_requests: u64,
    expected_responses: u64,
    max_ticks: u32,
) bool {
    var tick: u32 = 0;
    while (tick < max_ticks) : (tick += 1) {
        switch (client.status()) {
            .value => |instance| {
                if (instance.state == @intFromEnum(r4os.abi.ProgramInstanceState.done)) return false;
                if (instance.task_id != 0 and lifecycleClientWorkersReady(ctx, client.instanceId()) and
                    stallRequestQueued(ctx, endpoint_id, expected_requests, expected_responses) and
                    taskBlockedOnCompletion(ctx, instance.task_id)) return true;
            },
            .missing, .failure => return false,
        }
        ctx.sys.sleepTicks(1);
    }
    return false;
}

fn lifecycleClientWorkersReady(ctx: *DiagApi, instance_id: u32) bool {
    var output: [512]u8 = .{0} ** 512;
    const length = ctx.desk.consoleOutput(instance_id, output[0..]);
    if (length <= 0) return false;
    const used: usize = @intCast(@min(length, @as(i32, @intCast(output.len))));
    return containsBytes(output[0..used], "SPECTRA ASYNC_IO lifecycle workers=3 ready=OK") and
        (!hasArg(ctx.sys.argsRaw(), "/ASYNCQUICK") or containsBytes(output[0..used], "SPECTRA ASYNC_IO KILLPOOL submitted=8"));
}

fn formatLifecycleKillWaitArgs(service_handle: u32, out: *[40:0]u8) [*:0]const u8 {
    const prefix = "/KILLWAITTHREADS ";
    out.* = .{0} ** 40;
    @memcpy(out[0..prefix.len], prefix);
    var digits: [10]u8 = undefined;
    var value = service_handle;
    var count: usize = 0;
    while (true) {
        digits[count] = @intCast(value % 10);
        count += 1;
        value /= 10;
        if (value == 0) break;
    }
    var index: usize = 0;
    while (index < count) : (index += 1) out[prefix.len + index] = '0' + digits[count - index - 1];
    return @ptrCast(&out[0]);
}

fn containsBytes(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        var equal = true;
        for (haystack[start .. start + needle.len], needle) |actual, expected| {
            if (actual != expected) {
                equal = false;
                break;
            }
        }
        if (equal) return true;
    }
    return false;
}

fn testLifecycleConsoleTrees(ctx: *DiagApi) bool {
    const baseline = captureRuntimeBaseline(ctx) orelse return programLifecycleFail(ctx, "console-tree baseline unavailable");
    const registry = readProgramRegistry(ctx) orelse return programLifecycleFail(ctx, "console-tree registry unavailable");
    var close_root: r4os.abi.ProgramProcessHandle = .{};
    if (ctx.sys.programSpawnWithConsoleHostHandle(cleanup_path, route.arguments("LIFECYCLE", "/LIFECYCLEHOST 4").ptr(), .auto, .terminal_window, &close_root) != r4os.abi.program_handle_ok)
        return programLifecycleFail(ctx, "console close tree spawn failed");
    if (!waitLifecycleTreeLive(ctx, &close_root, registry.live_slots + 4, 4000))
        return programLifecycleFail(ctx, "console close tree did not reach depth four");
    if (ctx.sys.programHandleRequestClose(&close_root) != r4os.abi.program_handle_ok)
        return programLifecycleFail(ctx, "console tree close request failed");
    var completion: r4os.abi.ProgramProcessCompletion = .{};
    if (ctx.sys.programHandleWait(&close_root, 10000, &completion) != r4os.abi.program_handle_ok or
        ctx.sys.programHandleReap(&close_root, &completion) != r4os.abi.program_handle_ok or completion.exit_code != 0)
        return programLifecycleFail(ctx, "console close tree completion failed");
    if (!waitLifecycleBaseline(ctx, baseline, registry, 5000)) {
        printLifecycleBaselineMismatch(ctx, baseline, registry);
        return programLifecycleFail(ctx, "console close tree baseline not restored");
    }

    var kill_root: r4os.abi.ProgramProcessHandle = .{};
    if (ctx.sys.programSpawnWithConsoleHostHandle(cleanup_path, route.arguments("LIFECYCLE", "/LIFECYCLEHOST 4").ptr(), .auto, .terminal_window, &kill_root) != r4os.abi.program_handle_ok or
        kill_root.generation == close_root.generation)
        return programLifecycleFail(ctx, "console kill tree spawn/generation failed");
    if (!waitLifecycleTreeLive(ctx, &kill_root, registry.live_slots + 4, 4000))
        return programLifecycleFail(ctx, "console kill tree did not reach depth four");
    if (ctx.sys.programHandleKill(&kill_root) != r4os.abi.program_handle_ok or
        ctx.sys.programHandleWait(&kill_root, 10000, &completion) != r4os.abi.program_handle_ok or
        ctx.sys.programHandleReap(&kill_root, &completion) != r4os.abi.program_handle_ok or completion.exit_code != -9)
        return programLifecycleFail(ctx, "console kill tree completion failed");
    if (!waitLifecycleBaseline(ctx, baseline, registry, 5000)) {
        printLifecycleBaselineMismatch(ctx, baseline, registry);
        return programLifecycleFail(ctx, "console kill tree baseline not restored");
    }

    ctx.sys.println("SPECTRA LIFECYCLE programlifecycle consoles depth=4 close=OK kill=OK generations=OK orphanCompletions=0 baseline=OK");
    return true;
}

fn consoleWaitFixture(ctx: *DiagApi) i32 {
    var child: r4os.abi.ProgramProcessHandle = .{};
    if (hasArg(ctx.sys.argsRaw(), "/TREE")) {
        if (ctx.sys.programSpawnHandle(cleanup_path, route.arguments("LIFECYCLE", console_wait_fixture_arg).ptr(), .console, &child) != r4os.abi.program_handle_ok or
            !waitConsoleInputBlocked(ctx, &child, 3000)) return 67;
    }
    var generation: u64 = 0;
    while (!ctx.sys.programShouldClose()) {
        const rc = ctx.sys.consoleInputWait(generation, r4os.abi.io_wait_forever, &generation);
        if (rc == r4os.abi.console_input_wait_error_closed) break;
        if (rc != r4os.abi.console_input_wait_ready) return 68;
    }
    if (child.instance_id != 0) {
        _ = ctx.sys.programHandleRequestClose(&child);
        var completion: r4os.abi.ProgramProcessCompletion = .{};
        if (ctx.sys.programHandleWait(&child, 3000, &completion) != r4os.abi.program_handle_ok or
            ctx.sys.programHandleReap(&child, &completion) != r4os.abi.program_handle_ok) return 69;
    }
    return 0;
}

fn waitConsoleInputBlocked(ctx: *DiagApi, handle: *const r4os.abi.ProgramProcessHandle, max_ticks: u64) bool {
    const start = ctx.sys.ticks();
    while (ctx.sys.ticks() -% start < max_ticks) {
        var program: r4os.abi.ProgramInstanceInfo = .{};
        if (ctx.sys.programHandleStatus(handle, &program) != r4os.abi.program_handle_ok or
            program.state != @intFromEnum(r4os.abi.ProgramInstanceState.running)) return false;
        const summary = ctx.dev.performanceSummary() orelse return false;
        var index: u32 = 0;
        while (index < summary.task_max_count) : (index += 1) {
            const info = ctx.dev.performanceTask(index) orelse continue;
            if (info.id == program.task_id and info.state == task_state_blocked and
                info.blocked_object != 0 and fixedZEquals(info.wait_reason[0..], "console-input")) return true;
        }
        ctx.sys.sleepTicks(1);
    }
    return false;
}

fn testLifecycleConsoleInputWaits(ctx: *DiagApi) bool {
    var baseline: RuntimeBaseline = undefined;
    var registry = readProgramRegistry(ctx) orelse return programLifecycleFail(ctx, "consolewait registry unavailable");
    // Confirm genuine parking before Close/Kill. The tree has a child
    // borrowing the root's input namespace, not just its own execution pin.
    // Warm this exact hosted two-process shape once. Ordinary immediate-exit
    // ring warmup has different stack/cache and registry-shrink ownership.
    // Every warmup completion must still physically retire before measuring.
    for (0..3) |round| {
        for (0..3) |case| {
            var handle: r4os.abi.ProgramProcessHandle = .{};
            const args: [*:0]const u8 = if (case == 2) console_wait_fixture_arg ++ " /TREE" else console_wait_fixture_arg;
            if (ctx.sys.programSpawnWithConsoleHostHandle(cleanup_path, route.arguments("LIFECYCLE", args).ptr(), .console, .terminal_mode, &handle) != r4os.abi.program_handle_ok or
                !waitConsoleInputBlocked(ctx, &handle, 3000)) return programLifecycleFail(ctx, "consolewait parking failed");
            const close = case == 0;
            const result = if (close) ctx.sys.programHandleRequestClose(&handle) else ctx.sys.programHandleKill(&handle);
            var completion: r4os.abi.ProgramProcessCompletion = .{};
            if (result != r4os.abi.program_handle_ok or
                ctx.sys.programHandleWait(&handle, 3000, &completion) != r4os.abi.program_handle_ok or
                ctx.sys.programHandleReap(&handle, &completion) != r4os.abi.program_handle_ok or
                completion.exit_code != @as(i32, if (close) 0 else -9))
            {
                ctx.sys.write("SPECTRA LIFECYCLE consolewait failed case=");
                ctx.sys.printU64(case);
                ctx.sys.println("");
                return programLifecycleFail(ctx, "consolewait completion not physically retired");
            }
            if (round != 0 and !waitLifecycleBaseline(ctx, baseline, registry, 3000)) {
                printLifecycleBaselineMismatch(ctx, baseline, registry);
                return programLifecycleFail(ctx, "consolewait lease/resource baseline not restored");
            }
        }
        if (round == 0) {
            if (!waitLifecycleRegistryBaseline(ctx, registry, 3000))
                return programLifecycleFail(ctx, "consolewait warm registry not restored");
            ctx.sys.sleepTicks(2);
            baseline = captureRuntimeBaseline(ctx) orelse return programLifecycleFail(ctx, "consolewait warm baseline unavailable");
            registry = readProgramRegistry(ctx) orelse return programLifecycleFail(ctx, "consolewait warm registry unavailable");
        }
    }
    ctx.sys.println("SPECTRA LIFECYCLE consolewait parked=confirmed close=OK kill=OK redirected-tree-kill=OK cycles=2 baseline=OK");
    return true;
}

fn waitLifecycleTreeLive(
    ctx: *DiagApi,
    root: *const r4os.abi.ProgramProcessHandle,
    expected_live: u32,
    max_ticks: u32,
) bool {
    var tick: u32 = 0;
    while (tick < max_ticks) : (tick += 1) {
        const registry = readProgramRegistry(ctx) orelse return false;
        var info: r4os.abi.ProgramInstanceInfo = .{};
        if (registry.live_slots >= expected_live and
            ctx.sys.programHandleStatus(root, &info) == r4os.abi.program_handle_ok and
            info.id == root.instance_id) return true;
        ctx.sys.sleepTicks(1);
    }
    return false;
}

fn testLifecycleServices(ctx: *DiagApi) bool {
    const baseline = captureRuntimeBaseline(ctx) orelse return programLifecycleFail(ctx, "service baseline unavailable");
    const registry = readProgramRegistry(ctx) orelse return programLifecycleFail(ctx, "service registry unavailable");
    var info: r4os.abi.ServiceInfo = .{};

    if (ctx.sys.serviceStart("SVCEXIT0", &info) != r4os.abi.service_api_result_ok or
        !waitLifecycleServiceExit(ctx, "SVCEXIT0", 0, 4000, &info))
        return programLifecycleFail(ctx, "service exit 0 failed");
    const exit0_restarts = info.restart_count;
    if (ctx.sys.serviceRestart("SVCEXIT0", &info) != r4os.abi.service_api_result_ok or
        !waitLifecycleServiceExit(ctx, "SVCEXIT0", 0, 4000, &info) or info.restart_count <= exit0_restarts)
        return programLifecycleFail(ctx, "service exit 0 restart failed");

    if (ctx.sys.serviceStart("SVCEXIT37", &info) != r4os.abi.service_api_result_ok or
        !waitLifecycleServiceExit(ctx, "SVCEXIT37", 37, 4000, &info))
        return programLifecycleFail(ctx, "service exit 37 failed");
    const exit37_restarts = info.restart_count;
    if (ctx.sys.serviceRestart("SVCEXIT37", &info) != r4os.abi.service_api_result_ok or
        !waitLifecycleServiceExit(ctx, "SVCEXIT37", 37, 4000, &info) or info.restart_count <= exit37_restarts)
        return programLifecycleFail(ctx, "service exit 37 restart failed");

    if (!waitLifecycleBaseline(ctx, baseline, registry, 5000))
        return programLifecycleFail(ctx, "service baseline not restored");
    ctx.sys.println("SPECTRA LIFECYCLE programlifecycle services exit0=OK exit37=OK restarts=OK baseline=OK");
    return true;
}

fn waitLifecycleServiceExit(
    ctx: *DiagApi,
    name: [*:0]const u8,
    expected_exit: i32,
    max_ticks: u32,
    out: *r4os.abi.ServiceInfo,
) bool {
    var tick: u32 = 0;
    while (tick < max_ticks) : (tick += 1) {
        var info: r4os.abi.ServiceInfo = .{};
        if (ctx.sys.serviceStatus(name, &info) == r4os.abi.service_api_result_ok and
            info.instance_id == 0 and info.exit_code == expected_exit and
            (info.state == r4os.abi.service_state_stopped or info.state == r4os.abi.service_state_failed))
        {
            out.* = info;
            return true;
        }
        ctx.sys.sleepTicks(1);
    }
    return false;
}

fn testLifecycleCurrentTaskRetire(ctx: *DiagApi) bool {
    const baseline = captureRuntimeBaseline(ctx) orelse return programLifecycleFail(ctx, "current-task baseline unavailable");
    const registry = readProgramRegistry(ctx) orelse return programLifecycleFail(ctx, "current-task registry unavailable");
    var normal: r4os.abi.ProgramProcessHandle = .{};
    var completion: r4os.abi.ProgramProcessCompletion = .{};
    if (ctx.sys.programSpawnHandle(cleanup_path, route.arguments("LIFECYCLE", "/LIFECYCLEEXIT 88 0").ptr(), .auto, &normal) != r4os.abi.program_handle_ok or
        ctx.sys.programHandleWait(&normal, 10000, &completion) != r4os.abi.program_handle_ok or
        ctx.sys.programHandleReap(&normal, &completion) != r4os.abi.program_handle_ok or
        completion.exit_code != 88 or completion.exit_reason != r4os.abi.program_exit_reason_natural)
        return programLifecycleFail(ctx, "normal current-task return failed");

    if (!armLifecycleFailure(ctx, r4os.abi.program_registry_self_test_phase_detach_task))
        return programLifecycleFail(ctx, "current-task detach injection arm failed");
    var explicit: r4os.abi.ProgramProcessHandle = .{};
    if (ctx.sys.programSpawnHandle(cleanup_path, route.arguments("LIFECYCLE", lifecycle_thread_exit_arg).ptr(), .auto, &explicit) != r4os.abi.program_handle_ok)
        return programLifecycleFail(ctx, "explicit threadExit spawn failed");
    var wait_result = ctx.sys.programHandleWait(&explicit, 10000, &completion);
    if (wait_result == r4os.abi.program_handle_error_timeout) {
        if (!signalLifecycleReaper(ctx, null)) return programLifecycleFail(ctx, "current-task reaper signal failed");
        wait_result = ctx.sys.programHandleWait(&explicit, 10000, &completion);
    }
    if (wait_result != r4os.abi.program_handle_ok or
        ctx.sys.programHandleReap(&explicit, &completion) != r4os.abi.program_handle_ok or completion.exit_code != 89)
        return programLifecycleFail(ctx, "explicit threadExit completion failed");

    var signal: r4os.abi.ProgramRegistrySelfTestResultV2 = .{};
    if (!signalLifecycleReaper(ctx, &signal) or
        (signal.flags & (r4os.abi.program_registry_self_test_flag_lifecycle_consumed |
            r4os.abi.program_registry_self_test_flag_lifecycle_retried |
            r4os.abi.program_registry_self_test_flag_lifecycle_recovered)) !=
            (r4os.abi.program_registry_self_test_flag_lifecycle_consumed |
                r4os.abi.program_registry_self_test_flag_lifecycle_retried |
                r4os.abi.program_registry_self_test_flag_lifecycle_recovered))
        return programLifecycleFail(ctx, "current-task deferred retry evidence missing");
    const after = readProgramRegistry(ctx) orelse return programLifecycleFail(ctx, "current-task final registry unavailable");
    const retry_delta = after.retire_retries -| registry.retire_retries;
    if (retry_delta == 0 or after.history_sequence != registry.history_sequence + 2 or
        !waitLifecycleBaseline(ctx, baseline, registry, 3000))
        return programLifecycleFail(ctx, "current-task baseline/history mismatch");

    ctx.sys.write("SPECTRA LIFECYCLE programlifecycle deferred normal=88 threadExit=89 currentTask=OK retries=");
    ctx.sys.printU64(retry_delta);
    ctx.sys.println("");
    return true;
}

fn armLifecycleFailure(ctx: *DiagApi, phase: u32) bool {
    var request: r4os.abi.ProgramRegistrySelfTestResultV2 = .{
        .operation = r4os.abi.program_registry_self_test_operation_arm_lifecycle_failure,
        .lifecycle_phase = phase,
    };
    return ctx.dev.programRegistrySelfTestV2(&request) > 0 and
        request.version == 2 and request.size >= @sizeOf(r4os.abi.ProgramRegistrySelfTestResultV2) and
        request.operation == r4os.abi.program_registry_self_test_operation_arm_lifecycle_failure and
        request.lifecycle_phase == phase and request.lifecycle_result == r4os.abi.program_handle_ok and
        (request.flags & (r4os.abi.program_registry_self_test_flag_allowed |
            r4os.abi.program_registry_self_test_flag_one_shot |
            r4os.abi.program_registry_self_test_flag_lifecycle_armed)) ==
            (r4os.abi.program_registry_self_test_flag_allowed |
                r4os.abi.program_registry_self_test_flag_one_shot |
                r4os.abi.program_registry_self_test_flag_lifecycle_armed);
}

fn signalLifecycleReaper(ctx: *DiagApi, out: ?*r4os.abi.ProgramRegistrySelfTestResultV2) bool {
    var request: r4os.abi.ProgramRegistrySelfTestResultV2 = .{
        .operation = r4os.abi.program_registry_self_test_operation_signal_reaper,
    };
    if (ctx.dev.programRegistrySelfTestV2(&request) <= 0 or request.version != 2 or
        request.size < @sizeOf(r4os.abi.ProgramRegistrySelfTestResultV2) or
        request.operation != r4os.abi.program_registry_self_test_operation_signal_reaper or
        request.lifecycle_result != r4os.abi.program_handle_ok or
        (request.flags & r4os.abi.program_registry_self_test_flag_allowed) == 0)
        return false;
    if (out) |destination| destination.* = request;
    return true;
}

fn testLifecycleFailurePhases(ctx: *DiagApi) bool {
    var phase: u32 = r4os.abi.program_registry_self_test_phase_completion_reserve;
    while (phase <= r4os.abi.program_registry_self_test_phase_publish) : (phase += 1) {
        const baseline = captureRuntimeBaseline(ctx) orelse return programLifecycleFail(ctx, "spawn failure baseline unavailable");
        const registry = readProgramRegistry(ctx) orelse return programLifecycleFail(ctx, "spawn failure registry unavailable");
        if (!armLifecycleFailure(ctx, phase)) return programLifecycleFail(ctx, "spawn failure phase arm failed");
        var unexpected: r4os.abi.ProgramProcessHandle = .{};
        if (ctx.sys.programSpawnHandle(cleanup_path, route.arguments("LIFECYCLE", "/LIFECYCLEEXIT 0 0").ptr(), .auto, &unexpected) == r4os.abi.program_handle_ok or
            unexpected.instance_id != 0)
            return programLifecycleFail(ctx, "spawn failure phase published an instance");
        var observed: r4os.abi.ProgramRegistrySelfTestResultV2 = .{};
        if (!signalLifecycleReaper(ctx, &observed) or
            observed.lifecycle_phase != phase or
            (observed.flags & r4os.abi.program_registry_self_test_flag_lifecycle_consumed) == 0 or
            observed.history_sequence_after != registry.history_sequence)
            return programLifecycleFail(ctx, "spawn failure phase was not consumed atomically");
        if (!waitLifecycleBaseline(ctx, baseline, registry, 3000))
            return programLifecycleFail(ctx, "spawn failure rollback baseline mismatch");
    }

    var deferred_count: u32 = 0;
    var retire_retry_delta: u64 = 0;
    phase = r4os.abi.program_registry_self_test_phase_exit_commit;
    while (phase <= r4os.abi.program_registry_self_test_phase_slot_reclaim) : (phase += 1) {
        const baseline = captureRuntimeBaseline(ctx) orelse return programLifecycleFail(ctx, "retire failure baseline unavailable");
        const registry = readProgramRegistry(ctx) orelse return programLifecycleFail(ctx, "retire failure registry unavailable");
        if (!armLifecycleFailure(ctx, phase)) return programLifecycleFail(ctx, "retire failure phase arm failed");
        var handle: r4os.abi.ProgramProcessHandle = .{};
        if (ctx.sys.programSpawnHandle(cleanup_path, route.arguments("LIFECYCLE", "/LIFECYCLEEXIT 47 0").ptr(), .auto, &handle) != r4os.abi.program_handle_ok)
            return programLifecycleFail(ctx, "retire failure child spawn failed");
        var completion: r4os.abi.ProgramProcessCompletion = .{};
        var waited = ctx.sys.programHandleWait(&handle, 10000, &completion);
        if (waited == r4os.abi.program_handle_error_timeout) {
            if (!signalLifecycleReaper(ctx, null)) return programLifecycleFail(ctx, "retire failure reaper signal failed");
            waited = ctx.sys.programHandleWait(&handle, 10000, &completion);
        }
        if (waited != r4os.abi.program_handle_ok or completion.exit_code != 47 or
            ctx.sys.programHandleReap(&handle, &completion) != r4os.abi.program_handle_ok)
            return programLifecycleFail(ctx, "retire failure completion/reap failed");
        var observed: r4os.abi.ProgramRegistrySelfTestResultV2 = .{};
        if (!signalLifecycleReaper(ctx, &observed) or observed.lifecycle_phase != phase or
            (observed.flags & (r4os.abi.program_registry_self_test_flag_lifecycle_consumed |
                r4os.abi.program_registry_self_test_flag_lifecycle_recovered)) !=
                (r4os.abi.program_registry_self_test_flag_lifecycle_consumed |
                    r4os.abi.program_registry_self_test_flag_lifecycle_recovered) or
            observed.history_sequence_after != registry.history_sequence + 1)
            return programLifecycleFail(ctx, "retire failure recovery evidence missing");
        const after = readProgramRegistry(ctx) orelse return programLifecycleFail(ctx, "retire failure final registry unavailable");
        if (phase >= r4os.abi.program_registry_self_test_phase_cancel_execution) {
            if (after.retire_retries <= registry.retire_retries or
                (observed.flags & r4os.abi.program_registry_self_test_flag_lifecycle_retried) == 0)
                return programLifecycleFail(ctx, "retire failure did not retry");
            retire_retry_delta += after.retire_retries - registry.retire_retries;
        }
        deferred_count += 1;
        if (!waitLifecycleBaseline(ctx, baseline, registry, 3000))
            return programLifecycleFail(ctx, "retire failure baseline mismatch");
    }
    if (deferred_count != 7 or retire_retry_delta == 0)
        return programLifecycleFail(ctx, "retire failure coverage count mismatch");

    var reset: r4os.abi.ProgramRegistrySelfTestResultV2 = .{
        .operation = r4os.abi.program_registry_self_test_operation_reset,
    };
    if (ctx.dev.programRegistrySelfTestV2(&reset) <= 0)
        return programLifecycleFail(ctx, "lifecycle self-test reset failed");
    ctx.sys.println("SPECTRA LIFECYCLE programlifecycle injection phases=13 spawnRollback=6 deferred=7 historyOnce=OK baseline=OK");
    return true;
}

fn cleanupLifecycleHandles(ctx: *DiagApi, handles: []r4os.abi.ProgramProcessHandle) void {
    for (handles) |*handle| {
        if (handle.instance_id == 0) continue;
        _ = ctx.sys.programHandleKill(handle);
        var completion: r4os.abi.ProgramProcessCompletion = .{};
        if (ctx.sys.programHandleWait(handle, 2000, &completion) == r4os.abi.program_handle_ok)
            _ = ctx.sys.programHandleReap(handle, &completion);
        handle.* = .{};
    }
}

fn sameLifecycleHandle(a: r4os.abi.ProgramProcessHandle, b: r4os.abi.ProgramProcessHandle) bool {
    return a.instance_id == b.instance_id and a.generation == b.generation and a.reserved == 0 and b.reserved == 0;
}

fn waitLifecycleRegistryBaseline(
    ctx: *DiagApi,
    baseline: r4os.abi.ProgramRegistrySummaryV2,
    max_ticks: u32,
) bool {
    var tick: u32 = 0;
    while (tick < max_ticks) : (tick += 1) {
        const summary = readProgramRegistry(ctx) orelse return false;
        if (summary.reserved_slots == baseline.reserved_slots and
            summary.live_slots == baseline.live_slots and
            summary.done_slots == baseline.done_slots and
            summary.retiring_slots == baseline.retiring_slots and
            summary.completion_pending == baseline.completion_pending and
            summary.completion_ready == baseline.completion_ready and
            summary.completion_output_bytes == baseline.completion_output_bytes and
            summary.retire_queued == baseline.retire_queued)
            return true;
        ctx.sys.sleepTicks(1);
    }
    return false;
}

fn waitLifecycleBaseline(
    ctx: *DiagApi,
    baseline: RuntimeBaseline,
    registry: r4os.abi.ProgramRegistrySummaryV2,
    max_ticks: u32,
) bool {
    var tick: u32 = 0;
    while (tick < max_ticks) : (tick += 1) {
        const current = captureRuntimeBaseline(ctx) orelse return false;
        const current_registry = readProgramRegistry(ctx) orelse return false;
        if (sameTotals(baseline.resources, current.resources) and
            sameMemoryStable(baseline.memory, current.memory) and
            sameLifecycleStorageCurrent(baseline.storage, current.storage) and
            baseline.instance_count == current.instance_count and
            current_registry.reserved_slots == registry.reserved_slots and
            current_registry.live_slots == registry.live_slots and
            current_registry.done_slots == registry.done_slots and
            current_registry.retiring_slots == registry.retiring_slots and
            current_registry.completion_pending == registry.completion_pending and
            current_registry.completion_ready == registry.completion_ready and
            current_registry.completion_output_bytes == registry.completion_output_bytes and
            current_registry.retire_queued == registry.retire_queued)
            return true;
        ctx.sys.sleepTicks(1);
    }
    return false;
}

fn printLifecycleBaselineMismatch(
    ctx: *DiagApi,
    baseline: RuntimeBaseline,
    registry: r4os.abi.ProgramRegistrySummaryV2,
) void {
    const current = captureRuntimeBaseline(ctx) orelse {
        ctx.sys.println("SPECTRA LIFECYCLE programlifecycle baselineMismatch current=unavailable");
        return;
    };
    const current_registry = readProgramRegistry(ctx) orelse {
        ctx.sys.println("SPECTRA LIFECYCLE programlifecycle baselineMismatch registry=unavailable");
        return;
    };

    ctx.sys.write("SPECTRA LIFECYCLE programlifecycle baselineMismatch equal resources=");
    ctx.sys.printU64(if (sameTotals(baseline.resources, current.resources)) 1 else 0);
    ctx.sys.write(" memory=");
    ctx.sys.printU64(if (sameMemoryStable(baseline.memory, current.memory)) 1 else 0);
    ctx.sys.write(" storage=");
    ctx.sys.printU64(if (sameLifecycleStorageCurrent(baseline.storage, current.storage)) 1 else 0);
    ctx.sys.write(" instances=");
    printLifecycleValuePair(ctx, baseline.instance_count, current.instance_count);
    ctx.sys.write("\r\n");

    ctx.sys.write("SPECTRA LIFECYCLE programlifecycle baselineMismatch registry chunks=");
    printLifecycleValuePair(ctx, registry.chunk_count, current_registry.chunk_count);
    ctx.sys.write(" free=");
    printLifecycleValuePair(ctx, registry.free_slots, current_registry.free_slots);
    ctx.sys.write(" reserved=");
    printLifecycleValuePair(ctx, registry.reserved_slots, current_registry.reserved_slots);
    ctx.sys.write(" live=");
    printLifecycleValuePair(ctx, registry.live_slots, current_registry.live_slots);
    ctx.sys.write(" done=");
    printLifecycleValuePair(ctx, registry.done_slots, current_registry.done_slots);
    ctx.sys.write(" retiring=");
    printLifecycleValuePair(ctx, registry.retiring_slots, current_registry.retiring_slots);
    ctx.sys.write(" pending=");
    printLifecycleValuePair(ctx, registry.completion_pending, current_registry.completion_pending);
    ctx.sys.write(" ready=");
    printLifecycleValuePair(ctx, registry.completion_ready, current_registry.completion_ready);
    ctx.sys.write(" output=");
    printLifecycleValuePair(ctx, registry.completion_output_bytes, current_registry.completion_output_bytes);
    ctx.sys.write(" queue=");
    printLifecycleValuePair(ctx, registry.retire_queued, current_registry.retire_queued);
    ctx.sys.write("\r\n");

    ctx.sys.write("SPECTRA LIFECYCLE programlifecycle baselineMismatch resources blocks=");
    printLifecycleValuePair(ctx, baseline.resources.blocks, current.resources.blocks);
    ctx.sys.write(" images=");
    printLifecycleValuePair(ctx, baseline.resources.program_images, current.resources.program_images);
    ctx.sys.write(" vm=");
    printLifecycleValuePair(ctx, baseline.resources.vm_ranges, current.resources.vm_ranges);
    ctx.sys.write(" stacks=");
    printLifecycleValuePair(ctx, baseline.resources.app_stacks, current.resources.app_stacks);
    ctx.sys.write(" reserved=");
    printLifecycleValuePair(ctx, baseline.resources.reserved, current.resources.reserved);
    ctx.sys.write(" committed=");
    printLifecycleValuePair(ctx, baseline.resources.committed, current.resources.committed);
    ctx.sys.write(" physical=");
    printLifecycleValuePair(ctx, baseline.resources.physical, current.resources.physical);
    ctx.sys.write(" virtual=");
    printLifecycleValuePair(ctx, baseline.resources.virtual, current.resources.virtual);
    ctx.sys.write("\r\n");

    ctx.sys.write("SPECTRA LIFECYCLE programlifecycle baselineMismatch memory blocks=");
    printLifecycleValuePair(ctx, baseline.memory.active_blocks, current.memory.active_blocks);
    ctx.sys.write(" physical=");
    printLifecycleValuePair(ctx, baseline.memory.physical_bytes, current.memory.physical_bytes);
    ctx.sys.write(" virtual=");
    printLifecycleValuePair(ctx, baseline.memory.virtual_bytes, current.memory.virtual_bytes);
    ctx.sys.write(" reserved=");
    printLifecycleValuePair(ctx, baseline.memory.reserved_bytes, current.memory.reserved_bytes);
    ctx.sys.write(" committed=");
    printLifecycleValuePair(ctx, baseline.memory.committed_bytes, current.memory.committed_bytes);
    ctx.sys.write(" free=");
    printLifecycleValuePair(ctx, baseline.memory.free_physical_bytes, current.memory.free_physical_bytes);
    ctx.sys.write(" largestPhysBase=");
    printLifecycleValuePair(ctx, baseline.memory.largest_free_phys_base, current.memory.largest_free_phys_base);
    ctx.sys.write(" largestPhysLen=");
    printLifecycleValuePair(ctx, baseline.memory.largest_free_phys_len, current.memory.largest_free_phys_len);
    ctx.sys.write(" largestVmBase=");
    printLifecycleValuePair(ctx, baseline.memory.largest_free_virtual_base, current.memory.largest_free_virtual_base);
    ctx.sys.write(" largestVmLen=");
    printLifecycleValuePair(ctx, baseline.memory.largest_free_virtual_len, current.memory.largest_free_virtual_len);
    ctx.sys.write(" reserveFrames=");
    printLifecycleValuePair(ctx, baseline.memory.app_system_reserve_frames, current.memory.app_system_reserve_frames);
    ctx.sys.write(" availableFrames=");
    printLifecycleValuePair(ctx, baseline.memory.app_available_frames, current.memory.app_available_frames);
    ctx.sys.write("\r\n");

    ctx.sys.write("SPECTRA LIFECYCLE programlifecycle baselineMismatch storage registryBytes=");
    printLifecycleValuePair(ctx, baseline.storage.registry_reserved_core_bytes, current.storage.registry_reserved_core_bytes);
    ctx.sys.write(" liveCore=");
    printLifecycleValuePair(ctx, baseline.storage.live_core_bytes, current.storage.live_core_bytes);
    ctx.sys.write(" activeBytes=");
    printLifecycleValuePair(ctx, baseline.storage.active_instance_bytes, current.storage.active_instance_bytes);
    ctx.sys.write(" reservedBytes=");
    printLifecycleValuePair(ctx, baseline.storage.reserved_instance_bytes, current.storage.reserved_instance_bytes);
    ctx.sys.write(" payloadBytes=");
    printLifecycleValuePair(ctx, baseline.storage.current_payload_bytes, current.storage.current_payload_bytes);
    ctx.sys.write(" runtimeBytes=");
    printLifecycleValuePair(ctx, baseline.storage.current_runtime_bytes, current.storage.current_runtime_bytes);
    ctx.sys.write(" consoleBytes=");
    printLifecycleValuePair(ctx, baseline.storage.current_console_bytes, current.storage.current_console_bytes);
    ctx.sys.write(" outputPayloads=");
    printLifecycleValuePair(ctx, baseline.storage.console_output_payloads, current.storage.console_output_payloads);
    ctx.sys.write("\r\n");
}

fn printLifecycleValuePair(ctx: *DiagApi, baseline: anytype, current: @TypeOf(baseline)) void {
    ctx.sys.printU64(@intCast(baseline));
    ctx.sys.write("/");
    ctx.sys.printU64(@intCast(current));
}

fn sameLifecycleStorageCurrent(
    baseline: r4os.abi.ProgramInstanceStorageSummary,
    actual: r4os.abi.ProgramInstanceStorageSummary,
) bool {
    var normalized = actual;
    normalized.allocation_failures = baseline.allocation_failures;
    normalized.transaction_rollbacks = baseline.transaction_rollbacks;
    return sameStorageCurrent(baseline, normalized);
}

fn programLifecycleFail(ctx: *DiagApi, message: []const u8) bool {
    ctx.sys.write("SPECTRA LIFECYCLE programlifecycle FAILED: ");
    ctx.sys.write(message);
    ctx.sys.write("\r\n");
    ctx.sys.println("SPECTRA LIFECYCLE programlifecycle result: FAILED");
    return false;
}

fn registryHold(ctx: *DiagApi) i32 {
    while (!ctx.sys.programShouldClose()) ctx.sys.sleepTicks(1);
    return 0;
}

fn runDynamicProgramRegistry(ctx: *DiagApi) bool {
    if (!ctx.dev.hasFn("program_registry_summary"))
        return programRegistryFail(ctx, "R4DEV registry summary missing");
    if (!ctx.dev.hasFn("program_registry_self_test"))
        return programRegistryFail(ctx, "R4DEV registry self-test missing");

    const resources_before = captureResourceBaseline(ctx) orelse
        return programRegistryFail(ctx, "resource baseline unavailable");
    const baseline = readProgramRegistry(ctx) orelse
        return programRegistryFail(ctx, "registry baseline unavailable");
    var held: [registry_hold_capacity]?r4os.ProcessHandle = .{null} ** registry_hold_capacity;
    var held_count: usize = 0;
    defer cleanupRegistryProcesses(ctx, held[0..], &held_count);
    defer resetProgramRegistryTest(ctx);

    ctx.sys.println("SPECTRA LIFECYCLE programregistry begin");

    while (held_count < registry_concurrency_target) {
        const process = spawnPolicy(ctx, cleanup_path, route.arguments("LIFECYCLE", registry_hold_arg).ptr(), .auto) orelse
            return programRegistryFail(ctx, "concurrency spawn failed");
        const held_index = held_count;
        held[held_index] = process;
        held_count += 1;
        if (!waitForClass(ctx, &held[held_index].?, .console, true, 1000))
            return programRegistryFail(ctx, "concurrency child did not remain running");
    }
    if (!verifyRegistryProcesses(ctx, held[0..held_count]))
        return programRegistryFail(ctx, "concurrency process set invalid");
    const concurrent = readProgramRegistry(ctx) orelse
        return programRegistryFail(ctx, "concurrency registry summary unavailable");
    ctx.sys.write("SPECTRA LIFECYCLE programregistry trace baselineLive=");
    ctx.sys.printU64(baseline.live_slots);
    ctx.sys.write(" live=");
    ctx.sys.printU64(concurrent.live_slots);
    ctx.sys.write(" peak=");
    ctx.sys.printU64(concurrent.peak_live);
    ctx.sys.write(" capacity=");
    ctx.sys.printU64(concurrent.slot_capacity);
    ctx.sys.write(" chunks=");
    ctx.sys.printU64(concurrent.chunk_count);
    ctx.sys.write(" idChanged=");
    ctx.sys.write(if (concurrent.live_id_hash != baseline.live_id_hash) "yes" else "no");
    ctx.sys.write(" addressChanged=");
    ctx.sys.println(if (concurrent.live_address_hash != baseline.live_address_hash) "yes" else "no");
    if (concurrent.live_slots < baseline.live_slots + registry_concurrency_target or
        concurrent.peak_live < concurrent.live_slots or
        concurrent.slot_capacity < 32 or
        concurrent.live_id_hash == baseline.live_id_hash or
        concurrent.live_address_hash == baseline.live_address_hash)
        return programRegistryFail(ctx, "concurrency registry accounting mismatch");

    ctx.sys.write("SPECTRA LIFECYCLE programregistry concurrency holds=");
    ctx.sys.printU64(registry_concurrency_target);
    ctx.sys.write(" live=");
    ctx.sys.printU64(concurrent.live_slots);
    ctx.sys.write(" capacity=");
    ctx.sys.printU64(concurrent.slot_capacity);
    ctx.sys.write(" chunks=");
    ctx.sys.printU64(concurrent.chunk_count);
    ctx.sys.println(" status=OK");

    // Fill only the currently allocated chunks. The following spawn must then
    // request one new chunk and hit the one-shot allocator failure.
    while (true) {
        const current = readProgramRegistry(ctx) orelse
            return programRegistryFail(ctx, "fill registry summary unavailable");
        if (current.free_slots == 0) break;
        if (held_count >= held.len)
            return programRegistryFail(ctx, "registry boundary exceeds diagnostic capacity");
        const process = spawnPolicy(ctx, cleanup_path, route.arguments("LIFECYCLE", registry_hold_arg).ptr(), .auto) orelse
            return programRegistryFail(ctx, "boundary fill spawn failed");
        const held_index = held_count;
        held[held_index] = process;
        held_count += 1;
        if (!waitForClass(ctx, &held[held_index].?, .console, true, 1000))
            return programRegistryFail(ctx, "boundary child did not remain running");
    }

    const oom_before = readProgramRegistry(ctx) orelse
        return programRegistryFail(ctx, "OOM baseline unavailable");
    if (oom_before.free_slots != 0 or oom_before.reserved_slots != 0 or
        oom_before.done_slots != 0 or oom_before.retiring_slots != 0 or
        oom_before.live_slots < baseline.live_slots + registry_concurrency_target or
        !verifyRegistryProcesses(ctx, held[0..held_count]))
        return programRegistryFail(ctx, "OOM baseline not quiescent");

    var arm: r4os.abi.ProgramRegistrySelfTestResultV2 = .{
        .operation = r4os.abi.program_registry_self_test_operation_arm_next_growth,
    };
    if (ctx.dev.programRegistrySelfTestV2(&arm) <= 0 or
        arm.version != 2 or arm.size < @sizeOf(r4os.abi.ProgramRegistrySelfTestResultV2) or
        arm.operation != r4os.abi.program_registry_self_test_operation_arm_next_growth or
        (arm.flags & (r4os.abi.program_registry_self_test_flag_allowed |
            r4os.abi.program_registry_self_test_flag_armed |
            r4os.abi.program_registry_self_test_flag_one_shot)) !=
            (r4os.abi.program_registry_self_test_flag_allowed |
                r4os.abi.program_registry_self_test_flag_armed |
                r4os.abi.program_registry_self_test_flag_one_shot) or
        arm.chunk_count_before != oom_before.chunk_count or
        arm.slot_capacity_before != oom_before.slot_capacity or
        arm.free_slots_before != 0)
        return programRegistryFail(ctx, "one-shot OOM arm failed");

    const armed = readProgramRegistry(ctx) orelse
        return programRegistryFail(ctx, "armed registry summary unavailable");
    if ((armed.flags & r4os.abi.program_registry_summary_flag_failure_armed) == 0)
        return programRegistryFail(ctx, "one-shot OOM flag not visible");

    var unexpected: ?r4os.ProcessHandle = null;
    var path = r4os.FilePath.parse(cleanup_path) catch
        return programRegistryFail(ctx, "registry fixture path invalid");
    const failed_spawn = switch (ctx.resources.spawn(path.asZ(), route.arguments("LIFECYCLE", registry_hold_arg).ptr(), .auto)) {
        .failure => |raw| raw,
        .process => |process| blk: {
            unexpected = process;
            break :blk 0;
        },
    };
    if (unexpected) |*process| cleanupProcess(ctx, process);
    if (failed_spawn >= 0)
        return programRegistryFail(ctx, "forced registry OOM accepted spawn");

    const oom_after = readProgramRegistry(ctx) orelse
        return programRegistryFail(ctx, "post-OOM registry summary unavailable");
    if ((oom_after.flags & r4os.abi.program_registry_summary_flag_failure_armed) != 0 or
        oom_after.chunk_count != oom_before.chunk_count or
        oom_after.slot_capacity != oom_before.slot_capacity or
        oom_after.live_slots != oom_before.live_slots or
        oom_after.live_id_hash != oom_before.live_id_hash or
        oom_after.live_address_hash != oom_before.live_address_hash or
        oom_after.growth_failures != oom_before.growth_failures + 1 or
        oom_after.forced_failures != oom_before.forced_failures + 1 or
        oom_after.last_admission_error == 0 or
        !verifyRegistryProcesses(ctx, held[0..held_count]))
        return programRegistryFail(ctx, "forced registry OOM changed live set");

    ctx.sys.write("SPECTRA LIFECYCLE programregistry oom forced=1 existing=");
    ctx.sys.printU64(held_count);
    ctx.sys.println(" ids=stable addresses=stable admission=FAILED intact=OK");

    // Free one real slot and prove that normal admission immediately recovers.
    const released_index = held_count - 1;
    var released = &held[released_index].?;
    if (released.kill() != 0) return programRegistryFail(ctx, "recovery release kill failed");
    switch (released.wait(finiteTimeout(4000))) {
        .exited => {},
        else => return programRegistryFail(ctx, "recovery release reap failed"),
    }
    held[released_index] = null;
    held_count -= 1;

    const freed = readProgramRegistry(ctx) orelse
        return programRegistryFail(ctx, "recovery free summary unavailable");
    if (freed.free_slots == 0 or freed.live_slots + 1 != oom_after.live_slots)
        return programRegistryFail(ctx, "registry slot was not released");

    const replacement = spawnPolicy(ctx, cleanup_path, route.arguments("LIFECYCLE", registry_hold_arg).ptr(), .auto) orelse
        return programRegistryFail(ctx, "spawn did not recover after slot release");
    const replacement_index = held_count;
    held[replacement_index] = replacement;
    held_count += 1;
    if (!waitForClass(ctx, &held[replacement_index].?, .console, true, 1000))
        return programRegistryFail(ctx, "replacement child did not remain running");
    const recovered = readProgramRegistry(ctx) orelse
        return programRegistryFail(ctx, "recovery registry summary unavailable");
    if (recovered.live_slots != oom_after.live_slots or
        recovered.growth_failures != oom_after.growth_failures or
        recovered.forced_failures != oom_after.forced_failures or
        recovered.publish_count <= oom_after.publish_count or
        !verifyRegistryProcesses(ctx, held[0..held_count]))
        return programRegistryFail(ctx, "recovery spawn accounting mismatch");
    ctx.sys.println("SPECTRA LIFECYCLE programregistry recovery release=1 spawn=OK oneShot=reset");

    cleanupRegistryProcesses(ctx, held[0..], &held_count);
    resetProgramRegistryTest(ctx);
    const final = readProgramRegistry(ctx) orelse
        return programRegistryFail(ctx, "final registry summary unavailable");
    if (final.live_slots != baseline.live_slots or
        final.live_id_hash != baseline.live_id_hash or
        final.live_address_hash != baseline.live_address_hash or
        final.reserved_slots != baseline.reserved_slots or
        final.done_slots != baseline.done_slots or
        final.retiring_slots != baseline.retiring_slots or
        (final.flags & r4os.abi.program_registry_summary_flag_failure_armed) != 0 or
        !resourceBaselineRestored(ctx, resources_before))
        return programRegistryFail(ctx, "final registry baseline not restored");

    ctx.sys.write("SPECTRA LIFECYCLE programregistry cleanup live=");
    ctx.sys.printU64(final.live_slots);
    ctx.sys.write(" capacity=");
    ctx.sys.printU64(final.slot_capacity);
    ctx.sys.println(" handles=OK baseline=OK");
    ctx.sys.println("SPECTRA LIFECYCLE programregistry result: OK");
    return true;
}

fn readProgramRegistry(ctx: *DiagApi) ?r4os.abi.ProgramRegistrySummaryV2 {
    var out: r4os.abi.ProgramRegistrySummaryV2 = .{};
    if (ctx.dev.programRegistrySummaryV2(&out) <= 0) return null;
    if (out.version != 2 or out.size < @sizeOf(r4os.abi.ProgramRegistrySummaryV2) or
        out.chunk_slots == 0 or out.chunk_count == 0 or
        out.slot_capacity != out.chunk_slots * out.chunk_count or
        out.free_slots + out.reserved_slots + out.live_slots + out.done_slots + out.retiring_slots != out.slot_capacity or
        out.warm_chunks < 2 or out.chunk_slots * out.warm_chunks < 32 or
        out.peak_chunks < out.chunk_count or
        out.peak_live < out.live_slots or out.growth_failures > out.growth_attempts or
        out.forced_failures > out.growth_failures)
        return null;
    return out;
}

fn verifyRegistryProcesses(ctx: *DiagApi, held: []const ?r4os.ProcessHandle) bool {
    for (held, 0..) |entry, index| {
        const process = entry orelse return false;
        switch (process.status()) {
            .value => |info| {
                if (info.id != process.instanceId() or
                    info.app_class != @intFromEnum(r4os.abi.ProgramInstanceClass.console) or
                    info.state != @intFromEnum(r4os.abi.ProgramInstanceState.running))
                    return false;
            },
            .missing, .failure => return false,
        }
        var prior: usize = 0;
        while (prior < index) : (prior += 1) {
            if (held[prior].?.instanceId() == process.instanceId()) return false;
        }
    }
    _ = ctx;
    return true;
}

fn cleanupRegistryProcesses(ctx: *DiagApi, held: []?r4os.ProcessHandle, held_count: *usize) void {
    while (held_count.* != 0) {
        held_count.* -= 1;
        if (held[held_count.*]) |*process| cleanupProcess(ctx, process);
        held[held_count.*] = null;
    }
}

fn resetProgramRegistryTest(ctx: *DiagApi) void {
    var reset: r4os.abi.ProgramRegistrySelfTestResultV2 = .{
        .operation = r4os.abi.program_registry_self_test_operation_reset,
    };
    _ = ctx.dev.programRegistrySelfTestV2(&reset);
}

fn programRegistryFail(ctx: *DiagApi, msg: []const u8) bool {
    ctx.sys.write("SPECTRA LIFECYCLE programregistry FAILED: ");
    ctx.sys.write(msg);
    ctx.sys.write("\r\n");
    ctx.sys.println("SPECTRA LIFECYCLE programregistry result: FAILED");
    _ = fail(ctx, msg);
    return false;
}

fn guiPayloadHold(ctx: *DiagApi) i32 {
    if (ctx.draw.guiClear(0x0010_1010) <= 0)
        return fail(ctx, "GUI payload fixture command allocation failed");
    if (ctx.draw.guiBlit(0, 0, 2, 2, 1, gui_payload_pixels[0..]) <= 0)
        return fail(ctx, "GUI payload fixture raster allocation failed");
    if (ctx.draw.guiPresent() < 0)
        return fail(ctx, "GUI payload fixture present failed");
    ctx.sys.println("SPECTRA LIFECYCLE gui-payload fixture: ready");
    while (!ctx.sys.programShouldClose()) ctx.sys.sleepTicks(1);
    ctx.sys.println("SPECTRA LIFECYCLE gui-payload fixture: done");
    return 0;
}

fn guiRasterChainHold(ctx: *DiagApi) i32 {
    if (ctx.draw.guiClear(0x0010_1010) <= 0)
        return fail(ctx, "GUI raster-chain fixture command allocation failed");
    var tile: u32 = 0;
    while (tile < gui_raster_chain_tile_count) : (tile += 1) {
        const x: i32 = @intCast((tile % 2) * gui_raster_chain_tile_width);
        const y: i32 = @intCast((tile / 2) * gui_raster_chain_tile_height);
        if (ctx.draw.guiBlit(
            x,
            y,
            gui_raster_chain_tile_width,
            gui_raster_chain_tile_height,
            1,
            gui_raster_chain_pixels[0..],
        ) <= 0) return fail(ctx, "GUI raster-chain fixture append failed");
    }
    if (ctx.draw.guiPresent() < 0)
        return fail(ctx, "GUI raster-chain fixture present failed");
    ctx.sys.println("SPECTRA LIFECYCLE gui-raster-chain fixture: ready");
    while (!ctx.sys.programShouldClose()) ctx.sys.sleepTicks(1);
    ctx.sys.println("SPECTRA LIFECYCLE gui-raster-chain fixture: done");
    return 0;
}

const gui_frame_batch_commands: usize = 257;
const gui_frame_batch_rounds: usize = 16;
const gui_frame_rect_commands: usize = gui_frame_batch_commands * gui_frame_batch_rounds;
const gui_frame_mixed_resource_bytes: usize = 138;
const gui_frame_total_command_count: usize = gui_frame_rect_commands + 4;
const gui_frame_total_commands: u64 = gui_frame_total_command_count;

fn guiFrameHold(ctx: *DiagApi) i32 {
    if (!ctx.draw.supportsGuiFrameContract()) return fail(ctx, "GUI frame contract unavailable");
    if (ctx.draw.guiFrameBegin() != r4os.abi.gui_frame_result_ok)
        return fail(ctx, "GUI frame fixture begin failed");
    var building = true;
    defer {
        if (building) _ = ctx.draw.guiFrameCancel();
    }

    var commands = [_]r4os.abi.GuiFrameCommand{.{}} ** gui_frame_batch_commands;
    var round: usize = 0;
    while (round < gui_frame_batch_rounds) : (round += 1) {
        for (&commands, 0..) |*command, index| {
            const logical_index = round * gui_frame_batch_commands + index;
            command.* = .{
                .kind = r4os.abi.gui_frame_command_kind_rect,
                .x = @intCast(logical_index % 640),
                .y = @intCast((logical_index / 640) % 400),
                .w = 1,
                .h = 1,
                .rgb = 0x0010_2040 + @as(u32, @intCast(logical_index & 0xFF)),
            };
        }
        if (ctx.draw.guiFrameAppend(commands[0..], &.{}) != r4os.abi.gui_frame_result_ok)
            return fail(ctx, "GUI frame fixture command growth failed");
    }

    var resources = [_]u8{0} ** gui_frame_mixed_resource_bytes;
    resources[0] = 0xEE;
    resources[1] = 0x33;
    resources[2] = 0x22;
    resources[3] = 0x11;
    resources[4] = 0;
    @memset(resources[5..134], 'A');
    resources[134] = 0x10;
    resources[135] = 0x40;
    resources[136] = 0x80;
    resources[137] = 0xFF;
    const mixed = [_]r4os.abi.GuiFrameCommand{
        .{ .kind = r4os.abi.gui_frame_command_kind_clear, .rgb = 0x00FF_FFFF },
        .{
            .kind = r4os.abi.gui_frame_command_kind_text,
            .x = 8,
            .y = 8,
            .fg = 0,
            .bg = 0x00FF_FFFF,
            .text_w = 1032,
            .text_h = 16,
            .baseline = 12,
            .line_height = 16,
            .resource_offset = 5,
            .resource_bytes = 129,
        },
        .{
            .kind = r4os.abi.gui_frame_command_kind_raster,
            .x = 8,
            .y = 32,
            .w = 1,
            .h = 1,
            .resource_offset = 1,
            .resource_bytes = 4,
            .parameter0 = 1,
        },
        .{
            .kind = r4os.abi.gui_frame_command_kind_alpha8,
            .x = 16,
            .y = 32,
            .w = 2,
            .h = 2,
            .rgb = 0x0020_60A0,
            .resource_offset = 134,
            .resource_bytes = 4,
        },
    };
    if (ctx.draw.guiFrameAppend(mixed[0..], resources[0..]) != r4os.abi.gui_frame_result_ok)
        return fail(ctx, "GUI frame fixture mixed-resource append failed");
    if (ctx.draw.guiFrameCommit() != r4os.abi.gui_frame_result_ok)
        return fail(ctx, "GUI frame fixture commit failed");
    building = false;

    if (ctx.draw.guiFrameBegin() != r4os.abi.gui_frame_result_ok)
        return fail(ctx, "GUI frame fixture cancel begin failed");
    building = true;
    const cancelled = [_]r4os.abi.GuiFrameCommand{.{
        .kind = r4os.abi.gui_frame_command_kind_clear,
        .rgb = 0x00AA_0000,
    }};
    if (ctx.draw.guiFrameAppend(cancelled[0..], &.{}) != r4os.abi.gui_frame_result_ok or
        ctx.draw.guiFrameCancel() != r4os.abi.gui_frame_result_ok)
        return fail(ctx, "GUI frame fixture cancel failed");
    building = false;

    ctx.sys.println("SPECTRA LIFECYCLE gui-frame fixture: ready commands=4116 resources=138 commit=1 cancel=1");
    while (!ctx.sys.programShouldClose()) ctx.sys.sleepTicks(1);
    ctx.sys.println("SPECTRA LIFECYCLE gui-frame fixture: done");
    return 0;
}

fn dynamicThreadHold(ctx: *DiagApi) i32 {
    dynamic_hold_sys = ctx.sys;
    @as(*volatile bool, &dynamic_hold_release).* = false;
    var worker: r4os.abi.ProgramJoinHandle = .{};
    if (ctx.sys.threadCreateHandle(dynamicHoldWorkerMain, 0, 0, 0, &worker) != r4os.abi.thread_ok or
        !dynamicJoinHandleValid(worker))
        return fail(ctx, "dynamic thread-hold worker create failed");

    var info: r4os.abi.ProgramThreadInfo = .{};
    var tick: u32 = 0;
    while (tick < 1000) : (tick += 1) {
        if (ctx.sys.threadHandleStatus(&worker, &info) == r4os.abi.thread_ok and info.task_id != 0) break;
        ctx.sys.sleepTicks(1);
    }
    if (info.task_id == 0) return fail(ctx, "dynamic thread-hold worker did not publish");
    ctx.sys.println("SPECTRA LIFECYCLE dynamic thread-hold ready=OK");
    while (!ctx.sys.programShouldClose()) ctx.sys.sleepTicks(1);
    @as(*volatile bool, &dynamic_hold_release).* = true;
    var exit_code: i32 = 0;
    if (ctx.sys.threadHandleJoin(&worker, r4os.abi.thread_wait_forever, &exit_code) != r4os.abi.thread_ok or exit_code != 37)
        return fail(ctx, "dynamic thread-hold worker join failed");
    return 0;
}

fn dynamicHoldWorkerMain(_: u64) callconv(.c) i32 {
    var sys = dynamic_hold_sys orelse return 36;
    while (!@as(*volatile bool, &dynamic_hold_release).*) sys.sleepTicks(1);
    return 37;
}

fn runDynamicExecutionStress(ctx: *DiagApi, quick: bool) bool {
    if (!ctx.resources.available() or
        !ctx.sys.hasFn("program_inventory_begin") or
        !ctx.sys.hasFn("program_inventory_programs") or
        !ctx.sys.hasFn("program_inventory_tasks") or
        !ctx.sys.hasFn("program_inventory_threads") or
        !ctx.dev.hasFn("execution_inventory_summary") or
        !ctx.dev.hasFn("program_registry_summary_v2") or
        !ctx.dev.hasFn("program_registry_self_test_v2") or
        !ctx.dev.hasFn("program_instance_storage_summary") or
        !ctx.dev.hasFn("performance_summary"))
        return dynamicStressFail(ctx, "required 0.59.7-0.59.11 API missing");

    ctx.sys.println("SPECTRA LIFECYCLE dynamicstress begin");
    defer resetProgramRegistryTest(ctx);

    // Establish Registry chunks, task metadata, stacks, ProgramThread backing
    // and every lazy ProgramInstance payload with the exact measured shape.
    // Only after this private warm wave is fully reaped do we capture the
    // baseline used for byte/counter-exact acceptance.
    if (!runDynamicWave(ctx, false)) return false;
    const baseline = captureStableDynamicStressBaseline(ctx) orelse
        return dynamicStressFail(ctx, "warm baseline did not stabilize");
    const owned_baseline = captureOwnedExecutionSignature(ctx) orelse
        return dynamicStressFail(ctx, "warm owner-tagged inventory unavailable");

    if (!runDynamicWave(ctx, true)) return false;
    if (!waitDynamicStressBaseline(ctx, baseline, 10_000)) {
        printDynamicStressBaselineMismatch(ctx, baseline);
        return dynamicStressFail(ctx, "concurrent wave did not restore warm baseline");
    }

    if (!runDynamicTaskAdmissionOom(ctx)) return false;
    if (!runDynamicProgramRegistry(ctx))
        return dynamicStressFail(ctx, "program admission OOM fixture failed");
    // The age-based shrink hysteresis can leave more than the two warm chunks
    // immediately after the OOM fixture.  The following churn advances the
    // mutation epoch and must retire every empty chunk without changing the
    // published live set.
    ctx.sys.println("SPECTRA LIFECYCLE dynamicstress oom detail programGrowth=REJECTED taskAdmission=REJECTED rollback=OK liveSet=unchanged");
    ctx.sys.println("SPECTRA LIFECYCLE dynamicstress oom injected=2 program=REJECTED task=REJECTED live=stable admin=reachable recovery=OK reboot=no");

    const cycle_target = if (quick) dynamic_stress_quick_cycle_floor else dynamic_stress_cycle_floor;
    if (!runDynamicMixedChurn(ctx, cycle_target)) return false;
    const settle_ticks = if (quick) dynamic_stress_quick_settle_ticks else dynamic_stress_full_settle_ticks;
    if (!waitDynamicFinalBaseline(ctx, baseline, settle_ticks)) {
        printDynamicStressBaselineMismatch(ctx, baseline);
        return dynamicStressFail(ctx, "mixed churn did not restore warm baseline");
    }
    const owned_after = captureOwnedExecutionSignature(ctx) orelse
        return dynamicStressFail(ctx, "final owner-tagged inventory unavailable");
    if (!sameOwnedExecutionSignature(owned_baseline, owned_after))
        return dynamicStressFail(ctx, "owner-tagged task/thread identity changed");

    ctx.sys.println("SPECTRA LIFECYCLE dynamicstress baseline program=exact task=owner-tagged-exact thread=owner-tagged-exact completion=exact ownerResources=exact storage=exact registry=warm heap=bounded512K memory=bounded640K serviceVm=bounded128K adminTasks=bounded8 waiter=covered");
    ctx.sys.println("SPECTRA LIFECYCLE dynamicstress result: OK");
    return true;
}

fn runDynamicWave(ctx: *DiagApi, measured: bool) bool {
    const inventory_before = readExecutionInventory(ctx) orelse
        return dynamicStressFail(ctx, "wave inventory baseline unavailable");
    const registry_before = readProgramRegistry(ctx) orelse
        return dynamicStressFail(ctx, "wave registry baseline unavailable");
    var storage_before: r4os.abi.ProgramInstanceStorageSummary = .{};
    if (ctx.dev.programInstanceStorageSummary(&storage_before) <= 0 or !storageSummaryValid(&storage_before))
        return dynamicStressFail(ctx, "wave storage baseline unavailable");

    var handles: [dynamic_stress_program_floor]r4os.abi.ProgramProcessHandle =
        [_]r4os.abi.ProgramProcessHandle{.{}} ** dynamic_stress_program_floor;
    defer cleanupLifecycleHandles(ctx, handles[0..]);

    for (&handles, 0..) |*handle, index| {
        const kind = dynamicFixtureKind(index);
        const path: [*:0]const u8 = if (kind == .service_hold) service_path else cleanup_path;
        const args: [*:0]const u8 = switch (kind) {
            .console_hold => lifecycle_hold_arg,
            .child_spawn => "/LIFECYCLEHOST 2",
            .thread_hold => dynamic_thread_hold_arg,
            .gui_payload => gui_payload_hold_arg,
            .service_hold => "/HOLD",
        };
        const policy: r4os.abi.LaunchPolicy = if (kind == .gui_payload) .gui else .auto;
        // The child-spawn fixture needs a concrete generation-bound console
        // host so killing its root exercises the real descendant cascade.
        // A host-less root cannot represent that contract and would leave the
        // immediate child's owner-completion intentionally reachable.
        const spawn_status = if (kind == .child_spawn)
            ctx.sys.programSpawnWithConsoleHostHandle(path, route.arguments("LIFECYCLE", args).ptr(), policy, .terminal_window, handle)
        else
            ctx.sys.programSpawnHandle(path, if (kind == .service_hold) args else route.arguments("LIFECYCLE", args).ptr(), policy, handle);
        if (spawn_status != r4os.abi.program_handle_ok or
            handle.instance_id == 0 or handle.generation == 0)
            return dynamicStressFail(ctx, "128-way wave spawn failed");
    }

    if (!waitDynamicWaveReady(ctx, handles[0..], inventory_before, registry_before, storage_before, 10_000))
        return dynamicStressFail(ctx, "128-way wave did not become fully live");
    const scans = scanDynamicInventory(ctx, handles[0..]) orelse
        return dynamicStressFail(ctx, "wave paginated inventory unstable");
    if (!allInventoryChildrenFound(scans.programs.found[0..handles.len]) or
        !allInventoryChildrenFound(scans.tasks.found[0..handles.len]) or
        !allInventoryChildrenFound(scans.threads.found[0..handles.len]))
        return dynamicStressFail(ctx, "wave root missing from paginated inventory");

    if (measured) {
        ctx.sys.write("SPECTRA LIFECYCLE dynamicstress concurrency programs=");
        ctx.sys.printU64(scans.programs.count -| inventory_before.program_total);
        // The raw scheduler total also contains short-lived ownerless admin
        // workers.  ProgramThread inventory is the exact owner-tagged task
        // population created by this wave.
        ctx.sys.write(" ownedTasks=");
        ctx.sys.printU64(scans.threads.count -| inventory_before.thread_total);
        ctx.sys.write(" threads=");
        ctx.sys.printU64(scans.threads.count -| inventory_before.thread_total);
        ctx.sys.println(" roots=128 inventory=complete");
    }

    if (!stopDynamicWave(ctx, handles[0..])) return false;
    if (measured)
        ctx.sys.println("SPECTRA LIFECYCLE dynamicstress payload console=OK gui=OK service=OK child=OK waiters=OK completions=OK");
    return true;
}

fn dynamicFixtureKind(index: usize) DynamicFixtureKind {
    return @enumFromInt(@as(u8, @intCast(index % dynamic_stress_fixture_kinds)));
}

fn dynamicFixtureClass(kind: DynamicFixtureKind) r4os.abi.ProgramInstanceClass {
    return switch (kind) {
        .gui_payload => .gui,
        .service_hold => .service,
        else => .console,
    };
}

fn waitDynamicWaveReady(
    ctx: *DiagApi,
    handles: []const r4os.abi.ProgramProcessHandle,
    inventory_before: r4os.abi.ProgramInventorySummary,
    registry_before: r4os.abi.ProgramRegistrySummaryV2,
    storage_before: r4os.abi.ProgramInstanceStorageSummary,
    max_ticks: u32,
) bool {
    var tick: u32 = 0;
    while (tick < max_ticks) : (tick += 1) {
        var roots_ready = true;
        for (handles, 0..) |handle, index| {
            var info: r4os.abi.ProgramInstanceInfo = .{};
            if (ctx.sys.programHandleStatus(&handle, &info) != r4os.abi.program_handle_ok or
                info.state != @intFromEnum(r4os.abi.ProgramInstanceState.running) or
                info.app_class != @intFromEnum(dynamicFixtureClass(dynamicFixtureKind(index))))
            {
                roots_ready = false;
                break;
            }
        }
        const inventory = readExecutionInventory(ctx) orelse return false;
        const registry = readProgramRegistry(ctx) orelse return false;
        var storage: r4os.abi.ProgramInstanceStorageSummary = .{};
        if (ctx.dev.programInstanceStorageSummary(&storage) <= 0 or !storageSummaryValid(&storage)) return false;
        if (roots_ready and
            inventory.program_total >= inventory_before.program_total + dynamic_stress_program_floor + dynamic_stress_child_count and
            inventory.task_total >= inventory_before.task_total + dynamic_stress_program_floor + dynamic_stress_child_count + dynamic_stress_thread_child_count and
            inventory.thread_total >= inventory_before.thread_total + dynamic_stress_program_floor + dynamic_stress_child_count + dynamic_stress_thread_child_count and
            inventory.completion_total >= inventory_before.completion_total + dynamic_stress_completion_count and
            registry.live_slots >= registry_before.live_slots + dynamic_stress_program_floor + dynamic_stress_child_count and
            storage.active_console_instances >= storage_before.active_console_instances + dynamic_stress_console_count and
            storage.active_gui_instances >= storage_before.active_gui_instances + dynamic_stress_gui_count and
            storage.active_service_instances >= storage_before.active_service_instances + dynamic_stress_service_count and
            storage.gui_command_payloads >= storage_before.gui_command_payloads + dynamic_stress_gui_count and
            storage.gui_raster_payloads >= storage_before.gui_raster_payloads + dynamic_stress_gui_count)
            return true;
        ctx.sys.sleepTicks(1);
    }
    return false;
}

fn scanDynamicInventory(ctx: *DiagApi, handles: []const r4os.abi.ProgramProcessHandle) ?InventoryScanSet {
    var attempt: u32 = 0;
    while (attempt < 64) : (attempt += 1) {
        if (scanStableInventory(ctx, handles)) |result| return result;
        ctx.sys.sleepTicks(1);
    }
    return null;
}

fn stopDynamicWave(ctx: *DiagApi, handles: []r4os.abi.ProgramProcessHandle) bool {
    // Exit pressure is deliberately concurrent: publish every Close/Kill
    // request first, then drain the owned completions in a separate phase.
    for (handles, 0..) |*handle, index| {
        const killed = (index & 1) != 0;
        const stop = stopDynamicHandle(ctx, handle, killed);
        if (stop != r4os.abi.program_handle_ok)
            return dynamicStressFail(ctx, if (killed) "wave kill failed" else "wave close failed");
    }
    for (handles, 0..) |*handle, index| {
        const killed = (index & 1) != 0;
        const expected_exit: i32 = if (killed) -9 else 0;
        const instance_id = handle.instance_id;
        var waited: r4os.abi.ProgramProcessCompletion = .{};
        if (ctx.sys.programHandleWait(handle, 10_000, &waited) != r4os.abi.program_handle_ok or
            !sameLifecycleHandle(handle.*, waited.handle) or
            waited.exit_code != expected_exit)
            return dynamicStressFail(ctx, "wave wait/reap/exit mismatch");
        var reaped: r4os.abi.ProgramProcessCompletion = .{};
        if (reapDynamicHandle(ctx, handle, &reaped) != r4os.abi.program_handle_ok or
            !sameLifecycleHandle(handle.*, reaped.handle) or
            reaped.sequence != waited.sequence or reaped.exit_code != waited.exit_code)
            return dynamicStressFail(ctx, "wave wait/reap/exit mismatch");
        handle.* = .{};
        if (!waitDynamicOwnerGone(ctx, instance_id, 5000))
            return dynamicStressFail(ctx, "wave owner survived reap");
    }
    return true;
}

fn stopDynamicHandle(ctx: *DiagApi, handle: *const r4os.abi.ProgramProcessHandle, killed: bool) i32 {
    var retry: u32 = 0;
    while (true) {
        const status = if (killed)
            ctx.sys.programHandleKill(handle)
        else
            ctx.sys.programHandleRequestClose(handle);
        if (status != r4os.abi.program_handle_error_would_block or retry == dynamic_stress_handle_retry_limit)
            return status;
        retry += 1;
        ctx.sys.sleepTicks(1);
    }
}

fn reapDynamicHandle(
    ctx: *DiagApi,
    handle: *const r4os.abi.ProgramProcessHandle,
    out: *r4os.abi.ProgramProcessCompletion,
) i32 {
    var retry: u32 = 0;
    while (true) {
        const status = ctx.sys.programHandleReap(handle, out);
        if (status != r4os.abi.program_handle_error_would_block or retry == dynamic_stress_handle_retry_limit)
            return status;
        retry += 1;
        ctx.sys.sleepTicks(1);
    }
}

fn captureDynamicStressBaseline(ctx: *DiagApi) ?DynamicStressBaseline {
    const runtime = captureRuntimeBaseline(ctx) orelse return null;
    const inventory = readExecutionInventory(ctx) orelse return null;
    const registry = readProgramRegistry(ctx) orelse return null;
    var self_thread: r4os.abi.ProgramThreadInfo = .{};
    if (ctx.sys.threadStatus(0, &self_thread) != r4os.abi.thread_ok or self_thread.instance_id == 0 or self_thread.task_id == 0)
        return null;
    var self_instance: r4os.abi.ProgramInstanceInfo = .{};
    if (inventoryProgramById(ctx, self_thread.instance_id, &self_instance) != 1 or
        self_instance.task_id != self_thread.task_id)
        return null;
    const self_owner = resourceTotalsForOwner(ctx, self_thread.instance_id) orelse return null;
    if (!inventorySummaryValid(inventory) or
        registry.reserved_slots != 0 or registry.done_slots != 0 or registry.retiring_slots != 0 or
        registry.retire_queued != 0)
        return null;
    return .{
        .runtime = runtime,
        .inventory = inventory,
        .registry = registry,
        .self_instance = self_instance,
        .self_owner = self_owner,
    };
}

fn captureStableDynamicStressBaseline(ctx: *DiagApi) ?DynamicStressBaseline {
    // The production SSH/TCP sessions create short-lived r4x-async-io tasks.
    // Yield-only sampling can pin one of those workers on a stable scheduler
    // plateau and accidentally make its 496-byte task allocation part of the
    // warm baseline.  Advance the timer over a bounded 128 ms window instead
    // and retain the lowest complete snapshot seen between poll workers.  The
    // later acceptance still uses sameDynamicStressBaseline byte/counter-
    // exactly; this only selects the reproducible quiescent phase.
    var low_water: ?DynamicStressBaseline = null;
    var tick: u32 = 0;
    while (tick < 128) : (tick += 1) {
        if (captureDynamicStressBaseline(ctx)) |current| {
            if (low_water) |best| {
                // Replace on an equal footprint as well, so identity fields
                // come from the latest complete snapshot in the window.
                if (!dynamicStressFootprintLess(best, current)) low_water = current;
            } else {
                low_water = current;
            }
        }
        if (tick + 1 < 128) ctx.sys.sleepTicks(1);
    }
    return low_water;
}

fn dynamicStressFootprintLess(a: DynamicStressBaseline, b: DynamicStressBaseline) bool {
    // Lexicographic low-water key.  Task and heap ownership lead because a
    // transient async-I/O worker changes exactly those fields first; the
    // remaining consumption counters reject partially retired snapshots.
    const a_key = [_]u64{
        @intCast(a.inventory.task_total),
        a.inventory.heap_used_bytes,
        @intCast(a.inventory.heap_active_blocks),
        a.runtime.memory.physical_bytes,
        a.runtime.memory.virtual_bytes,
        @intCast(a.runtime.memory.active_blocks),
        a.runtime.memory.reserved_bytes,
        a.runtime.memory.committed_bytes,
        a.runtime.resources.blocks,
        a.runtime.resources.physical,
        a.runtime.resources.virtual,
        a.runtime.resources.reserved,
        a.runtime.resources.committed,
        @intCast(a.inventory.program_total),
        @intCast(a.inventory.thread_total),
    };
    const b_key = [_]u64{
        @intCast(b.inventory.task_total),
        b.inventory.heap_used_bytes,
        @intCast(b.inventory.heap_active_blocks),
        b.runtime.memory.physical_bytes,
        b.runtime.memory.virtual_bytes,
        @intCast(b.runtime.memory.active_blocks),
        b.runtime.memory.reserved_bytes,
        b.runtime.memory.committed_bytes,
        b.runtime.resources.blocks,
        b.runtime.resources.physical,
        b.runtime.resources.virtual,
        b.runtime.resources.reserved,
        b.runtime.resources.committed,
        @intCast(b.inventory.program_total),
        @intCast(b.inventory.thread_total),
    };
    for (a_key, b_key) |a_value, b_value| {
        if (a_value != b_value) return a_value < b_value;
    }
    return false;
}

fn waitDynamicStressBaseline(ctx: *DiagApi, baseline: DynamicStressBaseline, max_ticks: u32) bool {
    var tick: u32 = 0;
    var stable_matches: u32 = 0;
    while (tick < max_ticks) : (tick += 1) {
        const current = captureDynamicStressBaseline(ctx) orelse {
            stable_matches = 0;
            ctx.sys.sleepTicks(1);
            continue;
        };
        if (sameDynamicStressBaseline(baseline, current)) {
            stable_matches += 1;
            if (stable_matches == 8) return true;
            // Mirror captureStableDynamicStressBaseline: once the complete
            // byte/counter snapshot matches, verify that same quiescent
            // scheduler phase without advancing the timer.  Sleeping here
            // woke the production SSH/TCP pollers between every sample and
            // created a fresh 496-byte r4x-async-io Task, so the checker
            // itself prevented eight exact samples from ever succeeding.
            ctx.sys.taskYield();
        } else {
            stable_matches = 0;
            // A real mismatch still needs timer progress so deferred task,
            // program, heap, PMM and VM retirement can drain.
            ctx.sys.sleepTicks(1);
        }
    }
    return false;
}

fn waitDynamicFinalBaseline(ctx: *DiagApi, baseline: DynamicStressBaseline, max_ticks: u32) bool {
    var tick: u32 = 0;
    var stable_matches: u32 = 0;
    while (tick < max_ticks) : (tick += 1) {
        const current = captureDynamicStressBaseline(ctx) orelse {
            stable_matches = 0;
            ctx.sys.sleepTicks(1);
            continue;
        };
        if (sameDynamicFinalBaseline(baseline, current)) {
            stable_matches += 1;
            if (stable_matches == 8) return true;
            ctx.sys.taskYield();
        } else {
            stable_matches = 0;
            ctx.sys.sleepTicks(1);
        }
    }
    return false;
}

fn sameDynamicStressBaseline(a: DynamicStressBaseline, b: DynamicStressBaseline) bool {
    return sameDynamicPersistentBaseline(a, b) and dynamicStressInfrastructureEnvelope(a, b);
}

fn sameDynamicPersistentBaseline(a: DynamicStressBaseline, b: DynamicStressBaseline) bool {
    return sameLifecycleStorageCurrent(a.runtime.storage, b.runtime.storage) and
        a.runtime.instance_count == b.runtime.instance_count and
        sameDynamicInventoryCurrent(a.inventory, b.inventory) and
        sameTotals(a.self_owner, b.self_owner) and
        sameDynamicInstanceCurrent(a.self_instance, b.self_instance) and
        a.registry.chunk_count == b.registry.chunk_count and
        a.registry.slot_capacity == b.registry.slot_capacity and
        a.registry.free_slots == b.registry.free_slots and
        a.registry.reserved_slots == b.registry.reserved_slots and
        a.registry.live_slots == b.registry.live_slots and
        a.registry.done_slots == b.registry.done_slots and
        a.registry.retiring_slots == b.registry.retiring_slots and
        a.registry.live_id_hash == b.registry.live_id_hash and
        a.registry.live_address_hash == b.registry.live_address_hash and
        a.registry.completion_pending == b.registry.completion_pending and
        a.registry.completion_ready == b.registry.completion_ready and
        a.registry.completion_output_bytes == b.registry.completion_output_bytes and
        a.registry.retire_queued == b.registry.retire_queued;
}

fn sameDynamicLiveSetAcrossShrink(a: DynamicStressBaseline, b: DynamicStressBaseline) bool {
    return a.runtime.instance_count == b.runtime.instance_count and
        sameDynamicInventoryCurrent(a.inventory, b.inventory) and
        sameTotals(a.self_owner, b.self_owner) and
        sameDynamicInstanceCurrent(a.self_instance, b.self_instance) and
        a.registry.version == b.registry.version and
        a.registry.size == b.registry.size and
        a.registry.chunk_slots == b.registry.chunk_slots and
        a.registry.warm_chunks == b.registry.warm_chunks and
        a.registry.reserved_slots == b.registry.reserved_slots and
        a.registry.live_slots == b.registry.live_slots and
        a.registry.done_slots == b.registry.done_slots and
        a.registry.retiring_slots == b.registry.retiring_slots and
        a.registry.live_id_hash == b.registry.live_id_hash and
        a.registry.live_address_hash == b.registry.live_address_hash and
        a.registry.completion_pending == b.registry.completion_pending and
        a.registry.completion_ready == b.registry.completion_ready and
        a.registry.completion_output_bytes == b.registry.completion_output_bytes and
        a.registry.retire_queued == b.registry.retire_queued and
        sameDynamicStorageAcrossRegistryShrink(a.runtime.storage, b.runtime.storage);
}

fn sameDynamicStorageAcrossRegistryShrink(
    baseline: r4os.abi.ProgramInstanceStorageSummary,
    actual: r4os.abi.ProgramInstanceStorageSummary,
) bool {
    var normalized = actual;
    normalized.registry_reserved_core_bytes = baseline.registry_reserved_core_bytes;
    normalized.reserved_instance_bytes = baseline.reserved_instance_bytes;
    normalized.allocation_failures = baseline.allocation_failures;
    normalized.transaction_rollbacks = baseline.transaction_rollbacks;
    return sameStorageCurrent(baseline, normalized);
}

fn sameDynamicFinalBaseline(baseline: DynamicStressBaseline, current: DynamicStressBaseline) bool {
    return sameDynamicLiveSetAcrossShrink(baseline, current) and
        current.registry.chunk_count == current.registry.warm_chunks and
        current.registry.slot_capacity == current.registry.chunk_slots * current.registry.warm_chunks and
        current.registry.free_slots == current.registry.slot_capacity - current.registry.live_slots and
        dynamicStressInfrastructureEnvelope(baseline, current);
}

fn dynamicStressInfrastructureEnvelope(a: DynamicStressBaseline, b: DynamicStressBaseline) bool {
    const task_delta = absDiffU64(a.inventory.task_total, b.inventory.task_total);
    if (task_delta > dynamic_stress_admin_task_slack) return false;

    const byte_slack = dynamic_stress_admin_task_slack * dynamic_stress_admin_bytes_per_task;
    const block_slack = dynamic_stress_admin_task_slack * dynamic_stress_admin_active_blocks_per_task;
    // Registry shrink and stack-cache retirement are intentional reductions.
    // This envelope rejects only growth beyond the production-admin budget;
    // live objects and the stress owner's resources remain exact elsewhere.
    if (growthOverBaseline(a.inventory.heap_active_blocks, b.inventory.heap_active_blocks) > block_slack or
        growthOverBaseline(a.inventory.heap_used_bytes, b.inventory.heap_used_bytes) > byte_slack)
        return false;

    const resources_a = a.runtime.resources;
    const resources_b = b.runtime.resources;
    if (resources_a.program_images != resources_b.program_images or
        resources_a.app_stacks != resources_b.app_stacks or
        growthOverBaseline(resources_a.blocks, resources_b.blocks) > dynamic_stress_admin_service_vm_block_slack or
        growthOverBaseline(resources_a.vm_ranges, resources_b.vm_ranges) > dynamic_stress_admin_service_vm_block_slack or
        growthOverBaseline(resources_a.reserved, resources_b.reserved) > dynamic_stress_admin_service_vm_byte_slack or
        growthOverBaseline(resources_a.committed, resources_b.committed) > dynamic_stress_admin_service_vm_byte_slack or
        growthOverBaseline(resources_a.physical, resources_b.physical) > dynamic_stress_admin_service_vm_byte_slack or
        growthOverBaseline(resources_a.virtual, resources_b.virtual) > dynamic_stress_admin_service_vm_byte_slack)
        return false;

    const memory_byte_slack = byte_slack + dynamic_stress_admin_service_vm_byte_slack;
    const frame_slack = memory_byte_slack / 4096;
    const memory_a = a.runtime.memory;
    const memory_b = b.runtime.memory;
    return memory_a.app_system_reserve_frames == memory_b.app_system_reserve_frames and
        growthOverBaseline(memory_a.active_blocks, memory_b.active_blocks) <= block_slack and
        growthOverBaseline(memory_a.physical_bytes, memory_b.physical_bytes) <= memory_byte_slack and
        growthOverBaseline(memory_a.virtual_bytes, memory_b.virtual_bytes) <= memory_byte_slack and
        growthOverBaseline(memory_a.reserved_bytes, memory_b.reserved_bytes) <= memory_byte_slack and
        growthOverBaseline(memory_a.committed_bytes, memory_b.committed_bytes) <= memory_byte_slack and
        decreaseFromBaseline(memory_a.free_physical_bytes, memory_b.free_physical_bytes) <= memory_byte_slack and
        decreaseFromBaseline(memory_a.largest_free_phys_len, memory_b.largest_free_phys_len) <= memory_byte_slack and
        decreaseFromBaseline(memory_a.largest_free_virtual_len, memory_b.largest_free_virtual_len) <= memory_byte_slack and
        decreaseFromBaseline(memory_a.app_available_frames, memory_b.app_available_frames) <= frame_slack;
}

fn growthOverBaseline(baseline: anytype, current: @TypeOf(baseline)) u64 {
    const before: u64 = @intCast(baseline);
    const after: u64 = @intCast(current);
    return if (after > before) after - before else 0;
}

fn decreaseFromBaseline(baseline: anytype, current: @TypeOf(baseline)) u64 {
    const before: u64 = @intCast(baseline);
    const after: u64 = @intCast(current);
    return if (before > after) before - after else 0;
}

fn absDiffU64(a: anytype, b: @TypeOf(a)) u64 {
    const left: u64 = @intCast(a);
    const right: u64 = @intCast(b);
    return if (left >= right) left - right else right - left;
}

fn printDynamicStressBaselineMismatch(ctx: *DiagApi, baseline: DynamicStressBaseline) void {
    printLifecycleBaselineMismatch(ctx, baseline.runtime, baseline.registry);
    const current = captureDynamicStressBaseline(ctx) orelse {
        ctx.sys.println("SPECTRA LIFECYCLE dynamicstress baselineMismatch detail=unavailable");
        return;
    };

    ctx.sys.write("SPECTRA LIFECYCLE dynamicstress baselineMismatch equal inventory=");
    ctx.sys.printU64(if (sameDynamicInventoryCurrent(baseline.inventory, current.inventory)) 1 else 0);
    ctx.sys.write(" owner=");
    ctx.sys.printU64(if (sameTotals(baseline.self_owner, current.self_owner)) 1 else 0);
    ctx.sys.write(" self=");
    ctx.sys.printU64(if (sameDynamicInstanceCurrent(baseline.self_instance, current.self_instance)) 1 else 0);
    ctx.sys.write(" total=");
    ctx.sys.printU64(if (sameDynamicStressBaseline(baseline, current)) 1 else 0);
    ctx.sys.write("\r\n");

    ctx.sys.write("SPECTRA LIFECYCLE dynamicstress baselineMismatch inventory programs=");
    printLifecycleValuePair(ctx, baseline.inventory.program_total, current.inventory.program_total);
    ctx.sys.write(" active=");
    printLifecycleValuePair(ctx, baseline.inventory.program_active, current.inventory.program_active);
    ctx.sys.write(" done=");
    printLifecycleValuePair(ctx, baseline.inventory.program_done, current.inventory.program_done);
    ctx.sys.write(" completions=");
    printLifecycleValuePair(ctx, baseline.inventory.completion_total, current.inventory.completion_total);
    ctx.sys.write(" tasks=");
    printLifecycleValuePair(ctx, baseline.inventory.task_total, current.inventory.task_total);
    ctx.sys.write(" threads=");
    printLifecycleValuePair(ctx, baseline.inventory.thread_total, current.inventory.thread_total);
    ctx.sys.write(" threadDone=");
    printLifecycleValuePair(ctx, baseline.inventory.thread_done, current.inventory.thread_done);
    ctx.sys.write(" heapBlocks=");
    printLifecycleValuePair(ctx, baseline.inventory.heap_active_blocks, current.inventory.heap_active_blocks);
    ctx.sys.write(" heapBytes=");
    printLifecycleValuePair(ctx, baseline.inventory.heap_used_bytes, current.inventory.heap_used_bytes);
    ctx.sys.write("\r\n");

    ctx.sys.write("SPECTRA LIFECYCLE dynamicstress baselineMismatch selfOwner blocks=");
    printLifecycleValuePair(ctx, baseline.self_owner.blocks, current.self_owner.blocks);
    ctx.sys.write(" images=");
    printLifecycleValuePair(ctx, baseline.self_owner.program_images, current.self_owner.program_images);
    ctx.sys.write(" vm=");
    printLifecycleValuePair(ctx, baseline.self_owner.vm_ranges, current.self_owner.vm_ranges);
    ctx.sys.write(" stacks=");
    printLifecycleValuePair(ctx, baseline.self_owner.app_stacks, current.self_owner.app_stacks);
    ctx.sys.write(" reserved=");
    printLifecycleValuePair(ctx, baseline.self_owner.reserved, current.self_owner.reserved);
    ctx.sys.write(" committed=");
    printLifecycleValuePair(ctx, baseline.self_owner.committed, current.self_owner.committed);
    ctx.sys.write("\r\n");
}

fn sameDynamicInventoryCurrent(a: r4os.abi.ProgramInventorySummary, b: r4os.abi.ProgramInventorySummary) bool {
    // READY/RUNNING/BLOCKED scheduler distribution is intentionally excluded:
    // RDP, SSH and service workers may cross a scheduling boundary while their
    // reversible task/thread ownership remains unchanged.  Intrusive waiter
    // structure is covered by the dynamic task contract; task_blocked is not a
    // stable ownership counter and must not be presented as one here.
    return a.program_total == b.program_total and a.program_active == b.program_active and
        a.program_done == b.program_done and a.program_retiring == b.program_retiring and
        a.program_reserved == b.program_reserved and a.completion_total == b.completion_total and
        a.thread_total == b.thread_total and a.thread_done == b.thread_done and
        a.thread_joining == b.thread_joining;
}

fn sameDynamicInstanceCurrent(a: r4os.abi.ProgramInstanceInfo, b: r4os.abi.ProgramInstanceInfo) bool {
    return a.id == b.id and a.task_id == b.task_id and a.role == b.role and a.app_class == b.app_class and
        a.state == b.state and a.memory_reserved_bytes == b.memory_reserved_bytes and
        a.memory_committed_bytes == b.memory_committed_bytes and a.memory_resident_bytes == b.memory_resident_bytes and
        a.stack_reserved_bytes == b.stack_reserved_bytes and a.stack_committed_bytes == b.stack_committed_bytes;
}

fn runDynamicTaskAdmissionOom(ctx: *DiagApi) bool {
    const inventory_before = readExecutionInventory(ctx) orelse
        return dynamicStressFail(ctx, "task OOM inventory baseline unavailable");
    const registry_before = readProgramRegistry(ctx) orelse
        return dynamicStressFail(ctx, "task OOM registry baseline unavailable");
    if (!armLifecycleFailure(ctx, r4os.abi.program_registry_self_test_phase_task))
        return dynamicStressFail(ctx, "task admission OOM arm denied");

    var unexpected: r4os.abi.ProgramProcessHandle = .{};
    if (ctx.sys.programSpawnHandle(cleanup_path, route.arguments("LIFECYCLE", "/LIFECYCLEEXIT 63 0").ptr(), .auto, &unexpected) == r4os.abi.program_handle_ok or
        unexpected.instance_id != 0)
    {
        cleanupLifecycleHandles(ctx, @as(*[1]r4os.abi.ProgramProcessHandle, @ptrCast(&unexpected))[0..]);
        return dynamicStressFail(ctx, "task admission OOM published a program");
    }
    var observed: r4os.abi.ProgramRegistrySelfTestResultV2 = .{};
    if (!signalLifecycleReaper(ctx, &observed) or
        observed.lifecycle_phase != r4os.abi.program_registry_self_test_phase_task or
        (observed.flags & r4os.abi.program_registry_self_test_flag_lifecycle_consumed) == 0)
        return dynamicStressFail(ctx, "task admission OOM was not consumed");
    if (!waitDynamicLiveSet(ctx, inventory_before, registry_before, 5000))
        return dynamicStressFail(ctx, "task admission OOM changed live set");

    if (!runDynamicExitProcess(ctx, "/LIFECYCLEEXIT 64 0", 64))
        return dynamicStressFail(ctx, "task admission did not recover");
    resetProgramRegistryTest(ctx);
    return true;
}

fn waitDynamicLiveSet(
    ctx: *DiagApi,
    inventory: r4os.abi.ProgramInventorySummary,
    registry: r4os.abi.ProgramRegistrySummaryV2,
    max_ticks: u32,
) bool {
    var tick: u32 = 0;
    while (tick < max_ticks) : (tick += 1) {
        const current_inventory = readExecutionInventory(ctx) orelse return false;
        const current_registry = readProgramRegistry(ctx) orelse return false;
        if (sameDynamicInventoryCurrent(inventory, current_inventory) and
            current_registry.reserved_slots == registry.reserved_slots and
            current_registry.live_slots == registry.live_slots and
            current_registry.done_slots == registry.done_slots and
            current_registry.retiring_slots == registry.retiring_slots and
            current_registry.live_id_hash == registry.live_id_hash and
            current_registry.live_address_hash == registry.live_address_hash and
            current_registry.completion_pending == registry.completion_pending and
            current_registry.completion_ready == registry.completion_ready)
            return true;
        ctx.sys.sleepTicks(1);
    }
    return false;
}

fn runDynamicMixedChurn(ctx: *DiagApi, cycle_target: u32) bool {
    var cycle: u32 = 0;
    while (cycle < cycle_target) : (cycle += 1) {
        var thread: r4os.abi.ProgramJoinHandle = .{};
        if (ctx.sys.threadCreateHandle(dynamicStressWorkerMain, cycle & 0x7FFF, 0, 0, &thread) != r4os.abi.thread_ok or
            !dynamicJoinHandleValid(thread))
            return dynamicStressFail(ctx, "mixed churn thread create failed");
        var info: r4os.abi.ProgramThreadInfo = .{};
        if (ctx.sys.threadHandleStatus(&thread, &info) != r4os.abi.thread_ok or info.task_id == 0)
            return dynamicStressFail(ctx, "mixed churn task/thread status missing");
        const thread_id = thread.thread_id;
        var exit_code: i32 = -1;
        if (ctx.sys.threadHandleJoin(&thread, r4os.abi.thread_wait_forever, &exit_code) != r4os.abi.thread_ok or
            exit_code != @as(i32, @intCast(cycle & 0x7FFF)))
            return dynamicStressFail(ctx, "mixed churn thread exit/join mismatch");
        var stale: r4os.abi.ProgramThreadInfo = .{};
        if (ctx.sys.threadStatus(thread_id, &stale) != r4os.abi.thread_error_not_found)
            return dynamicStressFail(ctx, "mixed churn joined thread remained visible");

        switch (cycle % 3) {
            0 => {
                const index: usize = @intCast((cycle / 3) % dynamic_churn_exit_args.len);
                if (!runDynamicExitProcess(ctx, dynamic_churn_exit_args[index], dynamic_churn_exit_codes[index]))
                    return dynamicStressFail(ctx, "mixed churn process exit/reap failed");
            },
            1 => if (!runDynamicHeldProcess(ctx, false))
                return dynamicStressFail(ctx, "mixed churn process close/reap failed"),
            else => if (!runDynamicHeldProcess(ctx, true))
                return dynamicStressFail(ctx, "mixed churn process kill/reap failed"),
        }
    }
    ctx.sys.write("SPECTRA LIFECYCLE dynamicstress churn=");
    ctx.sys.printU64(cycle_target);
    ctx.sys.write(" tier=");
    ctx.sys.write(if (cycle_target == dynamic_stress_quick_cycle_floor) "quick" else "full");
    ctx.sys.println(" deterministic=mixed spawn=OK thread=OK exit=OK reap=OK");
    return true;
}

fn dynamicStressWorkerMain(arg: u64) callconv(.c) i32 {
    return @intCast(arg & 0x7FFF);
}

fn dynamicJoinHandleValid(handle: r4os.abi.ProgramJoinHandle) bool {
    return handle.thread_id != 0 and handle.instance_id != 0 and
        handle.thread_generation != 0 and handle.instance_generation != 0 and handle.reserved == 0;
}

fn runDynamicExitProcess(ctx: *DiagApi, args: [*:0]const u8, expected_exit: i32) bool {
    var handle: r4os.abi.ProgramProcessHandle = .{};
    if (ctx.sys.programSpawnHandle(cleanup_path, route.arguments("LIFECYCLE", args).ptr(), .auto, &handle) != r4os.abi.program_handle_ok) return false;
    const instance_id = handle.instance_id;
    defer if (handle.instance_id != 0) cleanupLifecycleHandles(ctx, @as(*[1]r4os.abi.ProgramProcessHandle, @ptrCast(&handle))[0..]);
    var completion: r4os.abi.ProgramProcessCompletion = .{};
    if (ctx.sys.programHandleWait(&handle, 10_000, &completion) != r4os.abi.program_handle_ok or
        !sameLifecycleHandle(handle, completion.handle) or completion.exit_code != expected_exit or
        ctx.sys.programHandleReap(&handle, &completion) != r4os.abi.program_handle_ok)
        return false;
    handle = .{};
    return waitDynamicOwnerGone(ctx, instance_id, 5000);
}

fn runDynamicHeldProcess(ctx: *DiagApi, killed: bool) bool {
    var handle: r4os.abi.ProgramProcessHandle = .{};
    if (ctx.sys.programSpawnHandle(cleanup_path, route.arguments("LIFECYCLE", dynamic_churn_hold_arg).ptr(), .auto, &handle) != r4os.abi.program_handle_ok) return false;
    const instance_id = handle.instance_id;
    defer if (handle.instance_id != 0) cleanupLifecycleHandles(ctx, @as(*[1]r4os.abi.ProgramProcessHandle, @ptrCast(&handle))[0..]);
    var tick: u32 = 0;
    var running = false;
    while (tick < 1000) : (tick += 1) {
        var info: r4os.abi.ProgramInstanceInfo = .{};
        if (ctx.sys.programHandleStatus(&handle, &info) == r4os.abi.program_handle_ok and
            info.state == @intFromEnum(r4os.abi.ProgramInstanceState.running))
        {
            running = true;
            break;
        }
        ctx.sys.sleepTicks(1);
    }
    if (!running) return false;
    const stop = if (killed) ctx.sys.programHandleKill(&handle) else ctx.sys.programHandleRequestClose(&handle);
    const expected_exit: i32 = if (killed) -9 else 0;
    var completion: r4os.abi.ProgramProcessCompletion = .{};
    if (stop != r4os.abi.program_handle_ok or
        ctx.sys.programHandleWait(&handle, 10_000, &completion) != r4os.abi.program_handle_ok or
        completion.exit_code != expected_exit or
        ctx.sys.programHandleReap(&handle, &completion) != r4os.abi.program_handle_ok)
        return false;
    handle = .{};
    return waitDynamicOwnerGone(ctx, instance_id, 5000);
}

fn waitDynamicOwnerGone(ctx: *DiagApi, instance_id: u32, max_ticks: u32) bool {
    var tick: u32 = 0;
    while (tick < max_ticks) : (tick += 1) {
        if (!instanceExists(ctx, instance_id) and ownerResourceBlocks(ctx, instance_id) == 0) return true;
        ctx.sys.sleepTicks(1);
    }
    return !instanceExists(ctx, instance_id) and ownerResourceBlocks(ctx, instance_id) == 0;
}

fn dynamicStressFail(ctx: *DiagApi, message: []const u8) bool {
    ctx.sys.write("SPECTRA LIFECYCLE dynamicstress FAILED: ");
    ctx.sys.write(message);
    ctx.sys.write("\r\n");
    ctx.sys.println("SPECTRA LIFECYCLE dynamicstress result: FAILED");
    return false;
}

fn runProgramInstanceStorage(ctx: *DiagApi) bool {
    ctx.sys.println("SPECTRA LIFECYCLE programstorage begin");

    if (!ctx.dev.hasFn("program_instance_storage_summary"))
        return programStorageFail(ctx, "R4DEV storage summary missing");
    if (!ctx.dev.hasFn("program_instance_storage_summary_v2"))
        return programStorageFail(ctx, "R4DEV storage summary v2 missing");
    if (!ctx.dev.hasFn("program_instance_storage_self_test"))
        return programStorageFail(ctx, "R4DEV storage self-test missing");
    if (!runProgramStorageSummaryNegotiation(ctx))
        return programStorageFail(ctx, "R4DEV storage summary prefix negotiation");
    if (!runProgramStorageSelfTest(ctx))
        return programStorageFail(ctx, "bounded heap/rollback self-test");

    if (!runNormalLifecycle(ctx, app_heap_path, "", .auto, .console))
        return programStorageFail(ctx, "console normal lifecycle");
    if (!runHeldLifecycle(ctx, app_heap_path, "/HOLD", .auto, .console, .kill))
        return programStorageFail(ctx, "console kill lifecycle");
    ctx.sys.println("SPECTRA LIFECYCLE programstorage console normal=OK kill=OK");

    if (!runHeldLifecycle(ctx, cleanup_path, route.arguments("LIFECYCLE", gui_payload_hold_arg).ptr(), .gui, .gui, .kill))
        return programStorageFail(ctx, "GUI kill lifecycle");
    ctx.sys.println("SPECTRA LIFECYCLE programstorage gui kill=OK");

    if (!runGuiRasterChainKillLifecycle(ctx))
        return programStorageFail(ctx, "GUI raster-chain kill lifecycle");
    if (!runGuiFrameContractLifecycle(ctx))
        return programStorageFail(ctx, "GUI transactional frame lifecycle");

    if (!runHeldLifecycle(ctx, service_path, "/HOLD", .auto, .service, .request_close))
        return programStorageFail(ctx, "service close lifecycle");
    if (!runHeldLifecycle(ctx, service_path, "/HOLD", .auto, .service, .kill))
        return programStorageFail(ctx, "service kill lifecycle");
    ctx.sys.println("SPECTRA LIFECYCLE programstorage service close=OK kill=OK");

    if (!runKillDuringIoWaitRegression(ctx))
        return programStorageFail(ctx, "kill during io_wait regression");

    const baseline = captureRuntimeBaseline(ctx) orelse
        return programStorageFail(ctx, "warm baseline unavailable");

    var cycle: u32 = 0;
    while (cycle < churn_cycles) : (cycle += 1) {
        const ok = switch (cycle % 3) {
            0 => runNormalLifecycle(ctx, cstart_path, "/QUIET", .auto, .console),
            1 => runHeldLifecycle(ctx, cleanup_path, route.arguments("LIFECYCLE", gui_payload_hold_arg).ptr(), .gui, .gui, .kill),
            else => runHeldLifecycle(
                ctx,
                service_path,
                "/HOLD",
                .auto,
                .service,
                if (((cycle / 3) & 1) == 0) .request_close else .kill,
            ),
        };
        if (!ok) return programStorageFail(ctx, "mixed churn lifecycle");
    }

    const after = captureRuntimeBaseline(ctx) orelse
        return programStorageFail(ctx, "post-churn baseline unavailable");
    if (!sameTotals(baseline.resources, after.resources))
        return programStorageFail(ctx, "owner resources changed after churn");
    if (!sameMemoryStable(baseline.memory, after.memory))
        return programStorageFail(ctx, "PMM or VM baseline changed after churn");
    if (baseline.instance_count != after.instance_count)
        return programStorageFail(ctx, "program registry baseline changed after churn");
    if (!sameStorageCurrent(baseline.storage, after.storage)) {
        printBaselineDiff(ctx, baseline, after);
        return programStorageFail(ctx, "payload storage baseline changed after churn");
    }
    if (after.storage.payload_allocations < baseline.storage.payload_allocations or
        after.storage.payload_releases < baseline.storage.payload_releases)
        return programStorageFail(ctx, "payload counters moved backwards");
    const allocation_delta = after.storage.payload_allocations - baseline.storage.payload_allocations;
    const release_delta = after.storage.payload_releases - baseline.storage.payload_releases;
    if (allocation_delta == 0 or allocation_delta != release_delta)
        return programStorageFail(ctx, "payload allocation/release delta mismatch");

    // Publish diagnostics after the measured interval. Parent transcripts
    // legitimately retain successful child output beyond child reaping.
    printRuntimeBaseline(ctx, &baseline);
    ctx.sys.write("SPECTRA LIFECYCLE programstorage churn cycles=18 console=6 gui=6 service=6 allocations=");
    ctx.sys.printU64(allocation_delta);
    ctx.sys.write(" releases=");
    ctx.sys.printU64(release_delta);
    ctx.sys.println(" ownerCleanup=OK pmm=OK vm=OK registry=OK storage=OK");
    ctx.sys.println("SPECTRA LIFECYCLE programstorage result: OK");
    return true;
}

fn runProgramStorageSelfTest(ctx: *DiagApi) bool {
    var result: r4os.abi.ProgramInstanceStorageSelfTestResult = .{};
    if (ctx.dev.programInstanceStorageSelfTest(&result) <= 0) return false;
    const required_flags = r4os.abi.program_instance_storage_self_test_flag_heap_ready |
        r4os.abi.program_instance_storage_self_test_flag_storage_baseline_restored |
        r4os.abi.program_instance_storage_self_test_flag_payload_balance |
        r4os.abi.program_instance_storage_self_test_flag_rollback_path;
    if (result.version != 1 or result.size < @sizeOf(r4os.abi.ProgramInstanceStorageSelfTestResult) or
        result.cases < 37 or result.passed_cases != result.cases or result.failed_case != 0 or
        (result.flags & required_flags) != required_flags or
        result.baseline_payload_reserved_bytes != result.final_payload_reserved_bytes or
        result.peak_payload_reserved_bytes <= result.baseline_payload_reserved_bytes or
        result.allocation_failures_after <= result.allocation_failures_before)
        return false;

    ctx.sys.write("SPECTRA LIFECYCLE programstorage selftest cases=");
    ctx.sys.printU64(@intCast(result.cases));
    ctx.sys.write(" flags=");
    ctx.sys.printU64(@intCast(result.flags));
    ctx.sys.println(" heap=OK rollback=OK balance=OK");
    return true;
}

const program_storage_summary_v1_size: u32 = 256;
const program_storage_summary_v1_bytes: usize = program_storage_summary_v1_size;

fn allBytesEqual(bytes: []const u8, expected: u8) bool {
    for (bytes) |byte| {
        if (byte != expected) return false;
    }
    return true;
}

fn runProgramStorageSummaryNegotiation(ctx: *DiagApi) bool {
    const Summary = r4os.abi.ProgramInstanceStorageSummary;
    const current_size = @sizeOf(Summary);
    const current_size_u32: u32 = current_size;
    if (current_size != 336) return false;

    // Slot 27 is the frozen output-only v1 ABI. In particular, it must not
    // inspect an old C caller's uninitialised header and it may never write
    // past the historical 256-byte object.
    var v1_bytes: [current_size]u8 align(@alignOf(Summary)) = [_]u8{0xA5} ** current_size;
    const v1: *Summary = @ptrCast(&v1_bytes);
    if (ctx.dev.programInstanceStorageSummaryLegacy(v1) <= 0 or
        v1.version != 1 or v1.size != program_storage_summary_v1_size or
        !allBytesEqual(v1_bytes[program_storage_summary_v1_bytes..], 0xA5))
        return false;

    // Slot 34 is the new, header-negotiated v2 ABI. The regular high-level
    // facade must prefer it, while the explicit facade preserves caller
    // headers so invalid-input no-write behaviour can be verified below.
    var v2: Summary = .{};
    v2.version = 2;
    v2.size = current_size_u32;
    if (ctx.dev.programInstanceStorageSummaryV2(&v2) <= 0 or v2.version != 2 or v2.size != current_size_u32)
        return false;

    var future: Summary = .{};
    future.version = 99;
    future.size = current_size_u32;
    if (ctx.dev.programInstanceStorageSummaryV2(&future) <= 0 or future.version != 2 or future.size != current_size_u32)
        return false;

    var high_level: Summary = undefined;
    if (ctx.dev.programInstanceStorageSummary(&high_level) <= 0 or
        high_level.version != 2 or high_level.size != current_size_u32)
        return false;

    var invalid_version_bytes: [current_size]u8 align(@alignOf(Summary)) = [_]u8{0x5A} ** current_size;
    const invalid_version: *Summary = @ptrCast(&invalid_version_bytes);
    invalid_version.version = 0;
    invalid_version.size = current_size_u32;
    if (ctx.dev.programInstanceStorageSummaryV2(invalid_version) != -1 or
        invalid_version.version != 0 or invalid_version.size != current_size_u32 or
        !allBytesEqual(invalid_version_bytes[8..], 0x5A))
        return false;

    var invalid_size_bytes: [current_size]u8 align(@alignOf(Summary)) = [_]u8{0x6B} ** current_size;
    const invalid_size: *Summary = @ptrCast(&invalid_size_bytes);
    invalid_size.version = 2;
    invalid_size.size = current_size_u32 - 1;
    if (ctx.dev.programInstanceStorageSummaryV2(invalid_size) != -1 or
        invalid_size.version != 2 or invalid_size.size != current_size_u32 - 1 or
        !allBytesEqual(invalid_size_bytes[8..], 0x6B))
        return false;

    ctx.sys.println("SPECTRA LIFECYCLE programstorage summary-prefix legacy=256 tail=unchanged v2=336 future=OK invalid=unchanged");
    return true;
}

fn runKillDuringIoWaitRegression(ctx: *DiagApi) bool {
    if (!ctx.dev.hasFn("performance_summary") or !ctx.dev.hasFn("performance_task"))
        return killWaitFailure(ctx, 0, "R4DEV task telemetry missing");

    var endpoint: r4os.abi.ServiceInfo = .{};
    if (!waitForStallEndpoint(ctx, &endpoint, 2000))
        return killWaitFailure(ctx, 0, "stall endpoint not registered");
    var opened: r4os.abi.ServiceInfo = .{};
    if (ctx.sys.serviceOpen(stall_service_name, &opened) != r4os.abi.service_api_result_ok or
        opened.handle == 0 or opened.handle != endpoint.handle or opened.instance_id != endpoint.instance_id)
        return killWaitFailure(ctx, 0, "parent service open failed");
    var service_handle = opened.handle;
    defer {
        if (service_handle != 0) _ = ctx.sys.serviceClose(service_handle);
    }
    const endpoint_id = opened.instance_id;
    const base_requests = opened.requests;
    const base_responses = opened.responses;
    const base_cancellations = opened.cancellations;

    // The first client may populate reusable task-stack/page-table backing.
    // Establish that infrastructure once, while still requiring all owned
    // resources and every ProgramInstance payload to return exactly.
    const cold = captureRuntimeBaseline(ctx) orelse
        return killWaitFailure(ctx, 0, "cold baseline unavailable");
    if (!runKillWaitCycle(
        ctx,
        0,
        service_handle,
        endpoint_id,
        base_requests + 1,
        base_responses,
        base_cancellations + 1,
    )) return false;
    const warm = captureRuntimeBaseline(ctx) orelse
        return killWaitFailure(ctx, 0, "warm baseline unavailable");
    if (!sameTotals(cold.resources, warm.resources) or
        cold.instance_count != warm.instance_count or
        !sameStorageCurrent(cold.storage, warm.storage))
    {
        printBaselineDiff(ctx, cold, warm);
        return killWaitFailure(ctx, 0, "warm-up owner or payload baseline not restored");
    }
    ctx.sys.println("SPECTRA LIFECYCLE programstorage killwait warmup=OK");

    const measured_base_requests = base_requests + 1;
    const measured_base_responses = base_responses;
    const measured_base_cancellations = base_cancellations + 1;

    var cycle: u32 = 0;
    while (cycle < kill_wait_cycles) : (cycle += 1) {
        const before = captureRuntimeBaseline(ctx) orelse
            return killWaitFailure(ctx, cycle, "baseline before cycle unavailable");
        const expected_requests = measured_base_requests + @as(u64, cycle) + 1;
        const expected_cancellations = measured_base_cancellations + @as(u64, cycle) + 1;
        if (!runKillWaitCycle(ctx, cycle, service_handle, endpoint_id, expected_requests, measured_base_responses, expected_cancellations))
            return false;
        const after = captureRuntimeBaseline(ctx) orelse
            return killWaitFailure(ctx, cycle, "baseline after cycle unavailable");

        if (!sameTotals(before.resources, after.resources))
            return killWaitFailure(ctx, cycle, "owner resources not restored");
        if (!sameMemoryStable(before.memory, after.memory))
            return killWaitFailure(ctx, cycle, "PMM or VM baseline not restored");
        if (before.instance_count != after.instance_count)
            return killWaitFailure(ctx, cycle, "program registry not restored");
        if (!sameStorageCurrent(before.storage, after.storage))
            return killWaitFailure(ctx, cycle, "payload storage not restored");
        if (after.storage.payload_allocations < before.storage.payload_allocations or
            after.storage.payload_releases < before.storage.payload_releases)
            return killWaitFailure(ctx, cycle, "payload counters moved backwards");
        const allocation_delta = after.storage.payload_allocations - before.storage.payload_allocations;
        const release_delta = after.storage.payload_releases - before.storage.payload_releases;
        if (allocation_delta == 0 or allocation_delta != release_delta)
            return killWaitFailure(ctx, cycle, "payload allocation/release imbalance");
    }

    if (ctx.sys.serviceClose(service_handle) != r4os.abi.service_api_result_ok)
        return killWaitFailure(ctx, kill_wait_cycles - 1, "parent service close failed");
    service_handle = 0;

    ctx.sys.println("SPECTRA LIFECYCLE programstorage killwait cycles=72 blocked=completion queue=OK reap=OK baseline=OK slots=OK");
    return true;
}

fn runKillWaitCycle(
    ctx: *DiagApi,
    cycle: u32,
    service_handle: u32,
    endpoint_id: u32,
    expected_requests: u64,
    expected_responses: u64,
    expected_cancellations: u64,
) bool {
    var args_buffer: [32:0]u8 = .{0} ** 32;
    const args = formatKillWaitArgs(service_handle, &args_buffer);
    var client = spawnPolicy(ctx, async_io_path, route.arguments("ASYNC_IO", args).ptr(), .auto) orelse
        return killWaitFailure(ctx, cycle, "killwait client spawn failed");
    defer cleanupProcess(ctx, &client);
    const client_id = client.instanceId();

    if (!waitForClientIoWait(ctx, &client, endpoint_id, expected_requests, expected_responses, 2000))
        return killWaitFailure(ctx, cycle, "client io_wait was not observed");
    if (client.kill() != 0)
        return killWaitFailure(ctx, cycle, "client kill failed");
    switch (client.wait(finiteTimeout(4000))) {
        .exited => {},
        else => return killWaitFailure(ctx, cycle, "client reap failed"),
    }
    if (instanceExists(ctx, client_id) or ownerResourceBlocks(ctx, client_id) != 0)
        return killWaitFailure(ctx, cycle, "client owner cleanup failed");
    if (!waitForStallQueueDrained(ctx, endpoint_id, expected_requests, expected_responses, expected_cancellations, 2000))
        return killWaitFailure(ctx, cycle, "service request cancellation not observed");
    return true;
}

fn waitForStallEndpoint(ctx: *DiagApi, out: *r4os.abi.ServiceInfo, max_ticks: u32) bool {
    var tick: u32 = 0;
    while (tick < max_ticks) : (tick += 1) {
        var info: r4os.abi.ServiceInfo = .{};
        if (ctx.sys.serviceStatus(stall_service_name, &info) == r4os.abi.service_api_result_ok and
            info.handle != 0 and info.instance_id != 0 and
            info.state == r4os.abi.service_state_running and
            (info.flags & r4os.abi.service_api_flag_endpoint) != 0 and
            (info.flags & r4os.abi.service_api_flag_queue_backed) != 0 and
            info.queue_depth == r4os.abi.service_api_endpoint_queue_depth and
            info.queue_used == 0 and info.requests == 0 and info.responses == 0)
        {
            out.* = info;
            return true;
        }
        ctx.sys.sleepTicks(1);
    }
    return false;
}

fn waitForClientIoWait(
    ctx: *DiagApi,
    client: *const r4os.ProcessHandle,
    endpoint_id: u32,
    expected_requests: u64,
    expected_responses: u64,
    max_ticks: u32,
) bool {
    var tick: u32 = 0;
    while (tick < max_ticks) : (tick += 1) {
        switch (client.status()) {
            .value => |instance| {
                if (instance.app_class != @intFromEnum(r4os.abi.ProgramInstanceClass.console) or
                    instance.state == @intFromEnum(r4os.abi.ProgramInstanceState.done))
                    return false;
                if (instance.task_id != 0 and stallRequestQueued(ctx, endpoint_id, expected_requests, expected_responses) and
                    taskBlockedOnCompletion(ctx, instance.task_id))
                    return true;
            },
            .missing, .failure => return false,
        }
        ctx.sys.sleepTicks(1);
    }
    return false;
}

fn stallRequestQueued(ctx: *DiagApi, endpoint_id: u32, expected_requests: u64, expected_responses: u64) bool {
    var info: r4os.abi.ServiceInfo = .{};
    return ctx.sys.serviceStatus(stall_service_name, &info) == r4os.abi.service_api_result_ok and
        info.handle != 0 and info.instance_id == endpoint_id and
        info.state == r4os.abi.service_state_running and
        info.queue_used == @as(u32, if (hasArg(ctx.sys.argsRaw(), "/ASYNCQUICK")) 4 else 1) and info.requests == expected_requests and info.responses == expected_responses and
        info.open_handles == 1;
}

fn waitForStallQueueDrained(
    ctx: *DiagApi,
    endpoint_id: u32,
    expected_requests: u64,
    expected_responses: u64,
    expected_cancellations: u64,
    max_ticks: u32,
) bool {
    var tick: u32 = 0;
    while (tick < max_ticks) : (tick += 1) {
        var info: r4os.abi.ServiceInfo = .{};
        if (ctx.sys.serviceStatus(stall_service_name, &info) == r4os.abi.service_api_result_ok and
            info.instance_id == endpoint_id and info.queue_used == 0 and
            info.requests == expected_requests and info.responses == expected_responses and
            info.cancellations == expected_cancellations and info.open_handles == 1)
            return true;
        ctx.sys.sleepTicks(1);
    }
    return false;
}

fn formatKillWaitArgs(service_handle: u32, out: *[32:0]u8) [*:0]const u8 {
    const prefix = kill_wait_arg ++ " ";
    out.* = .{0} ** 32;
    @memcpy(out[0..prefix.len], prefix);
    var digits: [10]u8 = undefined;
    var value = service_handle;
    var count: usize = 0;
    while (true) {
        digits[count] = @intCast(value % 10);
        count += 1;
        value /= 10;
        if (value == 0) break;
    }
    var index: usize = 0;
    while (index < count) : (index += 1) {
        out[prefix.len + index] = '0' + digits[count - index - 1];
    }
    // A child transcript may intentionally survive in its parent after
    // reaping. Keep successful measured cycles silent so exact storage
    // baselines measure owned resources, not retained diagnostic output.
    const suffix = " /QUIET";
    @memcpy(out[prefix.len + count ..][0..suffix.len], suffix);
    out[prefix.len + count + suffix.len] = 0;
    return @ptrCast(&out[0]);
}

fn taskBlockedOnCompletion(ctx: *DiagApi, task_id: u32) bool {
    var attempt: u32 = 0;
    restart: while (attempt < inventory_restart_limit) : (attempt += 1) {
        var cursor: r4os.abi.ProgramInventoryCursor = .{};
        var summary: r4os.abi.ProgramInventorySummary = .{};
        if (!beginProgramInventory(ctx, &cursor, &summary)) return false;
        while (true) {
            var entries: [@as(usize, r4os.abi.program_inventory_page_max)]r4os.abi.ProgramTaskSnapshot = undefined;
            var page: r4os.abi.ProgramInventoryPageInfo = .{};
            if (!readTaskInventoryPage(ctx, &cursor, entries[0..], &page)) return false;
            if (page.status == r4os.abi.program_inventory_status_restart) continue :restart;
            if (page.returned > entries.len or page.snapshot_generation != cursor.snapshot_generation) return false;
            for (entries[0..@intCast(page.returned)]) |entry| {
                if (entry.task_id == task_id) {
                    if (entry.state != task_state_blocked) return false;
                    return performanceTaskBlockedOnCompletion(ctx, task_id);
                }
            }
            if (page.status == r4os.abi.program_inventory_status_complete) return false;
            if (page.status != r4os.abi.program_inventory_status_more or page.returned == 0) return false;
        }
    }
    return false;
}

fn performanceTaskBlockedOnCompletion(ctx: *DiagApi, task_id: u32) bool {
    const summary = ctx.dev.performanceSummary() orelse return false;
    if (summary.task_max_count == 0) return false;
    var index: u32 = 0;
    while (index < summary.task_max_count) : (index += 1) {
        const info = ctx.dev.performanceTask(index) orelse continue;
        if (info.id != task_id) continue;
        return info.state == task_state_blocked and
            info.blocked_object != 0 and
            fixedZEquals(info.wait_reason[0..], "completion");
    }
    return false;
}

fn instanceExists(ctx: *DiagApi, instance_id: u32) bool {
    var info: r4os.abi.ProgramInstanceInfo = .{};
    // Be conservative on repeated WOULD_BLOCK/restart: cleanup is confirmed
    // only by one complete stable snapshot which does not contain the ID.
    return inventoryProgramById(ctx, instance_id, &info) != 0;
}

// 1 = found, 0 = one stable complete snapshot confirms missing,
// -1 = unavailable after bounded WOULD_BLOCK/restart retries.
fn inventoryProgramById(ctx: *DiagApi, instance_id: u32, out: *r4os.abi.ProgramInstanceInfo) i32 {
    out.* = .{};
    var attempt: u32 = 0;
    restart: while (attempt < inventory_restart_limit) : (attempt += 1) {
        var cursor: r4os.abi.ProgramInventoryCursor = .{};
        var summary: r4os.abi.ProgramInventorySummary = .{};
        if (!beginProgramInventory(ctx, &cursor, &summary)) return -1;
        while (true) {
            var entries: [@as(usize, r4os.abi.program_inventory_page_max)]r4os.abi.ProgramInstanceSnapshot = undefined;
            var page: r4os.abi.ProgramInventoryPageInfo = .{};
            if (!readProgramInventoryPage(ctx, &cursor, entries[0..], &page)) return -1;
            if (page.status == r4os.abi.program_inventory_status_restart) continue :restart;
            if (page.returned > entries.len or page.snapshot_generation != cursor.snapshot_generation) return -1;
            for (entries[0..@intCast(page.returned)]) |entry| {
                if (entry.info.id != instance_id) continue;
                out.* = entry.info;
                return 1;
            }
            if (page.status == r4os.abi.program_inventory_status_complete) return 0;
            if (page.status != r4os.abi.program_inventory_status_more or page.returned == 0) return -1;
        }
    }
    return -1;
}

fn fixedZEquals(buffer: []const u8, expected: []const u8) bool {
    if (expected.len >= buffer.len) return false;
    for (expected, 0..) |byte, index| {
        if (buffer[index] != byte) return false;
    }
    return buffer[expected.len] == 0;
}

fn killWaitFailure(ctx: *DiagApi, cycle: u32, stage: []const u8) bool {
    ctx.sys.write("SPECTRA LIFECYCLE programstorage killwait FAILED cycle=");
    ctx.sys.printU64(@intCast(cycle + 1));
    ctx.sys.write(" stage=");
    ctx.sys.write(stage);
    ctx.sys.write("\r\n");
    return false;
}

fn runNormalLifecycle(
    ctx: *DiagApi,
    path_text: []const u8,
    args: [*:0]const u8,
    policy: r4os.abi.LaunchPolicy,
    expected_class: r4os.abi.ProgramInstanceClass,
) bool {
    const before = captureResourceBaseline(ctx) orelse return false;
    var process = spawnPolicy(ctx, path_text, args, policy) orelse return false;
    if (!waitForClass(ctx, &process, expected_class, false, 250)) {
        cleanupProcess(ctx, &process);
        return false;
    }
    switch (process.wait(finiteTimeout(4000))) {
        .exited => |code| if (code != 0) return false,
        else => {
            cleanupProcess(ctx, &process);
            return false;
        },
    }
    return resourceBaselineRestored(ctx, before);
}

fn runHeldLifecycle(
    ctx: *DiagApi,
    path_text: []const u8,
    args: [*:0]const u8,
    policy: r4os.abi.LaunchPolicy,
    expected_class: r4os.abi.ProgramInstanceClass,
    stop_mode: StopMode,
) bool {
    const before = captureResourceBaseline(ctx) orelse return heldLifecycleFailure(ctx, "baseline-before");
    var process = spawnPolicy(ctx, path_text, args, policy) orelse return heldLifecycleFailure(ctx, "spawn");
    if (expected_class == .gui and !attachHeadlessGui(ctx, &process)) {
        cleanupProcess(ctx, &process);
        return heldLifecycleFailure(ctx, "gui-headless-attach");
    }
    if (!waitForClass(ctx, &process, expected_class, true, 500)) {
        cleanupProcess(ctx, &process);
        return heldLifecycleFailure(ctx, "class-running");
    }
    if (expected_class == .gui and !waitForGuiPayloads(ctx, &process, 500)) {
        switch (process.status()) {
            .value => |info| {
                ctx.sys.write("SPECTRA LIFECYCLE gui-payload wait process state=");
                ctx.sys.printU64(info.state);
                ctx.sys.write(" exit=");
                ctx.sys.printI32(info.exit_code);
                ctx.sys.write("\r\n");
            },
            .missing => ctx.sys.println("SPECTRA LIFECYCLE gui-payload wait process=missing"),
            .failure => ctx.sys.println("SPECTRA LIFECYCLE gui-payload wait process=status-failure"),
        }
        cleanupProcess(ctx, &process);
        return heldLifecycleFailure(ctx, "gui-payloads");
    }
    const stop_result = switch (stop_mode) {
        .request_close => process.requestClose(),
        .kill => process.kill(),
    };
    if (stop_result != 0) {
        cleanupProcess(ctx, &process);
        return heldLifecycleStatusFailure(ctx, "stop", stop_result);
    }
    switch (process.wait(finiteTimeout(4000))) {
        .exited => {},
        .would_block => {
            cleanupProcess(ctx, &process);
            return heldLifecycleFailure(ctx, "wait-would-block");
        },
        .timed_out => {
            cleanupProcess(ctx, &process);
            return heldLifecycleFailure(ctx, "wait-timeout");
        },
        .failure => |status| {
            cleanupProcess(ctx, &process);
            return heldLifecycleStatusFailure(ctx, "wait", status);
        },
    }
    if (!resourceBaselineRestored(ctx, before)) {
        const after = captureResourceBaseline(ctx);
        ctx.sys.write("SPECTRA LIFECYCLE held-lifecycle baseline resources=");
        ctx.sys.printU64(if (after != null and sameTotals(before.resources, after.?.resources)) 1 else 0);
        ctx.sys.write(" instances=");
        ctx.sys.printU64(@intCast(before.instance_count));
        ctx.sys.write("/");
        if (after) |value| {
            ctx.sys.printU64(@intCast(value.instance_count));
        } else {
            ctx.sys.write("unavailable");
        }
        ctx.sys.write("\r\n");
        return heldLifecycleFailure(ctx, "baseline-after");
    }
    return true;
}

fn runGuiRasterChainKillLifecycle(ctx: *DiagApi) bool {
    const before = captureRuntimeBaseline(ctx) orelse return heldLifecycleFailure(ctx, "raster-chain-baseline-before");
    var process = spawnPolicy(ctx, cleanup_path, route.arguments("LIFECYCLE", gui_raster_chain_hold_arg).ptr(), .gui) orelse
        return heldLifecycleFailure(ctx, "raster-chain-spawn");
    if (!attachHeadlessGui(ctx, &process)) {
        cleanupProcess(ctx, &process);
        return heldLifecycleFailure(ctx, "raster-chain-headless-attach");
    }
    if (!waitForClass(ctx, &process, .gui, true, 500)) {
        cleanupProcess(ctx, &process);
        return heldLifecycleFailure(ctx, "raster-chain-class-running");
    }
    const live = waitForGuiRasterChain(ctx, &before.storage, 500) orelse {
        cleanupProcess(ctx, &process);
        return heldLifecycleFailure(ctx, "raster-chain-payloads");
    };
    const live_gui_bytes = live.current_gui_bytes - before.storage.current_gui_bytes;
    if (process.kill() != 0) {
        cleanupProcess(ctx, &process);
        return heldLifecycleFailure(ctx, "raster-chain-kill");
    }
    switch (process.wait(finiteTimeout(4000))) {
        .exited => |code| if (code != -9) return heldLifecycleFailure(ctx, "raster-chain-kill-exit"),
        .would_block => {
            cleanupProcess(ctx, &process);
            return heldLifecycleFailure(ctx, "raster-chain-wait-would-block");
        },
        .timed_out => {
            cleanupProcess(ctx, &process);
            return heldLifecycleFailure(ctx, "raster-chain-wait-timeout");
        },
        .failure => |status| {
            cleanupProcess(ctx, &process);
            return heldLifecycleStatusFailure(ctx, "raster-chain-wait", status);
        },
    }
    const after = captureRuntimeBaseline(ctx) orelse return heldLifecycleFailure(ctx, "raster-chain-baseline-after");
    if (!sameTotals(before.resources, after.resources) or
        !sameMemoryStable(before.memory, after.memory) or
        before.instance_count != after.instance_count or
        !sameStorageCurrent(before.storage, after.storage))
        return heldLifecycleFailure(ctx, "raster-chain-baseline-restore");

    ctx.sys.write("SPECTRA LIFECYCLE programstorage gui raster-chain nodes=6 bytes=");
    ctx.sys.printU64(live_gui_bytes);
    ctx.sys.println(" hard-kill=OK baseline=OK");
    return true;
}

fn processAbiHandle(process: *const r4os.ProcessHandle) r4os.abi.ProgramProcessHandle {
    return .{
        .instance_id = process.raw,
        .reserved = process.handle_reserved,
        .generation = process.generation,
    };
}

fn sameProcessHandle(a: r4os.abi.ProgramProcessHandle, b: r4os.abi.ProgramProcessHandle) bool {
    return a.instance_id == b.instance_id and a.reserved == b.reserved and a.generation == b.generation;
}

fn guiFrameInfoReady(
    handle: r4os.abi.ProgramProcessHandle,
    info: *const r4os.abi.GuiFrameInfo,
) bool {
    return info.version == r4os.abi.gui_frame_info_version and
        info.size >= r4os.abi.gui_frame_info_size and
        sameProcessHandle(info.owner, handle) and
        info.state == r4os.abi.gui_frame_state_idle and
        (info.flags & r4os.abi.gui_frame_flag_committed) != 0 and
        (info.flags & r4os.abi.gui_frame_flag_building) == 0 and
        info.committed_generation != 0 and info.building_generation == 0 and
        info.committed_command_count == gui_frame_total_commands and
        info.committed_resource_bytes == gui_frame_mixed_resource_bytes and
        info.building_command_count == 0 and info.building_resource_bytes == 0 and
        info.current_frame_bytes != 0 and info.peak_frame_bytes >= info.current_frame_bytes and
        info.commit_count == 1 and info.cancel_count == 1 and info.oom_count == 0 and
        info.command_version == r4os.abi.gui_frame_command_version and
        info.command_size == r4os.abi.gui_frame_command_size;
}

fn waitForGuiFrame(
    ctx: *DiagApi,
    process: *const r4os.ProcessHandle,
    out: *r4os.abi.GuiFrameInfo,
    max_ticks: u32,
) bool {
    const handle = processAbiHandle(process);
    var tick: u32 = 0;
    while (tick < max_ticks) : (tick += 1) {
        switch (process.status()) {
            .value => |status| if (status.state == @intFromEnum(r4os.abi.ProgramInstanceState.done)) return false,
            .missing, .failure => return false,
        }
        out.* = .{};
        if (ctx.draw.guiFrameInfo(&handle, out) == r4os.abi.gui_frame_result_ok and guiFrameInfoReady(handle, out))
            return true;
        ctx.sys.sleepTicks(1);
    }
    return false;
}

fn validateGuiFrameSnapshot(
    ctx: *DiagApi,
    handle: *const r4os.abi.ProgramProcessHandle,
    info: *const r4os.abi.GuiFrameInfo,
) bool {
    var short_commands: [1]r4os.abi.GuiFrameCommand = undefined;
    const short_command_bytes: [*]u8 = @ptrCast(&short_commands);
    @memset(short_command_bytes[0..@sizeOf(@TypeOf(short_commands))], 0xC7);
    var short_resources = [_]u8{0xD8} ** 8;
    var short_info: r4os.abi.GuiFrameInfo = .{};
    if (ctx.draw.guiFrameRead(handle, info.committed_generation, short_commands[0..], short_resources[0..], &short_info) !=
        r4os.abi.gui_frame_error_buffer_too_small or
        !allBytesEqual(short_command_bytes[0..@sizeOf(@TypeOf(short_commands))], 0xC7) or
        !allBytesEqual(short_resources[0..], 0xD8) or
        short_info.committed_command_count != gui_frame_total_commands or
        short_info.committed_resource_bytes != gui_frame_mixed_resource_bytes)
        return guiFrameLifecycleFailure(ctx, "snapshot-too-small");

    @memset(short_command_bytes[0..@sizeOf(@TypeOf(short_commands))], 0xE9);
    @memset(short_resources[0..], 0xFA);
    short_info = .{};
    if (ctx.draw.guiFrameRead(handle, info.committed_generation - 1, short_commands[0..], short_resources[0..], &short_info) !=
        r4os.abi.gui_frame_error_stale or
        !allBytesEqual(short_command_bytes[0..@sizeOf(@TypeOf(short_commands))], 0xE9) or
        !allBytesEqual(short_resources[0..], 0xFA))
        return guiFrameLifecycleFailure(ctx, "snapshot-stale");

    var commands: [gui_frame_total_command_count]r4os.abi.GuiFrameCommand = undefined;
    var resources: [gui_frame_mixed_resource_bytes]u8 = undefined;
    var read_info: r4os.abi.GuiFrameInfo = .{};
    if (ctx.draw.guiFrameRead(handle, info.committed_generation, commands[0..], resources[0..], &read_info) !=
        r4os.abi.gui_frame_result_ok or
        !guiFrameInfoReady(handle.*, &read_info) or read_info.snapshot_read_count == 0)
        return guiFrameLifecycleFailure(ctx, "snapshot-read");

    for (commands[0..gui_frame_rect_commands], 0..) |command, index| {
        if (command.version != r4os.abi.gui_frame_command_version or
            command.size != r4os.abi.gui_frame_command_size or
            command.kind != r4os.abi.gui_frame_command_kind_rect or command.flags != 0 or
            command.x != @as(i32, @intCast(index % 640)) or
            command.y != @as(i32, @intCast((index / 640) % 400)) or
            command.w != 1 or command.h != 1 or
            command.resource_offset != 0 or command.resource_bytes != 0)
            return guiFrameLifecycleFailure(ctx, "snapshot-rect");
    }
    const clear = commands[gui_frame_rect_commands];
    const text = commands[gui_frame_rect_commands + 1];
    const raster = commands[gui_frame_rect_commands + 2];
    const alpha = commands[gui_frame_rect_commands + 3];
    if (clear.kind != r4os.abi.gui_frame_command_kind_clear or clear.rgb != 0x00FF_FFFF or clear.flags != 0 or
        text.kind != r4os.abi.gui_frame_command_kind_text or text.resource_offset != 5 or text.resource_bytes != 129 or text.flags != 0 or
        raster.kind != r4os.abi.gui_frame_command_kind_raster or raster.resource_offset != 1 or raster.resource_bytes != 4 or raster.parameter0 != 1 or raster.flags != 0 or
        alpha.kind != r4os.abi.gui_frame_command_kind_alpha8 or alpha.resource_offset != 134 or alpha.resource_bytes != 4 or alpha.flags != 0)
        return guiFrameLifecycleFailure(ctx, "snapshot-mixed-commands");
    if (resources[0] != 0xEE or resources[1] != 0x33 or resources[2] != 0x22 or
        resources[3] != 0x11 or resources[4] != 0 or
        !allBytesEqual(resources[5..134], 'A') or
        resources[134] != 0x10 or resources[135] != 0x40 or resources[136] != 0x80 or resources[137] != 0xFF)
        return guiFrameLifecycleFailure(ctx, "snapshot-resource-bytes");
    return true;
}

fn hardKillGuiFrameProcess(process: *r4os.ProcessHandle) bool {
    if (process.kill() != r4os.abi.program_handle_ok) return false;
    return switch (process.wait(finiteTimeout(10_000))) {
        .exited => |code| code == -9,
        else => false,
    };
}

fn forceNextProgramInstanceId(ctx: *DiagApi, instance_id: u32) bool {
    var force: r4os.abi.ProgramRegistrySelfTestResultV2 = .{
        .operation = r4os.abi.program_registry_self_test_operation_force_next_id,
        .requested_next_id = instance_id,
    };
    return ctx.dev.programRegistrySelfTestV2(&force) > 0 and
        force.version == 2 and force.size >= @sizeOf(r4os.abi.ProgramRegistrySelfTestResultV2) and
        force.lifecycle_result == r4os.abi.program_handle_ok and force.applied_next_id == instance_id and
        (force.flags & r4os.abi.program_registry_self_test_flag_allowed) != 0;
}

fn staleGuiFrameHandleRejected(
    ctx: *DiagApi,
    stale: *const r4os.abi.ProgramProcessHandle,
    replacement: *const r4os.abi.ProgramProcessHandle,
) bool {
    var info: r4os.abi.GuiFrameInfo = .{};
    if (ctx.draw.guiFrameInfo(stale, &info) != r4os.abi.gui_frame_error_invalid or
        !sameProcessHandle(info.owner, replacement.*))
        return guiFrameLifecycleFailure(ctx, "stale-handle-info");
    var commands: [1]r4os.abi.GuiFrameCommand = undefined;
    const command_bytes: [*]u8 = @ptrCast(&commands);
    @memset(command_bytes[0..@sizeOf(@TypeOf(commands))], 0xAB);
    var resources = [_]u8{0xBC} ** 8;
    info = .{};
    if (ctx.draw.guiFrameRead(stale, 1, commands[0..], resources[0..], &info) != r4os.abi.gui_frame_error_invalid or
        !allBytesEqual(command_bytes[0..@sizeOf(@TypeOf(commands))], 0xAB) or
        !allBytesEqual(resources[0..], 0xBC) or !sameProcessHandle(info.owner, replacement.*))
        return guiFrameLifecycleFailure(ctx, "stale-handle-read");
    return true;
}

fn runGuiFrameContractLifecycle(ctx: *DiagApi) bool {
    if (!ctx.draw.supportsGuiFrameContract() or !ctx.dev.hasFn("program_registry_self_test_v2"))
        return guiFrameLifecycleFailure(ctx, "contract-unavailable");
    const cold = captureRuntimeBaseline(ctx) orelse return guiFrameLifecycleFailure(ctx, "baseline-cold");
    if (!warmGuiFrameContractConcurrency(ctx)) return guiFrameLifecycleFailure(ctx, "warm-concurrency");
    const baseline = captureRuntimeBaseline(ctx) orelse return guiFrameLifecycleFailure(ctx, "baseline-before");
    if (!sameTotals(cold.resources, baseline.resources) or cold.instance_count != baseline.instance_count or
        !sameStorageCurrent(cold.storage, baseline.storage))
        return guiFrameLifecycleFailure(ctx, "warm-baseline-restore");

    var first = spawnPolicy(ctx, cleanup_path, route.arguments("LIFECYCLE", gui_frame_hold_arg).ptr(), .gui) orelse
        return guiFrameLifecycleFailure(ctx, "first-spawn");
    defer cleanupProcess(ctx, &first);
    if (!attachHeadlessGui(ctx, &first)) return guiFrameLifecycleFailure(ctx, "first-attach");
    var first_info: r4os.abi.GuiFrameInfo = .{};
    if (!waitForGuiFrame(ctx, &first, &first_info, 10_000)) return guiFrameLifecycleFailure(ctx, "first-frame");
    const stale_handle = processAbiHandle(&first);
    if (!validateGuiFrameSnapshot(ctx, &stale_handle, &first_info)) return false;
    if (!hardKillGuiFrameProcess(&first)) return guiFrameLifecycleFailure(ctx, "first-hard-kill");

    if (!forceNextProgramInstanceId(ctx, stale_handle.instance_id)) return guiFrameLifecycleFailure(ctx, "force-id-reuse");
    var replacement = spawnPolicy(ctx, cleanup_path, route.arguments("LIFECYCLE", gui_frame_hold_arg).ptr(), .gui) orelse
        return guiFrameLifecycleFailure(ctx, "replacement-spawn");
    defer cleanupProcess(ctx, &replacement);
    const replacement_handle = processAbiHandle(&replacement);
    if (replacement_handle.instance_id != stale_handle.instance_id or replacement_handle.generation == stale_handle.generation or
        !attachHeadlessGui(ctx, &replacement))
        return guiFrameLifecycleFailure(ctx, "replacement-identity-attach");

    var parallel = spawnPolicy(ctx, cleanup_path, route.arguments("LIFECYCLE", gui_frame_hold_arg).ptr(), .gui) orelse
        return guiFrameLifecycleFailure(ctx, "parallel-spawn");
    defer cleanupProcess(ctx, &parallel);
    const parallel_handle = processAbiHandle(&parallel);
    if (!attachHeadlessGui(ctx, &parallel)) return guiFrameLifecycleFailure(ctx, "parallel-attach");

    var replacement_info: r4os.abi.GuiFrameInfo = .{};
    var parallel_info: r4os.abi.GuiFrameInfo = .{};
    if (!waitForGuiFrame(ctx, &replacement, &replacement_info, 10_000))
        return guiFrameLifecycleFailure(ctx, "replacement-frame");
    if (!waitForGuiFrame(ctx, &parallel, &parallel_info, 10_000))
        return guiFrameLifecycleFailure(ctx, "parallel-frame");
    if (replacement_info.committed_generation == parallel_info.committed_generation)
        return guiFrameLifecycleFailure(ctx, "parallel-generation-unique");
    if (!staleGuiFrameHandleRejected(ctx, &stale_handle, &replacement_handle)) return false;

    if (!hardKillGuiFrameProcess(&replacement)) return guiFrameLifecycleFailure(ctx, "replacement-hard-kill");
    var retained_parallel: r4os.abi.GuiFrameInfo = .{};
    if (ctx.draw.guiFrameInfo(&parallel_handle, &retained_parallel) != r4os.abi.gui_frame_result_ok or
        retained_parallel.committed_generation != parallel_info.committed_generation)
        return guiFrameLifecycleFailure(ctx, "parallel-retained");
    if (!hardKillGuiFrameProcess(&parallel)) return guiFrameLifecycleFailure(ctx, "parallel-hard-kill");

    const after = captureRuntimeBaseline(ctx) orelse return guiFrameLifecycleFailure(ctx, "baseline-after");
    const resources_restored = sameTotals(baseline.resources, after.resources);
    const memory_restored = sameMemoryStable(baseline.memory, after.memory);
    const instances_restored = baseline.instance_count == after.instance_count;
    const storage_restored = sameStorageCurrent(baseline.storage, after.storage);
    if (!resources_restored or !memory_restored or !instances_restored or !storage_restored) {
        ctx.sys.write("SPECTRA LIFECYCLE gui-frame baseline resources/memory/instances/storage=");
        ctx.sys.printU64(@intFromBool(resources_restored));
        ctx.sys.write("/");
        ctx.sys.printU64(@intFromBool(memory_restored));
        ctx.sys.write("/");
        ctx.sys.printU64(@intFromBool(instances_restored));
        ctx.sys.write("/");
        ctx.sys.printU64(@intFromBool(storage_restored));
        ctx.sys.write(" currentPayload=");
        ctx.sys.printU64(baseline.storage.current_payload_bytes);
        ctx.sys.write("/");
        ctx.sys.printU64(after.storage.current_payload_bytes);
        ctx.sys.write(" frameBytes=");
        ctx.sys.printU64(baseline.storage.current_gui_frame_bytes);
        ctx.sys.write("/");
        ctx.sys.printU64(after.storage.current_gui_frame_bytes);
        ctx.sys.write(" frameNodes=");
        ctx.sys.printU64(baseline.storage.current_gui_frame_nodes);
        ctx.sys.write("/");
        ctx.sys.printU64(after.storage.current_gui_frame_nodes);
        ctx.sys.write(" failures=");
        ctx.sys.printU64(baseline.storage.allocation_failures);
        ctx.sys.write("/");
        ctx.sys.printU64(after.storage.allocation_failures);
        ctx.sys.write(" rollbacks=");
        ctx.sys.printU64(baseline.storage.transaction_rollbacks);
        ctx.sys.write("/");
        ctx.sys.printU64(after.storage.transaction_rollbacks);
        ctx.sys.write(" freePhysical=");
        ctx.sys.printU64(baseline.memory.free_physical_bytes);
        ctx.sys.write("/");
        ctx.sys.printU64(after.memory.free_physical_bytes);
        ctx.sys.write("\r\n");
        return guiFrameLifecycleFailure(ctx, "baseline-restore");
    }

    ctx.sys.println("SPECTRA LIFECYCLE programstorage gui-frame commands=4116 resources=138 snapshot=exact too-small=atomic cancel=retained id-reuse=stale-rejected parallel=2 hard-kill=OK baseline=OK");
    return true;
}

fn warmGuiFrameContractConcurrency(ctx: *DiagApi) bool {
    // The heap keeps newly obtained physical pages for reuse.  Reach the same
    // two-window peak as the actual ABA test before taking its strict memory
    // baseline, while still requiring both warm instances and all owned frame
    // storage to be fully reaped by the caller's cold/warm comparison.
    var first = spawnPolicy(ctx, cleanup_path, route.arguments("LIFECYCLE", gui_frame_hold_arg).ptr(), .gui) orelse return false;
    defer cleanupProcess(ctx, &first);
    var second = spawnPolicy(ctx, cleanup_path, route.arguments("LIFECYCLE", gui_frame_hold_arg).ptr(), .gui) orelse return false;
    defer cleanupProcess(ctx, &second);
    if (!attachHeadlessGui(ctx, &first) or !attachHeadlessGui(ctx, &second)) return false;
    var first_info: r4os.abi.GuiFrameInfo = .{};
    var second_info: r4os.abi.GuiFrameInfo = .{};
    if (!waitForGuiFrame(ctx, &first, &first_info, 10_000) or
        !waitForGuiFrame(ctx, &second, &second_info, 10_000) or
        first_info.committed_generation == second_info.committed_generation)
        return false;
    if (!hardKillGuiFrameProcess(&first)) return false;
    if (!hardKillGuiFrameProcess(&second)) return false;
    return true;
}

fn guiFrameLifecycleFailure(ctx: *DiagApi, stage: []const u8) bool {
    ctx.sys.write("SPECTRA LIFECYCLE gui-frame FAILED stage=");
    ctx.sys.write(stage);
    ctx.sys.write("\r\n");
    return false;
}

fn attachHeadlessGui(ctx: *DiagApi, process: *const r4os.ProcessHandle) bool {
    const child_handle = processAbiHandle(process);
    return ctx.desk.programSetWindowHandle(&child_handle, 0) == r4os.abi.program_handle_ok;
}

fn heldLifecycleFailure(ctx: *DiagApi, stage: []const u8) bool {
    ctx.sys.write("SPECTRA LIFECYCLE held-lifecycle FAILED stage=");
    ctx.sys.write(stage);
    ctx.sys.write("\r\n");
    return false;
}

fn heldLifecycleStatusFailure(ctx: *DiagApi, stage: []const u8, status: i32) bool {
    ctx.sys.write("SPECTRA LIFECYCLE held-lifecycle FAILED stage=");
    ctx.sys.write(stage);
    ctx.sys.write(" status=");
    ctx.sys.printI32(status);
    ctx.sys.write("\r\n");
    return false;
}

fn spawnPolicy(
    ctx: *DiagApi,
    path_text: []const u8,
    args: [*:0]const u8,
    policy: r4os.abi.LaunchPolicy,
) ?r4os.ProcessHandle {
    var path = r4os.FilePath.parse(path_text) catch return null;
    return switch (ctx.resources.spawn(path.asZ(), args, policy)) {
        .process => |process| process,
        .failure => null,
    };
}

fn waitForClass(
    ctx: *DiagApi,
    process: *const r4os.ProcessHandle,
    expected_class: r4os.abi.ProgramInstanceClass,
    require_running: bool,
    max_ticks: u32,
) bool {
    var tick: u32 = 0;
    while (tick < max_ticks) : (tick += 1) {
        switch (process.status()) {
            .value => |info| {
                if (info.app_class != @intFromEnum(expected_class)) return false;
                if (!require_running or info.state == @intFromEnum(r4os.abi.ProgramInstanceState.running)) return true;
                if (info.state == @intFromEnum(r4os.abi.ProgramInstanceState.done)) return false;
            },
            .missing, .failure => return false,
        }
        ctx.sys.sleepTicks(1);
    }
    return false;
}

fn waitForGuiPayloads(
    ctx: *DiagApi,
    process: *const r4os.ProcessHandle,
    max_ticks: u32,
) bool {
    const instance_id = process.instanceId();
    var last_clear_status: i32 = 0;
    var last_blit_status: i32 = 0;
    var last_raster_status: i32 = 0;
    var last_clear: r4os.abi.GuiCommand = .{};
    var last_blit: r4os.abi.GuiCommand = .{};
    var last_pixels = [_]u32{0} ** gui_payload_pixels.len;
    var tick: u32 = 0;
    while (tick < max_ticks) : (tick += 1) {
        switch (process.status()) {
            .value => |info| {
                if (info.state == @intFromEnum(r4os.abi.ProgramInstanceState.done)) return false;
                if (info.state != @intFromEnum(r4os.abi.ProgramInstanceState.running)) {
                    ctx.sys.sleepTicks(1);
                    continue;
                }
            },
            .missing, .failure => return false,
        }

        last_clear = .{};
        last_blit = .{};
        last_clear_status = ctx.desk.guiCommand(instance_id, 0, &last_clear);
        last_blit_status = ctx.desk.guiCommand(instance_id, 1, &last_blit);
        if (last_clear_status > 0 and last_blit_status > 0 and
            last_clear.kind == 1 and last_blit.kind == 4 and
            last_blit.w == 2 and last_blit.h == 2)
        {
            @memset(last_pixels[0..], 0);
            last_raster_status = ctx.draw.guiRasterRead(instance_id, last_blit.rgb, last_pixels[0..]);
            if (last_raster_status == last_pixels.len) {
                var exact = true;
                for (last_pixels, gui_payload_pixels) |actual, expected| exact = exact and actual == expected;
                if (exact) return true;
            }
        }
        ctx.sys.sleepTicks(1);
    }
    ctx.sys.write("SPECTRA LIFECYCLE gui-payload read cmdStatus=");
    ctx.sys.printI32(last_clear_status);
    ctx.sys.write("/");
    ctx.sys.printI32(last_blit_status);
    ctx.sys.write(" kind=");
    ctx.sys.printU64(last_clear.kind);
    ctx.sys.write("/");
    ctx.sys.printU64(last_blit.kind);
    ctx.sys.write(" size=");
    ctx.sys.printU64(last_blit.w);
    ctx.sys.write("x");
    ctx.sys.printU64(last_blit.h);
    ctx.sys.write(" offset=");
    ctx.sys.printU64(last_blit.rgb);
    ctx.sys.write(" rasterStatus=");
    ctx.sys.printI32(last_raster_status);
    ctx.sys.write(" pixels=");
    for (last_pixels, 0..) |pixel, index| {
        if (index != 0) ctx.sys.write(",");
        ctx.sys.printU64(pixel);
    }
    ctx.sys.write("\r\n");
    return false;
}

fn waitForGuiRasterChain(
    ctx: *DiagApi,
    before: *const r4os.abi.ProgramInstanceStorageSummary,
    max_ticks: u32,
) ?r4os.abi.ProgramInstanceStorageSummary {
    const raster_data_bytes: u64 = @as(u64, gui_raster_chain_tile_count) *
        gui_raster_chain_tile_width * gui_raster_chain_tile_height * @sizeOf(u32);
    var tick: u32 = 0;
    while (tick < max_ticks) : (tick += 1) {
        var current: r4os.abi.ProgramInstanceStorageSummary = .{};
        if (ctx.dev.programInstanceStorageSummary(&current) <= 0 or !storageSummaryValid(&current)) return null;
        if (current.active_gui_instances == before.active_gui_instances + 1 and
            current.gui_payloads == before.gui_payloads + 1 and
            current.gui_command_payloads == before.gui_command_payloads + 1 and
            current.gui_raster_payloads == before.gui_raster_payloads + gui_raster_chain_tile_count and
            current.current_gui_bytes >= before.current_gui_bytes + raster_data_bytes)
            return current;
        ctx.sys.sleepTicks(1);
    }
    return null;
}

fn cleanupProcess(ctx: *DiagApi, process: *r4os.ProcessHandle) void {
    if (!process.valid()) return;
    _ = process.kill();
    _ = process.wait(finiteTimeout(2000));
    _ = ctx;
}

const ResourceBaseline = struct {
    resources: ResourceTotals,
    instance_count: u8,
};

const RuntimeBaseline = struct {
    resources: ResourceTotals,
    memory: r4os.abi.ProgramMemorySummary,
    storage: r4os.abi.ProgramInstanceStorageSummary,
    instance_count: u8,
};

fn printBaselineDiff(ctx: *DiagApi, before: RuntimeBaseline, after: RuntimeBaseline) void {
    inline for (.{ "resources", "storage" }) |section| {
        inline for (@typeInfo(@TypeOf(@field(before, section))).@"struct".fields) |field| {
            const first = @field(@field(before, section), field.name);
            const last = @field(@field(after, section), field.name);
            if (first != last) {
                ctx.sys.write("SPECTRA LIFECYCLE baseline diff " ++ section ++ "." ++ field.name ++ "=");
                ctx.sys.printU64(first);
                ctx.sys.write(" -> ");
                ctx.sys.printU64(last);
                ctx.sys.println("");
            }
        }
    }
    if (before.instance_count != after.instance_count) {
        ctx.sys.write("SPECTRA LIFECYCLE baseline diff instances=");
        ctx.sys.printU64(before.instance_count);
        ctx.sys.write(" -> ");
        ctx.sys.printU64(after.instance_count);
        ctx.sys.println("");
    }
}

fn captureResourceBaseline(ctx: *DiagApi) ?ResourceBaseline {
    const resources = resourceTotals(ctx) orelse return null;
    var status: r4os.abi.ProgramStatus = .{};
    ctx.dev.programStatus(&status);
    return .{ .resources = resources, .instance_count = status.instance_count };
}

fn resourceBaselineRestored(ctx: *DiagApi, before: ResourceBaseline) bool {
    const after = captureResourceBaseline(ctx) orelse return false;
    return sameTotals(before.resources, after.resources) and before.instance_count == after.instance_count;
}

fn captureRuntimeBaseline(ctx: *DiagApi) ?RuntimeBaseline {
    const resources = resourceTotals(ctx) orelse {
        ctx.sys.println("SPECTRA LIFECYCLE baseline: resource totals unavailable");
        return null;
    };
    const memory = ctx.dev.memorySummary() orelse {
        ctx.sys.println("SPECTRA LIFECYCLE baseline: memory summary unavailable");
        return null;
    };
    if (memory.overflow != 0 or memory.error_blocks != 0) {
        ctx.sys.println("SPECTRA LIFECYCLE baseline: memory tracking errors");
        return null;
    }
    var storage: r4os.abi.ProgramInstanceStorageSummary = .{};
    if (ctx.dev.programInstanceStorageSummary(&storage) <= 0) {
        ctx.sys.println("SPECTRA LIFECYCLE baseline: storage summary unavailable");
        return null;
    }
    if (!storageSummaryValid(&storage)) {
        ctx.sys.write("SPECTRA LIFECYCLE baseline: storage summary invalid line=");
        ctx.sys.printU64(storage_invalid_line);
        ctx.sys.write(" owners=");
        ctx.sys.printU64(storage.owner_mismatches);
        ctx.sys.write(" headers=");
        ctx.sys.printU64(storage.header_errors);
        ctx.sys.write(" frees=");
        ctx.sys.printU64(storage.free_failures);
        ctx.sys.write(" quarantine=");
        ctx.sys.printU64(storage.quarantined_payloads);
        ctx.sys.write(" active=");
        ctx.sys.printU64(storage.active_instances);
        ctx.sys.write(" runtime=");
        ctx.sys.printU64(storage.runtime_payloads);
        ctx.sys.write(" process=");
        ctx.sys.printU64(storage.process_payloads);
        ctx.sys.write(" console=");
        ctx.sys.printU64(storage.active_console_instances);
        ctx.sys.write("/");
        ctx.sys.printU64(storage.console_payloads);
        ctx.sys.write("/");
        ctx.sys.printU64(storage.console_output_payloads);
        ctx.sys.write(" gui=");
        ctx.sys.printU64(storage.active_gui_instances);
        ctx.sys.write("/");
        ctx.sys.printU64(storage.gui_payloads);
        ctx.sys.write(" frames=");
        ctx.sys.printU64(storage.current_gui_frame_nodes);
        ctx.sys.write(" environment=");
        ctx.sys.printU64(storage.environment_payloads);
        ctx.sys.println("");
        return null;
    }
    var status: r4os.abi.ProgramStatus = .{};
    ctx.dev.programStatus(&status);
    if (storage.active_instances != @as(u32, status.instance_count)) {
        ctx.sys.println("SPECTRA LIFECYCLE baseline: instance count changed");
        return null;
    }
    return .{
        .resources = resources,
        .memory = memory,
        .storage = storage,
        .instance_count = status.instance_count,
    };
}

fn printRuntimeBaseline(ctx: *DiagApi, baseline: *const RuntimeBaseline) void {
    ctx.sys.write("SPECTRA LIFECYCLE programstorage baseline instances=");
    ctx.sys.printU64(@intCast(baseline.instance_count));
    ctx.sys.write(" activeBytes=");
    ctx.sys.printU64(baseline.storage.active_instance_bytes);
    ctx.sys.write(" reservedBytes=");
    ctx.sys.printU64(baseline.storage.reserved_instance_bytes);
    ctx.sys.write(" payloadBytes=");
    ctx.sys.printU64(baseline.storage.current_payload_bytes);
    ctx.sys.write(" freePhysical=");
    ctx.sys.printU64(baseline.memory.free_physical_bytes);
    ctx.sys.write("\r\n");
}

var storage_invalid_line: u32 = 0;
fn storageInvalid(line: u32) bool {
    storage_invalid_line = line;
    return false;
}
fn storageSummaryValid(summary: *const r4os.abi.ProgramInstanceStorageSummary) bool {
    if (summary.version != 2 or summary.size < @sizeOf(r4os.abi.ProgramInstanceStorageSummary)) return storageInvalid(@src().line);
    if (summary.core_bytes_per_instance == 0 or summary.registry_reserved_core_bytes == 0) return storageInvalid(@src().line);
    if (summary.active_console_instances + summary.active_gui_instances + summary.active_service_instances != summary.active_instances)
        return storageInvalid(@src().line);
    if (summary.runtime_payloads != summary.active_instances or
        summary.process_payloads != summary.active_instances or
        summary.console_payloads != summary.active_console_instances or
        // Output includes segmented writers and completion transcripts;
        // those deliberately survive the producing console instance.
        summary.console_output_payloads < summary.active_console_instances or
        summary.gui_payloads < summary.active_gui_instances or
        summary.gui_payloads > summary.active_instances or
        summary.environment_payloads > summary.active_instances or
        ((summary.gui_command_payloads != 0 or summary.gui_raster_payloads != 0 or
            summary.current_gui_frame_nodes != 0) and summary.gui_payloads == 0))
        return storageInvalid(@src().line);
    if (summary.live_core_bytes != @as(u64, summary.active_instances) * summary.core_bytes_per_instance or
        summary.current_runtime_bytes + summary.current_console_bytes + summary.current_gui_bytes != summary.current_payload_bytes)
        return storageInvalid(@src().line);
    const active_payload_bytes = if (summary.current_payload_bytes >= summary.quarantined_bytes)
        summary.current_payload_bytes - summary.quarantined_bytes
    else
        return storageInvalid(@src().line);
    // The fixed summary has no separate active-console-byte field. Only
    // console output can be retained by completion/transcript consumers;
    // runtime and GUI bytes still belong to the live instances.
    if (summary.active_instance_bytes < summary.live_core_bytes + summary.current_runtime_bytes + summary.current_gui_bytes or
        summary.active_instance_bytes > summary.live_core_bytes + active_payload_bytes or
        summary.reserved_instance_bytes != summary.registry_reserved_core_bytes + summary.current_payload_bytes)
        return storageInvalid(@src().line);
    if (summary.peak_active_instance_bytes < summary.active_instance_bytes or
        summary.peak_reserved_instance_bytes < summary.reserved_instance_bytes or
        summary.peak_payload_bytes < summary.current_payload_bytes or
        summary.peak_runtime_bytes < summary.current_runtime_bytes or
        summary.peak_console_bytes < summary.current_console_bytes or
        summary.peak_gui_bytes < summary.current_gui_bytes or
        summary.peak_gui_frame_bytes < summary.current_gui_frame_bytes or
        summary.peak_gui_frame_commands < summary.current_gui_frame_commands or
        summary.peak_gui_frame_nodes < summary.current_gui_frame_nodes)
        return storageInvalid(@src().line);
    if (summary.current_gui_frame_bytes > summary.current_gui_bytes or
        (summary.current_gui_frame_nodes == 0 and
            (summary.current_gui_frame_bytes != 0 or summary.current_gui_frame_commands != 0)) or
        (summary.current_gui_frame_nodes != 0 and summary.current_gui_frame_bytes == 0))
        return storageInvalid(@src().line);
    if (summary.current_payload_bytes == 0 or summary.payload_releases > summary.payload_allocations or
        summary.payload_allocations > summary.allocation_attempts)
        return storageInvalid(@src().line);
    // current_gui_frame_nodes is the non-overlapping total of frame roots,
    // command blocks, raster blocks and generic frame-data blocks.  The
    // legacy command/raster counters are useful physical detail, but adding
    // them here as well would double-count those two node kinds.
    const live_payloads = @as(u64, summary.runtime_payloads) + @as(u64, summary.process_payloads) +
        @as(u64, summary.environment_payloads) + @as(u64, summary.console_payloads) + @as(u64, summary.console_output_payloads) +
        @as(u64, summary.gui_payloads) + summary.current_gui_frame_nodes;
    if (summary.payload_allocations - summary.payload_releases != live_payloads + summary.quarantined_payloads)
        return storageInvalid(@src().line);
    if (summary.owner_mismatches != 0 or summary.header_errors != 0 or summary.free_failures != 0 or
        summary.quarantined_payloads != 0 or summary.quarantined_bytes != 0)
        return storageInvalid(@src().line);
    return true;
}

fn sameStorageCurrent(a: r4os.abi.ProgramInstanceStorageSummary, b: r4os.abi.ProgramInstanceStorageSummary) bool {
    return a.version == b.version and
        a.size == b.size and
        a.core_bytes_per_instance == b.core_bytes_per_instance and
        a.registry_reserved_core_bytes == b.registry_reserved_core_bytes and
        a.live_core_bytes == b.live_core_bytes and
        a.active_instance_bytes == b.active_instance_bytes and
        a.reserved_instance_bytes == b.reserved_instance_bytes and
        a.current_payload_bytes == b.current_payload_bytes and
        a.current_runtime_bytes == b.current_runtime_bytes and
        a.current_console_bytes == b.current_console_bytes and
        a.current_gui_bytes == b.current_gui_bytes and
        a.active_instances == b.active_instances and
        a.active_console_instances == b.active_console_instances and
        a.active_gui_instances == b.active_gui_instances and
        a.active_service_instances == b.active_service_instances and
        a.runtime_payloads == b.runtime_payloads and
        a.process_payloads == b.process_payloads and
        a.environment_payloads == b.environment_payloads and
        a.console_payloads == b.console_payloads and
        a.console_output_payloads == b.console_output_payloads and
        a.gui_payloads == b.gui_payloads and
        a.gui_command_payloads == b.gui_command_payloads and
        a.gui_raster_payloads == b.gui_raster_payloads and
        a.current_gui_frame_bytes == b.current_gui_frame_bytes and
        a.current_gui_frame_commands == b.current_gui_frame_commands and
        a.current_gui_frame_nodes == b.current_gui_frame_nodes and
        a.allocation_failures == b.allocation_failures and
        a.transaction_rollbacks == b.transaction_rollbacks and
        a.owner_mismatches == b.owner_mismatches and
        a.header_errors == b.header_errors and
        a.free_failures == b.free_failures and
        a.quarantined_payloads == b.quarantined_payloads and
        a.quarantined_bytes == b.quarantined_bytes;
}

fn sameMemoryStable(a: r4os.abi.ProgramMemorySummary, b: r4os.abi.ProgramMemorySummary) bool {
    return a.active_blocks == b.active_blocks and
        a.physical_bytes == b.physical_bytes and
        a.virtual_bytes == b.virtual_bytes and
        a.reserved_bytes == b.reserved_bytes and
        a.committed_bytes == b.committed_bytes and
        a.free_physical_bytes == b.free_physical_bytes and
        a.largest_free_phys_base == b.largest_free_phys_base and
        a.largest_free_phys_len == b.largest_free_phys_len and
        a.largest_free_virtual_base == b.largest_free_virtual_base and
        a.largest_free_virtual_len == b.largest_free_virtual_len and
        a.app_system_reserve_frames == b.app_system_reserve_frames and
        a.app_available_frames == b.app_available_frames;
}

fn programStorageFail(ctx: *DiagApi, msg: []const u8) bool {
    ctx.sys.write("SPECTRA LIFECYCLE programstorage FAILED: ");
    ctx.sys.write(msg);
    ctx.sys.write("\r\n");
    ctx.sys.println("SPECTRA LIFECYCLE programstorage result: FAILED");
    _ = fail(ctx, msg);
    return false;
}

fn testWatchCancellation(ctx: *DiagApi, standard: bool) i32 {
    var child: r4os.abi.ProgramProcessHandle = .{};
    const arguments = if (standard) "BENCH STANDARD /SETTLE:5000 /JSON" else "METRICS CLOCK /JSON /WATCH:60 /INTERVAL:1000";
    if (ctx.sys.programSpawnHandle(route.path, arguments, .console, &child) != r4os.abi.program_handle_ok)
        return fail(ctx, "watch spawn failed");
    var completion: r4os.abi.ProgramProcessCompletion = .{};
    var reaped = false;
    const timeout = ctx.sys.ticksFromMilliseconds(cleanup_lifecycle_timeout_ms);
    defer if (!reaped) {
        _ = ctx.sys.programHandleKill(&child);
        if (ctx.sys.programHandleWait(&child, timeout, &completion) == r4os.abi.program_handle_ok)
            _ = ctx.sys.programHandleReap(&child, &completion);
    };
    const start = ctx.sys.ticks();
    var output_seen = false;
    while (ctx.sys.ticks() -| start < timeout) {
        if (standard) {
            var info: r4os.abi.ProgramInstanceInfo = .{};
            if (ctx.sys.programHandleStatus(&child, &info) == r4os.abi.program_handle_ok and info.state == @intFromEnum(r4os.abi.ProgramInstanceState.running)) {
                ctx.sys.sleepTicks(ctx.sys.ticksFromMilliseconds(200));
                output_seen = true;
                break;
            }
        }
        var state: r4os.abi.ConsoleState = .{};
        if (ctx.sys.consoleState(child.instance_id, &state) >= 0 and state.stdout_bytes != 0) { output_seen = true; break; }
        ctx.sys.sleepTicks(1);
    }
    if (!output_seen) return fail(ctx, "watch did not produce its first snapshot");
    if (ctx.sys.programHandleRequestClose(&child) != r4os.abi.program_handle_ok or
        ctx.sys.programHandleWait(&child, timeout, &completion) != r4os.abi.program_handle_ok or
        completion.exit_code != 4)
        return fail(ctx, "watch did not acknowledge cancellation with exit 4");
    if (ctx.sys.programHandleReap(&child, &completion) != r4os.abi.program_handle_ok)
        return fail(ctx, "watch reap failed");
    reaped = true;
    var info: r4os.abi.ProgramInstanceInfo = .{};
    // Reap consumes the completion. Without a replacement generation the
    // handle contract reports not-found; stale applies after ID reuse.
    if (ctx.sys.programHandleStatus(&child, &info) != r4os.abi.program_handle_error_not_found)
        return fail(ctx, "cancelled watch handle remains visible");
    if (ownerResourceBlocks(ctx, child.instance_id) != 0)
        return fail(ctx, "cancelled watch retained resource blocks");
    ctx.sys.println(if (standard) "SPECTRA LIFECYCLE standard cancel: OK exit=4 owner-blocks=0 handle=not-found" else "SPECTRA LIFECYCLE watch cancel: OK exit=4 owner-blocks=0 handle=not-found");
    return 0;
}

fn testNormalExit(ctx: *DiagApi) bool {
    const before = resourceTotals(ctx) orelse return failBool(ctx, "baseline unavailable");
    var process = spawn(ctx, "C:\\R4OS\\SOFTWARE\\TERMINAL\\DIAG\\APPHEAPD.R4X", "") orelse return failBool(ctx, "normal spawn failed");
    const id = process.instanceId();
    switch (process.status()) {
        .value => {},
        else => return failBool(ctx, "normal status failed"),
    }
    var borrowed = switch (ctx.resources.openProcess(id)) {
        .process => |value| value,
        .failure => return failBool(ctx, "normal open failed"),
    };
    switch (borrowed.reap()) {
        .failure => |raw| if (raw != r4os.abi.err_not_owned) return failBool(ctx, "borrowed reap mismatch"),
        else => return failBool(ctx, "borrowed reap accepted"),
    }
    if (!waitForExitOrCleanup(ctx, &process, finiteTimeout(cleanup_lifecycle_timeout_ms), "normal wait failed")) return false;
    const after = resourceTotals(ctx) orelse return failBool(ctx, "normal after unavailable");
    if (!sameTotals(before, after)) return failBool(ctx, "normal cleanup mismatch");
    return true;
}

fn testRequestCloseCleanup(ctx: *DiagApi) bool {
    const before = resourceTotals(ctx) orelse return failBool(ctx, "close baseline unavailable");
    var process = spawn(ctx, "C:\\R4OS\\SOFTWARE\\TERMINAL\\DIAG\\APPHEAPD.R4X", "/HOLD") orelse return failBool(ctx, "close spawn failed");
    const id = process.instanceId();
    if (!waitOwnerResources(ctx, id, 500)) return failBool(ctx, "close resources not visible");
    if (process.requestClose() != 0) return failBool(ctx, "program_request_close failed");
    if (!waitForExitOrCleanup(ctx, &process, finiteTimeout(cleanup_lifecycle_timeout_ms), "close wait failed")) return false;
    if (ownerResourceBlocks(ctx, id) != 0) return failBool(ctx, "closed owner still has blocks");
    const after = resourceTotals(ctx) orelse return failBool(ctx, "close after unavailable");
    return sameTotals(before, after) or failBool(ctx, "close cleanup mismatch");
}

fn testKillCleanup(ctx: *DiagApi) bool {
    const before = resourceTotals(ctx) orelse return failBool(ctx, "kill baseline unavailable");
    var process = spawn(ctx, "C:\\R4OS\\SOFTWARE\\TERMINAL\\DIAG\\APPHEAPD.R4X", "/HOLD") orelse return failBool(ctx, "hold spawn failed");
    const id = process.instanceId();
    if (!waitOwnerResources(ctx, id, 250)) return failBool(ctx, "hold resources not visible");
    if (process.kill() != 0) return failBool(ctx, "program_kill failed");
    if (!waitForExitOrCleanup(ctx, &process, finiteTimeout(cleanup_lifecycle_timeout_ms), "kill wait failed")) return false;
    if (ownerResourceBlocks(ctx, id) != 0) return failBool(ctx, "killed owner still has blocks");
    const after = resourceTotals(ctx) orelse return failBool(ctx, "kill after unavailable");
    if (!sameTotals(before, after)) return failBool(ctx, "kill cleanup mismatch");
    return true;
}

fn stressProcessLifecycle(ctx: *DiagApi) bool {
    var index: u32 = 0;
    while (index < 24) : (index += 1) {
        var process = spawn(ctx, "C:\\R4OS\\SOFTWARE\\TERMINAL\\DIAG\\CSTARTD.R4X", "") orelse return failBool(ctx, "process stress spawn leaked slots");
        switch (process.wait(finiteTimeout(2000))) {
            .exited => {},
            else => return failBool(ctx, "process stress wait failed"),
        }
    }
    return true;
}

fn spawn(ctx: *DiagApi, path_text: []const u8, args: [*:0]const u8) ?r4os.ProcessHandle {
    var path = r4os.FilePath.parse(path_text) catch return null;
    return switch (ctx.resources.spawn(path.asZ(), args, .console)) {
        .process => |process| process,
        .failure => null,
    };
}

fn finiteTimeout(milliseconds: u64) r4os.time_contract.Timeout {
    return r4os.time_contract.timeoutFinite(r4os.time_contract.durationFromNanoseconds(milliseconds * 1_000_000));
}

fn waitForExitOrCleanup(ctx: *DiagApi, process: *r4os.ProcessHandle, timeout: r4os.time_contract.Timeout, message: []const u8) bool {
    const outcome = process.wait(timeout);
    switch (outcome) {
        .exited => return true,
        else => {
            ctx.sys.write("SPECTRA LIFECYCLE wait outcome: ");
            switch (outcome) {
                .exited => unreachable,
                .would_block => ctx.sys.println("WOULD_BLOCK"),
                .timed_out => ctx.sys.println("TIMEOUT"),
                .failure => |raw| {
                    ctx.sys.write("FAILED raw=");
                    ctx.sys.printI32(raw);
                    ctx.sys.println("");
                },
            }
            if (process.valid()) {
                _ = process.kill();
                _ = process.wait(finiteTimeout(cleanup_lifecycle_timeout_ms));
            }
            return failBool(ctx, message);
        },
    }
}

fn waitOwnerResources(ctx: *DiagApi, id: u32, max_ticks: u32) bool {
    var tick: u32 = 0;
    while (tick < max_ticks) : (tick += 1) {
        if (ownerResourceBlocks(ctx, id) >= 3) return true;
        ctx.sys.sleepTicks(1);
    }
    return ownerResourceBlocks(ctx, id) >= 3;
}

fn ownerResourceBlocks(ctx: *DiagApi, owner_id: u32) u64 {
    var count: u64 = 0;
    const block_count = ctx.dev.memoryBlockCount();
    var index: u32 = 0;
    while (index < block_count) : (index += 1) {
        const block = ctx.dev.memoryBlock(index) orelse continue;
        if (block.owner == owner_r4x_instance and block.owner_id == owner_id and isTrackedKind(block.kind)) {
            count += 1;
        }
    }
    return count;
}

fn resourceTotals(ctx: *DiagApi) ?ResourceTotals {
    var totals: ResourceTotals = .{};
    const block_count = ctx.dev.memoryBlockCount();
    var index: u32 = 0;
    while (index < block_count) : (index += 1) {
        const block = ctx.dev.memoryBlock(index) orelse continue;
        if (block.owner != owner_r4x_instance or !isTrackedKind(block.kind)) continue;
        totals.blocks += 1;
        if (block.kind == kind_program_image) totals.program_images += 1;
        if (block.kind == kind_virtual_range) totals.vm_ranges += 1;
        if (block.kind == kind_app_stack) totals.app_stacks += 1;
        totals.reserved +%= block.reserved_bytes;
        totals.committed +%= block.committed_bytes;
        totals.physical +%= block.phys_len;
        totals.virtual +%= block.virt_len;
    }
    return totals;
}

fn resourceTotalsForOwner(ctx: *DiagApi, owner_id: u32) ?ResourceTotals {
    if (owner_id == 0) return null;
    var totals: ResourceTotals = .{};
    const block_count = ctx.dev.memoryBlockCount();
    var index: u32 = 0;
    while (index < block_count) : (index += 1) {
        const block = ctx.dev.memoryBlock(index) orelse continue;
        if (block.owner != owner_r4x_instance or block.owner_id != owner_id or !isTrackedKind(block.kind)) continue;
        totals.blocks += 1;
        if (block.kind == kind_program_image) totals.program_images += 1;
        if (block.kind == kind_virtual_range) totals.vm_ranges += 1;
        if (block.kind == kind_app_stack) totals.app_stacks += 1;
        totals.reserved +%= block.reserved_bytes;
        totals.committed +%= block.committed_bytes;
        totals.physical +%= block.phys_len;
        totals.virtual +%= block.virt_len;
    }
    return totals;
}

fn isTrackedKind(kind: u8) bool {
    return kind == kind_program_image or kind == kind_virtual_range or kind == kind_app_stack;
}

fn sameTotals(a: ResourceTotals, b: ResourceTotals) bool {
    return a.blocks == b.blocks and
        a.program_images == b.program_images and
        a.vm_ranges == b.vm_ranges and
        a.app_stacks == b.app_stacks and
        a.reserved == b.reserved and
        a.committed == b.committed and
        a.physical == b.physical and
        a.virtual == b.virtual;
}

fn hasArg(args: [*:0]const u8, wanted: []const u8) bool {
    var offset: usize = 0;
    while (offset < 256 and args[offset] != 0) {
        while (offset < 256 and (args[offset] == ' ' or args[offset] == '\t')) : (offset += 1) {}
        const start = offset;
        while (offset < 256 and args[offset] != 0 and args[offset] != ' ' and args[offset] != '\t') : (offset += 1) {}
        if (equalsIgnoreCase(args[start..offset], wanted)) return true;
    }
    return false;
}

fn argumentToken(args: [*:0]const u8, wanted_index: usize) ?[]const u8 {
    var offset: usize = 0;
    var token_index: usize = 0;
    while (offset < 256 and args[offset] != 0) {
        while (offset < 256 and (args[offset] == ' ' or args[offset] == '\t')) : (offset += 1) {}
        if (offset >= 256 or args[offset] == 0) break;
        const start = offset;
        while (offset < 256 and args[offset] != 0 and args[offset] != ' ' and args[offset] != '\t') : (offset += 1) {}
        if (token_index == wanted_index) return args[start..offset];
        token_index += 1;
    }
    return null;
}

fn argumentU32(args: [*:0]const u8, index: usize) ?u32 {
    const token = argumentToken(args, index) orelse return null;
    if (token.len == 0) return null;
    var value: u64 = 0;
    for (token) |ch| {
        if (ch < '0' or ch > '9') return null;
        value = value * 10 + (ch - '0');
        if (value > 0xFFFF_FFFF) return null;
    }
    return @intCast(value);
}

fn argumentI32(args: [*:0]const u8, index: usize) ?i32 {
    const token = argumentToken(args, index) orelse return null;
    if (token.len == 0) return null;
    const negative = token[0] == '-';
    const digits = if (negative) token[1..] else token;
    if (digits.len == 0) return null;
    var value: u64 = 0;
    for (digits) |ch| {
        if (ch < '0' or ch > '9') return null;
        value = value * 10 + (ch - '0');
        if (value > 2_147_483_648) return null;
    }
    if (negative) {
        if (value == 2_147_483_648) return -2_147_483_648;
        return -@as(i32, @intCast(value));
    }
    if (value > 2_147_483_647) return null;
    return @intCast(value);
}

fn equalsIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var index: usize = 0;
    while (index < a.len) : (index += 1) {
        if (upper(a[index]) != upper(b[index])) return false;
    }
    return true;
}

fn upper(ch: u8) u8 {
    if (ch >= 'a' and ch <= 'z') return ch - ('a' - 'A');
    return ch;
}

fn fail(ctx: *DiagApi, msg: []const u8) i32 {
    ctx.sys.write("SPECTRA LIFECYCLE FAILED: ");
    ctx.sys.write(msg);
    ctx.sys.write("\r\n");
    ctx.sys.println("SPECTRA LIFECYCLE result: FAILED");
    return 1;
}

fn failBool(ctx: *DiagApi, msg: []const u8) bool {
    _ = fail(ctx, msg);
    return false;
}
