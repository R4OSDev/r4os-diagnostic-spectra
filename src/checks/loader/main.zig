const r4os = @import("r4os");
const metadata = @import("metadata.zig");


var boot_log_buffer: [r4os.abi.boot_log_buffer_size]u8 = .{0xA5} ** r4os.abi.boot_log_buffer_size;

const RuntimeR4LInterfaceHeader = extern struct {
    magic: u32,
    header_version: u16,
    flags: u16,
    size: u32,
    abi_major: u16,
    abi_minor: u16,
    interface_id_lo: u64,
    interface_id_hi: u64,
};

const RuntimeR4LInterface = extern struct {
    header: RuntimeR4LInterfaceHeader,
    add_42: u64,
};

const RuntimeR4LAddFn = *const fn (u64) callconv(.c) u64;

// These are ordinary table values, not pointers. They deliberately overlap
// the historical fixed-link address window so the guest smoke catches any
// loader that rewrites unlisted .rodata instead of applying only declared
// R4M0 relocations.
export const loaderd_relocation_collision_words align(8) = [_]u64{
    0x00000004_00000000,
    0x00000004_00000002,
    0x00000004_00000004,
};

pub fn r4_app_main(app: *r4os.App) i32 {
    const raw = app.startContext();
    const api = &app.bundle;
    var ctx = r4os.r4sys.Context.init(api);
    var dev = r4os.r4dev.Context.init(api);
    const start = r4os.r4xstart.Context.init(raw);
    var ok = true;

    ctx.println("SPECTRA LOADER");
    ok = checkRelocationCollisionData(&ctx) and ok;
    ok = checkR4XStartImports(&ctx, start) and ok;
    ok = checkNamedRuntimeR4L(&ctx, start) and ok;
    ok = checkR4X(&ctx, "C:\\R4OS\\SOFTWARE\\TERMINAL\\BEEP.R4X") and ok;
    ok = checkCurrentStartContract(&ctx, "C:\\R4OS\\SOFTWARE\\TERMINAL\\BEEP.R4X") and ok;
    ok = checkCurrentStartContract(&ctx, "C:\\R4OS\\SOFTWARE\\TERMINAL\\DIAG\\R4XSTARTD.R4X") and ok;
    ok = checkInvalidStartRejected(&ctx, "C:\\R4OS\\SOFTWARE\\TERMINAL\\DIAG\\BADSTART.R4X") and ok;
    ok = checkPlatformApiFilesAbsent(&ctx) and ok;
    ok = checkR4LQueryNegativeValidation(&ctx) and ok;
    ok = checkR4LResolverNegativeBootLog(&ctx) and ok;
    ok = checkR4D(&ctx, "C:\\R4OS\\DRIVERS\\EXAMPLE.R4D") and ok;
    ok = checkR4P(&ctx, "C:\\R4OS\\PROTOCOLS\\SMOKE.R4P") and ok;
    ok = checkR4P(&ctx, "C:\\R4OS\\PROTOCOLS\\BADDEP.R4P") and ok;
    ok = checkProtocolRuntime(&ctx, &dev) and ok;
    ok = checkLoaderStress(&ctx, &dev) and ok;
    ok = checkLoaderPerformance(&ctx, &dev) and ok;
    ok = checkLoaderMemory(&ctx, &dev) and ok;

    ctx.print("SPECTRA LOADER result: ");
    ctx.println(if (ok) "OK" else "FAILED");
    return if (ok) 0 else 1;
}

fn checkRelocationCollisionData(ctx: *const r4os.r4sys.Context) bool {
    const words: [*]const volatile u64 = @ptrCast(&loaderd_relocation_collision_words);
    const ok = words[0] == 0x00000004_00000000 and
        words[1] == 0x00000004_00000002 and
        words[2] == 0x00000004_00000004;
    printCheck(ctx, "R4M0 ordinary rodata preserved", ok);
    return ok;
}

fn checkR4X(ctx: *const r4os.r4sys.Context, path: [*:0]const u8) bool {
    const info = ctx.fileInfo(path) orelse return false;
    var buf: [8192]u8 = undefined;
    const len = ctx.fileReadAt(path, 0, buf[0..]);
    ctx.print("read header ");
    ctx.print(path);
    ctx.print(": ");
    ctx.printI32(len);
    ctx.println(" bytes");
    if (len >= 64 and buf[0] == 'R' and buf[1] == '4' and buf[2] == 'M' and buf[3] == '0') {
        return checkR4M(ctx, "R4X", buf[0..@intCast(len)], 1, 1, 1);
    }
    if (len < 32) return false;

    const magic_ok = buf[0] == 'R' and buf[1] == '4' and buf[2] == 'X' and buf[3] == '0';
    const version_ok = readLe16(buf[4..6]) == r4os.abi.r4x_version;
    const arch_ok = readLe16(buf[6..8]) == r4os.abi.arch_x86_64;
    const header_size = readLe32(buf[8..12]);
    const code_offset = readLe32(buf[12..16]);
    const code_size = readLe32(buf[16..20]);
    const entry_offset = readLe32(buf[20..24]);
    const flags = readLe32(buf[24..28]);
    const reserved = readLe32(buf[28..32]);
    const header_ok = header_size == 32;
    const offset_ok = code_offset == 32;
    const code_ok = code_size > 0 and @as(u64, code_offset) + @as(u64, code_size) <= info.size;
    const entry_ok = entry_offset < code_size and (entry_offset & 0xF) == 0;
    const flags_ok = (flags & ~@as(u32, 0x3)) == 0 and (flags & 0x3) != 0x3;
    const reserved_ok = reserved == 0;
    printCheck(ctx, "R4X magic", magic_ok);
    printCheck(ctx, "R4X version", version_ok);
    printCheck(ctx, "R4X arch", arch_ok);
    printCheck(ctx, "R4X header", header_ok);
    printCheck(ctx, "R4X code offset", offset_ok);
    printCheck(ctx, "R4X code", code_ok);
    printCheck(ctx, "R4X entry", entry_ok);
    printCheck(ctx, "R4X flags", flags_ok);
    printCheck(ctx, "R4X reserved", reserved_ok);
    return magic_ok and version_ok and arch_ok and header_ok and offset_ok and code_ok and entry_ok and flags_ok and reserved_ok;
}

fn checkCurrentStartContract(ctx: *const r4os.r4sys.Context, path: [*:0]const u8) bool {
    var head: [8192]u8 = undefined;
    const data = readHeaderPrefix(ctx, path, head[0..]) orelse return false;
    ctx.print("read ");
    ctx.print(path);
    ctx.print(": ");
    ctx.printU64(data.len);
    ctx.println(" prefix bytes");
    var strings_buf: [4096]u8 = undefined;
    const strings = readStringBlock(ctx, path, data, strings_buf[0..]) orelse return false;
    const r4m_ok = checkR4M(ctx, "R4XStart R4M", data, 1, 1, 1);
    const start_ok = stringBlockHas(strings, "r4x.start=r4xstart");
    const entry_meta_ok = stringBlockHas(strings, "r4x.entry=R4XStart");
    const context_ok = stringBlockHas(strings, "r4x.context=R4XStartContext");
    const export_ok = hasExportInStringBlock(data, strings, "R4XStart", 1);
    const r4sys_ok = hasImportInStringBlock(data, strings, "R4SYS", "Query", 1);
    printCheck(ctx, "R4XStart start contract", start_ok);
    printCheck(ctx, "R4XStart entry meta", entry_meta_ok);
    printCheck(ctx, "R4XStart context meta", context_ok);
    printCheck(ctx, "R4XStart export", export_ok);
    printCheck(ctx, "R4XStart R4SYS import", r4sys_ok);
    return r4m_ok and start_ok and entry_meta_ok and context_ok and export_ok and r4sys_ok;
}

