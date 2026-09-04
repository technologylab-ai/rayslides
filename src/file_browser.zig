//! Self-drawn modal file chooser shared by every platform.
//!
//! Studio needs to pick decks, images, and videos without relying on native
//! dialogs: a native panel exists only where the host toolkit is linked in,
//! behaves differently over a fullscreen raylib window, and returns absolute
//! paths that still have to be made deck-relative. Drawing the chooser with
//! the same chrome as `studio_prompt.zig` keeps one code path that works the
//! same on Linux, macOS, and Windows.
//!
//! The directory model (listing, filtering, navigation, selection) is separate
//! from raylib input so it can be unit tested against a temporary directory.

const std = @import("std");
const builtin = @import("builtin");
const rl = @import("raylib");
const theme = @import("studio_theme.zig");
const motion = @import("studio_motion.zig");

pub const image_extensions = [_][]const u8{ ".png", ".jpg", ".jpeg", ".bmp", ".gif", ".tga", ".qoi", ".svg" };
pub const video_extensions = [_][]const u8{ ".mp4", ".mov", ".m4v", ".webm", ".mkv", ".avi", ".mpg", ".mpeg" };
pub const deck_extensions = [_][]const u8{".sld"};

pub const max_entries = 4096;
const name_arena_len = 256 * 1024;
const max_path_bytes = std.fs.max_path_bytes;
const max_field_bytes = max_path_bytes;

const row_height: f32 = 26;
const row_font_size: f32 = 16;
const double_click_seconds: f64 = 0.4;

pub const Purpose = enum {
    deck,
    image,
    video,

    pub fn extensions(self: Purpose) []const []const u8 {
        return switch (self) {
            .deck => &deck_extensions,
            .image => &image_extensions,
            .video => &video_extensions,
        };
    }

    fn title(self: Purpose) [:0]const u8 {
        return switch (self) {
            .deck => "Open deck",
            .image => "Choose image",
            .video => "Choose video",
        };
    }

    fn commitLabel(self: Purpose) [:0]const u8 {
        return switch (self) {
            .deck => "OPEN",
            .image, .video => "CHOOSE",
        };
    }
};

pub const Outcome = enum {
    none,
    chosen,
    cancelled,
};

pub const Notice = enum {
    none,
    directory_unreadable,
    too_many_entries,
    path_not_found,
    wrong_kind,
};

const Focus = enum { list, path };

const EntryKind = enum { directory, file };

const Entry = struct {
    name_start: u32,
    name_len: u16,
    kind: EntryKind,
    /// A symlink whose target is missing. Shown dimmed and never activated.
    broken: bool,
};

/// Single-line editable text used for the location field and the type-ahead
/// filter. Codepoint-aware so Backspace never leaves half a UTF-8 sequence.
const TextField = struct {
    buffer: [max_field_bytes + 1]u8 = [_]u8{0} ** (max_field_bytes + 1),
    len: usize = 0,
    cursor: usize = 0,

    fn text(self: *const TextField) []const u8 {
        return self.buffer[0..self.len];
    }

    fn textZ(self: *const TextField) [:0]const u8 {
        return self.buffer[0..self.len :0];
    }

    fn set(self: *TextField, value: []const u8) void {
        const bounded = @min(value.len, max_field_bytes);
        @memcpy(self.buffer[0..bounded], value[0..bounded]);
        self.len = bounded;
        self.buffer[self.len] = 0;
        self.cursor = self.len;
    }

    fn clear(self: *TextField) void {
        self.set("");
    }

    fn insert(self: *TextField, value: []const u8) void {
        if (!std.unicode.utf8ValidateSlice(value)) return;
        if (value.len == 0 or value.len > max_field_bytes - self.len) return;
        std.mem.copyBackwards(
            u8,
            self.buffer[self.cursor + value.len .. self.len + value.len],
            self.buffer[self.cursor..self.len],
        );
        @memcpy(self.buffer[self.cursor .. self.cursor + value.len], value);
        self.len += value.len;
        self.cursor += value.len;
        self.buffer[self.len] = 0;
    }

    fn removePreviousCodepoint(self: *TextField) void {
        if (self.cursor == 0) return;
        const start = previousCodepointBoundary(self.text(), self.cursor);
        self.removeRange(start, self.cursor);
        self.cursor = start;
    }

    fn removeNextCodepoint(self: *TextField) void {
        if (self.cursor >= self.len) return;
        self.removeRange(self.cursor, nextCodepointBoundary(self.text(), self.cursor));
    }

    fn removeRange(self: *TextField, start: usize, end: usize) void {
        std.debug.assert(start <= end and end <= self.len);
        const removed = end - start;
        std.mem.copyForwards(u8, self.buffer[start .. self.len - removed], self.buffer[end..self.len]);
        self.len -= removed;
        self.buffer[self.len] = 0;
    }
};

