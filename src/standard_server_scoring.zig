//! Validate the independent automatic server score without reinterpreting the
//! immutable scores and baseline reference reported in the saved run.
const std = @import("std");
const Value = std.json.Value;

const areas = [_][]const u8{
    "scheduler_sync", "memory", "ipc", "lifecycle", "filesystem_io", "overall",
};

pub const Assessment = struct {
    baseline_id: []const u8,
    group_id: []const u8,
    is_baseline: bool,
    cross_host: bool,
    cpu_changed: bool,
    scores: [areas.len][]const u8,
    ratios: [areas.len][]Value,

    pub fn matches(a: Assessment, b: Assessment) bool {
        if (!std.mem.eql(u8, a.baseline_id, b.baseline_id) or
            !std.mem.eql(u8, a.group_id, b.group_id) or
            a.is_baseline != b.is_baseline or a.cross_host != b.cross_host or
            a.cpu_changed != b.cpu_changed) return false;
        for (areas, 0..) |_, index| {
            if (!std.mem.eql(u8, a.scores[index], b.scores[index]) or
                a.ratios[index].len != b.ratios[index].len) return false;
            for (a.ratios[index]) |left| {
                const metric_id = string(left, "metric_id") orelse return false;
                var found = false;
                for (b.ratios[index]) |right| {
                    if (!same(right, "metric_id", metric_id)) continue;
                    if (found or !same(right, "ratio", string(left, "ratio") orelse return false) or
                        !same(right, "weight", string(left, "weight") orelse return false)) return false;
                    found = true;
                }
                if (!found) return false;
            }
        }
        return true;
    }

    pub fn overall(a: Assessment) []const u8 {
        return a.scores[areas.len - 1];
    }
};

fn field(value: Value, key: []const u8) ?Value {
    return if (value == .object) value.object.get(key) else null;
}
fn string(value: Value, key: []const u8) ?[]const u8 {
    const item = field(value, key) orelse return null;
    return if (item == .string) item.string else null;
}
fn same(value: Value, key: []const u8, expected: []const u8) bool {
    return std.mem.eql(u8, string(value, key) orelse return false, expected);
}
fn boolean(value: Value, key: []const u8) ?bool {
    const item = field(value, key) orelse return null;
    return if (item == .bool) item.bool else null;
}
fn isNull(value: Value, key: []const u8) bool {
    const item = field(value, key) orelse return false;
    return item == .null;
}
fn optionalStringEqual(a: Value, a_key: []const u8, b: Value, b_key: []const u8) bool {
    const left = field(a, a_key) orelse return false;
    const right = field(b, b_key) orelse return false;
    if (left == .null or right == .null) return left == .null and right == .null;
    return left == .string and right == .string and std.mem.eql(u8, left.string, right.string);
}
fn uuid(value: []const u8) bool {
    if (value.len != 36) return false;
    for (value, 0..) |c, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            if (c != '-') return false;
        } else if (!std.ascii.isDigit(c) and (c < 'a' or c > 'f')) return false;
    }
    return true;
}
fn positiveDecimal(value: []const u8) bool {
    if (value.len == 0) return false;
    var i: usize = 0;
    var digits: usize = 0;
    var nonzero = false;
    while (i < value.len and std.ascii.isDigit(value[i])) : (i += 1) {
        digits += 1;
        nonzero = nonzero or value[i] != '0';
    }
    if (i < value.len and value[i] == '.') {
        i += 1;
        while (i < value.len and std.ascii.isDigit(value[i])) : (i += 1) {
            digits += 1;
            nonzero = nonzero or value[i] != '0';
        }
    }
    if (digits == 0 or !nonzero) return false;
    if (i < value.len and (value[i] == 'e' or value[i] == 'E')) {
        i += 1;
        if (i < value.len and (value[i] == '+' or value[i] == '-')) i += 1;
        const exponent_start = i;
        while (i < value.len and std.ascii.isDigit(value[i])) : (i += 1) {}
        if (i == exponent_start) return false;
    }
    return i == value.len;
}

