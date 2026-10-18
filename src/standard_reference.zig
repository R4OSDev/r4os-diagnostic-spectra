const std = @import("std");
const cli = @import("cli.zig");
const model = @import("standard_model.zig");
pub const Config = struct {
    area: ?usize = null,
    self_reference: bool = false,
    settle_ms: u32 = 200,
    path: [260:0]u8 = .{0} ** 260,
    key: [128]u8 = .{0} ** 128,
    key_len: usize = 0,
};
pub const Reference = struct {
    values: [5]?f64 = .{null} ** 5,
    run_id: [36]u8 = .{0} ** 36,
    reason: ?[]const u8 = "reference-not-supplied",
};
fn value(token: []const u8, prefix: []const u8) ?[]const u8 {
    if (token.len < prefix.len or !cli.same(token[0..prefix.len], prefix)) return null;
    const raw = token[prefix.len..];
    return if (raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"') raw[1 .. raw.len - 1] else raw;
}
pub fn parseOptions(args: []const u8) !Config {
    var config: Config = .{};
    var tokens: cli.Tokens = .{ .input = args };
    var settle_seen = false;
    while (try tokens.next()) |token| {
        if (cli.same(token, "/BASELINE")) {
            if (config.self_reference) return error.InvalidOption;
            config.self_reference = true;
        } else if (value(token, "/AREA:")) |id| {
            if (config.area != null) return error.InvalidOption;
            for (model.area_ids, 0..) |name, i| if (cli.same(name, id)) {
                config.area = i;
            };
            if (config.area == null) return error.InvalidOption;
        } else if (value(token, "/REFERENCE:")) |path| {
            if (path.len == 0 or path.len >= config.path.len or config.path[0] != 0) return error.InvalidOption;
            @memcpy(config.path[0..path.len], path);
        } else if (value(token, "/COMPAREKEY:")) |key| {
            if (key.len == 0 or key.len > config.key.len or config.key_len != 0) return error.InvalidOption;
            @memcpy(config.key[0..key.len], key);
            config.key_len = key.len;
        } else if (value(token, "/SETTLE:")) |ms| {
            if (settle_seen) return error.InvalidOption;
            config.settle_ms = try std.fmt.parseInt(u32, ms, 10);
            if (config.settle_ms > 5000) return error.InvalidOption;
            settle_seen = true;
        } else return error.InvalidOption;
    }
    if (config.self_reference and (config.area != null or config.path[0] != 0 or config.key_len != 0)) return error.InvalidOption;
    if ((config.path[0] != 0) != (config.key_len != 0)) return error.InvalidOption;
    return config;
}
const Value = std.json.Value;
fn field(object: Value, key: []const u8) ?Value {
    return if (object == .object) object.object.get(key) else null;
}
fn text(object: Value, key: []const u8) ?[]const u8 {
    const v = field(object, key) orelse return null;
    return if (v == .string) v.string else null;
}
fn isText(object: Value, key: []const u8, expected: []const u8) bool {
    return std.mem.eql(u8, text(object, key) orelse return false, expected);
}
fn decimal(v: Value) ?f64 {
    return switch (v) {
        .string => std.fmt.parseFloat(f64, v.string) catch null,
        .integer => @floatFromInt(v.integer),
        .float => v.float,
        .number_string => std.fmt.parseFloat(f64, v.number_string) catch null,
        else => null,
    };
}
pub fn readReference(root: Value, config: Config, detail: bool) Reference {
    var result: Reference = .{ .reason = "reference-invalid-or-incompatible" };
    const schema = decimal(field(root, "schema_version") orelse return result) orelse return result;
    if (schema != 1 or !isText(root, "status", "completed") or
        !isText(root, "suite_version", model.suite_version) or !isText(root, "scoring_version", model.scoring_version) or
        !isText(root, "instrumentation_mode", if (detail) "detail" else "base") or
        !isText(root, "comparison_key", config.key[0..config.key_len])) return result;
    const id = text(root, "run_id") orelse return result;
    if (id.len != 36) return result;
    for (id, 0..) |ch, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            if (ch != '-') return result;
        } else if (!std.ascii.isHex(ch)) return result;
    }
    const env = field(root, "environment") orelse return result;
    if ((decimal(field(env, "vcpus") orelse return result) orelse return result) < 1 or
        !isText(env, "cpu_policy", model.cpu_policy) or
        (decimal(field(env, "warmup_runs") orelse return result) orelse return result) != 1 or
        (decimal(field(env, "warmup_min_ns") orelse return result) orelse return result) != model.warmup_min_ns or
        (decimal(field(env, "warmup_min_batches") orelse return result) orelse return result) != model.warmup_min_batches or
        (decimal(field(env, "repetitions") orelse return result) orelse return result) != 5 or !isText(env, "cache_state", model.cache_state)) return result;
    const workloads = field(env, "workloads") orelse return result;
    for (model.area_ids, model.workload_ids) |area, workload| if (!isText(workloads, area, workload)) return result;
    const list = field(root, "metrics") orelse return result;
    if (list != .array or list.array.items.len != 5) return result;
    for (list.array.items) |metric| {
        const area = text(metric, "area_id") orelse return result;
        var found: ?usize = null;
        for (model.area_ids, 0..) |name, i| if (std.mem.eql(u8, name, area)) {
            found = i;
        };
        const index = found orelse return result;
        if (result.values[index] != null or !isText(metric, "metric_id", model.metric_id) or !isText(metric, "metric_version", model.metric_version) or
            !isText(metric, "status", "ok") or !isText(metric, "unit", "ns/operation") or !isText(metric, "direction", "lower_is_better") or
            (decimal(field(metric, "weight") orelse return result) orelse return result) != 1 or
            (decimal(field(metric, "sample_count") orelse return result) orelse return result) != 5) return result;
        const primary = field(metric, "primary") orelse return result;
        if (primary != .bool or !primary.bool) return result;
        const checks = field(metric, "checks") orelse return result;
        for ([_][]const u8{ "work_complete", "clock_valid", "cleanup_confirmed" }) |name| {
            const check = field(checks, name) orelse return result;
            if (check != .bool or !check.bool) return result;
        }
        const median = decimal(field(metric, "median_value") orelse return result) orelse return result;
        if (!std.math.isFinite(median) or median <= 0) return result;
        result.values[index] = median;
    }
    for (result.values) |median| if (median == null) return result;
    @memcpy(&result.run_id, id);
    result.reason = null;
    return result;
}
var file_bytes: [256 * 1024]u8 = undefined;
pub fn load(app: anytype, config: Config, detail: ?bool) Reference {
    if (config.path[0] == 0) return .{};
    const sys = app.system();
    const info = sys.fileInfo(&config.path) orelse return .{ .reason = "reference-file-missing" };
    if (info.size == 0 or info.size > file_bytes.len) return .{ .reason = "reference-file-size-invalid" };
    const got = sys.fileRead(&config.path, file_bytes[0..@intCast(info.size)]);
    if (got != info.size) return .{ .reason = "reference-file-read-incomplete" };
    const parsed = std.json.parseFromSlice(Value, sys.allocator(), file_bytes[0..@intCast(got)], .{ .allocate = .alloc_always }) catch return .{ .reason = "reference-json-invalid" };
    defer parsed.deinit();
    return readReference(parsed.value, config, detail orelse return .{ .reason = "instrumentation-mode-unavailable" });
}
test "standard parameters keep fixed work and reject ambiguous references" {
    const config = try parseOptions("/AREA:memory /REFERENCE:\"C:\\TEMP\\A B.JSON\" /COMPAREKEY:method-v1");
    try std.testing.expectEqual(@as(?usize, 1), config.area);
    try std.testing.expectEqualStrings("C:\\TEMP\\A B.JSON", std.mem.sliceTo(&config.path, 0));
    try std.testing.expectError(error.InvalidOption, parseOptions("/REFERENCE:C:\\A.JSON"));
    try std.testing.expectError(error.InvalidOption, parseOptions("/BASELINE /AREA:ipc"));
    try std.testing.expectError(error.InvalidOption, parseOptions("/REPEAT:3"));
}
test "reference parser requires the complete compatible five-area contract" {
    const parsed = try std.json.parseFromSlice(Value, std.testing.allocator, @embedFile("standard_reference_fixture.json"), .{});
    defer parsed.deinit();
    const config = try parseOptions("/REFERENCE:C:\\REF.JSON /COMPAREKEY:fixture-method");
    const valid = readReference(parsed.value, config, false);
    try std.testing.expect(valid.reason == null);
    for (valid.values) |median| try std.testing.expectEqual(@as(?f64, 1000), median);
    try std.testing.expect(readReference(parsed.value, config, true).reason != null);
    try std.testing.expect(readReference(parsed.value, try parseOptions("/REFERENCE:C:\\REF.JSON /COMPAREKEY:other"), false).reason != null);
    parsed.value.object.getPtr("metrics").?.array.items[0].object.getPtr("median_value").?.* = .{ .string = "0" };
    try std.testing.expect(readReference(parsed.value, config, false).reason != null);
}