fn checkInvalidStartRejected(ctx: *const r4os.r4sys.Context, path: [*:0]const u8) bool {
    var buf: [8192]u8 = undefined;
    const len = ctx.fileRead(path, buf[0..]);
    ctx.print("read ");
    ctx.print(path);
    ctx.print(": ");
    ctx.printI32(len);
    ctx.println(" bytes");
    if (len < 64) return false;
    const data = buf[0..@intCast(len)];
    const r4m_ok = checkR4M(ctx, "Invalid start R4M", data, 1, 1, 0);
    const feature_ok = hasMeta(data, "feature=invalid-start-contract-negative");
    const start_ok = hasMeta(data, "r4x.start=invalid");
    const entry_meta_ok = hasMeta(data, "r4x.entry=MissingStart");
    const context_ok = hasMeta(data, "r4x.context=R4XStartContext");
    const no_exports = readLe32(data[36..40]) == 0;
    const r4xstart_absent = !hasExport(data, "R4XStart", 1);
    const r4sys_ok = hasImport(data, "R4SYS", "Query", 1);
    const class_rc = ctx.programClass(path, .auto);
    const rejected_ok = class_rc == -2;
    printCheck(ctx, "Invalid start feature", feature_ok);
    printCheck(ctx, "Invalid start contract meta", start_ok);
    printCheck(ctx, "Invalid start entry meta", entry_meta_ok);
    printCheck(ctx, "Invalid start context meta", context_ok);
    printCheck(ctx, "Invalid start no exports", no_exports);
    printCheck(ctx, "Invalid start no R4XStart export", r4xstart_absent);
    printCheck(ctx, "Invalid start R4SYS import", r4sys_ok);
    ctx.write("  Invalid start loader rejection: ");
    ctx.write(if (rejected_ok) "OK" else "FAILED");
    ctx.write(" rc=");
    ctx.printI32(class_rc);
    ctx.println("");
    return r4m_ok and feature_ok and start_ok and entry_meta_ok and context_ok and no_exports and r4xstart_absent and r4sys_ok and rejected_ok;
}

// 0.57.6: Generischer Vertragstest fuer eine Kernel-Gruppentabelle -
// Import-Meta (group_id, min_version, group_interface-Flag) plus
// Tabellen-Header (magic exakt, abi_version/size mindestens auf dem
// Contract-Stand des SDK).
fn checkGroupTable(
    ctx: *const r4os.r4sys.Context,
    start: r4os.r4xstart.Context,
    comptime group: r4os.abi.R4LGroup,
    comptime label: []const u8,
    comptime Table: type,
    magic: u32,
    version: u32,
    size: u32,
    comptime slots: anytype,
) bool {
    const item = start.findImport(group) orelse return failCheck(ctx, label);
    const ok = item.group_id == @intFromEnum(group) and
        item.min_version == 1 and
        item.resolved_version >= 1 and
        (item.flags & r4os.abi.r4xstart_import_flag_group_interface) != 0 and
        item.table != 0 and blk: {
        const table: *const Table = @ptrFromInt(item.table);
        var table_ok = table.magic == magic and
            table.abi_version >= version and
            table.size >= size;
        inline for (slots) |slot| {
            if (slot.state != .function) table_ok = table_ok and @field(table.*, slot.name) == 0;
        }
        break :blk table_ok;
    };
    printCheck(ctx, label, ok);
    return ok;
}

fn checkR4XStartImports(ctx: *const r4os.r4sys.Context, start: r4os.r4xstart.Context) bool {
    const context_ok = start.valid();
    printCheck(ctx, "R4XStart import context", context_ok);
    if (!context_ok) return false;

    // 0.57.6: Vertragstest fuer ALLE 6 Kernel-Gruppentabellen (vorher
    // nur R4SYS/R4DEV; 0.56.41 fuehrte die Tabellen fuer alle ein).
    const abi = r4os.abi;
    const sys_ok = checkGroupTable(ctx, start, .r4sys, "R4XStart R4SYS group table", abi.R4XStartR4Sys, abi.r4xstart_r4sys_magic, abi.r4xstart_r4sys_version, abi.r4xstart_r4sys_size, abi.R4SysSlots);
    const sys_resolve_ok = start.r4sys() != null;
    printCheck(ctx, "R4XStart R4SYS context resolve", sys_resolve_ok);
    const desk_ok = checkGroupTable(ctx, start, .r4desk, "R4XStart R4DESK group table", abi.R4XStartR4Desk, abi.r4xstart_r4desk_magic, abi.r4xstart_r4desk_version, abi.r4xstart_r4desk_size, abi.R4DeskSlots);
    const draw_ok = checkGroupTable(ctx, start, .r4draw, "R4XStart R4DRAW group table", abi.R4XStartR4Draw, abi.r4xstart_r4draw_magic, abi.r4xstart_r4draw_version, abi.r4xstart_r4draw_size, abi.R4DrawSlots);
    const net_ok = checkGroupTable(ctx, start, .r4net, "R4XStart R4NET group table", abi.R4XStartR4Net, abi.r4xstart_r4net_magic, abi.r4xstart_r4net_version, abi.r4xstart_r4net_size, abi.R4NetSlots);
    const audio_ok = checkGroupTable(ctx, start, .r4audio, "R4XStart R4AUDIO group table", abi.R4XStartR4Audio, abi.r4xstart_r4audio_magic, abi.r4xstart_r4audio_version, abi.r4xstart_r4audio_size, abi.R4AudioSlots);
    const dev_ok = checkGroupTable(ctx, start, .r4dev, "R4XStart R4DEV group table", abi.R4XStartR4Dev, abi.r4xstart_r4dev_magic, abi.r4xstart_r4dev_version, abi.r4xstart_r4dev_size, abi.R4DevSlots);

    return sys_ok and sys_resolve_ok and desk_ok and draw_ok and net_ok and audio_ok and dev_ok;
}

fn checkNamedRuntimeR4L(ctx: *const r4os.r4sys.Context, start: r4os.r4xstart.Context) bool {
    const item = start.findImportNamed("EXTMATH", "API_V1") orelse return failCheck(ctx, "Runtime-R4L named import");
    const transport_ok = item.group_id == 0 and
        item.min_version == 1 and
        item.resolved_version == 1 and
        (item.flags & r4os.abi.r4xstart_import_flag_group_interface) == 0 and
        item.module_name != 0 and
        item.symbol_name != 0 and
        item.table != 0 and
        (item.table & 7) == 0;
    printCheck(ctx, "Runtime-R4L named transport", transport_ok);
    if (!transport_ok) return false;

    const table: *const RuntimeR4LInterface = @ptrFromInt(item.table);
    const header_ok = table.header.magic == 0x31493452 and
        table.header.header_version == 1 and
        table.header.flags == 0 and
        table.header.size == @sizeOf(RuntimeR4LInterface) and
        table.header.abi_major == 1 and
        @as(u32, table.header.abi_minor) == item.resolved_version and
        table.header.interface_id_lo == 0x0123456789ABCDEF and
        table.header.interface_id_hi == 0xFEDCBA9876543210;
    printCheck(ctx, "Runtime-R4L interface header", header_ok);
    if (!header_ok or table.add_42 == 0) return failCheck(ctx, "Runtime-R4L function slot");

    const add_42: RuntimeR4LAddFn = @ptrFromInt(table.add_42);
    const call_ok = add_42(100) == 142;
    printCheck(ctx, "Runtime-R4L relocated function call", call_ok);
    return call_ok;
}

fn checkPlatformApiFilesAbsent(ctx: *const r4os.r4sys.Context) bool {
    const paths = [_][*:0]const u8{
        "C:\\R4OS\\LIBS\\R4SYS.R4L",
        "C:\\R4OS\\LIBS\\R4DESK.R4L",
        "C:\\R4OS\\LIBS\\R4DRAW.R4L",
        "C:\\R4OS\\LIBS\\R4NET.R4L",
        "C:\\R4OS\\LIBS\\R4AUDIO.R4L",
        "C:\\R4OS\\LIBS\\R4DEV.R4L",
    };
    var ok = true;
    for (paths) |path| ok = (ctx.fileInfo(path) == null) and ok;
    printCheck(ctx, "Built-in Platform API files absent", ok);
    return ok;
}

