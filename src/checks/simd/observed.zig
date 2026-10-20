//! Register data lives only inside complete SysV assembly functions. Ordinary
//! API calls surround those functions; callers observe stored memory only.
const r4os = @import("r4os");
const abi = r4os.abi;
pub const Window = struct { begin: u64, end: u64 };
extern fn r4os_spectra_avx_burst(*const [32]u8, *[32]u8, *volatile u64, u64) callconv(.c) void;
extern fn r4os_spectra_chain_burst(*const [8]u32, *[8]u32, *const [8]u32, *const [8]u32, u64) callconv(.c) void;
pub fn registerWindow() Window {
    var begin: u64 = undefined;
    var end: u64 = undefined;
    // Explicit PC32 addresses avoid preemptible data/GOT relaxation in R4M0.
    asm ("leaq r4os_spectra_avx_live_begin(%%rip), %[begin]\n\tleaq r4os_spectra_avx_live_end(%%rip), %[end]"
        : [begin] "=r" (begin),
          [end] "=r" (end),
    );
    return .{ .begin = begin, .end = end };
}
pub fn chainWindow() Window {
    var begin: u64 = undefined;
    var end: u64 = undefined;
    // Explicit PC32 addresses avoid preemptible data/GOT relaxation in R4M0.
    asm ("leaq r4os_spectra_chain_live_begin(%%rip), %[begin]\n\tleaq r4os_spectra_chain_live_end(%%rip), %[end]"
        : [begin] "=r" (begin),
          [end] "=r" (end),
    );
    return .{ .begin = begin, .end = end };
}
pub fn registers(src: *const [32]u8, dst: *[32]u8, sink: *volatile u64, round: u32) void {
    r4os_spectra_avx_burst(src, dst, sink, @as(u64, round) + 31);
}
pub fn chain(seed: u32, count: u32) u64 {
    var input: [8]u32 = undefined;
    var output: [8]u32 = undefined;
    for (&input, 0..) |*lane, i| lane.* = seed +% (@as(u32, @intCast(i)) *% 0x9e37_79b9);
    const multiplier: [8]u32 = @splat(1664525);
    const addend: [8]u32 = @splat(1013904223);
    r4os_spectra_chain_burst(&input, &output, &multiplier, &addend, count);
    var sum: u64 = 0;
    for (output) |lane| sum +%= lane;
    return sum;
}
pub const Scope = struct {
    request: abi.FpuObservationRequest,
    before: abi.FpuObservationInfo,
    pub fn begin(dev: *const r4os.r4dev.Context, window: Window) ?Scope {
        const request = abi.FpuObservationRequest{ .operation = abi.fpu_observation_begin, .rip_begin = window.begin, .rip_end = window.end };
        var info: abi.FpuObservationInfo = .{};
        if (dev.fpuObservation(&request, &info) != 0 or info.version != 1 or info.size != 128 or info.flags != abi.fpu_observation_flag_available | abi.fpu_observation_flag_active or info.task_id == 0 or info.task_generation == 0 or info.token == 0 or info.rip_begin != window.begin or info.rip_end != window.end or info.timer_irqs != 0 or info.timer_preemptions != 0 or info.external_handlers != 0 or info.observed_cpus != 0) return null;
        return .{ .request = request, .before = info };
    }
    pub fn finish(self: Scope, dev: *const r4os.r4dev.Context) ?abi.FpuObservationInfo {
        var request = self.request;
        request.operation = abi.fpu_observation_end;
        request.token = self.before.token;
        request.task_generation = self.before.task_generation;
        var info: abi.FpuObservationInfo = .{};
        if (dev.fpuObservation(&request, &info) != 0 or info.version != 1 or info.size != 128 or info.flags != abi.fpu_observation_flag_available | abi.fpu_observation_flag_closed or info.task_id != self.before.task_id or info.task_generation != self.before.task_generation or info.token != self.before.token or info.rip_begin != request.rip_begin or info.rip_end != request.rip_end or info.timer_preemptions > info.timer_irqs) return null;
        const events = info.timer_irqs != 0 or info.external_handlers != 0;
        if (events != (info.observed_cpus != 0) or (events and (info.last_rip < info.rip_begin or info.last_rip >= info.rip_end or info.last_cpu >= 64)) or (info.external_handlers != 0 and (info.last_irq == 0 or info.last_irq >= 32 or info.last_owner == 0 or info.last_handler == 0))) return null;
        return info;
    }
};

