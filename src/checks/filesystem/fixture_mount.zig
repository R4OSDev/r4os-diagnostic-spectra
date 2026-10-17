//! Generation-checked private filesystem fixture lookup and target refresh.
const std = @import("std");
const r4os = @import("r4os");
const abi = r4os.abi;
pub fn mounted(sys: *const r4os.r4sys.Context, letter: u8) ?abi.StorageVolumeInfo {
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
pub fn refreshedTarget(sys: *const r4os.r4sys.Context, old: abi.StorageTarget) !abi.StorageTarget {
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