/// Allocation-free directory chooser. Lives in static storage: the entry
/// arena is sized for large media folders and would not fit a stack frame.
pub const Browser = struct {
    active: bool = false,
    purpose: Purpose = .deck,
    io: std.Io = undefined,
    directory_buffer: [max_path_bytes]u8 = undefined,
    directory_len: usize = 0,
    names: [name_arena_len]u8 = undefined,
    entries: [max_entries]Entry = undefined,
    entry_count: usize = 0,
    /// Indices into `entries` that survive the hidden/type-ahead filters, in
    /// display order.
    visible: [max_entries]u16 = undefined,
    visible_count: usize = 0,
    selected: ?usize = null,
    scroll_row: usize = 0,
    show_hidden: bool = false,
    focus: Focus = .list,
    path_field: TextField = .{},
    filter: TextField = .{},
    notice: Notice = .none,
    chosen_buffer: [max_path_bytes]u8 = undefined,
    chosen_len: usize = 0,
    last_click_time: f64 = -1,
    last_click_row: ?usize = null,
    /// Session memory so a second Browse reopens where the first one ended.
    remembered: [@typeInfo(Purpose).@"enum".fields.len][max_path_bytes]u8 = undefined,
    remembered_len: [@typeInfo(Purpose).@"enum".fields.len]usize = [_]usize{0} ** @typeInfo(Purpose).@"enum".fields.len,

    /// Opens the chooser in the remembered directory for this purpose, else in
    /// `initial_directory`, else in the process working directory. Missing
    /// directories fall back the same way instead of showing an empty list.
    pub fn begin(self: *Browser, io: std.Io, purpose: Purpose, initial_directory: []const u8) void {
        self.io = io;
        self.purpose = purpose;
        self.active = true;
        self.focus = .list;
        self.filter.clear();
        self.notice = .none;
        self.chosen_len = 0;
        self.last_click_row = null;
        self.selected = null;
        self.scroll_row = 0;

        const slot = @intFromEnum(purpose);
        if (self.remembered_len[slot] > 0 and self.navigateTo(self.remembered[slot][0..self.remembered_len[slot]])) return;
        if (initial_directory.len > 0 and self.navigateTo(initial_directory)) return;
        var cwd_buffer: [max_path_bytes]u8 = undefined;
        const cwd_len = std.Io.Dir.cwd().realPathFile(io, ".", &cwd_buffer) catch 0;
        if (cwd_len > 0 and self.navigateTo(cwd_buffer[0..cwd_len])) return;
        if (self.navigateTo(rootDirectory())) return;
        self.directory_len = 0;
        self.entry_count = 0;
        self.visible_count = 0;
        self.notice = .directory_unreadable;
    }

    pub fn cancel(self: *Browser) void {
        self.active = false;
    }

    pub fn directory(self: *const Browser) []const u8 {
        return self.directory_buffer[0..self.directory_len];
    }

    /// Absolute path of the chosen file; valid after `chosen` was returned.
    pub fn chosenPath(self: *const Browser) []const u8 {
        return self.chosen_buffer[0..self.chosen_len];
    }

    /// Canonicalizes `path` (relative paths resolve against the current
    /// directory, `~` against the home directory), lists it, and makes it
    /// current. Returns false and leaves the current listing untouched when
    /// the directory cannot be opened.
    pub fn navigateTo(self: *Browser, path: []const u8) bool {
        var expanded_buffer: [max_path_bytes]u8 = undefined;
        const expanded = self.expandPath(&expanded_buffer, path) orelse return false;
        var dir = std.Io.Dir.openDirAbsolute(self.io, expanded, .{ .iterate = true }) catch return false;
        defer dir.close(self.io);
        var canonical_buffer: [max_path_bytes]u8 = undefined;
        const canonical_len = dir.realPath(self.io, &canonical_buffer) catch return false;
        if (canonical_len == 0) return false;

        self.listDirectory(dir);
        @memcpy(self.directory_buffer[0..canonical_len], canonical_buffer[0..canonical_len]);
        self.directory_len = canonical_len;
        self.path_field.set(self.directory());
        self.filter.clear();
        self.selected = null;
        self.scroll_row = 0;
        self.last_click_row = null;
        self.applyFilters();
        const slot = @intFromEnum(self.purpose);
        @memcpy(self.remembered[slot][0..canonical_len], canonical_buffer[0..canonical_len]);
        self.remembered_len[slot] = canonical_len;
        return true;
    }

    pub fn navigateUp(self: *Browser) bool {
        const parent = std.fs.path.dirname(self.directory()) orelse return false;
        var child_buffer: [max_path_bytes]u8 = undefined;
        const child = std.fs.path.basename(self.directory());
        @memcpy(child_buffer[0..child.len], child);
        if (!self.navigateTo(if (parent.len == 0) rootDirectory() else parent)) return false;
        // Keep the folder we came from under the cursor so Backspace/Up feel
        // like walking the tree instead of dropping to the top of a list.
        self.selectByName(child_buffer[0..child.len]);
        return true;
    }

    pub fn navigateHome(self: *Browser) bool {
        const home = homeDirectory() orelse return false;
        return self.navigateTo(home);
    }

    pub fn toggleHidden(self: *Browser) void {
        self.show_hidden = !self.show_hidden;
        self.rememberSelectionAcrossFilter();
    }

    /// Enters the selected directory or chooses the selected file.
    pub fn activateSelected(self: *Browser) Outcome {
        const row = self.selected orelse return .none;
        return self.activateRow(row);
    }

    fn activateRow(self: *Browser, row: usize) Outcome {
        if (row >= self.visible_count) return .none;
        const entry = self.entries[self.visible[row]];
        if (entry.broken) return .none;
        var name_buffer: [max_path_bytes]u8 = undefined;
        const name = self.entryName(entry);
        @memcpy(name_buffer[0..name.len], name);
        switch (entry.kind) {
            .directory => {
                var joined_buffer: [max_path_bytes]u8 = undefined;
                const joined = joinPath(&joined_buffer, self.directory(), name_buffer[0..name.len]) orelse return .none;
                if (!self.navigateTo(joined)) self.notice = .directory_unreadable;
                return .none;
            },
            .file => {
                if (!self.matchesPurpose(name_buffer[0..name.len])) {
                    self.notice = .wrong_kind;
                    return .none;
                }
                return self.choose(self.directory(), name_buffer[0..name.len]);
            },
        }
    }

    /// Resolves the location field: a directory becomes current, a matching
    /// file is chosen directly, anything else reports a notice.
    pub fn submitPathField(self: *Browser) Outcome {
        const typed = std.mem.trim(u8, self.path_field.text(), " \t");
        if (typed.len == 0) return .none;
        var expanded_buffer: [max_path_bytes]u8 = undefined;
        const expanded = self.expandPath(&expanded_buffer, typed) orelse {
            self.notice = .path_not_found;
            return .none;
        };
        if (self.navigateTo(expanded)) {
            self.focus = .list;
            return .none;
        }
        const stat = std.Io.Dir.cwd().statFile(self.io, expanded, .{}) catch {
            self.notice = .path_not_found;
            return .none;
        };
        if (stat.kind == .directory) {
            self.notice = .directory_unreadable;
            return .none;
        }
        if (!self.matchesPurpose(expanded)) {
            self.notice = .wrong_kind;
            return .none;
        }
        return self.choose(expanded, "");
    }

    pub fn moveSelection(self: *Browser, delta: isize) void {
        if (self.visible_count == 0) {
            self.selected = null;
            return;
        }
        const current: isize = if (self.selected) |row| @intCast(row) else if (delta > 0) -1 else @intCast(self.visible_count);
        const target = std.math.clamp(current + delta, 0, @as(isize, @intCast(self.visible_count - 1)));
        self.selected = @intCast(target);
        self.notice = .none;
    }

    pub fn selectFirst(self: *Browser) void {
        self.selected = if (self.visible_count > 0) 0 else null;
    }

    pub fn selectLast(self: *Browser) void {
        self.selected = if (self.visible_count > 0) self.visible_count - 1 else null;
    }

    /// Type-ahead: narrows the list to names containing the typed text and
    /// keeps the first match selected so Enter always has a target.
    pub fn appendFilter(self: *Browser, value: []const u8) void {
        self.filter.insert(value);
        self.applyFilters();
        self.selectFirst();
        self.scroll_row = 0;
        self.notice = .none;
    }

    pub fn shrinkFilter(self: *Browser) void {
        self.filter.removePreviousCodepoint();
        self.applyFilters();
        self.selectFirst();
        self.scroll_row = 0;
    }

    pub fn clearFilter(self: *Browser) void {
        self.filter.clear();
        self.rememberSelectionAcrossFilter();
    }

    pub fn visibleCount(self: *const Browser) usize {
        return self.visible_count;
    }

    pub fn visibleName(self: *const Browser, row: usize) []const u8 {
        return self.entryName(self.entries[self.visible[row]]);
    }

    pub fn visibleIsDirectory(self: *const Browser, row: usize) bool {
        return self.entries[self.visible[row]].kind == .directory;
    }

    pub fn selectByName(self: *Browser, name: []const u8) void {
        for (0..self.visible_count) |row| {
            if (std.mem.eql(u8, self.visibleName(row), name)) {
                self.selected = row;
                return;
            }
        }
    }

    fn rememberSelectionAcrossFilter(self: *Browser) void {
        var name_buffer: [max_path_bytes]u8 = undefined;
        var name_len: usize = 0;
        if (self.selected) |row| {
            if (row < self.visible_count) {
                const name = self.visibleName(row);
                @memcpy(name_buffer[0..name.len], name);
                name_len = name.len;
            }
        }
        self.applyFilters();
        self.selected = null;
        if (name_len > 0) self.selectByName(name_buffer[0..name_len]);
    }

    fn choose(self: *Browser, directory_path: []const u8, name: []const u8) Outcome {
        const chosen = joinPath(&self.chosen_buffer, directory_path, name) orelse return .none;
        self.chosen_len = chosen.len;
        self.active = false;
        return .chosen;
    }

    fn matchesPurpose(self: *const Browser, name: []const u8) bool {
        const extension = std.fs.path.extension(name);
        for (self.purpose.extensions()) |candidate|
            if (std.ascii.eqlIgnoreCase(extension, candidate)) return true;
        return false;
    }

    fn entryName(self: *const Browser, entry: Entry) []const u8 {
        return self.names[entry.name_start .. entry.name_start + entry.name_len];
    }

    fn expandPath(self: *const Browser, buffer: []u8, path: []const u8) ?[]const u8 {
        if (path.len == 0) return null;
        if (path[0] == '~' and (path.len == 1 or path[1] == '/' or path[1] == std.fs.path.sep)) {
            const home = homeDirectory() orelse return null;
            return joinPath(buffer, home, path[@min(path.len, 2)..]);
        }
        if (std.fs.path.isAbsolute(path)) {
            if (path.len > buffer.len) return null;
            @memcpy(buffer[0..path.len], path);
            return buffer[0..path.len];
        }
        if (self.directory_len == 0) return null;
        return joinPath(buffer, self.directory(), path);
    }

    fn listDirectory(self: *Browser, dir: std.Io.Dir) void {
        self.entry_count = 0;
        var names_len: usize = 0;
        self.notice = .none;
        var iterator = dir.iterate();
        while (true) {
            const entry = iterator.next(self.io) catch {
                self.notice = .directory_unreadable;
                break;
            } orelse break;
            if (entry.name.len == 0 or entry.name.len > std.math.maxInt(u16)) continue;
            if (self.entry_count >= max_entries or names_len + entry.name.len > name_arena_len) {
                self.notice = .too_many_entries;
                break;
            }
            var kind: EntryKind = .file;
            var broken = false;
            switch (entry.kind) {
                .directory => kind = .directory,
                .sym_link => {
                    if (dir.statFile(self.io, entry.name, .{})) |stat| {
                        if (stat.kind == .directory) kind = .directory;
                    } else |_| broken = true;
                },
                else => {},
            }
            @memcpy(self.names[names_len .. names_len + entry.name.len], entry.name);
            self.entries[self.entry_count] = .{
                .name_start = @intCast(names_len),
                .name_len = @intCast(entry.name.len),
                .kind = kind,
                .broken = broken,
            };
            names_len += entry.name.len;
            self.entry_count += 1;
        }
        std.mem.sort(Entry, self.entries[0..self.entry_count], @as([]const u8, self.names[0..names_len]), entryLessThan);
    }

    fn applyFilters(self: *Browser) void {
        self.visible_count = 0;
        const needle = self.filter.text();
        for (self.entries[0..self.entry_count], 0..) |entry, index| {
            const name = self.entryName(entry);
            if (!self.show_hidden and name[0] == '.') continue;
            if (entry.kind == .file and !self.matchesPurpose(name)) continue;
            if (needle.len > 0 and !containsIgnoreCase(name, needle)) continue;
            self.visible[self.visible_count] = @intCast(index);
            self.visible_count += 1;
        }
        if (self.selected) |row| {
            if (row >= self.visible_count) self.selected = if (self.visible_count > 0) self.visible_count - 1 else null;
        }
    }

    pub fn updateFromRaylib(self: *Browser, screen_size: rl.Vector2, ui_font: rl.Font) Outcome {
        if (!self.active) return .none;
        const layout = browserLayout(screen_size);
        const pointer = rl.getMousePosition();
        const modifier = rl.isKeyDown(.left_control) or rl.isKeyDown(.right_control) or
            rl.isKeyDown(.left_super) or rl.isKeyDown(.right_super);
        const alt = rl.isKeyDown(.left_alt) or rl.isKeyDown(.right_alt);
        const shift = rl.isKeyDown(.left_shift) or rl.isKeyDown(.right_shift);
        const open_enabled = self.selectionActivatable();

        rl.setMouseCursor(if (pointInRectangle(pointer, layout.path))
            .ibeam
        else if (pointInRectangle(pointer, layout.cancel) or
            pointInRectangle(pointer, layout.up) or pointInRectangle(pointer, layout.home) or
            pointInRectangle(pointer, layout.hidden) or (open_enabled and pointInRectangle(pointer, layout.commit)) or
            self.rowAtPoint(layout, pointer) != null)
            .pointing_hand
        else
            .arrow);

        if (rl.isMouseButtonPressed(.left)) {
            if (pointInRectangle(pointer, layout.cancel)) {
                self.cancel();
                return .cancelled;
            }
            if (open_enabled and pointInRectangle(pointer, layout.commit)) return self.activateSelected();
            if (pointInRectangle(pointer, layout.up)) {
                _ = self.navigateUp();
                self.focus = .list;
            } else if (pointInRectangle(pointer, layout.home)) {
                _ = self.navigateHome();
                self.focus = .list;
            } else if (pointInRectangle(pointer, layout.hidden)) {
                self.toggleHidden();
            } else if (pointInRectangle(pointer, layout.path)) {
                self.focus = .path;
                self.path_field.cursor = cursorAtFieldPoint(self.path_field.text(), pointer, layout.path, ui_font);
            } else if (self.rowAtPoint(layout, pointer)) |row| {
                self.focus = .list;
                const now = rl.getTime();
                const double = self.last_click_row == row and now - self.last_click_time <= double_click_seconds;
                self.selected = row;
                self.notice = .none;
                self.last_click_row = row;
                self.last_click_time = now;
                if (double) {
                    self.last_click_row = null;
                    const outcome = self.activateRow(row);
                    if (outcome != .none) return outcome;
                }
            } else if (pointInRectangle(pointer, layout.list)) {
                self.focus = .list;
            }
        }

        const wheel = rl.getMouseWheelMoveV();
        if (wheel.y != 0 and pointInRectangle(pointer, layout.list)) {
            const rows_per_notch: f32 = 3;
            const delta: isize = @intFromFloat(@round(-wheel.y * rows_per_notch));
            const max_scroll = self.maxScrollRow(layout);
            const current: isize = @intCast(self.scroll_row);
            self.scroll_row = @intCast(std.math.clamp(current + delta, 0, @as(isize, @intCast(max_scroll))));
        }

        if (rl.isKeyPressed(.escape)) {
            if (self.focus == .path) {
                self.focus = .list;
                self.path_field.set(self.directory());
                return .none;
            }
            if (self.filter.len > 0) {
                self.clearFilter();
                return .none;
            }
            self.cancel();
            return .cancelled;
        }
        if (modifier and rl.isKeyPressed(.l)) {
            self.focus = .path;
            self.path_field.cursor = self.path_field.len;
            return .none;
        }
        if (modifier and rl.isKeyPressed(.h)) {
            self.toggleHidden();
            return .none;
        }
        if ((modifier or alt) and rl.isKeyPressed(.up)) {
            _ = self.navigateUp();
            self.focus = .list;
            self.ensureSelectionVisible(layout);
            return .none;
        }

        switch (self.focus) {
            .path => {
                if (rl.isKeyPressed(.enter) or rl.isKeyPressed(.kp_enter)) {
                    const outcome = self.submitPathField();
                    if (outcome != .none) return outcome;
                }
                if (rl.isKeyPressed(.tab)) {
                    self.focus = .list;
                    self.path_field.set(self.directory());
                }
                if (modifier and rl.isKeyPressed(.v)) self.path_field.insert(rl.getClipboardText());
                if (keyPressedOrRepeated(.backspace)) self.path_field.removePreviousCodepoint();
                if (keyPressedOrRepeated(.delete)) self.path_field.removeNextCodepoint();
                if (keyPressedOrRepeated(.left)) self.path_field.cursor = if (modifier) 0 else previousCodepointBoundary(self.path_field.text(), self.path_field.cursor);
                if (keyPressedOrRepeated(.right)) self.path_field.cursor = if (modifier) self.path_field.len else nextCodepointBoundary(self.path_field.text(), self.path_field.cursor);
                if (keyPressedOrRepeated(.home)) self.path_field.cursor = 0;
                if (keyPressedOrRepeated(.end)) self.path_field.cursor = self.path_field.len;
                self.insertTypedChars(.path);
            },
            .list => {
                if (rl.isKeyPressed(.enter) or rl.isKeyPressed(.kp_enter)) {
                    const outcome = self.activateSelected();
                    if (outcome != .none) return outcome;
                    self.ensureSelectionVisible(layout);
                }
                if (keyPressedOrRepeated(.backspace)) {
                    if (self.filter.len > 0) self.shrinkFilter() else _ = self.navigateUp();
                }
                if (keyPressedOrRepeated(.up)) self.moveSelection(-1);
                if (keyPressedOrRepeated(.down)) self.moveSelection(1);
                const page: isize = @intCast(@max(1, rowsPerPage(layout)));
                if (keyPressedOrRepeated(.page_up)) self.moveSelection(-page);
                if (keyPressedOrRepeated(.page_down)) self.moveSelection(page);
                if (keyPressedOrRepeated(.home) and !shift) self.selectFirst();
                if (keyPressedOrRepeated(.end) and !shift) self.selectLast();
                if (keyPressedOrRepeated(.up) or keyPressedOrRepeated(.down) or
                    keyPressedOrRepeated(.page_up) or keyPressedOrRepeated(.page_down) or
                    keyPressedOrRepeated(.home) or keyPressedOrRepeated(.end))
                    self.ensureSelectionVisible(layout);
                self.insertTypedChars(.list);
            },
        }
        self.clampScroll(layout);
        return .none;
    }

    fn insertTypedChars(self: *Browser, target: Focus) void {
        while (true) {
            const pressed = rl.getCharPressed();
            if (pressed <= 0) break;
            const codepoint = std.math.cast(u21, pressed) orelse continue;
            if (codepoint < 32 or codepoint == 127) continue;
            var encoded: [4]u8 = undefined;
            const encoded_len = std.unicode.utf8Encode(codepoint, &encoded) catch continue;
            const typed = encoded[0..encoded_len];
            switch (target) {
                .path => self.path_field.insert(typed),
                .list => {
                    // A path-looking first keystroke starts location entry
                    // instead of filtering; "/" and "~" never occur in names.
                    if (self.filter.len == 0 and (codepoint == '/' or codepoint == '~')) {
                        self.focus = .path;
                        self.path_field.set(if (codepoint == '~') "~/" else "/");
                        return;
                    }
                    self.appendFilter(typed);
                },
            }
        }
    }

    fn selectionActivatable(self: *const Browser) bool {
        const row = self.selected orelse return false;
        if (row >= self.visible_count) return false;
        return !self.entries[self.visible[row]].broken;
    }

    fn maxScrollRow(self: *const Browser, layout: Layout) usize {
        const rows = rowsPerPage(layout);
        return if (self.visible_count > rows) self.visible_count - rows else 0;
    }

    fn clampScroll(self: *Browser, layout: Layout) void {
        self.scroll_row = @min(self.scroll_row, self.maxScrollRow(layout));
    }

    fn ensureSelectionVisible(self: *Browser, layout: Layout) void {
        const row = self.selected orelse return;
        const rows = rowsPerPage(layout);
        if (row < self.scroll_row) self.scroll_row = row;
        if (row >= self.scroll_row + rows) self.scroll_row = row + 1 - rows;
        self.clampScroll(layout);
    }

    fn rowAtPoint(self: *const Browser, layout: Layout, point: rl.Vector2) ?usize {
        if (!pointInRectangle(point, layout.list)) return null;
        const offset: usize = @intFromFloat(@floor((point.y - layout.list.y) / row_height));
        const row = self.scroll_row + offset;
        if (row >= self.visible_count) return null;
        if (offset >= rowsPerPage(layout)) return null;
        return row;
    }

    pub fn draw(self: *const Browser, screen_size: rl.Vector2, ui_font: rl.Font) void {
        const reveal = motion.reveal(.file_browser);
        reveal.setOpen(self.active);
        if (!reveal.visible()) return;
        const presence = reveal.presence();
        rl.drawRectangle(0, 0, @intFromFloat(screen_size.x), @intFromFloat(screen_size.y), motion.scrimAt(presence));
        const layout = browserLayout(screen_size);
        const panel = layout.panel;
        const fold = motion.wipeFromTop(motion.inflateRect(panel, 6), presence);
        motion.pushClip(fold.clip);
        defer {
            motion.popClip();
            motion.drawFoldEdge(fold, panel.x, panel.width);
        }
        rl.drawRectangleRounded(panel, 0.035, 12, theme.raised);
        rl.drawRectangleRoundedLinesEx(panel, 0.035, 12, 1, theme.border_strong);

        rl.drawTextEx(ui_font, self.purpose.title(), .{ .x = panel.x + 24, .y = panel.y + 20 }, 25, 0, .white);
        rl.drawTextEx(ui_font, self.hint(), .{ .x = panel.x + 24, .y = panel.y + 55 }, 16, 0, theme.text_muted);
        drawButton(ui_font, layout.commit, self.purpose.commitLabel(), self.selectionActivatable(), true);
        drawButton(ui_font, layout.cancel, "Cancel", true, false);

        drawButton(ui_font, layout.up, "Up", self.directory_len > 0, false);
        drawButton(ui_font, layout.home, "Home", homeDirectory() != null, false);
        self.drawPathField(layout, ui_font);
        self.drawList(layout, ui_font);
        drawToggle(ui_font, layout.hidden, "Show hidden", self.show_hidden);

        const footer_y = panel.y + panel.height - 36;
        if (self.noticeMessage()) |message| {
            rl.drawTextEx(ui_font, message, .{ .x = panel.x + 24, .y = footer_y }, 16, 0, theme.warning);
        } else if (self.filter.len > 0) {
            var filter_buffer: [96]u8 = undefined;
            const shown = std.fmt.bufPrintZ(&filter_buffer, "Filter: {s}  ·  Esc clears", .{fitTail(self.filter.text(), 64)}) catch "Filter";
            rl.drawTextEx(ui_font, shown, .{ .x = panel.x + 24, .y = footer_y }, 16, 0, theme.accent_bright);
        } else {
            var count_buffer: [64]u8 = undefined;
            const count = std.fmt.bufPrintZ(&count_buffer, "{d} item{s}", .{ self.visible_count, if (self.visible_count == 1) "" else "s" }) catch "";
            rl.drawTextEx(ui_font, count, .{ .x = panel.x + 24, .y = footer_y }, 16, 0, theme.text_muted);
        }
    }

    fn drawPathField(self: *const Browser, layout: Layout, ui_font: rl.Font) void {
        const field = layout.path;
        const focused = self.focus == .path;
        rl.drawRectangleRec(field, theme.field);
        rl.drawRectangleLinesEx(field, 1, if (focused) theme.accent else theme.border_strong);
        const inner = fieldInner(field);
        motion.pushClip(inner);
        const value = self.path_field.textZ();
        // Keep the caret in view for long paths: the field scrolls so the
        // caret (or the path tail while unfocused) is always visible.
        const caret_x = textWidth(ui_font, value[0..@min(self.path_field.cursor, value.len)]);
        const full_width = textWidth(ui_font, value);
        const anchor = if (focused) caret_x else full_width;
        const scroll_x = @max(0, anchor + 4 - inner.width);
        const origin: rl.Vector2 = .{ .x = inner.x - scroll_x, .y = inner.y + (inner.height - row_font_size) / 2 };
        rl.drawTextEx(ui_font, value, origin, row_font_size, 0, theme.text);
        if (focused) {
            rl.drawRectangleRec(.{ .x = origin.x + caret_x, .y = origin.y, .width = 2, .height = row_font_size + 2 }, theme.accent_bright);
        }
        motion.popClip();
    }

    fn drawList(self: *const Browser, layout: Layout, ui_font: rl.Font) void {
        const list = layout.list;
        rl.drawRectangleRec(list, theme.sunken);
        rl.drawRectangleLinesEx(list, 1, if (self.focus == .list) theme.accent else theme.border);
        motion.pushClip(list);
        defer motion.popClip();

        if (self.visible_count == 0) {
            const empty: [:0]const u8 = if (self.filter.len > 0)
                "Nothing here matches the filter"
            else switch (self.purpose) {
                .deck => "No .sld decks or folders here",
                .image => "No images or folders here",
                .video => "No videos or folders here",
            };
            rl.drawTextEx(ui_font, empty, .{ .x = list.x + 14, .y = list.y + 12 }, row_font_size, 0, theme.text_muted);
            return;
        }

        const rows = rowsPerPage(layout);
        var name_buffer: [std.fs.max_name_bytes + 1]u8 = undefined;
        var slot: usize = 0;
        while (slot < rows) : (slot += 1) {
            const row = self.scroll_row + slot;
            if (row >= self.visible_count) break;
            const entry = self.entries[self.visible[row]];
            const rect: rl.Rectangle = .{
                .x = list.x + 1,
                .y = list.y + 1 + @as(f32, @floatFromInt(slot)) * row_height,
                .width = list.width - 2 - (if (self.visible_count > rows) @as(f32, 8) else 0),
                .height = row_height,
            };
            const selected = self.selected != null and self.selected.? == row;
            const hovered = pointInRectangle(rl.getMousePosition(), rect);
            if (selected) {
                rl.drawRectangleRec(rect, theme.accent_soft);
            } else if (hovered) {
                rl.drawRectangleRec(rect, theme.row);
            }
            drawEntryIcon(.{ .x = rect.x + 12, .y = rect.y + 6 }, entry.kind, entry.broken);
            const name = self.entryName(entry);
            const shown = fitTail(name, name_buffer.len - 1);
            @memcpy(name_buffer[0..shown.len], shown);
            name_buffer[shown.len] = 0;
            const color: rl.Color = if (entry.broken)
                theme.text_disabled
            else if (entry.kind == .directory)
                theme.text
            else
                theme.text_secondary;
            rl.drawTextEx(ui_font, name_buffer[0..shown.len :0], .{ .x = rect.x + 38, .y = rect.y + (row_height - row_font_size) / 2 }, row_font_size, 0, color);
        }

        if (self.visible_count > rows) {
            const track: rl.Rectangle = .{ .x = list.x + list.width - 7, .y = list.y + 2, .width = 4, .height = list.height - 4 };
            const thumb_height = @max(24, track.height * @as(f32, @floatFromInt(rows)) / @as(f32, @floatFromInt(self.visible_count)));
            const travel = track.height - thumb_height;
            const max_scroll = self.maxScrollRow(layout);
            const position = if (max_scroll == 0) 0 else travel * @as(f32, @floatFromInt(self.scroll_row)) / @as(f32, @floatFromInt(max_scroll));
            rl.drawRectangleRec(track, theme.control);
            rl.drawRectangleRec(.{ .x = track.x, .y = track.y + position, .width = track.width, .height = thumb_height }, theme.border_strong);
        }
    }

    fn hint(self: *const Browser) [:0]const u8 {
        return switch (self.purpose) {
            .deck => "Type to filter · Enter opens · Backspace goes up · / or ~ types a path · Esc cancels",
            .image, .video => "Type to filter · Enter chooses · Backspace goes up · / or ~ types a path · Esc cancels",
        };
    }

    pub fn noticeMessage(self: *const Browser) ?[:0]const u8 {
        return switch (self.notice) {
            .none => null,
            .directory_unreadable => "That folder could not be read.",
            .too_many_entries => "This folder is very large; only the first entries are listed. Type to filter or enter a path.",
            .path_not_found => "No file or folder exists at that path.",
            .wrong_kind => switch (self.purpose) {
                .deck => "Choose a .sld deck.",
                .image => "Choose an image file (png, jpg, svg, …).",
                .video => "Choose a video file (mp4, mov, webm, …).",
            },
        };
    }
};

