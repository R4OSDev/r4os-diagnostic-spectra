//! Only the completed child's idempotent report request can be repeated.
//! Measurement, Bind and other scene operations are never replayed here.
pub fn finish(check: anytype, target: anytype) !void {
    const original = check.deadline;
    check.deadline = @min(original, check.sys.ticks() +| check.sys.ticksFromMilliseconds(10000));
    defer check.deadline = original;
    while (true) {
        _ = check.call(.snes_finish, target, 0, 0) catch |err| {
            if (err != error.DesktopTimeout and err != error.DesktopBrokerBusy and err != error.DesktopReportPending) return err;
            if (check.sys.ticks() >= check.deadline) return err;
            // Each attempt closes its exact IPC connection. A late old job
            // cannot satisfy this new ticket; report_ready owns idempotence.
            try check.pause(50);
            continue;
        };
        return;
    }
}

const std = @import("std");
const Target = struct { instance: u32, generation: u64 };
const Clock = struct {
    now: u64 = 0,
    fn ticks(self: Clock) u64 { return self.now; }
    fn ticksFromMilliseconds(_: Clock, value: u32) u64 { return value; }
};
const Peer = struct {
    sys: Clock = .{},
    deadline: u64 = 300000,
    calls: usize = 0,
    failures: usize = 3,
    hard: ?anyerror = null,
    late: bool = false,
    expected: Target = .{ .instance = 60, .generation = 71 },
    fn call(self: *Peer, op: enum { snes_finish }, target: Target, dx: i32, dy: i32) !void {
        try std.testing.expect(op == .snes_finish and dx == 0 and dy == 0);
        try std.testing.expectEqualDeep(self.expected, target);
        if (self.sys.now >= self.deadline) return error.Timeout;
        self.calls += 1;
        if (self.hard) |err| return err;
        if (self.calls <= self.failures) {
            self.sys.now += if (self.late) 3000 else 2000;
            return if (self.late) (if (self.calls % 2 == 1) error.DesktopTimeout else error.DesktopBrokerBusy)
                else switch (self.calls) { 1 => error.DesktopTimeout, 2 => error.DesktopReportPending, else => error.DesktopBrokerBusy };
        }
    }
    fn pause(self: *Peer, milliseconds: u32) !void {
        self.sys.now += milliseconds;
        if (self.sys.now >= self.deadline) return error.Timeout;
    }
};
test "completed report retries exact target after bounded timeout without replaying child work" {
    var peer: Peer = .{};
    try finish(&peer, peer.expected);
    try std.testing.expectEqual(@as(usize, 4), peer.calls);
    try std.testing.expectEqual(@as(u64, 300000), peer.deadline);
    for ([_]anyerror{error.OwnerChanged, error.BusyOrUserActivity, error.DesktopWork}) |err| {
        peer = .{ .hard = err };
        try std.testing.expectError(err, finish(&peer, peer.expected));
        try std.testing.expectEqual(@as(usize, 1), peer.calls);
        try std.testing.expectEqual(@as(u64, 300000), peer.deadline);
    }
}
test "report retry preserves the original earlier deadline and remains finite" {
    var peer: Peer = .{ .deadline = 2500, .failures = 100, .late = true };
    try std.testing.expectError(error.DesktopTimeout, finish(&peer, peer.expected));
    try std.testing.expectEqual(@as(usize, 1), peer.calls);
    try std.testing.expectEqual(@as(u64, 2500), peer.deadline);
    peer = .{ .failures = 100, .late = true };
    try std.testing.expectError(error.DesktopBrokerBusy, finish(&peer, peer.expected));
    try std.testing.expectEqual(@as(usize, 4), peer.calls);
    try std.testing.expectEqual(@as(u64, 300000), peer.deadline);
}
