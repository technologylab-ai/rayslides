const std = @import("std");
const rl = @import("raylib");
const theme = @import("studio_theme.zig");

pub const max_input_bytes = 8192;
const editor_font_size: f32 = 21;
const editor_line_height: f32 = 25;
const editor_padding: f32 = 12;

pub const Kind = enum {
    text,
    shared_text,
    bullets,
    speaker_notes,
    image_path,
    video_path,
    /// Live-camera device rather than a file: an AVFoundation index or name on
    /// macOS, a V4L2 path on Linux, a DirectShow name on Windows. None of those
    /// are pickable in a file dialog, so this kind offers no Browse button.
    camera_device,
    reusable_name,
    coordinate,
    dimension,
    color,
    font_size,
    opacity,
    document_path,
    portable_folder,
};

pub const Outcome = enum {
    none,
    submitted,
    cancelled,
    browse_requested,
};

pub const InputResult = enum {
    accepted,
    overflow,
    invalid_utf8,
    blocked,
};

pub const Notice = enum {
    none,
    initial_overflow,
    append_overflow,
    invalid_initial_utf8,
    invalid_append_utf8,
    invalid_value,
    invalid_path,
    path_exists,
    save_failed,

    fn blocksEditing(self: Notice) bool {
        return self == .initial_overflow or self == .invalid_initial_utf8;
    }
};

