//! Foreground console ownership stays on the BSP. Only this explicitly owned
//! background execution may place the benchmark's private threads on APs.
const std = @import("std");
const r4os = @import("r4os");
const cli = @import("cli.zig");
const Output = @import("output.zig").Output;
const model = @import("standard_model.zig");
pub const prefix = "/STDWORK:";
const executable = "C:\\R4OS\\SOFTWARE\\TERMINAL\\DIAG\\SPECTRA.R4X";

pub fn workerRequest(app: *r4os.App, raw: []const u8, buffer: []u8) !cli.Request {
    if (!std.mem.startsWith(u8, raw, prefix) or raw.len - prefix.len >= 80) return error.InvalidWorker;
    var name: [80:0]u8 = .{0} ** 80;
    const path = raw[prefix.len..];
    if (!std.mem.startsWith(u8, path, "C:\\TEMP\\BSC")) return error.InvalidWorker;
    @memcpy(name[0..path.len], path);
    const sys = app.system();
    const info = sys.fileInfo(&name) orelse return error.InvalidWorker;
    if (info.size == 0 or info.size > buffer.len) return error.InvalidWorker;
    const got = sys.fileRead(&name, buffer[0..@intCast(info.size)]);
    if (got != info.size) return error.InvalidWorker;
    const request = try cli.parse(buffer[0..@intCast(got)]);
    if (request.command != .bench or !cli.same(request.group(), "STANDARD") or request.export_len == 0) return error.InvalidWorker;
    return request;
}

fn run(app: *r4os.App, request: *const cli.Request) !i32 {
    const sys = app.system();
    var capacity: r4os.abi.CpuCapacity = .{};
    if (sys.cpuCapacity(&capacity) != r4os.abi.thread_ok or capacity.available_cpus == 0) return error.CpuCapacity;
    const timeout = model.launcher_timeout_ns * model.timeoutScale(capacity.available_cpus);
    var identity: r4os.abi.ProgramJoinHandle = .{};
    if (sys.threadCurrentHandle(&identity) != r4os.abi.thread_ok or identity.instance_id == 0) return error.Identity;
    var command_path: [80:0]u8 = .{0} ** 80;
    var result_path: [80:0]u8 = .{0} ** 80;
    const command_name = try std.fmt.bufPrintZ(&command_path, "C:\\TEMP\\BSC{X:0>8}.CMD", .{identity.instance_id});
    const result_name = try std.fmt.bufPrintZ(&result_path, "C:\\TEMP\\BSR{X:0>8}.OUT", .{identity.instance_id});
    if (sys.exists(command_name) or sys.exists(result_name)) return error.PrivateFileConflict;
    var command: [1024]u8 = undefined;
    const bytes = try std.fmt.bufPrint(&command, "BENCH STANDARD {s} {s} /EXPORT:{s}", .{
        request.args(), if (request.format == .json) "/JSON" else "", result_name,
    });
    if (sys.fileStreamBegin(command_name, r4os.abi.file_stream_open_create) != 0) return error.CommandFile;
    var command_owned = true;
    defer if (command_owned) {
        _ = sys.fileDelete(command_name);
    };
    if (sys.fileStreamWrite(command_name, 0, bytes, 0) != bytes.len or sys.fileStreamFinish(command_name, bytes.len, 0) != 0) {
        _ = sys.fileStreamAbort(command_name);
        return error.CommandFile;
    }
    var arguments: [128:0]u8 = .{0} ** 128;
    const args = try std.fmt.bufPrintZ(&arguments, prefix ++ "{s}", .{command_name});
    var handle: r4os.abi.ProgramProcessHandle = .{};
    if (sys.programSpawnHandle(executable, args, .auto, &handle) != r4os.abi.program_handle_ok) return error.Spawn;
    var reaped = false;
    defer if (!reaped) {
        _ = sys.programHandleRequestClose(&handle);
        var completion: r4os.abi.ProgramProcessCompletion = .{};
        if (sys.programHandleWait(&handle, @max(1, sys.ticksFromMilliseconds(5000)), &completion) != r4os.abi.program_handle_ok) {
            _ = sys.programHandleKill(&handle);
            _ = sys.programHandleWait(&handle, @max(1, sys.ticksFromMilliseconds(5000)), &completion);
        }
        reaped = sys.programHandleReap(&handle, &completion) == r4os.abi.program_handle_ok;
        if (!reaped) {
            command_owned = false; // Exact live worker may still be reading it.
            sys.println("SPECTRA STANDARD: worker cleanup retained");
        } else if (sys.exists(result_name)) {
            _ = sys.fileDelete(result_name);
        }
    };
    const started = sys.monotonicNanoseconds() orelse return error.Clock;
    var closing = false;
    var completion: r4os.abi.ProgramProcessCompletion = .{};
    while (true) {
        if (sys.programShouldClose() and !closing) {
            _ = sys.programHandleRequestClose(&handle);
            closing = true;
        }
        const rc = sys.programHandleWait(&handle, @max(1, sys.ticksFromMilliseconds(200)), &completion);
        if (rc == r4os.abi.program_handle_ok) break;
        if (rc != r4os.abi.program_handle_error_timeout) return error.Wait;
        if ((sys.monotonicNanoseconds() orelse return error.Clock) -| started >= timeout) return error.Timeout;
    }
    if (sys.programHandleReap(&handle, &completion) != r4os.abi.program_handle_ok) return error.Reap;
    reaped = true;
    defer if (sys.exists(result_name)) {
        _ = sys.fileDelete(result_name);
    };
    const info = sys.fileInfo(result_name) orelse return error.MissingResult;
    if (info.size == 0 or info.size > 256 * 1024) return error.ResultSize;
    var out = Output.init(app, request);
    var buffer: [4096]u8 = undefined;
    var at: u64 = 0;
    while (at < info.size) {
        const count: usize = @intCast(@min(buffer.len, info.size - at));
        if (sys.fileReadAt(result_name, @intCast(at), buffer[0..count]) != count) return error.ResultRead;
        out.write(buffer[0..count]);
        at += count;
    }
    if (!out.finish()) return error.ResultWrite;
    return if (closing) 4 else completion.exit_code;
}

pub fn launch(app: *r4os.App, request: *const cli.Request) i32 {
    return run(app, request) catch |err| {
        app.system().write("SPECTRA STANDARD: ");
        app.system().println(@errorName(err));
        return 1;
    };
}
