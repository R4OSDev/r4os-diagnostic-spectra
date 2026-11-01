//! Converts the 43 guest-owned records into the immutable server Schema 1
//! document. Every measured value is copied from Spectra's own records.
const std = @import("std");
const Value = std.json.Value;
const area_ids = @import("standard_model.zig").area_ids;

pub const Context = struct {
    run_id: []const u8,
    host_id: []const u8,
    started_at_utc: []const u8,
    finished_at_utc: []const u8,
    release_version: []const u8,
    kernel_version: []const u8,
    environment_id: []const u8,
    comparison_key: []const u8,
    environment: Value,
    artifacts: Value,
};

fn field(value: Value, key: []const u8) ?Value {
    return if (value == .object) value.object.get(key) else null;
}
fn string(value: Value, key: []const u8) ?[]const u8 {
    const item = field(value, key) orelse return null;
    return if (item == .string) item.string else null;
}
fn equal(value: Value, key: []const u8, expected: []const u8) bool {
    return std.mem.eql(u8, string(value, key) orelse return false, expected);
}
fn set(object: *Value, allocator: std.mem.Allocator, key: []const u8, value: Value) !void {
    try object.object.put(allocator, key, value);
}
fn text(value: []const u8) Value {
    return .{ .string = value };
}
fn canonicalScore(allocator: std.mem.Allocator, value: Value) !Value {
    if (value == .null) return value;
    if (value != .string) return error.InvalidScore;
    const number = std.fmt.parseFloat(f64, value.string) catch return error.InvalidScore;
    if (!std.math.isFinite(number) or number <= 0) return error.InvalidScore;
    return text(try std.fmt.allocPrint(allocator, "{d:.6}", .{number}));
}
fn areaIndex(name: []const u8) ?usize {
    for (area_ids, 0..) |area, i| if (std.mem.eql(u8, area, name)) return i;
    return null;
}