/// Small allocation-free modal editor used by Studio property actions. The
/// source document remains untouched until `submitted` is returned.
pub const Prompt = struct {
    active: bool = false,
    kind: Kind = .text,
    buffer: [max_input_bytes + 1]u8 = [_]u8{0} ** (max_input_bytes + 1),
    len: usize = 0,
    cursor: usize = 0,
    preferred_column: ?usize = null,
    scroll_x: f32 = 0,
    scroll_y: f32 = 0,
    reveal_cursor: bool = false,
    select_all: bool = false,
    notice: Notice = .none,

    pub fn begin(self: *Prompt, kind: Kind, initial: []const u8) void {
        _ = self.tryBegin(kind, initial);
    }

    /// Opens the prompt only when the complete initial value is representable.
    /// On failure the existing buffer is retained byte-for-byte, submission is
    /// disabled, and `draw` displays a visible explanation until cancellation.
    pub fn tryBegin(self: *Prompt, kind: Kind, initial: []const u8) InputResult {
        self.active = true;
        self.kind = kind;
        if (initial.len > max_input_bytes) {
            self.notice = .initial_overflow;
            return .overflow;
        }
        if (!std.unicode.utf8ValidateSlice(initial)) {
            self.notice = .invalid_initial_utf8;
            return .invalid_utf8;
        }

        self.len = initial.len;
        @memcpy(self.buffer[0..self.len], initial);
        self.buffer[self.len] = 0;
        // A roomy multiline editor opens at the visible start of existing
        // content instead of silently placing its caret beyond the clipped
        // bottom/right edge. Scalar prompts retain end-of-value behavior.
        self.cursor = if (kindIsMultiline(kind)) 0 else self.len;
        self.preferred_column = null;
        self.scroll_x = 0;
        self.scroll_y = 0;
        self.reveal_cursor = true;
        self.select_all = false;
        self.notice = .none;
        return .accepted;
    }

    pub fn cancel(self: *Prompt) void {
        self.active = false;
        self.select_all = false;
        self.notice = .none;
    }

    /// Reopens a just-submitted scalar prompt after semantic validation
    /// rejects its complete value. The input remains intact so a typo can be
    /// corrected in place instead of forcing the user to reopen the property
    /// and type it again.
    pub fn rejectValue(self: *Prompt) void {
        self.active = true;
        self.notice = .invalid_value;
    }

    pub fn rejectInvalidPath(self: *Prompt) void {
        self.active = true;
        self.notice = .invalid_path;
    }

    pub fn rejectExistingPath(self: *Prompt) void {
        self.active = true;
        self.notice = .path_exists;
    }

    pub fn rejectSaveFailure(self: *Prompt) void {
        self.active = true;
        self.notice = .save_failed;
    }

    pub fn text(self: *const Prompt) []const u8 {
        return self.buffer[0..self.len];
    }

    pub fn updateFromRaylib(
        self: *Prompt,
        screen_size: rl.Vector2,
        ui_font: rl.Font,
        media_browse_available: bool,
    ) Outcome {
        if (!self.active) return .none;
        const layout = promptLayout(screen_size);
        const pointer = rl.getMousePosition();
        rl.setMouseCursor(if (pointInRectangle(pointer, layout.editor))
            .ibeam
        else if (!self.notice.blocksEditing() and pointInRectangle(pointer, layout.commit))
            .pointing_hand
        else if (media_browse_available and kindIsMediaPath(self.kind) and pointInRectangle(pointer, layout.browse))
            .pointing_hand
        else
            .arrow);
        if (rl.isMouseButtonPressed(.left)) {
            if (!self.notice.blocksEditing() and pointInRectangle(pointer, layout.commit))
                return self.submit();
            if (media_browse_available and kindIsMediaPath(self.kind) and
                pointInRectangle(pointer, layout.browse))
                return .browse_requested;
            if (!self.notice.blocksEditing() and pointInRectangle(pointer, layout.editor)) {
                self.cursor = cursorAtEditorPoint(
                    self.text(),
                    pointer,
                    layout.editor,
                    self.scroll_x,
                    self.scroll_y,
                    ui_font,
                );
                self.preferred_column = null;
                self.select_all = false;
                self.reveal_cursor = true;
            }
        }
        if (rl.isKeyPressed(.escape)) {
            self.cancel();
            return .cancelled;
        }

        // An initial value that cannot be represented is never substituted
        // with a partial or stale value. Escape is the only action until the
        // caller starts a new prompt with a valid complete value.
        if (self.notice.blocksEditing()) return .none;

        const modifier = rl.isKeyDown(.left_control) or rl.isKeyDown(.right_control) or
            rl.isKeyDown(.left_super) or rl.isKeyDown(.right_super);
        if (modifier and rl.isKeyPressed(.a)) {
            self.select_all = true;
            self.cursor = self.len;
            self.preferred_column = null;
            self.reveal_cursor = true;
        }
        if (modifier and rl.isKeyPressed(.v)) _ = self.insert(rl.getClipboardText());

        if (keyPressedOrRepeated(.backspace)) self.removePreviousCodepoint();
        if (keyPressedOrRepeated(.delete)) self.removeNextCodepoint();

        if (keyPressedOrRepeated(.left)) {
            if (self.select_all) {
                self.cursor = 0;
                self.select_all = false;
            } else if (modifier) {
                self.cursor = 0;
            } else {
                self.cursor = previousCodepointBoundary(self.text(), self.cursor);
            }
            self.preferred_column = null;
            self.reveal_cursor = true;
        }
        if (keyPressedOrRepeated(.right)) {
            if (self.select_all or modifier) {
                self.cursor = self.len;
                self.select_all = false;
            } else {
                self.cursor = nextCodepointBoundary(self.text(), self.cursor);
            }
            self.preferred_column = null;
            self.reveal_cursor = true;
        }
        if (keyPressedOrRepeated(.home)) {
            self.select_all = false;
            self.cursor = if (modifier) 0 else lineInfoAtCursor(self.text(), self.cursor).start;
            self.preferred_column = null;
            self.reveal_cursor = true;
        }
        if (keyPressedOrRepeated(.end)) {
            self.select_all = false;
            self.cursor = if (modifier) self.len else lineInfoAtCursor(self.text(), self.cursor).end;
            self.preferred_column = null;
            self.reveal_cursor = true;
        }
        if (keyPressedOrRepeated(.up)) self.moveCursorVertically(-1);
        if (keyPressedOrRepeated(.down)) self.moveCursorVertically(1);
        if (keyPressedOrRepeated(.page_up))
            self.moveCursorVertically(-@as(isize, @intFromFloat(@max(1, @floor(editorInner(layout.editor).height / editor_line_height)))));
        if (keyPressedOrRepeated(.page_down))
            self.moveCursorVertically(@as(isize, @intFromFloat(@max(1, @floor(editorInner(layout.editor).height / editor_line_height)))));

        const multiline = kindIsMultiline(self.kind);
        if (rl.isKeyPressed(.enter)) {
            const outcome = self.handleEnter(multiline and modifier);
            if (outcome != .none) return outcome;
        }

        while (true) {
            const pressed = rl.getCharPressed();
            if (pressed <= 0) break;
            const codepoint = std.math.cast(u21, pressed) orelse continue;
            if (codepoint < 32 or codepoint == 127) continue;
            var encoded: [4]u8 = undefined;
            const encoded_len = std.unicode.utf8Encode(codepoint, &encoded) catch continue;
            _ = self.insert(encoded[0..encoded_len]);
        }

        const wheel = rl.getMouseWheelMoveV();
        if (pointInRectangle(pointer, layout.editor) and (wheel.x != 0 or wheel.y != 0)) {
            const shift = rl.isKeyDown(.left_shift) or rl.isKeyDown(.right_shift);
            if (shift) {
                self.scroll_x -= (wheel.x + wheel.y) * editor_line_height * 3;
            } else {
                self.scroll_x -= wheel.x * editor_line_height * 3;
                self.scroll_y -= wheel.y * editor_line_height * 3;
            }
            self.reveal_cursor = false;
            self.clampScroll(layout.editor, ui_font);
        }
        if (self.reveal_cursor) {
            self.ensureCursorVisible(layout.editor, ui_font);
            self.reveal_cursor = false;
        }
        return .none;
    }

    /// Draws with Studio's dedicated UI face. Requiring the font at this
    /// boundary keeps every prompt kind off raylib's built-in pixel font and
    /// also ensures caret measurement uses the same glyph metrics as the
    /// editor text.
    pub fn draw(
        self: *const Prompt,
        screen_size: rl.Vector2,
        ui_font: rl.Font,
        media_browse_available: bool,
    ) void {
        if (!self.active) return;
        rl.drawRectangle(0, 0, @intFromFloat(screen_size.x), @intFromFloat(screen_size.y), theme.scrim);

        const layout = promptLayout(screen_size);
        const panel = layout.panel;
        rl.drawRectangleRounded(panel, 0.035, 12, theme.raised);
        rl.drawRectangleRoundedLinesEx(panel, 0.035, 12, 1, theme.border_strong);

        rl.drawTextEx(ui_font, promptTitle(self.kind), .{ .x = panel.x + 24, .y = panel.y + 20 }, 25, 0, .white);
        drawPromptButton(
            ui_font,
            layout.commit,
            promptCommitLabel(self.kind),
            !self.notice.blocksEditing(),
            true,
        );
        rl.drawTextEx(ui_font, promptHint(self.kind), .{ .x = panel.x + 24, .y = panel.y + 55 }, 16, 0, theme.text_muted);

        const editor = layout.editor;
        const inner = editorInner(editor);
        rl.drawRectangleRec(editor, theme.field);
        rl.drawRectangleLinesEx(editor, 1, theme.border_strong);
        if (!self.notice.blocksEditing() and self.select_all)
            rl.drawRectangleRec(inner, theme.selection);

        rl.beginScissorMode(
            @intFromFloat(inner.x),
            @intFromFloat(inner.y),
            @intFromFloat(inner.width),
            @intFromFloat(inner.height),
        );
        const visible: [:0]const u8 = if (self.notice.blocksEditing()) "" else self.buffer[0..self.len :0];
        const content_origin: rl.Vector2 = .{
            .x = inner.x - self.scroll_x,
            .y = inner.y - self.scroll_y,
        };
        drawEditorText(ui_font, visible, content_origin, theme.text);

        if (!self.notice.blocksEditing() and !self.select_all) {
            const caret = cursorContentPosition(self.text(), self.cursor, ui_font);
            rl.drawRectangleRec(.{
                .x = content_origin.x + caret.x,
                .y = content_origin.y + caret.y,
                .width = 2,
                .height = editor_font_size + 2,
            }, theme.accent_bright);
        }
        rl.endScissorMode();
        if (!self.notice.blocksEditing())
            drawEditorScrollbars(self.*, editor, ui_font);

        if (self.noticeMessage()) |message| {
            rl.drawTextEx(ui_font, message, .{ .x = panel.x + 24, .y = panel.y + panel.height - 36 }, 16, 0, theme.warning);
        }
        if (media_browse_available and kindIsMediaPath(self.kind)) {
            const hovered = pointInRectangle(rl.getMousePosition(), layout.browse);
            rl.drawRectangleRec(layout.browse, if (hovered) theme.control_hover else theme.control);
            rl.drawRectangleLinesEx(layout.browse, 1, theme.border_strong);
            const label: [:0]const u8 = "Browse…";
            const font_size: f32 = 16;
            const label_width = rl.measureTextEx(ui_font, label, font_size, 0).x;
            rl.drawTextEx(
                ui_font,
                label,
                .{
                    .x = layout.browse.x + (layout.browse.width - label_width) / 2,
                    .y = layout.browse.y + (layout.browse.height - font_size) / 2,
                },
                font_size,
                0,
                theme.text,
            );
        }
    }

    /// Appends the complete UTF-8 value or rejects it wholesale. In
    /// particular, a clipboard paste can never be silently shortened at the
    /// byte limit or leave half of a multibyte codepoint in the buffer.
    pub fn append(self: *Prompt, value: []const u8) InputResult {
        self.cursor = self.len;
        self.select_all = false;
        return self.insert(value);
    }

    /// Inserts a complete UTF-8 value at the caret. The buffer movement is
    /// atomic, so a rejected paste never changes either the text or caret.
    fn insert(self: *Prompt, value: []const u8) InputResult {
        if (self.notice.blocksEditing()) return .blocked;
        if (!std.unicode.utf8ValidateSlice(value)) {
            self.notice = .invalid_append_utf8;
            return .invalid_utf8;
        }
        const retained_len: usize = if (self.select_all) 0 else self.len;
        if (value.len > max_input_bytes - retained_len) {
            self.notice = .append_overflow;
            return .overflow;
        }
        if (value.len == 0) return .accepted;
        if (self.select_all) {
            self.len = 0;
            self.cursor = 0;
            self.buffer[0] = 0;
            self.select_all = false;
        }
        std.mem.copyBackwards(
            u8,
            self.buffer[self.cursor + value.len .. self.len + value.len],
            self.buffer[self.cursor..self.len],
        );
        @memcpy(self.buffer[self.cursor .. self.cursor + value.len], value);
        self.len += value.len;
        self.cursor += value.len;
        self.buffer[self.len] = 0;
        self.preferred_column = null;
        self.reveal_cursor = true;
        self.notice = .none;
        return .accepted;
    }

    /// Multiline prompts behave like text editors: an unmodified Enter adds a
    /// line, while Cmd/Ctrl-Enter explicitly submits. Scalar prompts retain
    /// the conventional Enter-to-submit behavior.
    fn handleEnter(self: *Prompt, commit_multiline: bool) Outcome {
        if (kindIsMultiline(self.kind) and !commit_multiline) {
            _ = self.insert("\n");
            return .none;
        }
        return self.submit();
    }

    fn submit(self: *Prompt) Outcome {
        if (self.notice.blocksEditing()) return .none;
        self.active = false;
        return .submitted;
    }

    fn removePreviousCodepoint(self: *Prompt) void {
        if (self.notice.blocksEditing()) return;
        if (self.select_all) {
            self.clearSelectedText();
            return;
        }
        if (self.cursor == 0) return;
        const start = previousCodepointBoundary(self.text(), self.cursor);
        self.removeRange(start, self.cursor);
        self.cursor = start;
        self.preferred_column = null;
        self.reveal_cursor = true;
    }

    fn removeNextCodepoint(self: *Prompt) void {
        if (self.notice.blocksEditing()) return;
        if (self.select_all) {
            self.clearSelectedText();
            return;
        }
        if (self.cursor >= self.len) return;
        self.removeRange(self.cursor, nextCodepointBoundary(self.text(), self.cursor));
        self.preferred_column = null;
        self.reveal_cursor = true;
    }

    fn clearSelectedText(self: *Prompt) void {
        if (!self.select_all) return;
        self.len = 0;
        self.cursor = 0;
        self.buffer[self.len] = 0;
        self.select_all = false;
        self.preferred_column = null;
        self.reveal_cursor = true;
        self.notice = .none;
    }

    fn removeRange(self: *Prompt, start: usize, end: usize) void {
        std.debug.assert(start <= end and end <= self.len);
        const removed = end - start;
        std.mem.copyForwards(u8, self.buffer[start .. self.len - removed], self.buffer[end..self.len]);
        self.len -= removed;
        self.buffer[self.len] = 0;
        self.notice = .none;
    }

    fn moveCursorVertically(self: *Prompt, delta: isize) void {
        if (delta == 0) return;
        self.select_all = false;
        const text_value = self.text();
        const current = lineInfoAtCursor(text_value, self.cursor);
        const desired_column = self.preferred_column orelse
            (std.unicode.utf8CountCodepoints(text_value[current.start..self.cursor]) catch 0);
        self.preferred_column = desired_column;
        const line_count = countTextLines(text_value);
        const current_line: isize = @intCast(current.index);
        const target_signed = std.math.clamp(current_line + delta, 0, @as(isize, @intCast(line_count - 1)));
        const target = lineInfoAtIndex(text_value, @intCast(target_signed));
        self.cursor = byteOffsetAtCodepointColumn(text_value, target, desired_column);
        self.reveal_cursor = true;
    }

    fn clampScroll(self: *Prompt, editor: rl.Rectangle, ui_font: rl.Font) void {
        const limits = editorScrollLimits(self.text(), editor, ui_font);
        self.scroll_x = std.math.clamp(self.scroll_x, 0, limits.x);
        self.scroll_y = std.math.clamp(self.scroll_y, 0, limits.y);
    }

    fn ensureCursorVisible(self: *Prompt, editor: rl.Rectangle, ui_font: rl.Font) void {
        const inner = editorInner(editor);
        const caret = cursorContentPosition(self.text(), self.cursor, ui_font);
        const margin: f32 = 5;
        if (caret.x < self.scroll_x + margin) self.scroll_x = @max(0, caret.x - margin);
        if (caret.x + 2 > self.scroll_x + inner.width - margin)
            self.scroll_x = caret.x + 2 - inner.width + margin;
        if (caret.y < self.scroll_y + margin) self.scroll_y = @max(0, caret.y - margin);
        if (caret.y + editor_line_height > self.scroll_y + inner.height - margin)
            self.scroll_y = caret.y + editor_line_height - inner.height + margin;
        self.clampScroll(editor, ui_font);
    }

    pub fn noticeMessage(self: *const Prompt) ?[:0]const u8 {
        return switch (self.notice) {
            .none => null,
            .initial_overflow => "Text exceeds the 8 KiB editor limit; nothing was truncated. Esc cancels.",
            .append_overflow => "Input rejected: it would exceed 8 KiB. Existing text was kept.",
            .invalid_initial_utf8 => "Text is not valid UTF-8; nothing was changed. Esc cancels.",
            .invalid_append_utf8 => "Input rejected: it is not valid UTF-8. Existing text was kept.",
            .invalid_value => "That value is invalid. Correct it and press Enter; the slide is unchanged.",
            .invalid_path => "Choose a non-empty single-line file path. The deck is still untitled.",
            .path_exists => "That file already exists. Choose another name; nothing was overwritten.",
            .save_failed => "The deck could not be saved there. Check the path and try again.",
        };
    }
};

