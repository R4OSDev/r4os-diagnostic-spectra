//! Explicit passive Desktop collection. No capture, sampler, renderer or probe.
const r4os = @import("r4os");
const wire = @import("desktop_diagnostics");
const client = @import("desktop_snapshot_client.zig");
const Output = @import("output.zig").Output;
const abi = r4os.abi;

fn outputs(app: *r4os.App, out: *Output) bool {
    const draw = app.drawing() orelse { out.unavailable("desktop_outputs", "R4DRAW unavailable"); return false; };
    var before: abi.GfxDisplayRevision = .{};
    if (draw.gfxOutputRevision(&before) != abi.gfx_output_ok or before.version != 1 or
        before.size != @sizeOf(abi.GfxDisplayRevision) or before.capacity > 32 or before.present > before.capacity)
    { out.unavailable("desktop_outputs", "current cached output catalog unavailable"); return false; }
    var rows: [32]abi.GfxOutputInfo = undefined;
    var count: usize = 0;
    // This public API returns dense ordinals (Store.info_at), including when
    // its internal storage has holes. Do not scan unused internal capacity.
    for (0..before.present) |slot| {
        var row: abi.GfxOutputInfo = .{};
        const rc = draw.gfxOutputInfo(@intCast(slot), &row);
        if (rc != abi.gfx_output_ok or row.version != 1 or row.size != @sizeOf(abi.GfxOutputInfo) or row.topology_revision != before.revision) {
            out.unavailable("desktop_outputs", "incomplete current output snapshot"); return false;
        }
        rows[count] = row; count += 1;
    }
    var after: abi.GfxDisplayRevision = .{};
    if (draw.gfxOutputRevision(&after) != abi.gfx_output_ok or after.version != 1 or after.size != @sizeOf(abi.GfxDisplayRevision) or after.revision != before.revision or
        after.capacity != before.capacity or after.present != before.present or count != before.present)
    { out.unavailable("desktop_outputs", "output ownership changed during collection"); return false; }
    out.record("inventory", "desktop_outputs", 0, .{ .revision = after.revision, .count = count, .capacity = after.capacity,
        .scope = @as([]const u8, "passive public output registry, not physical visibility or logical Desktop layout") });
    for (rows[0..count], 0..) |row, slot| out.record("snapshot", "desktop_output", @intCast(slot), .{
        .identity = row.identity, .topology_revision = row.topology_revision, .flags = row.flags,
        .connector_kind = row.connector_kind, .mode_count = row.mode_count,
        .physical_visibility = @as(?bool, null),
    });
    return true;
}

const Backend = struct {
    sys: r4os.r4sys.Context,
    status: i32 = 0,
    pub fn open(self: *@This()) !client.Opened {
        var info: abi.ServiceInfo = .{};
        self.status = self.sys.serviceOpen(abi.window_service_name, &info);
        if (self.status != abi.service_api_result_ok or info.handle == 0) return error.SourceUnavailable;
        return .{ .handle = info.handle, .instance = info.instance_id };
    }
    pub fn copy(self: *@This(), handle: u32, bytes: []u8) ![]const u8 {
        var header: abi.ServiceMessageHeader = .{};
        const count = self.sys.serviceCall(handle, wire.operation, "", &header, bytes, self.sys.ticksFromMilliseconds(250));
        self.status = if (count < 0) count else header.status;
        if (self.status != abi.service_api_result_ok) return error.CurrentSnapshotUnavailable;
        if (count < 0 or count > bytes.len) return error.InvalidProtocol;
        return bytes[0..@intCast(count)];
    }
    fn live(self: *@This(), id: u32, generation: u64, desktop: bool) bool {
        const handle: abi.ProgramProcessHandle = .{ .instance_id = id, .generation = generation };
        var info: abi.ProgramInstanceInfo = .{};
        return self.sys.programHandleStatus(&handle, &info) == abi.program_handle_ok and info.id == id and
            info.state != 2 and (!desktop or info.flags & abi.program_instance_flag_desktop_host != 0);
    }
    pub fn current(self: *@This(), s: wire.Snapshot) bool {
        var after: abi.ServiceInfo = .{};
        return self.sys.serviceStatus(abi.window_service_name, &after) == abi.service_api_result_ok and
            after.instance_id == s.service_instance and self.live(s.service_instance, s.service_generation, false) and
            (s.flags & wire.owner_valid == 0 or self.live(s.desktop_instance, s.desktop_generation, true));
    }
    pub fn close(self: *@This(), handle: u32) !void {
        const rc = self.sys.serviceClose(handle);
        if (rc != abi.service_api_result_ok) { self.status = rc; return error.CloseUnconfirmed; }
    }
};

