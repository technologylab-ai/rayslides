const std = @import("std");
const rpc = @import("rpc.zig");

pub const primary_grid_id: u64 = 1;
pub const max_cell_text_bytes = 32;

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn fromInteger(value: i64) ?Color {
        if (value < 0 or value > 0x00ff_ffff) return null;
        const rgb: u32 = @intCast(value);
        return .{
            .r = @truncate(rgb >> 16),
            .g = @truncate(rgb >> 8),
            .b = @truncate(rgb),
        };
    }
};

pub const Highlight = struct {
    foreground: ?Color = null,
    background: ?Color = null,
    special: ?Color = null,
    reverse: bool = false,
    italic: bool = false,
    bold: bool = false,
    strikethrough: bool = false,
    underline: bool = false,
    undercurl: bool = false,
    underdouble: bool = false,
    underdotted: bool = false,
    underdashed: bool = false,
    blend: u8 = 0,
};

pub const CursorShape = enum {
    block,
    horizontal,
    vertical,
};

pub const CursorStyle = struct {
    shape: CursorShape = .block,
    cell_percentage: u8 = 100,
    blink_wait_ms: u32 = 0,
    blink_on_ms: u32 = 0,
    blink_off_ms: u32 = 0,
    highlight_id: u64 = 0,
};

pub const Cell = struct {
    bytes: [max_cell_text_bytes]u8 = [_]u8{0} ** max_cell_text_bytes,
    len: u8 = 1,
    highlight_id: u64 = 0,
    replaced_oversized_text: bool = false,

    pub fn blank() Cell {
        var cell: Cell = .{};
        cell.bytes[0] = ' ';
        return cell;
    }

    pub fn text(self: *const Cell) []const u8 {
        return self.bytes[0..self.len];
    }

    fn setText(self: *Cell, value: []const u8) void {
        self.replaced_oversized_text = false;
        if (value.len <= self.bytes.len) {
            @memcpy(self.bytes[0..value.len], value);
            if (value.len < self.bytes.len) @memset(self.bytes[value.len..], 0);
            self.len = @intCast(value.len);
            return;
        }

        // A cell can contain a complete grapheme cluster. Pathological plugin
        // output must not allocate per-cell or silently change column width;
        // paint a visible replacement and retain a diagnostic bit instead.
        const replacement = "\xef\xbf\xbd";
        @memcpy(self.bytes[0..replacement.len], replacement);
        @memset(self.bytes[replacement.len..], 0);
        self.len = replacement.len;
        self.replaced_oversized_text = true;
    }
};

