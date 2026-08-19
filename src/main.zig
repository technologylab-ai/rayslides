const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const rl = @import("raylib");
const rg = @import("raygui");
const c = @cImport({
    @cInclude("pdfgen.h");
});

const fonts = @import("fonts.zig");
const parser = @import("parser.zig");
const renderer = @import("renderer.zig");
const slides = @import("slides.zig");
const animation = @import("animation.zig");
const playback = @import("playback.zig");
const crowdplay = @import("crowdplay.zig");
const presenter = @import("presenter.zig");
const qrcode = @import("qrcode.zig");
const source_editor = @import("source_editor.zig");
const studio = @import("studio.zig");
const studio_catalog = @import("studio_catalog.zig");
const studio_new_deck = @import("studio_new_deck.zig");
const studio_prompt = @import("studio_prompt.zig");
const studio_roundtrip_test = @import("studio_roundtrip_test.zig");
const SlideShow = slides.SlideShow;
const studio_ui_font_data = @embedFile("assets/Calibri Regular.ttf");
const presenter_ui_font_data = @embedFile("assets/Calibri Light.ttf");
const pristine_untitled_source = "@slide\n";
const cli_help =
    \\Rayslides {s}
    \\Usage: rayslides [options] [deck.sld]
    \\
    \\Open a source-native presentation from a terminal, or start Studio with
    \\no deck and choose a starter. Existing command-line workflows remain the
    \\same on macOS, Linux, and Windows.
    \\
    \\Core options:
    \\  --studio                         Start with Studio authoring open
    \\  --no-startup-banner              Skip the four-second presentation banner
    \\  --no-crowd                       Disable the Crowdplay server
    \\  --crowd-host=HOST                Bind Crowdplay to HOST
    \\  --crowd-port=PORT                Bind Crowdplay to PORT (default 7331)
    \\  --presenter-host=HOST            Address advertised by Presenter Companion
    \\  --presenter-port=PORT            Bind Presenter Companion to PORT (default 7332)
    \\  -h, --help                       Show this help and exit
    \\  -v, --version                    Show the version and exit
    \\
    \\Diagnostics and visual QA:
    \\  --diagnostics                    Show the diagnostics HUD
    \\  --diagnostics-command-palette    Open Studio with Commands visible
    \\  --diagnostics-command-tooltip    Show deterministic command hover help
    \\  --diagnostics-precision-view     Show rulers, guides, and precision tools
    \\  --diagnostics-presenter-pairing  Show the Presenter pairing overlay
    \\  --diagnostics-large-deck=N       Generate an N-slide stress deck (1-200)
    \\  --diagnostics-incremental-edit=N Edit slide N after the initial render
    \\  --diagnostics-window=WIDTHxHEIGHT
    \\  --diagnostics-select=ID
    \\  --diagnostics-find-slide=QUERY
    \\  --diagnostics-capture=PNG
    \\  --diagnostics-report=JSON
    \\  --diagnostics-capture-scenario=NAME
    \\  --diagnostics-capture-gate=PATH
    \\  --diagnostics-capture-settle=N
    \\  --diagnostics-exit-after-capture
    \\  --diagnostics-hide-hud
    \\
    \\A positional deck path may appear before or after options. Use `--` before
    \\a deck whose filename begins with a hyphen.
    \\
;

const MacOpenDocuments = struct {
    extern fn rayslides_macos_install_open_document_handler() void;
    extern fn rayslides_macos_take_open_document(buffer: [*]u8, capacity: usize) usize;

    fn install() void {
        if (comptime builtin.os.tag == .macos) rayslides_macos_install_open_document_handler();
    }

    fn take(buffer: []u8) usize {
        if (comptime builtin.os.tag == .macos) {
            return rayslides_macos_take_open_document(buffer.ptr, buffer.len);
        }
        return 0;
    }
};

fn isMacosAppExecutable(path: []const u8) bool {
    return std.mem.indexOf(u8, path, ".app/Contents/MacOS/") != null;
}

test "macOS app detection does not change ordinary command-line binaries" {
    try std.testing.expect(isMacosAppExecutable("/Applications/Rayslides.app/Contents/MacOS/rayslides"));
    try std.testing.expect(!isMacosAppExecutable("/usr/local/bin/rayslides"));
    try std.testing.expect(!isMacosAppExecutable("zig-out/bin/rayslides"));
}

test "build version and CLI help stay available without opening a window" {
    try std.testing.expect(build_options.version.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, cli_help, "Usage: rayslides") != null);
    try std.testing.expect(std.mem.indexOf(u8, cli_help, "deck.sld") != null);
}

comptime {
    if (studio.max_selection_items > renderer.max_item_geometry_previews)
        @compileError("Studio selection capacity exceeds renderer preview capacity");
}

const log = std.log.scoped(.main);

test {
    std.testing.refAllDecls(parser);
    std.testing.refAllDecls(presenter);
    std.testing.refAllDecls(renderer);
    std.testing.refAllDecls(slides);
    std.testing.refAllDecls(source_editor);
    std.testing.refAllDecls(studio);
    std.testing.refAllDecls(studio_catalog);
    std.testing.refAllDecls(studio_new_deck);
    std.testing.refAllDecls(studio_prompt);
    std.testing.refAllDecls(studio_roundtrip_test);
}

const CrowdOptions = struct {
    enabled: bool = true,
    host: []const u8 = "localhost",
    host_explicit: bool = false,
    port: u16 = 7331,
};

const PresenterOptions = struct {
    host: []const u8 = "localhost",
    host_explicit: bool = false,
    port: u16 = presenter.default_port,
};

const WindowDimensions = struct {
    width: i32,
    height: i32,
};

/// Studio benefits from more room than the presentation-only window, but a
/// literal 1920x1080 client area does not fit on a 1080p desktop once window
/// chrome and the OS shelf are considered. Start from 1600x900 and preserve
/// 16:9 while clamping to a conservative fraction of the active monitor.
fn studioStartupWindowSize(monitor_width: i32, monitor_height: i32) WindowDimensions {
    if (monitor_width <= 0 or monitor_height <= 0) return .{ .width = 1280, .height = 720 };
    const max_width = @max(@as(i32, 1), @divFloor(monitor_width * 9, 10));
    const max_height = @max(@as(i32, 1), @divFloor(monitor_height * 5, 6));
    var width: i32 = @min(1600, max_width);
    var height: i32 = @divFloor(width * 9, 16);
    if (height > @min(@as(i32, 900), max_height)) {
        height = @min(@as(i32, 900), max_height);
        width = @divFloor(height * 16, 9);
    }
    return .{ .width = width, .height = height };
}

fn parseDiagnosticWindowSize(value: []const u8) ?WindowDimensions {
    const separator = std.mem.indexOfScalar(u8, value, 'x') orelse return null;
    const width = std.fmt.parseInt(i32, value[0..separator], 10) catch return null;
    const height = std.fmt.parseInt(i32, value[separator + 1 ..], 10) catch return null;
    if (width < 900 or height < 506 or width > 7680 or height > 4320) return null;
    return .{ .width = width, .height = height };
}

test "Studio startup window fits common monitor sizes" {
    try std.testing.expectEqual(WindowDimensions{ .width = 1600, .height = 900 }, studioStartupWindowSize(1920, 1080));
    try std.testing.expectEqual(WindowDimensions{ .width = 1296, .height = 729 }, studioStartupWindowSize(1440, 900));
    try std.testing.expectEqual(WindowDimensions{ .width = 1137, .height = 640 }, studioStartupWindowSize(1366, 768));
    try std.testing.expectEqual(WindowDimensions{ .width = 1280, .height = 720 }, studioStartupWindowSize(0, 0));
}

test "diagnostic window size is explicit and safely bounded" {
    try std.testing.expectEqual(WindowDimensions{ .width = 900, .height = 600 }, parseDiagnosticWindowSize("900x600").?);
    try std.testing.expectEqual(WindowDimensions{ .width = 1920, .height = 1080 }, parseDiagnosticWindowSize("1920x1080").?);
    try std.testing.expect(parseDiagnosticWindowSize("899x600") == null);
    try std.testing.expect(parseDiagnosticWindowSize("900x500") == null);
    try std.testing.expect(parseDiagnosticWindowSize("wide") == null);
}

const SourceChange = struct {
    before: []u8,
    after: []u8,
    before_slide: i32,
    after_slide: i32,
    before_morph_scene: ?studio.MorphSceneCommand = null,
    after_morph_scene: ?studio.MorphSceneCommand = null,
};

const SourceRestore = struct {
    source: []const u8,
    slide: i32,
    morph_scene: ?studio.MorphSceneCommand = null,
};

const HistoryDirection = enum { undo, redo };

const StudioHistory = struct {
    allocator: std.mem.Allocator,
    undo_stack: std.ArrayList(SourceChange) = .empty,
    redo_stack: std.ArrayList(SourceChange) = .empty,

    const max_entries = 64;

    fn init(allocator: std.mem.Allocator) StudioHistory {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *StudioHistory) void {
        self.clearStack(&self.undo_stack);
        self.clearStack(&self.redo_stack);
        self.undo_stack.deinit(self.allocator);
        self.redo_stack.deinit(self.allocator);
    }

    fn clear(self: *StudioHistory) void {
        self.clearStack(&self.undo_stack);
        self.clearStack(&self.redo_stack);
    }

    fn clearStack(self: *StudioHistory, stack: *std.ArrayList(SourceChange)) void {
        for (stack.items) |entry| {
            self.allocator.free(entry.before);
            self.allocator.free(entry.after);
        }
        stack.clearRetainingCapacity();
    }

    /// Takes ownership of both source snapshots.
    fn record(self: *StudioHistory, before: []u8, after: []u8, before_slide: i32, after_slide: i32) !void {
        try self.reserveRecord();
        self.recordAssumeCapacity(before, after, before_slide, after_slide);
    }

    /// Preflight the only allocation a history record can require. Source
    /// transactions call this before replacing/reparsing the live document so
    /// committing history afterward is infallible.
    fn reserveRecord(self: *StudioHistory) !void {
        if (self.undo_stack.items.len < max_entries) {
            try self.undo_stack.ensureUnusedCapacity(self.allocator, 1);
        }
    }

    fn recordAssumeCapacity(self: *StudioHistory, before: []u8, after: []u8, before_slide: i32, after_slide: i32) void {
        self.clearStack(&self.redo_stack);
        if (self.undo_stack.items.len == max_entries) {
            const oldest = self.undo_stack.orderedRemove(0);
            self.allocator.free(oldest.before);
            self.allocator.free(oldest.after);
        }
        self.undo_stack.appendAssumeCapacity(.{
            .before = before,
            .after = after,
            .before_slide = before_slide,
            .after_slide = after_slide,
        });
    }

    fn setLatestAfterSlide(self: *StudioHistory, slide: usize) void {
        if (self.undo_stack.items.len == 0) return;
        self.undo_stack.items[self.undo_stack.items.len - 1].after_slide = @intCast(slide);
    }

    fn setLatestMorphScenes(
        self: *StudioHistory,
        before: ?usize,
        after: ?usize,
    ) void {
        if (self.undo_stack.items.len == 0) return;
        const latest = &self.undo_stack.items[self.undo_stack.items.len - 1];
        latest.before_morph_scene = .{ .active_state = before };
        latest.after_morph_scene = .{ .active_state = after };
    }

    /// Reserve the destination stack and expose a borrowed restore snapshot
    /// without moving the history cursor. The caller reparses this snapshot
    /// first, then commits the infallible stack move only after success.
    fn prepareRestore(self: *StudioHistory, direction: HistoryDirection) !?SourceRestore {
        const source_stack = if (direction == .undo) &self.undo_stack else &self.redo_stack;
        const destination_stack = if (direction == .undo) &self.redo_stack else &self.undo_stack;
        if (source_stack.items.len == 0) return null;
        try destination_stack.ensureUnusedCapacity(self.allocator, 1);
        const entry = source_stack.items[source_stack.items.len - 1];
        return if (direction == .undo)
            .{
                .source = entry.before,
                .slide = entry.before_slide,
                .morph_scene = entry.before_morph_scene,
            }
        else
            .{
                .source = entry.after,
                .slide = entry.after_slide,
                .morph_scene = entry.after_morph_scene,
            };
    }

    fn commitRestore(self: *StudioHistory, direction: HistoryDirection) void {
        const source_stack = if (direction == .undo) &self.undo_stack else &self.redo_stack;
        const destination_stack = if (direction == .undo) &self.redo_stack else &self.undo_stack;
        const entry = source_stack.pop() orelse return;
        destination_stack.appendAssumeCapacity(entry);
    }
};

const StudioClipboardItem = struct {
    snippet: []u8,
    /// Exact `@push` definition used by a captured literal `@pop`. Keeping
    /// this proof with the owned snippet prevents a paste from silently
    /// rebinding to a shadowing component definition.
    component_definition_offset: ?usize = null,
    position: rl.Vector2,
};

/// Internal authoring clipboard. Source snippets are captured eagerly so a
/// later reparse cannot invalidate their offsets, and every paste still goes
/// through the source editor's validation before entering the document.
const StudioClipboard = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(StudioClipboardItem) = .empty,
    paste_generation: usize = 0,

    fn init(allocator: std.mem.Allocator) StudioClipboard {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *StudioClipboard) void {
        self.clear();
        self.items.deinit(self.allocator);
    }

    fn clear(self: *StudioClipboard) void {
        for (self.items.items) |item| self.allocator.free(item.snippet);
        self.items.clearRetainingCapacity();
        self.paste_generation = 0;
    }
};

const StudioSelectionIds = struct {
    allocator: std.mem.Allocator,
    values: std.ArrayList([]u8) = .empty,

    fn init(allocator: std.mem.Allocator) StudioSelectionIds {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *StudioSelectionIds) void {
        self.clear();
        self.values.deinit(self.allocator);
    }

    fn clear(self: *StudioSelectionIds) void {
        for (self.values.items) |value| self.allocator.free(value);
        self.values.clearRetainingCapacity();
    }

    fn appendCopy(self: *StudioSelectionIds, value: []const u8) !void {
        if (self.values.items.len >= studio.max_selection_items) return error.SelectionCapacityReached;
        const owned = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned);
        try self.values.append(self.allocator, owned);
    }

    fn appendNextUnique(self: *StudioSelectionIds) !void {
        var serial = G.source_len + self.values.items.len + 1;
        var buffer: [96]u8 = undefined;
        while (true) : (serial += 1) {
            const candidate = try std.fmt.bufPrint(&buffer, "studio_{d}", .{serial});
            var needle_buffer: [112]u8 = undefined;
            const needle = try std.fmt.bufPrint(&needle_buffer, "id={s}", .{candidate});
            if (std.mem.indexOf(u8, G.editor_memory[0..G.source_len], needle) != null) continue;
            var duplicate = false;
            for (self.values.items) |existing| {
                if (std.mem.eql(u8, existing, candidate)) {
                    duplicate = true;
                    break;
                }
            }
            if (duplicate) continue;
            return self.appendCopy(candidate);
        }
    }
};

test "Studio history restores structural edit slide positions" {
    const allocator = std.testing.allocator;
    var history = StudioHistory.init(allocator);
    defer history.deinit();
    const before = try allocator.dupe(u8, "@slide\n@slide\n");
    errdefer allocator.free(before);
    const after = try allocator.dupe(u8, "@slide\n@slide\n@slide\n");
    errdefer allocator.free(after);
    try history.record(before, after, 0, 0);
    history.setLatestAfterSlide(1);
    history.setLatestMorphScenes(0, 1);

    const undo = (try history.prepareRestore(.undo)).?;
    try std.testing.expectEqual(@as(i32, 0), undo.slide);
    try std.testing.expectEqualStrings("@slide\n@slide\n", undo.source);
    try std.testing.expectEqual(@as(?usize, 0), undo.morph_scene.?.active_state);
    try std.testing.expectEqual(@as(usize, 1), history.undo_stack.items.len);
    try std.testing.expectEqual(@as(usize, 0), history.redo_stack.items.len);
    history.commitRestore(.undo);

    const redo = (try history.prepareRestore(.redo)).?;
    try std.testing.expectEqual(@as(i32, 1), redo.slide);
    try std.testing.expectEqualStrings("@slide\n@slide\n@slide\n", redo.source);
    try std.testing.expectEqual(@as(?usize, 1), redo.morph_scene.?.active_state);
    try std.testing.expectEqual(@as(usize, 0), history.undo_stack.items.len);
    try std.testing.expectEqual(@as(usize, 1), history.redo_stack.items.len);
    history.commitRestore(.redo);
    try std.testing.expectEqual(@as(usize, 1), history.undo_stack.items.len);
    try std.testing.expectEqual(@as(usize, 0), history.redo_stack.items.len);
}

test "Studio structural history reparses duplicated slides in both directions" {
    const allocator = std.testing.allocator;
    const source =
        "@slide\n" ++
        "@box id=hero x=20 y=30 text=Hero\n" ++
        "@state(morph) name=detail\n" ++
        "@set hero x=120\n" ++
        "@slide\n" ++
        "@box id=tail x=40 y=50 text=Tail\n";
    var initial_arena = std.heap.ArenaAllocator.init(allocator);
    defer initial_arena.deinit();
    const initial_deck = try slides.SlideShow.new(initial_arena.allocator());
    const initial_context = try parser.constructSlidesFromBuf(source, initial_deck, initial_arena.allocator());
    defer initial_context.deinit();
    try std.testing.expectEqual(@as(usize, 0), initial_context.parser_errors.items.len);
    try std.testing.expectEqual(@as(usize, 2), initial_deck.slides.items.len);

    const patch = try source_editor.duplicateSlide(
        allocator,
        source,
        initial_deck.slides.items[0].pos_in_editor,
    );
    var history = StudioHistory.init(allocator);
    defer history.deinit();
    const before = try allocator.dupe(u8, source);
    errdefer allocator.free(before);
    errdefer patch.deinit(allocator);
    try history.record(before, patch.source, 0, 1);
    history.setLatestMorphScenes(0, 0);

    const undo = (try history.prepareRestore(.undo)).?;
    var undo_arena = std.heap.ArenaAllocator.init(allocator);
    defer undo_arena.deinit();
    const undo_deck = try slides.SlideShow.new(undo_arena.allocator());
    const undo_context = try parser.constructSlidesFromBuf(undo.source, undo_deck, undo_arena.allocator());
    defer undo_context.deinit();
    try std.testing.expectEqual(@as(usize, 0), undo_context.parser_errors.items.len);
    try std.testing.expectEqual(@as(usize, 2), undo_deck.slides.items.len);
    try std.testing.expectEqual(@as(i32, 0), undo.slide);
    try std.testing.expectEqual(@as(?usize, 0), undo.morph_scene.?.active_state);
    history.commitRestore(.undo);

    const redo = (try history.prepareRestore(.redo)).?;
    var redo_arena = std.heap.ArenaAllocator.init(allocator);
    defer redo_arena.deinit();
    const redo_deck = try slides.SlideShow.new(redo_arena.allocator());
    const redo_context = try parser.constructSlidesFromBuf(redo.source, redo_deck, redo_arena.allocator());
    defer redo_context.deinit();
    try std.testing.expectEqual(@as(usize, 0), redo_context.parser_errors.items.len);
    try std.testing.expectEqual(@as(usize, 3), redo_deck.slides.items.len);
    try std.testing.expectEqual(@as(i32, 1), redo.slide);
    try std.testing.expectEqual(@as(?usize, 0), redo.morph_scene.?.active_state);
    try std.testing.expectEqualStrings(
        redo_deck.slides.items[0].items.?.items[0].id.?,
        redo_deck.slides.items[1].items.?.items[0].id.?,
    );
    history.commitRestore(.redo);
}

test "Studio history allocation failure preserves redo ownership" {
    const backing_allocator = std.testing.allocator;
    var failing = std.testing.FailingAllocator.init(backing_allocator, .{});
    const allocator = failing.allocator();
    var history = StudioHistory.init(allocator);
    defer history.deinit();

    const first_before = try allocator.dupe(u8, "before one");
    const first_after = try allocator.dupe(u8, "after one");
    try history.record(first_before, first_after, 0, 0);
    _ = (try history.prepareRestore(.undo)).?;
    history.commitRestore(.undo);
    try std.testing.expectEqual(@as(usize, 1), history.redo_stack.items.len);

    // Force the next record to need fresh undo capacity while redo owns the
    // previous transaction. The failed reserve must not clear that redo entry.
    history.undo_stack.deinit(allocator);
    history.undo_stack = .empty;
    const second_before = try allocator.dupe(u8, "before two");
    defer allocator.free(second_before);
    const second_after = try allocator.dupe(u8, "after two");
    defer allocator.free(second_after);
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, history.record(second_before, second_after, 0, 0));
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 0), history.undo_stack.items.len);
    try std.testing.expectEqual(@as(usize, 1), history.redo_stack.items.len);
    try std.testing.expectEqualStrings("before one", history.redo_stack.items[0].before);
    try std.testing.expectEqualStrings("after one", history.redo_stack.items[0].after);
}

test "Studio history restore allocation failure leaves its cursor fixed" {
    const backing_allocator = std.testing.allocator;
    var failing = std.testing.FailingAllocator.init(backing_allocator, .{});
    const allocator = failing.allocator();
    var history = StudioHistory.init(allocator);
    defer history.deinit();

    const before = try allocator.dupe(u8, "before");
    const after = try allocator.dupe(u8, "after");
    try history.record(before, after, 0, 1);
    history.redo_stack.deinit(allocator);
    history.redo_stack = .empty;
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, history.prepareRestore(.undo));
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 1), history.undo_stack.items.len);
    try std.testing.expectEqual(@as(usize, 0), history.redo_stack.items.len);
    try std.testing.expectEqualStrings("before", history.undo_stack.items[0].before);
    try std.testing.expectEqualStrings("after", history.undo_stack.items[0].after);
}

fn defaultCrowdHost(buffer: *[256]u8) []const u8 {
    if (comptime builtin.os.tag == .windows) return "localhost";
    var hostname_buffer: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const hostname = std.posix.gethostname(&hostname_buffer) catch return "localhost";
    if (std.mem.endsWith(u8, hostname, ".local") or std.mem.findScalar(u8, hostname, '.') != null) {
        return std.fmt.bufPrint(buffer, "{s}", .{hostname}) catch "localhost";
    }
    return std.fmt.bufPrint(buffer, "{s}.local", .{hostname}) catch "localhost";
}

fn slideshowHasCrowd(slideshow: *const SlideShow) bool {
    for (slideshow.slides.items) |slide| {
        if (slide.items) |items| for (items.items) |item| if (item.crowd != null) return true;
    }
    return false;
}

fn crowdSpecForSlide(slideshow: *const SlideShow, slide_number: i32) ?slides.CrowdSpec {
    if (slide_number < 0 or slide_number >= slideshow.slides.items.len) return null;
    const slide = slideshow.slides.items[@intCast(slide_number)];
    if (slide.items) |items| for (items.items) |item| if (item.crowd) |spec| return spec;
    return null;
}

fn ensurePresenterCompanionRunning(runtime: *presenter.Runtime, options: PresenterOptions) bool {
    if (runtime.isRunning()) return true;
    if (comptime builtin.os.tag == .windows) {
        if (!options.host_explicit) {
            log.err("Presenter Companion on Windows requires --presenter-host=<LAN-IP>", .{});
            return false;
        }
    }
    const port = runtime.start(options.port, options.host) catch |err| {
        log.err("Presenter Companion could not start: {any}", .{err});
        return false;
    };
    // Never log pairing_url: its fragment is the private presenter capability.
    log.info("Presenter Companion listening on port {d}; setup address: {s}", .{ port, runtime.base_url.slice() });
    return true;
}

fn notesForSlide(slideshow: *const SlideShow, slide_number: i32) []const u8 {
    if (slide_number < 0 or slide_number >= slideshow.slides.items.len) return "";
    return slideshow.slides.items[@intCast(slide_number)].speaker_notes orelse "";
}

fn publishPresenterState(
    runtime: *presenter.Runtime,
    controls_enabled: bool,
    pointer_enabled: bool,
    drawing_enabled: bool,
) void {
    if (!runtime.isRunning()) return;
    const slide_count = G.slideshow.slides.items.len;
    const valid_slide = G.current_slide >= 0 and G.current_slide < slide_count;
    const current_slide: usize = if (valid_slide) @intCast(G.current_slide) else 0;
    const step_count = if (valid_slide) G.slide_renderer.stepCount(G.current_slide) else 0;
    const has_previous = valid_slide and (G.playback.visible_step > 0 or G.current_slide > 0);
    const has_next = valid_slide and
        (G.playback.visible_step < step_count or current_slide + 1 < slide_count);
    const reversing = G.playback.active_step != null and G.playback.active_reverse;
    const advancing = G.playback.active_step != null and !G.playback.active_reverse;
    _ = runtime.publish(.{
        .current_slide = @intCast(@min(current_slide, std.math.maxInt(u32))),
        .slide_count = @intCast(@min(slide_count, std.math.maxInt(u32))),
        .visible_step = @intCast(@min(G.playback.visible_step, std.math.maxInt(u32))),
        .step_count = @intCast(@min(step_count, std.math.maxInt(u32))),
        .notes = notesForSlide(G.slideshow, G.current_slide),
        .next_notes = notesForSlide(G.slideshow, G.current_slide + 1),
        .can_previous = controls_enabled and has_previous and !reversing,
        .can_next = controls_enabled and has_next and !advancing,
        .pointer_enabled = pointer_enabled,
        .drawing_enabled = drawing_enabled,
    }) catch |err| log.err("Presenter state update failed: {any}", .{err});
}

fn presenterOverlayScale(screen_width: i32, screen_height: i32) f32 {
    const width_scale = @as(f32, @floatFromInt(@max(screen_width, 1))) / 1280.0;
    const height_scale = @as(f32, @floatFromInt(@max(screen_height, 1))) / 720.0;
    return std.math.clamp(@min(width_scale, height_scale), 1.0, 3.0);
}

fn presenterOverlayPx(base: i32, scale: f32) i32 {
    return @intFromFloat(@round(@as(f32, @floatFromInt(base)) * scale));
}

fn drawCenteredPresenterText(
    font: rl.Font,
    text: [:0]const u8,
    y: i32,
    font_size: f32,
    color: rl.Color,
    width: i32,
) void {
    const measured = rl.measureTextEx(font, text, font_size, 0);
    rl.drawTextEx(
        font,
        text,
        .{
            .x = (@as(f32, @floatFromInt(width)) - measured.x) / 2,
            .y = @floatFromInt(y),
        },
        font_size,
        0,
        color,
    );
}

fn drawPresenterPairingOverlay(
    code: *qrcode.Code,
    runtime: *presenter.Runtime,
    connected: bool,
    screen_width: i32,
    screen_height: i32,
) void {
    const scale = presenterOverlayScale(screen_width, screen_height);
    const font = G.presenter_ui_font;
    rl.drawRectangleRec(.{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(screen_width),
        .height = @floatFromInt(screen_height),
    }, .{ .r = 7, .g = 11, .b = 24, .a = 255 });
    drawCenteredPresenterText(font, "PAIR PRESENTER PHONE", presenterOverlayPx(18, scale), 36 * scale, .{ .r = 97, .g = 218, .b = 251, .a = 255 }, screen_width);
    drawCenteredPresenterText(font, "Scan this private code before enabling screen mirroring", presenterOverlayPx(58, scale), 24 * scale, .{ .r = 185, .g = 202, .b = 220, .a = 255 }, screen_width);

    const qr_target = @max(
        presenterOverlayPx(120, scale),
        @min(
            presenterOverlayPx(380, scale),
            @min(screen_width - presenterOverlayPx(80, scale), screen_height - presenterOverlayPx(210, scale)),
        ),
    );
    if (code.ensure(runtime.pairing_url.slice())) {
        const matrix_size = code.size();
        const quiet_modules: i32 = 4;
        const cell = @max(@as(i32, 1), @divFloor(qr_target, matrix_size + quiet_modules * 2));
        const rendered_side = (matrix_size + quiet_modules * 2) * cell;
        const left = @divFloor(screen_width - rendered_side, 2);
        const top = presenterOverlayPx(92, scale);
        rl.drawRectangleRec(.{
            .x = @floatFromInt(left),
            .y = @floatFromInt(top),
            .width = @floatFromInt(rendered_side),
            .height = @floatFromInt(rendered_side),
        }, .white);
        var y: i32 = 0;
        while (y < matrix_size) : (y += 1) {
            var x: i32 = 0;
            while (x < matrix_size) : (x += 1) {
                if (!code.module(x, y)) continue;
                rl.drawRectangleRec(.{
                    .x = @floatFromInt(left + (x + quiet_modules) * cell),
                    .y = @floatFromInt(top + (y + quiet_modules) * cell),
                    .width = @floatFromInt(cell),
                    .height = @floatFromInt(cell),
                }, .{ .r = 5, .g = 9, .b = 18, .a = 255 });
            }
        }

        var address_buffer: [320:0]u8 = @splat(0);
        const address = std.fmt.bufPrintZ(&address_buffer, "Local address: {s}", .{runtime.base_url.slice()}) catch "Local address is too long";
        const address_y = @min(screen_height - presenterOverlayPx(82, scale), top + rendered_side + presenterOverlayPx(14, scale));
        drawCenteredPresenterText(font, address, address_y, 22 * scale, .{ .r = 223, .g = 233, .b = 244, .a = 255 }, screen_width);
    } else {
        drawCenteredPresenterText(font, "The pairing address is too long to encode as a QR code.", presenterOverlayPx(160, scale), 24 * scale, .{ .r = 255, .g = 155, .b = 174, .a = 255 }, screen_width);
    }

    drawCenteredPresenterText(
        font,
        if (connected) "PHONE CONNECTED" else "WAITING FOR PHONE",
        screen_height - presenterOverlayPx(82, scale),
        24 * scale,
        if (connected) .{ .r = 130, .g = 230, .b = 174, .a = 255 } else .{ .r = 255, .g = 181, .b = 71, .a = 255 },
        screen_width,
    );
    drawCenteredPresenterText(font, "P: hide setup   •   Shift-P: unpair and stop", screen_height - presenterOverlayPx(30, scale), 18 * scale, .{ .r = 139, .g = 158, .b = 179, .a = 255 }, screen_width);
}

test "presenter pairing overlay scales for projector resolutions" {
    try std.testing.expectApproxEqAbs(@as(f32, 1), presenterOverlayScale(1280, 720), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), presenterOverlayScale(1920, 1080), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 3), presenterOverlayScale(3840, 2160), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1), presenterOverlayScale(900, 506), 0.001);
}

const ExportController = struct {
    gpa: std.mem.Allocator,
    running: bool,
    return_to_slide_number: i32,
    return_to_step_number: usize,
    current_slide_number: i32,
    num_slides: usize,
    export_dir: []const u8,

    ready_toggle: bool = false,
    exported_imgs: ?std.ArrayListUnmanaged([]const u8) = null,
    final_messagebox_message: ?[:0]const u8 = null,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, export_dir: ?[]const u8) !ExportController {
        const ex_dir = export_dir orelse ",rayslides-export";
        std.Io.Dir.cwd().createDirPath(io, ex_dir) catch |err| {
            std.process.fatal("Could not prepare export dir {s} : {any}", .{ ex_dir, err });
        };

        return .{
            .gpa = gpa,
            .running = false,
            .export_dir = try gpa.dupe(u8, ex_dir),
            .return_to_slide_number = 0,
            .return_to_step_number = 0,
            .current_slide_number = 0,
            .num_slides = 0,
        };
    }

    pub fn deinit(self: *ExportController) void {
        self.gpa.free(self.export_dir);
        self.clean_img_list();
        if (self.final_messagebox_message) |msg| {
            self.gpa.free(msg);
        }
    }

    fn clean_img_list(self: *ExportController) void {
        if (self.exported_imgs) |*img_list| {
            for (img_list.items) |img| {
                log.info("cleaning {s}", .{img});
                self.gpa.free(img);
            }
            img_list.deinit(self.gpa);
        }
        self.exported_imgs = null;
    }

    pub fn start(self: *ExportController, current_slide_number: i32, current_step_number: usize, num_slides: usize) void {
        self.running = true;
        self.return_to_slide_number = current_slide_number;
        self.return_to_step_number = current_step_number;
        self.current_slide_number = 0;
        self.num_slides = num_slides;
        self.exported_imgs = std.ArrayListUnmanaged([]const u8).empty;
        self.ready_toggle = false;
    }

    /// signals if it's done
    pub fn advance(self: *ExportController) bool {
        self.current_slide_number += 1;
        if (self.current_slide_number >= self.num_slides) {
            self.running = false;
            return true;
        }
        return false;
    }

    pub fn ready(self: *ExportController) bool {
        self.ready_toggle = !self.ready_toggle;
        return !self.ready_toggle;
    }

    // PDF snapshotting
    pub fn snapshot(self: *ExportController) !void {
        if (!self.running) return;
        if (self.exported_imgs == null) return error.InvalidState;

        const img_path = try std.fmt.allocPrintSentinel(
            self.gpa,
            "{s}/slide-{d}.png",
            .{ self.export_dir, self.current_slide_number },
            0,
        );
        defer self.gpa.free(img_path);

        try self.exported_imgs.?.append(self.gpa, try self.gpa.dupe(u8, img_path));
        var img = try rl.loadImageFromScreen();
        img.setFormat(.uncompressed_r8g8b8);
        if (!img.exportToFile(img_path)) {
            log.err("Could not export screenshot to {s}", .{img_path});
        }
    }

    // single screenshot
    pub fn screenshot(self: *ExportController, slideshow_filename: ?[]const u8) !void {
        if (slideshow_filename) |filp| {
            const img_path = try std.fmt.allocPrintSentinel(self.gpa, "{s}.png", .{filp}, 0);
            defer self.gpa.free(img_path);

            var img = try rl.loadImageFromScreen();
            if (!img.exportToFile(img_path)) {
                log.err("Could not export screenshot to {s}", .{img_path});
            }
            self.final_messagebox_message = try std.fmt.allocPrintSentinel(self.gpa, "Screenshot saved to {s}", .{img_path}, 0);
        }
    }

    pub fn to_pdf(self: *ExportController, slideshow_name: []const u8) !void {
        if (self.exported_imgs == null) return error.InvalidState;
        const pdf_name = try std.fmt.allocPrintSentinel(self.gpa, "{s}.pdf", .{slideshow_name}, 0);
        defer self.gpa.free(pdf_name);

        var info: c.pdf_info = .{};
        _ = try std.fmt.bufPrintZ(&info.producer, "{s}", .{"rayslides"});

        if (c.pdf_create(1920, 1080, &info)) |pdf| {
            defer c.pdf_destroy(pdf);

            for (self.exported_imgs.?.items) |img_file| {
                if (c.pdf_append_page(pdf) == null) {
                    return error.PdfAppendPage;
                }

                if (c.pdf_add_image_file(pdf, null, 0.0, 0.0, 1920.0, 1080.0, @ptrCast(img_file)) < 0) {
                    return error.PdfAddImage;
                }
            }
            if (c.pdf_save(pdf, pdf_name) < 0) {
                return error.PdfSave;
            }
        } else {
            return error.PdfCreate;
        }

        self.final_messagebox_message = try std.fmt.allocPrintSentinel(self.gpa, "Slideshow exported to {s}", .{pdf_name}, 0);
    }
};

const LaserPointer = struct {
    allocator: std.mem.Allocator,
    show: bool = false,
    color: rl.Color = .red,
    size: f32 = 20,
    size_index: usize = 0,
    sizes: [6]f32 = .{ 10, 20, 30, 50, 70, 100 },

    draw_state: struct {
        thick: f32 = 5.0,
        vertices: std.ArrayList(rl.Vector2),
        mousepos_prev: rl.Vector2 = .{ .x = 0, .y = 0 },
    },

    pub fn init(gpa: std.mem.Allocator) !LaserPointer {
        return .{
            .allocator = gpa,
            .draw_state = .{
                .vertices = try std.ArrayList(rl.Vector2).initCapacity(gpa, 1000),
            },
        };
    }

    pub fn deinit(self: *LaserPointer) void {
        self.draw_state.vertices.deinit(self.allocator);
    }

    pub fn toggle(self: *LaserPointer) void {
        self.show = !self.show;
        if (self.show) {
            self.clearDrawing();
        }
    }

    fn clearDrawing(self: *LaserPointer) void {
        self.draw_state.vertices.shrinkRetainingCapacity(0);
    }

    pub fn draw(self: *LaserPointer) !void {
        const pos = rl.getMousePosition();
        rl.drawCircleV(pos, self.size, self.color);

        // add vertex only if mousepos has changed
        if (pos.x != self.draw_state.mousepos_prev.x or pos.y != self.draw_state.mousepos_prev.y) {
            const mouse_down = rl.isMouseButtonDown(.left);
            if (mouse_down) {
                try self.draw_state.vertices.append(self.allocator, pos);
            }

            // if mouse released, add sentinel value
            if (rl.isMouseButtonReleased(.left)) {
                try self.draw_state.vertices.append(self.allocator, .{ .x = 0, .y = 0 });
            }

            // draw vertices
            for (self.draw_state.vertices.items, 0..) |vertex, i| {
                if (i == 0) continue;

                // draw a line from A to B
                const pos_a = self.draw_state.vertices.items[i - 1];
                if (vertex.x != 0.0 and vertex.y != 0.0 and pos_a.x != 0.0 and pos_a.y != 0.0) {
                    rl.drawLineEx(pos_a, vertex, self.draw_state.thick, self.color);
                }
            }
        }
    }

    pub fn changeSize(self: *LaserPointer) void {
        self.size_index += 1;
        if (self.size_index >= self.sizes.len) {
            self.size_index = 0;
        }
        self.size = self.sizes[self.size_index];
    }
};

const max_remote_drawing_vertices: usize = 32 * 1024;

const RemoteDrawing = struct {
    allocator: std.mem.Allocator,
    vertices: std.ArrayList(?rl.Vector2),
    active: bool = false,
    cursor: ?rl.Vector2 = null,

    fn init(allocator: std.mem.Allocator) !RemoteDrawing {
        return .{
            .allocator = allocator,
            .vertices = try std.ArrayList(?rl.Vector2).initCapacity(allocator, max_remote_drawing_vertices),
        };
    }

    fn deinit(self: *RemoteDrawing) void {
        self.vertices.deinit(self.allocator);
    }

    fn clear(self: *RemoteDrawing) void {
        self.vertices.shrinkRetainingCapacity(0);
        self.active = false;
        self.cursor = null;
    }

    fn finishStroke(self: *RemoteDrawing) void {
        if (self.active and self.vertices.items.len < max_remote_drawing_vertices) {
            self.vertices.appendAssumeCapacity(null);
        }
        self.active = false;
        self.cursor = null;
    }

    fn appendPoint(self: *RemoteDrawing, point: rl.Vector2) !void {
        if (self.vertices.items.len > 0) {
            if (self.vertices.items[self.vertices.items.len - 1]) |previous| {
                if (previous.x == point.x and previous.y == point.y) return;
            }
        }
        if (self.vertices.items.len >= max_remote_drawing_vertices) return error.DrawingCapacity;
        self.vertices.appendAssumeCapacity(point);
    }

    fn apply(self: *RemoteDrawing, event: presenter.DrawingEvent) !void {
        const point: rl.Vector2 = .{ .x = event.x, .y = event.y };
        switch (event.phase) {
            .begin => {
                self.finishStroke();
                try self.appendPoint(point);
                self.active = true;
                self.cursor = point;
            },
            .move => {
                try self.appendPoint(point);
                self.active = true;
                self.cursor = point;
            },
            .end => {
                if (self.active) try self.appendPoint(point);
                self.finishStroke();
            },
        }
    }

    fn draw(self: *const RemoteDrawing, slide_top_left: rl.Vector2, slide_size: rl.Vector2, color: rl.Color) void {
        var previous: ?rl.Vector2 = null;
        const thickness = @max(@as(f32, 3), slide_size.y * 0.006);
        for (self.vertices.items) |entry| {
            const normalized = entry orelse {
                previous = null;
                continue;
            };
            const point = presenterPointerPosition(
                .{ .x = normalized.x, .y = normalized.y },
                slide_top_left,
                slide_size,
            );
            if (previous) |prior| {
                const mapped_prior = presenterPointerPosition(
                    .{ .x = prior.x, .y = prior.y },
                    slide_top_left,
                    slide_size,
                );
                rl.drawLineEx(mapped_prior, point, thickness, color);
            }
            previous = normalized;
        }
        if (self.cursor) |cursor| {
            rl.drawCircleV(
                presenterPointerPosition(.{ .x = cursor.x, .y = cursor.y }, slide_top_left, slide_size),
                @max(@as(f32, 8), thickness * 1.8),
                color,
            );
        }
    }
};

