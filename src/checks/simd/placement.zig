//! Set accepts a pending request. Require the actual saved-context handoff
//! before admitting a register window; no register oracle runs while waiting.
const r4os = @import("r4os");
const a = r4os.abi;
pub fn cpu0(sys: *const r4os.r4sys.Context) bool {
    var own: a.ProgramJoinHandle = .{};
    if (sys.threadCurrentHandle(&own) != a.thread_ok) return false;
    var expected: ?u64 = null;
    for (0..64) |_| {
        var info: a.ThreadPlacementInfo = .{};
        if (sys.threadPlacementGet(&own, &info, &.{}) != a.thread_ok) return false;
        if (expected) |revision| {
            if (info.request_revision != revision) return false;
        } else expected = info.request_revision;
        if (info.home_cpu == 0 and info.running_cpu == 0 and info.request_revision == info.applied_revision and info.flags & a.thread_placement_flag_pending == 0) return true;
        sys.sleepTicks(1);
    }
    return false;
}
