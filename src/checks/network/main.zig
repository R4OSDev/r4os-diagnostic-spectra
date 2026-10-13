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

pub fn r4_app_main(r4_app: *r4os.App) i32 {
    var app = App.init(r4_app) orelse return r4os.abi.err_no_group;
    if (!true) {
        app.sys.println("SPECTRA NETWORK api: failed");
        return 1;
    }

    const args = trim(zSlice(app.sys.argsRaw()));
    if (args.len == 0 or isAllMode(args)) return runAll(&app);
    if (isHelp(args)) {
        app.sys.println("Usage: SPECTRA NETWORK [TIMING|BACKPRESSURE|CLEANUP|POWER|LIFECYCLE|RESET|DRIVER|ENVIRONMENT|LIMIT|CORPUS|NEGATIVE|R4P|ERRORS|/SELFTEST]");
        return 0;
    }
    const op = modeFromArgs(args) orelse {
        app.sys.println("SPECTRA NETWORK mode: failed");
        return 1;
    };
    return runMode(&app, op);
}

fn runAll(app: *const App) i32 {
    var failed = false;
    if (runMode(app, r4os.abi.net_diag_op_timing) != 0) failed = true;
    if (runMode(app, r4os.abi.net_diag_op_backpressure) != 0) failed = true;
    if (runMode(app, r4os.abi.net_diag_op_cleanup) != 0) failed = true;
    if (runMode(app, r4os.abi.net_diag_op_power) != 0) failed = true;
    if (runMode(app, r4os.abi.net_diag_op_lifecycle) != 0) failed = true;
    if (runMode(app, r4os.abi.net_diag_op_reset) != 0) failed = true;
    if (runMode(app, r4os.abi.net_diag_op_driver) != 0) failed = true;
    if (runMode(app, r4os.abi.net_diag_op_environment) != 0) failed = true;
    if (runMode(app, r4os.abi.net_diag_op_limit) != 0) failed = true;
    if (runMode(app, r4os.abi.net_diag_op_corpus) != 0) failed = true;
    if (runMode(app, r4os.abi.net_diag_op_negative) != 0) failed = true;
    if (runMode(app, r4os.abi.net_diag_op_r4p) != 0) failed = true;
    if (runMode(app, r4os.abi.net_diag_op_errors) != 0) failed = true;
    app.sys.write("SPECTRA NETWORK selftest: ");
    app.sys.println(if (failed) "failed" else "ok");
    return if (failed) 1 else 0;
}

fn runMode(app: *const App, op: u32) i32 {
    var result: r4os.abi.NetDiagResult = .{};
    const rc = app.net.netDiagRun(op, &result);
    var detail: r4os.abi.NetDetailSnapshot = .{};
    if (modeNeedsDetail(op)) {
        _ = app.net.netDetailGet(0, &detail);
    }
    printResult(app, result, detail);
    return if (rc == r4os.abi.net_diag_ok) 0 else 1;
}

fn modeNeedsDetail(op: u32) bool {
    return op == r4os.abi.net_diag_op_limit or
        op == r4os.abi.net_diag_op_corpus or
        op == r4os.abi.net_diag_op_negative;
}

fn printResult(app: *const App, result: r4os.abi.NetDiagResult, detail: r4os.abi.NetDetailSnapshot) void {
    switch (result.op) {
        r4os.abi.net_diag_op_timing => printTiming(app, result),
        r4os.abi.net_diag_op_backpressure => printBackpressureResult(app, result),
        r4os.abi.net_diag_op_cleanup => printCleanupResult(app, result, "cleanup/lifecycle"),
        r4os.abi.net_diag_op_power => printPower(app, result),
        r4os.abi.net_diag_op_lifecycle => printLifecycle(app, result),
        r4os.abi.net_diag_op_reset => printCleanupResult(app, result, "adapter reset"),
        r4os.abi.net_diag_op_driver => printDriver(app, result),
        r4os.abi.net_diag_op_environment => printEnvironment(app, result),
        r4os.abi.net_diag_op_limit => printLimit(app, result, detail),
        r4os.abi.net_diag_op_corpus => printCorpus(app, result, detail),
        r4os.abi.net_diag_op_negative => printNegative(app, result, detail),
        r4os.abi.net_diag_op_r4p => printR4p(app, result),
        r4os.abi.net_diag_op_errors => printErrors(app, result),
        else => printStatusLine(app, "mode", result.status),
    }
}