pub fn comparisonKey(allocator: std.mem.Allocator, fixture_sha: []const u8) ![64]u8 {
    if (fixture_sha.len != 64) return error.InvalidArtifactHash;
    for (fixture_sha) |ch| if (!((ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f'))) return error.InvalidArtifactHash;
    const canonical = try std.fmt.allocPrint(allocator, "{{\"cache_state\":\"parallel-active-per-area-1s-3batches-v3\",\"cpu_policy\":\"all-available-v1\",\"filesystem\":\"ntfs\",\"measurement\":\"parallel-wall-ns-per-operation-v3\",\"metric_version\":\"2\",\"repetitions\":\"5\",\"scoring_version\":\"spectra-geomean-1\",\"settle_ms\":\"200\",\"suite_version\":\"spectra-standard-3\",\"warmup_min_batches\":\"3\",\"warmup_min_ns\":\"1000000000\",\"warmup_runs\":\"1\",\"workloads\":{{\"filesystem_io\":\"allcpu-ntfs-stream-8x64k-v3\",\"ipc\":\"allcpu-kernel-dns-status-16384-v3\",\"lifecycle\":\"allcpu-owned-fixture-32-v3\",\"lifecycle_fixture_sha256\":\"{s}\",\"memory\":\"allcpu-demand-vm-512x128k-v3\",\"scheduler_sync\":\"allcpu-notification-ready-roundtrip-16384-v3\"}}}}", .{fixture_sha});
    defer allocator.free(canonical);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(canonical, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn build(allocator: std.mem.Allocator, records: []const u8, context: Context) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var metrics = std.json.Array.init(a);
    var samples = std.json.Array.init(a);
    var scores = std.json.Array.init(a);
    var header: ?Value = null;
    var result: ?Value = null;
    var count: usize = 0;
    var seen_metric: [5]bool = .{false} ** 5;
    var seen_sample: [5][6]bool = .{.{false} ** 6} ** 5;
    var seen_score: [6]bool = .{false} ** 6;
    var lines = std.mem.splitScalar(u8, records, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, "\r\n");
        if (line.len == 0) continue;
        if (count == 43) return error.UnexpectedRecord;
        var parsed = try std.json.parseFromSlice(Value, a, line, .{ .allocate = .alloc_always });
        if (parsed.value != .object or !equal(parsed.value, "schema", "r4os.spectra.standard")) return error.InvalidRecord;
        const version = field(parsed.value, "schema_version") orelse return error.InvalidRecord;
        if (version != .integer or version.integer != 1) return error.InvalidRecord;
        const kind = string(parsed.value, "kind") orelse return error.InvalidRecord;
        if (!parsed.value.object.orderedRemove("schema") or !parsed.value.object.orderedRemove("schema_version") or !parsed.value.object.orderedRemove("kind")) return error.InvalidRecord;
        if (std.mem.eql(u8, kind, "header")) {
            if (header != null or count != 0) return error.InvalidRecordOrder;
            header = parsed.value;
        } else if (std.mem.eql(u8, kind, "sample")) {
            if (header == null or result != null) return error.InvalidRecordOrder;
            const area = areaIndex(string(parsed.value, "area_id") orelse return error.InvalidRecord) orelse return error.InvalidRecord;
            const phase = string(parsed.value, "phase") orelse return error.InvalidRecord;
            const raw_index = string(parsed.value, "sample_index") orelse return error.InvalidRecord;
            const index = std.fmt.parseInt(usize, raw_index, 10) catch return error.InvalidRecord;
            const slot: usize = if (std.mem.eql(u8, phase, "warmup")) blk: {
                if (index != 0) return error.InvalidRecord;
                break :blk 0;
            } else if (std.mem.eql(u8, phase, "measurement")) blk: {
                if (index >= 5) return error.InvalidRecord;
                break :blk index + 1;
            } else return error.InvalidRecord;
            if (seen_sample[area][slot] or !equal(parsed.value, "metric_id", "elapsed_ns_per_operation")) return error.InvalidRecord;
            seen_sample[area][slot] = true;
            try samples.append(parsed.value);
        } else if (std.mem.eql(u8, kind, "metric")) {
            if (header == null or result != null) return error.InvalidRecordOrder;
            const area = areaIndex(string(parsed.value, "area_id") orelse return error.InvalidRecord) orelse return error.InvalidRecord;
            if (seen_metric[area] or !equal(parsed.value, "metric_id", "elapsed_ns_per_operation")) return error.InvalidRecord;
            seen_metric[area] = true;
            try metrics.append(parsed.value);
        } else if (std.mem.eql(u8, kind, "score")) {
            if (header == null or result != null) return error.InvalidRecordOrder;
            const name = string(parsed.value, "area_id") orelse return error.InvalidRecord;
            const area = if (std.mem.eql(u8, name, "overall")) @as(usize, 5) else areaIndex(name) orelse return error.InvalidRecord;
            if (seen_score[area]) return error.InvalidRecord;
            seen_score[area] = true;
            const score = field(parsed.value, "score") orelse return error.InvalidRecord;
            try set(&parsed.value, a, "score", try canonicalScore(a, score));
            try scores.append(parsed.value);
        } else if (std.mem.eql(u8, kind, "result")) {
            if (result != null or count != 42) return error.InvalidRecordOrder;
            result = parsed.value;
        } else return error.InvalidRecord;
        count += 1;
    }
    if (count != 43 or metrics.items.len != 5 or samples.items.len != 30 or scores.items.len != 6) return error.IncompleteRun;
    for (seen_metric, seen_sample) |metric, area| {
        if (!metric) return error.IncompleteRun;
        for (area) |sample| if (!sample) return error.IncompleteRun;
    }
    for (seen_score) |score| if (!score) return error.IncompleteRun;
    const h = header orelse return error.IncompleteRun;
    const r = result orelse return error.IncompleteRun;
    if (!equal(h, "suite_version", "spectra-standard-3") or !equal(h, "scoring_version", "spectra-geomean-1") or
        !equal(h, "warmup_runs", "1") or !equal(h, "warmup_min_ns", "1000000000") or
        !equal(h, "warmup_min_batches", "3") or !equal(h, "repetitions", "5") or
        !equal(h, "cpu_policy", "all-available-v1") or !equal(h, "settle_ms", "200") or
        !equal(r, "status", "completed") or !equal(r, "exit_code", "0")) return error.NonstandardRun;
    for (metrics.items) |metric| if (!equal(metric, "status", "ok") or !equal(metric, "metric_version", "2")) return error.IncompleteRun;
    for (samples.items) |sample| if (!equal(sample, "status", "ok")) return error.IncompleteRun;
    const cpus = string(h, "vcpus") orelse return error.IncompleteRun;
    if ((std.fmt.parseInt(u32, cpus, 10) catch 0) == 0 or !equal(h, "worker_count", cpus)) return error.IncompleteRun;
    if (!equal(context.environment, "vcpus", cpus)) return error.ContextMismatch;
    if (!equal(h, "reference_mode", "self") and !equal(h, "comparison_key", context.comparison_key)) return error.ContextMismatch;
    var root = (try std.json.parseFromSlice(Value, a, "{}", .{})).value;
    try set(&root, a, "run_id", text(context.run_id));
    try set(&root, a, "schema_version", .{ .integer = 1 });
    try set(&root, a, "host_id", text(context.host_id));
    try set(&root, a, "started_at_utc", text(context.started_at_utc));
    try set(&root, a, "finished_at_utc", text(context.finished_at_utc));
    try set(&root, a, "status", text("completed"));
    try set(&root, a, "failure_reason", .null);
    for ([_][]const u8{ "suite_version", "scoring_version", "spectra_version", "instrumentation_mode" }) |name| {
        try set(&root, a, name, field(h, name) orelse return error.IncompleteRun);
    }
    try set(&root, a, "release_version", text(context.release_version));
    try set(&root, a, "kernel_version", text(context.kernel_version));
    try set(&root, a, "baseline_run_id", field(scores.items[0], "baseline_run_id") orelse .null);
    try set(&root, a, "environment_id", text(context.environment_id));
    try set(&root, a, "comparison_key", text(context.comparison_key));
    try set(&root, a, "notes", text("Spectra Suite 3; direct R4OS export after completed guest measurement. Raw samples and metrics are copied without substitution."));
    try set(&root, a, "environment", context.environment);
    try set(&root, a, "artifacts", context.artifacts);
    try set(&root, a, "metrics", .{ .array = metrics });
    try set(&root, a, "samples", .{ .array = samples });
    try set(&root, a, "scores", .{ .array = scores });
    return std.json.Stringify.valueAlloc(allocator, root, .{ .whitespace = .indent_2 });
}

test "score presentation matches the six-decimal host exporter without changing raw records" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "33.67769029244681", .expected = "33.677690" },
        .{ .input = "123.5228379596652", .expected = "123.522838" },
        .{ .input = "111.53813535546284", .expected = "111.538135" },
    };
    for (cases) |case| {
        const output = try canonicalScore(allocator, text(case.input));
        defer allocator.free(output.string);
        try std.testing.expectEqualStrings(case.expected, output.string);
    }
}

