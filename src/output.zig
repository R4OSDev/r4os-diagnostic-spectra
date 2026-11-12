//! Bounded presentation sink. No file is opened without an explicit export.
const std = @import("std");
const r4os = @import("r4os");
const cli = @import("cli.zig");

pub const Output = struct {
    sys: r4os.r4sys.Context,
    format: cli.Format,
    path: ?[*:0]const u8 = null,
    offset: u64 = 0,
    stdout: ?r4os.launch_io.Output = null,
    writer: ?r4os.app_storage.StreamWriter = null,
    export_path: ?r4os.FilePath = null,
    failed: bool = false,
    detail: ?bool = null,
    sequence: u32 = 0,
    buffer: [4096]u8 = undefined,
    used: usize = 0,

    pub fn init(app: *r4os.App2, request: *const cli.Request) Output {
        var out = Output{ .sys = app.system(), .format = request.format };
        if (request.export_len != 0) {
            out.path = request.export_path[0..request.export_len :0].ptr;
            out.export_path = r4os.FilePath.parse(request.export_path[0..request.export_len]) catch {
                out.failed = true;
                return out;
            };
            const files = app.files() orelse { out.failed = true; return out; };
            out.writer = switch (files.streamWriter(out.export_path.?.asZ(), r4os.abi.file_stream_open_replace)) {
                .writer => |writer| writer,
                .failure => { out.failed = true; return out; },
            };
        } else {
            var stdout: r4os.launch_io.Output = undefined;
            if (r4os.launch_io.Output.init(app, &stdout) != 0) out.failed = true else out.stdout = stdout;
        }
        return out;
    }

    fn sink(raw: ?*anyopaque, chunk: *const r4os.diagnostics.core.Chunk) callconv(.c) r4os.diagnostics.core.Ack {
        const self: *Output = @ptrCast(@alignCast(raw.?));
        if (self.writer) |*writer| {
            // Output is returned by value from init. Rebind its owned path
            // after every possible move, before any real provider call.
            writer.state.path = self.export_path.?.asZ().ptr;
            return switch (writer.write(chunk.data[0..chunk.length])) {
                .ok => .{ .accepted_bytes = chunk.length },
                .failure => |code| .{ .kind = @intFromEnum(r4os.diagnostics.core.SinkKind.uncertain), .error_code = code },
                else => .{ .kind = @intFromEnum(r4os.diagnostics.core.SinkKind.uncertain) },
            };
        }
        if (self.stdout) |*stdout| return consoleSink(stdout, chunk);
        return .{ .kind = @intFromEnum(r4os.diagnostics.core.SinkKind.failed), .error_code = r4os.abi.err_no_fn };
    }

    fn consoleWrite(raw: ?*anyopaque, _: u64, bytes: [*]const u8, count: u32, absolute: *const r4os.time_contract.checked.DeadlineBudget) callconv(.c) r4os.stream_transfer.Ack {
        const stdout: *r4os.launch_io.Output = @ptrCast(@alignCast(raw.?));
        const a = r4os.abi;
        const limit: r4os.byte_pipe.Deadline = if (stdout.io.binding(1).?.kind == a.launch_io_pipe)
            r4os.byte_pipe.deadline(absolute.*) catch return .{ .kind = @intFromEnum(r4os.stream_transfer.IoKind.failed), .error_code = a.byte_pipe_error_clock_changed }
        else .{};
        var progress: r4os.byte_pipe.Progress = .{};
        const rc = stdout.io.writeChecked(1, bytes[0..count], limit, &progress);
        if (rc != 0) return .{ .kind = @intFromEnum(r4os.stream_transfer.IoKind.uncertain), .error_code = rc };
        return .{ .bytes = @intCast(progress.bytes), .kind = @intFromEnum(switch (progress.state) {
            a.byte_pipe_ready => r4os.stream_transfer.IoKind.progress,
            a.byte_pipe_would_block => .would_block,
            a.byte_pipe_timed_out => .timed_out,
            a.byte_pipe_closed, a.byte_pipe_broken_pipe => .closed,
            else => .failed,
        }) };
    }

    fn consoleSink(stdout: *r4os.launch_io.Output, chunk: *const r4os.diagnostics.core.Chunk) r4os.diagnostics.core.Ack {
        const records = r4os.diagnostics.core;
        const core = r4os.stream_transfer;
        if (stdout.failed) return .{ .kind = @intFromEnum(records.SinkKind.failed) };
        const budget = r4os.rpc_budget.Budget.fromTimeout(stdout.clock.read, .{ .kind = r4os.abi.timeout_kind_finite, .nanoseconds = 2_000_000_000 }) catch return .{ .kind = @intFromEnum(records.SinkKind.failed) };
        var transfer = core.Transfer.initAbsolute(.write_all, chunk.length, budget.deadline) catch return .{ .kind = @intFromEnum(records.SinkKind.failed) };
        while (true) {
            // The producer observes Close and stops its work. Its diagnostic
            // and completion records still drain under one bounded deadline,
            // including a cancellation report. Transfer owns every confirmed
            // prefix; an unknown effect is never replayed.
            const result = transfer.writeStep(chunk.data[@intCast(transfer.bytes)..chunk.length], r4os.abi.byte_pipe_max_step, false,
                core.adapters.PlatformClock.sample, &stdout.clock, consoleWrite, stdout) catch return .{ .kind = @intFromEnum(records.SinkKind.uncertain) };
            if (result.flags & core.core.terminal != 0) {
                stdout.failed = result.outcome != @intFromEnum(core.Outcome.complete);
                return .{ .accepted_bytes = @intCast(result.bytes), .error_code = result.error_code,
                    .kind = @intFromEnum(if (result.flags & core.core.effect_uncertain != 0) records.SinkKind.uncertain else if (stdout.failed) records.SinkKind.failed else records.SinkKind.accepted) };
            }
            if (result.outcome == @intFromEnum(core.Outcome.would_block)) stdout.sys.sleepTicks(1);
        }
    }

    pub fn flush(self: *Output) void {
        if (self.used == 0 or self.failed) return;
        // A complete UTF8 transport batch, not a claim that an arbitrarily
        // large JSON object is atomic. Encoding/framing stays with Spectra.
        // Queue and storage remain separate through the synchronous callback.
        var storage: [4104]u8 = undefined;
        var queue = r4os.diagnostics.core.BoundedDiagnosticBuffer.init(&storage) catch { self.failed = true; return; };
        const admitted = queue.appendRecord(self.buffer[0..self.used], .info) catch { self.failed = true; return; };
        if (admitted.kind != @intFromEnum(r4os.diagnostics.core.AppendKind.accepted)) { self.failed = true; return; }
        const result = queue.flushOnce(@intCast(self.used), sink, self) catch { self.failed = true; return; };
        if (result.kind != @intFromEnum(r4os.diagnostics.core.FlushKind.progress) or result.accepted_bytes != self.used or result.completed_records != 1) {
            self.failed = true; // Unknown acceptance is never automatically replayed.
            return;
        }
        if (self.path == null) {
            // Keep the original retained-console pacing outside measured work.
            self.sys.sleepTicks(@max(self.sys.ticksFromMilliseconds(20), @as(u64, @intCast((self.used + 15) / 16 + 2))));
        }
        self.offset += self.used;
        self.used = 0;
    }

    pub fn finish(self: *Output) bool {
        self.flush();
        if (self.writer) |*writer| {
            writer.state.path = self.export_path.?.asZ().ptr;
            if (!self.failed and writer.finish() != .ok) self.failed = true;
            if (!self.failed) {
                const info = writer.files.metadata(self.export_path.?.asZ());
                self.failed = switch (info) {
                    .found => |value| (r4os.metadata2.fileSize(&value) orelse std.math.maxInt(u64)) != self.offset,
                    else => true,
                };
            }
            if (self.failed) _ = writer.abort();
        }
        if (self.stdout) |*stdout| if (stdout.close() != 0) { self.failed = true; };
        return !self.failed;
    }

    pub fn write(self: *Output, bytes: []const u8) void {
        var at: usize = 0;
        while (at < bytes.len and !self.failed) {
            var count = @min(bytes.len - at, self.buffer.len - self.used);
            // Bounded JSON/text records are published whole, through one console
            // write. File export byte layout and measured workloads are unchanged.
            if (self.path == null) {
                if (std.mem.indexOfScalar(u8, bytes[at..][0..count], '\n')) |newline| count = newline + 1;
            }
            if (at + count < bytes.len) {
                while (count != 0 and bytes[at + count] & 0xC0 == 0x80) count -= 1;
                if (count == 0) {
                    if (self.used == 0) { self.failed = true; return; }
                    self.flush(); if (self.failed) return; continue;
                }
            }
            @memcpy(self.buffer[self.used..][0..count], bytes[at..][0..count]);
            self.used += count; at += count;
            if (self.used == self.buffer.len or (self.path == null and count != 0 and bytes[at-1] == '\n')) self.flush();
        }
    }

    pub fn number(self: *Output, value: anytype) void {
        var buffer: [80]u8 = undefined;
        self.write(std.fmt.bufPrint(&buffer, "{d}", .{value}) catch unreachable);
    }

    pub fn string(self: *Output, bytes: []const u8) void {
        self.write("\"");
        var at: usize = 0;
        while (at < bytes.len) : (at += 1) {
            const ch = bytes[at];
            if (ch >= 128) {
                const length = std.unicode.utf8ByteSequenceLength(ch) catch 0;
                if (length > 1 and at + length <= bytes.len) {
                    if (std.unicode.utf8Decode(bytes[at..][0..length])) |_| {
                        self.write(bytes[at..][0..length]);
                        at += length - 1;
                        continue;
                    } else |_| {}
                }
            }
            switch (ch) {
            '"' => self.write("\\\""),
            '\\' => self.write("\\\\"),
            '\n' => self.write("\\n"),
            '\r' => self.write("\\r"),
            '\t' => self.write("\\t"),
            else => if (ch < 32 or ch >= 127) {
                const hex = "0123456789abcdef";
                const escaped = [_]u8{ '\\', 'u', '0', '0', hex[ch >> 4], hex[ch & 15] };
                self.write(&escaped);
            } else self.write(&.{ch}),
            }
        }
        self.write("\"");
    }

    pub fn message(self: *Output, source: []const u8, bytes: []const u8, continued: bool) void {
        if (self.format == .text) { self.write(bytes); if (!continued) self.write("\r\n"); return; }
        self.record("message", source, 0, .{ .text = bytes, .continued = continued });
    }

    pub fn unavailable(self: *Output, group: []const u8, reason: []const u8) void {
        self.record("unavailable", group, 0, .{ .reason = reason });
    }

    pub fn record(self: *Output, kind: []const u8, group: []const u8, index: u64, value: anytype) void {
        if (self.format == .json) {
            self.jsonHeader(kind, group, index);
            self.renderValue(group, "", value, true);
            self.write("}\n");
        } else {
            self.write(group); self.write("["); self.number(index); self.write("] "); self.write(kind); self.write("\r\n");
            self.renderValue(group, "", value, false);
        }
    }

    fn jsonHeader(self: *Output, kind: []const u8, group: []const u8, index: u64) void {
        self.write("{\"schema\":\"r4os.spectra\",\"schema_version\":1,\"kind\":"); self.string(kind);
        self.write(",\"group\":"); self.string(group);
        self.write(",\"index\":\""); self.number(index);
        self.write("\",\"snapshot\":\""); self.number(self.sequence);
        self.write("\",\"detail_enabled\":");
        if (self.detail) |enabled| self.write(if (enabled) "true" else "false") else self.write("null");
        self.write(",\"data\":");
    }

    /// Caller validates one complete owner JSON value. Preserve its bytes and
    /// units; do not apply kernel-detail filtering or quantify/quote it again.
    pub fn ownerJson(self: *Output, kind: []const u8, group: []const u8, index: u64, bytes: []const u8) void {
        if (self.format == .json) {
            self.jsonHeader(kind, group, index);
            self.write(bytes); self.write("}\n");
        } else {
            self.write(group); self.write(" "); self.write(kind); self.write(": ");
            self.write(bytes); self.write("\r\n");
        }
    }

    fn renderValue(self: *Output, group: []const u8, comptime name: []const u8, data: anytype, json: bool) void {
        @setEvalBranchQuota(200_000);
        const T = @TypeOf(data);
        switch (@typeInfo(T)) {
            .@"struct" => |info| {
                if (json) self.write("{");
                comptime var first = true;
                inline for (info.fields) |field| {
                    if (comptime std.mem.startsWith(u8, field.name, "reserved")) continue;
                    if (json) {
                        if (!first) self.write(",");
                        self.string(field.name); self.write(":");
                    } else { self.write("  " ++ name ++ field.name ++ " = "); }
                    self.renderValue(group, field.name, @field(data, field.name), json);
                    if (!json) self.write("\r\n");
                    first = false;
                }
                if (json) self.write("}");
            },
            .int, .comptime_int => {
                const value_unit = comptime unit(name);
                const disabled = self.detail != null and !self.detail.? and detailField(group, name);
                const retired = if (comptime audioDurationField(name))
                    std.mem.eql(u8, group, "summary") and data == r4os.abi.audio_duration_ticks_unavailable
                else
                    false;
                if (json) {
                    self.write("{\"value\":");
                    if (retired or disabled) self.write("null") else { self.write("\""); self.number(data); self.write("\""); }
                    self.write(",\"unit\":"); self.string(value_unit);
                    if (retired) self.write(",\"unavailable\":\"retired\"") else if (disabled) self.write(",\"unavailable\":\"detail-disabled\"");
                    self.write("}");
                } else if (retired) self.write("unavailable (retired)") else if (disabled) self.write("unavailable (detail disabled)") else { self.number(data); self.write(" "); self.write(value_unit); }
            },
            .bool => self.write(if (data) "true" else "false"),
            .@"enum" => if (json) self.string(@tagName(data)) else self.write(@tagName(data)),
            .optional => if (data) |v| self.renderValue(group, name, v, json) else self.write("null"),
            .array => |info| {
                if (info.child == u8 and (comptime textField(name))) {
                    const text = std.mem.sliceTo(&data, 0);
                    if (json) self.string(text) else self.write(text);
                } else {
                    self.write("[");
                    for (data, 0..) |v, i| { if (i != 0) self.write(","); self.renderValue(group, name, v, json); }
                    self.write("]");
                }
            },
            .pointer => |info| {
                if (info.child != u8) @compileError("unsupported presentation pointer");
                const text: []const u8 = data;
                if (json) self.string(text) else self.write(text);
            },
            else => @compileError("unsupported presentation value: " ++ @typeName(T)),
        }
    }
};