const PresenterPreviewKey = struct {
    slide_number: i32,
    visible_step: usize,
    active_step: ?usize,
    previous_slide: ?i32,
    source_revision: usize,
    crowd_revision: u64,
    previous_crowd_revision: u64,
};

const presenter_preview_width: i32 = 640;
const presenter_preview_height: i32 = 360;
const presenter_preview_retry_interval_seconds: f64 = 1.0;

fn presenterPreviewCaptureDue(
    last_key: ?PresenterPreviewKey,
    last_capture_at: f64,
    published: bool,
    key: PresenterPreviewKey,
    animating: bool,
    now: f64,
) bool {
    // Capturing performs a synchronous GPU readback and PNG encode. Waiting
    // for the settled frame keeps that work entirely outside animations.
    if (animating) return false;
    const previous = last_key orelse return true;
    if (!std.meta.eql(previous, key)) return true;
    if (published) return false;
    return now - last_capture_at >= presenter_preview_retry_interval_seconds;
}

fn presenterCrowdRevision(snapshot: ?crowdplay.Snapshot) u64 {
    return if (snapshot) |value| value.revision else 0;
}

const PresenterPreviewController = struct {
    target: rl.RenderTexture,
    last_key: ?PresenterPreviewKey = null,
    last_capture_at: f64 = -std.math.inf(f64),
    published: bool = false,

    fn init() !PresenterPreviewController {
        return .{ .target = try rl.RenderTexture.init(presenter_preview_width, presenter_preview_height) };
    }

    fn deinit(self: *PresenterPreviewController) void {
        self.target.unload();
    }

    fn invalidate(self: *PresenterPreviewController) void {
        self.last_key = null;
        self.last_capture_at = -std.math.inf(f64);
        self.published = false;
    }

    fn capture(
        self: *PresenterPreviewController,
        runtime: *presenter.Runtime,
        slide_renderer: *renderer.SlideshowRenderer,
        slide_number: i32,
        reveal_state: renderer.RevealState,
        transition_state: renderer.TransitionState,
        internal_render_size: rl.Vector2,
        crowd_snapshot: ?crowdplay.Snapshot,
        previous_crowd_snapshot: ?crowdplay.Snapshot,
        crowd_url: []const u8,
        source_revision: usize,
        now: f64,
    ) !void {
        if (!runtime.isRunning()) {
            self.invalidate();
            return;
        }

        const key: PresenterPreviewKey = .{
            .slide_number = slide_number,
            .visible_step = reveal_state.visible_through,
            .active_step = reveal_state.active_step,
            .previous_slide = transition_state.previous_slide,
            .source_revision = source_revision,
            .crowd_revision = presenterCrowdRevision(crowd_snapshot),
            .previous_crowd_revision = presenterCrowdRevision(previous_crowd_snapshot),
        };
        const animating = reveal_state.active_step != null or transition_state.previous_slide != null;
        if (!presenterPreviewCaptureDue(self.last_key, self.last_capture_at, self.published, key, animating, now)) return;

        self.last_key = key;
        self.last_capture_at = now;
        self.published = false;

        {
            self.target.begin();
            defer self.target.end();
            rl.clearBackground(.black);
            try slide_renderer.render(
                slide_number,
                reveal_state,
                transition_state,
                .zero(),
                .{ .x = @floatFromInt(presenter_preview_width), .y = @floatFromInt(presenter_preview_height) },
                internal_render_size,
                crowd_snapshot,
                previous_crowd_snapshot,
                crowd_url,
            );
        }

        var image = try rl.loadImageFromTexture(self.target.texture);
        defer image.unload();
        image.flipVertical();
        image.setFormat(.uncompressed_r8g8b8);
        // raylib's in-memory exporter only implements PNG even when its
        // file-based JPEG codec is enabled in the build.
        const encoded = try rl.exportImageToMemory(image, presenter.preview_file_type);
        defer rl.memFree(@ptrCast(encoded.ptr));
        if (encoded.len > presenter.max_preview_bytes) return error.PresenterPreviewTooLarge;
        try runtime.publishPreview(encoded);
        self.published = true;
    }
};

fn presenterPointerPosition(sample: presenter.PointerSample, slide_top_left: rl.Vector2, slide_size: rl.Vector2) rl.Vector2 {
    return .{
        .x = slide_top_left.x + std.math.clamp(sample.x, 0, 1) * slide_size.x,
        .y = slide_top_left.y + std.math.clamp(sample.y, 0, 1) * slide_size.y,
    };
}

test "presenter preview schedule waits for settled frames and retries failures" {
    const first: PresenterPreviewKey = .{
        .slide_number = 2,
        .visible_step = 1,
        .active_step = null,
        .previous_slide = null,
        .source_revision = 4,
        .crowd_revision = 0,
        .previous_crowd_revision = 0,
    };
    try std.testing.expect(presenterPreviewCaptureDue(null, 0, false, first, false, 10));
    try std.testing.expect(!presenterPreviewCaptureDue(first, 10, true, first, false, 20));

    var changed = first;
    changed.visible_step = 2;
    changed.active_step = 2;
    try std.testing.expect(!presenterPreviewCaptureDue(first, 10, true, changed, true, 10.01));
    try std.testing.expect(!presenterPreviewCaptureDue(null, 0, false, changed, true, 10.22));

    changed.active_step = null;
    try std.testing.expect(presenterPreviewCaptureDue(first, 10, true, changed, false, 11));
    try std.testing.expect(!presenterPreviewCaptureDue(changed, 11, true, changed, false, 20));
    try std.testing.expect(!presenterPreviewCaptureDue(changed, 11, false, changed, false, 11.9));
    try std.testing.expect(presenterPreviewCaptureDue(changed, 11, false, changed, false, 12.01));

    var transitioning = changed;
    transitioning.previous_slide = 1;
    try std.testing.expect(!presenterPreviewCaptureDue(changed, 12.01, true, transitioning, true, 13));
}

test "presenter preview format supports raylib in-memory export" {
    var image = rl.genImageColor(8, 8, .black);
    defer image.unload();
    const encoded = try rl.exportImageToMemory(image, presenter.preview_file_type);
    defer rl.memFree(@ptrCast(encoded.ptr));

    const png_signature = [_]u8{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a };
    try std.testing.expect(encoded.len > png_signature.len);
    try std.testing.expectEqualSlices(u8, &png_signature, encoded[0..png_signature.len]);
}

test "presenter pointer maps normalized phone coordinates into the fitted slide" {
    const position = presenterPointerPosition(
        .{ .active = true, .x = 0.25, .y = 0.75, .sequence = 3 },
        .{ .x = 100, .y = 50 },
        .{ .x = 800, .y = 450 },
    );
    try std.testing.expectApproxEqAbs(@as(f32, 300), position.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 387.5), position.y, 0.001);
}

test "remote drawing preserves normalized stroke boundaries" {
    var drawing = try RemoteDrawing.init(std.testing.allocator);
    defer drawing.deinit();

    try drawing.apply(.{ .phase = .begin, .x = 0.1, .y = 0.2, .sequence = 1 });
    try drawing.apply(.{ .phase = .move, .x = 0.3, .y = 0.4, .sequence = 2 });
    try drawing.apply(.{ .phase = .move, .x = 0.3, .y = 0.4, .sequence = 3 });
    try drawing.apply(.{ .phase = .end, .x = 0.5, .y = 0.6, .sequence = 4 });

    try std.testing.expectEqual(@as(usize, 4), drawing.vertices.items.len);
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), drawing.vertices.items[0].?.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), drawing.vertices.items[1].?.y, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), drawing.vertices.items[2].?.x, 0.0001);
    try std.testing.expect(drawing.vertices.items[3] == null);
    try std.testing.expect(!drawing.active);
    try std.testing.expect(drawing.cursor == null);

    drawing.clear();
    try std.testing.expectEqual(@as(usize, 0), drawing.vertices.items.len);
}

const Banner = struct {
    logo_texture: ?rl.Texture = null,
    showtime_seconds: f64 = banner_display_time_seconds,
    show: bool = false,
    screen_width: i32,
    screen_height: i32,

    pub const banner_display_time_seconds: f64 = 4.0;

    pub fn init(screenWidth: i32, screenHeight: i32) !Banner {
        const img = try rl.loadImageFromMemory(".png", @embedFile("assets/raylib_96x96.png"));
        defer rl.unloadImage(img);

        return .{
            .logo_texture = try rl.loadTextureFromImage(img),
            .show = true,
            .screen_width = screenWidth,
            .screen_height = screenHeight,
        };
    }

    pub fn reset(self: *Banner) void {
        self.showtime_seconds = rl.getTime() + banner_display_time_seconds;
        self.show = true;
    }

    pub fn render(self: *Banner) void {
        if (self.show) {
            if (rl.getTime() <= self.showtime_seconds) {
                if (self.logo_texture) |logo| {
                    const font_size: i32 = 75;
                    const text1 = "Slides, now with ";
                    const text1_width: i32 = rl.measureText(text1, font_size);
                    const text2 = "100% more ";
                    const text2_width: i32 = rl.measureText(text2, font_size);

                    const w: i32 = 1200;
                    const h: i32 = 350;
                    const l: i32 = @divTrunc(self.screen_width - w, 2);
                    const t: i32 = @divTrunc(self.screen_height - h, 2);
                    const border_thick: f32 = 5.0;
                    const border_inset: f32 = 10.0;
                    const border_inset_i: i32 = @intFromFloat(border_inset);
                    const padding: i32 = 30;
                    const logo_size: i32 = 96;
                    const font_size_rene: i32 = 30;
                    const backdrop_thick: i32 = 20;
                    const backdrop_color: rl.Color = rl.Color.alpha(rl.Color.white, 0.3);
                    const bg_color: rl.Color = rl.Color.alpha(rl.Color.ray_white, 0.97);

                    rl.drawRectangle(l - backdrop_thick, t - backdrop_thick, w + 2 * backdrop_thick, h + 2 * backdrop_thick, backdrop_color);
                    rl.drawRectangle(l, t, w, h, bg_color);

                    const border_rect: rl.Rectangle = .{
                        .x = @as(f32, @floatFromInt(l)) + border_inset,
                        .y = @as(f32, @floatFromInt(t)) + border_inset,
                        .width = @as(f32, @floatFromInt(w)) - border_inset * 2,
                        .height = @as(f32, @floatFromInt(h)) - border_inset * 2,
                    };
                    rl.drawRectangleLinesEx(border_rect, border_thick, rl.Color.sky_blue);

                    rl.drawText(text1, l + padding + border_inset_i, t + h - padding - font_size, font_size, rl.Color.gold);
                    rl.drawText(text2, text1_width + l + padding + border_inset_i, t + h - padding - font_size, font_size, rl.Color.red);

                    rl.drawText("@renerocksai", l + padding + border_inset_i, t + padding + border_inset_i, font_size_rene, rl.Color.brightness(rl.Color.sky_blue, -0.2));

                    logo.draw(
                        text1_width + text2_width + l + padding + border_inset_i,
                        t + h - padding - logo_size - 10,
                        rl.Color.white,
                    );
                }
            } else {
                self.show = false;
            }
        }
    }

    pub fn deinit(self: *Banner) void {
        if (self.logo_texture) |logo| {
            rl.unloadTexture(logo);
            self.logo_texture = null;
        }
    }
};

/// Raylib keeps the native close flag asserted after a close-button click.
/// When an inline draft deferred that click, clear our edge-detection latch as
/// soon as the draft closes or its synchronous commit is resolved so the next
/// frame can route the still-asserted request through source recovery.
fn releaseDeferredInlineCloseLatch(
    window_close_seen: *bool,
    inline_was_active: bool,
    inline_is_active: bool,
    inline_commit_completed: bool,
) void {
    if (inline_was_active and (!inline_is_active or inline_commit_completed)) {
        window_close_seen.* = false;
    }
}

test "inline completion releases a deferred native close request" {
    var close_seen = true;
    releaseDeferredInlineCloseLatch(&close_seen, true, false, false);
    try std.testing.expect(!close_seen);

    close_seen = true;
    releaseDeferredInlineCloseLatch(&close_seen, true, true, true);
    try std.testing.expect(!close_seen);

    close_seen = true;
    releaseDeferredInlineCloseLatch(&close_seen, true, true, false);
    try std.testing.expect(close_seen);

    close_seen = true;
    releaseDeferredInlineCloseLatch(&close_seen, false, false, true);
    try std.testing.expect(close_seen);
}

test "frame diagnostics distinguishes full partial and unchanged rebuilds" {
    var diagnostics = FrameDiagnostics{};
    diagnostics.recordPreRender(0.010, 1024, .{
        .mode = .full,
        .rebuilt_slide_count = 12,
        .total_slide_count = 12,
    });
    diagnostics.recordPreRender(0.002, 2048, .{
        .mode = .partial,
        .rebuilt_slide_count = 1,
        .total_slide_count = 12,
    });
    diagnostics.recordPreRender(0.0001, 2048, .{
        .mode = .unchanged,
        .rebuilt_slide_count = 0,
        .total_slide_count = 12,
    });
    try std.testing.expectEqual(@as(usize, 3), diagnostics.pre_render_count);
    try std.testing.expectEqual(@as(usize, 1), diagnostics.full_rebuild_count);
    try std.testing.expectEqual(@as(usize, 1), diagnostics.partial_rebuild_count);
    try std.testing.expectEqual(@as(usize, 1), diagnostics.unchanged_rebuild_count);
    try std.testing.expectEqual(renderer.SlideshowRenderer.RebuildMode.unchanged, diagnostics.last_rebuild_mode);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.last_rebuilt_slide_count);
    try std.testing.expectEqual(@as(usize, 12), diagnostics.last_rebuild_total_slide_count);
}

const FrameDiagnostics = struct {
    enabled: bool = false,
    last_frame_at: f64 = 0,
    sample_started_at: f64 = 0,
    latest_frame_ms: f64 = 0,
    building_peak_ms: f64 = 0,
    building_slow_frames: usize = 0,
    sampled_peak_ms: f64 = 0,
    sampled_slow_frames: usize = 0,
    last_pre_render_ms: f64 = 0,
    slideshow_arena_bytes: usize = 0,
    pre_render_count: usize = 0,
    last_rebuild_mode: renderer.SlideshowRenderer.RebuildMode = .full,
    last_rebuilt_slide_count: usize = 0,
    last_rebuild_total_slide_count: usize = 0,
    last_full_rebuild_ms: f64 = 0,
    last_partial_rebuild_ms: f64 = 0,
    last_unchanged_rebuild_ms: f64 = 0,
    full_rebuild_count: usize = 0,
    partial_rebuild_count: usize = 0,
    unchanged_rebuild_count: usize = 0,
    last_studio_prepare_ms: f64 = 0,
    studio_document_cache_builds: usize = 0,
    studio_scene_cache_builds: usize = 0,
    studio_composition_cache_builds: usize = 0,
    studio_cache_rebuilt: bool = false,
    studio_slide_count: usize = 0,
    studio_item_count: usize = 0,
    studio_render_fragment_count: usize = 0,
    last_slow_log_at: f64 = -10,

    fn observeFrame(self: *FrameDiagnostics, now: f64) void {
        if (self.sample_started_at == 0) self.sample_started_at = now;
        if (self.last_frame_at != 0) {
            self.latest_frame_ms = (now - self.last_frame_at) * 1000;
            self.building_peak_ms = @max(self.building_peak_ms, self.latest_frame_ms);
            if (self.latest_frame_ms > 1000.0 / 30.0) self.building_slow_frames += 1;
            if (self.enabled and self.latest_frame_ms > 50 and now - self.last_slow_log_at >= 1) {
                log.warn("slow frame: {d:.1} ms", .{self.latest_frame_ms});
                self.last_slow_log_at = now;
            }
        }
        self.last_frame_at = now;
        if (now - self.sample_started_at >= 1) {
            self.sampled_peak_ms = self.building_peak_ms;
            self.sampled_slow_frames = self.building_slow_frames;
            self.building_peak_ms = 0;
            self.building_slow_frames = 0;
            self.sample_started_at = now;
        }
    }

    fn recordPreRender(
        self: *FrameDiagnostics,
        elapsed_seconds: f64,
        arena_bytes: usize,
        result: renderer.SlideshowRenderer.RebuildResult,
    ) void {
        self.last_pre_render_ms = elapsed_seconds * 1000;
        self.slideshow_arena_bytes = arena_bytes;
        self.pre_render_count += 1;
        self.last_rebuild_mode = result.mode;
        self.last_rebuilt_slide_count = result.rebuilt_slide_count;
        self.last_rebuild_total_slide_count = result.total_slide_count;
        switch (result.mode) {
            .full => {
                self.full_rebuild_count += 1;
                self.last_full_rebuild_ms = self.last_pre_render_ms;
            },
            .partial => {
                self.partial_rebuild_count += 1;
                self.last_partial_rebuild_ms = self.last_pre_render_ms;
            },
            .unchanged => {
                self.unchanged_rebuild_count += 1;
                self.last_unchanged_rebuild_ms = self.last_pre_render_ms;
            },
        }
        log.debug(
            "render graph rebuild #{d}: {s} {d}/{d} slides, {d:.1} ms, slideshow arena {d:.1} KiB",
            .{
                self.pre_render_count,
                @tagName(result.mode),
                result.rebuilt_slide_count,
                result.total_slide_count,
                self.last_pre_render_ms,
                @as(f64, @floatFromInt(arena_bytes)) / 1024.0,
            },
        );
    }

    fn recordStudioPrepare(
        self: *FrameDiagnostics,
        elapsed_seconds: f64,
        document_cache_builds: usize,
        scene_cache_builds: usize,
        composition_cache_builds: usize,
        cache_rebuilt: bool,
        slide_count: usize,
        item_count: usize,
        render_fragment_count: usize,
    ) void {
        self.last_studio_prepare_ms = elapsed_seconds * 1000;
        self.studio_document_cache_builds = document_cache_builds;
        self.studio_scene_cache_builds = scene_cache_builds;
        self.studio_composition_cache_builds = composition_cache_builds;
        self.studio_cache_rebuilt = cache_rebuilt;
        self.studio_slide_count = slide_count;
        self.studio_item_count = item_count;
        self.studio_render_fragment_count = render_fragment_count;
    }

    fn draw(self: FrameDiagnostics, font: rl.Font, beast_mode: bool, placement: FrameDiagnosticsPlacement) void {
        if (!self.enabled) return;
        var frame_buffer: [192]u8 = undefined;
        var graph_buffer: [192]u8 = undefined;
        var input_buffer: [192]u8 = undefined;
        const frame_text = std.fmt.bufPrintZ(
            &frame_buffer,
            "FRAME {d:.1} ms   PEAK {d:.1} ms   SLOW {d}/s   {s}",
            .{ self.latest_frame_ms, self.sampled_peak_ms, self.sampled_slow_frames, if (beast_mode) "UNCAPPED" else "VSYNC" },
        ) catch return;
        const graph_text = std.fmt.bufPrintZ(
            &graph_buffer,
            "REBUILD {d:.1} ms   {s} {d}/{d}   F/P/N {d}/{d}/{d}   ARENA {d:.1} KiB",
            .{
                self.last_pre_render_ms,
                @tagName(self.last_rebuild_mode),
                self.last_rebuilt_slide_count,
                self.last_rebuild_total_slide_count,
                self.full_rebuild_count,
                self.partial_rebuild_count,
                self.unchanged_rebuild_count,
                @as(f64, @floatFromInt(self.slideshow_arena_bytes)) / 1024.0,
            },
        ) catch return;
        const mouse = rl.getMousePosition();
        const input_text = std.fmt.bufPrintZ(
            &input_buffer,
            "STUDIO {d:.2} ms   CACHE {d}/{d}/{d}{s}   DECK {d}   ITEMS {d}/{d}   MOUSE {d:.0}, {d:.0}   WINDOW {d} x {d}",
            .{
                self.last_studio_prepare_ms,
                self.studio_document_cache_builds,
                self.studio_scene_cache_builds,
                self.studio_composition_cache_builds,
                if (self.studio_cache_rebuilt) "*" else "",
                self.studio_slide_count,
                self.studio_item_count,
                self.studio_render_fragment_count,
                mouse.x,
                mouse.y,
                rl.getScreenWidth(),
                rl.getScreenHeight(),
            },
        ) catch return;
        switch (placement) {
            .hidden => return,
            .overlay => |origin| {
                const x: i32 = @intFromFloat(origin.x + 8);
                const y: i32 = @intFromFloat(origin.y + 8);
                rl.drawRectangle(x, y, 560, 78, .{ .r = 5, .g = 11, .b = 22, .a = 230 });
                rl.drawRectangleLines(x, y, 560, 78, .{ .r = 119, .g = 226, .b = 255, .a = 210 });
                rl.drawTextEx(font, frame_text, .{ .x = @floatFromInt(x + 10), .y = @floatFromInt(y + 7) }, 16, 0, .white);
                rl.drawTextEx(font, graph_text, .{ .x = @floatFromInt(x + 10), .y = @floatFromInt(y + 30) }, 14, 0, .{ .r = 170, .g = 205, .b = 222, .a = 255 });
                rl.drawTextEx(font, input_text, .{ .x = @floatFromInt(x + 10), .y = @floatFromInt(y + 50) }, 14, 0, .{ .r = 170, .g = 205, .b = 222, .a = 255 });
            },
            .toolbar => |slot| {
                const scale = @max(@as(f32, 0.75), slot.height / 58);
                const panel_height = @min(slot.height, 54 * scale);
                const panel: rl.Rectangle = .{
                    .x = slot.x,
                    .y = slot.y + (slot.height - panel_height) / 2,
                    .width = slot.width,
                    .height = panel_height,
                };
                var compact_frame_buffer: [160]u8 = undefined;
                var compact_graph_buffer: [192]u8 = undefined;
                const roomy = panel.width >= 540 * scale;
                const compact_frame = if (roomy)
                    frame_text
                else
                    std.fmt.bufPrintZ(
                        &compact_frame_buffer,
                        "FRAME {d:.1}   PEAK {d:.1}   SLOW {d}/s",
                        .{ self.latest_frame_ms, self.sampled_peak_ms, self.sampled_slow_frames },
                    ) catch return;
                const compact_graph = if (roomy)
                    std.fmt.bufPrintZ(
                        &compact_graph_buffer,
                        "BUILD {d:.1} ms {s} {d}/{d}   PREP {d:.2} ms   CACHE {d}/{d}/{d}{s}   DECK {d}   ITEMS {d}/{d}",
                        .{
                            self.last_pre_render_ms,
                            @tagName(self.last_rebuild_mode),
                            self.last_rebuilt_slide_count,
                            self.last_rebuild_total_slide_count,
                            self.last_studio_prepare_ms,
                            self.studio_document_cache_builds,
                            self.studio_scene_cache_builds,
                            self.studio_composition_cache_builds,
                            if (self.studio_cache_rebuilt) "*" else "",
                            self.studio_slide_count,
                            self.studio_item_count,
                            self.studio_render_fragment_count,
                        },
                    ) catch return
                else
                    std.fmt.bufPrintZ(
                        &compact_graph_buffer,
                        "{s} {d}/{d}   {d:.0} ms   #{d}   {s}",
                        .{
                            @tagName(self.last_rebuild_mode),
                            self.last_rebuilt_slide_count,
                            self.last_rebuild_total_slide_count,
                            self.last_pre_render_ms,
                            self.pre_render_count,
                            if (beast_mode) "UNCAPPED" else "VSYNC",
                        },
                    ) catch return;
                rl.drawRectangleRec(panel, .{ .r = 5, .g = 11, .b = 22, .a = 235 });
                rl.drawRectangleLinesEx(panel, @max(@as(f32, 1), scale), .{ .r = 119, .g = 226, .b = 255, .a = 185 });
                rl.drawRectangleRec(.{ .x = panel.x, .y = panel.y, .width = 3 * scale, .height = panel.height }, .{ .r = 239, .g = 69, .b = 154, .a = 255 });
                rl.beginScissorMode(
                    @intFromFloat(panel.x + 5 * scale),
                    @intFromFloat(panel.y),
                    @intFromFloat(@max(0, panel.width - 8 * scale)),
                    @intFromFloat(panel.height),
                );
                defer rl.endScissorMode();
                rl.drawTextEx(font, compact_frame, .{ .x = panel.x + 11 * scale, .y = panel.y + 7 * scale }, 14 * scale, 0, .white);
                rl.drawTextEx(font, compact_graph, .{ .x = panel.x + 11 * scale, .y = panel.y + 29 * scale }, 13 * scale, 0, .{ .r = 170, .g = 205, .b = 222, .a = 255 });
            },
        }
    }
};

const FrameDiagnosticsPlacement = union(enum) {
    overlay: rl.Vector2,
    toolbar: rl.Rectangle,
    hidden: void,
};

fn frameDiagnosticsPlacement(viewport: studio.Viewport, fallback_origin: rl.Vector2) FrameDiagnosticsPlacement {
    if (viewport.chrome) |chrome| {
        if (chrome.visible) {
            const layout = studio.uiLayout(viewport);
            const scale = chrome.scale;
            const left = layout.scene_next.x + layout.scene_next.width + 10 * scale;
            const right = layout.command_palette.x - 10 * scale;
            if (right - left >= 330 * scale) return .{ .toolbar = .{
                .x = left,
                .y = chrome.toolbar.y + 6 * scale,
                .width = right - left,
                .height = @max(0, chrome.toolbar.height - 12 * scale),
            } };
            return .hidden;
        }
    }
    return .{ .overlay = fallback_origin };
}

fn validDiagnosticScenarioName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |char| {
        if (!std.ascii.isAlphanumeric(char) and char != '-' and char != '_') return false;
    }
    return true;
}

fn captureDiagnosticScreenshot(path: []const u8, logical_size: ?WindowDimensions) !WindowDimensions {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const sentinel_path = try std.fmt.bufPrintZ(&path_buffer, "{s}", .{path});
    var image = try rl.loadImageFromScreen();
    defer rl.unloadImage(image);
    if (logical_size) |size| {
        if (image.width != size.width or image.height != size.height) image.resize(size.width, size.height);
    }
    if (!image.exportToFile(sentinel_path)) return error.DiagnosticScreenshotFailed;
    return .{ .width = image.width, .height = image.height };
}

fn formatDiagnosticCaptureReport(
    buffer: []u8,
    scenario: []const u8,
    diagnostics: FrameDiagnostics,
    capture_size: WindowDimensions,
) ![]const u8 {
    if (!validDiagnosticScenarioName(scenario)) return error.InvalidDiagnosticScenario;
    return std.fmt.bufPrint(
        buffer,
        "{{\n" ++
            "  \"schema\": 1,\n" ++
            "  \"scenario\": \"{s}\",\n" ++
            "  \"capture\": {{ \"width\": {d}, \"height\": {d} }},\n" ++
            "  \"deck\": {{ \"slides\": {d}, \"active_items\": {d}, \"render_fragments\": {d} }},\n" ++
            "  \"render\": {{\n" ++
            "    \"events\": {d}, \"last_mode\": \"{s}\", \"last_rebuilt\": {d}, \"total_slides\": {d},\n" ++
            "    \"full_count\": {d}, \"partial_count\": {d}, \"unchanged_count\": {d},\n" ++
            "    \"last_full_ms\": {d:.3}, \"last_partial_ms\": {d:.3}, \"last_unchanged_ms\": {d:.3}\n" ++
            "  }},\n" ++
            "  \"studio\": {{ \"prepare_ms\": {d:.3}, \"document_cache_builds\": {d}, \"scene_cache_builds\": {d}, \"composition_cache_builds\": {d} }},\n" ++
            "  \"frame\": {{ \"latest_ms\": {d:.3}, \"sampled_peak_ms\": {d:.3}, \"sampled_slow_frames\": {d} }},\n" ++
            "  \"parser_arena_bytes\": {d}\n" ++
            "}}\n",
        .{
            scenario,
            capture_size.width,
            capture_size.height,
            diagnostics.studio_slide_count,
            diagnostics.studio_item_count,
            diagnostics.studio_render_fragment_count,
            diagnostics.pre_render_count,
            @tagName(diagnostics.last_rebuild_mode),
            diagnostics.last_rebuilt_slide_count,
            diagnostics.last_rebuild_total_slide_count,
            diagnostics.full_rebuild_count,
            diagnostics.partial_rebuild_count,
            diagnostics.unchanged_rebuild_count,
            diagnostics.last_full_rebuild_ms,
            diagnostics.last_partial_rebuild_ms,
            diagnostics.last_unchanged_rebuild_ms,
            diagnostics.last_studio_prepare_ms,
            diagnostics.studio_document_cache_builds,
            diagnostics.studio_scene_cache_builds,
            diagnostics.studio_composition_cache_builds,
            diagnostics.latest_frame_ms,
            diagnostics.sampled_peak_ms,
            diagnostics.sampled_slow_frames,
            diagnostics.slideshow_arena_bytes,
        },
    );
}

fn writeDiagnosticCaptureReport(
    io: std.Io,
    path: []const u8,
    scenario: []const u8,
    diagnostics: FrameDiagnostics,
    capture_size: WindowDimensions,
) !void {
    var report_buffer: [4096]u8 = undefined;
    const report = try formatDiagnosticCaptureReport(&report_buffer, scenario, diagnostics, capture_size);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = report });
}

fn diagnosticCaptureGateIsOpen(io: std.Io, path: ?[]const u8) bool {
    const gate_path = path orelse return true;
    const gate = std.Io.Dir.cwd().openFile(io, gate_path, .{}) catch return false;
    gate.close(io);
    return true;
}

test "frame diagnostics rolls peak and slow-frame counts" {
    var diagnostics = FrameDiagnostics{};
    diagnostics.observeFrame(1.0);
    diagnostics.observeFrame(1.016);
    diagnostics.observeFrame(1.056);
    diagnostics.observeFrame(2.1);
    try std.testing.expectApproxEqAbs(@as(f64, 1044), diagnostics.sampled_peak_ms, 0.001);
    try std.testing.expectEqual(@as(usize, 2), diagnostics.sampled_slow_frames);
}

test "frame diagnostics use the free Studio toolbar span without overlapping controls" {
    const frame = studio.frameLayout(.{ .x = 0, .y = 0, .width = 1600, .height = 900 }, true, false, .slides);
    const placement = frameDiagnosticsPlacement(frame.viewport, .zero());
    const slot = switch (placement) {
        .toolbar => |value| value,
        else => return error.TestExpectedEqual,
    };
    const layout = studio.uiLayout(frame.viewport);
    try std.testing.expect(slot.x >= layout.scene_next.x + layout.scene_next.width);
    try std.testing.expect(slot.x + slot.width <= layout.command_palette.x);
    try std.testing.expect(slot.y >= frame.chrome.toolbar.y);
    try std.testing.expect(slot.y + slot.height <= frame.chrome.toolbar.y + frame.chrome.toolbar.height);

    const compact = studio.frameLayout(.{ .x = 0, .y = 0, .width = 900, .height = 506 }, true, false, .slides);
    try std.testing.expect(frameDiagnosticsPlacement(compact.viewport, .zero()) == .hidden);
}

test "diagnostic capture report is valid structured JSON" {
    var diagnostics = FrameDiagnostics{
        .last_rebuild_mode = .partial,
        .last_rebuilt_slide_count = 1,
        .last_rebuild_total_slide_count = 160,
        .last_full_rebuild_ms = 6.5,
        .last_partial_rebuild_ms = 0.3,
        .full_rebuild_count = 1,
        .partial_rebuild_count = 1,
        .pre_render_count = 2,
        .studio_slide_count = 160,
        .studio_item_count = 7,
        .studio_render_fragment_count = 13,
    };
    diagnostics.recordStudioPrepare(0.00002, 2, 2, 2, false, 160, 7, 13);
    var buffer: [4096]u8 = undefined;
    const report = try formatDiagnosticCaptureReport(&buffer, "incremental-160", diagnostics, .{ .width = 1600, .height = 900 });
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, report, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("incremental-160", parsed.value.object.get("scenario").?.string);
    try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("render").?.object.get("last_rebuilt").?.integer);
    try std.testing.expect(!validDiagnosticScenarioName("bad/name"));
}

