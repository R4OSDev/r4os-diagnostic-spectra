//! Existing VM/file APIs exercised from exact admitted AP continuations.
//! All paths, ranges and backing reservations belong to this invocation.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const bytes = 64 * 1024;
const pages = bytes / 4096;
var system: ?r4os.r4sys.Context = null;
var devices: ?r4os.r4dev.Context = null;
var resources: ?r4os.Resources = null;
var gate: u32 = 0;
var finished: u32 = 0;
var observed_busy: u32 = 0;
var mode: u32 = 0;
var region_id: u32 = 0;
var shared: [*]volatile u8 = undefined;
var zero_page: [*]volatile u8 = undefined;
var paths: [3][96:0]u8 = .{.{0} ** 96} ** 3;
var backing_path: [96:0]u8 = .{0} ** 96;
var zeroes: [bytes]u8 = .{0} ** bytes;

fn bind(sys: *r4os.r4sys.Context, cpu: u32) !void {
    var handle: a.ProgramJoinHandle = .{};
    if (sys.threadCurrentHandle(&handle) != a.thread_ok) return error.Identity;
    const request: a.ThreadPlacementRequest = .{ .preferred_cpu = cpu };
    const mask = [_]u64{@as(u64, 1) << @intCast(cpu)};
    if (sys.threadPlacementSet(&handle, &request, &mask) != a.thread_ok) return error.Placement;
    const start = sys.monotonicNanoseconds() orelse return error.Clock;
    while (true) {
        var info: a.ThreadPlacementInfo = .{};
        var cpus: [1]u64 = .{0};
        if (sys.threadPlacementGet(&handle, &info, &cpus) != a.thread_ok) return error.Placement;
        if (info.running_cpu == cpu and info.applied_revision == info.request_revision) return;
        if ((sys.monotonicNanoseconds() orelse return error.Clock) -| start > 5_000_000_000) return error.Timeout;
        sys.taskYield();
    }
}
fn seed(index: usize) u8 {
    return @truncate(index *% 7 +% (index >> 12) *% 29 +% 0x51);
}
noinline fn faultVectors() u64 {
    const Vec = @Vector(8, u32);
    var v: Vec = .{ 1, 2, 3, 4, 5, 6, 7, 8 };
    for (0..pages) |page| {
        v = v *% @as(Vec, @splat(1664525)) +% @as(Vec, @splat(1013904223));
        // No call boundary: the emitted vector continuation crosses the
        // actual volatile page load and its possibly waiting exception.
        v ^= @as(Vec, @splat(@as(u32, shared[page * 4096])));
    }
    const lanes: [8]u32 = v;
    var sum: u64 = 0;
    for (lanes) |lane| sum += lane;
    return sum;
}
fn scalarExpected() u64 {
    var sum: u64 = 0;
    for (1..9) |initial| {
        var lane: u32 = @intCast(initial);
        for (0..pages) |page| {
            lane = lane *% 1664525 +% 1013904223;
            lane ^= seed(page * 4096);
        }
        sum += lane;
    }
    return sum;
}
fn fileRoundtrip(index: usize) !void {
    var sys = system orelse return error.Context;
    const res = resources orelse return error.Context;
    var region = switch (res.reserveVm(bytes, 4096, a.vm_region_flags_default)) {
        .region => |value| value,
        .failure => return error.Reserve,
    };
    var io_live = false;
    defer if (!io_live) {
        _ = region.release();
    };
    if (region.commit(0, bytes) != a.vm_ok) return error.Commit;
    const data: [*]u8 = @ptrFromInt(region.last_info.base);
    for (0..bytes) |i| data[i] = seed(i + index);
    if (sys.fileWrite(&paths[index], data[0..bytes]) != bytes) return error.Write;
    @memset(data[0..bytes], 0);
    var request: u32 = 0;
    if (sys.ioFileRead(&paths[index], data[0..bytes], 0, &request) != a.io_ok) return error.ReadSubmit;
    io_live = true;
    var completion: a.ProgramIoInfo = .{};
    if (sys.ioWait(request, sys.monotonicHz() * 10, &completion) != a.io_ok or completion.result != bytes) return error.ReadCompletion;
    if (sys.ioClose(request) != a.io_ok or sys.ioStatus(request, &completion) != a.io_error_not_found) return error.ReadClose;
    io_live = false;
    for (data[0..bytes], 0..) |value, i| if (value != seed(i + index)) return error.Content;
    if (region.release() != a.vm_ok) return error.Release;
    if (sys.fileDelete(&paths[index]) != 1) return error.Delete;
}
fn worker(index: u64) callconv(.c) i32 {
    var sys = system orelse return 80;
    bind(&sys, @intCast(index + 1)) catch return 81;
    _ = @atomicRmw(u32, &finished, .Add, 1, .acq_rel);
    const ready_at = sys.monotonicNanoseconds() orelse return 85;
    while (@atomicLoad(u32, &gate, .acquire) == 0) {
        if ((sys.monotonicNanoseconds() orelse return 85) -| ready_at > 5_000_000_000) return 86;
        std.atomic.spinLoopHint();
    }
    if (@atomicLoad(u32, &gate, .acquire) == 99) return 0;
    switch (mode) {
        0 => {
            if (zero_page[0] != 0) return 82;
            fileRoundtrip(@intCast(index)) catch |err| {
                sys.write("SPECTRA VM AP peer file: ");
                sys.println(@errorName(err));
                return 83;
            };
        },
        1 => {
            // Both APs fault on the same initially nonresident page, then
            // traverse the remaining backed pages with independent frames.
            if (faultVectors() != scalarExpected()) return 89;
            for (0..bytes) |i| if (shared[i] != seed(i)) return 84;
        },
        2 => {
            var dev = devices orelse return 85;
            const start = sys.monotonicNanoseconds() orelse return 85;
            while (@atomicLoad(u32, &finished, .acquire) < 3) {
                const state = dev.memoryVmPageStateProbe(region_id, 0, pages, a.memory_vm_page_state_operation_query, 0, 0, 0, 0) orelse return 85;
                if (state.busy_pages != 0) {
                    @atomicStore(u32, &observed_busy, 1, .release);
                    shared[17 + @as(usize, @intCast(index))] = @as(u8, @intCast(0xB0 + index));
                    return 0;
                }
                if ((sys.monotonicNanoseconds() orelse return 85) -| start > 5_000_000_000) return 86;
                std.atomic.spinLoopHint();
            }
            return 87;
        },
        else => return 88,
    }
    return 0;
}
const Peers = struct {
    handles: [2]a.ProgramJoinHandle = .{a.ProgramJoinHandle{}} ** 2,
    count: usize = 0,
    joined: usize = 0,
    fn start(self: *Peers, sys: *r4os.r4sys.Context, selected: u32) !void {
        mode = selected;
        @atomicStore(u32, &finished, 0, .release);
        @atomicStore(u32, &gate, 0, .release);
        for (&self.handles, 0..) |*handle, i| {
            if (sys.threadCreateHandle(worker, i + 1, 0, 0, handle) != a.thread_ok) return error.Create;
            self.count += 1;
        }
        const started = sys.monotonicNanoseconds() orelse return error.Clock;
        while (@atomicLoad(u32, &finished, .acquire) < 2) {
            if ((sys.monotonicNanoseconds() orelse return error.Clock) -| started > 5_000_000_000) return error.Ready;
            sys.sleepTicks(1);
        }
        @atomicStore(u32, &gate, 1, .release);
    }
    fn join(self: *Peers, sys: *r4os.r4sys.Context) !void {
        while (self.joined < self.count) {
            var exit: i32 = 0;
            if (sys.threadHandleJoin(&self.handles[self.joined], sys.monotonicHz() * 10, &exit) != a.thread_ok) return error.Join;
            self.joined += 1;
            if (exit != 0) {
                sys.write("SPECTRA VM AP peer exit=");
                sys.printI32(exit);
                sys.println("");
                return error.Peer;
            }
        }
    }
};
fn exercise(app: *r4os.App) !void {
    var sys = app.system();
    var dev = app.devicesLowLevel() orelse return error.Devices;
    system = sys;
    devices = dev;
    const res = app.resources();
    resources = res;
    var own: a.ProgramJoinHandle = .{};
    if (sys.threadCurrentHandle(&own) != a.thread_ok) return error.Identity;
    var placement: a.ThreadPlacementInfo = .{};
    var cpus: [1]u64 = .{0};
    if (sys.threadPlacementGet(&own, &placement, &cpus) != a.thread_ok or placement.flags & a.thread_placement_flag_parallel == 0 or cpus[0] & 15 != 15) return error.RequiresFourAdmittedCpus;
    defer {
        const restore: a.ThreadPlacementRequest = .{ .flags = placement.flags & a.thread_placement_flag_default_cpus, .work_class = placement.work_class, .preferred_cpu = placement.preferred_cpu };
        const mask: []const u64 = if (restore.flags != 0) &.{} else &cpus;
        _ = sys.threadPlacementSet(&own, &restore, mask);
    }
    try bind(&sys, 1);
    for (&paths, 0..) |*path, i| {
        _ = try std.fmt.bufPrintZ(path, "{c}:\\TEMP\\VA{X:0>8}-{X:0>16}-{d}.BIN", .{ @as(u8, if (i == 2) 'D' else 'C'), own.instance_id, own.instance_generation, i });
        if (sys.exists(path)) return error.PathConflict;
    }
    _ = try std.fmt.bufPrintZ(&backing_path, "D:\\TEMP\\VA{X:0>8}-{X:0>16}.SWP", .{ own.instance_id, own.instance_generation });
    if (sys.exists(&backing_path)) return error.BackingConflict;
    var region = switch (res.reserveVm(bytes, 4096, a.vm_region_flags_default)) {
        .region => |value| value,
        .failure => return error.Reserve,
    };
    region_id = region.raw;
    var zero = switch (res.reserveVm(4096, 4096, a.vm_region_flags_default)) {
        .region => |value| value,
        .failure => return error.Reserve,
    };
    var peers: Peers = .{};
    // A failed join leaves ranges/files retained for exact program teardown.
    // No borrowed worker pointer may outlive an explicitly freed VM range.
    defer {
        if (peers.joined != peers.count) {
            @atomicStore(u32, &gate, 99, .release);
            @atomicStore(u32, &finished, 3, .release);
            peers.join(&sys) catch {};
        }
        if (peers.joined == peers.count) {
            _ = zero.release();
            _ = region.release();
            for (&paths) |*path| if (sys.exists(path)) {
                _ = sys.fileDelete(path);
            };
            if (sys.exists(&backing_path)) _ = sys.fileDelete(&backing_path);
        }
    }
    if (zero.commit(0, 4096) != a.vm_ok or region.commit(0, bytes) != a.vm_ok) return error.Commit;
    shared = @ptrFromInt(region.last_info.base);
    zero_page = @ptrFromInt(zero.last_info.base);
    try peers.start(&sys, 0);
    if (zero_page[0] != 0) return error.DemandZero;
    try fileRoundtrip(0);
    try peers.join(&sys);
    if (zero.release() != a.vm_ok) return error.ZeroRelease;
    sys.println("SPECTRA VM AP files: OK cpus=1,2,3 same-volume=C cross-volume=D private=65536 close=stale-rejected");
    if (sys.fileWrite(&backing_path, &zeroes) != bytes) return error.BackingCreate;
    const slot = dev.memoryBackingStoreSlotProbe(&backing_path, bytes, a.memory_backing_store_slot_operation_reserve, pages, 0, a.memory_backing_store_slot_owner_kind_vm_region, own.instance_id, region.raw, 0) orelse return error.Slot;
    if (slot.status != a.memory_backing_store_slot_status_reserved or slot.reservation_id == 0) return error.BackingAlreadyOwned;
    for (0..bytes) |i| shared[i] = seed(i);
    const data: [*]u8 = @ptrFromInt(region.last_info.base);
    const out = dev.memoryPageIoProbe(&backing_path, bytes, a.memory_page_io_operation_page_out, region.raw, 0, slot.reservation_id, 0, pages, a.memory_backing_store_slot_owner_kind_vm_region, own.instance_id, slot.generation, data[0..bytes], 0) orelse return error.PageOut;
    if (out.status != a.memory_page_io_status_page_out_ok) return error.PageOut;
    const nonresident = dev.memoryVmPageStateProbe(region.raw, 0, pages, a.memory_vm_page_state_operation_query, 0, 0, 0, 0) orelse return error.PageState;
    if (nonresident.nonresident_pages != pages or nonresident.busy_pages != 0) return error.PageOutReceipt;
    peers = .{};
    try peers.start(&sys, 1);
    try peers.join(&sys);
    const restored = sys.vmQuery(region.raw) orelse return error.Query;
    if (restored.resident_bytes != bytes or restored.failed_faults != 0) return error.PageInReceipt;
    sys.println("SPECTRA VM AP page-in: OK shared-page=2 private-frame=retained pages=16 data=exact vector=scalar-oracle");
    peers = .{};
    observed_busy = 0;
    try peers.start(&sys, 2);
    const written = dev.memoryPageIoProbe(&backing_path, bytes, a.memory_page_io_operation_page_out, region.raw, 0, slot.reservation_id, 0, pages, a.memory_backing_store_slot_owner_kind_vm_region, own.instance_id, out.slot_generation, data[0..bytes], a.memory_page_io_flag_eviction_request) orelse return error.ConcurrentPageOut;
    @atomicStore(u32, &finished, 3, .release);
    if (written.status != a.memory_page_io_status_page_out_ok) {
        sys.write("SPECTRA VM AP page-out rejected status=");
        sys.printU64(written.status);
        sys.write(" blockers=");
        sys.printU64(written.blockers);
        sys.println("");
        return error.ConcurrentPageOut;
    }
    try peers.join(&sys);
    if (@atomicLoad(u32, &observed_busy, .acquire) == 0) return error.ConcurrentWrite;
    for (0..bytes) |i| {
        const expected: u8 = if (i == 18) 0xB1 else if (i == 19) 0xB2 else seed(i);
        if (shared[i] != expected) return error.ConcurrentContent;
    }
    sys.println("SPECTRA VM AP writeback: OK busy-observed=1 concurrent-writers=2 data=exact");
    var returned: u64 = 0;
    const before_reclaim = dev.performanceSummary() orelse return error.ReclaimSummary;
    const frame_bytes = if (before_reclaim.fs_cache_payload_frame_bytes == 0) 4096 else before_reclaim.fs_cache_payload_frame_bytes;
    var remaining_fs = before_reclaim.fs_cache_pmm_reclaimable_bytes / frame_bytes;
    // The public probe clamps at64 frames and prioritizes stack/cache receipts.
    // Follow the original bounded VM-eviction check's adaptive request policy.
    for (0..16) |attempt| {
        const request: u32 = @intCast(@min(remaining_fs + 1, 64));
        const reclaimed = dev.memoryReclaimProbe(request) orelse return error.Reclaim;
        sys.write("SPECTRA VM AP reclaim-step=");
        sys.printU64(attempt);
        sys.write(" requested=");
        sys.printU64(reclaimed.requested_frames);
        sys.write(" returned=");
        sys.printU64(reclaimed.returned_frames);
        sys.write(" fs=");
        sys.printU64(reclaimed.fs_returned_frames);
        sys.write(" vm=");
        sys.printU64(reclaimed.vm_returned_frames);
        sys.write(" failed=");
        sys.printU64(reclaimed.vm_failures);
        sys.println("");
        if (reclaimed.vm_failures != 0) return error.ReclaimFailure;
        returned += reclaimed.vm_returned_frames;
        if (returned != 0) break;
        remaining_fs -|= reclaimed.fs_returned_frames;
        if (reclaimed.returned_frames == 0) sys.sleepTicks(1);
    }
    if (returned == 0) return error.NoVmReclaim;
    for (0..bytes) |i| {
        const expected: u8 = if (i == 18) 0xB1 else if (i == 19) 0xB2 else seed(i);
        if (shared[i] != expected) return error.ReclaimContent;
    }
    if (region.release() != a.vm_ok) return error.Release;
    const released = dev.memoryBackingStoreSlotProbe(&backing_path, bytes, a.memory_backing_store_slot_operation_probe, 0, 0, a.memory_backing_store_slot_owner_kind_vm_region, own.instance_id, region_id, 0) orelse return error.Cleanup;
    if (released.reserved_slots != 0 or released.valid_slots != 0 or released.error_slots != 0) return error.Cleanup;
    sys.write("SPECTRA VM AP reclaim: OK cpu=1 returned=");
    sys.printU64(returned);
    sys.println(" own-slots=0 data=exact");
}
pub fn run(app: *r4os.App) i32 {
    exercise(app) catch |err| {
        app.system().write("SPECTRA VM AP failed: ");
        app.system().println(@errorName(err));
        return 1;
    };
    app.system().println("SPECTRA VM AP result: OK");
    return 0;
}
