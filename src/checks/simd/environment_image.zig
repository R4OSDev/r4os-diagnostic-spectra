//! Integer-only architectural oracle. Empty x87 register data is unspecified.
const std = @import("std");
pub const Pattern = extern struct {
    bytes: [704]u8 align(64) = @splat(0),
    pub fn init(seed: u32) Pattern {
        var p: Pattern = .{};
        for (p.bytes[0..512], 0..) |*b, i| b.* = @truncate((@as(u32, @intCast(i)) *% 73 +% seed) ^ (@as(u32, @intCast(i)) >> 3));
        for (0..8) |i| {
            const sig: u64 = 0x8000_0000_0000_0000 | ((i + 1) * 0x0102_0304_0506_0708 + seed);
            std.mem.writeInt(u64, p.bytes[512 + i * 16 ..][0..8], sig, .little);
            std.mem.writeInt(u16, p.bytes[520 + i * 16 ..][0..2], 0x3fff | @as(u16, if (i & 1 != 0) 0x8000 else 0), .little);
            const mm: u64 = 0x1928_3746_5546_3728 ^ (@as(u64, seed) << 24) ^ ((i + 1) * 0x0101_0101_0101_0101);
            std.mem.writeInt(u64, p.bytes[640 + i * 8 ..][0..8], mm, .little);
        }
        return p;
    }
};
pub const Output = extern struct { bytes: [2112]u8 align(64) = @splat(0) };
pub const Control = extern struct {
    cw: u16,
    reserved: u16 = 0,
    mxcsr: u32,
    avx: u32,
    phase: u32,
    pub fn init(round: u32, extras: u32, avx: bool, phase: u32) Control {
        return .{ .cw = 0x037f | (@as(u16, @intCast(round)) << 10), .mxcsr = 0x1f80 | (round << 13) | extras, .avx = @intFromBool(avx), .phase = phase };
    }
};
pub fn u16At(b: []const u8, o: usize) u16 {
    return std.mem.readInt(u16, b[o..][0..2], .little);
}
pub fn u32At(b: []const u8, o: usize) u32 {
    return std.mem.readInt(u32, b[o..][0..4], .little);
}
pub fn u64At(b: []const u8, o: usize) u64 {
    return std.mem.readInt(u64, b[o..][0..8], .little);
}
pub fn mxcsrMask(b: []const u8) u32 {
    const m = u32At(b, 28) & 0xffff;
    return if (m == 0) 0xffbf else m;
}
pub fn defaults(b: []const u8) bool {
    return u16At(b, 0) == 0x37f and u16At(b, 2) & 0x38ff == 0 and b[4] == 0 and u32At(b, 24) == 0x1f80;
}
pub fn valid(p: *const Pattern, c: Control, o: *const Output) bool {
    const top: u16 = if (c.phase == 0) 2 else if (c.phase == 1) 0 else 5;
    const tags: u8 = if (c.phase == 2) 0xe0 else 0xff;
    const live: usize = if (c.phase == 2) 3 else 8;
    if (c.phase > 2) return false;
    for ([_]usize{ 0, 512 }) |off| {
        const b = o.bytes[off .. off + 512];
        if (u16At(b, 0) != c.cw or u16At(b, 2) != (top << 11) or b[4] != tags or u32At(b, 24) != c.mxcsr) return false;
        for (0..live) |i| {
            const pos = 32 + i * 16;
            if (c.phase == 1) {
                if (!std.mem.eql(u8, b[pos .. pos + 8], p.bytes[640 + i * 8 .. 648 + i * 8]) or u16At(b, pos + 8) != 0xffff) return false;
            } else {
                const src = if (c.phase == 0) (13 - i) % 8 else 2 - i;
                if (!std.mem.eql(u8, b[pos .. pos + 10], p.bytes[512 + src * 16 .. 522 + src * 16])) return false;
            }
        }
        for (0..16) |i| if (!std.mem.eql(u8, b[160 + i * 16 .. 176 + i * 16], p.bytes[i * 32 .. i * 32 + 16])) return false;
    }
    const width: usize = if (c.avx != 0) 32 else 16;
    for (0..16) |i| if (!std.mem.eql(u8, o.bytes[1024 + i * 32 .. 1024 + i * 32 + width], p.bytes[i * 32 .. i * 32 + width])) return false;
    const expected = ([_]u64{ 2, 1, 2, 1 })[(c.cw >> 10) & 3];
    return u64At(&o.bytes, 1536) == expected and u64At(&o.bytes, 1544) == expected and o.bytes[1604] == 0;
}
test "zero architectural MXCSR mask cannot enable DAZ" {
    const b: [512]u8 = @splat(0);
    try std.testing.expectEqual(@as(u32, 0xffbf), mxcsrMask(&b));
    try std.testing.expectEqual(@as(u32, 0), mxcsrMask(&b) & 0x40);
}
test "empty x87 tags define control not stale data" {
    var b: [512]u8 = @splat(0xa5);
    std.mem.writeInt(u16, b[0..2], 0x37f, .little);
    std.mem.writeInt(u16, b[2..4], 0, .little);
    b[4] = 0;
    std.mem.writeInt(u32, b[24..28], 0x1f80, .little);
    try std.testing.expect(defaults(&b));
    b[2] = 1;
    try std.testing.expect(!defaults(&b));
}
test "all sixteen pattern registers and eight finite extended inputs differ" {
    const p = Pattern.init(19);
    for (0..8) |i| {
        try std.testing.expect(u64At(&p.bytes, 512 + i * 16) >> 63 != 0);
        try std.testing.expectEqual(@as(u16, 0x3fff), u16At(&p.bytes, 520 + i * 16) & 0x7fff);
    }
    for (1..16) |i| try std.testing.expect(!std.mem.eql(u8, p.bytes[0..32], p.bytes[i * 32 .. i * 32 + 32]));
    try std.testing.expectEqual(@as(usize, 704), @sizeOf(Pattern));
    try std.testing.expectEqual(@as(usize, 2112), @sizeOf(Output));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Control));
}
