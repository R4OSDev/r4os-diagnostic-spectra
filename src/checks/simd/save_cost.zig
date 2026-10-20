//! Explicit local save/restore cost diagnostic, independent of STANDARD.
//! All predetermined samples are retained, including asynchronous disturbance.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const image = @import("environment_image.zig");
const burst = @import("save_cost_asm.zig");
const observed = @import("observed.zig");
var sys: r4os.r4sys.Context = undefined;
var dev: r4os.r4dev.Context = undefined;
var gate: std.atomic.Value(u32) = .init(0);
const Sample = struct { cycles: u64 = 0, info: a.FpuObservationInfo = .{} };
var samples: [3][7][2]Sample = @splat(@splat(@splat(.{})));
var code: i32 = -1;
var supported: bool = false;
var active_bytes: usize = 0;
const Cpuid = struct { eax: u32, ebx: u32, ecx: u32, edx: u32 };
fn cpuid(leaf: u32, subleaf: u32) Cpuid {
    var eax: u32 = 0;
    var ebx: u32 = 0;
    var ecx: u32 = 0;
    var edx: u32 = 0;
    asm volatile ("cpuid"
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx),
        : [leaf] "{eax}" (leaf),
          [subleaf] "{ecx}" (subleaf),
    );
    return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
}
fn valid(pattern: *const image.Pattern, config: burst.Config, out: *const burst.Output, state: *const burst.State, active: usize) bool {
    if (out.cycles == 0 or image.u64At(&state.bytes, 512) & ~@as(u64, 7) != 0 or image.u64At(&state.bytes, 520) != 0) return false;
    for (state.bytes[528..576]) |b| if (b != 0) return false;
    for (state.bytes[active..]) |b| if (b != 0xa5) return false;
    if (config.variant != 0) return image.valid(pattern, config.control, &out.fp);
    if (!image.defaults(out.fp.bytes[0..512]) or !image.defaults(out.fp.bytes[512..1024])) return false;
    for (out.fp.bytes[1024..1536]) |b| if (b != 0) return false;
    return image.u64At(&out.fp.bytes, 1536) == 2 and image.u64At(&out.fp.bytes, 1544) == 2 and out.fp.bytes[1604] == 0;
}
fn worker(_: u64) callconv(.c) i32 {
    while (gate.load(.acquire) == 0) sys.sleepTicks(1);
    if (gate.load(.acquire) != 1) return 220;
    if (!@import("placement.zig").cpu0(&sys)) return 221;
    const base = cpuid(0, 0);
    const features = cpuid(1, 0);
    if (base.eax < 0xd or features.edx & (1 << 4) == 0 or features.ecx & (1 << 27) == 0 or cpuid(0xd, 1).eax & 1 == 0) {
        code = 0;
        return 248;
    }
    var xcr0_low: u32 = 0;
    var xcr0_high: u32 = 0;
    asm volatile ("xgetbv"
        : [lo] "={eax}" (xcr0_low),
          [hi] "={edx}" (xcr0_high),
        : [index] "{ecx}" (@as(u32, 0)),
    );
    const active: usize = cpuid(0xd, 0).ebx;
    if (xcr0_low != 7 or xcr0_high != 0 or active < 832 or active > 4096) return 222;
    supported = true;
    active_bytes = active;
    const pattern = image.Pattern.init(0x4801);
    for (0..3) |variant| {
        for (0..7) |repetition| {
            // Alternate the mode order before measuring; never select samples.
            for (0..2) |order| {
                const mode = (order + repetition) % 2;
                const config: burst.Config = .{ .control = image.Control.init(if (variant == 0) 0 else 1, 0, true, 0), .mode = @intCast(mode), .variant = @intCast(variant) };
                var state: burst.State = .{};
                @memset(state.bytes[active..], 0xa5);
                var out: burst.Output = .{};
                const scope = observed.Scope.begin(&dev, burst.window()) orelse return 223;
                burst.execute(&state, &out, &pattern, &config);
                const info = scope.finish(&dev) orelse return 224;
                samples[variant][repetition][mode] = .{ .cycles = out.cycles, .info = info };
                if (!valid(&pattern, config, &out, &state, active)) return 225;
            }
        }
    }
    code = 0;
    return 248;
}
pub fn run(app: *r4os.App) i32 {
    sys = app.system();
    dev = app.devicesLowLevel() orelse return 2;
    if (!dev.hasFn("fpu_observation")) return 2;
    const summary = dev.performanceSummary() orelse return 2;
    if (summary.fpu_avx_enabled != 1 or summary.fpu_avx2_enabled != 1) return 2;
    code = -1;
    supported = false;
    samples = @splat(@splat(@splat(.{})));
    gate.store(0, .release);
    var handle: a.ProgramJoinHandle = .{};
    if (sys.threadCreateHandle(worker, 0, 128 * 1024, 0, &handle) != a.thread_ok) return 1;
    const policy: a.ThreadPlacementRequest = .{ .preferred_cpu = 0 };
    const mask = [_]u64{1};
    const prepared = sys.threadPlacementSet(&handle, &policy, &mask) == a.thread_ok;
    gate.store(if (prepared) 1 else 2, .release);
    var exit: i32 = -1;
    const joined = sys.threadHandleJoin(&handle, a.thread_wait_forever, &exit);
    if (!prepared or joined != a.thread_ok or exit != 248 or code != 0) {
        sys.write("SPECTRA SIMD savecost result: FAILED exit=");
        sys.printI32(exit);
        sys.println("");
        return 1;
    }
    if (!supported) {
        sys.println("SPECTRA SIMD savecost result: unavailable local XSAVEOPT/TSC");
        return 0;
    }
    for (samples, 0..) |variant_samples, variant| {
        for (variant_samples, 0..) |pair, repetition| {
            for (pair, 0..) |sample, mode| {
                sys.write("SAVECOST48 variant=");
                sys.printU64(variant);
                sys.write(" repetition=");
                sys.printU64(repetition);
                sys.write(" mode=");
                sys.write(if (mode == 0) "classic" else "xsaveopt");
                sys.write(" pairs=256 tscCycles=");
                sys.printU64(sample.cycles);
                sys.write(" native=");
                sys.printU64(sample.info.task_id);
                sys.write(" generation=");
                sys.printU64(sample.info.task_generation);
                sys.write(" timerIrqs=");
                sys.printU64(sample.info.timer_irqs);
                sys.write(" timerSwitches=");
                sys.printU64(sample.info.timer_preemptions);
                sys.write(" cpuMask=");
                sys.printU64(sample.info.observed_cpus);
                sys.println(" oracle=PASS");
            }
        }
    }
    sys.write("SPECTRA SIMD savecost result: OK samples=42 variants=3 repetitions=7 pairs=256 layout=standard mask=7 bytes=");
    sys.printU64(active_bytes);
    sys.println(" canary=1 allSamplesRetained=1 callsInsideLiveWindow=0 units=guest-TSC-cycles scope=restore-modify-save-loop vmAndInterruptCostIncluded=1 noIsolatedSchedulerGainClaim=1");
    return 0;
}
