//! Existing subsystem scenarios moved from the embedded Desktop smoke.
//! Resolution, original fixture options, 60-second work, input, persistence,
//! exact exits and independent close/rejection cases are kept. Generic UI
//! checks use canonical Spectra; private render/font oracles stay native.
const std = @import("std");
const r4os = @import("r4os");
const r4std = @import("r4std");
const Controller = @import("subsystem_control.zig").Controller;
const HeadlessSubsystemLaunch = struct { index: usize, handle: r4os.abi.ProgramProcessHandle };
const window_launch_path_max: usize = 63;
const console_title_max: usize = 31;
const audio_service_module_path = "C:\\R4OS\\SERVICES\\AUDSVC.R4X";
const subsystem_host_test_path = "/R4OS/SUBSYSTEMS/test.basic/SUBSYSOK.R4X";
const subsystem_guest_a_path = "C:\\TEMP\\SUBSYSTEM-A.BAS";
const subsystem_guest_b_path = "C:\\TEMP\\SUBSYSTEM-B.BAS";
const subsystem_host_test_marker_path = "C:\\TEMP\\SUBSYS.OK";
const r4basic_host_path = "/R4OS/SUBSYSTEMS/r4os.basic/R4BASIC.R4X";
const r4basic_baseline_guest_path = "C:\\TEMP\\GORILLA.BAS";
const r4basic_baseline_marker_path = "C:\\TEMP\\R4BASIC.BASELINE";
const r4gb_host_path = "/R4OS/SUBSYSTEMS/r4os.gb/R4GB.R4X";
const r4gb_host_test_marker_path = "C:\\TEMP\\R4GB.HOST";
const r4gb_fixture_a_path = "C:\\TEMP\\R4GB-E2E-A.GB";
const r4gb_fixture_b_path = "C:\\TEMP\\R4GB-E2E-B.GBC";
const r4gb_fixture_cgb_path = "C:\\TEMP\\R4GB-CGB-ONLY.GBC";
const r4gb_trace_a = "00000000000000A1";
const r4gb_trace_b = "00000000000000B2";
const r4gb_trace_cgb = "00000000000000C3";
const r4gb_trace_end_key = "end";
const r4gb_report_a_path = "C:\\TEMP\\R4GB-00000000000000A1.REPORT";
const r4gb_report_b_path = "C:\\TEMP\\R4GB-00000000000000B2.REPORT";
const r4gb_report_cgb_path = "C:\\TEMP\\R4GB-00000000000000C3.REPORT";
const r4gb_cgb_rejection_exit: i32 = 71;
const r4snes_host_path = "/R4OS/SUBSYSTEMS/r4os.snes/R4SNES.R4X";
const r4snes_host_test_marker_path = "C:\\TEMP\\R4SNES.HOST";
const r4snes_fixture_a_path = "C:\\TEMP\\R4SNES-E2E-A.SFC";
const r4snes_fixture_b_path = "C:\\TEMP\\R4SNES-E2E-B.SMC";
const r4snes_fixture_invalid_path = "C:\\TEMP\\R4SNES-INVALID.SFC";
const r4snes_fixture_firmware_path = "C:\\TEMP\\R4SNES-DSP-REQUIRED.SFC";
const r4snes_trace_a = "00000000000000D1";
const r4snes_trace_b = "00000000000000D2";
const r4snes_trace_invalid = "00000000000000D3";
const r4snes_trace_firmware = "00000000000000D4";
const r4snes_trace_end_key = "end";
const r4snes_report_a_path = "C:\\TEMP\\R4SNES-00000000000000D1.REPORT";
const r4snes_report_b_path = "C:\\TEMP\\R4SNES-00000000000000D2.REPORT";
const r4snes_report_invalid_path = "C:\\TEMP\\R4SNES-00000000000000D3.REPORT";
const r4snes_report_firmware_path = "C:\\TEMP\\R4SNES-00000000000000D4.REPORT";
const r4snes_invalid_exit: i32 = 71;
const r4snes_firmware_exit: i32 = 74;
const subsystem_audio_service = "AUDSVC";
const subsystem_host_test_marker =
    "SUBSYSTEM host selftest: OK modes=640x350+320x200+256x224 formats=indexed8+xrgb32 damage=sparse indexed8=abi tiles=bounded input=sequenced+policy-filtered idle=no-frame fps>=20\r\n" ++
    "SUBSYSTEM runtime selftest: OK instances=2 slices=bounded time=monotonic audio=s16le-buffered lifecycle=pause+resume+reset+complete+close errors=isolated resources=closed\r\n" ++
    "R4BASIC source-probe: info_calls=1 read_calls=0 read_bytes=0 limit_bytes=262144\r\n" ++
    "R4GB explorer E2E: OK catalog=MODULES.JSON assoc=ids-only formats=.gb+.gbc probe=bounded instances=2 input=physical video=frames audio=app-audio save=sram+rtc rejection=cgb-only close=witness+separate\r\n" ++
    "R4GB long-run E2E: OK duration=60s instances=2 focus=alternating lifecycle=pause+resume+reset+mute endings=witness+close desktop=responsive\r\n" ++
    "R4SNES explorer E2E: OK catalog=MODULES.JSON assoc=ids-only formats=.sfc+.smc probe=zero-byte instances=2 input=physical video=xrgb32 audio=app-audio save=sram+rtc rejection=invalid+firmware close=witness+separate\r\n" ++
    "R4SNES long-run E2E: OK duration=60s instances=2 focus=alternating lifecycle=pause+resume+reset+mute endings=witness+close desktop=responsive\r\n";