fn printTiming(app: *const App, result: r4os.abi.NetDiagResult) void {
    printStatusLine(app, "timing/status", result.status);
    app.sys.write("Timing: ticks=");
    printU(app, result.timing.ticks);
    app.sys.write(" hz=");
    printU(app, result.timing.hz);
    app.sys.write(" arp_ttl=");
    printU(app, result.timing.arp_cache_ttl_ticks);
    app.sys.write(" arp_resolve=");
    printU(app, result.timing.arp_resolve_timeout_ticks);
    app.sys.write(" dhcp=");
    printU(app, result.timing.dhcp_timeout_ticks);
    app.sys.write(" dns=");
    printU(app, result.timing.dns_timeout_ticks);
    app.sys.write(" tcp_listen=");
    printU(app, result.timing.tcp_listen_timeout_ticks);
    app.sys.write(" tcp_retx=");
    printU(app, result.timing.tcp_retransmit_timeout_ticks);
    app.sys.write(" tcp_time_wait=");
    printU(app, result.timing.tcp_time_wait_ticks);
    app.sys.write(" svc_op=");
    printU(app, result.timing.service_operation_timeout_ticks);
    app.sys.write(" states=");
    printU(app, result.timing.operation_status_count);
    app.sys.write("\r\n");
}

fn printBackpressureResult(app: *const App, result: r4os.abi.NetDiagResult) void {
    printStatusLine(app, "backpressure/status", result.status);
    printBackpressure(app, result.backpressure);
}

fn printCleanupResult(app: *const App, result: r4os.abi.NetDiagResult, label: []const u8) void {
    printStatusLine(app, label, result.status);
    printCleanup(app, result.cleanup);
}

fn printLifecycle(app: *const App, result: r4os.abi.NetDiagResult) void {
    printStatusLine(app, "link lifecycle", result.status);
    printCleanup(app, result.cleanup);
    printSocketLifecycle(app);
}

fn printSocketLifecycle(app: *const App) void {
    if (!app.net.hasFn("tcp_summary")) {
        app.sys.println("Socket lifecycle: unsupported");
        return;
    }

    var tcp: r4os.abi.NetServiceTcpStatus = .{};
    if (app.net.tcpServiceStatusRaw(&tcp) == 0) {
        app.sys.write("TCP lifecycle: handles=");
        printU(app, tcp.handle_count);
        app.sys.write("/");
        printU(app, tcp.max_handles);
        app.sys.write(" stale=");
        printU(app, tcp.stale_handles_reaped);
        app.sys.write("/");
        printU(app, tcp.stale_tombstones);
        app.sys.write(" read_timeout=");
        printU(app, tcp.read_wait_timeouts);
        app.sys.write(" accept_timeout=");
        printU(app, tcp.accept_wait_timeouts);
        app.sys.write(" would_block=");
        printU(app, tcp.lifecycle_would_block);
        app.sys.write(" close_cancel=");
        printU(app, tcp.close_cancelled);
        app.sys.write(" last=");
        app.sys.write(app.net.netSocketLifecycleName(tcp.last_lifecycle_cause));
        app.sys.write("\r\n");
    }

    var udp: r4os.abi.NetServiceUdpStatus = .{};
    if (app.net.udpServiceStatusRaw(&udp) == 0) {
        app.sys.write("UDP lifecycle: sockets=");
        printU(app, udp.active_sockets);
        app.sys.write("/");
        printU(app, udp.max_sockets);
        app.sys.write(" would_block=");
        printU(app, udp.lifecycle_would_block);
        app.sys.write(" close=");
        printU(app, udp.lifecycle_local_close);
        app.sys.write(" bad_handle=");
        printU(app, udp.lifecycle_bad_handle);
        app.sys.write(" drops=");
        printU(app, udp.lifecycle_dropped);
        app.sys.write(" last=");
        app.sys.write(app.net.netSocketLifecycleName(udp.last_lifecycle_cause));
        app.sys.write("\r\n");
    }
}

