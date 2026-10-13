const r4os = @import("r4os");

const request_id_restart: u32 = 0x53564352;
const request_id_restart_test: u32 = 0x53564354;
const request_id_dns_probe: u32 = 0x53564344;
const request_id_stale_probe: u32 = 0x53564353;
const request_id_udp_probe: u32 = 0x53564355;
const request_id_tcp_probe: u32 = 0x53564350;
const restart_test_udp_port: u16 = 65019;
const restart_test_tcp_port: u16 = 65020;
var worker_probe_app: ?App = null;
var worker_probe_done: bool = false;

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
    const app = App.init(r4_app) orelse return r4os.abi.err_no_group;
    const args = trim(zSlice(app.sys.argsRaw()));

    if (args.len == 0 or equalsIgnoreCase(args, "STATUS")) return showStatus(&app);
    if (equalsIgnoreCase(args, "SELFTEST") or equalsIgnoreCase(args, "/SELFTEST")) return runIpcSelfTest(&app);
    if (equalsIgnoreCase(args, "WORKERS")) return runWorkerProbe(&app);
    if (equalsIgnoreCase(args, "RESTARTTEST")) return runRestartDiagnostic(&app);
    if (equalsIgnoreCase(args, "RESTART")) {
        return runTextRequest(&app, r4os.abi.net_service_op_service_restart, request_id_restart, "SPECTRA IPC restart: ");
    }
    if (equalsIgnoreCase(args, "DRIVERLIFETEST") or equalsIgnoreCase(args, "DRIVERLIFECYCLETEST")) {
        return runDriverLifecycleDiagnostic(&app);
    }

    app.sys.println("Usage: SPECTRA IPC [STATUS|SELFTEST|RESTART|RESTARTTEST|DRIVERLIFETEST]");
    return 1;
}

fn runWorkerProbe(app: *const App) i32 {
    worker_probe_app = app.*;
    @atomicStore(bool, &worker_probe_done, false, .release);
    var thread: r4os.abi.ProgramJoinHandle = .{};
    if (app.sys.threadCreateHandle(waitingDnsProbe, 0, 0, 0, &thread) != r4os.abi.thread_ok) return fail(app, "DNS worker create failed");
    var observed = false;
    const deadline = app.sys.ticks() + 2000;
    while (app.sys.ticks() < deadline) {
        var perf: r4os.abi.IpcPerformanceSummary = .{};
        if (app.net.ipcPerformance(r4os.abi.ipc_channel_net_dns, &perf) > 0 and perf.queue_running != 0) {
            observed = true;
            break;
        }
        if (@atomicLoad(bool, &worker_probe_done, .acquire)) break;
        app.sys.sleepTicks(1);
    }
    var response: [r4os.abi.ipc_max_message_size]u8 = undefined;
    var status: i32 = 0;
    const payload = requestBackend(app, r4os.abi.ipc_channel_net_udp, r4os.abi.net_service_op_udp_status_result, 0x7809_0002, "", &response, &status);
    const independent = observed and payload != null and status == r4os.abi.net_service_result_ok and
        !@atomicLoad(bool, &worker_probe_done, .acquire);
    var code: i32 = -1;
    const joined = app.sys.threadHandleJoin(&thread, 6000, &code);
    if (!independent or joined != r4os.abi.thread_ok or code != 0) return fail(app, "waiting DNS blocked independent UDP status");
    app.sys.println("SPECTRA IPC workers: OK dns=waiting udp=completed join=OK");
    return 0;
}

fn waitingDnsProbe(_: u64) callconv(.c) i32 {
    const app = worker_probe_app orelse return 1;
    var response: [r4os.abi.ipc_max_message_size]u8 = undefined;
    var status: i32 = 0;
    // QEMU's reachable gateway is not a DNS server: one bounded existing
    // DNS timeout holds the real handler while UDP status must complete.
    const payload = [_]u8{ 10, 0, 2, 2 } ++ "r4os-worker-probe.invalid";
    const result = requestBackend(&app, r4os.abi.ipc_channel_net_dns, r4os.abi.net_service_op_dns_resolve_a_server, 0x7809_0001, payload, &response, &status);
    @atomicStore(bool, &worker_probe_done, true, .release);
    return if (result != null) 0 else 1;
}

