//! Pure status/model decoder. No CPU instruction, sensor, allocation or
//! physical-address/error-repair inference is permitted in this layer.
const std = @import("std");
pub const Observation = struct {
    vendor: [12]u8 = "GenuineIntel".*,
    family: u32 = 6,
    model: u32 = 0x3c,
    stepping: u32 = 3,
    profile: u32 = 1,
    virtual: bool = false,
    format: u32 = 1,
    status: u64 = 0,
    status_after: u64 = 0,
    status_read: bool = false,
    after_read: bool = false,
    unstable: bool = false,
    address_read: bool = false,
    misc_read: bool = false,
    config_read: bool = false,
    config: u64 = 0,
    ipid_read: bool = false,
    ipid: u64 = 0,
    syndrome_read: bool = false,
    syndrome: u64 = 0,
};
pub const Classification = enum { unknown, no_valid_error, incoherent, corrected_record, uncorrected, deferred_uncorrected, system_context_corrupt, thread_context_corrupt };
pub const Decoded = struct {
    classification: Classification = .unknown,
    status_valid: bool = false,
    stable_status_readback: bool = false,
    source_virtual: bool = false,
    overflow_lost_errors: ?bool = null,
    reporting_enabled: ?bool = null,
    processor_context_corrupt: ?bool = null,
    address_valid: bool = false,
    misc_valid: bool = false,
    mca_error_code: ?u16 = null,
    model_error_code: ?u16 = null,
    smca_qualified: bool = false,
    deferred: ?bool = null,
    poison: ?bool = null,
    thread_context_corrupt: ?bool = null,
    ipid_hardware_id: ?u16 = null,
    ipid_type: ?u16 = null,
    ipid_instance: ?u64 = null,
    bank_type: []const u8 = "unknown",
    syndrome_captured: bool = false,
    syndrome_priority_matches: ?bool = null,
};
fn set(value: u64, shift: u6) bool {
    return value & (@as(u64, 1) << shift) != 0;
}
fn milan(o: Observation) bool {
    return std.mem.eql(u8, &o.vendor, "AuthenticAMD") and o.profile == 3 and
        o.family == 0x19 and o.model == 1 and o.stepping == 1 and o.format == 2;
}
fn block(hwid: u16, kind: u16) []const u8 {
    // PPR55898 B1/0.50 Table38; never infer these from bank ordinal.
    if (hwid == 0) return "unpopulated";
    if (hwid == 0xb0) return switch (kind) {
        0x10 => "LS",
        1 => "IF",
        2 => "L2",
        7 => "L3",
        5 => "EX",
        6 => "FP",
        3 => "DE",
        else => "unknown",
    };
    return switch (hwid) {
        1 => switch (kind) {
            1 => "SMU",
            2 => "MP5",
            else => "unknown",
        },
        5 => if (kind == 0) "PB" else "unknown",
        0x96 => if (kind == 0) "UMC" else "unknown",
        0x18 => if (kind == 0) "NBIO" else "unknown",
        0x46 => if (kind == 0) "PCIE" else "unknown",
        0xff => if (kind == 1) "PSP" else "unknown",
        0x2e => switch (kind) {
            1 => "PIE",
            2 => "CS",
            else => "unknown",
        },
        else => "unknown",
    };
}
pub fn decode(o: Observation) Decoded {
    var d: Decoded = .{ .source_virtual = o.virtual };
    if (!o.status_read) return d;
    d.status_valid = set(o.status, 63);
    if (!d.status_valid) {
        d.classification = .no_valid_error;
        return d;
    }
    if (!o.after_read or o.unstable or o.status != o.status_after) {
        d.classification = .incoherent;
        return d;
    }
    d.stable_status_readback = true;
    const intel = std.mem.eql(u8, &o.vendor, "GenuineIntel") and (o.family == 6 or o.family == 15) and o.profile == 1 and o.format == 1;
    const amd_legacy = std.mem.eql(u8, &o.vendor, "AuthenticAMD") and o.family >= 15 and o.profile == 2 and o.format == 1;
    const smca_model = milan(o);
    if (!intel and !amd_legacy and !smca_model) return d;
    // A bank's MCAX indicator is independent of the CPU's ScalableMca bit.
    // Unknown CONFIG forbids interpreting extended status as corrected.
    if (smca_model and (!o.config_read or o.config & 1 == 0)) return d;
    d.smca_qualified = smca_model;
    d.overflow_lost_errors = set(o.status, 62);
    d.reporting_enabled = set(o.status, 60);
    d.processor_context_corrupt = set(o.status, 57);
    d.address_valid = set(o.status, 58) and o.address_read;
    d.misc_valid = set(o.status, 59) and o.misc_read;
    d.mca_error_code = @truncate(o.status);
    // Intel's model code and Milan's six-bit XEC are different contracts.
    if (intel) d.model_error_code = @truncate(o.status >> 16);
    if (smca_model) d.model_error_code = @intCast((o.status >> 16) & 63);
    const uc = set(o.status, 61);
    const pcc = set(o.status, 57);
    if (pcc) d.classification = .system_context_corrupt else if (uc) d.classification = .uncorrected else d.classification = .corrected_record;
    if (amd_legacy and !pcc and !uc and o.status & ((@as(u64, 1) << 55) | (@as(u64, 1) << 44) | (@as(u64, 1) << 43)) != 0) {
        // UC=0 alone does not establish correction with unknown AMD extended
        // status. Do not interpret another model's Deferred/TCC/Poison bits.
        d.classification = .unknown;
    }
    if (smca_model) {
        const tcc = set(o.status, 55);
        const deferred = set(o.status, 44);
        const poison = set(o.status, 43);
        d.thread_context_corrupt = tcc;
        d.deferred = deferred;
        d.poison = poison;
        if (!pcc) {
            if (uc and tcc) d.classification = .thread_context_corrupt else if (!uc and tcc) d.classification = .unknown else if (!uc and deferred) d.classification = .deferred_uncorrected else if (!uc and poison) d.classification = .unknown;
        }
        if (o.ipid_read) {
            const hwid: u16 = @intCast((o.ipid >> 32) & 0xfff);
            const kind: u16 = @truncate(o.ipid >> 48);
            d.ipid_hardware_id = hwid;
            d.ipid_type = kind;
            d.ipid_instance = (o.ipid & 0xffff_ffff) | (((o.ipid >> 44) & 15) << 32);
            // A virtual signature is not evidence of a physical failing block.
            d.bank_type = if (o.virtual) "virtual SMCA model" else block(hwid, kind);
            if (hwid == 0) d.classification = .unknown;
        }
        d.syndrome_captured = set(o.status, 53) and o.syndrome_read;
        if (d.syndrome_captured and d.classification != .unknown) {
            const expected: u64 = if (pcc) 5 else if (uc) 4 else if (deferred) 3 else 2;
            d.syndrome_priority_matches = ((o.syndrome >> 24) & 7) == expected;
        }
    }
    return d;
}
pub const fixture_count = 22;
pub fn checkFixtures() bool {
    const val: u64 = @as(u64, 1) << 63;
    var o: Observation = .{};
    if (decode(o).classification != .unknown) return false;
    o.status_read = true;
    o.status = (@as(u64, 1) << 58) | (@as(u64, 1) << 59);
    if (decode(o).classification != .no_valid_error or decode(o).address_valid) return false;
    o.status = val;
    if (decode(o).classification != .incoherent) return false;
    o.after_read = true;
    o.status_after = val;
    if (decode(o).classification != .corrected_record) return false;
    o.status |= @as(u64, 1) << 61;
    o.status_after = o.status;
    if (decode(o).classification != .uncorrected) return false;
    o.status |= @as(u64, 1) << 57;
    o.status_after = o.status;
    if (decode(o).classification != .system_context_corrupt) return false;
    o.status_after = val;
    if (decode(o).classification != .incoherent) return false;
    o = .{ .status = val, .status_after = val, .status_read = true, .after_read = true, .vendor = "OtherVendor!".* };
    if (decode(o).classification != .unknown) return false;
    o = .{ .status = val | (@as(u64, 1) << 44), .status_after = val | (@as(u64, 1) << 44), .status_read = true, .after_read = true, .vendor = "AuthenticAMD".*, .family = 0x19, .model = 1, .stepping = 1, .profile = 3, .format = 2, .config_read = true, .config = 1, .ipid_read = true, .ipid = 0x0010_00b0_0000_0001 };
    if (decode(o).classification != .deferred_uncorrected or !std.mem.eql(u8, decode(o).bank_type, "LS")) return false;
    o.status |= (@as(u64, 1) << 61) | (@as(u64, 1) << 55);
    o.status_after = o.status;
    if (decode(o).classification != .thread_context_corrupt) return false;
    o.status = val | (@as(u64, 1) << 55);
    o.status_after = o.status;
    if (decode(o).classification != .unknown) return false;
    o.status = val | (@as(u64, 1) << 43);
    o.status_after = o.status;
    if (decode(o).classification != .unknown) return false;
    o.status = val | (@as(u64, 1) << 53);
    o.status_after = o.status;
    o.syndrome_read = true;
    o.syndrome = 2 << 24;
    if (decode(o).syndrome_priority_matches != true) return false;
    o.syndrome = 4 << 24;
    if (decode(o).syndrome_priority_matches != false) return false;
    o.model = 0x21;
    if (decode(o).classification != .unknown or decode(o).smca_qualified) return false;
    o.model = 1;
    o.config_read = false;
    if (decode(o).classification != .unknown) return false;
    o.config_read = true;
    o.virtual = true;
    if (!std.mem.eql(u8, decode(o).bank_type, "virtual SMCA model") or !decode(o).source_virtual) return false;
    o.virtual = false;
    o.ipid = 0;
    if (decode(o).classification != .unknown or decode(o).syndrome_priority_matches != null) return false;
    o.ipid = 0xffff_ffff_0000_0000;
    if (!std.mem.eql(u8, decode(o).bank_type, "unknown")) return false;
    for ([_]u6{ 44, 55, 43 }) |bit| {
        const legacy_status = val | (@as(u64, 1) << bit);
        const legacy = decode(.{ .vendor = "AuthenticAMD".*, .family = 0x15, .model = 0x60, .stepping = 1, .profile = 2, .format = 1, .status = legacy_status, .status_after = legacy_status, .status_read = true, .after_read = true });
        if (legacy.classification != .unknown or legacy.deferred != null or legacy.thread_context_corrupt != null or legacy.poison != null) return false;
    }
    return true;
}
test "MCA valid bits, status coherence, corrected/deferred/context and exact SMCA model fixtures" {
    try std.testing.expect(checkFixtures());
}