fn printPower(app: *const App, result: r4os.abi.NetDiagResult) void {
    printStatusLine(app, "power cleanup", result.status);
    app.sys.write("Power: tests=");
    printU(app, result.tests);
    app.sys.write(" cases=");
    printU(app, result.cases);
    app.sys.write("\r\n");
    printCleanup(app, result.cleanup);
}

fn printDriver(app: *const App, result: r4os.abi.NetDiagResult) void {
    printStatusLine(app, "driver lifecycle", result.status);
    app.sys.write("Driver lifecycle: tests=");
    printU(app, result.driver.tests);
    app.sys.write(" cases=");
    printU(app, result.driver.cases);
    app.sys.write("\r\n");
    printCleanup(app, result.cleanup);
}

fn printEnvironment(app: *const App, result: r4os.abi.NetDiagResult) void {
    printStatusLine(app, "environment contract", result.status);
    app.sys.write("Environment: tests=");
    printU(app, result.tests);
    app.sys.write(" cases=");
    printU(app, result.cases);
    app.sys.write("\r\n");
    printR4pLine(app, result.r4p);
}

fn printLimit(app: *const App, result: r4os.abi.NetDiagResult, detail: r4os.abi.NetDetailSnapshot) void {
    printStatusLine(app, "limits", result.status);
    app.sys.write("Limits: tests=");
    printU(app, result.tests);
    app.sys.write(" cases=");
    printU(app, result.cases);
    app.sys.write("\r\n");
    printBackpressure(app, result.backpressure);
    app.sys.write("UDP: drops=");
    printU(app, detail.udp.dropped_length + result.backpressure.udp_drops);
    app.sys.write(" last=");
    printFixed(app, detail.udp.last_error[0..]);
    app.sys.write("\r\n");
    app.sys.write("TCP: rx_drops=");
    printU(app, detail.tcp.rx_drops);
    app.sys.write(" checksum=");
    printU(app, detail.tcp.checksum_errors);
    app.sys.write("\r\n");
    app.sys.write("IPC: drops=");
    printU(app, result.backpressure.ipc_service_drops);
    app.sys.write(" queued=");
    printU(app, result.backpressure.ipc_service_queued);
    app.sys.write("/");
    printU(app, result.backpressure.ipc_service_queue_limit);
    app.sys.write("\r\n");
}

fn printCorpus(app: *const App, result: r4os.abi.NetDiagResult, detail: r4os.abi.NetDetailSnapshot) void {
    printStatusLine(app, "corpus", result.status);
    app.sys.write("Corpus: tests=");
    printU(app, result.tests);
    app.sys.write(" cases=");
    printU(app, result.cases);
    app.sys.write("\r\n");
    app.sys.write("Ethernet: drop_short=");
    printU(app, detail.ethernet.dropped_short);
    app.sys.write(" unknown=");
    printU(app, detail.ethernet.unknown_ethertype);
    app.sys.write("\r\n");
    app.sys.write("ARP: malformed=");
    printU(app, detail.arp.malformed);
    app.sys.write("\r\n");
    app.sys.write("IPv4: short=");
    printU(app, detail.ipv4.dropped_short);
    app.sys.write(" version=");
    printU(app, detail.ipv4.dropped_version);
    app.sys.write(" checksum=");
    printU(app, detail.ipv4.dropped_checksum);
    app.sys.write(" fragment=");
    printU(app, detail.ipv4.dropped_fragment);
    app.sys.write("\r\n");
    app.sys.write("ICMP: bad=");
    printU(app, detail.icmp.malformed);
    app.sys.write(" csum=");
    printU(app, detail.icmp.checksum_errors);
    app.sys.write("\r\n");
    app.sys.write("UDP: short=");
    printU(app, detail.udp.dropped_short);
    app.sys.write(" length=");
    printU(app, detail.udp.dropped_length);
    app.sys.write(" checksum=");
    printU(app, detail.udp.checksum_errors);
    app.sys.write("\r\n");
    app.sys.write("DHCP: malformed=");
    printU(app, detail.dhcp.malformed);
    app.sys.write("\r\n");
    app.sys.write("DNS: malformed=");
    printU(app, detail.dns.malformed);
    app.sys.write("\r\n");
    app.sys.write("TCP: csum=");
    printU(app, detail.tcp.checksum_errors);
    app.sys.write("\r\n");
}