pub fn startHeadlessSubsystemAcceptance(self: *Controller) bool {
    return runAcceptance(self, false);
}
pub fn startSnesAcceptance(self: *Controller) bool {
    return runAcceptance(self, true);
}
fn runAcceptance(self: *Controller, snes_only: bool) bool {
    // The canonical check proves isolated, quiet current Desktop admission
    // before touching this fixture's known outputs.
    if (!self.checkDesktopBase()) return self.headlessSubsystemFailure("desktop-check");
    if (!snes_only) {
        _ = self.ctx.fileDelete(subsystem_host_test_marker_path);
        _ = self.ctx.fileDelete(r4basic_baseline_marker_path);
        _ = self.ctx.fileDelete(r4gb_host_test_marker_path);
        _ = self.ctx.fileDelete(r4gb_report_a_path);
        _ = self.ctx.fileDelete(r4gb_report_b_path);
        _ = self.ctx.fileDelete(r4gb_report_cgb_path);
    }
    _ = self.ctx.fileDelete(r4snes_host_test_marker_path);
    _ = self.ctx.fileDelete(r4snes_report_a_path);
    _ = self.ctx.fileDelete(r4snes_report_b_path);
    _ = self.ctx.fileDelete(r4snes_report_invalid_path);
    _ = self.ctx.fileDelete(r4snes_report_firmware_path);
    if (!self.waitForHeadlessSubsystemAudio()) return self.headlessSubsystemFailure("audio-service");
    self.window_completion_handles = .{r4os.abi.ProgramProcessHandle{}} ** self.window_completion_handles.len;
    self.window_completion_exit_codes = .{0} ** self.window_completion_exit_codes.len;
    if (r4std.subsystem_runtime.load(&self.ctx.sys) != .loaded) return self.headlessSubsystemFailure("catalog-load");

    if (!snes_only) {
        const first = self.launchHeadlessSubsystemGuest(subsystem_guest_a_path) orelse return false;
        const second = self.launchHeadlessSubsystemGuest(subsystem_guest_b_path) orelse return false;
        if (first.index == second.index or sameProcessHandle(first.handle, second.handle)) return self.headlessSubsystemFailure("instance-identity");

        self.toggleMaximizeWindow(first.index);
        self.smokePumpCooperativeFrames(1);
        if (self.failed) return self.headlessSubsystemFailure("controller-transport-or-cancelled");
        if (sameProcessHandle(self.check.handles[first.index], first.handle)) self.toggleMaximizeWindow(first.index);
        self.activateWindow(second.index, false);
        self.pushGuiKeyEvent(first.index, 'P');
        self.pushGuiKeyEvent(second.index, 'P');

        const started = self.ctx.ticks();
        const timeout_ticks = @as(u64, self.monotonic_hz) * 45;
        while (sameProcessHandle(self.check.handles[first.index], first.handle) or
            sameProcessHandle(self.check.handles[second.index], second.handle))
        {
            self.smokePumpCooperativeFrames(1);
            if (self.failed) return self.headlessSubsystemFailure("controller-transport-or-cancelled");
            if (self.ctx.ticks() -| started >= timeout_ticks) return self.headlessSubsystemFailure("runtime-timeout");
        }

        if (!sameProcessHandle(self.window_completion_handles[first.index], first.handle)) return self.headlessSubsystemFailure("completion-a-handle");
        if (self.window_completion_exit_codes[first.index] != 0) return self.headlessSubsystemFailure("completion-a-exit");
        if (!sameProcessHandle(self.window_completion_handles[second.index], second.handle)) return self.headlessSubsystemFailure("completion-b-handle");
        if (self.window_completion_exit_codes[second.index] != 0) return self.headlessSubsystemFailure("completion-b-exit");

        const baseline = self.launchHeadlessR4BasicBaseline() orelse return false;
        const baseline_started = self.ctx.ticks();
        const baseline_timeout_ticks = @as(u64, self.monotonic_hz) * 60;
        while (sameProcessHandle(self.check.handles[baseline.index], baseline.handle)) {
            self.smokePumpCooperativeFrames(1);
            if (self.failed) return self.headlessSubsystemFailure("controller-transport-or-cancelled");
            if (self.ctx.ticks() -| baseline_started >= baseline_timeout_ticks) return self.headlessSubsystemFailure("r4basic-timeout");
        }
        if (!sameProcessHandle(self.window_completion_handles[baseline.index], baseline.handle)) return self.headlessSubsystemFailure("r4basic-completion-handle");
        if (self.window_completion_exit_codes[baseline.index] != 0) return self.headlessSubsystemFailure("r4basic-completion-exit");
        if (!self.ctx.exists(r4basic_baseline_marker_path)) return self.headlessSubsystemFailure("r4basic-marker");

        const r4gb = self.launchHeadlessR4GbHostSelfTest() orelse return false;
        const r4gb_started = self.ctx.ticks();
        const r4gb_timeout_ticks = @as(u64, self.monotonic_hz) * 30;
        while (sameProcessHandle(self.check.handles[r4gb.index], r4gb.handle)) {
            self.smokePumpCooperativeFrames(1);
            if (self.failed) return self.headlessSubsystemFailure("controller-transport-or-cancelled");
            if (self.ctx.ticks() -| r4gb_started >= r4gb_timeout_ticks) return self.headlessSubsystemFailure("r4gb-timeout");
        }
        if (!sameProcessHandle(self.window_completion_handles[r4gb.index], r4gb.handle)) return self.headlessSubsystemFailure("r4gb-completion-handle");
        if (self.window_completion_exit_codes[r4gb.index] != 0) return self.headlessSubsystemFailure("r4gb-completion-exit");
        if (!self.ctx.exists(r4gb_host_test_marker_path)) return self.headlessSubsystemFailure("r4gb-marker");
        if (!self.smokeR4GbProductPath()) return false;
    }

    const r4snes = self.launchHeadlessR4SnesHostSelfTest() orelse return false;
    const r4snes_started = self.ctx.ticks();
    const r4snes_timeout_ticks = @as(u64, self.monotonic_hz) * 30;
    while (sameProcessHandle(self.check.handles[r4snes.index], r4snes.handle)) {
        self.smokePumpCooperativeFrames(1);
        if (self.failed) return self.headlessSubsystemFailure("controller-transport-or-cancelled");
        if (self.ctx.ticks() -| r4snes_started >= r4snes_timeout_ticks) return self.headlessSubsystemFailure("r4snes-timeout");
    }
    if (!sameProcessHandle(self.window_completion_handles[r4snes.index], r4snes.handle)) return self.headlessSubsystemFailure("r4snes-completion-handle");
    if (self.window_completion_exit_codes[r4snes.index] != 0) return self.headlessSubsystemFailure("r4snes-completion-exit");
    if (!self.ctx.exists(r4snes_host_test_marker_path)) return self.headlessSubsystemFailure("r4snes-marker");
    if (!self.smokeR4SnesProductPath()) return false;
    return true;
}

pub fn launchHeadlessSubsystemGuest(self: *Controller, guest_path: []const u8) ?HeadlessSubsystemLaunch {
    const input = r4std.subsystem_runtime.probe(&self.ctx.sys, guest_path) catch return self.headlessSubsystemLaunchFailure("guest-probe");
    var args_storage: [r4os.subsystem_launch.max_args_bytes]u8 = undefined;
    var resolution: r4std.file_handler.Resolution = .{};
    r4std.file_handler.resolve(&self.assoc, r4std.subsystem_runtime.catalog(), input, args_storage[0..], &resolution) catch return self.headlessSubsystemLaunchFailure("handler-resolve");
    const target = resolution.target orelse return self.headlessSubsystemLaunchFailure("handler-missing");
    if (target.kind != .subsystem) return self.headlessSubsystemLaunchFailure("handler-kind");
    if (!equalsIgnoreCase(target.handler_id, "test.basic")) return self.headlessSubsystemLaunchFailure("handler-id");
    if (!equalsIgnoreCase(target.format_id, "basic.qbasic-source")) return self.headlessSubsystemLaunchFailure("guest-format");
    if (!equalsIgnoreCase(target.app_path, subsystem_host_test_path)) return self.headlessSubsystemLaunchFailure("host-path");
    if (!r4std.subsystem_runtime.hostPresent(&self.ctx.sys, target.app_path)) return self.headlessSubsystemLaunchFailure("host-missing");
    if (target.app_path.len > window_launch_path_max or target.args.len > r4os.subsystem_launch.max_args_bytes or target.title.len > console_title_max) return self.headlessSubsystemLaunchFailure("launch-limits");

    const request = r4os.subsystem_launch.parse(target.args) catch return self.headlessSubsystemLaunchFailure("launch-request");
    if (!equalsIgnoreCase(request.guest_path, guest_path)) return self.headlessSubsystemLaunchFailure("guest-identity");
    const index = self.findFreeAppWindow() orelse return self.headlessSubsystemLaunchFailure("window-slot");
    var path_z: [window_launch_path_max + 1]u8 = .{0} ** (window_launch_path_max + 1);
    var args_z: [r4os.subsystem_launch.max_args_bytes + 1]u8 = .{0} ** (r4os.subsystem_launch.max_args_bytes + 1);
    var title_z: [console_title_max + 1]u8 = .{0} ** (console_title_max + 1);
    copySliceZ(path_z[0..], target.app_path);
    copySliceZ(args_z[0..], target.args);
    copySliceZ(title_z[0..], target.title);
    self.launchGuiPath(zptr(path_z[0..]), zptr(args_z[0..]), zptr(title_z[0..]), target.policy);
    const handle = self.check.handles[index];
    if (!processHandleValid(handle)) return self.headlessSubsystemLaunchFailure("program-spawn");
    return .{ .index = index, .handle = handle };
}