fn showStatus(app: *const App) i32 {
    app.sys.println("IPC network services");
    printChannel(app, r4os.abi.ipc_channel_net_dhcp, "net.dhcp");
    printChannel(app, r4os.abi.ipc_channel_net_dns, "net.dns");
    printChannel(app, r4os.abi.ipc_channel_net_tcp, "net.tcp");
    printChannel(app, r4os.abi.ipc_channel_net_udp, "net.udp");
    return 0;
}

fn runIpcSelfTest(app: *const App) i32 {
    if (!app.net.hasFn("net_service_request") or !app.net.hasFn("ipc_performance")) return fail(app, "0.69.12 R4NET capability missing");
    if (!drainChannel(app, r4os.abi.ipc_channel_net_dns)) return fail(app, "initial DNS drain failed");

    var before: r4os.abi.IpcPerformanceSummary = .{};
    if (app.net.ipcPerformance(0, &before) <= 0) return fail(app, "performance snapshot failed");
    if (before.worker_started == 0 or before.queue_limit == 0) return fail(app, "IPC worker not active");

    const status_cases = [_]struct { channel: u32, op: u16 }{
        .{ .channel = r4os.abi.ipc_channel_net_dhcp, .op = r4os.abi.net_service_op_dhcp_status_result },
        .{ .channel = r4os.abi.ipc_channel_net_dns, .op = r4os.abi.net_service_op_dns_status_result },
        .{ .channel = r4os.abi.ipc_channel_net_tcp, .op = r4os.abi.net_service_op_tcp_status_result },
        .{ .channel = r4os.abi.ipc_channel_net_udp, .op = r4os.abi.net_service_op_udp_status_result },
    };
    for (status_cases, 0..) |case, case_index| {
        var response: [r4os.abi.ipc_max_message_size]u8 = undefined;
        var status: i32 = 0;
        const payload = requestBackend(app, case.channel, case.op, 0x6901_2000 + @as(u32, @intCast(case_index)), "", response[0..], &status) orelse return fail(app, "network status request failed");
        if (status != r4os.abi.net_service_result_ok or payload.len == 0) return fail(app, "network status response invalid");
        if (app.net.ipcPoll(case.channel) != 0) return fail(app, "targeted response entered raw queue");
    }

    // Eine absichtlich fremde Raw-Antwort bleibt neben dem zielgerichteten
    // Pfad erhalten und wird anschliessend exakt einmal explizit abgeholt.
    const stale_id = request_id_stale_probe + 0x1200;
    if (!queueDnsStatusResponse(app, stale_id)) return fail(app, "stale response enqueue failed");
    if (app.net.ipcClose(r4os.abi.ipc_channel_net_dns) < 0) return fail(app, "close during queued response failed");
    if (app.net.ipcOpen(r4os.abi.ipc_channel_net_dns) < 0) return fail(app, "reopen after queued response failed");
    if (!verifyDirectDnsStatus(app, request_id_dns_probe + 0x1200)) return fail(app, "direct request beside stale response failed");
    if (app.net.ipcPoll(r4os.abi.ipc_channel_net_dns) != 1) return fail(app, "stale response was consumed by direct request");
    var stale_response: [r4os.abi.ipc_max_message_size]u8 = undefined;
    const stale_got = app.net.ipcRecv(r4os.abi.ipc_channel_net_dns, stale_response[0..]);
    if (stale_got < r4os.abi.net_service_header_size or readU32(stale_response[0..@intCast(stale_got)], 12) != stale_id) return fail(app, "stale response identity mismatch");

    // Zu kleine Raw-Empfangspuffer verwerfen nur die betroffene aelteste
    // Nachricht und geben den Queueplatz sofort wieder frei.
    if (!queueDnsStatusResponse(app, stale_id + 1)) return fail(app, "small-buffer response enqueue failed");
    var tiny: [8]u8 = undefined;
    if (app.net.ipcRecv(r4os.abi.ipc_channel_net_dns, tiny[0..]) >= 0) return fail(app, "small-buffer receive did not fail");
    if (app.net.ipcPoll(r4os.abi.ipc_channel_net_dns) != 0) return fail(app, "small-buffer response blocked queue");

    // Acht Raw-Antworten belegen die feste Queue. Der neunte Send muss wie
    // vor 0.69.12 sofort mit Backpressure scheitern, nicht auf sich selbst
    // warten. Danach werden alle acht Antworten wieder abgebaut.
    var fill: u32 = 0;
    while (fill < r4os.abi.ipc_queue_depth) : (fill += 1) {
        if (!queueDnsStatusResponse(app, 0x6901_3000 + fill)) return fail(app, "queue fill failed");
    }
    if (queueDnsStatusResponse(app, 0x6901_3FFF)) return fail(app, "full queue accepted ninth response");
    if (app.net.ipcPoll(r4os.abi.ipc_channel_net_dns) != r4os.abi.ipc_queue_depth) return fail(app, "full queue depth mismatch");
    if (!drainChannel(app, r4os.abi.ipc_channel_net_dns)) return fail(app, "full queue drain failed");
    var empty_probe: [r4os.abi.ipc_max_message_size]u8 = undefined;
    if (app.net.ipcRecv(r4os.abi.ipc_channel_net_dns, empty_probe[0..]) != 0) return fail(app, "empty queue receive mismatch");

    // Der groesstmoegliche Requestpayload ist vollstaendig initialisiert;
    // der ungueltige Op-Code muss als gueltige, kleine Fehlerantwort enden.
    var maximum_payload: [r4os.abi.ipc_max_message_size - r4os.abi.net_service_header_size]u8 = undefined;
    for (&maximum_payload, 0..) |*byte, i| byte.* = @truncate(i *% 131 +% 17);
    var maximum_response: [r4os.abi.ipc_max_message_size]u8 = undefined;
    var maximum_status: i32 = 0;
    const maximum_result = requestBackend(app, r4os.abi.ipc_channel_net_dns, 0xFFFF, 0x6901_4000, maximum_payload[0..], maximum_response[0..], &maximum_status) orelse return fail(app, "maximum request failed");
    if (maximum_result.len != 0 or maximum_status != r4os.abi.net_service_result_bad_op) return fail(app, "maximum request error response mismatch");

    var after: r4os.abi.IpcPerformanceSummary = .{};
    if (app.net.ipcPerformance(0, &after) <= 0) return fail(app, "final performance snapshot failed");
    var dns_after: r4os.abi.IpcPerformanceSummary = .{};
    if (app.net.ipcPerformance(r4os.abi.ipc_channel_net_dns, &dns_after) <= 0) return fail(app, "channel performance snapshot failed");
    if (after.queue_used != 0 or dns_after.queue_used != 0) return fail(app, "queue not empty after selftest");
    if (after.handler_queued <= before.handler_queued or after.handler_completed - before.handler_completed != after.handler_queued - before.handler_queued) return fail(app, "handler completion accounting mismatch");
    if (after.payload_clear_bytes != before.payload_clear_bytes or after.recv_buffer_small <= before.recv_buffer_small or after.queue_full <= before.queue_full or after.queue_empty <= before.queue_empty) return fail(app, "byte or backpressure accounting mismatch");

    app.sys.println("SPECTRA IPC ipc-selftest: ok");
    app.sys.write("handler_delta=");
    app.sys.printU64(after.handler_completed - before.handler_completed);
    app.sys.write(" copy_bytes_delta=");
    app.sys.printU64(after.payload_copy_bytes - before.payload_copy_bytes);
    app.sys.write(" clear_bytes_delta=");
    app.sys.printU64(after.payload_clear_bytes - before.payload_clear_bytes);
    app.sys.write(" queue_full_delta=");
    app.sys.printU64(after.queue_full - before.queue_full);
    app.sys.write(" buffer_small_delta=");
    app.sys.printU64(after.recv_buffer_small - before.recv_buffer_small);
    app.sys.write("\r\n");
    return 0;
}