pub fn main(init: std.process.Init) anyerror!void {
    const gpa = init.gpa;
    const io = init.io;

    var executable_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const executable_path_len = std.process.executablePath(io, &executable_path_buffer) catch 0;
    const launched_from_macos_bundle = builtin.os.tag == .macos and
        isMacosAppExecutable(executable_path_buffer[0..executable_path_len]);
    var app_recovery_dir_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var app_recovery_dir: ?[]const u8 = null;
    if (launched_from_macos_bundle) {
        if (init.environ_map.get("HOME")) |home| {
            if (std.Io.Dir.openDirAbsolute(io, home, .{})) |home_dir| {
                defer home_dir.close(io);
                std.process.setCurrentDir(io, home_dir) catch |err|
                    log.warn("Could not use the home directory as the app working directory: {any}", .{err});
            } else |_| {}
            app_recovery_dir = std.fmt.bufPrint(
                &app_recovery_dir_buffer,
                "{s}/Library/Application Support/Rayslides/Recovery",
                .{home},
            ) catch null;
        }
    }

    //--------------------------------------------------------------------------------------

    var crowd_options = CrowdOptions{};
    var crowd_host_buffer: [256]u8 = undefined;
    crowd_options.host = defaultCrowdHost(&crowd_host_buffer);
    var presenter_options = PresenterOptions{};
    var presenter_host_buffer: [256]u8 = undefined;
    presenter_options.host = defaultCrowdHost(&presenter_host_buffer);
    var launch_studio = false;
    var suppress_startup_banner = false;
    var diagnostics_enabled = false;
    var diagnostics_command_palette = false;
    var diagnostics_command_tooltip = false;
    var diagnostics_precision_view = false;
    var diagnostics_presenter_pairing = false;
    var diagnostics_large_deck_count: ?usize = null;
    var diagnostics_incremental_edit_slide: ?usize = null;
    var diagnostics_window_size: ?WindowDimensions = null;
    var diagnostics_capture_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var diagnostics_capture_path: ?[]const u8 = null;
    var diagnostics_report_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var diagnostics_report_path: ?[]const u8 = null;
    var diagnostics_capture_scenario_buffer: [64]u8 = undefined;
    var diagnostics_capture_scenario: []const u8 = "manual";
    var diagnostics_capture_gate_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var diagnostics_capture_gate_path: ?[]const u8 = null;
    var diagnostics_capture_settle_frames: usize = 90;
    var diagnostics_exit_after_capture = false;
    var diagnostics_hide_hud = false;
    var diagnostics_select_buffer: [128]u8 = undefined;
    var diagnostics_select_id: ?[]const u8 = null;
    var diagnostics_find_slide_buffer: [studio.max_panel_search_bytes]u8 = undefined;
    var diagnostics_find_slide_query: ?[]const u8 = null;

    // get args
    const slideshow_to_load: ?[]const u8 = blk: {
        var args_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
        defer args_it.deinit();
        _ = args_it.skip();
        var slideshow_arg: ?[]const u8 = null;
        var positional_only = false;
        while (args_it.next()) |arg| {
            if (!positional_only and (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help"))) {
                var output: [8192]u8 = undefined;
                const rendered = try std.fmt.bufPrint(&output, cli_help, .{build_options.version});
                try std.Io.File.stdout().writeStreamingAll(io, rendered);
                return;
            } else if (!positional_only and (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version"))) {
                var output: [128]u8 = undefined;
                const rendered = try std.fmt.bufPrint(&output, "rayslides {s}\n", .{build_options.version});
                try std.Io.File.stdout().writeStreamingAll(io, rendered);
                return;
            } else if (!positional_only and std.mem.eql(u8, arg, "--")) {
                positional_only = true;
            } else if (!positional_only and std.mem.startsWith(u8, arg, "--crowd-host=")) {
                crowd_options.host = try std.fmt.bufPrint(&crowd_host_buffer, "{s}", .{arg["--crowd-host=".len..]});
                crowd_options.host_explicit = true;
            } else if (!positional_only and std.mem.startsWith(u8, arg, "--crowd-port=")) {
                crowd_options.port = std.fmt.parseInt(u16, arg["--crowd-port=".len..], 10) catch std.process.fatal("Invalid --crowd-port value", .{});
            } else if (!positional_only and std.mem.eql(u8, arg, "--no-crowd")) {
                crowd_options.enabled = false;
            } else if (!positional_only and std.mem.startsWith(u8, arg, "--presenter-host=")) {
                presenter_options.host = try std.fmt.bufPrint(&presenter_host_buffer, "{s}", .{arg["--presenter-host=".len..]});
                presenter_options.host_explicit = true;
            } else if (!positional_only and std.mem.startsWith(u8, arg, "--presenter-port=")) {
                presenter_options.port = std.fmt.parseInt(u16, arg["--presenter-port=".len..], 10) catch std.process.fatal("Invalid --presenter-port value", .{});
            } else if (!positional_only and std.mem.eql(u8, arg, "--studio")) {
                launch_studio = true;
            } else if (!positional_only and std.mem.eql(u8, arg, "--no-startup-banner")) {
                suppress_startup_banner = true;
            } else if (!positional_only and std.mem.eql(u8, arg, "--diagnostics")) {
                diagnostics_enabled = true;
            } else if (!positional_only and std.mem.eql(u8, arg, "--diagnostics-command-palette")) {
                diagnostics_enabled = true;
                diagnostics_command_palette = true;
                launch_studio = true;
            } else if (!positional_only and std.mem.eql(u8, arg, "--diagnostics-command-tooltip")) {
                diagnostics_enabled = true;
                diagnostics_command_tooltip = true;
                launch_studio = true;
            } else if (!positional_only and std.mem.eql(u8, arg, "--diagnostics-precision-view")) {
                diagnostics_enabled = true;
                diagnostics_precision_view = true;
                launch_studio = true;
            } else if (!positional_only and std.mem.eql(u8, arg, "--diagnostics-presenter-pairing")) {
                diagnostics_presenter_pairing = true;
                launch_studio = true;
            } else if (!positional_only and std.mem.startsWith(u8, arg, "--diagnostics-large-deck=")) {
                const value = arg["--diagnostics-large-deck=".len..];
                const count = std.fmt.parseInt(usize, value, 10) catch return error.InvalidDiagnosticSlideCount;
                if (count == 0 or count > 200) return error.InvalidDiagnosticSlideCount;
                diagnostics_enabled = true;
                diagnostics_large_deck_count = count;
                launch_studio = true;
            } else if (!positional_only and std.mem.startsWith(u8, arg, "--diagnostics-incremental-edit=")) {
                const value = arg["--diagnostics-incremental-edit=".len..];
                const one_based_slide = std.fmt.parseInt(usize, value, 10) catch return error.InvalidDiagnosticSlideIndex;
                if (one_based_slide == 0) return error.InvalidDiagnosticSlideIndex;
                diagnostics_enabled = true;
                launch_studio = true;
                diagnostics_incremental_edit_slide = one_based_slide - 1;
            } else if (!positional_only and std.mem.startsWith(u8, arg, "--diagnostics-window=")) {
                diagnostics_enabled = true;
                launch_studio = true;
                diagnostics_window_size = parseDiagnosticWindowSize(arg["--diagnostics-window=".len..]) orelse
                    std.process.fatal("Invalid diagnostics window size; use WIDTHxHEIGHT (minimum 900x506)", .{});
            } else if (!positional_only and std.mem.startsWith(u8, arg, "--diagnostics-capture=")) {
                diagnostics_capture_path = std.fmt.bufPrint(
                    &diagnostics_capture_path_buffer,
                    "{s}",
                    .{arg["--diagnostics-capture=".len..]},
                ) catch std.process.fatal("Diagnostics capture path is too long", .{});
                launch_studio = true;
            } else if (!positional_only and std.mem.startsWith(u8, arg, "--diagnostics-report=")) {
                diagnostics_report_path = std.fmt.bufPrint(
                    &diagnostics_report_path_buffer,
                    "{s}",
                    .{arg["--diagnostics-report=".len..]},
                ) catch std.process.fatal("Diagnostics report path is too long", .{});
            } else if (!positional_only and std.mem.startsWith(u8, arg, "--diagnostics-capture-scenario=")) {
                const scenario = arg["--diagnostics-capture-scenario=".len..];
                if (!validDiagnosticScenarioName(scenario)) return error.InvalidDiagnosticScenario;
                diagnostics_capture_scenario = std.fmt.bufPrint(
                    &diagnostics_capture_scenario_buffer,
                    "{s}",
                    .{scenario},
                ) catch return error.InvalidDiagnosticScenario;
            } else if (!positional_only and std.mem.startsWith(u8, arg, "--diagnostics-capture-settle=")) {
                diagnostics_capture_settle_frames = std.fmt.parseInt(
                    usize,
                    arg["--diagnostics-capture-settle=".len..],
                    10,
                ) catch return error.InvalidDiagnosticCaptureSettle;
                if (diagnostics_capture_settle_frames == 0 or diagnostics_capture_settle_frames > 600)
                    return error.InvalidDiagnosticCaptureSettle;
            } else if (!positional_only and std.mem.startsWith(u8, arg, "--diagnostics-capture-gate=")) {
                diagnostics_capture_gate_path = std.fmt.bufPrint(
                    &diagnostics_capture_gate_buffer,
                    "{s}",
                    .{arg["--diagnostics-capture-gate=".len..]},
                ) catch std.process.fatal("Diagnostics capture gate path is too long", .{});
            } else if (!positional_only and std.mem.eql(u8, arg, "--diagnostics-exit-after-capture")) {
                diagnostics_exit_after_capture = true;
            } else if (!positional_only and std.mem.eql(u8, arg, "--diagnostics-hide-hud")) {
                diagnostics_hide_hud = true;
            } else if (!positional_only and std.mem.startsWith(u8, arg, "--diagnostics-select=")) {
                diagnostics_enabled = true;
                launch_studio = true;
                diagnostics_select_id = std.fmt.bufPrint(
                    &diagnostics_select_buffer,
                    "{s}",
                    .{arg["--diagnostics-select=".len..]},
                ) catch std.process.fatal("Diagnostics selection ID is too long", .{});
            } else if (!positional_only and std.mem.startsWith(u8, arg, "--diagnostics-find-slide=")) {
                diagnostics_enabled = true;
                launch_studio = true;
                diagnostics_find_slide_query = std.fmt.bufPrint(
                    &diagnostics_find_slide_buffer,
                    "{s}",
                    .{arg["--diagnostics-find-slide=".len..]},
                ) catch std.process.fatal("Diagnostics slide query is too long", .{});
            } else if (!positional_only and std.mem.startsWith(u8, arg, "-")) {
                std.process.fatal("Unknown option: {s} (use --help)", .{arg});
            } else if (slideshow_arg == null) {
                slideshow_arg = arg;
            } else {
                std.process.fatal("Unexpected argument: {s}", .{arg});
            }
        }
        const selected = slideshow_arg orelse break :blk null;
        log.debug("loading... {s}", .{selected});
        break :blk try std.fmt.bufPrint(&G.slideshow_filp_to_load_buffer, "{s}", .{selected});
    };

    if ((diagnostics_report_path != null or diagnostics_exit_after_capture) and diagnostics_capture_path == null)
        return error.DiagnosticCapturePathRequired;

    const starts_in_studio = launch_studio or slideshow_to_load == null;
    const windowWidth: i32 = 1280;
    const windowHeight: i32 = 720;
    var screenWidth: i32 = windowWidth;
    var screenHeight: i32 = windowHeight;

    // Present complete frames on the monitor refresh boundary. The old 61 Hz
    // software-only cap could tear visibly on macOS while Studio continuously
    // redraws its canvas and chrome, even when the scene itself was static.
    // Register before GLFW finishes launching NSApplication: LaunchServices
    // may deliver the initial Finder/Open With document during initWindow.
    MacOpenDocuments.install();
    rl.setConfigFlags(.{ .window_resizable = true, .vsync_hint = true });
    rl.initWindow(screenWidth, screenHeight, "rayslides");
    rl.setWindowMinSize(900, 506);
    if (starts_in_studio) {
        const monitor = rl.getCurrentMonitor();
        const dimensions = diagnostics_window_size orelse studioStartupWindowSize(
            rl.getMonitorWidth(monitor),
            rl.getMonitorHeight(monitor),
        );
        rl.setWindowSize(dimensions.width, dimensions.height);
        const monitor_position = rl.getMonitorPosition(monitor);
        rl.setWindowPosition(
            @intFromFloat(monitor_position.x + @as(f32, @floatFromInt(rl.getMonitorWidth(monitor) - dimensions.width)) / 2),
            @intFromFloat(monitor_position.y + @as(f32, @floatFromInt(rl.getMonitorHeight(monitor) - dimensions.height)) / 2),
        );
        screenWidth = dimensions.width;
        screenHeight = dimensions.height;
    }
    // Studio owns Escape while editing (cancel drag, then leave Studio). Keep
    // Raylib from closing the process before the frame can consume the key.
    rl.setExitKey(.null);
    defer rl.closeWindow(); // Close window and OpenGL context

    // Initialize GPU-backed resources after the window and unload them before it closes.
    try G.init(gpa, io);
    defer G.deinit();
    if (app_recovery_dir) |path| G.setRecoveryDirectory(path);
    if (slideshow_to_load) |path| {
        G.slideshow_filp_to_load = path;
    } else if (diagnostics_large_deck_count) |slide_count| {
        try initializeDiagnosticLargeSlideshow(slide_count);
    } else {
        try initializeUntitledSlideshow();
    }
    var crowd_runtime = try crowdplay.Runtime.init(gpa, io);
    defer crowd_runtime.stop();
    var presenter_runtime = try presenter.Runtime.init(gpa, io);
    defer presenter_runtime.deinit();
    var presenter_preview = try PresenterPreviewController.init();
    defer presenter_preview.deinit();
    var presenter_qr: qrcode.Code = .{};
    var presenter_pairing_visible = false;
    if (diagnostics_presenter_pairing) {
        if (!ensurePresenterCompanionRunning(&presenter_runtime, presenter_options))
            return error.DiagnosticPresenterPairingFailed;
        presenter_pairing_visible = true;
    }

    rl.setTargetFPS(60);
    var beast_mode: bool = false;
    var frame_diagnostics = FrameDiagnostics{ .enabled = diagnostics_enabled and !diagnostics_hide_hud };
    var diagnostics_selection_pending = diagnostics_select_id;
    var diagnostics_command_palette_pending = diagnostics_command_palette;
    var diagnostics_precision_view_pending = diagnostics_precision_view;
    var diagnostics_find_slide_pending = diagnostics_find_slide_query;
    var diagnostics_incremental_edit_pending = diagnostics_incremental_edit_slide;
    var diagnostics_capture_stable_frames: usize = 0;
    var diagnostics_capture_complete = false;

    // Main game loop
    var is_pre_rendered: bool = false;
    var export_controller: ExportController = try .init(gpa, io, null);
    defer export_controller.deinit();
    var laser_pointer: LaserPointer = try .init(gpa);
    defer laser_pointer.deinit();
    var remote_drawing: RemoteDrawing = try .init(gpa);
    defer remote_drawing.deinit();
    var remote_drawing_slide = G.current_slide;
    var banner: Banner = try .init(screenWidth, screenHeight);
    if (suppress_startup_banner) banner.show = false;
    defer banner.deinit();
    var studio_mode: studio.Studio = .{
        .enabled = starts_in_studio,
        .dirty = slideshow_to_load == null,
        .ui_font = G.studio_ui_font,
    };
    var property_prompt: studio_prompt.Prompt = .{};
    var pending_semantic_command: ?studio.SemanticCommand = null;
    var pending_save_as = false;
    var studio_history = StudioHistory.init(gpa);
    defer studio_history.deinit();
    var studio_clipboard = StudioClipboard.init(gpa);
    defer studio_clipboard.deinit();
    var studio_bounds = std.ArrayList(studio.ResolvedBounds).empty;
    defer studio_bounds.deinit(gpa);
    var studio_render_bounds = std.ArrayList(renderer.SlideshowRenderer.ItemRenderBounds).empty;
    defer studio_render_bounds.deinit(gpa);
    var studio_workspace_cache = StudioWorkspaceCache.init(gpa);
    defer studio_workspace_cache.deinit();
    var studio_composition_cache: StudioCompositionCache = .{};

    var manual_fullscreen: bool = false;
    var windowed_width = screenWidth;
    var windowed_height = screenHeight;
    var window_close_seen = false;

    while (true) {
        frame_diagnostics.observeFrame(rl.getTime());
        // Window managers may tile a just-launched diagnostic process while
        // moving it to the requested QA workspace. Baseline capture is the
        // one mode where the CLI dimensions are a strict test contract, so
        // restore them until the floating window agrees.
        if (diagnostics_capture_path != null) {
            if (diagnostics_window_size) |dimensions| {
                if (rl.getScreenWidth() != dimensions.width or rl.getScreenHeight() != dimensions.height) {
                    rl.setWindowSize(dimensions.width, dimensions.height);
                    screenWidth = dimensions.width;
                    screenHeight = dimensions.height;
                    diagnostics_capture_stable_frames = 0;
                }
            }
        }
        const window_close_now = rl.windowShouldClose();
        const window_close_requested = window_close_now and !window_close_seen;
        window_close_seen = window_close_now;
        const inline_edit_active_at_frame_start = studio_mode.inlineEditActive();
        const command_palette_active_at_frame_start = studio_mode.commandPaletteActive();
        const text_input_active_at_frame_start = property_prompt.active or studio_mode.textEntryActive();
        const presenter_pairing_visible_at_frame_start = presenter_pairing_visible;
        var presenter_overlay_consumed_input = false;
        if (!text_input_active_at_frame_start and rl.isKeyPressed(.p)) {
            presenter_overlay_consumed_input = true;
            if (rl.isKeyDown(.left_shift) or rl.isKeyDown(.right_shift)) {
                presenter_runtime.stop();
                presenter_pairing_visible = false;
                log.info("Presenter Companion stopped and pairing invalidated", .{});
            } else if (presenter_pairing_visible) {
                presenter_pairing_visible = false;
            } else if (ensurePresenterCompanionRunning(&presenter_runtime, presenter_options)) {
                presenter_pairing_visible = true;
            }
        }
        if (presenter_pairing_visible_at_frame_start and rl.isKeyPressed(.escape)) {
            presenter_pairing_visible = false;
            presenter_overlay_consumed_input = true;
            window_close_seen = false;
        }
        const presenter_overlay_captures_input = presenter_pairing_visible_at_frame_start or
            presenter_pairing_visible or presenter_overlay_consumed_input;
        // A modal or inline property draft is not part of the persisted source
        // yet. Do not let the OS close button silently throw it away; after
        // submitting or cancelling, Q/Escape (or a fresh close request)
        // follows the normal source-recovery path below.
        if (window_close_requested and !text_input_active_at_frame_start and readyToQuitPreservingEdits(&studio_mode)) break;

        const studio_active_at_frame_start = studio_mode.capturesInput();
        // Update
        //----------------------------------------------------------------------------------
        // TODO: Update your variables here
        //----------------------------------------------------------------------------------
        G.content_window_size = .{ .x = @floatFromInt(screenWidth), .y = @floatFromInt(screenHeight) };
        if (G.content_window_size.x != G.last_window_size.x or G.content_window_size.y != G.last_window_size.y) {
            // window size changed
            std.log.debug("win size changed from {} to {}", .{ G.last_window_size, G.content_window_size });
            G.last_window_size = G.content_window_size;
        }

        if (export_controller.running) {
            if (export_controller.ready()) {
                if (export_controller.snapshot()) |_| {
                    if (export_controller.advance()) {
                        if (G.slideshow_filp) |slideshow_name| {
                            try export_controller.to_pdf(slideshow_name);
                        } else {
                            log.err("PDF-export: could not retrieve slideshow name, it's null!!!", .{});
                        }
                        G.current_slide = export_controller.return_to_slide_number;
                        G.playback.enterSlide(null, 0, export_controller.return_to_step_number, .{}, 1, rl.getTime());
                        export_controller.clean_img_list();
                    } else {
                        G.current_slide = export_controller.current_slide_number;
                    }
                } else |err| {
                    log.err("Error while snapshotting: {any}", .{err});
                }
            }
        }

        if (!text_input_active_at_frame_start and rl.isKeyPressed(.s)) {
            if (studio_mode.capturesInput() or (editorSourceDirty() and shortcutModifierDown())) {
                if (shortcutModifierDown()) {
                    if (G.slideshow_filp == null) {
                        pending_save_as = true;
                        property_prompt.begin(.document_path, "untitled.sld");
                    } else if (rl.isKeyDown(.left_shift) or rl.isKeyDown(.right_shift)) {
                        if (saveEditorSourceCopy()) |copy_path| {
                            studio_mode.markCopySaved();
                            log.info("Studio copy saved to {s}", .{copy_path});
                            gpa.free(copy_path);
                        } else |err| {
                            studio_mode.setNotice(.save_failed);
                            log.err("Studio Save Copy failed: {any}", .{err});
                        }
                    } else {
                        if (saveEditorSource()) |_| {
                            studio_mode.markSaved();
                            studio_mode.setNotice(.saved);
                            log.info("Studio source saved", .{});
                        } else |err| {
                            studio_mode.setNotice(if (err == error.SourceChangedOnDisk)
                                .source_changed_on_disk
                            else
                                .save_failed);
                            log.err("Studio save failed: {any}", .{err});
                        }
                    }
                }
            } else if (rl.isKeyDown(.left_shift) or rl.isKeyDown(.right_shift)) {
                if (export_controller.running == false) {
                    export_controller.start(G.current_slide, G.playback.visible_step, G.slideshow.slides.items.len);
                    G.current_slide = 0;
                }
            } else {
                if (export_controller.running == false) {
                    try export_controller.screenshot(G.slideshow_filp);
                }
            }
        }

        if (!text_input_active_at_frame_start and rl.isKeyPressed(.f3)) {
            frame_diagnostics.enabled = !frame_diagnostics.enabled;
            log.info("frame diagnostics {s}", .{if (frame_diagnostics.enabled) "enabled" else "disabled"});
        }

        // Finder/Open With arrives as a macOS open-documents Apple event,
        // while dropping onto the live window is exposed by Raylib on every
        // desktop platform. Both paths copy the transient OS string before
        // queuing the same ordinary slideshow reload.
        var external_open_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const external_open_len = MacOpenDocuments.take(&external_open_buffer);
        if (external_open_len > 0) {
            _ = queueExternalDeckOpen(
                external_open_buffer[0..external_open_len],
                text_input_active_at_frame_start,
                &studio_mode,
            );
        }
        if (rl.isFileDropped()) {
            const dropped = rl.loadDroppedFiles();
            defer rl.unloadDroppedFiles(dropped);
            var index: usize = 0;
            while (index < dropped.count) : (index += 1) {
                const raw_path = dropped.paths[index];
                if (raw_path == null) continue;
                const path = std.mem.span(raw_path);
                if (queueExternalDeckOpen(path, text_input_active_at_frame_start, &studio_mode)) break;
            }
        }

        // (re-) load slideshow
        if (G.slideshow_filp_to_load) |filp| {
            const studio_was_enabled = studio_mode.enabled;
            if (loadSlideshow(filp)) |_| {
                studio_history.clear();
                // Component clipboard entries carry source-order definition
                // provenance. Clear them only after the replacement commits;
                // a rejected hot reload leaves the complete authoring session
                // intact.
                studio_clipboard.clear();
                studio_bounds.clearRetainingCapacity();
                studio_mode = .{
                    .enabled = launch_studio or studio_was_enabled,
                    .ui_font = G.studio_ui_font,
                };
                is_pre_rendered = false;
            } else |err| {
                studio_mode.setNotice(.reload_failed);
                log.err("Slideshow reload rejected; current document preserved: {any}", .{err});
            }
        }

        if (is_pre_rendered == false) {
            if (G.source_len > 0) {
                const slideshow_filp = G.slideshow_filp orelse "untitled.sld";
                log.info("LOADED!!!", .{});
                log.debug("I AM GOING TO PRE-RENDER!", .{});
                const pre_render_started_at = rl.getTime();
                const rebuild_result: ?renderer.SlideshowRenderer.RebuildResult = G.slide_renderer.preRenderChanged(
                    G.slideshow,
                    slideshow_filp,
                ) catch |err| failed: {
                    // Keep the old graph live and retry next frame. Selective
                    // rebuilds are transactional, so a failed image/text/morph
                    // build cannot leave a half-updated deck on screen.
                    log.err("Pre-rendering failed: {any}", .{err});
                    break :failed null;
                };
                if (rebuild_result) |result| {
                    frame_diagnostics.recordPreRender(
                        rl.getTime() - pre_render_started_at,
                        G.slideshow_arena.queryCapacity(),
                        result,
                    );
                    const deck_has_crowd = slideshowHasCrowd(G.slideshow);
                    const host_is_usable = builtin.os.tag != .windows or crowd_options.host_explicit;
                    if (crowd_options.enabled and deck_has_crowd and !host_is_usable) {
                        log.err("Crowdplay on Windows requires --crowd-host=<LAN-IP>; server disabled", .{});
                    }
                    const wants_crowd = crowd_options.enabled and deck_has_crowd and host_is_usable;
                    var crowd_configured = false;
                    if (wants_crowd) {
                        if (crowd_runtime.configure(G.slideshow)) |_| {
                            crowd_configured = true;
                        } else |err| {
                            log.err("Crowdplay configuration failed; server disabled: {any}", .{err});
                            crowd_runtime.stop();
                        }
                    } else {
                        crowd_runtime.stop();
                    }
                    if (crowd_configured and !crowd_runtime.isRunning()) {
                        if (crowd_runtime.start(crowd_options.port, crowd_options.host)) |port| {
                            log.info("Crowdplay listening on port {d}; audience URL: {s}", .{ port, crowd_runtime.public_url.slice() });
                        } else |err| {
                            log.err("Crowdplay could not start: {any}", .{err});
                        }
                    }
                    if (G.slideshow.slides.items.len > 0) {
                        if (G.current_slide < 0 or G.current_slide >= G.slideshow.slides.items.len) G.current_slide = 0;
                        const now = rl.getTime();
                        G.playback.enterSlide(null, 0, 0, G.slide_renderer.transitionForSlide(G.current_slide), 1, now);
                    }
                    log.info("PRE-RENDERED {s} {d}/{d} slides", .{
                        @tagName(result.mode),
                        result.rebuilt_slide_count,
                        result.total_slide_count,
                    });
                    is_pre_rendered = true;
                }
            }
        }

        const now = rl.getTime();
        G.playback.settle(now);
        if (!export_controller.running and !studio_mode.capturesInput()) updateAutomaticReveal(now);
        const current_crowd_spec = crowdSpecForSlide(G.slideshow, G.current_slide);
        if (crowd_runtime.isRunning() and !export_controller.running) crowd_runtime.activate(current_crowd_spec);
        const presenter_controls_enabled = !export_controller.running and
            !studio_mode.capturesInput() and !presenter_overlay_captures_input;
        const presenter_pointer_enabled = presenter_controls_enabled and !laser_pointer.show;
        const presenter_drawing_enabled = presenter_controls_enabled and !laser_pointer.show;
        var presenter_commands_consumed: usize = 0;
        while (presenter_commands_consumed < 8) : (presenter_commands_consumed += 1) {
            const queued = presenter_runtime.takeCommand() orelse break;
            if (!presenter_controls_enabled) continue;
            switch (queued.command) {
                .previous => reversePresentation(now),
                .next => advancePresentation(now),
                .clear_drawing => {
                    presenter_runtime.clearDrawingInput();
                    remote_drawing.clear();
                    laser_pointer.clearDrawing();
                },
            }
        }
        if (remote_drawing_slide != G.current_slide) {
            presenter_runtime.clearDrawingInput();
            remote_drawing.clear();
            laser_pointer.clearDrawing();
            remote_drawing_slide = G.current_slide;
        }
        const remote_pointer: ?presenter.PointerSample = if (presenter_runtime.isRunning()) remote: {
            if (!presenter_pointer_enabled) {
                presenter_runtime.clearPointer();
                break :remote null;
            }
            break :remote presenter_runtime.activePointer();
        } else null;
        if (presenter_runtime.isRunning() and presenter_drawing_enabled) {
            var drawing_events_consumed: usize = 0;
            while (drawing_events_consumed < 64) : (drawing_events_consumed += 1) {
                const event = presenter_runtime.takeDrawing() orelse break;
                remote_drawing.apply(event) catch |err| log.err("Presenter drawing update failed: {any}", .{err});
            }
        } else {
            presenter_runtime.clearDrawingInput();
            remote_drawing.finishStroke();
        }
        publishPresenterState(
            &presenter_runtime,
            presenter_controls_enabled,
            presenter_pointer_enabled,
            presenter_drawing_enabled,
        );

        // render slide
        // G.slide_render_width = G.internal_render_size.x - ed_anim.current_size.x;
        // try G.slide_renderer.render(G.current_slide, slideAreaTL(), slideSizeInWindow(), G.internal_render_size);
        const internal_render_size: rl.Vector2 = .{ .x = 1920, .y = 1080 };
        if (!manual_fullscreen) {
            screenWidth = rl.getScreenWidth();
            screenHeight = rl.getScreenHeight();
        }
        const window_size: rl.Vector2 = .{ .x = @floatFromInt(screenWidth), .y = @floatFromInt(screenHeight) };
        const presentation_viewport: studio.Viewport = .{
            .slide_top_left = slideAreaTL(internal_render_size, window_size),
            .slide_size = slideSizeInWindow(internal_render_size, window_size),
            .logical_size = internal_render_size,
        };
        // Export and presentation retain the original edge-to-edge viewport.
        // Studio alone receives a docked frame whose permanent chrome is
        // outside the fitted 16:9 slide canvas.
        const studio_frame = studio_mode.layoutFrame(.{
            .x = 0,
            .y = 0,
            .width = window_size.x,
            .height = window_size.y,
        });
        const studio_viewport = if (studio_mode.capturesInput() and !export_controller.running)
            studio_frame.viewport
        else
            presentation_viewport;
        const slide_tl = studio_viewport.slide_top_left;
        const slide_size_in_window = studio_viewport.slide_size;

        var empty_studio_items: [0]slides.SlideItem = .{};
        var studio_items: []slides.SlideItem = empty_studio_items[0..];
        var current_slide: ?*slides.Slide = null;
        if (G.current_slide >= 0 and G.current_slide < G.slideshow.slides.items.len) {
            const current = G.slideshow.slides.items[@intCast(G.current_slide)];
            current_slide = current;
            studio_mode.setMorphStateCount(current.morph_states.items.len);
            if (studio_mode.capturesInput()) {
                if (studio_mode.active_morph_state) |state_index| {
                    if (state_index < current.morph_states.items.len) {
                        studio_items = current.morph_states.items[state_index].items.items;
                    }
                } else if (current.items) |*items| {
                    studio_items = items.items;
                }
            } else if (current.items) |*items| {
                studio_items = items.items;
            }
        }
        const studio_prepare_started_at = rl.getTime();
        const studio_render_fragment_count = try collectStudioBounds(
            &studio_bounds,
            &studio_render_bounds,
            gpa,
            G.current_slide,
            studio_mode.active_morph_state,
        );
        if (diagnostics_selection_pending) |item_id| {
            if (studio_mode.selectItemByIdOrSource(studio_items, item_id, .{})) {
                studio_mode.active_dock = .properties;
                studio_mode.inspector_panel = .properties;
            } else {
                log.warn("diagnostics could not select unique item id={s}", .{item_id});
            }
            diagnostics_selection_pending = null;
        }
        if (diagnostics_command_palette_pending) {
            studio_mode.openCommandPaletteForDiagnostics(studio_items);
            diagnostics_command_palette_pending = false;
        }
        if (diagnostics_precision_view_pending) {
            studio_mode.showPrecisionViewForDiagnostics();
            diagnostics_precision_view_pending = false;
        }
        if (diagnostics_find_slide_pending) |query| {
            if (!studio_mode.openSlideSearchForDiagnostics(query))
                log.warn("diagnostics could not open slide search for invalid query", .{});
            diagnostics_find_slide_pending = null;
        }
        if (rl.isWindowResized()) studio_mode.cancelActiveInteraction(studio_items);

        var frame_studio_catalog: ?studio_catalog.Catalog = null;
        var workspace_cache_rebuilt = false;
        var studio_workspace: studio.Workspace = .{};
        if (studio_mode.capturesInput()) {
            workspace_cache_rebuilt = try studio_workspace_cache.refreshDocument(
                G.source_revision,
                G.editor_memory[0..G.source_len],
                G.slideshow,
            );
            const item_insertion_offset = if (current_slide) |slide|
                studioItemInsertionOffset(slide, studio_mode.active_morph_state) catch slide.pos_in_editor
            else
                0;
            const slide_insertion_offset = if (current_slide) |slide|
                source_editor.slideEndOffset(G.editor_memory[0..G.source_len], slide.pos_in_editor) catch item_insertion_offset
            else
                item_insertion_offset;
            workspace_cache_rebuilt = (try studio_workspace_cache.refreshScene(
                if (current_slide != null and G.current_slide >= 0) @intCast(G.current_slide) else null,
                current_slide,
                item_insertion_offset,
                slide_insertion_offset,
            )) or workspace_cache_rebuilt;
            frame_studio_catalog = studio_workspace_cache.catalog;
            studio_workspace = .{
                .visible = true,
                .slides = studio_workspace_cache.slide_summaries.items,
                .current_slide = if (G.current_slide >= 0) @intCast(G.current_slide) else 0,
                .library = studio_workspace_cache.library_entries.items,
                .morph_states = studio_workspace_cache.morph_summaries.items,
                .new_deck = pristineUntitledDeck(),
                .undo_available = studio_history.undo_stack.items.len > 0,
                .redo_available = studio_history.redo_stack.items.len > 0,
                .clipboard_item_count = studio_clipboard.items.items.len,
            };
        }
        const composition_cache_builds_before = studio_composition_cache.rebuild_count;
        studio_mode.setCompositionContext(if (studio_mode.capturesInput() and current_slide != null)
            studio_composition_cache.resolve(
                G.source_revision,
                gpa,
                G.editor_memory[0..G.source_len],
                G.current_slide,
                current_slide.?,
                studio_mode.active_morph_state,
                studio_items,
                studio_mode,
            )
        else
            null);
        frame_diagnostics.recordStudioPrepare(
            rl.getTime() - studio_prepare_started_at,
            studio_workspace_cache.document_rebuild_count,
            studio_workspace_cache.scene_rebuild_count,
            studio_composition_cache.rebuild_count,
            workspace_cache_rebuilt or studio_composition_cache.rebuild_count != composition_cache_builds_before,
            G.slideshow.slides.items.len,
            studio_items.len,
            studio_render_fragment_count,
        );

        var semantic_to_apply: ?studio.SemanticCommand = null;
        var semantic_text: ?[]const u8 = null;
        var inline_field_to_finish: ?studio.InlineField = null;
        var inline_commit_completed = false;
        // false requests Undo, true requests Redo. Palette history commands
        // are applied after drawing, at the same safe graph-lifetime boundary
        // as their keyboard equivalents.
        var history_command_requested: ?bool = null;
        var studio_slide_to_select: ?usize = null;
        var source_graph_reparsed_this_frame = false;
        const prompt_was_active = property_prompt.active;
        if (prompt_was_active) {
            switch (property_prompt.updateFromRaylib()) {
                .none => {},
                .submitted => {
                    if (pending_save_as) {
                        if (saveUntitledEditorSourceAs(property_prompt.text())) |_| {
                            pending_save_as = false;
                            studio_mode.markSaved();
                            studio_mode.setNotice(.saved);
                            log.info("Studio deck saved as {s}", .{G.slideshow_filp.?});
                        } else |err| {
                            switch (err) {
                                error.InvalidStudioSavePath => property_prompt.rejectInvalidPath(),
                                error.PathAlreadyExists => property_prompt.rejectExistingPath(),
                                else => property_prompt.rejectSaveFailure(),
                            }
                            studio_mode.setNotice(.none);
                            log.err("Studio Save As failed: {any}", .{err});
                        }
                    } else {
                        semantic_to_apply = pending_semantic_command;
                        semantic_text = property_prompt.text();
                        pending_semantic_command = null;
                    }
                    window_close_seen = false;
                },
                .cancelled => {
                    pending_semantic_command = null;
                    pending_save_as = false;
                    window_close_seen = false;
                },
            }
        }

        const studio_command: ?studio.GeometryCommand = if (!export_controller.running and !prompt_was_active and !presenter_overlay_captures_input)
            studio_mode.updateWithWorkspaceFromRaylib(studio_items, studio_bounds.items, studio_viewport, studio_workspace)
        else
            null;
        if (diagnostics_command_tooltip and studio_mode.capturesInput() and !export_controller.running) {
            studio_mode.showCommandTooltipForDiagnostics(studio_viewport);
        }
        const studio_geometry_batch: ?studio.GeometryBatchCommand = studio_mode.takeGeometryBatch();
        if (!prompt_was_active) {
            if (studio_mode.takeSemanticCommand()) |command| {
                switch (command) {
                    .save_document => {
                        if (G.slideshow_filp == null) {
                            pending_save_as = true;
                            property_prompt.begin(.document_path, "untitled.sld");
                        } else if (saveEditorSource()) |_| {
                            studio_mode.markSaved();
                            studio_mode.setNotice(.saved);
                            log.info("Studio source saved", .{});
                        } else |err| {
                            studio_mode.setNotice(if (err == error.SourceChangedOnDisk)
                                .source_changed_on_disk
                            else
                                .save_failed);
                            log.err("Studio save failed: {any}", .{err});
                        }
                    },
                    .save_document_copy => {
                        if (G.slideshow_filp == null) {
                            pending_save_as = true;
                            property_prompt.begin(.document_path, "untitled.sld");
                        } else if (saveEditorSourceCopy()) |copy_path| {
                            studio_mode.markCopySaved();
                            log.info("Studio copy saved to {s}", .{copy_path});
                            gpa.free(copy_path);
                        } else |err| {
                            studio_mode.setNotice(.save_failed);
                            log.err("Studio Save Copy failed: {any}", .{err});
                        }
                    },
                    .undo => history_command_requested = false,
                    .redo => history_command_requested = true,
                    .edit_speaker_notes => {
                        pending_semantic_command = command;
                        property_prompt.begin(
                            .speaker_notes,
                            if (current_slide) |slide| slide.speaker_notes orelse "" else "",
                        );
                    },
                    .pair_presenter_phone => {
                        if (ensurePresenterCompanionRunning(&presenter_runtime, presenter_options)) {
                            presenter_pairing_visible = true;
                            studio_mode.setNotice(.none);
                        } else {
                            studio_mode.setNotice(.edit_failed);
                        }
                    },
                    .add_item => |add| switch (add.kind) {
                        .text => {
                            pending_semantic_command = command;
                            property_prompt.begin(.text, "Text");
                        },
                        .bullets => {
                            pending_semantic_command = command;
                            property_prompt.begin(.bullets, "- First item\n- Second item");
                        },
                        .image => {
                            pending_semantic_command = command;
                            property_prompt.begin(.image_path, "");
                        },
                        .shape => semantic_to_apply = command,
                    },
                    .edit_text => |target| {
                        const initial = studioItemByIdentity(studio_items, target.item_identity) orelse null;
                        const initial_text = if (initial) |item|
                            if (target.edit_scope == .shared_template)
                                if (item.sharedTemplateValues()) |shared| shared.text orelse "" else ""
                            else
                                item.text orelse ""
                        else
                            "";
                        pending_semantic_command = command;
                        property_prompt.begin(
                            if (target.edit_scope == .shared_template) .shared_text else .text,
                            initial_text,
                        );
                    },
                    .edit_numeric_geometry => |request| prompt: {
                        const item = studioItemByIdentity(studio_items, request.target.item_identity) orelse {
                            studio_mode.setNotice(.edit_failed);
                            break :prompt;
                        };
                        const geometry = if (request.target.edit_scope == .shared_template)
                            if (item.sharedTemplateValues()) |shared|
                                studio.Geometry{ .position = shared.position, .size = shared.size }
                            else
                                studio.itemGeometry(item.*, studio_bounds.items)
                        else
                            studio.itemGeometry(item.*, studio_bounds.items);
                        const value = switch (request.field) {
                            .x => geometry.position.x,
                            .y => geometry.position.y,
                            .width => geometry.size.x,
                            .height => geometry.size.y,
                        };
                        var initial_buffer: [64]u8 = undefined;
                        const initial = formatStudioFloat(&initial_buffer, value) catch "0";
                        pending_semantic_command = command;
                        property_prompt.begin(
                            switch (request.field) {
                                .x, .y => .coordinate,
                                .width, .height => .dimension,
                            },
                            initial,
                        );
                    },
                    .set_custom_foreground => |target| prompt: {
                        const item = studioItemByIdentity(studio_items, target.item_identity) orelse {
                            studio_mode.setNotice(.edit_failed);
                            break :prompt;
                        };
                        const color = if (target.edit_scope == .shared_template)
                            if (item.sharedTemplateValues()) |shared| shared.color else null
                        else
                            item.color;
                        var initial_buffer: [9]u8 = undefined;
                        pending_semantic_command = command;
                        property_prompt.begin(.color, if (color) |value| colorLiteral(&initial_buffer, value) else "#ffffffff");
                    },
                    .set_custom_background => |target| prompt: {
                        const item = studioItemByIdentity(studio_items, target.item_identity) orelse {
                            studio_mode.setNotice(.edit_failed);
                            break :prompt;
                        };
                        const color = if (target.edit_scope == .shared_template)
                            if (item.sharedTemplateValues()) |shared| shared.background_color else null
                        else
                            item.background_color;
                        var initial_buffer: [9]u8 = undefined;
                        pending_semantic_command = command;
                        property_prompt.begin(.color, if (color) |value| colorLiteral(&initial_buffer, value) else "#ffffffff");
                    },
                    .set_font_size => |target| prompt: {
                        const item = studioItemByIdentity(studio_items, target.item_identity) orelse {
                            studio_mode.setNotice(.edit_failed);
                            break :prompt;
                        };
                        const font_size = if (target.edit_scope == .shared_template)
                            if (item.sharedTemplateValues()) |shared| shared.font_size else null
                        else
                            item.fontSize;
                        var initial_buffer: [32]u8 = undefined;
                        const initial = if (font_size) |value|
                            std.fmt.bufPrint(&initial_buffer, "{d}", .{value}) catch ""
                        else
                            "";
                        pending_semantic_command = command;
                        property_prompt.begin(.font_size, initial);
                    },
                    .set_opacity => |target| prompt: {
                        const item = studioItemByIdentity(studio_items, target.item_identity) orelse {
                            studio_mode.setNotice(.edit_failed);
                            break :prompt;
                        };
                        const opacity = if (target.edit_scope == .shared_template)
                            if (item.sharedTemplateValues()) |shared| shared.opacity else item.opacity
                        else
                            item.opacity;
                        var initial_buffer: [64]u8 = undefined;
                        pending_semantic_command = command;
                        property_prompt.begin(.opacity, formatStudioFloat(&initial_buffer, opacity) catch "1");
                    },
                    .promote_to_reusable => |target| {
                        var suggested_name: [96]u8 = undefined;
                        const name = std.fmt.bufPrint(&suggested_name, "studio_item_{d}", .{target.source.line_number}) catch "studio_item";
                        pending_semantic_command = command;
                        property_prompt.begin(.reusable_name, name);
                    },
                    .promote_items_to_group => {
                        var suggested_name: [96]u8 = undefined;
                        const name = std.fmt.bufPrint(
                            &suggested_name,
                            "studio_group_{d}",
                            .{@as(usize, @intCast(@max(G.current_slide, 0))) + 1},
                        ) catch "studio_group";
                        pending_semantic_command = command;
                        property_prompt.begin(.reusable_name, name);
                    },
                    .promote_slide_to_template => |slide_index| {
                        var suggested_name: [96]u8 = undefined;
                        const name = std.fmt.bufPrint(&suggested_name, "slide_template_{d}", .{slide_index + 1}) catch "slide_template";
                        pending_semantic_command = command;
                        property_prompt.begin(.reusable_name, name);
                    },
                    .rename_morph_state => |state_index| {
                        if (state_index < studio_workspace_cache.morph_summaries.items.len) {
                            var suggested_name: [96]u8 = undefined;
                            const summary = studio_workspace_cache.morph_summaries.items[state_index];
                            const name = if (summary.label.len > 0)
                                summary.label
                            else
                                std.fmt.bufPrint(&suggested_name, "state_{d}", .{state_index + 1}) catch "state";
                            pending_semantic_command = command;
                            property_prompt.begin(.reusable_name, name);
                        } else {
                            studio_mode.setNotice(.edit_failed);
                        }
                    },
                    .rename_library_entry => |library_index| {
                        if (studioLibraryEntry(
                            frame_studio_catalog,
                            studio_workspace_cache.library_catalog_indices.items,
                            library_index,
                        )) |entry| {
                            pending_semantic_command = command;
                            property_prompt.begin(.reusable_name, entry.name);
                        } else {
                            studio_mode.setNotice(.edit_failed);
                        }
                    },
                    .delete_library_entry => semantic_to_apply = command,
                    .preview_library_cleanup => {
                        if (studio_catalog.cleanupSummary(
                            gpa,
                            G.editor_memory[0..G.source_len],
                        )) |summary| {
                            studio_mode.setLibraryCleanupPreview(
                                summary.removable_count,
                                summary.blocked_count,
                            );
                        } else |err| {
                            studio_mode.setNotice(switch (err) {
                                error.DynamicContextName => .structural_source_locked,
                                else => .edit_failed,
                            });
                            log.err("Studio Library cleanup preview failed: {any}", .{err});
                        }
                    },
                    .cleanup_library => semantic_to_apply = command,
                    .add_reusable => |add| {
                        if (add.library_entry_index) |library_index| {
                            if (studioLibraryName(
                                frame_studio_catalog,
                                studio_workspace_cache.library_catalog_indices.items,
                                library_index,
                                .element,
                            )) |name| {
                                semantic_to_apply = command;
                                semantic_text = name;
                            } else {
                                studio_mode.setNotice(.edit_failed);
                            }
                        } else {
                            pending_semantic_command = command;
                            property_prompt.begin(.reusable_name, "");
                        }
                    },
                    .new_slide_from_template => |library_index| {
                        if (studioLibraryName(
                            frame_studio_catalog,
                            studio_workspace_cache.library_catalog_indices.items,
                            library_index,
                            .slide,
                        )) |name| {
                            semantic_to_apply = command;
                            semantic_text = name;
                        } else {
                            studio_mode.setNotice(.edit_failed);
                        }
                    },
                    .add_reusable_group => semantic_to_apply = command,
                    .copy_items => |copy| {
                        if (current_slide) |slide| {
                            if (captureStudioClipboard(
                                &studio_clipboard,
                                copy,
                                slide,
                                studio_mode.active_morph_state,
                                studio_items,
                                studio_bounds.items,
                            )) |_| {
                                studio_mode.setNotice(.none);
                            } else |err| {
                                studio_mode.setNotice(switch (err) {
                                    error.UnsupportedClipboardItem,
                                    error.InvalidItemScene,
                                    => .copy_selection_unsupported,
                                    else => .edit_failed,
                                });
                                log.err("Studio copy failed: {any}", .{err});
                            }
                        } else {
                            studio_mode.setNotice(.edit_failed);
                        }
                    },
                    .commit_inline => |commit| {
                        // The borrowed command is resolved synchronously below,
                        // either by accepting it or by returning a field-local
                        // rejection. In both cases a close request deferred by
                        // the draft must be eligible for a fresh poll.
                        inline_commit_completed = true;
                        if (validateInlineCommit(commit)) |reason| {
                            studio_mode.rejectInlineCommit(commit.field, reason);
                            studio_mode.setNotice(.none);
                        } else if (!inlineCommitChangesValue(commit, studio_items, studio_bounds.items)) {
                            // Accepting a pristine field refreshes/traverses
                            // the editor without touching source or history.
                            studio_mode.acceptInlineCommit(commit.field);
                        } else {
                            const mapped = inlineSemanticEdit(commit);
                            inline_field_to_finish = commit.field;
                            semantic_to_apply = mapped.command;
                            semantic_text = mapped.value;
                        }
                    },
                    .select_slide => |slide_index| studio_slide_to_select = slide_index,
                    .select_morph_scene => {},
                    else => semantic_to_apply = command,
                }
            }
        }
        if (studio_mode.capturesInput() and laser_pointer.show) {
            laser_pointer.show = false;
            laser_pointer.clearDrawing();
            rl.showCursor();
        }
        var studio_previews: [renderer.max_item_geometry_previews]renderer.ItemGeometryPreview = undefined;
        var studio_preview_count: usize = 0;
        while (studio_preview_count < studio_previews.len) : (studio_preview_count += 1) {
            const preview = studio_mode.livePreviewAt(studio_preview_count) orelse break;
            studio_previews[studio_preview_count] = rendererPreviewFromLive(preview);
        }
        if (studio_preview_count == 0) {
            if (studio_geometry_batch) |batch| {
                for (batch.slice(), 0..) |command, index| {
                    studio_previews[index] = rendererPreviewFromCommand(command);
                }
                studio_preview_count = batch.count;
            } else if (studio_command) |command| {
                studio_previews[0] = rendererPreviewFromCommand(command);
                studio_preview_count = 1;
            }
        }
        G.slide_renderer.setItemGeometryPreviews(studio_previews[0..studio_preview_count]);

        const reveal_state: renderer.RevealState = if (export_controller.running)
            .{ .visible_through = G.slide_renderer.stepCount(G.current_slide) }
        else if (studio_mode.capturesInput())
            .{ .visible_through = G.slide_renderer.baseRevealStepCount(G.current_slide) + if (studio_mode.active_morph_state) |state| state + 1 else 0 }
        else
            .{
                .visible_through = G.playback.visible_step,
                .active_step = G.playback.active_step,
                .active_progress = G.playback.activeStepProgress(now),
            };
        const transition_state: renderer.TransitionState = if (export_controller.running or studio_mode.capturesInput())
            .{}
        else
            .{
                .previous_slide = G.playback.previous_slide,
                .previous_step = G.playback.previous_step,
                .spec = G.playback.transition,
                .progress = G.playback.transitionProgress(now),
                .direction = G.playback.direction,
            };
        const crowd_snapshot: ?crowdplay.Snapshot = if (crowd_runtime.isRunning()) crowd_runtime.snapshotFor(current_crowd_spec) else null;
        const previous_crowd_snapshot: ?crowdplay.Snapshot = if (crowd_runtime.isRunning()) blk: {
            const previous_slide = G.playback.previous_slide orelse break :blk null;
            break :blk crowd_runtime.snapshotFor(crowdSpecForSlide(G.slideshow, previous_slide));
        } else null;

        if (is_pre_rendered) {
            presenter_preview.capture(
                &presenter_runtime,
                G.slide_renderer,
                G.current_slide,
                reveal_state,
                transition_state,
                internal_render_size,
                crowd_snapshot,
                previous_crowd_snapshot,
                crowd_runtime.public_url.slice(),
                G.source_revision,
                now,
            ) catch |err| log.err("Presenter slide preview capture failed: {any}", .{err});
        } else if (!presenter_runtime.isRunning()) {
            presenter_preview.invalidate();
        }

        // Keep parsing, pre-rendering, workspace collection, and input updates
        // outside the acquired draw frame. Inspector commits can rebuild the
        // complete render graph; beginning the frame only when pixels are
        // ready prevents a partially held back buffer from presenting as a
        // redraw flash on macOS.
        {
            rl.beginDrawing();
            defer rl.endDrawing();
            rl.clearBackground(.blank);

            const clip_studio_canvas = studio_mode.capturesInput() and !export_controller.running;
            if (clip_studio_canvas) {
                const canvas = studio_viewport.canvasBounds();
                rl.beginScissorMode(
                    @intFromFloat(@floor(canvas.x)),
                    @intFromFloat(@floor(canvas.y)),
                    @intFromFloat(@ceil(canvas.width)),
                    @intFromFloat(@ceil(canvas.height)),
                );
            }
            try G.slide_renderer.render(
                G.current_slide,
                reveal_state,
                transition_state,
                slide_tl,
                slide_size_in_window,
                internal_render_size,
                crowd_snapshot,
                previous_crowd_snapshot,
                crowd_runtime.public_url.slice(),
            );
            if (clip_studio_canvas) rl.endScissorMode();
            if (!export_controller.running) {
                studio_mode.draw(studio_items, studio_bounds.items, studio_viewport);
                studio_mode.drawWorkspaceBackground(studio_viewport, studio_workspace);
                var preview_slot: usize = 0;
                while (studio_mode.visibleSlidePreview(studio_viewport, studio_workspace, preview_slot)) |preview| : (preview_slot += 1) {
                    rl.beginScissorMode(
                        @intFromFloat(preview.rect.x),
                        @intFromFloat(preview.rect.y),
                        @intFromFloat(preview.rect.width),
                        @intFromFloat(preview.rect.height),
                    );
                    G.slide_renderer.renderStudioThumbnail(
                        @intCast(preview.slide_index),
                        .{ .x = preview.rect.x, .y = preview.rect.y },
                        .{ .x = preview.rect.width, .y = preview.rect.height },
                        internal_render_size,
                    ) catch |err| log.err("Studio thumbnail render failed: {any}", .{err});
                    rl.endScissorMode();
                }
                studio_mode.drawWorkspaceOverlay(studio_viewport, studio_workspace);
            }
            if (beast_mode) rl.drawFPS(20, 20);

            if (export_controller.final_messagebox_message) |msg| {
                if (rg.messageBox(.{ .x = @floatFromInt(@divTrunc(screenWidth - 400, 2)), .y = 300, .width = 400, .height = 100 }, "Slideshow Export", msg, "OK") >= 0) {
                    gpa.free(msg);
                    export_controller.final_messagebox_message = null;
                }
            }
            if (!export_controller.running and !studio_mode.capturesInput()) {
                remote_drawing.draw(slide_tl, slide_size_in_window, laser_pointer.color);
            }
            if (remote_pointer) |sample| {
                rl.drawCircleV(presenterPointerPosition(sample, slide_tl, slide_size_in_window), laser_pointer.size, laser_pointer.color);
            }
            if (laser_pointer.show and !studio_mode.capturesInput()) try laser_pointer.draw();
            if (banner.show) banner.render();

            frame_diagnostics.draw(G.studio_ui_font, beast_mode, frameDiagnosticsPlacement(studio_viewport, slide_tl));
            property_prompt.draw(window_size);
            if (!export_controller.running) {
                // Discovery chrome is intentionally last: command search and
                // hover help must remain legible above diagnostics and every
                // persistent Studio surface.
                studio_mode.drawDiscoveryOverlay(studio_items, studio_viewport, studio_workspace);
            }
            if (presenter_pairing_visible and presenter_runtime.isRunning()) {
                drawPresenterPairingOverlay(
                    &presenter_qr,
                    &presenter_runtime,
                    presenter_runtime.phoneConnected(),
                    screenWidth,
                    screenHeight,
                );
            }
        }

        if (studio_geometry_batch) |batch| {
            if (applyStudioGeometryBatchEdit(&studio_history, batch, current_slide, studio_mode.active_morph_state, studio_items)) |_| {} else |err| {
                studio_mode.setNotice(.edit_failed);
                log.err("Studio group edit failed: {any}", .{err});
                reparseEditorSource() catch {};
            }
            studio_mode.dirty = editorSourceDirty();
            is_pre_rendered = false;
            source_graph_reparsed_this_frame = true;
            semantic_to_apply = null;
        } else if (studio_command) |command| {
            if (applyStudioGeometryEdit(&studio_history, command, current_slide, studio_mode.active_morph_state, studio_items)) |_| {} else |err| {
                studio_mode.setNotice(.edit_failed);
                log.err("Studio edit failed: {any}", .{err});
                reparseEditorSource() catch {};
            }
            studio_mode.dirty = editorSourceDirty();
            is_pre_rendered = false;
            source_graph_reparsed_this_frame = true;
            // Geometry and semantic commands are mutually exclusive in the
            // Studio update path. Keep that invariant explicit so a future UI
            // change cannot apply a second command through stale graph slices.
            semantic_to_apply = null;
        }

        if (studio_slide_to_select) |slide_index| {
            if (slide_index < G.slideshow.slides.items.len) {
                studio_mode.cancelActiveInteraction(studio_items);
                studio_mode.selected_identity = null;
                studio_mode.selected_source = null;
                studio_mode.active_morph_state = null;
                G.current_slide = @intCast(slide_index);
                G.playback.enterSlide(null, 0, 0, .{}, 1, rl.getTime());
                studio_mode.setNotice(.none);
            } else {
                studio_mode.setNotice(.edit_failed);
            }
        }

        if (semantic_to_apply) |command| {
            const customized_shared_property = semanticCommandTargetsCustomizedSharedProperty(command, studio_items);
            var selection_ids = StudioSelectionIds.init(gpa);
            defer selection_ids.deinit();
            var semantic_source_changed = false;
            if (applyStudioSemanticEdit(
                &studio_history,
                command,
                semantic_text,
                current_slide,
                studio_mode.active_morph_state,
                studio_items,
                studio_bounds.items,
                frame_studio_catalog,
                studio_workspace_cache.library_catalog_indices.items,
                &studio_clipboard,
                &selection_ids,
            )) |result| {
                semantic_source_changed = result.source_changed;
                if (result.source_changed) {
                    if (result.slide_index) |slide_index| {
                        studio_history.setLatestAfterSlide(slide_index);
                        G.current_slide = @intCast(slide_index);
                        studio_mode.active_morph_state = null;
                    }
                    if (result.morph_scene) |scene| {
                        studio_mode.active_morph_state = scene.active_state;
                    }
                    studio_mode.markSourceChanged();
                    var id_views: [studio.max_selection_items][]const u8 = undefined;
                    if (selection_ids.values.items.len > 0) {
                        for (selection_ids.values.items, 0..) |id, index| id_views[index] = id;
                    }
                    // Reparse invalidates every runtime identity. Rebind stable
                    // IDs when available and always clear the complete old
                    // group, including additional-selection state, when not.
                    if (!result.preserve_selection) {
                        studio_mode.selectItemsByIds(
                            currentStudioSceneItems(&studio_mode),
                            id_views[0..selection_ids.values.items.len],
                        );
                    }
                }
                if (inline_field_to_finish) |field| studio_mode.acceptInlineCommit(field);
                studio_mode.setNotice(if (customized_shared_property) .shared_template_customized else .none);
            } else |err| {
                const invalid_prompt_value = switch (err) {
                    error.InvalidStudioNumber,
                    error.InvalidStudioDimension,
                    error.InvalidStudioColor,
                    error.InvalidStudioFontSize,
                    error.InvalidStudioOpacity,
                    => true,
                    else => false,
                };
                if (inline_field_to_finish) |field| {
                    const reason = inlineErrorForSemanticFailure(field, err);
                    studio_mode.rejectInlineCommit(field, reason);
                    if (reason == .source_edit_failed) {
                        semantic_source_changed = true;
                        studio_mode.setNotice(switch (err) {
                            error.AmbiguousSlideTemplateLayout,
                            error.AmbiguousSlideTemplateDependency,
                            error.UnsafeSlideGlobalDirective,
                            error.UnsupportedSlideTemplateOverride,
                            error.UnsupportedSharedTemplateDeletion,
                            error.UnsupportedItemDuplication,
                            error.TemplateInstanceDuplicationUnsupported,
                            error.MorphItemDuplicationUnsupported,
                            error.AmbiguousItemLayer,
                            error.InvalidItemScene,
                            error.UnsupportedItemLayerMove,
                            error.UnsupportedClipboardItem,
                            error.UnsupportedBatchDeletion,
                            error.UnsupportedGroupPromotion,
                            error.UnsupportedGroupInstance,
                            error.UnsupportedGroupDetach,
                            => .structural_source_locked,
                            error.StudioClipboardEmpty => .clipboard_empty,
                            error.LockedLayerBarrier,
                            error.StudioItemLocked,
                            => .locked_item,
                            else => .edit_failed,
                        });
                        log.err("Studio inline edit failed: {any}", .{err});
                        reparseEditorSource() catch {};
                    } else {
                        studio_mode.setNotice(.none);
                    }
                } else if (invalid_prompt_value) {
                    property_prompt.rejectValue();
                    pending_semantic_command = command;
                    studio_mode.setNotice(.none);
                } else {
                    semantic_source_changed = true;
                    studio_mode.setNotice(switch (err) {
                        error.AmbiguousSlideTemplateLayout,
                        error.AmbiguousSlideTemplateDependency,
                        error.UnsafeSlideGlobalDirective,
                        error.UnsupportedSlideTemplateOverride,
                        error.UnsupportedSharedTemplateDeletion,
                        error.UnsupportedItemDuplication,
                        error.TemplateInstanceDuplicationUnsupported,
                        error.MorphItemDuplicationUnsupported,
                        error.AmbiguousItemLayer,
                        error.InvalidItemScene,
                        error.UnsupportedItemLayerMove,
                        error.UnsupportedClipboardItem,
                        error.UnsupportedBatchDeletion,
                        error.UnsupportedGroupPromotion,
                        error.UnsupportedGroupInstance,
                        => .structural_source_locked,
                        error.InvalidMorphStateOffset,
                        error.NoAdjacentMorphState,
                        => .morph_structure_locked,
                        error.InvalidMorphState,
                        error.StudioSourcePatchInvalid,
                        => if (semanticCommandIsMorphTimeline(command)) .morph_structure_locked else .edit_failed,
                        error.StudioClipboardEmpty => .clipboard_empty,
                        error.LockedLayerBarrier,
                        error.StudioItemLocked,
                        => .locked_item,
                        error.NoLocalPropertyOverride => .override_reset_unsupported,
                        error.UnsupportedComponentDetach,
                        error.UnsupportedGroupDetach,
                        error.ComponentDefinitionMismatch,
                        error.DetachedItemIdMismatch,
                        => .detach_instance_unsupported,
                        error.NameCollision => .library_name_conflict,
                        error.GroupNameCollision => .library_name_conflict,
                        error.SlideTemplateNameCollision => .library_name_conflict,
                        error.LiveUses => .library_entry_in_use,
                        error.UnsafeSlideTemplateDelete => .library_delete_unsupported,
                        error.UnsafeGroupDelete => .library_delete_unsupported,
                        error.NoCleanupCandidates => .library_cleanup_empty,
                        error.DynamicContextName => .structural_source_locked,
                        error.UnsupportedSlidePromotion => .slide_template_promotion_locked,
                        else => .edit_failed,
                    });
                    log.err("Studio property edit failed: {any}", .{err});
                    reparseEditorSource() catch {};
                }
            }
            if (semantic_source_changed) {
                studio_mode.dirty = editorSourceDirty();
                is_pre_rendered = false;
                source_graph_reparsed_this_frame = true;
            }
        }

        if (diagnostics_incremental_edit_pending) |slide_index| {
            if (is_pre_rendered and frame_diagnostics.pre_render_count > 0 and !source_graph_reparsed_this_frame) {
                diagnostics_incremental_edit_pending = null;
                if (applyDiagnosticIncrementalEdit(&studio_history, slide_index)) |_| {
                    studio_mode.markSourceChanged();
                    studio_mode.dirty = editorSourceDirty();
                    is_pre_rendered = false;
                    source_graph_reparsed_this_frame = true;
                    log.info("diagnostics applied incremental source edit to slide {d}", .{slide_index + 1});
                } else |err| {
                    log.err("diagnostics incremental edit failed for slide {d}: {any}", .{ slide_index + 1, err });
                }
            }
        }

        if (!diagnostics_capture_complete) {
            if (diagnostics_capture_path) |capture_path| {
                const expected_rebuild_events: usize = if (diagnostics_incremental_edit_slide != null) 2 else 1;
                const capture_ready = is_pre_rendered and
                    diagnosticCaptureGateIsOpen(io, diagnostics_capture_gate_path) and
                    diagnostics_incremental_edit_pending == null and
                    frame_diagnostics.pre_render_count >= expected_rebuild_events and
                    !source_graph_reparsed_this_frame;
                if (capture_ready) {
                    diagnostics_capture_stable_frames += 1;
                } else {
                    diagnostics_capture_stable_frames = 0;
                }
                if (diagnostics_capture_stable_frames >= diagnostics_capture_settle_frames) {
                    const capture_size = try captureDiagnosticScreenshot(capture_path, diagnostics_window_size);
                    if (diagnostics_report_path) |report_path| {
                        try writeDiagnosticCaptureReport(
                            io,
                            report_path,
                            diagnostics_capture_scenario,
                            frame_diagnostics,
                            capture_size,
                        );
                    }
                    diagnostics_capture_complete = true;
                    log.info("diagnostics captured {s} at {d}x{d}", .{
                        diagnostics_capture_scenario,
                        capture_size.width,
                        capture_size.height,
                    });
                }
            }
        }
        if (diagnostics_capture_complete and diagnostics_exit_after_capture) break;

        releaseDeferredInlineCloseLatch(
            &window_close_seen,
            inline_edit_active_at_frame_start,
            studio_mode.inlineEditActive(),
            inline_commit_completed,
        );
        if (command_palette_active_at_frame_start and !studio_mode.commandPaletteActive()) {
            // Native close flags can remain latched on macOS. Closing the
            // palette must make the deferred request observable again.
            window_close_seen = false;
        }

        const keyboard_history_requested = !presenter_overlay_captures_input and !property_prompt.active and !studio_mode.textEntryActive() and
            shortcutModifierDown() and rl.isKeyPressed(.z);
        if (!source_graph_reparsed_this_frame and studio_mode.capturesInput() and
            (keyboard_history_requested or history_command_requested != null))
        {
            // Undo owns the source graph. End a transient pointer gesture before
            // reparsing so it cannot later release stale pre-undo geometry.
            // Source history may remove an item and recycle its numeric
            // identity onto a following sibling. Clear the source-bound
            // selection before reparsing so undo/redo can never retarget it.
            studio_mode.clearSelection(studio_items);
            const redo_requested = history_command_requested orelse
                (rl.isKeyDown(.left_shift) or rl.isKeyDown(.right_shift));
            const changed = if (redo_requested)
                redoStudioEdit(&studio_history, &studio_mode)
            else
                undoStudioEdit(&studio_history, &studio_mode);
            if (changed) |did_change| {
                if (did_change) {
                    studio_mode.markSourceChanged();
                    studio_mode.setNotice(.none);
                    is_pre_rendered = false;
                }
            } else |err| {
                studio_mode.setNotice(.undo_failed);
                log.err("Studio undo/redo failed: {any}", .{err});
            }
            studio_mode.dirty = editorSourceDirty();
        }
        //
        // hanlde keys
        //
        if (!presenter_overlay_captures_input and !export_controller.running and !studio_mode.capturesInput() and (rl.isKeyPressed(.space) or rl.isKeyPressed(.right) or rl.isKeyPressed(.page_down) or (!laser_pointer.show and rl.isMouseButtonPressed(.left)))) {
            advancePresentation(rl.getTime());
        }

        if (!presenter_overlay_captures_input and !export_controller.running and !studio_mode.capturesInput() and (rl.isKeyPressed(.backspace) or rl.isKeyPressed(.left) or rl.isKeyPressed(.page_up))) {
            reversePresentation(rl.getTime());
        }

        if (!presenter_overlay_captures_input and crowd_runtime.isRunning() and !export_controller.running and !studio_mode.capturesInput() and rl.isKeyPressed(.o)) {
            _ = crowd_runtime.toggleOpen();
        }
        if (!presenter_overlay_captures_input and crowd_runtime.isRunning() and !export_controller.running and !studio_mode.capturesInput() and rl.isKeyPressed(.v)) {
            _ = crowd_runtime.toggleReveal();
        }
        if (!presenter_overlay_captures_input and crowd_runtime.isRunning() and !export_controller.running and !studio_mode.capturesInput() and rl.isKeyPressed(.r)) {
            _ = crowd_runtime.resetActive();
        }

        if (!presenter_overlay_captures_input and !property_prompt.active and !studio_mode.textEntryActive() and rl.isKeyPressed(.f)) {
            if (!manual_fullscreen) {
                windowed_width = screenWidth;
                windowed_height = screenHeight;
                const monitor = rl.getCurrentMonitor();
                rl.setWindowSize(rl.getMonitorWidth(monitor), rl.getMonitorHeight(monitor));
                if (rl.isKeyDown(.left_shift) or rl.isKeyDown(.right_shift)) {
                    screenWidth = rl.getMonitorWidth(monitor);
                    screenHeight = rl.getMonitorHeight(monitor);
                    rl.toggleFullscreen();
                } else {
                    screenWidth = rl.getRenderWidth();
                    screenHeight = rl.getRenderHeight();
                    rl.toggleBorderlessWindowed();
                }
                manual_fullscreen = true;
            } else {
                // rl.toggleFullscreen();
                screenWidth = windowed_width;
                screenHeight = windowed_height;
                if (rl.isKeyDown(.left_shift) or rl.isKeyDown(.right_shift)) {
                    rl.toggleFullscreen();
                } else {
                    rl.toggleBorderlessWindowed();
                }
                // rl.toggleFullscreen();
                rl.setWindowSize(windowed_width, windowed_height);
                manual_fullscreen = false;
            }
        }

        if (!presenter_overlay_captures_input and !property_prompt.active and !studio_mode.textEntryActive() and (rl.isKeyPressed(.q) or
            (rl.isKeyPressed(.escape) and !studio_active_at_frame_start and !presenter_pairing_visible_at_frame_start)))
        {
            if (readyToQuitPreservingEdits(&studio_mode)) break;
        }

        if (!presenter_overlay_captures_input and !export_controller.running and !studio_mode.capturesInput() and rl.isKeyPressed(.one)) {
            jumpToSlide(0, rl.getTime());
        }

        if (!presenter_overlay_captures_input and !export_controller.running and !studio_mode.capturesInput() and G.slideshow.slides.items.len > 0 and rl.isKeyPressed(.zero)) {
            jumpToSlide(@intCast(G.slideshow.slides.items.len - 1), rl.getTime());
        }

        if (!presenter_overlay_captures_input and !export_controller.running and !studio_mode.capturesInput() and G.slideshow.slides.items.len > 0 and rl.isKeyPressed(.g)) {
            if (rl.isKeyDown(.left_shift) or rl.isKeyDown(.right_shift)) {
                jumpToSlide(@intCast(G.slideshow.slides.items.len - 1), rl.getTime());
            } else {
                jumpToSlide(0, rl.getTime());
            }
        }

        if (!presenter_overlay_captures_input and !studio_mode.capturesInput() and !property_prompt.active and rl.isKeyPressed(.b)) {
            if (rl.isKeyDown(.left_shift) or rl.isKeyDown(.right_shift)) {
                banner.reset();
            } else {
                beast_mode = !beast_mode;
                if (beast_mode) {
                    rl.clearWindowState(.{ .vsync_hint = true });
                    rl.setTargetFPS(0);
                } else {
                    rl.setWindowState(.{ .vsync_hint = true });
                    rl.setTargetFPS(60);
                }
            }
        }

        if (!presenter_overlay_captures_input and !studio_mode.capturesInput() and rl.isKeyPressed(.l)) {
            if (rl.isKeyDown(.left_shift) or rl.isKeyDown(.right_shift)) {
                if (laser_pointer.show) {
                    laser_pointer.changeSize();
                }
            } else {
                laser_pointer.toggle();
                if (laser_pointer.show) {
                    rl.hideCursor();
                } else {
                    rl.showCursor();
                }
            }
        }

        if (!presenter_overlay_captures_input and !studio_mode.capturesInput() and rl.isKeyPressed(.c)) {
            laser_pointer.clearDrawing();
            presenter_runtime.clearDrawingInput();
            remote_drawing.clear();
        }

        // An external file change must never silently replace an unsaved
        // Studio document. Polling resumes after the buffer is saved.
        const do_reload = if (editorSourceDirty() or studio_mode.capturesInput()) false else checkAutoReload() catch false;
        if (do_reload) {
            G.slideshow_filp_to_load = G.slideshow_filp; // signal that we need to load
        }
    }
}

fn updateAutomaticReveal(now: f64) void {
    const next_step = G.playback.visible_step + 1;
    const step = G.slide_renderer.stepAt(G.current_slide, next_step) orelse return;
    if (G.playback.shouldAutoReveal(step, now)) {
        G.playback.reveal(next_step, step, now);
    }
}

fn shortcutModifierDown() bool {
    return rl.isKeyDown(.left_control) or rl.isKeyDown(.right_control) or
        rl.isKeyDown(.left_super) or rl.isKeyDown(.right_super);
}

fn advancePresentation(now: f64) void {
    G.playback.settle(now);
    // A repeated forward action must not skip over a step that is still
    // animating. If the active step is reversing, however, the same action
    // resumes it from the exact current frame.
    if (G.playback.active_step != null and !G.playback.active_reverse) return;
    const next_step = G.playback.visible_step + 1;
    if (G.slide_renderer.stepAt(G.current_slide, next_step)) |step| {
        G.playback.reveal(next_step, step, now);
        return;
    }

    const next_slide = G.current_slide + 1;
    if (next_slide < G.slideshow.slides.items.len) {
        moveToSlide(next_slide, 1, 0, now);
    }
}

fn reversePresentation(now: f64) void {
    G.playback.settle(now);
    // Symmetric with advancePresentation: allow changing direction, but do
    // not skip backward while an existing reverse is still in flight.
    if (G.playback.active_step != null and G.playback.active_reverse) return;
    if (G.playback.visible_step > 0) {
        const step_index = G.playback.visible_step;
        if (G.slide_renderer.stepAt(G.current_slide, step_index)) |step| {
            G.playback.hide(step_index, step, now);
        }
        return;
    }

    const previous_slide = G.current_slide - 1;
    if (previous_slide >= 0) {
        moveToSlide(previous_slide, -1, G.slide_renderer.stepCount(previous_slide), now);
    }
}

fn moveToSlide(target: i32, direction: i8, initial_step: usize, now: f64) void {
    if (target < 0 or target >= G.slideshow.slides.items.len or target == G.current_slide) return;
    const old_slide = G.current_slide;
    const old_step = G.playback.visible_step;
    const transition: animation.Transition = if (direction > 0)
        G.slide_renderer.transitionForSlide(target)
    else
        G.slide_renderer.transitionForSlide(old_slide);
    G.current_slide = target;
    G.playback.enterSlide(old_slide, old_step, initial_step, transition, direction, now);
}

fn jumpToSlide(target: i32, now: f64) void {
    if (target < 0 or target >= G.slideshow.slides.items.len) return;
    G.current_slide = target;
    G.playback.enterSlide(null, 0, 0, .{}, 1, now);
}

fn checkAutoReload() !bool {
    if (G.slideshow_filp) |filp| {
        if (filp.len > 0) {
            if (G.hot_reload_next_time <= rl.getTime()) {
                std.log.debug("Checking for auto-reload of `{s}`", .{filp});
                G.hot_reload_next_time += G.hot_reload_interval_seconds;
                const f = try std.Io.Dir.cwd().openFile(G.io, filp, .{});
                defer f.close(G.io);
                const x = try f.stat(G.io);
                if (G.hot_reload_last_stat) |last| {
                    if (x.mtime.nanoseconds != last.mtime.nanoseconds) {
                        std.log.debug("RELOAD {s}", .{filp});
                        return true;
                    }
                } else {
                    G.hot_reload_last_stat = x;
                }
            }
        }
    }
    return false;
}

fn isSlideshowDocumentPath(path: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.fs.path.extension(path), ".sld");
}

fn pristineUntitledCanBeReplaced() bool {
    return G.slideshow_filp == null and
        std.mem.eql(u8, G.editor_memory[0..G.source_len], pristine_untitled_source);
}

/// Copies a transient Finder/drop path into AppData and schedules the same
/// transactional load used by the command line and hot reload. A meaningful
/// unsaved Studio document is never replaced implicitly.
fn queueExternalDeckOpen(path: []const u8, text_input_active: bool, studio_mode: *studio.Studio) bool {
    if (!isSlideshowDocumentPath(path)) {
        studio_mode.setNotice(.open_requires_sld);
        log.warn("Ignored non-.sld document: {s}", .{path});
        return false;
    }
    if (text_input_active) {
        studio_mode.setNotice(.open_refused_editing);
        log.warn("Document open deferred/refused while a text field is active: {s}", .{path});
        return false;
    }
    if (editorSourceDirty() and !pristineUntitledCanBeReplaced()) {
        studio_mode.setNotice(.open_refused_dirty);
        log.warn("Document open refused because the current source has unsaved changes: {s}", .{path});
        return false;
    }
    if (G.slideshow_filp_to_load != null) return false;
    G.slideshow_filp_to_load = std.fmt.bufPrint(&G.slideshow_filp_to_load_buffer, "{s}", .{path}) catch {
        studio_mode.setNotice(.open_requires_sld);
        log.err("Document path is too long: {s}", .{path});
        return false;
    };
    log.info("Opening external deck {s}", .{path});
    return true;
}

test "external document filtering preserves CLI and desktop file semantics" {
    try std.testing.expect(isSlideshowDocumentPath("deck.sld"));
    try std.testing.expect(isSlideshowDocumentPath("/tmp/DECK.SLD"));
    try std.testing.expect(!isSlideshowDocumentPath("deck.txt"));
    try std.testing.expect(!isSlideshowDocumentPath("sld"));
}

/// A parser graph built beside the live application state. Its arena lives at
/// a stable heap address so every allocator retained by SlideShow and
/// ParserContext remains valid when ownership moves into AppData.
const ParsedSlideshowGraph = struct {
    backing_allocator: std.mem.Allocator,
    arena: ?*std.heap.ArenaAllocator,
    slideshow_allocator: std.mem.Allocator,
    slideshow: *SlideShow,
    parser_context: ?*parser.ParserContext,

    fn init(backing_allocator: std.mem.Allocator, source: []const u8) !ParsedSlideshowGraph {
        const arena = try backing_allocator.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(backing_allocator);
        errdefer {
            arena.deinit();
            backing_allocator.destroy(arena);
        }
        const slideshow_allocator = arena.allocator();
        const slideshow = try SlideShow.new(slideshow_allocator);
        const context = try parser.constructSlidesFromBuf(source, slideshow, slideshow_allocator);
        if (context.parser_errors.items.len != 0) {
            context.deinit();
            return error.StudioSourcePatchInvalid;
        }
        return .{
            .backing_allocator = backing_allocator,
            .arena = arena,
            .slideshow_allocator = slideshow_allocator,
            .slideshow = slideshow,
            .parser_context = context,
        };
    }

    fn deinit(self: *ParsedSlideshowGraph) void {
        if (self.parser_context) |context| context.deinit();
        self.parser_context = null;
        if (self.arena) |arena| {
            arena.deinit();
            self.backing_allocator.destroy(arena);
        }
        self.arena = null;
    }
};

test "staged parser rejection and allocation failure preserve the live graph" {
    const allocator = std.testing.allocator;
    var live = try ParsedSlideshowGraph.init(
        allocator,
        "@slide\n@box id=live x=10 y=20 text=Still here\n",
    );
    defer live.deinit();
    const live_slideshow = live.slideshow;
    const live_item = &live.slideshow.slides.items[0].items.?.items[0];
    try std.testing.expectEqualStrings("live", live_item.id.?);

    try std.testing.expectError(
        error.StudioSourcePatchInvalid,
        ParsedSlideshowGraph.init(allocator, "@slide\n@set missing x=99\n"),
    );
    try std.testing.expect(live.slideshow == live_slideshow);
    try std.testing.expectEqualStrings("Still here", live_item.text.?);

    var failing = std.testing.FailingAllocator.init(allocator, .{});
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(
        error.OutOfMemory,
        ParsedSlideshowGraph.init(failing.allocator(), "@slide\n@box id=new text=Nope\n"),
    );
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expect(live.slideshow == live_slideshow);
    try std.testing.expectEqualStrings("Still here", live_item.text.?);
}

const AppData = struct {
    allocator: std.mem.Allocator = undefined,
    io: std.Io = undefined,
    slideshow_arena: *std.heap.ArenaAllocator = undefined,
    slideshow_allocator: std.mem.Allocator = undefined,
    fonts: fonts.AvailableFonts = .{},
    /// Dedicated embedded UI face. Presentation font directives never replace
    /// this atlas, keeping Studio controls stable across decks.
    studio_ui_font: rl.Font = undefined,
    /// Projector-facing setup text scales independently from slide fonts and
    /// remains Calibri Light even when the deck replaces its presentation face.
    presenter_ui_font: rl.Font = undefined,
    editor_memory: []u8 = undefined,
    loaded_content: []u8 = undefined, // we will check for dirty editor against this
    source_len: usize = 0,
    loaded_len: usize = 0,
    /// Monotonic in-memory document generation. Studio caches key off this
    /// rather than rescanning up to 128 KiB of source every frame.
    source_revision: usize = 0,
    last_window_size: rl.Vector2 = .{ .x = 0.0, .y = 0.0 },
    content_window_size: rl.Vector2 = .{ .x = 0.0, .y = 0.0 },
    slide_renderer: *renderer.SlideshowRenderer = undefined,
    /// Owns parser-side storage borrowed by the live slide graph, including
    /// expanded `@let` directive lines. Keep it alive until the graph is
    /// replaced; destroying it immediately leaves item IDs/text as dangling
    /// slices even though the rendered slide itself still exists.
    parser_context: ?*parser.ParserContext = null,
    slideshow_filp_buffer: [std.fs.max_path_bytes]u8 = undefined,
    slideshow_filp_to_load_buffer: [std.fs.max_path_bytes]u8 = undefined,
    slideshow_filp: ?[]const u8 = null,
    slideshow_filp_to_load: ?[]const u8 = null,
    slideshow: *SlideShow = undefined,
    current_slide: i32 = 0,
    playback: playback.State = .{},
    hot_reload_next_time: f64 = 0.0,
    hot_reload_interval_seconds: f64 = 1.0,
    hot_reload_last_stat: ?std.Io.File.Stat = undefined,
    recovery_dir_buffer: [std.fs.max_path_bytes]u8 = undefined,
    recovery_dir: ?[]const u8 = null,

    fn init(self: *AppData, gpa: std.mem.Allocator, io: std.Io) !void {
        self.allocator = gpa;
        self.io = io;

        self.slideshow_arena = try gpa.create(std.heap.ArenaAllocator);
        self.slideshow_arena.* = std.heap.ArenaAllocator.init(gpa);
        errdefer {
            self.slideshow_arena.deinit();
            gpa.destroy(self.slideshow_arena);
        }
        self.slideshow_allocator = self.slideshow_arena.allocator();
        self.parser_context = null;

        self.fonts = try fonts.AvailableFonts.init(.{});
        errdefer self.fonts.deinit();
        self.studio_ui_font = try rl.loadFontFromMemory(
            ".ttf",
            studio_ui_font_data,
            32,
            fonts.default_fontchars[0..],
        );
        errdefer rl.unloadFont(self.studio_ui_font);
        rl.setTextureFilter(self.studio_ui_font.texture, .bilinear);
        self.presenter_ui_font = try rl.loadFontFromMemory(
            ".ttf",
            presenter_ui_font_data,
            64,
            fonts.default_fontchars[0..],
        );
        errdefer rl.unloadFont(self.presenter_ui_font);
        rl.setTextureFilter(self.presenter_ui_font.texture, .bilinear);
        self.slideshow = try SlideShow.new(self.slideshow_allocator);
        // The parser graph is arena-backed and replaced after every Studio
        // source edit. The renderer deliberately lives on the long-lived GPA
        // so unchanged rendered slides and cached textures can survive those
        // reparses and be replaced selectively.
        self.slide_renderer = try renderer.SlideshowRenderer.new(self.allocator, &self.fonts);
        self.playback.reset(rl.getTime());

        self.editor_memory = try self.allocator.alloc(u8, 128 * 1024);
        self.loaded_content = try self.allocator.alloc(u8, 128 * 1024);
        @memset(self.editor_memory, 0);
        @memset(self.loaded_content, 0);
    }

    fn deinit(self: *AppData) void {
        if (self.parser_context) |context| context.deinit();
        self.parser_context = null;
        self.slide_renderer.deinit();
        rl.unloadFont(self.presenter_ui_font);
        rl.unloadFont(self.studio_ui_font);
        self.fonts.deinit();
        self.allocator.free(self.editor_memory);
        self.allocator.free(self.loaded_content);
        self.slideshow_arena.deinit();
        self.allocator.destroy(self.slideshow_arena);
    }

    fn adoptParsedGraph(self: *AppData, replacement: *ParsedSlideshowGraph) void {
        if (self.parser_context) |context| context.deinit();
        self.slideshow_arena.deinit();
        self.allocator.destroy(self.slideshow_arena);

        self.slideshow_arena = replacement.arena.?;
        self.slideshow_allocator = replacement.slideshow_allocator;
        self.slideshow = replacement.slideshow;
        self.parser_context = replacement.parser_context;
        replacement.arena = null;
        replacement.parser_context = null;
    }

    fn noteSourceMutation(self: *AppData) void {
        self.source_revision +%= 1;
        // Keep zero as the never-observed/default generation so an overflow
        // cannot accidentally make a populated cache look pristine.
        if (self.source_revision == 0) self.source_revision = 1;
    }

    fn setRecoveryDirectory(self: *AppData, path: []const u8) void {
        const stored = std.fmt.bufPrint(&self.recovery_dir_buffer, "{s}", .{path}) catch {
            self.recovery_dir = null;
            return;
        };
        self.recovery_dir = stored;
    }
};

var G = AppData{};

var slicetocbuf: [1024]u8 = undefined;
fn sliceToC(input: []const u8) [:0]u8 {
    var input_cut = input;
    if (input.len > slicetocbuf.len) {
        input_cut = input[0 .. slicetocbuf.len - 1];
    }
    std.mem.copy(u8, slicetocbuf[0..], input_cut);
    slicetocbuf[input_cut.len] = 0;
    const xx = slicetocbuf[0 .. input_cut.len + 1];
    const yy = xx[0..input_cut.len :0];
    return yy;
}

fn loadSlideshow(filp: []const u8) !void {
    std.log.debug("LOAD {s}", .{filp});
    defer G.slideshow_filp_to_load = null;
    var staged_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const staged_path = try std.fmt.bufPrint(&staged_path_buffer, "{s}", .{filp});
    const file = try std.Io.Dir.cwd().openFile(G.io, staged_path, .{});
    defer file.close(G.io);
    const loaded_stat = try file.stat(G.io);

    var read_buffer: [4096]u8 = undefined;
    var file_reader = file.reader(G.io, &read_buffer);
    const input = try file_reader.interface.allocRemaining(G.allocator, .limited(G.editor_memory.len - 1));
    defer G.allocator.free(input);
    if (input.len >= G.editor_memory.len) return error.StudioSourceTooLarge;
    log.info("Read {d} bytes", .{input.len});

    var parsed = try ParsedSlideshowGraph.init(G.allocator, input);
    defer parsed.deinit();

    // Fonts and their renderer are GPU-backed, so stage a complete new set
    // while the old document remains drawable. A missing custom font or OOM
    // therefore cannot tear down the presentation currently on screen.
    var staged_fonts = try fonts.AvailableFonts.init(.{});
    var staged_fonts_owned = true;
    defer if (staged_fonts_owned) staged_fonts.deinit();
    if (parsed.parser_context.?.custom_fonts_present) {
        try staged_fonts.loadCustomFonts(parsed.parser_context.?.fontConfig, staged_path);
    }
    const staged_renderer = try renderer.SlideshowRenderer.new(G.allocator, &staged_fonts);
    var staged_renderer_owned = true;
    defer if (staged_renderer_owned) staged_renderer.deinit();

    // From here onward the commit is infallible. Destroy the old renderer
    // before its fonts, adopt the already-valid parser graph, and then publish
    // source/path/stat metadata together.
    G.slide_renderer.deinit();
    G.fonts.deinit();
    G.adoptParsedGraph(&parsed);
    G.fonts = staged_fonts;
    staged_fonts_owned = false;
    G.slide_renderer = staged_renderer;
    staged_renderer_owned = false;
    G.slide_renderer.fonts = &G.fonts;

    const old_source_len = G.source_len;
    const old_loaded_len = G.loaded_len;
    @memcpy(G.editor_memory[0..input.len], input);
    @memcpy(G.loaded_content[0..input.len], input);
    if (old_source_len > input.len) @memset(G.editor_memory[input.len..old_source_len], 0);
    if (old_loaded_len > input.len) @memset(G.loaded_content[input.len..old_loaded_len], 0);
    G.editor_memory[input.len] = 0;
    G.loaded_content[input.len] = 0;
    G.source_len = input.len;
    G.loaded_len = input.len;
    @memcpy(G.slideshow_filp_buffer[0..staged_path.len], staged_path);
    G.slideshow_filp = G.slideshow_filp_buffer[0..staged_path.len];
    G.hot_reload_last_stat = loaded_stat;
    G.current_slide = 0;
    G.playback.reset(rl.getTime());
    G.noteSourceMutation();
    log.info("Loaded {d} parser-clean slides from {s}", .{ G.slideshow.slides.items.len, staged_path });
}

fn reparseEditorSource() !void {
    const previous_slide = G.current_slide;
    var replacement = try ParsedSlideshowGraph.init(G.allocator, G.editor_memory[0..G.source_len]);
    defer replacement.deinit();
    G.adoptParsedGraph(&replacement);

    if (G.slideshow.slides.items.len == 0) {
        G.current_slide = 0;
    } else {
        G.current_slide = @min(previous_slide, @as(i32, @intCast(G.slideshow.slides.items.len - 1)));
    }
    G.playback.enterSlide(null, 0, 0, .{}, 1, rl.getTime());
}

fn initializeUntitledSlideshow() !void {
    @memcpy(G.editor_memory[0..pristine_untitled_source.len], pristine_untitled_source);
    G.editor_memory[pristine_untitled_source.len] = 0;
    G.source_len = pristine_untitled_source.len;
    G.loaded_len = 0;
    G.slideshow_filp = null;
    G.hot_reload_last_stat = null;
    G.noteSourceMutation();
    try reparseEditorSource();
}

fn appendDiagnosticDeckText(
    output: []u8,
    cursor: *usize,
    comptime format: []const u8,
    args: anytype,
) !void {
    if (cursor.* >= output.len) return error.DiagnosticDeckTooLarge;
    const rendered = std.fmt.bufPrint(output[cursor.*..], format, args) catch return error.DiagnosticDeckTooLarge;
    cursor.* += rendered.len;
}

fn diagnosticLargeDeckSource(output: []u8, slide_count: usize) ![]const u8 {
    if (slide_count == 0 or slide_count > 200) return error.InvalidDiagnosticSlideCount;
    var cursor: usize = 0;
    const definition_count: usize = 24;
    for (0..definition_count) |index| {
        try appendDiagnosticDeckText(
            output,
            &cursor,
            "@push perf_card_{d} w=220 h=76 fontsize=24 color=#dce8ffff bg=#17243cff text=Reusable {d}\n",
            .{ index, index },
        );
    }
    for (0..slide_count) |slide_index| {
        try appendDiagnosticDeckText(output, &cursor, "@slide\n", .{});
        try appendDiagnosticDeckText(
            output,
            &cursor,
            "@box id=title_{d} x=80 y=64 w=1300 h=90 fontsize=52 color=#f6f8ffff text=Performance slide {d}\n",
            .{ slide_index, slide_index + 1 },
        );
        for (0..5) |card_index| {
            const definition_index = (slide_index + card_index) % definition_count;
            try appendDiagnosticDeckText(
                output,
                &cursor,
                "@pop perf_card_{d} id=card_{d}_{d} x={d} y={d}\n",
                .{ definition_index, slide_index, card_index, 100 + card_index * 280, 250 + (card_index % 2) * 130 },
            );
        }
        try appendDiagnosticDeckText(
            output,
            &cursor,
            "@box id=footer_{d} x=80 y=940 fontsize=18 color=#8295b5ff text=Large-deck diagnostics · slide {d}\n",
            .{ slide_index, slide_index + 1 },
        );
        if (slide_index % 8 == 0) {
            try appendDiagnosticDeckText(
                output,
                &cursor,
                "@state(morph) name=focus_{d} duration=0.35\n@set title_{d} x=140 color=#55d9ffff\n",
                .{ slide_index, slide_index },
            );
        }
    }
    return output[0..cursor];
}

fn initializeDiagnosticLargeSlideshow(slide_count: usize) !void {
    const source = try diagnosticLargeDeckSource(G.editor_memory[0 .. G.editor_memory.len - 1], slide_count);
    G.editor_memory[source.len] = 0;
    G.source_len = source.len;
    G.loaded_len = 0;
    G.slideshow_filp = null;
    G.hot_reload_last_stat = null;
    G.noteSourceMutation();
    try reparseEditorSource();
}

test "large-deck diagnostics generate parser-clean reusable Studio stress data" {
    const allocator = std.testing.allocator;
    var source_buffer: [128 * 1024]u8 = undefined;
    const source = try diagnosticLargeDeckSource(&source_buffer, 160);
    try std.testing.expect(source.len < source_buffer.len);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const slideshow = try slides.SlideShow.new(arena.allocator());
    const parser_context = try parser.constructSlidesFromBuf(source, slideshow, arena.allocator());
    defer parser_context.deinit();
    try std.testing.expectEqual(@as(usize, 0), parser_context.parser_errors.items.len);
    try std.testing.expectEqual(@as(usize, 160), slideshow.slides.items.len);
    try std.testing.expectEqual(@as(usize, 1), slideshow.slides.items[0].morph_states.items.len);
    try std.testing.expectEqual(@as(usize, 0), slideshow.slides.items[1].morph_states.items.len);

    const catalog = try studio_catalog.discover(allocator, source);
    defer catalog.deinit();
    try std.testing.expectEqual(@as(usize, 24), catalog.entries.len);
}

fn pristineUntitledDeck() bool {
    return G.slideshow_filp == null and
        std.mem.eql(u8, G.editor_memory[0..G.source_len], pristine_untitled_source);
}

fn editorSourceDirty() bool {
    return G.source_len != G.loaded_len or
        !std.mem.eql(u8, G.editor_memory[0..G.source_len], G.loaded_content[0..G.loaded_len]);
}

fn sameSourceVersion(a: std.Io.File.Stat, b: std.Io.File.Stat) bool {
    return a.inode == b.inode and a.size == b.size and
        a.mtime.nanoseconds == b.mtime.nanoseconds and
        a.ctime.nanoseconds == b.ctime.nanoseconds;
}

fn writeSourceAtomically(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
    data: []const u8,
    expected: ?std.Io.File.Stat,
) !void {
    const permissions: std.Io.File.Permissions = if (dir.statFile(io, path, .{})) |stat|
        stat.permissions
    else |err| switch (err) {
        error.FileNotFound => .default_file,
        else => return err,
    };

    const Temporary = struct { path: []u8, file: std.Io.File };
    const temporary: Temporary = for (0..16) |_| {
        var nonce: u64 = undefined;
        io.random(std.mem.asBytes(&nonce));
        const candidate = try std.fmt.allocPrint(allocator, "{s}.rayslides-{x}.tmp", .{ path, nonce });
        const file = dir.createFile(io, candidate, .{
            .exclusive = true,
            .permissions = permissions,
        }) catch |err| switch (err) {
            error.PathAlreadyExists => {
                allocator.free(candidate);
                continue;
            },
            else => {
                allocator.free(candidate);
                return err;
            },
        };
        break .{ .path = candidate, .file = file };
    } else return error.CouldNotCreateUniqueTemporaryFile;
    defer allocator.free(temporary.path);
    errdefer dir.deleteFile(io, temporary.path) catch {};

    {
        defer temporary.file.close(io);
        try temporary.file.writeStreamingAll(io, data);
        try temporary.file.sync(io);
    }
    if (expected) |loaded_stat| {
        const current_stat = dir.statFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return error.SourceChangedOnDisk,
            else => return err,
        };
        if (!sameSourceVersion(current_stat, loaded_stat)) return error.SourceChangedOnDisk;
    }
    try dir.rename(temporary.path, dir, path, io);
}

