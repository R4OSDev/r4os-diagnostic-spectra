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
const Execution = struct {
    device_address: u64,
    device_handle_generation: u64,
    backend_device_generation: u64,
    reset_generation: u64,
    completed_frames: u64,
    visible_frames: u64,
    fn same(self: Execution, other: Execution) bool {
        return self.device_address == other.device_address and
            self.device_handle_generation == other.device_handle_generation and
            self.backend_device_generation == other.backend_device_generation and
            self.reset_generation == other.reset_generation;
    }
};
const Capture = struct {
    frame: u64,
    reused_captures: u64,
    atlas_reused_layers: u64,
    asset_misses: u64,
    captured_reads: u64,
    completed_reads: u64,
    failed_reads: u64,
    reads_empty: bool,
    external_receipts: u64,
};
const Target = struct { adapter_id: u32, connector_id: u32, head_id: u32, device_generation: u64, connection_generation: u64, display_generation: u64 };
const Owner = struct { owner: []const u8, active: bool, target: ?Target, execution: ?Execution, capture: ?Capture };
const Report = struct { contract: []const u8, caller_instance: u32, caller_generation: u64, sequence: u64, outputs: []Owner };
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
    var result: Snapshot = .{null} ** 4;
    var count: usize = 0;
    for (report.outputs) |owner| {
        if (!owner.active or (!std.mem.eql(u8, owner.owner, "native-gr") and
            !std.mem.eql(u8, owner.owner, "primary-native-gr"))) continue;
        result[count] = .{ .target = owner.target, .execution = owner.execution orelse return error.NativeOwnerUnavailable, .capture = owner.capture orelse return error.CaptureStateWorkerOwned };
        count += 1;
    }
    return result;
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
