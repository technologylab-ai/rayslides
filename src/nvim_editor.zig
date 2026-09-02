const std = @import("std");
const builtin = @import("builtin");
const rl = @import("raylib");
const build_options = @import("build_options");
const fonts = @import("fonts.zig");
const support = @import("neovim");

const log = std.log.scoped(.neovim_editor);
const startup_timeout_seconds = 8.0;

pub const default_font_size: f32 = 20;
pub const minimum_font_size: f32 = 10;
pub const maximum_font_size: f32 = 48;

pub const Options = struct {
    clean: bool = false,
    executable_path: ?[]const u8 = null,
    font_path: ?[]const u8 = null,
    font_size: f32 = default_font_size,
};

pub fn validFontSize(value: f32) bool {
    return std.math.isFinite(value) and value >= minimum_font_size and value <= maximum_font_size;
}

pub const compiled = support.compiled;

pub const BeginResult = enum {
    started,
    support_disabled,
    executable_missing,
    start_failed,
};

pub const BufferKind = enum {
    source,
    field,
};

pub const FieldKind = enum {
    text,
    speaker_notes,
};

pub const Apply = struct {
    source: []const u8,
    accepted_revision: usize,
    kind: BufferKind,
};

pub const Controller = if (compiled) EnabledController else DisabledController;

const DisabledController = struct {
    pub fn init(_: std.mem.Allocator, _: std.Io, _: Options) DisabledController {
        return .{};
    }
    pub fn deinit(_: *DisabledController) void {}
    pub fn active(_: *const DisabledController) bool {
        return false;
    }
    pub fn beginSource(_: *DisabledController, _: []const u8, _: usize, _: usize) BeginResult {
        return .support_disabled;
    }
    pub fn beginSourceClean(_: *DisabledController, _: []const u8, _: usize) BeginResult {
        return .support_disabled;
    }
    pub fn beginField(_: *DisabledController, _: FieldKind, _: []const u8, _: usize) BeginResult {
        return .support_disabled;
    }
    pub fn update(_: *DisabledController, _: rl.Rectangle) bool {
        return false;
    }
    pub fn draw(_: *const DisabledController, _: rl.Rectangle) void {}
    pub fn takeApply(_: *DisabledController) ?Apply {
        return null;
    }
    pub fn acceptApply(_: *DisabledController, _: usize) void {}
    pub fn rejectApply(_: *DisabledController, _: []const u8) void {}
    pub fn readyForCapture(_: *const DisabledController) bool {
        return false;
    }
};