fn verifyDirectDnsStatus(app: *const App, request_id: u32) bool {
    var response: [r4os.abi.ipc_max_message_size]u8 = undefined;
    var status: i32 = 0;
    const payload = requestBackend(app, r4os.abi.ipc_channel_net_dns, r4os.abi.net_service_op_dns_status_result, request_id, "", response[0..], &status) orelse return false;
    return status == r4os.abi.net_service_result_ok and payload.len >= @sizeOf(r4os.abi.NetServiceDnsStatus);
}

fn drainChannel(app: *const App, channel_id: u32) bool {
    var response: [r4os.abi.ipc_max_message_size]u8 = undefined;
    var drained: usize = 0;
    while (app.net.ipcPoll(channel_id) > 0) : (drained += 1) {
        if (drained >= r4os.abi.ipc_queue_depth) return false;
        if (app.net.ipcRecv(channel_id, response[0..]) <= 0) return false;
    }
    return app.net.ipcPoll(channel_id) == 0;
}

fn printChannel(app: *const App, channel_id: u32, name: []const u8) void {
    var info: r4os.abi.IpcChannelInfo = .{};
    _ = app.net.ipcChannel(channel_id, &info);
    app.sys.write("  ");
    app.sys.write(name);
    app.sys.write(" channel=");
    app.sys.printU64(channel_id);
    app.sys.write(" queued=");
    app.sys.printU64(info.queued);
    app.sys.write("/");
    app.sys.printU64(info.queue_depth);
    app.sys.write(" handler=");
    app.sys.write(if (info.has_handler != 0) "yes" else "no");
    app.sys.write("\r\n");
}