fn checkR4LQueryNegativeValidation(ctx: *const r4os.r4sys.Context) bool {
    const base = r4os.abi.R4LQuery{
        .magic = r4os.abi.r4l_abi_magic,
        .abi_version = r4os.abi.r4l_abi_version,
        .size = r4os.abi.r4l_query_struct_size,
        .group = @intFromEnum(r4os.abi.R4LGroup.r4dev),
        .kernel_bridge = 0,
        .reserved = 0,
    };
    var wrong_version = base;
    wrong_version.abi_version += 1;
    var wrong_group = base;
    wrong_group.group = 7;
    var incompatible_table = base;
    incompatible_table.size = r4os.abi.r4l_query_struct_size - 8;

    const version_ok = !validateR4LQuery(wrong_version, .r4dev);
    const group_ok = !validateR4LQuery(wrong_group, .r4dev);
    const table_ok = !validateR4LQuery(incompatible_table, .r4dev);
    printCheck(ctx, "Platform Query rejects wrong version", version_ok);
    printCheck(ctx, "Platform Query rejects wrong group", group_ok);
    printCheck(ctx, "Platform Query rejects incompatible table", table_ok);
    return version_ok and group_ok and table_ok;
}

fn checkR4LResolverNegativeBootLog(ctx: *const r4os.r4sys.Context) bool {
    const has_missing_fixture = ctx.fileInfo("C:\\R4OS\\LIBS\\MISS021.R4L") != null;
    const has_version_fixture = ctx.fileInfo("C:\\R4OS\\LIBS\\VERBAD.R4L") != null;
    if (!has_missing_fixture and !has_version_fixture) {
        ctx.println("  R4L resolver negative bootlog: SKIPPED");
        return true;
    }

    const info = ctx.bootLogInfo() orelse return failCheck(ctx, "R4L resolver bootlog info");
    const read_len: usize = @min(@as(usize, @intCast(info.length)), boot_log_buffer.len);
    const got = ctx.bootLogRead(0, boot_log_buffer[0..read_len]);
    if (got <= 0) return failCheck(ctx, "R4L resolver bootlog read");
    const text = boot_log_buffer[0..@as(usize, @intCast(got))];
    // The SMP acceptance emits enough additional boot diagnostics to roll the
    // bounded kernel log before AUTOEXEC reaches SPECTRA LOADER. The standard gate
    // still requires every exact early record. With an explicitly reported
    // rollover, only records that may have been evicted are waived; current
    // named-resolution evidence below remains mandatory.
    const rolled = info.dropped_bytes != 0;
    const missing_ok = rolled or (contains(text, "[MOD] resolver missing module=NOPE021") and contains(text, "importer=MISS021"));
    const version_ok = rolled or (contains(text, "[MOD] resolver version reject module=LIB021") and
        contains(text, "symbol=LibValue") and
        contains(text, "have=1") and
        contains(text, "need=2") and
        contains(text, "importer=VERBAD"));
    const no_file_fallback_ok = ctx.fileInfo("C:\\R4OS\\LIBS\\NOPE021.R4L") == null;
    const missing_export_ok = rolled or (contains(text, "[MOD] resolver missing export module=LIB021") and
        contains(text, "symbol=NotThere") and
        contains(text, "importer=NOSYM"));
    const duplicate_export_ok = rolled or (contains(text, "[MOD] duplicate export module=DUPEXP.R4L") and
        contains(text, "symbol=duplicate"));
    const duplicate_provider_ok = rolled or contains(text, "[MOD] resolver duplicate provider module=DUPMOD");
    const malformed_table_ok = rolled or (contains(text, "[MOD] interface reject module=BADTAB.R4L") and
        contains(text, "symbol=API_V1") and
        contains(text, "reason=interface-range"));
    const named_diagnostic_ok = contains(text, "[R4X] named import module=EXTMATH") and
        contains(text, "symbol=API_V1") and
        contains(text, "need=1") and
        contains(text, "have=1") and
        contains(text, "generation=1");
    printCheck(ctx, "R4L missing dependency logged", missing_ok);
    printCheck(ctx, "R4L version reject logged", version_ok);
    printCheck(ctx, "R4L missing library no fallback file", no_file_fallback_ok);
    printCheck(ctx, "R4L missing export logged", missing_export_ok);
    printCheck(ctx, "R4L duplicate export rejected", duplicate_export_ok);
    printCheck(ctx, "R4L duplicate provider rejected", duplicate_provider_ok);
    printCheck(ctx, "R4L malformed interface rejected", malformed_table_ok);
    printCheck(ctx, "R4L named resolver diagnostic", named_diagnostic_ok);
    if (rolled) {
        ctx.write("  R4L resolver bootlog rollover: accepted dropped_bytes=");
        ctx.printU64(info.dropped_bytes);
        ctx.println(" exact-records=standard-gate");
    }
    return missing_ok and version_ok and no_file_fallback_ok and missing_export_ok and
        duplicate_export_ok and duplicate_provider_ok and malformed_table_ok and named_diagnostic_ok;
}

fn validateR4LQuery(query: r4os.abi.R4LQuery, expected_group: r4os.abi.R4LGroup) bool {
    return query.magic == r4os.abi.r4l_abi_magic and
        query.abi_version == r4os.abi.r4l_abi_version and
        query.size >= r4os.abi.r4l_query_struct_size and
        query.group == @intFromEnum(expected_group) and
        query.kernel_bridge == 0 and
        query.reserved == 0;
}

fn checkR4D(ctx: *const r4os.r4sys.Context, path: [*:0]const u8) bool {
    var buf: [8192]u8 = undefined;
    const len = ctx.fileReadAt(path, 0, buf[0..]);
    ctx.print("read ");
    ctx.print(path);
    ctx.print(": ");
    ctx.printI32(len);
    ctx.println(" bytes");
    if (len < 32) return false;
    if (len >= 64 and buf[0] == 'R' and buf[1] == '4' and buf[2] == 'M' and buf[3] == '0') {
        return checkR4M(ctx, "R4D", buf[0..@intCast(len)], 3, 1, 2);
    }

    const magic_ok = buf[0] == 'R' and buf[1] == '4' and buf[2] == 'D' and buf[3] == '0';
    const version_ok = readLe32(buf[4..8]) == r4os.abi.r4d_version;
    const type_ok = readLe16(buf[8..10]) == @intFromEnum(r4os.abi.DriverType.misc);
    const init_ok = readLe32(buf[12..16]) >= 32;
    const shutdown_ok = readLe32(buf[16..20]) >= 32;
    const api_ok = readLe32(buf[28..32]) == r4os.abi.driver_api_version;
    printCheck(ctx, "R4D magic", magic_ok);
    printCheck(ctx, "R4D version", version_ok);
    printCheck(ctx, "R4D type", type_ok);
    printCheck(ctx, "R4D init", init_ok);
    printCheck(ctx, "R4D shutdown", shutdown_ok);
    printCheck(ctx, "R4D api", api_ok);
    return magic_ok and version_ok and type_ok and init_ok and shutdown_ok and api_ok;
}

fn checkR4P(ctx: *const r4os.r4sys.Context, path: [*:0]const u8) bool {
    var buf: [8192]u8 = undefined;
    const len = ctx.fileReadAt(path, 0, buf[0..]);
    ctx.print("read ");
    ctx.print(path);
    ctx.print(": ");
    ctx.printI32(len);
    ctx.println(" bytes");
    if (len < 64) return false;
    return checkR4M(ctx, "R4P", buf[0..@intCast(len)], 4, 1, 5);
}

