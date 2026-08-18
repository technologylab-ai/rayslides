const std = @import("std");
const rl = @import("raylib");

pub const max_input_bytes = 8192;

pub const Kind = enum {
    text,
    bullets,
    image_path,
    reusable_name,
};

pub const Outcome = enum {
    none,
    submitted,
    cancelled,
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
        self.notice = .none;
        return .accepted;
    }

    pub fn cancel(self: *Prompt) void {
        self.active = false;
        self.notice = .none;
    }

    pub fn text(self: *const Prompt) []const u8 {
        return self.buffer[0..self.len];
    }

    pub fn updateFromRaylib(self: *Prompt) Outcome {
        if (!self.active) return .none;
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
        if (modifier and rl.isKeyPressed(.v)) _ = self.append(rl.getClipboardText());

        if (rl.isKeyPressed(.backspace) or rl.isKeyPressedRepeat(.backspace)) self.removeLastCodepoint();

        const multiline = self.kind == .text or self.kind == .bullets;
        if (rl.isKeyPressed(.enter)) {
            const shift = rl.isKeyDown(.left_shift) or rl.isKeyDown(.right_shift);
            if (multiline and shift) {
                _ = self.append("\n");
            } else {
                self.active = false;
                return .submitted;
            }
        }

        while (true) {
            const pressed = rl.getCharPressed();
            if (pressed <= 0) break;
            const codepoint = std.math.cast(u21, pressed) orelse continue;
            if (codepoint < 32 or codepoint == 127) continue;
            var encoded: [4]u8 = undefined;
            const encoded_len = std.unicode.utf8Encode(codepoint, &encoded) catch continue;
            _ = self.append(encoded[0..encoded_len]);
        }
        return .none;
    }

    pub fn draw(self: *const Prompt, screen_size: rl.Vector2) void {
        if (!self.active) return;
        rl.drawRectangle(0, 0, @intFromFloat(screen_size.x), @intFromFloat(screen_size.y), .{ .r = 2, .g = 5, .b = 12, .a = 175 });

        const width = @min(@as(f32, 920), screen_size.x - 80);
        const height = @min(@as(f32, 430), screen_size.y - 80);
        const panel: rl.Rectangle = .{
            .x = (screen_size.x - width) / 2,
            .y = (screen_size.y - height) / 2,
            .width = width,
            .height = height,
        };
        rl.drawRectangleRounded(panel, 0.035, 12, .{ .r = 12, .g = 17, .b = 30, .a = 250 });
        rl.drawRectangleRoundedLinesEx(panel, 0.035, 12, 2, .{ .r = 80, .g = 215, .b = 255, .a = 230 });

        rl.drawText(promptTitle(self.kind), @intFromFloat(panel.x + 24), @intFromFloat(panel.y + 20), 25, .white);
        rl.drawText(promptHint(self.kind), @intFromFloat(panel.x + 24), @intFromFloat(panel.y + 55), 16, .{ .r = 175, .g = 188, .b = 211, .a = 255 });

        const editor: rl.Rectangle = .{
            .x = panel.x + 24,
            .y = panel.y + 92,
            .width = panel.width - 48,
            .height = panel.height - 142,
        };
        rl.drawRectangleRec(editor, .{ .r = 5, .g = 9, .b = 18, .a = 255 });
        rl.drawRectangleLinesEx(editor, 1, .{ .r = 76, .g = 92, .b = 123, .a = 255 });

        rl.beginScissorMode(
            @intFromFloat(editor.x + 10),
            @intFromFloat(editor.y + 10),
            @intFromFloat(editor.width - 20),
            @intFromFloat(editor.height - 20),
        );
        const visible: [:0]const u8 = if (self.notice.blocksEditing()) "" else self.buffer[0..self.len :0];
        rl.drawText(visible, @intFromFloat(editor.x + 12), @intFromFloat(editor.y + 12), 21, .{ .r = 235, .g = 241, .b = 252, .a = 255 });

        if (!self.notice.blocksEditing()) {
            const cursor_x = editor.x + 12 + @as(f32, @floatFromInt(rl.measureText(lastLine(self.text()), 21)));
            const line_count = 1 + std.mem.count(u8, self.text(), "\n");
            const cursor_y = editor.y + 12 + @as(f32, @floatFromInt(line_count - 1)) * 24;
            if (@mod(@as(i64, @intFromFloat(rl.getTime() * 2)), 2) == 0) {
                rl.drawRectangle(@intFromFloat(cursor_x), @intFromFloat(cursor_y), 2, 22, .{ .r = 80, .g = 215, .b = 255, .a = 255 });
            }
        }
        rl.endScissorMode();

        if (self.noticeMessage()) |message| {
            rl.drawText(message, @intFromFloat(panel.x + 24), @intFromFloat(panel.y + panel.height - 36), 16, .{ .r = 255, .g = 184, .b = 92, .a = 255 });
        }
    }

    /// Appends the complete UTF-8 value or rejects it wholesale. In
    /// particular, a clipboard paste can never be silently shortened at the
    /// byte limit or leave half of a multibyte codepoint in the buffer.
    pub fn append(self: *Prompt, value: []const u8) InputResult {
        if (self.notice.blocksEditing()) return .blocked;
        if (!std.unicode.utf8ValidateSlice(value)) {
            self.notice = .invalid_append_utf8;
            return .invalid_utf8;
        }
        if (value.len > max_input_bytes - self.len) {
            self.notice = .append_overflow;
            return .overflow;
        }
        if (value.len == 0) return .accepted;
        @memcpy(self.buffer[self.len .. self.len + value.len], value);
        self.len += value.len;
        self.buffer[self.len] = 0;
        self.notice = .none;
        return .accepted;
    }

    fn removeLastCodepoint(self: *Prompt) void {
        if (self.notice.blocksEditing() or self.len == 0) return;
        self.len -= 1;
        while (self.len > 0 and self.buffer[self.len] & 0xc0 == 0x80) self.len -= 1;
        self.buffer[self.len] = 0;
        self.notice = .none;
    }

    pub fn noticeMessage(self: *const Prompt) ?[:0]const u8 {
        return switch (self.notice) {
            .none => null,
            .initial_overflow => "Text exceeds the 8 KiB editor limit; nothing was truncated. Esc cancels.",
            .append_overflow => "Input rejected: it would exceed 8 KiB. Existing text was kept.",
            .invalid_initial_utf8 => "Text is not valid UTF-8; nothing was changed. Esc cancels.",
            .invalid_append_utf8 => "Input rejected: it is not valid UTF-8. Existing text was kept.",
        };
    }
};

