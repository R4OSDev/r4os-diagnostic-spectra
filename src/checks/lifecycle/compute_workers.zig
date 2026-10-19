//! Existing lifecycle profile: exact compute descendants, Close/Join and Kill/Reap.
const r4os = @import("r4os");
const route = @import("../../route.zig");
const a = r4os.abi;
const AtomicBool = @import("std").atomic.Value(bool);

fn failed(sys: r4os.r4sys.Context, cycle: usize, stage: []const u8, code: i32) bool {
    var buffer: [160]u8 = undefined;
    const text = @import("std").fmt.bufPrint(&buffer, "SPECTRA LIFECYCLE compute failure cycle={d} stage={s} code={d}", .{ cycle, stage, code }) catch "SPECTRA LIFECYCLE compute failure";
    sys.println(text);
    return false;
}

const Work = struct {
    sys: r4os.r4sys.Context,
    release: AtomicBool = .init(false),
    entered: AtomicBool = .init(false),
};

fn role(sys: r4os.r4sys.Context) bool {
    var identity: a.ProgramJoinHandle = .{};
    var info: a.ProgramThreadInfo = .{};
    return sys.threadCurrentHandle(&identity) == a.thread_ok and
        sys.threadHandleStatus(&identity, &info) == a.thread_ok and
        info.flags & a.thread_flag_compute_worker != 0 and info.flags & a.thread_flag_main == 0;
}

fn descendant(raw: u64) callconv(.c) i32 {
    const work: *Work = @ptrFromInt(raw);
    if (!role(work.sys)) return 30;
    var input: [1]u8 = .{0xA5};
    if (work.sys.consoleRead(&input) != 0 or input[0] != 0xA5 or work.sys.readKey() != 0 or
        work.sys.programCurrentConsoleHost() != .none) return 31;
    var identity: a.ProgramJoinHandle = .{};
    if (work.sys.threadCurrentHandle(&identity) != a.thread_ok or
        work.sys.programSetConsoleHost(identity.instance_id, .terminal_window) >= 0) return 31;
    // The runtime gate must suppress this exact marker and reject a console
    // descendant launch. No diagnostic clears or consumes the parent's input.
    work.sys.write("[FORBIDDEN COMPUTE OUTPUT]\r\n");
    if (work.sys.programSpawn(route.path, route.arguments("LIFECYCLE", "/COMPUTEHOLD").ptr(), .console) >= 0) return 32;
    work.entered.store(true, .release);
    while (!work.release.load(.acquire)) work.sys.sleepTicks(1);
    return 38;
}

fn worker(raw: u64) callconv(.c) i32 {
    const work: *Work = @ptrFromInt(raw);
    if (!role(work.sys)) return 33;
    var nested: a.ProgramJoinHandle = .{};
    // A zero-flag creation from a compute caller must inherit its role.
    if (work.sys.threadCreateHandle(descendant, raw, 256 * 1024, 0, &nested) != a.thread_ok) return 34;
    while (!work.release.load(.acquire)) work.sys.sleepTicks(1);
    var code: i32 = -1;
    if (work.sys.threadHandleJoin(&nested, work.sys.ticksFromMilliseconds(5000), &code) != a.thread_ok or code != 38) return 35;
    return 37;
}

pub fn hold(sys: r4os.r4sys.Context) i32 {
    // Stack storage stays alive through every real join, or through terminal
    // process stop. Never return a pointer to a still executing descendant.
    // Bypass only the diagnostic's userland text adapter for this raw console
    // admission probe. Both actual provider tables and bundle stay resident
    // on this retained main frame through join/terminal process stop.
    const adapted = sys.base.bundle orelse return 39;
    var original = r4os.program.bundleValueFromR4XStart(adapted.raw) orelse return 39;
    var work: Work = .{ .sys = r4os.r4sys.Context.init(&original) };
    var handle: a.ProgramJoinHandle = .{};
    if (sys.computeWorkerCreate(worker, @intFromPtr(&work), 256 * 1024, &handle) != a.thread_ok) return 40;
    while (!sys.programShouldClose()) sys.sleepTicks(1);
    work.release.store(true, .release);
    var code: i32 = -1;
    const joined = sys.threadHandleJoin(&handle, sys.ticksFromMilliseconds(5000), &code);
    if (joined != a.thread_ok or code != 37 or !work.entered.load(.acquire)) {
        _ = failed(sys, 0, if (joined != a.thread_ok) "hold-join" else if (code != 37) "hold-worker-exit" else "hold-not-entered", if (joined != a.thread_ok) joined else code);
        // Keep the stack resident until the ordinary process exit has stopped
        // every peer; a failed join cannot release this frame normally.
        _ = sys.programExit(41, a.program_exit_reason_failed);
        while (true) sys.sleepTicks(1);
    }
    return 0;
}