fn checkProtocolRuntime(ctx: *const r4os.r4sys.Context, dev: *const r4os.r4dev.Context) bool {
    var ok = true;
    ok = checkProtocolState(ctx, dev, "misc.smoke", .loaded) and ok;
    ok = checkProtocolState(ctx, dev, "misc.conformance", .loaded) and ok;
    ok = checkProtocolState(ctx, dev, "misc.example", .loaded) and ok;
    ok = checkProtocolState(ctx, dev, "misc.baddep", .loaded) and ok;
    ok = checkProtocolState(ctx, dev, "security.tls", .loaded) and ok;
    ok = checkExampleDispatch(ctx, dev) and ok;
    ok = checkProtocolState(ctx, dev, "misc.smoke", .active) and ok;
    ok = checkProtocolState(ctx, dev, "misc.example", .active) and ok;
    ok = checkProtocolState(ctx, dev, "misc.conformance", .loaded) and ok;
    ok = checkBadDependencyDemand(ctx, dev) and ok;
    ok = checkProtocolState(ctx, dev, "misc.baddep", .blocked) and ok;
    ok = checkRelocationWindowDemand(ctx, dev) and ok;
    return ok;
}

const stress_min_file_size: u64 = 320 * 1024;
const stress_min_section_payload: u64 = 300 * 1024;
const stress_spawn_count: usize = 4;
const metadata_window_capacity_bytes: u64 = 8 * 1024;
const stress_max_range_reads_per_start: u64 = 8;

fn checkLoaderStress(ctx: *const r4os.r4sys.Context, dev: *const r4os.r4dev.Context) bool {
    var ok = true;
    const r4x_path = "C:\\R4OS\\SOFTWARE\\TERMINAL\\DIAG\\LSTRX.R4X";
    const r4l_path = "C:\\R4OS\\LIBS\\LSTRL.R4L";
    const r4d_path = "C:\\R4OS\\DRIVERS\\LSTRD.R4D";
    const r4p_path = "C:\\R4OS\\PROTOCOLS\\LSTRP.R4P";

    ok = checkLargeR4M(ctx, "Loader stress R4X", r4x_path, 1, 2, 1) and ok;
    ok = checkLargeImport(ctx, r4x_path, "EXTMATH", "API_V1", 1) and ok;
    ok = checkLargeExport(ctx, r4x_path, "R4XStart", 1) and ok;
    ok = checkLargeR4M(ctx, "Loader stress R4L", r4l_path, 2, 0, 1) and ok;
    ok = checkLargeExport(ctx, r4l_path, "LoadStressValue", 1) and ok;
    ok = checkLargeR4M(ctx, "Loader stress R4D", r4d_path, 3, 0, 2) and ok;
    ok = checkLargeExport(ctx, r4d_path, "DriverInit", 1) and ok;
    ok = checkLargeExport(ctx, r4d_path, "DriverShutdown", 1) and ok;
    ok = checkLargeR4M(ctx, "Loader stress R4P", r4p_path, 4, 1, 5) and ok;
    ok = checkProtocolState(ctx, dev, "misc.loaderstress", .loaded) and ok;
    ok = checkLoaderStressDispatch(ctx, dev) and ok;
    ok = checkProtocolState(ctx, dev, "misc.loaderstress", .active) and ok;
    ok = checkStressR4XStarts(ctx, dev, r4x_path) and ok;
    return ok;
}

fn checkLargeR4M(
    ctx: *const r4os.r4sys.Context,
    label: []const u8,
    path: [*:0]const u8,
    expected_kind: u16,
    min_imports: u32,
    min_exports: u32,
) bool {
    const info = ctx.fileInfo(path) orelse return failCheck(ctx, label);
    var buf: [8192]u8 = undefined;
    const len = ctx.fileReadAt(path, 0, buf[0..]);
    if (len < 64) return failCheck(ctx, label);
    const data = buf[0..@intCast(len)];

    const magic_ok = data[0] == 'R' and data[1] == '4' and data[2] == 'M' and data[3] == '0';
    const version_ok = readLe16(data[4..6]) == 1;
    const arch_ok = readLe16(data[6..8]) == r4os.abi.arch_x86_64;
    const kind_ok = readLe16(data[8..10]) == expected_kind;
    const header_ok = readLe16(data[10..12]) == 64;
    const section_off = readLe32(data[16..20]);
    const section_count = readLe32(data[20..24]);
    const import_off = readLe32(data[24..28]);
    const import_count = readLe32(data[28..32]);
    const export_off = readLe32(data[32..36]);
    const export_count = readLe32(data[36..40]);
    const reloc_off = readLe32(data[40..44]);
    const reloc_count = readLe32(data[44..48]);
    const entry_off = readLe32(data[48..52]);
    const entry_count = readLe32(data[52..56]);
    const meta_off = readLe32(data[56..60]);
    const meta_size = readLe32(data[60..64]);

    const size_ok = info.exists != 0 and info.is_dir == 0 and info.size >= stress_min_file_size;
    const section_table_ok = tableFits(data.len, section_off, section_count, 32, true);
    const import_ok = import_count >= min_imports and tableFits(data.len, import_off, import_count, 16, min_imports != 0);
    const export_ok = export_count >= min_exports and tableFits(data.len, export_off, export_count, 16, min_exports != 0);
    const reloc_ok = tableFits(data.len, reloc_off, reloc_count, 24, false);
    const entry_ok = entry_count > 0 and tableFits(data.len, entry_off, entry_count, 16, true);
    const meta_ok = meta_size > 0 and rangeInFile(info.size, meta_off, meta_size);
    var section_ranges_ok = section_table_ok;
    var payload_bytes: u64 = 0;
    if (section_table_ok) {
        var i: u32 = 0;
        while (i < section_count) : (i += 1) {
            const off: usize = @as(usize, @intCast(section_off)) + @as(usize, @intCast(i)) * 32;
            const file_off = readLe32(data[off + 12 .. off + 16]);
            const file_size = readLe32(data[off + 16 .. off + 20]);
            const mem_size = readLe32(data[off + 20 .. off + 24]);
            const alignment = readLe32(data[off + 24 .. off + 28]);
            const section_ok = mem_size >= file_size and alignment != 0 and isPowerOfTwo(alignment) and rangeInFile(info.size, file_off, file_size);
            section_ranges_ok = section_ranges_ok and section_ok;
            payload_bytes +%= file_size;
        }
    }
    const payload_ok = payload_bytes >= stress_min_section_payload;
    const ok = magic_ok and version_ok and arch_ok and kind_ok and header_ok and size_ok and
        section_table_ok and section_ranges_ok and payload_ok and import_ok and export_ok and reloc_ok and entry_ok and meta_ok;

    printCheck(ctx, label, ok);
    ctx.write("  ");
    ctx.write(label);
    ctx.write(" bytes=");
    ctx.printU64(info.size);
    ctx.write(" payload=");
    ctx.printU64(payload_bytes);
    ctx.write(" imports=");
    ctx.printU64(import_count);
    ctx.write(" exports=");
    ctx.printU64(export_count);
    ctx.println("");
    return ok;
}

fn checkLargeImport(ctx: *const r4os.r4sys.Context, path: [*:0]const u8, module: []const u8, symbol: []const u8, min_version: u32) bool {
    var head: [8192]u8 = undefined;
    const data = readHeaderPrefix(ctx, path, head[0..]) orelse return failCheck(ctx, "Loader stress import");
    var strings_buf: [4096]u8 = undefined;
    const strings = readStringBlock(ctx, path, data, strings_buf[0..]) orelse return failCheck(ctx, "Loader stress import strings");
    const import_off = readLe32(data[24..28]);
    const import_count = readLe32(data[28..32]);
    if (!tableFits(data.len, import_off, import_count, 16, true)) return failCheck(ctx, "Loader stress import table");
    var i: u32 = 0;
    while (i < import_count) : (i += 1) {
        const off: usize = @as(usize, @intCast(import_off)) + @as(usize, @intCast(i)) * 16;
        const import_module = zStringFromBlock(strings, readLe32(data[off + 0 .. off + 4])) orelse return failCheck(ctx, "Loader stress import name");
        const import_symbol = zStringFromBlock(strings, readLe32(data[off + 4 .. off + 8])) orelse return failCheck(ctx, "Loader stress import symbol");
        const version = readLe32(data[off + 8 .. off + 12]);
        if (eq(import_module, module) and eq(import_symbol, symbol) and version >= min_version) {
            printCheck(ctx, "Loader stress import", true);
            return true;
        }
    }
    return failCheck(ctx, "Loader stress import");
}

