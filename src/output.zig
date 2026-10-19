//! Bounded presentation sink. No file is opened without an explicit export.
const std = @import("std");
const r4os = @import("r4os");
const cli = @import("cli.zig");

pub const Output = struct {
    sys: r4os.r4sys.Context,
    format: cli.Format,
    path: ?[*:0]const u8 = null,
    offset: u64 = 0,
    failed: bool = false,
    detail: ?bool = null,
    sequence: u32 = 0,
    buffer: [4096]u8 = undefined,
    used: usize = 0,

    pub fn init(app: *r4os.App, request: *const cli.Request) Output {
        var out = Output{ .sys = app.system(), .format = request.format };
        if (request.export_len != 0) {
            out.path = request.export_path[0..request.export_len :0].ptr;
            if (out.sys.fileStreamBegin(out.path.?, r4os.abi.file_stream_open_replace) < 0) out.failed = true;
        }
        return out;
    }

    pub fn flush(self: *Output) void {
        if (self.used == 0 or self.failed) return;
        if (self.path) |path| {
            const rc = self.sys.fileStreamWrite(path, self.offset, self.buffer[0..self.used], 0);
            if (rc != @as(i32, @intCast(self.used))) { self.failed = true; return; }
        } else {
            self.sys.write(self.buffer[0..self.used]);
            // The existing console is a retained transcript, not a pipe.
            // Give terminal/SSH readers time to drain each bounded batch.
            // This presentation cost is outside every measured workload;
            // explicit file exports do not incur the pacing delay.
            self.sys.sleepTicks(@max(1, self.sys.ticksFromMilliseconds(20)));
        }
        self.offset += self.used;
        self.used = 0;
    }

    pub fn finish(self: *Output) bool {
        self.flush();
        if (self.path) |path| {
            if (!self.failed and self.sys.fileStreamFinish(path, self.offset, 0) < 0) self.failed = true;
            if (self.failed) _ = self.sys.fileStreamAbort(path);
        }
        return !self.failed;
    }

    pub fn write(self: *Output, bytes: []const u8) void {
        var at: usize = 0;
        while (at < bytes.len and !self.failed) {
            const count = @min(bytes.len - at, self.buffer.len - self.used);
            @memcpy(self.buffer[self.used..][0..count], bytes[at..][0..count]);
            self.used += count;
            at += count;
            if (self.used == self.buffer.len) self.flush();
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
            self.write("{\"schema\":\"r4os.spectra\",\"schema_version\":1,\"kind\":"); self.string(kind);
            self.write(",\"group\":"); self.string(group);
            self.write(",\"index\":\""); self.number(index);
            self.write("\",\"snapshot\":\""); self.number(self.sequence);
            self.write("\",\"detail_enabled\":");
            if (self.detail) |enabled| self.write(if (enabled) "true" else "false") else self.write("null");
            self.write(",\"data\":"); self.renderValue(group, "", value, true);
            self.write("}\n");
        } else {
            self.write(group); self.write("["); self.number(index); self.write("] "); self.write(kind); self.write("\r\n");
            self.renderValue(group, "", value, false);
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
                if (json) {
                    self.write("{\"value\":");
                    if (disabled) self.write("null") else { self.write("\""); self.number(data); self.write("\""); }
                    self.write(",\"unit\":"); self.string(value_unit);
                    if (disabled) self.write(",\"unavailable\":\"detail-disabled\"");
                    self.write("}");
                } else if (disabled) self.write("unavailable (detail disabled)") else { self.number(data); self.write(" "); self.write(value_unit); }
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
    if (std.mem.eql(u8, name, "microcode_revision")) return "identifier";
    if (std.mem.eql(u8, name, "profile")) return "code";
    // CPU catalogue frequencies are nominal MHz. Register/control masks and
    // address/PMU bit widths must not inherit generic count/pixel/address units.
    if (std.mem.endsWith(u8, name, "_mhz")) return "MHz";
    if (std.mem.eql(u8, name, "pmu_counter_width") or std.mem.eql(u8, name, "physical_address_bits") or std.mem.eql(u8, name, "virtual_address_bits")) return "bits";
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

fn detailField(group: []const u8, comptime name: []const u8) bool {
    if (std.mem.eql(u8, name, "offline_cycles")) return false;
    if (std.mem.indexOf(u8, name, "cycles") != null or std.mem.indexOf(u8, name, "spins") != null) return true;
    if (std.mem.eql(u8, group, "stacks") and std.mem.startsWith(u8, name, "high_water")) return true;
    if ((std.mem.eql(u8, group, "irq") or std.mem.eql(u8, group, "work") or std.mem.eql(u8, group, "ipc_timing")) and std.mem.endsWith(u8, name, "_ns") and !std.mem.startsWith(u8, name, "clock_") and !std.mem.endsWith(u8, name, "_threshold_ns")) return true;
    if (std.mem.startsWith(u8, name, "service_lock_") and (std.mem.endsWith(u8, name, "_ns") or std.mem.eql(u8, name, "service_lock_timing_unavailable"))) return true;
    if (std.mem.eql(u8, name, "starvation_warnings") or std.mem.eql(u8, name, "scheduler_ready_waiting_max_ticks")) return true;
    if (std.mem.eql(u8, group, "summary") and (std.mem.eql(u8, name, "lock_order_violations") or std.mem.eql(u8, name, "lock_sleep_checks") or std.mem.eql(u8, name, "lock_sleep_under_lock") or std.mem.eql(u8, name, "lock_sleep_under_no_sleep_lock"))) return true;
    if (std.mem.eql(u8, group, "work") and (std.mem.eql(u8, name, "timing_unavailable") or std.mem.eql(u8, name, "critical_timing_unavailable") or std.mem.eql(u8, name, "long_callbacks"))) return true;
    return false;
}
