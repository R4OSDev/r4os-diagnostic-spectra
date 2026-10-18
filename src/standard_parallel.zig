//! One participant per schedulable CPU. Ready participants remain runnable
//! until the shared gate opens, so admission can balance them across CPUs.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const model = @import("standard_model.zig");
const work = @import("standard_workloads.zig");
pub const Result = struct { sample: model.Sample, retained: bool = false };
const Participant = struct { context: work.Context, pool: *Pool, handle: a.ProgramJoinHandle = .{} };
const Pool = struct {
    sys: *const r4os.r4sys.Context,
    area: usize,
    ready: usize = 0,
    go: bool = false,
    stop: bool = false,
    fn entry(raw: u64) callconv(.c) i32 {
        const participant: *Participant = @ptrFromInt(raw);
        const self = participant.pool;
        const context = &participant.context;
        var prepared = true;
        context.prepare(self.area) catch |err| {
            context.result.reason = @errorName(err);
            @atomicStore(bool, &self.stop, true, .release);
            prepared = false;
        };
        _ = @atomicRmw(usize, &self.ready, .Add, 1, .release);
        while (!@atomicLoad(bool, &self.go, .acquire)) self.sys.taskYield();
        if (prepared and !@atomicLoad(bool, &self.stop, .acquire)) context.run(self.area);
        context.cleanup();
        return if (context.result.reason == null and !context.cleanup_failed) 0 else 1;
    }
};

pub fn sample(sys: *const r4os.r4sys.Context, net: ?r4os.r4net.Context, area: usize, cpus: u32, deadline: u64, overhead: ?u64) Result {
    const failed = Result{ .sample = .{ .workers = cpus, .reason = "participant-allocation-failed" } };
    const allocator = sys.allocator();
    const pool = allocator.create(Pool) catch return failed;
    pool.* = .{ .sys = sys, .area = area };
    var retained = false;
    defer if (!retained) allocator.destroy(pool);
    const participants = allocator.alloc(Participant, cpus) catch return failed;
    defer if (!retained) allocator.free(participants);
    const buffer_count = if (area == 4) @as(usize, cpus) * 128 * 1024 else 0;
    const buffers = allocator.alloc(u8, buffer_count) catch return failed;
    defer if (!retained) allocator.free(buffers);
    var identity: a.ProgramJoinHandle = .{};
    if (sys.threadCurrentHandle(&identity) != a.thread_ok) return failed;
    for (participants, 0..) |*participant, index| {
        participant.* = .{ .context = .{ .sys = sys, .net = net, .stop = &pool.stop, .deadline = deadline, .index = @intCast(index) }, .pool = pool };
        if (area == 4) {
            const offset = index * 128 * 1024;
            participant.context.write_bytes = buffers[offset..][0 .. 64 * 1024];
            participant.context.read_bytes = buffers[offset + 64 * 1024 ..][0 .. 64 * 1024];
            for (participant.context.write_bytes, 0..) |*byte, i| byte.* = @truncate(i *% 131 +% 17 +% index *% 19);
            _ = std.fmt.bufPrintZ(&participant.context.file_path, "C:\\TEMP\\SB{X:0>8}{X:0>4}.BIN", .{ identity.instance_id, index }) catch return failed;
        }
    }
    var created: usize = 0;
    for (participants[1..]) |*participant| {
        if (sys.threadCreateHandle(Pool.entry, @intFromPtr(participant), 0, 0, &participant.handle) != a.thread_ok) break;
        created += 1;
    }
    var valid = created + 1 == participants.len;
    const first = &participants[0].context;
    if (valid) first.prepare(area) catch |err| {
        first.result.reason = @errorName(err);
        valid = false;
    };
    while (valid and @atomicLoad(usize, &pool.ready, .acquire) != created) {
        first.check() catch |err| {
            first.result.reason = @errorName(err);
            valid = false;
        };
        if (valid) sys.sleepTicks(work.ticks(sys, 1));
    }
    var start: ?a.MonotonicClockInfo = null;
    if (valid) {
        start = work.clock(sys);
        valid = start != null and !@atomicLoad(bool, &pool.stop, .acquire);
    }
    if (!valid) @atomicStore(bool, &pool.stop, true, .release);
    @atomicStore(bool, &pool.go, true, .release);
    if (valid) first.run(area);
    first.cleanup();
    for (participants[1..][0..created]) |*participant| {
        var code: i32 = -1;
        // Work has a shared finite deadline; join retains every exact owner.
        const remaining = deadline -| (sys.monotonicNanoseconds() orelse deadline);
        const timeout = @max(work.ticks(sys, 2000), sys.ticksFromMilliseconds(remaining / 1_000_000 + 2000));
        if (sys.threadHandleJoin(&participant.handle, timeout, &code) != a.thread_ok) {
            retained = true;
            @atomicStore(bool, &pool.stop, true, .release);
        } else if (code != 0) valid = false;
    }
    var result = model.Sample{ .workers = cpus, .reason = if (valid) null else "participant-work-failed" };
    if (start) |beginning| {
        if (work.clock(sys)) |end| {
            result.clock_source = beginning.source;
            result.clock_generation = beginning.generation;
            result.clock_resolution_ns = @max(beginning.resolution_ns, end.resolution_ns);
            result.observer_overhead_ns = overhead;
            if (end.source == beginning.source and end.generation == beginning.generation and end.instant_ns > beginning.instant_ns) {
                result.elapsed_ns = end.instant_ns - beginning.instant_ns;
            } else result.reason = "clock-changed-or-zero-interval";
        } else result.reason = "clock-unavailable";
    }
    if (!retained) for (participants) |*participant| {
        const context = &participant.context;
        result.operations += context.result.operations;
        result.bytes += context.result.bytes;
        if (context.result.reason == null and !context.cleanup_failed) result.completed_workers += 1 else {
            // Keep the originating failure instead of a peer's cooperative
            // cancellation after the shared stop flag was published.
            if (result.reason == null or std.mem.eql(u8, result.reason.?, "participant-work-failed") or std.mem.eql(u8, result.reason.?, "Cancelled"))
                result.reason = context.result.reason orelse "cleanup-unconfirmed";
        }
        if (context.cleanup_failed) retained = true;
    };
    if (retained) result.reason = "participant-cleanup-unconfirmed";
    return .{ .sample = result, .retained = retained };
}
