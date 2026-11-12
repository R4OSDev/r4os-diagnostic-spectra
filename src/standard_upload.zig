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
    const absolute = try r4os.AbsoluteFilePath.parse(path);
    const files: r4os.app_storage.Files = .{ .sys = sys.* };
    const info = switch (files.metadata(absolute.asZ())) {
        .found => |value| value,
        .missing => return error.RunMissing,
        .failure => return error.RunRead,
    };
    const size = r4os.metadata2.fileSize(&info) orelse return error.RunSize;
    if (info.flags & r4os.abi.file_metadata2_flag_directory != 0 or size == 0 or size > max_run_bytes) return error.RunSize;
    const bytes = try allocator.alloc(u8, @intCast(size));
    const read = switch (files.readDocumentPrefix(absolute.asZ(), bytes, .{ .kind = r4os.abi.timeout_kind_finite, .nanoseconds = timeout_ns })) {
        .value => |value| value,
        .failure => return error.RunRead,
    };
    if (read.bytes != size or read.file_size != size) return error.RunRead;
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
const RunSource = struct {
    // The hash, JSON admission and every transmitted byte refer to this
    // same complete immutable snapshot, held until transport retirement.
    bytes: []const u8,
    fn read(raw: ?*anyopaque, offset: u64, output: []u8) i64 {
        const self: *@This() = @ptrCast(@alignCast(raw orelse return -3));
        if (offset > self.bytes.len) return -3;
        const count = @min(output.len, self.bytes.len - @as(usize, @intCast(offset)));
        @memcpy(output[0..count], self.bytes[@intCast(offset)..][0..count]);
        return @intCast(count);
    }
};

fn putRun(allocator: std.mem.Allocator, web: *r4os.app_web.WebTransport, sys: *const r4os.r4sys.Context, address: []const u8, headers: []const u8, bytes: []const u8, response_bytes: []u8) !Value {
    var source = RunSource{ .bytes = bytes };
    var response = Response{ .bytes = response_bytes };
    var response_headers: [r4os.http.max_header_bytes]u8 = undefined;
    var io: [16 * 1024]u8 = undefined;
    var upload_buffer: [8 * 1024]u8 = undefined;
    var tls: [r4os.app_web.tls_scratch_bytes]u8 = undefined;
    var stream: r4os.app_web.PostStream = undefined;
    const timeout = r4os.time_contract.timeoutFinite(r4os.time_contract.durationFromNanoseconds(timeout_ns));
    var report = stream.init(web, address, .{ .headers = &response_headers, .io = &io, .upload = &upload_buffer, .tls = &tls }, .{ .context = &response, .write = Response.write }, .{
        .request = .{ .method = .put, .redirect = .manual, .timeout = timeout, .headers = headers, .content_type = "application/json" },
        .request_length = bytes.len,
        .reader = RunSource.read,
        .reader_context = &source,
    });
    defer {
        // This synchronous command has no background owner to inherit a
        // pending Close. Keep the snapshot, callbacks and transport buffers
        // alive until the real socket is retired, including on errors.
        // Only disposal is retried here; no request or body is replayed.
        while (!stream.canRelease()) {
            if (!stream.close(timeout)) sys.sleepTicks(1);
        }
        std.crypto.secureZero(u8, &stream.headers);
    }
    if (report.state == .failed or report.state == .cancelled) return error.UploadTransport;
    while (report.state == .ready or report.state == .paused) report = stream.run();
    const closed = stream.canRelease() or stream.close(timeout);
    try requireStatus(sys, "PUT", report.status orelse 0, 200, 201);
    if (report.state != .complete or !report.http_complete or !closed or report.request_body_confirmed != bytes.len) return error.UploadIncomplete;
    const parsed = try std.json.parseFromSlice(Value, allocator, response.bytes[0..response.len], .{ .allocate = .alloc_always });
    return parsed.value;
}

fn verifyClaim(value: Value, id: []const u8, hash: []const u8) !void {
    if (!isTrue(value, "stored") or !same(value, "host_id", id)) return error.ClaimMismatch;
    const host = field(value, "host") orelse return error.ClaimMismatch;
    const binding = field(value, "identity") orelse return error.ClaimMismatch;
    if (!same(host, "host_id", id) or !same(binding, "method", identity_api.method) or !same(binding, "hash", hash)) return error.ClaimMismatch;
}
fn run(app: *r4os.App2, path: [:0]const u8, expected_sha: ?[]const u8, phase: *[]const u8) !void {
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
        return switch (code orelse .bad_request) {
            .credentials, .invalid_secret => error.CredentialsMissing,
            .profile => error.RegistrationProfile,
            .target => error.RegistrationTarget,
            .network, .transport_unavailable, .transport => error.RegistrationTransport,
            .invalid_reply => error.RegistrationReply,
            else => error.RegistrationRejected,
        };
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
    const put = try putRun(allocator, &web, &sys, run_url, headers, local.bytes, &put_body);
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

pub const Report = struct { exit_code: i32 = 0, phase: []const u8 = "preflight", error_name: ?[]const u8 = null };

pub fn validateLocal(app: *r4os.App2, path: [:0]const u8, expected_sha: []const u8) !void {
    const sys = app.system();
    var arena = std.heap.ArenaAllocator.init(sys.allocator());
    defer arena.deinit();
    const local = try loadRun(arena.allocator(), &sys, path, expected_sha);
    const identity = try identity_api.derive(app);
    if (!std.mem.eql(u8, string(local.doc, "host_id") orelse return error.InvalidRun, &identity.host_id)) return error.WrongPhysicalHost;
}

pub fn uploadWithReport(app: *r4os.App2, path: [:0]const u8, expected_sha: ?[]const u8) Report {
    var phase: []const u8 = "preflight";
    run(app, path, expected_sha, &phase) catch |err| return .{ .exit_code = 1, .phase = phase, .error_name = @errorName(err) };
    return .{ .phase = phase };
}

pub fn upload(app: *r4os.App2, path: [:0]const u8, expected_sha: ?[]const u8) i32 {
    const report = uploadWithReport(app, path, expected_sha);
    if (report.error_name) |reason| {
        const sys = app.system();
        sys.write("SPECTRA STANDARD upload ");
        sys.write(report.phase);
        sys.write(": ");
        sys.println(reason);
        sys.write("SPECTRA STANDARD local run retained: ");
        sys.println(path);
    }
    return report.exit_code;
}