pub fn launchHeadlessR4BasicBaseline(self: *Controller) ?HeadlessSubsystemLaunch {
    const start_ns = self.ctx.sys.monotonicNanoseconds() orelse return self.headlessSubsystemLaunchFailure("r4basic-clock");
    const inspection = r4std.subsystem_runtime.inspect(&self.ctx.sys, r4basic_baseline_guest_path) catch return self.headlessSubsystemLaunchFailure("r4basic-probe");
    const probe_end_ns = self.ctx.sys.monotonicNanoseconds() orelse return self.headlessSubsystemLaunchFailure("r4basic-probe-clock");
    const associations = [_]r4os.subsystem_catalog.Association{.{
        .extension = ".BAS",
        .subsystem_id = "r4os.basic",
        .format_id = "basic.qbasic-source",
    }};
    var resolution: r4os.subsystem_catalog.Resolution = .{};
    r4os.subsystem_catalog.resolve(r4std.subsystem_runtime.catalog(), inspection.input, .{ .user_associations = &associations }, &resolution) catch return self.headlessSubsystemLaunchFailure("r4basic-resolve");
    const target = resolution.selected() orelse return self.headlessSubsystemLaunchFailure("r4basic-handler");
    const resolve_end_ns = self.ctx.sys.monotonicNanoseconds() orelse return self.headlessSubsystemLaunchFailure("r4basic-resolve-clock");
    if (!equalsIgnoreCase(target.subsystem_id, "r4os.basic") or
        !equalsIgnoreCase(target.format_id, "basic.qbasic-source") or
        !equalsIgnoreCase(target.host_path, r4basic_host_path) or
        !r4std.subsystem_runtime.hostPresent(&self.ctx.sys, target.host_path))
    {
        return self.headlessSubsystemLaunchFailure("r4basic-target");
    }
    if (inspection.access.info_calls != 1 or inspection.access.read_calls != 0 or inspection.access.read_bytes != 0 or
        r4os.subsystem_catalog.max_probe_bytes != 256 * 1024)
    {
        return self.headlessSubsystemLaunchFailure("r4basic-source-probe");
    }

    var trace_id: [16]u8 = undefined;
    writeR4BasicTraceId(&trace_id, start_ns);
    var phases_storage: [64]u8 = undefined;
    const desktop_ns = self.ctx.sys.monotonicNanoseconds() orelse return self.headlessSubsystemLaunchFailure("r4basic-host-clock");
    const phases = std.fmt.bufPrint(phases_storage[0..], "{d},{d},{d}", .{
        probe_end_ns -| start_ns,
        resolve_end_ns -| start_ns,
        desktop_ns -| start_ns,
    }) catch return self.headlessSubsystemLaunchFailure("r4basic-timeline");
    const options = [_]r4os.subsystem_launch.Option{
        .{ .key = r4os.subsystem_launch.trace_key, .value = trace_id[0..] },
        .{ .key = r4os.subsystem_launch.trace_mode_key, .value = r4os.subsystem_launch.trace_mode_headless },
        .{ .key = r4os.subsystem_launch.trace_phases_key, .value = phases },
    };
    var args_storage: [r4os.subsystem_launch.max_args_bytes + 1]u8 = .{0} ** (r4os.subsystem_launch.max_args_bytes + 1);
    const args = r4os.subsystem_launch.encode(r4basic_baseline_guest_path, &options, args_storage[0..r4os.subsystem_launch.max_args_bytes]) catch return self.headlessSubsystemLaunchFailure("r4basic-args");
    const index = self.findFreeAppWindow() orelse return self.headlessSubsystemLaunchFailure("r4basic-window-slot");
    var path_z: [window_launch_path_max + 1]u8 = .{0} ** (window_launch_path_max + 1);
    var title_z: [console_title_max + 1]u8 = .{0} ** (console_title_max + 1);
    copySliceZ(path_z[0..], target.host_path);
    copySliceZ(title_z[0..], target.display_name);
    self.launchGuiPath(zptr(path_z[0..]), zptr(args_storage[0 .. args.len + 1]), zptr(title_z[0..]), .gui);
    const handle = self.check.handles[index];
    if (!processHandleValid(handle)) return self.headlessSubsystemLaunchFailure("r4basic-program-spawn");
    return .{ .index = index, .handle = handle };
}

pub fn launchHeadlessR4GbHostSelfTest(self: *Controller) ?HeadlessSubsystemLaunch {
    if (!r4std.subsystem_runtime.hostPresent(&self.ctx.sys, r4gb_host_path)) return self.headlessSubsystemLaunchFailure("r4gb-host-missing");
    const index = self.findFreeAppWindow() orelse return self.headlessSubsystemLaunchFailure("r4gb-window-slot");
    self.launchGuiPath(r4gb_host_path, "/HOSTTEST", "R4GB host selftest", .gui);
    const handle = self.check.handles[index];
    if (!processHandleValid(handle)) return self.headlessSubsystemLaunchFailure("r4gb-program-spawn");
    return .{ .index = index, .handle = handle };
}

