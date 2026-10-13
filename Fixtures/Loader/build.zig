const std = @import("std");

// Unknown Runtime-R4L with a 32-byte interface header and one relocated
// function slot. Besides value+42 it owns a short, sentinel-gated CPU loop
// used solely by the SMP4 R4L-preemption acceptance. With the default zero
// sentinel the extra function returns immediately, so LOADERD's ordinary
// loader-stress starts retain their previous bounded behaviour.
const runtime_r4l_add_code = [_]u8{ 0x48, 0x89, 0xF8, 0x48, 0x83, 0xC0, 0x2A, 0xC3 };
const runtime_r4l_code = [_]u8{
    0x48, 0x89, 0xF8, 0x48, 0x83, 0xC0, 0x2A, 0xC3,
    0x48, 0x83, 0x3F, 0x03, 0x75, 0x1C,
    0x48, 0xC7, 0x07, 0x01, 0x00, 0x00, 0x00,
    0xB9, 0x00, 0x2D, 0x31, 0x01,
    0x48, 0x83, 0x3F, 0x02, 0x74, 0x06,
    0xF3, 0x90, 0xFF, 0xC9, 0x75, 0xF4,
    0x48, 0x8B, 0x07, 0xC3,
    0x31, 0xC0, 0xC3,
};
const runtime_r4l_data = [_]u8{
    0x52, 0x34, 0x49, 0x31, 0x01, 0x00, 0x00, 0x00,
    0x28, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00,
    0xEF, 0xCD, 0xAB, 0x89, 0x67, 0x45, 0x23, 0x01,
    0x10, 0x32, 0x54, 0x76, 0x98, 0xBA, 0xDC, 0xFE,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x52, 0x34, 0x4C, 0x31, 0x01, 0x00, 0x00, 0x00,
    0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
};
const runtime_r4l_bad_table = [_]u8{0} ** 8;
const loader_stress_payload_bytes: usize = 384 * 1024;

