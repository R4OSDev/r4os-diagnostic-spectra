const std = @import("std");
const r4os = @import("r4os");
const abi = r4os.abi;
const cli = @import("cli.zig");
const Output = @import("output.zig").Output;

var boot_buffer: [abi.boot_log_buffer_size]u8 = undefined;

fn boot(app: *r4os.App, out: *Output) i32 {
    const sys = app.system();
    for (0..3) |_| {
        const before = sys.bootLogInfo() orelse break;
        if (before.length > boot_buffer.len) break;
        const got = sys.bootLogRead(0, boot_buffer[0..before.length]);
        const after = sys.bootLogInfo() orelse break;
        if (got < 0 or got != before.length) continue;
        if (before.total_written != after.total_written or before.length != after.length or before.dropped_bytes != after.dropped_bytes) continue;
        out.record("source", "bootlog", 0, before);
        out.record("quality", "bootlog", 0, .{
            .severity = @as([]const u8, "unknown: legacy text"),
            .time_basis = @as([]const u8, "snapshot only; no per-message clock"),
            .start_may_be_fragment = before.dropped_bytes != 0,
        });
        out.message("bootlog", boot_buffer[0..@intCast(got)], false);
        return 0;
    }
    out.unavailable("bootlog", "source unavailable or changed during three bounded snapshot attempts");
    return 1;
}

fn service(app: *r4os.App, out: *Output) i32 {
    const sys = app.system();
    const allocator = app.lowLevel().allocator();
    for (0..3) |_| {
        var status: abi.LogServiceStatus = .{};
        if (sys.logServiceStatus(&status) != abi.service_api_result_ok) break;
        if (status.record_capacity > abi.log_service_max_records) break;
        const records = allocator.alloc(abi.LogServiceRecord, status.record_capacity) catch break;
        defer allocator.free(records);
        var count: usize = 0;
        var query = abi.LogServiceRecordQuery{ .source_id = abi.log_service_source_bootlog };
        var complete = false;
        var revision: ?u32 = null;
        while (count <= records.len) {
            var page: abi.LogServiceRecordPage = .{};
            if (sys.logServiceRecords(&query, &page) != abi.service_api_result_ok) break;
            if (revision) |expected| { if (page.revision != expected) break; } else revision = page.revision;
            if (page.count > page.records.len or count + page.count > records.len) break;
            @memcpy(records[count..][0..page.count], page.records[0..page.count]);
            count += page.count;
            if (page.flags & abi.log_service_page_flag_more == 0) { complete = count == page.total_matches; break; }
            if (page.next_index <= query.start_index) break;
            query.start_index = page.next_index;
        }
        if (!complete) continue;
        out.record("source", "logsvc_kernel", 0, status);
        out.record("quality", "logsvc_kernel", 0, .{
            .revision = revision, .count = count, .complete = true,
            .time_basis = @as([]const u8, "event ticks when LOGSVC collected legacy kernel text; not original event time"),
            .severity = @as([]const u8, "LOGSVC classification of legacy text"),
        });
        for (records[0..count]) |record| out.record("log", "logsvc_kernel", record.sequence, record);
        return 0;
    }
    out.unavailable("logsvc_kernel", "LOGSVC absent or no complete stable page set after three attempts");
    return 1;
}

pub fn run(app: *r4os.App, group: []const u8, out: *Output) i32 {
    if (cli.same(group, "BOOT")) return boot(app, out);
    if (cli.same(group, "SERVICE")) return service(app, out);
    out.unavailable("logs", "unknown source; use BOOT or SERVICE");
    return 2;
}