pub fn smokeR4GbProductPath(self: *Controller) bool {
    const first = self.launchHeadlessR4GbGuest(r4gb_fixture_a_path, r4gb_trace_a, "witness") orelse return false;
    const second = self.launchHeadlessR4GbGuest(r4gb_fixture_b_path, r4gb_trace_b, "close") orelse return false;
    if (first.index == second.index or sameProcessHandle(first.handle, second.handle)) return self.headlessSubsystemFailure("r4gb-instance-identity");

    self.toggleMaximizeWindow(first.index);
    self.smokePumpCooperativeFrames(1);
    if (self.failed) return self.headlessSubsystemFailure("controller-transport-or-cancelled");
    if (sameProcessHandle(self.check.handles[first.index], first.handle)) self.toggleMaximizeWindow(first.index);
    self.activateWindow(first.index, false);
    if (!self.pushGuiPhysicalKeyEvent(first.index, r4os.abi.physical_key_usage_right, true) or
        !self.pushGuiPhysicalKeyEvent(first.index, r4os.abi.physical_key_usage_right, false) or
        !self.pushGuiPhysicalKeyEvent(first.index, 0x3E, true))
    {
        return self.headlessSubsystemFailure("r4gb-input-a");
    }
    self.ctx.sleepTicks(ticksFromMs(self.monotonic_hz, 20));
    if (!self.pushGuiPhysicalKeyEvent(first.index, 0x3F, true) or
        !self.pushGuiPhysicalKeyEvent(first.index, 0x41, true)) return self.headlessSubsystemFailure("r4gb-controls-a");

    self.activateWindow(second.index, false);
    if (!self.pushGuiPhysicalKeyEvent(second.index, r4os.abi.physical_key_usage_space, true) or
        !self.pushGuiPhysicalKeyEvent(second.index, r4os.abi.physical_key_usage_space, false) or
        !self.pushGuiPhysicalKeyEvent(second.index, 0x42, true))
    {
        return self.headlessSubsystemFailure("r4gb-input-b");
    }
    self.ctx.sleepTicks(ticksFromMs(self.monotonic_hz, 20));
    if (!self.pushGuiPhysicalKeyEvent(second.index, 0x43, true)) return self.headlessSubsystemFailure("r4gb-controls-b");

    const exercise_started = self.ctx.ticks();
    const exercise_ticks = @as(u64, @max(self.monotonic_hz, 1)) * 60;
    const focus_interval = @as(u64, @max(self.monotonic_hz, 1)) * 10;
    var next_focus = focus_interval;
    var focus_round: u32 = 0;
    const redraws_before = self.render_stats.redraws;
    const lost_frames_before = self.render_stats.present_lost_frames;
    const present_failures_before = self.render_stats.present_failures;
    while (self.ctx.ticks() -| exercise_started < exercise_ticks) {
        if (!sameProcessHandle(self.check.handles[first.index], first.handle) or
            !sameProcessHandle(self.check.handles[second.index], second.handle))
        {
            return self.headlessSubsystemFailure("r4gb-early-exit");
        }
        const elapsed = self.ctx.ticks() -| exercise_started;
        if (elapsed >= next_focus) {
            const target = if ((focus_round & 1) == 0) first.index else second.index;
            const usage = if ((focus_round & 1) == 0) r4os.abi.physical_key_usage_up else r4os.abi.physical_key_usage_space;
            self.activateWindow(target, false);
            if (!self.pushGuiPhysicalKeyEvent(target, usage, true) or !self.pushGuiPhysicalKeyEvent(target, usage, false)) {
                return self.headlessSubsystemFailure("r4gb-longrun-input");
            }
            focus_round +%= 1;
            next_focus +|= focus_interval;
        }
        self.smokePumpCooperativeFrames(1);
        if (self.failed) return self.headlessSubsystemFailure("controller-transport-or-cancelled");
        self.ctx.sleepTicks(1);
    }
    if (focus_round < 5 or self.render_stats.redraws <= redraws_before or
        self.render_stats.present_lost_frames != lost_frames_before or
        self.render_stats.present_failures != present_failures_before)
    {
        return self.headlessSubsystemFailure("r4gb-longrun-desktop");
    }

    // The first original fixture ends from a guest-authored Start+Select
    // witness. This exercises the natural completion path independently
    // from the explicit close used for the second instance.
    self.activateWindow(first.index, false);
    if (!self.pushGuiPhysicalKeyEvent(first.index, r4os.abi.physical_key_usage_enter, true) or
        !self.pushGuiPhysicalKeyEvent(first.index, r4os.abi.physical_key_usage_right_control, true))
    {
        return self.headlessSubsystemFailure("r4gb-witness-input");
    }
    const first_started = self.ctx.ticks();
    const close_timeout_ticks = @as(u64, @max(self.monotonic_hz, 1)) * 30;
    while (sameProcessHandle(self.check.handles[first.index], first.handle)) {
        self.smokePumpCooperativeFrames(1);
        if (self.failed) return self.headlessSubsystemFailure("controller-transport-or-cancelled");
        if (self.ctx.ticks() -| first_started >= close_timeout_ticks) return self.headlessSubsystemFailure("r4gb-witness-a-timeout");
    }
    if (!sameProcessHandle(self.check.handles[second.index], second.handle)) return self.headlessSubsystemFailure("r4gb-close-isolation");
    if (!sameProcessHandle(self.window_completion_handles[first.index], first.handle)) return self.headlessSubsystemFailure("r4gb-completion-a-handle");
    if (self.window_completion_exit_codes[first.index] != 0) return self.headlessSubsystemFailure("r4gb-completion-a-exit");
    if (!self.ctx.exists(r4gb_report_a_path)) return self.headlessSubsystemFailure("r4gb-completion-a-report");

    self.pushGuiEvent(second.index, .close);
    const second_started = self.ctx.ticks();
    while (sameProcessHandle(self.check.handles[second.index], second.handle)) {
        self.smokePumpCooperativeFrames(1);
        if (self.failed) return self.headlessSubsystemFailure("controller-transport-or-cancelled");
        if (self.ctx.ticks() -| second_started >= close_timeout_ticks) return self.headlessSubsystemFailure("r4gb-close-b-timeout");
    }
    if (!sameProcessHandle(self.window_completion_handles[second.index], second.handle)) return self.headlessSubsystemFailure("r4gb-completion-b-handle");
    if (self.window_completion_exit_codes[second.index] != 0) return self.headlessSubsystemFailure("r4gb-completion-b-exit");
    if (!self.ctx.exists(r4gb_report_b_path)) return self.headlessSubsystemFailure("r4gb-completion-b-report");

    const rejected = self.launchHeadlessR4GbGuest(r4gb_fixture_cgb_path, r4gb_trace_cgb, "reject") orelse return false;
    const rejection_ready_started = self.ctx.ticks();
    const rejection_ready_timeout = @as(u64, @max(self.monotonic_hz, 1)) * 10;
    while (!std.mem.startsWith(u8, spanZPtr(self.windows[rejected.index].title()), "R4GB - Cartridgefehler") or
        !self.windows[rejected.index].frame_valid)
    {
        if (!sameProcessHandle(self.check.handles[rejected.index], rejected.handle)) return self.headlessSubsystemFailure("r4gb-rejection-early-exit");
        self.smokePumpCooperativeFrames(1);
        if (self.failed) return self.headlessSubsystemFailure("controller-transport-or-cancelled");
        if (self.ctx.ticks() -| rejection_ready_started >= rejection_ready_timeout) return self.headlessSubsystemFailure("r4gb-rejection-not-visible");
        self.ctx.sleepTicks(1);
    }
    const rejection_visible = self.ctx.ticks();
    const visibility_ticks = ticksFromMs(self.monotonic_hz, 100);
    while (self.ctx.ticks() -| rejection_visible < visibility_ticks) {
        if (!sameProcessHandle(self.check.handles[rejected.index], rejected.handle)) return self.headlessSubsystemFailure("r4gb-rejection-early-exit");
        self.smokePumpCooperativeFrames(1);
        if (self.failed) return self.headlessSubsystemFailure("controller-transport-or-cancelled");
        self.ctx.sleepTicks(1);
    }
    if (self.requestWindowProcessClose(rejected.index) != r4os.abi.program_handle_ok) return self.headlessSubsystemFailure("r4gb-rejection-close-request");
    // Mark the close as user-requested without arming Desktop's 200 ms
    // forced-kill timer; the test below owns its longer bounded timeout.
    // The admitted diagnostic origin keeps error-window cleanup with this parent.
    self.pushGuiEvent(rejected.index, .close);
    const rejection_started = self.ctx.ticks();
    while (sameProcessHandle(self.check.handles[rejected.index], rejected.handle)) {
        self.smokePumpCooperativeFrames(1);
        if (self.failed) return self.headlessSubsystemFailure("controller-transport-or-cancelled");
        if (self.ctx.ticks() -| rejection_started >= close_timeout_ticks) return self.headlessSubsystemFailure("r4gb-rejection-timeout");
    }
    if (!sameProcessHandle(self.window_completion_handles[rejected.index], rejected.handle) or
        self.window_completion_exit_codes[rejected.index] != r4gb_cgb_rejection_exit or
        !self.ctx.exists(r4gb_report_cgb_path))
    {
        return self.headlessSubsystemFailure("r4gb-rejection-result");
    }
    return true;
}