fn printNegative(app: *const App, result: r4os.abi.NetDiagResult, detail: r4os.abi.NetDetailSnapshot) void {
    printStatusLine(app, "negative paths", result.status);
    app.sys.write("Negative: tests=");
    printU(app, result.tests);
    app.sys.write(" cases=");
    printU(app, result.cases);
    app.sys.write("\r\n");
    app.sys.write("ARP: resolve_timeout=");
    printU(app, detail.arp.resolve_timeouts);
    app.sys.write(" pending_timeout=");
    printU(app, detail.arp.pending_timeouts);
    app.sys.write(" pending_drop=");
    printU(app, detail.arp.pending_drops);
    app.sys.write("\r\n");
    app.sys.write("DNS: timeouts=");
    printU(app, detail.dns.timeouts);
    app.sys.write(" last=");
    printFixed(app, detail.dns.last_error[0..]);
    app.sys.write("\r\n");
    app.sys.write("TCP: rst=");
    printU(app, detail.tcp.rst_rx);
    app.sys.write(" timeouts=");
    printU(app, detail.tcp.timeouts);
    app.sys.write("\r\n");
}

fn printR4p(app: *const App, result: r4os.abi.NetDiagResult) void {
    printStatusLine(app, "r4p runtime", result.status);
    printR4pLine(app, result.r4p);
}

fn printErrors(app: *const App, result: r4os.abi.NetDiagResult) void {
    printStatusLine(app, "error visibility", result.status);
    app.sys.write("Errors: total=");
    printU(app, result.errors.total);
    app.sys.write(" packet=");
    printU(app, result.errors.packet_errors);
    app.sys.write(" service=");
    printU(app, result.errors.service_errors);
    app.sys.write(" adapter=");
    printU(app, result.errors.adapter_errors);
    app.sys.write(" tx=");
    printU(app, result.errors.tx_failures);
    app.sys.write(" proto=");
    printU(app, result.errors.protocol_errors);
    app.sys.write(" r4p=");
    printU(app, result.errors.r4p_dispatch_failures);
    app.sys.write(" last_adapter=");
    printFixed(app, result.errors.last_adapter_error[0..]);
    app.sys.write(" last_protocol=");
    printFixed(app, result.errors.last_protocol_error[0..]);
    app.sys.write("\r\n");
}

