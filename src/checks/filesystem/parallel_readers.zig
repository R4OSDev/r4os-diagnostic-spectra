//! Explicit disposable-fixture case for shared reads and exclusive mutations.
const std = @import("std");
const r4os = @import("r4os");
const abi = r4os.abi;
const file_bytes = 1024 * 1024 + 37;
const read_bytes = 512 * 1024 + 37;
const rounds = 32;
const marker = "R4OS_READERS_FIXTURE=PRIVATE_TEST\n";

const Work = struct {
    sys: *const r4os.r4sys.Context,
    ready: *u32,
    ready_event: u64,
    start_event: u64,
    write_event: u64,
    in_flight: u32 = 0,
    done: u32 = 0,
    index: usize,
    path: [*:0]const u8,
    renamed: [*:0]const u8,
    buffer: []u8,
};
fn pattern(index: usize, seed: usize) u8 {
    return @intCast((index * 17 + index / 251 + seed) & 255);
}
fn valid(bytes: []const u8, offset: usize, seed: usize) bool {
    for (bytes, offset..) |byte, index| if (byte != pattern(index, seed)) return false;
    return true;
}
fn worker(raw: u64) callconv(.c) i32 {
    const w: *Work = @ptrFromInt(raw);
    _ = @atomicRmw(u32, w.ready, .Add, 1, .release);
    _ = w.sys.notificationNotify(w.ready_event, 1);
    if (w.sys.notificationWait(w.start_event, 0, abi.thread_wait_forever) != abi.notification_ok) return 1;
    defer @atomicStore(u32, &w.done, 1, .release);
    if (w.index == 2) {
        if (w.sys.notificationWait(w.write_event, 0, abi.thread_wait_forever) != abi.notification_ok) return 2;
        for (w.buffer, 0..) |*byte, index| byte.* = pattern(index, 91);
        if (w.sys.fileWrite(w.path, w.buffer) != w.buffer.len) return 3;
        const shorter = 96 * 1024 + 7;
        if (w.sys.fileWrite(w.path, w.buffer[0..shorter]) != shorter) return 4;
        if (w.sys.base.fileMove(w.path, w.renamed) <= 0 or w.sys.exists(w.path)) return 5;
        const info = w.sys.fileInfo(w.renamed) orelse return 6;
        if (info.size != shorter or w.sys.fileRead(w.renamed, w.buffer[0..shorter]) != shorter or !valid(w.buffer[0..shorter], 0, 91)) return 7;
        if (w.sys.base.fileMove(w.renamed, w.path) <= 0) return 8;
        return 0;
    }
    for (0..rounds) |step| {
        const offset: u32 = if (step % 2 == 0) 127 else 511;
        @atomicStore(u32, &w.in_flight, 1, .release);
        const got = w.sys.fileReadAt(w.path, offset, w.buffer);
        @atomicStore(u32, &w.in_flight, 0, .release);
        if (got != w.buffer.len or !valid(w.buffer, offset, 23 + w.index * 71)) return 9;
    }
    return 0;
}
fn mounted(sys: *const r4os.r4sys.Context, letter: u8) ?abi.StorageVolumeInfo {
    const storage = r4os.storage.Context{ .sys = sys };
    var inventory: abi.StorageInventory = .{};
    if (storage.inventory(&inventory) != 0) return null;
    var slot: u32 = 0;
    while (slot < inventory.volume_slots) : (slot += 1) {
        var volume: abi.StorageVolumeInfo = .{};
        if (storage.volume(inventory.generation, slot, &volume) == abi.storage_result_present and volume.letter == letter) return volume;
    }
    return null;
}
fn refreshedTarget(sys: *const r4os.r4sys.Context, old: abi.StorageTarget) !abi.StorageTarget {
    const storage = r4os.storage.Context{ .sys = sys };
    var inventory: abi.StorageInventory = .{};
    if (storage.inventory(&inventory) != 0) return error.TargetInventory;
    var device: abi.StorageDeviceInfo = .{};
    if (storage.device(inventory.generation, old.device.slot, &device) != abi.storage_result_present or
        !std.meta.eql(device.reference, old.device)) return error.TargetDeviceChanged;
    var slot: u32 = 0;
    while (slot < device.partition_slots) : (slot += 1) {
        var part: abi.StoragePartitionInfo = .{};
        const result = storage.partition(inventory.generation, &device.reference, slot, &part);
        if (result == 0) continue;
        if (result != abi.storage_result_present) return error.TargetPartition;
        if (part.target.partition_number != old.partition_number) continue;
        var expected = old;
        expected.layout_generation = part.target.layout_generation;
        if (!std.meta.eql(expected, part.target) or old.layout_generation == part.target.layout_generation) return error.TargetSelectionChanged;
        var after: abi.StorageInventory = .{};
        if (storage.inventory(&after) != 0 or after.generation != inventory.generation) return error.TargetInventoryChanged;
        return part.target;
    }
    return error.TargetMissing;
}
fn phase(sys: *const r4os.r4sys.Context, dev: *const r4os.r4dev.Context, letter: u8) !void {
    var paths: [5][64]u8 = undefined;
    const marker_path = try std.fmt.bufPrintZ(&paths[0], "{c}:\\TEMP\\READERS.R4S", .{letter});
    const a_path = try std.fmt.bufPrintZ(&paths[1], "{c}:\\TEMP\\READA.BIN", .{letter});
    const b_path = try std.fmt.bufPrintZ(&paths[2], "{c}:\\TEMP\\READB.BIN", .{letter});
    const write_path = try std.fmt.bufPrintZ(&paths[3], "{c}:\\TEMP\\READW.BIN", .{letter});
    const renamed_path = try std.fmt.bufPrintZ(&paths[4], "{c}:\\TEMP\\READW2.BIN", .{letter});
    var mark: [64]u8 = undefined;
    if (sys.fileRead(marker_path.ptr, &mark) != marker.len or !std.mem.eql(u8, mark[0..marker.len], marker)) return error.PrivateFixtureRequired;
    const volume = mounted(sys, letter) orelse return error.MissingMount;
    if (volume.filesystem != (if (letter == 'C') abi.storage_filesystem_ntfs else abi.storage_filesystem_fat32)) return error.WrongFilesystem;
    for ([_][*:0]const u8{ a_path.ptr, b_path.ptr }) |path| {
        const info = sys.fileInfo(path) orelse return error.MissingFile;
        if (info.size != file_bytes) return error.WrongFile;
    }
    // Never overwrite a pre-existing writer target, even in a marked fixture.
    if (sys.exists(write_path.ptr) or sys.exists(renamed_path.ptr)) return error.WriterTargetOccupied;
    defer {
        _ = sys.fileDelete(write_path.ptr);
        _ = sys.fileDelete(renamed_path.ptr);
    }
    const allocator = sys.allocator();
    const a = try allocator.alloc(u8, read_bytes);
    defer allocator.free(a);
    const b = try allocator.alloc(u8, read_bytes);
    defer allocator.free(b);
    const write = try allocator.alloc(u8, 256 * 1024 + 19);
    defer allocator.free(write);
    var events: [3]u64 = .{0} ** 3;
    var created: usize = 0;
    defer for (events[0..created]) |event| {
        _ = sys.notificationClose(event);
    };
    while (created < events.len) : (created += 1) {
        if (sys.notificationCreate(&events[created]) != abi.notification_ok) return error.NotificationCreate;
    }
    const storage = r4os.storage.Context{ .sys = sys };
    var lease: u64 = 0;
    // This separate, explicit lease makes the busy-unmount check race-free;
    // the parallel read check itself still uses the native request admissions.
    if (letter != 'C' and storage.useBegin(marker_path.ptr, &lease) != 0) return error.MountUse;
    defer if (lease != 0) {
        _ = storage.useEnd(&lease);
    };
    const before = dev.performanceSummary() orelse return error.PerformanceSnapshot;
    var ready: u32 = 0;
    var work: [3]Work = undefined;
    var handles: [3]abi.ProgramJoinHandle = undefined;
    var spawned: usize = 0;
    while (spawned < work.len) : (spawned += 1) {
        work[spawned] = .{ .sys = sys, .ready = &ready, .ready_event = events[0], .start_event = events[1], .write_event = events[2], .index = spawned, .path = switch (spawned) {
            0 => a_path.ptr,
            1 => b_path.ptr,
            else => write_path.ptr,
        }, .renamed = renamed_path.ptr, .buffer = switch (spawned) {
            0 => a,
            1 => b,
            else => write,
        } };
        if (sys.threadCreateHandle(worker, @intFromPtr(&work[spawned]), 0, 0, &handles[spawned]) != abi.thread_ok) break;
    }
    var ok = spawned == work.len;
    while (@atomicLoad(u32, &ready, .acquire) < spawned) {
        var sequence: u64 = 0;
        if (sys.notificationQuery(events[0], &sequence) != abi.notification_ok) {
            ok = false;
            break;
        }
        if (@atomicLoad(u32, &ready, .acquire) >= spawned) break;
        if (sys.notificationWait(events[0], sequence, abi.thread_wait_forever) != abi.notification_ok) {
            ok = false;
            break;
        }
    }
    if (sys.notificationNotify(events[1], 3) != abi.notification_ok) ok = false;
    var overlap = false;
    const deadline = sys.ticks() + 500;
    if (spawned == work.len) while (sys.ticks() < deadline) {
        if (@atomicLoad(u32, &work[0].done, .acquire) != 0 and @atomicLoad(u32, &work[1].done, .acquire) != 0) break;
        if (@atomicLoad(u32, &work[0].in_flight, .acquire) != 0 and @atomicLoad(u32, &work[1].in_flight, .acquire) != 0) {
            const summary = dev.performanceSummary() orelse {
                ok = false;
                break;
            };
            if (summary.fs_active_requests >= 2) {
                overlap = true;
                break;
            }
        }
        sys.taskYield();
    };
    const busy_ok = letter == 'C' or storage.unmount(&volume.reference) == abi.storage_error_busy;
    if (sys.notificationNotify(events[2], 1) != abi.notification_ok) ok = false;
    // All caller buffers, paths, events and Work remain alive until real joins.
    for (handles[0..spawned]) |*handle| {
        var code: i32 = -1;
        if (sys.threadHandleJoin(handle, abi.thread_wait_forever, &code) != abi.thread_ok) {
            sys.println("SPECTRA FILESYSTEM readers join failed; retaining live state");
            while (true) sys.sleepTicks(1);
        }
        if (code != 0) {
            sys.write("SPECTRA FILESYSTEM readers worker error=");
            sys.printI32(code);
            sys.println("");
            ok = false;
        }
    }
    while (created != 0) {
        if (sys.notificationClose(events[created - 1]) != abi.notification_ok) return error.NotificationClose;
        created -= 1;
    }
    const after = dev.performanceSummary() orelse return error.PerformanceSnapshot;
    const cache_ok = after.fs_cache_hits > before.fs_cache_hits and after.fs_cache_misses > before.fs_cache_misses;
    var mount_ok = true;
    if (letter != 'C') {
        if (storage.useEnd(&lease) != 0) return error.MountUseRelease;
        if (storage.unmount(&volume.reference) != 0) return error.Unmount;
        const target = try refreshedTarget(sys, volume.target);
        var rejected: abi.StorageVolumeRef = .{};
        if (storage.mount(&volume.target, letter, &rejected) != abi.storage_error_stale or rejected.generation != 0) return error.StaleTargetAccepted;
        var fresh: abi.StorageVolumeRef = .{};
        const mount_result = storage.mount(&target, letter, &fresh);
        if (mount_result != 0) {
            sys.write("SPECTRA FILESYSTEM readers remount error=");
            sys.printI32(mount_result);
            sys.println("");
            return error.Remount;
        }
        mount_ok = (fresh.slot != volume.reference.slot or fresh.generation != volume.reference.generation) and
            storage.unmount(&volume.reference) == abi.storage_error_stale;
        const current = mounted(sys, letter) orelse return error.RemountMissing;
        mount_ok = current.reference.slot == fresh.slot and current.reference.generation == fresh.generation and mount_ok;
        // Probe the restored mount through its newly bound ordinary read path.
        mount_ok = sys.fileReadAt(a_path.ptr, 127, a[0..1031]) == 1031 and valid(a[0..1031], 127, 23) and mount_ok;
    }
    sys.write("SPECTRA FILESYSTEM readers ");
    sys.putc(letter);
    sys.write(": ");
    sys.write(if (ok and overlap and busy_ok and mount_ok and cache_ok) "OK" else "FAILED");
    sys.write(" overlap=");
    sys.write(if (overlap) "yes" else "no");
    sys.write(" data=");
    sys.write(if (ok) "yes" else "no");
    sys.write(" writer=overwrite/truncate/rename busyUse=");
    sys.write(if (busy_ok) "yes" else "no");
    sys.write(" mountGeneration=");
    sys.write(if (mount_ok) "yes" else "no");
    sys.write(" notifications=closed hits=");
    sys.printU64(after.fs_cache_hits -| before.fs_cache_hits);
    sys.write(" misses=");
    sys.printU64(after.fs_cache_misses -| before.fs_cache_misses);
    sys.println("");
    if (!ok or !overlap or !busy_ok or !mount_ok or !cache_ok) return error.ReaderContract;
}
pub fn run(sys: *const r4os.r4sys.Context, dev: *const r4os.r4dev.Context) bool {
    var fat: u8 = 0;
    for ('D'..'Z' + 1) |candidate| {
        const letter: u8 = @intCast(candidate);
        const volume = mounted(sys, letter) orelse continue;
        if (volume.filesystem != abi.storage_filesystem_fat32) continue;
        var text: [64]u8 = undefined;
        const path = std.fmt.bufPrintZ(&text, "{c}:\\TEMP\\READERS.R4S", .{letter}) catch return false;
        var bytes: [64]u8 = undefined;
        if (sys.fileRead(path.ptr, &bytes) != marker.len or !std.mem.eql(u8, bytes[0..marker.len], marker)) continue;
        if (fat != 0) {
            sys.println("SPECTRA FILESYSTEM readers: FAILED ambiguous private FAT fixture");
            return false;
        }
        fat = letter;
    }
    if (fat == 0) {
        sys.println("SPECTRA FILESYSTEM readers: FAILED missing private FAT fixture");
        return false;
    }
    for ([_]u8{ 'C', fat }) |letter| phase(sys, dev, letter) catch |err| {
        sys.write("SPECTRA FILESYSTEM readers: FAILED reason=");
        sys.println(@errorName(err));
        return false;
    };
    sys.println("SPECTRA FILESYSTEM readers: OK files=4 readers=4 reads=128 writerTasks=2 joins=6");
    return true;
}