fn writeEditorSourceAtomically(path: []const u8, expected: ?std.Io.File.Stat) !void {
    return writeSourceAtomically(
        G.allocator,
        G.io,
        std.Io.Dir.cwd(),
        path,
        G.editor_memory[0..G.source_len],
        expected,
    );
}

test "atomic Studio writer replaces expected source and rejects a conflict" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "deck.sld", .data = "old source\n" });

    const loaded = try tmp.dir.statFile(io, "deck.sld", .{});
    try writeSourceAtomically(allocator, io, tmp.dir, "deck.sld", "Studio source\n", loaded);
    const written = try tmp.dir.readFileAlloc(io, "deck.sld", allocator, .unlimited);
    defer allocator.free(written);
    try std.testing.expectEqualStrings("Studio source\n", written);

    const studio_version = try tmp.dir.statFile(io, "deck.sld", .{});
    try tmp.dir.writeFile(io, .{ .sub_path = "deck.sld", .data = "external edit\n" });
    try std.testing.expectError(
        error.SourceChangedOnDisk,
        writeSourceAtomically(allocator, io, tmp.dir, "deck.sld", "must not win\n", studio_version),
    );
    const preserved = try tmp.dir.readFileAlloc(io, "deck.sld", allocator, .unlimited);
    defer allocator.free(preserved);
    try std.testing.expectEqualStrings("external edit\n", preserved);
}

