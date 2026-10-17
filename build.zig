const std = @import("std");

/// Eigenstaendiger Bau aus dem Manifest.
///
/// `zig build` erzeugt das Modul allein aus diesem Verzeichnis, ohne den Rest
/// von R4OS. Die Datei zeigt nur auf module.R4MF - Name, Klasse, Quellen,
/// Ziel, Imports und Metadaten stehen dort und nirgends sonst.
pub fn build(b: *std.Build) void {
    const host_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/unit_tests.zig"),
        .target = b.graph.host,
    }) });
    const test_step = b.step("test", "Spectra command, child routing and measurement contracts");
    test_step.dependOn(&b.addRunArtifact(host_tests).step);
    const result_tests = b.addSystemCommand(&.{ "pwsh", "-NoLogo", "-NoProfile", "-File" });
    result_tests.addFileArg(b.path("Tests/StandardBenchmark.Tests.ps1"));
    test_step.dependOn(&result_tests.step);
    const sdk_build = b.lazyImport(@This(), "r4os_sdk") orelse return;
    const sdk_dep = b.dependencyFromBuildZig(sdk_build, .{});
    const libraries_build = b.lazyImport(@This(), "r4os_libraries") orelse return;
    const libraries_dep = b.dependencyFromBuildZig(libraries_build, .{});
    const sdk = sdk_build.sdk(b, sdk_dep, .{});
    _ = sdk.addR4MFWithOptions(b.path("module.R4MF"), .{
        .zig_module_roots = &.{ libraries_dep.namedLazyPath("r4std_zig_binding"), b.path("Version.zig") },
    });
    _ = sdk.addR4MFWithOptions(b.path("Fixtures/StandardChild/module.R4MF"), .{});
    @import("Fixtures/Loader/build.zig").add(b, sdk_build.build_api, sdk.builder, sdk_dep);
}