pub const Model = struct {
    allocator: std.mem.Allocator,
    width: usize = 0,
    height: usize = 0,
    cells: []Cell = &.{},
    highlights: std.AutoHashMap(u64, Highlight),
    default_foreground: ?Color = null,
    default_background: ?Color = null,
    default_special: ?Color = null,
    cursor_row: usize = 0,
    cursor_col: usize = 0,
    cursor_visible: bool = true,
    cursor_style: CursorStyle = .{},
    mode_name: [32]u8 = [_]u8{0} ** 32,
    mode_name_len: u8 = 0,
    mode_styles: std.ArrayList(CursorStyle) = .empty,
    mouse_enabled: bool = false,
    busy: bool = false,
    flush_revision: u64 = 0,
    unknown_event_count: u64 = 0,
    oversized_cell_count: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) Model {
        return .{
            .allocator = allocator,
            .highlights = std.AutoHashMap(u64, Highlight).init(allocator),
        };
    }

    pub fn deinit(self: *Model) void {
        self.allocator.free(self.cells);
        self.cells = &.{};
        self.highlights.deinit();
        self.mode_styles.deinit(self.allocator);
    }

    pub fn cell(self: *const Model, row: usize, col: usize) ?*const Cell {
        if (row >= self.height or col >= self.width) return null;
        return &self.cells[row * self.width + col];
    }

    pub fn mode(self: *const Model) []const u8 {
        return self.mode_name[0..self.mode_name_len];
    }

    pub fn highlight(self: *const Model, id: u64) Highlight {
        return self.highlights.get(id) orelse .{};
    }

    pub fn applyNotification(self: *Model, view: *rpc.View) !bool {
        if (try view.kind() != .notification) return false;
        if (!std.mem.eql(u8, try view.method(), "redraw")) return false;
        try self.applyRedraw(view, try view.params());
        return true;
    }

    pub fn applyRedraw(self: *Model, view: *rpc.View, batches: rpc.Node) !void {
        for (0..try view.arrayLen(batches)) |batch_index| {
            const batch = try view.arrayAt(batches, batch_index);
            const batch_len = try view.arrayLen(batch);
            if (batch_len == 0) continue;
            const event_name = try view.string(try view.arrayAt(batch, 0));

            if (std.mem.eql(u8, event_name, "flush")) {
                self.flush_revision +%= 1;
                if (self.flush_revision == 0) self.flush_revision = 1;
                continue;
            }
            if (std.mem.eql(u8, event_name, "mouse_on")) {
                self.mouse_enabled = true;
                continue;
            }
            if (std.mem.eql(u8, event_name, "mouse_off")) {
                self.mouse_enabled = false;
                continue;
            }
            if (std.mem.eql(u8, event_name, "busy_start")) {
                self.busy = true;
                continue;
            }
            if (std.mem.eql(u8, event_name, "busy_stop")) {
                self.busy = false;
                continue;
            }

            var handled = true;
            for (1..batch_len) |call_index| {
                const args = try view.arrayAt(batch, call_index);
                if (std.mem.eql(u8, event_name, "grid_resize")) {
                    try self.applyGridResize(view, args);
                } else if (std.mem.eql(u8, event_name, "grid_clear")) {
                    try self.applyGridClear(view, args);
                } else if (std.mem.eql(u8, event_name, "grid_destroy")) {
                    try self.applyGridDestroy(view, args);
                } else if (std.mem.eql(u8, event_name, "grid_line")) {
                    try self.applyGridLine(view, args);
                } else if (std.mem.eql(u8, event_name, "grid_scroll")) {
                    try self.applyGridScroll(view, args);
                } else if (std.mem.eql(u8, event_name, "grid_cursor_goto")) {
                    try self.applyCursor(view, args);
                } else if (std.mem.eql(u8, event_name, "default_colors_set")) {
                    try self.applyDefaultColors(view, args);
                } else if (std.mem.eql(u8, event_name, "hl_attr_define")) {
                    try self.applyHighlight(view, args);
                } else if (std.mem.eql(u8, event_name, "mode_info_set")) {
                    try self.applyModeInfo(view, args);
                } else if (std.mem.eql(u8, event_name, "mode_change")) {
                    try self.applyModeChange(view, args);
                } else {
                    handled = false;
                    break;
                }
            }
            if (!handled) self.unknown_event_count +%= 1;
        }
    }

    fn applyGridResize(self: *Model, view: *rpc.View, args: rpc.Node) !void {
        if (try view.arrayLen(args) < 3) return error.UnexpectedShape;
        if (try view.uint(try view.arrayAt(args, 0)) != primary_grid_id) return;
        const new_width = try asUsize(try view.uint(try view.arrayAt(args, 1)));
        const new_height = try asUsize(try view.uint(try view.arrayAt(args, 2)));
        const count = try std.math.mul(usize, new_width, new_height);
        if (count > 4_000_000) return error.GridTooLarge;

        const replacement = try self.allocator.alloc(Cell, count);
        @memset(replacement, Cell.blank());
        const copy_width = @min(self.width, new_width);
        const copy_height = @min(self.height, new_height);
        for (0..copy_height) |row| {
            @memcpy(
                replacement[row * new_width ..][0..copy_width],
                self.cells[row * self.width ..][0..copy_width],
            );
        }
        self.allocator.free(self.cells);
        self.cells = replacement;
        self.width = new_width;
        self.height = new_height;
        if (self.height == 0) self.cursor_row = 0 else self.cursor_row = @min(self.cursor_row, self.height - 1);
        if (self.width == 0) self.cursor_col = 0 else self.cursor_col = @min(self.cursor_col, self.width - 1);
    }

    fn applyGridClear(self: *Model, view: *rpc.View, args: rpc.Node) !void {
        if (try view.arrayLen(args) < 1) return error.UnexpectedShape;
        if (try view.uint(try view.arrayAt(args, 0)) != primary_grid_id) return;
        @memset(self.cells, Cell.blank());
    }

    fn applyGridDestroy(self: *Model, view: *rpc.View, args: rpc.Node) !void {
        if (try view.arrayLen(args) < 1) return error.UnexpectedShape;
        if (try view.uint(try view.arrayAt(args, 0)) != primary_grid_id) return;
        self.allocator.free(self.cells);
        self.cells = &.{};
        self.width = 0;
        self.height = 0;
    }

    fn applyGridLine(self: *Model, view: *rpc.View, args: rpc.Node) !void {
        if (try view.arrayLen(args) < 4) return error.UnexpectedShape;
        if (try view.uint(try view.arrayAt(args, 0)) != primary_grid_id) return;
        const row = try asUsize(try view.uint(try view.arrayAt(args, 1)));
        var col = try asUsize(try view.uint(try view.arrayAt(args, 2)));
        const updates = try view.arrayAt(args, 3);
        if (row >= self.height) return;
        var current_highlight: u64 = 0;

        for (0..try view.arrayLen(updates)) |update_index| {
            const update = try view.arrayAt(updates, update_index);
            const update_len = try view.arrayLen(update);
            if (update_len < 1 or update_len > 3) return error.UnexpectedShape;
            const text = try view.string(try view.arrayAt(update, 0));
            if (update_len >= 2) current_highlight = try view.uint(try view.arrayAt(update, 1));
            const repeat = if (update_len >= 3)
                try asUsize(try view.uint(try view.arrayAt(update, 2)))
            else
                1;
            if (repeat > self.width) return error.GridLineTooLarge;

            for (0..repeat) |_| {
                if (col >= self.width) break;
                var target = &self.cells[row * self.width + col];
                target.* = Cell.blank();
                target.highlight_id = current_highlight;
                target.setText(text);
                if (target.replaced_oversized_text) self.oversized_cell_count +%= 1;
                col += 1;
            }
        }
    }

    fn applyGridScroll(self: *Model, view: *rpc.View, args: rpc.Node) !void {
        if (try view.arrayLen(args) < 7) return error.UnexpectedShape;
        if (try view.uint(try view.arrayAt(args, 0)) != primary_grid_id) return;
        const top = try asUsize(try view.uint(try view.arrayAt(args, 1)));
        const bottom = try asUsize(try view.uint(try view.arrayAt(args, 2)));
        const left = try asUsize(try view.uint(try view.arrayAt(args, 3)));
        const right = try asUsize(try view.uint(try view.arrayAt(args, 4)));
        const rows = try view.int(try view.arrayAt(args, 5));
        const cols = try view.int(try view.arrayAt(args, 6));
        if (top > bottom or left > right or bottom > self.height or right > self.width) return error.UnexpectedShape;

        const region_width = right - left;
        const region_height = bottom - top;
        const count = try std.math.mul(usize, region_width, region_height);
        const snapshot = try self.allocator.alloc(Cell, count);
        defer self.allocator.free(snapshot);
        for (0..region_height) |row| {
            @memcpy(
                snapshot[row * region_width ..][0..region_width],
                self.cells[(top + row) * self.width + left ..][0..region_width],
            );
        }

        for (0..region_height) |dest_row| {
            for (0..region_width) |dest_col| {
                const source_row = @as(i64, @intCast(dest_row)) + rows;
                const source_col = @as(i64, @intCast(dest_col)) + cols;
                const target = &self.cells[(top + dest_row) * self.width + left + dest_col];
                if (source_row >= 0 and source_row < region_height and source_col >= 0 and source_col < region_width) {
                    target.* = snapshot[@as(usize, @intCast(source_row)) * region_width + @as(usize, @intCast(source_col))];
                } else {
                    target.* = Cell.blank();
                }
            }
        }
    }

    fn applyCursor(self: *Model, view: *rpc.View, args: rpc.Node) !void {
        if (try view.arrayLen(args) < 3) return error.UnexpectedShape;
        if (try view.uint(try view.arrayAt(args, 0)) != primary_grid_id) return;
        const row = try asUsize(try view.uint(try view.arrayAt(args, 1)));
        const col = try asUsize(try view.uint(try view.arrayAt(args, 2)));
        if (row >= self.height or col >= self.width) return;
        self.cursor_row = row;
        self.cursor_col = col;
    }

    fn applyDefaultColors(self: *Model, view: *rpc.View, args: rpc.Node) !void {
        if (try view.arrayLen(args) < 3) return error.UnexpectedShape;
        self.default_foreground = Color.fromInteger(try view.int(try view.arrayAt(args, 0)));
        self.default_background = Color.fromInteger(try view.int(try view.arrayAt(args, 1)));
        self.default_special = Color.fromInteger(try view.int(try view.arrayAt(args, 2)));
    }

    fn applyHighlight(self: *Model, view: *rpc.View, args: rpc.Node) !void {
        if (try view.arrayLen(args) < 2) return error.UnexpectedShape;
        const id = try view.uint(try view.arrayAt(args, 0));
        const attrs = try view.arrayAt(args, 1);
        var highlight_value: Highlight = .{};
        for (0..try view.mapLen(attrs)) |entry_index| {
            const key = try view.string(try view.mapKeyAt(attrs, entry_index));
            const value = try view.mapValueAt(attrs, entry_index);
            if (std.mem.eql(u8, key, "foreground")) {
                highlight_value.foreground = Color.fromInteger(try view.int(value));
            } else if (std.mem.eql(u8, key, "background")) {
                highlight_value.background = Color.fromInteger(try view.int(value));
            } else if (std.mem.eql(u8, key, "special")) {
                highlight_value.special = Color.fromInteger(try view.int(value));
            } else if (std.mem.eql(u8, key, "reverse")) {
                highlight_value.reverse = try view.boolean(value);
            } else if (std.mem.eql(u8, key, "italic")) {
                highlight_value.italic = try view.boolean(value);
            } else if (std.mem.eql(u8, key, "bold")) {
                highlight_value.bold = try view.boolean(value);
            } else if (std.mem.eql(u8, key, "strikethrough")) {
                highlight_value.strikethrough = try view.boolean(value);
            } else if (std.mem.eql(u8, key, "underline")) {
                highlight_value.underline = try view.boolean(value);
            } else if (std.mem.eql(u8, key, "undercurl")) {
                highlight_value.undercurl = try view.boolean(value);
            } else if (std.mem.eql(u8, key, "underdouble")) {
                highlight_value.underdouble = try view.boolean(value);
            } else if (std.mem.eql(u8, key, "underdotted")) {
                highlight_value.underdotted = try view.boolean(value);
            } else if (std.mem.eql(u8, key, "underdashed")) {
                highlight_value.underdashed = try view.boolean(value);
            } else if (std.mem.eql(u8, key, "blend")) {
                highlight_value.blend = @intCast(@min(100, try view.uint(value)));
            }
        }
        try self.highlights.put(id, highlight_value);
    }

    fn applyModeInfo(self: *Model, view: *rpc.View, args: rpc.Node) !void {
        if (try view.arrayLen(args) < 2) return error.UnexpectedShape;
        self.cursor_visible = try view.boolean(try view.arrayAt(args, 0));
        const modes = try view.arrayAt(args, 1);
        self.mode_styles.clearRetainingCapacity();
        try self.mode_styles.ensureTotalCapacity(self.allocator, try view.arrayLen(modes));
        for (0..try view.arrayLen(modes)) |mode_index| {
            const attrs = try view.arrayAt(modes, mode_index);
            var style: CursorStyle = .{};
            for (0..try view.mapLen(attrs)) |entry_index| {
                const key = try view.string(try view.mapKeyAt(attrs, entry_index));
                const value = try view.mapValueAt(attrs, entry_index);
                if (std.mem.eql(u8, key, "cursor_shape")) {
                    const shape = try view.string(value);
                    style.shape = if (std.mem.eql(u8, shape, "horizontal"))
                        .horizontal
                    else if (std.mem.eql(u8, shape, "vertical"))
                        .vertical
                    else
                        .block;
                } else if (std.mem.eql(u8, key, "cell_percentage")) {
                    style.cell_percentage = @intCast(@min(100, try view.uint(value)));
                } else if (std.mem.eql(u8, key, "blinkwait")) {
                    style.blink_wait_ms = @intCast(@min(std.math.maxInt(u32), try view.uint(value)));
                } else if (std.mem.eql(u8, key, "blinkon")) {
                    style.blink_on_ms = @intCast(@min(std.math.maxInt(u32), try view.uint(value)));
                } else if (std.mem.eql(u8, key, "blinkoff")) {
                    style.blink_off_ms = @intCast(@min(std.math.maxInt(u32), try view.uint(value)));
                } else if (std.mem.eql(u8, key, "attr_id")) {
                    style.highlight_id = try view.uint(value);
                }
            }
            self.mode_styles.appendAssumeCapacity(style);
        }
    }

    fn applyModeChange(self: *Model, view: *rpc.View, args: rpc.Node) !void {
        if (try view.arrayLen(args) < 2) return error.UnexpectedShape;
        const name = try view.string(try view.arrayAt(args, 0));
        const copy_len = @min(name.len, self.mode_name.len);
        @memcpy(self.mode_name[0..copy_len], name[0..copy_len]);
        if (copy_len < self.mode_name.len) @memset(self.mode_name[copy_len..], 0);
        self.mode_name_len = @intCast(copy_len);
        const style_index = try asUsize(try view.uint(try view.arrayAt(args, 1)));
        if (style_index < self.mode_styles.items.len) self.cursor_style = self.mode_styles.items[style_index];
    }
};