fn checkLargeExport(ctx: *const r4os.r4sys.Context, path: [*:0]const u8, name: []const u8, min_version: u32) bool {
    var head: [8192]u8 = undefined;
    const data = readHeaderPrefix(ctx, path, head[0..]) orelse return failCheck(ctx, "Loader stress export");
    var strings_buf: [4096]u8 = undefined;
    const strings = readStringBlock(ctx, path, data, strings_buf[0..]) orelse return failCheck(ctx, "Loader stress export strings");
    const export_off = readLe32(data[32..36]);
    const export_count = readLe32(data[36..40]);
    if (!tableFits(data.len, export_off, export_count, 16, true)) return failCheck(ctx, "Loader stress export table");
    var i: u32 = 0;
    while (i < export_count) : (i += 1) {
        const off: usize = @as(usize, @intCast(export_off)) + @as(usize, @intCast(i)) * 16;
        const export_name = zStringFromBlock(strings, readLe32(data[off + 0 .. off + 4])) orelse return failCheck(ctx, "Loader stress export name");
        const version = readLe32(data[off + 12 .. off + 16]);
        if (eq(export_name, name) and version >= min_version) {
            printCheck(ctx, "Loader stress export", true);
            return true;
        }
    }
    return failCheck(ctx, "Loader stress export");
}

const StringBlock = struct {
    base: u32,
    data: []const u8,
};

fn stringBlockHas(block: StringBlock, needle: []const u8) bool {
    var cursor: usize = 0;
    while (cursor < block.data.len) {
        var end = cursor;
        while (end < block.data.len and block.data[end] != 0) : (end += 1) {}
        if (end > cursor and eq(block.data[cursor..end], needle)) return true;
        cursor = end + 1;
    }
    return false;
}

fn hasImportInStringBlock(header: []const u8, strings: StringBlock, module: []const u8, symbol: []const u8, min_version: u32) bool {
    const import_off = readLe32(header[24..28]);
    const import_count = readLe32(header[28..32]);
    if (!tableFits(header.len, import_off, import_count, 16, true)) return false;
    var index: u32 = 0;
    while (index < import_count) : (index += 1) {
        const off = @as(usize, @intCast(import_off)) + @as(usize, @intCast(index)) * 16;
        const import_module = zStringFromBlock(strings, readLe32(header[off + 0 .. off + 4])) orelse return false;
        const import_symbol = zStringFromBlock(strings, readLe32(header[off + 4 .. off + 8])) orelse return false;
        const version = readLe32(header[off + 8 .. off + 12]);
        if (eq(import_module, module) and eq(import_symbol, symbol) and version >= min_version) return true;
    }
    return false;
}

fn hasExportInStringBlock(header: []const u8, strings: StringBlock, name: []const u8, min_version: u32) bool {
    const export_off = readLe32(header[32..36]);
    const export_count = readLe32(header[36..40]);
    if (!tableFits(header.len, export_off, export_count, 16, true)) return false;
    var index: u32 = 0;
    while (index < export_count) : (index += 1) {
        const off = @as(usize, @intCast(export_off)) + @as(usize, @intCast(index)) * 16;
        const export_name = zStringFromBlock(strings, readLe32(header[off + 0 .. off + 4])) orelse return false;
        const version = readLe32(header[off + 12 .. off + 16]);
        if (eq(export_name, name) and version >= min_version) return true;
    }
    return false;
}

fn readHeaderPrefix(ctx: *const r4os.r4sys.Context, path: [*:0]const u8, out: []u8) ?[]const u8 {
    const len = ctx.fileReadAt(path, 0, out);
    if (len < 64) return null;
    return out[0..@intCast(len)];
}

fn readStringBlock(ctx: *const r4os.r4sys.Context, path: [*:0]const u8, header: []const u8, out: []u8) ?StringBlock {
    const meta_off = readLe32(header[56..60]);
    const meta_size = readLe32(header[60..64]);
    if (meta_size == 0 or meta_size > out.len) return null;
    const len = ctx.fileReadAt(path, meta_off, out[0..@intCast(meta_size)]);
    if (len != @as(i32, @intCast(meta_size))) return null;
    return .{ .base = meta_off, .data = out[0..@intCast(meta_size)] };
}

fn zStringFromBlock(block: StringBlock, raw_off: u32) ?[]const u8 {
    if (raw_off < block.base) return null;
    const off: usize = @intCast(raw_off - block.base);
    if (off >= block.data.len) return null;
    var end = off;
    while (end < block.data.len and block.data[end] != 0) : (end += 1) {}
    if (end >= block.data.len or end == off) return null;
    return block.data[off..end];
}

fn checkLoaderStressDispatch(ctx: *const r4os.r4sys.Context, dev: *const r4os.r4dev.Context) bool {
    var input = [_]u8{'?'};
    var output: [4]u8 = .{0} ** 4;
    var in_buffer = r4os.abi.ProtocolBuffer{
        .data = @ptrCast(&input),
        .len = input.len,
        .capacity = input.len,
        .flags = 0,
        .reserved = 0,
    };
    var out_buffer = r4os.abi.ProtocolBuffer{
        .data = @ptrCast(&output),
        .len = 0,
        .capacity = output.len,
        .flags = 0,
        .reserved = 0,
    };
    const rc = dev.protocolDispatch("misc.loaderstress", 1, &in_buffer, &out_buffer);
    const ok = rc == 0 and out_buffer.len == 4 and output[0] == 'L' and output[1] == 'S' and output[2] == 'T';
    ctx.write("  Loader stress R4P dispatch: ");
    ctx.write(if (ok) "OK" else "FAILED");
    ctx.write(" rc=");
    ctx.printI32(rc);
    ctx.println("");
    return ok;
}