const LineInfo = struct {
    start: usize,
    end: usize,
    index: usize,
};

fn keyPressedOrRepeated(key: rl.KeyboardKey) bool {
    return rl.isKeyPressed(key) or rl.isKeyPressedRepeat(key);
}

fn previousCodepointBoundary(text: []const u8, cursor: usize) usize {
    if (cursor == 0) return 0;
    var result = cursor - 1;
    while (result > 0 and text[result] & 0xc0 == 0x80) result -= 1;
    return result;
}

fn nextCodepointBoundary(text: []const u8, cursor: usize) usize {
    if (cursor >= text.len) return text.len;
    const sequence_len = std.unicode.utf8ByteSequenceLength(text[cursor]) catch 1;
    return @min(text.len, cursor + sequence_len);
}

fn lineInfoAtCursor(text: []const u8, cursor: usize) LineInfo {
    const bounded = @min(cursor, text.len);
    const start = if (std.mem.lastIndexOfScalar(u8, text[0..bounded], '\n')) |index| index + 1 else 0;
    const end = if (std.mem.indexOfScalarPos(u8, text, bounded, '\n')) |index| index else text.len;
    return .{
        .start = start,
        .end = end,
        .index = std.mem.count(u8, text[0..start], "\n"),
    };
}

fn lineInfoAtIndex(text: []const u8, requested_index: usize) LineInfo {
    var start: usize = 0;
    var line_index: usize = 0;
    while (line_index < requested_index) : (line_index += 1) {
        const newline = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse
            return .{ .start = text.len, .end = text.len, .index = line_index };
        start = newline + 1;
    }
    const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
    return .{ .start = start, .end = end, .index = line_index };
}

