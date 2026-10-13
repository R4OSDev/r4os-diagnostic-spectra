const r4os = @import("r4os");

pub fn r4_app_main(r4_app: *r4os.App) i32 {
    const ctx = r4_app.system();
    const dev = r4_app.devicesLowLevel() orelse return r4os.abi.err_no_group;
    const stress_mode = argsEqual(r4_app.args(), "/STRESS");
    var ok = true;

    ctx.println("SPECTRA WORK");
    if (dev.performanceInstrumentation()) |mode| {
        ctx.println(if (mode.mode == 1) "  Kernel timing: detailed (critical sections sampled 1/64)" else "  Kernel timing: unavailable (base instrumentation)");
    } else {
        ctx.println("  Kernel timing: availability unknown");
    }
    const header_ok = ctx.contractValid() and dev.hasFn("performance_driver_work");
    printCheck(&ctx, "R4DEV compact driver-work snapshot", header_ok);
    if (!header_ok) {
        ctx.println("SPECTRA WORK result: FAILED");
        return 1;
    }

    const snapshot = dev.performanceDriverWork(0) orelse {
        printCheck(&ctx, "driver performance snapshot", false);
        ctx.println("SPECTRA WORK result: FAILED");
        return 1;
    };

    ok = checkWorker(&ctx, snapshot) and ok;
    ok = checkAccounting(&ctx, snapshot) and ok;
    if (stress_mode) {
        ok = checkStressLifecycle(&ctx, snapshot) and ok;
    } else {
        ok = checkDeferredWork(&ctx, snapshot) and ok;
        ok = checkCompletion(&ctx, snapshot) and ok;
    }
    printBaseline(&ctx, snapshot);

    ctx.print("SPECTRA WORK result: ");
    ctx.println(if (ok) "OK" else "FAILED");
    return if (ok) 0 else 1;
}

fn checkStressLifecycle(ctx: *const r4os.r4sys.Context, snapshot: r4os.abi.ProgramDriverWorkPerformanceInfo) bool {
    const metrics = snapshot.metrics;
    const terminal = metrics.completed +% metrics.cancelled;
    const ok = snapshot.used_slots == 0 and
        snapshot.waiters_current == 0 and
        metrics.failed >= 1 and
        metrics.cancelled >= 2 and
        metrics.dropped >= 2 and
        metrics.full_rejections >= 2 and
        metrics.retained_full_rejections >= 1 and
        metrics.stale_handles >= 1 and
        metrics.wake_publications == terminal and
        metrics.cleanup_calls >= 1 and
        metrics.cleanup_quiesced >= 1 and
        metrics.cleanup_queued_cancelled >= 1 and
        metrics.cleanup_waits >= 1 and
        metrics.cleanup_wait_timeouts == 0 and
        metrics.cleanup_wait_failures == 0 and
        metrics.cleanup_released >= 2 and
        metrics.cleanup_late_finishes >= 1 and
        metrics.cleanup_scan_passes >= 1 and
        metrics.cleanup_scan_slots >= 1;
    printCheck(ctx, "Driver stress lifecycle", ok);
    return ok;
}

fn checkWorker(ctx: *const r4os.r4sys.Context, snapshot: r4os.abi.ProgramDriverWorkPerformanceInfo) bool {
    const ok = snapshot.version >= 2 and
        snapshot.size >= @sizeOf(r4os.abi.ProgramDriverWorkPerformanceInfo) and
        snapshot.initialized != 0 and
        snapshot.worker_started != 0 and
        snapshot.worker_count == 2 and
        snapshot.deadline_worker_started != 0 and
        snapshot.deadline_worker_count == 1 and
        snapshot.deadline_queue_capacity > 0 and
        snapshot.queue_capacity >= r4os.abi.driver_work_queue_capacity and
        snapshot.irq_burst_limit > 0;
    printCheck(ctx, "Driver workqueue worker", ok);
    return ok;
}

fn checkAccounting(ctx: *const r4os.r4sys.Context, snapshot: r4os.abi.ProgramDriverWorkPerformanceInfo) bool {
    const ok = snapshot.free_slots + snapshot.used_slots == snapshot.queue_capacity and
        snapshot.used_slots == snapshot.queued_slots + snapshot.running_slots +
            snapshot.completed_slots + snapshot.cancelled_slots and
        snapshot.queued_slots == snapshot.irq_queued_slots + snapshot.task_queued_slots + snapshot.deadline_queued_slots and
        snapshot.deadline_queued_slots <= snapshot.deadline_queue_capacity and
        snapshot.deadline_running_slots <= snapshot.running_slots and
        snapshot.queue_high_water <= snapshot.queue_capacity and
        snapshot.used_high_water <= snapshot.queue_capacity and
        snapshot.retained_high_water <= snapshot.queue_capacity;
    printCheck(ctx, "Driver slot accounting", ok);
    return ok;
}

