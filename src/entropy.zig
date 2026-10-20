//! Explicit bounded source/consumer checks. Never prints random byte contents.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const Output = @import("output.zig").Output;
const Atomic = std.atomic.Value(u32);
var sys: r4os.r4sys.Context = undefined;
var dev: r4os.r4dev.Context = undefined;
var context: r4os.program.Context = undefined;
var gate: Atomic = .init(0);
var done: Atomic = .init(0);
var missing = false;
var calls: u32 = 0;
var job: struct {
    cpu: a.CpuAccelerationInfo = .{},
    grant: a.CpuAccelerationWork = .{},
    source: a.EntropySourceInfo = .{},
    direct_requests: u32 = 0,
    direct_bytes: u32 = 0,
    shared: bool = false,
    webcrypto: bool = false,
    grant_result: i32 = 0,
} = .{};

pub fn collect(app: *r4os.App, out: *Output) bool {
    var info: a.EntropySourceInfo = .{};
    const source = app.lowLevel();
    const rc = source.entropySourceInfo(&info);
    if (rc != 0) {
        out.unavailable("entropy", "source metadata unavailable");
        return false;
    }
    out.record("entropy_source", "entropy", 0, info);
    return true;
}
fn pure(raw: u64, count: u32) callconv(.c) i32 {
    if (raw != @intFromPtr(&calls) or count != 1) return -1;
    calls += 1;
    return 0;
}
fn cases(cpu: u32) i32 {
    if (dev.cpuAccelerationInfo(&job.cpu) != 0 or job.cpu.cpu_index != cpu) return 11;
    job.grant_result = dev.cpuAccelerationWork(a.cpu_accel_work_kind_rdrand, 1, pure, @intFromPtr(&calls), &job.grant);
    if (job.cpu.os_mask & a.cpu_accel_feature_rdrand == 0) {
        if (job.grant_result != a.cpu_capabilities_error_unsupported or calls != 0) return 12;
    } else if (job.grant_result != 0 or calls != 1 or
        !r4os.cpu_acceleration.accepted(&job.grant, a.cpu_accel_work_kind_rdrand, 1)) return 13;
    if (missing and job.cpu.os_mask & a.cpu_accel_feature_rdrand != 0) return 14;
    var before: a.EntropySourceInfo = .{};
    if (context.entropySourceInfo(&before) != 0) return 15;
    if ((before.state == a.entropy_state_ready) == missing) return 16;
    const read = context.entropyFillFunction() orelse return 17;
    var buffer: [4097]u8 = @splat(0x77);
    if (read(&buffer, 4097) != a.entropy_error_invalid) return 18;
    for (buffer) |byte| if (byte != 0x77) return 19;
    var bad = before;
    bad.version = 0;
    const unchanged = bad;
    if (context.entropySourceInfo(&bad) != a.entropy_error_invalid or
        !std.mem.eql(u8, std.mem.asBytes(&bad), std.mem.asBytes(&unchanged))) return 20;
    for ([_]u32{ 1, 7, 8, 17, 64, 512, 4096 }) |bytes| {
        @memset(&buffer, 0x77);
        const result = read(&buffer, bytes);
        if (result != if (missing) a.entropy_error_unavailable else @as(i32, @intCast(bytes))) return 21;
        // Only tail/sanitization checks; byte statistics never prove a source.
        for (buffer[bytes..]) |byte| if (byte != 0x77) return 22;
        if (missing) for (buffer[0..bytes]) |byte| {
            if (byte != 0) return 23;
        };
        job.direct_requests += 1;
        job.direct_bytes += bytes;
    }
    var shared: [32]u8 = @splat(0x77);
    defer std.crypto.secureZero(u8, &shared);
    job.shared = r4os.secure_random.fill(&shared);
    if (job.shared == missing or r4os.secure_random.available() == missing) return 24;
    if (missing) for (shared) |byte| {
        if (byte != 0) return 25;
    };
    var web: [r4os.web_crypto.max_random_bytes]u8 = @splat(0x77);
    defer std.crypto.secureZero(u8, &web);
    job.webcrypto = r4os.web_crypto.fillSecureRandom(&web);
    if (job.webcrypto == missing) return 26;
    if (missing) for (web) |byte| {
        if (byte != 0) return 27;
    };
    if (context.entropySourceInfo(&job.source) != 0) return 28;
    if (!missing and (job.source.generation != before.generation or job.source.owner_epoch != before.owner_epoch or
        job.source.vendor_id != 0x1af4 or (job.source.device_id != 0x1044 and job.source.device_id != 0x1005) or
        job.source.flags & a.entropy_source_flag_verified_receipt == 0 or
        job.source.completed_requests < before.completed_requests + job.direct_requests or
        job.source.dma_completed < before.dma_completed + job.direct_requests or
        job.source.dma_completed != job.source.dma_submitted)) return 29;
    return 0;
}
fn worker(raw: u64) callconv(.c) i32 {
    defer done.store(1, .release);
    const begun = sys.monotonicNanoseconds() orelse return 8;
    while (gate.load(.acquire) == 0) {
        if ((sys.monotonicNanoseconds() orelse return 8) -| begun > 5_000_000_000) return 9;
        sys.sleepTicks(1);
    }
    return if (gate.load(.acquire) == 1) cases(@intCast(raw)) else 10;
}
pub fn run(app: *r4os.App, out: *Output, absent: bool) i32 {
    sys = app.system();
    dev = app.devicesLowLevel() orelse return 2;
    context = app.lowLevel();
    missing = absent;
    var first: a.CpuAccelerationInfo = .{};
    if (dev.cpuAccelerationInfo(&first) != 0 or first.configured_cpus == 0 or first.configured_cpus > 64) return 2;
    var created: u32 = 0;
    var reaped: u32 = 0;
    for (0..first.configured_cpus) |cpu| {
        job = .{};
        calls = 0;
        gate.store(0, .release);
        done.store(0, .release);
        var handle: a.ProgramJoinHandle = .{};
        if (sys.computeWorkerCreate(worker, cpu, 256 * 1024, &handle) != a.thread_ok) return 1;
        created += 1;
        const mask = [_]u64{@as(u64, 1) << @intCast(cpu)};
        const request: a.ThreadPlacementRequest = .{ .preferred_cpu = @intCast(cpu), .work_class = a.thread_placement_class_batch };
        var prepared = sys.threadPlacementSet(&handle, &request, &mask) == a.thread_ok;
        const begun = sys.monotonicNanoseconds() orelse 0;
        while (prepared) {
            var placement: a.ThreadPlacementInfo = .{};
            if (sys.threadPlacementGet(&handle, &placement, &.{}) != a.thread_ok) {
                prepared = false;
                break;
            }
            if (placement.request_revision == placement.applied_revision and placement.home_cpu == cpu) break;
            if ((sys.monotonicNanoseconds() orelse std.math.maxInt(u64)) -| begun > 5_000_000_000) {
                prepared = false;
                break;
            }
            sys.sleepTicks(1);
        }
        gate.store(if (prepared) 1 else 2, .release);
        var code: i32 = -1;
        if (sys.threadHandleJoin(&handle, sys.ticksFromMilliseconds(20000), &code) != a.thread_ok) {
            out.record("entropy_retained", "entropy", cpu, .{ .created = created, .reaped = reaped });
            _ = sys.programExit(30, a.program_exit_reason_failed);
            while (true) sys.sleepTicks(1);
        }
        reaped += 1;
        out.record("entropy_cpu", "entropy", cpu, job.cpu);
        out.record("entropy_cpu_grant", "entropy", cpu, job.grant);
        out.record("entropy_source", "entropy", cpu, job.source);
        out.record("entropy_check", "entropy", cpu, .{ .result = code, .prepared = prepared, .missing = missing, .direct_requests = job.direct_requests, .direct_bytes = job.direct_bytes, .shared = job.shared, .webcrypto = job.webcrypto, .grant_result = job.grant_result, .callbacks = calls });
        if (!prepared or code != 0 or done.load(.acquire) == 0) return 1;
    }
    if (!missing) {
        var input: [1]u8 = .{0};
        var response: [512]u8 = undefined;
        for ([_][]const u8{ "security.tls", "security.credssp" }) |role| {
            const request: a.ProtocolBuffer = .{ .data = &input, .len = 0, .capacity = 1 };
            var result: a.ProtocolBuffer = .{ .data = &response, .len = 0, .capacity = response.len };
            const rc = dev.protocolDispatch(role, 3, &request, &result);
            const ok = rc == 0 and result.len <= response.len and std.mem.indexOf(u8, response[0..result.len], "selftest OK") != null;
            out.record("entropy_protocol", "entropy", 0, .{ .role = role, .result = rc, .passed = ok });
            if (!ok) return 1;
        }
    }
    out.record("entropy_completed", "entropy", 0, .{ .configured_cpus = first.configured_cpus, .created = created, .reaped = reaped, .missing = missing, .standard_modified = false });
    out.message("entropy", "SPECTRA entropy: ok; queue receipts establish provenance, byte contents are not logged.", false);
    return 0;
}
