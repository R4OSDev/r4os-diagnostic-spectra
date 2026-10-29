//! Three explicit productive owner snapshots around the original two-window
//! work. No synthetic scene, forced frame, polling loop or timer adjustment.
const std = @import("std");
const r = @import("r4os");
const wire = @import("desktop_check");
const Check = @import("desktop_check.zig").Check;
const Status = @import("desktop_image_case").NativeStatus;
pub const child_argument = Status.child_argument;
pub fn child(app: *r.App) i32 {
    const ticket = Status.parse(app.args()) catch return 2;
    var buffer: [128:0]u8 = undefined;
    const path = Status.path(&buffer, ticket) catch return 2;
    // Parent created this exact path before Spawn. A missing claim is not
    // permission to create an unowned report or fall back to GUI stdout.
    if (!app.system().exists(path)) return 2;
    return @import("desktop_image_case").nativeProducer(app, path);
}
fn nativeReport(app: *r.App, check: *Check, owner: r.abi.ProgramProcessHandle) !bool {
    const allocator = app.allocator() orelse return error.AllocatorMissing;
    const bytes = try @import("desktop_bench.zig").readFile(app, &check.native_report);
    defer allocator.free(bytes);
    const identity: Status.Identity = .{ .instance = owner.instance_id, .generation = owner.generation };
    if (!Status.owns(bytes, identity)) return error.NativeImageReportIdentity;
    check.out.message("native-image-child", bytes, false);
    return Status.succeeded(bytes, identity);
}
const owner_report = @import("desktop_owner_report.zig");
const Execution = owner_report.Execution;
const Capture = owner_report.Capture;
const Target = owner_report.Target;
const Report = owner_report.Report;
pub const Sample = struct { target: ?Target = null, execution: Execution, capture: Capture };
pub const Snapshot = [4]?Sample;

