const std = @import("std");

pub const Command = enum { help, metrics, logs, check, bench };
pub const Format = enum { text, json };
pub const Error = error{ InvalidCommand, InvalidOption, MissingGroup, TooLong, UnclosedQuote };
pub const Request = struct {
    command: Command = .help,
    format: Format = .text,
    group_bytes: [64]u8 = .{0} ** 64,
    group_len: usize = 0,
    args_bytes: [512:0]u8 = .{0} ** 512,
    args_len: usize = 0,
    export_path: [260:0]u8 = .{0} ** 260,
    export_len: usize = 0,
    upload: bool = false,
    run_path: [260:0]u8 = .{0} ** 260,
    run_len: usize = 0,
    count: u32 = 1,
    interval_ms: u32 = 1000,

    pub fn group(self: *const Request) []const u8 {
        return self.group_bytes[0..self.group_len];
    }
    pub fn args(self: *const Request) [:0]const u8 {
        return self.args_bytes[0..self.args_len :0];
    }
};

pub const Tokens = struct {
    input: []const u8,
    at: usize = 0,

    pub fn next(self: *Tokens) Error!?[]const u8 {
        while (self.at < self.input.len and std.ascii.isWhitespace(self.input[self.at])) self.at += 1;
        if (self.at == self.input.len) return null;
        const start = self.at;
        var quoted = false;
        while (self.at < self.input.len) : (self.at += 1) {
            const ch = self.input[self.at];
            if (ch == '"') quoted = !quoted;
            if (!quoted and std.ascii.isWhitespace(ch)) break;
        }
        if (quoted) return error.UnclosedQuote;
        return self.input[start..self.at];
    }
};

