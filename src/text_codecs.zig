//! Explicit tests of the real imported R4STD provider; never part of STANDARD.
const std = @import("std");
const r4os = @import("r4os");
const r4std = @import("r4std");
const a = r4os.abi;
const c = r4std.codec;
const Output = @import("output.zig").Output;
const Atomic = std.atomic.Value(u32);
var sys: r4os.r4sys.Context = undefined;
var dev: r4os.r4dev.Context = undefined;
var gate: Atomic = .init(0);
var done: Atomic = .init(0);
var job: struct {
    failure: []const u8 = "",
    actual_cpu: u32 = std.math.maxInt(u32),
    mappings: u32 = 0,
    undefined_bytes: u32 = 0,
    scalar_cases: u32 = 0,
    split_cases: u32 = 0,
    roundtrip_bytes: u32 = 0,
    document_bytes: u32 = 0,
} = .{};

fn mapping(codepage: c.Codepage, mode: c.Mode, hash_hex: []const u8) !void {
    var words: [1024]u8 = undefined;
    for (0..256) |index| {
        const byte: u8 = @intCast(index);
        const scalar = c.legacyDecode(codepage, mode, byte) catch |err| {
            if (codepage != .windows1252 or mode != .controls or err != error.UndefinedByte or
                !(byte == 0x81 or byte == 0x8d or byte == 0x8f or byte == 0x90 or byte == 0x9d)) return error.WrongHole;
            std.mem.writeInt(u32, words[index * 4 ..][0..4], 0xffffffff, .little);
            job.undefined_bytes += 1;
            continue;
        };
        std.mem.writeInt(u32, words[index * 4 ..][0..4], scalar, .little);
        if (try c.legacyEncode(codepage, mode, scalar) != byte) return error.Inverse;
        var encoded: [4]u8 = undefined;
        const utf8 = try c.encode(scalar, &encoded);
        const decoded = (try c.decode(utf8)).complete;
        if (decoded.value != scalar or decoded.byte_length != utf8.len) return error.Utf8;
        job.mappings += 1;
    }
    var actual: [32]u8 = undefined;
    var expected: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&words, &actual, .{});
    _ = try std.fmt.hexToBytes(&expected, hash_hex);
    if (!std.mem.eql(u8, &actual, &expected)) return error.OfficialMapping;
}
fn cases(cpu: u32) !void {
    var info: a.CpuAccelerationInfo = .{};
    if (dev.cpuAccelerationInfo(&info) != 0 or info.cpu_index != cpu) return error.Placement;
    job.actual_cpu = info.cpu_index;
    try mapping(.cp437, .controls, "3b331692abddbdfa697e0e3b15e34d07859840f1d94e36eef8d34985405235ed");
    try mapping(.windows1252, .controls, "5ec4fd69b5ccaa999c8d15a2f30f1bed47757c063df0b27f9175cc118ff4f0c5");
    try mapping(.cp437, .pc_graphics, "2446a15fd3bc89a9b6eaf0e55d747a700224bac411e77e083c240e69a845939f");
    if (try c.legacyDecode(.cp437, .controls, 1) != 1 or try c.legacyDecode(.cp437, .pc_graphics, 1) != 0x263a) return error.Mode;
    if (c.legacyDecode(.cp850, .controls, 0x81)) |_| return error.Cp850Alias else |err| if (err != error.InvalidArgument) return err;
    if (c.legacyEncode(.cp437, .controls, 0x20ac)) |_| return error.Substitution else |err| if (err != error.Unrepresentable) return err;
    for ([_]u32{ 0, 0x7f, 0x80, 0x7ff, 0x800, 0xd7ff, 0xe000, 0xfdd0, 0xffff, 0x10000, 0x1f600, 0x10ffff }) |scalar| {
        var bytes: [4]u8 = undefined;
        var oracle: [4]u8 = undefined;
        const length = try std.unicode.utf8Encode(@intCast(scalar), &oracle);
        const encoded = try c.encode(scalar, &bytes);
        if (!std.mem.eql(u8, encoded, oracle[0..length]) or (try c.decode(encoded)).complete.value != scalar) return error.Scalar;
        job.scalar_cases += 1;
        for (0..encoded.len + 1) |cut| {
            var stream: c.Stream = .{};
            var final: ?u32 = null;
            for (encoded[0..cut]) |byte| switch (try stream.push(byte)) {
                .complete => |value| final = value.value,
                .incomplete => {},
            };
            if (try stream.finish() != (cut == 0 or cut == encoded.len)) return error.Incomplete;
            for (encoded[cut..]) |byte| switch (try stream.push(byte)) {
                .complete => |value| final = value.value,
                .incomplete => {},
            };
            if (!try stream.finish() or final != scalar or stream.state.length != 0) return error.Stream;
            job.split_cases += 1;
        }
    }
    var one: c.Stream = .{};
    var two: c.Stream = .{};
    _ = try one.push(0xc3);
    _ = try two.push(0xf0);
    _ = try two.push(0x9f);
    if ((try one.push(0xbc)).complete.value != 0xfc) return error.MixedStream;
    _ = try two.push(0x98);
    if ((try two.push(0x80)).complete.value != 0x1f600) return error.MixedStream;
    one.reset();
    _ = try one.push(0xe0);
    const before = one.state;
    if (one.push(0x80)) |_| return error.Overlong else |err| if (err != error.InvalidUtf8) return err;
    if (!std.mem.eql(u8, std.mem.asBytes(&before), std.mem.asBytes(&one.state)) or try one.finish()) return error.ErrorState;
    if (one.push('A')) |_| return error.BadContinuation else |err| if (err != error.InvalidUtf8) return err;
    one.reset();
    if ((try one.push('A')).complete.value != 'A') return error.LostAscii;
    for ([_][]const u8{ "\xc0\x80", "\xc1\xbf", "\xe0\x80\x80", "\xed\xa0\x80", "\xf0\x80\x80\x80", "\xf4\x90\x80\x80", "\xf5\x80\x80\x80", "\x80", "\xff" }) |bad| {
        if (c.decode(bad)) |_| return error.InvalidAccepted else |err| if (err != error.InvalidUtf8) return err;
    }
    var original: [256]u8 = undefined;
    for (&original, 0..) |*byte, index| byte.* = @intCast(index);
    var encoded: [768]u8 = undefined;
    var back: [256]u8 = undefined;
    for ([_]c.Mode{ .controls, .pc_graphics }) |mode| {
        const utf8 = try c.legacyToUtf8(.cp437, mode, &original, &encoded);
        if (!std.mem.eql(u8, &original, try c.utf8ToLegacy(.cp437, mode, utf8, &back))) return error.Roundtrip;
        job.roundtrip_bytes += original.len;
    }
    const document = try r4std.text.DocumentText.init(&original);
    if (document.encoding != .bytes or !std.mem.eql(u8, &original, try document.writeExact(&back))) return error.Document;
    job.document_bytes = original.len;
    const sentinel: [8]u8 = @splat(0xa5);
    var output = sentinel;
    if (c.legacyToUtf8(.windows1252, .controls, "A\x81", &output)) |_| return error.HoleAccepted else |err| if (err != error.UndefinedByte) return err;
    if (!std.mem.eql(u8, &sentinel, &output)) return error.PartialOutput;
    if (c.utf8ToLegacy(.cp437, .controls, "A\xf0\x9f\x98\x80", &output)) |_| return error.ReplaceAccepted else |err| if (err != error.Unrepresentable) return err;
    if (!std.mem.eql(u8, &sentinel, &output)) return error.PartialOutput;
    if (c.legacyToUtf8(.cp437, .controls, &original, &output)) |_| return error.Capacity else |err| if (err != error.BufferTooSmall) return err;
    if (!std.mem.eql(u8, &sentinel, &output)) return error.PartialOutput;
}
fn worker(raw: u64) callconv(.c) i32 {
    defer done.store(1, .release);
    const start = sys.monotonicNanoseconds() orelse return 8;
    while (gate.load(.acquire) == 0) {
        if ((sys.monotonicNanoseconds() orelse return 8) -| start > 5_000_000_000) return 9;
        sys.sleepTicks(1);
    }
    if (gate.load(.acquire) != 1) return 10;
    cases(@intCast(raw)) catch |err| {
        job.failure = @errorName(err);
        return 11;
    };
    return 0;
}
pub fn run(app: *r4os.App, out: *Output) i32 {
    sys = app.system();
    dev = app.devicesLowLevel() orelse return 2;
    if (!r4std.init(app.raw)) return 2;
    var first: a.CpuAccelerationInfo = .{};
    if (dev.cpuAccelerationInfo(&first) != 0 or first.configured_cpus == 0 or first.configured_cpus > 64) return 2;
    var created: u32 = 0;
    var reaped: u32 = 0;
    for (0..first.configured_cpus) |cpu| {
        job = .{};
        gate.store(0, .release);
        done.store(0, .release);
        var handle: a.ProgramJoinHandle = .{};
        if (sys.computeWorkerCreate(worker, cpu, 256 * 1024, &handle) != a.thread_ok) return 1;
        created += 1;
        const mask = [_]u64{@as(u64, 1) << @intCast(cpu)};
        const request: a.ThreadPlacementRequest = .{ .preferred_cpu = @intCast(cpu), .work_class = a.thread_placement_class_batch };
        var prepared = sys.threadPlacementSet(&handle, &request, &mask) == a.thread_ok;
        const started = sys.monotonicNanoseconds() orelse 0;
        while (prepared) {
            var placement: a.ThreadPlacementInfo = .{};
            if (sys.threadPlacementGet(&handle, &placement, &.{}) != a.thread_ok) {
                prepared = false;
                break;
            }
            if (placement.request_revision == placement.applied_revision and placement.home_cpu == cpu) break;
            if ((sys.monotonicNanoseconds() orelse std.math.maxInt(u64)) -| started > 5_000_000_000) {
                prepared = false;
                break;
            }
            sys.sleepTicks(1);
        }
        gate.store(if (prepared) 1 else 2, .release);
        var code: i32 = -1;
        if (sys.threadHandleJoin(&handle, sys.ticksFromMilliseconds(20000), &code) != a.thread_ok) {
            out.record("text_codecs_retained", "text", cpu, .{ .created = created, .reaped = reaped });
            _ = sys.programExit(30, a.program_exit_reason_failed);
            while (true) sys.sleepTicks(1);
        }
        reaped += 1;
        out.record("text_codecs_check", "text", cpu, .{ .result = code, .prepared = prepared, .actual_cpu = job.actual_cpu, .failure = job.failure, .mappings = job.mappings, .undefined_bytes = job.undefined_bytes, .scalar_cases = job.scalar_cases, .split_cases = job.split_cases, .roundtrip_bytes = job.roundtrip_bytes, .document_bytes = job.document_bytes });
        if (!prepared or code != 0 or done.load(.acquire) == 0) return 1;
    }
    out.record("text_codecs_completed", "text", 0, .{ .configured_cpus = first.configured_cpus, .created = created, .reaped = reaped, .library_version = @as([]const u8, "0.2.5"), .byte_scalar_grapheme_distinct = true, .standard_modified = false });
    out.message("text", "SPECTRA text codecs: ok; actual imported R4STD mappings/streams and exact document bytes.", false);
    return 0;
}
