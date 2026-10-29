//! Current public Desktop/GUI transport for the retained subsystem cases.
//! Two exact child handles own completion; copied metadata never grants reap
//! authority. Desktop keeps its scene and committed-frame ownership.
const std = @import("std");
const r = @import("r4os");
const r4std = @import("r4std");
const wire = @import("desktop_check");
const Check = @import("desktop_check.zig").Check;
const Output = @import("output.zig").Output;
const scenes = @import("subsystem_scenarios.zig");

pub const Context = struct {
    sys: r.r4sys.Context,
    pub fn exists(self: *const Context, path: [*:0]const u8) bool {
        return self.sys.exists(path);
    }
    pub fn fileDelete(self: *const Context, path: [*:0]const u8) i32 {
        return self.sys.fileDelete(path);
    }
    pub fn fileWrite(self: *const Context, path: [*:0]const u8, bytes: []const u8) i32 {
        return self.sys.fileWrite(path, bytes);
    }
    pub fn ticks(self: *const Context) u64 {
        return self.sys.ticks();
    }
    pub fn sleepTicks(self: *const Context, count: u64) void {
        self.sys.sleepTicks(count);
    }
};
pub const Window = struct {
    title_buf: [64:0]u8 = @splat(0),
    actual_id: i32 = -1,
    frame_valid: bool = false,
    pub fn title(self: *const Window) [*:0]const u8 {
        return &self.title_buf;
    }
};

