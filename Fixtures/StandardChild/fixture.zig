//! Fixed minimal workload entry. Kernel start/exit/reap owns all work.
//! Kept separate from Spectra's changing code size and diagnostic imports.
pub export fn r4xstart_entry(_: *const anyopaque) callconv(.c) i32 {
    return 17;
}
