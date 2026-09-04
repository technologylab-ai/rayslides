//! Small numeric slide picker shared by Studio and presentation mode.
//!
//! The app owns this overlay rather than either mode, so the same shortcut,
//! validation, and jump semantics apply everywhere. Drawing deliberately uses
//! Studio's command-palette theme without taking on its searchable result list:
//! this picker accepts a slide number and nothing else.

const std = @import("std");
const rl = @import("raylib");
const studio = @import("studio.zig");
const theme = @import("studio_theme.zig");
const motion = @import("studio_motion.zig");

pub const max_digits: usize = 20;

pub const Failure = enum {
    none,
    empty,
    out_of_bounds,
};

pub const Action = union(enum) {
    none,
    cancelled,
    /// Zero-based slide index, converted from the displayed 1-based number.
    select: usize,
};

pub const GShortcutInput = struct {
    pressed: bool,
    shortcut_modifier_down: bool,
    shift_down: bool,
    legacy_presentation_navigation: bool,
};

pub const GShortcutAction = enum {
    none,
    open_picker,
    first_slide,
    last_slide,
};

/// Classifies G once per frame so a modified G can never fall through to the
/// legacy presentation-mode G/Shift+G navigation handlers later in the frame.
pub fn classifyGShortcut(input: GShortcutInput) GShortcutAction {
    if (!input.pressed) return .none;
    if (input.shortcut_modifier_down) return .open_picker;
    if (!input.legacy_presentation_navigation) return .none;
    return if (input.shift_down) .last_slide else .first_slide;
}

pub const Layout = struct {
    scale: f32,
    bounds: rl.Rectangle,
    panel: rl.Rectangle,
    input: rl.Rectangle,
    footer: rl.Rectangle,
};

/// Snapshot of the picker as last drawn open, used while it folds shut.
var afterimage: Picker = .{};

