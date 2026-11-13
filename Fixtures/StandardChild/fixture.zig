//! Fixed minimal workload entry. Kernel start/exit/reap owns all work.
//! The typed Generation2 context is intentionally unused; no SDK startup.
const abi = @import("r4os").platform2.abi;
pub export fn R4XStart2(_: *const abi.R4XStartContext2) linksection(".text.r4xstart_entry") callconv(.c) i32 {
    return 17;
}
