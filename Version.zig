const std = @import("std");

// The module manifest owns the artifact version, including self-reports.
pub const value = version: {
    @setEvalBranchQuota(10000);
    var lines = std.mem.splitScalar(u8, @embedFile("module.R4MF"), '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "VERSION=")) {
            break :version std.mem.trimEnd(u8, line[8..], "\r");
        }
    }
    @compileError("Spectra module.R4MF is missing VERSION");
};
