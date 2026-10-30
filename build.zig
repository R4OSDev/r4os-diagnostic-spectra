const std = @import("std");

/// Eigenstaendiger Bau aus dem Manifest.
///
/// `zig build` erzeugt das Modul allein aus diesem Verzeichnis, ohne den Rest
/// von R4OS. Die Datei zeigt nur auf module.R4MF - Name, Klasse, Quellen,
/// Ziel, Imports und Metadaten stehen dort und nirgends sonst.
pub fn build(b: *std.Build) void {
    const desktop_wire_path: std.Build.LazyPath = .{ .cwd_relative = b.pathResolve(&.{"../../Services/WindowService/Contract/desktop_diagnostics_v1.zig"}) };
    const launch_wire_path: std.Build.LazyPath = .{ .cwd_relative = b.pathResolve(&.{"../../Services/WindowService/Contract/desktop_launch_v1.zig"}) };
    const active_wire_path: std.Build.LazyPath = .{ .cwd_relative = b.pathResolve(&.{"../../Apps/Desktop/Contract/desktop_check_v2.zig"}) };
    const image_case_path: std.Build.LazyPath = .{ .cwd_relative = b.pathResolve(&.{"../../Apps/Desktop/Tests/WindowImages/main.zig"}) };
    const active_wire = b.createModule(.{ .root_source_file = active_wire_path, .target = b.graph.host });
    const desktop_wire = b.createModule(.{ .root_source_file = desktop_wire_path, .target = b.graph.host });
    const host_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/unit_tests.zig"),
        .target = b.graph.host,
    }) });
    const test_step = b.step("test", "Spectra command, child routing and measurement contracts");
    host_tests.root_module.addImport("desktop_diagnostics", desktop_wire);
    host_tests.root_module.addImport("desktop_check", active_wire);
    test_step.dependOn(&b.addRunArtifact(host_tests).step);
    const result_tests = b.addSystemCommand(&.{ "pwsh", "-NoLogo", "-NoProfile", "-File" });
    result_tests.addFileArg(b.path("Tests/StandardBenchmark.Tests.ps1"));
    test_step.dependOn(&result_tests.step);
    const sdk_build = b.lazyImport(@This(), "r4os_sdk") orelse return;
    const sdk_dep = b.dependencyFromBuildZig(sdk_build, .{});
    const libraries_build = b.lazyImport(@This(), "r4os_libraries") orelse return;
    const libraries_dep = b.dependencyFromBuildZig(libraries_build, .{});
    const sdk = sdk_build.sdk(b, sdk_dep, .{});
    const output_module = b.createModule(.{
        .root_source_file = b.path("src/output.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    output_module.addImport("r4os", sdk.createR4osModule(b.graph.host, .Debug));
    const output_tests = b.addRunArtifact(b.addTest(.{ .root_module = output_module, .filters = &.{"audio duration"} }));
    b.step("output-test", "Actual unavailable audio duration text and JSON presentation").dependOn(&output_tests.step);
    test_step.dependOn(&output_tests.step);
    _ = sdk.addR4MFWithOptions(b.path("module.R4MF"), .{
        .zig_module_roots = &.{ libraries_dep.namedLazyPath("r4std_zig_binding"), b.path("Version.zig"), desktop_wire_path, active_wire_path, launch_wire_path, image_case_path },
    });
    _ = sdk.addR4MFWithOptions(b.path("Fixtures/StandardChild/module.R4MF"), .{});
    @import("Fixtures/Loader/build.zig").add(b, sdk_build.build_api, sdk.builder, sdk_dep);
    const desktop_cases = b.createModule(.{ .root_source_file = b.path("src/desktop_snapshot_client.zig"), .target = b.graph.host });
    desktop_cases.addImport("desktop_diagnostics", desktop_wire);
    const desktop_tests = b.addRunArtifact(b.addTest(.{ .root_module = desktop_cases }));
    const desktop_step = b.step("desktop-test", "Bounded current Desktop client/protocol/control cases");
    desktop_step.dependOn(&desktop_tests.step);
    const bench_options = b.createModule(.{ .root_source_file = b.path("src/desktop_bench_options.zig"), .target = b.graph.host });
    bench_options.addImport("desktop_check", active_wire);
    const bench_tests = b.addRunArtifact(b.addTest(.{ .root_module = bench_options }));
    desktop_step.dependOn(&bench_tests.step);
    const finish_tests = b.addRunArtifact(b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/desktop_bench_finish.zig"),
        .target = b.graph.host,
    }) }));
    desktop_step.dependOn(&finish_tests.step);
    test_step.dependOn(&finish_tests.step);
    test_step.dependOn(&bench_tests.step);
    test_step.dependOn(&desktop_tests.step);
}
