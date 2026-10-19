//! Exercise the installed applications through normal background launch,
//! window/input, placement, file and service APIs. No alternate app entry.
const std = @import("std");
const r = @import("r4os");
const a = r.abi;
const app_paths = [_][*:0]const u8{
    "C:\\R4OS\\SOFTWARE\\DESKTOP\\NOTEPAD.R4X",
    "C:\\R4OS\\SOFTWARE\\DESKTOP\\EXPLORER.R4X",
    "C:\\R4OS\\SOFTWARE\\DESKTOP\\LOGCENTER.R4X",
};
const markers = [_][]const u8{ "APPS08517-A", "APPS08517-B" };
const State = struct {
    sys: r.r4sys.Context,
    desk: r.r4desk.Context,
    draw: r.r4draw.Context,
    handles: [6]a.ProgramProcessHandle = .{a.ProgramProcessHandle{}} ** 6,
    threads: [6]a.ProgramJoinHandle = .{a.ProgramJoinHandle{}} ** 6,
    frames: [6]u64 = .{0} ** 6,
    cpus: [6]u32 = .{ 1, 2, 3, 1, 2, 3 },

    fn fail(self: *State, stage: []const u8) bool {
        self.sys.write("SPECTRA LIFECYCLE apps FAILED stage=");
        self.sys.println(stage);
        return false;
    }
    fn expired(self: *State, start: u64) bool {
        return self.sys.ticks() -% start > self.sys.ticksFromMilliseconds(8000);
    }
    fn reap(self: *State, handle: *a.ProgramProcessHandle, expected: i32) bool {
        var done: a.ProgramProcessCompletion = .{};
        if (self.sys.programHandleWait(handle, self.sys.ticksFromMilliseconds(8000), &done) != a.program_handle_ok or done.exit_code != expected) return false;
        if (self.sys.programHandleReap(handle, &done) != a.program_handle_ok or done.exit_code != expected) return false;
        handle.* = .{};
        return true;
    }
    fn cleanup(self: *State) void {
        for (&self.handles) |*handle| {
            if (handle.instance_id == 0) continue;
            _ = self.sys.programHandleKill(handle);
            _ = self.reap(handle, -9);
        }
    }
    fn frame(self: *State, index: usize, after: u64) bool {
        const start = self.sys.ticks();
        while (!self.expired(start)) {
            var info: a.GuiFrameInfo = .{};
            const handle = &self.handles[index];
            if (self.draw.guiFrameInfo(handle, &info) == a.gui_frame_result_ok and
                info.owner.instance_id == handle.instance_id and info.owner.generation == handle.generation and
                info.committed_generation > after and info.committed_command_count != 0 and
                info.state == a.gui_frame_state_idle and info.oom_count == 0)
            {
                self.frames[index] = info.committed_generation;
                return true;
            }
            self.sys.sleepTicks(1);
        }
        return false;
    }
    fn mainThread(self: *State, index: usize) bool {
        var status: a.ProgramInstanceInfo = .{};
        if (self.sys.programHandleStatus(&self.handles[index], &status) != a.program_handle_ok) return false;
        const start = self.sys.ticks();
        restart: while (!self.expired(start)) {
            var cursor: a.ProgramInventoryCursor = .{};
            var summary: a.ProgramInventorySummary = .{};
            if (self.sys.programInventoryBegin(&cursor, &summary) != a.program_handle_ok) {
                self.sys.sleepTicks(1);
                continue;
            }
            while (true) {
                var entries: [16]a.ProgramThreadSnapshot = undefined;
                var page: a.ProgramInventoryPageInfo = .{};
                if (self.sys.programInventoryThreads(&cursor, &entries, &page) != a.program_handle_ok or page.status == a.program_inventory_status_restart) continue :restart;
                if (page.returned > entries.len) return false;
                for (entries[0..page.returned]) |entry| {
                    if (entry.handle.instance_id == self.handles[index].instance_id and
                        entry.handle.instance_generation == self.handles[index].generation and entry.info.task_id == status.task_id)
                    {
                        self.threads[index] = entry.handle;
                        return true;
                    }
                }
                if (page.has_more == 0) break;
            }
            self.sys.sleepTicks(1);
        }
        return false;
    }
    fn placement(self: *State, index: usize, set: bool) bool {
        const mask = [_]u64{@as(u64, 1) << @intCast(self.cpus[index])};
        const request: a.ThreadPlacementRequest = .{ .work_class = a.thread_placement_class_batch, .preferred_cpu = self.cpus[index] };
        if (set) {
            const begun = self.sys.ticks();
            while (true) {
                const code = self.sys.threadPlacementSet(&self.threads[index], &request, &mask);
                if (code == a.thread_ok) break;
                // A saved waiter can still own a handoff/lock admission. The
                // public contract returns Busy instead of moving that frame.
                // Wake only this GUI and let it leave its original boundary.
                if (code != a.thread_error_busy or self.expired(begun)) return self.setupFailure("placement-set", index, code);
                if (!self.wake(index)) return self.setupFailure("placement-wake", index, -1);
                self.sys.sleepTicks(1);
            }
            if (!self.wake(index)) return self.setupFailure("placement-wake", index, -1);
        }
        const start = self.sys.ticks();
        var last: a.ThreadPlacementInfo = .{};
        var last_words: [1]u64 = .{0};
        while (!self.expired(start)) {
            var info: a.ThreadPlacementInfo = .{};
            var words: [1]u64 = .{0};
            const code = self.sys.threadPlacementGet(&self.threads[index], &info, &words);
            if (code == a.thread_error_busy) {
                self.sys.sleepTicks(1);
                continue;
            }
            if (code != a.thread_ok) return self.setupFailure("placement-get", index, code);
            last = info;
            last_words = words;
            if (info.request_revision == info.applied_revision and info.home_cpu == self.cpus[index] and words[0] == mask[0] and info.flags & a.thread_placement_flag_parallel != 0) return true;
            self.sys.sleepTicks(1);
        }
        self.sys.write("SPECTRA LIFECYCLE apps placement timeout home=");
        self.sys.printU64(last.home_cpu);
        self.sys.write(" running=");
        self.sys.printU64(last.running_cpu);
        self.sys.write(" flags=");
        self.sys.printU64(last.flags);
        self.sys.write(" requested/applied=");
        self.sys.printU64(last.request_revision);
        self.sys.write("/");
        self.sys.printU64(last.applied_revision);
        self.sys.write(" mask=");
        self.sys.printU64(last_words[0]);
        self.sys.println("");
        return false;
    }
    fn key(self: *State, index: usize, key_code: u32) bool {
        const event: a.GuiEvent = .{ .kind = @intFromEnum(a.GuiEventKind.key_down), .key = key_code };
        return self.desk.guiPushEvent(self.handles[index].instance_id, &event) == 0;
    }
    fn wake(self: *State, index: usize) bool {
        const event: a.GuiEvent = .{ .kind = @intFromEnum(a.GuiEventKind.resize) };
        return self.desk.guiPushEvent(self.handles[index].instance_id, &event) == 0;
    }
    fn startGui(self: *State, index: usize, args: [*:0]const u8) bool {
        const handle = &self.handles[index];
        const spawned = self.sys.programSpawnHandle(app_paths[index / 2], args, .gui, handle);
        if (spawned != a.program_handle_ok) return self.setupFailure("spawn", index, spawned);
        const window: a.GuiWindowInfo = .{ .window_id = @intCast(index), .client_w = 840, .client_h = 500 };
        const geometry = self.desk.guiSetWindowInfo(handle.instance_id, &window);
        if (geometry != 0) return self.setupFailure("geometry", index, geometry);
        const attached = self.desk.programSetWindowHandle(handle, @intCast(index));
        if (attached != a.program_handle_ok) return self.setupFailure("attach", index, attached);
        if (!self.frame(index, 0)) {
            var status: a.ProgramInstanceInfo = .{};
            const code = self.sys.programHandleStatus(handle, &status);
            self.sys.write("SPECTRA LIFECYCLE apps first-frame status=");
            self.sys.printI32(code);
            self.sys.write(" state=");
            self.sys.printU64(status.state);
            self.sys.write(" exit=");
            self.sys.printI32(status.exit_code);
            self.sys.println("");
            return self.setupFailure("frame", index, code);
        }
        if (!self.mainThread(index)) return self.setupFailure("main-thread-inventory", index, -1);
        if (!self.placement(index, true)) return self.setupFailure("placement", index, -1);
        // A wake used while the setter was Busy may have painted on the old
        // CPU. Take the frame baseline only after the policy is applied; the
        // measured input below must still produce a strictly newer frame.
        if (!self.frame(index, 0)) return self.setupFailure("placed-frame-baseline", index, -1);
        return true;
    }
    fn setupFailure(self: *State, stage: []const u8, index: usize, code: i32) bool {
        self.sys.write("SPECTRA LIFECYCLE apps setup FAILED stage=");
        self.sys.write(stage);
        self.sys.write(" index=");
        self.sys.printU64(index);
        self.sys.write(" instance=");
        self.sys.printU64(self.handles[index].instance_id);
        self.sys.write(" generation=");
        self.sys.printU64(self.handles[index].generation);
        self.sys.write(" code=");
        self.sys.printI32(code);
        self.sys.println("");
        return false;
    }
    fn waitFile(self: *State, path: [*:0]const u8, expected: []const u8) bool {
        const start = self.sys.ticks();
        var bytes: [64]u8 = undefined;
        while (!self.expired(start)) {
            const got = self.sys.fileRead(path, &bytes);
            if (got == expected.len and std.mem.eql(u8, bytes[0..@intCast(got)], expected)) return true;
            self.sys.sleepTicks(1);
        }
        return false;
    }

    fn exportComplete(self: *State, index: usize) bool {
        const start = self.sys.ticks();
        const allocator = self.sys.allocator();
        while (!self.expired(start)) {
            var info: a.GuiFrameInfo = .{};
            const handle = &self.handles[index];
            if (self.draw.guiFrameInfo(handle, &info) != a.gui_frame_result_ok or info.committed_command_count > 65536 or info.committed_resource_bytes > 1024 * 1024) return false;
            const commands = allocator.alloc(a.GuiFrameCommand, info.committed_command_count) catch return false;
            defer allocator.free(commands);
            const resources = allocator.alloc(u8, info.committed_resource_bytes) catch return false;
            defer allocator.free(resources);
            var snapshot: a.GuiFrameInfo = .{};
            if (self.draw.guiFrameRead(handle, info.committed_generation, commands, resources, &snapshot) == a.gui_frame_result_ok and std.mem.indexOf(u8, resources, "Exported ") != null) return true;
            self.sys.sleepTicks(1);
        }
        return false;
    }
};

