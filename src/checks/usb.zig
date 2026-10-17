//! Synthetic ring/router contracts through their existing native owner.
const std = @import("std");
const r4os = @import("r4os");
const abi = r4os.abi;
const Output = @import("../output.zig").Output;
const Report = abi.ProgramKernelUsbCheck;
const sentinel: u64 = 0x5a5a_a5a5_5a5a_a5a5;
fn headers(dev: *const r4os.r4dev.Context) bool {
    for (0..2) |index| {
        var value: Report = .{};
        if (index == 0) value.version = 0 else value.size -= 1;
        value.selected_cases = 0x5a5a_a5a5;
        const before = value;
        if (dev.kernelUsbCheck(&value) != -1 or !std.mem.eql(u8, std.mem.asBytes(&value), std.mem.asBytes(&before))) return false;
    }
    return true;
}
pub fn run(app: *r4os.App, args: []const u8, out: *Output) i32 {
    if (args.len != 0) {
        out.unavailable("usb", "use CHECK USB without extra arguments");
        return 2;
    }
    const dev = app.devicesLowLevel() orelse {
        out.unavailable("usb", "R4DEV unavailable");
        return 2;
    };
    if (!dev.hasFn("usb_contract_check")) {
        out.unavailable("usb", "native USB contracts unavailable");
        return 2;
    }
    if (!headers(&dev)) {
        out.message("usb", "SPECTRA USB header contract: FAILED", false);
        return 1;
    }
    var guarded = extern struct { value: Report = .{}, tail: [2]u64 = .{ sentinel, sentinel } }{};
    guarded.value.size = @sizeOf(@TypeOf(guarded));
    const rc = dev.kernelUsbCheck(&guarded.value);
    const result = guarded.value;
    out.record("kernel_usb", "usb", 0, result);
    out.message("usb", "Local synthetic ring-cycle and exact HID/storage/command routing contracts; no physical USB or liveboot qualification.", false);
    const ok = rc == 1 and guarded.tail[0] == sentinel and guarded.tail[1] == sentinel and result.version == abi.kernel_usb_check_version and result.size == @sizeOf(Report) and result.status == abi.kernel_usb_check_status_passed and result.selected_cases == abi.kernel_usb_check_cases_all and result.attempted_cases == abi.kernel_usb_check_cases_all and result.passed_cases == abi.kernel_usb_check_cases_all and result.failed_cases == 0 and result.reserved0 == 0;
    out.message("usb", if (ok) "SPECTRA USB contracts: ok" else "SPECTRA USB contracts: FAILED", false);
    return if (ok) 0 else 1;
}
