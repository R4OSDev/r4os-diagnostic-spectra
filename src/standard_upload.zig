//! Explicit Spectra Standard upload: register, claim the physical host, PUT the
//! saved run's exact bytes, then read back the immutable server record.
const std = @import("std");
const r4os = @import("r4os");
const identity_api = @import("standard_identity.zig");
const readback_api = @import("standard_readback.zig");
const scoring_api = @import("standard_server_scoring.zig");
const Value = std.json.Value;
const max_run_bytes = 256 * 1024;
const timeout_ns = 90_000_000_000;

fn field(value: Value, key: []const u8) ?Value {
    return if (value == .object) value.object.get(key) else null;
}
fn string(value: Value, key: []const u8) ?[]const u8 {
    const item = field(value, key) orelse return null;
    return if (item == .string) item.string else null;
}
fn same(value: Value, key: []const u8, expected: []const u8) bool {
    return std.mem.eql(u8, string(value, key) orelse return false, expected);
}
fn isTrue(value: Value, key: []const u8) bool {
    const item = field(value, key) orelse return false;
    return item == .bool and item.bool;
}
fn array(value: Value, key: []const u8, count: usize) ?[]Value {
    const item = field(value, key) orelse return null;
    if (item != .array or item.array.items.len != count) return null;
    return item.array.items;
}
fn responseCode(sys: *const r4os.r4sys.Context, phase: []const u8, status: u16) void {
    sys.write("SPECTRA STANDARD ");
    sys.write(phase);
    sys.write(" HTTP=");
    sys.printU64(status);
    sys.println("");
}
fn requireStatus(sys: *const r4os.r4sys.Context, phase: []const u8, status: u16, a: u16, b: u16) !void {
    responseCode(sys, phase, status);
    if (status != a and status != b) return error.ServerRejected;
}
fn url(buffer: []u8, ip: [4]u8, port: u16, route: []const u8, id: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "https://{d}.{d}.{d}.{d}:{d}/api/v1/{s}/{s}", .{
        ip[0], ip[1], ip[2], ip[3], port, route, id,
    });
}
fn loadRun(allocator: std.mem.Allocator, sys: *const r4os.r4sys.Context, path: [:0]const u8, expected_sha: ?[]const u8) !struct { bytes: []u8, doc: Value } {
    const prefix = "C:\\R4OS\\DATA\\BENCHMARKS\\";
    const suffix = "\\RUN.JSON";
    if (!std.mem.startsWith(u8, path, prefix) or path.len != prefix.len + 36 + suffix.len or
        !std.mem.endsWith(u8, path, suffix)) return error.InvalidRunPath;
    const info = sys.fileInfo(path) orelse return error.RunMissing;
    if (info.is_dir != 0 or info.size == 0 or info.size > max_run_bytes) return error.RunSize;
    const bytes = try allocator.alloc(u8, @intCast(info.size));
    if (sys.fileRead(path, bytes) != info.size) return error.RunRead;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const found = std.fmt.bytesToHex(digest, .lower);
    if (expected_sha) |wanted| if (!std.mem.eql(u8, &found, wanted)) return error.RunChanged;
    const parsed = try std.json.parseFromSlice(Value, allocator, bytes, .{ .allocate = .alloc_always });
    const doc = parsed.value;
    const run_id = string(doc, "run_id") orelse return error.InvalidRun;
    const host_id = string(doc, "host_id") orelse return error.InvalidRun;
    if (run_id.len != 36 or !std.mem.eql(u8, path[prefix.len..][0..36], run_id) or host_id.len != 64 or !same(doc, "status", "completed")) return error.InvalidRun;
    const schema = field(doc, "schema_version") orelse return error.InvalidRun;
    if (schema != .integer or schema.integer != 1 or array(doc, "metrics", 5) == null or
        array(doc, "samples", 30) == null or array(doc, "scores", 6) == null) return error.InvalidRun;
    return .{ .bytes = bytes, .doc = doc };
}

const Response = struct {
    bytes: []u8,
    len: usize = 0,
    fn write(raw: ?*anyopaque, offset: u64, chunk: []const u8) r4os.app_web.PostStreamAction {
        const self: *@This() = @ptrCast(@alignCast(raw orelse return .fail));
        if (offset != @as(u64, @intCast(self.len)) or chunk.len > self.bytes.len - self.len) return .fail;
        @memcpy(self.bytes[self.len..][0..chunk.len], chunk);
        self.len += chunk.len;
        return .accept;
    }
};
const FileSource = struct {
    sys: r4os.r4sys.Context,
    path: [:0]const u8,
    fn read(raw: ?*anyopaque, offset: u64, output: []u8) i64 {
        const self: *@This() = @ptrCast(@alignCast(raw orelse return -3));
        if (offset > std.math.maxInt(u32)) return -3;
        const count = self.sys.fileReadAt(self.path, @intCast(offset), output);
        return if (count < 0) -3 else count;
    }
};