fn textField(comptime name: []const u8) bool {
    return std.mem.eql(u8, name, "name") or std.mem.eql(u8, name, "wait_reason") or std.mem.eql(u8, name, "origin") or std.mem.eql(u8, name, "message") or std.mem.eql(u8, name, "memory_tag") or std.mem.endsWith(u8, name, "_name") or std.mem.eql(u8, name, "text");
}

fn unit(comptime name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "temperature_millic")) return "mdegC";
    if (std.mem.endsWith(u8, name, "_uj")) return "uJ";
    if (std.mem.endsWith(u8, name, "energy_bits")) return "bits";
    if (std.mem.eql(u8, name, "aperf") or std.mem.eql(u8, name, "mperf")) return "core-cycles";
    if (std.mem.eql(u8, name, "valid_mask") or std.mem.eql(u8, name, "fault_mask") or std.mem.eql(u8, name, "unsupported_mask") or std.mem.eql(u8, name, "package_mask") or std.mem.eql(u8, name, "core_mask") or std.mem.eql(u8, name, "thermal_current") or std.mem.eql(u8, name, "thermal_history")) return "bitmask";
    if (std.mem.eql(u8, name, "raw_microcode") or std.mem.eql(u8, name, "raw_thermal_status") or std.mem.eql(u8, name, "raw_temperature_target") or std.mem.eql(u8, name, "raw_energy_unit") or std.mem.eql(u8, name, "raw_reference") or std.mem.endsWith(u8, name, "energy_raw")) return "raw";
    if (std.mem.eql(u8, name, "microcode_revision") or std.mem.endsWith(u8, name, "_revision")) return "identifier";
    if (std.mem.endsWith(u8, name, "features_hash")) return "fingerprint";
    if (std.mem.eql(u8, name, "profile")) return "code";
    // CPU catalogue frequencies are nominal MHz. Register/control masks and
    // address/PMU bit widths must not inherit generic count/pixel/address units.
    if (std.mem.endsWith(u8, name, "_mhz")) return "MHz";
    if (std.mem.eql(u8, name, "pmu_counter_width") or std.mem.eql(u8, name, "counter_width") or std.mem.eql(u8, name, "fixed_width") or std.mem.eql(u8, name, "physical_address_bits") or std.mem.eql(u8, name, "virtual_address_bits")) return "bits";
    if (std.mem.eql(u8, name, "cr0") or std.mem.eql(u8, name, "cr4") or std.mem.eql(u8, name, "xcr0") or std.mem.eql(u8, name, "supported_xcr0") or std.mem.eql(u8, name, "efer") or std.mem.eql(u8, name, "pat") or std.mem.eql(u8, name, "raw_value") or std.mem.eql(u8, name, "control_value") or std.mem.eql(u8, name, "legacy_inventory_msr_faults")) return "bitmask";
    if (std.mem.eql(u8, name, "capture_sequence") or std.mem.eql(u8, name, "max_basic_leaf") or std.mem.eql(u8, name, "max_extended_leaf") or std.mem.eql(u8, name, "max_hypervisor_leaf") or std.mem.eql(u8, name, "raw_hypervisor_maximum") or std.mem.eql(u8, name, "source_leaf") or std.mem.eql(u8, name, "source_subleaf")) return "identifier";
    if (std.mem.eql(u8, name, "hardware_state") or std.mem.eql(u8, name, "os_state") or std.mem.eql(u8, name, "use_state") or std.mem.eql(u8, name, "source_register") or std.mem.eql(u8, name, "register_results")) return "code";
    if (std.mem.eql(u8, name, "pmu_version")) return "version";
    if (std.mem.eql(u8, name, "register_values")) return "raw";
    // Completed offline/online transitions are an operational event count,
    // independent of optional cycle-timing instrumentation.
    if (std.mem.eql(u8, name, "offline_cycles")) return "count";
    if (std.mem.indexOf(u8, name, "cycles") != null) return "tsc-ticks";
    if (std.mem.endsWith(u8, name, "_ns")) return "ns";
    if (std.mem.startsWith(u8, name, "ticks_since_")) return "event-ticks";
    if (std.mem.endsWith(u8, name, "_ticks") or std.mem.endsWith(u8, name, "_tick") or std.mem.eql(u8, name, "ticks")) return "event-ticks";
    if (std.mem.endsWith(u8, name, "_hz")) return "Hz";
    if (std.mem.endsWith(u8, name, "_ms")) return "ms";
    if (std.mem.endsWith(u8, name, "_len") or std.mem.eql(u8, name, "max_message_size") or std.mem.eql(u8, name, "edid_size")) return "bytes";
    if (std.mem.endsWith(u8, name, "_frames") or std.mem.endsWith(u8, name, "_pages")) return "pages";
    if (std.mem.endsWith(u8, name, "_sectors") or std.mem.eql(u8, name, "sector_count")) return "sectors";
    if (std.mem.endsWith(u8, name, "_width") or std.mem.endsWith(u8, name, "_height") or std.mem.endsWith(u8, name, "_pixels")) return "pixels";
    if (std.mem.endsWith(u8, name, "_bpp")) return "bits/pixel";
    if (std.mem.indexOf(u8, name, "bytes") != null or std.mem.endsWith(u8, name, "_pitch") or std.mem.eql(u8, name, "sector_size")) return "bytes";
    if (std.mem.indexOf(u8, name, "spins") != null) return "iterations";
    if (std.mem.indexOf(u8, name, "flags") != null) return "bitmask";
    if (std.mem.indexOf(u8, name, "address") != null or std.mem.endsWith(u8, name, "_base") or std.mem.endsWith(u8, name, "_top") or std.mem.endsWith(u8, name, "_rsp") or std.mem.eql(u8, name, "base") or std.mem.endsWith(u8, name, "_cr3") or std.mem.eql(u8, name, "active_root_phys") or std.mem.eql(u8, name, "hhdm_offset")) return "address";
    if (std.mem.eql(u8, name, "blocked_object") or std.mem.endsWith(u8, name, "_id") or std.mem.eql(u8, name, "id") or std.mem.indexOf(u8, name, "generation") != null or std.mem.indexOf(u8, name, "epoch") != null) return "identifier";
    if (std.mem.eql(u8, name, "size") or std.mem.eql(u8, name, "length") or std.mem.eql(u8, name, "local_mss")) return "bytes";
    if (std.mem.eql(u8, name, "version")) return "version";
    if (std.mem.eql(u8, name, "state") or std.mem.eql(u8, name, "status") or std.mem.eql(u8, name, "kind") or std.mem.eql(u8, name, "reason") or std.mem.endsWith(u8, name, "_kind") or std.mem.eql(u8, name, "mode") or std.mem.eql(u8, name, "source") or std.mem.endsWith(u8, name, "_source") or std.mem.endsWith(u8, name, "_reason") or std.mem.endsWith(u8, name, "_error")) return "code";
    return "count";
}

