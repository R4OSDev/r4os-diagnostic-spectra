//! Bounded comparison of the existing full inventory with the general lifecycle
//! view. Fixed local diagnostic population bound, not a runtime process limit.
const r = @import("r4os");
const a = r.abi;
const route = @import("../../route.zig");
const capacity = 64;
const repeats = 32;
const View = struct {
    rows: [capacity]a.ProgramLifecycleSnapshot = undefined,
    count: usize = 0,
    pages: u32 = 0,
    tasks: u32 = 0,
    threads: u32 = 0,
    fn find(self: *const View, handle: a.ProgramProcessHandle) ?a.ProgramLifecycleSnapshot {
        for (self.rows[0..self.count]) |row| {
            if (row.handle.instance_id == handle.instance_id and row.handle.generation == handle.generation) return row;
        }
        return null;
    }
};
fn project(row: a.ProgramInstanceSnapshot) a.ProgramLifecycleSnapshot {
    return .{ .handle = row.handle, .task_id = row.info.task_id, .role = row.info.role, .app_class = row.info.app_class, .state = row.info.state, .flags = row.info.flags, .exit_code = row.info.exit_code, .window_id = row.info.window_id };
}
const Work = struct {
    begin_calls: u32 = 0,
    page_calls: u32 = 0,
    busy: u32 = 0,
    restarts: u32 = 0,
    validated_rows: u32 = 0,
    complete: u32 = 0,
    failure: []const u8 = "none",
    code: i32 = 0,
    fn fail(self: *Work, reason: []const u8, code: i32) bool {
        self.failure = reason;
        self.code = code;
        return false;
    }
    fn write(self: *const Work, sys: r.r4sys.Context) void {
        sys.write(",\"begin_calls\":");
        sys.printU64(self.begin_calls);
        sys.write(",\"page_calls\":");
        sys.printU64(self.page_calls);
        sys.write(",\"would_block\":");
        sys.printU64(self.busy);
        sys.write(",\"restarts\":");
        sys.printU64(self.restarts);
        sys.write(",\"validated_rows\":");
        sys.printU64(self.validated_rows);
    }
};
fn capture_work(comptime full: bool, sys: r.r4sys.Context, out: *View, work: *Work) bool {
    restart: for (0..8) |_| {
        out.* = .{};
        var cursor: a.ProgramInventoryCursor = .{};
        var summary: a.ProgramInventorySummary = .{};
        work.begin_calls += 1;
        const begin = if (full) sys.programInventoryBegin(&cursor, &summary) else sys.programLifecycleBegin(&cursor);
        if (begin == a.program_handle_error_would_block) {
            work.busy += 1;
            // A refused acquisition owns no registry lock or row lease. Yield
            // within the same fixed eight-attempt bound; timed batches include
            // this wait and report every refused call.
            sys.sleepTicks(1);
            continue;
        }
        if (begin != 0) return work.fail("begin-code", begin);
        if (full) {
            out.tasks = summary.task_total;
            out.threads = summary.thread_total;
        }
        while (true) {
            var page: a.ProgramInventoryPageInfo = .{};
            var rows: [7]a.ProgramLifecycleSnapshot = undefined;
            work.page_calls += 1;
            const code = if (full) blk: {
                var diagnostic: [7]a.ProgramInstanceSnapshot = undefined;
                const code = sys.programInventoryPrograms(&cursor, &diagnostic, &page);
                if (code == 0 and page.returned <= diagnostic.len and page.status != a.program_inventory_status_restart)
                    for (0..page.returned) |i| {
                        rows[i] = project(diagnostic[i]);
                    };
                break :blk code;
            } else sys.programLifecyclePrograms(&cursor, &rows, &page);
            if (code == a.program_handle_error_would_block) {
                work.busy += 1;
                sys.sleepTicks(1);
                continue :restart;
            }
            if (code != 0) return work.fail("page-code", code);
            if (page.status == a.program_inventory_status_restart) {
                work.restarts += 1;
                continue :restart;
            }
            if (page.returned > rows.len or out.count + page.returned > capacity or
                page.snapshot_generation != cursor.snapshot_generation or
                (page.status != a.program_inventory_status_more and page.status != a.program_inventory_status_complete)) return work.fail("page-shape", page.status);
            for (rows[0..page.returned]) |row| {
                if (row.version != a.program_inventory_version or row.size != @sizeOf(a.ProgramLifecycleSnapshot) or
                    row.handle.instance_id == 0 or row.handle.generation == 0 or row.handle.reserved != 0) return work.fail("row-shape", 0);
                if (out.count != 0 and row.handle.generation <= out.rows[out.count - 1].handle.generation) return work.fail("row-order", 0);
                out.rows[out.count] = row;
                out.count += 1;
            }
            out.pages += 1;
            work.validated_rows += page.returned;
            if (page.status == a.program_inventory_status_complete) {
                work.complete += 1;
                return true;
            }
            if (page.returned == 0) return work.fail("empty-more", 0);
        }
    }
    return work.fail("attempts-exhausted", a.program_handle_error_would_block);
}
fn write_failure(sys: r.r4sys.Context, work: *const Work) void {
    sys.write("SPECTRA LIFECYCLE metadata capture failure=");
    sys.write(work.failure);
    sys.write(" code=");
    sys.printI32(work.code);
    work.write(sys);
    sys.println("");
}
fn capture(comptime full: bool, sys: r.r4sys.Context, out: *View) bool {
    var work: Work = .{};
    if (capture_work(full, sys, out, &work)) return true;
    write_failure(sys, &work);
    return false;
}
fn mismatch(sys: r.r4sys.Context, field: []const u8, left: a.ProgramLifecycleSnapshot, right: a.ProgramLifecycleSnapshot) bool {
    sys.write("SPECTRA LIFECYCLE metadata field mismatch=");
    sys.println(field);
    for ([_]a.ProgramLifecycleSnapshot{ left, right }) |row| {
        sys.write(" row id/gen/task/state/flags/window/version/size=");
        sys.printU64(row.handle.instance_id);
        sys.write("/");
        sys.printU64(row.handle.generation);
        sys.write("/");
        sys.printU64(row.task_id);
        sys.write("/");
        sys.printU64(row.state);
        sys.write("/");
        sys.printU64(row.flags);
        sys.write("/");
        sys.printI32(row.window_id);
        sys.write("/");
        sys.printU64(row.version);
        sys.write("/");
        sys.printU64(row.size);
        sys.println("");
    }
    return false;
}
fn fields_equal(sys: r.r4sys.Context, left: *const View, right: *const View) bool {
    if (left.count != right.count) {
        sys.write("SPECTRA LIFECYCLE metadata count mismatch=");
        sys.printU64(left.count);
        sys.write("/");
        sys.printU64(right.count);
        sys.println("");
        return false;
    }
    for (left.rows[0..left.count], right.rows[0..right.count]) |l, rr| {
        inline for (@typeInfo(a.ProgramLifecycleSnapshot).@"struct".fields) |field| {
            if (comptime @TypeOf(@field(l, field.name)) == a.ProgramProcessHandle) {
                if (l.handle.instance_id != rr.handle.instance_id or l.handle.generation != rr.handle.generation or l.handle.reserved != rr.handle.reserved) return mismatch(sys, field.name, l, rr);
            } else if (@field(l, field.name) != @field(rr, field.name)) return mismatch(sys, field.name, l, rr);
        }
    }
    return true;
}
fn batch(comptime full: bool, sys: r.r4sys.Context, index: usize) bool {
    var view: View = .{};
    var work: Work = .{};
    sys.write("SPECTRA LIFECYCLE metadata stage=batch-start mode=");
    sys.println(if (full) "full" else "lifecycle");
    var start: a.MonotonicClockInfo = .{};
    if (sys.monotonicClock(&start) <= 0 or start.flags & a.monotonic_clock_flag_valid == 0 or
        start.frequency_hz != a.monotonic_clock_frequency_hz or start.resolution_ns == 0) return false;
    for (0..repeats) |acquisition| if (!capture_work(full, sys, &view, &work)) {
        write_failure(sys, &work);
        sys.write("SPECTRA LIFECYCLE metadata failed=batch-capture index=");
        sys.printU64(acquisition);
        sys.println("");
        return false;
    };
    var end: a.MonotonicClockInfo = .{};
    if (sys.monotonicClock(&end) <= 0 or end.flags & a.monotonic_clock_flag_valid == 0 or
        end.source != start.source or end.generation != start.generation or end.frequency_hz != start.frequency_hz or
        end.source_frequency_hz != start.source_frequency_hz or end.resolution_ns != start.resolution_ns or
        end.instant_ns < start.instant_ns or end.instant_ns - start.instant_ns < start.resolution_ns)
    {
        sys.write("SPECTRA LIFECYCLE metadata failed=clock-boundary source=");
        sys.printU64(start.source);
        sys.write("/");
        sys.printU64(end.source);
        sys.write(" generation=");
        sys.printU64(start.generation);
        sys.write("/");
        sys.printU64(end.generation);
        sys.write(" ns=");
        sys.printU64(start.instant_ns);
        sys.write("/");
        sys.printU64(end.instant_ns);
        sys.write(" frequency=");
        sys.printU64(start.frequency_hz);
        sys.write("/");
        sys.printU64(end.frequency_hz);
        sys.write(" source_frequency=");
        sys.printU64(start.source_frequency_hz);
        sys.write("/");
        sys.printU64(end.source_frequency_hz);
        sys.write(" resolution=");
        sys.printU64(start.resolution_ns);
        sys.write("/");
        sys.printU64(end.resolution_ns);
        sys.println("");
        return false;
    }
    sys.write("{\"schema\":1,\"kind\":\"lifecycle_metadata_batch\",\"mode\":\"");
    sys.write(if (full) "full" else "lifecycle");
    sys.write("\",\"batch\":");
    sys.printU64(index);
    sys.write(",\"complete_acquisitions\":");
    sys.printU64(work.complete);
    work.write(sys);
    sys.write(",\"wall_ns\":");
    sys.printU64(end.instant_ns - start.instant_ns);
    sys.write(",\"clock_source\":");
    sys.printU64(start.source);
    sys.write(",\"clock_generation\":");
    sys.printU64(start.generation);
    sys.write(",\"clock_resolution_ns\":");
    sys.printU64(start.resolution_ns);
    sys.write(",\"clock_interval_validated\":true");
    sys.write(",\"last_program_rows\":");
    sys.printU64(view.count);
    sys.write(",\"last_program_pages\":");
    sys.printU64(view.pages);
    sys.write(",\"last_full_summary_tasks\":");
    sys.printU64(view.tasks);
    sys.write(",\"last_full_summary_threads\":");
    sys.printU64(view.threads);
    sys.println("}");
    return true;
}
fn prepare_begin(comptime full: bool, sys: r.r4sys.Context, cursor: *a.ProgramInventoryCursor, summary: *a.ProgramInventorySummary) i32 {
    var code: i32 = a.program_handle_error_would_block;
    for (0..8) |_| {
        code = if (full) sys.programInventoryBegin(cursor, summary) else sys.programLifecycleBegin(cursor);
        if (code != a.program_handle_error_would_block) return code;
        // This is untimed fixture admission, not a new wait inside refresh or
        // measured work. A transient unavailable owner is never authority.
        sys.sleepTicks(1);
    }
    return code;
}
fn failed_code(sys: r.r4sys.Context, stage: []const u8, code: i32) bool {
    sys.write("SPECTRA LIFECYCLE metadata failed=");
    sys.write(stage);
    sys.write(" code=");
    sys.printI32(code);
    sys.println("");
    return false;
}
pub fn run(sys: r.r4sys.Context) bool {
    sys.println("SPECTRA LIFECYCLE metadata stage=begin");
    var old: a.ProgramInventoryCursor = .{};
    if (sys.programLifecycleBegin(&old) != 0) return false;
    var child: a.ProgramProcessHandle = .{};
    if (sys.programSpawnHandle(route.path, route.arguments("LIFECYCLE", "/LIFECYCLEHOLD").ptr(), .auto, &child) != 0) return false;
    var live = true;
    defer if (live) {
        _ = sys.programHandleKill(&child);
        var done: a.ProgramProcessCompletion = .{};
        if (sys.programHandleWait(&child, sys.ticksFromMilliseconds(8000), &done) == 0) _ = sys.programHandleReap(&child, &done);
    };
    sys.println("SPECTRA LIFECYCLE metadata stage=spawned");
    var marker = [_]a.ProgramLifecycleSnapshot{.{ .handle = .{ .instance_id = 0x12345678, .generation = 0x1234567887654321 } }};
    var page: a.ProgramInventoryPageInfo = .{};
    if (sys.programLifecyclePrograms(&old, &marker, &page) != 0 or page.status != a.program_inventory_status_restart or
        old.program_after_generation != 0 or marker[0].handle.instance_id != 0x12345678 or marker[0].handle.generation != 0x1234567887654321) return false;
    sys.println("SPECTRA LIFECYCLE metadata stage=restart-checked");
    // Mixed cursor modes refuse before producing diagnostic or lifecycle rows.
    var full_cursor: a.ProgramInventoryCursor = .{};
    var summary: a.ProgramInventorySummary = .{};
    const full_begin = prepare_begin(true, sys, &full_cursor, &summary);
    if (full_begin != 0) return failed_code(sys, "mode-full-admission", full_begin);
    const wrong_lifecycle = sys.programLifecyclePrograms(&full_cursor, &marker, &page);
    if (wrong_lifecycle != a.program_handle_error_invalid) return failed_code(sys, "mode-full-as-lifecycle", wrong_lifecycle);
    const light_begin = prepare_begin(false, sys, &old, &summary);
    if (light_begin != 0) return failed_code(sys, "mode-lifecycle-admission", light_begin);
    var full_rows: [1]a.ProgramInstanceSnapshot = undefined;
    const wrong_full = sys.programInventoryPrograms(&old, &full_rows, &page);
    if (wrong_full != a.program_handle_error_invalid) return failed_code(sys, "mode-lifecycle-as-full", wrong_full);
    sys.println("SPECTRA LIFECYCLE metadata stage=modes-checked");
    var full: View = .{};
    var light: View = .{};
    if (!capture(true, sys, &full)) {
        sys.println("SPECTRA LIFECYCLE metadata failed=initial-full");
        return false;
    }
    if (!capture(false, sys, &light)) {
        sys.println("SPECTRA LIFECYCLE metadata failed=initial-lifecycle");
        return false;
    }
    if (!fields_equal(sys, &full, &light)) {
        sys.println("SPECTRA LIFECYCLE metadata failed=initial-fields");
        return false;
    }
    if (light.find(child) == null) {
        sys.println("SPECTRA LIFECYCLE metadata failed=initial-child");
        return false;
    }
    sys.println("SPECTRA LIFECYCLE metadata stage=fields-checked");
    for (0..5) |i| {
        if (i % 2 == 0) {
            if (!batch(true, sys, i) or !batch(false, sys, i)) return false;
        } else {
            if (!batch(false, sys, i) or !batch(true, sys, i)) return false;
        }
    }
    if (sys.programHandleRequestClose(&child) != 0) return false;
    var done: a.ProgramProcessCompletion = .{};
    if (sys.programHandleWait(&child, sys.ticksFromMilliseconds(8000), &done) != 0 or done.exit_code != 0) return false;
    if (!capture(false, sys, &light)) return false;
    const ended = light.find(child) orelse return false;
    if (ended.state != @intFromEnum(a.ProgramInstanceState.done) or ended.exit_code != 0) return false;
    if (sys.programHandleReap(&child, &done) != 0 or done.exit_code != 0) return false;
    live = false;
    if (!capture(false, sys, &light) or light.find(child) != null) return false;
    const stale = sys.programHandleRequestClose(&child);
    if (stale != a.program_handle_error_stale and stale != a.program_handle_error_not_found) return false;
    sys.println("SPECTRA LIFECYCLE metadata fields/restart/mode/close/completion/reap result=OK");
    return true;
}