fn saveEditorSource() !void {
    const path = G.slideshow_filp orelse return error.NoSlideshowPath;
    const resolved_path = try std.Io.Dir.cwd().realPathFileAlloc(G.io, path, G.allocator);
    defer G.allocator.free(resolved_path);
    try writeEditorSourceAtomically(resolved_path, G.hot_reload_last_stat);
    @memcpy(G.loaded_content[0..G.source_len], G.editor_memory[0..G.source_len]);
    if (G.loaded_len > G.source_len) @memset(G.loaded_content[G.source_len..G.loaded_len], 0);
    G.loaded_len = G.source_len;

    const file = try std.Io.Dir.cwd().openFile(G.io, path, .{});
    defer file.close(G.io);
    G.hot_reload_last_stat = try file.stat(G.io);
}

fn writeRecoveryCopy(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
    source: []const u8,
) ![]u8 {
    const stem = if (std.mem.endsWith(u8, path, ".sld")) path[0 .. path.len - ".sld".len] else path;
    var sequence: usize = 1;
    const copy_path = while (sequence < 10_000) : (sequence += 1) {
        const candidate = if (sequence == 1)
            try std.fmt.allocPrint(allocator, "{s}.edited.sld", .{stem})
        else
            try std.fmt.allocPrint(allocator, "{s}.edited-{d}.sld", .{ stem, sequence });
        const reservation = dir.createFile(io, candidate, .{ .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => {
                allocator.free(candidate);
                continue;
            },
            else => {
                allocator.free(candidate);
                return err;
            },
        };
        reservation.close(io);
        break candidate;
    } else return error.TooManyEditedCopies;
    errdefer allocator.free(copy_path);
    errdefer dir.deleteFile(io, copy_path) catch {};
    try writeSourceAtomically(allocator, io, dir, copy_path, source, null);
    return copy_path;
}

fn writeRecoveryCopyInDirectory(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    recovery_dir: []const u8,
    source_name: []const u8,
    source: []const u8,
) ![]u8 {
    try dir.createDirPath(io, recovery_dir);
    const base_name = std.fs.path.basename(source_name);
    const recovery_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ recovery_dir, base_name });
    defer allocator.free(recovery_path);
    return writeRecoveryCopy(allocator, io, dir, recovery_path, source);
}

fn saveEditorSourceCopy() ![]u8 {
    const cwd = std.Io.Dir.cwd();
    const source = G.editor_memory[0..G.source_len];
    if (G.slideshow_filp) |path| {
        return writeRecoveryCopy(G.allocator, G.io, cwd, path, source) catch |primary_error| {
            const recovery_dir = G.recovery_dir orelse return primary_error;
            log.warn("Could not save beside {s}; using {s}: {any}", .{ path, recovery_dir, primary_error });
            return writeRecoveryCopyInDirectory(G.allocator, G.io, cwd, recovery_dir, path, source);
        };
    }
    if (G.recovery_dir) |recovery_dir| {
        return writeRecoveryCopyInDirectory(
            G.allocator,
            G.io,
            cwd,
            recovery_dir,
            "untitled.sld",
            source,
        );
    }
    // Preserve the historical terminal behavior on every platform: a direct
    // CLI launch with an untitled deck recovers into its working directory.
    return writeRecoveryCopy(G.allocator, G.io, cwd, "untitled.sld", source);
}

fn adoptEditorSourcePath(path: []const u8) !void {
    // Resolve every fallible filesystem operation before publishing the new
    // document identity. Save As can then delete the just-created file and
    // leave the untitled session intact if adoption fails.
    var staged_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const staged_path = try std.fmt.bufPrint(&staged_path_buffer, "{s}", .{path});
    const file = try std.Io.Dir.cwd().openFile(G.io, staged_path, .{});
    defer file.close(G.io);
    const stat = try file.stat(G.io);

    @memcpy(G.slideshow_filp_buffer[0..staged_path.len], staged_path);
    G.slideshow_filp = G.slideshow_filp_buffer[0..staged_path.len];
    @memcpy(G.loaded_content[0..G.source_len], G.editor_memory[0..G.source_len]);
    if (G.loaded_len > G.source_len) @memset(G.loaded_content[G.source_len..G.loaded_len], 0);
    G.loaded_len = G.source_len;
    G.hot_reload_last_stat = stat;
}

fn normalizeUntitledSavePath(allocator: std.mem.Allocator, raw_path: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, raw_path, " \t");
    if (trimmed.len == 0 or
        trimmed.len > std.fs.max_path_bytes - ".sld".len or
        !std.unicode.utf8ValidateSlice(trimmed) or
        std.mem.indexOfAny(u8, trimmed, "\x00\r\n") != null)
    {
        return error.InvalidStudioSavePath;
    }
    if (std.ascii.endsWithIgnoreCase(trimmed, ".sld")) return allocator.dupe(u8, trimmed);
    return std.fmt.allocPrint(allocator, "{s}.sld", .{trimmed});
}

fn writeNewSourceFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
    source: []const u8,
) !void {
    const reservation = try dir.createFile(io, path, .{ .exclusive = true });
    errdefer dir.deleteFile(io, path) catch {};
    const reserved_stat = blk: {
        defer reservation.close(io);
        break :blk try reservation.stat(io);
    };
    try writeSourceAtomically(allocator, io, dir, path, source, reserved_stat);
}

fn saveUntitledEditorSourceAs(raw_path: []const u8) !void {
    if (G.slideshow_filp != null) return error.SlideshowAlreadyNamed;
    const path = try normalizeUntitledSavePath(G.allocator, raw_path);
    defer G.allocator.free(path);

    try writeNewSourceFile(
        G.allocator,
        G.io,
        std.Io.Dir.cwd(),
        path,
        G.editor_memory[0..G.source_len],
    );
    errdefer std.Io.Dir.cwd().deleteFile(G.io, path) catch {};
    try adoptEditorSourcePath(path);
}

test "untitled Save As normalizes a safe explicit sld path" {
    const allocator = std.testing.allocator;
    const appended = try normalizeUntitledSavePath(allocator, "  my-talk  ");
    defer allocator.free(appended);
    try std.testing.expectEqualStrings("my-talk.sld", appended);

    const preserved = try normalizeUntitledSavePath(allocator, "decks/keynote.SLD");
    defer allocator.free(preserved);
    try std.testing.expectEqualStrings("decks/keynote.SLD", preserved);

    try std.testing.expectError(error.InvalidStudioSavePath, normalizeUntitledSavePath(allocator, " \t"));
    try std.testing.expectError(error.InvalidStudioSavePath, normalizeUntitledSavePath(allocator, "bad\nname"));
    try std.testing.expectError(error.InvalidStudioSavePath, normalizeUntitledSavePath(allocator, "bad\x00name"));
}

test "untitled Save As creates once and never overwrites an existing deck" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "taken.sld", .data = "keep me\n" });
    try std.testing.expectError(error.PathAlreadyExists, writeNewSourceFile(
        allocator,
        io,
        tmp.dir,
        "taken.sld",
        "replacement\n",
    ));
    const preserved = try tmp.dir.readFileAlloc(io, "taken.sld", allocator, .unlimited);
    defer allocator.free(preserved);
    try std.testing.expectEqualStrings("keep me\n", preserved);

    try writeNewSourceFile(allocator, io, tmp.dir, "new.sld", "@slide\n");
    const created = try tmp.dir.readFileAlloc(io, "new.sld", allocator, .unlimited);
    defer allocator.free(created);
    try std.testing.expectEqualStrings("@slide\n", created);
}

test "untitled Save As removes its reservation when the atomic writer fails" {
    const backing_allocator = std.testing.allocator;
    var failing = std.testing.FailingAllocator.init(backing_allocator, .{});
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, writeNewSourceFile(
        failing.allocator(),
        io,
        tmp.dir,
        "retryable.sld",
        "@slide\n",
    ));
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "retryable.sld", .{}));
}

test "recovery copies are unique and preserve every source byte" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source = "\xEF\xBB\xBF@slide\r\n@box text=Unsaved · ä\r\n";

    const first = try writeRecoveryCopy(allocator, io, tmp.dir, "deck.sld", source);
    defer allocator.free(first);
    const second = try writeRecoveryCopy(allocator, io, tmp.dir, "deck.sld", source);
    defer allocator.free(second);
    try std.testing.expectEqualStrings("deck.edited.sld", first);
    try std.testing.expectEqualStrings("deck.edited-2.sld", second);

    const first_source = try tmp.dir.readFileAlloc(io, first, allocator, .unlimited);
    defer allocator.free(first_source);
    const second_source = try tmp.dir.readFileAlloc(io, second, allocator, .unlimited);
    defer allocator.free(second_source);
    try std.testing.expectEqualStrings(source, first_source);
    try std.testing.expectEqualStrings(source, second_source);
}

test "configured recovery directory is created and uses only the deck basename" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const recovery = try writeRecoveryCopyInDirectory(
        allocator,
        io,
        tmp.dir,
        "Application Support/Rayslides/Recovery",
        "/read-only/talk.sld",
        "@slide\n",
    );
    defer allocator.free(recovery);
    try std.testing.expectEqualStrings("Application Support/Rayslides/Recovery/talk.edited.sld", recovery);
    const contents = try tmp.dir.readFileAlloc(io, recovery, allocator, .unlimited);
    defer allocator.free(contents);
    try std.testing.expectEqualStrings("@slide\n", contents);
}

/// Quitting should never turn the in-memory source buffer into a data-loss
/// trap. A unique edit copy is the safest automatic fallback: it preserves the
/// original file and does not require a modal dialog during a window-close
/// event. Returning false keeps the app open when recovery itself fails.
fn readyToQuitPreservingEdits(studio_mode: *studio.Studio) bool {
    if (!editorSourceDirty()) return true;
    if (studio_mode.copy_is_current) return true;
    if (saveEditorSourceCopy()) |copy_path| {
        log.warn("Unsaved Studio changes recovered to {s}", .{copy_path});
        G.allocator.free(copy_path);
        return true;
    } else |err| {
        studio_mode.setNotice(.save_failed);
        log.err("Could not preserve unsaved Studio changes; quit cancelled: {any}", .{err});
        return false;
    }
}

fn replaceEditorSource(source: []const u8) !void {
    if (source.len >= G.editor_memory.len) return error.StudioSourceTooLarge;
    const old_len = G.source_len;
    @memcpy(G.editor_memory[0..source.len], source);
    if (old_len > source.len) @memset(G.editor_memory[source.len..old_len], 0);
    G.editor_memory[source.len] = 0;
    G.source_len = source.len;
    G.noteSourceMutation();
}

fn studioItemByIdentity(items: []const slides.SlideItem, identity: usize) ?*const slides.SlideItem {
    for (items) |*item| if (item.identity == identity) return item;
    return null;
}

fn inheritedPropertyForInlineField(field: studio.InlineField) source_editor.InheritedProperty {
    return switch (field) {
        .text => .text,
        .x => .x,
        .y => .y,
        .width => .w,
        .height => .h,
        .foreground => .color,
        .background => .bg,
        .font_size => .fontsize,
        .opacity => .opacity,
    };
}

fn studioPropertyOverrides(
    source_overrides: source_editor.InheritedPropertyOverrides,
) studio.PropertyOverrideSet {
    var result: studio.PropertyOverrideSet = .{};
    const fields = [_]studio.InlineField{
        .text,
        .x,
        .y,
        .width,
        .height,
        .foreground,
        .background,
        .font_size,
        .opacity,
    };
    for (fields) |field| {
        if (source_overrides.contains(inheritedPropertyForInlineField(field))) result.set(field);
    }
    return result;
}

fn studioResetOwner(
    source: []const u8,
    slide: *const slides.Slide,
    morph_state: ?usize,
    item: *const slides.SlideItem,
) !source_editor.MutationOwner {
    const id = item.id orelse return error.NoLocalPropertyOverride;
    if (morph_state) |state_index| {
        if (state_index >= slide.morph_states.items.len or
            itemBornInMorphState(slide, state_index, item) or
            item.state_source == null or item.state_source_state == null or
            item.state_source_state.? != state_index)
        {
            return error.NoLocalPropertyOverride;
        }
        return .{ .morph_state = .{
            .state_offset = slide.morph_states.items[state_index].source.line_offset,
            .effective_mutation_offset = item.state_source.?.line_offset,
        } };
    }

    return switch (item.source.scope) {
        .slide_template => if (item.instance_source) |instance_source|
            .{ .template_instance = .{
                .slide_offset = slide.pos_in_editor,
                .effective_mutation_offset = instance_source.line_offset,
            } }
        else
            error.NoLocalPropertyOverride,
        .component_instance => blk: {
            const info = try source_editor.inspectComponentInstance(source, item.source.line_offset);
            if (!std.mem.eql(u8, info.effective_id, id)) return error.DetachedItemIdMismatch;
            break :blk .{ .component_instance = .{
                .instance_offset = item.source.line_offset,
                .expected_definition_offset = info.definition_offset,
            } };
        },
        else => error.NoLocalPropertyOverride,
    };
}

fn studioReusableKind(item: *const slides.SlideItem) studio.ReusableInstanceKind {
    return switch (item.source.scope) {
        .component_instance => .component,
        .group_instance_member => .group,
        .slide_template => .slide_template,
        else => .none,
    };
}

/// Build a fresh, source-validated capability snapshot for the selected
/// object. Studio never guesses reset/detach ownership from rendered values;
/// every affordance comes from this exact slide/state/source scan.
fn studioCompositionContext(
    allocator: std.mem.Allocator,
    source: []const u8,
    slide: *const slides.Slide,
    morph_state: ?usize,
    items: []const slides.SlideItem,
    studio_state: studio.Studio,
) ?studio.CompositionContext {
    if (studio_state.selectionCount() != 1) return null;
    const identity = studio_state.selectedIdentityAt(0) orelse return null;
    const item = studioItemByIdentity(items, identity) orelse return null;
    const kind = studioReusableKind(item);
    var context: studio.CompositionContext = .{
        .item_identity = identity,
        .selection_source = item.effectiveSource(),
        .kind = kind,
        .detach_block = if (kind == .none) .not_instance else .dependent_structure,
    };

    if (item.id != null) {
        if (studioResetOwner(source, slide, morph_state, item)) |owner| {
            if (source_editor.inheritedPropertyOverrides(source, owner, item.id.?)) |overrides| {
                context.local_overrides = studioPropertyOverrides(overrides);
                if (!context.local_overrides.empty() and item.effectiveSource().patchable) {
                    context.resettable_overrides = context.local_overrides;
                    context.reset_target = .{
                        .item_identity = identity,
                        .source = item.effectiveSource(),
                        .edit_scope = if (morph_state != null)
                            .direct
                        else if (item.source.scope == .slide_template)
                            .local_instance
                        else
                            .direct,
                    };
                }
            } else |_| {}
        } else |_| {}
    }

    if (kind == .component) {
        if (morph_state != null) {
            context.detach_block = .morph_scene;
        } else if (!item.source.patchable) {
            context.detach_block = .generated_source;
        } else if (source_editor.inspectComponentInstanceForDetach(source, item.source.line_offset)) |info| {
            if (item.id != null and std.mem.eql(u8, item.id.?, info.effective_id)) {
                context.detach_target = .{
                    .item_identity = identity,
                    .source = item.source,
                    .edit_scope = .direct,
                };
                context.detach_block = .none;
            } else {
                context.detach_block = .ambiguous_instance;
            }
        } else |_| {
            context.detach_block = .dependent_structure;
        }
    } else if (kind == .group) {
        if (morph_state != null) {
            context.detach_block = .morph_scene;
        } else if (!item.source.patchable) {
            context.detach_block = .generated_source;
        } else if (source_editor.inspectReusableGroupInstance(
            allocator,
            source,
            item.source.line_offset,
        )) |info| {
            if (info.member_count > 0 and info.member_count <= studio.max_selection_items) {
                context.detach_target = .{
                    .item_identity = identity,
                    .source = item.source,
                    .edit_scope = .direct,
                };
                context.detach_block = .none;
            } else {
                context.detach_block = .ambiguous_instance;
            }
        } else |_| {
            context.detach_block = .dependent_structure;
        }
    } else if (kind == .slide_template and morph_state != null) {
        context.detach_block = .morph_scene;
    }
    return context;
}

test "Studio composition capabilities expose exact component overrides and safe detach" {
    const allocator = std.testing.allocator;
    const source =
        "@push card x=10 y=20 w=300 h=80 fontsize=40 color=#112233ff text=Shared\n" ++
        "@slide\n" ++
        "@pop card id=hero x=120 text=Local\n" ++
        "@slide\n";
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const deck = try slides.SlideShow.new(arena.allocator());
    const parser_context = try parser.constructSlidesFromBuf(source, deck, arena.allocator());
    defer parser_context.deinit();
    try std.testing.expectEqual(@as(usize, 0), parser_context.parser_errors.items.len);

    const slide = deck.slides.items[0];
    const items = slide.items.?.items;
    var studio_state: studio.Studio = .{
        .enabled = true,
        .selected_identity = items[0].identity,
        .selected_source = items[0].source,
    };
    const context = studioCompositionContext(allocator, source, slide, null, items, studio_state).?;
    try std.testing.expectEqual(studio.ReusableInstanceKind.component, context.kind);
    try std.testing.expect(context.local_overrides.contains(.x));
    try std.testing.expect(context.local_overrides.contains(.text));
    try std.testing.expect(!context.local_overrides.contains(.foreground));
    try std.testing.expect(context.resettable_overrides.contains(.x));
    try std.testing.expect(context.reset_target != null);
    try std.testing.expect(context.detach_target != null);
    try std.testing.expectEqual(studio.CompositionBlockReason.none, context.detach_block);

    var capability_cache: StudioCompositionCache = .{};
    const cached = capability_cache.resolve(7, allocator, source, 0, slide, null, items, studio_state).?;
    try std.testing.expect(cached.local_overrides.contains(.x));
    _ = capability_cache.resolve(7, allocator, source, 0, slide, null, items, studio_state);
    try std.testing.expectEqual(@as(usize, 1), capability_cache.rebuild_count);

    studio_state.additional_selection_count = 1;
    try std.testing.expect(studioCompositionContext(allocator, source, slide, null, items, studio_state) == null);
    try std.testing.expect(capability_cache.resolve(7, allocator, source, 0, slide, null, items, studio_state) == null);
    try std.testing.expectEqual(@as(usize, 2), capability_cache.rebuild_count);
}

test "Studio composition capabilities authorize an exact reusable group detach" {
    const allocator = std.testing.allocator;
    const source =
        "@pushgroup feature\n" ++
        "@box id=title x=100 y=100 text=Title\n" ++
        "@box id=art x=900 y=100 w=400 h=300 color=#223344ff\n" ++
        "@endgroup\n" ++
        "@slide\n" ++
        "@popgroup feature id=hero\n";
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const deck = try slides.SlideShow.new(arena.allocator());
    const parser_context = try parser.constructSlidesFromBuf(source, deck, arena.allocator());
    defer parser_context.deinit();
    try std.testing.expectEqual(@as(usize, 0), parser_context.parser_errors.items.len);

    const slide = deck.slides.items[0];
    const items = slide.items.?.items;
    try std.testing.expectEqual(@as(usize, 2), items.len);
    const studio_state: studio.Studio = .{
        .enabled = true,
        .selected_identity = items[1].identity,
        .selected_source = items[1].source,
    };
    const context = studioCompositionContext(allocator, source, slide, null, items, studio_state).?;
    try std.testing.expectEqual(studio.ReusableInstanceKind.group, context.kind);
    try std.testing.expectEqual(studio.CompositionBlockReason.none, context.detach_block);
    try std.testing.expect(context.detach_target != null);
    try std.testing.expectEqual(items[1].source.line_offset, context.detach_target.?.source.line_offset);
    try std.testing.expectEqual(@as(u16, 0), context.local_overrides.bits);
}

test "Studio component materialization preserves effective box semantics" {
    const allocator = std.testing.allocator;
    const source =
        "@push card x=10 y=20 w=300 h=80 fontsize=40 color=#112233ff bg=#01020304 " ++
        "line_height=1.2 underline_width=2 bullet_color=#aabbccff bullet_symbol=• " ++
        "shadow=#101112ff shadow_x=3 shadow_y=4 opacity=0.75 visible=false locked=true text=Shared\n" ++
        "@slide\n" ++
        "@anim(fade) duration=0.2\n" ++
        "@pop card id=hero x=120 text=Local\n" ++
        "@slide\n";
    var before_arena = std.heap.ArenaAllocator.init(allocator);
    defer before_arena.deinit();
    const before_deck = try slides.SlideShow.new(before_arena.allocator());
    const before_context = try parser.constructSlidesFromBuf(source, before_deck, before_arena.allocator());
    defer before_context.deinit();
    try std.testing.expectEqual(@as(usize, 0), before_context.parser_errors.items.len);
    const before = before_deck.slides.items[0].items.?.items[0];

    const snippet = try materializeStudioItem(allocator, &before);
    defer allocator.free(snippet);
    const direct_source = try std.fmt.allocPrint(allocator, "@slide\n{s}\n", .{snippet});
    defer allocator.free(direct_source);
    var after_arena = std.heap.ArenaAllocator.init(allocator);
    defer after_arena.deinit();
    const after_deck = try slides.SlideShow.new(after_arena.allocator());
    const after_context = try parser.constructSlidesFromBuf(direct_source, after_deck, after_arena.allocator());
    defer after_context.deinit();
    try std.testing.expectEqual(@as(usize, 0), after_context.parser_errors.items.len);
    const after = after_deck.slides.items[0].items.?.items[0];

    try std.testing.expectEqual(slides.SourceScope.direct, after.source.scope);
    try std.testing.expectEqualStrings(before.id.?, after.id.?);
    try std.testing.expectEqualStrings(before.text.?, after.text.?);
    try std.testing.expectEqual(before.position, after.position);
    try std.testing.expectEqual(before.size, after.size);
    try std.testing.expectEqual(before.fontSize, after.fontSize);
    try std.testing.expectEqual(before.color, after.color);
    try std.testing.expectEqual(before.background_color, after.background_color);
    try std.testing.expectEqual(before.line_height_factor, after.line_height_factor);
    try std.testing.expectEqual(before.underline_width, after.underline_width);
    try std.testing.expectEqual(before.bullet_color, after.bullet_color);
    try std.testing.expectEqualStrings(before.bullet_symbol.?, after.bullet_symbol.?);
    try std.testing.expectEqual(before.text_shadow, after.text_shadow);
    try std.testing.expectApproxEqAbs(before.opacity, after.opacity, 0.0001);
    try std.testing.expectEqual(before.visible, after.visible);
    try std.testing.expectEqual(before.locked, after.locked);
    try std.testing.expectEqual(before.animation, after.animation);
}

fn semanticCommandTargetsCustomizedSharedProperty(command: studio.SemanticCommand, items: []const slides.SlideItem) bool {
    if (command == .set_locked) {
        for (command.set_locked.slice()) |target| {
            if (target.edit_scope != .shared_template) continue;
            const item = studioItemByIdentity(items, target.item_identity) orelse continue;
            if (item.instance_source != null) return true;
        }
        return false;
    }
    if (command == .set_visible) {
        for (command.set_visible.slice()) |target| {
            if (target.edit_scope != .shared_template) continue;
            const item = studioItemByIdentity(items, target.item_identity) orelse continue;
            if (item.instance_source != null) return true;
        }
        return false;
    }
    const target: studio.CommandTarget = switch (command) {
        .edit_text => |value| value,
        .edit_numeric_geometry => |value| value.target,
        .set_foreground, .set_background => |value| value.target,
        .set_custom_foreground,
        .set_custom_background,
        .set_font_size,
        .set_opacity,
        .clear_background,
        => |value| value,
        else => return false,
    };
    if (target.edit_scope != .shared_template) return false;
    const item = studioItemByIdentity(items, target.item_identity) orelse return false;
    return item.instance_source != null;
}

fn semanticCommandIsMorphTimeline(command: studio.SemanticCommand) bool {
    return switch (command) {
        .add_morph_state,
        .duplicate_morph_state,
        .rename_morph_state,
        .delete_morph_state,
        .move_morph_state,
        => true,
        else => false,
    };
}

fn layerCommandSelects(command: studio.LayerCommand, identity: usize) bool {
    for (command.slice()) |target| {
        if (target.item_identity == identity) return true;
    }
    return false;
}

/// A locked item is a structural barrier as well as an interaction guard.
/// Refuse the whole batch when its requested paint-order move would cross one.
fn layerCommandCrossesLocked(command: studio.LayerCommand, items: []const slides.SlideItem) bool {
    if (command.count == 0) return false;
    switch (command.action) {
        .front => {
            var seen_selected = false;
            for (items) |item| {
                if (layerCommandSelects(command, item.identity)) seen_selected = true else if (seen_selected and item.locked) return true;
            }
        },
        .back => {
            var seen_selected = false;
            var index = items.len;
            while (index > 0) {
                index -= 1;
                const item = items[index];
                if (layerCommandSelects(command, item.identity)) seen_selected = true else if (seen_selected and item.locked) return true;
            }
        },
        .up => {
            var index: usize = 0;
            while (index < items.len) {
                if (!layerCommandSelects(command, items[index].identity)) {
                    index += 1;
                    continue;
                }
                while (index < items.len and layerCommandSelects(command, items[index].identity)) : (index += 1) {}
                if (index < items.len and items[index].locked) return true;
            }
        },
        .down => {
            var index = items.len;
            while (index > 0) {
                if (!layerCommandSelects(command, items[index - 1].identity)) {
                    index -= 1;
                    continue;
                }
                while (index > 0 and layerCommandSelects(command, items[index - 1].identity)) : (index -= 1) {}
                if (index > 0 and items[index - 1].locked) return true;
            }
        },
    }
    return false;
}

test "Studio layer batches cannot cross locked paint-order barriers" {
    const items = [_]slides.SlideItem{
        .{ .identity = 1, .kind = .textbox },
        .{ .identity = 2, .kind = .textbox, .locked = true },
        .{ .identity = 3, .kind = .textbox },
        .{ .identity = 4, .kind = .textbox },
    };
    const target_one: studio.CommandTarget = .{ .item_identity = 1, .source = .{} };
    const target_three: studio.CommandTarget = .{ .item_identity = 3, .source = .{} };

    var command = studio.LayerCommand{ .action = .front };
    command.targets[0] = target_one;
    command.count = 1;
    try std.testing.expect(layerCommandCrossesLocked(command, &items));

    command.targets[0] = target_three;
    try std.testing.expect(!layerCommandCrossesLocked(command, &items));
    command.action = .down;
    try std.testing.expect(layerCommandCrossesLocked(command, &items));

    command.targets[0] = target_one;
    command.action = .up;
    try std.testing.expect(layerCommandCrossesLocked(command, &items));

    command.targets[1] = target_three;
    command.count = 2;
    command.action = .front;
    try std.testing.expect(layerCommandCrossesLocked(command, &items));
}

fn recordStudioPatch(history: *StudioHistory, result: source_editor.PatchResult) !void {
    const before = try G.allocator.dupe(u8, G.editor_memory[0..G.source_len]);
    errdefer G.allocator.free(before);
    errdefer result.deinit(G.allocator);
    const before_slide = G.current_slide;
    try history.reserveRecord();

    try replaceEditorSource(result.source);
    reparseEditorSource() catch |err| {
        replaceEditorSource(before) catch {};
        reparseEditorSource() catch {};
        return err;
    };
    history.recordAssumeCapacity(before, result.source, before_slide, G.current_slide);
}