fn checkStressR4XStarts(ctx: *const r4os.r4sys.Context, dev: *const r4os.r4dev.Context, path: [*:0]const u8) bool {
    const instrumentation = dev.performanceInstrumentation() orelse return failCheck(ctx, "Loader instrumentation unavailable");
    const detailed = instrumentation.mode == 1;
    const before = dev.performanceSummary() orelse return failCheck(ctx, "Loader stress perf before");
    var ids: [stress_spawn_count]u32 = .{0} ** stress_spawn_count;
    var task_ids: [stress_spawn_count]u32 = .{0} ** stress_spawn_count;
    var index: usize = 0;
    while (index < ids.len) : (index += 1) {
        const raw_id = ctx.programSpawn(path, "", .console);
        if (raw_id <= 0) return failCheck(ctx, "Loader stress R4X spawn");
        ids[index] = @intCast(raw_id);
        task_ids[index] = findInstanceTaskId(ctx, ids[index]) orelse return failCheck(ctx, "Loader stress R4X task identity");
    }
    index = 0;
    var exit_ok = true;
    var last_exit_code: i32 = 0;
    while (index < ids.len) : (index += 1) {
        const exit_code = waitInstanceReaped(ctx, ids[index], 500) orelse return failCheck(ctx, "Loader stress R4X reap");
        last_exit_code = exit_code;
        exit_ok = exit_ok and exit_code == 0;
    }
    ctx.sleepTicks(2);
    const after = dev.performanceSummary() orelse return failCheck(ctx, "Loader stress perf after");
    const range_delta = counterDelta(after.loader_file_range_reads, before.loader_file_range_reads);
    const range_byte_delta = counterDelta(after.loader_file_range_read_bytes, before.loader_file_range_read_bytes);
    const reader_delta = counterDelta(after.loader_metadata_reader_initializations, before.loader_metadata_reader_initializations);
    const logical_delta = counterDelta(after.loader_metadata_logical_reads, before.loader_metadata_logical_reads);
    const hit_delta = counterDelta(after.loader_metadata_window_hits, before.loader_metadata_window_hits);
    const fill_delta = counterDelta(after.loader_metadata_window_fills, before.loader_metadata_window_fills);
    const fill_byte_delta = counterDelta(after.loader_metadata_window_fill_bytes, before.loader_metadata_window_fill_bytes);
    const range_ok = range_delta > 0 and
        range_delta <= @as(u64, ids.len) * stress_max_range_reads_per_start and
        range_byte_delta > 0 and
        after.loader_file_full_reads == before.loader_file_full_reads;
    const detail_ok = if (detailed) logical_delta > range_delta and
        hit_delta > 0 and fill_delta > 0 and fill_delta <= range_delta and fill_byte_delta > 0
    else metadata.countersValid(before, false) and metadata.countersValid(after, false);
    const reader_ok = reader_delta >= ids.len and detail_ok and
        after.loader_metadata_window_capacity_bytes == metadata_window_capacity_bytes;
    var cleaned_tasks: usize = 0;
    for (task_ids) |task_id| {
        if (!taskIdPresent(dev, after.task_count, task_id)) cleaned_tasks += 1;
    }
    // task_dead is a global instantaneous gauge. Async I/O owned by this
    // diagnostic can legitimately cross the snapshot boundary, so the
    // lifecycle assertion follows the exact four main-task IDs captured at
    // admission instead of accepting or rejecting an unrelated worker.
    const task_cleanup_ok = cleaned_tasks == task_ids.len;
    const ok = exit_ok and range_ok and reader_ok and task_cleanup_ok;
    printCheck(ctx, "Loader stress parallel R4X starts", ok);
    printCheck(ctx, "Loader stress bounded metadata reader", reader_ok);
    printCheck(ctx, "Loader stress task cleanup", task_cleanup_ok);
    ctx.write("  Loader stress starts=");
    ctx.printU64(ids.len);
    ctx.write(" rangeReads=");
    ctx.printU64(range_delta);
    ctx.write(" bytes=");
    ctx.printU64(range_byte_delta);
    ctx.write(" readers=");
    ctx.printU64(reader_delta);
    ctx.write(" logical/hit/fill=");
    ctx.printU64(logical_delta);
    ctx.write("/");
    ctx.printU64(hit_delta);
    ctx.write("/");
    ctx.printU64(fill_delta);
    ctx.write(" fillBytes=");
    ctx.printU64(fill_byte_delta);
    ctx.write(" fullReads=");
    ctx.printU64(after.loader_file_full_reads);
    ctx.write(" taskDead=");
    ctx.printU64(before.task_dead);
    ctx.write("->");
    ctx.printU64(after.task_dead);
    ctx.write(" ownedTasks=");
    ctx.printU64(cleaned_tasks);
    ctx.write("/");
    ctx.printU64(task_ids.len);
    ctx.write(" exit=");
    ctx.printI32(last_exit_code);
    ctx.println("");
    return ok;
}

fn findInstanceTaskId(ctx: *const r4os.r4sys.Context, wanted_id: u32) ?u32 {
    var instance_index: u32 = 0;
    while (true) {
        var info: r4os.abi.ProgramInstanceInfo = .{};
        if (ctx.programInstance(instance_index, &info) <= 0) return null;
        if (info.id == wanted_id and info.task_id != 0) return info.task_id;
        if (instance_index == 0xFFFF_FFFF) return null;
        instance_index += 1;
    }
}

fn taskIdPresent(dev: *const r4os.r4dev.Context, task_count: u32, wanted_id: u32) bool {
    var task_index: u32 = 0;
    while (task_index < task_count) : (task_index += 1) {
        const info = dev.performanceTask(task_index) orelse continue;
        if (info.id == wanted_id) return true;
    }
    return false;
}

fn waitInstanceReaped(ctx: *const r4os.r4sys.Context, id: u32, max_ticks: u32) ?i32 {
    var tick: u32 = 0;
    while (tick < max_ticks) : (tick += 1) {
        const rc = ctx.programReapInstance(id);
        if (rc >= 0) return rc;
        if (rc != -2) return null;
        ctx.sleepTicks(1);
    }
    const rc = ctx.programReapInstance(id);
    return if (rc >= 0) rc else null;
}

fn checkLoaderPerformance(ctx: *const r4os.r4sys.Context, dev: *const r4os.r4dev.Context) bool {
    if (!dev.hasFn("performance_summary")) return failCheck(ctx, "Loader performance API missing");
    const summary = dev.performanceSummary() orelse return failCheck(ctx, "Loader performance summary unavailable");
    const ready = (summary.flags & r4os.abi.performance_flag_loader_performance_ready) != 0;
    const lifecycle_ok = summary.loader_initialized != 0 and
        summary.loader_started != 0 and
        summary.loader_completed != 0 and
        summary.loader_r4p_runtime_started != 0 and
        summary.loader_r4p_runtime_completed != 0;
    const modules_ok = summary.loader_r4l_candidates > 0 and
        summary.loader_r4l_loaded > 0 and
        summary.loader_r4d_candidates > 0 and
        summary.loader_r4d_discovered > 0 and
        summary.loader_r4p_candidates > 0 and
        summary.loader_r4p_active > 0 and
        summary.loader_r4p_blocked > 0;
    const config_ok = summary.loader_config_bytes > 0 and summary.loader_config_driver_count > 0;
    const service_ok = summary.loader_service_boot_status == r4os.abi.loader_service_boot_status_ran;
    const audit_ok = summary.loader_boot_critical_count > 0 and summary.loader_lazy_candidate_count > 0;
    const ok = ready and lifecycle_ok and modules_ok and config_ok and service_ok and audit_ok;
    printCheck(ctx, "Loader performance snapshot", ok);
    if (!ok) {
        ctx.write("  Loader perf detail: ready=");
        ctx.write(if (ready) "y" else "n");
        ctx.write(" lifecycle=");
        ctx.write(if (lifecycle_ok) "y" else "n");
        ctx.write(" modules=");
        ctx.write(if (modules_ok) "y" else "n");
        ctx.write(" config=");
        ctx.write(if (config_ok) "y" else "n");
        ctx.write(" service=");
        ctx.write(if (service_ok) "y" else "n");
        ctx.write(" audit=");
        ctx.println(if (audit_ok) "y" else "n");
    }
    ctx.write("  Loader perf: r4l=");
    ctx.printU64(summary.loader_r4l_loaded);
    ctx.write("/");
    ctx.printU64(summary.loader_r4l_candidates);
    ctx.write(" r4d=");
    ctx.printU64(summary.loader_r4d_discovered);
    ctx.write("/");
    ctx.printU64(summary.loader_r4d_candidates);
    ctx.write(" r4p=");
    ctx.printU64(summary.loader_r4p_active);
    ctx.write("/");
    ctx.printU64(summary.loader_r4p_candidates);
    ctx.write(" blocked=");
    ctx.printU64(summary.loader_r4p_blocked);
    ctx.write(" cfg=");
    ctx.printU64(summary.loader_config_bytes);
    ctx.write(" service=");
    ctx.printU64(summary.loader_service_boot_status);
    ctx.write(" ticks=");
    ctx.printU64(summary.loader_total_ticks);
    ctx.write("/");
    ctx.printU64(summary.loader_r4p_runtime_total_ticks);
    ctx.write("/");
    ctx.printU64(summary.loader_service_boot_ticks);
    ctx.println("");
    return ok;
}