fn create(sys: r.r4sys.Context, path: [:0]const u8, bytes: []const u8) bool {
    const files: r.app_storage.Files = .{ .sys = sys };
    var writer = switch (files.streamWriter(.{ .ptr = path, .len = @intCast(path.len) }, a.file_stream_open_create)) {
        .writer => |value| value,
        .failure => return false,
    };
    if (writer.write(bytes) == .ok and writer.finish() == .ok) return true;
    _ = writer.abort();
    return false;
}

// Every line must belong to one complete captured filter. The shared output
// may contain either winning export, never pages from both GUI instances.
fn validateExport(sys: r.r4sys.Context, path: [*:0]const u8) bool {
    const allocator = sys.allocator();
    const bytes = allocator.alloc(u8, 128 * 1024) catch return false;
    defer allocator.free(bytes);
    const got = sys.fileRead(path, bytes);
    if (got <= 0 or got >= bytes.len) return false;
    var lines = std.mem.splitSequence(u8, bytes[0..@intCast(got)], "\r\n");
    var chosen: ?usize = null;
    var count: usize = 0;
    var previous: u64 = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var found: ?usize = null;
        for (markers, 0..) |marker, index| if (std.mem.indexOf(u8, line, marker) != null) {
            found = index;
        };
        const index = found orelse return false;
        if (chosen) |wanted| {
            if (index != wanted) return false;
        } else chosen = index;
        if (!std.mem.startsWith(u8, line, "seq=")) return false;
        const end = std.mem.indexOfScalar(u8, line, ' ') orelse return false;
        const sequence = std.fmt.parseInt(u64, line[4..end], 10) catch return false;
        if (sequence <= previous) return false;
        previous = sequence;
        count += 1;
    }
    return count == 40;
}

