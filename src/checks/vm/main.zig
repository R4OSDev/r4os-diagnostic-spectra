const r4os = @import("r4os");

const DiagApi = struct {
    sys: r4os.r4sys.Context,
    dev: r4os.r4dev.Context,
    resources: r4os.Resources,

    fn init(app: *r4os.App) ?DiagApi {
        return .{
            .sys = app.system(),
            .dev = app.devicesLowLevel() orelse return null,
            .resources = app.resources(),
        };
    }
};

pub fn r4_app_main(app: *r4os.App) i32 {
    var ctx = DiagApi.init(app) orelse return r4os.abi.err_no_group;
    if (argsEqual(app.args(), "/HOLDVM")) return holdVmMode(&ctx);
    if (app.args().len != 0) return 2;
    if (!testR4sysVmApi(&ctx) or !stressVmLifecycle(&ctx)) return 1;
    ctx.sys.println("SPECTRA VM result: OK");
    return 0;
}

fn holdVmMode(ctx: *DiagApi) i32 {
    var region = switch (ctx.resources.reserveVm(128 * 1024 * 1024, 4096, r4os.abi.vm_region_flags_default)) {
        .region => |value| value,
        .failure => return fail(ctx, "SPECTRA VM hold-vm reserve failed"),
    };
    var release_needed = true;
    defer {
        if (release_needed) _ = region.release();
    }

    if (region.commit(0, 64 * 1024 * 1024) != r4os.abi.vm_ok) return fail(ctx, "SPECTRA VM hold-vm commit failed");
    const committed = switch (region.info()) {
        .value => |info| info,
        .failure => return fail(ctx, "SPECTRA VM hold-vm query failed"),
    };
    const ptr: [*]u8 = @ptrFromInt(committed.base);
    const touched_pages = touchVmPages(ptr, 16 * 1024 * 1024, 0x4C);
    const touched = switch (region.info()) {
        .value => |info| info,
        .failure => return fail(ctx, "SPECTRA VM hold-vm touched query failed"),
    };
    if (touched.resident_bytes < touched_pages * 4096 or touched.fault_count < touched_pages or touched.failed_faults != 0) {
        return fail(ctx, "SPECTRA VM hold-vm stats failed");
    }
    ctx.sys.write("SPECTRA VM hold-vm: ready resident=");
    ctx.sys.printU64(touched.resident_bytes);
    ctx.sys.println("");
    while (!ctx.sys.programShouldClose()) {
        ctx.sys.sleepTicks(1);
    }
    if (region.release() != r4os.abi.vm_ok) return fail(ctx, "SPECTRA VM hold-vm release failed");
    release_needed = false;
    ctx.sys.println("SPECTRA VM hold-vm: done");
    return 0;
}

fn testR4sysVmApi(ctx: *DiagApi) bool {
    var region = switch (ctx.resources.reserveVm(32 * 1024 * 1024, 4096, r4os.abi.vm_region_flags_default)) {
        .region => |value| value,
        .failure => return failBool(ctx, "SPECTRA VM VM reserve failed"),
    };
    var release_needed = true;
    defer {
        if (release_needed) _ = region.release();
    }

    if (region.last_info.kind != r4os.abi.memory_kind_virtual_range or region.last_info.window != r4os.abi.memory_window_r4x_vm) {
        return failBool(ctx, "SPECTRA VM VM reserve kind failed");
    }
    var borrowed = region;
    borrowed.owned = false;
    if (borrowed.release() != r4os.abi.err_not_owned) return failBool(ctx, "SPECTRA VM borrowed release accepted");
    if (region.commit(0, 8 * 1024 * 1024) != r4os.abi.vm_ok) return failBool(ctx, "SPECTRA VM VM commit failed");
    const committed = switch (region.info()) {
        .value => |info| info,
        .failure => return failBool(ctx, "SPECTRA VM VM query failed"),
    };
    if (committed.committed_bytes < 8 * 1024 * 1024) return failBool(ctx, "SPECTRA VM VM committed bytes failed");
    const ptr: [*]u8 = @ptrFromInt(committed.base);
    if (!touchSparse(ptr, 8 * 1024 * 1024, 0x51)) return failBool(ctx, "SPECTRA VM VM touch failed");
    const touched = switch (region.info()) {
        .value => |info| info,
        .failure => return failBool(ctx, "SPECTRA VM VM touched query failed"),
    };
    if (touched.resident_bytes < 3 * 4096 or touched.fault_count < 3 or touched.failed_faults != 0) {
        return failBool(ctx, "SPECTRA VM VM region stats failed");
    }
    if (region.decommit(0, 8 * 1024 * 1024) != r4os.abi.vm_ok) return failBool(ctx, "SPECTRA VM VM decommit failed");
    if (region.release() != r4os.abi.vm_ok) return failBool(ctx, "SPECTRA VM VM release failed");
    if (region.release() != r4os.abi.err_closed) return failBool(ctx, "SPECTRA VM double release mismatch");
    release_needed = false;
    return true;
}

fn stressVmLifecycle(ctx: *DiagApi) bool {
    var index: u32 = 0;
    while (index < 80) : (index += 1) {
        var region = switch (ctx.resources.reserveVm(4096, 4096, r4os.abi.vm_region_flags_default)) {
            .region => |value| value,
            .failure => return failBool(ctx, "SPECTRA VM VM stress reserve leaked slots"),
        };
        if (region.commit(0, 4096) != r4os.abi.vm_ok or region.decommit(0, 4096) != r4os.abi.vm_ok or region.release() != r4os.abi.vm_ok) {
            return failBool(ctx, "SPECTRA VM VM stress lifecycle failed");
        }
    }
    return true;
}

fn touchSparse(mem: [*]u8, len: u64, seed: u8) bool {
    if (len < 4096) return false;
    const first: usize = 0;
    const middle: usize = @intCast((len / 2) & ~@as(u64, 4095));
    const last: usize = @intCast(len - 1);
    mem[first] = seed;
    mem[middle] = seed +% 1;
    mem[last] = seed ^ 0xA5;
    return mem[first] == seed and mem[middle] == seed +% 1 and mem[last] == seed ^ 0xA5;
}

fn touchVmPages(mem: [*]u8, len: u64, seed: u8) u64 {
    var offset: u64 = 0;
    var pages: u64 = 0;
    while (offset < len) : (offset += 4096) {
        const index: usize = @intCast(offset);
        mem[index] = seed +% @as(u8, @truncate(offset >> 12));
        pages += 1;
    }
    return pages;
}

fn fail(ctx: *DiagApi, msg: []const u8) i32 {
    ctx.sys.println(msg);
    ctx.sys.println("SPECTRA VM result: FAILED");
    return 1;
}

fn failBool(ctx: *DiagApi, msg: []const u8) bool {
    _ = fail(ctx, msg);
    return false;
}

fn argsEqual(args: []const u8, expected: []const u8) bool {
    if (args.len != expected.len) return false;
    for (args, expected) |actual, wanted| if (upperAscii(actual) != upperAscii(wanted)) return false;
    return true;
}

fn upperAscii(ch: u8) u8 {
    return if (ch >= 'a' and ch <= 'z') ch - 32 else ch;
}