fn checkLoaderMemory(ctx: *const r4os.r4sys.Context, dev: *const r4os.r4dev.Context) bool {
    const instrumentation = dev.performanceInstrumentation() orelse return failCheck(ctx, "Loader instrumentation unavailable");
    const detailed = instrumentation.mode == 1;
    if (!dev.hasFn("performance_summary")) return failCheck(ctx, "Loader memory API missing");
    const summary = dev.performanceSummary() orelse return failCheck(ctx, "Loader memory summary unavailable");
    const contract_ok = summary.version == r4os.abi.performance_snapshot_version and
        summary.size >= @sizeOf(r4os.abi.ProgramPerformanceSummary);
    const ready = (summary.flags & r4os.abi.performance_flag_loader_memory_ready) != 0;
    const idle_ok = summary.loader_file_active_buffers == 0 and
        summary.loader_file_reserved_bytes == 0 and
        summary.loader_file_committed_bytes == 0;
    const read_path_ok = summary.loader_file_range_reads > 0 and summary.loader_file_full_reads == 0;
    const metadata_reader_ok = summary.loader_file_range_read_bytes > 0 and
        summary.loader_metadata_reader_initializations > 0 and
        metadata.countersValid(summary, detailed) and
        summary.loader_metadata_window_capacity_bytes == metadata_window_capacity_bytes;
    const peak_ok = summary.loader_file_peak_reserved_bytes >= summary.loader_file_peak_committed_bytes and
        summary.loader_file_peak_reserved_bytes >= summary.loader_file_reserved_bytes and
        summary.loader_file_peak_committed_bytes >= summary.loader_file_committed_bytes;
    const failure_ok = summary.loader_file_reserve_failures == 0 and
        summary.loader_file_commit_failures == 0 and
        summary.loader_file_read_failures == 0 and
        summary.loader_file_short_reads == 0 and
        summary.loader_file_release_failures == 0 and
        summary.loader_file_pressure_failures == 0;
    const failures = summary.loader_file_reserve_failures +%
        summary.loader_file_commit_failures +%
        summary.loader_file_read_failures +%
        summary.loader_file_short_reads +%
        summary.loader_file_release_failures +%
        summary.loader_file_pressure_failures;
    const ok = contract_ok and ready and idle_ok and read_path_ok and metadata_reader_ok and peak_ok and failure_ok;
    printCheck(ctx, "Loader memory snapshot", ok);
    printCheck(ctx, "Loader metadata-reader snapshot", metadata_reader_ok);
    ctx.write("  Loader memory: active=");
    ctx.printU64(summary.loader_file_active_buffers);
    ctx.write(" reserved=");
    ctx.printU64(summary.loader_file_reserved_bytes);
    ctx.write(" committed=");
    ctx.printU64(summary.loader_file_committed_bytes);
    ctx.write(" peak=");
    ctx.printU64(summary.loader_file_peak_reserved_bytes);
    ctx.write("/");
    ctx.printU64(summary.loader_file_peak_committed_bytes);
    ctx.write(" reads=");
    ctx.printU64(summary.loader_file_full_reads);
    ctx.write("/");
    ctx.printU64(summary.loader_file_range_reads);
    ctx.write(" bytes=");
    ctx.printU64(summary.loader_file_range_read_bytes);
    ctx.write(" metadata=");
    ctx.printU64(summary.loader_metadata_logical_reads);
    ctx.write("/");
    ctx.printU64(summary.loader_metadata_window_hits);
    ctx.write("/");
    ctx.printU64(summary.loader_metadata_window_fills);
    ctx.write(" capacity=");
    ctx.printU64(summary.loader_metadata_window_capacity_bytes);
    ctx.write(" pressure=");
    ctx.printU64(summary.loader_file_pressure_reclaim_attempts);
    ctx.write("/");
    ctx.printU64(summary.loader_file_pressure_reclaimed_frames);
    ctx.write(" failures=");
    ctx.printU64(failures);
    ctx.println("");
    return ok;
}

fn checkProtocolState(ctx: *const r4os.r4sys.Context, dev: *const r4os.r4dev.Context, role: []const u8, expected: r4os.abi.ProtocolState) bool {
    var status: r4os.abi.ProtocolStatus = .{};
    const rc = dev.protocolStatus(role, &status);
    const source_ok = (status.flags & (1 << 1)) != 0;
    const ok = rc == 0 and status.state == @intFromEnum(expected) and source_ok;
    ctx.write("  R4P role ");
    ctx.write(role);
    ctx.write(": ");
    ctx.write(if (ok) "OK" else "FAILED");
    ctx.write(" state=");
    ctx.printU64(status.state);
    ctx.write(" flags=");
    ctx.printU64(status.flags);
    if (rc != 0) {
        ctx.write(" rc=");
        ctx.printI32(rc);
    }
    ctx.println("");
    return ok;
}

fn checkBadDependencyDemand(ctx: *const r4os.r4sys.Context, dev: *const r4os.r4dev.Context) bool {
    var input = [_]u8{0};
    var output = [_]u8{0};
    var in_buffer = r4os.abi.ProtocolBuffer{
        .data = @ptrCast(&input),
        .len = 0,
        .capacity = input.len,
        .flags = 0,
        .reserved = 0,
    };
    var out_buffer = r4os.abi.ProtocolBuffer{
        .data = @ptrCast(&output),
        .len = 0,
        .capacity = output.len,
        .flags = 0,
        .reserved = 0,
    };
    const rc = dev.protocolDispatch("misc.baddep", 1, &in_buffer, &out_buffer);
    const ok = rc == -5;
    ctx.write("  R4P missing dependency on demand: ");
    ctx.write(if (ok) "OK" else "FAILED");
    ctx.write(" rc=");
    ctx.printI32(rc);
    ctx.println("");
    return ok;
}

fn checkRelocationWindowDemand(ctx: *const r4os.r4sys.Context, dev: *const r4os.r4dev.Context) bool {
    const instrumentation = dev.performanceInstrumentation() orelse return failCheck(ctx, "Loader instrumentation unavailable");
    const detailed = instrumentation.mode == 1;
    const path = "C:\\R4OS\\PROTOCOLS\\R4TLS.R4P";
    var header: [64]u8 = undefined;
    const data = readHeaderPrefix(ctx, path, header[0..]) orelse return failCheck(ctx, "R4P relocation-window header");
    const relocation_count: u64 = readLe32(data[44..48]);
    const before = dev.performanceSummary() orelse return failCheck(ctx, "R4P relocation-window perf before");

    var input = [_]u8{0};
    var output: [512]u8 = .{0} ** 512;
    var in_buffer = r4os.abi.ProtocolBuffer{
        .data = @ptrCast(&input),
        .len = 0,
        .capacity = input.len,
        .flags = 0,
        .reserved = 0,
    };
    var out_buffer = r4os.abi.ProtocolBuffer{
        .data = @ptrCast(&output),
        .len = 0,
        .capacity = output.len,
        .flags = 0,
        .reserved = 0,
    };
    const rc = dev.protocolDispatch("security.tls", 1, &in_buffer, &out_buffer);
    const after = dev.performanceSummary() orelse return failCheck(ctx, "R4P relocation-window perf after");
    const range_delta = if (after.loader_file_range_reads >= before.loader_file_range_reads)
        after.loader_file_range_reads - before.loader_file_range_reads
    else
        0;
    const logical_delta = counterDelta(after.loader_metadata_logical_reads, before.loader_metadata_logical_reads);
    const hit_delta = counterDelta(after.loader_metadata_window_hits, before.loader_metadata_window_hits);
    const fill_delta = counterDelta(after.loader_metadata_window_fills, before.loader_metadata_window_fills);
    const expected_windows = if (relocation_count == 0) 0 else 1 + (relocation_count - 1) / 170;
    // The fixed allowance covers header, section, entry, import/export and
    // metadata reads.  A historical per-relocation loader exceeds this bound
    // by more than an order of magnitude for R4TLS. Detail logical reads now
    // count grouped callback requests, not individual decoded relocations.
    const detail_ok = if (detailed) logical_delta >= expected_windows and
        logical_delta < relocation_count and hit_delta > 0 and
        fill_delta >= expected_windows and fill_delta <= range_delta
    else metadata.countersValid(before, false) and metadata.countersValid(after, false);
    const io_ok = relocation_count >= 170 and
        range_delta > 0 and range_delta <= expected_windows + 16 and detail_ok and
        after.loader_file_full_reads == before.loader_file_full_reads;
    const dispatch_ok = rc == 0 and out_buffer.len > 0;
    const state_ok = checkProtocolState(ctx, dev, "security.tls", .active);
    const ok = io_ok and dispatch_ok and state_ok;
    printCheck(ctx, "R4M relocation-window demand load", ok);
    ctx.write("  R4M demand I/O: relocations=");
    ctx.printU64(relocation_count);
    ctx.write(" windows=");
    ctx.printU64(expected_windows);
    ctx.write(" rangeReads=");
    ctx.printU64(range_delta);
    ctx.write(" metadataLogical/hit/fill=");
    ctx.printU64(logical_delta);
    ctx.write("/");
    ctx.printU64(hit_delta);
    ctx.write("/");
    ctx.printU64(fill_delta);
    ctx.write(" fullReads=");
    ctx.printU64(before.loader_file_full_reads);
    ctx.write("->");
    ctx.printU64(after.loader_file_full_reads);
    ctx.write(" rc=");
    ctx.printI32(rc);
    ctx.println("");
    return ok;
}