pub fn launchHeadlessR4GbGuest(self: *Controller, guest_path: []const u8, trace_id: []const u8, expected_end: []const u8) ?HeadlessSubsystemLaunch {
    var inspection = r4std.subsystem_runtime.inspect(&self.ctx.sys, guest_path) catch return self.headlessSubsystemLaunchFailure("r4gb-inspect");
    const metadata_input = inspection.input;
    const probed_input = r4std.subsystem_runtime.completeProbe(&self.ctx.sys, metadata_input, &inspection.access) catch return self.headlessSubsystemLaunchFailure("r4gb-probe");
    if (inspection.access.info_calls != 1 or inspection.access.read_calls == 0 or
        inspection.access.read_bytes == 0 or inspection.access.read_bytes > r4os.subsystem_catalog.max_probe_bytes)
    {
        return self.headlessSubsystemLaunchFailure("r4gb-probe-bounds");
    }
    var probed: r4os.subsystem_catalog.Resolution = .{};
    r4os.subsystem_catalog.resolve(r4std.subsystem_runtime.catalog(), probed_input, .{}, &probed) catch return self.headlessSubsystemLaunchFailure("r4gb-probe-resolve");
    const probe_target = probed.selected() orelse return self.headlessSubsystemLaunchFailure("r4gb-probe-target");
    if (!equalsIgnoreCase(probe_target.subsystem_id, "r4os.gb") or
        !equalsIgnoreCase(probe_target.format_id, "gameboy.dmg-cartridge") or
        probe_target.evidence != .confirmed_probe)
    {
        return self.headlessSubsystemLaunchFailure("r4gb-probe-identity");
    }

    var args_storage: [r4os.subsystem_launch.max_args_bytes]u8 = undefined;
    var resolution: r4std.file_handler.Resolution = .{};
    r4std.file_handler.resolve(&self.assoc, r4std.subsystem_runtime.catalog(), metadata_input, args_storage[0..], &resolution) catch return self.headlessSubsystemLaunchFailure("r4gb-assoc-resolve");
    const target = resolution.target orelse return self.headlessSubsystemLaunchFailure("r4gb-assoc-target");
    if (target.kind != .subsystem or !equalsIgnoreCase(target.handler_id, "r4os.gb") or
        !equalsIgnoreCase(target.format_id, "gameboy.dmg-cartridge") or
        !equalsIgnoreCase(target.app_path, r4gb_host_path))
    {
        return self.headlessSubsystemLaunchFailure("r4gb-assoc-identity");
    }
    const request = r4os.subsystem_launch.parse(target.args) catch return self.headlessSubsystemLaunchFailure("r4gb-request");
    if (!equalsIgnoreCase(request.guest_path, guest_path)) return self.headlessSubsystemLaunchFailure("r4gb-guest-identity");

    var choices: r4std.file_handler.ChoiceList = .{};
    var choice_access: r4std.subsystem_runtime.AccessStats = .{};
    r4std.file_handler.collectPathChoices(&self.ctx.sys, &self.assoc, r4std.subsystem_runtime.catalog(), guest_path, &choices, &choice_access) catch return self.headlessSubsystemLaunchFailure("r4gb-open-with");
    if (choice_access.info_calls != 1 or choice_access.read_calls != 0 or choice_access.read_bytes != 0) return self.headlessSubsystemLaunchFailure("r4gb-open-with-probe");
    var found = false;
    for (choices.slice()) |choice| if (choice.kind == .subsystem and
        equalsIgnoreCase(choice.handler_id, "r4os.gb") and equalsIgnoreCase(choice.format_id, "gameboy.dmg-cartridge"))
    {
        found = true;
    };
    if (!found) return self.headlessSubsystemLaunchFailure("r4gb-open-with-choice");

    const options = [_]r4os.subsystem_launch.Option{
        .{ .key = r4os.subsystem_launch.trace_key, .value = trace_id },
        .{ .key = r4os.subsystem_launch.trace_mode_key, .value = r4os.subsystem_launch.trace_mode_headless },
        .{ .key = r4gb_trace_end_key, .value = expected_end },
    };
    var traced_storage: [r4os.subsystem_launch.max_args_bytes + 1]u8 = .{0} ** (r4os.subsystem_launch.max_args_bytes + 1);
    const traced = r4os.subsystem_launch.encode(guest_path, &options, traced_storage[0..r4os.subsystem_launch.max_args_bytes]) catch return self.headlessSubsystemLaunchFailure("r4gb-trace-args");
    const index = self.findFreeAppWindow() orelse return self.headlessSubsystemLaunchFailure("r4gb-window-slot");
    var path_z: [window_launch_path_max + 1]u8 = .{0} ** (window_launch_path_max + 1);
    var title_z: [console_title_max + 1]u8 = .{0} ** (console_title_max + 1);
    copySliceZ(path_z[0..], target.app_path);
    copySliceZ(title_z[0..], target.title);
    self.launchGuiPath(zptr(path_z[0..]), zptr(traced_storage[0 .. traced.len + 1]), zptr(title_z[0..]), .gui);
    const handle = self.check.handles[index];
    if (!processHandleValid(handle)) return self.headlessSubsystemLaunchFailure("r4gb-product-spawn");
    return .{ .index = index, .handle = handle };
}

pub fn launchHeadlessR4SnesHostSelfTest(self: *Controller) ?HeadlessSubsystemLaunch {
    if (!r4std.subsystem_runtime.hostPresent(&self.ctx.sys, r4snes_host_path)) return self.headlessSubsystemLaunchFailure("r4snes-host-missing");
    const index = self.findFreeAppWindow() orelse return self.headlessSubsystemLaunchFailure("r4snes-window-slot");
    self.launchGuiPath(r4snes_host_path, "/HOSTTEST", "R4SNES fixture generator", .gui);
    const handle = self.check.handles[index];
    if (!processHandleValid(handle)) return self.headlessSubsystemLaunchFailure("r4snes-program-spawn");
    return .{ .index = index, .handle = handle };
}

