// Explicit physical-input regression. A host/operator supplies the announced
// key sequences; ordinary CHECK INPUT remains passive apart from key polling.
const r4os = @import("r4os");
const abi = r4os.abi;
pub const Mode = enum { modifiers, resync, overlap };

fn marker(sys: *const r4os.r4sys.Context, label: []const u8, suffix: []const u8) void {
    sys.write("SPECTRA INPUT modifiers ");
    sys.write(label);
    sys.println(suffix);
}

fn valid(event: *const abi.PhysicalKeyEvent) bool {
    return event.magic == abi.physical_key_magic and event.version == 1 and event.size == @sizeOf(abi.PhysicalKeyEvent);
}

fn drain(desk: *const r4os.r4desk.Context) bool {
    var event: abi.PhysicalKeyEvent = .{};
    for (0..512) |_| {
        const rc = desk.physicalKeyPoll(&event);
        if (rc == abi.physical_key_poll_empty) break;
        if (rc != abi.physical_key_poll_ready or !valid(&event)) return false;
    } else return false;
    for (0..512) |_| {
        if (desk.readKey() == 0) return true;
    }
    return false;
}

fn phase(sys: *const r4os.r4sys.Context, desk: *const r4os.r4desk.Context, label: []const u8, codes: []const u8, usages: []const u32, masks: []const u32, release_usage: u32, long_hold: bool) bool {
    marker(sys, label, " READY");
    const start = sys.ticks();
    var code_count: usize = 0;
    var down_count: usize = 0;
    var released = release_usage == 0;
    var last_up = false;
    var sequence: u64 = 0;
    var first_tick: u64 = 0;
    var modifier_repeats: u32 = 0;
    while (sys.ticks() -| start < sys.ticksFromMilliseconds(8000) and !sys.programShouldClose()) {
        var event: abi.PhysicalKeyEvent = .{};
        for (0..64) |_| {
            const rc = desk.physicalKeyPoll(&event);
            if (rc == abi.physical_key_poll_empty) break;
            if (rc != abi.physical_key_poll_ready or !valid(&event) or event.sequence <= sequence) return fail(sys, label, "physical stream");
            sequence = event.sequence;
            if (event.kind == abi.physical_key_kind_reset) return fail(sys, label, "unexpected reset");
            if (event.kind == abi.physical_key_kind_up) {
                if (event.key == release_usage) released = event.modifiers == 0;
                if (down_count == usages.len and event.key == usages[usages.len - 1]) last_up = true;
            }
            if (event.kind != abi.physical_key_kind_down) continue;
            if (event.key >= 0xe0) {
                if (event.flags & abi.physical_key_flag_repeat != 0) modifier_repeats += 1;
                continue;
            }
            if (down_count >= usages.len or event.key != usages[down_count] or event.modifiers != masks[down_count] or event.flags & abi.physical_key_flag_repeat != 0) return fail(sys, label, "key/modifier snapshot");
            if (down_count == 0) first_tick = event.tick;
            if (long_hold and down_count == 1 and event.tick -| first_tick < sys.ticksFromMilliseconds(750)) return fail(sys, label, "hold below 750 ms");
            down_count += 1;
        }
        for (0..64) |_| {
            const key = desk.readKey();
            if (key == 0) break;
            if (code_count >= codes.len or key != codes[code_count]) {
                sys.write("SPECTRA INPUT modifiers unexpected codepoint: ");
                sys.printU64(key);
                sys.println("");
                return fail(sys, label, "text projection");
            }
            code_count += 1;
        }
        if (code_count == codes.len and down_count == usages.len and released and last_up) {
            marker(sys, label, ": ok");
            sys.write("SPECTRA INPUT modifiers ");
            sys.write(label);
            sys.write(" modifier-repeats=");
            sys.printU64(modifier_repeats);
            sys.println("");
            return true;
        }
        sys.sleepTicks(1);
    }
    return fail(sys, label, "deadline/cancel");
}

fn fail(sys: *const r4os.r4sys.Context, label: []const u8, why: []const u8) bool {
    marker(sys, label, ": FAILED");
    sys.println(why);
    return false;
}

