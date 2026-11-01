//! Client-owned, create-only Schema 1 export after the measured worker exits.
//! Failed exports keep the worker's original record file for diagnosis.
const std = @import("std");
const r4os = @import("r4os");
const identity_api = @import("standard_identity.zig");
const run_json = @import("standard_run_json.zig");
const child_path = @import("standard_workloads.zig").child_path;
const root_dir = "C:\\R4OS\\DATA\\BENCHMARKS";

pub const Result = struct {
    run_id: [36]u8,
    path: [260:0]u8,
    path_len: usize,
    sha256: [64]u8,
};

const Hash = struct { sha256: [64]u8, bytes: u64 };

fn hashFile(sys: *const r4os.r4sys.Context, path: [:0]const u8) !Hash {
    const info = sys.fileInfo(path) orelse return error.ArtifactMissing;
    if (info.is_dir != 0 or info.size == 0 or info.size > 64 * 1024 * 1024) return error.ArtifactSize;
    var sha = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [8192]u8 = undefined;
    var offset: u64 = 0;
    while (offset < info.size) {
        const count: usize = @intCast(@min(buffer.len, info.size - offset));
        if (sys.fileReadAt(path, @intCast(offset), buffer[0..count]) != count) return error.ArtifactRead;
        sha.update(buffer[0..count]);
        offset += count;
    }
    var digest: [32]u8 = undefined;
    sha.final(&digest);
    return .{ .sha256 = std.fmt.bytesToHex(digest, .lower), .bytes = info.size };
}

fn utc(value: r4os.abi.TimeState) ![20]u8 {
    if (value.valid == 0 or value.year < 2020 or value.year > 9999 or value.month < 1 or value.month > 12 or
        value.hour > 23 or value.minute > 59 or value.second > 59) return error.UtcUnavailable;
    const leap = value.year % 4 == 0 and (value.year % 100 != 0 or value.year % 400 == 0);
    const days: u8 = switch (value.month) {
        2 => if (leap) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
    if (value.day < 1 or value.day > days) return error.UtcUnavailable;
    var result: [20]u8 = undefined;
    _ = std.fmt.bufPrint(&result, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        value.year, value.month, value.day, value.hour, value.minute, value.second,
    }) catch return error.UtcUnavailable;
    return result;
}

fn runId() ![36]u8 {
    var bytes: [16]u8 = undefined;
    if (!r4os.secure_random.fill(&bytes)) return error.EntropyUnavailable;
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    const hex = std.fmt.bytesToHex(bytes, .lower);
    var value: [36]u8 = undefined;
    @memcpy(value[0..8], hex[0..8]);
    value[8] = '-';
    @memcpy(value[9..13], hex[8..12]);
    value[13] = '-';
    @memcpy(value[14..18], hex[12..16]);
    value[18] = '-';
    @memcpy(value[19..23], hex[16..20]);
    value[23] = '-';
    @memcpy(value[24..36], hex[20..32]);
    return value;
}

fn readRecords(allocator: std.mem.Allocator, sys: *const r4os.r4sys.Context, path: [:0]const u8) ![]u8 {
    const info = sys.fileInfo(path) orelse return error.RecordsMissing;
    if (info.is_dir != 0 or info.size == 0 or info.size > 256 * 1024) return error.RecordsSize;
    const bytes = try allocator.alloc(u8, @intCast(info.size));
    if (sys.fileRead(path, bytes) != info.size) return error.RecordsRead;
    return bytes;
}

fn ensureDirectory(sys: *const r4os.r4sys.Context, path: [:0]const u8) !void {
    _ = sys.dirCreate(path);
    const info = sys.fileInfo(path) orelse return error.ExportDirectory;
    if (info.is_dir == 0) return error.ExportDirectory;
}

fn publish(sys: *const r4os.r4sys.Context, staged: [:0]const u8, target: [:0]const u8, bytes: []const u8) ![64]u8 {
    if (sys.exists(staged) or sys.exists(target)) return error.ExportExists;
    if (sys.fileStreamBegin(staged, r4os.abi.file_stream_open_create) != 0) return error.ExportOpen;
    var active = true;
    defer {
        if (active) _ = sys.fileStreamAbort(staged);
    }
    var offset: u64 = 0;
    while (offset < bytes.len) {
        const count = @min(8192, bytes.len - @as(usize, @intCast(offset)));
        const part = bytes[@intCast(offset)..][0..count];
        if (sys.fileStreamWrite(staged, offset, part, 0) != count) return error.ExportWrite;
        offset += count;
    }
    if (sys.fileStreamFinish(staged, bytes.len, 0) != 0) return error.ExportFinish;
    active = false;
    if (sys.fileRename(staged, target) <= 0) return error.ExportPublish;
    const stored = try hashFile(sys, target);
    if (stored.bytes != bytes.len) return error.ExportReadback;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const expected = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &stored.sha256, &expected)) return error.ExportReadback;
    return expected;
}