fn printBackpressure(app: *const App, status: r4os.abi.NetDiagBackpressure) void {
    app.sys.write("Backpressure: packets=");
    printU(app, status.packet_pool_used);
    app.sys.write("/");
    printU(app, status.packet_pool_limit);
    app.sys.write(" app=");
    printU(app, status.app_ipv4_queued);
    app.sys.write("/");
    printU(app, status.app_ipv4_queue_limit);
    app.sys.write(" udp=");
    printU(app, status.udp_queued_packets);
    app.sys.write("/");
    printU(app, status.udp_queue_limit_total);
    app.sys.write(" tcp=");
    printU(app, status.tcp_active_connections);
    app.sys.write("/");
    printU(app, status.tcp_connection_limit);
    app.sys.write(" ipcq=");
    printU(app, status.ipc_service_queued);
    app.sys.write("/");
    printU(app, status.ipc_service_queue_limit);
    app.sys.write(" tx_fail=");
    printU(app, status.tx_failures);
    app.sys.write(" tx_no_adapter=");
    printU(app, status.tx_no_adapter);
    app.sys.write(" tx_busy=");
    printU(app, status.tx_busy);
    app.sys.write(" tx_large=");
    printU(app, status.tx_too_large);
    app.sys.write(" tx_backend=");
    printU(app, status.tx_backend_error);
    app.sys.write(" tx_last=");
    printFixed(app, status.tx_last_result[0..]);
    app.sys.write(" nonblock=");
    printFixed(app, status.nonblocking_empty_status[0..]);
    app.sys.write(" res_queue_full=");
    printU(app, status.resource_queue_full);
    app.sys.write(" res_drops=");
    printU(app, status.resource_packet_drops);
    app.sys.write(" res_bufsmall=");
    printU(app, status.resource_buffer_small);
    app.sys.write(" res_retry=");
    printU(app, status.resource_retries);
    app.sys.write(" res_timeout=");
    printU(app, status.resource_timeouts);
    app.sys.write(" res_cancel=");
    printU(app, status.resource_cancels);
    app.sys.write(" res_busy=");
    printU(app, status.resource_backend_busy);
    app.sys.write("\r\n");
}

fn printCleanup(app: *const App, status: r4os.abi.NetDiagCleanup) void {
    app.sys.write("Cleanup: runs=");
    printU(app, status.runs);
    app.sys.write(" link_down=");
    printU(app, status.link_down_cleanups);
    app.sys.write(" reset=");
    printU(app, status.adapter_reset_cleanups);
    app.sys.write(" unreg=");
    printU(app, status.adapter_unregister_cleanups);
    app.sys.write(" poweroff=");
    printU(app, status.poweroff_cleanups);
    app.sys.write(" reboot=");
    printU(app, status.reboot_cleanups);
    app.sys.write(" udp=");
    printU(app, status.udp_sockets_closed);
    app.sys.write(" tcp_conn=");
    printU(app, status.tcp_connections_aborted);
    app.sys.write(" tcp_listen=");
    printU(app, status.tcp_listeners_closed);
    app.sys.write(" dhcp=");
    printU(app, status.dhcp_operations_cancelled);
    app.sys.write(" dns=");
    printU(app, status.dns_operations_cancelled);
    app.sys.write(" last=");
    printFixed(app, status.last_reason[0..]);
    app.sys.write("\r\n");
}

fn printR4pLine(app: *const App, status: r4os.abi.NetDiagR4p) void {
    app.sys.write("R4P runtime: active=");
    printU(app, status.active);
    app.sys.write("/");
    printU(app, status.protocol_count);
    app.sys.write(" missing=");
    printU(app, status.missing);
    app.sys.write(" dispatch_fail=");
    printU(app, status.dispatch_failures);
    app.sys.write(" rx=");
    printU(app, status.r4p_rx);
    app.sys.write(" tx=");
    printU(app, status.r4p_tx);
    app.sys.write(" build=");
    printU(app, status.r4p_build);
    app.sys.write(" classify=");
    printU(app, status.r4p_classify);
    app.sys.write(" control=");
    printU(app, status.r4p_control);
    app.sys.write("\r\n");
}

fn printStatusLine(app: *const App, label: []const u8, status: i32) void {
    app.sys.write("SPECTRA NETWORK ");
    app.sys.write(label);
    app.sys.write(": ");
    app.sys.println(if (status == r4os.abi.net_diag_ok) "ok" else "failed");
}

fn printU(app: *const App, value: anytype) void {
    app.sys.printU64(@intCast(value));
}

