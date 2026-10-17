//! Explicit admission probes pass scalar lengths through the real ABI. Their
//! actual buffers stay small; oversized requests must never reach the backend.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const path = "C:\\TEMP\\IOLIMIT.BIN";
const stream_path = "C:\\TEMP\\IOLENSTR.BIN";
const payload: []const u8 = "single-io-bound!";
const max_count: u64 = std.math.maxInt(i32);
const Op = enum { read, read_at, write, append, write_at, stream_write };

fn api(sys: *const r4os.r4sys.Context, comptime name: []const u8) @field(a.R4SysFns, name) {
    return @ptrFromInt(@field(sys.base.bundle.?.sys.?.*, name));
}
fn fail(sys: *r4os.r4sys.Context, message: []const u8) i32 {
    sys.print("SPECTRA ASYNC_IO lengths FAILED: ");
    sys.println(message);
    return 1;
}
fn submit(sys: *r4os.r4sys.Context, op: Op, target: [*:0]const u8, out: *[16]u8, count: u64, id: *u32) i32 {
    return switch (op) {
        .read => api(sys, "io_file_read")(target, out, count, 0, id),
        .read_at => api(sys, "io_file_read_at")(target, 0, out, count, 0, id),
        .write => api(sys, "io_file_write")(target, payload.ptr, count, 0, id),
        .append => api(sys, "io_file_append")(target, payload.ptr, count, 0, id),
        .write_at => api(sys, "io_file_write_at")(target, 0, payload.ptr, count, 0, id),
        .stream_write => api(sys, "io_file_stream_write")(target, payload.len, payload.ptr, count, 0, id),
    };
}
fn legacy(sys: *r4os.r4sys.Context, op: Op, target: [*:0]const u8, out: *[16]u8, count: u32) i32 {
    return switch (op) {
        .read => api(sys, "file_read")(target, out, count),
        .read_at => api(sys, "file_read_at")(target, 0, out, count),
        .write => api(sys, "file_write")(target, payload.ptr, count),
        .append => api(sys, "file_append")(target, payload.ptr, count),
        .stream_write => api(sys, "file_stream_write")(target, payload.len, payload.ptr, count, 0),
        .write_at => unreachable, // This operation has the 64-bit async ABI.
    };
}
fn waitResult(sys: *r4os.r4sys.Context, id: u32, expected: i32, requested: u64) bool {
    var info: a.ProgramIoInfo = .{};
    const waited = sys.ioWait(id, sys.monotonicHz() * 5, &info);
    if (waited != a.io_ok) {
        return false;
    }
    const closed = sys.ioClose(id);
    return closed == a.io_ok and info.request_id == id and info.result == expected and
        info.requested_bytes == requested and info.processed_bytes == 0;
}

pub fn run(app: *r4os.App) i32 {
    var sys = app.system();
    inline for (.{ "io_file_read", "io_file_read_at", "io_file_write", "io_file_append", "io_file_write_at", "io_file_stream_write", "file_read", "file_read_at", "file_write", "file_append", "file_stream_write", "file_stream_begin", "file_stream_finish", "file_stream_abort", "io_wait", "io_close" }) |name| {
        if (!sys.hasFn(name)) return fail(&sys, "ABI function unavailable");
    }
    defer {
        _ = api(&sys, "file_stream_abort")(stream_path);
        _ = sys.fileDelete(stream_path);
        _ = sys.fileDelete(path);
    }
    if (sys.fileWrite(path, payload) != payload.len) return fail(&sys, "fixture write");
    const before = sys.fileInfo(path) orelse return fail(&sys, "fixture identity");
    if (api(&sys, "file_stream_begin")(stream_path, a.file_stream_open_replace) != a.file_stream_result_ok or
        api(&sys, "file_stream_write")(stream_path, 0, payload.ptr, payload.len, 0) != payload.len)
        return fail(&sys, "stream fixture");

    var out: [16]u8 = .{0xa7} ** 16;
    var rejected: u32 = 0;
    for ([_]u64{ max_count + 1, std.math.maxInt(u32), std.math.maxInt(u64) }) |count| {
        inline for (std.meta.tags(Op)) |op| {
            const target: [*:0]const u8 = if (op == .stream_write) stream_path else path;
            var id: u32 = std.math.maxInt(u32);
            const result = submit(&sys, op, target, &out, count, &id);
            if (result != a.io_error_too_large or id != 0) {
                if (result == a.io_ok and id != 0) {
                    var info: a.ProgramIoInfo = .{};
                    _ = sys.ioWait(id, sys.monotonicHz() * 5, &info);
                    _ = sys.ioClose(id);
                }
                return fail(&sys, "async oversized request admitted");
            }
            rejected += 1;
            if (op != .write_at and count <= std.math.maxInt(u32)) {
                if (legacy(&sys, op, target, &out, @intCast(count)) != a.io_error_too_large)
                    return fail(&sys, "legacy oversized request admitted");
                rejected += 1;
            }
        }
    }
    for (out) |byte| if (byte != 0xa7) return fail(&sys, "rejected read changed output");

    // The exact positive boundary passes length admission and reaches an
    // intentionally invalid empty path, without touching any large buffer.
    inline for (std.meta.tags(Op)) |op| {
        var id: u32 = 0;
        if (submit(&sys, op, "", &out, max_count, &id) != a.io_ok or id == 0 or
            !waitResult(&sys, id, a.io_error_invalid, max_count))
            return fail(&sys, "INT32_MAX admission boundary");
        if (op != .write_at and legacy(&sys, op, "", &out, @intCast(max_count)) != a.io_error_invalid)
            return fail(&sys, "legacy INT32_MAX boundary");
    }
    var id: u32 = 0;
    if (api(&sys, "io_file_read_at")(path, @as(u64, 1) << 32 | 7, &out, out.len, 0, &id) != a.io_ok or
        id == 0 or !waitResult(&sys, id, 0, out.len))
        return fail(&sys, "64-bit range-read offset");

    const after = sys.fileInfo(path) orelse return fail(&sys, "fixture disappeared");
    var verify: [32]u8 = undefined;
    if (after.first_cluster != before.first_cluster or after.size != before.size or
        sys.fileRead(path, &verify) != payload.len or !std.mem.eql(u8, verify[0..payload.len], payload))
        return fail(&sys, "rejected transfer changed file");
    if (api(&sys, "file_stream_write")(stream_path, payload.len, payload.ptr, payload.len, 0) != payload.len or
        api(&sys, "file_stream_finish")(stream_path, payload.len * 2, 0) != a.file_stream_result_ok or
        sys.fileRead(stream_path, &verify) != payload.len * 2 or
        !std.mem.eql(u8, verify[0..payload.len], payload) or
        !std.mem.eql(u8, verify[payload.len .. payload.len * 2], payload))
        return fail(&sys, "rejected transfer changed stream");
    sys.print("SPECTRA ASYNC_IO lengths result: OK rejected=");
    sys.printU64(rejected);
    sys.println(" max=2147483647 file=unchanged stream=unchanged output=unchanged offset64=yes");
    return 0;
}