pub fn run(sys: r.r4sys.Context, desk: r.r4desk.Context, draw: r.r4draw.Context) bool {
    var state: State = .{ .sys = sys, .desk = desk, .draw = draw };
    var capacity: a.CpuCapacity = .{};
    if (sys.cpuCapacity(&capacity) != a.thread_ok or capacity.available_cpus < 4) return state.fail("four-cpus-required");
    var identity: a.ProgramJoinHandle = .{};
    if (sys.threadCurrentHandle(&identity) != a.thread_ok) return state.fail("identity");
    var buffers: [3][128:0]u8 = undefined;
    var paths: [3][:0]const u8 = undefined;
    for (&buffers, 0..) |*buffer, index| paths[index] = std.fmt.bufPrintZ(buffer, "C:\\TEMP\\APPS-{d}-{x}-{d}.TXT", .{ identity.instance_id, identity.instance_generation, index }) catch return false;
    var owned = [_]bool{false} ** 3;
    // File cleanup happens after the deferred process cleanup below.
    defer for (paths, owned) |path, present| {
        if (present) _ = sys.fileDelete(path);
    };
    defer state.cleanup();
    for (paths) |path| if (sys.exists(path)) return state.fail("private-file-conflict");
    for (paths[0..2], 0..) |path, index| {
        if (!create(sys, path, if (index == 0) "alpha" else "bravo")) return state.fail("input-create");
        owned[index] = true;
    }
    // Establish ownership of the shared output before either GUI can replace
    // it; all later checks/read/delete remain confined to this private path.
    if (!create(sys, paths[2], "pending")) return state.fail("output-create");
    owned[2] = true;
    for (markers) |marker| for (0..40) |_| {
        if (sys.logServiceWriteRecord(a.log_service_source_application, a.log_record_type_event, a.log_severity_info, "SPECTRA", marker) != a.service_api_result_ok) return state.fail("log-fixture");
    };
    var args: [2][256:0]u8 = undefined;
    for (0..2) |i| {
        const log_args = std.fmt.bufPrintZ(&args[i], "/SOURCE=APPLICATION /SEARCH={s} /OUT={s}", .{ markers[i], paths[2] }) catch return false;
        if (!state.startGui(i, paths[i]) or !state.startGui(i + 2, "C:\\TEMP") or !state.startGui(i + 4, log_args)) return state.fail("normal-gui-frame-placement");
    }
    for (0..2) |i| {
        if (!state.key(i, r.gui.Key.ctrl_a) or !state.key(i, @as(u32, 'A') + @as(u32, @intCast(i))) or !state.key(i, 0x13)) return state.fail("notepad-input");
        if (!state.key(i + 2, r.gui.Key.down)) return state.fail("explorer-directory-input");
        if (!state.key(i + 4, 'e')) return state.fail("log-export-input");
    }
    if (!state.waitFile(paths[0], "A") or !state.waitFile(paths[1], "B")) return state.fail("notepad-open-save-bytes");
    if (!state.exportComplete(4) or !state.exportComplete(5)) return state.fail("both-gui-exports-published");
    for (0..6) |index| {
        const after = state.frames[index];
        if (!state.frame(index, after) or !state.placement(index, false)) return state.fail("new-frame-after-applied-placement");
        sys.write("SPECTRA LIFECYCLE apps instance=");
        sys.printU64(state.handles[index].instance_id);
        sys.write(" generation=");
        sys.printU64(state.handles[index].generation);
        sys.write(" cpu=");
        sys.printU64(state.cpus[index]);
        sys.println(" new-frame=OK");
    }
    if (!validateExport(sys, paths[2])) return state.fail("complete-atomic-export");
    var probes = [_]a.ProgramProcessHandle{.{}} ** 2;
    defer for (&probes) |*probe| {
        if (probe.instance_id != 0) {
            _ = sys.programHandleKill(probe);
            _ = state.reap(probe, -9);
        }
    };
    for (&probes) |*probe| {
        // Successful child output is deliberately quiet: the parent console
        // otherwise keeps sealed child backing blocks to preserve that text
        // after Reap. Errors remain visible and the full probe still runs.
        if (sys.programSpawnHandle(app_paths[1], "/SELFTEST /FILES /QUIET", .console, probe) != a.program_handle_ok) return state.fail("parallel-file-probe-spawn");
    }
    for (&probes) |*probe| if (!state.reap(probe, 0)) return state.fail("parallel-file-probe-reap");
    // Each app gets both a graceful close and a forced kill. Exact wait and
    // reap receipts precede file release and the caller's owner-baseline check.
    for (0..6) |index| {
        const handle = &state.handles[index];
        const code: i32 = if (index % 2 == 0) 0 else -9;
        const result = if (code == 0) sys.programHandleRequestClose(handle) else sys.programHandleKill(handle);
        if (result != a.program_handle_ok or !state.reap(handle, code)) return state.fail("close-kill-reap");
    }
    sys.println("SPECTRA LIFECYCLE apps six normal GUIs files=A/B log-lines=40 parallel-file-probes=2 Close=3 Kill=3 Reap=8: OK");
    return true;
}