test "complete guest records keep exact measurement strings in Schema 1" {
    const allocator = std.testing.allocator;
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(allocator);
    try raw.appendSlice(allocator, "{\"schema\":\"r4os.spectra.standard\",\"schema_version\":1,\"kind\":\"header\",\"suite_version\":\"spectra-standard-3\",\"scoring_version\":\"spectra-geomean-1\",\"spectra_version\":\"0.1.106\",\"instrumentation_mode\":\"base\",\"warmup_runs\":\"1\",\"warmup_min_ns\":\"1000000000\",\"warmup_min_batches\":\"3\",\"repetitions\":\"5\",\"cpu_policy\":\"all-available-v1\",\"settle_ms\":\"200\",\"vcpus\":\"4\",\"worker_count\":\"4\",\"reference_mode\":\"none\",\"comparison_key\":\"key\"}\n");
    for (area_ids) |area| {
        for (0..6) |i| {
            const line = try std.fmt.allocPrint(allocator, "{{\"schema\":\"r4os.spectra.standard\",\"schema_version\":1,\"kind\":\"sample\",\"area_id\":\"{s}\",\"metric_id\":\"elapsed_ns_per_operation\",\"phase\":\"{s}\",\"sample_index\":\"{d}\",\"status\":\"ok\",\"elapsed_ns\":\"1000\",\"worker_count\":\"4\",\"completed_workers\":\"4\"}}\n", .{ area, if (i == 0) "warmup" else "measurement", if (i == 0) @as(usize, 0) else i - 1 });
            defer allocator.free(line);
            try raw.appendSlice(allocator, line);
        }
        const line = try std.fmt.allocPrint(allocator, "{{\"schema\":\"r4os.spectra.standard\",\"schema_version\":1,\"kind\":\"metric\",\"area_id\":\"{s}\",\"metric_id\":\"elapsed_ns_per_operation\",\"metric_version\":\"2\",\"status\":\"ok\",\"median_value\":\"0.000123\"}}\n", .{area});
        defer allocator.free(line);
        try raw.appendSlice(allocator, line);
    }
    for (0..6) |i| {
        const line = try std.fmt.allocPrint(allocator, "{{\"schema\":\"r4os.spectra.standard\",\"schema_version\":1,\"kind\":\"score\",\"area_id\":\"{s}\",\"baseline_run_id\":null,\"score\":null,\"status\":\"unavailable\"}}\n", .{if (i == 5) "overall" else area_ids[i]});
        defer allocator.free(line);
        try raw.appendSlice(allocator, line);
    }
    try raw.appendSlice(allocator, "{\"schema\":\"r4os.spectra.standard\",\"schema_version\":1,\"kind\":\"result\",\"exit_code\":\"0\",\"status\":\"completed\"}\n");
    var env = try std.json.parseFromSlice(Value, allocator, "{\"vcpus\":\"4\"}", .{});
    defer env.deinit();
    var artifacts = try std.json.parseFromSlice(Value, allocator, "[]", .{});
    defer artifacts.deinit();
    const output = try build(allocator, raw.items, .{ .run_id = "123e4567-e89b-42d3-a456-426614174000", .host_id = "hw1-test", .started_at_utc = "2026-11-01T16:00:00Z", .finished_at_utc = "2026-11-01T16:01:00Z", .release_version = "0.89.3", .kernel_version = "0.1.453", .environment_id = "native", .comparison_key = "key", .environment = env.value, .artifacts = artifacts.value });
    defer allocator.free(output);
    var doc = try std.json.parseFromSlice(Value, allocator, output, .{});
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 5), field(doc.value, "metrics").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 30), field(doc.value, "samples").?.array.items.len);
    try std.testing.expectEqualStrings("0.000123", string(field(doc.value, "metrics").?.array.items[0], "median_value").?);
    try std.testing.expect(field(doc.value, "metrics").?.array.items[0].object.get("kind") == null);
}

test "Suite 3 comparison key matches the existing host exporter" {
    const key = try comparisonKey(std.testing.allocator, "75122e4a5a360dd0db05a81e42ca1d88b95f877dca46a09dc02b329f523e8037");
    try std.testing.expectEqualStrings("962ef07e9b752294bf76297993199651e0dd3acbe61311505fc60497e855520b", &key);
}
