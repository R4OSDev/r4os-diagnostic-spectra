//! Explicit private runner option. Default CHECK/BENCH never starts a host.
const r = @import("r4os");
const a = r.abi;
const Check = @import("desktop_check.zig").Check;
const passive = @import("desktop_diagnostics");
pub const Owned = struct {
    handle: a.ProgramProcessHandle = .{},
    pub fn start(self: *Owned, check: *Check) !void {
        const before = try check.queryDesktop();
        if (before.flags & passive.owner_valid != 0) return error.ExistingDesktop;
        if (check.sys.programSpawnHandle("C:\\R4OS\\SOFTWARE\\DESKTOP\\R4DESK.R4X", "/CHECK-ISOLATED", .gui, &self.handle) != 0 or self.handle.instance_id == 0)
            return error.DesktopSpawn;
        const start_tick = check.sys.ticks();
        while (true) {
            const current = try check.queryDesktop();
            if (current.flags & passive.owner_valid != 0) {
                if (current.desktop_instance != self.handle.instance_id or current.desktop_generation != self.handle.generation) return error.DesktopOwnerChanged;
                check.out.record("owned-desktop", "DESKTOP", 0, .{ .handle = self.handle, .explicit_isolated_start = true });
                return;
            }
            if (check.sys.ticks() -% start_tick >= check.sys.ticksFromMilliseconds(10000)) return error.DesktopStartTimeout;
            try check.pause(50);
        }
    }
    pub fn close(self: *Owned, check: *Check) bool {
        if (self.handle.instance_id == 0) return true;
        var done: a.ProgramProcessCompletion = .{};
        const current = check.sys.programHandleWait(&self.handle, 0, &done);
        if (current == a.program_handle_error_timeout) {
            const state = check.queryDesktop() catch return false;
            // A user-created window makes this a foreign session. Keep the
            // host alive instead of closing it underneath another application.
            if (state.flags & passive.owner_valid != 0 and
                (state.desktop_instance != self.handle.instance_id or state.desktop_generation != self.handle.generation or state.window_count != 0)) return false;
            _ = check.sys.programHandleRequestClose(&self.handle);
            if (check.sys.programHandleWait(&self.handle, check.sys.ticksFromMilliseconds(5000), &done) != 0) return false;
        } else if (current != 0) return false;
        if (done.handle.instance_id != self.handle.instance_id or done.handle.generation != self.handle.generation or done.sequence == 0) return false;
        const sequence = done.sequence;
        const code = done.exit_code;
        const started = check.sys.ticks();
        while (true) {
            const status = check.sys.programHandleReap(&self.handle, &done);
            if (status == 0) break;
            if (status != a.program_handle_error_would_block or check.sys.ticks() -% started >= check.sys.ticksFromMilliseconds(3000)) return false;
            check.sys.sleepTicks(1);
        }
        if (done.sequence != sequence or done.handle.instance_id != self.handle.instance_id or done.handle.generation != self.handle.generation) return false;
        check.out.record("owned-desktop-completion", "DESKTOP", 0, .{ .handle = self.handle, .sequence = sequence, .exit_code = code, .reaped = true });
        self.handle = .{};
        return code == 0;
    }
};
