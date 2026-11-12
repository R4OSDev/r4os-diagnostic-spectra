//! Private same-binary GUI jobs. A nonce, both process generations and the
//! selection/generation bind the receipt. Only a reaped child can complete it.
const std = @import("std");
const r4os = @import("r4os");
const model = @import("gui_model.zig");
const cli = @import("cli.zig");
const uploader = @import("standard_upload.zig");
pub const prefix = "/SGUIJOB:";
const directory = "C:\\TEMP\\SG";
const executable = "C:\\R4OS\\SOFTWARE\\TERMINAL\\DIAG\\SPECTRA.R4X";
const limit = 4096;
pub const Kind = enum { measure, upload };
const SavedWire = struct { run_id: []const u8, path: []const u8, sha256: []const u8 };
const Request = struct {
    version: u32,
    token: []const u8,
    parent: r4os.abi.ProgramProcessHandle,
    gui_window: i32,
    generation: u64,
    kind: Kind,
    choice: usize,
    saved: ?SavedWire,
};
const Receipt = struct {
    version: u32,
    token: []const u8,
    parent: r4os.abi.ProgramProcessHandle,
    child: r4os.abi.ProgramProcessHandle,
    generation: u64,
    kind: Kind,
    choice: usize,
    code: i32,
    validated: bool,
    saved: ?SavedWire,
    phase: []const u8,
    error_name: ?[]const u8,
};
pub const Outcome = struct {
    generation: u64,
    kind: Kind,
    code: i32,
    saved: ?model.SavedRun = null,
    phase: [64:0]u8 = .{0} ** 64,
    reason: [128:0]u8 = .{0} ** 128,
    local_invalid: bool = false,
    pub fn phaseText(self: *const Outcome) []const u8 {
        return std.mem.sliceTo(&self.phase, 0);
    }
    pub fn reasonText(self: *const Outcome) []const u8 {
        return std.mem.sliceTo(&self.reason, 0);
    }
};
fn same(a: r4os.abi.ProgramProcessHandle, b: r4os.abi.ProgramProcessHandle) bool {
    return std.meta.eql(a, b);
}
fn ownedIdentity(sys: *const r4os.r4sys.Context) !r4os.abi.ProgramProcessHandle {
    var identity: r4os.abi.ProgramJoinHandle = .{};
    if (sys.threadCurrentHandle(&identity) != 0 or identity.instance_id == 0 or identity.instance_generation == 0) return error.JobIdentity;
    return .{ .instance_id = identity.instance_id, .generation = identity.instance_generation };
}
fn write(sys: *const r4os.r4sys.Context, path: [*:0]const u8, bytes: []const u8) !void {
    if (bytes.len == 0 or bytes.len > limit or sys.exists(path)) return error.PrivateFileConflict;
    if (sys.fileStreamBegin(path, r4os.abi.file_stream_open_create) != 0) return error.PrivateFileOpen;
    var done = false;
    defer if (!done) {
        _ = sys.fileStreamAbort(path);
    };
    if (sys.fileStreamWrite(path, 0, bytes, 0) != bytes.len or sys.fileStreamFinish(path, bytes.len, 0) != 0) return error.PrivateFileWrite;
    done = true;
}
fn read(sys: *const r4os.r4sys.Context, allocator: std.mem.Allocator, path: [*:0]const u8) ![]u8 {
    const info = sys.fileInfo(path) orelse return error.MissingReceipt;
    if (info.is_dir != 0 or info.size == 0 or info.size > limit) return error.InvalidReceipt;
    const bytes = try allocator.alloc(u8, @intCast(info.size));
    if (sys.fileRead(path, bytes) != bytes.len) return error.ReceiptRead;
    return bytes;
}
fn wire(saved: *const model.SavedRun) SavedWire {
    return .{ .run_id = &saved.run_id, .path = saved.pathZ(), .sha256 = &saved.sha256 };
}
fn invalidLocal(reason: ?[]const u8) bool {
    const text = reason orelse return false;
    inline for (.{ "RunChanged", "RunMissing", "RunSize", "RunRead", "InvalidRun", "InvalidRunPath", "WrongPhysicalHost" }) |name| if (std.mem.eql(u8, text, name)) return true;
    return false;
}
pub const Job = struct {
    active: bool = false,
    parent: r4os.abi.ProgramProcessHandle = .{},
    child: r4os.abi.ProgramProcessHandle = .{},
    token: [32]u8 = undefined,
    command: [80:0]u8 = .{0} ** 80,
    response: [80:0]u8 = .{0} ** 80,
    generation: u64 = 0,
    choice: usize = 0,
    kind: Kind = .measure,
    close_started: ?u64 = null,
    kill_sent: bool = false,

    pub fn begin(self: *Job, app: *r4os.App2, window: i32, kind: Kind, choice: usize, generation: u64, saved: ?model.SavedRun) !void {
        if (self.active or choice >= model.labels.len or window < 0 or (kind == .upload and (choice != 0 or saved == null))) return error.JobBusy;
        const sys = app.system();
        self.* = .{ .parent = try ownedIdentity(&sys), .generation = generation, .choice = choice, .kind = kind };
        var random: [16]u8 = undefined;
        if (!r4os.secure_random.fill(&random)) return error.JobEntropy;
        self.token = std.fmt.bytesToHex(random, .lower);
        _ = try std.fmt.bufPrintZ(&self.command, directory ++ "{s}.CMD", .{self.token});
        _ = try std.fmt.bufPrintZ(&self.response, directory ++ "{s}.RSP", .{self.token});
        if (sys.exists(&self.command) or sys.exists(&self.response)) return error.PrivateFileConflict;
        var arena = std.heap.ArenaAllocator.init(sys.allocator());
        defer arena.deinit();
        const request: Request = .{ .version = 1, .token = &self.token, .parent = self.parent, .gui_window = window, .generation = generation, .kind = kind, .choice = choice, .saved = if (saved) |*value| wire(value) else null };
        const bytes = try std.json.Stringify.valueAlloc(arena.allocator(), request, .{});
        try write(&sys, &self.command, bytes);
        var started = false;
        defer if (!started) {
            _ = sys.fileDelete(&self.command);
        };
        var arguments: [112:0]u8 = .{0} ** 112;
        const args = try std.fmt.bufPrintZ(&arguments, prefix ++ "{s}", .{std.mem.sliceTo(&self.command, 0)});
        if (sys.programSpawnHandle(executable, args, .auto, &self.child) != 0) return error.JobSpawn;
        self.active = true;
        started = true;
    }
    pub fn requestClose(self: *Job, sys: *const r4os.r4sys.Context) void {
        if (!self.active or self.close_started != null) return;
        self.close_started = sys.monotonicNanoseconds() orelse 0;
        _ = sys.programHandleRequestClose(&self.child);
    }
    pub fn poll(self: *Job, app: *r4os.App2) !?Outcome {
        if (!self.active) return null;
        const sys = app.system();
        if (self.close_started) |started| {
            const now = sys.monotonicNanoseconds() orelse started;
            if (!self.kill_sent and now -| started >= 25_000_000_000) {
                _ = sys.programHandleKill(&self.child);
                self.kill_sent = true;
            }
        }
        var completion: r4os.abi.ProgramProcessCompletion = .{};
        const waited = sys.programHandleWait(&self.child, 0, &completion);
        if (waited == r4os.abi.program_handle_error_timeout or waited == r4os.abi.program_handle_error_would_block) return null;
        if (waited != 0 or !same(completion.handle, self.child)) return error.JobWait;
        const reaped = sys.programHandleReap(&self.child, &completion);
        if (reaped == r4os.abi.program_handle_error_would_block) return null;
        if (reaped != 0 or !same(completion.handle, self.child)) return error.JobReap;
        self.active = false;
        defer self.cleanup(&sys);
        if (self.close_started != null) {
            return .{ .generation = self.generation, .kind = self.kind, .code = 4 };
        }
        var arena = std.heap.ArenaAllocator.init(sys.allocator());
        defer arena.deinit();
        const bytes = try read(&sys, arena.allocator(), &self.response);
        const parsed = try std.json.parseFromSlice(Receipt, arena.allocator(), bytes, .{});
        const receipt = parsed.value;
        if (receipt.version != 1 or !std.mem.eql(u8, receipt.token, &self.token) or !same(receipt.parent, self.parent) or !same(receipt.child, self.child) or
            receipt.generation != self.generation or receipt.kind != self.kind or receipt.choice != self.choice or receipt.code != completion.exit_code) return error.StaleReceipt;
        var outcome: Outcome = .{ .generation = self.generation, .kind = self.kind, .code = receipt.code, .local_invalid = invalidLocal(receipt.error_name) };
        const phase = receipt.phase[0..@min(receipt.phase.len, outcome.phase.len)];
        @memcpy(outcome.phase[0..phase.len], phase);
        if (receipt.error_name) |text| {
            const reason = text[0..@min(text.len, outcome.reason.len)];
            @memcpy(outcome.reason[0..reason.len], reason);
        }
        if (receipt.saved) |value| {
            if (receipt.kind != .measure or receipt.choice != 0 or receipt.code != 0 or !receipt.validated) return error.InvalidReceipt;
            outcome.saved = try model.SavedRun.from(value.run_id, value.path, value.sha256);
        }
        if (receipt.kind == .measure and receipt.choice == 0 and receipt.code == 0 and outcome.saved == null) return error.MissingSavedRun;
        return outcome;
    }
    fn cleanup(self: *Job, sys: *const r4os.r4sys.Context) void {
        // Both names were create-only, nonce-bound control files. Never erase
        // RUN.JSON/RECORDS.NDJSON or a measured worker's retained failure data.
        _ = sys.fileDelete(&self.command);
        _ = sys.fileDelete(&self.response);
    }
};