fn starterDeckPatch(
    allocator: std.mem.Allocator,
    current_source: []const u8,
    preset: studio.NewDeckPreset,
) !source_editor.PatchResult {
    const replacement = studio_new_deck.source(preset);
    const new_length = std.math.cast(isize, replacement.len) orelse return error.StudioSourceTooLarge;
    const old_length = std.math.cast(isize, current_source.len) orelse return error.StudioSourceTooLarge;
    return .{
        .source = try allocator.dupe(u8, replacement),
        .byte_delta = new_length - old_length,
    };
}

test "starter deck replacement is one owned source patch" {
    const patch = try starterDeckPatch(std.testing.allocator, pristine_untitled_source, .aurora);
    defer patch.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(studio_new_deck.source(.aurora), patch.source);
    try std.testing.expectEqual(
        @as(isize, @intCast(patch.source.len)) - @as(isize, @intCast(pristine_untitled_source.len)),
        patch.byte_delta,
    );
}

fn recordStudioCatalogPatch(history: *StudioHistory, result: studio_catalog.EditResult) !void {
    return recordStudioPatch(history, .{
        .source = result.source,
        .byte_delta = result.byte_delta,
    });
}

fn rendererPreviewFromLive(preview: studio.LivePreview) renderer.ItemGeometryPreview {
    return .{
        .owner_identity = preview.item_identity,
        .before_position = preview.before.position,
        .before_size = preview.before.size,
        .after_position = preview.after.position,
        .after_size = preview.after.size,
        .resized = preview.resized,
    };
}

fn rendererPreviewFromCommand(command: studio.GeometryCommand) renderer.ItemGeometryPreview {
    return .{
        .owner_identity = command.item_identity,
        .before_position = command.before_position,
        .before_size = command.before_size,
        .after_position = command.after_position,
        .after_size = command.after_size,
        .resized = command.resized,
    };
}

const MorphItemEditTarget = union(enum) {
    patch: slides.SourceRef,
    insert_local,
};

fn itemBornInMorphState(slide: *const slides.Slide, state_index: usize, item: *const slides.SlideItem) bool {
    _ = slide;
    return item.creation_morph_state != null and item.creation_morph_state.? == state_index;
}

fn morphItemEditTarget(slide: *const slides.Slide, state_index: usize, item: *const slides.SlideItem) MorphItemEditTarget {
    if (item.state_source_state != null and item.state_source_state.? == state_index) {
        return .{ .patch = item.state_source.? };
    }
    if (itemBornInMorphState(slide, state_index, item)) return .{ .patch = item.source };
    return .insert_local;
}

fn insertStudioTemplateOverride(
    history: *StudioHistory,
    slide: *const slides.Slide,
    snippet: []const u8,
) !void {
    return recordStudioPatch(history, try source_editor.insertSlideTemplateOverride(
        G.allocator,
        G.editor_memory[0..G.source_len],
        slide.pos_in_editor,
        snippet,
    ));
}

fn applyStudioGeometryEdit(
    history: *StudioHistory,
    command: studio.GeometryCommand,
    slide_opt: ?*slides.Slide,
    morph_state: ?usize,
    items: []const slides.SlideItem,
) !void {
    const source_after_position = command.source_after_position orelse command.after_position;
    const source_after_size = command.source_after_size orelse command.after_size;
    var source_ref = command.source;
    if (morph_state) |state_index| {
        const slide = slide_opt orelse return error.NoStudioSlide;
        const item = studioItemByIdentity(items, command.item_identity) orelse return error.StudioItemMissing;
        switch (morphItemEditTarget(slide, state_index, item)) {
            .patch => |patch_source| source_ref = patch_source,
            .insert_local => {
                const id = item.id orelse return error.MorphItemNeedsId;
                var directive_buffer: [512]u8 = undefined;
                const directive = if (command.resized)
                    try std.fmt.bufPrint(
                        &directive_buffer,
                        "@set {s} x={d} y={d} w={d} h={d}",
                        .{ id, source_after_position.x, source_after_position.y, source_after_size.x, source_after_size.y },
                    )
                else
                    try std.fmt.bufPrint(
                        &directive_buffer,
                        "@set {s} x={d} y={d}",
                        .{ id, source_after_position.x, source_after_position.y },
                    );
                const insertion_offset = try source_editor.morphStateEndOffset(
                    G.editor_memory[0..G.source_len],
                    slide.morph_states.items[state_index].source.line_offset,
                );
                return recordStudioPatch(history, try source_editor.insertDirectiveAt(
                    G.allocator,
                    G.editor_memory[0..G.source_len],
                    insertion_offset,
                    directive,
                ));
            },
        }
    } else if (command.edit_scope == .local_instance) {
        const slide = slide_opt orelse return error.NoStudioSlide;
        const item = studioItemByIdentity(items, command.item_identity) orelse return error.StudioItemMissing;
        const id = item.id orelse return error.TemplateInstanceItemNeedsId;
        if (item.instance_source) |instance_source| {
            if (instance_source.patchable) {
                return recordStudioPatch(history, try source_editor.patchSlideTemplateOverrideGeometry(
                    G.allocator,
                    G.editor_memory[0..G.source_len],
                    slide.pos_in_editor,
                    instance_source.line_offset,
                    id,
                    .{
                        .x = source_after_position.x,
                        .y = source_after_position.y,
                        .w = if (command.resized) source_after_size.x else null,
                        .h = if (command.resized) source_after_size.y else null,
                    },
                ));
            }
        }

        var directive_buffer: [512]u8 = undefined;
        const directive = if (command.resized)
            try std.fmt.bufPrint(
                &directive_buffer,
                "@set {s} x={d} y={d} w={d} h={d}",
                .{ id, source_after_position.x, source_after_position.y, source_after_size.x, source_after_size.y },
            )
        else
            try std.fmt.bufPrint(
                &directive_buffer,
                "@set {s} x={d} y={d}",
                .{ id, source_after_position.x, source_after_position.y },
            );
        return insertStudioTemplateOverride(history, slide, directive);
    } else if (command.edit_scope == .shared_template) {
        const item = studioItemByIdentity(items, command.item_identity) orelse return error.StudioItemMissing;
        if (item.instance_source != null and command.source_after_position == null) return error.SharedTemplateTargetMissing;
        source_ref = item.source;
    }
    if (source_ref.scope == .none or !source_ref.patchable) return error.StudioItemHasNoPatchableSource;

    return recordStudioPatch(history, try source_editor.patchGeometry(
        G.allocator,
        G.editor_memory[0..G.source_len],
        source_ref.line_offset,
        .{
            .x = source_after_position.x,
            .y = source_after_position.y,
            .w = if (command.resized) source_after_size.x else null,
            .h = if (command.resized) source_after_size.y else null,
        },
    ));
}

fn applyStudioGeometryBatchEdit(
    history: *StudioHistory,
    batch: studio.GeometryBatchCommand,
    slide_opt: ?*slides.Slide,
    morph_state: ?usize,
    items: []const slides.SlideItem,
) !void {
    const source = G.editor_memory[0..G.source_len];
    var edits: [studio.max_selection_items]source_editor.GeometrySourceEdit = undefined;
    var snippet_buffers: [studio.max_selection_items][512]u8 = undefined;
    const planned = try planStudioGeometryBatchEdits(
        source,
        batch,
        slide_opt,
        morph_state,
        items,
        &edits,
        &snippet_buffers,
    );

    return recordStudioPatch(history, try source_editor.applyGeometryEdits(
        G.allocator,
        source,
        planned,
    ));
}

fn planStudioGeometryBatchEdits(
    source: []const u8,
    batch: studio.GeometryBatchCommand,
    slide_opt: ?*slides.Slide,
    morph_state: ?usize,
    items: []const slides.SlideItem,
    edits: *[studio.max_selection_items]source_editor.GeometrySourceEdit,
    snippet_buffers: *[studio.max_selection_items][512]u8,
) ![]const source_editor.GeometrySourceEdit {
    if (batch.count == 0 or batch.count > studio.max_selection_items) return error.InvalidStudioGeometryBatch;

    for (batch.slice(), 0..) |command, index| {
        const item = studioItemByIdentity(items, command.item_identity) orelse return error.StudioItemMissing;
        const source_after_position = command.source_after_position orelse command.after_position;
        const source_after_size = command.source_after_size orelse command.after_size;
        const geometry: source_editor.GeometryPatch = .{
            .x = source_after_position.x,
            .y = source_after_position.y,
            .w = if (command.resized) source_after_size.x else null,
            .h = if (command.resized) source_after_size.y else null,
        };

        var source_ref = command.source;
        if (morph_state) |state_index| {
            const slide = slide_opt orelse return error.NoStudioSlide;
            switch (morphItemEditTarget(slide, state_index, item)) {
                .patch => |patch_source| {
                    if (item.state_source_state != null and item.state_source_state.? == state_index) {
                        try source_editor.validateMorphMutationTarget(
                            source,
                            slide.morph_states.items[state_index].source.line_offset,
                            patch_source.line_offset,
                            item.id orelse return error.MorphItemNeedsId,
                        );
                    }
                    source_ref = patch_source;
                },
                .insert_local => {
                    const id = item.id orelse return error.MorphItemNeedsId;
                    const snippet = if (command.resized)
                        try std.fmt.bufPrint(
                            &snippet_buffers[index],
                            "@set {s} x={d} y={d} w={d} h={d}",
                            .{ id, source_after_position.x, source_after_position.y, source_after_size.x, source_after_size.y },
                        )
                    else
                        try std.fmt.bufPrint(
                            &snippet_buffers[index],
                            "@set {s} x={d} y={d}",
                            .{ id, source_after_position.x, source_after_position.y },
                        );
                    edits[index] = .{ .insert = .{
                        .insertion_offset = try source_editor.morphStateEndOffset(
                            source,
                            slide.morph_states.items[state_index].source.line_offset,
                        ),
                        .snippet = snippet,
                    } };
                    continue;
                },
            }
        } else switch (command.edit_scope) {
            .local_instance => {
                const slide = slide_opt orelse return error.NoStudioSlide;
                const id = item.id orelse return error.TemplateInstanceItemNeedsId;
                if (item.instance_source) |instance_source| {
                    if (instance_source.patchable) {
                        try source_editor.validateSlideTemplateOverrideGeometryTarget(
                            source,
                            slide.pos_in_editor,
                            instance_source.line_offset,
                            id,
                        );
                        source_ref = instance_source;
                        edits[index] = .{ .patch = .{
                            .directive_offset = source_ref.line_offset,
                            .geometry = geometry,
                        } };
                        continue;
                    }
                }

                const snippet = if (command.resized)
                    try std.fmt.bufPrint(
                        &snippet_buffers[index],
                        "@set {s} x={d} y={d} w={d} h={d}",
                        .{ id, source_after_position.x, source_after_position.y, source_after_size.x, source_after_size.y },
                    )
                else
                    try std.fmt.bufPrint(
                        &snippet_buffers[index],
                        "@set {s} x={d} y={d}",
                        .{ id, source_after_position.x, source_after_position.y },
                    );
                edits[index] = .{ .insert = .{
                    .insertion_offset = try source_editor.slideTemplateOverrideInsertionOffset(
                        source,
                        slide.pos_in_editor,
                        snippet,
                    ),
                    .snippet = snippet,
                } };
                continue;
            },
            .shared_template => {
                if (item.sharedTemplateValues() == null) return error.SharedTemplateValuesMissing;
                if (item.instance_source != null and command.source_after_position == null) return error.SharedTemplateTargetMissing;
                source_ref = item.source;
            },
            .direct => {},
        }

        if (source_ref.scope == .none or !source_ref.patchable) return error.StudioItemHasNoPatchableSource;
        edits[index] = .{ .patch = .{
            .directive_offset = source_ref.line_offset,
            .geometry = geometry,
        } };
    }

    return edits[0..batch.count];
}

test "Studio group planner mixes existing and missing local overrides with a direct patch" {
    const allocator = std.testing.allocator;
    const source =
        "@box id=hero x=10 y=20 w=300 h=120 text=Hero\n" ++
        "@box id=badge x=40 y=180 w=160 h=80 text=Badge\n" ++
        "@pushslide layout\n" ++
        "@popslide layout\n" ++
        "@set hero x=100 y=120\n" ++
        "@box id=local x=500 y=300 w=240 h=100 text=Local\n" ++
        "@popslide layout\n";

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const slideshow = try slides.SlideShow.new(arena.allocator());
    const context = try parser.constructSlidesFromBuf(source, slideshow, arena.allocator());
    defer context.deinit();
    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    try std.testing.expectEqual(@as(usize, 2), slideshow.slides.items.len);

    const first_slide = slideshow.slides.items[0];
    const first_items = first_slide.items.?.items;
    try std.testing.expectEqual(@as(usize, 3), first_items.len);

    var batch = studio.GeometryBatchCommand{ .count = 3 };
    const destinations = [_]rl.Vector2{
        .{ .x = 150, .y = 160 },
        .{ .x = 450, .y = 200 },
        .{ .x = 700, .y = 500 },
    };
    const scopes = [_]studio.EditScope{ .local_instance, .local_instance, .direct };
    for (first_items, destinations, scopes, 0..) |item, destination, edit_scope, index| {
        batch.commands[index] = .{
            .item_identity = item.identity,
            .source = item.effectiveBaseSource(),
            .edit_scope = edit_scope,
            .before_position = item.position,
            .before_size = item.size,
            .after_position = destination,
            .after_size = item.size,
            .resized = false,
        };
    }

    var edits: [studio.max_selection_items]source_editor.GeometrySourceEdit = undefined;
    var snippets: [studio.max_selection_items][512]u8 = undefined;
    const planned = try planStudioGeometryBatchEdits(
        source,
        batch,
        first_slide,
        null,
        first_items,
        &edits,
        &snippets,
    );
    try std.testing.expectEqual(@as(usize, 3), planned.len);

    const patch = try source_editor.applyGeometryEdits(allocator, source, planned);
    defer patch.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, patch.source, "@set hero"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, patch.source, "@set badge"));

    var reparsed_arena = std.heap.ArenaAllocator.init(allocator);
    defer reparsed_arena.deinit();
    const reparsed = try slides.SlideShow.new(reparsed_arena.allocator());
    const reparsed_context = try parser.constructSlidesFromBuf(patch.source, reparsed, reparsed_arena.allocator());
    defer reparsed_context.deinit();
    try std.testing.expectEqual(@as(usize, 0), reparsed_context.parser_errors.items.len);

    const edited = reparsed.slides.items[0].items.?.items;
    for (edited, destinations) |item, destination| {
        try std.testing.expectApproxEqAbs(destination.x, item.position.x, 0.0001);
        try std.testing.expectApproxEqAbs(destination.y, item.position.y, 0.0001);
    }
    try std.testing.expect(edited[0].instance_source != null);
    try std.testing.expect(edited[1].instance_source != null);

    const untouched = reparsed.slides.items[1].items.?.items;
    try std.testing.expectApproxEqAbs(@as(f32, 10), untouched[0].position.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 40), untouched[1].position.x, 0.0001);

    // Cross the planner -> one source patch -> history -> parser boundary in
    // both directions. prepareRestore deliberately leaves the cursor fixed
    // until the candidate source has reparsed successfully.
    var history = StudioHistory.init(allocator);
    defer history.deinit();
    try history.record(
        try allocator.dupe(u8, source),
        try allocator.dupe(u8, patch.source),
        0,
        0,
    );
    const undo_restore = (try history.prepareRestore(.undo)).?;
    var undo_arena = std.heap.ArenaAllocator.init(allocator);
    defer undo_arena.deinit();
    const undo_deck = try slides.SlideShow.new(undo_arena.allocator());
    const undo_context = try parser.constructSlidesFromBuf(undo_restore.source, undo_deck, undo_arena.allocator());
    defer undo_context.deinit();
    try std.testing.expectEqual(@as(usize, 0), undo_context.parser_errors.items.len);
    try std.testing.expectApproxEqAbs(@as(f32, 100), undo_deck.slides.items[0].items.?.items[0].position.x, 0.0001);
    try std.testing.expectEqual(@as(usize, 1), history.undo_stack.items.len);
    try std.testing.expectEqual(@as(usize, 0), history.redo_stack.items.len);
    history.commitRestore(.undo);

    const redo_restore = (try history.prepareRestore(.redo)).?;
    var redo_arena = std.heap.ArenaAllocator.init(allocator);
    defer redo_arena.deinit();
    const redo_deck = try slides.SlideShow.new(redo_arena.allocator());
    const redo_context = try parser.constructSlidesFromBuf(redo_restore.source, redo_deck, redo_arena.allocator());
    defer redo_context.deinit();
    try std.testing.expectEqual(@as(usize, 0), redo_context.parser_errors.items.len);
    const redone = redo_deck.slides.items[0].items.?.items;
    for (redone, destinations) |item, destination| {
        try std.testing.expectApproxEqAbs(destination.x, item.position.x, 0.0001);
        try std.testing.expectApproxEqAbs(destination.y, item.position.y, 0.0001);
    }
    history.commitRestore(.redo);
    try std.testing.expectEqual(@as(usize, 1), history.undo_stack.items.len);
    try std.testing.expectEqual(@as(usize, 0), history.redo_stack.items.len);
}

test "Studio planner persists shared authored geometry while a local override stays masked" {
    const allocator = std.testing.allocator;
    const source =
        "@box id=hero x=10 y=20 w=300 h=120 text=Hero\n" ++
        "@pushslide layout\n" ++
        "@popslide layout\n" ++
        "@set hero x=100 y=120\n" ++
        "@popslide layout\n";

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const slideshow = try slides.SlideShow.new(arena.allocator());
    const context = try parser.constructSlidesFromBuf(source, slideshow, arena.allocator());
    defer context.deinit();
    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);

    const first_slide = slideshow.slides.items[0];
    const item = first_slide.items.?.items[0];
    try std.testing.expectApproxEqAbs(@as(f32, 100), item.position.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 10), item.sharedTemplateValues().?.position.x, 0.0001);

    var batch = studio.GeometryBatchCommand{ .count = 1 };
    batch.commands[0] = .{
        .item_identity = item.identity,
        .source = item.source,
        .edit_scope = .shared_template,
        .before_position = item.position,
        .before_size = item.size,
        .after_position = .{ .x = 120, .y = 120 },
        .after_size = item.size,
        .source_after_position = .{ .x = 30, .y = 20 },
        .source_after_size = item.sharedTemplateValues().?.size,
        .resized = false,
    };

    var edits: [studio.max_selection_items]source_editor.GeometrySourceEdit = undefined;
    var snippets: [studio.max_selection_items][512]u8 = undefined;
    const planned = try planStudioGeometryBatchEdits(
        source,
        batch,
        first_slide,
        null,
        first_slide.items.?.items,
        &edits,
        &snippets,
    );
    const patch = try source_editor.applyGeometryEdits(allocator, source, planned);
    defer patch.deinit(allocator);

    var reparsed_arena = std.heap.ArenaAllocator.init(allocator);
    defer reparsed_arena.deinit();
    const reparsed = try slides.SlideShow.new(reparsed_arena.allocator());
    const reparsed_context = try parser.constructSlidesFromBuf(patch.source, reparsed, reparsed_arena.allocator());
    defer reparsed_context.deinit();
    try std.testing.expectEqual(@as(usize, 0), reparsed_context.parser_errors.items.len);

    const customized = reparsed.slides.items[0].items.?.items[0];
    const ordinary = reparsed.slides.items[1].items.?.items[0];
    try std.testing.expectApproxEqAbs(@as(f32, 100), customized.position.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 120), customized.position.y, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 30), customized.sharedTemplateValues().?.position.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 30), ordinary.position.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 20), ordinary.position.y, 0.0001);
}

fn colorLiteral(buffer: *[9]u8, color: rl.Color) []const u8 {
    const digits = "0123456789abcdef";
    const components = [_]u8{ color.r, color.g, color.b, color.a };
    buffer[0] = '#';
    for (components, 0..) |component, index| {
        buffer[1 + index * 2] = digits[component >> 4];
        buffer[2 + index * 2] = digits[component & 0x0f];
    }
    return buffer;
}

fn parseStudioFiniteFloat(value: []const u8) !f32 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidStudioNumber;
    const parsed = std.fmt.parseFloat(f32, trimmed) catch return error.InvalidStudioNumber;
    if (!std.math.isFinite(parsed)) return error.InvalidStudioNumber;
    return if (parsed == 0) 0 else parsed;
}

fn formatStudioFloat(buffer: []u8, value: f32) ![]const u8 {
    if (!std.math.isFinite(value)) return error.InvalidStudioNumber;
    return std.fmt.bufPrint(buffer, "{d}", .{if (value == 0) @as(f32, 0) else value});
}

fn canonicalStudioColor(input: []const u8, buffer: *[9]u8) ![]const u8 {
    const value = std.mem.trim(u8, input, " \t\r\n");
    if ((value.len != 7 and value.len != 9) or value[0] != '#') return error.InvalidStudioColor;
    buffer[0] = '#';
    for (value[1..]) |byte| {
        if (!std.ascii.isHex(byte)) return error.InvalidStudioColor;
    }
    for (value[1..], 1..) |byte, index| buffer[index] = std.ascii.toLower(byte);
    if (value.len == 7) {
        buffer[7] = 'f';
        buffer[8] = 'f';
    }
    return buffer;
}

fn canonicalStudioOpacity(input: []const u8, buffer: []u8) ![]const u8 {
    return formatStudioFloat(buffer, try canonicalOpacityValue(input));
}

fn canonicalStudioFontSize(input: []const u8, buffer: []u8) ![]const u8 {
    const value = std.mem.trim(u8, input, " \t\r\n");
    const size = std.fmt.parseInt(i32, value, 10) catch return error.InvalidStudioFontSize;
    if (size <= 0 or size > 4096) return error.InvalidStudioFontSize;
    return std.fmt.bufPrint(buffer, "{d}", .{size});
}

const InlineSemanticEdit = struct {
    command: studio.SemanticCommand,
    value: []const u8,
};

/// Convert a dock-owned inline commit into the established source-edit
/// command surface. Keeping the mapping here means legacy modal actions and
/// inline fields share exactly the same ownership, canonicalization, history,
/// and reparse implementation.
fn inlineSemanticEdit(commit: studio.InlineCommit) InlineSemanticEdit {
    const command: studio.SemanticCommand = switch (commit.field) {
        .text => .{ .edit_text = commit.target },
        .x => .{ .edit_numeric_geometry = .{ .target = commit.target, .field = .x } },
        .y => .{ .edit_numeric_geometry = .{ .target = commit.target, .field = .y } },
        .width => .{ .edit_numeric_geometry = .{ .target = commit.target, .field = .width } },
        .height => .{ .edit_numeric_geometry = .{ .target = commit.target, .field = .height } },
        .foreground => .{ .set_custom_foreground = commit.target },
        .background => if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, commit.value, " \t\r\n"), "none"))
            .{ .clear_background = commit.target }
        else
            .{ .set_custom_background = commit.target },
        .font_size => .{ .set_font_size = commit.target },
        .opacity => .{ .set_opacity = commit.target },
    };
    return .{ .command = command, .value = commit.value };
}

/// Inline input never reaches the source layer until its complete value is
/// known to be valid. This supplies field-specific feedback without closing
/// the dock editor or perturbing the selection/source history.
fn validateInlineCommit(commit: studio.InlineCommit) ?studio.InlineError {
    if (commit.value.len > studio.max_inline_input_bytes) return .too_long;
    if (!std.unicode.utf8ValidateSlice(commit.value)) return .invalid_utf8;

    switch (commit.field) {
        .text => validateStudioTextValue(commit.value) catch return .invalid_text,
        .x, .y => _ = parseStudioFiniteFloat(commit.value) catch return .invalid_number,
        .width, .height => {
            const value = parseStudioFiniteFloat(commit.value) catch return .invalid_number;
            if (value < studio.default_min_item_size) return .non_positive_dimension;
        },
        .foreground => {
            var buffer: [9]u8 = undefined;
            _ = canonicalStudioColor(commit.value, &buffer) catch return .invalid_color;
        },
        .background => {
            if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, commit.value, " \t\r\n"), "none")) {
                var buffer: [9]u8 = undefined;
                _ = canonicalStudioColor(commit.value, &buffer) catch return .invalid_color;
            }
        },
        .font_size => {
            var buffer: [32]u8 = undefined;
            _ = canonicalStudioFontSize(commit.value, &buffer) catch return .invalid_font_size;
        },
        .opacity => {
            var buffer: [64]u8 = undefined;
            _ = canonicalStudioOpacity(commit.value, &buffer) catch return .invalid_opacity;
        },
    }
    return null;
}

/// A pristine Enter/Tab must not manufacture source churn or an undo entry.
/// Compare against the captured edit layer: shared-template fields use their
/// immutable shared values even when a local override masks them onscreen.
fn inlineCommitChangesValue(
    commit: studio.InlineCommit,
    items: []const slides.SlideItem,
    resolved_bounds: []const studio.ResolvedBounds,
) bool {
    const item = studioItemByIdentity(items, commit.target.item_identity) orelse return true;
    const shared = if (commit.target.edit_scope == .shared_template) item.sharedTemplateValues() else null;
    const geometry = if (shared) |values|
        studio.Geometry{ .position = values.position, .size = values.size }
    else
        studio.itemGeometry(item.*, resolved_bounds);

    return switch (commit.field) {
        .text => !std.mem.eql(
            u8,
            if (shared) |values| values.text orelse "" else item.text orelse "",
            commit.value,
        ),
        .x => geometry.position.x != (parseStudioFiniteFloat(commit.value) catch return true),
        .y => geometry.position.y != (parseStudioFiniteFloat(commit.value) catch return true),
        .width => geometry.size.x != (parseStudioFiniteFloat(commit.value) catch return true),
        .height => geometry.size.y != (parseStudioFiniteFloat(commit.value) catch return true),
        .foreground => changed: {
            const current = if (shared) |values| values.color else item.color;
            const color = current orelse break :changed true;
            var current_buffer: [9]u8 = undefined;
            var submitted_buffer: [9]u8 = undefined;
            const submitted = canonicalStudioColor(commit.value, &submitted_buffer) catch return true;
            break :changed !std.mem.eql(u8, colorLiteral(&current_buffer, color), submitted);
        },
        .background => changed: {
            const current = if (shared) |values| values.background_color else item.background_color;
            const submitted = std.mem.trim(u8, commit.value, " \t\r\n");
            if (std.ascii.eqlIgnoreCase(submitted, "none")) break :changed current != null;
            const color = current orelse break :changed true;
            var current_buffer: [9]u8 = undefined;
            var submitted_buffer: [9]u8 = undefined;
            const canonical = canonicalStudioColor(submitted, &submitted_buffer) catch return true;
            break :changed !std.mem.eql(u8, colorLiteral(&current_buffer, color), canonical);
        },
        .font_size => changed: {
            const current = if (shared) |values| values.font_size else item.fontSize;
            const submitted = std.fmt.parseInt(i32, std.mem.trim(u8, commit.value, " \t\r\n"), 10) catch return true;
            break :changed current == null or current.? != submitted;
        },
        .opacity => changed: {
            const current = if (shared) |values| values.opacity else item.opacity;
            const submitted = canonicalOpacityValue(commit.value) catch return true;
            break :changed @abs(current - submitted) > 0.000001;
        },
    };
}

fn canonicalOpacityValue(input: []const u8) !f32 {
    const value = std.mem.trim(u8, input, " \t\r\n");
    if (value.len == 0) return error.InvalidStudioOpacity;
    const opacity = if (value[value.len - 1] == '%') blk: {
        const percent = try parseStudioFiniteFloat(value[0 .. value.len - 1]);
        break :blk percent / 100;
    } else try parseStudioFiniteFloat(value);
    if (opacity < 0 or opacity > 1) return error.InvalidStudioOpacity;
    return opacity;
}

fn inlineErrorForSemanticFailure(field: studio.InlineField, err: anyerror) studio.InlineError {
    return switch (err) {
        error.InvalidStudioNumber => .invalid_number,
        error.InvalidStudioDimension => .non_positive_dimension,
        error.InvalidStudioColor => .invalid_color,
        error.InvalidStudioFontSize => .invalid_font_size,
        error.InvalidStudioOpacity => .invalid_opacity,
        error.InvalidStudioText => .invalid_text,
        error.InvalidLiteralValue => if (field == .text) .invalid_text else .source_edit_failed,
        else => .source_edit_failed,
    };
}

test "Studio custom property values canonicalize safely" {
    var color_buffer: [9]u8 = undefined;
    try std.testing.expectEqualStrings("#aabbccff", try canonicalStudioColor(" #AaBbCc ", &color_buffer));
    try std.testing.expectEqualStrings("#01020304", try canonicalStudioColor("#01020304", &color_buffer));
    try std.testing.expectError(error.InvalidStudioColor, canonicalStudioColor("#12345g", &color_buffer));

    var number_buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("0.75", try canonicalStudioOpacity("75%", &number_buffer));
    try std.testing.expectEqualStrings("0.25", try canonicalStudioOpacity("0.25", &number_buffer));
    try std.testing.expectEqualStrings("0", try canonicalStudioOpacity("0", &number_buffer));
    try std.testing.expectEqualStrings("0", try canonicalStudioOpacity("0%", &number_buffer));
    try std.testing.expectEqualStrings("0.005", try canonicalStudioOpacity("0.5%", &number_buffer));
    try std.testing.expectError(error.InvalidStudioOpacity, canonicalStudioOpacity("-0.1", &number_buffer));
    try std.testing.expectError(error.InvalidStudioOpacity, canonicalStudioOpacity("101%", &number_buffer));
    try std.testing.expectEqualStrings("48", try canonicalStudioFontSize("48", &number_buffer));
    try std.testing.expectError(error.InvalidStudioFontSize, canonicalStudioFontSize("0", &number_buffer));
}

test "Studio inline commits map to legacy atomic semantic edits" {
    const target: studio.CommandTarget = .{
        .item_identity = 42,
        .source = .{ .scope = .direct, .line_offset = 12, .patchable = true },
    };
    const cases = [_]struct {
        field: studio.InlineField,
        value: []const u8,
        tag: std.meta.Tag(studio.SemanticCommand),
    }{
        .{ .field = .text, .value = "Hello", .tag = .edit_text },
        .{ .field = .x, .value = "10", .tag = .edit_numeric_geometry },
        .{ .field = .y, .value = "20", .tag = .edit_numeric_geometry },
        .{ .field = .width, .value = "300", .tag = .edit_numeric_geometry },
        .{ .field = .height, .value = "200", .tag = .edit_numeric_geometry },
        .{ .field = .foreground, .value = "#aabbccff", .tag = .set_custom_foreground },
        .{ .field = .background, .value = "#01020304", .tag = .set_custom_background },
        .{ .field = .background, .value = " NoNe ", .tag = .clear_background },
        .{ .field = .font_size, .value = "48", .tag = .set_font_size },
        .{ .field = .opacity, .value = "75%", .tag = .set_opacity },
    };
    for (cases) |case| {
        const mapped = inlineSemanticEdit(.{ .target = target, .field = case.field, .value = case.value });
        try std.testing.expectEqual(case.tag, std.meta.activeTag(mapped.command));
        try std.testing.expectEqualStrings(case.value, mapped.value);
    }
}

test "Studio inline validation reports the exact field without touching source" {
    const target: studio.CommandTarget = .{ .item_identity = 1, .source = .{} };
    const invalid_utf8 = [_]u8{ 0xe2, 0x82 };
    try std.testing.expectEqual(studio.InlineError.invalid_utf8, validateInlineCommit(.{
        .target = target,
        .field = .text,
        .value = &invalid_utf8,
    }).?);
    try std.testing.expectEqual(studio.InlineError.invalid_number, validateInlineCommit(.{
        .target = target,
        .field = .x,
        .value = "left",
    }).?);
    try std.testing.expectEqual(studio.InlineError.non_positive_dimension, validateInlineCommit(.{
        .target = target,
        .field = .width,
        .value = "0",
    }).?);
    try std.testing.expectEqual(studio.InlineError.invalid_color, validateInlineCommit(.{
        .target = target,
        .field = .foreground,
        .value = "red",
    }).?);
    try std.testing.expectEqual(studio.InlineError.invalid_font_size, validateInlineCommit(.{
        .target = target,
        .field = .font_size,
        .value = "12.5",
    }).?);
    try std.testing.expectEqual(studio.InlineError.invalid_opacity, validateInlineCommit(.{
        .target = target,
        .field = .opacity,
        .value = "101%",
    }).?);
    try std.testing.expectEqual(studio.InlineError.invalid_text, validateInlineCommit(.{
        .target = target,
        .field = .text,
        .value = "Safe\n@slide",
    }).?);
    try std.testing.expect(validateInlineCommit(.{
        .target = target,
        .field = .background,
        .value = "none",
    }) == null);
    try std.testing.expect(validateInlineCommit(.{
        .target = target,
        .field = .opacity,
        .value = "0%",
    }) == null);
}

test "Studio pristine inline commits compare against the captured ownership layer" {
    const item: slides.SlideItem = .{
        .identity = 7,
        .id = "hero",
        .source = .{ .scope = .slide_template, .line_offset = 10, .patchable = true },
        .instance_source = .{ .scope = .slide_instance_override, .line_offset = 100, .patchable = true },
        .shared_template_values = .{
            .text = "Shared",
            .font_size = 40,
            .color = .{ .r = 1, .g = 2, .b = 3, .a = 255 },
            .background_color = .{ .r = 10, .g = 20, .b = 30, .a = 40 },
            .position = .{ .x = 10, .y = 20 },
            .size = .{ .x = 300, .y = 200 },
            .opacity = 0.75,
        },
        .kind = .textbox,
        .text = "Local",
        .fontSize = 52,
        .color = .{ .r = 9, .g = 8, .b = 7, .a = 255 },
        .background_color = null,
        .position = .{ .x = 100, .y = 120 },
        .size = .{ .x = 320, .y = 220 },
        .opacity = 0.5,
    };
    const items = [_]slides.SlideItem{item};
    const bounds = [_]studio.ResolvedBounds{.{
        .identity = 7,
        .position = item.position,
        .size = item.size,
    }};
    const local_target: studio.CommandTarget = .{
        .item_identity = 7,
        .source = item.instance_source.?,
        .edit_scope = .local_instance,
    };
    const shared_target: studio.CommandTarget = .{
        .item_identity = 7,
        .source = item.source,
        .edit_scope = .shared_template,
    };

    try std.testing.expect(!inlineCommitChangesValue(.{
        .target = local_target,
        .field = .x,
        .value = "100.000",
    }, &items, &bounds));
    try std.testing.expect(!inlineCommitChangesValue(.{
        .target = local_target,
        .field = .background,
        .value = "NONE",
    }, &items, &bounds));
    try std.testing.expect(!inlineCommitChangesValue(.{
        .target = shared_target,
        .field = .x,
        .value = "10",
    }, &items, &bounds));
    try std.testing.expect(!inlineCommitChangesValue(.{
        .target = shared_target,
        .field = .text,
        .value = "Shared",
    }, &items, &bounds));
    try std.testing.expect(!inlineCommitChangesValue(.{
        .target = shared_target,
        .field = .opacity,
        .value = "75%",
    }, &items, &bounds));
    try std.testing.expect(inlineCommitChangesValue(.{
        .target = shared_target,
        .field = .x,
        .value = "100",
    }, &items, &bounds));
    try std.testing.expect(inlineCommitChangesValue(.{
        .target = shared_target,
        .field = .text,
        .value = "Local",
    }, &items, &bounds));
}