pub fn sample(app: *r.App, check: *Check, sequence: usize) !Snapshot {
    const result = try readOwner(app, check, sequence);
    if (result[0] == null) return error.NativeCaptureUnavailable;
    return result;
}
pub fn reportOwner(app: *r.App, check: *Check, sequence: usize) !void {
    _ = try readOwner(app, check, sequence);
}
fn readOwner(app: *r.App, check: *Check, sequence: usize) !Snapshot {
    const observed = try presentationSample(app, check, sequence);
    var result: Snapshot = .{null} ** 4;
    for (observed.owners, 0..) |entry, index| if (entry) |owner| {
        result[index] = .{ .target = owner.target, .execution = owner.execution, .capture = owner.capture orelse return error.CaptureStateWorkerOwned };
    };
    return result;
}
// Same copied report and cleanup ownership as replay, without demanding a CPU
// capture when only the existing provider presentation receipts are required.
pub fn presentationSample(app: *r.App, check: *Check, sequence: usize) !owner_report.Observation {
    if (sequence >= check.replay_reports.len) return error.CaptureSequence;
    var path_buffer: [128:0]u8 = undefined;
    const caller: wire.Identity = .{ .instance = check.caller.instance_id, .generation = check.caller.generation };
    const path = try wire.captureReportPath(&path_buffer, caller, sequence);
    if (check.sys.exists(path)) return error.CaptureReportExists;
    check.replay_reports[sequence] = true; // Ambiguous completion still owns cleanup.
    const old_item = check.request_item;
    check.request_item = sequence;
    defer check.request_item = old_item;
    _ = try check.call(.capture_stats, .{}, 0, 0);
    const allocator = app.allocator() orelse return error.AllocatorMissing;
    const bytes = try @import("desktop_bench.zig").readFile(app, path);
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(Report, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const report = parsed.value;
    if (!std.mem.eql(u8, report.contract, "desktop-capture-owner-v1") or
        report.caller_instance != caller.instance or report.caller_generation != caller.generation or
        report.sequence != sequence or report.outputs.len > 4) return error.CaptureReportIdentity;
    check.out.ownerJson("capture-owner", "DESKTOP", sequence, bytes);
    if (check.out.failed) return error.Output;
    return owner_report.observe(report);
}

pub fn verify(before: Snapshot, after: Snapshot, closed: Snapshot) !void {
    for (before) |entry| {
        const first = entry orelse continue;
        const later = find(after, first) orelse return error.CaptureOwnerChanged;
        const last = find(closed, first) orelse return error.CaptureOwnerChanged;
        if (later.capture.reused_captures <= first.capture.reused_captures or
            later.capture.frame <= first.capture.frame or
            later.execution.completed_frames <= first.execution.completed_frames or
            later.execution.visible_frames <= first.execution.visible_frames) return error.CpuCaptureReuseMissing;
        if (later.capture.captured_reads <= first.capture.captured_reads or
            later.capture.completed_reads <= first.capture.completed_reads or
            later.capture.failed_reads != first.capture.failed_reads) return error.NativeImageReadMissing;
        if (later.capture.asset_misses <= first.capture.asset_misses or
            later.capture.atlas_reused_layers <= first.capture.atlas_reused_layers) return error.AtlasContentReuseMissing;
        if (!last.capture.reads_empty or last.capture.external_receipts != 0 or
            last.capture.captured_reads != last.capture.completed_reads or
            last.capture.failed_reads != first.capture.failed_reads) return error.NativeImageReleaseMissing;
    }
}
fn find(snapshot: Snapshot, owner: Sample) ?Sample {
    for (snapshot) |entry| if (entry) |s| if (s.execution.same(owner.execution) and std.meta.eql(s.target, owner.target)) return s;
    return null;
}

pub fn run(app: *r.App, check: *Check) !void {
    // Keep every original APPDEF/CLOCK oracle. Those classic producers do
    // not supply native BOs. Start a new reservation within the SAME overall
    // deadline, after both originals have actually exited and been reaped.
    _ = try check.call(.end, .{}, 0, 0);
    check.session = false;
    _ = try check.beginSession(.begin);
    const before = try sample(app, check, 0);
    const ticket: Status.Ticket = .{ .parent = .{ .instance = check.caller.instance_id, .generation = check.caller.generation }, .nonce = check.sys.monotonicNanoseconds() orelse return error.Clock };
    const report_path = try Status.path(&check.native_report, ticket);
    if (check.sys.exists(report_path)) return error.NativeImageReportExists;
    check.native_report_owned = true; // Ambiguous writes still own cleanup.
    if (check.sys.fileWrite(report_path, "") != 0) return error.NativeImageReportCreate;
    var arguments: [128:0]u8 = undefined;
    const raw_arguments = try Status.arguments(&arguments, ticket);
    if (check.sys.programSpawnHandle("C:\\R4OS\\SOFTWARE\\TERMINAL\\DIAG\\SPECTRA.R4X", raw_arguments, .gui, &check.handles[0]) != 0) return error.NativeImageSpawn;
    const image_owner = check.handles[0];
    errdefer {
        _ = nativeReport(app, check, image_owner) catch blk: {
            check.out.unavailable("native-image-child", "No exact child-qualified status available before cleanup");
            break :blk false;
        };
        // The original operation is already failed. One distinct copied
        // owner snapshot may expose the exact service failure that preceded
        // recovery. It cannot turn the failed work into a replay/return pass.
        _ = sample(app, check, 1) catch blk: {
            check.out.unavailable("desktop-failure-owner", "No exact post-failure owner snapshot available");
            break :blk @as(Snapshot, .{null} ** 4);
        };
    }
    const target: wire.Identity = .{ .instance = check.handles[0].instance_id, .generation = check.handles[0].generation };
    _ = try check.call(.bind, target, 0, 0);
    const started = check.sys.ticks();
    var done: r.abi.ProgramProcessCompletion = .{};
    while (true) {
        try check.checkDeadline();
        const status = check.sys.programHandleWait(&check.handles[0], check.sys.ticksFromMilliseconds(100), &done);
        if (status == 0) break;
        if (status != r.abi.program_handle_error_timeout or check.sys.ticks() -% started >= check.sys.ticksFromMilliseconds(15000)) return error.NativeImageWait;
    }
    if (!try nativeReport(app, check, image_owner)) return error.NativeImageProducer;
    if (!check.closeChild(0, false)) return error.NativeImageReap;
    try check.pause(300);
    const after = try sample(app, check, 1);
    try check.pause(300);
    const closed = try sample(app, check, 2);
    try verify(before, after, closed);
    check.out.record("capture-replay", "DESKTOP", 0, .{ .cpu_capture_reused = true, .atlas_unrelated_content_reused = true, .native_reads_returned = true, .same_native_owner = true, .native_producer = @as([]const u8, "WINIMAGE fresh child-qualified glyph and two device-local images/GPU fences/Take/Return/reuse/Close"), .physical_visibility = @as(?bool, null) });
}
