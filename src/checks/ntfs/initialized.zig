// Explicit, read-only checks on Prepare-NtfsInitialized.ps1's disposable
// derivative of the existing Windows NTFS4K fixture. No ordinary disk fits
// the selection marker; no files are created or modified by this mode.
const r4os = @import("r4os");
const Layout = enum { lznt1, raw, sparse, plain };
const Case = struct { offset: usize, want: usize };
var buffer: [4128]u8 = undefined;
var path_storage: r4os.FilePath = undefined;

fn path(letter: u8, rest: []const u8) ?r4os.path.PathZ {
    var text: [128]u8 = undefined;
    if (rest.len + 3 > text.len) return null;
    text[0] = letter;
    text[1] = ':';
    text[2] = '\\';
    @memcpy(text[3 .. 3 + rest.len], rest);
    path_storage = r4os.FilePath.parse(text[0 .. 3 + rest.len]) catch return null;
    return path_storage.asZ();
}

fn count(result: r4os.app_storage.Transfer) ?usize {
    return switch (result) {
        .bytes => |n| n,
        .end => 0,
        .failure => null,
    };
}

fn filled(bytes: []const u8, value: u8) bool {
    for (bytes) |b| if (b != value) return false;
    return true;
}

fn check(files: *const r4os.Files, letter: u8, rest: []const u8, layout: Layout, size: usize, initialized: usize, cases: []const Case) bool {
    const p = path(letter, rest) orelse return false;
    const info = switch (files.info(p)) {
        .value => |v| v,
        else => return false,
    };
    if (info.size != size) return false;
    for (cases) |c| {
        @memset(&buffer, 0xa5);
        const got = count(files.readAt(p, @intCast(c.offset), buffer[16 .. 16 + c.want])) orelse return false;
        if (got != @min(c.want, size -| c.offset)) return false;
        if (!filled(buffer[0..16], 0xa5) or !filled(buffer[16 + got ..], 0xa5)) return false;
        var state: u32 = 23; // Existing DATA2.BIN uses seed 22 | 1.
        if (layout == .plain) for (0..c.offset) |_| {
            state ^= state << 13;
            state ^= state >> 17;
            state ^= state << 5;
        };
        for (buffer[16 .. 16 + got], 0..) |actual, i| {
            const position = c.offset + i;
            const valid: u8 = switch (layout) {
                .lznt1 => "R4OS NTFS compression test line. "[position % 33],
                .raw => @truncate(position * 7 + 17),
                .sparse => if (position % (1024 * 1024) < 4096) @truncate((position % (1024 * 1024)) * 7) else 0,
                .plain => blk: {
                    state ^= state << 13;
                    state ^= state >> 17;
                    state ^= state << 5;
                    break :blk @truncate(state);
                },
            };
            if (actual != (if (position < initialized) valid else 0)) return false;
        }
    }
    return true;
}

fn report(ctx: *const r4os.r4sys.Context, name: []const u8, ok: bool) bool {
    ctx.write("SPECTRA NTFS initialized ");
    ctx.write(name);
    ctx.println(if (ok) ": ok" else ": FAILED");
    return ok;
}

pub fn run(ctx: *const r4os.r4sys.Context, files: *const r4os.Files) i32 {
    var letter: u8 = 0;
    for (0..26) |index| {
        const drive = ctx.driveInfo(@intCast(index)) orelse continue;
        if (drive.mounted == 0 or drive.kind != 3) continue;
        const p = path(drive.letter, "BASIC\\HELLO.TXT") orelse continue;
        @memset(&buffer, 0xa5);
        const n = count(files.read(p, buffer[0..24])) orelse continue;
        const marker = "R4OS-INIT-0847";
        if (n == 24 and equal(buffer[0..marker.len], marker) and filled(buffer[marker.len..24], 0)) {
            letter = drive.letter;
            break;
        }
    }
    if (letter == 0) {
        ctx.println("SPECTRA NTFS initialized fixture unavailable");
        return 1;
    }
    var ok = true;
    const boundary = [_]Case{
        .{ .offset = 0, .want = 64 },
        .{ .offset = 65504, .want = 128 },
        .{ .offset = 65627, .want = 128 },
        .{ .offset = 65659, .want = 64 },
        .{ .offset = 131072, .want = 128 },
    };
    ok = report(ctx, "lznt1", check(files, letter, "COMP\\COMPRESS.TXT", .lznt1, 270336, 65659, &boundary) and
        check(files, letter, "COMP\\COMPRESS.TXT", .lznt1, 270336, 65659, &.{ .{ .offset = 270329, .want = 16 }, .{ .offset = 270336, .want = 16 } })) and ok;
    ok = report(ctx, "raw-units", check(files, letter, "COMP\\RANDOM.BIN", .raw, 262144, 65659, &boundary) and
        check(files, letter, "COMP\\RANDOM.BIN", .raw, 262144, 65659, &.{ .{ .offset = 262137, .want = 16 }, .{ .offset = 262144, .want = 16 } })) and ok;
    ok = report(ctx, "sparse-units", check(files, letter, "SPARSE.BIN", .sparse, 2097152, 1048699, &.{
        .{ .offset = 0, .want = 4096 },
        .{ .offset = 65536, .want = 128 },
        .{ .offset = 1048544, .want = 128 },
        .{ .offset = 1048667, .want = 128 },
        .{ .offset = 1048699, .want = 64 },
        .{ .offset = 1049600, .want = 128 },
        .{ .offset = 2097145, .want = 16 },
        .{ .offset = 2097152, .want = 16 },
    })) and ok;
    ok = report(ctx, "plain-control", check(files, letter, "BASIC\\SUB1\\SUB2\\DATA2.BIN", .plain, 12345, 4219, &.{
        .{ .offset = 0, .want = 64 },
        .{ .offset = 4187, .want = 128 },
        .{ .offset = 4219, .want = 64 },
        .{ .offset = 12288, .want = 128 },
        .{ .offset = 12345, .want = 16 },
    })) and ok;
    var rejects_prefix = false;
    if (path(letter, "BASIC\\SUB1\\DATA1.BIN")) |p| {
        rejects_prefix = switch (files.readAt(p, 0, buffer[16..272])) {
            .failure => true,
            else => false,
        };
    }
    ok = report(ctx, "prefix-error", rejects_prefix and check(files, letter, "BASIC\\SUB1\\DATA1.BIN", .raw, 4096, 123, &.{.{ .offset = 123, .want = 256 }})) and ok;
    ctx.println(if (ok) "SPECTRA NTFS initialized result: OK" else "SPECTRA NTFS initialized result: FAILED");
    return if (ok) 0 else 1;
}

fn equal(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| if (left != right) return false;
    return true;
}
