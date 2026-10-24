//! Explicit standalone Desktop ownership for the existing check. Never close
//! or replace a foreign host. Completion and Reap carry the exact spawned
//! generation, independently of the calling terminal/SSH connection.
const std = @import("std");
const r = @import("r4os");
const a = r.abi;
const Output = @import("output.zig").Output;
pub const Owner = struct {
    handle: a.ProgramProcessHandle = .{},
    retired: bool = false,
    exit_code: ?i32 = null,

    pub fn start(self: *Owner, sys: r.r4sys.Context) !void {
        if (self.handle.instance_id != 0) return error.HostAlreadyOwned;
        if (try active(sys)) |host| {
            _ = host;
            return error.ForeignDesktop;
        }
        if (sys.programSpawnHandle("C:\\R4OS\\SOFTWARE\\DESKTOP\\R4DESK.R4X", "/CHECK-ISOLATED", .gui, &self.handle) != 0 or
            self.handle.instance_id == 0 or self.handle.generation == 0) return error.HostSpawn;
        const deadline = sys.ticks() +| sys.ticksFromMilliseconds(30000);
        while (sys.ticks() < deadline) {
            var info: a.ProgramInstanceInfo = .{};
            if (sys.programHandleStatus(&self.handle, &info) != 0 or info.state != @intFromEnum(a.ProgramInstanceState.running)) return error.HostEndedBeforeClaim;
            if (try active(sys)) |host| {
                if (host.instance_id != self.handle.instance_id or host.generation != self.handle.generation) return error.ForeignDesktop;
                return;
            }
            if (sys.programShouldClose()) return error.Cancelled;
            sys.sleepTicks(1);
        }
        return error.HostClaimTimeout;
    }

    pub fn finish(self: *Owner, sys: r.r4sys.Context, out: *Output) bool {
        if (self.handle.instance_id == 0 or self.retired) return true;
        _ = sys.programHandleRequestClose(&self.handle);
        var done: a.ProgramProcessCompletion = .{};
        if (sys.programHandleWait(&self.handle, sys.ticksFromMilliseconds(10000), &done) != 0 or
            done.handle.instance_id != self.handle.instance_id or done.handle.generation != self.handle.generation or
            done.sequence == 0) return false;
        const sequence = done.sequence;
        const code = done.exit_code;
        const deadline = sys.ticks() +| sys.ticksFromMilliseconds(3000);
        while (true) {
            const status = sys.programHandleReap(&self.handle, &done);
            if (status == 0) break;
            if (status != a.program_handle_error_would_block or sys.ticks() >= deadline) return false;
            sys.sleepTicks(1);
        }
        if (done.handle.instance_id != self.handle.instance_id or done.handle.generation != self.handle.generation or
            done.sequence != sequence or done.exit_code != code) return false;
        self.retired = true;
        self.exit_code = code;
        out.record("host-completion", "DESKTOP", 0, .{ .handle = self.handle, .sequence = sequence,
            .exit_code = code, .reaped = true, .foreign_host_closed = false });
        return true;
    }
};

fn active(sys: r.r4sys.Context) !?a.ProgramProcessHandle {
    var service: a.ServiceInfo = .{};
    if (sys.serviceOpen("WINSVC", &service) != 0 or service.handle == 0) return error.WindowServiceUnavailable;
    var bytes: [128]u8 = undefined;
    var header: a.ServiceMessageHeader = .{};
    const count = sys.serviceCall(service.handle, 4500, "", &header, &bytes, sys.ticksFromMilliseconds(3000));
    const closed = sys.serviceClose(service.handle);
    if (closed != 0) return error.HostConnectionClose;
    if (count != bytes.len or header.status != 0 or !std.mem.eql(u8, bytes[0..8], "RDM1\x01\x00\x80\x00")) return error.HostStatus;
    const flags = std.mem.readInt(u32, bytes[8..12], .little);
    const instance = std.mem.readInt(u32, bytes[32..36], .little);
    const generation = std.mem.readInt(u64, bytes[40..48], .little);
    if (flags & 1 == 0) return null;
    if (instance == 0 or generation == 0) return error.HostIdentity;
    return .{ .instance_id = instance, .generation = generation };
}