const EnabledController = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    embedded: ?*support.session.Session = null,
    initial_source: ?[]u8 = null,
    snapshot_value: ?support.session.Snapshot = null,
    font: rl.Font,
    owns_font: bool = false,
    emoji_font: rl.Font,
    owns_emoji_font: bool = false,
    font_size: f32 = default_font_size,
    cell_width: f32 = 12,
    cell_height: f32 = 24,
    configured: bool = false,
    last_cols: usize = 0,
    last_rows: usize = 0,
    last_focus: bool = true,
    mouse_capture: [3]bool = @splat(false),
    status: [192:0]u8 = @splat(0),
    status_len: usize = 0,
    runtime_path: [std.fs.max_path_bytes]u8 = undefined,
    runtime_path_len: usize = 0,
    buffer_kind: BufferKind = .source,
    field_kind: FieldKind = .text,
    clean_mode: bool = false,
    default_clean: bool,
    executable_path: [std.fs.max_path_bytes]u8 = undefined,
    executable_path_len: usize = 0,
    initial_line: usize = 1,
    startup_started_at: f64 = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, options: Options) EnabledController {
        var executable_dir: [std.fs.max_path_bytes]u8 = undefined;
        const executable_dir_len = std.process.executableDirPath(io, &executable_dir) catch 0;
        var editor_fontchars_storage: [768]i32 = undefined;
        const editor_fontchars = editorFontCharacters(&editor_fontchars_storage);
        const font_size = if (validFontSize(options.font_size)) options.font_size else default_font_size;
        const font_load_size: i32 = @max(24, @as(i32, @intFromFloat(@ceil(font_size * 1.2))));
        var font = rl.getFontDefault() catch unreachable;
        var owns_font = false;
        if (options.font_path) |candidate| {
            if (loadEditorFont(candidate, editor_fontchars, font_load_size)) |loaded| {
                font = loaded;
                owns_font = true;
            } else {
                log.warn("could not load configured Neovim font at {s}; using fallback discovery", .{candidate});
            }
        }
        if (!owns_font and executable_dir_len > 0) {
            var candidate_buffer: [std.fs.max_path_bytes:0]u8 = @splat(0);
            for ([_][]const u8{
                "../share/rayslides/fonts/JetBrainsMono-Regular.ttf",
                "../Resources/fonts/JetBrainsMono-Regular.ttf",
            }) |relative| {
                const candidate = std.fmt.bufPrintZ(
                    &candidate_buffer,
                    "{s}/{s}",
                    .{ executable_dir[0..executable_dir_len], relative },
                ) catch continue;
                if (loadEditorFont(candidate, editor_fontchars, font_load_size)) |loaded| {
                    font = loaded;
                    owns_font = true;
                    break;
                }
            }
        }
        if (!owns_font and build_options.neovim_font_development_path.len > 0) {
            if (loadEditorFont(build_options.neovim_font_development_path, editor_fontchars, font_load_size)) |loaded| {
                font = loaded;
                owns_font = true;
            }
        }
        if (!owns_font) {
            const candidates = [_][]const u8{
                "/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf",
                "/usr/share/fonts/TTF/JetBrainsMono-Regular.ttf",
                "/usr/share/fonts/truetype/jetbrains-mono/JetBrainsMono-Regular.ttf",
                "/opt/homebrew/share/fonts/JetBrainsMono-Regular.ttf",
                "/usr/local/share/fonts/JetBrainsMono-Regular.ttf",
                "/usr/share/fonts/noto/NotoSansMono-Regular.ttf",
                "/usr/share/fonts/Adwaita/AdwaitaMono-Regular.ttf",
            };
            for (candidates) |candidate| {
                if (loadEditorFont(candidate, editor_fontchars, font_load_size)) |loaded| {
                    font = loaded;
                    owns_font = true;
                    break;
                }
            }
        }
        if (owns_font) rl.setTextureFilter(font.texture, .bilinear);
        var emoji_font = font;
        var owns_emoji_font = false;
        if (fonts.loadBitmapEmojiFont(font_load_size)) |loaded| {
            emoji_font = loaded;
            owns_emoji_font = true;
            rl.setTextureFilter(emoji_font.texture, .bilinear);
        } else |err| {
            log.warn("could not load the embedded Rayslides emoji font: {any}", .{err});
        }
        const measured = rl.measureTextEx(font, "M", font_size, 0);
        var result: EnabledController = .{
            .allocator = allocator,
            .io = io,
            .font = font,
            .owns_font = owns_font,
            .emoji_font = emoji_font,
            .owns_emoji_font = owns_emoji_font,
            .font_size = font_size,
            .cell_width = @max(8, measured.x),
            .cell_height = @ceil(font_size * 1.2),
            .default_clean = options.clean,
        };
        if (options.executable_path) |path| {
            if (path.len <= result.executable_path.len) {
                @memcpy(result.executable_path[0..path.len], path);
                result.executable_path_len = path.len;
            }
        }
        if (executable_dir_len > 0) {
            for ([_][]const u8{
                "../share/rayslides/nvim",
                "../Resources/nvim",
            }) |relative| {
                const resolved = std.fmt.bufPrint(
                    &result.runtime_path,
                    "{s}/{s}",
                    .{ executable_dir[0..executable_dir_len], relative },
                ) catch continue;
                if (directoryExistsAbsolute(io, resolved)) {
                    result.runtime_path_len = resolved.len;
                    break;
                }
            }
        }
        if (result.runtime_path_len == 0) {
            const fallback = "src/nvim/runtime";
            @memcpy(result.runtime_path[0..fallback.len], fallback);
            result.runtime_path_len = fallback.len;
        }
        return result;
    }

    pub fn deinit(self: *EnabledController) void {
        self.closeSession();
        if (self.owns_emoji_font) rl.unloadFont(self.emoji_font);
        if (self.owns_font) rl.unloadFont(self.font);
    }

    pub fn active(self: *const EnabledController) bool {
        return self.embedded != null;
    }

    pub fn beginSource(self: *EnabledController, source: []const u8, revision: usize, initial_line: usize) BeginResult {
        return self.beginBuffer(.source, .text, source, revision, self.default_clean, initial_line);
    }

    /// Starts a reproducible recovery/diagnostic session without user config.
    /// Interactive editor entry points deliberately keep the user's normal
    /// Neovim configuration.
    pub fn beginSourceClean(self: *EnabledController, source: []const u8, revision: usize) BeginResult {
        return self.beginBuffer(.source, .text, source, revision, true, 1);
    }

    pub fn beginField(
        self: *EnabledController,
        field_kind: FieldKind,
        source: []const u8,
        revision: usize,
    ) BeginResult {
        return self.beginBuffer(.field, field_kind, source, revision, self.default_clean, 1);
    }

    fn beginBuffer(
        self: *EnabledController,
        buffer_kind: BufferKind,
        field_kind: FieldKind,
        source: []const u8,
        revision: usize,
        clean_mode: bool,
        initial_line: usize,
    ) BeginResult {
        self.closeSession();
        self.initial_source = self.allocator.dupe(u8, source) catch {
            self.setStatus("Could not allocate the Neovim source buffer");
            return .start_failed;
        };

        var candidates: [10][]const u8 = undefined;
        var candidate_count: usize = 0;
        if (self.executable_path_len > 0) {
            candidates[candidate_count] = self.executable_path[0..self.executable_path_len];
            candidate_count += 1;
        }
        for ([_][]const u8{
            "nvim",
            "/opt/homebrew/bin/nvim",
            "/usr/local/bin/nvim",
            "/opt/local/bin/nvim",
            "/usr/bin/nvim",
        }) |candidate| {
            candidates[candidate_count] = candidate;
            candidate_count += 1;
        }
        var home_candidate_buffers: [4][std.fs.max_path_bytes:0]u8 = @splat(@splat(0));
        if (std.c.getenv("HOME")) |home_raw| {
            const home = std.mem.span(home_raw);
            for ([_][]const u8{
                ".local/bin/nvim",
                "bin/nvim",
                ".local/share/mise/shims/nvim",
                ".asdf/shims/nvim",
            }, 0..) |relative, index| {
                const candidate = std.fmt.bufPrintZ(
                    &home_candidate_buffers[index],
                    "{s}/{s}",
                    .{ home, relative },
                ) catch continue;
                candidates[candidate_count] = candidate;
                candidate_count += 1;
            }
        }
        var saw_non_missing_failure = false;
        for (candidates[0..candidate_count]) |candidate| {
            const embedded = support.session.Session.start(
                self.io,
                self.allocator,
                candidate,
                clean_mode,
                support.session.default_width,
                support.session.default_height,
                revision,
            ) catch |err| {
                if (err != error.FileNotFound) {
                    saw_non_missing_failure = true;
                    log.warn("could not start embedded Neovim at {s}: {any}", .{ candidate, err });
                }
                continue;
            };
            self.embedded = embedded;
            self.configured = false;
            self.last_cols = 0;
            self.last_rows = 0;
            self.last_focus = rl.isWindowFocused();
            self.buffer_kind = buffer_kind;
            self.field_kind = field_kind;
            self.clean_mode = clean_mode;
            self.initial_line = @max(1, initial_line);
            self.startup_started_at = rl.getTime();
            self.setStatus("Starting Neovim…");
            return .started;
        }

        self.allocator.free(self.initial_source.?);
        self.initial_source = null;
        self.setStatus(if (saw_non_missing_failure)
            "Neovim failed to start; see the log"
        else
            "Neovim was not found; the built-in editor remains available");
        return if (saw_non_missing_failure) .start_failed else .executable_missing;
    }

    /// Updates transport and input. Returns true exactly on an overlay-close
    /// transition, including :q/:q!, BufWinLeave, EOF, and child failure.
    pub fn update(self: *EnabledController, outer: rl.Rectangle) bool {
        const embedded = self.embedded orelse return false;
        if (embedded.shouldClose()) {
            self.closeSession();
            return true;
        }

        if (!self.configured and embedded.state() == .starting and
            rl.getTime() - self.startup_started_at >= startup_timeout_seconds)
        {
            var stderr_buffer: [2048]u8 = undefined;
            const stderr_tail = embedded.copyStderrTail(&stderr_buffer);
            log.warn("Neovim did not become ready within {d:.0} seconds; stderr tail: {s}", .{
                startup_timeout_seconds,
                stderr_tail,
            });
            self.setStatus("Neovim startup timed out; retry with --neovim-clean");
            self.closeSession();
            return true;
        }

        if (!self.configured and embedded.state() == .ready) {
            const source = self.initial_source orelse "";
            if (embedded.openBufferAtLine(
                source,
                self.runtime_path[0..self.runtime_path_len],
                switch (self.buffer_kind) {
                    .source => .source,
                    .field => switch (self.field_kind) {
                        .text => .text,
                        .speaker_notes => .speaker_notes,
                    },
                },
                self.initial_line,
            )) |opened| {
                if (opened) {
                    self.configured = true;
                    if (self.clean_mode) embedded.command("set guicursor=a:blinkon0") catch {};
                    self.allocator.free(source);
                    self.initial_source = null;
                    self.setStatus(if (self.buffer_kind == .source)
                        "Neovim · :w applies source · :q closes · :q! discards"
                    else
                        "Neovim · :w applies field · :q closes · :q! discards");
                }
            } else |err| {
                log.warn("could not configure embedded Neovim buffer: {any}", .{err});
                self.setStatus("Neovim buffer setup failed; see the log");
                self.closeSession();
                return true;
            }
        }

        const content = contentRect(outer);
        const cols: usize = @max(10, @as(usize, @intFromFloat(@floor(content.width / self.cell_width))));
        const rows: usize = @max(4, @as(usize, @intFromFloat(@floor(content.height / self.cell_height))));
        if (self.configured and (cols != self.last_cols or rows != self.last_rows)) {
            embedded.resize(cols, rows) catch |err| log.warn("Neovim grid resize failed: {any}", .{err});
            self.last_cols = cols;
            self.last_rows = rows;
        }

        if (self.snapshot_value == null or embedded.state() == .ready) {
            const revision = if (self.snapshot_value) |snapshot| snapshot.flush_revision else 0;
            if (embedded.snapshot(self.allocator, revision)) |next_opt| {
                if (next_opt) |next| {
                    if (self.snapshot_value) |*previous| previous.deinit();
                    self.snapshot_value = next;
                }
            } else |err| log.warn("Neovim grid snapshot failed: {any}", .{err});
        }

        if (self.configured) {
            const focused = rl.isWindowFocused();
            if (focused != self.last_focus) {
                embedded.focus(focused) catch {};
                self.last_focus = focused;
            }
            if (focused) {
                self.forwardInput(embedded, content);
                if (self.embedded == null) return true;
            }
        }
        return false;
    }

    pub fn takeApply(self: *EnabledController) ?Apply {
        const embedded = self.embedded orelse return null;
        const pending = embedded.takeApply() orelse return null;
        return .{
            .source = pending.source,
            .accepted_revision = pending.opening_revision,
            .kind = self.buffer_kind,
        };
    }

    pub fn acceptApply(self: *EnabledController, revision: usize) void {
        const embedded = self.embedded orelse return;
        embedded.acceptApply(revision);
        self.setStatus("Applied to Rayslides · use Studio Save to write the .sld file");
    }

    pub fn rejectApply(self: *EnabledController, message: []const u8) void {
        const embedded = self.embedded orelse return;
        embedded.rejectApply(message) catch {
            embedded.rejectApply("Rayslides rejected the source update") catch {};
        };
        self.setStatus(message);
    }

    pub fn readyForCapture(self: *const EnabledController) bool {
        return self.configured and self.snapshot_value != null;
    }

    pub fn draw(self: *const EnabledController, outer: rl.Rectangle) void {
        if (self.embedded == null) return;
        rl.drawRectangleRec(.{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(rl.getScreenWidth()),
            .height = @floatFromInt(rl.getScreenHeight()),
        }, .{ .r = 4, .g = 7, .b = 12, .a = 220 });
        rl.drawRectangleRec(outer, .{ .r = 15, .g = 18, .b = 25, .a = 255 });
        rl.drawRectangleLinesEx(outer, 1, .{ .r = 88, .g = 98, .b = 120, .a = 255 });

        const header = headerRect(outer);
        rl.drawRectangleRec(header, .{ .r = 24, .g = 29, .b = 40, .a = 255 });
        const label: [:0]const u8 = switch (self.buffer_kind) {
            .source => "EDIT SOURCE · NEOVIM",
            .field => switch (self.field_kind) {
                .text => "EDIT TEXT · NEOVIM",
                .speaker_notes => "EDIT SPEAKER NOTES · NEOVIM",
            },
        };
        rl.drawTextEx(self.font, label, .{ .x = header.x + 14, .y = header.y + 9 }, 17, 0, .{ .r = 226, .g = 232, .b = 240, .a = 255 });
        const status_text: [:0]const u8 = self.status[0..self.status_len :0];
        const status_size = rl.measureTextEx(self.font, status_text, 14, 0);
        rl.drawTextEx(
            self.font,
            status_text,
            .{ .x = header.x + header.width - status_size.x - 14, .y = header.y + 11 },
            14,
            0,
            .{ .r = 151, .g = 163, .b = 184, .a = 255 },
        );

        const content = contentRect(outer);
        const snapshot = if (self.snapshot_value) |*value| value else {
            rl.drawTextEx(self.font, "Waiting for Neovim redraw…", .{ .x = content.x + 12, .y = content.y + 12 }, 18, 0, .{ .r = 190, .g = 198, .b = 210, .a = 255 });
            return;
        };
        const default_fg = snapshot.default_foreground orelse support.grid.Color{ .r = 220, .g = 223, .b = 228 };
        const default_bg = snapshot.default_background orelse support.grid.Color{ .r = 18, .g = 20, .b = 26 };
        rl.beginScissorMode(
            @intFromFloat(content.x),
            @intFromFloat(content.y),
            @intFromFloat(content.width),
            @intFromFloat(content.height),
        );
        rl.drawRectangleRec(content, rayColor(default_bg));
        for (0..snapshot.height) |row| {
            for (0..snapshot.width) |col| {
                const index = row * snapshot.width + col;
                if (index >= snapshot.cells.len) break;
                const paint = snapshot.cells[index];
                var foreground = paint.highlight.foreground orelse default_fg;
                var background = paint.highlight.background orelse default_bg;
                if (paint.highlight.reverse) std.mem.swap(support.grid.Color, &foreground, &background);
                const x = content.x + @as(f32, @floatFromInt(col)) * self.cell_width;
                const y = content.y + @as(f32, @floatFromInt(row)) * self.cell_height;
                if (!std.meta.eql(background, default_bg)) {
                    var color = rayColor(background);
                    color.a = @intCast(255 - @as(u16, paint.highlight.blend) * 255 / 100);
                    rl.drawRectangleRec(.{ .x = x, .y = y, .width = self.cell_width + 0.5, .height = self.cell_height }, color);
                }
                if (paint.cell.text().len > 0 and !std.mem.eql(u8, paint.cell.text(), " ")) {
                    var text_buffer: [support.grid.max_cell_text_bytes + 1:0]u8 = @splat(0);
                    const text = editorCellText(paint.cell.text(), &text_buffer);
                    const cell_font = switch (editorCellFontChoice(text)) {
                        .primary => self.font,
                        .emoji => self.emoji_font,
                    };
                    const color = rayColor(foreground);
                    rl.drawTextEx(cell_font, text, .{ .x = x, .y = y + 1 }, self.font_size, 0, color);
                    if (paint.highlight.bold)
                        rl.drawTextEx(cell_font, text, .{ .x = x + 0.65, .y = y + 1 }, self.font_size, 0, color);
                }
                const decoration = rayColor(paint.highlight.special orelse foreground);
                if (paint.highlight.underline or paint.highlight.undercurl or paint.highlight.underdouble or
                    paint.highlight.underdotted or paint.highlight.underdashed)
                {
                    rl.drawLineEx(.{ .x = x, .y = y + self.cell_height - 2 }, .{ .x = x + self.cell_width, .y = y + self.cell_height - 2 }, 1, decoration);
                }
                if (paint.highlight.strikethrough)
                    rl.drawLineEx(.{ .x = x, .y = y + self.cell_height * 0.55 }, .{ .x = x + self.cell_width, .y = y + self.cell_height * 0.55 }, 1, decoration);
            }
        }
        if (snapshot.cursor_visible and snapshot.cursor_row < snapshot.height and snapshot.cursor_col < snapshot.width) {
            const x = content.x + @as(f32, @floatFromInt(snapshot.cursor_col)) * self.cell_width;
            const y = content.y + @as(f32, @floatFromInt(snapshot.cursor_row)) * self.cell_height;
            const fraction = @as(f32, @floatFromInt(@max(10, snapshot.cursor_style.cell_percentage))) / 100;
            const cursor_color = rayColor(default_fg);
            switch (snapshot.cursor_style.shape) {
                .block => {
                    var translucent = cursor_color;
                    translucent.a = 125;
                    rl.drawRectangleRec(.{ .x = x, .y = y, .width = self.cell_width, .height = self.cell_height }, translucent);
                },
                .vertical => rl.drawRectangleRec(.{ .x = x, .y = y, .width = @max(1.5, self.cell_width * fraction), .height = self.cell_height }, cursor_color),
                .horizontal => rl.drawRectangleRec(.{ .x = x, .y = y + self.cell_height * (1 - fraction), .width = self.cell_width, .height = self.cell_height * fraction }, cursor_color),
            }
        }
        rl.endScissorMode();
    }

    fn forwardInput(self: *EnabledController, embedded: *support.session.Session, content: rl.Rectangle) void {
        const ctrl = rl.isKeyDown(.left_control) or rl.isKeyDown(.right_control);
        const alt = rl.isKeyDown(.left_alt) or rl.isKeyDown(.right_alt);
        const right_alt = rl.isKeyDown(.right_alt);
        const shift = rl.isKeyDown(.left_shift) or rl.isKeyDown(.right_shift);
        const super = rl.isKeyDown(.left_super) or rl.isKeyDown(.right_super);

        if (ctrl and alt and shift and keyTriggered(.f12)) {
            self.setStatus("Neovim overlay force-closed");
            self.closeSession();
            return;
        }

        var character_buffer: [512]u8 = undefined;
        const characters = collectCharacterInput(&character_buffer);
        const send_characters = characters.len > 0 and prefersCharacterInput(
            ctrl,
            alt,
            super,
            right_alt,
            builtin.os.tag == .macos,
        );

        if ((super and keyTriggered(.v)) or (ctrl and shift and keyTriggered(.v)) or (shift and keyTriggered(.insert))) {
            embedded.paste(rl.getClipboardText()) catch |err| log.warn("Neovim paste failed: {any}", .{err});
        } else if (send_characters) {
            sendLiteralText(embedded, characters);
        } else {
            self.forwardModifiedCharacters(embedded, ctrl, alt, shift, super);
        }

        const special = [_]struct { key: rl.KeyboardKey, name: []const u8 }{
            .{ .key = .escape, .name = "Esc" },
            .{ .key = .enter, .name = "CR" },
            .{ .key = .kp_enter, .name = "CR" },
            .{ .key = .tab, .name = "Tab" },
            .{ .key = .backspace, .name = "BS" },
            .{ .key = .delete, .name = "Del" },
            .{ .key = .insert, .name = "Insert" },
            .{ .key = .left, .name = "Left" },
            .{ .key = .right, .name = "Right" },
            .{ .key = .up, .name = "Up" },
            .{ .key = .down, .name = "Down" },
            .{ .key = .home, .name = "Home" },
            .{ .key = .end, .name = "End" },
            .{ .key = .page_up, .name = "PageUp" },
            .{ .key = .page_down, .name = "PageDown" },
            .{ .key = .f1, .name = "F1" },
            .{ .key = .f2, .name = "F2" },
            .{ .key = .f3, .name = "F3" },
            .{ .key = .f4, .name = "F4" },
            .{ .key = .f5, .name = "F5" },
            .{ .key = .f6, .name = "F6" },
            .{ .key = .f7, .name = "F7" },
            .{ .key = .f8, .name = "F8" },
            .{ .key = .f9, .name = "F9" },
            .{ .key = .f10, .name = "F10" },
            .{ .key = .f11, .name = "F11" },
            .{ .key = .f12, .name = "F12" },
        };
        for (special) |entry| {
            if (entry.key == .insert and shift) continue;
            if (entry.key == .f12 and ctrl and alt and shift) continue;
            if (keyTriggered(entry.key)) sendNotation(embedded, entry.name, ctrl, alt, shift, super);
        }

        const snapshot = if (self.snapshot_value) |*value| value else return;
        if (!snapshot.mouse_enabled or snapshot.width == 0 or snapshot.height == 0) return;
        const mouse = rl.getMousePosition();
        const inside = rl.checkCollisionPointRec(mouse, content);
        const col: usize = @min(snapshot.width -| 1, @as(usize, @intFromFloat(@max(0, @floor((mouse.x - content.x) / self.cell_width)))));
        const row: usize = @min(snapshot.height -| 1, @as(usize, @intFromFloat(@max(0, @floor((mouse.y - content.y) / self.cell_height)))));
        const modifier = mouseModifier(ctrl, alt, shift, super);
        const delta = rl.getMouseDelta();
        for ([_]struct { button: rl.MouseButton, name: []const u8 }{
            .{ .button = .left, .name = "left" },
            .{ .button = .right, .name = "right" },
            .{ .button = .middle, .name = "middle" },
        }, 0..) |entry, index| {
            if (inside and rl.isMouseButtonPressed(entry.button)) {
                self.mouse_capture[index] = true;
                embedded.mouse(entry.name, "press", modifier, row, col) catch {};
            }
            if (self.mouse_capture[index] and rl.isMouseButtonDown(entry.button) and (delta.x != 0 or delta.y != 0))
                embedded.mouse(entry.name, "drag", modifier, row, col) catch {};
            if (self.mouse_capture[index] and rl.isMouseButtonReleased(entry.button)) {
                embedded.mouse(entry.name, "release", modifier, row, col) catch {};
                self.mouse_capture[index] = false;
            }
        }
        if (inside and !self.mouse_capture[0] and !self.mouse_capture[1] and !self.mouse_capture[2] and
            (delta.x != 0 or delta.y != 0))
            embedded.mouse("move", "", modifier, row, col) catch {};
        const wheel = rl.getMouseWheelMoveV();
        if (inside and wheel.y != 0) embedded.mouse("wheel", if (wheel.y > 0) "up" else "down", modifier, row, col) catch {};
        if (inside and wheel.x != 0) embedded.mouse("wheel", if (wheel.x > 0) "right" else "left", modifier, row, col) catch {};
    }

    fn forwardModifiedCharacters(self: *EnabledController, embedded: *support.session.Session, ctrl: bool, alt: bool, shift: bool, super: bool) void {
        _ = self;
        if (!ctrl and !alt and !super) return;
        var index: usize = 0;
        while (index < 26) : (index += 1) {
            const key: rl.KeyboardKey = @enumFromInt(@intFromEnum(rl.KeyboardKey.a) + @as(c_int, @intCast(index)));
            if (!keyTriggered(key)) continue;
            var name = [_]u8{0};
            name[0] = @as(u8, 'a') + @as(u8, @intCast(index));
            sendNotation(embedded, name[0..1], ctrl, alt, shift, super);
        }
        for ([_]struct { key: rl.KeyboardKey, name: []const u8 }{
            .{ .key = .space, .name = "Space" },
            .{ .key = .zero, .name = "0" },
            .{ .key = .one, .name = "1" },
            .{ .key = .two, .name = "2" },
            .{ .key = .three, .name = "3" },
            .{ .key = .four, .name = "4" },
            .{ .key = .five, .name = "5" },
            .{ .key = .six, .name = "6" },
            .{ .key = .seven, .name = "7" },
            .{ .key = .eight, .name = "8" },
            .{ .key = .nine, .name = "9" },
            .{ .key = .apostrophe, .name = "'" },
            .{ .key = .comma, .name = "," },
            .{ .key = .minus, .name = "-" },
            .{ .key = .period, .name = "." },
            .{ .key = .slash, .name = "/" },
            .{ .key = .semicolon, .name = ";" },
            .{ .key = .equal, .name = "=" },
            .{ .key = .left_bracket, .name = "[" },
            .{ .key = .backslash, .name = "Bslash" },
            .{ .key = .right_bracket, .name = "]" },
            .{ .key = .grave, .name = "`" },
        }) |entry| {
            if (keyTriggered(entry.key)) sendNotation(embedded, entry.name, ctrl, alt, shift, super);
        }
    }

    fn closeSession(self: *EnabledController) void {
        if (self.embedded) |embedded| embedded.deinit();
        self.embedded = null;
        if (self.initial_source) |source| self.allocator.free(source);
        self.initial_source = null;
        if (self.snapshot_value) |*snapshot| snapshot.deinit();
        self.snapshot_value = null;
        self.configured = false;
        self.last_cols = 0;
        self.last_rows = 0;
        self.mouse_capture = @splat(false);
        self.buffer_kind = .source;
        self.field_kind = .text;
        self.initial_line = 1;
        self.startup_started_at = 0;
    }

    fn setStatus(self: *EnabledController, message: []const u8) void {
        self.status_len = @min(message.len, self.status.len - 1);
        @memcpy(self.status[0..self.status_len], message[0..self.status_len]);
        @memset(self.status[self.status_len..], 0);
    }
};

