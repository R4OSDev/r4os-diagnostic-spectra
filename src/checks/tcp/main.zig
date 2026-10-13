const r4os = @import("r4os");

const App = struct {
    sys: r4os.r4sys.Context,
    net: r4os.r4net.Context,

    fn init(r4_app: *r4os.App) ?App {
        return .{
            .sys = r4_app.system(),
            .net = r4_app.networkLowLevel() orelse return null,
        };
    }
};

pub fn r4_app_main(app: *r4os.App) i32 {
    const ctx = App.init(app) orelse return r4os.abi.err_no_group;
    return if (testTcpPerformance(&ctx)) 0 else 1;
}

fn testTcpPerformance(app: *const App) bool {
    var info: r4os.abi.TcpPerformanceInfo = .{};
    if (app.net.tcpPerformance(&info) <= 0) return failBool(app, "tcp performance query");
    var summary: r4os.abi.TcpSummary = .{};
    if (app.net.tcpSummary(&summary) <= 0) return failBool(app, "tcp performance summary");
    const catalog_bytes = @as(u64, info.catalog_capacity) * @as(u64, info.local_mss);
    const outstanding_limit = @as(u64, info.catalog_capacity) * @as(u64, summary.max_connections);
    const ok = info.version == 1 and
        info.size == @sizeOf(r4os.abi.TcpPerformanceInfo) and
        info.local_mss == 1460 and
        catalog_bytes >= 65_535 and
        info.delayed_ack_ms > 0 and info.delayed_ack_ms <= 500 and
        info.write_completed_bytes <= info.write_requested_bytes and
        info.outstanding_segments <= outstanding_limit and
        info.service_poll_skips <= info.service_poll_requests;
    if (!ok) return failBool(app, "tcp performance contract");

    app.sys.write("SPECTRA TCP tcp-performance: OK mss=");
    app.sys.printU64(info.local_mss);
    app.sys.write(" catalog=");
    app.sys.printU64(info.catalog_capacity);
    app.sys.write(" write=");
    app.sys.printU64(info.write_completed_bytes);
    app.sys.write("/");
    app.sys.printU64(info.write_requested_bytes);
    app.sys.write(" segments=");
    app.sys.printU64(info.write_segments);
    app.sys.write(" outstanding=");
    app.sys.printU64(info.outstanding_segments);
    app.sys.write("/");
    app.sys.printU64(info.outstanding_bytes);
    app.sys.write(" ack=pure/");
    app.sys.printU64(info.pure_ack_tx);
    app.sys.write(",delayed/");
    app.sys.printU64(info.delayed_ack_tx);
    app.sys.write(",coalesced/");
    app.sys.printU64(info.ack_coalesced);
    app.sys.write(" polls=");
    app.sys.printU64(info.adapter_poll_rounds);
    app.sys.write(" skip=");
    app.sys.printU64(info.service_poll_skips);
    app.sys.write("/");
    app.sys.printU64(info.service_poll_requests);
    app.sys.write(" retransmits=");
    app.sys.printU64(info.retransmits);
    app.sys.write("\r\n");
    return true;
}

fn failBool(app: *const App, msg: []const u8) bool {
    app.sys.write("SPECTRA TCP failed: ");
    app.sys.write(msg);
    app.sys.write("\r\n");
    return false;
}