fn asUsize(value: u64) !usize {
    return std.math.cast(usize, value) orelse error.ValueOutOfRange;
}

fn applyEncoded(model: *Model, encoded: []const u8) !void {
    var view: rpc.View = .{};
    try view.init(encoded);
    defer view.deinit();
    try std.testing.expect(try model.applyNotification(&view));
}

test "line-grid redraw applies colors highlights cells cursor mode and flush" {
    var encoder = rpc.Encoder.init(std.testing.allocator);
    defer encoder.deinit();
    try encoder.beginNotification("redraw", 8);

    try encoder.writeArrayHeader(2);
    try encoder.writeString("grid_resize");
    try encoder.writeArrayHeader(3);
    try encoder.writeUint(1);
    try encoder.writeUint(5);
    try encoder.writeUint(2);

    try encoder.writeArrayHeader(2);
    try encoder.writeString("default_colors_set");
    try encoder.writeArrayHeader(5);
    try encoder.writeUint(0xd0d0d0);
    try encoder.writeUint(0x101010);
    try encoder.writeUint(0xff0000);
    try encoder.writeInt(-1);
    try encoder.writeInt(-1);

    try encoder.writeArrayHeader(2);
    try encoder.writeString("hl_attr_define");
    try encoder.writeArrayHeader(4);
    try encoder.writeUint(7);
    try encoder.writeMapHeader(3);
    try encoder.writeString("foreground");
    try encoder.writeUint(0x112233);
    try encoder.writeString("background");
    try encoder.writeUint(0x445566);
    try encoder.writeString("bold");
    try encoder.writeBool(true);
    try encoder.writeMapHeader(0);
    try encoder.writeArrayHeader(0);

    try encoder.writeArrayHeader(2);
    try encoder.writeString("grid_line");
    try encoder.writeArrayHeader(5);
    try encoder.writeUint(1);
    try encoder.writeUint(0);
    try encoder.writeUint(0);
    try encoder.writeArrayHeader(3);
    try encoder.writeArrayHeader(2);
    try encoder.writeString("A");
    try encoder.writeUint(7);
    try encoder.writeArrayHeader(1);
    try encoder.writeString("B");
    try encoder.writeArrayHeader(3);
    try encoder.writeString(" ");
    try encoder.writeUint(0);
    try encoder.writeUint(3);
    try encoder.writeBool(false);

    try encoder.writeArrayHeader(2);
    try encoder.writeString("grid_cursor_goto");
    try encoder.writeArrayHeader(3);
    try encoder.writeUint(1);
    try encoder.writeUint(0);
    try encoder.writeUint(1);

    try encoder.writeArrayHeader(2);
    try encoder.writeString("mode_info_set");
    try encoder.writeArrayHeader(2);
    try encoder.writeBool(true);
    try encoder.writeArrayHeader(1);
    try encoder.writeMapHeader(3);
    try encoder.writeString("cursor_shape");
    try encoder.writeString("vertical");
    try encoder.writeString("cell_percentage");
    try encoder.writeUint(25);
    try encoder.writeString("attr_id");
    try encoder.writeUint(7);

    try encoder.writeArrayHeader(2);
    try encoder.writeString("mode_change");
    try encoder.writeArrayHeader(2);
    try encoder.writeString("insert");
    try encoder.writeUint(0);

    try encoder.writeArrayHeader(2);
    try encoder.writeString("flush");
    try encoder.writeArrayHeader(0);

    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    try applyEncoded(&model, encoder.bytes());

    try std.testing.expectEqual(@as(usize, 5), model.width);
    try std.testing.expectEqual(@as(usize, 2), model.height);
    try std.testing.expectEqualStrings("A", model.cell(0, 0).?.text());
    try std.testing.expectEqual(@as(u64, 7), model.cell(0, 0).?.highlight_id);
    try std.testing.expectEqualStrings("B", model.cell(0, 1).?.text());
    try std.testing.expectEqual(@as(u64, 7), model.cell(0, 1).?.highlight_id);
    try std.testing.expectEqualStrings(" ", model.cell(0, 4).?.text());
    try std.testing.expectEqual(@as(usize, 0), model.cursor_row);
    try std.testing.expectEqual(@as(usize, 1), model.cursor_col);
    try std.testing.expectEqualStrings("insert", model.mode());
    try std.testing.expectEqual(CursorShape.vertical, model.cursor_style.shape);
    try std.testing.expectEqual(@as(u8, 25), model.cursor_style.cell_percentage);
    try std.testing.expect(model.highlight(7).bold);
    try std.testing.expectEqual(Color{ .r = 0x11, .g = 0x22, .b = 0x33 }, model.highlight(7).foreground.?);
    try std.testing.expectEqual(@as(u64, 1), model.flush_revision);
}

