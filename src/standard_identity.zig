//! Spectra owns the automatic benchmark host identity; only a digest leaves
//! the client. The firmware bytes are never part of a run or a log record.
const r4os = @import("r4os");
const Output = @import("output.zig").Output;

const benchmark_host_identity = @import("benchmark_host_identity.zig");
pub const Identity = benchmark_host_identity.Identity;
pub const method = benchmark_host_identity.method;

pub fn derive(app: *r4os.App) !Identity {
    const dev = app.devicesLowLevel() orelse return error.FirmwareIdentityUnavailable;
    const firmware = dev.firmwareSystemUuid() orelse return error.FirmwareIdentityUnavailable;
    return benchmark_host_identity.deriveBytes(firmware.uuid) catch error.InvalidFirmwareIdentity;
}

pub fn check(app: *r4os.App, args: []const u8, out: *Output) i32 {
    if (args.len != 0) return 2;
    const identity = derive(app) catch |err| {
        out.unavailable("hostid", @errorName(err));
        return 1;
    };
    const host_id: []const u8 = &identity.host_id;
    const identity_method: []const u8 = method;
    out.record("host_identity", "hostid", 0, .{
        .host_id = host_id,
        .method = identity_method,
    });
    return 0;
}