fn validReusableName(name: []const u8) bool {
    if (name.len == 0 or !(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name[1..]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-') return false;
    }
    return true;
}

/// Retains source-borrowing Studio metadata for exactly one editor revision.
/// The parser graph and editor buffer are immutable between revisions, so
/// slide titles and catalog names remain valid without per-frame rescans or
/// allocations. Scene-dependent slices rebuild only when their physical
/// insertion offsets change.
const StudioWorkspaceCache = struct {
    allocator: std.mem.Allocator,
    revision: ?usize = null,
    catalog: ?studio_catalog.Catalog = null,
    slide_summaries: std.ArrayList(studio.SlideSummary) = .empty,
    morph_summaries: std.ArrayList(studio.MorphStateSummary) = .empty,
    library_entries: std.ArrayList(studio.LibraryEntry) = .empty,
    library_catalog_indices: std.ArrayList(usize) = .empty,
    morph_slide_index: ?usize = null,
    library_item_offset: ?usize = null,
    library_slide_offset: ?usize = null,
    document_rebuild_count: usize = 0,
    scene_rebuild_count: usize = 0,

    fn init(allocator: std.mem.Allocator) StudioWorkspaceCache {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *StudioWorkspaceCache) void {
        if (self.catalog) |catalog| catalog.deinit();
        self.catalog = null;
        self.slide_summaries.deinit(self.allocator);
        self.morph_summaries.deinit(self.allocator);
        self.library_entries.deinit(self.allocator);
        self.library_catalog_indices.deinit(self.allocator);
    }

    fn refreshDocument(
        self: *StudioWorkspaceCache,
        revision: usize,
        source: []const u8,
        slideshow: *const slides.SlideShow,
    ) !bool {
        if (self.revision != null and self.revision.? == revision) return false;

        const catalog = try studio_catalog.discover(self.allocator, source);
        errdefer catalog.deinit();
        self.slide_summaries.clearRetainingCapacity();
        try collectStudioSlideSummaries(&self.slide_summaries, self.allocator, slideshow);

        if (self.catalog) |previous| previous.deinit();
        self.catalog = catalog;
        self.revision = revision;
        self.morph_summaries.clearRetainingCapacity();
        self.library_entries.clearRetainingCapacity();
        self.library_catalog_indices.clearRetainingCapacity();
        self.morph_slide_index = null;
        self.library_item_offset = null;
        self.library_slide_offset = null;
        self.document_rebuild_count += 1;
        return true;
    }

    fn refreshScene(
        self: *StudioWorkspaceCache,
        slide_index: ?usize,
        slide: ?*const slides.Slide,
        item_insertion_offset: usize,
        slide_insertion_offset: usize,
    ) !bool {
        var rebuilt = false;
        if (self.morph_slide_index != slide_index) {
            self.morph_summaries.clearRetainingCapacity();
            if (slide) |current| {
                for (current.morph_states.items, 0..) |state, state_index| {
                    try self.morph_summaries.append(self.allocator, .{
                        .index = state_index,
                        .label = state.spec.label orelse "",
                        .duration = state.spec.duration,
                        .after = state.spec.after,
                        .easing = state.spec.easing,
                        .source = state.source,
                    });
                }
            }
            self.morph_slide_index = slide_index;
            rebuilt = true;
        }

        if (self.library_item_offset != item_insertion_offset or
            self.library_slide_offset != slide_insertion_offset)
        {
            self.library_entries.clearRetainingCapacity();
            self.library_catalog_indices.clearRetainingCapacity();
            if (self.catalog) |catalog| try collectStudioLibraryEntries(
                &self.library_entries,
                &self.library_catalog_indices,
                self.allocator,
                catalog,
                item_insertion_offset,
                slide_insertion_offset,
            );
            self.library_item_offset = item_insertion_offset;
            self.library_slide_offset = slide_insertion_offset;
            rebuilt = true;
        }
        if (rebuilt) self.scene_rebuild_count += 1;
        return rebuilt;
    }
};

const StudioCompositionCache = struct {
    const Key = struct {
        revision: usize,
        slide_index: i32,
        morph_state: ?usize,
        selection_count: usize,
        selected_identity: ?usize,
    };

    key: ?Key = null,
    value: ?studio.CompositionContext = null,
    rebuild_count: usize = 0,

    fn resolve(
        self: *StudioCompositionCache,
        revision: usize,
        allocator: std.mem.Allocator,
        source: []const u8,
        slide_index: i32,
        slide: *const slides.Slide,
        morph_state: ?usize,
        items: []const slides.SlideItem,
        studio_state: studio.Studio,
    ) ?studio.CompositionContext {
        const key: Key = .{
            .revision = revision,
            .slide_index = slide_index,
            .morph_state = morph_state,
            .selection_count = studio_state.selectionCount(),
            .selected_identity = studio_state.selectedIdentityAt(0),
        };
        if (self.key) |cached| {
            if (std.meta.eql(cached, key)) return self.value;
        }
        self.value = studioCompositionContext(
            allocator,
            source,
            slide,
            morph_state,
            items,
            studio_state,
        );
        self.key = key;
        self.rebuild_count += 1;
        return self.value;
    }
};

fn studioSlideTitle(slide: *const slides.Slide) []const u8 {
    var title: []const u8 = "";
    var largest_font: i32 = std.math.minInt(i32);
    if (slide.items) |items| {
        for (items.items) |item| {
            if (item.kind != .textbox or !item.visible or item.opacity <= 0) continue;
            const text = item.text orelse continue;
            const first_line_end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
            const first_line = std.mem.trim(u8, text[0..first_line_end], " \t\r");
            if (first_line.len == 0) continue;
            const font_size = item.fontSize orelse 0;
            if (title.len == 0 or font_size > largest_font) {
                title = first_line;
                largest_font = font_size;
            }
        }
    }
    return title;
}

fn collectStudioSlideSummaries(
    output: *std.ArrayList(studio.SlideSummary),
    allocator: std.mem.Allocator,
    slideshow: *const slides.SlideShow,
) !void {
    for (slideshow.slides.items, 0..) |slide, index| {
        try output.append(allocator, .{
            .index = index,
            .title = studioSlideTitle(slide),
            .item_count = if (slide.items) |items| items.items.len else 0,
            .morph_count = slide.morph_states.items.len,
        });
    }
}

fn collectStudioLibraryEntries(
    output: *std.ArrayList(studio.LibraryEntry),
    catalog_indices: *std.ArrayList(usize),
    allocator: std.mem.Allocator,
    catalog: studio_catalog.Catalog,
    item_insertion_offset: usize,
    slide_insertion_offset: usize,
) !void {
    for (catalog.entries, 0..) |entry, catalog_index| {
        const insertion_offset = switch (entry.kind) {
            .element => item_insertion_offset,
            .group => item_insertion_offset,
            .slide => slide_insertion_offset,
        };
        if (!catalog.isVisibleAt(catalog_index, insertion_offset)) continue;
        try output.append(allocator, .{
            .kind = switch (entry.kind) {
                .element => .element,
                .group => .group,
                .slide => .slide_template,
            },
            .name = entry.name,
            .available = entry.placeable,
            .use_count = entry.use_count,
            .deletable = entry.kind != .slide and entry.use_count == 0,
        });
        errdefer _ = output.pop();
        try catalog_indices.append(allocator, catalog_index);
    }
}

test "Studio workspace cache avoids unchanged large-deck rescans" {
    const allocator = std.testing.allocator;
    var source_builder = std.ArrayList(u8).empty;
    defer source_builder.deinit(allocator);
    const definition_count: usize = 48;
    const slide_count: usize = 256;
    for (0..definition_count) |index| {
        var line_buffer: [160]u8 = undefined;
        const line = try std.fmt.bufPrint(
            &line_buffer,
            "@push card_{d} x={d} y=20 w=180 h=60 text=Card {d}\n",
            .{ index, index * 3, index },
        );
        try source_builder.appendSlice(allocator, line);
    }
    for (0..slide_count) |index| {
        var line_buffer: [192]u8 = undefined;
        const lines = try std.fmt.bufPrint(
            &line_buffer,
            "@slide\n@box id=title_{d} x=80 y=80 fontsize=48 text=Slide {d}\n",
            .{ index, index },
        );
        try source_builder.appendSlice(allocator, lines);
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const slideshow = try slides.SlideShow.new(arena.allocator());
    const parser_context = try parser.constructSlidesFromBuf(source_builder.items, slideshow, arena.allocator());
    defer parser_context.deinit();
    try std.testing.expectEqual(@as(usize, 0), parser_context.parser_errors.items.len);
    try std.testing.expectEqual(slide_count, slideshow.slides.items.len);

    var cache = StudioWorkspaceCache.init(allocator);
    defer cache.deinit();
    try std.testing.expect(try cache.refreshDocument(11, source_builder.items, slideshow));
    try std.testing.expectEqual(slide_count, cache.slide_summaries.items.len);
    try std.testing.expectEqual(definition_count, cache.catalog.?.entries.len);

    const selected_index: usize = 200;
    const selected = slideshow.slides.items[selected_index];
    const item_offset = try source_editor.slideItemInsertionOffset(source_builder.items, selected.pos_in_editor);
    const slide_offset = try source_editor.slideEndOffset(source_builder.items, selected.pos_in_editor);
    try std.testing.expect(try cache.refreshScene(selected_index, selected, item_offset, slide_offset));
    try std.testing.expectEqual(definition_count, cache.library_entries.items.len);
    try std.testing.expectEqual(@as(usize, 1), cache.document_rebuild_count);
    try std.testing.expectEqual(@as(usize, 1), cache.scene_rebuild_count);

    // A steady Studio frame performs no catalog, slide-summary, morph, or
    // library rebuild regardless of deck size.
    try std.testing.expect(!try cache.refreshDocument(11, source_builder.items, slideshow));
    try std.testing.expect(!try cache.refreshScene(selected_index, selected, item_offset, slide_offset));
    try std.testing.expectEqual(@as(usize, 1), cache.document_rebuild_count);
    try std.testing.expectEqual(@as(usize, 1), cache.scene_rebuild_count);

    const next = slideshow.slides.items[selected_index + 1];
    try std.testing.expect(try cache.refreshScene(
        selected_index + 1,
        next,
        try source_editor.slideItemInsertionOffset(source_builder.items, next.pos_in_editor),
        try source_editor.slideEndOffset(source_builder.items, next.pos_in_editor),
    ));
    try std.testing.expectEqual(@as(usize, 1), cache.document_rebuild_count);
    try std.testing.expectEqual(@as(usize, 2), cache.scene_rebuild_count);

    // A new source generation invalidates every borrowed offset/name exactly
    // once, even when the test deliberately reuses identical bytes.
    try std.testing.expect(try cache.refreshDocument(12, source_builder.items, slideshow));
    try std.testing.expectEqual(@as(usize, 2), cache.document_rebuild_count);
}

fn studioLibraryName(
    catalog_opt: ?studio_catalog.Catalog,
    catalog_indices: []const usize,
    workspace_index: usize,
    expected_kind: studio_catalog.Kind,
) ?[]const u8 {
    const entry = studioLibraryEntry(catalog_opt, catalog_indices, workspace_index) orelse return null;
    if (entry.kind != expected_kind) return null;
    return entry.name;
}

fn studioLibraryEntry(
    catalog_opt: ?studio_catalog.Catalog,
    catalog_indices: []const usize,
    workspace_index: usize,
) ?studio_catalog.Entry {
    const catalog = catalog_opt orelse return null;
    if (workspace_index >= catalog_indices.len) return null;
    const catalog_index = catalog_indices[workspace_index];
    if (catalog_index >= catalog.entries.len) return null;
    const entry = catalog.entries[catalog_index];
    if (!entry.placeable) return null;
    return entry;
}

fn reusableNameDefined(name: []const u8) bool {
    var needle_buffer: [192]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buffer, "@push {s}", .{name}) catch return false;
    var cursor: usize = 0;
    const source = G.editor_memory[0..G.source_len];
    while (std.mem.indexOfPos(u8, source, cursor, needle)) |offset| {
        const end = offset + needle.len;
        if ((offset == 0 or source[offset - 1] == '\n') and
            (end == source.len or source[end] == ' ' or source[end] == '\t' or source[end] == '\r' or source[end] == '\n'))
        {
            return true;
        }
        cursor = end;
    }
    return false;
}

fn nextStudioItemId(buffer: []u8) ![]const u8 {
    var serial: usize = G.source_len + 1;
    while (true) : (serial += 1) {
        const candidate = try std.fmt.bufPrint(buffer, "studio_{d}", .{serial});
        var needle_buffer: [96]u8 = undefined;
        const needle = try std.fmt.bufPrint(&needle_buffer, "id={s}", .{candidate});
        if (std.mem.indexOf(u8, G.editor_memory[0..G.source_len], needle) == null) return candidate;
    }
}

fn normalizeBullets(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    var lines = std.mem.splitScalar(u8, input, '\n');
    var first = true;
    while (lines.next()) |raw_line| {
        if (!first) try output.append(allocator, '\n');
        const line = std.mem.trim(u8, raw_line, " \t");
        if (line.len > 0 and !std.mem.startsWith(u8, line, "- ")) try output.appendSlice(allocator, "- ");
        try output.appendSlice(allocator, line);
        first = false;
    }
    return output.toOwnedSlice(allocator);
}

fn validateStudioTextValue(text_value: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(text_value)) return error.InvalidStudioText;
    if (std.mem.indexOfScalar(u8, text_value, '\r') != null) return error.InvalidStudioText;
    if (std.mem.indexOfScalar(u8, text_value, '\n') == null) return;
    var lines = std.mem.splitScalar(u8, text_value, '\n');
    while (lines.next()) |line| {
        if (line.len > 0 and (line[0] == '@' or line[0] == '#')) return error.InvalidStudioText;
    }
}

fn itemTextSnippet(
    allocator: std.mem.Allocator,
    directive_without_text: []const u8,
    text_value: []const u8,
) ![]u8 {
    try validateStudioTextValue(text_value);
    if (std.mem.indexOfScalar(u8, text_value, '\n') == null) {
        return std.fmt.allocPrint(allocator, "{s} text={s}", .{ directive_without_text, text_value });
    }
    return std.fmt.allocPrint(allocator, "{s}\n{s}", .{ directive_without_text, text_value });
}

fn appendStudioToken(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    comptime format: []const u8,
    args: anytype,
) !void {
    var buffer: [160]u8 = undefined;
    const token = try std.fmt.bufPrint(&buffer, format, args);
    try output.appendSlice(allocator, token);
}

fn animationEffectLiteral(effect: animation.Effect) []const u8 {
    return switch (effect) {
        .none => "none",
        .appear => "appear",
        .fade => "fade",
        .slide_left => "slide-left",
        .slide_right => "slide-right",
        .slide_up => "slide-up",
        .slide_down => "slide-down",
    };
}

fn animationGroupingLiteral(grouping: animation.Grouping) []const u8 {
    return switch (grouping) {
        .item => "item",
        .line => "line",
        .bullet => "bullet",
    };
}

fn studioLiteralToken(value: []const u8) ![]const u8 {
    if (value.len == 0 or !std.unicode.utf8ValidateSlice(value) or
        std.mem.indexOfAny(u8, value, " \t\r\n=$") != null)
    {
        return error.UnsupportedComponentDetach;
    }
    return value;
}

/// Materialize the complete effective renderer-facing item into a direct
/// literal @box. Detach is an explicit customization boundary, so values that
/// were previously inherited are intentionally made concrete. Auto-sized
/// images retain zero W/H plus their scale/ratio controls.
fn materializeStudioItem(allocator: std.mem.Allocator, item: *const slides.SlideItem) ![]u8 {
    if (item.kind != .textbox and item.kind != .img) return error.UnsupportedComponentDetach;
    const id = try studioLiteralToken(item.id orelse return error.DetachedItemIdMismatch);

    var directive = std.ArrayList(u8).empty;
    defer directive.deinit(allocator);
    try directive.appendSlice(allocator, "@box id=");
    try directive.appendSlice(allocator, id);
    try appendStudioToken(&directive, allocator, " x={d} y={d} w={d} h={d}", .{
        item.position.x,
        item.position.y,
        item.size.x,
        item.size.y,
    });

    if (item.img_path) |path| {
        try directive.appendSlice(allocator, " img=");
        try directive.appendSlice(allocator, try studioLiteralToken(path));
    }
    if (item.fontSize) |font_size|
        try appendStudioToken(&directive, allocator, " fontsize={d}", .{font_size});
    if (item.color) |color| {
        var color_buffer: [9]u8 = undefined;
        try directive.appendSlice(allocator, " color=");
        try directive.appendSlice(allocator, colorLiteral(&color_buffer, color));
    }
    try directive.appendSlice(allocator, " bg=");
    if (item.background_color) |background| {
        var background_buffer: [9]u8 = undefined;
        try directive.appendSlice(allocator, colorLiteral(&background_buffer, background));
    } else {
        try directive.appendSlice(allocator, "none");
    }
    if (item.line_height_factor) |line_height|
        try appendStudioToken(&directive, allocator, " line_height={d}", .{line_height});
    if (item.underline_width) |underline_width|
        try appendStudioToken(&directive, allocator, " underline_width={d}", .{underline_width});
    if (item.bullet_color) |bullet_color| {
        var bullet_color_buffer: [9]u8 = undefined;
        try directive.appendSlice(allocator, " bullet_color=");
        try directive.appendSlice(allocator, colorLiteral(&bullet_color_buffer, bullet_color));
    }
    if (item.bullet_symbol) |bullet_symbol| {
        try directive.appendSlice(allocator, " bullet_symbol=");
        try directive.appendSlice(allocator, try studioLiteralToken(bullet_symbol));
    }
    if (item.scale) |scale| try appendStudioToken(&directive, allocator, " scale={d}", .{scale});
    if (item.ratio) |ratio| try appendStudioToken(&directive, allocator, " ratio={d}", .{ratio});
    try appendStudioToken(&directive, allocator, " opacity={d} visible={s} locked={s}", .{
        item.opacity,
        if (item.visible) "true" else "false",
        if (item.locked) "true" else "false",
    });
    if (item.text_shadow) |shadow| {
        try directive.appendSlice(allocator, " shadow=");
        if (shadow.enabled) {
            var shadow_buffer: [9]u8 = undefined;
            try directive.appendSlice(allocator, colorLiteral(&shadow_buffer, shadow.color));
        } else {
            try directive.appendSlice(allocator, "none");
        }
        try appendStudioToken(&directive, allocator, " shadow_x={d} shadow_y={d}", .{
            shadow.offset.x,
            shadow.offset.y,
        });
    } else {
        try directive.appendSlice(allocator, " shadow=none");
    }
    if (item.animation) |spec| {
        try directive.appendSlice(allocator, " anim=");
        try directive.appendSlice(allocator, animationEffectLiteral(spec.effect));
        try directive.appendSlice(allocator, " by=");
        try directive.appendSlice(allocator, animationGroupingLiteral(spec.by));
        if (spec.after) |after| try appendStudioToken(&directive, allocator, " after={d}", .{after});
        try appendStudioToken(&directive, allocator, " duration={d}", .{spec.duration});
    }

    if (item.text) |text_value| {
        return itemTextSnippet(allocator, directive.items, text_value);
    }
    return directive.toOwnedSlice(allocator);
}

fn studioItemInsertionOffset(slide: *const slides.Slide, morph_state: ?usize) !usize {
    if (morph_state) |state_index| {
        if (state_index >= slide.morph_states.items.len) return error.InvalidMorphState;
        return source_editor.morphStateEndOffset(
            G.editor_memory[0..G.source_len],
            slide.morph_states.items[state_index].source.line_offset,
        );
    }
    return source_editor.slideItemInsertionOffset(G.editor_memory[0..G.source_len], slide.pos_in_editor);
}

fn studioItemSceneAnchor(slide: *const slides.Slide, morph_state: ?usize) !source_editor.ItemSceneAnchor {
    if (morph_state) |state_index| {
        if (state_index >= slide.morph_states.items.len) return error.InvalidMorphState;
        return .{ .morph_state = slide.morph_states.items[state_index].source.line_offset };
    }
    return .{ .base_slide = slide.pos_in_editor };
}

fn captureStudioClipboard(
    clipboard: *StudioClipboard,
    command: studio.CopyItemsCommand,
    slide: *const slides.Slide,
    morph_state: ?usize,
    items: []const slides.SlideItem,
    resolved_bounds: []const studio.ResolvedBounds,
) !void {
    if (command.count == 0 or command.count > studio.max_selection_items) return error.InvalidStudioClipboardBatch;
    const scene = try studioItemSceneAnchor(slide, morph_state);

    var captured = std.ArrayList(StudioClipboardItem).empty;
    defer captured.deinit(clipboard.allocator);
    errdefer for (captured.items) |item| clipboard.allocator.free(item.snippet);

    for (command.slice()) |target| {
        const item = studioItemByIdentity(items, target.item_identity) orelse return error.StudioItemMissing;
        const item_capture = try source_editor.captureItemForPaste(
            clipboard.allocator,
            G.editor_memory[0..G.source_len],
            scene,
            target.source.line_offset,
        );
        captured.append(clipboard.allocator, .{
            .snippet = item_capture.snippet,
            .component_definition_offset = item_capture.component_definition_offset,
            .position = studio.itemGeometry(item.*, resolved_bounds).position,
        }) catch |err| {
            item_capture.deinit(clipboard.allocator);
            return err;
        };
    }

    // Allocate before clearing so a failed copy never destroys the previous
    // valid clipboard. Once capacity is secured, ownership moves as a unit.
    try clipboard.items.ensureTotalCapacity(clipboard.allocator, captured.items.len);
    clipboard.clear();
    for (captured.items) |item| clipboard.items.appendAssumeCapacity(item);
    captured.items.len = 0;
}

fn currentStudioSceneItems(studio_mode: *const studio.Studio) []const slides.SlideItem {
    if (G.current_slide < 0 or G.current_slide >= G.slideshow.slides.items.len) return &.{};
    const slide = G.slideshow.slides.items[@intCast(G.current_slide)];
    if (studio_mode.active_morph_state) |state_index| {
        if (state_index >= slide.morph_states.items.len) return &.{};
        return slide.morph_states.items[state_index].items.items;
    }
    return if (slide.items) |items| items.items else &.{};
}

fn insertStudioSnippet(
    history: *StudioHistory,
    slide: *const slides.Slide,
    morph_state: ?usize,
    snippet: []const u8,
) !void {
    const offset = try studioItemInsertionOffset(slide, morph_state);
    return recordStudioPatch(history, try source_editor.insertSnippetAt(
        G.allocator,
        G.editor_memory[0..G.source_len],
        offset,
        snippet,
    ));
}

fn deleteStudioItem(
    history: *StudioHistory,
    item: *const slides.SlideItem,
    directive_offset: usize,
) !void {
    const source = G.editor_memory[0..G.source_len];
    const patch = if (item.id) |id|
        try source_editor.deleteItemCascadingMorphMutations(G.allocator, source, directive_offset, id)
    else
        try source_editor.deleteItem(G.allocator, source, directive_offset);
    try recordStudioPatch(history, patch);
}

fn applyStudioLiteralAttribute(
    history: *StudioHistory,
    slide: *const slides.Slide,
    morph_state: ?usize,
    item: *const slides.SlideItem,
    edit_scope: studio.EditScope,
    key: []const u8,
    value: []const u8,
) !void {
    var source_ref = item.source;
    if (morph_state) |state_index| {
        switch (morphItemEditTarget(slide, state_index, item)) {
            .patch => |patch_source| source_ref = patch_source,
            .insert_local => {
                const id = item.id orelse return error.MorphItemNeedsId;
                const directive = try std.fmt.allocPrint(G.allocator, "@set {s} {s}={s}", .{ id, key, value });
                defer G.allocator.free(directive);
                return insertStudioSnippet(history, slide, morph_state, directive);
            },
        }
    } else if (edit_scope == .local_instance) {
        const id = item.id orelse return error.TemplateInstanceItemNeedsId;
        if (item.instance_source) |instance_source| {
            if (instance_source.patchable) {
                const patches = [_]source_editor.LiteralAttributePatch{.{ .key = key, .value = value }};
                return recordStudioPatch(history, try source_editor.patchSlideTemplateOverrideAttributes(
                    G.allocator,
                    G.editor_memory[0..G.source_len],
                    slide.pos_in_editor,
                    instance_source.line_offset,
                    id,
                    &patches,
                ));
            }
        }
        const directive = try std.fmt.allocPrint(G.allocator, "@set {s} {s}={s}", .{ id, key, value });
        defer G.allocator.free(directive);
        return insertStudioTemplateOverride(history, slide, directive);
    } else if (edit_scope == .shared_template) {
        source_ref = item.source;
    }
    if (!source_ref.patchable) return error.StudioItemHasNoPatchableSource;
    const patches = [_]source_editor.LiteralAttributePatch{.{ .key = key, .value = value }};
    return recordStudioPatch(history, try source_editor.patchLiteralAttributes(
        G.allocator,
        G.editor_memory[0..G.source_len],
        source_ref.line_offset,
        &patches,
    ));
}

/// One-shot real source edit for repeatable incremental-render QA. It uses the
/// same patch/history/reparse boundary as the Properties inspector, then lets
/// the following frame report which render-graph region was rebuilt.
fn applyDiagnosticIncrementalEdit(history: *StudioHistory, slide_index: usize) !void {
    if (slide_index >= G.slideshow.slides.items.len) return error.InvalidDiagnosticSlideIndex;
    const slide = G.slideshow.slides.items[slide_index];
    const items = if (slide.items) |*list| list else return error.InvalidDiagnosticSlideIndex;
    for (items.items) |*item| {
        if (item.kind != .textbox or item.color == null or
            item.source.scope != .direct or !item.source.patchable)
            continue;
        return applyStudioLiteralAttribute(
            history,
            slide,
            null,
            item,
            .direct,
            "color",
            "#ff5ca8ff",
        );
    }
    return error.InvalidDiagnosticSlideIndex;
}

fn applyStudioText(
    history: *StudioHistory,
    slide: *const slides.Slide,
    morph_state: ?usize,
    item: *const slides.SlideItem,
    edit_scope: studio.EditScope,
    text_value: []const u8,
) !void {
    var source_ref = item.source;
    if (morph_state) |state_index| {
        switch (morphItemEditTarget(slide, state_index, item)) {
            .patch => |patch_source| source_ref = patch_source,
            .insert_local => {
                const id = item.id orelse return error.MorphItemNeedsId;
                const directive = try std.fmt.allocPrint(G.allocator, "@set {s}", .{id});
                defer G.allocator.free(directive);
                const snippet = try itemTextSnippet(G.allocator, directive, text_value);
                defer G.allocator.free(snippet);
                return insertStudioSnippet(history, slide, morph_state, snippet);
            },
        }
    } else if (edit_scope == .local_instance) {
        const id = item.id orelse return error.TemplateInstanceItemNeedsId;
        if (item.instance_source) |instance_source| {
            if (instance_source.patchable) {
                return recordStudioPatch(history, try source_editor.patchSlideTemplateOverrideText(
                    G.allocator,
                    G.editor_memory[0..G.source_len],
                    slide.pos_in_editor,
                    instance_source.line_offset,
                    id,
                    text_value,
                ));
            }
        }
        const directive = try std.fmt.allocPrint(G.allocator, "@set {s}", .{id});
        defer G.allocator.free(directive);
        const snippet = try itemTextSnippet(G.allocator, directive, text_value);
        defer G.allocator.free(snippet);
        return insertStudioTemplateOverride(history, slide, snippet);
    } else if (edit_scope == .shared_template) {
        source_ref = item.source;
    }
    if (!source_ref.patchable) return error.StudioItemHasNoPatchableSource;
    return recordStudioPatch(history, try source_editor.patchItemText(
        G.allocator,
        G.editor_memory[0..G.source_len],
        source_ref.line_offset,
        text_value,
    ));
}

fn applyStudioLockEdit(
    history: *StudioHistory,
    command: studio.SetLockedCommand,
    slide: *const slides.Slide,
    morph_state: ?usize,
    items: []const slides.SlideItem,
) !void {
    if (command.count == 0 or command.count > studio.max_selection_items) return error.InvalidStudioLockBatch;
    const source = G.editor_memory[0..G.source_len];
    const value = if (command.locked) "true" else "false";
    var edits: [studio.max_selection_items]source_editor.LiteralSourceEdit = undefined;
    var patches: [studio.max_selection_items][1]source_editor.LiteralAttributePatch = undefined;
    var snippets: [studio.max_selection_items]?[]u8 = @splat(null);
    defer for (snippets[0..command.count]) |snippet| if (snippet) |owned| G.allocator.free(owned);

    for (command.slice(), 0..) |target, index| {
        const item = studioItemByIdentity(items, target.item_identity) orelse return error.StudioItemMissing;
        patches[index][0] = .{ .key = "locked", .value = value };
        var source_ref = item.source;

        if (morph_state) |state_index| {
            if (state_index >= slide.morph_states.items.len) return error.InvalidMorphState;
            switch (morphItemEditTarget(slide, state_index, item)) {
                .patch => |patch_source| {
                    if (item.state_source_state != null and item.state_source_state.? == state_index) {
                        try source_editor.validateMorphMutationTarget(
                            source,
                            slide.morph_states.items[state_index].source.line_offset,
                            patch_source.line_offset,
                            item.id orelse return error.MorphItemNeedsId,
                        );
                    }
                    source_ref = patch_source;
                },
                .insert_local => {
                    const id = item.id orelse return error.MorphItemNeedsId;
                    snippets[index] = try std.fmt.allocPrint(G.allocator, "@set {s} locked={s}", .{ id, value });
                    edits[index] = .{ .insert = .{
                        .insertion_offset = try source_editor.morphStateEndOffset(
                            source,
                            slide.morph_states.items[state_index].source.line_offset,
                        ),
                        .snippet = snippets[index].?,
                    } };
                    continue;
                },
            }
        } else switch (target.edit_scope) {
            .local_instance => {
                const id = item.id orelse return error.TemplateInstanceItemNeedsId;
                if (item.instance_source) |instance_source| {
                    if (instance_source.patchable) {
                        try source_editor.validateSlideTemplateOverrideTarget(
                            source,
                            slide.pos_in_editor,
                            instance_source.line_offset,
                            id,
                        );
                        source_ref = instance_source;
                        edits[index] = .{ .patch = .{
                            .directive_offset = source_ref.line_offset,
                            .patches = patches[index][0..],
                        } };
                        continue;
                    }
                }
                snippets[index] = try std.fmt.allocPrint(G.allocator, "@set {s} locked={s}", .{ id, value });
                edits[index] = .{ .insert = .{
                    .insertion_offset = try source_editor.slideTemplateOverrideInsertionOffset(
                        source,
                        slide.pos_in_editor,
                        snippets[index].?,
                    ),
                    .snippet = snippets[index].?,
                } };
                continue;
            },
            .shared_template => source_ref = item.source,
            .direct => source_ref = target.source,
        }

        if (source_ref.scope == .none or !source_ref.patchable) return error.StudioItemHasNoPatchableSource;
        edits[index] = .{ .patch = .{
            .directive_offset = source_ref.line_offset,
            .patches = patches[index][0..],
        } };
    }

    return recordStudioPatch(history, try source_editor.applyLiteralEdits(G.allocator, source, edits[0..command.count]));
}

fn planStudioVisibilityEdits(
    source: []const u8,
    command: studio.SetVisibleCommand,
    slide: *const slides.Slide,
    morph_state: ?usize,
    items: []const slides.SlideItem,
    edits: *[studio.max_selection_items]source_editor.VisibilitySourceEdit,
) ![]const source_editor.VisibilitySourceEdit {
    if (command.count == 0 or command.count > studio.max_selection_items) return error.InvalidStudioVisibilityBatch;

    for (command.slice(), 0..) |target, index| {
        const item = studioItemByIdentity(items, target.item_identity) orelse return error.StudioItemMissing;
        if (item.kind == .background) return error.ItemHasNoVisibility;
        // Visibility is a persistent property mutation. A lock protects it in
        // the same way as geometry, text, color, opacity, and layer order.
        if (item.locked) return error.StudioItemLocked;

        if (morph_state) |state_index| {
            if (state_index >= slide.morph_states.items.len) return error.InvalidMorphState;
            switch (morphItemEditTarget(slide, state_index, item)) {
                .patch => |patch_source| {
                    if (item.state_source_state != null and item.state_source_state.? == state_index) {
                        const id = item.id orelse return error.MorphItemNeedsId;
                        try source_editor.validateMorphMutationTarget(
                            source,
                            slide.morph_states.items[state_index].source.line_offset,
                            patch_source.line_offset,
                            id,
                        );
                        edits[index] = .{ .rewrite_mutation = .{
                            .directive_offset = patch_source.line_offset,
                            .item_id = id,
                            .visible = command.visible,
                        } };
                    } else {
                        if (patch_source.scope == .none or !patch_source.patchable) {
                            return error.StudioItemHasNoPatchableSource;
                        }
                        edits[index] = .{ .patch_item = .{
                            .directive_offset = patch_source.line_offset,
                            .visible = command.visible,
                        } };
                    }
                },
                .insert_local => {
                    const id = item.id orelse return error.MorphItemNeedsId;
                    edits[index] = .{ .insert_mutation = .{
                        .insertion_offset = try source_editor.morphStateEndOffset(
                            source,
                            slide.morph_states.items[state_index].source.line_offset,
                        ),
                        .item_id = id,
                        .visible = command.visible,
                    } };
                },
            }
            continue;
        }

        switch (target.edit_scope) {
            .local_instance => {
                const id = item.id orelse return error.TemplateInstanceItemNeedsId;
                if (item.instance_source) |instance_source| {
                    if (!instance_source.patchable) return error.StudioItemHasNoPatchableSource;
                    try source_editor.validateSlideTemplateOverrideTarget(
                        source,
                        slide.pos_in_editor,
                        instance_source.line_offset,
                        id,
                    );
                    edits[index] = .{ .rewrite_mutation = .{
                        .directive_offset = instance_source.line_offset,
                        .item_id = id,
                        .visible = command.visible,
                    } };
                } else {
                    edits[index] = .{ .insert_mutation = .{
                        .insertion_offset = try source_editor.slideTemplateVisibilityInsertionOffset(
                            source,
                            slide.pos_in_editor,
                            id,
                        ),
                        .item_id = id,
                        .visible = command.visible,
                    } };
                }
            },
            .shared_template, .direct => {
                const source_ref = if (target.edit_scope == .shared_template) item.source else item.effectiveBaseSource();
                if (source_ref.scope == .none or !source_ref.patchable) {
                    return error.StudioItemHasNoPatchableSource;
                }
                edits[index] = .{ .patch_item = .{
                    .directive_offset = source_ref.line_offset,
                    .visible = command.visible,
                } };
            },
        }
    }

    return edits[0..command.count];
}

fn applyStudioVisibilityEdit(
    history: *StudioHistory,
    command: studio.SetVisibleCommand,
    slide: *const slides.Slide,
    morph_state: ?usize,
    items: []const slides.SlideItem,
) !void {
    const source = G.editor_memory[0..G.source_len];
    var edits: [studio.max_selection_items]source_editor.VisibilitySourceEdit = undefined;
    const planned = try planStudioVisibilityEdits(
        source,
        command,
        slide,
        morph_state,
        items,
        &edits,
    );
    return recordStudioPatch(history, try source_editor.applyVisibilityEdits(
        G.allocator,
        source,
        planned,
    ));
}

test "Studio visibility planner preserves direct template-local and shared ownership" {
    const allocator = std.testing.allocator;
    const source =
        "@box id=hero visible=true text=Hero\n" ++
        "@box id=badge visible=true text=Badge\n" ++
        "@pushslide layout\n" ++
        "@popslide layout\n" ++
        "@show hero x=100\n" ++
        "@box id=local text=Local\n" ++
        "@popslide layout\n";

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const slideshow = try slides.SlideShow.new(arena.allocator());
    const context = try parser.constructSlidesFromBuf(source, slideshow, arena.allocator());
    defer context.deinit();
    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    const first_slide = slideshow.slides.items[0];
    const items = first_slide.items.?.items;
    try std.testing.expectEqual(@as(usize, 3), items.len);

    var command = studio.SetVisibleCommand{ .count = 3, .visible = false };
    command.targets[0] = .{
        .item_identity = items[0].identity,
        .source = items[0].effectiveBaseSource(),
        .edit_scope = .local_instance,
    };
    command.targets[1] = .{
        .item_identity = items[1].identity,
        .source = items[1].effectiveBaseSource(),
        .edit_scope = .local_instance,
    };
    command.targets[2] = .{
        .item_identity = items[2].identity,
        .source = items[2].effectiveBaseSource(),
        .edit_scope = .direct,
    };
    var edits: [studio.max_selection_items]source_editor.VisibilitySourceEdit = undefined;
    const planned = try planStudioVisibilityEdits(
        source,
        command,
        first_slide,
        null,
        items,
        &edits,
    );
    const hidden = try source_editor.applyVisibilityEdits(allocator, source, planned);
    defer hidden.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, hidden.source, "@hide hero x=100") != null);
    try std.testing.expect(std.mem.indexOf(u8, hidden.source, "@hide badge") != null);
    try std.testing.expect(std.mem.indexOf(u8, hidden.source, "@box id=local visible=false text=Local") != null);

    var hidden_arena = std.heap.ArenaAllocator.init(allocator);
    defer hidden_arena.deinit();
    const hidden_slideshow = try slides.SlideShow.new(hidden_arena.allocator());
    const hidden_context = try parser.constructSlidesFromBuf(hidden.source, hidden_slideshow, hidden_arena.allocator());
    defer hidden_context.deinit();
    try std.testing.expectEqual(@as(usize, 0), hidden_context.parser_errors.items.len);
    for (hidden_slideshow.slides.items[0].items.?.items) |item| try std.testing.expect(!item.visible);
    for (hidden_slideshow.slides.items[1].items.?.items) |item| try std.testing.expect(item.visible);

    // A shared edit patches the @pushslide-owned creation directive. The
    // first instance's local @show remains effective, while the uncustomized
    // second instance receives the new shared value.
    var shared_command = studio.SetVisibleCommand{ .count = 1, .visible = false };
    shared_command.targets[0] = .{
        .item_identity = items[0].identity,
        .source = items[0].source,
        .edit_scope = .shared_template,
    };
    const shared_planned = try planStudioVisibilityEdits(
        source,
        shared_command,
        first_slide,
        null,
        items,
        &edits,
    );
    const shared_hidden = try source_editor.applyVisibilityEdits(allocator, source, shared_planned);
    defer shared_hidden.deinit(allocator);

    var shared_arena = std.heap.ArenaAllocator.init(allocator);
    defer shared_arena.deinit();
    const shared_slideshow = try slides.SlideShow.new(shared_arena.allocator());
    const shared_context = try parser.constructSlidesFromBuf(shared_hidden.source, shared_slideshow, shared_arena.allocator());
    defer shared_context.deinit();
    try std.testing.expectEqual(@as(usize, 0), shared_context.parser_errors.items.len);
    try std.testing.expect(shared_slideshow.slides.items[0].items.?.items[0].visible);
    try std.testing.expect(!shared_slideshow.slides.items[1].items.?.items[0].visible);
}

test "Studio visibility planner targets current morph ownership and inherited snapshots" {
    const allocator = std.testing.allocator;
    const source =
        "@slide\n" ++
        "@box id=base text=Base\n" ++
        "@state(morph)\n" ++
        "@set base x=100 color=#010203ff\n" ++
        "@box id=born text=Born\n" ++
        "@state(morph)\n";

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const slideshow = try slides.SlideShow.new(arena.allocator());
    const context = try parser.constructSlidesFromBuf(source, slideshow, arena.allocator());
    defer context.deinit();
    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    const slide = slideshow.slides.items[0];
    const first_state = slide.morph_states.items[0].items.items;

    var hide = studio.SetVisibleCommand{ .count = 2, .visible = false };
    for (first_state, 0..) |item, index| hide.targets[index] = .{
        .item_identity = item.identity,
        .source = item.effectiveSource(),
        .edit_scope = .direct,
    };
    var edits: [studio.max_selection_items]source_editor.VisibilitySourceEdit = undefined;
    const planned_hide = try planStudioVisibilityEdits(
        source,
        hide,
        slide,
        0,
        first_state,
        &edits,
    );
    const hidden = try source_editor.applyVisibilityEdits(allocator, source, planned_hide);
    defer hidden.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, hidden.source, "@hide base x=100 color=#010203ff") != null);
    try std.testing.expect(std.mem.indexOf(u8, hidden.source, "@box id=born visible=false text=Born") != null);

    var hidden_arena = std.heap.ArenaAllocator.init(allocator);
    defer hidden_arena.deinit();
    const hidden_slideshow = try slides.SlideShow.new(hidden_arena.allocator());
    const hidden_context = try parser.constructSlidesFromBuf(hidden.source, hidden_slideshow, hidden_arena.allocator());
    defer hidden_context.deinit();
    try std.testing.expectEqual(@as(usize, 0), hidden_context.parser_errors.items.len);
    const hidden_slide = hidden_slideshow.slides.items[0];
    for (hidden_slide.morph_states.items[0].items.items) |item| try std.testing.expect(!item.visible);

    const inherited = hidden_slide.morph_states.items[1].items.items;
    var show_inherited = studio.SetVisibleCommand{ .count = 1, .visible = true };
    show_inherited.targets[0] = .{
        .item_identity = inherited[0].identity,
        .source = inherited[0].effectiveSource(),
        .edit_scope = .direct,
    };
    const planned_show = try planStudioVisibilityEdits(
        hidden.source,
        show_inherited,
        hidden_slide,
        1,
        inherited,
        &edits,
    );
    const shown = try source_editor.applyVisibilityEdits(allocator, hidden.source, planned_show);
    defer shown.deinit(allocator);
    try std.testing.expect(std.mem.endsWith(u8, shown.source, "@state(morph)\n@show base\n"));

    var shown_arena = std.heap.ArenaAllocator.init(allocator);
    defer shown_arena.deinit();
    const shown_slideshow = try slides.SlideShow.new(shown_arena.allocator());
    const shown_context = try parser.constructSlidesFromBuf(shown.source, shown_slideshow, shown_arena.allocator());
    defer shown_context.deinit();
    try std.testing.expectEqual(@as(usize, 0), shown_context.parser_errors.items.len);
    const shown_second = shown_slideshow.slides.items[0].morph_states.items[1].items.items;
    try std.testing.expect(shown_second[0].visible);
    try std.testing.expect(!shown_second[1].visible);
}

test "Studio visibility planner supports component instances and rejects locked batches" {
    const allocator = std.testing.allocator;
    const source =
        "@box id=content text=Component\n" ++
        "@push card\n" ++
        "@slide\n" ++
        "@pop card id=instance x=20 y=30\n" ++
        "@box id=locked locked=true text=Guarded\n";

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const slideshow = try slides.SlideShow.new(arena.allocator());
    const context = try parser.constructSlidesFromBuf(source, slideshow, arena.allocator());
    defer context.deinit();
    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    const slide = slideshow.slides.items[0];
    const items = slide.items.?.items;
    try std.testing.expectEqual(slides.SourceScope.component_instance, items[0].source.scope);

    var edits: [studio.max_selection_items]source_editor.VisibilitySourceEdit = undefined;
    var component = studio.SetVisibleCommand{ .count = 1, .visible = false };
    component.targets[0] = .{
        .item_identity = items[0].identity,
        .source = items[0].source,
        .edit_scope = .direct,
    };
    const planned = try planStudioVisibilityEdits(
        source,
        component,
        slide,
        null,
        items,
        &edits,
    );
    const hidden = try source_editor.applyVisibilityEdits(allocator, source, planned);
    defer hidden.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, hidden.source, "@pop card id=instance x=20 y=30 visible=false") != null);

    var locked = studio.SetVisibleCommand{ .count = 2, .visible = false };
    for (items, 0..) |item, index| locked.targets[index] = .{
        .item_identity = item.identity,
        .source = item.source,
        .edit_scope = .direct,
    };
    try std.testing.expectError(error.StudioItemLocked, planStudioVisibilityEdits(
        source,
        locked,
        slide,
        null,
        items,
        &edits,
    ));
}