fn epoch_begin(sys: r.r4sys.Context, cursor: *a.ProgramInventoryCursor) bool {
    var summary: a.ProgramInventorySummary = .{};
    const code = prepare_begin(false, sys, cursor, &summary);
    if (code != 0) return failed_code(sys, "epoch-begin", code);
    return cursor.program_epoch != 0 and cursor.snapshot_generation == cursor.program_epoch;
}
fn epoch_after(sys: r.r4sys.Context, before: a.ProgramInventoryCursor, changed: bool) bool {
    var after: a.ProgramInventoryCursor = .{};
    if (!epoch_begin(sys, &after) or (after.program_epoch != before.program_epoch) != changed)
        return failed_code(sys, if (changed) "epoch-missing-change" else "epoch-false-change", 0);
    if (!changed) return true;
    var old = before;
    var marker = [_]a.ProgramLifecycleSnapshot{.{ .handle = .{ .instance_id = 0x12345678, .generation = 0x1234567887654321 } }};
    var page: a.ProgramInventoryPageInfo = .{};
    for (0..8) |_| {
        const code = sys.programLifecyclePrograms(&old, &marker, &page);
        if (code == a.program_handle_error_would_block) {
            sys.sleepTicks(1);
            continue;
        }
        return code == 0 and page.status == a.program_inventory_status_restart and page.returned == 0 and
            old.program_after_generation == before.program_after_generation and
            marker[0].handle.instance_id == 0x12345678 and marker[0].handle.generation == 0x1234567887654321;
    }
    return failed_code(sys, "epoch-restart-admission", a.program_handle_error_would_block);
}

