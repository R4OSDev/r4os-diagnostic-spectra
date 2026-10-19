//! Passive collectors; no probe, trace enable, or benchmark is called here.
const std = @import("std");
const r4os = @import("r4os");
const abi = r4os.abi;
const cli = @import("cli.zig");
const Output = @import("output.zig").Output;

fn selected(group: []const u8, name: []const u8) bool { return cli.same(group, "ALL") or cli.same(group, name); }

fn optional(out: *Output, group: []const u8, index: u32, value: anytype) bool {
    if (value) |v| { out.record("snapshot", group, index, v); return true; }
    out.unavailable(group, "source absent or snapshot unavailable");
    return false;
}

fn tasks(app: *r4os.App, dev: *const r4os.r4dev.Context, out: *Output) bool {
    const allocator = app.lowLevel().allocator();
    const sys = app.system();
    var attempt: usize = 0;
    restart: while (attempt < 3) : (attempt += 1) {
        var before: abi.ProgramInventorySummary = .{};
        var cursor: abi.ProgramInventoryCursor = .{};
        if (sys.programInventoryBegin(&cursor, &before) != abi.program_handle_ok) continue;
        const rows = allocator.alloc(abi.ProgramTaskPerformanceInfo, before.task_total) catch break;
        defer allocator.free(rows);
        const identities = allocator.alloc(abi.ProgramTaskSnapshot, before.task_total) catch break;
        defer allocator.free(identities);
        var count: usize = 0;
        while (true) {
            var page: abi.ProgramInventoryPageInfo = .{};
            const end = @min(identities.len, count + abi.program_inventory_page_max);
            if (sys.programInventoryTasks(&cursor, identities[count..end], &page) != abi.program_handle_ok or
                page.snapshot_generation != cursor.snapshot_generation or
                page.status == abi.program_inventory_status_restart or
                page.returned > end - count) continue :restart;
            count += page.returned;
            if (page.status == abi.program_inventory_status_complete) break;
            if (page.status != abi.program_inventory_status_more or page.returned == 0 or count == identities.len) continue :restart;
        }
        if (count != identities.len) continue;
        var complete = true;
        for (rows, 0..) |*row, i| { row.* = dev.performanceTask(@intCast(i)) orelse { complete = false; break; }; }
        var after: abi.ProgramInventorySummary = .{};
        if (dev.executionInventorySummary(&after) != abi.program_handle_ok or before.task_epoch != after.task_epoch or before.task_total != after.task_total) continue;
        if (!complete) break;
        out.record("inventory", "tasks", 0, .{ .task_epoch = before.task_epoch, .count = rows.len, .complete = true });
        for (rows, 0..) |row, i| out.record("snapshot", "tasks", i, row);
        for (identities) |row| out.record("snapshot", "task_identity", row.task_id, row);
        return true;
    }
    out.unavailable("tasks", "no complete stable task inventory after three attempts (churn or allocation failure)");
    return false;
}