const Layout = struct {
    panel: rl.Rectangle,
    path: rl.Rectangle,
    up: rl.Rectangle,
    home: rl.Rectangle,
    list: rl.Rectangle,
    hidden: rl.Rectangle,
    commit: rl.Rectangle,
    cancel: rl.Rectangle,
};

fn browserLayout(screen_size: rl.Vector2) Layout {
    const width = @min(@as(f32, 980), screen_size.x - 80);
    const height = @min(@as(f32, 640), screen_size.y - 80);
    const panel: rl.Rectangle = .{
        .x = (screen_size.x - width) / 2,
        .y = (screen_size.y - height) / 2,
        .width = width,
        .height = height,
    };
    const toolbar_y = panel.y + 88;
    const button_width: f32 = 64;
    const list_top = toolbar_y + 44;
    return .{
        .panel = panel,
        .up = .{ .x = panel.x + 24, .y = toolbar_y, .width = button_width, .height = 32 },
        .home = .{ .x = panel.x + 24 + button_width + 8, .y = toolbar_y, .width = button_width, .height = 32 },
        .path = .{
            .x = panel.x + 24 + (button_width + 8) * 2,
            .y = toolbar_y,
            .width = @max(0, panel.width - 48 - (button_width + 8) * 2),
            .height = 32,
        },
        .list = .{
            .x = panel.x + 24,
            .y = list_top,
            .width = panel.width - 48,
            .height = @max(0, panel.height - (list_top - panel.y) - 62),
        },
        .hidden = .{ .x = panel.x + panel.width - 24 - 112 - 112 - 8 - 130, .y = panel.y + panel.height - 44, .width = 130, .height = 30 },
        .cancel = .{ .x = panel.x + panel.width - 24 - 112 - 8 - 112, .y = panel.y + panel.height - 44, .width = 112, .height = 30 },
        .commit = .{ .x = panel.x + panel.width - 24 - 112, .y = panel.y + panel.height - 44, .width = 112, .height = 30 },
    };
}

