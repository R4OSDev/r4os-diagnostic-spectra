//! Userland presentation of retained initial-entry/restart receipts. Queries
//! are passive and never load firmware or execute CPUID/MSR instructions.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const d = @import("microcode_decode.zig");
const Output = @import("output.zig").Output;
fn observation(info: a.CpuMicrocodeInfo) d.Observation {
    return .{ .status = info.status, .virtual = info.flags & a.cpu_microcode_flag_virtual != 0,
        .before = if (info.flags & a.cpu_microcode_flag_before_valid != 0) info.before_revision else null,
        .after = if (info.flags & a.cpu_microcode_flag_after_valid != 0) info.after_revision else null,
        .target = if (info.package_id != 0) info.target_revision else null,
        .attempts = info.write_attempts, .post_baseline = info.flags & a.cpu_microcode_flag_post_baseline != 0 };
}
fn valid(info: a.CpuMicrocodeInfo, cpu: usize) bool {
    return info.version == 1 and info.size == @sizeOf(a.CpuMicrocodeInfo) and info.cpu_index == cpu and
        info.epoch != 0 and info.sequence != 0 and info.sequence & 1 == 0 and info.reserved0 == 0 and info.flags & ~@as(u32, 2047) == 0;
}
pub fn collect(dev: *const r4os.r4dev.Context, out: *Output) bool {
    if (!dev.hasFn("cpu_microcode_info")) { out.unavailable("microcode", "early microcode receipt unavailable"); return true; }
    var first: a.CpuMicrocodeInfo = .{};
    if (dev.cpuMicrocodeInfo(0, &first) != 0 or first.configured_cpus == 0 or first.configured_cpus > 64) return false;
    for (0..first.configured_cpus) |cpu| {
        var info: a.CpuMicrocodeInfo = .{};
        if (dev.cpuMicrocodeInfo(@intCast(cpu), &info) != 0 or !valid(info, cpu)) return false;
        const v = observation(info);
        const decoded = d.decode(v);
        out.record("cpu_microcode_raw", "microcode", cpu, info);
        var hash: [64]u8 = undefined;
        const hex = "0123456789abcdef";
        for (info.package_sha256, 0..) |byte, index| { hash[index * 2] = hex[byte >> 4]; hash[index * 2 + 1] = hex[byte & 15]; }
        out.record("cpu_microcode", "microcode", cpu, .{
            .cpu_index = cpu, .epoch = info.epoch, .capture_sequence = info.sequence,
            .state = decoded.state, .virtual_revision_only = v.virtual, .before_revision = v.before, .after_revision = v.after,
            .target_revision = v.target, .minimum_revision = @as(?u32, if (info.package_id != 0) info.minimum_revision else null),
            .package_id = info.package_id, .package_hash_name = @as(?[]const u8, if (info.flags & a.cpu_microcode_flag_payload_verified != 0) &hash else null),
            .firmware_supplied = info.flags & a.cpu_microcode_flag_bundle_valid != 0,
            .update_trigger_attempts = info.write_attempts, .update_readback_confirmed = decoded.update_readback_confirmed,
            .post_baseline_captured = v.post_baseline, .raw_features_changed = info.flags & a.cpu_microcode_flag_features_changed != 0,
            .initial_boot = info.flags & a.cpu_microcode_flag_initial_boot != 0,
        });
        if (decoded.state == .inconsistent) return false;
    }
    out.message("microcode", "Passive early CPU revision evidence. Virtual values are guest-only; a supplied file is not update success. Missing reads stay unavailable. CPUID fingerprints are diagnostic; PAT/FPU/module admission uses its original owners.", false);
    return true;
}
fn copies(dev: *const r4os.r4dev.Context) bool {
    const sentinel: u64 = 0x8533_1122_3344_5566;
    var guarded: extern struct { info: a.CpuMicrocodeInfo = .{}, tail: u64 = sentinel } = .{};
    guarded.info.size = @sizeOf(@TypeOf(guarded));
    if (dev.cpuMicrocodeInfo(0, &guarded.info) != 0 or guarded.tail != sentinel or !valid(guarded.info, 0)) return false;
    for (0..3) |mode| {
        var bad = guarded;
        if (mode == 0) bad.info.version = 2;
        if (mode == 1) bad.info.size = @sizeOf(a.CpuMicrocodeInfo) - 1;
        const before = bad;
        const result = dev.cpuMicrocodeInfo(if (mode == 2) guarded.info.configured_cpus else 0, &bad.info);
        if (result != (if (mode == 2) a.cpu_capabilities_error_index else a.cpu_capabilities_error_invalid) or
            !std.mem.eql(u8, std.mem.asBytes(&before), std.mem.asBytes(&bad))) return false;
    }
    for (0..guarded.info.configured_cpus) |cpu| {
        var info: a.CpuMicrocodeInfo = .{}; var cap: a.CpuCapabilitiesInfo = .{};
        if (dev.cpuMicrocodeInfo(@intCast(cpu), &info) != 0 or dev.cpuCapabilities(@intCast(cpu), &cap) != 0 or !valid(info, cpu) or
            info.epoch != cap.epoch or info.flags & a.cpu_microcode_flag_post_baseline == 0 or
            info.flags & a.cpu_microcode_flag_post_features_fresh == 0 or
            (info.flags & a.cpu_microcode_flag_virtual != 0) != (cap.flags & a.cpu_capabilities_flag_hypervisor_present != 0)) return false;
        if (info.flags & a.cpu_microcode_flag_virtual != 0 and
            ((info.status != a.cpu_microcode_status_virtual_cpu and info.status != a.cpu_microcode_status_package_rejected) or info.write_attempts != 0)) return false;
    }
    return true;
}
pub fn check(app: *r4os.App, out: *Output) i32 {
    const dev = app.devicesLowLevel() orelse return 2;
    if (!dev.hasFn("cpu_microcode_info")) { out.unavailable("microcode", "early microcode receipt unavailable"); return 2; }
    const decoded = d.checkFixtures(); const copied = copies(&dev);
    out.record("cpu_microcode_contract", "microcode", 0, .{ .passed = decoded and copied, .synthetic_decoder_cases = d.fixture_count, .passive_copy = true, .hardware_update_injection = false });
    const collected = collect(&dev, out);
    out.message("microcode", if (decoded and copied and collected) "SPECTRA MICROCODE: ok (synthetic presentation and passive exact revision receipts)" else "SPECTRA MICROCODE: FAILED", false);
    return if (decoded and copied and collected) 0 else 1;
}
comptime {
    if (a.cpu_microcode_status_virtual_cpu != @intFromEnum(d.State.virtual_cpu) or
        a.cpu_microcode_status_updated != @intFromEnum(d.State.updated) or
        a.cpu_microcode_status_firmware_prerequisite != @intFromEnum(d.State.firmware_prerequisite) or
        a.cpu_microcode_status_identity_changed != @intFromEnum(d.State.identity_changed)) @compileError("Microcode status contract drift");
}