test "grid scroll copies a rectangular snapshot and clears exposed cells" {
    var model = Model.init(std.testing.allocator);
    defer model.deinit();

    var encoder = rpc.Encoder.init(std.testing.allocator);
    defer encoder.deinit();
    try encoder.beginNotification("redraw", 3);
    try encoder.writeArrayHeader(2);
    try encoder.writeString("grid_resize");
    try encoder.writeArrayHeader(3);
    try encoder.writeUint(1);
    try encoder.writeUint(3);
    try encoder.writeUint(3);

    try encoder.writeArrayHeader(4);
    try encoder.writeString("grid_line");
    for ([_][]const u8{ "abc", "def", "ghi" }, 0..) |line, row| {
        try encoder.writeArrayHeader(5);
        try encoder.writeUint(1);
        try encoder.writeUint(row);
        try encoder.writeUint(0);
        try encoder.writeArrayHeader(3);
        for (line) |byte| {
            try encoder.writeArrayHeader(1);
            try encoder.writeString(&.{byte});
        }
        try encoder.writeBool(false);
    }

    try encoder.writeArrayHeader(2);
    try encoder.writeString("grid_scroll");
    try encoder.writeArrayHeader(7);
    try encoder.writeUint(1);
    try encoder.writeUint(0);
    try encoder.writeUint(3);
    try encoder.writeUint(0);
    try encoder.writeUint(3);
    try encoder.writeInt(1);
    try encoder.writeInt(0);

    try applyEncoded(&model, encoder.bytes());
    try std.testing.expectEqualStrings("d", model.cell(0, 0).?.text());
    try std.testing.expectEqualStrings("g", model.cell(1, 0).?.text());
    try std.testing.expectEqualStrings(" ", model.cell(2, 0).?.text());
}

