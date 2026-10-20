//! Full active register/control cases. Public APIs only surround complete
//! assembly bursts; exact native-task/RIP counters qualify asynchronous events.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const image = @import("environment_image.zig");
const burst = @import("environment_asm.zig");
const observed = @import("observed.zig");
const controls = @import("controls_asm.zig");
var sys: r4os.r4sys.Context = undefined;
var dev: r4os.r4dev.Context = undefined;
var gate: std.atomic.Value(u32) = .init(0);
const Job = struct { code: i32 = -1, exit: i32 = -1, cases: u32 = 0, mask: u32 = 0, phases: [3]observed.Evidence = .{ .{}, .{}, .{} } };
var jobs: [2]Job = .{ .{}, .{} };
fn protocol(_: usize) callconv(.c) i32 {
    var input = [_]u8{ 0x46, 0x87, 0x58, 0x4d };
    var output: [4]u8 = @splat(0);
    const in_buffer: a.ProtocolBuffer = .{ .data = &input, .len = input.len, .capacity = input.len, .flags = 0, .reserved = 0 };
    var out_buffer: a.ProtocolBuffer = .{ .data = &output, .len = 0, .capacity = output.len, .flags = 0, .reserved = 0 };
    const rc = dev.protocolDispatch("misc.example", 1, &in_buffer, &out_buffer);
    return if (rc == 0 and out_buffer.len == input.len and std.mem.eql(u8, &input, &output)) 0 else 1;
}
fn legacy(out: *align(64) [512]u8) void {
    asm volatile ("fxsave64 (%[out])"
        :
        : [out] "r" (out),
        : .{ .memory = true });
}
fn worker(arg: u64) callconv(.c) i32 {
    const slot: usize = @intCast(arg);
    while (gate.load(.acquire) == 0) sys.sleepTicks(1);
    if (gate.load(.acquire) != 1) return 210;
    if (!@import("placement.zig").cpu0(&sys)) return 211;
    var raw: [512]u8 align(64) = @splat(0);
    legacy(&raw);
    if (!image.defaults(&raw)) return 212;
    const mask = image.mxcsrMask(&raw);
    jobs[slot].mask = mask;
    const pattern = image.Pattern.init(0x4600 + @as(u32, @intCast(slot)));
    var out: image.Output = .{};
    for (0..4) |round| {
        for (0..4) |variant| {
            const extras: u32 = (if (variant & 1 != 0) @as(u32, 0x40) else 0) | (if (variant & 2 != 0) @as(u32, 0x8000) else 0);
            if (extras & ~mask != 0) continue;
            for (0..3) |phase| {
                const control = image.Control.init(@intCast(round), extras, true, @intCast(phase));
                const scope = observed.Scope.begin(&dev, burst.window()) orelse return 213;
                burst.execute(&pattern, &out, &control, 65536);
                const info = scope.finish(&dev) orelse return 214;
                if (!jobs[slot].phases[phase].add(info)) return 215;
                if (!image.valid(&pattern, control, &out)) return 216;
                jobs[slot].cases += 1;
            }
        }
    }
    jobs[slot].code = 0;
    return 201 + @as(i32, @intCast(slot));
}
pub fn run(app: *r4os.App) i32 {
    sys = app.system();
    dev = app.devicesLowLevel() orelse return 2;
    if (!dev.hasFn("fpu_observation")) return 2;
    const summary = dev.performanceSummary() orelse return 2;
    if (summary.fpu_avx_enabled != 1 or summary.fpu_avx2_enabled != 1) return 2;
    const ordinary = controls.check(protocol, 0);
    sys.println(if (ordinary) "SPECTRA SIMD ordinary SysV controls: OK r4p=indirect data=caller-saved" else "SPECTRA SIMD ordinary SysV controls: FAILED");
    if (!ordinary) return 1;
    jobs = .{ .{}, .{} };
    gate.store(0, .release);
    var handles: [2]a.ProgramJoinHandle = .{ .{}, .{} };
    var made: usize = 0;
    for (&handles, 0..) |*handle, i| {
        if (sys.threadCreateHandle(worker, i, 128 * 1024, 0, handle) != a.thread_ok) break;
        made += 1;
    }
    var prepared = made == 2;
    const policy: a.ThreadPlacementRequest = .{ .preferred_cpu = 0 };
    const mask = [_]u64{1};
    for (handles[0..made]) |*handle| if (sys.threadPlacementSet(handle, &policy, &mask) != a.thread_ok) {
        prepared = false;
    };
    gate.store(if (prepared) 1 else 2, .release);
    var ok = prepared;
    for (handles[0..made], 0..) |*handle, i| {
        var code: i32 = -1;
        const joined = sys.threadHandleJoin(handle, a.thread_wait_forever, &code);
        jobs[i].exit = code;
        ok = joined == a.thread_ok and code == 201 + @as(i32, @intCast(i)) and jobs[i].code == 0 and jobs[i].cases > 0 and ok;
    }
    for (jobs, 0..) |job, i| {
        sys.write("SPECTRA SIMD environment worker=");
        sys.printU64(i);
        sys.write(" cases=");
        sys.printU64(job.cases);
        sys.write(" mxcsrMask=");
        sys.printU64(job.mask);
        sys.write(" code=");
        sys.printI32(job.code);
        sys.write(" exit=");
        sys.printI32(job.exit);
        sys.println("");
        job.phases[0].print(&sys, "  ENV full-x87");
        job.phases[1].print(&sys, "  ENV mmx-alias");
        job.phases[2].print(&sys, "  ENV sparse-x87");
    }
    sys.println(if (ok) "SPECTRA SIMD environment result: OK vectors=16 x87=8 top=rotated tags=full-sparse mmx=8 rounding=4 valid-ftz-daz=yes callsInsideLiveWindow=0" else "SPECTRA SIMD environment result: FAILED");
    return if (ok) 0 else 1;
}