pub fn create(app: *r4os.App, records_path: [:0]const u8, started: r4os.abi.TimeState, finished: r4os.abi.TimeState, custom_reference_key: ?[]const u8) !Result {
    const sys = app.system();
    const dev = app.devicesLowLevel() orelse return error.HardwareApiUnavailable;
    var arena = std.heap.ArenaAllocator.init(sys.allocator());
    defer arena.deinit();
    const a = arena.allocator();
    const raw = try readRecords(a, &sys, records_path);
    const first_end = std.mem.indexOfScalar(u8, raw, '\n') orelse return error.RecordsIncomplete;
    const header = try std.json.parseFromSlice(std.json.Value, a, raw[0..first_end], .{});
    if (header.value != .object) return error.RecordsIncomplete;
    const vcpus_value = header.value.object.get("vcpus") orelse return error.RecordsIncomplete;
    if (vcpus_value != .string) return error.RecordsIncomplete;
    const vcpus = vcpus_value.string;
    const start = try utc(started);
    const end = try utc(finished);
    if (std.mem.order(u8, &end, &start) == .lt) return error.UtcMovedBackwards;
    const identity = try identity_api.derive(app);
    const id = try runId();
    var module_buffer: [260:0]u8 = .{0} ** 260;
    const module_len = sys.programModulePath(&module_buffer);
    if (module_len < 4 or module_len >= @as(i32, @intCast(module_buffer.len))) return error.ModulePathUnavailable;
    module_buffer[@intCast(module_len)] = 0;
    const spectra_hash = try hashFile(&sys, module_buffer[0..@intCast(module_len) :0]);
    const fixture_hash = try hashFile(&sys, child_path);
    var release_buffer: [128]u8 = undefined;
    const release_info = sys.fileInfo("C:\\R4OS\\CONFIG\\VERSION.R4S") orelse return error.ReleaseVersionUnavailable;
    if (release_info.size == 0 or release_info.size > release_buffer.len) return error.ReleaseVersionUnavailable;
    if (sys.fileRead("C:\\R4OS\\CONFIG\\VERSION.R4S", release_buffer[0..@intCast(release_info.size)]) != release_info.size) return error.ReleaseVersionUnavailable;
    const release_version = r4os.version_info.parseReleaseVersion(release_buffer[0..@intCast(release_info.size)]) orelse return error.ReleaseVersionUnavailable;
    const kernel = dev.kernelVersion() orelse return error.KernelVersionUnavailable;
    var kernel_buffer: [48]u8 = undefined;
    const kernel_version = r4os.version_info.formatKernelVersion(kernel, &kernel_buffer) orelse return error.KernelVersionUnavailable;
    const memory = dev.memoryPressure() orelse return error.MemoryInfoUnavailable;
    if (memory.total_physical_bytes == 0) return error.MemoryInfoUnavailable;
    const drive = sys.driveInfo(2) orelse return error.StorageInfoUnavailable;
    if (drive.mounted == 0 or drive.letter != 'C' or drive.kind != 3) return error.StorageInfoUnavailable;
    var cpu: r4os.abi.CpuCapabilitiesInfo = .{};
    if (dev.cpuCapabilities(0, &cpu) != 0) return error.CpuInfoUnavailable;
    const hypervisor = cpu.flags & r4os.abi.cpu_capabilities_flag_hypervisor_present != 0;
    const hypervisor_name = std.mem.trim(u8, std.mem.sliceTo(&cpu.hypervisor_name, 0), " ");
    const backend: ?[]const u8 = if (!hypervisor) null else if (std.mem.startsWith(u8, hypervisor_name, "KVM")) "kvm" else if (std.mem.startsWith(u8, hypervisor_name, "TCG")) "tcg" else return error.UnsupportedVirtualMachine;
    const Qemu = struct { version: []const u8, backend: []const u8 };
    const qemu: ?Qemu = if (backend) |name| .{ .version = "unavailable-in-guest", .backend = name } else null;
    const cpu_brand = std.mem.trim(u8, std.mem.sliceTo(&cpu.brand_name, 0), " ");
    const ram_text = try std.fmt.allocPrint(a, "{d}", .{memory.total_physical_bytes});
    const comparison = try run_json.comparisonKey(a, &fixture_hash.sha256);
    const chosen_comparison = custom_reference_key orelse comparison[0..];
    const environment_bytes = try std.json.Stringify.valueAlloc(a, .{
        .execution = if (backend == null) "native" else "qemu",
        .vcpus = vcpus,
        .ram_bytes = ram_text,
        .cpu_policy = "all-available-v1",
        .measurement = "parallel-wall-ns-per-operation-v3",
        .filesystem = "ntfs",
        .settle_ms = "200",
        .qemu = qemu,
        .storage = .{ .filesystem = "ntfs", .volume = "C:", .workload = "spectra-standard-3" },
        .workloads = .{
            .scheduler_sync = "allcpu-notification-ready-roundtrip-16384-v3",
            .memory = "allcpu-demand-vm-512x128k-v3",
            .ipc = "allcpu-kernel-dns-status-16384-v3",
            .lifecycle = "allcpu-owned-fixture-32-v3",
            .filesystem_io = "allcpu-ntfs-stream-8x64k-v3",
            .lifecycle_fixture_sha256 = fixture_hash.sha256[0..],
        },
        .cache_state = "parallel-active-per-area-1s-3batches-v3",
        .warmup_runs = "1",
        .warmup_min_ns = "1000000000",
        .warmup_min_batches = "3",
        .repetitions = "5",
        .cpu = .{ .vendor = std.mem.sliceTo(&cpu.vendor_name, 0), .brand = cpu_brand },
    }, .{});
    const environment = try std.json.parseFromSlice(std.json.Value, a, environment_bytes, .{});
    const artifact_bytes = try std.json.Stringify.valueAlloc(a, .{
        .{ .component = "spectra", .sha256 = spectra_hash.sha256[0..], .bytes = spectra_hash.bytes },
        .{ .component = "lifecycle-fixture", .sha256 = fixture_hash.sha256[0..], .bytes = fixture_hash.bytes },
    }, .{});
    const artifacts = try std.json.parseFromSlice(std.json.Value, a, artifact_bytes, .{});
    const run_bytes = try run_json.build(a, raw, .{
        .run_id = &id,
        .host_id = &identity.host_id,
        .started_at_utc = &start,
        .finished_at_utc = &end,
        .release_version = release_version,
        .kernel_version = kernel_version,
        .environment_id = if (backend == null) "r4os-native-standard3-v1" else "r4os-qemu-standard3-v1",
        .comparison_key = chosen_comparison,
        .environment = environment.value,
        .artifacts = artifacts.value,
    });
    const finished_bytes = try std.fmt.allocPrint(a, "{s}\n", .{run_bytes});
    try ensureDirectory(&sys, "C:\\R4OS\\DATA");
    try ensureDirectory(&sys, root_dir);
    var directory: [260:0]u8 = .{0} ** 260;
    const run_dir = try std.fmt.bufPrintZ(&directory, root_dir ++ "\\{s}", .{&id});
    try ensureDirectory(&sys, run_dir);
    var staged_raw: [260:0]u8 = .{0} ** 260;
    var final_raw: [260:0]u8 = .{0} ** 260;
    const raw_stage = try std.fmt.bufPrintZ(&staged_raw, "{s}\\RECORDS.TMP", .{run_dir});
    const raw_target = try std.fmt.bufPrintZ(&final_raw, "{s}\\RECORDS.NDJSON", .{run_dir});
    _ = try publish(&sys, raw_stage, raw_target, raw);
    var staged_run: [260:0]u8 = .{0} ** 260;
    var final_run: [260:0]u8 = .{0} ** 260;
    const run_stage = try std.fmt.bufPrintZ(&staged_run, "{s}\\RUN.TMP", .{run_dir});
    const run_target = try std.fmt.bufPrintZ(&final_run, "{s}\\RUN.JSON", .{run_dir});
    const saved_hash = try publish(&sys, run_stage, run_target, finished_bytes);
    var result: Result = .{ .run_id = id, .path = .{0} ** 260, .path_len = run_target.len, .sha256 = saved_hash };
    @memcpy(result.path[0..run_target.len], run_target);
    return result;
}
