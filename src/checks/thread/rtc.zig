//! Explicit isolated-guest RTC mutation check; never part of passive metrics.
const std = @import("std");
const r4os = @import("r4os");
const r4std = @import("r4std");
const a = r4os.abi;
const route = @import("../../route.zig");
const first: a.TimeState = .{ .valid = 1, .year = 2028, .month = 2, .day = 29, .weekday = 2, .hour = 1, .minute = 2, .second = 3 };
const second: a.TimeState = .{ .valid = 1, .year = 2031, .month = 12, .day = 31, .weekday = 3, .hour = 23, .minute = 57, .second = 59 };
const Shared = struct {
    sys: r4os.r4sys.Context,
    deadline: u64,
    go: bool = false,
    stop: bool = false,
    ready: u32 = 0,
    writers_done: u32 = 0,
    reads: [4]u32 = .{0} ** 4,
    sets: [4]u32 = .{0} ** 4,
    cpus: [4]u32 = .{0} ** 4,
};
var shared: Shared = undefined;
fn fail(sys: *const r4os.r4sys.Context, name: []const u8) i32 {
    sys.write("SPECTRA RTC: ");
    sys.println(name);
    return 1;
}
fn live() bool {
    const now = shared.sys.monotonicNanoseconds() orelse return false;
    return now < shared.deadline and !@atomicLoad(bool, &shared.stop, .acquire) and !shared.sys.programShouldClose();
}
fn place(cpu: u32) !void {
    var handle: a.ProgramJoinHandle = .{};
    if (shared.sys.threadCurrentHandle(&handle) != a.thread_ok) return error.Identity;
    const request: a.ThreadPlacementRequest = .{ .preferred_cpu = cpu };
    const mask = [_]u64{@as(u64, 1) << @intCast(cpu)};
    if (shared.sys.threadPlacementSet(&handle, &request, &mask) != a.thread_ok) return error.Placement;
    while (live()) {
        var info: a.ThreadPlacementInfo = .{};
        var words: [1]u64 = undefined;
        if (shared.sys.threadPlacementGet(&handle, &info, &words) != a.thread_ok) return error.PlacementRead;
        if (info.applied_revision == info.request_revision and info.running_cpu == cpu and info.home_cpu == cpu and words[0] == mask[0]) {
            shared.cpus[cpu] = cpu + 1;
            return;
        }
        shared.sys.taskYield();
    }
    return error.PlacementTimeout;
}
fn set(value: *const a.TimeState) !void {
    while (live()) {
        const code = shared.sys.timeSetState(value);
        if (code == 0) return;
        if (code != -2) return error.SetRejected;
        shared.sys.sleepTicks(@max(1, shared.sys.ticksFromMilliseconds(1)));
    }
    return error.SetTimeout;
}
fn matches(value: a.TimeState, expected: a.TimeState) bool {
    const seconds = @as(u32, value.hour) * 3600 + @as(u32, value.minute) * 60 + value.second;
    const base = @as(u32, expected.hour) * 3600 + @as(u32, expected.minute) * 60 + expected.second;
    return value.valid == 1 and value.year == expected.year and value.month == expected.month and value.day == expected.day and value.weekday == expected.weekday and
        value.hour <= 23 and value.minute <= 59 and value.second <= 59 and
        value.seconds_since_midnight == seconds and seconds >= base and seconds <= base + 12;
}
fn exercise(index: usize) !void {
    if (index == 1 or index == 3) {
        const value = if (index == 1) &first else &second;
        for (0..100) |_| {
            try set(value);
            shared.sets[index] += 1;
            if (!live()) return error.Deadline;
        }
        _ = @atomicRmw(u32, &shared.writers_done, .Add, 1, .release);
    } else {
        while (shared.reads[index] < 1000 or @atomicLoad(u32, &shared.writers_done, .acquire) != 2) {
            if (!live()) return error.Deadline;
            const value = shared.sys.timeState();
            if (!matches(value, first) and !matches(value, second)) return error.MixedCalendar;
            shared.reads[index] += 1;
            if (shared.reads[index] % 16 == 0) shared.sys.taskYield();
        }
    }
}
fn thread(index: u64) callconv(.c) i32 {
    place(@intCast(index)) catch {
        @atomicStore(bool, &shared.stop, true, .release);
        return 1;
    };
    _ = @atomicRmw(u32, &shared.ready, .Add, 1, .release);
    while (!@atomicLoad(bool, &shared.go, .acquire)) {
        if (!live()) return 1;
        shared.sys.taskYield();
    }
    exercise(@intCast(index)) catch {
        @atomicStore(bool, &shared.stop, true, .release);
        return 1;
    };
    return 0;
}
fn interruptFlags() u64 {
    return asm volatile ("pushfq; popq %[value]"
        : [value] "=r" (-> u64),
        :
        : .{ .memory = true });
}
fn checkIfAndInvalid() !void {
    try set(&first);
    const flags = interruptFlags();
    _ = shared.sys.timeState();
    if ((interruptFlags() ^ flags) & (1 << 9) != 0) return error.ReadIf;
    asm volatile ("cli" ::: .{ .memory = true });
    const value = shared.sys.timeState();
    const set_result = shared.sys.timeSetState(&first);
    const disabled = interruptFlags();
    if (flags & (1 << 9) != 0) asm volatile ("sti" ::: .{ .memory = true });
    if (disabled & (1 << 9) != 0 or !matches(value, first) or (set_result != 0 and set_result != -2)) return error.DisabledIf;
    var invalid = first;
    invalid.day = 30;
    if (shared.sys.timeSetState(&invalid) != -1 or !matches(shared.sys.timeState(), first)) return error.InvalidChangedTime;
}
pub fn child(app: *r4os.App) i32 {
    const sys = app.system();
    const start = sys.monotonicNanoseconds() orelse return fail(&sys, "no monotonic clock");
    shared = .{ .sys = sys, .deadline = start + 10_000_000_000 };
    place(0) catch |err| return fail(&sys, @errorName(err));
    checkIfAndInvalid() catch |err| return fail(&sys, @errorName(err));
    var handles = [_]a.ProgramJoinHandle{.{}} ** 3;
    var created: usize = 0;
    for (&handles, 1..) |*handle, index| {
        if (sys.threadCreateHandle(thread, index, 0, 0, handle) != a.thread_ok) break;
        created += 1;
    }
    var valid = created == handles.len;
    while (valid and @atomicLoad(u32, &shared.ready, .acquire) != created) {
        if (!live()) {
            valid = false;
            break;
        }
        sys.taskYield();
    }
    if (!valid) @atomicStore(bool, &shared.stop, true, .release);
    @atomicStore(bool, &shared.go, true, .release);
    if (valid) exercise(0) catch {
        valid = false;
        @atomicStore(bool, &shared.stop, true, .release);
    };
    var joined: usize = 0;
    for (handles[0..created]) |*handle| {
        var code: i32 = -1;
        if (sys.threadHandleJoin(handle, sys.ticksFromMilliseconds(12_000), &code) == a.thread_ok) {
            joined += 1;
            var stale: a.ProgramThreadInfo = .{};
            if (code != 0 or sys.threadHandleStatus(handle, &stale) != a.thread_error_not_found) valid = false;
        } else valid = false;
    }
    if (!valid or joined != 3 or !std.mem.eql(u32, &shared.cpus, &.{ 1, 2, 3, 4 }) or shared.sets[1] != 100 or shared.sets[3] != 100 or shared.reads[0] < 1000 or shared.reads[2] < 1000) return fail(&sys, "worker/CPU/join proof incomplete");
    var message: [200]u8 = undefined;
    sys.println(std.fmt.bufPrint(&message, "SPECTRA RTC worker: OK cpus=4 cpu_mask=0xF sets=200 reads={d} IF=preserved joins=3", .{shared.reads[0] + shared.reads[2]}) catch unreachable);
    return 0;
}
fn restore(sys: *const r4os.r4sys.Context, original: a.TimeState, started: u64) bool {
    const date = r4std.date.fromTimeState(original) orelse return false;
    const utc = r4std.date.utcFromDateTime(date, 0) orelse return false;
    const now = sys.monotonicNanoseconds() orelse return false;
    const deadline = now + 2_000_000_000;
    while (true) {
        const at = sys.monotonicNanoseconds() orelse return false;
        if (at < started or at >= deadline) return false;
        var advanced = utc;
        advanced.seconds_since_unix_epoch += @intCast((at - started) / 1_000_000_000);
        const target = r4std.date.toTimeState(r4std.date.dateTimeFromUtc(advanced) orelse return false) orelse return false;
        if (sys.timeSetState(&target) == 0) {
            const actual = sys.timeState();
            if (actual.valid == 0) return false;
            const actual_utc = r4std.date.utcFromDateTime(r4std.date.fromTimeState(actual) orelse return false, 0) orelse return false;
            return actual_utc.seconds_since_unix_epoch >= advanced.seconds_since_unix_epoch and actual_utc.seconds_since_unix_epoch - advanced.seconds_since_unix_epoch <= 1;
        }
        sys.sleepTicks(@max(1, sys.ticksFromMilliseconds(1)));
    }
}
pub fn parent(app: *r4os.App) i32 {
    const sys = app.system();
    if (!r4std.init(app.startContext())) return fail(&sys, "R4STD unavailable");
    var capacity: a.CpuCapacity = .{};
    if (sys.cpuCapacity(&capacity) != a.thread_ok or capacity.available_cpus < 4) return fail(&sys, "requires four admitted CPUs");
    const original = sys.timeState();
    const start = sys.monotonicNanoseconds() orelse return fail(&sys, "no monotonic clock");
    if (original.valid == 0 or r4std.date.fromTimeState(original) == null) return fail(&sys, "initial RTC invalid");
    sys.println("SPECTRA RTC: isolated-guest check changes calendar temporarily; restores after exact child teardown.");
    var handle: a.ProgramProcessHandle = .{};
    if (sys.programSpawnHandle(route.path, "CHECK THREAD /RTCWORKER", .auto, &handle) != a.program_handle_ok) return fail(&sys, "child spawn");
    var completion: a.ProgramProcessCompletion = .{};
    var completed = sys.programHandleWait(&handle, sys.ticksFromMilliseconds(15_000), &completion) == a.program_handle_ok;
    const natural = completed;
    if (!completed) {
        _ = sys.programHandleKill(&handle);
        completed = sys.programHandleWait(&handle, sys.ticksFromMilliseconds(5_000), &completion) == a.program_handle_ok;
    }
    if (!completed) return fail(&sys, "child still live; restore pending");
    var bytes: [4096]u8 = undefined;
    const length = sys.consoleOutput(handle.instance_id, &bytes);
    const proof = length > 0 and length <= bytes.len and std.mem.indexOf(u8, bytes[0..@intCast(length)], "SPECTRA RTC worker: OK") != null;
    if (length > 0 and length <= bytes.len) sys.write(bytes[0..@intCast(length)]);
    if (sys.programHandleReap(&handle, &completion) != a.program_handle_ok) return fail(&sys, "child reap missing; restore pending");
    if (!restore(&sys, original, start)) return fail(&sys, "original calendar restoration failed");
    if (!natural or completion.exit_code != 0 or !proof) return fail(&sys, "child failed; original calendar restored");
    sys.println("SPECTRA RTC result: OK child_reaped=yes restored=yes");
    return 0;
}