pub fn smokeR4SnesProductPath(self: *Controller) bool {
    const first = self.launchHeadlessR4SnesGuest(r4snes_fixture_a_path, r4snes_trace_a, "witness") orelse return false;
    const second = self.launchHeadlessR4SnesGuest(r4snes_fixture_b_path, r4snes_trace_b, "close") orelse return false;
    if (first.index == second.index or sameProcessHandle(first.handle, second.handle)) return self.headlessSubsystemFailure("r4snes-instance-identity");

    self.toggleMaximizeWindow(first.index);
    self.smokePumpCooperativeFrames(1);
    if (self.failed) return self.headlessSubsystemFailure("controller-transport-or-cancelled");
    if (sameProcessHandle(self.check.handles[first.index], first.handle)) self.toggleMaximizeWindow(first.index);
    self.activateWindow(first.index, false);
    const first_keys = [_]u32{
        r4os.abi.physical_key_usage_up,
        r4os.abi.physical_key_usage_right,
        r4os.abi.physical_key_usage_keypad_8,
        r4os.abi.physical_key_usage_keypad_6,
    };
    for (first_keys) |usage| if (!self.pushGuiPhysicalKeyEvent(first.index, usage, true)) {
        return self.headlessSubsystemFailure("r4snes-input-a-down");
    };
    var held_started = self.ctx.ticks();
    const held_ticks = ticksFromMs(self.monotonic_hz, 250);
    while (self.ctx.ticks() -| held_started < held_ticks) {
        self.smokePumpCooperativeFrames(1);
        if (self.failed) return self.headlessSubsystemFailure("controller-transport-or-cancelled");
        self.ctx.sleepTicks(1);
    }
    for (first_keys) |usage| if (!self.pushGuiPhysicalKeyEvent(first.index, usage, false)) {
        return self.headlessSubsystemFailure("r4snes-input-a-up");
    };
    if (!self.pushGuiPhysicalKeyEvent(first.index, 0x3E, true)) return self.headlessSubsystemFailure("r4snes-pause");
    self.ctx.sleepTicks(ticksFromMs(self.monotonic_hz, 20));
    if (!self.pushGuiPhysicalKeyEvent(first.index, 0x3F, true) or
        !self.pushGuiPhysicalKeyEvent(first.index, 0x41, true) or
        !self.pushGuiPhysicalKeyEvent(first.index, 0x42, true))
    {
        return self.headlessSubsystemFailure("r4snes-lifecycle-a");
    }
    self.ctx.sleepTicks(ticksFromMs(self.monotonic_hz, 20));
    if (!self.pushGuiPhysicalKeyEvent(first.index, 0x43, true)) return self.headlessSubsystemFailure("r4snes-unmute");

    self.activateWindow(second.index, false);
    const second_keys = [_]u32{
        r4os.abi.physical_key_usage_down,
        r4os.abi.physical_key_usage_left,
        r4os.abi.physical_key_usage_keypad_2,
        r4os.abi.physical_key_usage_keypad_4,
        r4os.abi.physical_key_usage_keypad_7,
        r4os.abi.physical_key_usage_keypad_9,
    };
    for (second_keys) |usage| if (!self.pushGuiPhysicalKeyEvent(second.index, usage, true)) {
        return self.headlessSubsystemFailure("r4snes-input-b-down");
    };
    held_started = self.ctx.ticks();
    while (self.ctx.ticks() -| held_started < held_ticks) {
        self.smokePumpCooperativeFrames(1);
        if (self.failed) return self.headlessSubsystemFailure("controller-transport-or-cancelled");
        self.ctx.sleepTicks(1);
    }
    // Keep B held across the long run.  On a slow host the cartridge may
    // still be uploading its SPC program during the short initial hold;
    // the persistent physical state must therefore remain observable at
    // a later controller latch.  All other buttons are released now.
    for (second_keys) |usage| {
        if (usage == r4os.abi.physical_key_usage_keypad_2) continue;
        if (!self.pushGuiPhysicalKeyEvent(second.index, usage, false)) {
            return self.headlessSubsystemFailure("r4snes-input-b-up");
        }
    }

    const presentation = @import("desktop_replay_check.zig");
    const before_output = presentation.presentationSample(self.app, &self.check, 0) catch |err| {
        self.check.out.unavailable("SUBSYSTEM-PRESENTATION", @errorName(err));
        return self.headlessSubsystemFailure("r4snes-presentation-before");
    };
    const exercise_started = self.ctx.ticks();
    const exercise_ticks = @as(u64, @max(self.monotonic_hz, 1)) * 60;
    const focus_interval = @as(u64, @max(self.monotonic_hz, 1)) * 10;
    var next_focus = focus_interval;
    var focus_round: u32 = 0;
    var witness_input_sent = false;
    var first_completed = false;
    const redraws_before = self.render_stats.redraws;
    const lost_frames_before = self.render_stats.present_lost_frames;
    const present_failures_before = self.render_stats.present_failures;
    while (self.ctx.ticks() -| exercise_started < exercise_ticks) {
        if (!sameProcessHandle(self.check.handles[first.index], first.handle) and !first_completed) {
            // The first guest can finish its full60 guest seconds just
            // before this controller's later60-second wall interval ends.
            // Exact identity, successful self-report and all work remain
            // required; the independent second instance must stay alive.
            if (!sameProcessHandle(self.window_completion_handles[first.index], first.handle) or
                self.window_completion_exit_codes[first.index] != 0 or !self.ctx.exists(r4snes_report_a_path))
                return self.headlessSubsystemFailure("r4snes-early-exit");
            first_completed = true;
        }
        if (!sameProcessHandle(self.check.handles[second.index], second.handle))
            return self.headlessSubsystemFailure("r4snes-early-exit");
        const elapsed = self.ctx.ticks() -| exercise_started;
        if (elapsed >= next_focus) {
            const target = if ((focus_round & 1) == 0) first.index else second.index;
            const usage = if ((focus_round & 1) == 0)
                r4os.abi.physical_key_usage_keypad_8
            else
                r4os.abi.physical_key_usage_keypad_2;
            self.activateWindow(target, false);
            // D2 keeps B down for its complete focus interval.  The next
            // focus loss releases all guest buttons by contract; an
            // instantaneous press/release could otherwise fall between
            // two controller latches on a slower emulation host.
            const keep_held = target == second.index;
            if (!self.pushGuiPhysicalKeyEvent(target, usage, true) or
                (!keep_held and !self.pushGuiPhysicalKeyEvent(target, usage, false)))
            {
                return self.headlessSubsystemFailure("r4snes-longrun-input");
            }
            // Arm the guest-ROM witness during the final A focus interval,
            // while CPU time can still advance. Sending it only after60s
            // races the deliberately frozen target on a caught-up host.
            if (target == first.index and elapsed >= exercise_ticks - focus_interval) {
                if (!self.pushGuiPhysicalKeyEvent(first.index, r4os.abi.physical_key_usage_enter, true) or
                    !self.pushGuiPhysicalKeyEvent(first.index, r4os.abi.physical_key_usage_right_control, true))
                    return self.headlessSubsystemFailure("r4snes-witness-input");
                witness_input_sent = true;
            }
            focus_round +%= 1;
            next_focus +|= focus_interval;
        }
        self.smokePumpCooperativeFrames(1);
        if (self.failed) return self.headlessSubsystemFailure("controller-transport-or-cancelled");
        self.ctx.sleepTicks(1);
    }
    const after_output = presentation.presentationSample(self.app, &self.check, 1) catch |err| {
        self.check.out.unavailable("SUBSYSTEM-PRESENTATION", @errorName(err));
        return self.headlessSubsystemFailure("r4snes-presentation-after");
    };
    const output_progress = @import("desktop_owner_report.zig").progress(before_output, after_output) catch |err| {
        self.check.out.unavailable("SUBSYSTEM-PRESENTATION", @errorName(err));
        return self.headlessSubsystemFailure("r4snes-presentation-progress");
    };
    self.check.out.record("presentation-progress", "SUBSYSTEM", 0, .{
        .contract = @as([]const u8, "same-owner-native-receipts-or-original-cpu-v1"),
        .mode = @tagName(output_progress),
        .focus_rounds = focus_round,
        .cpu_redraws_before = redraws_before,
        .cpu_redraws_after = self.render_stats.redraws,
        .cpu_lost_before = lost_frames_before,
        .cpu_lost_after = self.render_stats.present_lost_frames,
        .cpu_failures_before = present_failures_before,
        .cpu_failures_after = self.render_stats.present_failures,
        .physical_visibility = @as(?bool, null),
    });
    if (focus_round < 5 or (output_progress == .cpu and self.render_stats.redraws <= redraws_before) or
        self.render_stats.present_lost_frames != lost_frames_before or
        self.render_stats.present_failures != present_failures_before)
    {
        return self.headlessSubsystemFailure("r4snes-longrun-desktop");
    }

    if (!witness_input_sent) return self.headlessSubsystemFailure("r4snes-witness-input");
    const first_started = self.ctx.ticks();
    // A TCG-only host can be slower than the 21.477272-MHz guest. The
    // product guest freezes its marked 60-second target and drains bounded
    // clock debt without extending guest time; leave enough wall time for
    // that deterministic catch-up while continuing to pump the desktop.
    const close_timeout_ticks = @as(u64, @max(self.monotonic_hz, 1)) * 480;
    while (sameProcessHandle(self.check.handles[first.index], first.handle)) {
        self.smokePumpCooperativeFrames(1);
        if (self.failed) return self.headlessSubsystemFailure("controller-transport-or-cancelled");
        self.ctx.sleepTicks(1);
        if (self.ctx.ticks() -| first_started >= close_timeout_ticks) return self.headlessSubsystemFailure("r4snes-witness-timeout");
    }
    if (!sameProcessHandle(self.check.handles[second.index], second.handle)) return self.headlessSubsystemFailure("r4snes-close-isolation");
    if (!sameProcessHandle(self.window_completion_handles[first.index], first.handle) or
        self.window_completion_exit_codes[first.index] != 0 or !self.ctx.exists(r4snes_report_a_path))
    {
        return self.headlessSubsystemFailure("r4snes-completion-a");
    }

    // D1 deliberately performs a reset and can finish a fraction of a
    // guest second before D2 on a single-vCPU TCG host.  Keep D2 alive and
    // focused for a bounded five-second settling interval: this drains its
    // already frozen 60-second clock debt and samples a physical button
    // after the cartridge's SPC upload, before testing the separate close.
    self.activateWindow(second.index, false);
    if (!self.pushGuiPhysicalKeyEvent(second.index, r4os.abi.physical_key_usage_keypad_2, true)) {
        return self.headlessSubsystemFailure("r4snes-settle-input-down");
    }
    const settle_started = self.ctx.ticks();
    const settle_ticks = @as(u64, @max(self.monotonic_hz, 1)) * 5;
    while (self.ctx.ticks() -| settle_started < settle_ticks) {
        if (!sameProcessHandle(self.check.handles[second.index], second.handle)) {
            return self.headlessSubsystemFailure("r4snes-settle-isolation");
        }
        self.smokePumpCooperativeFrames(1);
        if (self.failed) return self.headlessSubsystemFailure("controller-transport-or-cancelled");
        self.ctx.sleepTicks(1);
    }
    if (!self.pushGuiPhysicalKeyEvent(second.index, r4os.abi.physical_key_usage_keypad_2, false)) {
        return self.headlessSubsystemFailure("r4snes-settle-input-up");
    }

    self.pushGuiEvent(second.index, .close);
    const second_started = self.ctx.ticks();
    while (sameProcessHandle(self.check.handles[second.index], second.handle)) {
        self.smokePumpCooperativeFrames(1);
        if (self.failed) return self.headlessSubsystemFailure("controller-transport-or-cancelled");
        self.ctx.sleepTicks(1);
        if (self.ctx.ticks() -| second_started >= close_timeout_ticks) return self.headlessSubsystemFailure("r4snes-close-b-timeout");
    }
    if (!sameProcessHandle(self.window_completion_handles[second.index], second.handle) or
        self.window_completion_exit_codes[second.index] != 0 or !self.ctx.exists(r4snes_report_b_path))
    {
        return self.headlessSubsystemFailure("r4snes-completion-b");
    }

    if (!self.smokeR4SnesRejection(
        r4snes_fixture_invalid_path,
        r4snes_trace_invalid,
        "reject-invalid",
        "R4SNES - Cartridgefehler",
        r4snes_invalid_exit,
        r4snes_report_invalid_path,
        "r4snes-invalid",
    )) return false;
    return self.smokeR4SnesRejection(
        r4snes_fixture_firmware_path,
        r4snes_trace_firmware,
        "reject-firmware",
        "R4SNES - Firmwarefehler",
        r4snes_firmware_exit,
        r4snes_report_firmware_path,
        "r4snes-firmware",
    );
}