fn countTextLines(text: []const u8) usize {
    return 1 + std.mem.count(u8, text, "\n");
}

fn byteOffsetAtCodepointColumn(text: []const u8, line: LineInfo, column: usize) usize {
    var offset = line.start;
    var current_column: usize = 0;
    while (offset < line.end and current_column < column) : (current_column += 1)
        offset = nextCodepointBoundary(text, offset);
    return offset;
}

fn glyphAdvance(font: rl.Font, codepoint: u21) f32 {
    if (font.baseSize <= 0 or font.glyphCount <= 0) return editor_font_size * 0.56;
    const raw_index = rl.getGlyphIndex(font, codepoint);
    if (raw_index < 0 or raw_index >= font.glyphCount) return editor_font_size * 0.56;
    const index: usize = @intCast(raw_index);
    const scale = editor_font_size / @as(f32, @floatFromInt(font.baseSize));
    const advance = font.glyphs[index].advanceX;
    if (advance != 0) return @as(f32, @floatFromInt(advance)) * scale;
    return font.recs[index].width * scale;
}

fn textWidth(font: rl.Font, text: []const u8) f32 {
    var width: f32 = 0;
    var offset: usize = 0;
    while (offset < text.len) {
        const next = nextCodepointBoundary(text, offset);
        const codepoint = std.unicode.utf8Decode(text[offset..next]) catch '?';
        width += glyphAdvance(font, codepoint);
        offset = next;
    }
    return width;
}