fn resync(sys: *const r4os.r4sys.Context, desk: *const r4os.r4desk.Context) bool {
    if (!drain(desk)) return fail(sys, "RESYNC", "initial drain");
    marker(sys, "RESET_FILL", " READY");
    const start = sys.ticks();
    var ended = false;
    // Deliberately leave physical transitions queued while consuming text.
    // Enter ends the host's bounded fill, independently of the Ctrl state.
    while (sys.ticks() -| start < sys.ticksFromMilliseconds(15000) and !sys.programShouldClose()) {
        const key = desk.readKey();
        if (key == 10) {
            ended = true;
            break;
        }
        if (key == 0) sys.sleepTicks(1);
    }
    if (!ended) return fail(sys, "RESYNC", "fill deadline/cancel");
    var reset = false;
    var sequence: u64 = 0;
    var event: abi.PhysicalKeyEvent = .{};
    for (0..512) |_| {
        const rc = desk.physicalKeyPoll(&event);
        if (rc == abi.physical_key_poll_empty) break;
        if (rc != abi.physical_key_poll_ready or !valid(&event) or event.sequence <= sequence) return fail(sys, "RESYNC", "physical stream");
        sequence = event.sequence;
        if (event.kind == abi.physical_key_kind_reset) reset = true;
        if (reset and event.modifiers != 0) return fail(sys, "RESYNC", "held state after reset");
    } else return fail(sys, "RESYNC", "drain bound");
    if (!reset) return fail(sys, "RESYNC", "no confirmed reset");
    if (!phase(sys, desk, "RESET_TAIL", &.{'a'}, &.{0x04}, &.{0}, 0, false)) return false;
    // The host now releases Ctrl and sends Enter down/up before shutdown.
    if (!phase(sys, desk, "RESET_ACK", &.{10}, &.{abi.physical_key_usage_enter}, &.{0}, 0, false)) return false;
    marker(sys, "RESYNC", ": ok");
    return true;
}

fn overlap(sys: *const r4os.r4sys.Context, desk: *const r4os.r4desk.Context) bool {
    if (!drain(desk)) return fail(sys, "START", "initial drain");
    if (!phase(sys, desk, "SHIFT_LR", &.{ 'A', 'a' }, &.{ 0x04, 0x04 }, &.{ 32, 0 }, 0, false)) return false;
    if (!phase(sys, desk, "SHIFT_RL", &.{ 'A', 'a' }, &.{ 0x04, 0x04 }, &.{ 16, 0 }, 0, false)) return false;
    if (!phase(sys, desk, "CTRL_LR", &.{ 1, 'a' }, &.{ 0x04, 0x04 }, &.{ 2, 0 }, 0, false)) return false;
    return phase(sys, desk, "CTRL_RL", &.{ 1, 'a' }, &.{ 0x04, 0x04 }, &.{ 1, 0 }, 0, false);
}

fn cases(sys: *const r4os.r4sys.Context, desk: *const r4os.r4desk.Context, mode: Mode) bool {
    if (mode == .resync) return resync(sys, desk);
    if (mode == .overlap) return overlap(sys, desk);
    if (!drain(desk)) return fail(sys, "START", "initial drain");
    if (!phase(sys, desk, "CTRL", &.{ 1, 4, 'a' }, &.{ 0x04, 0x07, 0x04 }, &.{ 1, 1, 0 }, 0xe0, true)) return false;
    if (!phase(sys, desk, "ALT", &.{ 0x85, 0x85, 9 }, &.{ 0x2b, 0x2b, 0x2b }, &.{ 4, 4, 0 }, 0xe2, true)) return false;
    if (!phase(sys, desk, "ALTGR", &.{ '@', '@', 'q' }, &.{ 0x14, 0x14, 0x14 }, &.{ 8, 8, 0 }, 0xe6, true)) return false;
    return resync(sys, desk);
}

pub fn run(sys: *const r4os.r4sys.Context, desk: *const r4os.r4desk.Context, mode: Mode) i32 {
    var old: abi.KeyboardLayoutInfo = .{};
    if (desk.keyboardLayoutCurrent(&old) < 0 or desk.keyboardLayoutSet("de_de") < 0) return 1;
    var old_name: [17:0]u8 = .{0} ** 17;
    @memcpy(old_name[0..16], &old.name);
    const passed = cases(sys, desk, mode);
    const restored = desk.keyboardLayoutSet(&old_name) >= 0;
    marker(sys, "layout-restore", if (restored) ": ok" else ": FAILED");
    marker(sys, "result", if (passed and restored) ": OK" else ": FAILED");
    return if (passed and restored) 0 else 1;
}