comptime {
    // Typed extern C calls provide the full ordinary memory/caller-saved
    // register effects. These bodies use only caller-saved GPR/YMM registers;
    // no stack/callee-saved GPR or floating control environment is changed.
    asm (
        \\.text
        \\.p2align 4
        \\.global r4os_spectra_avx_burst
        \\.hidden r4os_spectra_avx_burst
        \\.type r4os_spectra_avx_burst,@function
        \\r4os_spectra_avx_burst:
        \\vmovdqu (%rdi), %ymm0
        \\.global r4os_spectra_avx_live_begin
        \\.hidden r4os_spectra_avx_live_begin
        \\r4os_spectra_avx_live_begin:
        \\xor %r8d, %r8d
        \\1:
        \\mov (%rdx), %r9
        \\mov (%rdx), %r10
        \\shr $5, %r10
        \\lea (,%r8,4), %r11
        \\xor %rcx, %r11
        \\xor %r10, %r11
        \\add %r11, %r9
        \\mov %r9, (%rdx)
        \\inc %r8
        \\cmp $65536, %r8
        \\jb 1b
        \\.global r4os_spectra_avx_live_end
        \\.hidden r4os_spectra_avx_live_end
        \\r4os_spectra_avx_live_end:
        \\vmovdqu %ymm0, (%rsi)
        \\vzeroupper
        \\ret
        \\.size r4os_spectra_avx_burst,.-r4os_spectra_avx_burst
        \\.p2align 4
        \\.global r4os_spectra_chain_burst
        \\.hidden r4os_spectra_chain_burst
        \\.type r4os_spectra_chain_burst,@function
        \\r4os_spectra_chain_burst:
        \\vmovdqu (%rdi), %ymm0
        \\vmovdqu (%rdx), %ymm1
        \\vmovdqu (%rcx), %ymm2
        \\xor %eax, %eax
        \\test %r8, %r8
        \\jz 3f
        \\.global r4os_spectra_chain_live_begin
        \\.hidden r4os_spectra_chain_live_begin
        \\r4os_spectra_chain_live_begin:
        \\2:
        \\vpmulld %ymm1, %ymm0, %ymm0
        \\vpaddd %ymm2, %ymm0, %ymm0
        \\vmovd %eax, %xmm3
        \\vpbroadcastd %xmm3, %ymm3
        \\vpxor %ymm3, %ymm0, %ymm0
        \\inc %rax
        \\cmp %r8, %rax
        \\jb 2b
        \\3:
        \\.global r4os_spectra_chain_live_end
        \\.hidden r4os_spectra_chain_live_end
        \\r4os_spectra_chain_live_end:
        \\vmovdqu %ymm0, (%rsi)
        \\vzeroupper
        \\ret
        \\.size r4os_spectra_chain_burst,.-r4os_spectra_chain_burst
    );
}

