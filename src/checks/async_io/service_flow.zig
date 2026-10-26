//! Existing ServiceClassDiag endpoints and productive Async calls. No fake
//! worker/load state: four outstanding replies must leave a fifth call runnable.
const r4os = @import("r4os");
const abi = r4os.abi;
const Context = r4os.r4sys.Context;
const path = "C:\\R4OS\\SOFTWARE\\TERMINAL\\DIAG\\SVCAPPD.R4X";
const slow = "SVCSTALL";
const fast = "SVCAPPD";
const slow_budget: u64 = 3000;

pub fn run(app: *r4os.App) i32 {
    var sys = app.system();
    sys.println("SPECTRA ASYNC_IO service begin");
    var info: abi.ServiceInfo = .{};
    if (sys.serviceInstall(slow, path, "/HOLD /STALLENDPOINT", abi.service_start_manual, "Async continuation fixture", &info) != 0) return fail(&sys, "install slow");
    var slow_installed = true;
    defer if (slow_installed) {
        _ = sys.serviceRemove(slow);
    };
    if (sys.serviceStart(slow, &info) != 0) return fail(&sys, "start slow");
    var slow_running = true;
    defer if (slow_running) {
        _ = sys.serviceStop(slow, &info, 2000);
    };
    var fast_installed = false;
    var fast_running = false;
    defer if (fast_installed) {
        _ = sys.serviceRemove(fast);
    };
    defer if (fast_running) {
        _ = sys.serviceStop(fast, &info, 2000);
    };
    var fast_before: abi.ServiceInfo = .{};
    const existing_fast = sys.serviceStatus(fast, &fast_before);
    if (existing_fast == abi.service_api_result_not_found) {
        if (sys.serviceInstall(fast, path, "/HOLD /ENDPOINT", abi.service_start_manual, "Async fast independent endpoint", &info) != 0) return fail(&sys, "install fast");
        fast_installed = true;
        if (sys.serviceStart(fast, &info) != 0) return fail(&sys, "start fast");
        fast_running = true;
        fast_before = info;
    } else {
        // Test profiles already auto-start this exact canonical fixture. Open
        // it, but retain its service/endpoint identity, handles and running state.
        var detail: abi.ServiceDetail = .{};
        if (existing_fast != 0 or sys.serviceDetailByName(fast, &detail) != 0 or
            detail.info.state != abi.service_state_running or detail.info.handle == 0 or
            !equal(detail.path[0..path.len], path) or detail.path[path.len] != 0)
            return fail(&sys, "preexisting fast fixture identity");
    }
    if (!endpoint(&sys, slow, 0, 0, 2000) or !endpoint(&sys, fast, 0, fast_before.requests, 2000)) return fail(&sys, "endpoints not ready");
    var s: abi.ServiceInfo = .{};
    var f: abi.ServiceInfo = .{};
    if (sys.serviceOpen(slow, &s) != 0) return fail(&sys, "open slow");
    defer if (s.handle != 0) {
        _ = sys.serviceClose(s.handle);
    };
    if (sys.serviceOpen(fast, &f) != 0) return fail(&sys, "open fast");
    defer if (f.handle != 0) {
        _ = sys.serviceClose(f.handle);
    };
    var ids: [12]u32 = .{0} ** 12;
    var headers: [12]abi.ServiceMessageHeader = .{abi.ServiceMessageHeader{}} ** 12;
    var buffers: [12][8]u8 = .{[_]u8{0} ** 8} ** 12;
    // Even a failed assertion cannot return while a worker/continuation holds
    // these exact stack buffers. All submitted operations have finite budgets.
    defer for (&ids) |*id| {
        if (id.* != 0) {
            var io: abi.ProgramIoInfo = .{};
            _ = sys.ioWait(id.*, abi.io_wait_forever, &io);
            _ = sys.ioClose(id.*);
        }
    };
    for (0..4) |i| {
        if (!submit(&sys, s.handle, 0x0597, slow_budget, &ids[i], &headers[i], &buffers[i])) return fail(&sys, "four slow submits");
    }
    if (!endpoint(&sys, slow, 4, s.requests + 4, 1500)) return fail(&sys, "four replies not pending");
    if (!submit(&sys, f.handle, 1, 500, &ids[8], &headers[8], &buffers[8])) return fail(&sys, "fast submit");
    if (!complete(&sys, &ids[8], 1000, 4, 0) or headers[8].magic != abi.service_api_magic or !equal(buffers[8][0..4], "PING")) return fail(&sys, "fifth independent call blocked");
    for (0..4) |i| {
        var state: abi.ProgramIoInfo = .{};
        if (sys.ioStatus(ids[i], &state) != 0 or state.state != abi.io_state_running or sys.ioClose(ids[i]) != abi.io_error_busy) return fail(&sys, "pending buffers/close lifetime");
    }
    sys.println("ASYNC08740 PASS four-replies=pending fifth=completed independent=1 buffers=held");
    for (4..8) |i| {
        if (!submit(&sys, s.handle, 0x0597, slow_budget, &ids[i], &headers[i], &buffers[i])) return fail(&sys, "fill endpoint");
    }
    if (!endpoint(&sys, slow, 8, s.requests + 8, 1000)) return fail(&sys, "eight pending endpoint slots");
    if (!submit(&sys, s.handle, 0x0597, 60, &ids[9], &headers[9], &buffers[9])) return fail(&sys, "admission deadline submit");
    if (!complete(&sys, &ids[9], 1000, abi.service_api_result_timeout, 60) or !endpoint(&sys, slow, 8, s.requests + 8, 0)) return fail(&sys, "full endpoint deadline admitted expired request");
    sys.println("ASYNC08740 PASS full=8 admission-timeout=60 submitted=unchanged deadline=from-submission");
    if (!submit(&sys, s.handle, 0x0597, 3500, &ids[10], &headers[10], &buffers[10])) return fail(&sys, "admission continuation submit");
    for (0..8) |i| {
        if (!complete(&sys, &ids[i], 5000, abi.service_api_result_timeout, slow_budget)) return fail(&sys, "reply deadline/drain");
    }
    if (!endpoint(&sys, slow, 1, s.requests + 9, 250)) return fail(&sys, "permit release did not resume admission");
    if (!complete(&sys, &ids[10], 2000, abi.service_api_result_timeout, 3500) or !endpoint(&sys, slow, 0, s.requests + 9, 250)) return fail(&sys, "shared admission/reply deadline or cleanup");
    sys.println("ASYNC08740 PASS permit-event=continued reply-budget=same-deadline all-endpoint-slots=released");
    // Zero is the existing one-attempt contract. The silent endpoint cannot
    // answer, so this attempt must remove its slot without enrolling a wait.
    if (!submit(&sys, s.handle, 0x0597, 0, &ids[11], &headers[11], &buffers[11])) return fail(&sys, "zero budget submit");
    var zero: abi.ProgramIoInfo = .{};
    if (sys.ioWait(ids[11], 1000, &zero) != 0 or zero.result != abi.service_api_result_timeout) return fail(&sys, "zero budget contract");
    if (sys.ioClose(ids[11]) != 0) return fail(&sys, "zero close");
    ids[11] = 0;
    if (!endpoint(&sys, slow, 0, s.requests + 10, 250) or !endpoint(&sys, fast, 0, f.requests + 1, 0)) return fail(&sys, "zero/fast endpoints not drained");
    sys.println("ASYNC08740 PASS zero=one-attempt completion=terminal close=released");
    if (sys.serviceClose(s.handle) != 0 or sys.serviceClose(f.handle) != 0) return fail(&sys, "endpoint close");
    s.handle = 0;
    f.handle = 0;
    if (sys.serviceStop(slow, &info, 2000) != 0) return fail(&sys, "slow fixture stop/drain");
    slow_running = false;
    if (sys.serviceRemove(slow) != 0) return fail(&sys, "slow fixture remove");
    slow_installed = false;
    if (sys.serviceStatus(slow, &info) != abi.service_api_result_not_found) return fail(&sys, "slow fixture identity remains");
    if (fast_installed) {
        if (sys.serviceStop(fast, &info, 2000) != 0) return fail(&sys, "fast fixture stop/drain");
        fast_running = false;
        if (sys.serviceRemove(fast) != 0) return fail(&sys, "fast fixture remove");
        fast_installed = false;
        if (sys.serviceStatus(fast, &info) != abi.service_api_result_not_found) return fail(&sys, "fast fixture identity remains");
    } else {
        if (sys.serviceStatus(fast, &info) != 0 or info.state != abi.service_state_running or
            info.handle != fast_before.handle or info.instance_id != fast_before.instance_id or
            info.start_tick != fast_before.start_tick or info.restart_count != fast_before.restart_count or
            info.queue_used != 0 or info.open_handles != fast_before.open_handles or
            info.requests != f.requests + 1 or info.responses != fast_before.responses + 1)
            return fail(&sys, "preexisting fast fixture not preserved");
    }
    sys.println("ASYNC08740 PASS fixtures=owned-stopped+removed preexisting=preserved requests=closed buffers=released");
    sys.println("SPECTRA ASYNC_IO service result: OK");
    return 0;
}
fn submit(sys: *const Context, handle: u32, op: u16, budget: u64, id: *u32, header: *abi.ServiceMessageHeader, output: []u8) bool {
    return sys.ioServiceCall(handle, op, "PING", header, output, budget, 0, id) == 0 and id.* != 0;
}
fn complete(sys: *const Context, id: *u32, timeout: u64, result: i32, minimum: u64) bool {
    var io: abi.ProgramIoInfo = .{};
    const waited = sys.ioWait(id.*, timeout, &io);
    if (waited != 0 or io.result != result or io.state != abi.io_state_completed or io.completed_tick < io.submitted_tick or io.completed_tick - io.submitted_tick < minimum) {
        sys.write("ASYNC08740 completion mismatch wait=");
        sys.printI32(waited);
        sys.write(" result=");
        sys.printI32(io.result);
        sys.write(" state=");
        sys.printU64(io.state);
        sys.println("");
        return false;
    }
    if (sys.ioClose(id.*) != 0) return false;
    id.* = 0;
    return true;
}
fn endpoint(sys: *const Context, name: [*:0]const u8, used: u32, requests: u64, timeout: u64) bool {
    const start = sys.ticks();
    while (true) {
        var info: abi.ServiceInfo = .{};
        if (sys.serviceStatus(name, &info) == 0 and info.handle != 0 and info.state == abi.service_state_running and info.queue_used == used and info.requests == requests) return true;
        if (sys.ticks() -| start >= timeout) return false;
        sys.sleepTicks(1);
    }
}
fn equal(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}
fn fail(sys: *const Context, text: []const u8) i32 {
    sys.write("ASYNC08740 FAIL ");
    sys.println(text);
    return 1;
}
