//! Pure presentation. A copied receipt, raw modulo and absolute hardware
//! count are different claims; no software clock value becomes an event count.
const std = @import("std");
pub const State = enum { measured, modulo_only, overflow, failed, inconsistent };
pub const Observation = struct {
    profile: u32 = 1,
    status: u32 = 0,
    flags: u32 = 0,
    width: u32 = 48,
    before: u64 = 0,
    after: u64 = 0,
    delta: u64 = 0,
    callback_result: i32 = 0,
    original_if: u64 = 512,
    final_if: u64 = 512,
};
pub const Decoded = struct {
    state: State,
    raw_before: ?u64 = null,
    raw_after: ?u64 = null,
    modulo_delta: ?u64 = null,
    absolute_count: ?u64 = null,
};
const raw_before: u32 = 1;
const raw_after: u32 = 2;
const absolute: u32 = 32;
const modulo: u32 = 64;
const overflow: u32 = 128;
const required: u32 = 1 | 2 | 4 | 8 | 16 | 256 | 512 | 1024 | 8192;
pub fn decode(v: Observation) Decoded {
    var out: Decoded = .{ .state = .failed, .raw_before = if (v.flags & raw_before != 0) v.before else null, .raw_after = if (v.flags & raw_after != 0) v.after else null };
    const has_count = v.flags & (absolute | modulo) != 0;
    if (!has_count) {
        if (v.status == 0) out.state = .inconsistent;
        return out;
    }
    const valid_width = v.width >= 32 and v.width <= 64;
    const mask: u64 = if (valid_width) @as(u64, std.math.maxInt(u64)) >> @as(u6, @intCast(64 - v.width)) else 0;
    if (!valid_width or v.flags & required != required or v.callback_result != 0 or
        v.original_if != 512 or v.final_if != 512 or v.before & ~mask != 0 or v.after & ~mask != 0 or
        ((v.after -% v.before) & mask) != v.delta or v.flags & modulo == 0 or
        (v.profile != 1 and v.profile != 2) or (v.profile == 2 and v.width != 48))
    {
        out.state = .inconsistent;
        return out;
    }
    if (v.profile == 1 and v.status == 4 and v.flags & overflow != 0 and v.flags & absolute == 0) {
        out.state = .overflow;
        out.modulo_delta = v.delta;
        return out;
    }
    if (v.status != 0 or v.flags & overflow != 0 or (v.profile == 2 and v.flags & absolute != 0)) {
        out.state = .inconsistent;
        return out;
    }
    out.modulo_delta = v.delta;
    if (v.profile == 1 and v.flags & absolute != 0) {
        out.state = .measured;
        out.absolute_count = v.delta;
    } else if (v.profile == 2) {
        out.state = .modulo_only;
    } else {
        out.state = .inconsistent;
        out.modulo_delta = null;
    }
    return out;
}
pub fn eventName(profile: u32, event: u32) []const u8 {
    const generic = [_][]const u8{ "unhalted core cycles", "retired instructions", "retired branches", "retired branch misses", "cache references", "cache misses" };
    if (event >= generic.len) return "unknown event";
    if (profile == 1 and event == 4) return "LLC references";
    if (profile == 1 and event == 5) return "LLC misses";
    if (profile == 2 and event == 4) return "L2 core requests (group1 mask F8)";
    if (profile == 2 and event == 5) return "L2 data-cache request misses";
    return generic[event];
}
pub fn reasonName(reason: u32) []const u8 {
    return switch (reason) {
        0 => "native profile qualified",
        1 => "no PMU exposed",
        2 => "virtual CPU; native counters unavailable",
        3 => "unsupported counter layout",
        4 => "unqualified model/event catalogue",
        5 => "malformed exposure",
        6 => "MSR unavailable",
        7 => "CPU offline",
        8 => "counter state quarantined",
        else => "unknown reason",
    };
}
pub const fixture_count = 14;
pub fn checkFixtures() bool {
    const valid: Observation = .{ .flags = required | absolute | modulo, .after = 100, .delta = 100 };
    if (decode(valid).absolute_count != 100) return false;
    var v = valid;
    v.after = 0;
    v.delta = 0;
    if (decode(v).absolute_count != 0) return false;
    v = valid;
    v.profile = 2;
    v.flags &= ~absolute;
    if (decode(v).state != .modulo_only or decode(v).absolute_count != null or decode(v).modulo_delta != 100) return false;
    v = valid;
    v.status = 4;
    v.flags = (v.flags & ~absolute) | overflow;
    if (decode(v).state != .overflow or decode(v).absolute_count != null) return false;
    v = valid;
    v.flags &= ~@as(u32, 16);
    if (decode(v).state != .inconsistent) return false;
    v = valid;
    v.flags &= ~@as(u32, 1024);
    if (decode(v).state != .inconsistent) return false;
    v = valid;
    v.final_if = 0;
    if (decode(v).state != .inconsistent) return false;
    v = valid;
    v.profile = 2;
    if (decode(v).state != .inconsistent) return false;
    v = valid;
    v.width = 0;
    if (decode(v).state != .inconsistent) return false;
    v = valid;
    v.delta = 99;
    if (decode(v).state != .inconsistent) return false;
    v = valid;
    v.status = 5;
    if (decode(v).state != .inconsistent) return false;
    v = valid;
    v.flags |= overflow;
    if (decode(v).state != .inconsistent) return false;
    v = .{ .status = 2, .flags = 0 };
    if (decode(v).raw_after != null or decode(v).absolute_count != null or decode(v).state != .failed) return false;
    v = valid;
    v.before = (1 << 48) - 3;
    v.after = 4;
    v.delta = 7;
    v.status = 4;
    v.flags = (v.flags & ~absolute) | overflow;
    if (decode(v).state != .overflow or decode(v).modulo_delta != 7) return false;
    return true;
}
test "fourteen PMU presentation cases never turn missing/overflow/modulo/time into absolute events" {
    try std.testing.expect(checkFixtures());
}