pub fn overlayRect(screen_width: i32, screen_height: i32) rl.Rectangle {
    const margin = @max(@as(f32, 22), @min(@as(f32, @floatFromInt(screen_width)), @as(f32, @floatFromInt(screen_height))) * 0.035);
    return .{
        .x = margin,
        .y = margin,
        .width = @as(f32, @floatFromInt(screen_width)) - margin * 2,
        .height = @as(f32, @floatFromInt(screen_height)) - margin * 2,
    };
}

fn headerRect(outer: rl.Rectangle) rl.Rectangle {
    return .{ .x = outer.x, .y = outer.y, .width = outer.width, .height = 38 };
}

fn contentRect(outer: rl.Rectangle) rl.Rectangle {
    return .{ .x = outer.x + 1, .y = outer.y + 39, .width = outer.width - 2, .height = outer.height - 40 };
}

fn keyTriggered(key: rl.KeyboardKey) bool {
    return rl.isKeyPressed(key) or rl.isKeyPressedRepeat(key);
}

fn sendNotation(embedded: *support.session.Session, name: []const u8, ctrl: bool, alt: bool, shift: bool, super: bool) void {
    var buffer: [48]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buffer);
    stream.writeByte('<') catch return;
    if (ctrl) stream.writeAll("C-") catch return;
    if (alt) stream.writeAll("M-") catch return;
    if (shift) stream.writeAll("S-") catch return;
    if (super) stream.writeAll("D-") catch return;
    stream.writeAll(name) catch return;
    stream.writeByte('>') catch return;
    embedded.input(stream.buffered()) catch |err| log.warn("Neovim key input failed: {any}", .{err});
}

