//! Compare the saved run with the server's normalized records. The server
//! sorts rows and removes insignificant decimal zeroes during ingestion.
const std = @import("std");
const Value = std.json.Value;

pub const Mismatch = struct {
    group: []const u8,
    index: usize,
    field: []const u8,
};

fn field(value: Value, key: []const u8) ?Value {
    return if (value == .object) value.object.get(key) else null;
}

fn rows(value: Value, key: []const u8, count: usize) ?[]Value {
    const item = field(value, key) orelse return null;
    if (item != .array or item.array.items.len != count) return null;
    return item.array.items;
}

fn primitiveEqual(a: Value, b: Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .null => true,
        .string => std.mem.eql(u8, a.string, b.string),
        .integer => a.integer == b.integer,
        .bool => a.bool == b.bool,
        else => false,
    };
}

fn decimalCanonical(value: []const u8) []const u8 {
    const dot = std.mem.indexOfScalar(u8, value, '.') orelse return value;
    var end = value.len;
    while (end > dot + 1 and value[end - 1] == '0') end -= 1;
    if (end == dot + 1) end = dot;
    return value[0..end];
}

fn decimalField(name: []const u8) bool {
    inline for (.{ "median_value", "min_value", "max_value", "mad_value", "value", "score" }) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

fn fieldEqual(a: Value, b: Value, name: []const u8) bool {
    if (decimalField(name) and a == .string and b == .string)
        return std.mem.eql(u8, decimalCanonical(a.string), decimalCanonical(b.string));
    return primitiveEqual(a, b);
}

fn sameIdentity(a: Value, b: Value, keys: []const []const u8) bool {
    for (keys) |key| {
        const left = field(a, key) orelse return false;
        const right = field(b, key) orelse return false;
        if (!primitiveEqual(left, right)) return false;
    }
    return true;
}

pub fn firstMismatch(local: Value, remote: Value) ?Mismatch {
    const groups = [_]struct { key: []const u8, count: usize, identity: []const []const u8, fields: []const []const u8 }{
        .{ .key = "metrics", .count = 5, .identity = &.{ "area_id", "metric_id" }, .fields = &.{ "area_id", "metric_id", "status", "sample_count", "median_value", "min_value", "max_value", "mad_value" } },
        .{ .key = "samples", .count = 30, .identity = &.{ "area_id", "metric_id", "phase", "sample_index" }, .fields = &.{ "area_id", "metric_id", "phase", "sample_index", "status", "elapsed_ns", "operation_count", "bytes_processed", "value" } },
        .{ .key = "scores", .count = 6, .identity = &.{"area_id"}, .fields = &.{ "area_id", "status", "score" } },
        .{ .key = "artifacts", .count = 2, .identity = &.{"component"}, .fields = &.{ "component", "sha256", "bytes" } },
    };
    for (groups) |group| {
        const before = rows(local, group.key, group.count) orelse return .{ .group = group.key, .index = 0, .field = "local_count" };
        const after = rows(remote, group.key, group.count) orelse return .{ .group = group.key, .index = 0, .field = "server_count" };
        var used: [30]bool = .{false} ** 30;
        for (before, 0..) |item, index| {
            var match: ?usize = null;
            for (after, 0..) |candidate, candidate_index| {
                if (!used[candidate_index] and sameIdentity(item, candidate, group.identity)) {
                    if (match != null) return .{ .group = group.key, .index = index, .field = "duplicate_identity" };
                    match = candidate_index;
                }
            }
            const found = match orelse return .{ .group = group.key, .index = index, .field = "identity" };
            used[found] = true;
            for (group.fields) |name| {
                const left = field(item, name) orelse return .{ .group = group.key, .index = index, .field = name };
                const right = field(after[found], name) orelse return .{ .group = group.key, .index = index, .field = name };
                if (!fieldEqual(left, right, name)) return .{ .group = group.key, .index = index, .field = name };
            }
        }
    }
    return null;
}

test "server sorts samples and canonicalizes decimal strings" {
    try std.testing.expectEqualStrings("13269.89418", decimalCanonical("13269.894180"));
    try std.testing.expectEqualStrings("100", decimalCanonical("100.000000"));
    const left = try std.json.parseFromSlice(Value, std.testing.allocator, "{\"area_id\":\"memory\",\"sample_index\":\"0\"}", .{});
    defer left.deinit();
    const right = try std.json.parseFromSlice(Value, std.testing.allocator, "{\"sample_index\":\"0\",\"area_id\":\"memory\"}", .{});
    defer right.deinit();
    try std.testing.expect(sameIdentity(
        left.value,
        right.value,
        &.{ "area_id", "sample_index" },
    ));
}
