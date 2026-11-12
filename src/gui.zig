//! Compact native frontend. Measurements, export/hash checks and networking
//! belong to the private same-binary job, never to the event/render loop.
const std = @import("std");
const r4os = @import("r4os");
const policy = @import("gui_model.zig");
const jobs = @import("gui_jobs.zig");
const bg: u32 = 0x000000;
const fg: u32 = 0xEEEEEE;
const palette = r4os.gui.Palette{ .text = fg, .disabled_text = 0x707070, .face = 0x181818, .face_light = 0x909090, .face_shadow = 0x080808, .client_bg = bg, .select_bg = 0x283D70, .select_text = 0xFFFFFF, .title_bg = 0x181818, .title_text = fg };
const Press = enum { none, start, upload };
const View = struct {
    app: *r4os.App2,
    sys: r4os.r4sys.Context,
    desk: r4os.r4desk.Context,
    draw: r4os.r4draw.Context,
    model: policy.Model = .{},
    job: jobs.Job = .{},
    width: i32 = 520,
    height: i32 = 360,
    title_font: u32 = 0,
    focus: u8 = 1,
    popup: bool = false,
    hover: ?usize = null,
    pressed: Press = .none,
    capture: r4os.abi.GuiPointerCaptureHandle = .{},
    status: [256:0]u8 = .{0} ** 256,
    hint: [256:0]u8 = .{0} ** 256,
    dirty: bool = true,
    closing: bool = false,

    fn message(self: *View, text: []const u8, hint: []const u8) void {
        self.status = .{0} ** 256;
        self.hint = .{0} ** 256;
        @memcpy(self.status[0..@min(text.len, 256)], text[0..@min(text.len, 256)]);
        @memcpy(self.hint[0..@min(hint.len, 256)], hint[0..@min(hint.len, 256)]);
        self.dirty = true;
    }
    fn metrics(self: *View) void {
        var info: r4os.abi.GuiWindowInfo = .{};
        if (self.desk.guiWindowInfo(&info) >= 0) {
            self.width = @max(400, info.client_w);
            self.height = @max(320, info.client_h);
        }
        var best: u32 = 0;
        var weight: u32 = 0;
        for (0..@min(self.draw.fontCount(), 128)) |id| {
            var font: r4os.abi.GuiFontInfo = .{};
            if (self.draw.fontInfo(@intCast(id), &font) < 0 or font.height > 48) continue;
            if (font.height > best or (font.height == best and font.weight > weight)) {
                best = font.height;
                weight = font.weight;
                self.title_font = font.id;
            }
        }
        self.dirty = true;
    }
    fn dropdown(self: *const View) r4os.gui.Dropdown {
        const width = @min(320, self.width - 48);
        return .{ .rect = .{ .x = @divTrunc(self.width - width, 2), .y = 124, .w = width, .h = 26 }, .items = &policy.labels, .selected_index = self.model.selected, .hover_index = self.hover, .max_visible_rows = 6, .open = self.popup, .disabled = self.model.busy(), .focused = self.focus == 0, .palette = palette };
    }
    fn button(self: *const View, which: Press) r4os.gui.Button {
        const upload = which == .upload;
        const enabled = !self.closing and !self.model.busy() and (!upload or self.model.canUpload());
        return .{ .rect = .{ .x = @divTrunc(self.width, 2) + (if (upload) @as(i32, 18) else @as(i32, -128)), .y = 202, .w = 110, .h = 30 }, .text = if (upload) "Upload" else "Start", .state = if (!enabled) .disabled else if (self.pressed == which) .pressed else .normal, .focused = self.focus == (if (upload) @as(u8, 2) else @as(u8, 1)), .is_default = !upload, .palette = palette };
    }
    fn paint(self: *View) void {
        var painting = switch (r4os.app_gui.beginPaintForSize(&self.draw, self.width, self.height)) {
            .paint => |p| p,
            .failure => return,
        };
        defer painting.discard();
        const canvas = painting.canvas;
        var scratch: [512]u8 = undefined;
        _ = canvas.clear(bg);
        const title = canvas.withFontId(self.title_font);
        _ = title.text(@divTrunc(self.width - title.textWidthZ("Spectra"), 2), 34, "Spectra", fg, bg);
        _ = self.button(.start).draw(canvas, &scratch);
        _ = self.button(.upload).draw(canvas, &scratch);
        _ = canvas.text(18, self.height - 52, &self.status, fg, bg);
        _ = canvas.text(18, self.height - 30, &self.hint, 0xA0A0A0, bg);
        _ = self.dropdown().draw(canvas, &scratch); // popup overlays the buttons
        if (painting.present() >= 0) self.dirty = false;
    }
    fn releasePointer(self: *View) void {
        if (self.capture.id != 0) _ = self.desk.guiPointerCaptureRelease(&self.capture);
        self.capture = .{};
    }
    fn pressPointer(self: *View) void {
        var info: r4os.abi.GuiPointerCaptureInfo = .{};
        if (self.desk.guiPointerCaptureInfo(null, &info) == 0 and info.capture.window.window_id == self.desk.programWindowId())
            _ = self.desk.guiPointerCaptureAcquire(&info.capture.window, r4os.abi.gui_pointer_mode_drag, &self.capture);
    }
    fn select(self: *View, index: usize) void {
        if (self.model.select(index)) self.message("Bereit. Start druecken.", if (index == 0) "Upload nach gespeichertem Standardlauf." else "Teiltest bleibt lokal; Upload nur fuer Standard.");
        self.popup = false;
        self.hover = null;
        self.dirty = true;
    }
    fn down(self: *View, x: i32, y: i32) void {
        if (self.closing or self.model.busy()) return;
        const choice = self.dropdown();
        if (choice.indexAt(x, y)) |index| {
            self.select(index);
            return;
        }
        if (choice.contains(x, y)) {
            self.popup = !self.popup;
            self.focus = 0;
            self.dirty = true;
            return;
        }
        self.popup = false;
        self.pressed = .none;
        if (self.button(.start).contains(x, y)) {
            self.pressed = .start;
            self.focus = 1;
        }
        if (self.button(.upload).contains(x, y)) {
            self.pressed = .upload;
            self.focus = 2;
        }
        if (self.pressed != .none) self.pressPointer();
        self.dirty = true;
    }
    fn up(self: *View, x: i32, y: i32) void {
        const pressed = self.pressed;
        self.pressed = .none;
        self.releasePointer();
        self.dirty = true;
        if (pressed != .none and self.button(pressed).contains(x, y)) self.action(pressed);
    }
    fn onKey(self: *View, key: u8) void {
        if (self.closing or self.model.busy()) return;
        if (key == r4os.gui.Key.escape) {
            self.popup = false;
            self.dirty = true;
            return;
        }
        if (key == r4os.gui.Key.tab or key == r4os.gui.Key.shift_tab) {
            self.popup = false;
            const backward = key == r4os.gui.Key.shift_tab;
            self.focus = (self.focus + (if (backward) @as(u8, 2) else @as(u8, 1))) % 3;
            if (self.focus == 2 and !self.model.canUpload()) self.focus = if (backward) 1 else 0;
            self.dirty = true;
            return;
        }
        if (self.focus == 0) {
            if (key == r4os.gui.Key.enter or key == '\n' or key == ' ') {
                self.popup = !self.popup;
                self.dirty = true;
                return;
            }
            const step = self.dropdown().keyAction(key);
            if (step.index != self.model.selected and step.index < policy.labels.len) {
                self.select(step.index);
                self.focus = 0;
            }
            return;
        }
        if (key == r4os.gui.Key.enter or key == '\n' or key == ' ') self.action(if (self.focus == 2) .upload else .start);
    }
    fn action(self: *View, which: Press) void {
        if (self.closing or self.job.active) return;
        const kind: jobs.Kind = if (which == .upload) .upload else .measure;
        const accepted = if (kind == .measure) self.model.start() else self.model.upload();
        if (!accepted) return;
        self.popup = false;
        if (kind == .measure) {
            var text: [160]u8 = undefined;
            const label = std.fmt.bufPrint(&text, "{s} laeuft...", .{policy.labels[self.model.selected]}) catch "Test laeuft...";
            self.message(label, "Bitte warten. Upload ist gesperrt.");
        } else self.message("Upload laeuft...", "Gespeicherte Originaldatei wird verwendet.");
        self.paint();
        self.job.begin(self.app, self.desk.programWindowId(), kind, self.model.selected, self.model.generation, self.model.saved) catch |err| {
            if (kind == .measure) _ = self.model.measured(self.model.generation, 1, null) else _ = self.model.uploaded(self.model.generation, 1, false);
            self.failure(@errorName(err), "prepare", false);
        };
    }
    fn failure(self: *View, reason: []const u8, phase: []const u8, upload: bool) void {
        const text = if (std.mem.eql(u8, reason, "RunChanged") or std.mem.eql(u8, reason, "InvalidRun")) "Ergebnis wurde veraendert. Upload gesperrt." else if (std.mem.eql(u8, reason, "WrongPhysicalHost")) "Ergebnis gehoert zu einem anderen Host." else if (std.mem.eql(u8, reason, "CredentialsMissing") or std.mem.eql(u8, reason, "SecretMissing")) "Zugangsdaten fehlen oder sind ungueltig." else if (std.mem.eql(u8, phase, "registration")) "Server-Registrierung fehlgeschlagen." else if (std.mem.eql(u8, phase, "claim")) "Hostanlage abgewiesen. Upload gestoppt." else if (std.mem.eql(u8, phase, "save")) "Ergebnis konnte nicht gesichert werden." else if (upload) "Upload nicht bestaetigt." else "Test fehlgeschlagen oder unvollstaendig.";
        var detail: [240]u8 = undefined;
        const hint = std.fmt.bufPrint(&detail, "{s}: {s}", .{ phase, if (reason.len == 0) "unbekannter Fehler" else reason }) catch "Details nicht verfuegbar.";
        self.message(text, hint);
    }
    fn poll(self: *View) void {
        const result = self.job.poll(self.app) catch |err| {
            if (self.job.active) {
                self.job.requestClose(&self.sys);
                self.message("Arbeitsabschluss wird geprueft...", @errorName(err));
                return;
            }
            if (self.closing) return;
            if (self.job.kind == .measure) _ = self.model.measured(self.model.generation, 1, null) else _ = self.model.uploaded(self.model.generation, 1, false);
            self.failure(@errorName(err), "Abschluss", self.job.kind == .upload);
            return;
        };
        const done = result orelse return;
        if (self.closing) return;
        if (done.kind == .measure) {
            if (!self.model.measured(done.generation, done.code, done.saved)) return;
            switch (self.model.phase) {
                .saved => self.message("Standardlauf fertig. Ergebnis gespeichert.", "Upload ist bereit und erfolgt nur per Klick."),
                .partial => self.message("Teiltest abgeschlossen.", "Teiltest bleibt lokal; Upload nur fuer Standard."),
                .cancelled => self.message("Test abgebrochen.", "Kein uploadfaehiges Ergebnis."),
                else => self.failure(done.reasonText(), done.phaseText(), false),
            }
        } else {
            if (!self.model.uploaded(done.generation, done.code, done.local_invalid)) return;
            if (done.code == 0) self.message("Upload bestaetigt.", "Originaldaten und Serverwertung geprueft.") else self.failure(done.reasonText(), done.phaseText(), true);
        }
    }
    fn close(self: *View) void {
        if (self.closing) return;
        self.closing = true;
        self.model.phase = .closing;
        self.popup = false;
        self.pressed = .none;
        self.releasePointer();
        self.job.requestClose(&self.sys);
        self.message("Arbeit wird beendet...", "Gespeicherte Originale bleiben erhalten.");
    }
    fn run(self: *View) i32 {
        if (self.desk.programWindowId() < 0) return 2;
        _ = self.desk.guiSetTitle("Spectra");
        _ = self.desk.guiSetMinSize(400, 320);
        self.metrics();
        self.message("Bereit. Standard ist ausgewaehlt.", "Start misst; Upload uebertraegt nur nach Klick.");
        defer self.releasePointer();
        while (true) {
            if (self.sys.programShouldClose()) self.close();
            var event: r4os.abi.GuiEvent = .{};
            while (self.desk.guiPollEvent(&event) > 0) {
                switch (@as(r4os.abi.GuiEventKind, @enumFromInt(event.kind))) {
                    .close => self.close(),
                    .resize, .font_changed => self.metrics(),
                    .focus_gained => {
                        self.dirty = true;
                    },
                    .focus_lost, .input_reset => {
                        self.pressed = .none;
                        self.popup = false;
                        self.releasePointer();
                        self.dirty = true;
                    },
                    .capture_changed => {
                        var info: r4os.abi.GuiPointerCaptureInfo = .{};
                        if (self.capture.id != 0 and (self.desk.guiPointerCaptureInfo(&self.capture, &info) != 0 or info.state == r4os.abi.gui_pointer_state_cancelled or info.state == r4os.abi.gui_pointer_state_released)) {
                            self.pressed = .none;
                            self.releasePointer();
                            self.dirty = true;
                        }
                    },
                    .mouse_down => self.down(event.x, event.y),
                    .mouse_up => self.up(event.x, event.y),
                    .mouse_move => {
                        if (self.popup) {
                            const hover = self.dropdown().indexAt(event.x, event.y);
                            if (hover != self.hover) {
                                self.hover = hover;
                                self.dirty = true;
                            }
                        }
                    },
                    .key_down => self.onKey(@intCast(event.key & 0xFF)),
                    else => {},
                }
            }
            self.poll();
            if (self.closing and !self.job.active) return 0;
            if (self.dirty) self.paint();
            self.sys.sleepTicks(@max(1, self.sys.ticksFromMilliseconds(if (self.job.active) 150 else 16)));
        }
    }
};
var view: View = undefined;
pub fn run(app: *r4os.App2) i32 {
    const desk = app.desktop() orelse {
        app.system().println("SPECTRA /GUI requires an explicit Desktop GUI launch.");
        return 2;
    };
    const draw = app.drawing() orelse return 2;
    if (desk.programWindowId() < 0) {
        app.system().println("SPECTRA /GUI requires an explicit Desktop GUI launch.");
        return 2;
    }
    view = .{ .app = app, .sys = app.system(), .desk = desk, .draw = draw };
    return view.run();
}
