comptime {
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