fn rowsPerPage(layout: Layout) usize {
    return @intFromFloat(@max(1, @floor(layout.list.height / row_height)));
}

fn fieldInner(field: rl.Rectangle) rl.Rectangle {
    return .{ .x = field.x + 10, .y = field.y + 2, .width = @max(0, field.width - 20), .height = @max(0, field.height - 4) };
}

fn drawEntryIcon(origin: rl.Vector2, kind: EntryKind, broken: bool) void {
    // Kind is conveyed by shape and weight, not hue: the theme reserves its
    // semantic colours for state and its single accent for selection.
    const color: rl.Color = if (broken) theme.text_disabled else if (kind == .directory) theme.text_secondary else theme.text_muted;
    switch (kind) {
        .directory => {
            rl.drawRectangleRec(.{ .x = origin.x, .y = origin.y + 2, .width = 7, .height = 3 }, color);
            rl.drawRectangleRec(.{ .x = origin.x, .y = origin.y + 4, .width = 16, .height = 10 }, color);
        },
        .file => {
            rl.drawRectangleLinesEx(.{ .x = origin.x + 2, .y = origin.y, .width = 12, .height = 14 }, 1, color);
            rl.drawRectangleRec(.{ .x = origin.x + 5, .y = origin.y + 4, .width = 6, .height = 1 }, color);
            rl.drawRectangleRec(.{ .x = origin.x + 5, .y = origin.y + 7, .width = 6, .height = 1 }, color);
            rl.drawRectangleRec(.{ .x = origin.x + 5, .y = origin.y + 10, .width = 6, .height = 1 }, color);
        },
    }
}

