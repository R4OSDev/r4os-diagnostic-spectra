//! Child fixtures are commands of the same module. Argument storage belongs
//! to the caller and remains live until the synchronous spawn call returns.
const std = @import("std");
pub const path = "C:\\R4OS\\SOFTWARE\\TERMINAL\\DIAG\\SPECTRA.R4X";
pub const Arguments = struct {
    bytes: [1024:0]u8 = .{0} ** 1024,
    pub fn ptr(self: *const Arguments) [*:0]const u8 { return &self.bytes; }
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