pub fn add(
    b: *std.Build,
    comptime r4os_build: type,
    builder: *std.Build.Step.Compile,
    sdk_dependency: *std.Build.Dependency,
) void {
    const generated = b.addWriteFiles();
    const runtime_code = generated.add("EXTMATH.code.bin", runtime_r4l_code[0..]);
    const runtime_add_code = generated.add("RUNTIME-ADD42.code.bin", runtime_r4l_add_code[0..]);
    const runtime_data = generated.add("EXTMATH.data.bin", runtime_r4l_data[0..]);
    const bad_table = generated.add("BADTAB.data.bin", runtime_r4l_bad_table[0..]);

    _ = r4os_build.addR4LRaw(b, .{
        .name = "EXTMATH",
        .module_version = "0.1.1",
        .code = runtime_code,
        .data = runtime_data,
        .builder = builder,
        .exports = &.{
            "API_V1:.data:0:1",
            "Query:.data:40:1",
            "PREEMPT_SPIN:.text:8:1",
            "PREEMPT_FLAG:.data:72:1",
        },
        .relocations = &.{"base_rel64:.data:32:.text:0:0"},
        .metadata = &.{
            "description=0.64.2 unknown named Runtime-R4L provider",
            "feature=runtime-r4l-named-provider",
        },
    });
    _ = r4os_build.addR4LRaw(b, .{
        .name = "DUPEXP",
        .module_version = "0.1.0",
        .code = runtime_add_code,
        .builder = builder,
        .exports = &.{ "DUPLICATE:.text:0:1", "duplicate:.text:0:1" },
        .metadata = &.{
            "description=0.64.2 duplicate export negative fixture",
            "feature=runtime-r4l-duplicate-export-negative",
        },
    });
    _ = r4os_build.addR4LRaw(b, .{
        .name = "BADTAB",
        .module_version = "0.1.0",
        .code = runtime_add_code,
        .data = bad_table,
        .builder = builder,
        .exports = &.{"API_V1:.data:0:1"},
        .metadata = &.{
            "description=0.64.2 malformed interface table negative fixture",
            "feature=runtime-r4l-malformed-interface-negative",
        },
    });
    _ = r4os_build.addR4LRaw(b, .{
        .name = "NOSYM",
        .module_version = "0.1.0",
        .code = runtime_add_code,
        .builder = builder,
        .imports = &.{"LIB021:NotThere:1"},
        .metadata = &.{
            "description=0.64.2 missing export negative fixture",
            "feature=runtime-r4l-missing-export-negative",
        },
    });
    _ = r4os_build.addR4MRaw(b, .{
        .name = "DUPM1",
        .module_name = "DUPMOD",
        .kind = "r4l",
        .extension = "R4L",
        .code = runtime_add_code,
        .builder = builder,
        .metadata = &.{
            "description=0.64.2 duplicate module provider A",
            "feature=runtime-r4l-duplicate-provider-negative",
        },
    });
    _ = r4os_build.addR4MRaw(b, .{
        .name = "DUPM2",
        .module_name = "DUPMOD",
        .kind = "r4l",
        .extension = "R4L",
        .code = runtime_add_code,
        .builder = builder,
        .metadata = &.{
            "description=0.64.2 duplicate module provider B",
            "feature=runtime-r4l-duplicate-provider-negative",
        },
    });

    const test_code = sdk_dependency.path("Tests/Fixture/Module/R4M021/TEST021.code.bin");
    const library_code = sdk_dependency.path("Tests/Fixture/Module/R4M021/LIB021.code.bin");
    _ = r4os_build.addR4LRaw(b, .{
        .name = "LIB021",
        .code = library_code,
        .builder = builder,
        .exports = &.{"LibValue:0:1"},
        .metadata = &.{
            "description=0.21.4 resolver provider library",
            "feature=resolver-positive-provider",
        },
    });
    _ = r4os_build.addR4LRaw(b, .{
        .name = "MISS021",
        .code = test_code,
        .builder = builder,
        .imports = &.{"NOPE021:Missing:1"},
        .metadata = &.{
            "description=0.21.4 missing dependency negative probe",
            "feature=resolver-negative-missing",
        },
    });
    _ = r4os_build.addR4LRaw(b, .{
        .name = "VERBAD",
        .code = test_code,
        .builder = builder,
        .imports = &.{"LIB021:LibValue:2"},
        .metadata = &.{
            "description=0.21.4 export version negative probe",
            "feature=resolver-negative-version",
        },
    });
    _ = r4os_build.addR4MRaw(b, .{
        .name = "BADSTART",
        .kind = "r4x",
        .extension = "R4X",
        .code = test_code,
        .builder = builder,
        .imports = &.{"R4SYS:Query:1"},
        .metadata = &.{
            "description=invalid R4X start contract rejection fixture",
            "feature=invalid-start-contract-negative",
            "r4x.name=BADSTART",
            "r4x.class=console",
            "r4x.start=invalid",
            "r4x.entry=MissingStart",
            "r4x.start_abi=1",
            "r4x.context=R4XStartContext",
        },
        .app_class = "console",
    });

    addLoaderStressModules(b, r4os_build, builder);
}

