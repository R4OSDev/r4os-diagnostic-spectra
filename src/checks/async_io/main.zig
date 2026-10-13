const r4os = @import("r4os");

const write_path_text = "C:\\TEMP\\SPECTRA ASYNC_IO.TXT";
const stream_path_text = "C:\\TEMP\\ASYNIOS.TXT";
const payload = "async-r4sys-io-v1";
const stream_a = "stream-";
const stream_b = "completion";
const task_churn_requests: u32 = 512;
const kill_wait_arg = "/KILLWAIT";
const kill_wait_threads_arg = "/KILLWAITTHREADS";
const retire_retry_arg = "/RETIRERETRY";
const retire_retry_path = "C:\\TEMP\\ASYNIOR.TXT";
const retire_retry_payload = "async-retire-retry";
const kill_wait_op: u16 = 0x0597;
var lifecycle_sys: ?r4os.r4sys.Context = null;

pub fn r4_app_main(app: *r4os.App) i32 {
    var sys = app.system();
    if (hasArg(sys.argsRaw(), "/KILLPOOL")) {
        const handle = argU32After(sys.argsRaw(), "/KILLPOOL") orelse return 1;
        return runKillWaitWithThreads(&sys, handle);
    }
    if (hasArg(sys.argsRaw(), retire_retry_arg)) return runRetireRetry(&sys);
    if (hasArg(sys.argsRaw(), kill_wait_threads_arg)) {
        const handle = argU32After(sys.argsRaw(), kill_wait_threads_arg) orelse
            return fail(&sys, "SPECTRA ASYNC_IO killwaitthreads handle missing");
        return runKillWaitWithThreads(&sys, handle);
    }
    if (hasArg(sys.argsRaw(), kill_wait_arg)) {
        const handle = argU32After(sys.argsRaw(), kill_wait_arg) orelse
            return fail(&sys, "SPECTRA ASYNC_IO killwait handle missing");
        return runKillWait(&sys, handle);
    }
    const resources = app.resources();
    const write_path = r4os.FilePath.parse(write_path_text) catch return fail(&sys, "SPECTRA ASYNC_IO write path invalid");
    const stream_path = r4os.FilePath.parse(stream_path_text) catch return fail(&sys, "SPECTRA ASYNC_IO stream path invalid");

    sys.println("SPECTRA ASYNC_IO");
    if (!resources.available()) return fail(&sys, "SPECTRA ASYNC_IO resource facade missing");
    if (!writeAndVerify(&sys, &resources, write_path.asZ())) return fail(&sys, "SPECTRA ASYNC_IO write/read failed");
    if (!streamAndVerify(&resources, stream_path.asZ())) return fail(&sys, "SPECTRA ASYNC_IO stream failed");
    if (hasArg(sys.argsRaw(), "/POOL")) {
        if (!poolRequests(&sys, write_path.asZ())) return fail(&sys, "SPECTRA ASYNC_IO pool reuse failed");
    } else if (!stressRequests(&sys, &resources, write_path.asZ())) return fail(&sys, "SPECTRA ASYNC_IO stress leaked slots");

    sys.println("SPECTRA ASYNC_IO result: OK");
    return 0;
}

fn runRetireRetry(sys: *r4os.r4sys.Context) i32 {
    sys.println("SPECTRA ASYNC_IO retire retry");
    const written = sys.fileWrite(retire_retry_path, retire_retry_payload);
    if (written != @as(i32, @intCast(retire_retry_payload.len)))
        return fail(sys, "SPECTRA ASYNC_IO retire retry write failed");
    var verify: [32]u8 = .{0} ** 32;
    const read = sys.fileRead(retire_retry_path, verify[0..]);
    if (read != written or !equal(verify[0..retire_retry_payload.len], retire_retry_payload))
        return fail(sys, "SPECTRA ASYNC_IO retire retry verify failed");
    sys.println("SPECTRA ASYNC_IO retire retry: OK");
    sys.println("SPECTRA ASYNC_IO result: OK");
    return 0;
}

