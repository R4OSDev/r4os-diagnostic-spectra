comptime {
    _ = @import("gui_model.zig");
    _ = @import("desktop_owner_report.zig");
    _ = @import("checks/simd/environment_image.zig");
    _ = @import("mca_decode.zig");
    _ = @import("microcode_decode.zig");
    _ = @import("pmu_decode.zig");
    _ = @import("cli.zig");
    _ = @import("route.zig");
    _ = @import("desktop_snapshot_client.zig");
    _ = @import("desktop_bench_options.zig");
    _ = @import("checks/performance/measurement.zig");
    _ = @import("checks/memory/resource_balance.zig");
    _ = @import("standard_model.zig");
    _ = @import("standard_reference.zig");
}

test "GUI ignores late upload completion and revokes a changed local original" {
    const std = @import("std");
    const gui = @import("gui_model.zig");
    const id = "123e4567-e89b-42d3-a456-426614174000";
    const original = try gui.SavedRun.from(id, "C:\\R4OS\\DATA\\BENCHMARKS\\" ++ id ++ "\\RUN.JSON", "a" ** 64);
    var state: gui.Model = .{};
    try std.testing.expect(state.start());
    try std.testing.expect(state.measured(state.generation, 0, original));
    try std.testing.expect(state.upload());
    const generation = state.generation;
    try std.testing.expect(!state.uploaded(generation - 1, 0, false));
    try std.testing.expect(state.busy() and !state.upload() and !state.start());
    try std.testing.expect(state.uploaded(generation, 1, true));
    try std.testing.expect(state.saved == null and !state.canUpload());
    try std.testing.expectEqualStrings(id, &original.run_id);
    try std.testing.expectEqualStrings("a" ** 64, &original.sha256);
}

test "GUI saved result rejects foreign path and noncanonical hash before permission" {
    const std = @import("std");
    const gui = @import("gui_model.zig");
    const id = "123e4567-e89b-42d3-a456-426614174000";
    const path = "C:\\R4OS\\DATA\\BENCHMARKS\\" ++ id ++ "\\RUN.JSON";
    try std.testing.expectError(error.InvalidSavedRun, gui.SavedRun.from(id, "C:\\TEMP\\RUN.JSON", "a" ** 64));
    try std.testing.expectError(error.InvalidSavedRun, gui.SavedRun.from(id, path, "A" ** 64));
    try std.testing.expectError(error.InvalidSavedRun, gui.SavedRun.from("223e4567-e89b-42d3-a456-426614174000", path, "a" ** 64));
}