fn cursorContentPosition(text: []const u8, cursor: usize, ui_font: rl.Font) rl.Vector2 {
    const line = lineInfoAtCursor(text, cursor);
    return .{
        .x = textWidth(ui_font, text[line.start..@min(cursor, line.end)]),
        .y = @as(f32, @floatFromInt(line.index)) * editor_line_height,
    };
}

fn editorInner(editor: rl.Rectangle) rl.Rectangle {
    return .{
        .x = editor.x + editor_padding,
        .y = editor.y + editor_padding,
        .width = @max(0, editor.width - editor_padding * 2),
        .height = @max(0, editor.height - editor_padding * 2),
    };
}

fn editorScrollLimits(text: []const u8, editor: rl.Rectangle, ui_font: rl.Font) rl.Vector2 {
    var max_width: f32 = 0;
    for (0..countTextLines(text)) |line_index| {
        const line = lineInfoAtIndex(text, line_index);
        max_width = @max(max_width, textWidth(ui_font, text[line.start..line.end]));
    }
    const inner = editorInner(editor);
    const content_height = @as(f32, @floatFromInt(countTextLines(text))) * editor_line_height;
    return .{
        .x = @max(0, max_width + 3 - inner.width),
        .y = @max(0, content_height - inner.height),
    };
}

fn cursorAtEditorPoint(
    text: []const u8,
    pointer: rl.Vector2,
    editor: rl.Rectangle,
    scroll_x: f32,
    scroll_y: f32,
    ui_font: rl.Font,
) usize {
    const inner = editorInner(editor);
    const content_y = @max(0, pointer.y - inner.y + scroll_y);
    const requested_line: usize = @intFromFloat(@floor(content_y / editor_line_height));
    const line = lineInfoAtIndex(text, @min(requested_line, countTextLines(text) - 1));
    const content_x = @max(0, pointer.x - inner.x + scroll_x);
    var width: f32 = 0;
    var offset = line.start;
    while (offset < line.end) {
        const next = nextCodepointBoundary(text, offset);
        const advance = textWidth(ui_font, text[offset..next]);
        if (content_x < width + advance / 2) return offset;
        width += advance;
        offset = next;
    }
    return line.end;
}

fn drawEditorScrollbars(prompt: Prompt, editor: rl.Rectangle, ui_font: rl.Font) void {
    const limits = editorScrollLimits(prompt.text(), editor, ui_font);
    const inner = editorInner(editor);
    const track_color: rl.Color = theme.control;
    const thumb_color: rl.Color = theme.border_strong;
    if (limits.y > 0) {
        const track: rl.Rectangle = .{
            .x = editor.x + editor.width - 7,
            .y = inner.y,
            .width = 4,
            .height = inner.height,
        };
        const content_height = inner.height + limits.y;
        const thumb_height = @min(track.height, @max(24, track.height * inner.height / content_height));
        const travel = track.height - thumb_height;
        rl.drawRectangleRec(track, track_color);
        rl.drawRectangleRec(.{
            .x = track.x,
            .y = track.y + travel * prompt.scroll_y / limits.y,
            .width = track.width,
            .height = thumb_height,
        }, thumb_color);
    }
    if (limits.x > 0) {
        const track: rl.Rectangle = .{
            .x = inner.x,
            .y = editor.y + editor.height - 7,
            .width = inner.width,
            .height = 4,
        };
        const content_width = inner.width + limits.x;
        const thumb_width = @min(track.width, @max(24, track.width * inner.width / content_width));
        const travel = track.width - thumb_width;
        rl.drawRectangleRec(track, track_color);
        rl.drawRectangleRec(.{
            .x = track.x + travel * prompt.scroll_x / limits.x,
            .y = track.y,
            .width = thumb_width,
            .height = track.height,
        }, thumb_color);
    }
}

fn drawEditorText(font: rl.Font, text: []const u8, origin: rl.Vector2, color: rl.Color) void {
    var line_buffer: [max_input_bytes + 1]u8 = undefined;
    for (0..countTextLines(text)) |line_index| {
        const line = lineInfoAtIndex(text, line_index);
        const line_text = text[line.start..line.end];
        @memcpy(line_buffer[0..line_text.len], line_text);
        line_buffer[line_text.len] = 0;
        rl.drawTextEx(
            font,
            line_buffer[0..line_text.len :0],
            .{
                .x = origin.x,
                .y = origin.y + @as(f32, @floatFromInt(line_index)) * editor_line_height,
            },
            editor_font_size,
            0,
            color,
        );
    }
}