pub const Picker = struct {
    active: bool = false,
    digits: [max_digits:0]u8 = @splat(0),
    len: usize = 0,
    failure: Failure = .none,

    pub fn open(self: *Picker) void {
        self.* = .{ .active = true };
    }

    pub fn close(self: *Picker) void {
        self.* = .{};
    }

    pub fn text(self: *const Picker) [:0]const u8 {
        return self.digits[0..self.len :0];
    }

    /// Returns true only when an ASCII digit was accepted. All other input is
    /// ignored, keeping the field numeric without needing a later sanitizer.
    pub fn appendCodepoint(self: *Picker, codepoint: u21) bool {
        if (codepoint < '0' or codepoint > '9' or self.len >= max_digits) return false;
        self.digits[self.len] = @intCast(codepoint);
        self.len += 1;
        self.digits[self.len] = 0;
        self.failure = .none;
        return true;
    }

    pub fn backspace(self: *Picker) void {
        if (self.len == 0) return;
        self.len -= 1;
        self.digits[self.len] = 0;
        self.failure = .none;
    }

    /// Bounds-checks the displayed 1-based slide number and returns the
    /// renderer's zero-based index. Invalid submissions leave the picker open.
    pub fn submit(self: *Picker, slide_count: usize) Action {
        if (self.len == 0) {
            self.failure = .empty;
            return .none;
        }
        const number = std.fmt.parseInt(usize, self.text(), 10) catch {
            self.failure = .out_of_bounds;
            return .none;
        };
        if (number == 0 or number > slide_count) {
            self.failure = .out_of_bounds;
            return .none;
        }
        self.close();
        return .{ .select = number - 1 };
    }

    pub fn updateFromRaylib(self: *Picker, slide_count: usize) Action {
        if (!self.active) return .none;
        const shortcut_modifier = rl.isKeyDown(.left_control) or rl.isKeyDown(.right_control) or
            rl.isKeyDown(.left_super) or rl.isKeyDown(.right_super);
        if (rl.isKeyPressed(.escape) or (shortcut_modifier and rl.isKeyPressed(.g))) {
            self.close();
            return .cancelled;
        }
        if (rl.isKeyPressed(.backspace) or rl.isKeyPressedRepeat(.backspace)) self.backspace();
        while (true) {
            const pressed = rl.getCharPressed();
            if (pressed <= 0) break;
            const codepoint = std.math.cast(u21, pressed) orelse continue;
            _ = self.appendCodepoint(codepoint);
        }
        if (rl.isKeyPressed(.enter) or rl.isKeyPressed(.kp_enter)) return self.submit(slide_count);
        return .none;
    }

    pub fn draw(
        self: Picker,
        viewport: studio.Viewport,
        font: rl.Font,
        current_slide: usize,
        slide_count: usize,
    ) void {
        // The picker folds open and shut like the command palette; while it
        // folds shut the last typed digits stay visible through the afterimage.
        const reveal = motion.reveal(.goto_slide);
        reveal.setOpen(self.active);
        if (self.active) afterimage = self;
        if (!reveal.visible()) return;
        const shown: Picker = if (self.active) self else afterimage;
        const settled = pickerLayout(viewport);
        if (settled.panel.width <= 0 or settled.panel.height <= 0) return;
        const scale = settled.scale;
        const fold = motion.foldFromTop(settled.panel, reveal.presence(), scale);
        var placement = settled;
        placement.panel = motion.shiftRect(settled.panel, 0, fold.offset_y);
        placement.input = motion.shiftRect(settled.input, 0, fold.offset_y);
        placement.footer = motion.shiftRect(settled.footer, 0, fold.offset_y);
        const heading_size = @as(f32, @floatFromInt(scaledFont(scale, studio.UiTypography.heading)));
        const value_size = @as(f32, @floatFromInt(scaledFont(scale, 30)));
        const compact_size = @as(f32, @floatFromInt(scaledFont(scale, studio.UiTypography.compact)));

        // Same elevation stack as Studio's command palette, scoped to the
        // visible slide so editor docks remain readable and usable context.
        const scrim_alpha: f32 = @floatFromInt(theme.scrim.a);
        rl.drawRectangleRec(placement.bounds, theme.alpha(theme.scrim, @intFromFloat(@round(scrim_alpha * fold.scrim))));
        motion.pushClip(fold.clip);
        defer {
            motion.popClip();
            motion.drawFoldEdge(fold, placement.panel.x, placement.panel.width);
        }
        rl.drawRectangleRounded(.{
            .x = placement.panel.x + 4 * scale,
            .y = placement.panel.y + 10 * scale,
            .width = placement.panel.width,
            .height = placement.panel.height,
        }, 0.05, 12, theme.alpha(theme.shadow, 60));
        rl.drawRectangleRounded(.{
            .x = placement.panel.x + 2 * scale,
            .y = placement.panel.y + 4 * scale,
            .width = placement.panel.width,
            .height = placement.panel.height,
        }, 0.05, 12, theme.alpha(theme.shadow, 100));
        rl.drawRectangleRounded(placement.panel, 0.05, 12, theme.raised);
        rl.drawRectangleRoundedLinesEx(placement.panel, 0.05, 12, scale, theme.border_strong);

        drawText(font, "GO TO SLIDE", .{
            .x = placement.input.x,
            .y = placement.panel.y + 15 * scale,
        }, heading_size, theme.text_heading);

        const value: [:0]const u8 = if (shown.len > 0) shown.text() else "Slide number";
        drawText(font, value, .{
            .x = placement.input.x,
            .y = placement.input.y + (placement.input.height - value_size) / 2,
        }, value_size, if (shown.len > 0) theme.text else theme.text_muted);

        var count_buffer: [48]u8 = undefined;
        const count_text = std.fmt.bufPrintZ(&count_buffer, "/ {d}", .{slide_count}) catch "/ ?";
        const count_width = measureText(font, count_text, heading_size);
        drawText(font, count_text, .{
            .x = placement.input.x + placement.input.width - count_width,
            .y = placement.input.y + (placement.input.height - heading_size) / 2,
        }, heading_size, theme.text_muted);

        const line_color = if (shown.failure == .none) theme.border else theme.danger;
        rl.drawRectangleRec(.{
            .x = placement.input.x,
            .y = placement.input.y + placement.input.height,
            .width = placement.input.width,
            .height = @max(1, scale),
        }, line_color);

        const caret_x = if (shown.len == 0)
            placement.input.x
        else
            @min(
                placement.input.x + placement.input.width - count_width - 14 * scale,
                placement.input.x + measureText(font, shown.text(), value_size) + 3 * scale,
            );
        rl.drawRectangleRec(.{
            .x = caret_x,
            .y = placement.input.y + 10 * scale,
            .width = @max(1, 1.5 * scale),
            .height = @max(0, placement.input.height - 20 * scale),
        }, theme.accent_bright);

        var status_buffer: [96]u8 = undefined;
        const status: [:0]const u8 = switch (shown.failure) {
            .none => std.fmt.bufPrintZ(&status_buffer, "Current slide {d}", .{current_slide + 1}) catch "Current slide",
            .empty => "Enter a slide number",
            .out_of_bounds => std.fmt.bufPrintZ(&status_buffer, "Choose a slide from 1 to {d}", .{slide_count}) catch "Slide is out of range",
        };
        drawText(font, status, .{
            .x = placement.footer.x,
            .y = placement.footer.y + (placement.footer.height - compact_size) / 2,
        }, compact_size, if (shown.failure == .none) theme.text_muted else theme.danger);

        const help: [:0]const u8 = "enter go   esc close";
        const help_width = measureText(font, help, compact_size);
        drawText(font, help, .{
            .x = placement.footer.x + placement.footer.width - help_width,
            .y = placement.footer.y + (placement.footer.height - compact_size) / 2,
        }, compact_size, theme.text_muted);
    }
};