fn runTextRequest(app: *const App, op: u16, request_id: u32, prefix: []const u8) i32 {
    var response: [r4os.abi.ipc_max_message_size]u8 = undefined;
    var status: i32 = 0;
    const payload = requestBackend(app, r4os.abi.ipc_channel_net_dns, op, request_id, "", response[0..], &status) orelse return fail(app, "backend request failed");
    if (status != r4os.abi.net_service_result_ok) return fail(app, "backend returned error");

    app.sys.write(prefix);
    app.sys.write(payload);
    if (!endsWithNewline(payload)) app.sys.write("\r\n");
    return if (startsWith(payload, "ok")) 0 else 1;
}

fn runRestartDiagnostic(app: *const App) i32 {
    if (!queueDnsStatusResponse(app, request_id_stale_probe)) return fail(app, "queue probe failed");
    if (!verifyDnsStatus(app)) return fail(app, "dns status probe failed");
    if (!queueDnsStatusResponse(app, request_id_restart_test + 1)) return fail(app, "restart queue probe failed");
    if (!bindUdpForRestart(app)) return fail(app, "udp lifecycle probe failed");
    if (!listenTcpForRestart(app)) return fail(app, "tcp lifecycle probe failed");

    var response: [r4os.abi.ipc_max_message_size]u8 = undefined;
    var status: i32 = 0;
    const payload = requestBackend(
        app,
        r4os.abi.ipc_channel_net_dns,
        r4os.abi.net_service_op_service_restart,
        request_id_restart_test,
        "",
        response[0..],
        &status,
    ) orelse return fail(app, "restart request failed");
    if (status != r4os.abi.net_service_result_ok or !startsWith(payload, "ok")) return fail(app, "restart result failed");
    if (!verifyRestartCleaned(app)) return fail(app, "restart cleanup status failed");

    app.sys.write("SPECTRA IPC restart-test: ");
    app.sys.write(payload);
    if (!endsWithNewline(payload)) app.sys.write("\r\n");
    return 0;
}

fn runDriverLifecycleDiagnostic(app: *const App) i32 {
    if (!app.net.hasFn("net_diag_run")) return fail(app, "netdiag api missing");

    var result: r4os.abi.NetDiagResult = .{};
    const rc = app.net.netDiagRun(r4os.abi.net_diag_op_driver, &result);
    app.sys.write("SPECTRA IPC driver-lifecycle-test: ");
    app.sys.println(if (rc == r4os.abi.net_diag_ok) "ok" else "failed");
    app.sys.write("Driver lifecycle: tests=");
    printU(app, result.driver.tests);
    app.sys.write(" cases=");
    printU(app, result.driver.cases);
    app.sys.write("\r\n");
    printCleanup(app, result.cleanup);
    return if (rc == r4os.abi.net_diag_ok) 0 else 1;
}