test "oversized grapheme cells receive a visible replacement and diagnostic" {
    var encoder = rpc.Encoder.init(std.testing.allocator);
    defer encoder.deinit();
    try encoder.beginNotification("redraw", 2);
    try encoder.writeArrayHeader(2);
    try encoder.writeString("grid_resize");
    try encoder.writeArrayHeader(3);
    try encoder.writeUint(1);
    try encoder.writeUint(1);
    try encoder.writeUint(1);
    try encoder.writeArrayHeader(2);
    try encoder.writeString("grid_line");
    try encoder.writeArrayHeader(5);
    try encoder.writeUint(1);
    try encoder.writeUint(0);
    try encoder.writeUint(0);
    try encoder.writeArrayHeader(1);
    try encoder.writeArrayHeader(1);
    try encoder.writeString("abcdefghijklmnopqrstuvwxyz0123456789");
    try encoder.writeBool(false);

    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    try applyEncoded(&model, encoder.bytes());
    try std.testing.expectEqualStrings("\xef\xbf\xbd", model.cell(0, 0).?.text());
    try std.testing.expect(model.cell(0, 0).?.replaced_oversized_text);
    try std.testing.expectEqual(@as(u64, 1), model.oversized_cell_count);
}

test "wide continuation and combining grapheme cells preserve exact bytes" {
    var encoder = rpc.Encoder.init(std.testing.allocator);
    defer encoder.deinit();
    try encoder.beginNotification("redraw", 3);

    try encoder.writeArrayHeader(2);
    try encoder.writeString("grid_resize");
    try encoder.writeArrayHeader(3);
    try encoder.writeUint(primary_grid_id);
    try encoder.writeUint(4);
    try encoder.writeUint(1);

    try encoder.writeArrayHeader(2);
    try encoder.writeString("grid_line");
    try encoder.writeArrayHeader(5);
    try encoder.writeUint(primary_grid_id);
    try encoder.writeUint(0);
    try encoder.writeUint(0);
    try encoder.writeArrayHeader(3);
    try encoder.writeArrayHeader(2);
    try encoder.writeString("界");
    try encoder.writeUint(17);
    try encoder.writeArrayHeader(1);
    try encoder.writeString("");
    try encoder.writeArrayHeader(1);
    try encoder.writeString("e\xcc\x81");
    try encoder.writeBool(false);

    try encoder.writeArrayHeader(2);
    try encoder.writeString("flush");
    try encoder.writeArrayHeader(0);

    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    try applyEncoded(&model, encoder.bytes());
    try std.testing.expectEqualStrings("界", model.cell(0, 0).?.text());
    try std.testing.expectEqualStrings("", model.cell(0, 1).?.text());
    try std.testing.expectEqualStrings("e\xcc\x81", model.cell(0, 2).?.text());
    try std.testing.expectEqual(@as(u64, 17), model.cell(0, 2).?.highlight_id);
}