/// Copies are inspected only after real joins; task generation is the native
/// observation identity, independent of ProgramJoinHandle's generation.
pub const Evidence = struct {
    scopes: u32 = 0,
    task_id: u32 = 0,
    generation: u64 = 0,
    token: u64 = 0,
    timers: u64 = 0,
    preemptions: u64 = 0,
    external: u64 = 0,
    cpus: u64 = 0,
    witness: abi.FpuObservationInfo = .{},
    external_witness: abi.FpuObservationInfo = .{},
    pub fn add(self: *Evidence, info: abi.FpuObservationInfo) bool {
        if (self.scopes != 0 and (info.task_id != self.task_id or info.task_generation != self.generation or info.token <= self.token)) return false;
        self.scopes += 1;
        self.task_id = info.task_id;
        self.generation = info.task_generation;
        self.token = info.token;
        self.timers += info.timer_irqs;
        self.preemptions += info.timer_preemptions;
        self.external += info.external_handlers;
        self.cpus |= info.observed_cpus;
        if (info.timer_irqs != 0 or info.external_handlers != 0) self.witness = info;
        if (info.external_handlers != 0) self.external_witness = info;
        return true;
    }
    pub fn print(self: Evidence, sys: anytype, label: []const u8) void {
        sys.write(label);
        sys.write(" scopes=");
        sys.printU64(self.scopes);
        sys.write(" nativeTask=");
        sys.printU64(self.task_id);
        sys.write(" generation=");
        sys.printU64(self.generation);
        sys.write(" timerIrqs=");
        sys.printU64(self.timers);
        sys.write(" timerSwitches=");
        sys.printU64(self.preemptions);
        sys.write(" externalHandlers=");
        sys.printU64(self.external);
        sys.write(" cpuMask=");
        sys.printU64(self.cpus);
        sys.write(" lastRip=");
        sys.printU64(self.witness.last_rip);
        sys.write(" timer=");
        sys.write(if (self.timers != 0) "observed" else "unavailable");
        sys.write(" preemption=");
        sys.write(if (self.preemptions != 0) "observed" else "unavailable");
        sys.write(" externalIRQ=");
        sys.println(if (self.external != 0) "observed" else "unavailable");
        if (self.external != 0) {
            sys.write("  external witness irq=");
            sys.printU64(self.external_witness.last_irq);
            sys.write(" owner=");
            sys.printU64(self.external_witness.last_owner);
            sys.write(" handler=");
            sys.printU64(self.external_witness.last_handler);
            sys.write(" ownRipBegin=");
            sys.printU64(self.external_witness.rip_begin);
            sys.write(" ownRipEnd=");
            sys.printU64(self.external_witness.rip_end);
            sys.write(" interruptedRip=");
            sys.printU64(self.external_witness.last_rip);
            sys.println("");
        }
    }
};

/// Exercises metadata rejection in ordinary task context; no event is injected.
/// Rejected calls must preserve output and the live observation slot.
pub fn contractCheck(dev: *const r4os.r4dev.Context) bool {
    const std = @import("std");
    var caps: abi.FpuObservationInfo = .{};
    var request: abi.FpuObservationRequest = .{};
    if (dev.fpuObservation(&request, &caps) != 0 or caps.flags != abi.fpu_observation_flag_available or caps.task_generation == 0) return false;
    var output: abi.FpuObservationInfo = .{ .token = 0xabc, .timer_irqs = 0xdef };
    const sentinel = output;
    request.version = 0;
    if (dev.fpuObservation(&request, &output) != abi.fpu_observation_error_invalid or !std.mem.eql(u8, std.mem.asBytes(&sentinel), std.mem.asBytes(&output))) return false;
    const scope = Scope.begin(dev, registerWindow()) orelse return false;
    var ok = dev.fpuObservation(&scope.request, &output) == abi.fpu_observation_error_busy;
    var end = scope.request;
    end.operation = abi.fpu_observation_end;
    end.task_generation = scope.before.task_generation;
    end.token = scope.before.token + 1;
    ok = dev.fpuObservation(&end, &output) == abi.fpu_observation_error_stale and ok;
    end.token = scope.before.token;
    end.task_generation += 1;
    ok = dev.fpuObservation(&end, &output) == abi.fpu_observation_error_stale and ok;
    end.task_generation = scope.before.task_generation;
    end.rip_end += 1;
    ok = dev.fpuObservation(&end, &output) == abi.fpu_observation_error_stale and ok;
    ok = std.mem.eql(u8, std.mem.asBytes(&sentinel), std.mem.asBytes(&output)) and ok;
    const closed = scope.finish(dev) orelse return false;
    ok = closed.timer_irqs == 0 and closed.timer_preemptions == 0 and closed.external_handlers == 0 and ok;
    end.rip_end = scope.request.rip_end;
    return dev.fpuObservation(&end, &output) == abi.fpu_observation_error_stale and std.mem.eql(u8, std.mem.asBytes(&sentinel), std.mem.asBytes(&output)) and ok;
}