fn queueDnsStatusResponse(app: *const App, request_id: u32) bool {
    var request: [r4os.abi.net_service_header_size]u8 = undefined;
    writeNetServiceHeader(
        request[0..],
        r4os.abi.ipc_channel_net_dns,
        r4os.abi.net_service_op_dns_status_result,
        request_id,
        app.net.netServiceClientId(),
        r4os.abi.net_service_result_ok,
        0,
    ) orelse return false;
    return app.net.ipcSend(r4os.abi.ipc_channel_net_dns, request[0..]) > 0;
}

fn verifyDnsStatus(app: *const App) bool {
    var response: [r4os.abi.ipc_max_message_size]u8 = undefined;
    var status: i32 = 0;
    const payload = requestBackend(
        app,
        r4os.abi.ipc_channel_net_dns,
        r4os.abi.net_service_op_dns_status_result,
        request_id_dns_probe,
        "",
        response[0..],
        &status,
    ) orelse return false;
    if (status != r4os.abi.net_service_result_ok) return false;
    var dns_status: r4os.abi.NetServiceDnsStatus = .{};
    return copyDnsStatus(payload, &dns_status);
}

fn bindUdpForRestart(app: *const App) bool {
    var request: [2]u8 = undefined;
    writeU16(request[0..], 0, restart_test_udp_port);
    var response: [r4os.abi.ipc_max_message_size]u8 = undefined;
    var status: i32 = 0;
    const payload = requestBackend(
        app,
        r4os.abi.ipc_channel_net_udp,
        r4os.abi.net_service_op_udp_bind_result,
        request_id_udp_probe,
        request[0..],
        response[0..],
        &status,
    ) orelse return false;
    if (status != r4os.abi.net_service_result_ok) return false;
    var result: r4os.abi.NetServiceUdpResult = .{};
    return copyUdpResult(payload, &result) and result.result == 0 and
        (result.flags & r4os.abi.net_service_udp_flag_handle_valid) != 0;
}

fn listenTcpForRestart(app: *const App) bool {
    var request: [2]u8 = undefined;
    writeU16(request[0..], 0, restart_test_tcp_port);
    var response: [r4os.abi.ipc_max_message_size]u8 = undefined;
    var status: i32 = 0;
    const payload = requestBackend(
        app,
        r4os.abi.ipc_channel_net_tcp,
        r4os.abi.net_service_op_tcp_listen_result,
        request_id_tcp_probe,
        request[0..],
        response[0..],
        &status,
    ) orelse return false;
    if (status != r4os.abi.net_service_result_ok) return false;
    var result: r4os.abi.NetServiceTcpResult = .{};
    return copyTcpResult(payload, &result) and result.result == 0 and
        (result.flags & r4os.abi.net_service_tcp_flag_listener) != 0;
}

fn verifyRestartCleaned(app: *const App) bool {
    var udp_status: r4os.abi.NetServiceUdpStatus = .{};
    if (!readUdpStatus(app, &udp_status)) return false;
    var tcp_status: r4os.abi.NetServiceTcpStatus = .{};
    if (!readTcpStatus(app, &tcp_status)) return false;
    return udp_status.active_sockets == 0 and
        tcp_status.active_listeners == 0 and
        tcp_status.handle_count == 0;
}

fn readUdpStatus(app: *const App, out: *r4os.abi.NetServiceUdpStatus) bool {
    var response: [r4os.abi.ipc_max_message_size]u8 = undefined;
    var status: i32 = 0;
    const payload = requestBackend(
        app,
        r4os.abi.ipc_channel_net_udp,
        r4os.abi.net_service_op_udp_status_result,
        request_id_udp_probe + 1,
        "",
        response[0..],
        &status,
    ) orelse return false;
    return status == r4os.abi.net_service_result_ok and copyUdpStatus(payload, out);
}