fn ready(sys: r4os.r4sys.Context, process: *r4os.app_resources.ProcessHandle) bool {
    const begun = sys.ticks();
    restart: while (sys.ticks() -% begun < sys.ticksFromMilliseconds(5000)) {
        sys.sleepTicks(1);
        var cursor: a.ProgramInventoryCursor = .{};
        var summary: a.ProgramInventorySummary = .{};
        if (sys.programInventoryBegin(&cursor, &summary) != a.program_handle_ok) {
            sys.sleepTicks(1);
            continue;
        }
        var threads: [2]a.ProgramThreadSnapshot = undefined;
        var count: usize = 0;
        while (true) {
            var entries: [16]a.ProgramThreadSnapshot = undefined;
            var page: a.ProgramInventoryPageInfo = .{};
            if (sys.programInventoryThreads(&cursor, &entries, &page) != a.program_handle_ok or page.status == a.program_inventory_status_restart) continue :restart;
            if (page.returned > entries.len) return false;
            for (entries[0..page.returned]) |entry| {
                if (entry.handle.instance_id != process.raw or entry.handle.instance_generation != process.generation or
                    entry.info.flags & a.thread_flag_compute_worker == 0) continue;
                if (count >= threads.len or entry.info.state != a.thread_state_running) continue :restart;
                threads[count] = entry;
                count += 1;
            }
            if (page.has_more == 0) break;
        }
        if (count != threads.len) {
            sys.sleepTicks(1);
            continue;
        }
        if (sys.programInventoryBegin(&cursor, &summary) != a.program_handle_ok) continue;
        // Both exact Tasks must have reached their timed sleep after executing
        // their module code, including inherited-role and console checks.
        var found: u8 = 0;
        while (true) {
            var tasks: [16]a.ProgramTaskSnapshot = undefined;
            var page: a.ProgramInventoryPageInfo = .{};
            if (sys.programInventoryTasks(&cursor, &tasks, &page) != a.program_handle_ok or page.status == a.program_inventory_status_restart) continue :restart;
            if (page.returned > tasks.len) return false;
            for (tasks[0..page.returned]) |task| {
                for (threads, 0..) |thread, index| {
                    if (task.owner_instance_id == thread.handle.instance_id and task.instance_generation == thread.handle.instance_generation and
                        task.task_id == thread.info.task_id and task.state == 3 and task.last_run_tick != 0)
                        found |= @as(u8, 1) << @intCast(index);
                }
            }
            if (page.has_more == 0) break;
        }
        if (found == 3) return true;
        sys.sleepTicks(1);
    }
    return false;
}

pub fn run(sys: r4os.r4sys.Context) bool {
    const resources: r4os.Resources = .{ .sys = sys };
    const path = r4os.FilePath.parse(route.path) catch return false;
    for (0..2) |cycle| {
        var child = switch (resources.spawn(path.asZ(), route.arguments("LIFECYCLE", "/COMPUTEHOLD").ptr(), .console)) {
            .process => |value| value,
            .failure => |reason| return failed(sys, cycle, "spawn", reason),
        };
        const owner = a.ProgramProcessHandle{ .instance_id = child.raw, .generation = child.generation };
        defer if (child.valid()) {
            _ = child.kill();
            _ = child.wait(timeout());
        };
        if (!ready(sys, &child)) {
            sys.println("SPECTRA LIFECYCLE compute readiness failed");
            return false;
        }
        const status = if (cycle == 0) child.requestClose() else child.kill();
        if (status != a.program_handle_ok) return failed(sys, cycle, "close-or-kill", status);
        switch (child.wait(timeout())) {
            .exited => |code| if (cycle == 0 and code != 0) return failed(sys, cycle, "child-exit", code),
            else => return failed(sys, cycle, "child-wait", -1),
        }
        const inspection_start = sys.ticks();
        var stable = false;
        // The catalog is system-wide: an unrelated exact process retirement
        // may invalidate this cursor after our own genuine wait. Retry only
        // the documented restart status, never accept a partial scan or hide
        // a retained thread belonging to the exact completed generation.
        inspect: while (sys.ticks() -% inspection_start < sys.ticksFromMilliseconds(5000)) {
            var cursor: a.ProgramInventoryCursor = .{};
            var summary: a.ProgramInventorySummary = .{};
            const begun = sys.programInventoryBegin(&cursor, &summary);
            if (begun != a.program_handle_ok) return failed(sys, cycle, "inventory-begin", begun);
            while (true) {
                var entries: [16]a.ProgramThreadSnapshot = undefined;
                var page: a.ProgramInventoryPageInfo = .{};
                const result = sys.programInventoryThreads(&cursor, &entries, &page);
                if (result != a.program_handle_ok) return failed(sys, cycle, "inventory-threads", result);
                if (page.status == a.program_inventory_status_restart) {
                    sys.sleepTicks(1);
                    continue :inspect;
                }
                if (page.returned > entries.len) return failed(sys, cycle, "inventory-capacity", @intCast(page.returned));
                for (entries[0..page.returned]) |entry| {
                    if (entry.handle.instance_id == owner.instance_id and entry.handle.instance_generation == owner.generation) return failed(sys, cycle, "retained-own-thread", @intCast(entry.handle.thread_id));
                }
                if (page.has_more == 0) {
                    stable = true;
                    break :inspect;
                }
            }
        }
        if (!stable) return failed(sys, cycle, "inventory-restart-timeout", 0);
    }
    return true;
}

fn timeout() r4os.time_contract.Timeout {
    return r4os.time_contract.timeoutFinite(r4os.time_contract.durationFromNanoseconds(5_000_000_000));
}