fn collectCharacterInput(buffer: []u8) []const u8 {
    var len: usize = 0;
    while (true) {
        const codepoint = rl.getCharPressed();
        if (codepoint <= 0) break;
        var encoded: [4]u8 = undefined;
        const encoded_len = std.unicode.utf8Encode(@intCast(codepoint), &encoded) catch continue;
        if (encoded_len > buffer.len - len) continue;
        @memcpy(buffer[len..][0..encoded_len], encoded[0..encoded_len]);
        len += encoded_len;
    }
    return buffer[0..len];
}

fn prefersCharacterInput(
    ctrl: bool,
    alt: bool,
    super: bool,
    right_alt: bool,
    macos: bool,
) bool {
    if (!ctrl and !alt and !super) return true;
    if (ctrl and alt and right_alt and !super) return true; // AltGr.
    return macos and alt and !ctrl and !super; // Option-composed text.
}

fn sendLiteralText(embedded: *support.session.Session, value: []const u8) void {
    var start: usize = 0;
    for (value, 0..) |byte, index| {
        if (byte != '<') continue;
        if (index > start) embedded.input(value[start..index]) catch {};
        embedded.input("<lt>") catch {};
        start = index + 1;
    }
    if (start < value.len)
        embedded.input(value[start..]) catch |err| log.warn("Neovim text input failed: {any}", .{err});
}

