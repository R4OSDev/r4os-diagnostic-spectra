//! Copy-only bounded boot/#MC evidence. Rendering and model names are userland
//! work; absence of a valid record never proves current hardware health.
const r4os = @import("r4os");
const std = @import("std");
const a = r4os.abi;
const d = @import("mca_decode.zig");
const Output = @import("output.zig").Output;
fn observation(info: a.CpuMachineInfo, b: a.CpuMachineBank) d.Observation {
    return .{
        .vendor = info.vendor_name,
        .family = info.family,
        .model = info.model,
        .stepping = info.stepping,
        .profile = info.profile,
        .virtual = info.flags & a.cpu_machine_flag_virtual != 0,
        .format = b.format,
        .status = b.status,
        .status_after = b.status_after,
        .status_read = b.flags & a.cpu_machine_bank_status_read != 0,
        .after_read = b.flags & a.cpu_machine_bank_status_after_read != 0,
        .unstable = b.flags & a.cpu_machine_bank_unstable != 0,
        .address_read = b.flags & a.cpu_machine_bank_address_read != 0,
        .misc_read = b.flags & a.cpu_machine_bank_misc_read != 0,
        .config_read = b.flags & a.cpu_machine_bank_config_read != 0,
        .config = b.config,
        .ipid_read = b.flags & a.cpu_machine_bank_ipid_read != 0,
        .ipid = b.ipid,
        .syndrome_read = b.flags & a.cpu_machine_bank_syndrome_read != 0,
        .syndrome = b.syndrome,
    };
}
pub fn collect(dev: *const r4os.r4dev.Context, out: *Output) bool {
    if (!dev.hasFn("cpu_machine_info") or !dev.hasFn("cpu_machine_bank")) {
        out.unavailable("mca", "resident Machine Check receipt unavailable");
        return true;
    }
    var first: a.CpuMachineInfo = .{};
    if (dev.cpuMachineInfo(0, &first) != 0 or first.configured_cpus == 0 or first.configured_cpus > 64) return false;
    for (0..first.configured_cpus) |cpu| {
        var info: a.CpuMachineInfo = .{};
        if (dev.cpuMachineInfo(@intCast(cpu), &info) != 0 or info.cpu_index != cpu or info.sequence == 0 or info.sequence & 1 != 0 or info.stored_banks > a.cpu_machine_bank_limit) return false;
        out.record("machine_check", "mca", cpu, info);
        const global_valid = info.flags & a.cpu_machine_flag_status_valid != 0;
        out.record("machine_check_global", "mca", cpu, .{
            .cpu_index = cpu,
            .epoch = info.epoch,
            .capture_sequence = info.sequence,
            .origin = info.origin,
            .scope = @as([]const u8, if (info.origin == 1) "retained boot-passive scan" else if (info.origin == 2) "terminal delivered Machine Check" else "unavailable"),
            .restart_ip_valid = @as(?bool, if (global_valid) info.mcg_status & 1 != 0 else null),
            .error_ip_valid = @as(?bool, if (global_valid) info.mcg_status & 2 != 0 else null),
            .machine_check_in_progress = @as(?bool, if (global_valid) info.mcg_status & 4 != 0 else null),
            .bank_count_valid = info.flags & a.cpu_machine_flag_cap_valid != 0,
            .cr4_mce_enabled_at_capture = info.flags & a.cpu_machine_flag_mce_enabled != 0,
            .atomic_hardware_bank_transaction = false,
        });
        if (dev.hasFn("cpu_power_info")) {
            var model: a.CpuPowerInfo = .{};
            if (dev.cpuPowerInfo(@intCast(cpu), info.epoch, &model) == 0 and model.cpu_index == cpu and model.epoch == info.epoch) out.record("machine_check_model", "mca", cpu, .{
                .cpu = cpu,
                .epoch = info.epoch,
                .profile = model.profile,
                .documented_mca_model = model.flags & a.cpu_power_flag_mca_model != 0,
                .documented_smca_model = model.flags & a.cpu_power_flag_smca_model != 0,
                .actual_bank_capability = false,
            });
        }
        for (0..info.stored_banks) |index| {
            var bank: a.CpuMachineBank = .{};
            if (dev.cpuMachineBank(@intCast(cpu), info.epoch, info.sequence, @intCast(index), &bank) != 0 or bank.cpu_index != cpu or bank.epoch != info.epoch or bank.sequence != info.sequence or bank.bank_index != index) return false;
            out.record("machine_check_bank", "mca", index, bank);
            out.record("machine_check_decoded", "mca", index, .{
                .cpu_index = cpu,
                .epoch = info.epoch,
                .capture_sequence = info.sequence,
                .bank_index = index,
                .decoded = d.decode(observation(info, bank)),
            });
        }
        var after: a.CpuMachineInfo = .{};
        if (dev.cpuMachineInfo(@intCast(cpu), &after) != 0 or after.sequence != info.sequence or after.epoch != info.epoch) {
            out.unavailable("mca", "capture changed while copying banks; retry explicitly");
            return false;
        }
    }
    out.message("mca", "Passive retained boot/terminal evidence; no current-health, atomic bank transaction, physical-address or general recovery claim. No status cleared. A delivered #MC is terminal even if a bank reports corrected data.", false);
    return true;
}
pub fn check(app: *r4os.App, out: *Output) i32 {
    const passed = d.checkFixtures();
    out.record("machine_check_decoder", "mca", 0, .{ .synthetic = true, .cases = d.fixture_count, .passed = passed, .hardware_injection = false });
    const dev = app.devicesLowLevel() orelse return 2;
    if (!dev.hasFn("cpu_machine_info") or !dev.hasFn("cpu_machine_bank")) {
        out.unavailable("mca", "resident Machine Check receipt unavailable");
        return 2;
    }
    const headers = checkCopies(&dev);
    out.record("machine_check_copy_contract", "mca", 0, .{ .passed = headers, .passive = true, .hardware_injection = false });
    const copied = collect(&dev, out);
    out.message("mca", if (passed and headers and copied) "SPECTRA MCA: ok (synthetic decoder and passive exact capture copies; no hardware error injection)" else "SPECTRA MCA: FAILED", false);
    return if (passed and headers and copied) 0 else 1;
}
fn same(comptime T: type, left: *const T, right: *const T) bool {
    return std.mem.eql(u8, std.mem.asBytes(left), std.mem.asBytes(right));
}
fn checkCopies(dev: *const r4os.r4dev.Context) bool {
    if (!dev.hasFn("cpu_machine_info") or !dev.hasFn("cpu_machine_bank")) return false;
    const sentinel: u64 = 0x8532_1122_3344_5566;
    var info: extern struct { value: a.CpuMachineInfo = .{ .rip = sentinel }, tail: u64 = sentinel } = .{};
    info.value.size = @sizeOf(@TypeOf(info));
    if (dev.cpuMachineInfo(0, &info.value) != 0 or info.tail != sentinel or info.value.size != @sizeOf(a.CpuMachineInfo)) return false;
    for (0..3) |mode| {
        var invalid = info;
        switch (mode) {
            0 => invalid.value.version = 2,
            1 => invalid.value.size = @sizeOf(a.CpuMachineInfo) - 1,
            else => {},
        }
        const before = invalid;
        const result = dev.cpuMachineInfo(if (mode == 2) info.value.configured_cpus else 0, &invalid.value);
        if (result != (if (mode == 2) a.cpu_capabilities_error_index else a.cpu_capabilities_error_invalid) or !same(@TypeOf(invalid), &invalid, &before)) return false;
    }
    const epoch = info.value.epoch;
    const sequence = info.value.sequence;
    if (epoch == 0 or epoch == std.math.maxInt(u64) or sequence > std.math.maxInt(u64) - 2) return false;
    for (0..6) |mode| {
        var bank: extern struct { value: a.CpuMachineBank = .{ .status = sentinel }, tail: u64 = sentinel } = .{};
        bank.value.size = @sizeOf(@TypeOf(bank));
        switch (mode) {
            0 => bank.value.version = 2,
            1 => bank.value.size = @sizeOf(a.CpuMachineBank) - 1,
            else => {},
        }
        const before = bank;
        const expected: i32 = switch (mode) {
            0, 1 => a.cpu_capabilities_error_invalid,
            2 => a.cpu_capabilities_error_index,
            3 => a.cpu_capabilities_error_epoch,
            4 => a.cpu_capabilities_error_busy,
            else => a.cpu_capabilities_end,
        };
        const rc = dev.cpuMachineBank(if (mode == 2) info.value.configured_cpus else 0, if (mode == 3) epoch + 1 else epoch, if (mode == 4) sequence + 2 else sequence, if (mode == 5) info.value.stored_banks else 0, &bank.value);
        if (rc != expected or !same(@TypeOf(bank), &bank, &before)) return false;
    }
    if (info.value.stored_banks != 0) {
        var bank: extern struct { value: a.CpuMachineBank = .{}, tail: u64 = sentinel } = .{};
        bank.value.size = @sizeOf(@TypeOf(bank));
        if (dev.cpuMachineBank(0, epoch, sequence, 0, &bank.value) != 0 or bank.tail != sentinel or bank.value.cpu_index != 0 or bank.value.epoch != epoch or bank.value.sequence != sequence) return false;
    }
    return true;
}
