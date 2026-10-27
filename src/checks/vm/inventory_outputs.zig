//! Explicit real-pager regression: caller rows are untouched demand memory.
//! No scan, sampler, background task or artificial fault injection is enabled.
const std = @import("std");
const r = @import("r4os");

fn page(sys: r.r4sys.Context, comptime threads: bool) !void {
    const T = if (threads) r.abi.ProgramThreadSnapshot else r.abi.ProgramTaskSnapshot;
    const bytes = std.mem.alignForward(u64, @sizeOf(T) * 64, 4096);
    const region = sys.vmReserve(bytes, 4096, r.abi.vm_region_flags_default) orelse return error.Reserve;
    var released = false;
    defer if (!released) {
        _ = sys.vmRelease(region.id);
    };
    if (sys.vmCommit(region.id, 0, bytes) != r.abi.vm_ok) return error.Commit;
    const before = sys.vmQuery(region.id) orelse return error.Query;
    if (before.resident_bytes != 0 or before.fault_count != 0 or before.committed_bytes != bytes) return error.NotFreshDemandMemory;
    const rows = @as([*]T, @ptrFromInt(region.base))[0..64];
    var returned: u32 = 0;
    for (0..16) |_| {
        var cursor: r.abi.ProgramInventoryCursor = .{};
        var summary: r.abi.ProgramInventorySummary = .{};
        if (sys.programInventoryBegin(&cursor, &summary) != r.abi.program_handle_ok) continue;
        var result: r.abi.ProgramInventoryPageInfo = .{};
        const rc = if (threads) sys.programInventoryThreads(&cursor, rows, &result) else sys.programInventoryTasks(&cursor, rows, &result);
        if (rc != r.abi.program_handle_ok) return error.Page;
        if (result.status == r.abi.program_inventory_status_restart) {
            if (result.returned != 0) return error.RestartPublishedRows;
            continue;
        }
        if ((result.status != r.abi.program_inventory_status_complete and result.status != r.abi.program_inventory_status_more) or result.returned == 0 or result.returned > 64 or result.snapshot_generation != cursor.snapshot_generation) return error.PageIdentity;
        returned = result.returned;
        break;
    }
    if (returned == 0) return error.NoStablePage;
    for (rows[0..returned]) |row| {
        if (row.version != 1 or row.size != @sizeOf(T)) return error.RowLayout;
        if (threads) {
            if (row.handle.thread_id == 0 or row.handle.thread_generation == 0) return error.RowIdentity;
        } else if (row.task_id == 0 or row.generation == 0) return error.RowIdentity;
    }
    const after = sys.vmQuery(region.id) orelse return error.Query;
    if (after.resident_bytes == 0 or after.fault_count == 0 or after.failed_faults != 0) return error.NoRealDemandFault;
    var text: [256]u8 = undefined;
    sys.println(try std.fmt.bufPrint(&text, "SPECTRA VM inventory-output: kind={s} before-resident=0 returned={d} resident={d} faults={d} failed=0", .{ if (threads) "thread" else "task", returned, after.resident_bytes, after.fault_count }));
    if (sys.vmRelease(region.id) != r.abi.vm_ok) return error.Release;
    released = true;
}

pub fn run(sys: r.r4sys.Context) bool {
    page(sys, false) catch |err| {
        sys.write("SPECTRA VM inventory task FAILED: ");
        sys.println(@errorName(err));
        return false;
    };
    page(sys, true) catch |err| {
        sys.write("SPECTRA VM inventory thread FAILED: ");
        sys.println(@errorName(err));
        return false;
    };
    sys.println("SPECTRA VM inventory-output: OK task+thread demand-faults=real cleanup=complete");
    return true;
}