pub fn pickerLayout(viewport: studio.Viewport) Layout {
    const slide: rl.Rectangle = .{
        .x = viewport.slide_top_left.x,
        .y = viewport.slide_top_left.y,
        .width = viewport.slide_size.x,
        .height = viewport.slide_size.y,
    };
    const visible = rectangleIntersection(slide, viewport.canvasBounds()) orelse slide;
    const scale = studio.uiScale(viewport);
    const margin = 20 * scale;
    const panel_width = @min(440 * scale, @max(0, visible.width - margin * 2));
    const panel_height = @min(178 * scale, @max(0, visible.height - margin * 2));
    const panel: rl.Rectangle = .{
        .x = visible.x + (visible.width - panel_width) / 2,
        .y = visible.y + (visible.height - panel_height) / 2,
        .width = panel_width,
        .height = panel_height,
    };
    const inset = 18 * scale;
    const input: rl.Rectangle = .{
        .x = panel.x + inset,
        .y = panel.y + 48 * scale,
        .width = @max(0, panel.width - inset * 2),
        .height = @max(0, @min(62 * scale, panel.height - 92 * scale)),
    };
    return .{
        .scale = scale,
        .bounds = visible,
        .panel = panel,
        .input = input,
        .footer = .{
            .x = panel.x + inset,
            .y = panel.y + panel.height - 38 * scale,
            .width = @max(0, panel.width - inset * 2),
            .height = 24 * scale,
        },
    };
}

fn rectangleIntersection(a: rl.Rectangle, b: rl.Rectangle) ?rl.Rectangle {
    const x = @max(a.x, b.x);
    const y = @max(a.y, b.y);
    const right = @min(a.x + a.width, b.x + b.width);
    const bottom = @min(a.y + a.height, b.y + b.height);
    if (right <= x or bottom <= y) return null;
    return .{ .x = x, .y = y, .width = right - x, .height = bottom - y };
}

fn scaledFont(scale: f32, base_size: i32) i32 {
    return @max(studio.UiTypography.minimum, @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(base_size)) * scale))));
}