fn runKillWaitWithThreads(sys: *r4os.r4sys.Context, service_handle: u32) i32 {
    lifecycle_sys = sys.*;
    var index: u32 = 0;
    while (index < 3) : (index += 1) {
        var handle: r4os.abi.ProgramJoinHandle = .{};
        if (sys.threadCreateHandle(lifecycleWorker, index, 0, 0, &handle) != r4os.abi.thread_ok or !validJoinHandle(handle))
            return fail(sys, "SPECTRA ASYNC_IO lifecycle worker create failed");
        // Intentionally do not join: /KILLWAITTHREADS validates that killing
        // the owning program tears down exactly these three live child threads
        // together with the blocked async request and the owner instance.
    }
    sys.println("SPECTRA ASYNC_IO lifecycle workers=3 ready=OK");
    return runKillWait(sys, service_handle);
}

fn validJoinHandle(handle: r4os.abi.ProgramJoinHandle) bool {
    return handle.thread_id != 0 and
        handle.instance_id != 0 and
        handle.thread_generation != 0 and
        handle.instance_generation != 0 and
        handle.reserved == 0;
}

fn lifecycleWorker(_: u64) callconv(.c) i32 {
    var sys = lifecycle_sys orelse return 71;
    while (true) sys.sleepTicks(1);
}

fn runKillWait(sys: *r4os.r4sys.Context, service_handle: u32) i32 {
    const quiet = hasArg(sys.argsRaw(), "/QUIET");
    if (!quiet) sys.println("SPECTRA ASYNC_IO killwait begin");
    if (!sys.hasFn("io_service_call") or !sys.hasFn("io_wait") or !sys.hasFn("io_close"))
        return fail(sys, "SPECTRA ASYNC_IO killwait async service API missing");

    var headers: [8]r4os.abi.ServiceMessageHeader = .{r4os.abi.ServiceMessageHeader{}} ** 8;
    var responses: [8][1]u8 = .{[1]u8{0}} ** 8;
    var requests: [8]u32 = .{0} ** 8;
    const count: usize = if (hasArg(sys.argsRaw(), "/KILLPOOL")) 8 else 1;
    for (0..count) |i| {
        const submit = sys.ioServiceCall(service_handle, kill_wait_op, "WAIT", &headers[i], &responses[i], r4os.abi.io_wait_forever, 0, &requests[i]);
        if (submit != r4os.abi.io_ok or requests[i] == 0) return fail(sys, "SPECTRA ASYNC_IO killwait submit failed");
    }
    if (count == 8) sys.println("SPECTRA ASYNC_IO KILLPOOL submitted=8");
    const request_id = requests[0];

    if (!quiet) {
        sys.write("SPECTRA ASYNC_IO killwait submitted request=");
        sys.printU64(@intCast(request_id));
        sys.println("");
    }

    var io_info: r4os.abi.ProgramIoInfo = .{};
    const waited = sys.ioWait(request_id, r4os.abi.io_wait_forever, &io_info);
    _ = sys.ioClose(request_id);
    sys.write("SPECTRA ASYNC_IO killwait unexpected wake rc=");
    sys.printI32(waited);
    sys.println("");
    return fail(sys, "SPECTRA ASYNC_IO killwait returned before kill");
}

fn writeAndVerify(sys: *r4os.r4sys.Context, resources: *const r4os.Resources, path: r4os.app_storage.PathZ) bool {
    var write_request = switch (resources.asyncWrite(path, payload, 0)) {
        .request => |request| request,
        .failure => return false,
    };
    if (!write_request.buffersHeld() or write_request.releaseBuffers() != r4os.abi.err_buffer_in_use) return false;
    if (!waitExpect(&write_request, @intCast(payload.len))) return false;
    if (write_request.close() != r4os.abi.io_ok or write_request.buffersHeld()) return false;
    if (write_request.close() != r4os.abi.err_closed) return false;

    var buffer: [64]u8 = .{0} ** 64;
    var read_request = switch (resources.asyncRead(path, buffer[0..], 0)) {
        .request => |request| request,
        .failure => return false,
    };
    const status = switch (read_request.status()) {
        .value => |info| info,
        .failure => return false,
    };
    if (status.request_id != read_request.raw or status.kind != r4os.abi.io_kind_file_read) return false;
    if (!waitExpect(&read_request, @intCast(payload.len))) return false;
    if (read_request.releaseBuffers() != r4os.abi.err_buffer_in_use) return false;
    if (read_request.close() != r4os.abi.io_ok or read_request.releaseBuffers() != r4os.abi.io_ok) return false;
    if (!equal(buffer[0..payload.len], payload)) return false;
    _ = sys;
    return true;
}

