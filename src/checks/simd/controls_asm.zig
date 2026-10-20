//! Ordinary SysV call: only controls are preserved, all FP data are free.
const Seen = extern struct { cw: u16 = 0, reserved: u16 = 0, mxcsr: u32 = 0 };
extern fn r4os_spectra_fp_control_call(*const fn (usize) callconv(.c) i32, usize, *Seen) callconv(.c) i32;
pub fn check(callback: *const fn (usize) callconv(.c) i32, context: usize) bool {
    var seen: Seen = .{};
    const result = r4os_spectra_fp_control_call(callback, context, &seen);
    return result == 0 and seen.cw == 0x077f and seen.mxcsr & ~@as(u32, 0x3f) == 0x3f80;
}
comptime {
    asm (
        \\.text
        \\.p2align 4
        \\.global r4os_spectra_fp_control_call
        \\.hidden r4os_spectra_fp_control_call
        \\.type r4os_spectra_fp_control_call,@function
        \\r4os_spectra_fp_control_call:
        \\    push %rbx
        \\    push %r12
        \\    push %r13
        \\    sub $32,%rsp
        \\    fnstcw 0(%rsp)
        \\    stmxcsr 4(%rsp)
        \\    movw $0x077f,8(%rsp)
        \\    movl $0x3f80,12(%rsp)
        \\    mov %rdx,%r12
        \\    mov %rdi,%rax
        \\    mov %rsi,%rdi
        \\    fninit
        \\    fldcw 8(%rsp)
        \\    ldmxcsr 12(%rsp)
        \\    call *%rax
        \\    fnstcw 0(%r12)
        \\    stmxcsr 4(%r12)
        \\    emms
        \\    fninit
        \\    fldcw 0(%rsp)
        \\    ldmxcsr 4(%rsp)
        \\    add $32,%rsp
        \\    pop %r13
        \\    pop %r12
        \\    pop %rbx
        \\    ret
        \\.size r4os_spectra_fp_control_call,.-r4os_spectra_fp_control_call
        \\.section .note.GNU-stack,"",@progbits
    );
}