fn audioDurationField(comptime name: []const u8) bool {
    inline for (.{ "audio_stream_write_", "audio_backend_write_", "audio_backend_refill_" }) |prefix| {
        inline for (.{ "total_ticks", "max_ticks", "last_ticks" }) |suffix| {
            if (std.mem.eql(u8, name, prefix ++ suffix)) return true;
        }
    }
    return false;
}

fn detailField(group: []const u8, comptime name: []const u8) bool {
    if (std.mem.eql(u8, name, "loader_metadata_logical_reads") or
        std.mem.eql(u8, name, "loader_metadata_logical_bytes") or
        std.mem.eql(u8, name, "loader_metadata_window_hits") or
        std.mem.eql(u8, name, "loader_metadata_window_fills") or
        std.mem.eql(u8, name, "loader_metadata_window_fill_bytes") or
        std.mem.eql(u8, name, "loader_metadata_direct_reads") or
        std.mem.eql(u8, name, "loader_metadata_direct_bytes")) return true;
    if (std.mem.eql(u8, name, "offline_cycles")) return false;
    if (std.mem.indexOf(u8, name, "cycles") != null or std.mem.indexOf(u8, name, "spins") != null) return true;
    if (std.mem.eql(u8, group, "stacks") and std.mem.startsWith(u8, name, "high_water")) return true;
    if ((std.mem.eql(u8, group, "irq") or std.mem.eql(u8, group, "work") or std.mem.eql(u8, group, "ipc_timing")) and std.mem.endsWith(u8, name, "_ns") and !std.mem.startsWith(u8, name, "clock_") and !std.mem.endsWith(u8, name, "_threshold_ns")) return true;
    if (std.mem.startsWith(u8, name, "service_lock_") and (std.mem.endsWith(u8, name, "_ns") or std.mem.eql(u8, name, "service_lock_timing_unavailable"))) return true;
    if (std.mem.eql(u8, name, "starvation_warnings") or std.mem.eql(u8, name, "scheduler_ready_waiting_max_ticks")) return true;
    if (comptime (std.mem.eql(u8, name, "lock_order_violations") or
        std.mem.eql(u8, name, "lock_sleep_checks") or
        std.mem.eql(u8, name, "lock_sleep_under_lock") or
        std.mem.eql(u8, name, "lock_sleep_under_no_sleep_lock") or
        std.mem.eql(u8, name, "lock_held_slots_used") or
        std.mem.eql(u8, name, "lock_max_depth") or
        std.mem.eql(u8, name, "lock_tracking_drops"))) return std.mem.eql(u8, group, "summary");
    if (std.mem.eql(u8, group, "work") and (std.mem.eql(u8, name, "timing_unavailable") or std.mem.eql(u8, name, "critical_timing_unavailable") or std.mem.eql(u8, name, "long_callbacks"))) return true;
    return false;
}

