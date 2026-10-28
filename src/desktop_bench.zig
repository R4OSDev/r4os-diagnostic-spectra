//! Control/presentation only. No emulator, renderer, score or workload copy.
const std = @import("std");
const r = @import("r4os");
const a = r.abi;
const wire = @import("desktop_check");
const Check = @import("desktop_check.zig").Check;
const Output = @import("output.zig").Output;
const Options = @import("desktop_bench_options.zig").Options;
const snes_path = "C:\\R4OS\\SUBSYSTEMS\\r4os.snes\\R4SNES.R4X";

pub fn readFile(app: *r.App, path: [*:0]const u8) ![]u8 {
    const sys = app.system();
    const info = sys.fileInfo(path) orelse return error.OwnerFileMissing;
    if (info.size == 0 or info.size > 2 * 1024 * 1024) return error.OwnerFileSize;
    const allocator = app.allocator() orelse return error.AllocatorMissing;
    const bytes = try allocator.alloc(u8, @intCast(info.size));
    errdefer allocator.free(bytes);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const part = bytes[offset..][0..@min(16384, bytes.len - offset)];
        if (sys.fileReadAt(path, @intCast(offset), part) != @as(i32, @intCast(part.len))) return error.OwnerFileRead;
        offset += part.len;
    }
    return bytes;
}
fn textField(value: std.json.Value, name: []const u8, expected: []const u8) bool {
    if (value != .object) return false;
    const field = value.object.get(name) orelse return false;
    return field == .string and std.mem.eql(u8, field.string, expected);
}
fn emit(app: *r.App, out: *Output, path: [*:0]const u8, kind: []const u8, group: []const u8, lines: bool, count: *usize) !void {
    const allocator = app.allocator() orelse return error.AllocatorMissing;
    const bytes = try readFile(app, path);
    defer allocator.free(bytes);
    var split = std.mem.splitScalar(u8, bytes, '\n');
    count.* = 0;
    var document_consumed = false;
    while (if (lines) split.next() else if (!document_consumed) @as(?[]const u8, bytes) else null) |part| {
        document_consumed = true;
        const raw = std.mem.trim(u8, part, " \r\n\t");
        if (raw.len == 0) continue;
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.OwnerJsonObject;
        var original_count: usize = 1;
        if (lines) {
            if (!textField(parsed.value, "profile", "r4os-window-audsvc-v2") or !textField(parsed.value, "scene", "r4snes.active-scene.v2")) return error.OwnerSnesContract;
            const cleanup = parsed.value.object.get("cleanup_verified") orelse return error.OwnerCleanupMissing;
            if (cleanup != .bool or !cleanup.bool) return error.OwnerCleanupMissing;
        } else {
            const software = std.mem.eql(u8, kind, "software-output");
            if (!textField(parsed.value, "contract", if (software) "desktop-software-output-v1" else "desktop-window-output-v1")) return error.OwnerOutputContract;
            const records = parsed.value.object.get("records") orelse return error.OwnerDataMissing;
            const managed_context = !software and textField(parsed.value, "receipt", "managed-output-context-only");
            if (records != .array or (if (managed_context) records.array.items.len != 0 else records.array.items.len == 0) or
                (software and records.array.items.len != 20)) return error.OwnerDataMissing;
            if (software) original_count = records.array.items.len;
        }
        out.ownerJson(kind, group, count.*, raw);
        if (out.failed) return error.Output;
        count.* += original_count;
    }
    if (count.* == 0) return error.OwnerDataMissing;
}
fn work(app: *r.App, check: *Check, options: Options, snes: bool, owner_records: *usize) !void {
    const begin = try check.beginSession(.begin_benchmark);
    check.out.record("benchmark-control", check.resource_group, 0, .{ .owner = check.desktop, .caller = check.caller,
        .snes = snes, .options = options.snes, .output_analysis = options.output_analysis,
        .original_work = true, .ipc_sampling_during_child = false });
    if (snes and begin.flags & wire.isolated == 0) return error.RequiresIsolatedDesktopBoot;
    if (!snes or options.output_analysis) {
        _ = try check.call(.software_profile, .{}, 0, 0);
        var buffer: [128:0]u8 = undefined;
        const path = try wire.softwareReportPath(&buffer, .{ .instance = check.caller.instance_id, .generation = check.caller.generation });
        var documents: usize = 0;
        try emit(app, check.out, path, "software-output", "DESKTOP", false, &documents);
        if (!snes) owner_records.* = documents;
    }
    if (!snes) return;
    if (!check.sys.exists(snes_path)) return error.SnesMissing;
    try check.prepareSnes(options.snes);
    var args_buffer: [128:0]u8 = undefined;
    const args = try std.fmt.bufPrintZ(&args_buffer, "{s} {s} {s}", .{
        if (options.snes.check_only) @as([]const u8, "/PERFCHECK") else "/PERFTEST",
        if (options.snes.pal) @as([]const u8, "/PAL") else "/NTSC",
        switch (options.snes.mode) { .normal => @as([]const u8, "/NORMAL"), .detail => "/DETAIL", .paired => "/PAIRED" },
    });
    // The public pending-attach gate keeps this exact GUI from warming up
    // until the prepared owner geometry and trace have been bound.
    if (check.sys.programSpawnHandle(snes_path, args, .gui, &check.handles[0]) != 0 or check.handles[0].instance_id == 0) return error.SnesSpawn;
    const target: wire.Identity = .{ .instance = check.handles[0].instance_id, .generation = check.handles[0].generation };
    _ = try check.call(.bind, target, 0, 0);
    var done: a.ProgramProcessCompletion = .{};
    while (true) {
        try check.checkDeadline();
        const status = check.sys.programHandleWait(&check.handles[0], check.sys.ticksFromMilliseconds(100), &done);
        if (status == 0) break;
        if (status != a.program_handle_error_timeout) return error.SnesWait;
    }
    if (done.handle.instance_id != target.instance or done.handle.generation != target.generation or done.sequence == 0) return error.SnesCompletion;
    check.out.record("benchmark-child", "SNES", 0, .{ .handle = done.handle, .sequence = done.sequence, .exit_code = done.exit_code });
    if (done.exit_code != 0) return error.SnesChildFailed;
    try @import("desktop_bench_finish.zig").finish(check, target);
    try emit(app, check.out, wire.snes_data_path, "snes-sample", "SNES", true, owner_records);
    const expected: usize = if (options.snes.check_only) 1 else if (options.snes.mode == .paired) 10 else 5;
    if (owner_records.* != expected) return error.SnesSampleCount;
    var documents: usize = 0;
    try emit(app, check.out, wire.snes_window_path, "desktop-output", "SNES", false, &documents);
    if (!check.closeChild(0, false)) return error.SnesReap;
}