/// Only the Standard-3/geomean-1 client path uses the independent policy.
pub fn applicable(local: Value) bool {
    return same(local, "suite_version", "spectra-standard-3") and
        same(local, "scoring_version", "spectra-geomean-1");
}

pub fn verify(local: Value, response: Value) !Assessment {
    if (!applicable(local)) return error.ServerScoringNotApplicable;
    const score = field(response, "server_scoring") orelse return error.ServerScoringMissing;
    if (score != .object or !same(score, "policy", "first-valid-standard-v1") or
        boolean(score, "applicable") != true) return error.ServerScoringPolicy;
    if (!same(score, "status", "valid")) return error.ServerScoreNotValid;
    if (!optionalStringEqual(local, "baseline_run_id", score, "requested_baseline_run_id"))
        return error.ServerScoringReferenceMismatch;
    const run_id = string(local, "run_id") orelse return error.ServerScoringRunMismatch;
    const baseline_id = string(score, "baseline_run_id") orelse return error.ServerScoringReferenceMismatch;
    const group_id = string(score, "baseline_group_id") orelse return error.ServerScoringGroupMismatch;
    if (!uuid(run_id) or !uuid(baseline_id) or group_id.len == 0 or group_id.len > 256)
        return error.ServerScoringReferenceMismatch;
    const is_baseline = boolean(score, "is_baseline") orelse return error.ServerScoringBaselineMismatch;
    if (is_baseline != std.mem.eql(u8, run_id, baseline_id) or
        boolean(score, "reported_scores_validated") != false) return error.ServerScoringBaselineMismatch;
    const comparison = field(score, "comparison") orelse return error.ServerScoringComparisonMismatch;
    if (!same(comparison, "status", "comparable") or !isNull(comparison, "reason"))
        return error.ServerScoringComparisonMismatch;
    const cross_host = boolean(comparison, "cross_host") orelse return error.ServerScoringComparisonMismatch;
    const cpu_changed = boolean(comparison, "cpu_changed") orelse return error.ServerScoringComparisonMismatch;
    const results = field(score, "areas") orelse return error.ServerScoringAreasMismatch;
    if (results != .object or results.object.count() != areas.len) return error.ServerScoringAreasMismatch;
    var assessment: Assessment = .{
        .baseline_id = baseline_id,
        .group_id = group_id,
        .is_baseline = is_baseline,
        .cross_host = cross_host,
        .cpu_changed = cpu_changed,
        .scores = undefined,
        .ratios = undefined,
    };
    for (areas, 0..) |area_name, index| {
        const area = field(results, area_name) orelse return error.ServerScoringAreasMismatch;
        if (!same(area, "status", "valid") or !isNull(area, "reason")) return error.ServerScoringAreasMismatch;
        const value = string(area, "score") orelse return error.ServerScoringAreasMismatch;
        if (!positiveDecimal(value)) return error.ServerScoringAreasMismatch;
        assessment.scores[index] = value;
        const ratios = field(area, "metric_ratios") orelse return error.ServerScoringAreasMismatch;
        if (ratios != .array or ratios.array.items.len > 16 or
            ((index == areas.len - 1) != (ratios.array.items.len == 0))) return error.ServerScoringAreasMismatch;
        assessment.ratios[index] = ratios.array.items;
        for (ratios.array.items) |ratio| {
            const metric_id = string(ratio, "metric_id") orelse return error.ServerScoringAreasMismatch;
            const amount = string(ratio, "ratio") orelse return error.ServerScoringAreasMismatch;
            const weight = string(ratio, "weight") orelse return error.ServerScoringAreasMismatch;
            if (metric_id.len == 0 or !positiveDecimal(amount) or !positiveDecimal(weight))
                return error.ServerScoringAreasMismatch;
        }
    }
    return assessment;
}

test "positive server decimal scores include scientific notation but exclude zero" {
    try std.testing.expect(positiveDecimal("100"));
    try std.testing.expect(positiveDecimal("101.463638"));
    try std.testing.expect(positiveDecimal("1e-99999"));
    try std.testing.expect(!positiveDecimal("0.000"));
    try std.testing.expect(!positiveDecimal("-1"));
    try std.testing.expect(!positiveDecimal("NaN"));
}
