//! Canonical controller for the retained Test-profile subsystem work. The
//! Desktop only starts this explicit job and later hands off its terminal.
const std = @import("std");
const r = @import("r4os");
const Output = @import("output.zig").Output;
const Controller = @import("subsystem_control.zig").Controller;
const Host = @import("desktop_host_check.zig").Owner;

pub fn run(app: *r.App, args: []const u8, out: *Output) i32 {
    var own_host = false;
    var snes_only = false;
    var options = std.mem.tokenizeAny(u8, args, " \t");
    while (options.next()) |option| {
        if (std.ascii.eqlIgnoreCase(option, "/HOST") and !own_host) own_host = true else if (std.ascii.eqlIgnoreCase(option, "/SNES") and !snes_only) snes_only = true else return 2;
    }
    @import("check_context.zig").emit(app, out, "SUBSYSTEM");
    var host: Host = .{};
    defer if (!host.retired and !host.finish(app.system(), out)) out.unavailable("SUBSYSTEM", "owned host cleanup not acknowledged");
    if (own_host) host.start(app.system()) catch |err| {
        out.unavailable("SUBSYSTEM", @errorName(err));
        out.record("result", "SUBSYSTEM", 0, .{ .exit_code = @as(i32, 1), .success = false, .cleanup_acknowledged = host.finish(app.system(), out) });
        return 1;
    };
    var control = Controller.init(app, out) catch |err| {
        out.unavailable("SUBSYSTEM", @errorName(err));
        failure(app.system(), "SUBSYSTEM runtime bootstrap FAILED: controller-init\r\n");
        return 1;
    };
    const completed = if (snes_only) control.startSnesAcceptance() else control.startHeadlessSubsystemAcceptance();
    const controller_cleaned = control.check.cleanup();
    const host_cleaned = host.finish(app.system(), out);
    const cleaned = controller_cleaned and host_cleaned;
    const host_ok = if (host.exit_code) |code| code == 0 else !own_host;
    const success = completed and !control.failed and cleaned and host_ok and
        (snes_only or control.writeHeadlessSubsystemMarker());
    if (!success) failure(app.system(), "SUBSYSTEM runtime bootstrap FAILED: controller-work-or-cleanup\r\n");
    out.record("result", "SUBSYSTEM", 0, .{ .exit_code = @as(i32, if (success) 0 else 1), .scope = @as([]const u8, if (snes_only) "snes" else "all"), .success = success, .cleanup_acknowledged = cleaned, .desktop_wire_version = @as(u32, 2), .long_run_pair_seconds = @as(u32, 60), .metadata_interval_ms = @as(u32, 50), .snapshot_requests = control.snapshot_requests, .physical_visibility = @as(?bool, null), .cursor_latency_ns = @as(?u64, null) });
    return if (success) 0 else 1;
}

fn failure(sys: r.r4sys.Context, text: []const u8) void {
    // Preserve the first scenario's concrete failure. The Rust starter waits
    // for this process' real completion before starting AUTOEXEC/readback.
    if (!sys.exists("C:\\TEMP\\SUBSYS.OK")) _ = sys.fileWrite("C:\\TEMP\\SUBSYS.OK", text);
}