pub fn run(app: *r.App, args: []const u8, out: *Output, snes: bool) i32 {
    const options = @import("desktop_bench_options.zig").parse(args, snes) catch return 2;
    const group: []const u8 = if (snes) "SNES" else "DESKTOP";
    @import("check_context.zig").emit(app, out, group);
    if (options.core) {
        out.unavailable(group, "Core is the independent native host-owner benchmark; use R4SNES/Benchmark.ps1 -Profile Core. No Core guest measurement was performed.");
        out.record("result", group, 0, .{ .exit_code = @as(i32, 1), .success = false, .cleanup_acknowledged = true });
        return 1;
    }
    var check: Check = .{ .sys = app.system(), .out = out, .desk = app.desktop(), .resource_group = group };
    check.deadline = check.sys.ticks() +| check.sys.ticksFromMilliseconds(300000);
    if (check.sys.programOpenHandle(@intCast(app.raw.instance_id), &check.caller) != 0) return 1;
    var owned: @import("owned_desktop.zig").Owned = .{};
    var result: i32 = 0;
    var owner_records: usize = 0;
    if (options.own_desktop) owned.start(&check) catch |err| {
        out.unavailable(group, @errorName(err));
        result = if (check.cancelled or check.sys.programShouldClose()) 4 else 1;
    };
    if (result == 0) work(app, &check, options, snes, &owner_records) catch |err| {
        const cancelled = check.cancelled or check.sys.programShouldClose();
        out.unavailable(group, if (cancelled) "Cancelled" else @errorName(err));
        result = if (cancelled) 4 else 1;
    };
    // Preserve complete original partial samples on failure before the exact
    // child/session cleanup removes its own files. Never turn them into scores.
    if (result != 0 and snes and check.handles[0].instance_id != 0) {
        // Never read a still-running writer's partial file. Actual completion
        // and reap precede failure export, then End removes the reserved files.
        if (check.closeChild(0, true)) {
            if (owner_records == 0) emit(app, out, wire.snes_data_path, "snes-sample", "SNES", true, &owner_records) catch {};
            if (readFile(app, wire.snes_error_path)) |bytes| {
                const allocator = app.allocator().?;
                defer allocator.free(bytes);
                if (std.json.parseFromSlice(std.json.Value, allocator, bytes, .{})) |value| {
                    defer value.deinit();
                    if (value.value == .object) out.ownerJson("snes-error", "SNES", 0, bytes)
                    else out.message("SNES", bytes, false);
                } else |_| out.message("SNES", bytes, false);
            } else |_| {}
        }
    }
    var cleaned = check.cleanup();
    const host_closed = owned.close(&check);
    if (!host_closed) cleaned = false;
    if (check.connection != 0 and !check.cleanup()) cleaned = false; // A failed final passive query.
    if (!cleaned) result = 1;
    out.record("result", group, 0, .{ .exit_code = result, .success = result == 0,
        .cleanup_acknowledged = cleaned, .original_owner_records = owner_records,
        .physical_visibility = @as(?bool, null), .cursor_latency_ns = @as(?u64, null) });
    return result;
}