fn drawButton(ui_font: rl.Font, rect: rl.Rectangle, label: [:0]const u8, enabled: bool, emphasized: bool) void {
    const glow = motion.touchAt(rect, emphasized, if (enabled) rl.getMousePosition() else null);
    const colors = motion.controlColors(glow);
    const fill: rl.Color = if (!enabled) theme.control_disabled else colors.fill;
    const border: rl.Color = if (!enabled) theme.border else colors.border;
    rl.drawRectangleRec(rect, fill);
    rl.drawRectangleLinesEx(rect, 1, border);
    if (enabled) motion.drawControlMotion(rect, glow);
    const label_width = rl.measureTextEx(ui_font, label, row_font_size, 0).x;
    rl.drawTextEx(
        ui_font,
        label,
        .{ .x = rect.x + (rect.width - label_width) / 2, .y = rect.y + (rect.height - row_font_size) / 2 },
        row_font_size,
        0,
        if (enabled) theme.text else theme.text_disabled,
    );
}

fn drawToggle(ui_font: rl.Font, rect: rl.Rectangle, label: [:0]const u8, on: bool) void {
    const hovered = pointInRectangle(rl.getMousePosition(), rect);
    rl.drawRectangleRec(rect, if (hovered) theme.control_hover else theme.control);
    rl.drawRectangleLinesEx(rect, 1, theme.border_strong);
    const box: rl.Rectangle = .{ .x = rect.x + 9, .y = rect.y + (rect.height - 14) / 2, .width = 14, .height = 14 };
    rl.drawRectangleRec(box, if (on) theme.accent_fill else theme.field);
    rl.drawRectangleLinesEx(box, 1, if (on) theme.accent else theme.border_strong);
    if (on) rl.drawRectangleRec(.{ .x = box.x + 4, .y = box.y + 4, .width = 6, .height = 6 }, theme.accent_bright);
    rl.drawTextEx(ui_font, label, .{ .x = box.x + box.width + 8, .y = rect.y + (rect.height - row_font_size) / 2 }, row_font_size, 0, theme.text);
}

