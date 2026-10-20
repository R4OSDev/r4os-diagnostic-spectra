//! Private local-CPU diagnostic. Complete integer/pointer SysV assembly;
//! callers never keep floating data live across an ordinary API boundary.
const image = @import("environment_image.zig");
const observed = @import("observed.zig");
pub const State = extern struct { bytes: [4096]u8 align(64) = @splat(0) };
pub const Config = extern struct { control: image.Control, mask: u64 = 7, rounds: u64 = 256, mode: u32, variant: u32 };
pub const Output = extern struct { cycles: u64 = 0, padding: [56]u8 = @splat(0), fp: image.Output = .{} };
extern fn r4os_spectra_save_cost(*State, *Output, *const image.Pattern, *const Config) callconv(.c) void;
pub fn execute(state: *State, out: *Output, pattern: *const image.Pattern, config: *const Config) void {
    r4os_spectra_save_cost(state, out, pattern, config);
}
pub fn window() observed.Window {
    var begin: u64 = undefined;
    var end: u64 = undefined;
    asm ("leaq r4os_spectra_save_cost_live_begin(%%rip), %[begin]\n\tleaq r4os_spectra_save_cost_live_end(%%rip), %[end]"
        : [begin] "=r" (begin),
          [end] "=r" (end),
    );
    return .{ .begin = begin, .end = end };
}
comptime {
    if (@offsetOf(Config, "mask") != 16 or @offsetOf(Config, "rounds") != 24 or @offsetOf(Config, "mode") != 32 or @offsetOf(Config, "variant") != 36 or @sizeOf(Config) != 40 or @offsetOf(Output, "fp") != 64 or @sizeOf(Output) != 2176) @compileError("save-cost assembly layout");
    asm (
        \\.text
        \\.p2align 4
        \\.global r4os_spectra_save_cost
        \\.hidden r4os_spectra_save_cost
        \\.type r4os_spectra_save_cost,@function
        \\r4os_spectra_save_cost:
        \\    push %rbx
        \\    push %rbp
        \\    push %r12
        \\    push %r13
        \\    push %r14
        \\    push %r15
        \\    sub $24, %rsp
        \\    fnstcw 0(%rsp)
        \\    stmxcsr 4(%rsp)
        \\    mov %rdi, %r15
        \\    lea 64(%rsi), %r13
        \\    mov %rdx, %r12
        \\    mov %rcx, %r14
        \\    mov 24(%r14), %rbx
        \\    fninit
        \\    fldcw 0(%r14)
        \\    ldmxcsr 4(%r14)
        \\    vzeroall
        \\    cmpl $0, 36(%r14)
        \\    je .Lsave_cost_seeded
        \\    fldt 512(%r12)
        \\    fldt 528(%r12)
        \\    fldt 544(%r12)
        \\    fldt 560(%r12)
        \\    fldt 576(%r12)
        \\    fldt 592(%r12)
        \\    fldt 608(%r12)
        \\    fldt 624(%r12)
        \\    fincstp
        \\    fincstp
        \\    vmovdqu 0(%r12), %ymm0
        \\    vmovdqu 32(%r12), %ymm1
        \\    vmovdqu 64(%r12), %ymm2
        \\    vmovdqu 96(%r12), %ymm3
        \\    vmovdqu 128(%r12), %ymm4
        \\    vmovdqu 160(%r12), %ymm5
        \\    vmovdqu 192(%r12), %ymm6
        \\    vmovdqu 224(%r12), %ymm7
        \\    vmovdqu 256(%r12), %ymm8
        \\    vmovdqu 288(%r12), %ymm9
        \\    vmovdqu 320(%r12), %ymm10
        \\    vmovdqu 352(%r12), %ymm11
        \\    vmovdqu 384(%r12), %ymm12
        \\    vmovdqu 416(%r12), %ymm13
        \\    vmovdqu 448(%r12), %ymm14
        \\    vmovdqu 480(%r12), %ymm15
        \\.Lsave_cost_seeded:
        \\    fxsave64 0(%r13)
        \\    mov 16(%r14), %rax
        \\    mov %rax, %rdx
        \\    shr $32, %rdx
        \\    xsave64 (%r15)
        \\    lfence
        \\    rdtsc
        \\    lfence
        \\    shl $32, %rdx
        \\    or %rdx, %rax
        \\    mov %rax, %rbp
        \\.global r4os_spectra_save_cost_live_begin
        \\.hidden r4os_spectra_save_cost_live_begin
        \\r4os_spectra_save_cost_live_begin:
        \\.Lsave_cost_loop:
        \\    mov 16(%r14), %rax
        \\    mov %rax, %rdx
        \\    shr $32, %rdx
        \\    xrstor64 (%r15)
        \\    cmpl $2, 36(%r14)
        \\    jne .Lsave_cost_save
        \\    fninit
        \\    fldcw 0(%r14)
        \\    ldmxcsr 4(%r14)
        \\    fldt 512(%r12)
        \\    fldt 528(%r12)
        \\    fldt 544(%r12)
        \\    fldt 560(%r12)
        \\    fldt 576(%r12)
        \\    fldt 592(%r12)
        \\    fldt 608(%r12)
        \\    fldt 624(%r12)
        \\    fincstp
        \\    fincstp
        \\    vmovdqu 0(%r12), %ymm0
        \\    vmovdqu 32(%r12), %ymm1
        \\    vmovdqu 64(%r12), %ymm2
        \\    vmovdqu 96(%r12), %ymm3
        \\    vmovdqu 128(%r12), %ymm4
        \\    vmovdqu 160(%r12), %ymm5
        \\    vmovdqu 192(%r12), %ymm6
        \\    vmovdqu 224(%r12), %ymm7
        \\    vmovdqu 256(%r12), %ymm8
        \\    vmovdqu 288(%r12), %ymm9
        \\    vmovdqu 320(%r12), %ymm10
        \\    vmovdqu 352(%r12), %ymm11
        \\    vmovdqu 384(%r12), %ymm12
        \\    vmovdqu 416(%r12), %ymm13
        \\    vmovdqu 448(%r12), %ymm14
        \\    vmovdqu 480(%r12), %ymm15
        \\.Lsave_cost_save:
        \\    mov 16(%r14), %rax
        \\    mov %rax, %rdx
        \\    shr $32, %rdx
        \\    cmpl $0, 32(%r14)
        \\    jne .Lsave_cost_opt
        \\    xsave64 (%r15)
        \\    jmp .Lsave_cost_next
        \\.Lsave_cost_opt:
        \\    xsaveopt64 (%r15)
        \\.Lsave_cost_next:
        \\    dec %rbx
        \\    jnz .Lsave_cost_loop
        \\.global r4os_spectra_save_cost_live_end
        \\.hidden r4os_spectra_save_cost_live_end
        \\r4os_spectra_save_cost_live_end:
        \\    lfence
        \\    rdtsc
        \\    lfence
        \\    shl $32, %rdx
        \\    or %rdx, %rax
        \\    sub %rbp, %rax
        \\    mov %rax, -64(%r13)
        \\    fxsave64 512(%r13)
        \\    vmovdqu %ymm0, 1024(%r13)
        \\    vmovdqu %ymm1, 1056(%r13)
        \\    vmovdqu %ymm2, 1088(%r13)
        \\    vmovdqu %ymm3, 1120(%r13)
        \\    vmovdqu %ymm4, 1152(%r13)
        \\    vmovdqu %ymm5, 1184(%r13)
        \\    vmovdqu %ymm6, 1216(%r13)
        \\    vmovdqu %ymm7, 1248(%r13)
        \\    vmovdqu %ymm8, 1280(%r13)
        \\    vmovdqu %ymm9, 1312(%r13)
        \\    vmovdqu %ymm10, 1344(%r13)
        \\    vmovdqu %ymm11, 1376(%r13)
        \\    vmovdqu %ymm12, 1408(%r13)
        \\    vmovdqu %ymm13, 1440(%r13)
        \\    vmovdqu %ymm14, 1472(%r13)
        \\    vmovdqu %ymm15, 1504(%r13)
        \\    emms
        \\    fninit
        \\    fldcw 0(%r14)
        \\    fldl .Lsave_cost_half(%rip)
        \\    fistpll 1536(%r13)
        \\    movsd .Lsave_cost_half(%rip), %xmm0
        \\    cvtsd2siq %xmm0, %rax
        \\    mov %rax, 1544(%r13)
        \\    emms
        \\    fxsave64 1600(%r13)
        \\    fninit
        \\    ldmxcsr 4(%rsp)
        \\    fldcw 0(%rsp)
        \\    vzeroupper
        \\    add $24, %rsp
        \\    pop %r15
        \\    pop %r14
        \\    pop %r13
        \\    pop %r12
        \\    pop %rbp
        \\    pop %rbx
        \\    ret
        \\.size r4os_spectra_save_cost,.-r4os_spectra_save_cost
        \\.section .rodata
        \\.p2align 3
        \\.Lsave_cost_half:
        \\    .quad 0x3ff8000000000000
        \\.section .note.GNU-stack,"",@progbits
    );
}
