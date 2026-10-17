//! One bounded real-thread case for the SDK allocator's unlocked VM path.
const std = @import("std");
const r4os = @import("r4os");
const abi = r4os.abi;
var explicit_heap: ?r4os.vm_allocator.Heap = null;

const Work = struct {
    sys: *const r4os.r4sys.Context,
    allocator: std.mem.Allocator,
    ready: *u32,
    ready_event: u64,
    start_event: u64,
    index: usize,
};

fn worker(raw: u64) callconv(.c) i32 {
    const work: *const Work = @ptrFromInt(raw);
    _ = @atomicRmw(u32, work.ready, .Add, 1, .release);
    _ = work.sys.notificationNotify(work.ready_event, 1);
    if (work.sys.notificationWait(work.start_event, 0, abi.thread_wait_forever) != abi.notification_ok) return 1;
    for (0..16) |step| {
        var memory = work.allocator.alloc(u8, 257 + work.index * 31) catch return 2;
        defer work.allocator.free(memory);
        const pattern: u8 = @intCast(17 + step + work.index * 37);
        @memset(memory, pattern);
        const original_len = memory.len;
        memory = work.allocator.realloc(memory, 96 * 1024) catch return 3;
        for (memory[0..original_len]) |byte| if (byte != pattern) return 4;
        memory = work.allocator.realloc(memory, 64) catch return 5;
        for (memory) |byte| if (byte != pattern) return 6;
        const large = work.allocator.alloc(u8, if (step % 4 == 0) 9 * 1024 * 1024 else 1024 * 1024 + 4096) catch return 7;
        defer work.allocator.free(large);
        large[0] = pattern;
        large[large.len - 1] = pattern ^ 0xA5;
        work.sys.taskYield();
        if (large[0] != pattern or large[large.len - 1] != (pattern ^ 0xA5)) return 8;
    }
    return 0;
}

fn phase(sys: *const r4os.r4sys.Context, a: std.mem.Allocator) bool {
    var start: u64 = 0;
    var event: u64 = 0;
    if (sys.notificationCreate(&start) != abi.notification_ok) return false;
    if (sys.notificationCreate(&event) != abi.notification_ok) {
        _ = sys.notificationClose(start);
        return false;
    }
    var ready: u32 = 0;
    var work: [4]Work = undefined;
    var handles: [4]abi.ProgramJoinHandle = undefined;
    var spawned: usize = 0;
    while (spawned < work.len) : (spawned += 1) {
        work[spawned] = .{ .sys = sys, .allocator = a, .ready = &ready, .ready_event = event, .start_event = start, .index = spawned };
        if (sys.threadCreateHandle(worker, @intFromPtr(&work[spawned]), 0, 0, &handles[spawned]) != abi.thread_ok) break;
    }
    var ok = spawned == work.len;
    while (@atomicLoad(u32, &ready, .acquire) < spawned) {
        var observed: u64 = 0;
        if (sys.notificationQuery(event, &observed) != abi.notification_ok) {
            ok = false;
            break;
        }
        if (@atomicLoad(u32, &ready, .acquire) >= spawned) break;
        if (sys.notificationWait(event, observed, abi.thread_wait_forever) != abi.notification_ok) {
            ok = false;
            break;
        }
    }
    if (sys.notificationNotify(start, 4) != abi.notification_ok) ok = false;
    // Work and allocator state stay alive until actual thread-exit receipts.
    for (handles[0..spawned]) |*handle| {
        var exit_code: i32 = -1;
        if (sys.threadHandleJoin(handle, abi.thread_wait_forever, &exit_code) != abi.thread_ok) {
            sys.println("SPECTRA MEMORY SDK join failed; retaining worker state");
            while (true) sys.sleepTicks(1);
        }
        if (exit_code != 0) {
            sys.write("SPECTRA MEMORY SDK worker failed: ");
            sys.printI32(exit_code);
            sys.println("");
            ok = false;
        }
    }
    if (sys.notificationClose(start) != abi.notification_ok) ok = false;
    if (sys.notificationClose(event) != abi.notification_ok) ok = false;
    return ok;
}

pub fn run(sys: *const r4os.r4sys.Context) bool {
    const table = (sys.base.bundle orelse return false).sys orelse return false;
    if (explicit_heap == null) explicit_heap = .{ .api = table };
    if (explicit_heap.?.api != table) return false;
    const before = sys.allocatorStats();
    if (!phase(sys, sys.allocator())) return false;
    sys.allocatorTrim();
    const after = sys.allocatorStats();
    if (after.active_allocations != before.active_allocations or after.active_bytes != before.active_bytes or after.corruptions != before.corruptions or
        after.direct_active != before.direct_active or after.direct_cached != 0) return false;
    if (after.vm_reserve_calls <= before.vm_reserve_calls or after.vm_commit_calls <= before.vm_commit_calls or
        after.vm_decommit_calls <= before.vm_decommit_calls or after.vm_release_calls <= before.vm_release_calls) return false;
    const heap = &explicit_heap.?;
    if (!phase(sys, heap.allocator())) return false;
    heap.trim();
    const stats = heap.stats();
    if (stats.active_allocations != 0 or stats.active_bytes != 0 or stats.corruptions != 0 or stats.direct_active != 0 or stats.direct_cached != 0 or
        stats.vm_reserve_calls == 0 or stats.vm_commit_calls == 0 or stats.vm_decommit_calls == 0 or stats.vm_release_calls == 0) return false;
    sys.println("SPECTRA MEMORY SDK parallel: OK heaps=2 threads=8 iterations=128 own-live=0 direct-cache=0");
    return true;
}