fn entryLessThan(names: []const u8, a: Entry, b: Entry) bool {
    if (a.kind != b.kind) return a.kind == .directory;
    const name_a = names[a.name_start .. a.name_start + a.name_len];
    const name_b = names[b.name_start .. b.name_start + b.name_len];
    const shared = @min(name_a.len, name_b.len);
    for (name_a[0..shared], name_b[0..shared]) |ca, cb| {
        const la = std.ascii.toLower(ca);
        const lb = std.ascii.toLower(cb);
        if (la != lb) return la < lb;
    }
    if (name_a.len != name_b.len) return name_a.len < name_b.len;
    return std.mem.lessThan(u8, name_a, name_b);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[start .. start + needle.len], needle)) return true;
    }
    return false;
}

fn joinPath(buffer: []u8, directory_path: []const u8, name: []const u8) ?[]const u8 {
    if (name.len == 0) {
        if (directory_path.len > buffer.len) return null;
        @memcpy(buffer[0..directory_path.len], directory_path);
        return buffer[0..directory_path.len];
    }
    const needs_separator = directory_path.len > 0 and !std.fs.path.isSep(directory_path[directory_path.len - 1]);
    return std.fmt.bufPrint(buffer, "{s}{s}{s}", .{
        directory_path,
        if (needs_separator) std.fs.path.sep_str else "",
        name,
    }) catch null;
}