const PromptLayout = struct {
    panel: rl.Rectangle,
    editor: rl.Rectangle,
    commit: rl.Rectangle,
    browse: rl.Rectangle,
};

fn promptLayout(screen_size: rl.Vector2) PromptLayout {
    const width = @min(@as(f32, 920), screen_size.x - 80);
    const height = @min(@as(f32, 430), screen_size.y - 80);
    const panel: rl.Rectangle = .{
        .x = (screen_size.x - width) / 2,
        .y = (screen_size.y - height) / 2,
        .width = width,
        .height = height,
    };
    return .{
        .panel = panel,
        .editor = .{
            .x = panel.x + 24,
            .y = panel.y + 92,
            .width = panel.width - 48,
            .height = panel.height - 142,
        },
        .commit = .{
            .x = panel.x + panel.width - 136,
            .y = panel.y + 16,
            .width = 112,
            .height = 34,
        },
        .browse = .{
            .x = panel.x + panel.width - 136,
            .y = panel.y + panel.height - 44,
            .width = 112,
            .height = 30,
        },
    };
}

fn drawPromptButton(
    ui_font: rl.Font,
    rect: rl.Rectangle,
    label: [:0]const u8,
    enabled: bool,
    emphasized: bool,
) void {
    const hovered = enabled and pointInRectangle(rl.getMousePosition(), rect);
    // The confirming action is the only filled button; everything else stays
    // neutral so the dialog has a single obvious default.
    const fill: rl.Color = if (!enabled)
        theme.control_disabled
    else if (emphasized)
        if (hovered) theme.accent else theme.accent_fill
    else if (hovered)
        theme.control_hover
    else
        theme.control;
    const border: rl.Color = if (!enabled)
        theme.border
    else if (emphasized)
        theme.accent
    else
        theme.border_strong;
    const text_color: rl.Color = if (enabled) theme.text else theme.text_disabled;
    rl.drawRectangleRec(rect, fill);
    rl.drawRectangleLinesEx(rect, 1, border);
    const font_size: f32 = 16;
    const label_width = rl.measureTextEx(ui_font, label, font_size, 0).x;
    rl.drawTextEx(
        ui_font,
        label,
        .{
            .x = rect.x + (rect.width - label_width) / 2,
            .y = rect.y + (rect.height - font_size) / 2,
        },
        font_size,
        0,
        text_color,
    );
}

fn pointInRectangle(point: rl.Vector2, rect: rl.Rectangle) bool {
    return point.x >= rect.x and point.x <= rect.x + rect.width and
        point.y >= rect.y and point.y <= rect.y + rect.height;
}

fn lastLine(value: [:0]const u8) [:0]const u8 {
    // Keep the sentinel in the type. Reconstructing a sentinel slice from an
    // ordinary `[]const u8` forces a bounds check at `len`, even when the
    // backing Prompt buffer really does contain the terminator there.
    const start = if (std.mem.lastIndexOfScalar(u8, value, '\n')) |index| index + 1 else 0;
    return value[start.. :0];
}

test "last prompt line retains its sentinel at every boundary" {
    try std.testing.expectEqualStrings("", lastLine(""));
    try std.testing.expectEqualStrings("one", lastLine("one"));
    try std.testing.expectEqualStrings("two", lastLine("one\ntwo"));
    try std.testing.expectEqualStrings("", lastLine("one\n"));
    try std.testing.expectEqualStrings("€", lastLine("one\n€"));
}

fn promptTitle(kind: Kind) [:0]const u8 {
    return switch (kind) {
        .text => "Edit text",
        .shared_text => "Edit shared template text",
        .bullets => "Edit bullet list",
        .speaker_notes => "Edit speaker notes",
        .image_path => "Choose image",
        .video_path => "Choose video",
        .camera_device => "Choose camera device",
        .reusable_name => "Name reusable or template",
        .coordinate => "Set coordinate",
        .dimension => "Set object size",
        .color => "Set custom color",
        .font_size => "Set font size",
        .opacity => "Set opacity",
        .document_path => "Name and save your deck",
        .portable_folder => "Create portable show folder",
    };
}

fn kindIsMultiline(kind: Kind) bool {
    return kind == .text or kind == .shared_text or
        kind == .bullets or kind == .speaker_notes;
}

fn kindIsMediaPath(kind: Kind) bool {
    return kind == .image_path or kind == .video_path;
}

test "image and video prompts share browsing but retain specific copy" {
    try std.testing.expect(kindIsMediaPath(.image_path));
    try std.testing.expect(kindIsMediaPath(.video_path));
    try std.testing.expect(!kindIsMediaPath(.document_path));
    try std.testing.expectEqualStrings("Choose image", promptTitle(.image_path));
    try std.testing.expectEqualStrings("Choose video", promptTitle(.video_path));
    try std.testing.expect(std.mem.indexOf(u8, promptHint(.image_path), "image") != null);
    try std.testing.expect(std.mem.indexOf(u8, promptHint(.video_path), "video") != null);
}

test "camera prompt asks for a device instead of a browsable file" {
    try std.testing.expect(!kindIsMediaPath(.camera_device));
    try std.testing.expectEqualStrings("Choose camera device", promptTitle(.camera_device));
    try std.testing.expect(std.mem.indexOf(u8, promptHint(.camera_device), "/dev/video") != null);
}

fn promptCommitLabel(kind: Kind) [:0]const u8 {
    if (kindIsMultiline(kind)) return "COMMIT";
    return if (kind == .document_path) "SAVE" else if (kind == .portable_folder) "CREATE" else "OK";
}