fn checkDeferredWork(ctx: *const r4os.r4sys.Context, snapshot: r4os.abi.ProgramDriverWorkPerformanceInfo) bool {
    const metrics = snapshot.metrics;
    const submitted_by_context = metrics.submitted_actual_irq +% metrics.submitted_actual_task;
    const submitted_by_class = metrics.submitted_irq_class +% metrics.submitted_task_class;
    const selected = metrics.selection_irq +% metrics.selection_task +% snapshot.deadline_started;
    const ok = metrics.submitted == submitted_by_context and
        metrics.submitted == submitted_by_class and
        metrics.started <= metrics.submitted and
        metrics.completed <= metrics.started and
        selected == metrics.started and
        snapshot.deadline_started <= snapshot.deadline_submitted and
        snapshot.deadline_completed <= snapshot.deadline_started and
        snapshot.deadline_queued_slots <= snapshot.deadline_queue_capacity and
        metrics.failed == 0 and
        metrics.dropped == 0 and
        metrics.full_rejections == 0 and
        metrics.scan_passes == metrics.cleanup_scan_passes and
        metrics.scan_slots == metrics.cleanup_scan_slots;
    printCheck(ctx, "Driver deferred work", ok);
    return ok;
}

fn checkCompletion(ctx: *const r4os.r4sys.Context, snapshot: r4os.abi.ProgramDriverWorkPerformanceInfo) bool {
    const metrics = snapshot.metrics;
    const terminal = metrics.completed +% metrics.cancelled;
    const ok = metrics.wake_publications == terminal and
        metrics.wake_waiters +% metrics.wake_misses >= metrics.wake_publications and
        metrics.wait_timeouts == 0 and
        metrics.wait_denied_irq == 0 and
        metrics.wait_failed == 0 and
        metrics.invalid_handles == 0 and
        metrics.stale_handles == 0 and
        metrics.cleanup_wait_timeouts == 0 and
        metrics.cleanup_wait_failures == 0;
    printCheck(ctx, "Driver completion publication", ok);
    return ok;
}

fn printBaseline(ctx: *const r4os.r4sys.Context, snapshot: r4os.abi.ProgramDriverWorkPerformanceInfo) void {
    const metrics = snapshot.metrics;
    ctx.print("  Driver workqueue: cap/free/used=");
    ctx.printU64(snapshot.queue_capacity);
    ctx.print("/");
    ctx.printU64(snapshot.free_slots);
    ctx.print("/");
    ctx.printU64(snapshot.used_slots);
    ctx.print(" q/r/c/x=");
    ctx.printU64(snapshot.queued_slots);
    ctx.print("/");
    ctx.printU64(snapshot.running_slots);
    ctx.print("/");
    ctx.printU64(snapshot.completed_slots);
    ctx.print("/");
    ctx.printU64(snapshot.cancelled_slots);
    ctx.print(" submitted=");
    ctx.printU64(metrics.submitted);
    ctx.print(" irq/task=");
    ctx.printU64(metrics.submitted_actual_irq);
    ctx.print("/");
    ctx.printU64(metrics.submitted_actual_task);
    ctx.print(" releases=");
    ctx.printU64(metrics.releases);
    ctx.print(" deadline=");
    ctx.printU64(snapshot.deadline_submitted);
    ctx.print("/");
    ctx.printU64(snapshot.deadline_completed);
    ctx.print(" miss/overrun/reject=");
    ctx.printU64(snapshot.deadline_misses);
    ctx.print("/");
    ctx.printU64(snapshot.deadline_budget_overruns);
    ctx.print("/");
    ctx.printU64(snapshot.deadline_queue_rejections);
    ctx.println("");

    ctx.print("  Timing ns: queueLast/max=");
    ctx.printU64(metrics.queue_last_ns);
    ctx.print("/");
    ctx.printU64(metrics.queue_max_ns);
    ctx.print(" runLast/max=");
    ctx.printU64(metrics.run_last_ns);
    ctx.print("/");
    ctx.printU64(metrics.run_max_ns);
    ctx.print(" e2eLast/max=");
    ctx.printU64(metrics.e2e_last_ns);
    ctx.print("/");
    ctx.printU64(metrics.e2e_max_ns);
    ctx.print(" irqOffLast/max=");
    ctx.printU64(metrics.critical_last_ns);
    ctx.print("/");
    ctx.printU64(metrics.critical_max_ns);
    ctx.println("");

    ctx.print("  Work accounting: wakes=");
    ctx.printU64(metrics.wake_publications);
    ctx.print("/");
    ctx.printU64(metrics.wake_waiters);
    ctx.print("/");
    ctx.printU64(metrics.wake_misses);
    ctx.print(" scan=");
    ctx.printU64(metrics.scan_passes);
    ctx.print("/");
    ctx.printU64(metrics.scan_slots);
    ctx.print(" cleanup=");
    ctx.printU64(metrics.cleanup_calls);
    ctx.print("/");
    ctx.printU64(metrics.cleanup_quiesced);
    ctx.print(" errors=");
    ctx.printU64(metrics.failed +% metrics.dropped +% metrics.full_rejections +
        metrics.wait_timeouts +% metrics.invalid_handles +% metrics.stale_handles);
    ctx.println("");
}

fn printCheck(ctx: *const r4os.r4sys.Context, name: []const u8, ok: bool) void {
    ctx.write("  ");
    ctx.write(name);
    ctx.write(": ");
    ctx.println(if (ok) "OK" else "FAILED");
}

fn argsEqual(args: []const u8, expected: []const u8) bool {
    if (args.len != expected.len) return false;
    for (args, expected) |actual, wanted| {
        const folded = if (actual >= 'a' and actual <= 'z') actual - ('a' - 'A') else actual;
        if (folded != wanted) return false;
    }
    return true;
}