pub fn run(app: *r4os.App, group: []const u8, out: *Output) i32 {
    const dev = app.devicesLowLevel() orelse { out.unavailable("kernel", "R4DEV unavailable"); return 1; };
    const sys = app.system();
    var clock: abi.MonotonicClockInfo = .{};
    const clock_ok = sys.monotonicClock(&clock) > 0;
    out.record("begin", "collection", 0, .{ .start_ns = sys.monotonicNanoseconds(), .event_hz = sys.monotonicHz(), .atomic_across_groups = false });
    var ok = true;
    var known = false;
    if (clock_ok) out.record("snapshot", "clock", 0, clock) else { out.unavailable("clock", "clock quality unavailable"); ok = false; }
    ok = optional(out, "instrumentation", 0, dev.performanceInstrumentation()) and ok;
    if (selected(group, "CLOCK")) {
        known = true;
        ok = optional(out, "kernel_version", 0, dev.kernelVersion()) and ok;
    }
    if (@import("cli.zig").same(group, "CPUFEATURES")) { known = true; ok = @import("cpu_capabilities.zig").collect(&dev, out, true) and ok; }
    if (selected(group, "CPUPOWER")) { known = true; ok = @import("cpu_power.zig").collect(dev, sys, out) and ok; }
    if (selected(group, "SMP")) { known = true; ok = @import("smp.zig").collect(&dev, out) and ok; }
    if (selected(group, "SUMMARY")) { known = true; ok = optional(out, "summary", 0, dev.performanceSummary()) and ok; }
    if (selected(group, "LOCKS") or selected(group, "STACKS")) {
        known = true;
        if (dev.performanceInstrumentation()) |info| {
            if (selected(group, "LOCKS")) for (0..info.lock_count) |i| { ok = optional(out, "locks", @intCast(i), dev.performanceLock(@intCast(i))) and ok; };
            if (selected(group, "STACKS")) {
                for (0..info.stack_group_count) |i| { ok = optional(out, "stacks", @intCast(i), dev.performanceStack(@intCast(i))) and ok; }
                ok = @import("stack_fault.zig").collect(&dev, out) and ok;
            }
        } else { out.unavailable("instrumentation", "mode/list metadata unavailable"); ok = false; }
    }
    if (selected(group, "TASKS")) { known = true; ok = tasks(app, &dev, out) and ok; }
    if (selected(group, "MEMORY")) {
        known = true;
        ok = optional(out, "memory", 0, dev.memorySummary()) and ok;
        ok = optional(out, "pressure", 0, dev.memoryPressure()) and ok;
        ok = optional(out, "paging", 0, dev.pagingSummary()) and ok;
        const count = dev.memoryBlockCount();
        out.record("inventory", "memory_blocks", 0, .{ .count = count, .atomic = false });
        for (0..count) |i| { ok = optional(out, "memory_blocks", @intCast(i), dev.memoryBlock(@intCast(i))) and ok; }
        if (dev.memoryBlockCount() != count) { out.unavailable("memory_blocks", "inventory changed during collection; retry"); ok = false; }
    }
    if (selected(group, "BOOT")) {
        known = true;
        ok = optional(out, "boot_info", 0, dev.bootInfoSummary()) and ok;
        for (0..dev.bootInfoMemoryCount()) |i| { ok = optional(out, "boot_memory", @intCast(i), dev.bootInfoMemoryEntry(@intCast(i))) and ok; }
        if (dev.performanceBootSummary()) |info| {
            out.record("snapshot", "boot", 0, info);
            for (0..info.phase_count) |i| {
                ok = optional(out, "boot_phase", @intCast(i), dev.performanceBootPhase(@intCast(i))) and ok;
                ok = optional(out, "boot_clock", @intCast(i), dev.performanceBootPhaseClock(@intCast(i))) and ok;
            }
        } else { out.unavailable("boot", "boot summary unavailable"); ok = false; }
    }
    if (selected(group, "IRQ")) { known = true; for (0..32) |i| { ok = optional(out, "irq", @intCast(i), dev.performanceIrqTiming(@intCast(i))) and ok; } }
    if (selected(group, "STORAGE")) {
        known = true;
        if (dev.performanceSummary()) |info| {
            for (0..info.storage_device_count) |i| { ok = optional(out, "storage", @intCast(i), dev.performanceStorage(@intCast(i))) and ok; }
            out.record("inventory", "storage", 0, .{ .count = info.storage_device_count });
        } else { out.unavailable("storage", "device count unavailable"); ok = false; }
    }
    if (selected(group, "WORK")) {
        known = true;
        // The v2 owner ABI accepts aggregate 0 and owner IDs 1..16.
        for (0..17) |i| { ok = optional(out, "work", @intCast(i), dev.performanceDriverWork(@intCast(i))) and ok; }
    }
    if (selected(group, "INPUT")) { known = true; ok = optional(out, "input", 0, dev.performanceInput()) and ok; }
    if (selected(group, "PCI")) { known = true; ok = optional(out, "pci", 0, dev.performancePciInventory()) and ok; }
    if (selected(group, "LIFECYCLE")) {
        known = true;
        var storage: abi.ProgramInstanceStorageSummary = .{};
        var registry: abi.ProgramRegistrySummaryV2 = .{};
        var inventory: abi.ProgramInventorySummary = .{};
        const src = dev.programInstanceStorageSummary(&storage);
        const rrc = dev.programRegistrySummaryV2(&registry);
        const irc = dev.executionInventorySummary(&inventory);
        if (src >= 0) out.record("snapshot", "program_storage", 0, storage) else { out.unavailable("program_storage", "source unavailable"); ok = false; }
        if (rrc >= 0) out.record("snapshot", "registry", 0, registry) else { out.unavailable("registry", "source unavailable"); ok = false; }
        if (irc >= 0) out.record("snapshot", "execution", 0, inventory) else { out.unavailable("execution", "source unavailable"); ok = false; }
    }
    if (selected(group, "IPC")) {
        known = true;
        var info: abi.IpcSummary = .{};
        if (dev.ipcSummary(&info) >= 0) {
            out.record("snapshot", "ipc", 0, info);
            if (app.networkLowLevel()) |net| {
                var timing: abi.IpcPerformanceSummary = .{};
                const aggregate_rc = net.ipcPerformance(0, &timing);
                if (aggregate_rc >= 0) out.record("snapshot", "ipc_timing", 0, timing) else {
                    out.record("unavailable", "ipc_timing", 0, .{ .reason = @as([]const u8, "aggregate unavailable"), .status = aggregate_rc });
                    ok = false;
                }
                var id: u32 = 1;
                while (id <= info.max_channels) : (id += 1) {
                    var channel: abi.IpcChannelInfo = .{};
                    const channel_rc = dev.ipcChannel(id, &channel);
                    if (channel_rc >= 0) {
                        out.record("snapshot", "ipc_channel", id, channel);
                        const timing_rc = net.ipcPerformance(id, &timing);
                        if (timing_rc >= 0) out.record("snapshot", "ipc_timing", id, timing) else {
                            out.record("unavailable", "ipc_timing", id, .{ .reason = @as([]const u8, "channel timing snapshot unavailable"), .status = timing_rc });
                            ok = false;
                        }
                    } else {
                        out.record("unavailable", "ipc_channel", id, .{ .reason = @as([]const u8, "channel snapshot unavailable"), .status = channel_rc });
                        ok = false;
                    }
                }
            } else { out.unavailable("ipc_timing", "R4NET unavailable"); ok = false; }
        } else { out.unavailable("ipc", "source unavailable"); ok = false; }
    }
    if (selected(group, "NETWORK")) {
        known = true;
        var info: abi.TcpSummary = .{};
        var udp: abi.UdpStatus = .{};
        if (app.networkLowLevel()) |net| {
            var performance: abi.TcpPerformanceInfo = .{};
            if (net.tcpPerformance(&performance) > 0) out.record("snapshot", "tcp_performance", 0, performance) else { out.unavailable("tcp_performance", "source unavailable"); ok = false; }
        } else { out.unavailable("tcp_performance", "R4NET unavailable"); ok = false; }
        if (dev.tcpSummary(&info) >= 0) {
            out.record("snapshot", "tcp", 0, info);
            for (0..info.max_connections) |i| {
                var row: abi.TcpConnectionInfo = .{};
                const rc = dev.tcpConnection(@intCast(i), &row);
                if (rc > 0) out.record("snapshot", "tcp_connection", i, row) else if (rc < 0) {
                    out.record("unavailable", "tcp_connection", i, .{ .reason = @as([]const u8, "connection snapshot unavailable"), .status = rc });
                    ok = false;
                }
            }
        } else { out.unavailable("tcp", "source unavailable"); ok = false; }
        if (dev.udpStatus(&udp) >= 0) out.record("snapshot", "udp", 0, udp) else { out.unavailable("udp", "source unavailable"); ok = false; }
    }
    if (!known) { out.unavailable("metrics", "unknown group; use HELP"); return 2; }
    var end_clock: abi.MonotonicClockInfo = .{};
    const stable_clock = sys.monotonicClock(&end_clock) > 0 and clock_ok and end_clock.generation == clock.generation and end_clock.source == clock.source;
    ok = ok and stable_clock;
    out.record("end", "collection", 0, .{ .end_ns = sys.monotonicNanoseconds(), .complete = ok, .stable_clock = stable_clock });
    return if (ok) 0 else 1;
}
