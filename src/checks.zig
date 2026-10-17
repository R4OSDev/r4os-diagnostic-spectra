//! Explicit active checks. Migrated check bodies keep their original assertions.
const std = @import("std");
const r4os = @import("r4os");
const cli = @import("cli.zig");
const Output = @import("output.zig").Output;

var adapted: r4os.App = undefined;
var raw: r4os.abi.R4XStartContext = undefined;
var table: r4os.abi.R4XStartR4Sys = undefined;
var imports: [32]r4os.abi.R4XStartImport = undefined;
var arguments: [1024:0]u8 = undefined;
var sink: *Output = undefined;
var line: [4096]u8 = undefined;
var line_length: usize = 0;
var machine_continuation = false;
var write_lock: u8 = 0;
var write_failed: u8 = 0;

fn write(bytes: [*]const u8, length: u32) callconv(.c) i32 {
    // A check can print from several threads. Serialize the shared framing
    // buffer and yield on contention; never spin while its owner drains I/O.
    // A killed writer must cause an output failure, not an unbounded wait.
    var attempts: u32 = 0;
    while (@cmpxchgWeak(u8, &write_lock, 0, 1, .acquire, .monotonic) != null) {
        if (attempts >= 1000 or sink.sys.programShouldClose()) {
            @atomicStore(u8, &write_failed, 1, .release);
            return -1;
        }
        attempts += 1;
        sink.sys.sleepTicks(1);
    }
    defer @atomicStore(u8, &write_lock, 0, .release);
    for (bytes[0..length]) |byte| {
        if (byte == '\r') continue;
        if (byte == '\n') {
            if (sink.format == .json and (machine_continuation or std.mem.startsWith(u8, line[0..line_length], "{\"schema\":"))) {
                // Existing benchmark records already carry their versioned
                // numeric model; preserve them as records, not quoted text.
                sink.write(line[0..line_length]);
                sink.write("\n");
            } else sink.message("check", line[0..line_length], false);
            line_length = 0;
            machine_continuation = false;
        } else {
            line[line_length] = byte;
            line_length += 1;
            if (line_length == line.len) {
                if (sink.format == .json and (machine_continuation or std.mem.startsWith(u8, &line, "{\"schema\":"))) {
                    sink.write(&line);
                    machine_continuation = true;
                } else sink.message("check", &line, true);
                line_length = 0;
            }
        }
    }
    return @intCast(length);
}

fn putc(byte: u8) callconv(.c) void { _ = write(&.{byte}, 1); }

fn prepare(app: *r4os.App, args: [:0]const u8, out: *Output) bool {
    if (args.len >= arguments.len or app.raw.import_count > imports.len) return false;
    @memcpy(arguments[0..args.len], args);
    arguments[args.len] = 0;
    raw = app.raw.*;
    raw.args = @intFromPtr(&arguments);
    raw.args_len = args.len;
    adapted = app.*;
    adapted.raw = &raw;
    adapted.bundle.raw = &raw;
    sink = out;
    line_length = 0;
    machine_continuation = false;
    write_lock = 0;
    write_failed = 0;
    // Normal console checks retain their real output cost and timing.
    if (out.format == .json or out.path != null) {
        const original = app.bundle.sys orelse return false;
        table = .{};
        const len = @min(@sizeOf(@TypeOf(table)), original.size);
        @memcpy(std.mem.asBytes(&table)[0..len], std.mem.asBytes(original)[0..len]);
        table.write = @intFromPtr(&write);
        table.putc = @intFromPtr(&putc);
        adapted.bundle.sys = &table;
        const source: [*]const r4os.abi.R4XStartImport = @ptrFromInt(raw.imports);
        @memcpy(imports[0..raw.import_count], source[0..raw.import_count]);
        for (imports[0..raw.import_count]) |*item| if (item.group_id == @intFromEnum(r4os.abi.R4LGroup.r4sys)) { item.table = @intFromPtr(&table); };
        raw.imports = @intFromPtr(&imports);
    }
    return true;
}

