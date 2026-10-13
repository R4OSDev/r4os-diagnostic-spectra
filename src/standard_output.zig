const std = @import("std");
const Output = @import("output.zig").Output;
const model = @import("standard_model.zig");
const reference_api = @import("standard_reference.zig");
fn record(out: *Output, kind: []const u8) void {
    out.write("{\"schema\":\"r4os.spectra.standard\",\"schema_version\":1,\"kind\":");
    out.string(kind);
}
fn str(out: *Output, name: []const u8, value: []const u8) void {
    out.write(",\"");
    out.write(name);
    out.write("\":");
    out.string(value);
}
fn number(out: *Output, name: []const u8, value: anytype) void {
    out.write(",\"");
    out.write(name);
    out.write("\":\"");
    out.number(value);
    out.write("\"");
}
fn optionalNumber(out: *Output, name: []const u8, value: ?u64) void {
    if (value) |v| number(out, name, v) else {
        out.write(",\"");
        out.write(name);
        out.write("\":null");
    }
}
fn reason(out: *Output, why: ?[]const u8) void {
    out.write(",\"failure_reason\":");
    if (why) |text| out.string(text) else out.write("null");
}
fn quantity(out: *Output, name: []const u8, elapsed: u64, operations: u64, usable: bool) void {
    out.write(",\"");
    out.write(name);
    out.write("\":");
    if (!usable) {
        out.write("null");
        return;
    }
    const scaled = @as(u128, elapsed) * 1_000_000 / operations;
    out.write("\"");
    out.number(scaled / 1_000_000);
    out.write(".");
    var bytes: [6]u8 = undefined;
    out.write(std.fmt.bufPrint(&bytes, "{d:0>6}", .{scaled % 1_000_000}) catch unreachable);
    out.write("\"");
}
pub fn render(out: *Output, samples: *const [5][6]model.Sample, metrics: *const [5]model.Metric, reference: reference_api.Reference, config: reference_api.Config, exit_code: i32, beginning: anytype) void {
    if (out.format == .json) {
        record(out, "header");
        str(out, "suite_version", model.suite_version);
        str(out, "scoring_version", model.scoring_version);
        str(out, "spectra_version", "0.1.1");
        str(out, "instrumentation_mode", if (out.detail orelse false) "detail" else "base");
        str(out, "cache_state", model.cache_state);
        number(out, "warmup_runs", 1);
        number(out, "repetitions", 5);
        number(out, "vcpus", 4);
        number(out, "settle_ms", config.settle_ms);
        number(out, "guest_started_ns", beginning.instant_ns);
        str(out, "reference_mode", if (config.self_reference) "self" else if (config.path[0] != 0) "file" else "none");
        str(out, "comparison_key", config.key[0..config.key_len]);
        out.write(",\"workloads\":{");
        for (model.area_ids, model.workload_ids, 0..) |area, workload, i| {
            if (i != 0) out.write(",");
            out.string(area);
            out.write(":");
            out.string(workload);
        }
        out.write("}}\n");
    } else {
        out.write("Spectra standard benchmark ");
        out.write(model.suite_version);
        out.write(" (1 warmup, 5 measurements per area)\r\n");
    }
    var scores: [5]?f64 = .{null} ** 5;
    for (model.area_ids, metrics, samples, 0..) |area, metric, raw, index| {
        if (out.format == .json) {
            for (raw, 0..) |sample, i| {
                record(out, "sample");
                str(out, "area_id", area);
                str(out, "metric_id", model.metric_id);
                str(out, "phase", if (i == 0) "warmup" else "measurement");
                number(out, "sample_index", if (i == 0) 0 else i - 1);
                str(out, "status", if (sample.reason == null) "ok" else if (std.mem.eql(u8, sample.reason.?, "not-run")) "skipped" else "failed");
                reason(out, sample.reason);
                optionalNumber(out, "elapsed_ns", if (sample.elapsed_ns != 0) sample.elapsed_ns else null);
                number(out, "operation_count", sample.operations);
                number(out, "bytes_processed", sample.bytes);
                str(out, "clock_source", switch (sample.clock_source) {
                    1 => "TSC",
                    2 => "HPET",
                    3 => "periodic-event",
                    else => "unavailable",
                });
                optionalNumber(out, "clock_generation", if (sample.clock_generation != 0) sample.clock_generation else null);
                optionalNumber(out, "clock_resolution_ns", if (sample.clock_resolution_ns != 0) sample.clock_resolution_ns else null);
                optionalNumber(out, "observer_overhead_ns", sample.observer_overhead_ns);
                quantity(out, "value", sample.elapsed_ns, model.operation_counts[index], sample.reason == null);
                out.write("}\n");
            }
            record(out, "metric");
            str(out, "area_id", area);
            str(out, "metric_id", model.metric_id);
            str(out, "metric_version", "1");
            str(out, "unit", "ns/operation");
            str(out, "direction", "lower_is_better");
            out.write(",\"primary\":true,\"weight\":\"1\"");
            str(out, "status", if (metric.reason == null) "ok" else if (std.mem.eql(u8, metric.reason.?, "not-run")) "skipped" else "failed");
            reason(out, metric.reason);
            number(out, "sample_count", metric.count);
            quantity(out, "median_value", metric.median_ns, model.operation_counts[index], metric.reason == null);
            quantity(out, "min_value", metric.minimum_ns, model.operation_counts[index], metric.reason == null);
            quantity(out, "max_value", metric.maximum_ns, model.operation_counts[index], metric.reason == null);
            quantity(out, "mad_value", metric.mad_ns, model.operation_counts[index], metric.reason == null);
            out.write(",\"checks\":{\"work_complete\":");
            out.write(if (metric.reason == null) "true" else "false");
            out.write(",\"clock_valid\":");
            out.write(if (metric.reason == null) "true" else "false");
            out.write(",\"cleanup_confirmed\":");
            out.write(if (metric.reason == null) "true" else "false");
            out.write("}}\n");
        } else {
            out.write(area);
            out.write(": ");
            if (metric.reason) |why| {
                out.write("unavailable (");
                out.write(why);
                out.write(")");
            } else {
                out.number(metric.median_ns / model.operation_counts[index]);
                out.write(" ns/operation; min/median/max=");
                out.number(metric.minimum_ns);
                out.write("/");
                out.number(metric.median_ns);
                out.write("/");
                out.number(metric.maximum_ns);
                out.write(" ns; MAD=");
                out.number(metric.mad_ns);
                out.write(" ns");
            }
            out.write("\r\n");
        }
        if (metric.reason == null) {
            if (config.self_reference) scores[index] = 100 else if (reference.reason == null) scores[index] = model.score(reference.values[index].?, @as(f64, @floatFromInt(metric.median_ns)) / @as(f64, @floatFromInt(model.operation_counts[index])));
        }
    }
    const total = if (exit_code == 0) model.overall(scores) else null;
    for (0..6) |i| {
        const score_value = if (i == 5) total else scores[i];
        const why: ?[]const u8 = if (score_value != null) null else if (i == 5) "all-five-valid-areas-required" else metrics[i].reason orelse reference.reason orelse "invalid-reference-value";
        if (out.format == .json) {
            record(out, "score");
            str(out, "area_id", if (i == 5) "overall" else model.area_ids[i]);
            str(out, "scoring_version", model.scoring_version);
            out.write(",\"baseline_run_id\":");
            if (reference.reason == null) out.string(&reference.run_id) else out.write("null");
            str(out, "status", if (score_value != null) "valid" else "unavailable");
            out.write(",\"reason\":");
            if (why) |text| out.string(text) else out.write("null");
            out.write(",\"score\":");
            if (score_value) |v| {
                out.write("\"");
                out.number(v);
                out.write("\"");
            } else out.write("null");
            out.write("}\n");
        } else {
            out.write(if (i == 5) "overall" else model.area_ids[i]);
            out.write(" score=");
            if (score_value) |v| out.number(v) else {
                out.write("null (");
                out.write(why.?);
                out.write(")");
            }
            out.write("\r\n");
        }
    }
    if (out.format == .json) {
        record(out, "result");
        number(out, "exit_code", exit_code);
        str(out, "status", if (exit_code == 0 and config.area != null) "incomplete" else if (exit_code == 0) "completed" else if (exit_code == 4) "cancelled" else "failed");
        out.write("}\n");
    } else {
        out.write("SPECTRA STANDARD result=");
        out.write(if (exit_code == 0) "OK" else if (exit_code == 4) "CANCELLED" else "FAILED");
        out.write("\r\n");
    }
}