pub const Controller = struct {
    app: *r.App,
    ctx: Context,
    check: Check,
    assoc: r4std.app_assoc.Config = .{},
    monotonic_hz: u32,
    metadata_interval_ticks: u64,
    next_snapshot_tick: [2]u64 = .{0} ** 2,
    snapshot_requests: u64 = 0,
    windows: [2]Window = .{Window{}} ** 2,
    window_completion_handles: [2]r.abi.ProgramProcessHandle = .{r.abi.ProgramProcessHandle{}} ** 2,
    window_completion_exit_codes: [2]i32 = .{0} ** 2,
    failed: bool = false,
    failure_owner_attempted: bool = false,
    render_stats: struct { redraws: u64 = 0, present_lost_frames: u64 = 0, present_failures: u64 = 0 } = .{},

    pub const startHeadlessSubsystemAcceptance = scenes.startHeadlessSubsystemAcceptance;
    pub const startSnesAcceptance = scenes.startSnesAcceptance;
    pub const launchHeadlessSubsystemGuest = scenes.launchHeadlessSubsystemGuest;
    pub const launchHeadlessR4BasicBaseline = scenes.launchHeadlessR4BasicBaseline;
    pub const launchHeadlessR4GbHostSelfTest = scenes.launchHeadlessR4GbHostSelfTest;
    pub const smokeR4GbProductPath = scenes.smokeR4GbProductPath;
    pub const launchHeadlessR4GbGuest = scenes.launchHeadlessR4GbGuest;
    pub const launchHeadlessR4SnesHostSelfTest = scenes.launchHeadlessR4SnesHostSelfTest;
    pub const smokeR4SnesProductPath = scenes.smokeR4SnesProductPath;
    pub const smokeR4SnesRejection = scenes.smokeR4SnesRejection;
    pub const launchHeadlessR4SnesGuest = scenes.launchHeadlessR4SnesGuest;
    pub const headlessSubsystemFailure = scenes.headlessSubsystemFailure;
    pub const writeHeadlessSubsystemMarker = scenes.writeHeadlessSubsystemMarker;
    pub const headlessSubsystemLaunchFailure = scenes.headlessSubsystemLaunchFailure;
    pub const waitForHeadlessSubsystemAudio = scenes.waitForHeadlessSubsystemAudio;

    pub fn init(app: *r.App, out: *Output, require_basic_fixtures: bool) !Controller {
        if (!r4std.init(app.startContext())) return error.StandardLibrary;
        const sys = app.system();
        // The targeted SNES acceptance never opens these BASIC fixtures.
        // Full subsystem acceptance still requires every original prerequisite.
        if (require_basic_fixtures and (!sys.exists("C:\\R4OS\\SUBSYSTEMS\\test.basic\\SUBSYSOK.R4X") or
            !sys.exists("C:\\TEMP\\SUBSYSTEM-A.BAS") or !sys.exists("C:\\TEMP\\SUBSYSTEM-B.BAS"))) return error.TestFixturesUnavailable;
        const hz = sys.ticksFromMilliseconds(1000);
        if (hz == 0 or hz > std.math.maxInt(u32)) return error.Clock;
        var value: Controller = .{ .app = app, .ctx = .{ .sys = sys }, .check = .{ .sys = sys, .out = out, .desk = app.desktop(), .resource_group = "SUBSYSTEM" }, .monotonic_hz = @intCast(hz), .metadata_interval_ticks = @max(1, sys.ticksFromMilliseconds(50)) };
        if (sys.programOpenHandle(@intCast(app.startContext().instance_id), &value.check.caller) != 0) return error.Caller;
        value.assoc = r4std.app_assoc.Config.initDefault();
        var bytes: [4096]u8 = undefined;
        const count = sys.fileRead(r4std.settings.paths.assoc, &bytes);
        if (count > 0) _ = value.assoc.loadFromBytes(bytes[0..@intCast(count)]);
        return value;
    }

    pub fn checkDesktopBase(self: *Controller) bool {
        return @import("desktop_check.zig").run(self.app, "/RESTART /AUDIO", self.check.out) == 0;
    }

    pub fn findFreeAppWindow(self: *Controller) ?usize {
        for (self.check.handles, 0..) |handle, index| if (handle.instance_id == 0) return index;
        return null;
    }

    fn beginStage(self: *Controller) bool {
        if (self.check.handles[0].instance_id != 0 or self.check.handles[1].instance_id != 0) return true;
        if (self.check.session) {
            // End can meet a still-retiring owned child or an already empty
            // reservation. Carry a short cleanup deadline on either path;
            // the previous benchmark's broad work deadline is not an idle
            // session lease. Completion still requires the real End reply.
            self.check.deadline = @min(self.check.deadline, self.ctx.ticks() +| self.ctx.sys.ticksFromMilliseconds(10000));
            while (true) {
                _ = self.check.call(.end, .{}, 0, 0) catch |err| {
                    if (err == error.BusyOrUserActivity or err == error.DesktopBrokerBusy) {
                        self.ctx.sys.sleepTicks(1);
                        continue;
                    }
                    self.check.out.record("stage-retirement-error", "SUBSYSTEM", 0, .{ .reason = @errorName(err), .now_tick = self.ctx.ticks(), .deadline_tick = self.check.deadline, .output_failed = self.check.out.failed });
                    return self.headlessSubsystemFailure("stage-retirement");
                };
                break;
            }
            self.check.session = false;
        }
        self.check.deadline = self.ctx.ticks() +| self.ctx.sys.ticksFromMilliseconds(300000);
        _ = self.check.beginSession(.begin_benchmark) catch return self.headlessSubsystemFailure("stage-admission");
        return true;
    }

    pub fn launchGuiPath(self: *Controller, path: [*:0]const u8, args: [*:0]const u8, title: [*:0]const u8, policy: r.abi.LaunchPolicy) void {
        _ = title;
        if (!self.beginStage()) {
            self.failed = true;
            return;
        }
        const index = self.findFreeAppWindow() orelse {
            self.failed = true;
            return;
        };
        self.windows[index] = .{};
        self.next_snapshot_tick[index] = 0;
        if (self.ctx.sys.programSpawnHandle(path, args, policy, &self.check.handles[index]) != 0) {
            self.failed = true;
            return;
        }
        var info: r.abi.ProgramInstanceInfo = .{};
        // A fixture generator may really finish before the first UI bind.
        // The exact parent still owns its completion and reaps it in pump.
        if (self.ctx.sys.programHandleStatus(&self.check.handles[index], &info) == 0 and
            info.state == @intFromEnum(r.abi.ProgramInstanceState.done)) return;
        _ = self.check.call(.bind, identity(self.check.handles[index]), 0, 0) catch {
            self.failed = true;
            _ = self.headlessSubsystemFailure("window-bind");
        };
    }

    pub fn smokePumpCooperativeFrames(self: *Controller, count: u32) void {
        if (self.ctx.sys.programShouldClose()) {
            self.failed = true;
            return;
        }
        for (0..count) |_| {
            self.ctx.sleepTicks(0);
            for (0..2) |index| {
                const handle = self.check.handles[index];
                if (handle.instance_id == 0) continue;
                var info: r.abi.ProgramInstanceInfo = .{};
                if (self.ctx.sys.programHandleStatus(&handle, &info) != 0) {
                    self.failed = true;
                    continue;
                }
                if (info.state == @intFromEnum(r.abi.ProgramInstanceState.done)) {
                    var done: r.abi.ProgramProcessCompletion = .{};
                    if (self.ctx.sys.programHandleWait(&handle, 0, &done) != 0 or !same(done.handle, handle) or done.sequence == 0) {
                        self.failed = true;
                        continue;
                    }
                    const sequence = done.sequence;
                    const code = done.exit_code;
                    const reaped = self.ctx.sys.programHandleReap(&handle, &done);
                    if (reaped == r.abi.program_handle_error_would_block) continue;
                    if (reaped != 0 or !same(done.handle, handle) or done.sequence != sequence or done.exit_code != code) {
                        self.failed = true;
                        continue;
                    }
                    self.window_completion_handles[index] = handle;
                    self.window_completion_exit_codes[index] = code;
                    self.check.handles[index] = .{};
                    self.check.out.record("completion", "SUBSYSTEM", index, .{ .handle = handle, .sequence = sequence, .exit_code = code, .reaped = true });
                    continue;
                }
                if (info.state == @intFromEnum(r.abi.ProgramInstanceState.close_requested)) continue;
                const now = self.ctx.ticks();
                if (now < self.next_snapshot_tick[index]) continue;
                self.next_snapshot_tick[index] = now +| self.metadata_interval_ticks;
                self.snapshot_requests +%= 1;
                const snapshot = self.check.call(.snapshot, identity(handle), 0, 0) catch |err| {
                    // A GUI can really finish between Status and Snapshot,
                    // or still await its first Desktop attachment. Retain
                    // this parent's exact handle until actual completion.
                    // The original scenario deadline bounds a missing window.
                    var current: r.abi.ProgramInstanceInfo = .{};
                    if (err == error.NotFound and self.ctx.sys.programHandleStatus(&handle, &current) == 0 and
                        (current.state == @intFromEnum(r.abi.ProgramInstanceState.running) or
                            current.state == @intFromEnum(r.abi.ProgramInstanceState.close_requested) or
                            current.state == @intFromEnum(r.abi.ProgramInstanceState.done))) continue;
                    self.check.out.unavailable("SUBSYSTEM", @errorName(err));
                    self.failed = true;
                    continue;
                };
                self.windows[index].actual_id = info.window_id;
                self.render_stats = .{ .redraws = snapshot.redraws, .present_lost_frames = snapshot.present_lost_frames, .present_failures = snapshot.present_failures };
                self.windows[index].frame_valid = snapshot.flags & wire.frame_valid != 0;
                _ = (self.app.desktop() orelse {
                    self.failed = true;
                    continue;
                }).guiTitle(handle.instance_id, &self.windows[index].title_buf);
            }
        }
    }

    pub fn activateWindow(self: *Controller, index: usize, unused: bool) void {
        _ = unused;
        if (index >= 2) {
            self.failed = true;
            return;
        }
        self.windowAction(index, .focus);
    }
    pub fn toggleMaximizeWindow(self: *Controller, index: usize) void {
        if (index >= 2) {
            self.failed = true;
            return;
        }
        self.windowAction(index, .maximize);
    }
    fn ended(self: *Controller, handle: r.abi.ProgramProcessHandle) bool {
        if (handle.instance_id == 0) return true; // Only our Reap clears it.
        var info: r.abi.ProgramInstanceInfo = .{};
        return self.ctx.sys.programHandleStatus(&handle, &info) == 0 and
            info.state == @intFromEnum(r.abi.ProgramInstanceState.done);
    }
    fn windowAction(self: *Controller, index: usize, op: wire.Op) void {
        const handle = self.check.handles[index];
        // The original fire-and-forget UI actions ignore an already ended
        // window. Fast KVM fixtures can really finish during the prior pump.
        if (self.ended(handle)) return;
        _ = self.check.call(op, identity(handle), 0, 0) catch |err| {
            if (err == error.NotFound and self.ended(handle)) return;
            self.check.out.record("transport-failure", "SUBSYSTEM", index, .{ .operation = op, .reason = @errorName(err), .handle = handle });
            self.failed = true;
        };
    }
    pub fn requestWindowProcessClose(self: *Controller, index: usize) i32 {
        if (index >= 2) return -1;
        return self.ctx.sys.programHandleRequestClose(&self.check.handles[index]);
    }
    pub fn pushGuiKeyEvent(self: *Controller, index: usize, key: u32) void {
        if (index < 2 and self.ended(self.check.handles[index])) return;
        if (!self.push(index, .{ .kind = @intFromEnum(r.abi.GuiEventKind.key_down), .key = key })) {
            if (index < 2 and self.ended(self.check.handles[index])) return;
            self.check.out.unavailable("SUBSYSTEM", "logical-key-delivery");
            self.failed = true;
        }
    }
    pub fn pushGuiEvent(self: *Controller, index: usize, kind: r.abi.GuiEventKind) void {
        if (index < 2 and self.ended(self.check.handles[index])) return;
        if (!self.push(index, .{ .kind = @intFromEnum(kind) })) {
            if (index < 2 and self.ended(self.check.handles[index])) return;
            if (kind == .close and index < 2) {
                var info: r.abi.ProgramInstanceInfo = .{};
                if (self.ctx.sys.programHandleStatus(&self.check.handles[index], &info) == 0 and
                    info.state == @intFromEnum(r.abi.ProgramInstanceState.close_requested)) return;
            }
            self.check.out.unavailable("SUBSYSTEM", "event-delivery");
            self.failed = true;
        }
    }
    pub fn pushGuiPhysicalKeyEvent(self: *Controller, index: usize, usage: u32, down: bool) bool {
        return self.push(index, .{ .kind = @intFromEnum(if (down) r.abi.GuiEventKind.physical_key_down else r.abi.GuiEventKind.physical_key_up), .key = usage });
    }
    fn push(self: *Controller, index: usize, event: r.abi.GuiEvent) bool {
        if (index >= 2 or self.check.handles[index].instance_id == 0) {
            self.check.out.record("gui-event-refusal", "SUBSYSTEM", index, .{ .stage = @as([]const u8, "owned-handle"), .event = event });
            return false;
        }
        const handle = self.check.handles[index];
        var info: r.abi.ProgramInstanceInfo = .{};
        const status = self.ctx.sys.programHandleStatus(&handle, &info);
        if (status != 0 or
            (info.state != @intFromEnum(r.abi.ProgramInstanceState.running) and
                info.state != @intFromEnum(r.abi.ProgramInstanceState.close_requested)) or info.window_id < 0)
        {
            self.check.out.record("gui-event-refusal", "SUBSYSTEM", index, .{ .stage = @as([]const u8, "program-window"), .handle = handle, .status = status, .state = info.state, .window = info.window_id, .event = event, .last_window_id = self.windows[index].actual_id, .last_frame_valid = self.windows[index].frame_valid });
            return false;
        }
        var value = event;
        value.window_id = info.window_id;
        value.tick = self.ctx.ticks();
        const desk = self.app.desktop() orelse {
            self.check.out.record("gui-event-refusal", "SUBSYSTEM", index, .{ .stage = @as([]const u8, "desktop-api"), .handle = handle, .event = value });
            return false;
        };
        for (0..4) |attempt| {
            const rc = desk.guiPushEvent(handle.instance_id, &value);
            if (rc == 0) return true;
            if (rc != -3 or attempt == 3) {
                self.check.out.record("gui-event-refusal", "SUBSYSTEM", index, .{ .stage = @as([]const u8, "push"), .handle = handle, .state = info.state, .window = info.window_id, .event = value, .attempt = attempt, .raw = rc, .last_window_id = self.windows[index].actual_id, .last_frame_valid = self.windows[index].frame_valid });
                return false;
            }
            self.ctx.sleepTicks(0);
        }
        return false;
    }
};

fn identity(handle: r.abi.ProgramProcessHandle) wire.Identity {
    return .{ .instance = handle.instance_id, .generation = handle.generation };
}
fn same(a: r.abi.ProgramProcessHandle, b: r.abi.ProgramProcessHandle) bool {
    return a.instance_id != 0 and a.instance_id == b.instance_id and a.generation == b.generation;
}