// Focused untimed metadata cases. An isolated console guest is required: fake
// window IDs and the diagnostic's own temporary terminal-host state must not
// be observed by a concurrently running Desktop. No physical input is used.
pub fn epoch_owner(app: *r.App) bool {
    const sys = app.system();
    const desk = app.desktop() orelse return false;
    var child: a.ProgramProcessHandle = .{};
    // Foreground diagnostics can redirect console operations to their parent.
    // This exact owned console makes the host/request changes self-contained.
    if (desk.programSpawnWithConsoleHostHandle(route.path, route.arguments("LIFECYCLE", "/METADATAEPOCHCHILD").ptr(), .console, .terminal_window, &child) != 0) return false;
    var live = true;
    defer if (live) {
        _ = sys.programHandleKill(&child);
        var done: a.ProgramProcessCompletion = .{};
        if (sys.programHandleWait(&child, sys.ticksFromMilliseconds(8000), &done) == 0) _ = sys.programHandleReap(&child, &done);
    };
    var done: a.ProgramProcessCompletion = .{};
    if (sys.programHandleWait(&child, sys.ticksFromMilliseconds(30000), &done) != 0) return failed_code(sys, "epoch-owned-wait", 0);
    var output: [4096]u8 = undefined;
    var read: u32 = 0;
    const captured = sys.programCompletionRead(&child, 0, &output, &read);
    if (captured == 0 and read <= output.len) sys.write(output[0..read]);
    if (sys.programHandleReap(&child, &done) != 0) return false;
    live = false;
    if (captured != 0 or read > output.len or done.exit_code != 0) return failed_code(sys, "epoch-owned-result", done.exit_code);
    sys.println("SPECTRA LIFECYCLE metadata epoch result: OK");
    return true;
}
pub fn epochs(app: *r.App) bool {
    const sys = app.system();
    const desk = app.desktop() orelse return false;
    const draw = app.drawing() orelse return false;
    var view: View = .{};
    if (!capture(false, sys, &view)) return false;
    for (view.rows[0..view.count]) |row| {
        if (row.flags & a.program_instance_flag_desktop_host != 0)
            return failed_code(sys, "epoch-requires-isolated-console", 0);
    }
    var current: a.ProgramProcessHandle = .{};
    if (sys.programOpenHandle(@intCast(app.raw.instance_id), &current) != 0) return false;
    const initial = view.find(current) orelse return false;
    if (initial.flags & 2 != 0) return failed_code(sys, "epoch-request-already-set", 0);
    var old: a.ProgramInventoryCursor = .{};
    if (!epoch_begin(sys, &old) or !epoch_after(sys, old, false)) return false;
    var child: a.ProgramProcessHandle = .{};
    if (sys.programSpawnHandle(route.path, route.arguments("LIFECYCLE", "/GUIPAYLOADHOLD").ptr(), .gui, &child) != 0) return false;
    var live = true;
    defer if (live) {
        _ = sys.programHandleKill(&child);
        var done: a.ProgramProcessCompletion = .{};
        if (sys.programHandleWait(&child, sys.ticksFromMilliseconds(8000), &done) == 0) _ = sys.programHandleReap(&child, &done);
    };
    if (!epoch_after(sys, old, true)) return false;
    // Initial attachment starts the GUI child. A real frame proves it has
    // executed after activation; public "running" alone includes publication.
    if (desk.programSetWindowHandle(&child, 0) != 0) return false;
    var ready = false;
    const ready_start = sys.ticks();
    while (sys.ticks() -| ready_start < sys.ticksFromMilliseconds(8000)) {
        var info: a.ProgramInstanceInfo = .{};
        if (sys.programHandleStatus(&child, &info) != 0) return false;
        if (info.state == @intFromEnum(a.ProgramInstanceState.done)) return false;
        var frame: a.GuiFrameInfo = .{};
        if (draw.guiFrameInfo(&child, &frame) == 0 and frame.committed_generation != 0) {
            ready = true;
            break;
        }
        sys.sleepTicks(1);
    }
    if (!ready) return false;
    for ([_]bool{ true, false }) |by_handle| {
        if (!epoch_begin(sys, &old)) return false;
        const window: i32 = if (by_handle) 123 else 456;
        const code = if (by_handle) desk.programSetWindowHandle(&child, window) else desk.programSetWindow(child.instance_id, window);
        if (code != 0 or !epoch_after(sys, old, true)) return false;
        if (!capture(false, sys, &view)) return false;
        const row = view.find(child) orelse return false;
        if (row.window_id != window) return false;
        if (!epoch_begin(sys, &old)) return false;
        const same = if (by_handle) desk.programSetWindowHandle(&child, window) else desk.programSetWindow(child.instance_id, window);
        if (same != 0 or !epoch_after(sys, old, false)) return false;
    }
    const original_host = sys.programCurrentConsoleHost();
    defer _ = desk.programSetConsoleHost(current.instance_id, original_host);
    if (original_host == .terminal_mode) return failed_code(sys, "epoch-requires-unhosted-caller", 0);
    if (!epoch_begin(sys, &old) or desk.programSetConsoleHost(current.instance_id, .terminal_mode) != 0 or
        !epoch_after(sys, old, true)) return false;
    if (!capture(false, sys, &view) or (view.find(current) orelse return false).flags & 4 == 0) return false;
    if (!epoch_begin(sys, &old) or desk.programSetConsoleHost(current.instance_id, .terminal_mode) != 0 or
        !epoch_after(sys, old, false)) return false;
    if (!epoch_begin(sys, &old) or sys.programRequestDesktop() != 0 or !epoch_after(sys, old, true)) return false;
    if (!capture(false, sys, &view) or (view.find(current) orelse return false).flags & 2 == 0) return false;
    if (!epoch_begin(sys, &old) or sys.programRequestDesktop() != 0 or !epoch_after(sys, old, false)) return false;
    if (!epoch_begin(sys, &old) or desk.programSetConsoleHost(current.instance_id, original_host) != 0 or
        !epoch_after(sys, old, true)) return false;
    if (!capture(false, sys, &view) or (view.find(current) orelse return false).flags & 4 != initial.flags & 4) return false;
    if (!epoch_begin(sys, &old) or sys.programHandleRequestClose(&child) != 0 or !epoch_after(sys, old, true)) return false;
    var done: a.ProgramProcessCompletion = .{};
    if (sys.programHandleWait(&child, sys.ticksFromMilliseconds(8000), &done) != 0 or done.exit_code != 0) return false;
    if (!capture(false, sys, &view)) return false;
    if ((view.find(child) orelse return false).state != @intFromEnum(a.ProgramInstanceState.done)) return false;
    if (!epoch_begin(sys, &old) or sys.programHandleReap(&child, &done) != 0 or !epoch_after(sys, old, true)) return false;
    live = false;
    if (!capture(false, sys, &view) or view.find(child) != null) return false;
    const stale = desk.programSetWindowHandle(&child, 789);
    if (stale != a.program_handle_error_stale and stale != a.program_handle_error_not_found) return false;
    sys.println("SPECTRA LIFECYCLE metadata epoch window-handle/id=OK console-host=OK desktop-request=OK unchanged=stable restart=atomic close/done/reap=OK stale=rejected");
    return true;
}
