//! The same bounded two-caller admission/real-join proof for native checks.
const r4os = @import("r4os");
const Output = @import("../output.zig").Output;
pub fn Probe(comptime Report: type, comptime invoke: anytype, comptime passed: anytype, comptime busy: anytype) type {
    return struct {
        var shared_dev: r4os.r4dev.Context = undefined;
        var peer_report: Report = .{};
        var peer_started: u8 = 0;
        var peer_valid: bool = false;
        fn peer(_: u64) callconv(.c) i32 {
            @atomicStore(u8, &peer_started, 1, .release);
            peer_valid = invoke(&shared_dev, &peer_report);
            return 0;
        }
        pub fn run(app: *r4os.App, dev: *const r4os.r4dev.Context, out: *Output, kind: []const u8, group: []const u8, success: []const u8) i32 {
            shared_dev = dev.*; peer_report = .{}; peer_valid = false;
            @atomicStore(u8, &peer_started, 0, .release);
            var worker = switch (app.resources().createThread(peer, 0, 0)) {
                .handle => |value| value,
                .failure => { out.message(group, "Native admission: worker unavailable", false); return 1; },
            };
            var sys = app.system();
            for (0..2000) |_| {
                if (@atomicLoad(u8, &peer_started, .acquire) != 0) break;
                sys.sleepTicks(1);
            }
            var own: Report = .{};
            const valid = invoke(dev, &own);
            const joined = switch (worker.join(r4os.time_contract.timeoutFinite(.{ .nanoseconds = 90_000_000_000 }))) {
                .exited => |code| code == 0,
                else => false,
            };
            if (!joined) { out.message(group, "Native admission: join FAILED", false); return 1; }
            out.record(kind, group, 0, own);
            out.record(kind, group, 1, peer_report);
            const own_busy = busy(own);
            const other_busy = busy(peer_report);
            const completed = if (own_busy) peer_report else own;
            const ok = valid and peer_valid and own_busy != other_busy and passed(completed);
            out.message(group, if (ok) success else "Native admission: FAILED", false);
            return if (ok) 0 else 1;
        }
    };
}