pub fn run(app: *r4os.App, request: *const cli.Request, out: *Output) i32 {
    const group = request.group();
    var args_buffer: [1024:0]u8 = undefined;
    var args = request.args();
    if (request.command == .bench) {
        if (cli.same(group, "OBSERVER")) {
            if (args.len != 0 or request.format == .json or request.export_len != 0) {
                out.unavailable("observer", "requires real console output; no options or redirected presentation");
                return 2;
            }
            args = "/OBSERVER";
        } else {
            const suites = .{ "CLOCK", "BLIT", "SERVICE-REGISTRY", "KERNEL-IPC", "DRIVER-WORK", "PCI-INVENTORY", "MEMORY-METADATA" };
            var found = false;
            inline for (suites) |name| if (cli.same(group, name)) { found = true; };
            if (!found) { out.unavailable("bench", "unknown benchmark group"); return 2; }
            args = std.fmt.bufPrintZ(&args_buffer, "/BENCHMARK /{s} {s}", .{ group, args }) catch return 2;
        }
    } else if (cli.same(group, "PERFORMANCE")) {
        if (args.len != 0) { out.unavailable("check", "PERFORMANCE takes no options; use BENCH for workloads"); return 2; }
        args = "/CONFORMANCE";
    }
    if (!prepare(app, args, out)) return 2;
    var result: i32 = 2;
    if (request.command == .bench or cli.same(group, "PERFORMANCE")) {
        result = @import("checks/performance/main.zig").r4_app_main(&adapted);
    } else {
        if (cli.same(group, "smp")) result = @import("checks/smp.zig").run(&adapted, args, out);
        if (cli.same(group, "vm")) result = @import("checks/vm/main.zig").r4_app_main(&adapted);
        if (cli.same(group, "storage")) result = @import("checks/storage/main.zig").r4_app_main(&adapted);
        if (cli.same(group, "tcp")) result = @import("checks/tcp/main.zig").r4_app_main(&adapted);
        if (cli.same(group, "boot")) result = @import("checks/boot/main.zig").r4_app_main(&adapted);
        if (cli.same(group, "work")) result = @import("checks/work/main.zig").r4_app_main(&adapted);
        if (cli.same(group, "thread")) {
            var options = cli.Tokens{ .input = args };
            var kernel_selected = false;
            while (options.next() catch return 2) |token| {
                if (std.ascii.startsWithIgnoreCase(token, "/KERNEL")) kernel_selected = true;
            }
            if (kernel_selected) result = @import("checks/thread/kernel.zig").run(&adapted, args, out)
            else result = @import("checks/thread/main.zig").r4_app_main(&adapted);
        }
        if (cli.same(group, "stack")) result = @import("checks/stack/main.zig").r4_app_main(&adapted);
        if (cli.same(group, "simd")) result = @import("checks/simd/main.zig").r4_app_main(&adapted);
        if (cli.same(group, "lifecycle")) result = @import("checks/lifecycle/main.zig").r4_app_main(&adapted);
        if (cli.same(group, "async_io")) result = @import("checks/async_io/main.zig").r4_app_main(&adapted);
        if (cli.same(group, "memory")) {
            var options = cli.Tokens{ .input = args };
            var heap_selected = false;
            while (options.next() catch return 2) |token| {
                if (cli.same(token, "/KERNELHEAP")) heap_selected = true;
            }
            if (heap_selected) {
                if (!cli.same(args, "/KERNELHEAP")) {
                    out.unavailable("memory", "/KERNELHEAP takes no check options");
                    result = 2;
                } else result = @import("checks/memory/kernel_heap.zig").run(&adapted, out);
            } else result = @import("checks/memory/main.zig").r4_app_main(&adapted);
        }
        if (cli.same(group, "filesystem")) result = @import("checks/filesystem/main.zig").r4_app_main(&adapted);
        if (cli.same(group, "ntfs")) result = @import("checks/ntfs/main.zig").r4_app_main(&adapted);
        if (cli.same(group, "loader")) result = @import("checks/loader/main.zig").r4_app_main(&adapted);
        if (cli.same(group, "resources")) result = @import("checks/resources/main.zig").r4_app_main(&adapted);
        if (cli.same(group, "input")) result = @import("checks/input/main.zig").r4_app_main(&adapted);
        if (cli.same(group, "network")) result = @import("checks/network/main.zig").r4_app_main(&adapted);
        if (cli.same(group, "ipc")) result = @import("checks/ipc/main.zig").r4_app_main(&adapted);

    }
    if (@atomicLoad(u8, &write_failed, .acquire) != 0) out.failed = true;
    if (line_length != 0) out.message("check", line[0..line_length], false);
    out.record("result", group, 0, .{ .exit_code = result, .success = result == 0 });
    return result;
}