fn readTcpStatus(app: *const App, out: *r4os.abi.NetServiceTcpStatus) bool {
    var response: [r4os.abi.ipc_max_message_size]u8 = undefined;
    var status: i32 = 0;
    const payload = requestBackend(
        app,
        r4os.abi.ipc_channel_net_tcp,
        r4os.abi.net_service_op_tcp_status_result,
        request_id_tcp_probe + 1,
        "",
        response[0..],
        &status,
    ) orelse return false;
    return status == r4os.abi.net_service_result_ok and copyTcpStatus(payload, out);
}

fn requestBackend(
    app: *const App,
    channel_id: u32,
    op: u16,
    request_id: u32,
    payload_in: []const u8,
    response: []u8,
    status: *i32,
) ?[]const u8 {
    const got = app.net.netServiceRequest(channel_id, op, request_id, payload_in, response);
    if (got <= 0) return null;
    return app.net.netServicePayload(response[0..@intCast(got)], status);
}

fn copyDnsStatus(payload: []const u8, out: *r4os.abi.NetServiceDnsStatus) bool {
    if (payload.len < @sizeOf(r4os.abi.NetServiceDnsStatus)) return false;
    const bytes: [*]u8 = @ptrCast(out);
    @memcpy(bytes[0..@sizeOf(r4os.abi.NetServiceDnsStatus)], payload[0..@sizeOf(r4os.abi.NetServiceDnsStatus)]);
    return out.magic == r4os.abi.net_service_dns_status_magic and out.version == r4os.abi.net_service_dns_status_version;
}

fn copyUdpStatus(payload: []const u8, out: *r4os.abi.NetServiceUdpStatus) bool {
    if (payload.len < @sizeOf(r4os.abi.NetServiceUdpStatus)) return false;
    const bytes: [*]u8 = @ptrCast(out);
    @memcpy(bytes[0..@sizeOf(r4os.abi.NetServiceUdpStatus)], payload[0..@sizeOf(r4os.abi.NetServiceUdpStatus)]);
    return out.magic == r4os.abi.net_service_udp_status_magic and out.version == r4os.abi.net_service_udp_status_version;
}

fn copyTcpStatus(payload: []const u8, out: *r4os.abi.NetServiceTcpStatus) bool {
    if (payload.len < @sizeOf(r4os.abi.NetServiceTcpStatus)) return false;
    const bytes: [*]u8 = @ptrCast(out);
    @memcpy(bytes[0..@sizeOf(r4os.abi.NetServiceTcpStatus)], payload[0..@sizeOf(r4os.abi.NetServiceTcpStatus)]);
    return out.magic == r4os.abi.net_service_tcp_status_magic and out.version == r4os.abi.net_service_tcp_status_version;
}

fn copyUdpResult(payload: []const u8, out: *r4os.abi.NetServiceUdpResult) bool {
    if (payload.len < @sizeOf(r4os.abi.NetServiceUdpResult)) return false;
    const bytes: [*]u8 = @ptrCast(out);
    @memcpy(bytes[0..@sizeOf(r4os.abi.NetServiceUdpResult)], payload[0..@sizeOf(r4os.abi.NetServiceUdpResult)]);
    return out.magic == r4os.abi.net_service_udp_result_magic and out.version == r4os.abi.net_service_udp_result_version;
}

fn copyTcpResult(payload: []const u8, out: *r4os.abi.NetServiceTcpResult) bool {
    if (payload.len < @sizeOf(r4os.abi.NetServiceTcpResult)) return false;
    const bytes: [*]u8 = @ptrCast(out);
    @memcpy(bytes[0..@sizeOf(r4os.abi.NetServiceTcpResult)], payload[0..@sizeOf(r4os.abi.NetServiceTcpResult)]);
    return out.magic == r4os.abi.net_service_tcp_result_magic and out.version == r4os.abi.net_service_tcp_result_version;
}

