const r4os = @import("r4os");

var checksum: u64 = 0;

pub fn r4_app_main(r4_app: *r4os.App) i32 {
    const sys = r4_app.system();
    sys.println("SPECTRA STACK");

    checksum = 0;
    consumeStack(96, 0x19);

    const ok = checksum != 0;
    sys.print("SPECTRA STACK checksum: ");
    sys.printU64(checksum);
    sys.println("");
    sys.print("SPECTRA STACK result: ");
    sys.println(if (ok) "OK" else "FAILED");
    return if (ok) 0 else 1;
}

noinline fn consumeStack(depth: u32, seed: u8) void {
    var page: [4096]u8 = undefined;
    const bytes: [*]volatile u8 = @ptrCast(&page);
    var offset: usize = 0;
    while (offset < page.len) : (offset += 512) {
        bytes[offset] = seed +% @as(u8, @truncate(offset + depth));
    }
    bytes[page.len - 1] = seed ^ @as(u8, @truncate(depth));
    checksum +%= @as(u64, bytes[0]) + @as(u64, bytes[page.len - 1]) + depth;
    if (depth != 0) consumeStack(depth - 1, seed +% 1);
    checksum +%= bytes[@as(usize, @intCast(depth)) & (page.len - 1)];
}