pub fn worker(app: *r4os.App2, raw: []const u8) i32 {
    return runWorker(app, raw) catch |err| {
        app.system().write("SPECTRA GUI job: ");
        app.system().println(@errorName(err));
        return 1;
    };
}
fn runWorker(app: *r4os.App2, raw: []const u8) !i32 {
    const sys = app.system();
    const name = raw[prefix.len..];
    if (name.len != directory.len + 32 + 4 or !std.mem.startsWith(u8, name, directory) or !std.mem.endsWith(u8, name, ".CMD")) return error.InvalidPrivateJob;
    var command: [80:0]u8 = .{0} ** 80;
    @memcpy(command[0..name.len], name);
    var arena = std.heap.ArenaAllocator.init(sys.allocator());
    defer arena.deinit();
    const bytes = try read(&sys, arena.allocator(), &command);
    const parsed = try std.json.parseFromSlice(Request, arena.allocator(), bytes, .{});
    const request = parsed.value;
    if (request.version != 1 or request.token.len != 32 or !std.mem.eql(u8, request.token, name[directory.len..][0..32]) or request.gui_window < 0 or
        request.parent.instance_id == 0 or request.parent.generation == 0 or request.parent.reserved != 0 or request.choice >= model.labels.len or
        (request.kind == .upload and (request.choice != 0 or request.saved == null)) or (request.kind == .measure and request.saved != null)) return error.InvalidPrivateJob;
    for (request.token) |c| if (!std.ascii.isHex(c) or std.ascii.isUpper(c)) return error.InvalidPrivateJob;
    const child = try ownedIdentity(&sys);
    var receipt: Receipt = .{ .version = 1, .token = request.token, .parent = request.parent, .child = child, .generation = request.generation, .kind = request.kind, .choice = request.choice, .code = 1, .validated = false, .saved = null, .phase = "prepare", .error_name = null };
    var retained: ?model.SavedRun = null;
    if (sys.programShouldClose()) receipt.code = 4 else if (request.kind == .measure) {
        var text: [128]u8 = undefined;
        const command_text = try std.fmt.bufPrint(&text, "BENCH STANDARD {s} /JSON", .{model.arguments[request.choice]});
        const benchmark = try cli.parse(command_text);
        const report = @import("standard_launch.zig").launchForGui(app, &benchmark);
        receipt.code = report.exit_code;
        receipt.phase = report.phase;
        receipt.error_name = report.error_name;
        if (report.exit_code == 0) {
            if (report.saved) |saved| {
                uploader.validateLocal(app, saved.path[0..saved.path_len :0], &saved.sha256) catch |err| {
                    receipt.code = 1;
                    receipt.phase = "save";
                    receipt.error_name = @errorName(err);
                };
                if (receipt.code == 0) {
                    retained = try model.SavedRun.from(&saved.run_id, saved.path[0..saved.path_len], &saved.sha256);
                    receipt.validated = true;
                }
            }
        }
    } else {
        const input = request.saved.?;
        var saved = try model.SavedRun.from(input.run_id, input.path, input.sha256);
        const report = uploader.uploadWithReport(app, saved.pathZ(), &saved.sha256);
        receipt.code = report.exit_code;
        receipt.phase = report.phase;
        receipt.error_name = report.error_name;
    }
    receipt.saved = if (retained) |*saved| wire(saved) else null;
    var response: [80:0]u8 = .{0} ** 80;
    _ = try std.fmt.bufPrintZ(&response, directory ++ "{s}.RSP", .{request.token});
    const result = try std.json.Stringify.valueAlloc(arena.allocator(), receipt, .{});
    try write(&sys, &response, result);
    return receipt.code;
}