fn putRun(allocator: std.mem.Allocator, web: *r4os.app_web.WebTransport, sys: *const r4os.r4sys.Context, address: []const u8, headers: []const u8, path: [:0]const u8, length: u64, response_bytes: []u8) !Value {
    var source = FileSource{ .sys = sys.*, .path = path };
    var response = Response{ .bytes = response_bytes };
    var response_headers: [r4os.http.max_header_bytes]u8 = undefined;
    var io: [16 * 1024]u8 = undefined;
    var upload_buffer: [8 * 1024]u8 = undefined;
    var tls: [r4os.app_web.tls_scratch_bytes]u8 = undefined;
    var stream: r4os.app_web.PostStream = undefined;
    const timeout = r4os.time_contract.timeoutFinite(r4os.time_contract.durationFromNanoseconds(timeout_ns));
    var report = stream.init(web, address, .{ .headers = &response_headers, .io = &io, .upload = &upload_buffer, .tls = &tls }, .{ .context = &response, .write = Response.write }, .{
        .request = .{ .method = .put, .redirect = .manual, .timeout = timeout, .headers = headers, .content_type = "application/json" },
        .request_length = length,
        .reader = FileSource.read,
        .reader_context = &source,
    });
    defer {
        if (!stream.canRelease()) _ = stream.close(timeout);
        std.crypto.secureZero(u8, &stream.headers);
    }
    if (report.state == .failed or report.state == .cancelled) return error.UploadTransport;
    while (report.state == .ready or report.state == .paused) report = stream.run();
    const closed = stream.canRelease() or stream.close(timeout);
    try requireStatus(sys, "PUT", report.status orelse 0, 200, 201);
    if (report.state != .complete or !report.http_complete or !closed or report.request_body_confirmed != length) return error.UploadIncomplete;
    const parsed = try std.json.parseFromSlice(Value, allocator, response.bytes[0..response.len], .{ .allocate = .alloc_always });
    return parsed.value;
}