fn streamAndVerify(resources: *const r4os.Resources, path: r4os.app_storage.PathZ) bool {
    var begin = switch (resources.asyncStreamBegin(path, r4os.abi.file_stream_open_replace)) {
        .request => |request| request,
        .failure => return false,
    };
    if (!waitExpect(&begin, r4os.abi.file_stream_result_ok) or begin.close() != r4os.abi.io_ok) return false;

    var first = switch (resources.asyncStreamWrite(path, 0, stream_a, 0)) {
        .request => |request| request,
        .failure => return false,
    };
    if (!waitExpect(&first, @intCast(stream_a.len)) or first.close() != r4os.abi.io_ok) return false;

    var second = switch (resources.asyncStreamWrite(path, stream_a.len, stream_b, 0)) {
        .request => |request| request,
        .failure => return false,
    };
    if (!waitExpect(&second, @intCast(stream_b.len)) or second.close() != r4os.abi.io_ok) return false;

    const expected_size = stream_a.len + stream_b.len;
    var finish = switch (resources.asyncStreamFinish(path, expected_size, 0)) {
        .request => |request| request,
        .failure => return false,
    };
    if (!waitExpect(&finish, r4os.abi.file_stream_result_ok) or finish.close() != r4os.abi.io_ok) return false;

    var buffer: [64]u8 = .{0} ** 64;
    var read_request = switch (resources.asyncRead(path, buffer[0..], 0)) {
        .request => |request| request,
        .failure => return false,
    };
    if (!waitExpect(&read_request, @intCast(expected_size)) or read_request.close() != r4os.abi.io_ok) return false;
    return equal(buffer[0..stream_a.len], stream_a) and equal(buffer[stream_a.len..expected_size], stream_b);
}

fn poolRequests(sys: *r4os.r4sys.Context, path: r4os.app_storage.PathZ) bool {
    var requests: [64]u32 = .{0} ** 64;
    var buffers: [64][32]u8 = undefined;
    var workers: [4]u32 = .{0} ** 4;
    var worker_count: usize = 0;
    // Two waves cross the request-slot reuse boundary. Completed but open
    // requests still count towards the unchanged 64-slot admission limit.
    for (0..2) |_| {
        for (&requests, &buffers, 0..) |*request, *buffer, index| {
            const submitted = sys.ioFileRead(path.ptr, buffer[0..], 0, request);
            if (submitted != r4os.abi.io_ok) {
                sys.write("SPECTRA ASYNC_IO pool submit index=");
                sys.printU64(index);
                sys.write(" rc=");
                sys.printI32(submitted);
                sys.println("");
                return false;
            }
        }
        var extra: u32 = 0;
        var extra_buffer: [32]u8 = undefined;
        if (sys.ioFileRead(path.ptr, &extra_buffer, 0, &extra) != r4os.abi.io_error_no_slots or extra != 0) return false;
        for (requests, &buffers) |request, *buffer| {
            var info: r4os.abi.ProgramIoInfo = .{};
            const waited = sys.ioWait(request, r4os.abi.io_wait_forever, &info);
            if (waited != r4os.abi.io_ok or info.result != payload.len or info.task_id == 0 or !equal(buffer[0..payload.len], payload)) {
                sys.write("SPECTRA ASYNC_IO pool wait rc=");
                sys.printI32(waited);
                sys.write(" result=");
                sys.printI32(info.result);
                sys.write(" worker=");
                sys.printU64(info.task_id);
                sys.write(" bytes=");
                for (buffer[0..payload.len]) |byte| {
                    sys.printU64(byte);
                    sys.write(",");
                }
                sys.println("");
                return false;
            }
            var found = false;
            for (workers[0..worker_count]) |id| if (id == info.task_id) {
                found = true;
            };
            if (!found) {
                if (worker_count == workers.len) return false;
                workers[worker_count] = info.task_id;
                worker_count += 1;
            }
            if (sys.ioClose(request) != r4os.abi.io_ok or sys.ioStatus(request, &info) != r4os.abi.io_error_not_found) return false;
        }
    }
    sys.write("SPECTRA ASYNC_IO pool: OK requests=128 workers=");
    sys.printU64(worker_count);
    sys.println(" limit=64 overload=OK stale=OK");
    return true;
}

