//! Explicit current Explorer workload and real GUI input. No product delay,
//! fake worker, private kernel state or physical visibility assertion.
const std = @import("std");
const r = @import("r4os");
const a = r.abi;
const Output = @import("output.zig").Output;
const Host = @import("desktop_host_check.zig").Owner;
const count_files: usize = 1024;
const directory = "C:\\TEMP\\EXPNAV08744";
const link_bytes = "R4S_FORMAT=1\nSCHEMA=R4LNK\nTARGET=C:\\AUTOEXEC.BAT\nTITLE=ZZZ resolved title\n";

fn filePath(out: *[128]u8, index: usize, link: bool) ![:0]u8 {
    return std.fmt.bufPrintZ(out, directory ++ "\\{s}{d:0>4}.{s}", .{ if (link) "LINK" else "ITEM", index, if (link) "LNK" else "TXT" });
}
fn create(sys: *const r.r4sys.Context, owned: *bool) !void {
    var info: a.FileInfo = .{};
    if (sys.fileInfoRaw(directory, &info) != 0) return error.FixtureOccupied;
    if (sys.dirCreate(directory) <= 0) return error.FixtureCreate;
    owned.* = true;
    var path: [128]u8 = undefined;
    for (0..count_files) |index| {
        const normal = try filePath(&path, index, false);
        if (sys.fileWrite(normal.ptr, "native navigation") != 17) return error.FixtureFile;
        const link = try filePath(&path, index, true);
        if (sys.fileWrite(link.ptr, link_bytes) != link_bytes.len) return error.FixtureLink;
    }
}
fn cleanup(sys: *const r.r4sys.Context) bool {
    var path: [128]u8 = undefined;
    for (0..count_files) |index| for ([_]bool{ false, true }) |link| {
        const name = filePath(&path, index, link) catch return false;
        if (sys.fileDelete(name.ptr) < 0) return false;
    };
    return sys.dirDelete(directory) > 0;
}
fn close(sys: *const r.r4sys.Context, child: *a.ProgramProcessHandle) bool {
    if (child.instance_id == 0) return true;
    _ = sys.programHandleRequestClose(child);
    const deadline = sys.ticks() +| sys.ticksFromMilliseconds(10000);
    while (sys.ticks() < deadline) {
        var info: a.ProgramInstanceInfo = .{};
        const result = sys.programHandleStatus(child, &info);
        if (result == a.program_handle_error_not_found or result == a.program_handle_error_stale) {
            child.* = .{};
            return true;
        }
        if (result != 0) return false;
        sys.sleepTicks(1);
    }
    return false;
}
const Launched = struct { process: a.ProgramProcessHandle, content: u64 };
fn launch(sys: *const r.r4sys.Context) !Launched {
    var gui_child: a.ProgramProcessHandle = .{};
    var gui_returned = false;
    defer if (!gui_returned and gui_child.instance_id != 0) {
        _ = close(sys, &gui_child);
    };
    var helper: a.ProgramProcessHandle = .{};
    if (sys.programSpawnHandle("C:\\R4OS\\SOFTWARE\\TERMINAL\\DESKRUN.R4X", "/JSON /WAIT:10000 /WAITFRAME \"C:\\R4OS\\SOFTWARE\\DESKTOP\\EXPLORER.R4X\" " ++ directory, .console, &helper) != 0) return error.Launch;
    var retired = false;
    defer if (!retired) {
        _ = sys.programHandleKill(&helper);
        var completion: a.ProgramProcessCompletion = .{};
        _ = sys.programHandleWait(&helper, 4000, &completion);
        _ = sys.programHandleReap(&helper, &completion);
    };
    var completion: a.ProgramProcessCompletion = .{};
    if (sys.programHandleWait(&helper, 15000, &completion) != 0) return error.LaunchWait;
    var bytes: [1024]u8 = undefined;
    var length: u32 = 0;
    if (sys.programCompletionRead(&helper, 0, &bytes, &length) != 0 or length == 0 or length > bytes.len) return error.LaunchReceipt;
    var memory: [8192]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&memory);
    const Reply = struct { process_id: u32, process_generation: u64, errorlevel: i32, phase: []const u8, content: u64 };
    const parsed = try std.json.parseFromSlice(Reply, fixed.allocator(), std.mem.trim(u8, bytes[0..length], " \r\n\t"), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const value = parsed.value;
    if (value.process_id != 0 and value.process_generation != 0) gui_child = .{ .instance_id = value.process_id, .generation = value.process_generation };
    if (completion.exit_code != 0 or value.process_id == 0 or value.process_generation == 0 or value.errorlevel != 0 or value.content == 0 or !std.mem.eql(u8, value.phase, "content")) return error.LaunchIdentity;
    if (sys.programHandleReap(&helper, &completion) != 0) return error.LaunchReap;
    retired = true;
    gui_returned = true;
    return .{ .process = .{ .instance_id = value.process_id, .generation = value.process_generation }, .content = value.content };
}
fn title(desk: *const r.r4desk.Context, child: a.ProgramProcessHandle, out: *[128]u8) ![]const u8 {
    @memset(out, 0);
    if (desk.guiTitle(child.instance_id, out) < 0) return error.Title;
    return std.mem.sliceTo(out, 0);
}
fn waitTitle(sys: *const r.r4sys.Context, desk: *const r.r4desk.Context, child: a.ProgramProcessHandle, wanted: []const u8) !u32 {
    const deadline = sys.ticks() +| sys.ticksFromMilliseconds(20000);
    var buffer: [128]u8 = undefined;
    while (sys.ticks() < deadline) {
        var info: a.ProgramInstanceInfo = .{};
        if (sys.programHandleStatus(&child, &info) != 0 or info.state != @intFromEnum(a.ProgramInstanceState.running)) return error.ChildEnded;
        if (std.mem.eql(u8, try title(desk, child, &buffer), wanted)) return desk.guiRevision(child.instance_id);
        if (sys.programShouldClose()) return error.Cancelled;
        sys.sleepTicks(1);
    }
    return error.PhaseNotObserved;
}
fn key(sys: *const r.r4sys.Context, desk: *const r.r4desk.Context, child: a.ProgramProcessHandle, code: u32) !void {
    var info: a.ProgramInstanceInfo = .{};
    if (sys.programHandleStatus(&child, &info) != 0 or info.window_id < 0 or info.state != @intFromEnum(a.ProgramInstanceState.running)) return error.KeyIdentity;
    var event: a.GuiEvent = .{ .kind = @intFromEnum(a.GuiEventKind.key_down), .window_id = info.window_id, .key = code, .tick = sys.ticks() };
    if (desk.guiPushEvent(child.instance_id, &event) < 0) return error.Key;
}
fn exercise(sys: *const r.r4sys.Context, desk: *const r.r4desk.Context, out: *Output, details: bool, close_loading: bool) !void {
    const launched = try launch(sys);
    var child = launched.process;
    defer if (child.instance_id != 0) {
        _ = close(sys, &child);
    };
    // Reading is set only after a real frame publication admitted the worker.
    const phase = if (details) "Explorer - Reading shortcut details..." else "Explorer - Reading folder...";
    const before = try waitTitle(sys, desk, child, phase);
    if (close_loading) {
        const identity = child;
        if (!close(sys, &child)) return error.CloseDuringLoad;
        out.record("explorer-close-during-load", "DESKTOP", 0, .{ .process = identity, .first_content = launched.content, .observed_phase = phase, .native_join_and_desktop_reap = true, .physical_visibility = @as(?bool, null) });
        return;
    }
    try key(sys, desk, child, 'd');
    const after = try waitTitle(sys, desk, child, "Explorer - D:\\");
    if (after == before) return error.NoGuiResponse;
    var buffer: [128]u8 = undefined;
    const until = sys.ticks() +| sys.ticksFromMilliseconds(100);
    while (sys.ticks() < until) {
        if (!std.mem.eql(u8, try title(desk, child, &buffer), "Explorer - D:\\")) return error.LateOldAdoption;
        sys.sleepTicks(1);
    }
    const identity = child;
    if (!close(sys, &child)) return error.ReplacementClose;
    out.record("explorer-navigation", "DESKTOP", @intFromBool(details), .{ .process = identity, .files = count_files * 2, .first_content = launched.content, .observed_phase = phase, .revision_before = before, .revision_after_input = after, .new_target = @as([]const u8, "D:\\"), .new_target_retained = true, .old_generation_replaced = true, .cooperative_close_and_desktop_reap = true, .physical_visibility = @as(?bool, null) });
}
pub fn run(app: *r.App, args: []const u8, out: *Output) i32 {
    var own = false;
    var nav = false;
    var options = std.mem.tokenizeAny(u8, args, " \t");
    while (options.next()) |option| {
        if (std.ascii.eqlIgnoreCase(option, "/HOST") and !own) own = true else if (std.ascii.eqlIgnoreCase(option, "/NAV") and !nav) nav = true else return 2;
    }
    if (!own or !nav) return 2;
    const sys = app.system();
    const desk = app.desktop() orelse return 2;
    var host: Host = .{};
    host.start(sys) catch |err| {
        out.unavailable("DESKTOP", @errorName(err));
        return 1;
    };
    var ok = true;
    var fixture_owned = false;
    create(&sys, &fixture_owned) catch |err| {
        out.unavailable("DESKTOP", @errorName(err));
        ok = false;
    };
    if (ok) {
        exercise(&sys, &desk, out, false, false) catch |err| {
            out.unavailable("DESKTOP", @errorName(err));
            ok = false;
        };
        if (ok) exercise(&sys, &desk, out, true, false) catch |err| {
            out.unavailable("DESKTOP", @errorName(err));
            ok = false;
        };
        if (ok) exercise(&sys, &desk, out, false, true) catch |err| {
            out.unavailable("DESKTOP", @errorName(err));
            ok = false;
        };
    }
    const files_removed = !fixture_owned or cleanup(&sys);
    const host_retired = host.finish(sys, out);
    ok = ok and files_removed and host_retired;
    out.record("result", "DESKTOP", 0, .{ .exit_code = @as(i32, if (ok) 0 else 1), .success = ok, .cleanup_acknowledged = files_removed and host_retired, .input_consumed_by_check = false, .physical_visibility = @as(?bool, null) });
    return if (ok) 0 else 1;
}