fn lastLine(value: []const u8) [:0]const u8 {
    // Raylib needs a sentinel. The caller's value always points into Prompt's
    // sentinel-terminated buffer, so its final subslice retains that sentinel.
    const start = if (std.mem.lastIndexOfScalar(u8, value, '\n')) |index| index + 1 else 0;
    return value[start.. :0];
}

fn promptTitle(kind: Kind) [:0]const u8 {
    return switch (kind) {
        .text => "Edit text",
        .bullets => "Edit bullet list",
        .image_path => "Choose image",
        .reusable_name => "Name reusable or template",
    };
}

fn promptHint(kind: Kind) [:0]const u8 {
    return switch (kind) {
        .text => "Enter commits · Shift-Enter adds a line · Cmd/Ctrl-V pastes · Esc cancels",
        .bullets => "One item per line; '-' is added when needed · Shift-Enter adds a line",
        .image_path => "Path relative to the slide file · Enter commits · Esc cancels",
        .reusable_name => "Use letters, numbers, '_' or '-' · Enter commits · Esc cancels",
    };
}

test "prompt edits UTF-8 without splitting the final codepoint" {
    var prompt = Prompt{};
    prompt.begin(.text, "hello €");
    prompt.removeLastCodepoint();
    try std.testing.expectEqualStrings("hello ", prompt.text());
    try std.testing.expectEqual(InputResult.accepted, prompt.append("world"));
    try std.testing.expectEqualStrings("hello world", prompt.text());
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