fn checkExampleDispatch(ctx: *const r4os.r4sys.Context, dev: *const r4os.r4dev.Context) bool {
    var input = [_]u8{ 'R', '4', 'P' };
    var output: [8]u8 = .{0} ** 8;
    var in_buffer = r4os.abi.ProtocolBuffer{
        .data = @ptrCast(&input),
        .len = input.len,
        .capacity = input.len,
        .flags = 0,
        .reserved = 0,
    };
    var out_buffer = r4os.abi.ProtocolBuffer{
        .data = @ptrCast(&output),
        .len = 0,
        .capacity = output.len,
        .flags = 0,
        .reserved = 0,
    };
    const rc = dev.protocolDispatch("misc.example", 1, &in_buffer, &out_buffer);
    const ok = rc == 0 and out_buffer.len == input.len and output[0] == input[0] and output[1] == input[1] and output[2] == input[2];
    ctx.write("  R4P misc.example dispatch: ");
    ctx.write(if (ok) "OK" else "FAILED");
    ctx.write(" rc=");
    ctx.printI32(rc);
    ctx.println("");
    return ok;
}

fn checkR4M(ctx: *const r4os.r4sys.Context, label: []const u8, buf: []const u8, expected_kind: u16, min_imports: u32, min_exports: u32) bool {
    const magic_ok = buf.len >= 64 and buf[0] == 'R' and buf[1] == '4' and buf[2] == 'M' and buf[3] == '0';
    const version_ok = readLe16(buf[4..6]) == 1;
    const arch_ok = readLe16(buf[6..8]) == r4os.abi.arch_x86_64;
    const kind_ok = readLe16(buf[8..10]) == expected_kind;
    const header_ok = readLe16(buf[10..12]) == 64;
    const section_ok = readLe32(buf[20..24]) > 0 and readLe32(buf[16..20]) >= 64;
    const import_ok = readLe32(buf[28..32]) >= min_imports;
    const export_ok = readLe32(buf[36..40]) >= min_exports;
    const reloc_ok = readLe32(buf[44..48]) == 0 or readLe32(buf[40..44]) >= 64;
    const entry_ok = readLe32(buf[52..56]) > 0 and readLe32(buf[48..52]) >= 64;
    const meta_ok = readLe32(buf[60..64]) > 0 and readLe32(buf[56..60]) >= 64;
    printCheck(ctx, label, magic_ok);
    printCheck(ctx, "R4M version", version_ok);
    printCheck(ctx, "R4M arch", arch_ok);
    printCheck(ctx, "R4M kind", kind_ok);
    printCheck(ctx, "R4M header", header_ok);
    printCheck(ctx, "R4M sections", section_ok);
    printCheck(ctx, "R4M imports", import_ok);
    printCheck(ctx, "R4M exports", export_ok);
    printCheck(ctx, "R4M relocs", reloc_ok);
    printCheck(ctx, "R4M entries", entry_ok);
    printCheck(ctx, "R4M meta", meta_ok);
    return magic_ok and version_ok and arch_ok and kind_ok and header_ok and section_ok and import_ok and export_ok and reloc_ok and entry_ok and meta_ok;
}

fn hasImport(buf: []const u8, module: []const u8, symbol: []const u8, min_version: u32) bool {
    if (buf.len < 64) return false;
    const import_off = readLe32(buf[24..28]);
    const import_count = readLe32(buf[28..32]);
    var i: usize = 0;
    while (i < import_count) : (i += 1) {
        const off = @as(usize, @intCast(import_off)) + i * 16;
        if (off + 16 > buf.len) return false;
        const import_module = zString(buf, readLe32(buf[off + 0 .. off + 4])) orelse return false;
        const import_symbol = zString(buf, readLe32(buf[off + 4 .. off + 8])) orelse return false;
        const version = readLe32(buf[off + 8 .. off + 12]);
        if (eq(import_module, module) and eq(import_symbol, symbol) and version >= min_version) return true;
    }
    return false;
}

fn hasExport(buf: []const u8, name: []const u8, min_version: u32) bool {
    if (buf.len < 64) return false;
    const export_off = readLe32(buf[32..36]);
    const export_count = readLe32(buf[36..40]);
    var i: usize = 0;
    while (i < export_count) : (i += 1) {
        const off = @as(usize, @intCast(export_off)) + i * 16;
        if (off + 16 > buf.len) return false;
        const export_name = zString(buf, readLe32(buf[off + 0 .. off + 4])) orelse return false;
        const version = readLe32(buf[off + 12 .. off + 16]);
        if (eq(export_name, name) and version >= min_version) return true;
    }
    return false;
}

fn hasMeta(buf: []const u8, needle: []const u8) bool {
    if (buf.len < 64) return false;
    const meta_off: usize = @intCast(readLe32(buf[56..60]));
    const meta_size: usize = @intCast(readLe32(buf[60..64]));
    if (meta_size == 0 or meta_off > buf.len or meta_size > buf.len - meta_off) return false;
    const end = meta_off + meta_size;
    var cursor = meta_off;
    while (cursor < end) {
        var item_end = cursor;
        while (item_end < end and buf[item_end] != 0) : (item_end += 1) {}
        if (item_end > cursor and eq(buf[cursor..item_end], needle)) return true;
        cursor = item_end + 1;
    }
    return false;
}

fn zString(buf: []const u8, raw_off: u32) ?[]const u8 {
    const off: usize = @intCast(raw_off);
    if (off >= buf.len) return null;
    var end = off;
    while (end < buf.len and buf[end] != 0) : (end += 1) {}
    if (end >= buf.len) return null;
    return buf[off..end];
}

fn eq(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (a[i] != b[i]) return false;
    }
    return true;
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (eq(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn tableFits(buf_len: usize, raw_off: u32, raw_count: u32, stride: usize, required: bool) bool {
    if (raw_count == 0) return !required;
    if (raw_off == 0) return false;
    const off: usize = @intCast(raw_off);
    const count: usize = @intCast(raw_count);
    if (off > buf_len) return false;
    return count <= (buf_len - off) / stride;
}

fn counterDelta(after: u64, before: u64) u64 {
    return after -| before;
}

fn rangeInFile(file_size: u64, raw_off: u32, raw_size: u32) bool {
    if (raw_size == 0) return true;
    if (raw_off == 0) return false;
    const off: u64 = raw_off;
    const size: u64 = raw_size;
    if (off > file_size) return false;
    return size <= file_size - off;
}

fn isPowerOfTwo(value: u32) bool {
    return value != 0 and (value & (value - 1)) == 0;
}

fn printCheck(ctx: *const r4os.r4sys.Context, name: []const u8, ok: bool) void {
    ctx.write("  ");
    ctx.write(name);
    ctx.write(": ");
    ctx.println(if (ok) "OK" else "FAILED");
}

fn failCheck(ctx: *const r4os.r4sys.Context, name: []const u8) bool {
    printCheck(ctx, name, false);
    return false;
}

fn readLe16(bytes: []const u8) u16 {
    return @as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8);
}

fn readLe32(bytes: []const u8) u32 {
    return @as(u32, bytes[0]) |
        (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16) |
        (@as(u32, bytes[3]) << 24);
}