test "audio duration JSON marks all nine retired fields independently of detail mode" {
    const t = std.testing;
    inline for (.{ "audio_stream_write_total_ticks", "audio_stream_write_max_ticks", "audio_stream_write_last_ticks", "audio_backend_write_total_ticks", "audio_backend_write_max_ticks", "audio_backend_write_last_ticks", "audio_backend_refill_total_ticks", "audio_backend_refill_max_ticks", "audio_backend_refill_last_ticks" }) |name| {
        for ([_]?bool{ null, false, true }) |detail| {
            var out: Output = .{ .sys = undefined, .format = .json, .detail = detail };
            out.renderValue("summary", name, r4os.abi.audio_duration_ticks_unavailable, true);
            try t.expectEqualStrings("{\"value\":null,\"unit\":\"event-ticks\",\"unavailable\":\"retired\"}", out.buffer[0..out.used]);
        }
    }
}

test "audio duration JSON retains historical zero and nonzero ticks and unrelated full-width counters" {
    const t = std.testing;
    inline for (.{ @as(u64, 0), @as(u64, 27) }) |ticks| {
        var out: Output = .{ .sys = undefined, .format = .json };
        out.renderValue("summary", "audio_stream_write_last_ticks", ticks, true);
        var expected: [100]u8 = undefined;
        const text = try std.fmt.bufPrint(&expected, "{{\"value\":\"{d}\",\"unit\":\"event-ticks\"}}", .{ticks});
        try t.expectEqualStrings(text, out.buffer[0..out.used]);
    }
    var out: Output = .{ .sys = undefined, .format = .json };
    out.renderValue("summary", "audio_stream_writes", std.math.maxInt(u64), true);
    try t.expectEqualStrings("{\"value\":\"18446744073709551615\",\"unit\":\"count\"}", out.buffer[0..out.used]);
}

test "audio duration text reports retirement without changing detail-disabled fields" {
    const t = std.testing;
    var out: Output = .{ .sys = undefined, .format = .text, .detail = true };
    out.renderValue("summary", "audio_backend_refill_max_ticks", r4os.abi.audio_duration_ticks_unavailable, false);
    try t.expectEqualStrings("unavailable (retired)", out.buffer[0..out.used]);
    out.used = 0;
    out.detail = false;
    out.renderValue("summary", "lock_order_violations", @as(u64, 0), false);
    try t.expectEqualStrings("unavailable (detail disabled)", out.buffer[0..out.used]);
}