fn verifyClaim(value: Value, id: []const u8, hash: []const u8) !void {
    if (!isTrue(value, "stored") or !same(value, "host_id", id)) return error.ClaimMismatch;
    const host = field(value, "host") orelse return error.ClaimMismatch;
    const binding = field(value, "identity") orelse return error.ClaimMismatch;
    if (!same(host, "host_id", id) or !same(binding, "method", identity_api.method) or !same(binding, "hash", hash)) return error.ClaimMismatch;
}
fn run(app: *r4os.App, path: [:0]const u8, expected_sha: ?[]const u8, phase: *[]const u8) !void {
    const sys = app.system();
    var arena = std.heap.ArenaAllocator.init(sys.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();
    phase.* = "local file";
    const local = try loadRun(allocator, &sys, path, expected_sha);
    const id = string(local.doc, "run_id").?;
    const host_id = string(local.doc, "host_id").?;
    const identity = try identity_api.derive(app);
    if (!std.mem.eql(u8, host_id, &identity.host_id)) return error.WrongPhysicalHost;
    phase.* = "registration";
    const services = app.services() orelse return error.ServiceApiUnavailable;
    const client = r4os.server_access.Client{ .services = services };
    const target = switch (client.ensure(.benchmarks)) {
        .response => |value| value,
        else => return error.RegistrationUnavailable,
    };
    if (target.code != @intFromEnum(r4os.server_access.Code.ok) or target.port == 0) {
        const code = std.enums.fromInt(r4os.server_access.Code, target.code);
        sys.write("SPECTRA STANDARD registration code: ");
        sys.println(if (code) |known| @tagName(known) else "invalid_target");
        return error.RegistrationRejected;
    }
    var bearer = try r4os.server_credentials.load(&sys, .benchmark_bearer);
    defer bearer.clear();
    var authorization: [320]u8 = undefined;
    defer std.crypto.secureZero(u8, &authorization);
    const headers = try std.fmt.bufPrint(&authorization, "Authorization: Bearer {s}\naccept:application/json\n", .{bearer.bytes()});
    var web = app.web() orelse return error.WebUnavailable;
    var claim_url_buf: [200]u8 = undefined;
    const claim_url = try std.fmt.bufPrint(&claim_url_buf, "https://{d}.{d}.{d}.{d}:{d}/api/v1/hosts/{s}/claim", .{
        target.target_ip[0], target.target_ip[1], target.target_ip[2], target.target_ip[3], target.port, host_id,
    });
    const display = try std.fmt.allocPrint(allocator, "R4OS {s}", .{host_id[0..16]});
    const claim_body = try std.json.Stringify.valueAlloc(allocator, .{
        .display_name = display,
        .identity = .{ .method = identity_api.method, .hash = identity.hash[0..] },
    }, .{});
    if (claim_body.len > 4096) return error.ClaimBodySize;
    phase.* = "claim";
    var raw_response: [r4os.http.max_header_bytes]u8 = undefined;
    var small_body: [8192]u8 = undefined;
    var tls: [r4os.app_web.tls_scratch_bytes]u8 = undefined;
    const timeout = r4os.time_contract.timeoutFinite(r4os.time_contract.durationFromNanoseconds(timeout_ns));
    const claim = web.fetch(claim_url, &raw_response, &small_body, &tls, .{
        .method = .post,
        .body = claim_body,
        .content_type = "application/json",
        .headers = headers,
        .redirect = .error_mode,
        .redirect_limit = 0,
        .timeout = timeout,
    });
    const claim_reply = switch (claim) {
        .response => |reply| reply,
        .failure => return error.ClaimTransport,
    };
    if (!claim_reply.secure) return error.InsecureResponse;
    try requireStatus(&sys, "claim", claim_reply.status, 200, 201);
    const claimed = try std.json.parseFromSlice(Value, allocator, claim_reply.body, .{ .allocate = .alloc_always });
    try verifyClaim(claimed.value, host_id, &identity.hash);

    phase.* = "PUT";
    var run_url_buf: [200]u8 = undefined;
    const run_url = try url(&run_url_buf, target.target_ip, target.port, "benchmark-runs", id);
    var put_body: [8192]u8 = undefined;
    const put = try putRun(allocator, &web, &sys, run_url, headers, path, local.bytes.len, &put_body);
    if (!isTrue(put, "stored") or !same(put, "run_id", id) or field(put, "score_validation") == null or
        (scoring_api.applicable(local.doc) and field(put, "server_scoring") == null)) return error.PutMismatch;

    phase.* = "GET";
    // fetch keeps the complete wire response in raw_response as well as the
    // decoded body. A run can exceed the small claim/header buffer.
    const get_raw = try allocator.alloc(u8, max_run_bytes + r4os.http.max_header_bytes);
    const get_body = try allocator.alloc(u8, max_run_bytes);
    const get = web.fetch(run_url, get_raw, get_body, &tls, .{
        .headers = headers,
        .redirect = .error_mode,
        .redirect_limit = 0,
        .timeout = timeout,
    });
    const readback = switch (get) {
        .response => |reply| reply,
        .failure => |reason| {
            sys.write("SPECTRA STANDARD GET transport: ");
            sys.println(@tagName(reason));
            return error.ReadbackTransport;
        },
    };
    if (!readback.secure) return error.InsecureResponse;
    try requireStatus(&sys, "GET", readback.status, 200, 200);
    const stored = try std.json.parseFromSlice(Value, allocator, readback.body, .{ .allocate = .alloc_always });
    if (!same(stored.value, "run_id", id) or !same(stored.value, "host_id", host_id) or !same(stored.value, "comparison_key", string(local.doc, "comparison_key") orelse "")) return error.ReadbackMismatch;
    const sample_total = field(stored.value, "sample_total") orelse return error.ReadbackMismatch;
    if (sample_total != .integer or sample_total.integer != 30) return error.ReadbackMismatch;
    if (readback_api.firstMismatch(local.doc, stored.value)) |mismatch| {
        sys.write("SPECTRA STANDARD GET mismatch: ");
        sys.write(mismatch.group);
        sys.write("[");
        sys.printU64(mismatch.index);
        sys.write("].");
        sys.println(mismatch.field);
        return error.ReadbackMismatch;
    }
    const validation = field(stored.value, "score_validation") orelse return error.ReadbackMismatch;
    const score_status = string(validation, "status") orelse return error.ReadbackMismatch;
    const put_validation = field(put, "score_validation") orelse return error.PutMismatch;
    if (string(put_validation, "status") == null) return error.PutMismatch;
    sys.write("SPECTRA STANDARD score validation: ");
    sys.println(score_status);
    if (scoring_api.applicable(local.doc)) {
        const submitted = try scoring_api.verify(local.doc, put);
        const confirmed = try scoring_api.verify(local.doc, stored.value);
        if (!submitted.matches(confirmed)) return error.ServerScoringChanged;
        sys.println("SPECTRA STANDARD server scoring: valid");
        sys.write("SPECTRA STANDARD server baseline: ");
        sys.println(confirmed.baseline_id);
        sys.write("SPECTRA STANDARD server overall: ");
        sys.println(confirmed.overall());
    } else {
        if (!same(put_validation, "status", score_status)) return error.ReadbackMismatch;
        if (std.mem.eql(u8, score_status, "invalid") or std.mem.eql(u8, score_status, "pending"))
            return error.ServerScoreNotValid;
    }
    sys.write("SPECTRA STANDARD upload confirmed: ");
    sys.println(id);
}

pub fn upload(app: *r4os.App, path: [:0]const u8, expected_sha: ?[]const u8) i32 {
    var phase: []const u8 = "preflight";
    run(app, path, expected_sha, &phase) catch |err| {
        const sys = app.system();
        sys.write("SPECTRA STANDARD upload ");
        sys.write(phase);
        sys.write(": ");
        sys.println(@errorName(err));
        sys.write("SPECTRA STANDARD local run retained: ");
        sys.println(path);
        return 1;
    };
    return 0;
}
