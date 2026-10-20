//! Explicit CPU-local optional ISA/memory consumer checks and observations.
//! Uses real joined workers. Times are contextual observations, never scores.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const Output = @import("output.zig").Output;
const Atomic = std.atomic.Value(u32);
var sys: r4os.r4sys.Context = undefined;
var dev: r4os.r4dev.Context = undefined;
var execute: ?r4os.cpu_acceleration.WorkFn = null;
fn provider() ?r4os.cpu_acceleration.WorkFn {
    // Same conservative hint as the productive consumers. The mandatory work
    // window still revalidates the exact CPU; this never grants an instruction.
    return if (job.info.os_mask & a.cpu_accel_feature_sha != 0) execute else null;
}
const Hash = r4os.crypto_sha256.Sha256(provider);
var gate: Atomic = .init(0);
var done: Atomic = .init(0);
var words: [128]u64 = .{0} ** 128;
const Sizes = [_]usize{ 0, 1, 55, 56, 63, 64, 65, 255, 256, 511, 512, 513, 4095, 4096, 4097, 8192 };
const Observation = struct { bytes: usize = 0, repetitions: u32 = 0, base_ns: u64 = 0, selected_ns: u64 = 0 };
const Job = struct {
    info: a.CpuAccelerationInfo = .{},
    receipt: a.CpuAccelerationWork = .{},
    sha_result: i32 = -1,
    callbacks: u32 = 0,
    vectors: u32 = 0,
    accepted_blocks: usize = 0,
    refused_windows: usize = 0,
    memory_cases: u32 = 0,
    copies: [4]Observation = .{Observation{}} ** 4,
    hash: Observation = .{},
};
var job: Job = .{};
fn now() u64 { return sys.monotonicNanoseconds() orelse 0; }
fn current(cpu: u32) bool {
    var h: a.ProgramJoinHandle = .{};
    var p: a.ThreadPlacementInfo = .{};
    return sys.threadCurrentHandle(&h) == a.thread_ok and sys.threadPlacementGet(&h, &p, &.{}) == a.thread_ok and
        p.running_cpu == cpu and p.home_cpu == cpu and p.request_revision == p.applied_revision;
}
noinline fn pure(context: u64, count: u32) callconv(.c) i32 {
    const out: *volatile u32 = @ptrFromInt(context);
    out.* += count;
    return 0;
}
fn same(comptime T: type, x: *const T, y: *const T) bool {
    return std.mem.eql(u8, std.mem.asBytes(x), std.mem.asBytes(y));
}
noinline fn copyBase(dst: []u8, src: []const u8) void { (r4os.cpu_memory.Policy{}).move(dst, src); }
noinline fn hashBase(src: []const u8, dst: *[32]u8) void { std.crypto.hash.sha2.Sha256.hash(src, dst, .{}); }
fn barrier() void { asm volatile ("" ::: .{ .memory = true }); }
fn cases(cpu: u32) i32 {
    if (!current(cpu) or dev.cpuAccelerationInfo(&job.info) != 0 or job.info.cpu_index != cpu or job.info.epoch == 0 or job.info.feature_count != 61) return 11;
    const has_sha = job.info.os_mask & a.cpu_accel_feature_sha != 0;
    var invalid: a.CpuAccelerationInfo = .{ .version = 0, .epoch = 0xabcd };
    const before = invalid;
    if (dev.cpuAccelerationInfo(&invalid) != a.cpu_capabilities_error_invalid or !same(a.CpuAccelerationInfo, &before, &invalid)) return 12;
    var refused: a.CpuAccelerationWork = .{ .begin_ns = 0xabcd };
    const prior = refused;
    if (dev.cpuAccelerationWork(2, 1, pure, @intFromPtr(&job.callbacks), &refused) != a.cpu_capabilities_error_invalid or
        dev.cpuAccelerationWork(0, 0, pure, @intFromPtr(&job.callbacks), &refused) != a.cpu_capabilities_error_invalid or
        dev.cpuAccelerationWork(0, 65, pure, @intFromPtr(&job.callbacks), &refused) != a.cpu_capabilities_error_invalid or
        dev.cpuAccelerationWork(0, 1, null, 0, &refused) != a.cpu_capabilities_error_invalid or !same(a.CpuAccelerationWork, &prior, &refused) or job.callbacks != 0) return 13;
    job.sha_result = dev.cpuAccelerationWork(a.cpu_accel_work_kind_sha256, 1, pure, @intFromPtr(&job.callbacks), &job.receipt);
    if (has_sha) {
        if (job.sha_result != 0 or job.callbacks != 1 or !r4os.cpu_acceleration.accepted(&job.receipt, a.cpu_accel_work_kind_sha256, 1)) return 14;
    } else if (job.sha_result != a.cpu_capabilities_error_unsupported or job.callbacks != 0) return 15;
    var data: [8192]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @truncate(i *% 73 +% cpu);
    for (Sizes) |size| {
        var expected: [32]u8 = undefined;
        hashBase(data[0..size], &expected);
        var hash = Hash.init(.{});
        hash.update(data[0..@min(size, 17)]);
        hash.update(data[@min(size, 17)..size]);
        const result = hash.finalResult();
        if (!std.mem.eql(u8, &expected, &result)) return 16;
        job.accepted_blocks += hash.accepted_blocks;
        job.refused_windows += hash.refused_windows;
        job.vectors += 1;
    }
    if (has_sha and job.accepted_blocks == 0) return 17;
    var expected_mac: [32]u8 = undefined;
    var actual_mac: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&expected_mac, &data, "bounded SHA consumer");
    std.crypto.auth.hmac.Hmac(Hash).create(&actual_mac, &data, "bounded SHA consumer");
    if (!std.mem.eql(u8, &expected_mac, &actual_mac)) return 18;
    const policy = r4os.cpu_memory.Policy.fromInfo(&job.info);
    var memory: [65536 + 128]u8 = undefined;
    var reference: [65536 + 128]u8 = undefined;
    for ([_]usize{ 0, 1, 31, 63 }) |alignment| for (Sizes) |size| {
        @memset(&memory, 0xa5);
        policy.move(memory[alignment..][0..size], data[0..size]);
        if (!std.mem.eql(u8, memory[alignment..][0..size], data[0..size]) or memory[alignment + size] != 0xa5 or (alignment != 0 and memory[alignment - 1] != 0xa5)) return 19;
        job.memory_cases += 1;
    };
    for ([_]usize{ 1, 31, 257 }) |distance| for ([_]bool{ false, true }) |backward| {
        @memset(&memory, 0xa5);
        @memcpy(memory[0..8192], &data);
        reference = memory;
        const start: usize = if (backward) 0 else distance;
        const target: usize = if (backward) distance else 0;
        if (backward) std.mem.copyBackwards(u8, reference[target..][0..4096], reference[start..][0..4096])
        else std.mem.copyForwards(u8, reference[target..][0..4096], reference[start..][0..4096]);
        policy.move(memory[target..][0..4096], memory[start..][0..4096]);
        if (!std.mem.eql(u8, &memory, &reference)) return 20;
        job.memory_cases += 1;
    };
    // Warm both ordinary memory implementations. Equal owned work and buffers;
    // the explicit comparator always reaches the real baseline function.
    @memset(&reference, 0x6b);
    copyBase(&memory, &reference);
    policy.move(&memory, &reference);
    for ([_]usize{ 256, 512, 4096, 65536 }, 0..) |size, index| {
        const n: u32 = 256;
        const begin = now();
        for (0..n) |_| { copyBase(memory[0..size], reference[0..size]); barrier(); }
        const middle = now();
        for (0..n) |_| { policy.move(memory[0..size], reference[0..size]); barrier(); }
        const end = now();
        if (begin == 0 or middle < begin or end < middle or !std.mem.eql(u8, memory[0..size], reference[0..size])) return 21;
        job.copies[index] = .{ .bytes = size, .repetitions = n, .base_ns = middle - begin, .selected_ns = end - middle };
    }
    var digest: [32]u8 = undefined;
    hashBase(&data, &digest);
    Hash.hash(&data, &digest, .{});
    const begin = now();
    for (0..32) |_| { hashBase(&data, &digest); barrier(); }
    const middle = now();
    for (0..32) |_| { Hash.hash(&data, &digest, .{}); barrier(); }
    const end = now();
    if (begin == 0 or middle < begin or end < middle) return 22;
    job.hash = .{ .bytes = data.len, .repetitions = 32, .base_ns = middle - begin, .selected_ns = end - middle };
    return if (current(cpu)) 0 else 23;
}
fn worker(raw: u64) callconv(.c) i32 {
    defer done.store(1, .release);
    const begun = now();
    while (gate.load(.acquire) == 0) {
        if (now() -| begun > 5_000_000_000) return 10;
        sys.sleepTicks(1);
    }
    return if (gate.load(.acquire) == 1) cases(@intCast(raw)) else 9;
}
pub fn run(app: *r4os.App, out: *Output) i32 {
    sys = app.system();
    dev = app.devicesLowLevel() orelse return 2;
    execute = dev.cpuAccelerationWorkFunction() orelse return 2;
    var first: a.CpuAccelerationInfo = .{};
    if (dev.cpuAccelerationInfo(&first) != 0 or first.configured_cpus == 0) return 2;
    const word_count = (@as(usize, first.configured_cpus) + 63) / 64;
    if (word_count > words.len) return 2;
    var created: u32 = 0;
    var reaped: u32 = 0;
    for (0..first.configured_cpus) |cpu| {
        job = .{};
        gate.store(0, .release);
        done.store(0, .release);
        var handle: a.ProgramJoinHandle = .{};
        if (sys.computeWorkerCreate(worker, cpu, 256 * 1024, &handle) != a.thread_ok) return 1;
        created += 1;
        @memset(&words, 0);
        words[cpu / 64] = @as(u64, 1) << @intCast(cpu % 64);
        const request: a.ThreadPlacementRequest = .{ .preferred_cpu = @intCast(cpu), .work_class = a.thread_placement_class_batch };
        var prepared = sys.threadPlacementSet(&handle, &request, words[0..word_count]) == a.thread_ok;
        const begun = now();
        while (prepared) {
            var placement: a.ThreadPlacementInfo = .{};
            if (sys.threadPlacementGet(&handle, &placement, &.{}) != a.thread_ok) { prepared = false; break; }
            if (placement.request_revision == placement.applied_revision and placement.home_cpu == cpu) break;
            if (now() -| begun > 5_000_000_000) { prepared = false; break; }
            sys.sleepTicks(1);
        }
        gate.store(if (prepared) 1 else 2, .release);
        var code: i32 = -1;
        const joined = sys.threadHandleJoin(&handle, sys.ticksFromMilliseconds(10000), &code);
        if (joined != a.thread_ok) {
            out.record("cpu_acceleration_retained", "cpu_acceleration", cpu, .{ .joined = joined, .created = created, .reaped = reaped });
            _ = sys.programExit(24, a.program_exit_reason_failed);
            while (true) sys.sleepTicks(1);
        }
        reaped += 1;
        out.record("cpu_acceleration_info", "cpu_acceleration", cpu, job.info);
        out.record("cpu_acceleration_work", "cpu_acceleration", cpu, job.receipt);
        out.record("cpu_acceleration_check", "cpu_acceleration", cpu, .{ .result = code, .prepared = prepared, .vectors = job.vectors, .memory_cases = job.memory_cases, .accepted_blocks = job.accepted_blocks, .refused_windows = job.refused_windows, .sha_result = job.sha_result, .callbacks = job.callbacks });
        for (job.copies) |value| out.record("cpu_memory_observation", "cpu_acceleration", cpu, value);
        out.record("cpu_hash_observation", "cpu_acceleration", cpu, job.hash);
        if (!prepared or code != 0 or done.load(.acquire) == 0) return 1;
    }
    var input: [1]u8 = .{0};
    var response: [512]u8 = undefined;
    const request: a.ProtocolBuffer = .{ .data = &input, .len = 0, .capacity = input.len };
    var result: a.ProtocolBuffer = .{ .data = &response, .len = 0, .capacity = response.len };
    const protocol_rc = dev.protocolDispatch("security.tls", 3, &request, &result);
    const tls_ok = protocol_rc == 0 and result.len <= response.len and
        std.mem.indexOf(u8, response[0..result.len], "R4TLS selftest OK;live=ok;client=ok;x509=ok;app_write=ok;app_read=ok") != null;
    out.record("cpu_acceleration_protocol", "cpu_acceleration", 0, .{ .result = protocol_rc, .tls_full_selftest = tls_ok });
    if (!tls_ok) return 1;
    out.record("cpu_acceleration_completed", "cpu_acceleration", 0, .{ .configured_cpus = first.configured_cpus, .created = created, .reaped = reaped, .standard_modified = false });
    out.message("cpu_acceleration", "SPECTRA CPU acceleration: ok; observed durations apply only to this CPU, work size and environment.", false);
    return 0;
}