fn printCleanup(app: *const App, cleanup: r4os.abi.NetDiagCleanup) void {
    app.sys.write("Cleanup: runs=");
    printU(app, cleanup.runs);
    app.sys.write(" link_down=");
    printU(app, cleanup.link_down_cleanups);
    app.sys.write(" reset=");
    printU(app, cleanup.adapter_reset_cleanups);
    app.sys.write(" unreg=");
    printU(app, cleanup.adapter_unregister_cleanups);
    app.sys.write(" svc_restart=");
    printU(app, cleanup.service_restart_cleanups);
    app.sys.write(" poweroff=");
    printU(app, cleanup.poweroff_cleanups);
    app.sys.write(" reboot=");
    printU(app, cleanup.reboot_cleanups);
    app.sys.write(" udp=");
    printU(app, cleanup.udp_sockets_closed);
    app.sys.write(" tcp=");
    printU(app, cleanup.tcp_connections_aborted);
    app.sys.write(" tcp_listen=");
    printU(app, cleanup.tcp_listeners_closed);
    app.sys.write(" dhcp=");
    printU(app, cleanup.dhcp_operations_cancelled);
    app.sys.write(" dns=");
    printU(app, cleanup.dns_operations_cancelled);
    app.sys.write(" last=");
    printFixed(app, cleanup.last_reason[0..]);
    app.sys.write("\r\n");
}

fn printFixed(app: *const App, value: []const u8) void {
    app.sys.write(spanZ(value));
}

fn spanZ(value: []const u8) []const u8 {
    var len: usize = 0;
    while (len < value.len and value[len] != 0) : (len += 1) {}
    return value[0..len];
}

fn printU(app: *const App, value: anytype) void {
    app.sys.printU64(@intCast(value));
}

fn fail(app: *const App, msg: []const u8) i32 {
    app.sys.write("SPECTRA IPC failed: ");
    app.sys.write(msg);
    app.sys.write("\r\n");
    return 1;
}

fn zSlice(value: [*:0]const u8) []const u8 {
    var len: usize = 0;
    while (value[len] != 0) : (len += 1) {}
    return value[0..len];
}

fn trim(value: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = value.len;
    while (start < end and isSpace(value[start])) : (start += 1) {}
    while (end > start and isSpace(value[end - 1])) : (end -= 1) {}
    return value[start..end];
}

fn isSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n';
}

fn equalsIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (upper(ca) != upper(cb)) return false;
    }
    return true;
}

fn startsWith(value: []const u8, prefix: []const u8) bool {
    return value.len >= prefix.len and bytesEqual(value[0..prefix.len], prefix);
}

fn endsWithNewline(value: []const u8) bool {
    return value.len != 0 and (value[value.len - 1] == '\n' or value[value.len - 1] == '\r');
}

fn bytesEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

fn upper(ch: u8) u8 {
    if (ch >= 'a' and ch <= 'z') return ch - 32;
    return ch;
}

fn writeNetServiceHeader(out: []u8, channel_id: u32, op: u16, request_id: u32, client_id: u16, status: i32, payload_len: u16) ?void {
    if (out.len < r4os.abi.net_service_header_size) return null;
    writeU32(out, 0, r4os.abi.net_service_magic);
    writeU16(out, 4, r4os.abi.net_service_version);
    writeU16(out, 6, @intCast(channel_id));
    writeU16(out, 8, op);
    writeU16(out, 10, 0);
    writeU32(out, 12, request_id);
    writeU16(out, 16, client_id);
    writeU16(out, 18, payload_len);
    writeI32(out, 20, status);
}

fn writeU16(out: []u8, offset: usize, value: u16) void {
    out[offset] = @intCast(value & 0xFF);
    out[offset + 1] = @intCast(value >> 8);
}

fn writeU32(out: []u8, offset: usize, value: u32) void {
    writeU16(out, offset, @intCast(value & 0xFFFF));
    writeU16(out, offset + 2, @intCast(value >> 16));
}

fn writeI32(out: []u8, offset: usize, value: i32) void {
    writeU32(out, offset, @bitCast(value));
}

fn readU16(value: []const u8, offset: usize) u16 {
    return @as(u16, value[offset]) | (@as(u16, value[offset + 1]) << 8);
}

fn readU32(value: []const u8, offset: usize) u32 {
    return @as(u32, readU16(value, offset)) | (@as(u32, readU16(value, offset + 2)) << 16);
}
