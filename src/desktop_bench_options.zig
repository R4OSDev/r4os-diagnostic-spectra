//! Only control arguments; measured SNES work stays in R4SNES.
const std = @import("std");
const cli = @import("cli.zig");
const wire = @import("desktop_check");
pub const Options = struct {
    snes: wire.SnesOptions = .{},
    own_desktop: bool = false,
    output_analysis: bool = false,
    core: bool = false,
};
pub fn parse(args: []const u8, snes: bool) !Options {
    var options: Options = .{};
    var seen: u16 = 0;
    var tokens: cli.Tokens = .{ .input = args };
    while (try tokens.next()) |word| {
        var category: u16 = 0;
        if (cli.same(word, "/OWN-DESKTOP")) { category = 1; options.own_desktop = true; }
        else if (snes and (cli.same(word, "/WINDOW") or cli.same(word, "/CORE"))) { category = 2; options.core = cli.same(word, "/CORE"); }
        else if (snes and (cli.same(word, "/NTSC") or cli.same(word, "/PAL"))) { category = 4; options.snes.pal = cli.same(word, "/PAL"); }
        else if (snes and (cli.same(word, "/NORMAL") or cli.same(word, "/DETAIL") or cli.same(word, "/PAIRED"))) {
            category = 8; options.snes.mode = if (cli.same(word, "/NORMAL")) .normal else if (cli.same(word, "/DETAIL")) .detail else .paired;
        } else if (snes and (cli.same(word, "/SMALL") or cli.same(word, "/MAXIMIZED"))) { category = 16; options.snes.maximized = cli.same(word, "/MAXIMIZED"); }
        else if (snes and cli.same(word, "/OUTPUT-ANALYSIS")) { category = 32; options.output_analysis = true; }
        else if (snes and cli.same(word, "/CHECK")) { category = 64; options.snes.check_only = true; }
        else return error.InvalidOption;
        if (seen & category != 0) return error.DuplicateOption;
        seen |= category;
    }
    return options;
}
test "benchmark control preserves explicit modes and refuses ambiguous or foreign options" {
    const options = try parse("/WINDOW /PAL /DETAIL /MAXIMIZED /CHECK /OUTPUT-ANALYSIS /OWN-DESKTOP", true);
    try std.testing.expectEqualDeep(wire.SnesOptions{ .pal = true, .mode = .detail, .maximized = true, .check_only = true }, options.snes);
    try std.testing.expect(options.own_desktop and options.output_analysis);
    try std.testing.expectError(error.DuplicateOption, parse("/NORMAL /DETAIL", true));
    try std.testing.expectError(error.DuplicateOption, parse("/CORE /WINDOW", true));
    try std.testing.expectError(error.InvalidOption, parse("/PAL", false));
    try std.testing.expect((try parse("/CORE", true)).core);
}
