//! Real public placement consumer. Only a spawned owned-v1 background instance
//! receives AP admission; the foreground instance verifies its BSP restriction.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const route = @import("../../route.zig");
const worker_prefix = "/PLACEMENTWORKER:";
var system: ?r4os.r4sys.Context = null;
var notification: u64 = 0;
var phase: u32 = 0;
var target_cpu: u32 = 0;
var worker_handle: a.ProgramJoinHandle = .{};

fn failure(sys: *r4os.r4sys.Context, stage: []const u8, code: i32) i32 {
    var bytes: [160]u8 = undefined;
    const text = std.fmt.bufPrint(&bytes, "SPECTRA THREAD placement: {s} ({d})", .{ stage, code }) catch "SPECTRA THREAD placement: failure";
    sys.println(text);
    return 1;
}
fn childOutput(sys: *r4os.r4sys.Context, handle: *const a.ProgramProcessHandle) void {
    var bytes: [2048]u8 = undefined;
    const got = sys.consoleOutput(handle.instance_id, &bytes);
    if (got > 0 and got <= bytes.len) sys.println(bytes[0..@intCast(got)]);
}

fn snapshot(sys: *r4os.r4sys.Context, handle: *const a.ProgramJoinHandle, info: *a.ThreadPlacementInfo, words: *[2]u64) !void {
    info.* = .{};
    words.* = .{ 0, 0x79_79797979797979 };
    const code = sys.threadPlacementGet(handle, info, words);
    if (code != a.thread_ok) {
        _ = failure(sys, "snapshot API", code);
        return error.Snapshot;
    }
    if (info.cpu_word_count != 1 or words[1] != 0x79_79797979797979) {
        _ = failure(sys, "snapshot words/tail", @intCast(info.cpu_word_count));
        return error.Snapshot;
    }
}
fn change(sys: *r4os.r4sys.Context, handle: *const a.ProgramJoinHandle, cpu: u32, class: u32) !a.ThreadPlacementInfo {
    const words = [_]u64{@as(u64, 1) << @intCast(cpu)};
    const request: a.ThreadPlacementRequest = .{ .work_class = class, .preferred_cpu = cpu };
    if (sys.threadPlacementSet(handle, &request, &words) != a.thread_ok) return error.Set;
    var info: a.ThreadPlacementInfo = .{};
    var output: [2]u64 = undefined;
    try snapshot(sys, handle, &info, &output);
    if (output[0] != words[0] or info.work_class != class or info.preferred_cpu != cpu) return error.Request;
    return info;
}
fn waitPhase(sys: *r4os.r4sys.Context, wanted: u32) !void {
    const start = sys.monotonicNanoseconds() orelse return error.Clock;
    while (@atomicLoad(u32, &phase, .acquire) != wanted) {
        if (@atomicLoad(u32, &phase, .acquire) == 99) return error.Worker;
        if ((sys.monotonicNanoseconds() orelse return error.Clock) -| start > 5_000_000_000) return error.Timeout;
        sys.sleepTicks(1);
    }
}
fn checkSelf(sys: *r4os.r4sys.Context, handle: *const a.ProgramJoinHandle, cpu: u32, class: u32) !void {
    _ = try change(sys, handle, cpu, class);
    var info: a.ThreadPlacementInfo = .{};
    var words: [2]u64 = undefined;
    const start = sys.monotonicNanoseconds() orelse return error.Clock;
    while (true) {
        try snapshot(sys, handle, &info, &words);
        if (info.request_revision == info.applied_revision) break;
        if ((sys.monotonicNanoseconds() orelse return error.Clock) -| start > 5_000_000_000) return error.SaveTimeout;
        sys.taskYield();
    }
    if (info.running_cpu != cpu or info.home_cpu != cpu or info.request_revision != info.applied_revision or info.flags & a.thread_placement_flag_pending != 0) return error.SavedSwitch;
}
fn invalid(sys: *r4os.r4sys.Context, handle: *const a.ProgramJoinHandle) !void {
    var info: a.ThreadPlacementInfo = .{};
    var words: [2]u64 = undefined;
    try snapshot(sys, handle, &info, &words);
    const before = info;
    const before_words = words;
    var old = handle.*;
    old.thread_generation +%= 1;
    if (sys.threadPlacementGet(&old, &info, &words) != a.thread_error_not_found or !std.meta.eql(info, before) or !std.meta.eql(words, before_words)) return error.Stale;
    var request: a.ThreadPlacementRequest = .{};
    const valid = [_]u64{1};
    const flags = asm volatile ("pushfq; popq %[value]"
        : [value] "=r" (-> u64),
        :
        : .{ .memory = true });
    asm volatile ("cli" ::: .{ .memory = true });
    const critical_get = sys.threadPlacementGet(handle, &info, &words);
    const critical_set = sys.threadPlacementSet(handle, &request, &valid);
    if (flags & (1 << 9) != 0) asm volatile ("sti" ::: .{ .memory = true });
    if (critical_get != a.thread_error_busy or critical_set != a.thread_error_busy or !std.meta.eql(info, before) or !std.meta.eql(words, before_words)) return error.Critical;

    if (sys.threadPlacementSet(&old, &request, &valid) != a.thread_error_not_found) return error.StaleSet;
    if (sys.threadPlacementSet(handle, &request, &.{}) != a.thread_placement_error_capacity) return error.Count;
    if (sys.threadPlacementSet(handle, &request, &.{0}) != a.thread_error_invalid) return error.Empty;
    if (sys.threadPlacementSet(handle, &request, &.{@as(u64, 1) << 63}) != a.thread_error_invalid) return error.Offline;
    request.preferred_cpu = 63;
    if (sys.threadPlacementSet(handle, &request, &valid) != a.thread_error_invalid) return error.Hint;
    request = .{ .flags = 0x80000000 };
    if (sys.threadPlacementSet(handle, &request, &valid) != a.thread_error_invalid) return error.Flags;
    request = .{ .work_class = 3 };
    if (sys.threadPlacementSet(handle, &request, &valid) != a.thread_error_invalid) return error.Class;
    request = .{ .reserved1 = 1 };
    if (sys.threadPlacementSet(handle, &request, &valid) != a.thread_error_invalid) return error.Reserved;
    info.version = 9;
    const bad_header = info;
    if (sys.threadPlacementGet(handle, &info, &words) != a.thread_error_invalid or !std.meta.eql(info, bad_header) or !std.meta.eql(words, before_words)) return error.Header;
    try snapshot(sys, handle, &info, &words);
    if (info.request_revision != before.request_revision or info.work_class != before.work_class or info.preferred_cpu != before.preferred_cpu or !std.meta.eql(words, before_words)) return error.InvalidMutation;
}
fn adopted(sys: *r4os.r4sys.Context, info: *a.ThreadPlacementInfo, words: *[2]u64) !void {
    const start = sys.monotonicNanoseconds() orelse return error.Clock;
    while (true) {
        try snapshot(sys, &worker_handle, info, words);
        if (info.request_revision == info.applied_revision) return;
        if ((sys.monotonicNanoseconds() orelse return error.Clock) -| start > 5_000_000_000) return error.SaveTimeout;
        sys.taskYield();
    }
}
fn peer(_: u64) callconv(.c) i32 {
    var sys = system orelse return 90;
    if (sys.threadCurrentHandle(&worker_handle) != a.thread_ok) return 90;
    @atomicStore(u32, &phase, 1, .release);
    if (sys.notificationWait(notification, 0, a.thread_wait_forever) != a.notification_ok) return 91;
    var info: a.ThreadPlacementInfo = .{};
    var words: [2]u64 = undefined;
    adopted(&sys, &info, &words) catch {
        @atomicStore(u32, &phase, 99, .release);
        return 92;
    };
    if (info.running_cpu != 1 or words[0] != 2 or info.work_class != a.thread_placement_class_batch) {
        @atomicStore(u32, &phase, 99, .release);
        return 93;
    }
    @atomicStore(u32, &phase, 2, .release);
    // Ordinary program instructions allow timer/IPI preemption. A foreign
    // setter must move this live continuation through its actual saved frame.
    var spins: u64 = 0;
    while (true) {
        for (0..1024) |_| asm volatile ("pause" ::: .{ .memory = true });
        spins +%= 1;
        snapshot(&sys, &worker_handle, &info, &words) catch {
            @atomicStore(u32, &phase, 99, .release);
            return 94;
        };
        const target = @atomicLoad(u32, &target_cpu, .acquire);
        if (target != 0 and info.running_cpu == target and info.request_revision == info.applied_revision and words[0] == @as(u64, 1) << @intCast(target)) break;
        if (spins > 100000) {
            @atomicStore(u32, &phase, 99, .release);
            return 95;
        }
    }
    var observed: u64 = 0;
    if (sys.notificationQuery(notification, &observed) != a.notification_ok) return 96;
    @atomicStore(u32, &phase, 3, .release);
    if (sys.notificationWait(notification, observed, a.thread_wait_forever) != a.notification_ok) return 96;
    adopted(&sys, &info, &words) catch return 97;
    if (info.running_cpu != 2 or words[0] != 4 or info.work_class != a.thread_placement_class_preferred) return 98;
    @atomicStore(u32, &phase, 4, .release);
    return 73;
}
fn exercise(app: *r4os.App) !void {
    var sys = app.system();
    system = sys;
    var identity: a.ProgramJoinHandle = .{};
    if (sys.threadCurrentHandle(&identity) != a.thread_ok) return error.Identity;
    var info: a.ThreadPlacementInfo = .{};
    var words: [2]u64 = undefined;
    try snapshot(&sys, &identity, &info, &words);
    if (info.flags & a.thread_placement_flag_parallel == 0 or words[0] & 15 != 15) return error.ParallelAdmission;
    sys.println("placement child: admitted");
    try invalid(&sys, &identity);
    sys.println("placement child: invalid inputs passed");
    // No private peer exists during these transitions; AP3 and AP1 therefore
    // need a real idle continuation when this sole local task leaves them.
    try checkSelf(&sys, &identity, 3, a.thread_placement_class_batch);
    sys.println("placement child: self3 batch");
    try checkSelf(&sys, &identity, 1, a.thread_placement_class_interactive);
    sys.println("placement child: self1 interactive");
    try checkSelf(&sys, &identity, 3, a.thread_placement_class_preferred);
    sys.println("placement child: self3 preferred");
    const revision = (try change(&sys, &identity, 3, a.thread_placement_class_preferred)).request_revision;
    const same = try change(&sys, &identity, 3, a.thread_placement_class_preferred);
    if (same.request_revision != revision) return error.EqualRequest;
    try checkSelf(&sys, &identity, 0, a.thread_placement_class_interactive);
    // Inputs are consumed synchronously, with no retained vector storage.
    if (sys.notificationCreate(&notification) != a.notification_ok) return error.Notification;
    var handle: a.ProgramJoinHandle = .{};
    var joined = false;
    var notification_closed = false;
    defer {
        if (!joined) {
            @atomicStore(u32, &target_cpu, 3, .release);
            _ = sys.notificationNotify(notification, 2);
            var ignored: i32 = 0;
            joined = sys.threadHandleJoin(&handle, sys.monotonicHz() * 5, &ignored) == a.thread_ok;
        }
        if (joined and !notification_closed) _ = sys.notificationClose(notification);
    }
    phase = 0;
    target_cpu = 0;
    if (sys.threadCreateHandle(peer, 0, 0, 0, &handle) != a.thread_ok) {
        joined = true;
        return error.Create;
    }
    try waitPhase(&sys, 1);
    _ = try change(&sys, &handle, 1, a.thread_placement_class_batch);
    if (sys.notificationNotify(notification, 1) != a.notification_ok) return error.Notify;
    try waitPhase(&sys, 2);
    @atomicStore(u32, &target_cpu, 3, .release);
    _ = try change(&sys, &handle, 3, a.thread_placement_class_interactive);
    try waitPhase(&sys, 3);
    _ = try change(&sys, &handle, 2, a.thread_placement_class_preferred);
    if (sys.notificationNotify(notification, 1) != a.notification_ok) return error.Notify;
    var result: i32 = 0;
    if (sys.threadHandleJoin(&handle, sys.monotonicHz() * 5, &result) != a.thread_ok) return error.Join;
    joined = true;
    if (result != 73 or @atomicLoad(u32, &phase, .acquire) != 4) return error.WorkerResult;
    if (sys.notificationClose(notification) != a.notification_ok) return error.NotificationClose;
    notification_closed = true;
    // The consumed exact handle cannot retarget a later reused Thread slot.
    info = .{};
    words = .{ 79, 79 };
    if (sys.threadPlacementGet(&handle, &info, &words) != a.thread_error_not_found or words[0] != 79 or info.cpu_word_count != 0) return error.JoinedHandle;
    const reset: a.ThreadPlacementRequest = .{ .flags = a.thread_placement_flag_default_cpus };
    if (sys.threadPlacementSet(&identity, &reset, &.{}) != a.thread_ok) return error.Default;
    try snapshot(&sys, &identity, &info, &words);
    if (words[0] & 15 != 15 or info.flags & a.thread_placement_flag_default_cpus == 0) return error.Default;
    // Return to the BSP before file-system work; AP I/O expansion is separate.
    try checkSelf(&sys, &identity, 0, a.thread_placement_class_interactive);
}
pub fn child(app: *r4os.App, args: []const u8) i32 {
    var sys = app.system();
    if (!std.mem.startsWith(u8, args, worker_prefix)) return 2;
    const path = args[worker_prefix.len..];
    var name: [80:0]u8 = .{0} ** 80;
    if (path.len == 0 or path.len >= name.len or !std.mem.startsWith(u8, path, "C:\\TEMP\\TP")) return 2;
    @memcpy(name[0..path.len], path);
    exercise(app) catch |err| {
        // Exact program teardown owns any still-live peer; do not erase its
        // notification or return a fabricated successful cleanup receipt.
        var own: a.ProgramJoinHandle = .{};
        if (sys.threadCurrentHandle(&own) == a.thread_ok) {
            checkSelf(&sys, &own, 0, a.thread_placement_class_interactive) catch {};
            if (sys.fileStreamBegin(&name, a.file_stream_open_create) == 0) {
                const message = @errorName(err);
                if (sys.fileStreamWrite(&name, 0, message, 0) == message.len) _ = sys.fileStreamFinish(&name, message.len, 0) else _ = sys.fileStreamAbort(&name);
            }
        }
        _ = sys.programExit(1, a.program_exit_reason_failed);
        return 1;
    };
    const result = "{\"thread_placement\":\"pass\",\"cpus\":4,\"self_save_sequence\":\"3,1,3,0\",\"peer_saved_migration\":true,\"wait_wake\":true,\"invalid_unchanged\":true,\"stale_handle\":true}\r\n";
    if (sys.fileStreamBegin(&name, a.file_stream_open_create) != 0) return 1;
    if (sys.fileStreamWrite(&name, 0, result, 0) != result.len or sys.fileStreamFinish(&name, result.len, 0) != 0) {
        _ = sys.fileStreamAbort(&name);
        return 1;
    }
    return 0;
}
pub fn bsp(app: *r4os.App) i32 {
    var sys = app.system();
    var identity: a.ProgramJoinHandle = .{};
    if (sys.threadCurrentHandle(&identity) != a.thread_ok) return failure(&sys, "BSP identity", 1);
    var info: a.ThreadPlacementInfo = .{};
    var words: [2]u64 = undefined;
    snapshot(&sys, &identity, &info, &words) catch return failure(&sys, "BSP snapshot", 1);
    if (info.flags & a.thread_placement_flag_parallel != 0 or words[0] != 1) return failure(&sys, "foreground admission", @intCast(info.flags));
    const request: a.ThreadPlacementRequest = .{};
    const denied = sys.threadPlacementSet(&identity, &request, &.{2});
    if (denied != a.thread_error_invalid) return failure(&sys, "foreground AP rejection", denied);
    invalid(&sys, &identity) catch |err| return failure(&sys, @errorName(err), 1);
    checkSelf(&sys, &identity, 0, a.thread_placement_class_batch) catch |err| return failure(&sys, @errorName(err), 1);
    const args = app.args();
    const prefix = "/PLACEMENTBSP:";
    if (std.mem.startsWith(u8, args, prefix)) {
        const path = args[prefix.len..];
        var name: [80:0]u8 = .{0} ** 80;
        if (path.len == 0 or path.len >= name.len or !std.mem.startsWith(u8, path, "C:\\TEMP\\TB")) return failure(&sys, "foreground proof path", 1);
        @memcpy(name[0..path.len], path);
        const proof = "BSP-GATE-OK";
        if (sys.fileStreamBegin(&name, a.file_stream_open_create) != 0) return failure(&sys, "foreground proof begin", 1);
        if (sys.fileStreamWrite(&name, 0, proof, 0) != proof.len or sys.fileStreamFinish(&name, proof.len, 0) != 0) {
            _ = sys.fileStreamAbort(&name);
            return failure(&sys, "foreground proof finish", 1);
        }
    }
    sys.println("SPECTRA THREAD placement BSP gate: OK");
    return 0;
}