pub fn smokeR4SnesRejection(
    self: *Controller,
    guest_path: []const u8,
    trace_id: []const u8,
    expected_end: []const u8,
    expected_title: []const u8,
    expected_exit: i32,
    report_path: [*:0]const u8,
    comptime reason: []const u8,
) bool {
    const rejected = self.launchHeadlessR4SnesGuest(guest_path, trace_id, expected_end) orelse return false;
    const ready_started = self.ctx.ticks();
    const ready_timeout = @as(u64, @max(self.monotonic_hz, 1)) * 10;
    while (!std.mem.startsWith(u8, spanZPtr(self.windows[rejected.index].title()), expected_title) or
        !self.windows[rejected.index].frame_valid)
    {
        if (!sameProcessHandle(self.check.handles[rejected.index], rejected.handle)) return self.headlessSubsystemFailure(reason ++ "-early-exit");
        self.smokePumpCooperativeFrames(1);
        if (self.failed) return self.headlessSubsystemFailure("controller-transport-or-cancelled");
        if (self.ctx.ticks() -| ready_started >= ready_timeout) return self.headlessSubsystemFailure(reason ++ "-not-visible");
        self.ctx.sleepTicks(1);
    }
    const visible_started = self.ctx.ticks();
    const visibility_ticks = ticksFromMs(self.monotonic_hz, 100);
    while (self.ctx.ticks() -| visible_started < visibility_ticks) {
        if (!sameProcessHandle(self.check.handles[rejected.index], rejected.handle)) return self.headlessSubsystemFailure(reason ++ "-early-exit");
        self.smokePumpCooperativeFrames(1);
        if (self.failed) return self.headlessSubsystemFailure("controller-transport-or-cancelled");
        self.ctx.sleepTicks(1);
    }
    if (self.requestWindowProcessClose(rejected.index) != r4os.abi.program_handle_ok) return self.headlessSubsystemFailure(reason ++ "-close-request");
    // The admitted diagnostic origin keeps error-window cleanup with this parent.
    self.pushGuiEvent(rejected.index, .close);
    const close_started = self.ctx.ticks();
    const close_timeout = @as(u64, @max(self.monotonic_hz, 1)) * 30;
    while (sameProcessHandle(self.check.handles[rejected.index], rejected.handle)) {
        self.smokePumpCooperativeFrames(1);
        if (self.failed) return self.headlessSubsystemFailure("controller-transport-or-cancelled");
        if (self.ctx.ticks() -| close_started >= close_timeout) return self.headlessSubsystemFailure(reason ++ "-timeout");
    }
    if (!sameProcessHandle(self.window_completion_handles[rejected.index], rejected.handle) or
        self.window_completion_exit_codes[rejected.index] != expected_exit or !self.ctx.exists(report_path))
    {
        return self.headlessSubsystemFailure(reason ++ "-result");
    }
    return true;
}