fn promptHint(kind: Kind) [:0]const u8 {
    return switch (kind) {
        .text => "Enter adds a line · COMMIT applies changes · Cmd/Ctrl-Enter is optional",
        .shared_text => "Enter adds a line · COMMIT applies shared template text",
        .bullets => "Enter adds a line · COMMIT applies changes · One item per line",
        .speaker_notes => "Enter adds a line · COMMIT applies private notes",
        .image_path => "Browse for an image or enter a path relative to the slide file · Enter commits · Esc cancels",
        .video_path => "Browse for a video or enter a path relative to the slide file · Enter commits · Esc cancels",
        .camera_device => "Capture device · index or name on macOS, /dev/video* on Linux · Enter commits · Esc cancels",
        .reusable_name => "Use letters, numbers, '_' or '-' · Enter commits · Esc cancels",
        .coordinate => "Logical slide pixels · decimals and negative values are allowed · Enter commits",
        .dimension => "Logical slide pixels · use a positive value · Enter commits",
        .color => "Use #RRGGBB or #RRGGBBAA · Enter commits · Esc cancels",
        .font_size => "Positive whole-number pixels · Enter commits · Esc cancels",
        .opacity => "Use 0–1 or 0–100% · transparent items remain selectable in Objects",
        .document_path => "Relative or absolute .sld path · Enter saves · Esc keeps it untitled",
        .portable_folder => "New empty folder path · assets and a normal .sld copy will be created · Esc cancels",
    };
}

test "prompt edits UTF-8 without splitting the final codepoint" {
    var prompt = Prompt{};
    prompt.begin(.text, "hello €");
    prompt.cursor = prompt.len;
    prompt.removePreviousCodepoint();
    try std.testing.expectEqualStrings("hello ", prompt.text());
    try std.testing.expectEqual(InputResult.accepted, prompt.append("world"));
    try std.testing.expectEqualStrings("hello world", prompt.text());
}

test "prompt inserts and deletes complete UTF-8 codepoints at the caret" {
    var prompt = Prompt{};
    prompt.begin(.text, "ab€cd");
    prompt.cursor = 2;
    try std.testing.expectEqual(InputResult.accepted, prompt.insert("X"));
    try std.testing.expectEqualStrings("abX€cd", prompt.text());
    try std.testing.expectEqual(@as(usize, 3), prompt.cursor);

    prompt.removeNextCodepoint();
    try std.testing.expectEqualStrings("abXcd", prompt.text());
    prompt.removePreviousCodepoint();
    try std.testing.expectEqualStrings("abcd", prompt.text());
    try std.testing.expect(std.unicode.utf8ValidateSlice(prompt.text()));
}

test "multiline Enter inserts a line and only Cmd or Ctrl Enter submits" {
    var prompt = Prompt{};
    prompt.begin(.text, "- first\n- second");
    prompt.cursor = prompt.len;

    try std.testing.expectEqual(Outcome.none, prompt.handleEnter(false));
    try std.testing.expect(prompt.active);
    try std.testing.expectEqualStrings("- first\n- second\n", prompt.text());

    try std.testing.expectEqual(Outcome.submitted, prompt.handleEnter(true));
    try std.testing.expect(!prompt.active);

    prompt.begin(.coordinate, "42");
    try std.testing.expectEqual(Outcome.submitted, prompt.handleEnter(false));
    try std.testing.expect(!prompt.active);
}

test "prompt commit button action submits editable values and labels modal intent" {
    var prompt = Prompt{};
    prompt.begin(.text, "changed");
    try std.testing.expectEqualStrings("COMMIT", promptCommitLabel(prompt.kind));
    try std.testing.expectEqual(Outcome.submitted, prompt.submit());
    try std.testing.expect(!prompt.active);

    prompt.begin(.coordinate, "42");
    try std.testing.expectEqualStrings("OK", promptCommitLabel(prompt.kind));
    prompt.begin(.document_path, "talk.sld");
    try std.testing.expectEqualStrings("SAVE", promptCommitLabel(prompt.kind));
}

test "prompt vertical movement preserves its desired codepoint column" {
    var prompt = Prompt{};
    prompt.begin(.text, "abcd\nx\nwxyz");
    prompt.cursor = 3;
    prompt.moveCursorVertically(1);
    try std.testing.expectEqual(@as(usize, 6), prompt.cursor);
    prompt.moveCursorVertically(1);
    try std.testing.expectEqual(@as(usize, 10), prompt.cursor);
    prompt.moveCursorVertically(-2);
    try std.testing.expectEqual(@as(usize, 3), prompt.cursor);
}

test "prompt select-all replacement is atomic and resets the caret" {
    var prompt = Prompt{};
    prompt.begin(.text, "old text");
    prompt.select_all = true;
    try std.testing.expectEqual(InputResult.accepted, prompt.insert("replacement"));
    try std.testing.expectEqualStrings("replacement", prompt.text());
    try std.testing.expectEqual(prompt.len, prompt.cursor);
    try std.testing.expect(!prompt.select_all);
}