fn mouseModifier(ctrl: bool, alt: bool, shift: bool, super: bool) []const u8 {
    const mask = @as(u4, @intFromBool(ctrl)) |
        (@as(u4, @intFromBool(alt)) << 1) |
        (@as(u4, @intFromBool(shift)) << 2) |
        (@as(u4, @intFromBool(super)) << 3);
    return switch (mask) {
        0b0000 => "",
        0b0001 => "C",
        0b0010 => "A",
        0b0011 => "CA",
        0b0100 => "S",
        0b0101 => "CS",
        0b0110 => "AS",
        0b0111 => "CAS",
        0b1000 => "D",
        0b1001 => "CD",
        0b1010 => "AD",
        0b1011 => "CAD",
        0b1100 => "SD",
        0b1101 => "CSD",
        0b1110 => "ASD",
        0b1111 => "CASD",
    };
}

fn rayColor(color: support.grid.Color) rl.Color {
    return .{ .r = color.r, .g = color.g, .b = color.b, .a = 255 };
}

const EditorCellFontChoice = enum {
    primary,
    emoji,
};

fn editorCellFontChoice(text: []const u8) EditorCellFontChoice {
    var byte_index: usize = 0;
    while (byte_index < text.len) {
        const codepoint = nextCodepoint(text, &byte_index);
        if (fonts.codepointFontChoice(codepoint) == .emoji) return .emoji;
    }
    return .primary;
}