fn stressRequests(sys: *r4os.r4sys.Context, resources: *const r4os.Resources, path: r4os.app_storage.PathZ) bool {
    var index: u32 = 0;
    while (index < task_churn_requests) : (index += 1) {
        var buffer: [64]u8 = .{0} ** 64;
        var request = switch (resources.asyncRead(path, buffer[0..], 0)) {
            .request => |value| value,
            .failure => return false,
        };
        if (!waitExpect(&request, @intCast(payload.len)) or request.close() != r4os.abi.io_ok) return false;
    }
    sys.write("SPECTRA ASYNC_IO task churn: OK requests=");
    sys.printU64(task_churn_requests);
    sys.println("");
    return true;
}

fn waitExpect(request: *r4os.IoRequest, expected: i32) bool {
    const info = switch (request.wait(r4os.time_contract.timeoutForever())) {
        .completed => |value| value,
        else => return false,
    };
    return info.result == expected and info.state == r4os.abi.io_state_completed;
}

fn equal(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| if (left != right) return false;
    return true;
}

fn hasArg(args: [*:0]const u8, wanted: []const u8) bool {
    var offset: usize = 0;
    while (offset < 256 and args[offset] != 0) {
        while (offset < 256 and (args[offset] == ' ' or args[offset] == '\t')) : (offset += 1) {}
        const start = offset;
        while (offset < 256 and args[offset] != 0 and args[offset] != ' ' and args[offset] != '\t') : (offset += 1) {}
        if (equalsIgnoreCase(args[start..offset], wanted)) return true;
    }
    return false;
}

fn argU32After(args: [*:0]const u8, wanted: []const u8) ?u32 {
    var offset: usize = 0;
    while (offset < 256 and args[offset] != 0) {
        while (offset < 256 and (args[offset] == ' ' or args[offset] == '\t')) : (offset += 1) {}
        const start = offset;
        while (offset < 256 and args[offset] != 0 and args[offset] != ' ' and args[offset] != '\t') : (offset += 1) {}
        if (!equalsIgnoreCase(args[start..offset], wanted)) continue;
        while (offset < 256 and (args[offset] == ' ' or args[offset] == '\t')) : (offset += 1) {}
        var value: u32 = 0;
        var digits: u32 = 0;
        while (offset < 256 and args[offset] >= '0' and args[offset] <= '9') : (offset += 1) {
            const digit: u32 = args[offset] - '0';
            if (value > (0xFFFF_FFFF - digit) / 10) return null;
            value = value * 10 + digit;
            digits += 1;
        }
        if (digits == 0 or value == 0) return null;
        if (offset < 256 and args[offset] != 0 and args[offset] != ' ' and args[offset] != '\t') return null;
        return value;
    }
    return null;
}

fn equalsIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| if (upper(left) != upper(right)) return false;
    return true;
}

fn upper(ch: u8) u8 {
    if (ch >= 'a' and ch <= 'z') return ch - ('a' - 'A');
    return ch;
}

fn fail(sys: *r4os.r4sys.Context, msg: []const u8) i32 {
    sys.println(msg);
    sys.println("SPECTRA ASYNC_IO result: FAILED");
    return 1;
}
