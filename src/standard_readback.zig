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
        .float => a.float == b.float,
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

fn timeEqual(a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, b)) return true;
    const short, const long = if (a.len < b.len) .{ a, b } else .{ b, a };
    if (short.len == 0 or short[short.len - 1] != 'Z' or
        !std.mem.startsWith(u8, long, short[0 .. short.len - 1])) return false;
    const fraction = long[short.len - 1 ..];
    if (fraction.len < 3 or fraction[0] != '.' or fraction[fraction.len - 1] != 'Z') return false;
    for (fraction[1 .. fraction.len - 1]) |digit| if (digit != '0') return false;
    return true;
}

fn valueMismatch(a: Value, b: Value, name: []const u8, row_id: ?[]const u8) ?[]const u8 {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return name;
    switch (a) {
        .string => {
            if (decimalField(name) and
                std.mem.eql(u8, decimalCanonical(a.string), decimalCanonical(b.string))) return null;
            if ((std.mem.eql(u8, name, "started_at_utc") or
                std.mem.eql(u8, name, "finished_at_utc")) and timeEqual(a.string, b.string)) return null;
            return if (std.mem.eql(u8, a.string, b.string)) null else name;
        },
        .object => {
            var left = a.object.iterator();
            while (left.next()) |entry| {
                const key = entry.key_ptr.*;
                const right = b.object.get(key) orelse return key;
                if (valueMismatch(entry.value_ptr.*, right, key, null)) |different| return different;
            }
            var right = b.object.iterator();
            while (right.next()) |entry| {
                const key = entry.key_ptr.*;
                if (a.object.contains(key)) continue;
                if (row_id) |expected| {
                    if (std.mem.eql(u8, key, "run_id") and
                        entry.value_ptr.* == .string and
                        std.mem.eql(u8, entry.value_ptr.string, expected)) continue;
                }
                return key;
            }
            return null;
        },
        .array => {
            if (a.array.items.len != b.array.items.len) return name;
            for (a.array.items, b.array.items) |before, after| {
                if (valueMismatch(before, after, name, null)) |different| return different;
            }
            return null;
        },
        else => return if (primitiveEqual(a, b)) null else name,
    }
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
    if (local != .object or remote != .object) return .{ .group = "run", .index = 0, .field = "object" };
    const groups = [_]struct { key: []const u8, count: usize, identity: []const []const u8 }{
        .{ .key = "metrics", .count = 5, .identity = &.{ "area_id", "metric_id" } },
        .{ .key = "samples", .count = 30, .identity = &.{ "area_id", "metric_id", "phase", "sample_index" } },
        .{ .key = "scores", .count = 6, .identity = &.{"area_id"} },
        .{ .key = "artifacts", .count = 2, .identity = &.{"component"} },
    };
    const run_id = field(local, "run_id") orelse return .{ .group = "run", .index = 0, .field = "run_id" };
    if (run_id != .string) return .{ .group = "run", .index = 0, .field = "run_id" };
    var top = local.object.iterator();
    while (top.next()) |entry| {
        const key = entry.key_ptr.*;
        var is_group = false;
        for (groups) |group| if (std.mem.eql(u8, key, group.key)) {
            is_group = true;
            break;
        };
        if (is_group) continue;
        const after = field(remote, key) orelse return .{ .group = "run", .index = 0, .field = key };
        if (valueMismatch(entry.value_ptr.*, after, key, null)) |different|
            return .{ .group = "run", .index = 0, .field = different };
    }
    var extra = remote.object.iterator();
    while (extra.next()) |entry| {
        const key = entry.key_ptr.*;
        if (local.object.contains(key)) continue;
        var allowed = false;
        inline for (.{ "host_snapshot", "imported_at_utc", "sample_total", "score_validation", "server_scoring" }) |server_key| {
            if (std.mem.eql(u8, key, server_key)) allowed = true;
        }
        if (!allowed) return .{ .group = "run", .index = 0, .field = key };
    }
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
            if (valueMismatch(item, after[found], group.key, run_id.string)) |different|
                return .{ .group = group.key, .index = index, .field = different };
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
    try std.testing.expect(timeEqual("2026-11-01T17:28:49Z", "2026-11-01T17:28:49.000000000Z"));
}

test "readback detects changed original reference" {
    const before = try std.json.parseFromSlice(Value, std.testing.allocator,
        "{\"run_id\":\"79d863e6-0b84-4f9c-8a84-57f18d15245b\",\"baseline_run_id\":\"old\"}", .{});
    defer before.deinit();
    const after = try std.json.parseFromSlice(Value, std.testing.allocator,
        "{\"run_id\":\"79d863e6-0b84-4f9c-8a84-57f18d15245b\",\"baseline_run_id\":\"changed\"}", .{});
    defer after.deinit();
    const mismatch = firstMismatch(before.value, after.value) orelse return error.ExpectedMismatch;
    try std.testing.expectEqualStrings("baseline_run_id", mismatch.field);
}
