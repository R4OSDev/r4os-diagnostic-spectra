//! SPECTRA RESOURCES - Gastdiagnose des R4M0-Ressourcenbereichs (0.61.13).
//!
//! Liest die eingebetteten Ressourcen des Dauerfixtures RSRCFIX ueber die
//! R4SYS-Lese-API und vergleicht byteweise gegen die deterministischen
//! Bauquellen (deren Erzeugungsformeln, nicht deren Kopien - die Formeln
//! stehen am Fixture). Jede Bedingung meldet Name, Ist und Soll einzeln;
//! ein kollabierter Sammelfehler ohne Werte war die teuerste Eigenschaft
//! des alten pagerstress-Tests (0.61.10).
const r4os = @import("r4os");

const fixture_path = "C:\\R4OS\\SOFTWARE\\TERMINAL\\DIAG\\RSRCFIX.R4X";
const plain_path = "C:\\R4OS\\SOFTWARE\\TERMINAL\\DIAG\\SPECTRA.R4X";
const not_module_path = "C:\\R4OS\\CONFIG\\VERSION.R4S";

const type_icon: u32 = 1;
const type_help: u32 = 2;
const type_file: u32 = 3;

const App = struct {
    sys: r4os.r4sys.Context,
    ok: bool = true,

    fn fail(self: *App, name: []const u8, actual: i32, expected: i32) void {
        self.ok = false;
        self.sys.write("SPECTRA RESOURCES FAILED: ");
        self.sys.write(name);
        self.sys.write(": actual=");
        self.sys.printI32(actual);
        self.sys.write(" expected=");
        self.sys.printI32(expected);
        self.sys.write("\r\n");
    }

    fn expectEq(self: *App, name: []const u8, actual: i32, expected: i32) void {
        if (actual != expected) self.fail(name, actual, expected);
    }
};

pub fn r4_app_main(r4_app: *r4os.App) i32 {
    var app = App{ .sys = r4_app.system() };
    const sys = &app.sys;
    sys.println("SPECTRA RESOURCES");

    // Icon 0: Groesse, Signatur, stat == read.
    var icon_buf: [4096]u8 = undefined;
    const icon_stat = sys.moduleResourceStat(fixture_path, type_icon, 0, null);
    app.expectEq("icon0 stat size", icon_stat, 2238);
    const icon_read = sys.moduleResourceRead(fixture_path, type_icon, 0, null, icon_buf[0..]);
    app.expectEq("icon0 read size", icon_read, 2238);
    if (icon_read == 2238) {
        // ICONDIR: reserved=0, type=1, count=1.
        const sig_ok = icon_buf[0] == 0 and icon_buf[1] == 0 and icon_buf[2] == 1 and icon_buf[3] == 0 and icon_buf[4] == 1 and icon_buf[5] == 0;
        if (!sig_ok) app.fail("icon0 icondir signature", @intCast(icon_buf[2]), 1);
        // Pixelformel des Generators: (x + y*7 + 3) & 0xFF ab Offset 1086.
        var pixel_ok = true;
        var probe: usize = 0;
        while (probe < 64) : (probe += 1) {
            const x = probe % 32;
            const y = probe / 32;
            if (icon_buf[1086 + probe] != @as(u8, @intCast((x + y * 7 + 3) & 0xFF))) pixel_ok = false;
        }
        if (!pixel_ok) app.fail("icon0 pixel formula", 0, 1);
    }

    // Icon 1 existiert, Icon 2 nicht.
    app.expectEq("icon1 stat size", sys.moduleResourceStat(fixture_path, type_icon, 1, null), 2238);
    app.expectEq("icon2 must be absent", sys.moduleResourceStat(fixture_path, type_icon, 2, null), r4os.r4sys.module_resource_error_no_entry);

    // Helpfile: 301 Bytes (kanonische LF-Bauquelle 304 MIT BOM - der Builder strippt),
    // beginnt mit dem Klartext, traegt kein BOM.
    var help_buf: [512]u8 = undefined;
    const help_read = sys.moduleResourceRead(fixture_path, type_help, 0, null, help_buf[0..]);
    app.expectEq("help read size", help_read, 301);
    if (help_read == 301) {
        if (help_buf[0] == 0xEF) app.fail("help must not carry a bom", 0xEF, 'R');
        const kopf = "RSRCFIX - resource area smoke fixture";
        var kopf_ok = true;
        for (kopf, 0..) |byte, index| {
            if (help_buf[index] != byte) kopf_ok = false;
        }
        if (!kopf_ok) app.fail("help text head", @intCast(help_buf[0]), 'R');
    }

    // Benannte Datei: 64 Bytes nach der Generatorformel (i*37+11)&0xFF,
    // Name case-insensitive.
    var data_buf: [128]u8 = undefined;
    const data_read = sys.moduleResourceRead(fixture_path, type_file, 0, "data.bin", data_buf[0..]);
    app.expectEq("file DATA.BIN read size", data_read, 64);
    if (data_read == 64) {
        var formel_ok = true;
        var index: usize = 0;
        while (index < 64) : (index += 1) {
            if (data_buf[index] != @as(u8, @intCast((index * 37 + 11) & 0xFF))) formel_ok = false;
        }
        if (!formel_ok) app.fail("file DATA.BIN byte formula", @intCast(data_buf[0]), 11);
    }

    // Negativfaelle: falscher Name, zu kleiner Buffer, Modul ohne
    // Ressourcen, Datei die kein Modul ist.
    app.expectEq("unknown name rejected", sys.moduleResourceStat(fixture_path, type_file, 0, "MISSING.BIN"), r4os.r4sys.module_resource_error_no_entry);
    var tiny: [16]u8 = undefined;
    app.expectEq("small buffer rejected", sys.moduleResourceRead(fixture_path, type_icon, 0, null, tiny[0..]), r4os.r4sys.module_resource_error_too_small);
    app.expectEq("plain module has no resources", sys.moduleResourceStat(plain_path, type_help, 0, null), r4os.r4sys.module_resource_error_no_resources);
    app.expectEq("non-module rejected", sys.moduleResourceStat(not_module_path, type_help, 0, null), r4os.r4sys.module_resource_error_bad_module);

    // Eigener Modulpfad: endet auf SPECTRA.R4X.
    var path_buf: [128]u8 = undefined;
    const path_len = sys.programModulePath(path_buf[0..]);
    if (path_len <= 0) {
        app.fail("own module path length", path_len, 1);
    } else {
        const suffix = "SPECTRA.R4X";
        const len: usize = @intCast(path_len);
        var suffix_ok = len >= suffix.len;
        if (suffix_ok) {
            for (suffix, 0..) |byte, index| {
                if (path_buf[len - suffix.len + index] != byte) suffix_ok = false;
            }
        }
        if (!suffix_ok) app.fail("own module path suffix", @intCast(path_buf[len - 1]), 'X');
        // Und der Pfad funktioniert als Eingabe der Lese-API: das eigene
        // Modul hat keine Ressourcen - der Fehler dafuer ist der Beweis,
        // dass Aufloesung und Containerlesen am eigenen Pfad ankommen.
        path_buf[len] = 0;
        const self_path: [*:0]const u8 = @ptrCast(path_buf[0..len :0]);
        app.expectEq("own module resolvable", sys.moduleResourceStat(self_path, type_help, 0, null), r4os.r4sys.module_resource_error_no_resources);
    }

    if (app.ok) {
        sys.println("SPECTRA RESOURCES result: OK");
        return 0;
    }
    sys.println("SPECTRA RESOURCES result: FAILED");
    return 1;
}
