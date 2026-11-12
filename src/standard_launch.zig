//! Foreground console ownership stays on the BSP. Only this explicitly owned
//! background execution may place the benchmark's private threads on APs.
const std = @import("std");
const r4os = @import("r4os");
const cli = @import("cli.zig");
const Output = @import("output.zig").Output;
const model = @import("standard_model.zig");
const export_api = @import("standard_export.zig");
pub const Report = struct {
    exit_code: i32 = 1,
    saved: ?export_api.Result = null,
    phase: []const u8 = "prepare",
    error_name: ?[]const u8 = null,
};
pub const prefix = "/STDWORK:";
const executable = "C:\\R4OS\\SOFTWARE\\TERMINAL\\DIAG\\SPECTRA.R4X";

pub fn workerRequest(app: *r4os.App2, raw: []const u8, buffer: []u8) !cli.Request {
    if (!std.mem.startsWith(u8, raw, prefix) or raw.len - prefix.len >= 80) return error.InvalidWorker;
    const path = raw[prefix.len..];
    if (!std.mem.startsWith(u8, path, "C:\\TEMP\\BSC")) return error.InvalidWorker;
    const files = app.files() orelse return error.InvalidWorker;
    const file_path = try r4os.AbsoluteFilePath.parse(path);
    const read = switch (files.readDocumentPrefix(file_path.asZ(), buffer, .{ .kind = r4os.abi.timeout_kind_finite, .nanoseconds = 2_000_000_000 })) {
        .value => |value| value,
        .failure => return error.InvalidWorker,
    };
    if (read.file_size == 0 or read.file_size > buffer.len or read.bytes != read.file_size) return error.InvalidWorker;
    const got = read.bytes;
    const request = try cli.parse(buffer[0..@intCast(got)]);
    if (request.command != .bench or !cli.same(request.group(), "STANDARD") or request.export_len == 0) return error.InvalidWorker;
    return request;
}

fn run(app: *r4os.App2, request: *const cli.Request, report: *Report, emit: bool, presentation: export_api.Presentation) !i32 {
    const sys = app.system();
    const config = try @import("standard_reference.zig").parseOptions(request.args());
    const full_standard = config.area == null and config.settle_ms == 200;
    if (request.upload and !full_standard) return error.NonstandardUpload;
    const started_utc = sys.timeState();
    var capacity: r4os.abi.CpuCapacity = .{};
    if (sys.cpuCapacity(&capacity) != r4os.abi.thread_ok or capacity.available_cpus == 0) return error.CpuCapacity;
    const timeout = model.launcher_timeout_ns * model.timeoutScale(capacity.available_cpus);
    var identity: r4os.abi.ProgramJoinHandle = .{};
    if (sys.threadCurrentHandle(&identity) != r4os.abi.thread_ok or identity.instance_id == 0) return error.Identity;
    var command_path: [80:0]u8 = .{0} ** 80;
    var result_path: [80:0]u8 = .{0} ** 80;
    var raw_path_buffer: [96:0]u8 = .{0} ** 96;
    const command_name = try std.fmt.bufPrintZ(&command_path, "C:\\TEMP\\BSC{X:0>8}.CMD", .{identity.instance_id});
    const result_name = try std.fmt.bufPrintZ(&result_path, "C:\\TEMP\\BSR{X:0>8}.OUT", .{identity.instance_id});
    const raw_name = try std.fmt.bufPrintZ(&raw_path_buffer, "{s}.RAW", .{result_name});
    if (sys.exists(command_name) or sys.exists(result_name) or sys.exists(raw_name)) return error.PrivateFileConflict;
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
        }
    };
    const started = sys.monotonicNanoseconds() orelse return error.Clock;
    var closing = false;
    var close_started: u64 = 0;
    report.phase = "measure";
    var completion: r4os.abi.ProgramProcessCompletion = .{};
    while (true) {
        if (sys.programShouldClose() and !closing) {
            _ = sys.programHandleRequestClose(&handle);
            closing = true;
            close_started = sys.monotonicNanoseconds() orelse return error.Clock;
        }
        const rc = sys.programHandleWait(&handle, @max(1, sys.ticksFromMilliseconds(200)), &completion);
        if (rc == r4os.abi.program_handle_ok) break;
        if (rc != r4os.abi.program_handle_error_timeout) return error.Wait;
        const now = sys.monotonicNanoseconds() orelse return error.Clock;
        if (closing and now -| close_started >= 5_000_000_000) return error.Cancelled;
        if (now -| started >= timeout) return error.Timeout;
    }
    if (sys.programHandleReap(&handle, &completion) != r4os.abi.program_handle_ok) return error.Reap;
    reaped = true;
    const finished_utc = sys.timeState();
    const info = sys.fileInfo(result_name) orelse return error.MissingResult;
    if (info.size == 0 or info.size > 256 * 1024) return error.ResultSize;
    if (emit) {
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
    }
    if (closing or completion.exit_code != 0) return if (closing) 4 else completion.exit_code;
    if (!full_standard) {
        _ = sys.fileDelete(result_name);
        if (request.format != .json) _ = sys.fileDelete(raw_name);
        return 0;
    }
    const machine_path = if (request.format == .json) result_name else raw_name;
    report.phase = "save";
    const saved = export_api.createWithPresentation(app, machine_path, started_utc, finished_utc, if (config.path[0] != 0) config.key[0..config.key_len] else null, presentation) catch |err| {
        report.error_name = @errorName(err);
        if (emit) {
            sys.write("SPECTRA STANDARD export: ");
            sys.println(@errorName(err));
            sys.write("SPECTRA STANDARD raw records retained: ");
            sys.println(machine_path);
        }
        return 1;
    };
    report.saved = saved;
    _ = sys.fileDelete(result_name);
    if (request.format != .json) _ = sys.fileDelete(machine_path);
    if (emit) {
        sys.write("SPECTRA STANDARD run: ");
        sys.println(saved.path[0..saved.path_len]);
        sys.write("SPECTRA STANDARD SHA256: ");
        sys.println(&saved.sha256);
    }
    if (request.upload) return @import("standard_upload.zig").upload(app, saved.path[0..saved.path_len :0], &saved.sha256);
    return if (closing) 4 else completion.exit_code;
}

pub fn launch(app: *r4os.App2, request: *const cli.Request) i32 {
    var report: Report = .{};
    return run(app, request, &report, true, .terminal) catch |err| {
        app.system().write("SPECTRA STANDARD: ");
        app.system().println(@errorName(err));
        return if (err == error.Cancelled) 4 else 1;
    };
}

/// Same execution/export as the CLI, with a typed result for the private GUI
/// job. It never infers success from console output or starts an upload.
pub fn launchForGui(app: *r4os.App2, request: *const cli.Request) Report {
    var report: Report = .{};
    report.exit_code = run(app, request, &report, false, .desktop_gui) catch |err| result: {
        report.error_name = @errorName(err);
        break :result if (err == error.Cancelled) @as(i32, 4) else @as(i32, 1);
    };
    return report;
}
