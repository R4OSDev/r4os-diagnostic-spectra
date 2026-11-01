//! Stable benchmark host identity. The firmware UUID never leaves the client.
const std = @import("std");

pub const method = "smbios-system-uuid-sha256-v1";
const host_domain = "R4OS/benchmark/host-id/v1";
const identity_domain = "R4OS/benchmark/host-identity/v1";

pub const Error = error{InvalidUuid};
pub const Identity = struct {
    host_id: [64]u8,
    hash: [64]u8,
};

pub fn deriveBytes(uuid: [16]u8) Error!Identity {
    const hex = std.fmt.bytesToHex(uuid, .lower);
    var canonical: [36]u8 = undefined;
    @memcpy(canonical[0..8], hex[0..8]);
    canonical[8] = '-';
    @memcpy(canonical[9..13], hex[8..12]);
    canonical[13] = '-';
    @memcpy(canonical[14..18], hex[12..16]);
    canonical[18] = '-';
    @memcpy(canonical[19..23], hex[16..20]);
    canonical[23] = '-';
    @memcpy(canonical[24..36], hex[20..32]);
    return derive(&canonical);
}

fn lowerHex(ch: u8) bool {
    return (ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f');
}

pub fn derive(uuid: []const u8) Error!Identity {
    if (uuid.len != 36) return error.InvalidUuid;
    var repeated: ?u8 = null;
    var all_repeated = true;
    for (uuid, 0..) |ch, index| {
        if (index == 8 or index == 13 or index == 18 or index == 23) {
            if (ch != '-') return error.InvalidUuid;
            continue;
        }
        if (!lowerHex(ch)) return error.InvalidUuid;
        if (repeated) |first| {
            all_repeated = all_repeated and ch == first;
        } else repeated = ch;
    }
    if (all_repeated) return error.InvalidUuid;
    const host_digest = digest(host_domain, uuid);
    const identity_digest = digest(identity_domain, uuid);
    const host_hex = std.fmt.bytesToHex(host_digest, .lower);
    const identity_hex = std.fmt.bytesToHex(identity_digest, .lower);
    var result: Identity = undefined;
    @memcpy(result.host_id[0..4], "hw1-");
    @memcpy(result.host_id[4..], host_hex[0..60]);
    result.hash = identity_hex;
    return result;
}

fn digest(comptime domain: []const u8, uuid: []const u8) [32]u8 {
    var sha = std.crypto.hash.sha2.Sha256.init(.{});
    sha.update(domain);
    sha.update(&.{0});
    sha.update(uuid);
    var result: [32]u8 = undefined;
    sha.final(&result);
    return result;
}

test "server 0.5.19 canonical synthetic UUID vector" {
    const value = try derive("123e4567-e89b-12d3-a456-426614174000");
    try std.testing.expectEqualStrings("hw1-059340d0ce0ef6bd1fe8492bdee6426cf64202f791a35bf8522c9ff7fcbc", &value.host_id);
    try std.testing.expectEqualStrings("beaf5e9c75bc93b8b7ba2c79be16782765e63204a8049080f17c3652a7862043", &value.hash);
    const bytes: [16]u8 = .{
        0x12, 0x3e, 0x45, 0x67, 0xe8, 0x9b, 0x12, 0xd3,
        0xa4, 0x56, 0x42, 0x66, 0x14, 0x17, 0x40, 0x00,
    };
    const decoded = try deriveBytes(bytes);
    try std.testing.expectEqualSlices(u8, &value.host_id, &decoded.host_id);
    try std.testing.expectEqualSlices(u8, &value.hash, &decoded.hash);
}

test "only canonical nontrivial firmware UUIDs are admitted" {
    for ([_][]const u8{
        "00000000-0000-0000-0000-000000000000",
        "ffffffff-ffff-ffff-ffff-ffffffffffff",
        "11111111-1111-1111-1111-111111111111",
        "123E4567-e89b-12d3-a456-426614174000",
        "123e4567e89b12d3a456426614174000",
        "123e4567-e89b-12d3-a456-42661417400g",
    }) |invalid| try std.testing.expectError(error.InvalidUuid, derive(invalid));
}
