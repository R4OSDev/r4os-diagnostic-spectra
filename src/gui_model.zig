//! UI policy only. A saved Standard result is bound by value; changing a
//! selection or starting work cannot retain a previous upload permission.
const std = @import("std");
pub const labels = [_][]const u8{ "Standard", "Scheduler / Synchronisierung", "Arbeitsspeicher", "IPC", "Prozesslebenszyklus", "Dateisystem / I/O" };
pub const arguments = [_][]const u8{ "", "/AREA:scheduler_sync", "/AREA:memory", "/AREA:ipc", "/AREA:lifecycle", "/AREA:filesystem_io" };
pub const Phase = enum { ready, measuring, saved, partial, failed, cancelled, uploading, uploaded, closing };
pub const SavedRun = struct {
    run_id: [36]u8,
    path: [260:0]u8 = .{0} ** 260,
    path_len: usize,
    sha256: [64]u8,
    pub fn from(id: []const u8, path: []const u8, hash: []const u8) !SavedRun {
        const prefix = "C:\\R4OS\\DATA\\BENCHMARKS\\";
        if (id.len != 36 or hash.len != 64 or path.len != prefix.len + 36 + "\\RUN.JSON".len or path.len >= 260 or
            !std.mem.startsWith(u8, path, prefix) or !std.mem.endsWith(u8, path, "\\RUN.JSON") or !std.mem.eql(u8, path[prefix.len..][0..36], id)) return error.InvalidSavedRun;
        for (id, 0..) |c, i| {
            if (i == 8 or i == 13 or i == 18 or i == 23) {
                if (c != '-') return error.InvalidSavedRun;
            } else if (!std.ascii.isHex(c) or std.ascii.isUpper(c)) return error.InvalidSavedRun;
        }
        for (hash) |c| if (!std.ascii.isHex(c) or std.ascii.isUpper(c)) return error.InvalidSavedRun;
        var result: SavedRun = .{ .run_id = undefined, .path_len = path.len, .sha256 = undefined };
        @memcpy(&result.run_id, id);
        @memcpy(result.path[0..path.len], path);
        @memcpy(&result.sha256, hash);
        return result;
    }
    pub fn pathZ(self: *const SavedRun) [:0]const u8 {
        return self.path[0..self.path_len :0];
    }
};
pub const Model = struct {
    selected: usize = 0,
    phase: Phase = .ready,
    generation: u64 = 0,
    saved: ?SavedRun = null,
    pub fn busy(self: *const Model) bool {
        return self.phase == .measuring or self.phase == .uploading or self.phase == .closing;
    }
    pub fn canUpload(self: *const Model) bool {
        return !self.busy() and self.selected == 0 and self.saved != null;
    }
    pub fn select(self: *Model, index: usize) bool {
        if (self.busy() or index >= labels.len or index == self.selected) return false;
        self.selected = index;
        self.saved = null;
        self.phase = .ready;
        self.generation +%= 1;
        return true;
    }
    pub fn start(self: *Model) bool {
        if (self.busy()) return false;
        self.generation +%= 1;
        self.saved = null;
        self.phase = .measuring;
        return true;
    }
    pub fn measured(self: *Model, generation: u64, code: i32, result: ?SavedRun) bool {
        if (self.phase != .measuring or generation != self.generation) return false;
        self.saved = null;
        self.phase = if (code == 4) .cancelled else if (code != 0) .failed else if (self.selected != 0) .partial else if (result != null) .saved else .failed;
        if (self.phase == .saved) self.saved = result;
        return true;
    }
    pub fn upload(self: *Model) bool {
        if (!self.canUpload()) return false;
        self.generation +%= 1;
        self.phase = .uploading;
        return true;
    }
    pub fn uploaded(self: *Model, generation: u64, code: i32, local_invalid: bool) bool {
        if (self.phase != .uploading or generation != self.generation) return false;
        if (local_invalid) self.saved = null;
        self.phase = if (code == 0) .uploaded else if (code == 4) .cancelled else .failed;
        return true;
    }
};
test "GUI upload permission follows the exact completed Standard and survives explicit transport retry" {
    var m: Model = .{};
    try std.testing.expect(!m.canUpload());
    try std.testing.expect(m.start());
    const generation = m.generation;
    try std.testing.expect(!m.start());
    try std.testing.expect(!m.upload());
    const id = "123e4567-e89b-42d3-a456-426614174000";
    const saved = try SavedRun.from(id, "C:\\R4OS\\DATA\\BENCHMARKS\\" ++ id ++ "\\RUN.JSON", "a" ** 64);
    try std.testing.expect(!m.measured(generation + 1, 0, saved));
    try std.testing.expect(!m.canUpload());
    try std.testing.expect(m.measured(generation, 0, saved));
    try std.testing.expect(m.canUpload());
    try std.testing.expect(m.upload());
    try std.testing.expect(!m.start());
    try std.testing.expect(!m.select(1));
    try std.testing.expect(m.uploaded(m.generation, 1, false));
    try std.testing.expect(m.canUpload());
    try std.testing.expectEqualStrings(saved.pathZ(), m.saved.?.pathZ());
    try std.testing.expect(m.upload());
    try std.testing.expect(m.uploaded(m.generation, 0, false));
    try std.testing.expect(m.select(1));
    try std.testing.expect(!m.canUpload());
}
test "partial, failed, cancelled and missing-result runs never enable GUI upload" {
    var m: Model = .{};
    for (1..labels.len) |index| {
        _ = m.select(index);
        _ = m.start();
        _ = m.measured(m.generation, 0, null);
        try std.testing.expect(m.phase == .partial and !m.canUpload());
    }
    _ = m.select(0);
    for ([_]i32{ 1, 4, 0 }) |code| {
        _ = m.start();
        _ = m.measured(m.generation, code, null);
        try std.testing.expect(!m.canUpload());
    }
}