fn printFixed(app: *const App, buf: []const u8) void {
    app.sys.write(fixedSlice(buf));
}

fn fixedSlice(buf: []const u8) []const u8 {
    var len: usize = 0;
    while (len < buf.len and buf[len] != 0) : (len += 1) {}
    return buf[0..len];
}

fn modeFromArgs(args: []const u8) ?u32 {
    if (equalsIgnoreCase(args, "TIMING") or slashEquals(args, "TIMING")) return r4os.abi.net_diag_op_timing;
    if (equalsIgnoreCase(args, "BACKPRESSURE") or slashEquals(args, "BACKPRESSURE")) return r4os.abi.net_diag_op_backpressure;
    if (equalsIgnoreCase(args, "CLEANUP") or slashEquals(args, "CLEANUP")) return r4os.abi.net_diag_op_cleanup;
    if (equalsIgnoreCase(args, "POWER") or slashEquals(args, "POWER")) return r4os.abi.net_diag_op_power;
    if (equalsIgnoreCase(args, "LIFECYCLE") or slashEquals(args, "LIFECYCLE")) return r4os.abi.net_diag_op_lifecycle;
    if (equalsIgnoreCase(args, "RESET") or slashEquals(args, "RESET")) return r4os.abi.net_diag_op_reset;
    if (equalsIgnoreCase(args, "DRIVER") or slashEquals(args, "DRIVER")) return r4os.abi.net_diag_op_driver;
    if (equalsIgnoreCase(args, "ENVIRONMENT") or slashEquals(args, "ENVIRONMENT")) return r4os.abi.net_diag_op_environment;
    if (equalsIgnoreCase(args, "LIMIT") or slashEquals(args, "LIMIT")) return r4os.abi.net_diag_op_limit;
    if (equalsIgnoreCase(args, "CORPUS") or slashEquals(args, "CORPUS")) return r4os.abi.net_diag_op_corpus;
    if (equalsIgnoreCase(args, "NEGATIVE") or slashEquals(args, "NEGATIVE")) return r4os.abi.net_diag_op_negative;
    if (equalsIgnoreCase(args, "R4P") or slashEquals(args, "R4P")) return r4os.abi.net_diag_op_r4p;
    if (equalsIgnoreCase(args, "ERRORS") or slashEquals(args, "ERRORS")) return r4os.abi.net_diag_op_errors;
    return null;
}

fn isAllMode(args: []const u8) bool {
    return equalsIgnoreCase(args, "/SELFTEST") or
        equalsIgnoreCase(args, "SELFTEST") or
        equalsIgnoreCase(args, "/ALL") or
        equalsIgnoreCase(args, "ALL") or
        equalsIgnoreCase(args, "/CHECK") or
        equalsIgnoreCase(args, "CHECK");
}

fn isHelp(args: []const u8) bool {
    return equalsIgnoreCase(args, "/?") or equalsIgnoreCase(args, "HELP") or equalsIgnoreCase(args, "/HELP");
}

fn slashEquals(value: []const u8, needle: []const u8) bool {
    return value.len == needle.len + 1 and value[0] == '/' and equalsIgnoreCase(value[1..], needle);
}

fn zSlice(value: [*:0]const u8) []const u8 {
    var len: usize = 0;
    while (value[len] != 0) : (len += 1) {}
    return value[0..len];
}

fn trim(value: []const u8) []const u8 {
    var start: usize = 0;
    var end = value.len;
    while (start < end and isSpace(value[start])) : (start += 1) {}
    while (end > start and isSpace(value[end - 1])) : (end -= 1) {}
    return value[start..end];
}

fn isSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n';
}

fn equalsIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var index: usize = 0;
    while (index < a.len) : (index += 1) {
        if (asciiUpper(a[index]) != asciiUpper(b[index])) return false;
    }
    return true;
}

fn asciiUpper(ch: u8) u8 {
    if (ch >= 'a' and ch <= 'z') return ch - 32;
    return ch;
}