/// Neovim may include emoji variation selectors or a joiner in a grid-cell
/// grapheme. Rayslides deliberately renders its portable emoji repertoire as
/// individual monochrome codepoints, so omit those shaping controls instead
/// of letting raylib replace them with tofu.
fn editorCellText(text: []const u8, storage: *[support.grid.max_cell_text_bytes + 1:0]u8) [:0]const u8 {
    var source_index: usize = 0;
    var output_len: usize = 0;
    while (source_index < text.len) {
        const codepoint_start = source_index;
        const codepoint = nextCodepoint(text, &source_index);
        if (fonts.codepointFontChoice(codepoint) == .ignore) continue;
        const codepoint_bytes = text[codepoint_start..source_index];
        if (output_len + codepoint_bytes.len > support.grid.max_cell_text_bytes) break;
        @memcpy(storage[output_len..][0..codepoint_bytes.len], codepoint_bytes);
        output_len += codepoint_bytes.len;
    }
    storage[output_len] = 0;
    return storage[0..output_len :0];
}

fn nextCodepoint(text: []const u8, byte_index: *usize) u21 {
    const sequence_len = std.unicode.utf8ByteSequenceLength(text[byte_index.*]) catch {
        byte_index.* += 1;
        return '?';
    };
    const end = byte_index.* + sequence_len;
    if (end > text.len) {
        byte_index.* += 1;
        return '?';
    }
    const codepoint = std.unicode.utf8Decode(text[byte_index.*..end]) catch {
        byte_index.* += 1;
        return '?';
    };
    byte_index.* = end;
    return codepoint;
}

