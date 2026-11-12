//! Child fixtures are commands of the same module. Argument storage belongs
//! to the caller and remains live until the synchronous spawn call returns.
const std = @import("std");
pub const path = "C:\\R4OS\\SOFTWARE\\TERMINAL\\DIAG\\SPECTRA.R4X";
pub const Arguments = struct {
    bytes: [1024:0]u8 = .{0} ** 1024,
    pub fn ptr(self: *const Arguments) [*:0]const u8 {
        return &self.bytes;
    }
};
pub fn arguments(comptime group: []const u8, original: [*:0]const u8) Arguments {
    var result: Arguments = .{};
    _ = std.fmt.bufPrintZ(&result.bytes, "CHECK " ++ group ++ " {s}", .{std.mem.span(original)}) catch {
        // Never run a default workload with truncated fixture arguments.
        const fallback = "CHECK INVALID_OVERFLOW";
        @memcpy(result.bytes[0..fallback.len], fallback);
        result.bytes[fallback.len] = 0;
    };
    return result;
}

test "child command keeps fixture arguments and overflow never starts a default check" {
    const cli = @import("cli.zig");
    const child = arguments("LIFECYCLE", "/LIFECYCLEEXIT -71 64");
    const request = try cli.parse(std.mem.span(child.ptr()));
    try std.testing.expectEqualStrings("LIFECYCLE", request.group());
    try std.testing.expectEqualStrings("/LIFECYCLEEXIT -71 64", request.args());
    const overlong = arguments("THREAD", "a" ** 1024);
    try std.testing.expectEqualStrings("CHECK INVALID_OVERFLOW", std.mem.span(overlong.ptr()));
}

// A private child may deliberately return a nonzero exit code and exactly N
// console bytes. Its payload is the parent's lifecycle oracle; an appended
// presentation record changes that payload. Explicit JSON/export callers keep
// framed presentation, as do invalid fixtures and unexpected fixture failures.
pub const FixtureOutput = union(enum) {
    framed,
    declared: struct { exit_code: i32, bytes: u32 },
    quiet_success,

    pub fn needsResult(self: FixtureOutput, result: i32) bool {
        return switch (self) {
            .framed => true,
            .declared => |value| result != value.exit_code,
            .quiet_success => result != 0,
        };
    }
};
pub fn fixtureOutput(group: []const u8, args: []const u8) FixtureOutput {
    const cli = @import("cli.zig");
    if (!cli.same(group, "LIFECYCLE")) return .framed;
    if (cli.same(args, "/COMPUTEHOLD")) return .quiet_success;
    if (cli.same(args, "/GUIPAYLOADHOLD") or cli.same(args, "/GUIRASTERCHAINHOLD") or
        cli.same(args, "/GUIFRAMEHOLD")) return .quiet_success;
    // Match the fixture's legacy bounded space/tab and decimal grammar.
    if (args.len >= 256) return .framed;
    var tokens = std.mem.tokenizeAny(u8, args, " \t");
    const mode = tokens.next() orelse return .framed;
    if (!cli.same(mode, "/LIFECYCLEEXIT")) return .framed;
    const code_text = tokens.next() orelse return .framed;
    const digits = if (code_text[0] == '-') code_text[1..] else code_text;
    if (digits.len == 0) return .framed;
    for (digits) |ch| if (!std.ascii.isDigit(ch)) return .framed;
    const code = std.fmt.parseInt(i32, code_text, 10) catch return .framed;
    const bytes_text = tokens.next() orelse return .framed;
    for (bytes_text) |ch| if (!std.ascii.isDigit(ch)) return .framed;
    const bytes = std.fmt.parseInt(u32, bytes_text, 10) catch return .framed;
    if (tokens.next() != null) return .framed;
    return .{ .declared = .{ .exit_code = code, .bytes = bytes } };
}

test "declared fixture payload preserves intentional exits and unexpected failures stay framed" {
    const raw = fixtureOutput("LIFECYCLE", "/LIFECYCLEEXIT -1 32");
    try std.testing.expectEqual(@as(u32, 32), raw.declared.bytes);
    try std.testing.expect(!raw.needsResult(-1));
    try std.testing.expect(raw.needsResult(2));
    try std.testing.expect(!fixtureOutput("LIFECYCLE", "/LIFECYCLEEXIT 101 0").needsResult(101));
    try std.testing.expect(fixtureOutput("LIFECYCLE", "/PROGRAMLIFECYCLE").needsResult(0));
    try std.testing.expect(fixtureOutput("THREAD", "/LIFECYCLEEXIT -1 32").needsResult(-1));
    for ([_][]const u8{ "/LIFECYCLEEXIT -1", "/LIFECYCLEEXIT -1 -1", "/LIFECYCLEEXIT 2147483648 32", "/LIFECYCLEEXIT -1 32 extra", "/LIFECYCLEEXIT 0 +32", "/LIFECYCLEEXIT 0 3_2", "/LIFECYCLEEXIT +0 32", "/LIFECYCLEEXIT 0 \"32\"" }) |invalid| {
        try std.testing.expect(fixtureOutput("LIFECYCLE", invalid).needsResult(-1));
        try std.testing.expect(fixtureOutput("LIFECYCLE", invalid).needsResult(0));
    }
    try std.testing.expect(!fixtureOutput("LIFECYCLE", "/COMPUTEHOLD").needsResult(0));
    try std.testing.expect(fixtureOutput("LIFECYCLE", "/COMPUTEHOLD").needsResult(1));
    for ([_][]const u8{ "/GUIPAYLOADHOLD", "/GUIRASTERCHAINHOLD", "/GUIFRAMEHOLD" }) |gui| {
        try std.testing.expect(!fixtureOutput("LIFECYCLE", gui).needsResult(0));
        try std.testing.expect(fixtureOutput("LIFECYCLE", gui).needsResult(1));
        try std.testing.expect(fixtureOutput("THREAD", gui).needsResult(0));
    }
}