test "redraw state spans batches and missing highlights use safe defaults" {
    var first = rpc.Encoder.init(std.testing.allocator);
    defer first.deinit();
    try first.beginNotification("redraw", 2);
    try first.writeArrayHeader(2);
    try first.writeString("grid_resize");
    try first.writeArrayHeader(3);
    try first.writeUint(primary_grid_id);
    try first.writeUint(3);
    try first.writeUint(1);
    try first.writeArrayHeader(2);
    try first.writeString("grid_line");
    try first.writeArrayHeader(5);
    try first.writeUint(primary_grid_id);
    try first.writeUint(0);
    try first.writeUint(0);
    try first.writeArrayHeader(1);
    try first.writeArrayHeader(2);
    try first.writeString("A");
    try first.writeUint(999);
    try first.writeBool(false);

    var second = rpc.Encoder.init(std.testing.allocator);
    defer second.deinit();
    try second.beginNotification("redraw", 2);
    try second.writeArrayHeader(2);
    try second.writeString("grid_line");
    try second.writeArrayHeader(5);
    try second.writeUint(primary_grid_id);
    try second.writeUint(0);
    try second.writeUint(1);
    try second.writeArrayHeader(1);
    try second.writeArrayHeader(1);
    try second.writeString("B");
    try second.writeBool(false);
    try second.writeArrayHeader(2);
    try second.writeString("flush");
    try second.writeArrayHeader(0);

    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    try applyEncoded(&model, first.bytes());
    try std.testing.expectEqual(@as(u64, 0), model.flush_revision);
    try applyEncoded(&model, second.bytes());
    try std.testing.expectEqualStrings("A", model.cell(0, 0).?.text());
    try std.testing.expectEqualStrings("B", model.cell(0, 1).?.text());
    try std.testing.expectEqual(Highlight{}, model.highlight(999));
    try std.testing.expectEqual(@as(u64, 1), model.flush_revision);
}

test "unknown redraw events are counted without aborting later batches" {
    var encoder = rpc.Encoder.init(std.testing.allocator);
    defer encoder.deinit();
    try encoder.beginNotification("redraw", 3);
    try encoder.writeArrayHeader(2);
    try encoder.writeString("future_event");
    try encoder.writeArrayHeader(2);
    try encoder.writeString("ignored");
    try encoder.writeUint(42);
    try encoder.writeArrayHeader(2);
    try encoder.writeString("mouse_on");
    try encoder.writeArrayHeader(0);
    try encoder.writeArrayHeader(2);
    try encoder.writeString("flush");
    try encoder.writeArrayHeader(0);

    var model = Model.init(std.testing.allocator);
    defer model.deinit();
    try applyEncoded(&model, encoder.bytes());
    try std.testing.expectEqual(@as(u64, 1), model.unknown_event_count);
    try std.testing.expect(model.mouse_enabled);
    try std.testing.expectEqual(@as(u64, 1), model.flush_revision);
}