fn addLoaderStressModules(
    b: *std.Build,
    comptime r4os_build: type,
    builder: *std.Build.Step.Compile,
) void {
    const r4x_code = generatedFile(b, "loader-stress/LSTRX.code.bin",
        "\x48\xbf\x00\x00\x00\x00\x00\x00\x00\x00" ++
        "\x48\xb8\x00\x00\x00\x00\x00\x00\x00\x00" ++
        "\xff\xd0\x48\x83\xf8\x01\x0f\x94\xc0\x0f\xb6\xc0\xc3");
    const r4l_code = generatedFile(b, "loader-stress/LSTRL.code.bin", "\x31\xc0\xc3");
    const r4d_code = generatedFile(b, "loader-stress/LSTRD.code.bin", "\x31\xc0\xc3\x31\xc0\xc3");
    const r4p_code = generatedFile(b, "loader-stress/LSTRP.code.bin", "\x31\xc0\xc3" ++
        "\x31\xc0\xc3" ++
        "\xc7\x07\x02\x00\x00\x00\x31\xc0\xc3" ++
        "\x48\x8b\x02\x48\x85\xc0\x74\x10\xc7\x00\x4c\x53\x54\x21\xc7\x42\x08\x04\x00\x00\x00\x31\xc0\xc3\xb8\xfd\xff\xff\xff\xc3");
    const r4x_payload = generatedLoaderStressPayload(b, "loader-stress/LSTRX.rodata.bin", 0x58);
    const r4l_payload = generatedLoaderStressPayload(b, "loader-stress/LSTRL.rodata.bin", 0x4c);
    const r4d_payload = generatedLoaderStressPayload(b, "loader-stress/LSTRD.rodata.bin", 0x44);
    const r4p_payload = generatedLoaderStressPayload(b, "loader-stress/LSTRP.rodata.bin", 0x50);

    _ = r4os_build.addR4MRaw(b, .{
        .name = "LSTRX",
        .module_name = "R4X_LSTRX",
        .kind = "r4x",
        .extension = "R4X",
        .code = r4x_code,
        .rodata = r4x_payload,
        .builder = builder,
        .imports = &.{
            "R4SYS:Query:1",
            "EXTMATH:API_V1:1",
            "EXTMATH:PREEMPT_SPIN:1",
            "EXTMATH:PREEMPT_FLAG:1",
        },
        .exports = &.{"R4XStart:.text:0:1"},
        .relocations = &.{
            "import_slot64:.text:2:import3:0",
            "import_slot64:.text:12:import2:0",
        },
        .metadata = &.{
            "module.version=0.1.3",
            "r4x.name=LSTRX",
            "runtime.parallel=owned-v1",
            "r4x.class=console",
            "feature=program-module",
            "feature=loader-stress-0547",
            "r4x.start=r4xstart",
            "r4x.entry=R4XStart",
            "r4x.start_abi=1",
            "r4x.context=R4XStartContext",
            "memory.profile=normal",
            "memory.tag=loaderstress",
        },
        .app_class = "console",
    });
    _ = r4os_build.addR4LRaw(b, .{
        .name = "LSTRL",
        .code = r4l_code,
        .rodata = r4l_payload,
        .builder = builder,
        .exports = &.{"LoadStressValue:.text:0:1"},
        .metadata = &.{
            "description=0.54.7 loader stress R4L",
            "feature=loader-stress-0547",
        },
    });
    _ = r4os_build.addR4MRaw(b, .{
        .name = "LSTRD",
        .module_name = "R4D_LSTRD",
        .kind = "r4d",
        .extension = "R4D",
        .code = r4d_code,
        .rodata = r4d_payload,
        .builder = builder,
        .exports = &.{ "DriverInit:.text:0:1", "DriverShutdown:.text:3:1" },
        .metadata = &.{
            "r4d.name=LSTRD",
            "r4d.type=misc",
            "description=0.54.7 loader stress R4D discovery module",
            "feature=loader-stress-0547",
        },
    });
    _ = r4os_build.addR4MRaw(b, .{
        .name = "LSTRP",
        .module_name = "R4P_LSTRP",
        .kind = "r4p",
        .extension = "R4P",
        .code = r4p_code,
        .rodata = r4p_payload,
        .builder = builder,
        .imports = &.{"R4DEV:Query:1"},
        .exports = &.{
            "ProtocolInit:.text:0:1",
            "ProtocolShutdown:.text:3:1",
            "ProtocolQuery:.text:6:1",
            "ProtocolDispatch:.text:15:1",
            "ProtocolRole:.text:0:1",
        },
        .metadata = &.{
            "r4p.name=LSTRP",
            "r4p.role=misc.loaderstress",
            "r4p.category=misc",
            "description=0.54.7 loader stress R4P",
            "feature=loader-stress-0547",
        },
    });
}

fn generatedFile(b: *std.Build, path: []const u8, bytes: []const u8) std.Build.LazyPath {
    const files = b.addWriteFiles();
    return files.add(path, bytes);
}

fn generatedLoaderStressPayload(b: *std.Build, path: []const u8, seed: u8) std.Build.LazyPath {
    const bytes = b.allocator.alloc(u8, loader_stress_payload_bytes) catch @panic("OOM");
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        const mixed = (i *% 131) +% (@as(usize, seed) *% 17) +% (i >> 7);
        bytes[i] = @intCast(mixed & 0xff);
    }
    return generatedFile(b, path, bytes);
}