fn measureText(font: rl.Font, text: [:0]const u8, size: f32) f32 {
    return rl.measureTextEx(font, text, size, 0).x;
}

fn drawText(font: rl.Font, text: [:0]const u8, position: rl.Vector2, size: f32, color: rl.Color) void {
    rl.drawTextEx(font, text, position, size, 0, color);
}

test "go-to picker accepts only numeric input" {
    var picker: Picker = .{ .active = true };
    try std.testing.expect(!picker.appendCodepoint('a'));
    try std.testing.expect(picker.appendCodepoint('0'));
    try std.testing.expect(picker.appendCodepoint('4'));
    try std.testing.expect(!picker.appendCodepoint(' '));
    try std.testing.expectEqualStrings("04", picker.text());
}

test "modified G only opens the picker and never requests slide one" {
    try std.testing.expectEqual(GShortcutAction.open_picker, classifyGShortcut(.{
        .pressed = true,
        .shortcut_modifier_down = true,
        .shift_down = false,
        .legacy_presentation_navigation = true,
    }));
}

test "plain G retains legacy presentation navigation" {
    try std.testing.expectEqual(GShortcutAction.first_slide, classifyGShortcut(.{
        .pressed = true,
        .shortcut_modifier_down = false,
        .shift_down = false,
        .legacy_presentation_navigation = true,
    }));
    try std.testing.expectEqual(GShortcutAction.last_slide, classifyGShortcut(.{
        .pressed = true,
        .shortcut_modifier_down = false,
        .shift_down = true,
        .legacy_presentation_navigation = true,
    }));
    try std.testing.expectEqual(GShortcutAction.none, classifyGShortcut(.{
        .pressed = true,
        .shortcut_modifier_down = false,
        .shift_down = false,
        .legacy_presentation_navigation = false,
    }));
}

test "go-to picker converts valid bounds and keeps invalid input open" {
    var picker: Picker = .{};
    picker.open();
    _ = picker.appendCodepoint('0');
    try std.testing.expect(picker.submit(42) == .none);
    try std.testing.expect(picker.active);
    try std.testing.expectEqual(Failure.out_of_bounds, picker.failure);

    picker.open();
    _ = picker.appendCodepoint('4');
    _ = picker.appendCodepoint('3');
    try std.testing.expect(picker.submit(42) == .none);
    try std.testing.expect(picker.active);
    try std.testing.expectEqual(Failure.out_of_bounds, picker.failure);

    picker.open();
    try std.testing.expect(picker.submit(42) == .none);
    try std.testing.expectEqual(Failure.empty, picker.failure);

    picker.open();
    _ = picker.appendCodepoint('4');
    _ = picker.appendCodepoint('2');
    switch (picker.submit(42)) {
        .select => |index| try std.testing.expectEqual(@as(usize, 41), index),
        else => return error.ExpectedSlideSelection,
    }
    try std.testing.expect(!picker.active);
}

test "go-to picker panel is centered and contained on the visible slide" {
    const viewport: studio.Viewport = .{
        .slide_top_left = .{ .x = 100, .y = 80 },
        .slide_size = .{ .x = 1280, .y = 720 },
    };
    const placement = pickerLayout(viewport);
    try std.testing.expectApproxEqAbs(
        placement.bounds.x + placement.bounds.width / 2,
        placement.panel.x + placement.panel.width / 2,
        0.001,
    );
    try std.testing.expectApproxEqAbs(
        placement.bounds.y + placement.bounds.height / 2,
        placement.panel.y + placement.panel.height / 2,
        0.001,
    );
    try std.testing.expect(placement.panel.x >= placement.bounds.x);
    try std.testing.expect(placement.panel.y >= placement.bounds.y);
    try std.testing.expect(placement.panel.x + placement.panel.width <= placement.bounds.x + placement.bounds.width);
    try std.testing.expect(placement.panel.y + placement.panel.height <= placement.bounds.y + placement.bounds.height);
}