pub fn parent(app: *r4os.App) i32 {
    var sys = app.system();
    var identity: a.ProgramJoinHandle = .{};
    const identity_code = sys.threadCurrentHandle(&identity);
    if (identity_code != a.thread_ok) return failure(&sys, "parent identity", identity_code);
    var info: a.ThreadPlacementInfo = .{};
    var words: [2]u64 = undefined;
    snapshot(&sys, &identity, &info, &words) catch return failure(&sys, "parent snapshot", 1);
    // The shell may host this audited module as a background instance with a
    // private console. Explicitly run role0 to verify the BSP-only boundary.
    checkSelf(&sys, &identity, 0, a.thread_placement_class_interactive) catch |err| return failure(&sys, @errorName(err), 1);
    if (info.flags & a.thread_placement_flag_parallel == 0) {
        // A caller that already owns the legacy foreground slot tests its own
        // admission; another foreground launch would correctly be rejected.
        if (bsp(app) != 0) return failure(&sys, "current foreground admission", 1);
        checkSelf(&sys, &identity, 0, a.thread_placement_class_interactive) catch |err| return failure(&sys, @errorName(err), 1);
    } else {
        // Legacy programRun returns launch/completion status, not the child's
        // exit code. Require its own success-only private file acknowledgement.
        var foreground_name: [80:0]u8 = .{0} ** 80;
        const proof_path = std.fmt.bufPrintZ(&foreground_name, "C:\\TEMP\\TB{X:0>8}-{X:0>16}.OUT", .{ identity.instance_id, identity.instance_generation }) catch return 1;
        if (sys.exists(proof_path)) return failure(&sys, "foreground proof conflict", 1);
        var terminal = false;
        defer if (terminal and sys.exists(proof_path)) {
            _ = sys.fileDelete(proof_path);
        };
        var foreground_args: [128:0]u8 = .{0} ** 128;
        const foreground_command = std.fmt.bufPrintZ(&foreground_args, "CHECK THREAD /PLACEMENTBSP:{s}", .{proof_path}) catch return 1;
        const foreground = sys.programRun(route.path, foreground_command);
        terminal = foreground == 0;
        if (!terminal) return failure(&sys, "explicit foreground child", foreground);
        var proof_bytes: [32]u8 = undefined;
        const proof_length = sys.fileRead(proof_path, &proof_bytes);
        if (proof_length != 11 or !std.mem.eql(u8, proof_bytes[0..11], "BSP-GATE-OK")) return failure(&sys, "foreground proof missing", proof_length);
    }
    sys.println("SPECTRA THREAD placement foreground admission: OK");
    var capacity: a.CpuCapacity = .{};
    if (sys.cpuCapacity(&capacity) != a.thread_ok or capacity.available_cpus < 4) {
        sys.println("SPECTRA THREAD placement: requires four admitted CPUs");
        return 2;
    }
    var name: [80:0]u8 = .{0} ** 80;
    const path = std.fmt.bufPrintZ(&name, "C:\\TEMP\\TP{X:0>8}.OUT", .{identity.instance_id}) catch return 1;
    if (sys.exists(path)) return failure(&sys, "private file conflict", 1);
    var process_live = false;
    defer if (!process_live and sys.exists(path)) {
        _ = sys.fileDelete(path);
    };
    var command: [128:0]u8 = .{0} ** 128;
    const args = std.fmt.bufPrintZ(&command, "CHECK THREAD " ++ worker_prefix ++ "{s}", .{path}) catch return 1;
    var handle: a.ProgramProcessHandle = .{};
    const spawn_code = sys.programSpawnHandle(route.path, args, .auto, &handle);
    if (spawn_code != a.program_handle_ok) return failure(&sys, "spawn", spawn_code);
    process_live = true;
    var reaped = false;
    defer if (!reaped) {
        _ = sys.programHandleKill(&handle);
        var done: a.ProgramProcessCompletion = .{};
        if (sys.programHandleWait(&handle, sys.monotonicHz() * 5, &done) == a.program_handle_ok) reaped = sys.programHandleReap(&handle, &done) == a.program_handle_ok;
        if (reaped) process_live = false;
    };
    var completion: a.ProgramProcessCompletion = .{};
    const waited = sys.programHandleWait(&handle, sys.monotonicHz() * 20, &completion);
    if (waited != a.program_handle_ok) {
        childOutput(&sys, &handle);
        return failure(&sys, "child completion", waited);
    }
    reaped = sys.programHandleReap(&handle, &completion) == a.program_handle_ok;
    if (reaped) process_live = false;
    if (!reaped or completion.exit_code != 0) {
        sys.println("SPECTRA THREAD placement: worker FAILED");
        childOutput(&sys, &handle);
        var message: [256]u8 = undefined;
        const count = sys.fileRead(path, &message);
        if (count > 0 and count <= message.len) sys.println(message[0..@intCast(count)]);
        return 1;
    }
    var result: [512]u8 = undefined;
    const got = sys.fileRead(path, &result);
    if (got <= 0 or got > result.len) return failure(&sys, "result file", got);
    sys.write(result[0..@intCast(got)]);
    sys.println("SPECTRA THREAD placement: OK");
    return 0;
}