fn rootDirectory() []const u8 {
    return if (builtin.os.tag == .windows) "C:\\" else "/";
}

fn homeDirectory() ?[]const u8 {
    const variable: [*:0]const u8 = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
    const value = std.c.getenv(variable) orelse return null;
    const home = std.mem.span(value);
    return if (home.len == 0) null else home;
}

fn fitTail(value: []const u8, max_len: usize) []const u8 {
    if (value.len <= max_len) return value;
    var start = value.len - max_len;
    while (start < value.len and value[start] & 0xc0 == 0x80) start += 1;
    return value[start..];
}

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

fn glyphAdvance(font: rl.Font, codepoint: u21) f32 {
    if (font.baseSize <= 0 or font.glyphCount <= 0) return row_font_size * 0.56;
    const raw_index = rl.getGlyphIndex(font, codepoint);
    if (raw_index < 0 or raw_index >= font.glyphCount) return row_font_size * 0.56;
    const index: usize = @intCast(raw_index);
    const scale = row_font_size / @as(f32, @floatFromInt(font.baseSize));
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

fn cursorAtFieldPoint(text: []const u8, pointer: rl.Vector2, field: rl.Rectangle, ui_font: rl.Font) usize {
    const inner = fieldInner(field);
    const full_width = textWidth(ui_font, text);
    const scroll_x = @max(0, full_width + 4 - inner.width);
    const content_x = @max(0, pointer.x - inner.x + scroll_x);
    var width: f32 = 0;
    var offset: usize = 0;
    while (offset < text.len) {
        const next = nextCodepointBoundary(text, offset);
        const advance = textWidth(ui_font, text[offset..next]);
        if (content_x < width + advance / 2) return offset;
        width += advance;
        offset = next;
    }
    return text.len;
}

fn pointInRectangle(point: rl.Vector2, rect: rl.Rectangle) bool {
    return point.x >= rect.x and point.x <= rect.x + rect.width and
        point.y >= rect.y and point.y <= rect.y + rect.height;
}

// ---------------------------------------------------------------------------
// Tests: the directory model against a real temporary tree.
// ---------------------------------------------------------------------------

const TestTree = struct {
    tmp: std.testing.TmpDir,
    root_buffer: [max_path_bytes]u8,
    root_len: usize,

    fn root(self: *const TestTree) []const u8 {
        return self.root_buffer[0..self.root_len];
    }

    fn init() !TestTree {
        const io = std.testing.io;
        var tree: TestTree = .{ .tmp = std.testing.tmpDir(.{ .iterate = true }), .root_buffer = undefined, .root_len = 0 };
        tree.root_len = try tree.tmp.dir.realPath(io, &tree.root_buffer);
        try tree.tmp.dir.createDirPath(io, "Talks/archive");
        try tree.tmp.dir.createDirPath(io, "assets");
        try tree.tmp.dir.createDirPath(io, ".git");
        try tree.tmp.dir.writeFile(io, .{ .sub_path = "keynote.sld", .data = "@slide\n" });
        try tree.tmp.dir.writeFile(io, .{ .sub_path = "Talks/Lightning.SLD", .data = "@slide\n" });
        try tree.tmp.dir.writeFile(io, .{ .sub_path = "notes.txt", .data = "x" });
        try tree.tmp.dir.writeFile(io, .{ .sub_path = ".hidden.sld", .data = "@slide\n" });
        try tree.tmp.dir.writeFile(io, .{ .sub_path = "assets/logo.png", .data = "x" });
        try tree.tmp.dir.writeFile(io, .{ .sub_path = "assets/clip.mp4", .data = "x" });
        return tree;
    }

    fn deinit(self: *TestTree) void {
        self.tmp.cleanup();
    }
};

fn testBrowser() *Browser {
    const holder = struct {
        var browser: Browser = .{};
    };
    holder.browser = .{};
    return &holder.browser;
}

fn joinedTestPath(buffer: []u8, root: []const u8, tail: []const u8) []const u8 {
    return joinPath(buffer, root, tail).?;
}

test "deck purpose lists folders first and only .sld files, hiding dotfiles" {
    var tree = try TestTree.init();
    defer tree.deinit();
    const browser = testBrowser();
    browser.begin(std.testing.io, .deck, tree.root());
    try std.testing.expect(browser.active);
    try std.testing.expectEqualStrings(tree.root(), browser.directory());

    try std.testing.expectEqual(@as(usize, 3), browser.visibleCount());
    try std.testing.expectEqualStrings("assets", browser.visibleName(0));
    try std.testing.expectEqualStrings("Talks", browser.visibleName(1));
    try std.testing.expectEqualStrings("keynote.sld", browser.visibleName(2));
    try std.testing.expect(browser.visibleIsDirectory(0));
    try std.testing.expect(!browser.visibleIsDirectory(2));

    browser.toggleHidden();
    try std.testing.expectEqual(@as(usize, 5), browser.visibleCount());
    try std.testing.expectEqualStrings(".git", browser.visibleName(0));
    try std.testing.expectEqualStrings(".hidden.sld", browser.visibleName(3));
}

test "media purposes filter by their own extensions" {
    var tree = try TestTree.init();
    defer tree.deinit();
    var assets_buffer: [max_path_bytes]u8 = undefined;
    const assets = joinedTestPath(&assets_buffer, tree.root(), "assets");

    const browser = testBrowser();
    browser.begin(std.testing.io, .image, assets);
    try std.testing.expectEqual(@as(usize, 1), browser.visibleCount());
    try std.testing.expectEqualStrings("logo.png", browser.visibleName(0));

    browser.begin(std.testing.io, .video, assets);
    try std.testing.expectEqual(@as(usize, 1), browser.visibleCount());
    try std.testing.expectEqualStrings("clip.mp4", browser.visibleName(0));
}

test "Enter descends into folders, chooses matching files, and goes back up" {
    var tree = try TestTree.init();
    defer tree.deinit();
    const browser = testBrowser();
    browser.begin(std.testing.io, .deck, tree.root());

    browser.selectByName("Talks");
    try std.testing.expectEqual(Outcome.none, browser.activateSelected());
    var talks_buffer: [max_path_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(joinedTestPath(&talks_buffer, tree.root(), "Talks"), browser.directory());
    try std.testing.expectEqual(@as(usize, 2), browser.visibleCount());
    try std.testing.expectEqualStrings("archive", browser.visibleName(0));
    try std.testing.expectEqualStrings("Lightning.SLD", browser.visibleName(1));

    try std.testing.expect(browser.navigateUp());
    try std.testing.expectEqualStrings(tree.root(), browser.directory());
    try std.testing.expectEqualStrings("Talks", browser.visibleName(browser.selected.?));

    browser.selectByName("keynote.sld");
    try std.testing.expectEqual(Outcome.chosen, browser.activateSelected());
    try std.testing.expect(!browser.active);
    var chosen_buffer: [max_path_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(joinedTestPath(&chosen_buffer, tree.root(), "keynote.sld"), browser.chosenPath());
}

test "type-ahead narrows the list case-insensitively and Backspace widens it" {
    var tree = try TestTree.init();
    defer tree.deinit();
    const browser = testBrowser();
    browser.begin(std.testing.io, .deck, tree.root());

    browser.appendFilter("TA");
    try std.testing.expectEqual(@as(usize, 1), browser.visibleCount());
    try std.testing.expectEqualStrings("Talks", browser.visibleName(0));
    try std.testing.expectEqual(@as(?usize, 0), browser.selected);

    browser.appendFilter("zz");
    try std.testing.expectEqual(@as(usize, 0), browser.visibleCount());
    try std.testing.expectEqual(@as(?usize, null), browser.selected);
    try std.testing.expectEqual(Outcome.none, browser.activateSelected());

    browser.shrinkFilter();
    browser.shrinkFilter();
    try std.testing.expectEqual(@as(usize, 1), browser.visibleCount());
    browser.clearFilter();
    try std.testing.expectEqual(@as(usize, 3), browser.visibleCount());
    try std.testing.expectEqualStrings("Talks", browser.visibleName(browser.selected.?));
}

test "the location field resolves folders, relative paths, and matching files" {
    var tree = try TestTree.init();
    defer tree.deinit();
    const browser = testBrowser();
    browser.begin(std.testing.io, .deck, tree.root());

    browser.path_field.set("Talks/archive");
    try std.testing.expectEqual(Outcome.none, browser.submitPathField());
    var archive_buffer: [max_path_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(joinedTestPath(&archive_buffer, tree.root(), "Talks/archive"), browser.directory());
    try std.testing.expectEqual(Focus.list, browser.focus);

    browser.path_field.set("../..");
    try std.testing.expectEqual(Outcome.none, browser.submitPathField());
    try std.testing.expectEqualStrings(tree.root(), browser.directory());

    browser.path_field.set("nowhere/at/all");
    try std.testing.expectEqual(Outcome.none, browser.submitPathField());
    try std.testing.expectEqual(Notice.path_not_found, browser.notice);

    browser.path_field.set("notes.txt");
    try std.testing.expectEqual(Outcome.none, browser.submitPathField());
    try std.testing.expectEqual(Notice.wrong_kind, browser.notice);
    try std.testing.expect(browser.active);

    browser.path_field.set("Talks/Lightning.SLD");
    try std.testing.expectEqual(Outcome.chosen, browser.submitPathField());
    var chosen_buffer: [max_path_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(joinedTestPath(&chosen_buffer, tree.root(), "Talks/Lightning.SLD"), browser.chosenPath());
}

test "reopening for the same purpose returns to the last folder, other purposes do not" {
    var tree = try TestTree.init();
    defer tree.deinit();
    var assets_buffer: [max_path_bytes]u8 = undefined;
    const assets = joinedTestPath(&assets_buffer, tree.root(), "assets");
    const browser = testBrowser();

    browser.begin(std.testing.io, .deck, tree.root());
    browser.selectByName("Talks");
    _ = browser.activateSelected();
    browser.cancel();

    browser.begin(std.testing.io, .deck, tree.root());
    var talks_buffer: [max_path_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(joinedTestPath(&talks_buffer, tree.root(), "Talks"), browser.directory());

    browser.begin(std.testing.io, .image, assets);
    try std.testing.expectEqualStrings(assets, browser.directory());
}

test "an unreadable start directory falls back instead of leaving an empty chooser" {
    var tree = try TestTree.init();
    defer tree.deinit();
    const browser = testBrowser();
    var missing_buffer: [max_path_bytes]u8 = undefined;
    const missing = joinedTestPath(&missing_buffer, tree.root(), "does-not-exist");
    browser.begin(std.testing.io, .deck, missing);
    try std.testing.expect(browser.active);
    try std.testing.expect(browser.directory_len > 0);
    try std.testing.expect(!std.mem.eql(u8, browser.directory(), missing));
}

test "selection movement clamps and page keys stay in range" {
    var tree = try TestTree.init();
    defer tree.deinit();
    const browser = testBrowser();
    browser.begin(std.testing.io, .deck, tree.root());
    try std.testing.expectEqual(@as(?usize, null), browser.selected);
    browser.moveSelection(1);
    try std.testing.expectEqual(@as(?usize, 0), browser.selected);
    browser.moveSelection(50);
    try std.testing.expectEqual(@as(?usize, 2), browser.selected);
    browser.moveSelection(-50);
    try std.testing.expectEqual(@as(?usize, 0), browser.selected);
    browser.selectLast();
    try std.testing.expectEqual(@as(?usize, 2), browser.selected);
}

test "entry ordering is folders first then case-insensitive names" {
    var names: [64]u8 = undefined;
    const spec = "bravo" ++ "Alpha" ++ "charlie" ++ "alpha";
    @memcpy(names[0..spec.len], spec);
    var entries = [_]Entry{
        .{ .name_start = 0, .name_len = 5, .kind = .file, .broken = false },
        .{ .name_start = 5, .name_len = 5, .kind = .file, .broken = false },
        .{ .name_start = 10, .name_len = 7, .kind = .directory, .broken = false },
        .{ .name_start = 17, .name_len = 5, .kind = .file, .broken = false },
    };
    std.mem.sort(Entry, &entries, @as([]const u8, names[0..spec.len]), entryLessThan);
    try std.testing.expectEqual(EntryKind.directory, entries[0].kind);
    try std.testing.expectEqual(@as(u32, 5), entries[1].name_start);
    try std.testing.expectEqual(@as(u32, 17), entries[2].name_start);
    try std.testing.expectEqual(@as(u32, 0), entries[3].name_start);
}

test "joinPath never doubles separators and fitTail respects UTF-8" {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("/a/b", joinPath(&buffer, "/a", "b").?);
    try std.testing.expectEqualStrings("/b", joinPath(&buffer, "/", "b").?);
    try std.testing.expectEqualStrings("/a", joinPath(&buffer, "/a", "").?);
    try std.testing.expectEqualStrings("€b", fitTail("a€b", 4));
    try std.testing.expectEqualStrings("b", fitTail("a€b", 3));
}
