//! Copied existing owner evidence. No rendering, capture demand or polling.
const std = @import("std");
pub const Execution = struct {
    device_address: u64,
    device_handle_generation: u64,
    backend_device_generation: u64,
    reset_generation: u64,
    completed_frames: u64,
    visible_frames: u64,
    pub fn same(self: Execution, other: Execution) bool {
        return self.device_address == other.device_address and
            self.device_handle_generation == other.device_handle_generation and
            self.backend_device_generation == other.backend_device_generation and
            self.reset_generation == other.reset_generation;
    }
};
pub const Capture = struct {
    frame: u64,
    reused_captures: u64,
    atlas_reused_layers: u64,
    asset_misses: u64,
    captured_reads: u64,
    completed_reads: u64,
    failed_reads: u64,
    reads_empty: bool,
    external_receipts: u64,
};
pub const Target = struct { adapter_id: u32, connector_id: u32, head_id: u32, device_generation: u64, connection_generation: u64, display_generation: u64 };
pub const Owner = struct { owner: []const u8, active: bool, target: ?Target, execution: ?Execution, capture: ?Capture };
pub const Report = struct {
    contract: []const u8,
    caller_instance: u32,
    caller_generation: u64,
    sequence: u64,
    outputs: []Owner,
    native_failures: ?struct { total: u64 } = null,
};
pub const Observed = struct {
    primary: bool,
    target: ?Target,
    execution: Execution,
    capture: ?Capture,
    fn same(self: Observed, other: Observed) bool {
        return self.primary == other.primary and self.execution.same(other.execution) and std.meta.eql(self.target, other.target);
    }
};
pub const Observation = struct {
    owners: [4]?Observed = .{null} ** 4,
    native_failures: ?u64 = null,
    pub fn count(self: Observation) usize {
        var n: usize = 0;
        for (self.owners) |owner| if (owner != null) {
            n += 1;
        };
        return n;
    }
};
pub fn observe(report: Report) !Observation {
    var result: Observation = .{ .native_failures = if (report.native_failures) |v| v.total else null };
    var n: usize = 0;
    for (report.outputs) |owner| {
        const primary = std.mem.eql(u8, owner.owner, "primary-native-gr");
        if (!owner.active or (!primary and !std.mem.eql(u8, owner.owner, "native-gr"))) continue;
        if (n == result.owners.len) return error.TooManyOwners;
        const item: Observed = .{ .primary = primary, .target = owner.target, .execution = owner.execution orelse return error.NativeOwnerUnavailable, .capture = owner.capture };
        for (result.owners) |prior| if (prior) |p| {
            if (p.same(item)) return error.DuplicateOwner;
        };
        if (item.execution.visible_frames > item.execution.completed_frames) return error.InvalidCompletionCounts;
        result.owners[n] = item;
        n += 1;
    }
    return result;
}
pub const Progress = enum { cpu, native };
pub fn progress(before: Observation, after: Observation) !Progress {
    const count = before.count();
    if (count != after.count()) return error.NativeOwnerChanged;
    if (count == 0) return .cpu; // Caller retains its exact original CPU oracle.
    const failures = before.native_failures orelse return error.NativeFailuresUnavailable;
    if ((after.native_failures orelse return error.NativeFailuresUnavailable) != failures) return error.NativeFailure;
    var visible = false;
    for (before.owners) |entry| {
        const first = entry orelse continue;
        var found = false;
        for (after.owners) |candidate| {
            const last = candidate orelse continue;
            if (!first.same(last)) continue;
            found = true;
            if (last.execution.completed_frames < first.execution.completed_frames or
                last.execution.visible_frames < first.execution.visible_frames) return error.CompletionRegressed;
            if (last.execution.visible_frames > first.execution.visible_frames) {
                if (last.execution.completed_frames <= first.execution.completed_frames) return error.InvalidCompletionCounts;
                visible = true;
            }
            break;
        }
        if (!found) return error.NativeOwnerChanged;
    }
    if (!visible) return error.NativePresentationMissing;
    return .native;
}

test "native progress requires same actual owner and visible completion even without a CPU capture" {
    const first: Observed = .{ .primary = false, .target = .{ .adapter_id = 1, .connector_id = 2, .head_id = 0, .device_generation = 3, .connection_generation = 4, .display_generation = 5 }, .execution = .{ .device_address = 0x1000, .device_handle_generation = 1, .backend_device_generation = 3, .reset_generation = 1, .completed_frames = 6, .visible_frames = 5 }, .capture = null };
    const before: Observation = .{ .owners = .{ first, null, null, null }, .native_failures = 0 };
    var after = before;
    after.owners[0].?.execution.completed_frames += 1;
    try std.testing.expectError(error.NativePresentationMissing, progress(before, after));
    after.owners[0].?.execution.visible_frames += 1;
    try std.testing.expectEqual(Progress.native, try progress(before, after));
    const good = after;
    after.owners[0].?.execution.reset_generation += 1;
    try std.testing.expectError(error.NativeOwnerChanged, progress(before, after));
    after = good;
    after.owners[0].?.target.?.connection_generation += 1;
    try std.testing.expectError(error.NativeOwnerChanged, progress(before, after));
    after = good;
    after.native_failures = 1;
    try std.testing.expectError(error.NativeFailure, progress(before, after));
    after = good;
    after.native_failures = null;
    try std.testing.expectError(error.NativeFailuresUnavailable, progress(before, after));
    after = good;
    after.owners[0].?.execution.visible_frames = 4;
    try std.testing.expectError(error.CompletionRegressed, progress(before, after));
    try std.testing.expectError(error.NativeOwnerChanged, progress(before, .{}));
    try std.testing.expectEqual(Progress.cpu, try progress(.{}, .{}));
}