const StudioSemanticEditResult = struct {
    source_changed: bool = true,
    slide_index: ?usize = null,
    morph_scene: ?studio.MorphSceneCommand = null,
    /// Non-structural property edits preserve item identity/order. Leaving the
    /// source-bound selection in Studio lets it rebind on the next frame,
    /// including id-less literal items, so inspector workflows can edit
    /// several fields without reselecting after every commit.
    preserve_selection: bool = false,
};

fn applyStudioSemanticEdit(
    history: *StudioHistory,
    command: studio.SemanticCommand,
    prompted_text: ?[]const u8,
    slide_opt: ?*slides.Slide,
    morph_state: ?usize,
    items: []const slides.SlideItem,
    resolved_bounds: []const studio.ResolvedBounds,
    catalog_opt: ?studio_catalog.Catalog,
    catalog_indices: []const usize,
    clipboard: *StudioClipboard,
    selection_ids: *StudioSelectionIds,
) !StudioSemanticEditResult {
    const slide = slide_opt orelse return error.NoStudioSlide;
    switch (command) {
        .save_document, .save_document_copy, .undo, .redo, .pair_presenter_phone => return error.NonSourceStudioCommand,
        .edit_speaker_notes => {
            const notes = prompted_text orelse return error.StudioPromptMissing;
            if (std.mem.eql(u8, notes, slide.speaker_notes orelse "")) return .{ .source_changed = false };
            try recordStudioPatch(history, try source_editor.setSpeakerNotes(
                G.allocator,
                G.editor_memory[0..G.source_len],
                slide.pos_in_editor,
                notes,
            ));
            return .{ .preserve_selection = true };
        },
        .create_starter_deck => |preset| {
            if (!pristineUntitledDeck()) return error.StarterDeckUnavailable;
            try recordStudioPatch(history, try starterDeckPatch(
                G.allocator,
                G.editor_memory[0..G.source_len],
                preset,
            ));
            return .{ .slide_index = 0 };
        },
        .add_item => |add| {
            var id_buffer: [64]u8 = undefined;
            const id = try nextStudioItemId(&id_buffer);
            var directive_buffer: [512]u8 = undefined;
            const directive = switch (add.kind) {
                .text, .bullets => try std.fmt.bufPrint(
                    &directive_buffer,
                    "@box id={s} x={d} y={d} w={d} h={d}",
                    .{ id, add.position.x, add.position.y, add.suggested_size.x, add.suggested_size.y },
                ),
                .image => blk: {
                    const path = prompted_text orelse return error.StudioPromptMissing;
                    if (path.len == 0 or std.mem.indexOfAny(u8, path, " \t\r\n") != null) return error.InvalidStudioImagePath;
                    break :blk try std.fmt.bufPrint(
                        &directive_buffer,
                        "@box id={s} img={s} x={d} y={d} w={d} h={d}",
                        .{ id, path, add.position.x, add.position.y, add.suggested_size.x, add.suggested_size.y },
                    );
                },
                .shape => blk: {
                    var color_buffer: [9]u8 = undefined;
                    const color = colorLiteral(&color_buffer, studio.paletteColor(add.suggested_color orelse .blue));
                    break :blk try std.fmt.bufPrint(
                        &directive_buffer,
                        "@box id={s} x={d} y={d} w={d} h={d} color={s}",
                        .{ id, add.position.x, add.position.y, add.suggested_size.x, add.suggested_size.y, color },
                    );
                },
            };
            if (add.kind == .text or add.kind == .bullets) {
                const raw_text = prompted_text orelse return error.StudioPromptMissing;
                const owned_text = if (add.kind == .bullets)
                    try normalizeBullets(G.allocator, raw_text)
                else
                    try G.allocator.dupe(u8, raw_text);
                defer G.allocator.free(owned_text);
                const snippet = try itemTextSnippet(G.allocator, directive, owned_text);
                defer G.allocator.free(snippet);
                try insertStudioSnippet(history, slide, morph_state, snippet);
            } else {
                try insertStudioSnippet(history, slide, morph_state, directive);
            }
        },
        .duplicate_item => |target| {
            const item = studioItemByIdentity(items, target.item_identity) orelse return error.StudioItemMissing;
            if (item.kind == .crowd) return error.UnsupportedItemDuplication;

            const source_ref: slides.SourceRef = if (morph_state) |state_index| blk: {
                if (!itemBornInMorphState(slide, state_index, item) or item.state_source != null) {
                    return error.MorphItemDuplicationUnsupported;
                }
                break :blk item.source;
            } else switch (target.edit_scope) {
                .local_instance => return error.TemplateInstanceDuplicationUnsupported,
                .direct => target.source,
                .shared_template => item.source,
            };
            if (!source_ref.patchable) return error.StudioItemHasNoPatchableSource;

            var id_buffer: [64]u8 = undefined;
            const id = try nextStudioItemId(&id_buffer);
            const geometry = if (target.edit_scope == .shared_template)
                if (item.sharedTemplateValues()) |shared|
                    studio.Geometry{ .position = shared.position, .size = shared.size }
                else
                    return error.SharedTemplateValuesMissing
            else
                studio.itemGeometry(item.*, resolved_bounds);
            try selection_ids.appendCopy(id);
            try recordStudioPatch(history, try source_editor.duplicateItem(
                G.allocator,
                G.editor_memory[0..G.source_len],
                source_ref.line_offset,
                id,
                .{ .x = geometry.position.x + 20, .y = geometry.position.y + 20 },
            ));
        },
        .duplicate_items => |batch| {
            if (batch.count == 0 or batch.count > studio.max_selection_items) {
                return error.InvalidStudioClipboardBatch;
            }
            const scene = try studioItemSceneAnchor(slide, morph_state);
            var targets: [studio.max_selection_items]source_editor.DuplicateItemTarget = undefined;
            for (batch.slice(), 0..) |target, index| {
                const item = studioItemByIdentity(items, target.item_identity) orelse return error.StudioItemMissing;
                if (item.locked or target.edit_scope != .direct or !target.source.patchable) {
                    return error.UnsupportedItemDuplication;
                }
                if (morph_state) |state_index| {
                    if (!itemBornInMorphState(slide, state_index, item) or item.state_source != null) {
                        return error.MorphItemDuplicationUnsupported;
                    }
                } else switch (target.source.scope) {
                    .direct, .component_instance => {},
                    else => return error.UnsupportedItemDuplication,
                }

                try selection_ids.appendNextUnique();
                const geometry = studio.itemGeometry(item.*, resolved_bounds);
                targets[index] = .{
                    .directive_offset = target.source.line_offset,
                    .new_id = selection_ids.values.items[index],
                    .placement = .{
                        .x = geometry.position.x + 20,
                        .y = geometry.position.y + 20,
                    },
                };
            }
            try recordStudioPatch(history, try source_editor.duplicateItems(
                G.allocator,
                G.editor_memory[0..G.source_len],
                scene,
                scene,
                targets[0..batch.count],
            ));
        },
        .delete_item => |target| {
            const item = studioItemByIdentity(items, target.item_identity) orelse return error.StudioItemMissing;
            if (morph_state) |state_index| {
                if (itemBornInMorphState(slide, state_index, item)) {
                    try deleteStudioItem(history, item, item.source.line_offset);
                } else {
                    const id = item.id orelse return error.MorphItemNeedsId;
                    const directive = try std.fmt.allocPrint(G.allocator, "@hide {s}", .{id});
                    defer G.allocator.free(directive);
                    try insertStudioSnippet(history, slide, morph_state, directive);
                }
            } else {
                switch (target.edit_scope) {
                    .direct => try deleteStudioItem(history, item, target.source.line_offset),
                    .shared_template => {
                        try recordStudioPatch(history, try source_editor.deleteSharedSlideTemplateItem(
                            G.allocator,
                            G.editor_memory[0..G.source_len],
                            slide.pos_in_editor,
                            item.source.line_offset,
                            item.id,
                        ));
                    },
                    .local_instance => {
                        const id = item.id orelse return error.TemplateInstanceItemNeedsId;
                        const directive = try std.fmt.allocPrint(G.allocator, "@hide {s}", .{id});
                        defer G.allocator.free(directive);
                        try insertStudioTemplateOverride(history, slide, directive);
                    },
                }
            }
        },
        .delete_items => |batch| {
            if (batch.count == 0 or batch.count > studio.max_selection_items) {
                return error.UnsupportedBatchDeletion;
            }
            const scene = try studioItemSceneAnchor(slide, morph_state);
            var targets: [studio.max_selection_items]source_editor.DeleteItemTarget = undefined;
            for (batch.slice(), 0..) |target, index| {
                const item = studioItemByIdentity(items, target.item_identity) orelse return error.StudioItemMissing;
                if (item.locked or target.edit_scope == .shared_template) {
                    return error.UnsupportedBatchDeletion;
                }
                targets[index] = if (morph_state) |state_index| blk: {
                    if (itemBornInMorphState(slide, state_index, item)) {
                        break :blk .{ .authored = .{
                            .directive_offset = item.source.line_offset,
                            .item_id = item.id,
                        } };
                    }
                    break :blk .{ .hide = .{
                        .item_id = item.id orelse return error.MorphItemNeedsId,
                    } };
                } else switch (target.edit_scope) {
                    .direct => .{ .authored = .{
                        .directive_offset = target.source.line_offset,
                        .item_id = item.id,
                    } },
                    .local_instance => .{ .hide = .{
                        .item_id = item.id orelse return error.TemplateInstanceItemNeedsId,
                    } },
                    .shared_template => unreachable,
                };
            }
            try recordStudioPatch(history, try source_editor.deleteItems(
                G.allocator,
                G.editor_memory[0..G.source_len],
                scene,
                targets[0..batch.count],
            ));
        },
        .edit_text => |target| {
            const item = studioItemByIdentity(items, target.item_identity) orelse return error.StudioItemMissing;
            if (item.kind != .textbox and item.kind != .crowd) return error.ItemHasNoEditableText;
            if (item.locked) return error.StudioItemLocked;
            try applyStudioText(
                history,
                slide,
                morph_state,
                item,
                target.edit_scope,
                prompted_text orelse return error.StudioPromptMissing,
            );
            return .{ .preserve_selection = true };
        },
        .edit_numeric_geometry => |request| {
            const item = studioItemByIdentity(items, request.target.item_identity) orelse return error.StudioItemMissing;
            if (item.kind == .background) return error.ItemHasNoEditableGeometry;
            if (item.locked) return error.StudioItemLocked;
            const parsed = try parseStudioFiniteFloat(prompted_text orelse return error.StudioPromptMissing);
            const key: []const u8 = switch (request.field) {
                .x => "x",
                .y => "y",
                .width => "w",
                .height => "h",
            };
            if ((request.field == .width or request.field == .height) and parsed < studio.default_min_item_size) {
                return error.InvalidStudioDimension;
            }
            var value_buffer: [64]u8 = undefined;
            const value = try formatStudioFloat(&value_buffer, parsed);
            try applyStudioLiteralAttribute(
                history,
                slide,
                morph_state,
                item,
                request.target.edit_scope,
                key,
                value,
            );
            return .{ .preserve_selection = true };
        },
        .set_foreground => |change| {
            const item = studioItemByIdentity(items, change.target.item_identity) orelse return error.StudioItemMissing;
            if (item.kind != .textbox) return error.ItemHasNoForegroundColor;
            if (item.locked) return error.StudioItemLocked;
            var color_buffer: [9]u8 = undefined;
            const color = colorLiteral(&color_buffer, studio.paletteColor(change.color));
            try applyStudioLiteralAttribute(history, slide, morph_state, item, change.target.edit_scope, "color", color);
            return .{ .preserve_selection = true };
        },
        .set_custom_foreground => |target| {
            const item = studioItemByIdentity(items, target.item_identity) orelse return error.StudioItemMissing;
            if (item.kind != .textbox) return error.ItemHasNoForegroundColor;
            if (item.locked) return error.StudioItemLocked;
            var color_buffer: [9]u8 = undefined;
            const color = try canonicalStudioColor(prompted_text orelse return error.StudioPromptMissing, &color_buffer);
            try applyStudioLiteralAttribute(history, slide, morph_state, item, target.edit_scope, "color", color);
            return .{ .preserve_selection = true };
        },
        .set_background => |change| {
            const item = studioItemByIdentity(items, change.target.item_identity) orelse return error.StudioItemMissing;
            if (item.kind == .background) return error.ItemHasNoBackgroundColor;
            if (item.locked) return error.StudioItemLocked;
            var color_buffer: [9]u8 = undefined;
            const color = colorLiteral(&color_buffer, studio.paletteColor(change.color));
            try applyStudioLiteralAttribute(
                history,
                slide,
                morph_state,
                item,
                change.target.edit_scope,
                "bg",
                color,
            );
            return .{ .preserve_selection = true };
        },
        .set_custom_background => |target| {
            const item = studioItemByIdentity(items, target.item_identity) orelse return error.StudioItemMissing;
            if (item.kind == .background) return error.ItemHasNoBackgroundColor;
            if (item.locked) return error.StudioItemLocked;
            var color_buffer: [9]u8 = undefined;
            const color = try canonicalStudioColor(prompted_text orelse return error.StudioPromptMissing, &color_buffer);
            try applyStudioLiteralAttribute(history, slide, morph_state, item, target.edit_scope, "bg", color);
            return .{ .preserve_selection = true };
        },
        .set_font_size => |target| {
            const item = studioItemByIdentity(items, target.item_identity) orelse return error.StudioItemMissing;
            if (item.kind != .textbox) return error.ItemHasNoFontSize;
            if (item.locked) return error.StudioItemLocked;
            var value_buffer: [32]u8 = undefined;
            const value = try canonicalStudioFontSize(prompted_text orelse return error.StudioPromptMissing, &value_buffer);
            try applyStudioLiteralAttribute(history, slide, morph_state, item, target.edit_scope, "fontsize", value);
            return .{ .preserve_selection = true };
        },
        .set_opacity => |target| {
            const item = studioItemByIdentity(items, target.item_identity) orelse return error.StudioItemMissing;
            if (item.kind == .background) return error.ItemHasNoOpacity;
            if (item.locked) return error.StudioItemLocked;
            var value_buffer: [64]u8 = undefined;
            const value = try canonicalStudioOpacity(prompted_text orelse return error.StudioPromptMissing, &value_buffer);
            try applyStudioLiteralAttribute(history, slide, morph_state, item, target.edit_scope, "opacity", value);
            return .{ .preserve_selection = true };
        },
        .clear_background => |target| {
            const item = studioItemByIdentity(items, target.item_identity) orelse return error.StudioItemMissing;
            if (item.kind == .background) return error.ItemHasNoBackgroundColor;
            if (item.locked) return error.StudioItemLocked;
            try applyStudioLiteralAttribute(history, slide, morph_state, item, target.edit_scope, "bg", "none");
            return .{ .preserve_selection = true };
        },
        .reorder_items => |layer| {
            if (layer.count == 0 or layer.count > studio.max_selection_items) return error.InvalidStudioLayerBatch;
            if (layerCommandCrossesLocked(layer, items)) return error.LockedLayerBarrier;
            const scene = try studioItemSceneAnchor(slide, morph_state);
            var offsets: [studio.max_selection_items]usize = undefined;
            var all_have_ids = true;
            for (layer.slice(), 0..) |target, index| {
                const item = studioItemByIdentity(items, target.item_identity) orelse return error.StudioItemMissing;
                offsets[index] = target.source.line_offset;
                if (item.id) |id| {
                    try selection_ids.appendCopy(id);
                } else {
                    all_have_ids = false;
                }
            }
            if (!all_have_ids) selection_ids.clear();
            const move: source_editor.LayerMove = switch (layer.action) {
                .back => .to_back,
                .down => .backward,
                .up => .forward,
                .front => .to_front,
            };
            const patch = source_editor.reorderItemsLayer(
                G.allocator,
                G.editor_memory[0..G.source_len],
                scene,
                offsets[0..layer.count],
                move,
            ) catch |err| switch (err) {
                error.NoLayerChange => return .{ .source_changed = false },
                else => return err,
            };
            try recordStudioPatch(history, patch);
        },
        .commit_inline => return error.NonSourceStudioCommand,
        .copy_items => return error.NonSourceStudioCommand,
        .paste_items => |paste| {
            if (clipboard.items.items.len == 0) return error.StudioClipboardEmpty;
            if (clipboard.items.items.len > studio.max_selection_items) return error.InvalidStudioClipboardBatch;
            const scene = try studioItemSceneAnchor(slide, morph_state);
            const generation: f32 = @floatFromInt(clipboard.paste_generation + 1);
            var paste_items: [studio.max_selection_items]source_editor.CapturedPasteItem = undefined;
            for (clipboard.items.items, 0..) |clipboard_item, index| {
                try selection_ids.appendNextUnique();
                paste_items[index] = .{
                    .snippet = clipboard_item.snippet,
                    .component_definition_offset = clipboard_item.component_definition_offset,
                    .new_id = selection_ids.values.items[index],
                    .placement = .{
                        .x = clipboard_item.position.x + paste.offset.x * generation,
                        .y = clipboard_item.position.y + paste.offset.y * generation,
                    },
                };
            }
            try recordStudioPatch(history, try source_editor.pasteCapturedItems(
                G.allocator,
                G.editor_memory[0..G.source_len],
                scene,
                paste_items[0..clipboard.items.items.len],
            ));
            clipboard.paste_generation += 1;
        },
        .set_visible => |visibility| {
            try applyStudioVisibilityEdit(history, visibility, slide, morph_state, items);
            // Visibility does not add/remove/reorder items, so runtime
            // identities remain stable across the reparse. Keeping the
            // source-bound selection is what lets the Objects dock recover a
            // newly hidden item, including an id-less direct item.
            return .{ .preserve_selection = true };
        },
        .set_locked => |lock| {
            var all_have_ids = true;
            for (lock.slice()) |target| {
                const item = studioItemByIdentity(items, target.item_identity) orelse return error.StudioItemMissing;
                if (item.id) |id| try selection_ids.appendCopy(id) else all_have_ids = false;
            }
            if (!all_have_ids) selection_ids.clear();
            try applyStudioLockEdit(history, lock, slide, morph_state, items);
        },
        .reset_local_override => |reset| {
            const item = studioItemByIdentity(items, reset.target.item_identity) orelse
                return error.StudioItemMissing;
            if (item.locked) return error.StudioItemLocked;
            const id = item.id orelse return error.NoLocalPropertyOverride;
            const owner = try studioResetOwner(
                G.editor_memory[0..G.source_len],
                slide,
                morph_state,
                item,
            );
            const property = inheritedPropertyForInlineField(reset.field);
            if (!try source_editor.inheritedPropertyOverrideExists(
                G.editor_memory[0..G.source_len],
                owner,
                id,
                property,
            )) return error.NoLocalPropertyOverride;
            try recordStudioPatch(history, try source_editor.resetInheritedProperty(
                G.allocator,
                G.editor_memory[0..G.source_len],
                owner,
                id,
                property,
            ));
            return .{ .preserve_selection = true };
        },
        .detach_reusable_instance => |detach| {
            if (morph_state != null) return error.UnsupportedComponentDetach;
            const item = studioItemByIdentity(items, detach.target.item_identity) orelse
                return error.StudioItemMissing;
            if (item.locked) return error.StudioItemLocked;
            switch (detach.kind) {
                .component => {
                    if (item.source.scope != .component_instance or
                        item.source.line_offset != detach.target.source.line_offset)
                    {
                        return error.UnsupportedComponentDetach;
                    }
                    const info = try source_editor.inspectComponentInstanceForDetach(
                        G.editor_memory[0..G.source_len],
                        item.source.line_offset,
                    );
                    if (item.id == null or !std.mem.eql(u8, item.id.?, info.effective_id)) {
                        return error.DetachedItemIdMismatch;
                    }
                    const materialized = try materializeStudioItem(G.allocator, item);
                    defer G.allocator.free(materialized);
                    // Detach is structural; allocate the stable rebind key before the
                    // source/history transaction so an OOM cannot leave stale UI state.
                    try selection_ids.appendCopy(info.effective_id);
                    try recordStudioPatch(history, try source_editor.detachComponentInstance(
                        G.allocator,
                        G.editor_memory[0..G.source_len],
                        item.source.line_offset,
                        info.definition_offset,
                        materialized,
                    ));
                },
                .group => {
                    if (item.source.scope != .group_instance_member or
                        item.source.line_offset != detach.target.source.line_offset)
                    {
                        return error.UnsupportedGroupDetach;
                    }
                    const info = try source_editor.inspectReusableGroupInstance(
                        G.allocator,
                        G.editor_memory[0..G.source_len],
                        item.source.line_offset,
                    );
                    var snippets: [studio.max_selection_items][]u8 = undefined;
                    var snippet_count: usize = 0;
                    defer for (snippets[0..snippet_count]) |snippet| G.allocator.free(snippet);
                    for (items) |*member| {
                        if (member.source.scope != .group_instance_member or
                            member.source.line_offset != item.source.line_offset) continue;
                        if (snippet_count >= snippets.len) return error.UnsupportedGroupDetach;
                        const member_id = member.id orelse return error.UnsupportedGroupDetach;
                        try selection_ids.appendCopy(member_id);
                        snippets[snippet_count] = try materializeStudioItem(G.allocator, member);
                        snippet_count += 1;
                    }
                    if (snippet_count != info.member_count) return error.UnsupportedGroupDetach;
                    var snippet_views: [studio.max_selection_items][]const u8 = undefined;
                    for (snippets[0..snippet_count], 0..) |snippet, index| snippet_views[index] = snippet;
                    try recordStudioPatch(history, try source_editor.detachReusableGroupInstance(
                        G.allocator,
                        G.editor_memory[0..G.source_len],
                        item.source.line_offset,
                        info.definition_offset,
                        snippet_views[0..snippet_count],
                    ));
                },
                .none, .slide_template => return error.UnsupportedComponentDetach,
            }
        },
        .promote_items_to_group => |batch| {
            if (morph_state != null or batch.count < 2 or batch.count > studio.max_selection_items) {
                return error.UnsupportedGroupPromotion;
            }
            const group_name = prompted_text orelse return error.StudioPromptMissing;
            if (!validReusableName(group_name)) return error.InvalidReusableName;
            var instance_buffer: [64]u8 = undefined;
            const instance_id = try nextStudioItemId(&instance_buffer);
            var member_buffers: [studio.max_selection_items][64]u8 = undefined;
            var member_ids: [studio.max_selection_items][]const u8 = undefined;
            var promotion_targets: [studio.max_selection_items]source_editor.GroupPromotionTarget = undefined;

            for (batch.slice(), 0..) |target, index| {
                const selected = studioItemByIdentity(items, target.item_identity) orelse
                    return error.StudioItemMissing;
                if (selected.locked or !target.source.patchable or
                    (target.source.scope != .direct and target.source.scope != .component_instance))
                {
                    return error.UnsupportedGroupPromotion;
                }
                const proposed = if (selected.id) |id|
                    if (validReusableName(id)) id else null
                else
                    null;
                var unique = proposed != null;
                if (proposed) |candidate| {
                    for (batch.slice(), 0..) |other_target, other_index| {
                        if (other_index == index) continue;
                        const other = studioItemByIdentity(items, other_target.item_identity) orelse
                            return error.StudioItemMissing;
                        if (other.id != null and std.mem.eql(u8, other.id.?, candidate)) {
                            unique = false;
                            break;
                        }
                    }
                }
                member_ids[index] = if (unique)
                    proposed.?
                else
                    try std.fmt.bufPrint(&member_buffers[index], "item_{d}", .{index + 1});
                for (member_ids[0..index]) |previous| {
                    if (std.mem.eql(u8, previous, member_ids[index])) {
                        member_ids[index] = try std.fmt.bufPrint(
                            &member_buffers[index],
                            "member_{d}",
                            .{index + 1},
                        );
                        break;
                    }
                }
                promotion_targets[index] = .{
                    .directive_offset = target.source.line_offset,
                    .member_id = member_ids[index],
                };
            }
            // Preallocate all stable qualified selection keys before the
            // structural source/history transaction.
            for (member_ids[0..batch.count]) |member_id| {
                const qualified = try std.fmt.allocPrint(
                    G.allocator,
                    "{s}.{s}",
                    .{ instance_id, member_id },
                );
                defer G.allocator.free(qualified);
                try selection_ids.appendCopy(qualified);
            }
            try recordStudioPatch(history, try source_editor.promoteItemsToReusableGroup(
                G.allocator,
                G.editor_memory[0..G.source_len],
                try studioItemSceneAnchor(slide, morph_state),
                promotion_targets[0..batch.count],
                group_name,
                instance_id,
            ));
        },
        .promote_to_reusable => |target| {
            if (morph_state != null) return error.MorphPromotionUnsupported;
            const name = prompted_text orelse return error.StudioPromptMissing;
            if (!validReusableName(name)) return error.InvalidReusableName;
            if (reusableNameDefined(name)) return error.ReusableNameAlreadyDefined;
            try recordStudioPatch(history, try source_editor.promoteItemToReusable(
                G.allocator,
                G.editor_memory[0..G.source_len],
                target.source.line_offset,
                name,
            ));
        },
        .promote_slide_to_template => |slide_index| {
            if (slide_index >= G.slideshow.slides.items.len) return error.NoStudioSlide;
            const name = prompted_text orelse return error.StudioPromptMissing;
            if (!validReusableName(name)) return error.InvalidReusableName;
            const target = G.slideshow.slides.items[slide_index];
            try recordStudioPatch(history, try source_editor.promoteSlideToTemplate(
                G.allocator,
                G.editor_memory[0..G.source_len],
                target.pos_in_editor,
                name,
            ));
            return .{ .slide_index = slide_index };
        },
        .rename_library_entry => |workspace_index| {
            const entry = studioLibraryEntry(catalog_opt, catalog_indices, workspace_index) orelse
                return error.StudioLibraryEntryMissing;
            const new_name = prompted_text orelse return error.StudioPromptMissing;
            if (std.mem.eql(u8, entry.name, new_name)) return .{ .source_changed = false };
            try recordStudioCatalogPatch(history, try studio_catalog.renameDefinition(
                G.allocator,
                G.editor_memory[0..G.source_len],
                entry,
                new_name,
            ));
        },
        .delete_library_entry => |workspace_index| {
            const entry = studioLibraryEntry(catalog_opt, catalog_indices, workspace_index) orelse
                return error.StudioLibraryEntryMissing;
            try recordStudioCatalogPatch(history, try studio_catalog.deleteDefinition(
                G.allocator,
                G.editor_memory[0..G.source_len],
                entry,
            ));
        },
        .preview_library_cleanup => return .{ .source_changed = false },
        .cleanup_library => {
            const summary = try studio_catalog.cleanupSummary(
                G.allocator,
                G.editor_memory[0..G.source_len],
            );
            if (summary.removable_count == 0) return .{ .source_changed = false };
            try recordStudioCatalogPatch(history, try studio_catalog.cleanupUnusedDefinitions(
                G.allocator,
                G.editor_memory[0..G.source_len],
            ));
            return .{ .preserve_selection = true };
        },
        .add_reusable => |add| {
            const name = prompted_text orelse return error.StudioPromptMissing;
            if (!validReusableName(name)) return error.InvalidReusableName;
            const insertion_offset = try studioItemInsertionOffset(slide, morph_state);
            const catalog = try studio_catalog.discover(G.allocator, G.editor_memory[0..G.source_len]);
            defer catalog.deinit();
            if (catalog.findVisible(.element, name, insertion_offset) == null) return error.ReusableNameNotFound;
            var id_buffer: [64]u8 = undefined;
            const id = try nextStudioItemId(&id_buffer);
            const directive = if (add.library_entry_index != null)
                try std.fmt.allocPrint(
                    G.allocator,
                    "@pop {s} id={s} x={d} y={d}",
                    .{ name, id, add.position.x, add.position.y },
                )
            else
                try std.fmt.allocPrint(
                    G.allocator,
                    "@pop {s} id={s} x={d} y={d} w={d} h={d}",
                    .{ name, id, add.position.x, add.position.y, add.suggested_size.x, add.suggested_size.y },
                );
            defer G.allocator.free(directive);
            try recordStudioPatch(history, try source_editor.insertSnippetAt(
                G.allocator,
                G.editor_memory[0..G.source_len],
                insertion_offset,
                directive,
            ));
        },
        .add_reusable_group => |workspace_index| {
            if (morph_state != null) return error.UnsupportedGroupInstance;
            const entry = studioLibraryEntry(catalog_opt, catalog_indices, workspace_index) orelse
                return error.StudioLibraryEntryMissing;
            if (entry.kind != .group) return error.StudioLibraryEntryMissing;
            var instance_buffer: [64]u8 = undefined;
            const instance_id = try nextStudioItemId(&instance_buffer);
            try recordStudioPatch(history, try source_editor.insertReusableGroupInstance(
                G.allocator,
                G.editor_memory[0..G.source_len],
                try studioItemSceneAnchor(slide, null),
                entry.directive_offset,
                entry.name,
                instance_id,
            ));
        },
        .add_morph_state => |scene| {
            const after_offset: ?usize = if (scene.active_state) |state_index| blk: {
                if (state_index >= slide.morph_states.items.len) return error.InvalidMorphState;
                break :blk slide.morph_states.items[state_index].source.line_offset;
            } else null;
            try recordStudioPatch(history, try source_editor.insertMorphStateAfter(
                G.allocator,
                G.editor_memory[0..G.source_len],
                slide.pos_in_editor,
                after_offset,
            ));
            const next_state: ?usize = if (scene.active_state) |state_index| state_index + 1 else 0;
            history.setLatestMorphScenes(morph_state, next_state);
            return .{ .morph_scene = .{ .active_state = next_state } };
        },
        .duplicate_morph_state => |state_index| {
            if (state_index >= slide.morph_states.items.len) return error.InvalidMorphState;
            try recordStudioPatch(history, try source_editor.duplicateMorphState(
                G.allocator,
                G.editor_memory[0..G.source_len],
                slide.pos_in_editor,
                slide.morph_states.items[state_index].source.line_offset,
            ));
            history.setLatestMorphScenes(morph_state, state_index + 1);
            return .{ .morph_scene = .{ .active_state = state_index + 1 } };
        },
        .rename_morph_state => |state_index| {
            if (state_index >= slide.morph_states.items.len) return error.InvalidMorphState;
            const label = prompted_text orelse return error.StudioPromptMissing;
            if (!validReusableName(label)) return error.InvalidReusableName;
            if (slide.morph_states.items[state_index].spec.label) |existing| {
                if (std.mem.eql(u8, existing, label)) return .{
                    .source_changed = false,
                    .morph_scene = .{ .active_state = state_index },
                };
            }
            try recordStudioPatch(history, try source_editor.renameMorphState(
                G.allocator,
                G.editor_memory[0..G.source_len],
                slide.pos_in_editor,
                slide.morph_states.items[state_index].source.line_offset,
                label,
            ));
            history.setLatestMorphScenes(morph_state, state_index);
            return .{ .morph_scene = .{ .active_state = state_index } };
        },
        .delete_morph_state => |state_index| {
            const state_count = slide.morph_states.items.len;
            if (state_index >= state_count) return error.InvalidMorphState;
            try recordStudioPatch(history, try source_editor.deleteMorphState(
                G.allocator,
                G.editor_memory[0..G.source_len],
                slide.pos_in_editor,
                slide.morph_states.items[state_index].source.line_offset,
            ));
            const next_state: ?usize = if (state_count == 1)
                null
            else if (state_index + 1 < state_count)
                state_index
            else
                state_index - 1;
            history.setLatestMorphScenes(morph_state, next_state);
            return .{ .morph_scene = .{ .active_state = next_state } };
        },
        .move_morph_state => |move| {
            if (move.state_index >= slide.morph_states.items.len) return error.InvalidMorphState;
            const direction: source_editor.MorphStateMoveDirection = switch (move.direction) {
                .earlier => .earlier,
                .later => .later,
            };
            try recordStudioPatch(history, try source_editor.moveMorphState(
                G.allocator,
                G.editor_memory[0..G.source_len],
                slide.pos_in_editor,
                slide.morph_states.items[move.state_index].source.line_offset,
                direction,
            ));
            const next_state: usize = switch (move.direction) {
                .earlier => move.state_index - 1,
                .later => move.state_index + 1,
            };
            history.setLatestMorphScenes(morph_state, next_state);
            return .{ .morph_scene = .{ .active_state = next_state } };
        },
        .new_slide => {
            try recordStudioPatch(history, try source_editor.insertBlankSlideAfter(
                G.allocator,
                G.editor_memory[0..G.source_len],
                slide.pos_in_editor,
            ));
            return .{ .slide_index = @intCast(@as(usize, @intCast(G.current_slide)) + 1) };
        },
        .select_slide => return error.NonSourceStudioCommand,
        .duplicate_slide => |slide_index| {
            if (slide_index >= G.slideshow.slides.items.len) return error.NoStudioSlide;
            const target = G.slideshow.slides.items[slide_index];
            try recordStudioPatch(history, try source_editor.duplicateSlide(
                G.allocator,
                G.editor_memory[0..G.source_len],
                target.pos_in_editor,
            ));
            return .{ .slide_index = slide_index + 1 };
        },
        .delete_slide => |slide_index| {
            if (slide_index >= G.slideshow.slides.items.len) return error.NoStudioSlide;
            const slide_count = G.slideshow.slides.items.len;
            const target = G.slideshow.slides.items[slide_index];
            try recordStudioPatch(history, try source_editor.deleteSlide(
                G.allocator,
                G.editor_memory[0..G.source_len],
                target.pos_in_editor,
            ));
            return .{ .slide_index = if (slide_index + 1 < slide_count) slide_index else slide_index - 1 };
        },
        .move_slide => |move| {
            if (move.slide_index >= G.slideshow.slides.items.len) return error.NoStudioSlide;
            const target = G.slideshow.slides.items[move.slide_index];
            const direction: source_editor.SlideMoveDirection = switch (move.direction) {
                .up => .earlier,
                .down => .later,
            };
            try recordStudioPatch(history, try source_editor.moveSlide(
                G.allocator,
                G.editor_memory[0..G.source_len],
                target.pos_in_editor,
                direction,
            ));
            return .{ .slide_index = switch (move.direction) {
                .up => move.slide_index - 1,
                .down => move.slide_index + 1,
            } };
        },
        .new_slide_from_template => {
            const name = prompted_text orelse return error.StudioPromptMissing;
            if (!validReusableName(name)) return error.InvalidReusableName;
            const insertion_offset = try source_editor.slideEndOffset(G.editor_memory[0..G.source_len], slide.pos_in_editor);
            const catalog = try studio_catalog.discover(G.allocator, G.editor_memory[0..G.source_len]);
            defer catalog.deinit();
            if (catalog.findVisible(.slide, name, insertion_offset) == null) return error.ReusableNameNotFound;
            const directive = try std.fmt.allocPrint(G.allocator, "@popslide {s}", .{name});
            defer G.allocator.free(directive);
            try recordStudioPatch(history, try source_editor.insertDirectiveAt(
                G.allocator,
                G.editor_memory[0..G.source_len],
                insertion_offset,
                directive,
            ));
            return .{ .slide_index = @intCast(@as(usize, @intCast(G.current_slide)) + 1) };
        },
        .select_morph_scene => {},
    }
    return .{};
}

fn restoreStudioHistory(
    history: *StudioHistory,
    studio_mode: *studio.Studio,
    direction: HistoryDirection,
) !bool {
    const restore = try history.prepareRestore(direction) orelse return false;
    const rollback_source = try G.allocator.dupe(u8, G.editor_memory[0..G.source_len]);
    defer G.allocator.free(rollback_source);
    const rollback_slide = G.current_slide;
    const rollback_morph_state = studio_mode.active_morph_state;

    try replaceEditorSource(restore.source);
    reparseEditorSource() catch |restore_error| {
        try replaceEditorSource(rollback_source);
        try reparseEditorSource();
        restoreStudioSlide(rollback_slide);
        studio_mode.active_morph_state = rollback_morph_state;
        return restore_error;
    };
    history.commitRestore(direction);
    restoreStudioSlide(restore.slide);
    restoreStudioMorphScene(studio_mode, restore.morph_scene);
    return true;
}

fn undoStudioEdit(history: *StudioHistory, studio_mode: *studio.Studio) !bool {
    return restoreStudioHistory(history, studio_mode, .undo);
}

fn redoStudioEdit(history: *StudioHistory, studio_mode: *studio.Studio) !bool {
    return restoreStudioHistory(history, studio_mode, .redo);
}

fn restoreStudioMorphScene(studio_mode: *studio.Studio, requested: ?studio.MorphSceneCommand) void {
    const scene = requested orelse return;
    const slide_index = std.math.cast(usize, G.current_slide) orelse {
        studio_mode.active_morph_state = null;
        return;
    };
    if (slide_index >= G.slideshow.slides.items.len) {
        studio_mode.active_morph_state = null;
        return;
    }
    const state_count = G.slideshow.slides.items[slide_index].morph_states.items.len;
    studio_mode.active_morph_state = if (scene.active_state) |state_index|
        if (state_index < state_count) state_index else null
    else
        null;
}

fn restoreStudioSlide(requested: i32) void {
    if (G.slideshow.slides.items.len == 0) {
        G.current_slide = 0;
        return;
    }
    const last: i32 = @intCast(G.slideshow.slides.items.len - 1);
    G.current_slide = std.math.clamp(requested, 0, last);
    G.playback.enterSlide(null, 0, 0, .{}, 1, rl.getTime());
}

fn collectStudioBounds(
    output: *std.ArrayList(studio.ResolvedBounds),
    render_bounds: *std.ArrayList(renderer.SlideshowRenderer.ItemRenderBounds),
    allocator: std.mem.Allocator,
    slide_number: i32,
    morph_state: ?usize,
) !usize {
    output.clearRetainingCapacity();
    const fragment_count = try G.slide_renderer.collectItemRenderBoundsForMorphState(
        allocator,
        render_bounds,
        slide_number,
        morph_state,
    );
    try output.ensureUnusedCapacity(allocator, render_bounds.items.len);
    for (render_bounds.items) |entry| {
        const bounds = entry.bounds;
        try output.append(allocator, .{
            .identity = entry.owner_identity,
            .position = .{ .x = bounds.x, .y = bounds.y },
            .size = .{ .x = bounds.width, .y = bounds.height },
        });
    }
    return fragment_count;
}

fn slideSizeInWindow(internal_render_size: rl.Vector2, window_size: rl.Vector2) rl.Vector2 {
    var ret = rl.Vector2.zero();
    ret.x = window_size.x;

    // aspect ratio
    ret.y = ret.x * internal_render_size.y / internal_render_size.x;
    if (ret.y > window_size.y) {
        ret.y = window_size.y - 1;
        ret.x = ret.y * internal_render_size.x / internal_render_size.y;
    }
    return ret;
}

fn slideAreaTL(internal_render_size: rl.Vector2, window_size: rl.Vector2) rl.Vector2 {
    const ss = slideSizeInWindow(internal_render_size, window_size);
    var ret = rl.Vector2.zero();

    ret.y = (window_size.y - ss.y) / 2.0;
    ret.x = (window_size.x - ss.x) / 2.0;
    return ret;
}