pub fn same(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn option(value: []const u8, prefix: []const u8) ?[]const u8 {
    if (value.len < prefix.len or !same(value[0..prefix.len], prefix)) return null;
    return value[prefix.len..];
}

fn unsigned(value: []const u8, minimum: u32, maximum: u32) Error!u32 {
    const result = std.fmt.parseInt(u32, value, 10) catch return error.InvalidOption;
    if (result < minimum or result > maximum) return error.InvalidOption;
    return result;
}

fn groupName(request: *Request, value: []const u8) Error!void {
    if (value.len == 0 or value.len > request.group_bytes.len) return error.TooLong;
    for (value, 0..) |ch, index| {
        if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-')) return error.InvalidOption;
        request.group_bytes[index] = std.ascii.toUpper(ch);
    }
    request.group_len = value.len;
}

pub fn parse(input: []const u8) Error!Request {
    if (input.len > 1024) return error.TooLong;
    var tokens = Tokens{ .input = input };
    var request: Request = .{};
    const command = try tokens.next() orelse return request;
    if (same(command, "HELP") or same(command, "/?") or same(command, "--help")) return request;
    request.command = if (same(command, "METRICS")) .metrics else if (same(command, "LOGS")) .logs else if (same(command, "CHECK")) .check else if (same(command, "BENCH")) .bench else return error.InvalidCommand;
    var count_seen = false;
    var interval_seen = false;
    while (try tokens.next()) |token| {
        if (same(token, "/JSON") or same(token, "--json")) {
            request.format = .json;
        } else if (same(token, "/UPLOAD")) {
            if (request.upload) return error.InvalidOption;
            request.upload = true;
        } else if (option(token, "/EXPORT:")) |raw| {
            const path = if (raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"') raw[1 .. raw.len - 1] else raw;
            if (path.len == 0 or path.len >= request.export_path.len or request.export_len != 0) return error.InvalidOption;
            @memcpy(request.export_path[0..path.len], path);
            request.export_len = path.len;
        } else if (option(token, "/RUN:")) |raw| {
            if (raw.len == 0 or raw.len >= request.run_path.len or request.run_len != 0) return error.InvalidOption;
            @memcpy(request.run_path[0..raw.len], raw);
            request.run_len = raw.len;
        } else if (option(token, "/WATCH:")) |value| {
            if (count_seen) return error.InvalidOption;
            count_seen = true;
            request.count = try unsigned(value, 1, 60);
        } else if (option(token, "/INTERVAL:")) |value| {
            if (interval_seen) return error.InvalidOption;
            interval_seen = true;
            request.interval_ms = try unsigned(value, 100, 60_000);
        } else if (request.group_len == 0 and token.len != 0 and token[0] != '/' and token[0] != '-') {
            try groupName(&request, token);
        } else {
            if (request.command != .check and request.command != .bench) return error.InvalidOption;
            const separator: usize = if (request.args_len == 0) 0 else 1;
            if (request.args_len + separator + token.len > request.args_bytes.len) return error.TooLong;
            if (separator != 0) {
                request.args_bytes[request.args_len] = ' ';
                request.args_len += 1;
            }
            @memcpy(request.args_bytes[request.args_len..][0..token.len], token);
            request.args_len += token.len;
        }
    }
    if ((count_seen or interval_seen) and request.command != .metrics and request.command != .logs) return error.InvalidOption;
    if (request.upload and (request.command != .bench or !(same(request.group(), "STANDARD") or same(request.group(), "UPLOAD")))) return error.InvalidOption;
    if (request.command == .bench and same(request.group(), "UPLOAD")) {
        if (request.run_len == 0 or request.args_len != 0 or !request.upload or request.export_len != 0 or request.format != .text) return error.InvalidOption;
    } else if (request.run_len != 0) return error.InvalidOption;
    if (interval_seen and !count_seen) return error.InvalidOption;
    if (@as(u64, request.count - 1) * request.interval_ms > 60_000) return error.InvalidOption;
    if (request.group_len == 0) {
        if (request.command == .check or request.command == .bench) return error.MissingGroup;
        try groupName(&request, if (request.command == .metrics) "ALL" else "BOOT");
    }
    return request;
}

test "empty invocation is passive and explicit benchmark retains bounded arguments" {
    try std.testing.expectEqual(Command.help, (try parse("")).command);
    try std.testing.expectError(error.MissingGroup, parse("BENCH"));
    const request = try parse("bench clock /REPEAT:5 /WARM /JSON");
    try std.testing.expectEqual(Command.bench, request.command);
    try std.testing.expectEqual(Format.json, request.format);
    try std.testing.expectEqualStrings("CLOCK", request.group());
    try std.testing.expectEqualStrings("/REPEAT:5 /WARM", request.args());
    const upload = try parse("bench standard /UPLOAD /JSON");
    try std.testing.expect(upload.upload);
    try std.testing.expectEqualStrings("", upload.args());
    try std.testing.expectError(error.InvalidOption, parse("bench standard /UPLOAD /UPLOAD"));
    try std.testing.expectError(error.InvalidOption, parse("bench clock /UPLOAD"));
    const retry = try parse("BENCH UPLOAD /RUN:C:\\R4OS\\DATA\\BENCHMARKS\\123e4567-e89b-42d3-a456-426614174000\\RUN.JSON /UPLOAD");
    try std.testing.expectEqualStrings("UPLOAD", retry.group());
    try std.testing.expect(retry.run_len > 0);
    try std.testing.expectError(error.InvalidOption, parse("BENCH UPLOAD"));
    try std.testing.expectError(error.InvalidOption, parse("BENCH STANDARD /RUN:C:\\RUN.JSON"));
}

test "watch requests are finite and restricted to passive commands" {
    const request = try parse("metrics locks /WATCH:4 /INTERVAL:200");
    try std.testing.expectEqual(@as(u32, 4), request.count);
    try std.testing.expectError(error.InvalidOption, parse("check stack /WATCH:2"));
    try std.testing.expectError(error.InvalidOption, parse("logs /WATCH:61"));
    try std.testing.expectError(error.InvalidOption, parse("logs /WATCH:60 /INTERVAL:2000"));
    try std.testing.expectError(error.InvalidOption, parse("logs /INTERVAL:100"));
    const desktop = try parse("metrics desktop /JSON /WATCH:2 /INTERVAL:100 /EXPORT:C:\\TEMP\\DESKTOP.JSON");
    try std.testing.expectEqualStrings("DESKTOP", desktop.group());
    try std.testing.expectEqual(@as(u32, 2), desktop.count);
    try std.testing.expectEqual(Format.json, desktop.format);
}

test "export paths and argument overflow are explicit" {
    const request = try parse("metrics clock /JSON /EXPORT:\"C:\\TEMP\\CLOCK VALUES.JSON\"");
    try std.testing.expectEqualStrings("C:\\TEMP\\CLOCK VALUES.JSON", request.export_path[0..request.export_len]);
    try std.testing.expectError(error.UnclosedQuote, parse("logs /EXPORT:\"missing"));
    try std.testing.expectError(error.TooLong, parse("check thread " ++ "X" ** 513));
    try std.testing.expectError(error.InvalidOption, parse("metrics /unknown"));
}