fn editorFontCharacters(storage: []i32) []const i32 {
    var len: usize = 0;
    for (fonts.default_fontchars) |codepoint| {
        storage[len] = codepoint;
        len += 1;
    }
    for ([_][2]i32{
        .{ 0x0300, 0x036f }, // Combining diacritics used in grid graphemes.
        .{ 0x2500, 0x257f }, // Box drawing used by editor UI/plugins.
        .{ 0x2580, 0x259f }, // Block elements used by status/progress UI.
        .{ 0x25a0, 0x25ff }, // Geometric shapes used by diagnostics/signs.
    }) |range| {
        var codepoint = range[0];
        while (codepoint <= range[1]) : (codepoint += 1) {
            std.debug.assert(len < storage.len);
            storage[len] = codepoint;
            len += 1;
        }
    }
    return storage[0..len];
}

fn loadEditorFont(path: []const u8, font_chars: []const i32, pixel_size: i32) ?rl.Font {
    var path_buffer: [std.fs.max_path_bytes:0]u8 = @splat(0);
    if (path.len >= path_buffer.len) return null;
    @memcpy(path_buffer[0..path.len], path);
    return rl.loadFontEx(path_buffer[0..path.len :0], pixel_size, font_chars) catch null;
}

fn directoryExistsAbsolute(io: std.Io, path: []const u8) bool {
    var dir = std.Io.Dir.openDirAbsolute(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}

test "overlay geometry keeps a usable inset" {
    const rect = overlayRect(1280, 720);
    try std.testing.expect(rect.x >= 22 and rect.y >= 22);
    try std.testing.expect(rect.width > 1100 and rect.height > 600);
}

test "editor font size accepts a bounded finite range" {
    try std.testing.expect(validFontSize(default_font_size));
    try std.testing.expect(validFontSize(minimum_font_size));
    try std.testing.expect(validFontSize(maximum_font_size));
    try std.testing.expect(!validFontSize(minimum_font_size - 0.1));
    try std.testing.expect(!validFontSize(maximum_font_size + 0.1));
    try std.testing.expect(!validFontSize(std.math.nan(f32)));
}

test "editor cells use the Rayslides emoji repertoire and omit shaping controls" {
    for (fonts.emoji_fontchars) |raw_codepoint| {
        const codepoint: u21 = @intCast(raw_codepoint);
        var encoded: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(codepoint, &encoded);
        try std.testing.expectEqual(EditorCellFontChoice.emoji, editorCellFontChoice(encoded[0..len]));
    }
    try std.testing.expectEqual(EditorCellFontChoice.primary, editorCellFontChoice("A→"));

    var text_storage: [support.grid.max_cell_text_bytes + 1:0]u8 = @splat(0);
    try std.testing.expectEqualStrings("❤", editorCellText("❤️", &text_storage));
}

test "mouse modifiers preserve every simultaneous modifier" {
    try std.testing.expectEqualStrings("", mouseModifier(false, false, false, false));
    try std.testing.expectEqualStrings("CA", mouseModifier(true, true, false, false));
    try std.testing.expectEqualStrings("CSD", mouseModifier(true, false, true, true));
    try std.testing.expectEqualStrings("CASD", mouseModifier(true, true, true, true));
}

test "committed text wins for plain input AltGr and macOS Option composition" {
    try std.testing.expect(prefersCharacterInput(false, false, false, false, false));
    try std.testing.expect(prefersCharacterInput(true, true, false, true, false));
    try std.testing.expect(prefersCharacterInput(false, true, false, false, true));
    try std.testing.expect(!prefersCharacterInput(true, false, false, false, false));
    try std.testing.expect(!prefersCharacterInput(false, true, false, false, false));
    try std.testing.expect(!prefersCharacterInput(false, false, true, false, true));
}
