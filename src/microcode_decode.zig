//! Pure presentation of qualified receipts; supplied/virtual data never
//! becomes a successful physical update by interpreting a revision number.
const std = @import("std");
pub const State = enum(u32) {
    not_prepared = 0, package_missing = 1, unsupported_cpu = 2, virtual_cpu = 3,
    already_current = 4, updated = 5, firmware_prerequisite = 6,
    package_rejected = 7, revision_unavailable = 8, load_failed = 9,
    revision_mismatch = 10, restart_verified = 11, restart_requires_update = 12,
    identity_changed = 13, inconsistent = 0xffff_fffe, unknown = 0xffff_ffff,
};
pub const Observation = struct {
    status: u32, virtual: bool = false, before: ?u32 = null, after: ?u32 = null,
    target: ?u32 = null, attempts: u32 = 0, post_baseline: bool = false,
};
pub const Decoded = struct { state: State, update_readback_confirmed: bool };
pub fn decode(v: Observation) Decoded {
    var state = std.enums.fromInt(State, v.status) orelse .unknown;
    if (v.virtual) {
        if (state != .virtual_cpu and state != .package_rejected and state != .identity_changed) state = .inconsistent;
    } else if (state == .virtual_cpu) state = .inconsistent;
    var confirmed = false;
    if (state == .updated) {
        confirmed = !v.virtual and v.before != null and v.after != null and v.target != null and
            v.target.? != 0 and v.after.? == v.target.? and v.before.? < v.after.? and v.attempts == 1 and v.post_baseline;
        if (!confirmed) state = .inconsistent;
    }
    if (state == .already_current or state == .restart_verified) {
        if (v.after == null or v.target == null or v.after.? < v.target.? or v.attempts != 0) state = .inconsistent;
    }
    return .{ .state = state, .update_readback_confirmed = confirmed };
}
const fixtures = [_]struct { v: Observation, state: State }{
    .{ .v = .{ .status = 3, .virtual = true, .before = 0, .after = 0 }, .state = .virtual_cpu },
    .{ .v = .{ .status = 5, .virtual = true, .before = 39, .after = 40, .target = 40, .attempts = 1, .post_baseline = true }, .state = .inconsistent },
    .{ .v = .{ .status = 5, .before = 39, .after = 40, .target = 40, .attempts = 1, .post_baseline = true }, .state = .updated },
    .{ .v = .{ .status = 5, .before = 39, .after = 39, .target = 40, .attempts = 1, .post_baseline = true }, .state = .inconsistent },
    .{ .v = .{ .status = 4, .before = 40, .after = 40, .target = 40 }, .state = .already_current },
    .{ .v = .{ .status = 6, .before = 0x0a0011d5, .after = 0x0a0011d5, .target = 0x0a0011de }, .state = .firmware_prerequisite },
    .{ .v = .{ .status = 8 }, .state = .revision_unavailable },
    .{ .v = .{ .status = 99 }, .state = .unknown },
    .{ .v = .{ .status = 12, .before = 39, .after = 39, .target = 40 }, .state = .restart_requires_update },
    .{ .v = .{ .status = 5, .before = 39, .after = 40, .target = 40, .post_baseline = true }, .state = .inconsistent },
    .{ .v = .{ .status = 5, .before = 0, .after = 0, .target = 0, .attempts = 1, .post_baseline = true }, .state = .inconsistent },
    .{ .v = .{ .status = 4, .virtual = true, .before = 40, .after = 40, .target = 40 }, .state = .inconsistent },
    .{ .v = .{ .status = 5, .before = 39, .after = 40, .target = 40, .attempts = 1 }, .state = .inconsistent },
    .{ .v = .{ .status = 4, .before = 41, .after = 41, .target = 40 }, .state = .already_current },
    .{ .v = .{ .status = 3 }, .state = .inconsistent },
};
pub const fixture_count = fixtures.len;
pub fn checkFixtures() bool {
    for (fixtures) |f| {
        const value = decode(f.v);
        if (value.state != f.state or value.update_readback_confirmed != (f.state == .updated)) return false;
    }
    return true;
}
test "microcode revision validity, exact readback, prerequisites and virtual origin stay distinct" {
    try std.testing.expect(checkFixtures());
}