test "prompt keeps a distant multiline caret visible with both scroll axes" {
    var prompt = Prompt{};
    var value: [1024]u8 = undefined;
    var stream = std.Io.Writer.fixed(&value);
    for (0..18) |line| {
        if (line > 0) try stream.writeByte('\n');
        try stream.print("line-{d}-abcdefghijklmnopqrstuvwxyz0123456789", .{line});
    }
    prompt.begin(.text, stream.buffered());
    prompt.cursor = prompt.len;
    const editor: rl.Rectangle = .{ .x = 0, .y = 0, .width = 180, .height = 90 };
    prompt.ensureCursorVisible(editor, std.mem.zeroes(rl.Font));
    try std.testing.expect(prompt.scroll_x > 0);
    try std.testing.expect(prompt.scroll_y > 0);

    prompt.cursor = 0;
    prompt.ensureCursorVisible(editor, std.mem.zeroes(rl.Font));
    try std.testing.expectEqual(@as(f32, 0), prompt.scroll_x);
    try std.testing.expectEqual(@as(f32, 0), prompt.scroll_y);
}

test "prompt click positioning selects the requested visible line" {
    const editor: rl.Rectangle = .{ .x = 10, .y = 20, .width = 300, .height = 140 };
    const inner = editorInner(editor);
    const cursor = cursorAtEditorPoint(
        "abc\ndef\nghi",
        .{ .x = inner.x + 1, .y = inner.y + editor_line_height + 2 },
        editor,
        0,
        0,
        std.mem.zeroes(rl.Font),
    );
    try std.testing.expectEqual(@as(usize, 4), cursor);
}

test "shared template text uses an explicit multiline prompt kind" {
    var prompt = Prompt{};
    try std.testing.expectEqual(InputResult.accepted, prompt.tryBegin(.shared_text, "Shared\ntext"));
    try std.testing.expectEqualStrings("Shared\ntext", prompt.text());
    try std.testing.expectEqual(@as(usize, 0), prompt.cursor);
    try std.testing.expectEqualStrings("Edit shared template text", promptTitle(prompt.kind));

    prompt.begin(.color, "#123456ff");
    try std.testing.expectEqual(prompt.len, prompt.cursor);
}

test "oversized initial text is refused without replacing existing input" {
    var prompt = Prompt{};
    try std.testing.expectEqual(InputResult.accepted, prompt.tryBegin(.text, "keep me"));

    var oversized: [max_input_bytes + 1]u8 = undefined;
    @memset(&oversized, 'x');
    try std.testing.expectEqual(InputResult.overflow, prompt.tryBegin(.text, &oversized));
    try std.testing.expect(prompt.active);
    try std.testing.expectEqual(Notice.initial_overflow, prompt.notice);
    try std.testing.expect(prompt.noticeMessage() != null);
    try std.testing.expectEqualStrings("keep me", prompt.text());
    try std.testing.expectEqual(InputResult.blocked, prompt.append("!"));
}

test "oversized paste is rejected atomically at a UTF-8 boundary" {
    var prompt = Prompt{};
    var initial: [max_input_bytes - 2]u8 = undefined;
    @memset(&initial, 'a');
    try std.testing.expectEqual(InputResult.accepted, prompt.tryBegin(.text, &initial));

    const before = prompt.text();
    try std.testing.expectEqual(InputResult.overflow, prompt.append("€"));
    try std.testing.expectEqual(@as(usize, max_input_bytes - 2), prompt.len);
    try std.testing.expectEqualSlices(u8, &initial, prompt.text());
    try std.testing.expectEqualSlices(u8, &initial, before);
    try std.testing.expect(std.unicode.utf8ValidateSlice(prompt.text()));
    try std.testing.expectEqual(Notice.append_overflow, prompt.notice);
}

test "paste larger than the entire prompt capacity is refused wholesale" {
    var prompt = Prompt{};
    prompt.begin(.text, "existing");

    var oversized: [max_input_bytes + 1]u8 = undefined;
    @memset(&oversized, 'p');
    try std.testing.expectEqual(InputResult.overflow, prompt.append(&oversized));
    try std.testing.expectEqualStrings("existing", prompt.text());
    try std.testing.expectEqual(Notice.append_overflow, prompt.notice);
    try std.testing.expect(prompt.noticeMessage() != null);
}

test "complete UTF-8 input exactly at capacity is accepted" {
    var exact: [max_input_bytes]u8 = undefined;
    @memset(&exact, 'a');
    @memcpy(exact[exact.len - "€".len ..], "€");

    var prompt = Prompt{};
    try std.testing.expectEqual(InputResult.accepted, prompt.tryBegin(.text, &exact));
    try std.testing.expectEqual(@as(usize, max_input_bytes), prompt.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(prompt.text()));
    try std.testing.expectEqual(InputResult.overflow, prompt.append("x"));
    try std.testing.expectEqualSlices(u8, &exact, prompt.text());
}

test "invalid UTF-8 append is refused without modifying the prompt" {
    var prompt = Prompt{};
    prompt.begin(.text, "valid");
    const invalid = [_]u8{ 0xe2, 0x82 };
    try std.testing.expectEqual(InputResult.invalid_utf8, prompt.append(&invalid));
    try std.testing.expectEqualStrings("valid", prompt.text());
    try std.testing.expectEqual(Notice.invalid_append_utf8, prompt.notice);
}

test "semantic value rejection keeps submitted input editable" {
    var prompt = Prompt{};
    prompt.begin(.color, "#12345g");
    prompt.active = false;
    prompt.rejectValue();
    try std.testing.expect(prompt.active);
    try std.testing.expectEqual(Notice.invalid_value, prompt.notice);
    try std.testing.expectEqualStrings("#12345g", prompt.text());
    try std.testing.expectEqual(InputResult.accepted, prompt.append("0"));
    try std.testing.expectEqual(Notice.none, prompt.notice);
}