fn captureCounters(app: *r4os.App, out: *Output) void {
    const desk = app.desktop() orelse { out.unavailable("desktop_capture_counters", "R4DESK unavailable"); return; };
    var stats: abi.RemoteFrameCaptureStats = .{};
    if (desk.remoteFrameCaptureStats(&stats) != 0 or stats.version != 1 or stats.size != @sizeOf(abi.RemoteFrameCaptureStats)) {
        out.unavailable("desktop_capture_counters", "passive resident capture counters unavailable"); return;
    }
    out.record("snapshot", "desktop_capture_counters", 0, .{
        .scope = @as([]const u8, "global existing capture counters; no demand/lease acquired by this query"), .counters = stats,
    });
}

pub fn collect(app: *r4os.App, dev: *const r4os.r4dev.Context, out: *Output) bool {
    defer captureCounters(app, out);
    const before = dev.displayState();
    var backend: Backend = .{ .sys = app.system() };
    const snapshot = client.read(&backend) catch |err| {
        out.record("unavailable", "desktop", 0, .{ .interface = @as([]const u8, "r4os.desktop.snapshot"),
            .version = wire.version, .reason = @errorName(err), .status = backend.status,
            .owner = @as(?u32, null), .work_requested = false });
        return false;
    };
    const has_owner = snapshot.flags & wire.owner_valid != 0;
    const has_display = snapshot.flags & wire.display_valid != 0;
    const has_clock = snapshot.flags & wire.clock_valid != 0;
    out.record("snapshot", "desktop", 0, .{
        .interface = @as([]const u8, "r4os.desktop.snapshot"), .version = wire.version,
        .scope = @as([]const u8, "resident WINSVC broker copy; private render timings unavailable"),
        .service_instance = snapshot.service_instance, .service_generation = snapshot.service_generation,
        .endpoint = snapshot.endpoint, .desktop_available = has_owner,
        .desktop_instance = if (has_owner) @as(?u32, snapshot.desktop_instance) else null,
        .desktop_generation = if (has_owner) @as(?u64, snapshot.desktop_generation) else null,
        .desktop_epoch = if (has_owner) @as(?u64, snapshot.desktop_epoch) else null,
        .service_window_revision = snapshot.window_revision, .service_cached_windows = snapshot.window_count,
        .service_focused_instance = snapshot.focused_instance,
        .collected_ns = if (has_clock) @as(?u64, snapshot.collected_ns) else null,
        .clock_generation = if (has_clock) @as(?u64, snapshot.clock_generation) else null,
        .published_state_age_ns = @as(?u64, null),
        .display_state_available = has_display,
        .display_epoch = if (has_display) @as(?u64, snapshot.display_epoch) else null,
        .display_revision = if (has_display) @as(?u64, snapshot.display_revision) else null,
        .logical_outputs = if (has_display) @as(?u32, snapshot.logical_outputs) else null,
        .render_frames = @as(?u64, null), .render_ns = @as(?u64, null),
        .physical_visibility_ns = @as(?u64, null), .physical_cursor_latency_ns = @as(?u64, null),
        .detail_available = false, .work_requested = false,
    });
    const after = dev.displayState();
    const coherent = before != null and after != null and r4os.graphics_status.sameOwner(before.?, after.?);
    if (coherent) {
        const display = after.?;
        out.record("snapshot", "desktop_display_owner", 0, .{
            .scope = @as([]const u8, "kernel cached display owner; no scanout/physical visibility receipt"),
            .revision = display.revision, .state = display.state, .backend_kind = display.backend_kind,
            .adapter_id = if (display.adapter_id != 0) @as(?u32, display.adapter_id) else null,
            .device_generation = if (display.adapter_id != 0 and display.device_generation != 0) @as(?u64, display.device_generation) else null,
            .reset_generation = if (display.adapter_id != 0 and display.reset_generation != 0) @as(?u64, display.reset_generation) else null,
            .width = display.width, .height = display.height, .pitch = display.pitch,
            .per_output_detail = @as(?u32, null), .physical_visibility = @as(?bool, null),
        });
    } else out.unavailable("desktop_display_owner", "cached display ownership absent or changed during collection");
    const complete_outputs = outputs(app, out);
    return has_owner and coherent and complete_outputs;
}
