//! Exact STDCHILD container transition. Hashes describe actual complete files;
//! the fixed reference and actual method keys are never rewritten.
const std = @import("std");
const model = @import("standard_model.zig");
const run_json = @import("standard_run_json.zig");
const Value = std.json.Value;
pub const policy = "stdchild-generation2-payload-equivalence-v1";
pub const original_hash = "75122e4a5a360dd0db05a81e42ca1d88b95f877dca46a09dc02b329f523e8037";
pub const current_hash = "e91432c45d49c6684ee10861df0c19daa1a696cf97e095dc63be99d6f8124e0d";
pub const original_key = "962ef07e9b752294bf76297993199651e0dd3acbe61311505fc60497e855520b";
pub const current_key = "345210f5af06c692d5d290d170b10ba48a3bfba12b2369491ae3d13d02d0b907";
pub const original_bytes: u64 = 4408;
pub const current_bytes: u64 = 4409;
// Independently compared sole9-byte payload, no relocations or extra startup:
pub const payload_sha256 = "ad7667acb97aaff8a9768f1b6d37857207481df178268fc895116382019e3c02";
pub const Compatibility = enum { same_method, exact_fixture_transition };
pub const Identity = struct { sha256: [64]u8, comparison_key: [64]u8 };

pub fn verifyCurrent(bytes: u64, actual_sha256: []const u8) !Identity {
    if (bytes != current_bytes or !std.mem.eql(u8, actual_sha256, current_hash)) return error.UnqualifiedLifecycleFixture;
    return .{ .sha256 = current_hash[0..64].*, .comparison_key = current_key[0..64].* };
}
fn field(value: Value, key: []const u8) ?Value {
    return if (value == .object) value.object.get(key) else null;
}
fn text(value: Value, key: []const u8) ?[]const u8 {
    const item = field(value, key) orelse return null;
    return if (item == .string) item.string else null;
}
fn same(value: Value, key: []const u8, expected: []const u8) bool {
    return std.mem.eql(u8, text(value, key) orelse return false, expected);
}
/// Called in addition to schema/metric/sample/reference validation. The
/// complete fixed method is checked, not only a claimed comparison key.
pub fn referenceCompatibility(actual: Identity, root: Value) ?Compatibility {
    if (!std.mem.eql(u8, &actual.sha256, current_hash) or !std.mem.eql(u8, &actual.comparison_key, current_key)) return null;
    if (!same(root, "suite_version", model.suite_version) or !same(root, "scoring_version", model.scoring_version)) return null;
    const environment = field(root, "environment") orelse return null;
    const expected = .{
        .{ "cpu_policy", model.cpu_policy },   .{ "measurement", "parallel-wall-ns-per-operation-v3" },
        .{ "filesystem", "ntfs" },             .{ "settle_ms", "200" },
        .{ "cache_state", model.cache_state }, .{ "warmup_runs", "1" },
        .{ "warmup_min_ns", "1000000000" },    .{ "warmup_min_batches", "3" },
        .{ "repetitions", "5" },
    };
    inline for (expected) |entry| if (!same(environment, entry[0], entry[1])) return null;
    const workloads = field(environment, "workloads") orelse return null;
    if (workloads != .object or workloads.object.count() != 6) return null;
    for (model.area_ids, model.workload_ids) |area, workload| if (!same(workloads, area, workload)) return null;
    const hash = text(workloads, "lifecycle_fixture_sha256") orelse return null;
    const mode: Compatibility = if (std.mem.eql(u8, hash, current_hash) and same(root, "comparison_key", current_key))
        .same_method
    else if (std.mem.eql(u8, hash, original_hash) and same(root, "comparison_key", original_key))
        .exact_fixture_transition
    else
        return null;
    const artifacts = field(root, "artifacts") orelse return null;
    if (artifacts != .array) return null;
    var found = false;
    for (artifacts.array.items) |artifact| if (same(artifact, "component", "lifecycle-fixture")) {
        if (found or !same(artifact, "sha256", hash)) return null;
        found = true;
    };
    return if (found) mode else null;
}

test "exact actual work keys and current whole-container admission stay bound" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqualStrings(original_key, &try run_json.comparisonKey(allocator, original_hash));
    try std.testing.expectEqualStrings(current_key, &try run_json.comparisonKey(allocator, current_hash));
    _ = try verifyCurrent(current_bytes, current_hash);
    try std.testing.expectError(error.UnqualifiedLifecycleFixture, verifyCurrent(original_bytes, original_hash));
    try std.testing.expectError(error.UnqualifiedLifecycleFixture, verifyCurrent(current_bytes, original_hash));
    try std.testing.expectError(error.UnqualifiedLifecycleFixture, verifyCurrent(current_bytes + 1, current_hash));
}
test "frozen original permits only exact known payload transition and complete method" {
    const parsed = try std.json.parseFromSlice(Value, std.testing.allocator, @embedFile("standard_reference_original.json"), .{});
    defer parsed.deinit();
    const actual = try verifyCurrent(current_bytes, current_hash);
    try std.testing.expectEqual(Compatibility.exact_fixture_transition, referenceCompatibility(actual, parsed.value).?);
    const environment = parsed.value.object.getPtr("environment").?;
    for ([_][]const u8{ "cpu_policy", "measurement", "filesystem", "settle_ms", "cache_state", "warmup_runs", "warmup_min_ns", "warmup_min_batches", "repetitions" }) |name| {
        const value = environment.object.getPtr(name).?;
        const original = value.*;
        value.* = .{ .string = "changed-work" };
        try std.testing.expect(referenceCompatibility(actual, parsed.value) == null);
        value.* = original;
    }
    // Available capacity is measured context under all-available fixed work.
    const cpus = environment.object.getPtr("vcpus").?;
    const previous_cpus = cpus.*;
    cpus.* = .{ .string = "8" };
    try std.testing.expect(referenceCompatibility(actual, parsed.value) != null);
    cpus.* = previous_cpus;
    const workloads = environment.object.getPtr("workloads").?;
    try workloads.object.put(parsed.arena.allocator(), "additional_work", .{ .string = "1" });
    try std.testing.expect(referenceCompatibility(actual, parsed.value) == null);
    _ = workloads.object.orderedRemove("additional_work");
    for (model.area_ids) |name| {
        const value = workloads.object.getPtr(name).?;
        const original = value.*;
        value.* = .{ .string = "additional-work" };
        try std.testing.expect(referenceCompatibility(actual, parsed.value) == null);
        value.* = original;
    }
    const artifact = parsed.value.object.getPtr("artifacts").?.array.items[2].object.getPtr("sha256").?;
    const previous_artifact = artifact.*;
    artifact.* = .{ .string = current_hash };
    try std.testing.expect(referenceCompatibility(actual, parsed.value) == null);
    artifact.* = previous_artifact;
    const hash = workloads.object.getPtr("lifecycle_fixture_sha256").?;
    hash.* = .{ .string = current_hash };
    // Merely substituting the new artifact hash cannot keep the old key.
    try std.testing.expect(referenceCompatibility(actual, parsed.value) == null);
}