pub fn launchHeadlessR4SnesGuest(self: *Controller, guest_path: []const u8, trace_id: []const u8, expected_end: []const u8) ?HeadlessSubsystemLaunch {
    const inspection = r4std.subsystem_runtime.inspect(&self.ctx.sys, guest_path) catch return self.headlessSubsystemLaunchFailure("r4snes-inspect");
    const metadata_input = inspection.input;
    if (inspection.access.info_calls != 1 or inspection.access.read_calls != 0 or inspection.access.read_bytes != 0) {
        return self.headlessSubsystemLaunchFailure("r4snes-probe-bounds");
    }
    var probed: r4os.subsystem_catalog.Resolution = .{};
    r4os.subsystem_catalog.resolve(r4std.subsystem_runtime.catalog(), metadata_input, .{}, &probed) catch return self.headlessSubsystemLaunchFailure("r4snes-probe-resolve");
    const probe_target = probed.selected() orelse return self.headlessSubsystemLaunchFailure("r4snes-probe-target");
    if (!equalsIgnoreCase(probe_target.subsystem_id, "r4os.snes") or
        !equalsIgnoreCase(probe_target.format_id, "snes.cartridge") or
        probe_target.evidence != .extension)
    {
        return self.headlessSubsystemLaunchFailure("r4snes-probe-identity");
    }

    var args_storage: [r4os.subsystem_launch.max_args_bytes]u8 = undefined;
    var resolution: r4std.file_handler.Resolution = .{};
    r4std.file_handler.resolve(&self.assoc, r4std.subsystem_runtime.catalog(), metadata_input, args_storage[0..], &resolution) catch return self.headlessSubsystemLaunchFailure("r4snes-assoc-resolve");
    const target = resolution.target orelse return self.headlessSubsystemLaunchFailure("r4snes-assoc-target");
    if (target.kind != .subsystem or !equalsIgnoreCase(target.handler_id, "r4os.snes") or
        !equalsIgnoreCase(target.format_id, "snes.cartridge") or
        !equalsIgnoreCase(target.app_path, r4snes_host_path))
    {
        return self.headlessSubsystemLaunchFailure("r4snes-assoc-identity");
    }
    const request = r4os.subsystem_launch.parse(target.args) catch return self.headlessSubsystemLaunchFailure("r4snes-request");
    if (!equalsIgnoreCase(request.guest_path, guest_path)) return self.headlessSubsystemLaunchFailure("r4snes-guest-identity");

    var choices: r4std.file_handler.ChoiceList = .{};
    var choice_access: r4std.subsystem_runtime.AccessStats = .{};
    r4std.file_handler.collectPathChoices(&self.ctx.sys, &self.assoc, r4std.subsystem_runtime.catalog(), guest_path, &choices, &choice_access) catch return self.headlessSubsystemLaunchFailure("r4snes-open-with");
    if (choice_access.info_calls != 1 or choice_access.read_calls != 0 or choice_access.read_bytes != 0) return self.headlessSubsystemLaunchFailure("r4snes-open-with-probe");
    var found = false;
    for (choices.slice()) |choice| if (choice.kind == .subsystem and
        equalsIgnoreCase(choice.handler_id, "r4os.snes") and equalsIgnoreCase(choice.format_id, "snes.cartridge"))
    {
        found = true;
    };
    if (!found) return self.headlessSubsystemLaunchFailure("r4snes-open-with-choice");

    const options = [_]r4os.subsystem_launch.Option{
        .{ .key = r4os.subsystem_launch.trace_key, .value = trace_id },
        .{ .key = r4os.subsystem_launch.trace_mode_key, .value = r4os.subsystem_launch.trace_mode_headless },
        .{ .key = r4snes_trace_end_key, .value = expected_end },
    };
    var traced_storage: [r4os.subsystem_launch.max_args_bytes + 1]u8 = .{0} ** (r4os.subsystem_launch.max_args_bytes + 1);
    const traced = r4os.subsystem_launch.encode(guest_path, &options, traced_storage[0..r4os.subsystem_launch.max_args_bytes]) catch return self.headlessSubsystemLaunchFailure("r4snes-trace-args");
    const index = self.findFreeAppWindow() orelse return self.headlessSubsystemLaunchFailure("r4snes-window-slot");
    var path_z: [window_launch_path_max + 1]u8 = .{0} ** (window_launch_path_max + 1);
    var title_z: [console_title_max + 1]u8 = .{0} ** (console_title_max + 1);
    copySliceZ(path_z[0..], target.app_path);
    copySliceZ(title_z[0..], target.title);
    self.launchGuiPath(zptr(path_z[0..]), zptr(traced_storage[0 .. traced.len + 1]), zptr(title_z[0..]), .gui);
    const handle = self.check.handles[index];
    if (!processHandleValid(handle)) return self.headlessSubsystemLaunchFailure("r4snes-product-spawn");
    return .{ .index = index, .handle = handle };
}

pub fn headlessSubsystemFailure(self: *Controller, comptime reason: []const u8) bool {
    self.check.out.record("failure", "SUBSYSTEM", 0, .{ .stage = reason });
    // The original failure is already recorded. Inspect this exact live host
    // once before cleanup, without replaying an action or extending its work
    // deadline. The existing copied report owns its normal exact-file cleanup.
    if (!self.failure_owner_attempted) {
        self.failure_owner_attempted = true;
        if (self.check.session and self.check.desktop.valid() and
            !self.ctx.sys.programShouldClose() and self.ctx.ticks() < self.check.deadline)
        {
            for (self.check.replay_reports, 0..) |owned, sequence| {
                if (owned) continue;
                @import("desktop_replay_check.zig").reportOwner(self.app, &self.check, sequence) catch |err| {
                    self.check.out.unavailable("SUBSYSTEM-OWNER", @errorName(err));
                };
                break;
            }
        }
    }
    if (self.ctx.exists(subsystem_host_test_marker_path)) return false;
    const marker = "SUBSYSTEM runtime bootstrap FAILED: " ++ reason ++ "\r\n";
    _ = self.ctx.fileWrite(subsystem_host_test_marker_path, marker);
    return false;
}

pub fn headlessSubsystemLaunchFailure(self: *Controller, comptime reason: []const u8) ?HeadlessSubsystemLaunch {
    _ = self.headlessSubsystemFailure(reason);
    return null;
}

pub fn waitForHeadlessSubsystemAudio(self: *Controller) bool {
    const started = self.ctx.ticks();
    const timeout_ticks = @as(u64, @max(self.monotonic_hz, 1)) * 5;
    while (self.ctx.ticks() -| started < timeout_ticks) {
        var info: r4os.abi.ServiceInfo = .{};
        if (self.ctx.sys.serviceOpen(subsystem_audio_service, &info) == r4os.abi.service_api_result_ok and info.handle != 0) {
            _ = self.ctx.sys.serviceClose(info.handle);
            return true;
        }
        self.ctx.sleepTicks(1);
    }
    return false;
}

pub fn writeHeadlessSubsystemMarker(self: *Controller) bool {
    if (self.failed) return self.headlessSubsystemFailure("controller-transport");
    // No old private render/cache statistics are manufactured by the caller.
    return self.ctx.fileWrite(subsystem_host_test_marker_path, subsystem_host_test_marker) == subsystem_host_test_marker.len;
}
fn sameProcessHandle(a: r4os.abi.ProgramProcessHandle, b: r4os.abi.ProgramProcessHandle) bool {
    return a.instance_id != 0 and a.instance_id == b.instance_id and a.generation == b.generation;
}
fn processHandleValid(value: r4os.abi.ProgramProcessHandle) bool {
    return value.instance_id != 0 and value.generation != 0;
}
fn equalsIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}
fn spanZPtr(value: [*:0]const u8) []const u8 {
    return std.mem.span(value);
}
fn copySliceZ(out: []u8, value: []const u8) void {
    @memset(out, 0);
    const length = @min(value.len, out.len - 1);
    @memcpy(out[0..length], value[0..length]);
}
fn zptr(value: []const u8) [*:0]const u8 {
    return @ptrCast(value.ptr);
}
fn ticksFromMs(hz: u32, ms: u64) u64 {
    return @max(1, (ms * hz + 999) / 1000);
}
fn writeR4BasicTraceId(out: *[16]u8, value: u64) void {
    const hex = "0123456789ABCDEF";
    for (out, 0..) |*byte, index| {
        const shift: u6 = @intCast((15 - index) * 4);
        byte.* = hex[@as(u4, @truncate(value >> shift))];
    }
}
