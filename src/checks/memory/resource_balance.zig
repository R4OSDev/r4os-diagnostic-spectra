const std = @import("std");

pub const Totals = struct {
    blocks: u64 = 0,
    program_images: u64 = 0,
    vm_ranges: u64 = 0,
    app_stacks: u64 = 0,
    reserved: u64 = 0,
    committed: u64 = 0,
    physical: u64 = 0,
    virtual: u64 = 0,
};

pub const Stack = struct {
    owner_id: u32,
    reserved: u64,
    committed: u64,
};

pub fn same(a: Totals, b: Totals) bool {
    return std.meta.eql(a, b);
}

/// A live caller keeps its grown main stack until process exit. The catalogue
/// counts each committed byte once in the virtual stack and once in its
/// physical backing. Physical backing rows can split without creating stacks.
/// Allow only that independently reported growth; retain every other original
/// balance check. Killed-child cleanup must still require zero owner blocks.
pub fn sameWithGrowingStack(a: Totals, b: Totals, before: Stack, after: Stack) bool {
    if (before.owner_id == 0 or before.owner_id != after.owner_id or
        before.reserved != after.reserved or before.committed == 0 or
        before.committed >= before.reserved or after.committed >= after.reserved or
        after.committed < before.committed or
        a.app_stacks == 0 or b.app_stacks == 0 or
        a.blocks < a.app_stacks or b.blocks < b.app_stacks)
        return false;
    const growth = after.committed - before.committed;
    if (growth > std.math.maxInt(u64) / 2) return false;
    return a.blocks - a.app_stacks == b.blocks - b.app_stacks and
        a.program_images == b.program_images and a.vm_ranges == b.vm_ranges and
        a.virtual == b.virtual and
        increasedBy(a.physical, b.physical, growth) and
        increasedBy(a.reserved, b.reserved, growth) and
        increasedBy(a.committed, b.committed, growth * 2);
}

fn increasedBy(before: u64, after: u64, delta: u64) bool {
    return after >= before and after - before == delta;
}

test "live stack growth and fragmented backing are not VM leaks" {
    const before = Totals{ .blocks = 9, .program_images = 7, .app_stacks = 2, .reserved = 50_585_600, .committed = 17_293_312, .physical = 17_031_168, .virtual = 33_554_432 };
    const stack = Stack{ .owner_id = 42, .reserved = 32 * 1024 * 1024, .committed = 256 * 1024 };
    var after = before;
    after.blocks += 5;
    after.app_stacks += 5;
    after.reserved += 64 * 1024;
    after.committed += 128 * 1024;
    after.physical += 64 * 1024;
    var grown = stack;
    grown.committed += 64 * 1024;
    try std.testing.expect(!same(before, after));
    try std.testing.expect(sameWithGrowingStack(before, after, stack, grown));
    try std.testing.expect(sameWithGrowingStack(before, before, stack, stack));
    var split = before;
    split.blocks += 1;
    split.app_stacks += 1;
    try std.testing.expect(sameWithGrowingStack(before, split, stack, stack));

    // Actual leaks and unconfirmed growth remain failures, including a leak
    // that occurs in the same run as legitimate stack growth.
    var leak = after;
    leak.blocks += 1;
    leak.vm_ranges += 1;
    try std.testing.expect(!sameWithGrowingStack(before, leak, stack, grown));
    leak = after;
    leak.committed += 4096;
    try std.testing.expect(!sameWithGrowingStack(before, leak, stack, grown));
    leak = after;
    leak.physical += 4096;
    try std.testing.expect(!sameWithGrowingStack(before, leak, stack, grown));
    leak = after;
    leak.reserved += 4096;
    try std.testing.expect(!sameWithGrowingStack(before, leak, stack, grown));
    leak = after;
    leak.virtual += 4096;
    try std.testing.expect(!sameWithGrowingStack(before, leak, stack, grown));
    leak = after;
    leak.program_images += 1;
    try std.testing.expect(!sameWithGrowingStack(before, leak, stack, grown));
    try std.testing.expect(!sameWithGrowingStack(before, after, stack, stack));
    var wrong = grown;
    wrong.owner_id += 1;
    try std.testing.expect(!sameWithGrowingStack(before, after, stack, wrong));
    wrong = grown;
    wrong.reserved += 4096;
    try std.testing.expect(!sameWithGrowingStack(before, after, stack, wrong));
    try std.testing.expect(!sameWithGrowingStack(after, before, grown, stack));
}
