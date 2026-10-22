//! The only transport operations needed for a passive broker copy.
const std = @import("std");
const wire = @import("desktop_diagnostics");
pub const Opened = struct { handle: u32, instance: u32 };
pub fn read(backend: anytype) !wire.Snapshot {
    const opened = try backend.open();
    const result = copyCurrent(backend, opened);
    // One exact connection, including refusals. A failed close is not a
    // successful snapshot and must not be hidden by an earlier copy error.
    try backend.close(opened.handle);
    return result;
}
fn copyCurrent(backend: anytype, opened: Opened) !wire.Snapshot {
    var bytes: [wire.size]u8 = undefined;
    const response = try backend.copy(opened.handle, &bytes);
    const snapshot = try wire.decode(response);
    if (snapshot.service_instance != opened.instance or !backend.current(snapshot)) return error.OwnerChanged;
    return snapshot;
}

test "passive client refuses incomplete old or changed peers and closes its exact connection" {
    const Peer = struct {
        const Mode = enum { current, active, absent, truncated, old, changed, wrong_service, close_refused };
        mode: Mode = .current,
        opens: u32 = 0,
        copies: u32 = 0,
        closes: u32 = 0,
        pub fn open(self: *@This()) !Opened {
            if (self.mode == .absent) return error.Unavailable;
            self.opens += 1;
            return .{ .handle = 5, .instance = 7 };
        }
        pub fn copy(self: *@This(), handle: u32, out: []u8) ![]const u8 {
            try std.testing.expectEqual(@as(u32, 5), handle);
            self.copies += 1;
            var snapshot: wire.Snapshot = .{ .service_instance = if (self.mode == .wrong_service) 8 else 7,
                .endpoint = 5, .service_generation = 11 };
            if (self.mode == .active) {
                snapshot.flags = wire.owner_valid;
                snapshot.desktop_instance = 12;
                snapshot.desktop_generation = 99;
                snapshot.desktop_epoch = 99;
            }
            const bytes = try wire.encode(out, snapshot);
            if (self.mode == .old) out[4] = 0;
            return if (self.mode == .truncated) bytes[0..127] else bytes;
        }
        pub fn current(self: *@This(), _: wire.Snapshot) bool { return self.mode != .changed; }
        pub fn close(self: *@This(), handle: u32) !void {
            try std.testing.expectEqual(@as(u32, 5), handle);
            self.closes += 1;
            if (self.mode == .close_refused) return error.CloseUnconfirmed;
        }
    };
    inline for (std.meta.tags(Peer.Mode)) |mode| {
        var peer: Peer = .{ .mode = mode };
        if (mode == .current or mode == .active) {
            const snapshot = try read(&peer);
            try std.testing.expectEqual(@as(u32, if (mode == .active) wire.owner_valid else 0), snapshot.flags);
            try std.testing.expectEqual(@as(u64, if (mode == .active) 99 else 0), snapshot.desktop_generation);
        } else if (read(&peer)) |_| return error.ExpectedRefusal else |_| {}
        try std.testing.expectEqual(peer.opens, peer.closes);
        try std.testing.expectEqual(peer.opens, peer.copies);
    }
}
