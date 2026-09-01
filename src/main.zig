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
const goto_slide = @import("goto_slide.zig");
const studio_catalog = @import("studio_catalog.zig");
const studio_library_preview = @import("studio_library_preview.zig");
const studio_new_deck = @import("studio_new_deck.zig");
const studio_prompt = @import("studio_prompt.zig");
const file_browser = @import("file_browser.zig");
const studio_roundtrip_test = @import("studio_roundtrip_test.zig");
const motion_schedule = @import("motion_schedule.zig");
const videoplayer = @import("videoplayer.zig");
const showtime = @import("showtime.zig");
const nvim_editor = @import("nvim_editor.zig");
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
    \\  --neovim-clean                  Start embedded Neovim without user config
    \\  --no-crowd                       Disable the Crowdplay server
    \\  --crowd-host=HOST                Bind Crowdplay to HOST
    \\  --crowd-port=PORT                Bind Crowdplay to PORT (default 7331)
    \\  --presenter-host=HOST            Address advertised by Presenter Companion
    \\  --presenter-port=PORT            Bind Presenter Companion to PORT (default 7332)
    \\  --showtime-report=JSON           Preflight the deck, write JSON, and exit
    \\  --portable-show=DIR              Create and re-preflight a portable show folder
    \\  -h, --help                       Show this help and exit
    \\  -v, --version                    Show the version and exit
    \\
    \\Diagnostics and visual QA:
    \\  --diagnostics                    Show the diagnostics HUD
    \\  --diagnostics-command-palette    Open Studio with Commands visible
    \\  --diagnostics-neovim-editor      Open Studio's embedded source editor
    \\  --diagnostics-goto-slide         Open with the go-to-slide picker visible
    \\  --diagnostics-file-browser       Open Studio with the deck file chooser visible
    \\  --diagnostics-command-tooltip    Show deterministic command hover help
    \\  --diagnostics-precision-view     Show rulers, guides, and precision tools
    \\  --diagnostics-grid-settings      Open the Studio grid appearance popover
    \\  --diagnostics-status-drawer      Pin the Studio status drawer open
    \\  --diagnostics-presenter-pairing  Show the Presenter pairing overlay
    \\  --diagnostics-presenter-session  Pair, then enter presentation for browser QA
    \\  --diagnostics-presentation-capture
    \\                                    Capture a presentation-size framebuffer
    \\  --diagnostics-display-picker     Show the presentation display picker
    \\  --diagnostics-confirm-display=N  Confirm active display N (1-based) before QA
    \\  --diagnostics-showtime           Open the Showtime readiness overlay
    \\  --diagnostics-large-deck=N       Generate an N-slide stress deck (1-200)
    \\  --diagnostics-incremental-edit=N Edit slide N after the initial render
    \\  --diagnostics-window=WIDTHxHEIGHT
    \\  --diagnostics-select=ID
    \\  --diagnostics-motion=ID        Select an item and open the Motion inspector
    \\  --diagnostics-timeline-step=N  Show the current slide through reveal step N
    \\  --diagnostics-slide=N          Open Studio on slide N (1-based)
    \\  --diagnostics-motion-state=N   Select morph state N (1-based) with ghosts and the State section
    \\  --diagnostics-motion-transition Open the Motion inspector on the slide transition
    \\  --diagnostics-motion-preview=SECONDS
    \\                                 Pause the live preview at that time
    \\  --diagnostics-video-playback   Open a selected video's Playback page
    \\  --diagnostics-library-preview=NAME
    \\  --diagnostics-library-definition=NAME
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

const StudioMediaKind = enum { image, video };

fn studioMediaKindForPath(path: []const u8) ?StudioMediaKind {
    const extension = std.fs.path.extension(path);
    for (file_browser.image_extensions) |candidate|
        if (std.ascii.eqlIgnoreCase(extension, candidate)) return .image;
    for (file_browser.video_extensions) |candidate|
        if (std.ascii.eqlIgnoreCase(extension, candidate)) return .video;
    return null;
}

fn studioMediaPathFromSelection(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    deck_path: ?[]const u8,
    selected_path: []const u8,
) ![]u8 {
    const deck_dir = if (deck_path) |path| std.fs.path.dirname(path) orelse "." else return allocator.dupe(u8, selected_path);
    return std.fs.path.relative(allocator, cwd, null, deck_dir, selected_path) catch
        allocator.dupe(u8, selected_path);
}

fn studioMediaDirective(
    buffer: []u8,
    id: []const u8,
    kind: StudioMediaKind,
    path: []const u8,
    position: rl.Vector2,
    size: rl.Vector2,
) ![]u8 {
    const source_path = try studioMediaSourceValue(path);
    return std.fmt.bufPrint(
        buffer,
        "@box id={s} {s}={s} x={d} y={d} w={d} h={d}",
        .{ id, if (kind == .image) "img" else "vid", source_path, position.x, position.y, size.x, size.y },
    );
}

/// Media paths are literal `.sld` attribute values today. Keep picker,
/// insertion, drop, and replacement validation on one boundary so no UI path
/// can accidentally become whitespace-separated source or a `$` expansion.
fn studioMediaSourceValue(path: []const u8) ![]const u8 {
    if (path.len == 0 or std.mem.indexOfAny(u8, path, " \t\r\n$") != null)
        return error.InvalidStudioMediaPath;
    return path;
}

test "media chooser stores paths relative to a saved deck" {
    const allocator = std.testing.allocator;
    const relative = try studioMediaPathFromSelection(
        allocator,
        "/work/project",
        "decks/talk.sld",
        "/work/project/decks/assets/hero.png",
    );
    defer allocator.free(relative);
    try std.testing.expectEqualStrings("assets/hero.png", relative);

    const untitled = try studioMediaPathFromSelection(allocator, "/work/project", null, "/tmp/hero.png");
    defer allocator.free(untitled);
    try std.testing.expectEqualStrings("/tmp/hero.png", untitled);
}

test "Studio media directives distinguish image and video attributes" {
    var buffer: [256]u8 = undefined;
    const position: rl.Vector2 = .{ .x = 120, .y = 240 };
    const size: rl.Vector2 = .{ .x = 640, .y = 360 };
    try std.testing.expectEqualStrings(
        "@box id=hero img=assets/hero.png x=120 y=240 w=640 h=360",
        try studioMediaDirective(&buffer, "hero", .image, "assets/hero.png", position, size),
    );
    try std.testing.expectEqualStrings(
        "@box id=clip vid=assets/demo.mp4 x=120 y=240 w=640 h=360",
        try studioMediaDirective(&buffer, "clip", .video, "assets/demo.mp4", position, size),
    );
    try std.testing.expectError(
        error.InvalidStudioMediaPath,
        studioMediaDirective(&buffer, "clip", .video, "assets/demo clip.mp4", position, size),
    );
    try std.testing.expectError(
        error.InvalidStudioMediaPath,
        studioMediaSourceValue("assets/$demo.mp4"),
    );
}

test "Studio media drop classification is case-insensitive and explicit" {
    try std.testing.expectEqual(StudioMediaKind.image, studioMediaKindForPath("/tmp/hero.PNG").?);
    try std.testing.expectEqual(StudioMediaKind.video, studioMediaKindForPath("assets/demo.WebM").?);
    try std.testing.expect(studioMediaKindForPath("notes.txt") == null);
    try std.testing.expect(studioMediaKindForPath("deck.sld") == null);
}

test "Studio media insertion stays selectable and undoable in every authored scene" {
    const allocator = std.testing.allocator;
    const Scene = enum { base, group_definition, slide_definition };
    const Case = struct {
        scene: Scene,
        kind: StudioMediaKind,
        source: []const u8,
        local_id: []const u8,
        effective_id: []const u8,
        path: []const u8,
    };
    const Harness = struct {
        fn expectAbsent(deck: *slides.SlideShow, id: []const u8) !void {
            for (deck.slides.items) |slide| {
                const items = if (slide.items) |list| list.items else continue;
                for (items) |item| {
                    if (item.id) |item_id| try std.testing.expect(!std.mem.eql(u8, item_id, id));
                }
            }
        }

        fn expectSelectable(
            deck: *slides.SlideShow,
            scene: Scene,
            kind: StudioMediaKind,
            local_id: []const u8,
            effective_id: []const u8,
            path: []const u8,
        ) !void {
            for (deck.slides.items) |slide| {
                const items = if (slide.items) |list| list.items else continue;
                var expected_index: ?usize = null;
                for (items, 0..) |item, index| {
                    const item_id = item.id orelse continue;
                    if (std.mem.eql(u8, item_id, effective_id)) {
                        expected_index = index;
                        switch (kind) {
                            .image => {
                                try std.testing.expectEqual(slides.SlideItemKind.img, item.kind);
                                try std.testing.expectEqualStrings(path, item.img_path.?);
                            },
                            .video => {
                                try std.testing.expectEqual(slides.SlideItemKind.vid, item.kind);
                                try std.testing.expectEqualStrings(path, item.vid_path.?);
                            },
                        }
                        break;
                    }
                }
                const wanted_index = expected_index orelse continue;

                var studio_mode: studio.Studio = .{ .enabled = true };
                switch (scene) {
                    .base => studio_mode.selectItemsByIds(items, &.{local_id}),
                    .group_definition, .slide_definition => {
                        var authored: [0]slides.SlideItem = .{};
                        try std.testing.expect(studio_mode.enterDefinitionMode(
                            &authored,
                            0,
                            0,
                            .{
                                .kind = if (scene == .group_definition) .group else .slide_template,
                                .name = if (scene == .group_definition) "media_group" else "media_slide",
                            },
                        ));
                        studio_mode.queueDefinitionSelectionIds(&.{local_id});
                        studio_mode.applyPendingDefinitionSelection(items);
                    },
                }
                try std.testing.expectEqual(wanted_index, studio_mode.selectedIndex(items).?);
                return;
            }
            return error.TestExpectedMediaItem;
        }

        fn parseAndExpectAbsent(
            allocator_: std.mem.Allocator,
            source: []const u8,
            id: []const u8,
        ) !void {
            var arena = std.heap.ArenaAllocator.init(allocator_);
            defer arena.deinit();
            const deck = try slides.SlideShow.new(arena.allocator());
            const context = try parser.constructSlidesFromBuf(source, deck, arena.allocator());
            defer context.deinit();
            try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
            try expectAbsent(deck, id);
        }

        fn parseAndExpectSelectable(
            allocator_: std.mem.Allocator,
            source: []const u8,
            scene: Scene,
            kind: StudioMediaKind,
            local_id: []const u8,
            effective_id: []const u8,
            path: []const u8,
        ) !void {
            var arena = std.heap.ArenaAllocator.init(allocator_);
            defer arena.deinit();
            const deck = try slides.SlideShow.new(arena.allocator());
            const context = try parser.constructSlidesFromBuf(source, deck, arena.allocator());
            defer context.deinit();
            try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
            try expectSelectable(deck, scene, kind, local_id, effective_id, path);
        }
    };

    const base_source = "@slide\n";
    const group_source =
        "@pushgroup media_group\n" ++
        "@box id=label x=80 y=80 w=500 h=80 text=Media\n" ++
        "@endgroup\n" ++
        "@slide\n" ++
        "@popgroup media_group id=instance\n";
    const slide_source =
        "@box id=label x=80 y=80 w=500 h=80 text=Media\n" ++
        "@pushslide media_slide\n" ++
        "@popslide media_slide\n";
    const cases = [_]Case{
        .{ .scene = .base, .kind = .image, .source = base_source, .local_id = "hero", .effective_id = "hero", .path = "assets/hero.png" },
        .{ .scene = .base, .kind = .video, .source = base_source, .local_id = "clip", .effective_id = "clip", .path = "assets/demo.mp4" },
        .{ .scene = .group_definition, .kind = .image, .source = group_source, .local_id = "hero", .effective_id = "instance.hero", .path = "assets/hero.png" },
        .{ .scene = .group_definition, .kind = .video, .source = group_source, .local_id = "clip", .effective_id = "instance.clip", .path = "assets/demo.mp4" },
        .{ .scene = .slide_definition, .kind = .image, .source = slide_source, .local_id = "hero", .effective_id = "hero", .path = "assets/hero.png" },
        .{ .scene = .slide_definition, .kind = .video, .source = slide_source, .local_id = "clip", .effective_id = "clip", .path = "assets/demo.mp4" },
    };

    for (cases) |case| {
        const anchor: source_editor.ItemSceneAnchor = switch (case.scene) {
            .base => .{ .base_slide = std.mem.indexOf(u8, case.source, "@slide").? },
            .group_definition => .{ .group_definition = std.mem.indexOf(u8, case.source, "@pushgroup").? },
            .slide_definition => .{ .slide_definition = std.mem.indexOf(u8, case.source, "@pushslide").? },
        };
        var directive_buffer: [512]u8 = undefined;
        const directive = try studioMediaDirective(
            &directive_buffer,
            case.local_id,
            case.kind,
            case.path,
            .{ .x = 120, .y = 180 },
            .{ .x = 640, .y = 360 },
        );
        const patch = try source_editor.insertSnippetAt(
            allocator,
            case.source,
            try source_editor.itemSceneInsertionOffset(case.source, anchor),
            directive,
        );
        defer patch.deinit(allocator);

        var selection_ids = StudioSelectionIds.init(allocator);
        defer selection_ids.deinit();
        try selection_ids.appendCopy(case.local_id);
        try std.testing.expectEqual(@as(usize, 1), selection_ids.values.items.len);

        var history = StudioHistory.init(allocator);
        defer history.deinit();
        try history.record(
            try allocator.dupe(u8, case.source),
            try allocator.dupe(u8, patch.source),
            0,
            0,
        );

        try Harness.parseAndExpectSelectable(
            allocator,
            patch.source,
            case.scene,
            case.kind,
            selection_ids.values.items[0],
            case.effective_id,
            case.path,
        );

        const undo_restore = (try history.prepareRestore(.undo)).?;
        try Harness.parseAndExpectAbsent(allocator, undo_restore.source, case.effective_id);
        history.commitRestore(.undo);
        try std.testing.expectEqual(@as(usize, 0), history.undo_stack.items.len);
        try std.testing.expectEqual(@as(usize, 1), history.redo_stack.items.len);

        const redo_restore = (try history.prepareRestore(.redo)).?;
        try Harness.parseAndExpectSelectable(
            allocator,
            redo_restore.source,
            case.scene,
            case.kind,
            selection_ids.values.items[0],
            case.effective_id,
            case.path,
        );
        history.commitRestore(.redo);
        try std.testing.expectEqual(@as(usize, 1), history.undo_stack.items.len);
        try std.testing.expectEqual(@as(usize, 0), history.redo_stack.items.len);
    }
}

test "Studio gives unavailable media stable selectable fallback bounds" {
    const allocator = std.testing.allocator;
    const items = [_]slides.SlideItem{
        .{ .identity = 1, .kind = .img, .img_path = "missing.png", .position = .{ .x = 20, .y = 30 } },
        .{ .identity = 2, .kind = .vid, .vid_path = "missing.mp4", .position = .{ .x = 40, .y = 50 }, .size = .{ .x = 800, .y = 0 } },
    };
    var bounds = std.ArrayList(studio.ResolvedBounds).empty;
    defer bounds.deinit(allocator);
    try appendStudioUnavailableMediaBounds(&bounds, allocator, &items);
    try std.testing.expectEqual(@as(usize, 2), bounds.items.len);
    try std.testing.expectEqual(studio.MediaAvailability.image_unavailable, bounds.items[0].media_availability);
    try std.testing.expectEqual(@as(f32, 640), bounds.items[0].size.x);
    try std.testing.expectEqual(@as(f32, 360), bounds.items[0].size.y);
    try std.testing.expectEqual(studio.MediaAvailability.video_unavailable, bounds.items[1].media_availability);
    try std.testing.expectEqual(@as(f32, 800), bounds.items[1].size.x);
    try std.testing.expectEqual(@as(f32, 450), bounds.items[1].size.y);

    // A renderer-provided entry is authoritative and must never be shadowed
    // by a fallback diagnostic.
    bounds.clearRetainingCapacity();
    try bounds.append(allocator, .{ .identity = 1, .position = .zero(), .size = .{ .x = 10, .y = 20 } });
    try appendStudioUnavailableMediaBounds(&bounds, allocator, &items);
    try std.testing.expectEqual(@as(usize, 2), bounds.items.len);
    try std.testing.expectEqual(studio.MediaAvailability.ready, bounds.items[0].media_availability);
}

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
    std.testing.refAllDecls(showtime);
    std.testing.refAllDecls(presenter);
    std.testing.refAllDecls(renderer);
    std.testing.refAllDecls(slides);
    std.testing.refAllDecls(source_editor);
    std.testing.refAllDecls(studio);
    std.testing.refAllDecls(studio_catalog);
    std.testing.refAllDecls(studio_library_preview);
    std.testing.refAllDecls(studio_new_deck);
    std.testing.refAllDecls(studio_prompt);
    std.testing.refAllDecls(file_browser);
    std.testing.refAllDecls(studio_roundtrip_test);
    std.testing.refAllDecls(motion_schedule);
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

const PresenterNetworkState = struct {
    discovery: presenter.LocalAddressDiscovery = .{},
    selected: presenter.LocalAddress = .{},
    selected_index: usize = 0,
    explicit: bool = false,
    manually_selected: bool = false,

    fn init(options: PresenterOptions) PresenterNetworkState {
        var result: PresenterNetworkState = .{ .explicit = options.host_explicit };
        if (options.host_explicit) {
            const configured = presenter.LocalAddress.init(options.host, "--presenter-host", .explicit) orelse
                presenter.LocalAddress.init("127.0.0.1", "invalid explicit host", .loopback).?;
            result.discovery.add(configured);
            result.selected = configured;
            return result;
        }
        _ = result.refresh();
        return result;
    }

    /// Returns true only when the advertised host changed and an existing
    /// private capability must therefore be rotated.
    fn refresh(self: *PresenterNetworkState) bool {
        if (self.explicit) return false;
        const old_host = self.selected.host;
        const previous_host = old_host.slice();
        const fresh = presenter.discoverLocalAddresses();
        var next_index: usize = 0;
        var next = fresh.preferred() orelse
            presenter.LocalAddress.init("127.0.0.1", "loopback", .loopback).?;

        if (self.manually_selected and previous_host.len > 0) {
            for (fresh.addresses[0..fresh.len], 0..) |candidate, index| {
                if (!candidate.host.eql(previous_host)) continue;
                next = candidate;
                next_index = index;
                break;
            } else self.manually_selected = false;
        }
        if (!self.manually_selected) {
            for (fresh.addresses[0..fresh.len], 0..) |candidate, index| {
                if (candidate.host.eql(next.host.slice())) {
                    next_index = index;
                    break;
                }
            }
        }

        self.discovery = fresh;
        self.selected = next;
        self.selected_index = next_index;
        return previous_host.len > 0 and !self.selected.host.eql(previous_host);
    }

    fn cycle(self: *PresenterNetworkState) bool {
        if (self.explicit or self.discovery.len < 2) return false;
        const old_host = self.selected.host;
        self.selected_index = (self.selected_index + 1) % self.discovery.len;
        self.selected = self.discovery.addresses[self.selected_index];
        self.manually_selected = true;
        return !self.selected.host.eql(old_host.slice());
    }

    fn host(self: *const PresenterNetworkState) []const u8 {
        return self.selected.host.slice();
    }
};

test "Presenter network selection prefers LAN and preserves an intentional choice" {
    var state: PresenterNetworkState = .{};
    state.discovery.add(presenter.LocalAddress.init("127.0.0.1", "lo0", .loopback).?);
    state.discovery.add(presenter.LocalAddress.init("192.168.8.10", "en0", .private_lan).?);
    state.selected_index = 1;
    state.selected = state.discovery.addresses[1];
    try std.testing.expect(state.cycle());
    try std.testing.expectEqualStrings("127.0.0.1", state.host());
    try std.testing.expect(state.manually_selected);
}

const WindowDimensions = struct {
    width: i32,
    height: i32,
};

const FullscreenMode = enum {
    windowed,
    borderless,
    exclusive,
};

const DisplayPicker = struct {
    visible: bool = false,
    candidate_monitor: i32 = 0,
    confirmed_monitor: i32 = 0,
    identified_monitor: ?i32 = null,
    restore_fullscreen: FullscreenMode = .windowed,

    fn monitorCount() i32 {
        return @max(@as(i32, 1), rl.getMonitorCount());
    }

    fn clampMonitor(monitor: i32) i32 {
        return std.math.clamp(monitor, 0, monitorCount() - 1);
    }

    fn init() DisplayPicker {
        const current = clampMonitor(rl.getCurrentMonitor());
        return .{ .candidate_monitor = current, .confirmed_monitor = current };
    }

    fn cycle(self: *DisplayPicker, delta: i32) void {
        const count = monitorCount();
        self.candidate_monitor = @mod(self.candidate_monitor + delta, count);
        self.identified_monitor = null;
    }
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

fn fitWindowToMonitor(
    requested_width: i32,
    requested_height: i32,
    monitor_width: i32,
    monitor_height: i32,
) WindowDimensions {
    if (requested_width <= 0 or requested_height <= 0 or monitor_width <= 0 or monitor_height <= 0)
        return .{ .width = 1280, .height = 720 };
    const max_width = @max(@as(i32, 1), @divFloor(monitor_width * 9, 10));
    const max_height = @max(@as(i32, 1), @divFloor(monitor_height * 9, 10));
    if (requested_width <= max_width and requested_height <= max_height)
        return .{ .width = requested_width, .height = requested_height };
    const width_scale = @as(f64, @floatFromInt(max_width)) / @as(f64, @floatFromInt(requested_width));
    const height_scale = @as(f64, @floatFromInt(max_height)) / @as(f64, @floatFromInt(requested_height));
    const scale = @min(width_scale, height_scale);
    return .{
        .width = @max(@as(i32, 1), @as(i32, @intFromFloat(@floor(@as(f64, @floatFromInt(requested_width)) * scale)))),
        .height = @max(@as(i32, 1), @as(i32, @intFromFloat(@floor(@as(f64, @floatFromInt(requested_height)) * scale)))),
    };
}

fn moveWindowToMonitor(
    monitor_unchecked: i32,
    requested_width: i32,
    requested_height: i32,
) WindowDimensions {
    const monitor = DisplayPicker.clampMonitor(monitor_unchecked);
    const dimensions = fitWindowToMonitor(
        requested_width,
        requested_height,
        rl.getMonitorWidth(monitor),
        rl.getMonitorHeight(monitor),
    );
    rl.setWindowMonitor(monitor);
    rl.setWindowSize(dimensions.width, dimensions.height);
    const position = rl.getMonitorPosition(monitor);
    rl.setWindowPosition(
        @intFromFloat(position.x + @as(f32, @floatFromInt(rl.getMonitorWidth(monitor) - dimensions.width)) / 2),
        @intFromFloat(position.y + @as(f32, @floatFromInt(rl.getMonitorHeight(monitor) - dimensions.height)) / 2),
    );
    return dimensions;
}

fn leavePresentationFullscreen(
    mode: *FullscreenMode,
    monitor: i32,
    windowed_width: i32,
    windowed_height: i32,
    screen_width: *i32,
    screen_height: *i32,
) void {
    switch (mode.*) {
        .windowed => return,
        .borderless => rl.toggleBorderlessWindowed(),
        .exclusive => rl.toggleFullscreen(),
    }
    const dimensions = moveWindowToMonitor(monitor, windowed_width, windowed_height);
    screen_width.* = dimensions.width;
    screen_height.* = dimensions.height;
    mode.* = .windowed;
}

fn enterPresentationFullscreen(
    mode: *FullscreenMode,
    desired: FullscreenMode,
    monitor_unchecked: i32,
    windowed_width: *i32,
    windowed_height: *i32,
    screen_width: *i32,
    screen_height: *i32,
) void {
    if (desired == .windowed or mode.* != .windowed) return;
    const monitor = DisplayPicker.clampMonitor(monitor_unchecked);
    windowed_width.* = rl.getScreenWidth();
    windowed_height.* = rl.getScreenHeight();
    _ = moveWindowToMonitor(monitor, windowed_width.*, windowed_height.*);
    rl.setWindowSize(rl.getMonitorWidth(monitor), rl.getMonitorHeight(monitor));
    screen_width.* = rl.getMonitorWidth(monitor);
    screen_height.* = rl.getMonitorHeight(monitor);
    switch (desired) {
        .windowed => unreachable,
        .borderless => rl.toggleBorderlessWindowed(),
        .exclusive => rl.toggleFullscreen(),
    }
    mode.* = desired;
}

fn parseDiagnosticWindowSize(value: []const u8) ?WindowDimensions {
    const separator = std.mem.indexOfScalar(u8, value, 'x') orelse return null;
    const width = std.fmt.parseInt(i32, value[0..separator], 10) catch return null;
    const height = std.fmt.parseInt(i32, value[separator + 1 ..], 10) catch return null;
    if (width < 900 or height < 506 or width > 7680 or height > 4320) return null;
    return .{ .width = width, .height = height };
}

fn parseDiagnosticDisplayNumber(value: []const u8) ?i32 {
    const one_based = std.fmt.parseInt(i32, value, 10) catch return null;
    if (one_based <= 0) return null;
    return one_based - 1;
}

test "Studio startup window fits common monitor sizes" {
    try std.testing.expectEqual(WindowDimensions{ .width = 1600, .height = 900 }, studioStartupWindowSize(1920, 1080));
    try std.testing.expectEqual(WindowDimensions{ .width = 1296, .height = 729 }, studioStartupWindowSize(1440, 900));
    try std.testing.expectEqual(WindowDimensions{ .width = 1137, .height = 640 }, studioStartupWindowSize(1366, 768));
    try std.testing.expectEqual(WindowDimensions{ .width = 1280, .height = 720 }, studioStartupWindowSize(0, 0));
}

test "display selection keeps a usable aspect-preserving window" {
    try std.testing.expectEqual(WindowDimensions{ .width = 1280, .height = 720 }, fitWindowToMonitor(1280, 720, 1920, 1080));
    try std.testing.expectEqual(WindowDimensions{ .width = 1152, .height = 648 }, fitWindowToMonitor(1920, 1080, 1280, 720));
    try std.testing.expectEqual(WindowDimensions{ .width = 1024, .height = 768 }, fitWindowToMonitor(1024, 768, 1920, 1080));
    try std.testing.expectEqual(WindowDimensions{ .width = 1280, .height = 720 }, fitWindowToMonitor(0, 0, 0, 0));
}

test "diagnostic window size is explicit and safely bounded" {
    try std.testing.expectEqual(WindowDimensions{ .width = 900, .height = 600 }, parseDiagnosticWindowSize("900x600").?);
    try std.testing.expectEqual(WindowDimensions{ .width = 1920, .height = 1080 }, parseDiagnosticWindowSize("1920x1080").?);
    try std.testing.expect(parseDiagnosticWindowSize("899x600") == null);
    try std.testing.expect(parseDiagnosticWindowSize("900x500") == null);
    try std.testing.expect(parseDiagnosticWindowSize("wide") == null);
}

test "diagnostic display number is one-based and rejects invalid input" {
    try std.testing.expectEqual(@as(i32, 0), parseDiagnosticDisplayNumber("1").?);
    try std.testing.expectEqual(@as(i32, 11), parseDiagnosticDisplayNumber("12").?);
    try std.testing.expect(parseDiagnosticDisplayNumber("0") == null);
    try std.testing.expect(parseDiagnosticDisplayNumber("-1") == null);
    try std.testing.expect(parseDiagnosticDisplayNumber("display") == null);
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

test "Definition mode retains its physical catalog target across undo and redo" {
    const allocator = std.testing.allocator;
    const source =
        "@push unrelated text=Other\n" ++
        "@push card text=Before\n" ++
        "@slide\n" ++
        "@pop card id=card\n" ++
        "@push card text=Shadow\n";
    const definition_offset = std.mem.indexOf(u8, source, "@push card text=Before").?;
    const patch = try source_editor.patchItemText(allocator, source, definition_offset, "After");
    var patch_owned = true;
    defer if (patch_owned) patch.deinit(allocator);
    var history = StudioHistory.init(allocator);
    defer history.deinit();
    const before = try allocator.dupe(u8, source);
    var before_owned = true;
    defer if (before_owned) allocator.free(before);
    try history.record(before, patch.source, 0, 0);
    before_owned = false;
    patch_owned = false;

    var no_items: [0]slides.SlideItem = .{};
    var studio_mode: studio.Studio = .{ .enabled = true };
    try std.testing.expect(studio_mode.enterDefinitionMode(
        &no_items,
        1,
        0,
        .{ .kind = .element, .name = "card", .use_count = 1 },
    ));

    const undo = (try history.prepareRestore(.undo)).?;
    var undo_catalog = try studio_catalog.discover(allocator, undo.source);
    defer undo_catalog.deinit();
    try std.testing.expectEqualStrings("card", undo_catalog.entries[1].name);
    try std.testing.expect(std.mem.indexOf(u8, undo.source, "text=Before") != null);
    studio_mode.markSourceChanged();
    try std.testing.expect(studio_mode.syncDefinitionMode(
        1,
        0,
        .{ .kind = .element, .name = undo_catalog.entries[1].name, .use_count = 1 },
    ));
    history.commitRestore(.undo);

    const redo = (try history.prepareRestore(.redo)).?;
    var redo_catalog = try studio_catalog.discover(allocator, redo.source);
    defer redo_catalog.deinit();
    try std.testing.expectEqualStrings("card", redo_catalog.entries[1].name);
    try std.testing.expect(std.mem.indexOf(u8, redo.source, "text=After") != null);
    studio_mode.markSourceChanged();
    try std.testing.expect(studio_mode.syncDefinitionMode(
        1,
        0,
        .{ .kind = .element, .name = redo_catalog.entries[1].name, .use_count = 1 },
    ));
    history.commitRestore(.redo);
    try std.testing.expectEqual(@as(?usize, 1), studio_mode.definitionCatalogIndex());
}

test "Studio structural history reparses duplicated slides in both directions" {
    const allocator = std.testing.allocator;
    const source =
        "@slide\n" ++
        "@box id=hero x=20 y=30 text=Hero\n" ++
        "@state(morph) label=detail\n" ++
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

fn showtimeRuntimeSnapshot(
    picker: *const DisplayPicker,
    fullscreen_mode: FullscreenMode,
    presenter_runtime: *presenter.Runtime,
    presenter_network: *const PresenterNetworkState,
    crowd_runtime: *const crowdplay.Runtime,
) showtime.RuntimeSnapshot {
    const monitor_count: usize = @intCast(@max(@as(i32, 0), DisplayPicker.monitorCount()));
    const selected = DisplayPicker.clampMonitor(picker.confirmed_monitor);
    const presenter_kind = presenter_network.selected.kind;
    const presenter_health = presenter_runtime.clientHealth();
    var presenter_health_samples: u32 = 0;
    var presenter_health_failures: u32 = 0;
    var presenter_health_p95_ms: ?u32 = null;
    if (presenter_health) |health| {
        const metrics = [_]presenter.LatencyMetric{ health.state, health.command, health.pointer, health.drawing };
        for (metrics) |metric| {
            presenter_health_samples += metric.samples;
            presenter_health_failures += metric.failures;
            if (metric.p95_ms) |value|
                presenter_health_p95_ms = @max(presenter_health_p95_ms orelse 0, value);
        }
    }
    return .{
        .monitor_count = monitor_count,
        .selected_monitor = @intCast(@max(@as(i32, 0), selected)),
        .display_width = if (monitor_count > 0) rl.getMonitorWidth(selected) else 0,
        .display_height = if (monitor_count > 0) rl.getMonitorHeight(selected) else 0,
        .refresh_rate = if (monitor_count > 0) rl.getMonitorRefreshRate(selected) else 0,
        .vsync_enabled = true,
        .fullscreen = fullscreen_mode != .windowed,
        .presenter_running = presenter_runtime.isRunning(),
        .presenter_reachable = switch (presenter_kind) {
            .explicit, .private_lan, .public_lan, .vpn => true,
            .link_local, .loopback => false,
        },
        .presenter_connected = presenter_runtime.phoneConnected(),
        .presenter_address = presenter_network.host(),
        .presenter_health_samples = presenter_health_samples,
        .presenter_health_p95_ms = presenter_health_p95_ms,
        .presenter_health_failures = presenter_health_failures,
        .crowdplay_required = slideshowHasCrowd(G.slideshow),
        .crowdplay_running = crowd_runtime.isRunning(),
    };
}

fn replaceShowtimeReport(destination: *?showtime.Report, replacement: showtime.Report) void {
    if (destination.*) |*current| current.deinit();
    destination.* = replacement;
}

/// A visible Showtime overlay describes the exact live document and renderer.
/// Once a different document commits, discard that cached analysis so the
/// post-render path cannot keep presenting findings from the previous deck.
fn invalidateShowtimeForDocumentReplacement(
    overlay: *const ShowtimeOverlay,
    destination: *?showtime.Report,
) void {
    if (!overlay.visible) return;
    if (destination.*) |*current| current.deinit();
    destination.* = null;
}

test "visible Showtime report is invalidated when the live document is replaced" {
    var cached: ?showtime.Report = showtime.Report.init(std.testing.allocator);
    if (cached) |*report| try report.add(
        .info,
        .portable,
        .portable_verified,
        null,
        null,
        null,
        null,
        "old deck",
        "cached analysis",
    );

    const hidden: ShowtimeOverlay = .{};
    invalidateShowtimeForDocumentReplacement(&hidden, &cached);
    try std.testing.expect(cached != null);

    const visible: ShowtimeOverlay = .{ .visible = true };
    invalidateShowtimeForDocumentReplacement(&visible, &cached);
    try std.testing.expect(cached == null);
}

fn buildLiveShowtimeReport(runtime: showtime.RuntimeSnapshot) !showtime.Report {
    var report = try showtime.analyze(
        G.allocator,
        G.slideshow,
        G.slide_renderer,
        G.editor_memory[0..G.source_len],
        runtime,
    );
    errdefer report.deinit();
    try appendReusableDefinitionShowtime(
        &report,
        G.editor_memory[0..G.source_len],
        G.slideshow_filp orelse "untitled.sld",
    );
    return report;
}

fn readFileAllocLimited(allocator: std.mem.Allocator, io: std.Io, path: []const u8, limit: usize) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var read_buffer: [8192]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    return reader.interface.allocRemaining(allocator, .limited(limit));
}

/// Turn a rejected document load into the same stable report shape used by a
/// successful renderer-backed preflight. This path deliberately reparses in
/// isolation: malformed source never replaces the live Studio document.
/// Titles the window with the open document so several Rayslides windows can
/// be told apart in a window manager, a Dock, or a screenshot. Only pushed to
/// the OS when the text actually changes; setWindowTitle is not free.
fn syncWindowTitle(dirty: bool) void {
    const cache = struct {
        var last: [std.fs.max_path_bytes + 32]u8 = undefined;
        var last_len: usize = 0;
        var primed: bool = false;
    };
    var buffer: [std.fs.max_path_bytes + 32]u8 = undefined;
    const name: []const u8 = if (G.slideshow_filp) |path| std.fs.path.basename(path) else "";
    const title: [:0]const u8 = if (name.len == 0)
        "Rayslides"
    else
        std.fmt.bufPrintZ(&buffer, "{s}{s} - Rayslides", .{ name, if (dirty) " *" else "" }) catch "Rayslides";
    if (cache.primed and std.mem.eql(u8, cache.last[0..cache.last_len], title)) return;
    @memcpy(cache.last[0..title.len], title);
    cache.last_len = title.len;
    cache.primed = true;
    rl.setWindowTitle(title);
}

fn buildLoadFailureShowtimeReport(deck_path: []const u8, load_error: anyerror) !showtime.Report {
    var report = showtime.Report.init(G.allocator);
    errdefer report.deinit();

    const source = readFileAllocLimited(G.allocator, G.io, deck_path, G.editor_memory.len - 1) catch |read_error| {
        try report.add(
            .error_,
            .deck,
            .deck_load_failed,
            null,
            null,
            null,
            null,
            "Deck could not be read",
            @errorName(read_error),
        );
        return report;
    };
    defer G.allocator.free(source);

    var arena = std.heap.ArenaAllocator.init(G.allocator);
    defer arena.deinit();
    const deck = try SlideShow.new(arena.allocator());
    const context = parser.constructSlidesFromBuf(source, deck, arena.allocator()) catch |parse_error| {
        try report.add(
            .error_,
            .deck,
            .deck_load_failed,
            null,
            null,
            null,
            null,
            "Deck could not be parsed",
            @errorName(parse_error),
        );
        return report;
    };
    defer context.deinit();
    report.summary.slides = deck.slides.items.len;

    for (context.parser_errors.items) |parse_error| {
        const title = try std.fmt.allocPrint(
            G.allocator,
            "Parser error on line {d}",
            .{parse_error.line_number},
        );
        defer G.allocator.free(title);
        const detail = if (parse_error.message) |message| message else @errorName(parse_error.parser_error);
        try report.add(
            .error_,
            .deck,
            .parser_error,
            null,
            null,
            null,
            if (parse_error.line_number > 0) parse_error.line_number else null,
            title,
            detail,
        );
    }
    if (context.parser_errors.items.len == 0) {
        try report.add(
            .error_,
            .deck,
            .deck_load_failed,
            null,
            null,
            null,
            null,
            "Deck could not be loaded",
            @errorName(load_error),
        );
    }
    return report;
}

/// Re-open the just-created ordinary deck through an independent parser,
/// font set, renderer, and Showtime report. None of the live document,
/// history, selection, poll, or playback objects are borrowed or replaced.
fn verifyPortableShowtime(deck_path: []const u8, runtime: showtime.RuntimeSnapshot) !showtime.Report {
    const source = try readFileAllocLimited(G.allocator, G.io, deck_path, G.editor_memory.len - 1);
    defer G.allocator.free(source);
    var graph = try ParsedSlideshowGraph.init(G.allocator, source);
    defer graph.deinit();
    var isolated_fonts = try fonts.AvailableFonts.init(.{});
    defer isolated_fonts.deinit();
    if (graph.parser_context.?.custom_fonts_present)
        try isolated_fonts.loadCustomFonts(graph.parser_context.?.fontConfig, deck_path);
    const isolated_renderer = try renderer.SlideshowRenderer.new(G.allocator, &isolated_fonts);
    defer isolated_renderer.deinit();
    isolated_renderer.video_cache.io = G.io;
    isolated_renderer.texture_cache.io = G.io;
    try isolated_renderer.preRender(graph.slideshow, deck_path);
    var report = try showtime.analyze(G.allocator, graph.slideshow, isolated_renderer, source, runtime);
    errdefer report.deinit();
    try appendReusableDefinitionShowtime(&report, source, deck_path);
    return report;
}

fn sourceLineAtOffset(source: []const u8, offset: usize) usize {
    var line: usize = 1;
    for (source[0..@min(offset, source.len)]) |byte| if (byte == '\n') {
        line += 1;
    };
    return line;
}

/// Showtime definition findings carry an authored source line. Resolve that
/// line to the nearest physical definition that starts at or before it; group
/// and slide-template members naturally fall under their owning directive.
fn showtimeDefinitionCatalogIndexAtLine(
    source: []const u8,
    catalog: studio_catalog.Catalog,
    source_line: usize,
) ?usize {
    if (source_line == 0) return null;
    var candidate: ?usize = null;
    for (catalog.entries, 0..) |entry, index| {
        if (sourceLineAtOffset(source, entry.directive_offset) > source_line) break;
        candidate = index;
    }
    return candidate;
}

test "Showtime source links resolve reusable directives and body members" {
    const allocator = std.testing.allocator;
    const source =
        "@push card x=10 y=10 text=Card\n" ++
        "@pushgroup cluster\n" ++
        "@box id=one x=20 y=20 text=One\n" ++
        "@endgroup\n" ++
        "@slide\n";
    var catalog = try studio_catalog.discover(allocator, source);
    defer catalog.deinit();
    try std.testing.expectEqual(@as(?usize, 0), showtimeDefinitionCatalogIndexAtLine(source, catalog, 1));
    try std.testing.expectEqual(@as(?usize, 1), showtimeDefinitionCatalogIndexAtLine(source, catalog, 3));
}

fn definitionUseOffset(catalog: studio_catalog.Catalog, entry_index: usize) usize {
    const entry = catalog.entries[entry_index];
    for (catalog.entries[entry_index + 1 ..]) |later| {
        if (later.kind == entry.kind and std.mem.eql(u8, later.name, entry.name)) return later.directive_offset;
    }
    return catalog.source_len;
}

/// Materialize every physical reusable definition at the exact source-order
/// point where that definition is active. Each one gets an independent
/// parser projection and renderer, so unused Library content receives the
/// same media/glyph/layout scrutiny without disturbing Studio's preview cache.
fn appendReusableDefinitionShowtime(report: *showtime.Report, source: []const u8, deck_path: []const u8) !void {
    var catalog = try studio_catalog.discover(G.allocator, source);
    defer catalog.deinit();
    for (catalog.entries, 0..) |entry, entry_index| {
        if (!entry.placeable) {
            try report.add(.error_, .deck, .render_scene_missing, null, null, null, sourceLineAtOffset(source, entry.directive_offset), "Reusable definition has an unstable name", "Use a literal letters/numbers/_/- name so Showtime and Studio can materialize it.");
            continue;
        }
        var id_buffer: [64]u8 = undefined;
        const instance_id = std.fmt.bufPrint(&id_buffer, "__showtime_{x}", .{
            @as(u32, @truncate(std.hash.Wyhash.hash(entry.directive_offset, entry.name))),
        }) catch "__showtime_definition";
        const temporary_source = studio_library_preview.buildSource(G.allocator, source, .{
            .kind = entry.kind,
            .name = entry.name,
            .insertion_offset = definitionUseOffset(catalog, entry_index),
            .instance_id = instance_id,
        }) catch |err| {
            var title_buffer: [256]u8 = undefined;
            const title = std.fmt.bufPrint(&title_buffer, "{s} definition “{s}” cannot be projected", .{ @tagName(entry.kind), entry.name }) catch "Reusable definition cannot be projected";
            var detail_buffer: [192]u8 = undefined;
            const detail = std.fmt.bufPrint(&detail_buffer, "Fix this definition and retry: {s}", .{@errorName(err)}) catch "Fix this definition and retry.";
            try report.add(.error_, .render, .render_scene_missing, null, null, null, sourceLineAtOffset(source, entry.directive_offset), title, detail);
            continue;
        };
        defer G.allocator.free(temporary_source);
        var graph = ParsedSlideshowGraph.init(G.allocator, temporary_source) catch |err| {
            var title_buffer: [256]u8 = undefined;
            const title = std.fmt.bufPrint(&title_buffer, "{s} definition “{s}” cannot be parsed", .{ @tagName(entry.kind), entry.name }) catch "Reusable definition cannot be parsed";
            var detail_buffer: [192]u8 = undefined;
            const detail = std.fmt.bufPrint(&detail_buffer, "Fix this definition and retry: {s}", .{@errorName(err)}) catch "Fix this definition and retry.";
            try report.add(.error_, .deck, .render_scene_missing, null, null, null, sourceLineAtOffset(source, entry.directive_offset), title, detail);
            continue;
        };
        defer graph.deinit();
        if (graph.slideshow.slides.items.len == 0) continue;
        const parsed = graph.slideshow.slides.items[graph.slideshow.slides.items.len - 1];
        const projected = studio_library_preview.projectSlide(
            graph.slideshow_allocator,
            parsed,
            entry.kind,
            instance_id,
        ) catch |err| {
            var title_buffer: [256]u8 = undefined;
            const title = std.fmt.bufPrint(&title_buffer, "{s} definition “{s}” produces no preview", .{ @tagName(entry.kind), entry.name }) catch "Reusable definition produces no preview";
            var detail_buffer: [192]u8 = undefined;
            const detail = std.fmt.bufPrint(&detail_buffer, "Fix this definition and retry: {s}", .{@errorName(err)}) catch "Fix this definition and retry.";
            try report.add(.error_, .render, .render_scene_missing, null, null, null, sourceLineAtOffset(source, entry.directive_offset), title, detail);
            continue;
        };
        const projected_deck = try SlideShow.new(graph.slideshow_allocator);
        try projected_deck.slides.append(graph.slideshow_allocator, projected);
        const isolated_renderer = try renderer.SlideshowRenderer.new(G.allocator, &G.fonts);
        defer isolated_renderer.deinit();
        isolated_renderer.video_cache.io = G.io;
        isolated_renderer.texture_cache.io = G.io;
        isolated_renderer.preRender(projected_deck, deck_path) catch |err| {
            var title_buffer: [256]u8 = undefined;
            const title = std.fmt.bufPrint(&title_buffer, "{s} definition “{s}” cannot render", .{ @tagName(entry.kind), entry.name }) catch "Reusable definition cannot render";
            var detail_buffer: [192]u8 = undefined;
            const detail = std.fmt.bufPrint(&detail_buffer, "Fix this definition and retry: {s}", .{@errorName(err)}) catch "Fix this definition and retry.";
            try report.add(.error_, .render, .render_scene_missing, null, null, null, sourceLineAtOffset(source, entry.directive_offset), title, detail);
            continue;
        };
        var definition_report = try showtime.analyze(G.allocator, projected_deck, isolated_renderer, temporary_source, .{
            .monitor_count = 1,
            .display_width = 1920,
            .display_height = 1080,
            .refresh_rate = 60,
            .vsync_enabled = true,
            .presenter_running = true,
            .presenter_reachable = true,
        });
        defer definition_report.deinit();
        for (definition_report.findings.items) |finding| {
            if (finding.slide_index == null) continue;
            var title_buffer: [512]u8 = undefined;
            const title = std.fmt.bufPrint(&title_buffer, "{s} “{s}”: {s}", .{ @tagName(entry.kind), entry.name, finding.title }) catch finding.title;
            try report.add(
                finding.severity,
                finding.category,
                finding.code,
                null,
                finding.morph_state,
                finding.owner_identity,
                finding.source_line orelse sourceLineAtOffset(source, entry.directive_offset),
                title,
                finding.detail,
            );
        }
    }
}

fn crowdSpecForSlide(slideshow: *const SlideShow, slide_number: i32) ?slides.CrowdSpec {
    if (slide_number < 0 or slide_number >= slideshow.slides.items.len) return null;
    const slide = slideshow.slides.items[@intCast(slide_number)];
    if (slide.items) |items| for (items.items) |item| if (item.crowd) |spec| return spec;
    return null;
}

fn ensurePresenterCompanionRunning(
    runtime: *presenter.Runtime,
    options: PresenterOptions,
    network: *PresenterNetworkState,
) bool {
    if (runtime.isRunning()) return true;
    _ = network.refresh();
    const port = runtime.start(options.port, network.host()) catch |err| {
        log.err("Presenter Companion could not start: {any}", .{err});
        return false;
    };
    // Never log pairing_url: its fragment is the private presenter capability.
    log.info("Presenter Companion listening on port {d}; setup address: {s}", .{ port, runtime.base_url.slice() });
    return true;
}

fn rePairPresenterCompanion(
    runtime: *presenter.Runtime,
    network: *const PresenterNetworkState,
) bool {
    if (!runtime.isRunning()) return true;
    runtime.rePair(network.host()) catch |err| {
        // Do not leave an obsolete capability alive after the interface that
        // advertised it disappeared. Local presentation controls are
        // independent and continue normally.
        runtime.stop();
        log.err("Presenter Companion could not refresh after network change: {any}", .{err});
        return false;
    };
    // Never log pairing_url: its fragment is the newly rotated capability.
    log.info("Presenter Companion re-paired for {s}", .{runtime.base_url.slice()});
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
    network: *const PresenterNetworkState,
    connected: bool,
    laptop_link_copied: bool,
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
    drawCenteredPresenterText(font, "PAIR PRESENTER COMPANION", presenterOverlayPx(18, scale), 36 * scale, .{ .r = 97, .g = 218, .b = 251, .a = 255 }, screen_width);
    drawCenteredPresenterText(font, "Scan on a phone, or press L for a private laptop link", presenterOverlayPx(58, scale), 24 * scale, .{ .r = 185, .g = 202, .b = 220, .a = 255 }, screen_width);

    const qr_target = @max(
        presenterOverlayPx(120, scale),
        @min(
            presenterOverlayPx(380, scale),
            @min(screen_width - presenterOverlayPx(80, scale), screen_height - presenterOverlayPx(300, scale)),
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
        const address_y = @min(screen_height - presenterOverlayPx(150, scale), top + rendered_side + presenterOverlayPx(14, scale));
        drawCenteredPresenterText(font, address, address_y, 22 * scale, .{ .r = 223, .g = 233, .b = 244, .a = 255 }, screen_width);

        var network_buffer: [192:0]u8 = @splat(0);
        const network_label = std.fmt.bufPrintZ(
            &network_buffer,
            "{s} · {s} · address {d}/{d}",
            .{
                network.selected.interface_name.slice(),
                network.selected.kind.label(),
                network.selected_index + 1,
                @max(@as(usize, 1), network.discovery.len),
            },
        ) catch "Network details unavailable";
        drawCenteredPresenterText(
            font,
            network_label,
            address_y + presenterOverlayPx(27, scale),
            18 * scale,
            .{ .r = 97, .g = 218, .b = 251, .a = 255 },
            screen_width,
        );
        var guidance_buffer: [192:0]u8 = @splat(0);
        const guidance = std.fmt.bufPrintZ(
            &guidance_buffer,
            "{s}",
            .{network.selected.kind.guidance()},
        ) catch "Verify that the phone can reach this address";
        drawCenteredPresenterText(
            font,
            guidance,
            address_y + presenterOverlayPx(51, scale),
            17 * scale,
            .{ .r = 185, .g = 202, .b = 220, .a = 255 },
            screen_width,
        );
    } else {
        drawCenteredPresenterText(font, "The pairing address is too long to encode as a QR code.", presenterOverlayPx(160, scale), 24 * scale, .{ .r = 255, .g = 155, .b = 174, .a = 255 }, screen_width);
    }

    drawCenteredPresenterText(
        font,
        if (laptop_link_copied)
            "PRIVATE LAPTOP LINK COPIED"
        else if (connected)
            "COMPANION CONNECTED"
        else
            "WAITING FOR COMPANION",
        screen_height - presenterOverlayPx(82, scale),
        24 * scale,
        if (laptop_link_copied or connected) .{ .r = 130, .g = 230, .b = 174, .a = 255 } else .{ .r = 255, .g = 181, .b = 71, .a = 255 },
        screen_width,
    );
    drawCenteredPresenterText(
        font,
        if (network.discovery.len > 1)
            "L: copy laptop link   •   N: next address   •   P: hide   •   Shift-P: stop"
        else
            "L: copy laptop link   •   P: hide   •   Shift-P: unpair and stop",
        screen_height - presenterOverlayPx(30, scale),
        18 * scale,
        .{ .r = 139, .g = 158, .b = 179, .a = 255 },
        screen_width,
    );
}

fn openDisplayPicker(
    picker: *DisplayPicker,
    fullscreen_mode: *FullscreenMode,
    windowed_width: i32,
    windowed_height: i32,
    screen_width: *i32,
    screen_height: *i32,
) void {
    picker.restore_fullscreen = fullscreen_mode.*;
    picker.confirmed_monitor = DisplayPicker.clampMonitor(picker.confirmed_monitor);
    if (fullscreen_mode.* != .windowed) leavePresentationFullscreen(
        fullscreen_mode,
        picker.confirmed_monitor,
        windowed_width,
        windowed_height,
        screen_width,
        screen_height,
    );
    picker.candidate_monitor = picker.confirmed_monitor;
    picker.identified_monitor = null;
    picker.visible = true;
}

fn placeDisplayPickerWindow(
    picker: *DisplayPicker,
    monitor_unchecked: i32,
    windowed_width: *i32,
    windowed_height: *i32,
    screen_width: *i32,
    screen_height: *i32,
) void {
    const monitor = DisplayPicker.clampMonitor(monitor_unchecked);
    const dimensions = moveWindowToMonitor(monitor, windowed_width.*, windowed_height.*);
    windowed_width.* = dimensions.width;
    windowed_height.* = dimensions.height;
    screen_width.* = dimensions.width;
    screen_height.* = dimensions.height;
    picker.identified_monitor = monitor;
}

fn closeDisplayPicker(
    picker: *DisplayPicker,
    accept: bool,
    fullscreen_mode: *FullscreenMode,
    windowed_width: *i32,
    windowed_height: *i32,
    screen_width: *i32,
    screen_height: *i32,
) void {
    const monitor = DisplayPicker.clampMonitor(if (accept)
        picker.candidate_monitor
    else
        picker.confirmed_monitor);
    placeDisplayPickerWindow(
        picker,
        monitor,
        windowed_width,
        windowed_height,
        screen_width,
        screen_height,
    );
    if (accept) picker.confirmed_monitor = monitor;
    const restore = picker.restore_fullscreen;
    picker.visible = false;
    picker.identified_monitor = null;
    picker.restore_fullscreen = .windowed;
    if (restore != .windowed) enterPresentationFullscreen(
        fullscreen_mode,
        restore,
        monitor,
        windowed_width,
        windowed_height,
        screen_width,
        screen_height,
    );
}

const DisplayPickerLayout = struct {
    top: i32,
    row_height: i32,
    row_gap: i32,
    left: i32,
    panel_width: i32,
    start_monitor: i32,
    visible_count: i32,

    fn monitorAt(self: DisplayPickerLayout, point: rl.Vector2) ?i32 {
        var row: i32 = 0;
        while (row < self.visible_count) : (row += 1) {
            const y = self.top + row * (self.row_height + self.row_gap);
            if (point.x >= @as(f32, @floatFromInt(self.left)) and
                point.x <= @as(f32, @floatFromInt(self.left + self.panel_width)) and
                point.y >= @as(f32, @floatFromInt(y)) and
                point.y <= @as(f32, @floatFromInt(y + self.row_height)))
            {
                return self.start_monitor + row;
            }
        }
        return null;
    }
};

fn displayPickerLayout(screen_width: i32, screen_height: i32, count: i32, candidate_monitor: i32) DisplayPickerLayout {
    const scale = presenterOverlayScale(screen_width, screen_height);
    const row_height = presenterOverlayPx(66, scale);
    const row_gap = presenterOverlayPx(8, scale);
    const top = presenterOverlayPx(103, scale);
    const footer_space = presenterOverlayPx(112, scale);
    const available = @max(row_height, screen_height - top - footer_space);
    const visible_count: i32 = @min(count, @max(@as(i32, 1), @divFloor(available + row_gap, row_height + row_gap)));
    const max_start = @max(@as(i32, 0), count - visible_count);
    const start = std.math.clamp(candidate_monitor - @divFloor(visible_count, 2), 0, max_start);
    const panel_width = @min(screen_width - presenterOverlayPx(64, scale), presenterOverlayPx(930, scale));
    return .{
        .top = top,
        .row_height = row_height,
        .row_gap = row_gap,
        .left = @divFloor(screen_width - panel_width, 2),
        .panel_width = panel_width,
        .start_monitor = start,
        .visible_count = visible_count,
    };
}

fn drawDisplayPickerOverlay(
    picker: *const DisplayPicker,
    screen_width: i32,
    screen_height: i32,
) void {
    const scale = presenterOverlayScale(screen_width, screen_height);
    const font = G.presenter_ui_font;
    rl.drawRectangle(0, 0, screen_width, screen_height, .{ .r = 7, .g = 11, .b = 24, .a = 255 });

    var title_buffer: [96:0]u8 = @splat(0);
    const title: [:0]const u8 = if (picker.identified_monitor) |monitor|
        std.fmt.bufPrintZ(&title_buffer, "DISPLAY {d} IDENTIFIED HERE", .{monitor + 1}) catch "IDENTIFY PRESENTATION DISPLAY"
    else
        "CHOOSE PRESENTATION DISPLAY";
    drawCenteredPresenterText(font, title, presenterOverlayPx(20, scale), 34 * scale, .{ .r = 97, .g = 218, .b = 251, .a = 255 }, screen_width);
    drawCenteredPresenterText(
        font,
        "Rayslides never guesses which active screen is the projector",
        presenterOverlayPx(61, scale),
        19 * scale,
        .{ .r = 185, .g = 202, .b = 220, .a = 255 },
        screen_width,
    );

    const count = DisplayPicker.monitorCount();
    const layout = displayPickerLayout(screen_width, screen_height, count, picker.candidate_monitor);
    const current_monitor = DisplayPicker.clampMonitor(rl.getCurrentMonitor());

    var visible_index: i32 = 0;
    while (visible_index < layout.visible_count) : (visible_index += 1) {
        const monitor = layout.start_monitor + visible_index;
        const y = layout.top + visible_index * (layout.row_height + layout.row_gap);
        const candidate = monitor == picker.candidate_monitor;
        const confirmed = monitor == picker.confirmed_monitor;
        const window_here = monitor == current_monitor;
        rl.drawRectangleRounded(
            .{
                .x = @floatFromInt(layout.left),
                .y = @floatFromInt(y),
                .width = @floatFromInt(layout.panel_width),
                .height = @floatFromInt(layout.row_height),
            },
            0.18,
            8,
            if (candidate) .{ .r = 27, .g = 52, .b = 78, .a = 255 } else .{ .r = 12, .g = 24, .b = 40, .a = 255 },
        );
        rl.drawRectangleRoundedLinesEx(
            .{
                .x = @floatFromInt(layout.left),
                .y = @floatFromInt(y),
                .width = @floatFromInt(layout.panel_width),
                .height = @floatFromInt(layout.row_height),
            },
            0.18,
            8,
            if (candidate) 2 * scale else 1 * scale,
            if (candidate) .{ .r = 97, .g = 218, .b = 251, .a = 255 } else .{ .r = 33, .g = 58, .b = 86, .a = 255 },
        );

        var name_buffer: [256:0]u8 = @splat(0);
        const name = std.fmt.bufPrintZ(
            &name_buffer,
            "{s}  DISPLAY {d} · {s}",
            .{ if (candidate) ">" else " ", monitor + 1, rl.getMonitorName(monitor) },
        ) catch "Display name unavailable";
        rl.drawTextEx(
            font,
            name,
            .{ .x = @floatFromInt(layout.left + presenterOverlayPx(18, scale)), .y = @floatFromInt(y + presenterOverlayPx(8, scale)) },
            20 * scale,
            0,
            .{ .r = 238, .g = 246, .b = 255, .a = 255 },
        );

        const position = rl.getMonitorPosition(monitor);
        var detail_buffer: [256:0]u8 = @splat(0);
        const detail = std.fmt.bufPrintZ(
            &detail_buffer,
            "{d} × {d} · {d} Hz · position {d}, {d}{s}{s}",
            .{
                rl.getMonitorWidth(monitor),
                rl.getMonitorHeight(monitor),
                rl.getMonitorRefreshRate(monitor),
                @as(i32, @intFromFloat(position.x)),
                @as(i32, @intFromFloat(position.y)),
                if (confirmed) " · SELECTED" else "",
                if (window_here) " · WINDOW HERE" else "",
            },
        ) catch "Display details unavailable";
        rl.drawTextEx(
            font,
            detail,
            .{ .x = @floatFromInt(layout.left + presenterOverlayPx(18, scale)), .y = @floatFromInt(y + presenterOverlayPx(36, scale)) },
            15 * scale,
            0,
            if (confirmed) .{ .r = 130, .g = 230, .b = 174, .a = 255 } else .{ .r = 139, .g = 158, .b = 179, .a = 255 },
        );
    }

    var page_buffer: [96:0]u8 = @splat(0);
    const page: [:0]const u8 = if (count == 1)
        "One active display detected"
    else
        std.fmt.bufPrintZ(
            &page_buffer,
            "Display {d} of {d} selected",
            .{ picker.candidate_monitor + 1, count },
        ) catch "Display selection";
    drawCenteredPresenterText(
        font,
        page,
        screen_height - presenterOverlayPx(78, scale),
        18 * scale,
        .{ .r = 255, .g = 181, .b = 71, .a = 255 },
        screen_width,
    );
    drawCenteredPresenterText(
        font,
        "Click row: identify/use   ·   ↑/↓: select   ·   Space: identify   ·   Enter: use   ·   Esc: cancel",
        screen_height - presenterOverlayPx(36, scale),
        17 * scale,
        .{ .r = 139, .g = 158, .b = 179, .a = 255 },
        screen_width,
    );
}

const ShowtimeOverlay = struct {
    visible: bool = false,
    selected: usize = 0,
    first_visible: usize = 0,

    fn normalize(self: *ShowtimeOverlay, finding_count: usize, capacity: usize) void {
        if (finding_count == 0) {
            self.selected = 0;
            self.first_visible = 0;
            return;
        }
        self.selected = @min(self.selected, finding_count - 1);
        if (capacity == 0) return;
        if (self.selected < self.first_visible) self.first_visible = self.selected;
        if (self.selected >= self.first_visible + capacity) self.first_visible = self.selected + 1 - capacity;
        self.first_visible = @min(self.first_visible, finding_count - @min(finding_count, capacity));
    }

    fn move(self: *ShowtimeOverlay, delta: i8, finding_count: usize, capacity: usize) void {
        if (finding_count == 0) return;
        if (delta < 0) self.selected -|= 1 else self.selected = @min(finding_count - 1, self.selected + 1);
        self.normalize(finding_count, capacity);
    }
};

const ShowtimeOverlayLayout = struct {
    panel: rl.Rectangle,
    summary: rl.Rectangle,
    rows: rl.Rectangle,
    footer: rl.Rectangle,
    row_height: f32,
    row_gap: f32,
    capacity: usize,

    fn row(self: ShowtimeOverlayLayout, slot: usize) rl.Rectangle {
        return .{
            .x = self.rows.x,
            .y = self.rows.y + @as(f32, @floatFromInt(slot)) * (self.row_height + self.row_gap),
            .width = self.rows.width,
            .height = self.row_height,
        };
    }

    fn rowAt(self: ShowtimeOverlayLayout, point: rl.Vector2) ?usize {
        for (0..self.capacity) |slot| if (showtimePointInRectangle(point, self.row(slot))) return slot;
        return null;
    }
};

fn showtimePointInRectangle(point: rl.Vector2, rect: rl.Rectangle) bool {
    return point.x >= rect.x and point.y >= rect.y and point.x <= rect.x + rect.width and point.y <= rect.y + rect.height;
}

fn showtimeOverlayLayout(screen_width: i32, screen_height: i32) ShowtimeOverlayLayout {
    const scale = presenterOverlayScale(screen_width, screen_height);
    const margin = 20 * scale;
    const panel: rl.Rectangle = .{
        .x = margin,
        .y = margin,
        .width = @as(f32, @floatFromInt(screen_width)) - margin * 2,
        .height = @as(f32, @floatFromInt(screen_height)) - margin * 2,
    };
    const header_height = 78 * scale;
    const summary_height = 68 * scale;
    const footer_height = 42 * scale;
    const row_gap = 7 * scale;
    const rows: rl.Rectangle = .{
        .x = panel.x + 20 * scale,
        .y = panel.y + header_height + summary_height + 15 * scale,
        .width = panel.width - 40 * scale,
        .height = @max(0, panel.height - header_height - summary_height - footer_height - 31 * scale),
    };
    const row_height = 67 * scale;
    return .{
        .panel = panel,
        .summary = .{ .x = rows.x, .y = panel.y + header_height, .width = rows.width, .height = summary_height },
        .rows = rows,
        .footer = .{ .x = rows.x, .y = panel.y + panel.height - footer_height, .width = rows.width, .height = footer_height },
        .row_height = row_height,
        .row_gap = row_gap,
        .capacity = @max(@as(usize, 1), @as(usize, @intFromFloat(@floor((rows.height + row_gap) / (row_height + row_gap))))),
    };
}

const ShowtimeOverlayAction = union(enum) {
    none,
    close,
    rerun,
    portable,
    open_finding: usize,
};

fn updateShowtimeOverlay(
    overlay: *ShowtimeOverlay,
    report: *const showtime.Report,
    screen_width: i32,
    screen_height: i32,
) ShowtimeOverlayAction {
    if (!overlay.visible) return .none;
    const layout = showtimeOverlayLayout(screen_width, screen_height);
    overlay.normalize(report.findings.items.len, layout.capacity);
    if (rl.isKeyPressed(.escape)) return .close;
    if (rl.isKeyPressed(.r)) return .rerun;
    if (rl.isKeyPressed(.p)) return .portable;
    if (rl.isKeyPressed(.up)) overlay.move(-1, report.findings.items.len, layout.capacity);
    if (rl.isKeyPressed(.down)) overlay.move(1, report.findings.items.len, layout.capacity);
    const wheel = rl.getMouseWheelMove();
    if (wheel > 0) overlay.move(-1, report.findings.items.len, layout.capacity);
    if (wheel < 0) overlay.move(1, report.findings.items.len, layout.capacity);
    if (rl.isKeyPressed(.enter) and report.findings.items.len > 0) return .{ .open_finding = overlay.selected };
    if (rl.isMouseButtonPressed(.left)) {
        const pointer = rl.getMousePosition();
        if (!showtimePointInRectangle(pointer, layout.panel)) return .close;
        if (layout.rowAt(pointer)) |slot| {
            const index = overlay.first_visible + slot;
            if (index < report.findings.items.len) {
                if (overlay.selected == index) return .{ .open_finding = index };
                overlay.selected = index;
            }
        }
    }
    return .none;
}

fn showtimeSeverityColor(severity: showtime.Severity) rl.Color {
    return switch (severity) {
        .error_ => .{ .r = 255, .g = 107, .b = 132, .a = 255 },
        .warning => .{ .r = 255, .g = 181, .b = 71, .a = 255 },
        .info => .{ .r = 97, .g = 218, .b = 251, .a = 255 },
    };
}

fn drawShowtimeOverlay(
    overlay: *const ShowtimeOverlay,
    report: *const showtime.Report,
    screen_width: i32,
    screen_height: i32,
) void {
    const layout = showtimeOverlayLayout(screen_width, screen_height);
    const scale = presenterOverlayScale(screen_width, screen_height);
    const font = G.presenter_ui_font;
    rl.drawRectangle(0, 0, screen_width, screen_height, .{ .r = 5, .g = 9, .b = 20, .a = 255 });
    rl.drawRectangleRounded(layout.panel, 0.025, 8, .{ .r = 10, .g = 19, .b = 33, .a = 255 });

    var title_buffer: [160:0]u8 = @splat(0);
    const title: [:0]const u8 = if (report.ready())
        std.fmt.bufPrintZ(&title_buffer, "READY FOR SHOW  ·  {d} SLIDES  ·  {d} SCENES", .{ report.summary.slides, report.summary.scenes }) catch "SHOWTIME PREFLIGHT"
    else
        std.fmt.bufPrintZ(&title_buffer, "SHOWTIME  ·  {d} BLOCKERS  ·  {d} WARNINGS", .{ report.summary.errors, report.summary.warnings }) catch "SHOWTIME PREFLIGHT";
    rl.drawTextEx(font, title, .{ .x = layout.panel.x + 20 * scale, .y = layout.panel.y + 15 * scale }, 28 * scale, 0, if (report.ready()) .{ .r = 130, .g = 230, .b = 174, .a = 255 } else .{ .r = 255, .g = 181, .b = 71, .a = 255 });
    rl.drawTextEx(font, "Exact parser + renderer + venue state · no playback, history, selection, or source mutation", .{ .x = layout.panel.x + 20 * scale, .y = layout.panel.y + 48 * scale }, 15 * scale, 0, .{ .r = 151, .g = 170, .b = 193, .a = 255 });

    rl.drawRectangleRounded(layout.summary, 0.10, 8, .{ .r = 14, .g = 28, .b = 47, .a = 255 });
    var summary_buffer: [384:0]u8 = @splat(0);
    const summary_text = std.fmt.bufPrintZ(
        &summary_buffer,
        "DECK {d} slides / {d} endpoints     RENDER {d} fragments     ASSETS {d}     DEFINITIONS {d}",
        .{ report.summary.slides, report.summary.reveal_endpoints, report.summary.render_fragments, report.summary.assets, report.summary.reusable_definitions },
    ) catch "Showtime summary";
    rl.drawTextEx(font, summary_text, .{ .x = layout.summary.x + 16 * scale, .y = layout.summary.y + 12 * scale }, 18 * scale, 0, .{ .r = 232, .g = 241, .b = 250, .a = 255 });
    var counts_buffer: [256:0]u8 = @splat(0);
    const counts = std.fmt.bufPrintZ(&counts_buffer, "{d} errors   ·   {d} warnings   ·   {d} notes{s}", .{ report.summary.errors, report.summary.warnings, report.summary.info, if (report.truncated) "   ·   result limit reached" else "" }) catch "Readiness counts";
    rl.drawTextEx(font, counts, .{ .x = layout.summary.x + 16 * scale, .y = layout.summary.y + 39 * scale }, 15 * scale, 0, if (report.summary.errors > 0) showtimeSeverityColor(.error_) else if (report.summary.warnings > 0) showtimeSeverityColor(.warning) else .{ .r = 130, .g = 230, .b = 174, .a = 255 });

    if (report.findings.items.len == 0) {
        rl.drawTextEx(font, "All deterministic checks passed. Review the actual projector and phone before walking on stage.", .{ .x = layout.rows.x + 12 * scale, .y = layout.rows.y + 22 * scale }, 19 * scale, 0, .{ .r = 185, .g = 202, .b = 220, .a = 255 });
    } else {
        for (0..layout.capacity) |slot| {
            const index = overlay.first_visible + slot;
            if (index >= report.findings.items.len) break;
            const finding = report.findings.items[index];
            const row = layout.row(slot);
            const selected = index == overlay.selected;
            rl.drawRectangleRounded(row, 0.10, 8, if (selected) .{ .r = 24, .g = 48, .b = 72, .a = 255 } else .{ .r = 12, .g = 25, .b = 42, .a = 255 });
            rl.drawRectangle(@intFromFloat(row.x), @intFromFloat(row.y), @max(@as(i32, 3), @as(i32, @intFromFloat(5 * scale))), @intFromFloat(row.height), showtimeSeverityColor(finding.severity));
            var location_buffer: [64:0]u8 = @splat(0);
            const location: [:0]const u8 = if (finding.slide_index) |slide_index|
                std.fmt.bufPrintZ(&location_buffer, "  ·  slide {d}", .{slide_index + 1}) catch ""
            else if (finding.source_line) |line|
                std.fmt.bufPrintZ(&location_buffer, "  ·  line {d}", .{line}) catch ""
            else
                "";
            var row_title_buffer: [512:0]u8 = @splat(0);
            const row_title = std.fmt.bufPrintZ(&row_title_buffer, "{s}  {s}{s}{s}", .{
                @tagName(finding.category),
                finding.title,
                location,
                if (finding.morph_state != null) "  ·  morph" else "",
            }) catch "Showtime finding";
            rl.drawTextEx(font, row_title, .{ .x = row.x + 17 * scale, .y = row.y + 9 * scale }, 18 * scale, 0, .{ .r = 238, .g = 246, .b = 255, .a = 255 });
            var detail_buffer: [640:0]u8 = @splat(0);
            const detail = std.fmt.bufPrintZ(&detail_buffer, "{s}", .{finding.detail}) catch "See source for details";
            rl.drawTextEx(font, detail, .{ .x = row.x + 17 * scale, .y = row.y + 37 * scale }, 14 * scale, 0, .{ .r = 151, .g = 170, .b = 193, .a = 255 });
        }
    }

    var page_buffer: [128:0]u8 = @splat(0);
    const page = if (report.findings.items.len == 0)
        "R rerun  ·  P portable folder  ·  Esc close"
    else
        std.fmt.bufPrintZ(&page_buffer, "↑/↓ review  ·  Enter open slide/source  ·  R rerun  ·  P portable folder  ·  Esc close   ({d}/{d})", .{ overlay.selected + 1, report.findings.items.len }) catch "Showtime controls";
    rl.drawTextEx(font, page, .{ .x = layout.footer.x, .y = layout.footer.y + 10 * scale }, 15 * scale, 0, .{ .r = 139, .g = 158, .b = 179, .a = 255 });
}

test "presenter pairing overlay scales for projector resolutions" {
    try std.testing.expectApproxEqAbs(@as(f32, 1), presenterOverlayScale(1280, 720), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), presenterOverlayScale(1920, 1080), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 3), presenterOverlayScale(3840, 2160), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1), presenterOverlayScale(900, 506), 0.001);
}

test "display picker rows stay clickable at compact and projector sizes" {
    const compact = displayPickerLayout(900, 506, 2, 0);
    try std.testing.expectEqual(@as(i32, 2), compact.visible_count);
    try std.testing.expectEqual(@as(i32, 0), compact.monitorAt(.{
        .x = @floatFromInt(compact.left + 10),
        .y = @floatFromInt(compact.top + 10),
    }).?);
    try std.testing.expectEqual(@as(i32, 1), compact.monitorAt(.{
        .x = @floatFromInt(compact.left + 10),
        .y = @floatFromInt(compact.top + compact.row_height + compact.row_gap + 10),
    }).?);
    try std.testing.expect(compact.monitorAt(.{ .x = 0, .y = 0 }) == null);

    const projector = displayPickerLayout(1920, 1080, 12, 9);
    try std.testing.expect(projector.visible_count < 12);
    try std.testing.expect(projector.start_monitor <= 9);
    try std.testing.expect(projector.start_monitor + projector.visible_count > 9);
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
            try slide_renderer.renderWithVideoPosters(
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
    studio_gallery_cache_builds: usize = 0,
    studio_gallery_projected_count: usize = 0,
    studio_gallery_placeholder_count: usize = 0,
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
        gallery_cache_builds: usize,
        gallery_projected_count: usize,
        gallery_placeholder_count: usize,
        cache_rebuilt: bool,
        slide_count: usize,
        item_count: usize,
        render_fragment_count: usize,
    ) void {
        self.last_studio_prepare_ms = elapsed_seconds * 1000;
        self.studio_document_cache_builds = document_cache_builds;
        self.studio_scene_cache_builds = scene_cache_builds;
        self.studio_composition_cache_builds = composition_cache_builds;
        self.studio_gallery_cache_builds = gallery_cache_builds;
        self.studio_gallery_projected_count = gallery_projected_count;
        self.studio_gallery_placeholder_count = gallery_placeholder_count;
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
            "STUDIO {d:.2} ms   CACHE {d}/{d}/{d}/{d}{s}   GALLERY {d}/{d}   DECK {d}   ITEMS {d}/{d}   MOUSE {d:.0}, {d:.0}   WINDOW {d} x {d}",
            .{
                self.last_studio_prepare_ms,
                self.studio_document_cache_builds,
                self.studio_scene_cache_builds,
                self.studio_composition_cache_builds,
                self.studio_gallery_cache_builds,
                if (self.studio_cache_rebuilt) "*" else "",
                self.studio_gallery_projected_count,
                self.studio_gallery_placeholder_count,
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
                        "BUILD {d:.1} ms {s} {d}/{d}   PREP {d:.2} ms   CACHE {d}/{d}/{d}/{d}{s}   GAL {d}/{d}   DECK {d}   ITEMS {d}/{d}",
                        .{
                            self.last_pre_render_ms,
                            @tagName(self.last_rebuild_mode),
                            self.last_rebuilt_slide_count,
                            self.last_rebuild_total_slide_count,
                            self.last_studio_prepare_ms,
                            self.studio_document_cache_builds,
                            self.studio_scene_cache_builds,
                            self.studio_composition_cache_builds,
                            self.studio_gallery_cache_builds,
                            if (self.studio_cache_rebuilt) "*" else "",
                            self.studio_gallery_projected_count,
                            self.studio_gallery_placeholder_count,
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
            "  \"studio\": {{ \"prepare_ms\": {d:.3}, \"document_cache_builds\": {d}, \"scene_cache_builds\": {d}, \"composition_cache_builds\": {d}, \"gallery_cache_builds\": {d}, \"gallery_projected\": {d}, \"gallery_placeholders\": {d} }},\n" ++
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
            diagnostics.studio_gallery_cache_builds,
            diagnostics.studio_gallery_projected_count,
            diagnostics.studio_gallery_placeholder_count,
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
    diagnostics.recordStudioPrepare(0.00002, 2, 2, 2, 3, 40, 1, false, 160, 7, 13);
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
    var neovim_clean = false;
    var diagnostics_enabled = false;
    var diagnostics_command_palette = false;
    var diagnostics_neovim_editor = false;
    var diagnostics_goto_slide = false;
    var diagnostics_file_browser = false;
    var diagnostics_command_tooltip = false;
    var diagnostics_precision_view = false;
    var diagnostics_grid_settings = false;
    var diagnostics_status_drawer = false;
    var diagnostics_presenter_pairing = false;
    var diagnostics_presenter_session = false;
    var diagnostics_presentation_capture = false;
    var diagnostics_display_picker = false;
    var diagnostics_confirm_display: ?i32 = null;
    var diagnostics_showtime = false;
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
    var diagnostics_motion_buffer: [128]u8 = undefined;
    var diagnostics_motion_id: ?[]const u8 = null;
    var diagnostics_timeline_step: ?usize = null;
    var diagnostics_motion_preview: ?f32 = null;
    var diagnostics_slide: ?usize = null;
    var diagnostics_motion_state: ?usize = null;
    var diagnostics_motion_transition = false;
    var diagnostics_video_playback = false;
    var diagnostics_library_preview_buffer: [128]u8 = undefined;
    var diagnostics_library_preview_name: ?[]const u8 = null;
    var diagnostics_library_definition_buffer: [128]u8 = undefined;
    var diagnostics_library_definition_name: ?[]const u8 = null;
    var diagnostics_find_slide_buffer: [studio.max_panel_search_bytes]u8 = undefined;
    var diagnostics_find_slide_query: ?[]const u8 = null;
    var showtime_report_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var showtime_report_path: ?[]const u8 = null;
    var portable_show_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var portable_show_path: ?[]const u8 = null;

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
            } else if (!positional_only and std.mem.eql(u8, arg, "--neovim-clean")) {
                neovim_clean = true;
            } else if (!positional_only and std.mem.eql(u8, arg, "--diagnostics")) {
                diagnostics_enabled = true;
            } else if (!positional_only and std.mem.eql(u8, arg, "--diagnostics-command-palette")) {
                diagnostics_enabled = true;
                diagnostics_command_palette = true;
                launch_studio = true;
            } else if (!positional_only and std.mem.eql(u8, arg, "--diagnostics-neovim-editor")) {
                diagnostics_enabled = true;
                diagnostics_neovim_editor = true;
                launch_studio = true;
            } else if (!positional_only and std.mem.eql(u8, arg, "--diagnostics-goto-slide")) {
                diagnostics_enabled = true;
                diagnostics_goto_slide = true;
            } else if (!positional_only and std.mem.eql(u8, arg, "--diagnostics-file-browser")) {
                diagnostics_enabled = true;
                diagnostics_file_browser = true;
                launch_studio = true;
            } else if (!positional_only and std.mem.eql(u8, arg, "--diagnostics-command-tooltip")) {
                diagnostics_enabled = true;
                diagnostics_command_tooltip = true;
                launch_studio = true;
            } else if (!positional_only and std.mem.eql(u8, arg, "--diagnostics-precision-view")) {
                diagnostics_enabled = true;
                diagnostics_precision_view = true;
                launch_studio = true;
            } else if (!positional_only and std.mem.eql(u8, arg, "--diagnostics-grid-settings")) {
                diagnostics_enabled = true;
                diagnostics_grid_settings = true;
                launch_studio = true;
            } else if (!positional_only and std.mem.eql(u8, arg, "--diagnostics-status-drawer")) {
                diagnostics_enabled = true;
                diagnostics_status_drawer = true;
                launch_studio = true;
            } else if (!positional_only and std.mem.eql(u8, arg, "--diagnostics-presenter-pairing")) {
                diagnostics_presenter_pairing = true;
                launch_studio = true;
            } else if (!positional_only and std.mem.eql(u8, arg, "--diagnostics-presenter-session")) {
                diagnostics_presenter_session = true;
            } else if (!positional_only and std.mem.eql(u8, arg, "--diagnostics-presentation-capture")) {
                diagnostics_enabled = true;
                diagnostics_presentation_capture = true;
            } else if (!positional_only and std.mem.eql(u8, arg, "--diagnostics-display-picker")) {
                diagnostics_display_picker = true;
                launch_studio = true;
            } else if (!positional_only and std.mem.startsWith(u8, arg, "--diagnostics-confirm-display=")) {
                diagnostics_confirm_display = parseDiagnosticDisplayNumber(arg["--diagnostics-confirm-display=".len..]) orelse
                    return error.InvalidDiagnosticMonitorIndex;
                launch_studio = true;
            } else if (!positional_only and std.mem.eql(u8, arg, "--diagnostics-showtime")) {
                diagnostics_showtime = true;
                launch_studio = true;
            } else if (!positional_only and std.mem.startsWith(u8, arg, "--showtime-report=")) {
                showtime_report_path = std.fmt.bufPrint(
                    &showtime_report_path_buffer,
                    "{s}",
                    .{arg["--showtime-report=".len..]},
                ) catch std.process.fatal("Showtime report path is too long", .{});
            } else if (!positional_only and std.mem.startsWith(u8, arg, "--portable-show=")) {
                portable_show_path = std.fmt.bufPrint(
                    &portable_show_path_buffer,
                    "{s}",
                    .{arg["--portable-show=".len..]},
                ) catch std.process.fatal("Portable show path is too long", .{});
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
            } else if (!positional_only and std.mem.startsWith(u8, arg, "--diagnostics-motion=")) {
                diagnostics_enabled = true;
                launch_studio = true;
                diagnostics_motion_id = std.fmt.bufPrint(
                    &diagnostics_motion_buffer,
                    "{s}",
                    .{arg["--diagnostics-motion=".len..]},
                ) catch std.process.fatal("Diagnostics motion ID is too long", .{});
            } else if (!positional_only and std.mem.startsWith(u8, arg, "--diagnostics-slide=")) {
                diagnostics_enabled = true;
                launch_studio = true;
                const one_based = std.fmt.parseInt(usize, arg["--diagnostics-slide=".len..], 10) catch
                    std.process.fatal("Diagnostics slide must be a whole number", .{});
                if (one_based == 0) std.process.fatal("Diagnostics slide numbers start at 1", .{});
                diagnostics_slide = one_based - 1;
            } else if (!positional_only and std.mem.eql(u8, arg, "--diagnostics-motion-transition")) {
                diagnostics_enabled = true;
                launch_studio = true;
                diagnostics_motion_transition = true;
            } else if (!positional_only and std.mem.startsWith(u8, arg, "--diagnostics-motion-state=")) {
                diagnostics_enabled = true;
                launch_studio = true;
                const one_based = std.fmt.parseInt(usize, arg["--diagnostics-motion-state=".len..], 10) catch
                    std.process.fatal("Diagnostics motion state must be a whole number", .{});
                if (one_based == 0) std.process.fatal("Diagnostics motion states start at 1", .{});
                diagnostics_motion_state = one_based - 1;
            } else if (!positional_only and std.mem.startsWith(u8, arg, "--diagnostics-motion-preview=")) {
                diagnostics_enabled = true;
                launch_studio = true;
                diagnostics_motion_preview = std.fmt.parseFloat(f32, arg["--diagnostics-motion-preview=".len..]) catch
                    std.process.fatal("Diagnostics motion preview time must be a number of seconds", .{});
            } else if (!positional_only and std.mem.startsWith(u8, arg, "--diagnostics-timeline-step=")) {
                diagnostics_enabled = true;
                launch_studio = true;
                diagnostics_timeline_step = std.fmt.parseInt(usize, arg["--diagnostics-timeline-step=".len..], 10) catch
                    std.process.fatal("Diagnostics timeline step must be a whole number", .{});
            } else if (!positional_only and std.mem.eql(u8, arg, "--diagnostics-video-playback")) {
                diagnostics_enabled = true;
                launch_studio = true;
                diagnostics_video_playback = true;
            } else if (!positional_only and std.mem.startsWith(u8, arg, "--diagnostics-library-preview=")) {
                diagnostics_enabled = true;
                launch_studio = true;
                diagnostics_library_preview_name = std.fmt.bufPrint(
                    &diagnostics_library_preview_buffer,
                    "{s}",
                    .{arg["--diagnostics-library-preview=".len..]},
                ) catch std.process.fatal("Diagnostics Library preview name is too long", .{});
            } else if (!positional_only and std.mem.startsWith(u8, arg, "--diagnostics-library-definition=")) {
                diagnostics_enabled = true;
                launch_studio = true;
                diagnostics_library_definition_name = std.fmt.bufPrint(
                    &diagnostics_library_definition_buffer,
                    "{s}",
                    .{arg["--diagnostics-library-definition=".len..]},
                ) catch std.process.fatal("Diagnostics Library definition name is too long", .{});
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
    if (diagnostics_presentation_capture) {
        if (slideshow_to_load == null or diagnostics_window_size == null or diagnostics_capture_path == null or
            !diagnostics_presenter_session)
            return error.InvalidDiagnosticPresentationCapture;
        // Studio-oriented diagnostics keep their existing defaults. This
        // explicit mode reuses the same stable framebuffer capture while the
        // real presentation renderer is driven through Presenter Companion.
        launch_studio = false;
    }
    if (showtime_report_path != null and portable_show_path != null)
        return error.ShowtimeOutputModesConflict;
    if (portable_show_path != null and slideshow_to_load == null)
        return error.PortableShowRequiresDeck;

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
    rl.setConfigFlags(.{
        .window_resizable = true,
        .vsync_hint = true,
        .window_hidden = showtime_report_path != null or portable_show_path != null,
    });
    rl.initWindow(screenWidth, screenHeight, "rayslides");
    rl.setWindowMinSize(900, 506);
    if (starts_in_studio or diagnostics_presentation_capture) {
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

    // Video sound arrives as raw PCM chunks streamed into an AudioStream.
    rl.setAudioStreamBufferSizeDefault(videoplayer.audio_stream_buffer_frames);
    rl.initAudioDevice();
    defer rl.closeAudioDevice();

    // Initialize GPU-backed resources after the window and unload them before it closes.
    try G.init(gpa, io);
    defer G.deinit();
    // Raygui is only used for a small number of application message boxes,
    // but it otherwise silently falls back to raylib's pixel font. Keep it on
    // the same embedded face as the rest of the application UI.
    rg.setFont(G.studio_ui_font);
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
    var presenter_network = PresenterNetworkState.init(presenter_options);
    var presenter_network_refresh_at: f64 = 0;
    var presenter_preview = try PresenterPreviewController.init();
    defer presenter_preview.deinit();
    var presenter_qr: qrcode.Code = .{};
    var presenter_pairing_visible = false;
    var presenter_laptop_link_copied_until: f64 = 0;
    if (diagnostics_presenter_pairing or diagnostics_presenter_session) {
        if (!ensurePresenterCompanionRunning(&presenter_runtime, presenter_options, &presenter_network))
            return error.DiagnosticPresenterPairingFailed;
        presenter_pairing_visible = true;
    }

    rl.setTargetFPS(60);
    var beast_mode: bool = false;
    var frame_diagnostics = FrameDiagnostics{ .enabled = diagnostics_enabled and !diagnostics_hide_hud };
    var diagnostics_selection_pending = diagnostics_select_id;
    var diagnostics_motion_pending = diagnostics_motion_id;
    var diagnostics_timeline_step_pending = diagnostics_timeline_step;
    var diagnostics_motion_preview_pending = diagnostics_motion_preview;
    var diagnostics_slide_pending = diagnostics_slide;
    var diagnostics_motion_state_pending = diagnostics_motion_state;
    var diagnostics_motion_transition_pending = diagnostics_motion_transition;
    var studio_preview: StudioMotionPreview = .{};
    defer studio_preview.stop(gpa);
    var diagnostics_library_preview_pending = diagnostics_library_preview_name;
    var diagnostics_library_definition_pending = diagnostics_library_definition_name;
    var diagnostics_command_palette_pending = diagnostics_command_palette;
    var diagnostics_neovim_editor_pending = diagnostics_neovim_editor;
    var diagnostics_file_browser_pending = diagnostics_file_browser;
    var diagnostics_precision_view_pending = diagnostics_precision_view;
    var diagnostics_grid_settings_pending = diagnostics_grid_settings;
    var diagnostics_status_drawer_pending = diagnostics_status_drawer;
    var diagnostics_find_slide_pending = diagnostics_find_slide_query;
    var diagnostics_incremental_edit_pending = diagnostics_incremental_edit_slide;
    var diagnostics_capture_stable_frames: usize = 0;
    var diagnostics_capture_complete = false;

    // Main game loop
    var is_pre_rendered: bool = false;
    var export_controller: ExportController = try .init(gpa, io, null);
    defer export_controller.deinit();
    // A presentation screenshot is rendered once with immutable authored
    // video posters, then read back at the start of the following frame. Live
    // playback keeps advancing and is never stopped or rewound for the copy.
    var screenshot_poster_render_pending = false;
    var screenshot_capture_pending = false;
    var laser_pointer: LaserPointer = try .init(gpa);
    defer laser_pointer.deinit();
    var remote_drawing: RemoteDrawing = try .init(gpa);
    defer remote_drawing.deinit();
    var remote_drawing_slide = G.current_slide;
    var studio_mode: studio.Studio = .{
        .enabled = starts_in_studio,
        .dirty = slideshow_to_load == null,
        .ui_font = G.studio_ui_font,
    };
    var embedded_editor = nvim_editor.Controller.init(gpa, io, neovim_clean);
    defer embedded_editor.deinit();
    var property_prompt: studio_prompt.Prompt = .{};
    var pending_semantic_command: ?studio.SemanticCommand = null;
    var pending_neovim_semantic_command: ?studio.SemanticCommand = null;
    var pending_save_as = false;
    var pending_portable_show = false;
    var showtime_overlay = ShowtimeOverlay{ .visible = diagnostics_showtime };
    var goto_slide_picker: goto_slide.Picker = .{ .active = diagnostics_goto_slide };
    var showtime_report: ?showtime.Report = null;
    defer if (showtime_report) |*report| report.deinit();
    var showtime_cli_completed = false;
    var showtime_cli_failed = false;
    var showtime_source_line_pending: ?usize = null;
    var showtime_definition_identity_pending: ?usize = null;
    var studio_history = StudioHistory.init(gpa);
    defer studio_history.deinit();
    var studio_clipboard = StudioClipboard.init(gpa);
    defer studio_clipboard.deinit();
    var studio_bounds = std.ArrayList(studio.ResolvedBounds).empty;
    defer studio_bounds.deinit(gpa);
    var studio_render_bounds = std.ArrayList(renderer.SlideshowRenderer.ItemRenderBounds).empty;
    defer studio_render_bounds.deinit(gpa);
    var studio_previous_bounds = std.ArrayList(studio.ResolvedBounds).empty;
    defer studio_previous_bounds.deinit(gpa);
    var studio_previous_render_bounds = std.ArrayList(renderer.SlideshowRenderer.ItemRenderBounds).empty;
    defer studio_previous_render_bounds.deinit(gpa);
    var studio_state_changes = std.ArrayList(studio.StateChangeSummary).empty;
    defer studio_state_changes.deinit(gpa);
    var studio_workspace_cache = StudioWorkspaceCache.init(gpa);
    defer studio_workspace_cache.deinit();
    var studio_library_gallery_cache = StudioLibraryGalleryCache.init(gpa);
    defer studio_library_gallery_cache.deinit();
    var studio_library_preview_cache = StudioLibraryPreviewCache.init(gpa);
    defer studio_library_preview_cache.deinit(G.slide_renderer);
    var studio_composition_cache: StudioCompositionCache = .{};

    var fullscreen_mode: FullscreenMode = .windowed;
    var windowed_width = screenWidth;
    var windowed_height = screenHeight;
    var display_picker = DisplayPicker.init();
    if (diagnostics_confirm_display) |requested_monitor| {
        const monitor_count = DisplayPicker.monitorCount();
        if (requested_monitor >= monitor_count) return error.InvalidDiagnosticMonitorIndex;
        // Drive the same identify + confirm functions as the interactive
        // picker. This gives venue QA a deterministic path even when a window
        // manager isolation Space cannot deliver synthetic GLFW input.
        openDisplayPicker(
            &display_picker,
            &fullscreen_mode,
            windowed_width,
            windowed_height,
            &screenWidth,
            &screenHeight,
        );
        display_picker.candidate_monitor = requested_monitor;
        placeDisplayPickerWindow(
            &display_picker,
            requested_monitor,
            &windowed_width,
            &windowed_height,
            &screenWidth,
            &screenHeight,
        );
        closeDisplayPicker(
            &display_picker,
            true,
            &fullscreen_mode,
            &windowed_width,
            &windowed_height,
            &screenWidth,
            &screenHeight,
        );
        log.info("diagnostics confirmed presentation display {d}/{d}: {s} ({d}x{d} @ {d} Hz)", .{
            requested_monitor + 1,
            monitor_count,
            rl.getMonitorName(requested_monitor),
            rl.getMonitorWidth(requested_monitor),
            rl.getMonitorHeight(requested_monitor),
            rl.getMonitorRefreshRate(requested_monitor),
        });
    }
    if (diagnostics_display_picker) display_picker.visible = true;
    var window_close_seen = false;
    var studio_was_capturing_input = false;

    // Dev/docs helper: RAYSLIDES_PILL_SHOT=SECONDS[:PATH] keeps the video
    // controls visible (see processVideoOverlay) and exports the frame shown
    // at SECONDS to PATH (default /tmp/video_pill_shot.png), for headless
    // screenshots of the player pill.
    var pill_shot_at: ?f64 = null;
    var pill_shot_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var pill_shot_path: [:0]const u8 = "/tmp/video_pill_shot.png";
    if (std.c.getenv("RAYSLIDES_PILL_SHOT")) |raw_spec| {
        const spec = std.mem.span(raw_spec);
        var spec_it = std.mem.splitScalar(u8, spec, ':');
        pill_shot_at = std.fmt.parseFloat(f64, spec_it.next() orelse "") catch null;
        if (spec_it.rest().len > 0) {
            pill_shot_path = std.fmt.bufPrintZ(&pill_shot_path_buffer, "{s}", .{spec_it.rest()}) catch pill_shot_path;
        }
        if (pill_shot_at == null) log.err("RAYSLIDES_PILL_SHOT wants SECONDS[:PATH], got {s}", .{spec});
    }

    while (true) {
        frame_diagnostics.observeFrame(rl.getTime());
        syncWindowTitle(studio_mode.dirty);
        var neovim_source_changed_this_frame = false;
        var neovim_field_apply: ?nvim_editor.Apply = null;
        var neovim_apply_message_buffer: [512]u8 = undefined;
        const neovim_outer = nvim_editor.overlayRect(screenWidth, screenHeight);
        const neovim_closed_this_frame = embedded_editor.update(neovim_outer);
        if (neovim_closed_this_frame) pending_neovim_semantic_command = null;
        if (embedded_editor.takeApply()) |apply| {
            switch (apply.kind) {
                .field => neovim_field_apply = apply,
                .source => {
                    if (apply.accepted_revision != G.source_revision) {
                        embedded_editor.rejectApply("Rayslides changed since this editor opened; close and reopen Neovim");
                    } else if (std.mem.eql(u8, apply.source, G.editor_memory[0..G.source_len])) {
                        embedded_editor.acceptApply(G.source_revision);
                    } else if (neovimSourceDiagnostic(
                        gpa,
                        apply.source,
                        G.editor_memory.len - 1,
                        &neovim_apply_message_buffer,
                    )) |diagnostic_opt| {
                        if (diagnostic_opt) |diagnostic| {
                            embedded_editor.rejectApply(diagnostic);
                            log.warn("Neovim source apply rejected: {s}", .{diagnostic});
                        } else {
                            const owned = gpa.dupe(u8, apply.source) catch null;
                            if (owned) |replacement| {
                                const old_len = std.math.cast(isize, G.source_len) orelse 0;
                                const new_len = std.math.cast(isize, replacement.len) orelse 0;
                                if (recordStudioPatch(&studio_history, .{
                                    .source = replacement,
                                    .byte_delta = new_len - old_len,
                                })) |_| {
                                    studio_mode.markSourceChanged();
                                    studio_mode.dirty = editorSourceDirty();
                                    is_pre_rendered = false;
                                    neovim_source_changed_this_frame = true;
                                    embedded_editor.acceptApply(G.source_revision);
                                } else |err| {
                                    const message = std.fmt.bufPrint(
                                        &neovim_apply_message_buffer,
                                        "Rayslides rejected this write: {s}",
                                        .{@errorName(err)},
                                    ) catch "Rayslides rejected this write; the last valid slideshow is unchanged";
                                    embedded_editor.rejectApply(message);
                                    log.warn("Neovim source apply rejected after validation: {any}", .{err});
                                }
                            } else {
                                embedded_editor.rejectApply("Rayslides could not allocate this source update");
                            }
                        }
                    } else |err| {
                        const message = std.fmt.bufPrint(
                            &neovim_apply_message_buffer,
                            "Rayslides could not validate this write: {s}",
                            .{@errorName(err)},
                        ) catch "Rayslides could not validate this write";
                        embedded_editor.rejectApply(message);
                        log.warn("Neovim source validation failed: {any}", .{err});
                    }
                },
            }
        }
        if (diagnostics_neovim_editor_pending and G.source_len > 0 and !embedded_editor.active()) {
            diagnostics_neovim_editor_pending = false;
            if (embedded_editor.beginSourceClean(G.editor_memory[0..G.source_len], G.source_revision) != .started)
                return error.DiagnosticNeovimEditorUnavailable;
        }
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
        const library_picker_active_at_frame_start = studio_mode.libraryPickerActive();
        const goto_slide_active_at_frame_start = goto_slide_picker.active;
        const text_input_active_at_frame_start = goto_slide_active_at_frame_start or
            property_prompt.active or studio_file_browser.active or studio_mode.textEntryActive();
        const neovim_shortcut_requested = !embedded_editor.active() and studio_mode.capturesInput() and
            !text_input_active_at_frame_start and !display_picker.visible and !showtime_overlay.visible and
            !presenter_pairing_visible and shortcutModifierDown() and rl.isKeyPressed(.e);
        if (neovim_shortcut_requested) {
            switch (embedded_editor.beginSource(G.editor_memory[0..G.source_len], G.source_revision)) {
                .started => studio_mode.setNotice(.none),
                .support_disabled, .executable_missing => studio_mode.setNotice(.neovim_unavailable),
                .start_failed => studio_mode.setNotice(.neovim_start_failed),
            }
        }
        // Once the embedded UI exists it owns the complete input frame. Raylib
        // key queries are non-consuming, so merely forwarding a key to Neovim
        // does not stop later Rayslides shortcut checks from seeing it too.
        const neovim_captures_input = neovimOwnsInput(
            embedded_editor.active(),
            neovim_shortcut_requested,
            neovim_closed_this_frame,
        );
        const g_shortcut_action = goto_slide.classifyGShortcut(.{
            .pressed = !neovim_captures_input and rl.isKeyPressed(.g),
            .shortcut_modifier_down = shortcutModifierDown(),
            .shift_down = rl.isKeyDown(.left_shift) or rl.isKeyDown(.right_shift),
            .legacy_presentation_navigation = !studio_mode.capturesInput(),
        });
        const presenter_network_now = rl.getTime();
        if (presenter_runtime.isRunning() and !presenter_network.explicit and
            presenter_network_now >= presenter_network_refresh_at)
        {
            presenter_network_refresh_at = presenter_network_now + 1.5;
            if (presenter_network.refresh() and
                !rePairPresenterCompanion(&presenter_runtime, &presenter_network))
            {
                presenter_pairing_visible = false;
            }
        }
        if (diagnostics_presenter_session and presenter_pairing_visible and presenter_runtime.phoneConnected()) {
            presenter_pairing_visible = false;
        }
        const presenter_pairing_visible_at_frame_start = presenter_pairing_visible;
        const display_picker_visible_at_frame_start = display_picker.visible;
        const showtime_visible_at_frame_start = showtime_overlay.visible;
        var presenter_overlay_consumed_input = false;
        if (neovim_captures_input) {
            presenter_overlay_consumed_input = true;
        } else if (goto_slide_active_at_frame_start) {
            presenter_overlay_consumed_input = true;
            switch (goto_slide_picker.updateFromRaylib(G.slideshow.slides.items.len)) {
                .none => {},
                .cancelled => window_close_seen = false,
                .select => |slide_index| {
                    if (studio_mode.capturesInput()) prepareStudioForSlideJump(&studio_mode, &studio_library_preview_cache);
                    jumpToSlide(@intCast(slide_index), rl.getTime());
                    window_close_seen = false;
                },
            }
        } else if (!export_controller.running and !text_input_active_at_frame_start and
            !showtime_visible_at_frame_start and !display_picker_visible_at_frame_start and
            !presenter_pairing_visible_at_frame_start and g_shortcut_action == .open_picker)
        {
            goto_slide_picker.open();
            if (studio_mode.capturesInput()) suspendStudioForSlidePicker(&studio_mode, &studio_library_preview_cache);
            presenter_overlay_consumed_input = true;
            window_close_seen = false;
        } else if (showtime_visible_at_frame_start) {
            presenter_overlay_consumed_input = true;
            if (showtime_report) |*active_report| switch (updateShowtimeOverlay(&showtime_overlay, active_report, screenWidth, screenHeight)) {
                .none => {},
                .close => {
                    showtime_overlay.visible = false;
                    window_close_seen = false;
                },
                .rerun => {
                    const runtime = showtimeRuntimeSnapshot(
                        &display_picker,
                        fullscreen_mode,
                        &presenter_runtime,
                        &presenter_network,
                        &crowd_runtime,
                    );
                    if (buildLiveShowtimeReport(runtime)) |report| {
                        replaceShowtimeReport(&showtime_report, report);
                        showtime_overlay.normalize(showtime_report.?.findings.items.len, showtimeOverlayLayout(screenWidth, screenHeight).capacity);
                    } else |err| log.err("Showtime rerun failed: {any}", .{err});
                },
                .portable => {
                    pending_portable_show = true;
                    var folder_buffer: [std.fs.max_path_bytes]u8 = undefined;
                    const deck_name = if (G.slideshow_filp) |path| std.fs.path.basename(path) else "show.sld";
                    const extension = std.fs.path.extension(deck_name);
                    const stem = deck_name[0 .. deck_name.len - extension.len];
                    const initial = std.fmt.bufPrint(&folder_buffer, "{s}-portable", .{stem}) catch "show-portable";
                    property_prompt.begin(.portable_folder, initial);
                    showtime_overlay.visible = false;
                },
                .open_finding => |finding_index| {
                    const finding = showtime_report.?.findings.items[finding_index];
                    if (finding.slide_index) |slide_index| {
                        if (slide_index < G.slideshow.slides.items.len) {
                            G.current_slide = @intCast(slide_index);
                            studio_mode.active_morph_state = finding.morph_state;
                            G.playback.enterSlide(null, 0, 0, .{}, 1, rl.getTime());
                            const slide = G.slideshow.slides.items[slide_index];
                            const items = if (finding.morph_state) |state|
                                if (state < slide.morph_states.items.len) slide.morph_states.items[state].items.items else &.{}
                            else
                                slide.items.?.items;
                            if (finding.owner_identity) |identity| {
                                for (items) |item| {
                                    if (item.identity != identity) continue;
                                    _ = studio_mode.selectItemByIdOrSource(items, item.id, item.effectiveSource());
                                    break;
                                }
                            }
                            showtime_overlay.visible = false;
                        }
                    } else if (finding.source_line) |source_line| {
                        showtime_source_line_pending = source_line;
                        showtime_definition_identity_pending = finding.owner_identity;
                        showtime_overlay.visible = false;
                    }
                },
            };
        } else if (display_picker_visible_at_frame_start) {
            presenter_overlay_consumed_input = true;
            display_picker.confirmed_monitor = DisplayPicker.clampMonitor(display_picker.confirmed_monitor);
            display_picker.candidate_monitor = DisplayPicker.clampMonitor(display_picker.candidate_monitor);
            if (rl.isMouseButtonPressed(.left)) {
                const layout = displayPickerLayout(
                    screenWidth,
                    screenHeight,
                    DisplayPicker.monitorCount(),
                    display_picker.candidate_monitor,
                );
                if (layout.monitorAt(rl.getMousePosition())) |monitor| {
                    if (display_picker.identified_monitor == monitor and
                        display_picker.candidate_monitor == monitor)
                    {
                        closeDisplayPicker(
                            &display_picker,
                            true,
                            &fullscreen_mode,
                            &windowed_width,
                            &windowed_height,
                            &screenWidth,
                            &screenHeight,
                        );
                    } else {
                        display_picker.candidate_monitor = monitor;
                        placeDisplayPickerWindow(
                            &display_picker,
                            monitor,
                            &windowed_width,
                            &windowed_height,
                            &screenWidth,
                            &screenHeight,
                        );
                    }
                }
            }
            if (rl.isKeyPressed(.up) or rl.isKeyPressed(.left)) display_picker.cycle(-1);
            if (rl.isKeyPressed(.down) or rl.isKeyPressed(.right) or rl.isKeyPressed(.n)) display_picker.cycle(1);
            if (rl.isKeyPressed(.space)) placeDisplayPickerWindow(
                &display_picker,
                display_picker.candidate_monitor,
                &windowed_width,
                &windowed_height,
                &screenWidth,
                &screenHeight,
            );
            if (rl.isKeyPressed(.enter)) closeDisplayPicker(
                &display_picker,
                true,
                &fullscreen_mode,
                &windowed_width,
                &windowed_height,
                &screenWidth,
                &screenHeight,
            );
            if (rl.isKeyPressed(.escape) or rl.isKeyPressed(.d)) {
                closeDisplayPicker(
                    &display_picker,
                    false,
                    &fullscreen_mode,
                    &windowed_width,
                    &windowed_height,
                    &screenWidth,
                    &screenHeight,
                );
                window_close_seen = false;
            }
        } else if (!text_input_active_at_frame_start and rl.isKeyPressed(.d)) {
            presenter_overlay_consumed_input = true;
            presenter_pairing_visible = false;
            openDisplayPicker(
                &display_picker,
                &fullscreen_mode,
                windowed_width,
                windowed_height,
                &screenWidth,
                &screenHeight,
            );
        } else {
            if (!text_input_active_at_frame_start and rl.isKeyPressed(.p)) {
                presenter_overlay_consumed_input = true;
                if (rl.isKeyDown(.left_shift) or rl.isKeyDown(.right_shift)) {
                    presenter_runtime.stop();
                    presenter_pairing_visible = false;
                    log.info("Presenter Companion stopped and pairing invalidated", .{});
                } else if (presenter_pairing_visible) {
                    presenter_pairing_visible = false;
                } else if (ensurePresenterCompanionRunning(&presenter_runtime, presenter_options, &presenter_network)) {
                    presenter_pairing_visible = true;
                }
            }
            if (presenter_pairing_visible_at_frame_start and rl.isKeyPressed(.escape)) {
                presenter_pairing_visible = false;
                presenter_overlay_consumed_input = true;
                window_close_seen = false;
            }
            if (presenter_pairing_visible_at_frame_start and rl.isKeyPressed(.n)) {
                presenter_overlay_consumed_input = true;
                if (presenter_network.cycle()) {
                    if (!rePairPresenterCompanion(&presenter_runtime, &presenter_network))
                        presenter_pairing_visible = false;
                }
            }
            if (presenter_pairing_visible_at_frame_start and rl.isKeyPressed(.l)) {
                presenter_overlay_consumed_input = true;
                const private_link = presenter_runtime.pairing_url.slice();
                var clipboard_buffer: [385:0]u8 = @splat(0);
                if (private_link.len < clipboard_buffer.len) {
                    @memcpy(clipboard_buffer[0..private_link.len], private_link);
                    rl.setClipboardText(clipboard_buffer[0..private_link.len :0]);
                    presenter_laptop_link_copied_until = rl.getTime() + 1.8;
                }
            }
        }
        const presenter_overlay_captures_input = presenter_pairing_visible_at_frame_start or
            presenter_pairing_visible or display_picker_visible_at_frame_start or
            display_picker.visible or showtime_visible_at_frame_start or
            showtime_overlay.visible or goto_slide_active_at_frame_start or
            goto_slide_picker.active or presenter_overlay_consumed_input or neovim_captures_input;
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

        // The pill screenshot reads the last completed frame here, before any
        // drawing, for the same reason ExportController.snapshot does.
        if (pill_shot_at) |shot_at| {
            if (rl.getTime() > shot_at) {
                pill_shot_at = null;
                var img = try rl.loadImageFromScreen();
                defer rl.unloadImage(img);
                if (img.exportToFile(pill_shot_path)) {
                    log.info("pill screenshot saved to {s}", .{pill_shot_path});
                } else {
                    log.err("could not export pill screenshot to {s}", .{pill_shot_path});
                }
            }
        }

        if (screenshot_capture_pending) {
            screenshot_capture_pending = false;
            try export_controller.screenshot(G.slideshow_filp);
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

        // Cmd/Ctrl-O works in Studio and in presentation alike, exactly like
        // dropping a deck onto the window; the same open guards apply.
        if (!presenter_overlay_captures_input and !text_input_active_at_frame_start and
            !export_controller.running and shortcutModifierDown() and rl.isKeyPressed(.o))
        {
            beginStudioFileBrowse(.deck);
        }

        if (!presenter_overlay_captures_input and !text_input_active_at_frame_start and rl.isKeyPressed(.s)) {
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
                    // Stopped videos show their poster frame, which keeps the
                    // exported pages deterministic.
                    G.slide_renderer.stopAllVideos();
                    export_controller.start(G.current_slide, G.playback.visible_step, G.slideshow.slides.items.len);
                    G.current_slide = 0;
                }
            } else {
                if (export_controller.running == false) {
                    screenshot_poster_render_pending = true;
                }
            }
        }

        if (!presenter_overlay_captures_input and !text_input_active_at_frame_start and rl.isKeyPressed(.f3)) {
            frame_diagnostics.enabled = !frame_diagnostics.enabled;
            log.info("frame diagnostics {s}", .{if (frame_diagnostics.enabled) "enabled" else "disabled"});
        }

        // Finder/Open With arrives as a macOS open-documents Apple event.
        // Raylib file drops can additionally create image/video items while
        // Studio owns input. Copy every accepted transient OS path before
        // releasing Raylib's FilePathList below.
        var dropped_media_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        var dropped_media_path_len: usize = 0;
        var dropped_media_kind: ?StudioMediaKind = null;
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
                if (isSlideshowDocumentPath(path)) {
                    if (queueExternalDeckOpen(path, text_input_active_at_frame_start, &studio_mode)) break;
                    continue;
                }
                if (studio_mode.capturesInput() and !text_input_active_at_frame_start) {
                    if (studioMediaKindForPath(path)) |kind| {
                        if (dropped_media_kind == null and path.len <= dropped_media_path_buffer.len) {
                            @memcpy(dropped_media_path_buffer[0..path.len], path);
                            dropped_media_path_len = path.len;
                            dropped_media_kind = kind;
                        }
                        // One drop maps to one ordinary source/history edit;
                        // additional recognized media files can be dropped in
                        // following gestures without making a hidden batch.
                        continue;
                    }
                }
                studio_mode.setNotice(if (studio_mode.capturesInput()) .media_drop_unsupported else .open_requires_sld);
                log.warn("Ignored unsupported dropped file: {s}", .{path});
            }
        }

        // (re-) load slideshow
        if (G.slideshow_filp_to_load) |filp| {
            const studio_was_enabled = studio_mode.enabled;
            // The live renderer is replaced by a successful document load;
            // release its detached definition scene before staging the swap.
            if (studio_mode.definitionModeActive())
                studio_mode.leaveDefinitionMode(studio_library_preview_cache.items());
            studio_library_preview_cache.clear(G.slide_renderer);
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
                invalidateShowtimeForDocumentReplacement(&showtime_overlay, &showtime_report);
                is_pre_rendered = false;
            } else |err| {
                studio_mode.setNotice(.reload_failed);
                log.err("Slideshow reload rejected; current document preserved: {any}", .{err});
                if (!showtime_cli_completed and (showtime_report_path != null or portable_show_path != null)) {
                    var report = try buildLoadFailureShowtimeReport(filp, err);
                    defer report.deinit();
                    if (showtime_report_path) |report_path| {
                        const encoded = try showtime.jsonAlloc(gpa, &report);
                        defer gpa.free(encoded);
                        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = report_path, .data = encoded });
                        log.err("Showtime report written to {s}: not ready", .{report_path});
                    } else if (portable_show_path) |destination| {
                        log.err("Portable show was not created at {s}: the source deck did not pass parsing", .{destination});
                    }
                    showtime_cli_failed = true;
                    showtime_cli_completed = true;
                    break;
                }
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
                        if (!export_controller.running and !studio_mode.capturesInput()) {
                            G.slide_renderer.autoplayVideosOnSlide(G.current_slide, now);
                        }
                    }
                    log.info("PRE-RENDERED {s} {d}/{d} slides", .{
                        @tagName(result.mode),
                        result.rebuilt_slide_count,
                        result.total_slide_count,
                    });
                    is_pre_rendered = true;

                    const showtime_runtime = showtimeRuntimeSnapshot(
                        &display_picker,
                        fullscreen_mode,
                        &presenter_runtime,
                        &presenter_network,
                        &crowd_runtime,
                    );
                    if (showtime_overlay.visible and showtime_report == null) {
                        replaceShowtimeReport(&showtime_report, try buildLiveShowtimeReport(showtime_runtime));
                        showtime_overlay.visible = true;
                    }
                    if (!showtime_cli_completed) {
                        if (showtime_report_path) |report_path| {
                            var report = try buildLiveShowtimeReport(showtime_runtime);
                            defer report.deinit();
                            const encoded = try showtime.jsonAlloc(gpa, &report);
                            defer gpa.free(encoded);
                            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = report_path, .data = encoded });
                            showtime_cli_failed = !report.ready();
                            showtime_cli_completed = true;
                            log.info("Showtime report written to {s}: {s}", .{ report_path, if (report.ready()) "ready" else "not ready" });
                            break;
                        }
                        if (portable_show_path) |destination| {
                            var portable = try showtime.createPortableFolder(
                                gpa,
                                io,
                                G.editor_memory[0..G.source_len],
                                G.slideshow_filp.?,
                                destination,
                            );
                            defer portable.deinit();
                            var report = try verifyPortableShowtime(portable.deck_path, showtime_runtime);
                            defer report.deinit();
                            try report.add(.info, .portable, .portable_verified, null, null, null, null, "Portable copy re-opened successfully", "The copied .sld and copied assets passed an independent parser/renderer preflight.");
                            const encoded = try showtime.jsonAlloc(gpa, &report);
                            defer gpa.free(encoded);
                            const portable_report_path = try std.fs.path.join(gpa, &.{ destination, "showtime-report.json" });
                            defer gpa.free(portable_report_path);
                            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = portable_report_path, .data = encoded, .flags = .{ .exclusive = true } });
                            showtime_cli_failed = !report.ready();
                            showtime_cli_completed = true;
                            log.info("Portable show created at {s}: {s}", .{ destination, if (report.ready()) "ready" else "not ready" });
                            break;
                        }
                    }
                }
            }
        }

        const now = rl.getTime();
        G.playback.settle(now);
        G.slide_renderer.tickVideos(now);
        if (G.slide_renderer.takeCameraFailure()) studio_mode.setNotice(.camera_start_failed);
        if (!studio_mode.capturesInput() and studio_mode.notice == .camera_start_failed and
            (rl.isMouseButtonPressed(.left) or rl.isKeyPressed(.escape)))
            studio_mode.setNotice(.none);
        // Entering Studio must silence a playing video; editing over audio
        // is jarring and Studio always shows the static base scene anyway.
        if (studio_mode.capturesInput() and !studio_was_capturing_input) G.slide_renderer.stopAllVideos();
        studio_was_capturing_input = studio_mode.capturesInput();
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
        if (fullscreen_mode == .windowed) {
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
        const authored_studio_items = studio_items;
        const studio_prepare_started_at = rl.getTime();

        var frame_studio_catalog: ?studio_catalog.Catalog = null;
        var workspace_cache_rebuilt = false;
        var gallery_cache_rebuilt = false;
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
                G.slide_renderer.revealBuilds(G.current_slide),
                G.editor_memory[0..G.source_len],
            )) or workspace_cache_rebuilt;
            frame_studio_catalog = studio_workspace_cache.catalog;
            if (frame_studio_catalog) |catalog| gallery_cache_rebuilt = try studio_library_gallery_cache.refresh(
                G.source_revision,
                G.editor_memory[0..G.source_len],
                catalog,
                studio_workspace_cache.library_catalog_indices.items,
                studio_workspace_cache.library_item_offset orelse item_insertion_offset,
                studio_workspace_cache.library_slide_offset orelse slide_insertion_offset,
            );
            studio_workspace = .{
                .visible = true,
                .slides = studio_workspace_cache.slide_summaries.items,
                .current_slide = if (G.current_slide >= 0) @intCast(G.current_slide) else 0,
                .library = studio_workspace_cache.library_entries.items,
                .library_visuals = studio_library_gallery_cache.visuals.items,
                .morph_states = studio_workspace_cache.morph_summaries.items,
                .builds = studio_workspace_cache.build_summaries.items,
                .transition = if (current_slide) |slide| studioTransitionSummary(slide) else .{},
                .new_deck = pristineUntitledDeck(),
                .undo_available = studio_history.undo_stack.items.len > 0,
                .redo_available = studio_history.redo_stack.items.len > 0,
                .clipboard_item_count = studio_clipboard.items.items.len,
            };
        }
        if (showtime_source_line_pending) |source_line| {
            var opened = false;
            if (frame_studio_catalog) |catalog| {
                if (showtimeDefinitionCatalogIndexAtLine(
                    G.editor_memory[0..G.source_len],
                    catalog,
                    source_line,
                )) |catalog_index| {
                    if (std.mem.indexOfScalar(
                        usize,
                        studio_workspace_cache.library_catalog_indices.items,
                        catalog_index,
                    )) |workspace_index| {
                        if (workspace_index < studio_workspace.library.len) {
                            opened = studio_mode.enterDefinitionMode(
                                studio_items,
                                catalog_index,
                                workspace_index,
                                studio_workspace.library[workspace_index],
                            );
                        }
                    }
                }
            }
            if (!opened) {
                showtime_definition_identity_pending = null;
                studio_mode.setNotice(.edit_failed);
                log.warn("Showtime could not open reusable definition at source line {d}", .{source_line});
            }
            showtime_source_line_pending = null;
        }
        if (diagnostics_library_definition_pending) |name| {
            const workspace_index = studioLibraryWorkspaceIndex(studio_workspace, name);
            if (workspace_index) |index| {
                const catalog = frame_studio_catalog;
                if (catalog != null and index < studio_workspace_cache.library_catalog_indices.items.len) {
                    const catalog_index = studio_workspace_cache.library_catalog_indices.items[index];
                    if (!studio_mode.enterDefinitionMode(
                        studio_items,
                        catalog_index,
                        index,
                        studio_workspace.library[index],
                    )) log.warn("diagnostics could not open Library definition name={s}", .{name});
                } else {
                    log.warn("diagnostics Library catalog unavailable for name={s}", .{name});
                }
            } else {
                log.warn("diagnostics could not find Library definition name={s}", .{name});
            }
            diagnostics_library_definition_pending = null;
        }
        var definition_preview_entry: ?studio.LibraryEntry = null;
        var definition_edit_context: ?StudioDefinitionEditContext = null;
        if (studio_mode.capturesInput()) definition: {
            const catalog_index = studio_mode.definitionCatalogIndex() orelse break :definition;
            const catalog = frame_studio_catalog orelse {
                studio_mode.leaveDefinitionMode(studio_library_preview_cache.items());
                studio_library_preview_cache.clear(G.slide_renderer);
                break :definition;
            };
            const workspace_index = std.mem.indexOfScalar(
                usize,
                studio_workspace_cache.library_catalog_indices.items,
                catalog_index,
            ) orelse {
                studio_mode.leaveDefinitionMode(studio_library_preview_cache.items());
                studio_library_preview_cache.clear(G.slide_renderer);
                studio_mode.setNotice(.edit_failed);
                break :definition;
            };
            if (catalog_index >= catalog.entries.len or workspace_index >= studio_workspace.library.len) {
                studio_mode.leaveDefinitionMode(studio_library_preview_cache.items());
                studio_library_preview_cache.clear(G.slide_renderer);
                studio_mode.setNotice(.edit_failed);
                break :definition;
            }
            const entry = catalog.entries[catalog_index];
            const workspace_entry = studio_workspace.library[workspace_index];
            if (!studio_mode.syncDefinitionMode(catalog_index, workspace_index, workspace_entry)) {
                studio_mode.leaveDefinitionMode(studio_library_preview_cache.items());
                studio_library_preview_cache.clear(G.slide_renderer);
                studio_mode.setNotice(.edit_failed);
                break :definition;
            }
            const insertion_offset = switch (entry.kind) {
                .element, .group => studio_workspace_cache.library_item_offset orelse entry.full_end,
                .slide => studio_workspace_cache.library_slide_offset orelse entry.full_end,
            };
            _ = studio_library_preview_cache.refresh(
                G.slide_renderer,
                G.source_revision,
                G.editor_memory[0..G.source_len],
                catalog_index,
                entry,
                insertion_offset,
                authored_studio_items,
                G.slideshow_filp orelse "untitled.sld",
            ) catch |err| {
                studio_mode.leaveDefinitionMode(studio_library_preview_cache.items());
                studio_library_preview_cache.clear(G.slide_renderer);
                studio_mode.setNotice(.edit_failed);
                log.err("Studio Definition mode projection failed: {any}", .{err});
                break :definition;
            };
            studio_items = studio_library_preview_cache.items();
            studio_mode.applyPendingDefinitionSelection(studio_items);
            if (showtime_definition_identity_pending) |identity| {
                for (studio_items) |item| {
                    if (item.identity != identity) continue;
                    _ = studio_mode.selectItemByIdOrSource(studio_items, item.id, item.effectiveSource());
                    break;
                }
                showtime_definition_identity_pending = null;
            }
            definition_preview_entry = workspace_entry;
            definition_edit_context = switch (entry.kind) {
                .element => null,
                .group => .{
                    .kind = .group,
                    .scene = .{ .group_definition = entry.directive_offset },
                },
                .slide => .{
                    .kind = .slide,
                    .scene = .{ .slide_definition = entry.directive_offset },
                },
            };
        }
        const studio_render_fragment_count = if (definition_preview_entry != null)
            try collectStudioDefinitionBounds(&studio_bounds, &studio_render_bounds, gpa, studio_items)
        else
            try collectStudioBounds(
                &studio_bounds,
                &studio_render_bounds,
                gpa,
                G.current_slide,
                studio_mode.active_morph_state,
                studio_items,
            );
        // Morph scene context for ghosts and the State section: the previous
        // scene's bounds plus every object the active state touches.
        studio_previous_bounds.clearRetainingCapacity();
        studio_state_changes.clearRetainingCapacity();
        if (studio_mode.capturesInput() and definition_preview_entry == null) {
            if (studio_mode.active_morph_state) |state_index| {
                if (current_slide) |slide| if (state_index < slide.morph_states.items.len) {
                    const previous_items = if (state_index == 0) (if (slide.items) |*list| list.items else &.{}) else slide.morph_states.items[state_index - 1].items.items;
                    _ = try collectStudioBounds(
                        &studio_previous_bounds,
                        &studio_previous_render_bounds,
                        gpa,
                        G.current_slide,
                        if (state_index == 0) null else state_index - 1,
                        previous_items,
                    );
                    try collectStudioStateChanges(&studio_state_changes, gpa, slide, state_index, studio_items);
                };
            }
        }
        studio_mode.setMorphSceneContext(studio_previous_bounds.items, studio_state_changes.items);
        if (diagnostics_slide_pending) |slide_index| {
            if (slide_index < G.slideshow.slides.items.len and @as(i32, @intCast(slide_index)) != G.current_slide) {
                jumpToSlide(@intCast(slide_index), rl.getTime());
            }
            diagnostics_slide_pending = null;
            // Selection and scene hooks must see the requested slide's items.
            continue;
        }
        if (diagnostics_motion_state_pending) |state_index| {
            if (current_slide != null and state_index < current_slide.?.morph_states.items.len) {
                studio_mode.selectMorphSceneForDiagnostics(studio_items, state_index);
            } else {
                log.warn("diagnostics could not select morph state {d}", .{state_index + 1});
            }
            diagnostics_motion_state_pending = null;
            _ = studio_mode.takeSemanticCommand();
            continue;
        }
        if (diagnostics_selection_pending) |item_id| {
            if (studio_mode.selectItemByIdOrSource(studio_items, item_id, .{})) {
                studio_mode.active_dock = .properties;
                studio_mode.inspector_panel = .properties;
                studio_mode.video_properties_playback = diagnostics_video_playback;
            } else {
                log.warn("diagnostics could not select unique item id={s}", .{item_id});
            }
            diagnostics_selection_pending = null;
        }
        if (diagnostics_motion_transition_pending) {
            studio_mode.showTransitionSection(studio_items);
            _ = studio_mode.takeSemanticCommand();
            diagnostics_motion_transition_pending = false;
        }
        if (diagnostics_motion_pending) |item_id| {
            if (studio_mode.selectItemByIdOrSource(studio_items, item_id, .{})) {
                studio_mode.showMotionForDiagnostics();
            } else {
                log.warn("diagnostics could not select unique motion item id={s}", .{item_id});
            }
            diagnostics_motion_pending = null;
        }
        if (diagnostics_timeline_step_pending) |step| {
            if (studio_workspace.builds.len > 0) {
                studio_mode.selectRevealStepForDiagnostics(studio_items, studio_workspace.builds, step);
                diagnostics_timeline_step_pending = null;
            }
        }
        // Live preview: any source, slide, scene, tool, or gesture change
        // stops it; otherwise the deterministic clock advances.
        if (studio_preview.active()) {
            const scene_changed = studio_mode.active_morph_state != studio_preview.morph_state or
                studio_mode.visible_reveal_step != studio_preview.reveal_step;
            if (!studio_mode.capturesInput() or G.source_revision != studio_preview.revision or
                G.current_slide != studio_preview.slide or scene_changed or
                studio_mode.interaction != .idle or studio_mode.tool != .select)
            {
                studio_preview.stop(gpa);
            } else {
                studio_preview.advance(rl.getFrameTime());
            }
        }
        if (diagnostics_motion_preview_pending) |seconds| {
            if (studio_mode.capturesInput() and G.slide_renderer.stepCount(G.current_slide) > 0) {
                studio_preview.start(gpa, G.slide_renderer, G.current_slide, G.source_revision, studio_mode.active_morph_state, studio_mode.visible_reveal_step) catch {};
                studio_preview.seek(seconds);
                diagnostics_motion_preview_pending = null;
            }
        }
        if (studio_mode.capturesInput()) {
            const preview_available = G.slide_renderer.stepCount(G.current_slide) > 0 or
                (G.current_slide > 0 and G.slide_renderer.transitionForSlide(G.current_slide).effect != .none);
            const preview_state = studio_preview.state();
            studio_mode.setMotionPreview(.{
                .available = preview_available,
                .playing = studio_preview.playing,
                .paused = studio_preview.paused,
                .looping = studio_preview.looping,
                .time = studio_preview.clock,
                .total = studio_preview.total(),
                .step = if (preview_state) |value| (value.active_step orelse value.visible_through) else 0,
                .in_transition = if (preview_state) |value| value.transition_progress != null else false,
            });
        }
        // The release-QA harness moves the native window to its isolated
        // workspace before opening focus-sensitive diagnostic UI. Otherwise
        // the workspace transition can dismiss a freshly opened overlay.
        const diagnostic_ui_gate_open = diagnosticCaptureGateIsOpen(io, diagnostics_capture_gate_path);
        if (diagnostic_ui_gate_open) {
            if (diagnostics_command_palette_pending) {
                studio_mode.openCommandPaletteForDiagnostics(studio_items);
                diagnostics_command_palette_pending = false;
            }
            if (diagnostics_file_browser_pending) {
                beginStudioFileBrowse(.deck);
                diagnostics_file_browser_pending = false;
            }
            if (diagnostics_precision_view_pending) {
                studio_mode.showPrecisionViewForDiagnostics();
                diagnostics_precision_view_pending = false;
            }
            if (diagnostics_grid_settings_pending) {
                studio_mode.showGridSettingsForDiagnostics();
                diagnostics_grid_settings_pending = false;
            }
            if (diagnostics_status_drawer_pending) {
                studio_mode.showStatusRevealForDiagnostics();
                diagnostics_status_drawer_pending = false;
            }
            if (diagnostics_find_slide_pending) |query| {
                if (!studio_mode.openSlideSearchForDiagnostics(query))
                    log.warn("diagnostics could not open slide search for invalid query", .{});
                diagnostics_find_slide_pending = null;
            }
        }
        if (rl.isWindowResized()) studio_mode.cancelActiveInteraction(studio_items);
        const composition_cache_builds_before = studio_composition_cache.rebuild_count;
        studio_mode.setCompositionContext(if (studio_mode.capturesInput() and current_slide != null and definition_preview_entry == null)
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
            studio_library_gallery_cache.rebuild_count,
            studio_library_gallery_cache.projected_count,
            studio_library_gallery_cache.placeholder_count,
            workspace_cache_rebuilt or gallery_cache_rebuilt or
                studio_composition_cache.rebuild_count != composition_cache_builds_before,
            G.slideshow.slides.items.len,
            studio_items.len,
            studio_render_fragment_count,
        );

        var semantic_to_apply: ?studio.SemanticCommand = null;
        var semantic_text: ?[]const u8 = null;
        var semantic_from_neovim_field = false;
        var dropped_media_source_buffer: [std.fs.max_path_bytes]u8 = undefined;
        var inline_field_to_finish: ?studio.InlineField = null;
        var inline_commit_completed = false;
        // false requests Undo, true requests Redo. Palette history commands
        // are applied after drawing, at the same safe graph-lifetime boundary
        // as their keyboard equivalents.
        var history_command_requested: ?bool = null;
        var studio_slide_to_select: ?usize = null;
        var source_graph_reparsed_this_frame = neovim_source_changed_this_frame;
        if (neovim_field_apply) |apply| {
            if (apply.accepted_revision != G.source_revision) {
                embedded_editor.rejectApply("Rayslides changed since this field editor opened; discard and reopen Neovim");
            } else if (pending_neovim_semantic_command == null) {
                embedded_editor.rejectApply("Rayslides no longer has an edit target for this field");
            } else if (apply.source.len > studio_prompt.max_input_bytes) {
                const message = std.fmt.bufPrint(
                    &neovim_apply_message_buffer,
                    "Field is {d} bytes; Rayslides supports at most {d}",
                    .{ apply.source.len, studio_prompt.max_input_bytes },
                ) catch "The field is too large for Rayslides";
                embedded_editor.rejectApply(message);
            } else if (!std.unicode.utf8ValidateSlice(apply.source)) {
                embedded_editor.rejectApply("The field is not valid UTF-8");
            } else {
                semantic_to_apply = pending_neovim_semantic_command;
                semantic_text = apply.source;
                semantic_from_neovim_field = true;
            }
        }
        const browser_was_active = studio_file_browser.active;
        const prompt_was_active = property_prompt.active;
        // The file chooser stacks above a media prompt: while it is open the
        // prompt underneath neither reads keys nor submits.
        const modal_was_active = prompt_was_active or browser_was_active;
        if (browser_was_active) {
            switch (studio_file_browser.updateFromRaylib(window_size, G.studio_ui_font)) {
                .none => {},
                .chosen => {
                    const chosen = studio_file_browser.chosenPath();
                    switch (studio_file_browser.purpose) {
                        .deck => _ = queueExternalDeckOpen(chosen, false, &studio_mode),
                        .image, .video => if (property_prompt.active) {
                            var source_path: [std.fs.max_path_bytes]u8 = undefined;
                            const source_len = studioMediaSourcePath(chosen, &source_path);
                            if (source_len > 0) property_prompt.begin(property_prompt.kind, source_path[0..source_len]);
                        },
                    }
                    window_close_seen = false;
                },
                .cancelled => window_close_seen = false,
            }
        } else if (prompt_was_active) {
            switch (property_prompt.updateFromRaylib(window_size, G.studio_ui_font, true)) {
                .none => {},
                .browse_requested => {
                    beginStudioFileBrowse(switch (property_prompt.kind) {
                        .image_path => .image,
                        .video_path => .video,
                        else => unreachable,
                    });
                    window_close_seen = false;
                },
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
                    } else if (pending_portable_show) {
                        const runtime = showtimeRuntimeSnapshot(
                            &display_picker,
                            fullscreen_mode,
                            &presenter_runtime,
                            &presenter_network,
                            &crowd_runtime,
                        );
                        if (showtime.createPortableFolder(
                            gpa,
                            io,
                            G.editor_memory[0..G.source_len],
                            G.slideshow_filp orelse "untitled.sld",
                            property_prompt.text(),
                        )) |portable_value| {
                            var portable = portable_value;
                            defer portable.deinit();
                            if (verifyPortableShowtime(portable.deck_path, runtime)) |verified_value| {
                                var verified = verified_value;
                                verified.add(.info, .portable, .portable_verified, null, null, null, null, "Portable copy re-opened successfully", "The copied .sld and copied assets passed an independent parser/renderer preflight.") catch {};
                                replaceShowtimeReport(&showtime_report, verified);
                                showtime_overlay = .{ .visible = true };
                                pending_portable_show = false;
                                studio_mode.setNotice(.none);
                                log.info("Portable show created and independently preflighted at {s}", .{property_prompt.text()});
                            } else |err| {
                                property_prompt.rejectSaveFailure();
                                log.err("Portable show verification failed: {any}", .{err});
                            }
                        } else |err| {
                            switch (err) {
                                error.InvalidPortableDestination => property_prompt.rejectInvalidPath(),
                                error.PathAlreadyExists => property_prompt.rejectExistingPath(),
                                else => property_prompt.rejectSaveFailure(),
                            }
                            studio_mode.setNotice(.none);
                            log.err("Portable show creation failed: {any}", .{err});
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
                    pending_portable_show = false;
                    window_close_seen = false;
                },
            }
        }

        const studio_command: ?studio.GeometryCommand = if (!export_controller.running and !modal_was_active and !presenter_overlay_captures_input)
            studio_mode.updateWithWorkspaceFromRaylib(studio_items, studio_bounds.items, studio_viewport, studio_workspace)
        else
            null;
        if (definition_preview_entry != null and !studio_mode.definitionModeActive()) {
            // Back or deck navigation can leave Definition mode during the
            // update. Stop borrowing its parser arena before the preview
            // cache is cleared/replaced later in this same frame, and restore
            // authored-slide hit-test geometry for the remaining UI draw.
            studio_items = authored_studio_items;
            _ = try collectStudioBounds(
                &studio_bounds,
                &studio_render_bounds,
                gpa,
                G.current_slide,
                studio_mode.active_morph_state,
                studio_items,
            );
            definition_preview_entry = null;
        }
        if (diagnostics_command_tooltip and studio_mode.capturesInput() and !export_controller.running) {
            studio_mode.showCommandTooltipForDiagnostics(studio_viewport);
        }
        const studio_geometry_batch: ?studio.GeometryBatchCommand = studio_mode.takeGeometryBatch();
        if (!modal_was_active) {
            if (studio_mode.takeSemanticCommand()) |command| {
                switch (command) {
                    .open_document => beginStudioFileBrowse(.deck),
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
                    .edit_source_neovim => {
                        switch (embedded_editor.beginSource(G.editor_memory[0..G.source_len], G.source_revision)) {
                            .started => studio_mode.setNotice(.none),
                            .support_disabled, .executable_missing => studio_mode.setNotice(.neovim_unavailable),
                            .start_failed => studio_mode.setNotice(.neovim_start_failed),
                        }
                    },
                    .edit_speaker_notes => {
                        const initial_notes = if (current_slide) |slide| slide.speaker_notes orelse "" else "";
                        if (embedded_editor.beginField(
                            .speaker_notes,
                            initial_notes,
                            G.source_revision,
                        ) == .started) {
                            pending_neovim_semantic_command = command;
                            studio_mode.setNotice(.none);
                        } else {
                            // A disabled build, missing executable, broken user
                            // config, or startup failure must retain the proven
                            // allocation-free field editor as a full fallback.
                            pending_semantic_command = command;
                            property_prompt.begin(.speaker_notes, initial_notes);
                        }
                    },
                    .pair_presenter_phone => {
                        if (ensurePresenterCompanionRunning(&presenter_runtime, presenter_options, &presenter_network)) {
                            presenter_pairing_visible = true;
                            studio_mode.setNotice(.none);
                        } else {
                            studio_mode.setNotice(.edit_failed);
                        }
                    },
                    .choose_presentation_display => {
                        presenter_pairing_visible = false;
                        openDisplayPicker(
                            &display_picker,
                            &fullscreen_mode,
                            windowed_width,
                            windowed_height,
                            &screenWidth,
                            &screenHeight,
                        );
                        studio_mode.setNotice(.none);
                    },
                    .showtime_preflight => {
                        const runtime = showtimeRuntimeSnapshot(
                            &display_picker,
                            fullscreen_mode,
                            &presenter_runtime,
                            &presenter_network,
                            &crowd_runtime,
                        );
                        if (buildLiveShowtimeReport(runtime)) |report| {
                            replaceShowtimeReport(&showtime_report, report);
                            showtime_overlay = .{ .visible = true };
                            presenter_pairing_visible = false;
                            studio_mode.setNotice(.none);
                        } else |err| {
                            studio_mode.setNotice(.edit_failed);
                            log.err("Showtime preflight failed: {any}", .{err});
                        }
                    },
                    .create_portable_show => {
                        pending_portable_show = true;
                        var folder_buffer: [std.fs.max_path_bytes]u8 = undefined;
                        const deck_name = if (G.slideshow_filp) |path| std.fs.path.basename(path) else "show.sld";
                        const extension = std.fs.path.extension(deck_name);
                        const stem = deck_name[0 .. deck_name.len - extension.len];
                        const initial = std.fmt.bufPrint(&folder_buffer, "{s}-portable", .{stem}) catch "show-portable";
                        property_prompt.begin(.portable_folder, initial);
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
                        .video => {
                            pending_semantic_command = command;
                            property_prompt.begin(.video_path, "");
                        },
                        .shape, .line, .arrow => semantic_to_apply = command,
                    },
                    .edit_text => |target| {
                        const initial = studioItemByIdentity(studio_items, target.item_identity) orelse null;
                        const initial_text = studio_mode.inlineTextForModal(target) orelse if (initial) |item|
                            if (target.edit_scope == .shared_template)
                                if (item.sharedTemplateValues()) |shared| shared.text orelse "" else ""
                            else
                                item.text orelse ""
                        else
                            "";
                        if (embedded_editor.beginField(.text, initial_text, G.source_revision) == .started) {
                            pending_neovim_semantic_command = command;
                            studio_mode.setNotice(.none);
                        } else {
                            pending_semantic_command = command;
                            property_prompt.begin(
                                if (target.edit_scope == .shared_template) .shared_text else .text,
                                initial_text,
                            );
                        }
                        // Either editor copied any live inline draft, so the
                        // narrow editor can now be dismissed without losing it.
                        studio_mode.dismissInlineTextForModal();
                    },
                    .replace_media => |target| prompt: {
                        const item = studioItemByIdentity(studio_items, target.item_identity) orelse {
                            studio_mode.setNotice(.edit_failed);
                            break :prompt;
                        };
                        const kind: studio_prompt.Kind = switch (item.kind) {
                            .img => .image_path,
                            .vid => if (item.vid_is_camera) .camera_device else .video_path,
                            else => {
                                studio_mode.setNotice(.property_unavailable);
                                break :prompt;
                            },
                        };
                        const initial = if (item.kind == .img) item.img_path orelse "" else item.vid_path orelse "";
                        pending_semantic_command = command;
                        property_prompt.begin(kind, initial);
                    },
                    .replace_camera_poster => |target| prompt: {
                        const item = studioItemByIdentity(studio_items, target.item_identity) orelse {
                            studio_mode.setNotice(.edit_failed);
                            break :prompt;
                        };
                        if (item.kind != .vid or !item.vid_is_camera) {
                            studio_mode.setNotice(.property_unavailable);
                            break :prompt;
                        }
                        pending_semantic_command = command;
                        property_prompt.begin(.image_path, item.vid_camera_poster orelse "");
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
                    .set_rotation => |change| prompt: {
                        if (change.value != null) {
                            semantic_to_apply = command;
                            break :prompt;
                        }
                        const item = studioItemByIdentity(studio_items, change.target.item_identity) orelse {
                            studio_mode.setNotice(.edit_failed);
                            break :prompt;
                        };
                        const rotation = if (change.target.edit_scope == .shared_template)
                            if (item.sharedTemplateValues()) |shared| shared.rotation else item.rotation
                        else
                            item.rotation;
                        var initial_buffer: [64]u8 = undefined;
                        pending_semantic_command = command;
                        property_prompt.begin(.coordinate, formatStudioFloat(&initial_buffer, rotation) catch "0");
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
                    .edit_library_entry => |library_index| {
                        if (library_index < studio_workspace_cache.library_catalog_indices.items.len and
                            library_index < studio_workspace.library.len)
                        {
                            const catalog_index = studio_workspace_cache.library_catalog_indices.items[library_index];
                            if (!studio_mode.enterDefinitionMode(
                                studio_items,
                                catalog_index,
                                library_index,
                                studio_workspace.library[library_index],
                            )) studio_mode.setNotice(.edit_failed);
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
                                definition_edit_context,
                                studio_items,
                                studio_bounds.items,
                            )) |_| {
                                studio_mode.setNotice(.none);
                            } else |err| {
                                studio_mode.setNotice(switch (err) {
                                    error.UnsupportedClipboardItem,
                                    error.InvalidItemScene,
                                    => .copy_selection_unsupported,
                                    error.UnsupportedDefinitionStructure => .definition_structure_unsupported,
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
                    .motion_preview => |preview_command| switch (preview_command) {
                        .play => if (studio_preview.active()) {
                            if (studio_preview.clock >= studio_preview.total()) studio_preview.clock = 0;
                            studio_preview.playing = true;
                            studio_preview.paused = false;
                        } else {
                            studio_preview.start(gpa, G.slide_renderer, G.current_slide, G.source_revision, studio_mode.active_morph_state, studio_mode.visible_reveal_step) catch |err| {
                                log.err("motion preview failed to start: {any}", .{err});
                            };
                        },
                        .pause => {
                            studio_preview.playing = false;
                            studio_preview.paused = studio_preview.active();
                        },
                        .stop => studio_preview.stop(gpa),
                        .toggle_loop => studio_preview.looping = !studio_preview.looping,
                        .seek => |seconds| {
                            if (!studio_preview.active()) {
                                studio_preview.start(gpa, G.slide_renderer, G.current_slide, G.source_revision, studio_mode.active_morph_state, studio_mode.visible_reveal_step) catch |err| {
                                    log.err("motion preview failed to start: {any}", .{err});
                                };
                            }
                            studio_preview.seek(seconds);
                        },
                    },
                    else => semantic_to_apply = command,
                }
            }
        }
        if (semantic_to_apply == null) {
            if (dropped_media_kind) |kind| {
                const source_path_len = studioMediaSourcePath(
                    dropped_media_path_buffer[0..dropped_media_path_len],
                    &dropped_media_source_buffer,
                );
                if (source_path_len == 0) {
                    studio_mode.setNotice(.edit_failed);
                } else if (std.mem.indexOfAny(
                    u8,
                    dropped_media_source_buffer[0..source_path_len],
                    " \t\r\n",
                ) != null) {
                    // The current attribute grammar has no quoted path form.
                    // Refuse rather than emitting a directive that would bind
                    // only the prefix before the first whitespace byte.
                    studio_mode.setNotice(.media_drop_unsupported);
                    log.warn("Dropped media path cannot be represented in .sld yet: {s}", .{
                        dropped_media_source_buffer[0..source_path_len],
                    });
                } else {
                    const pointer = rl.getMousePosition();
                    const position = if (studio_viewport.containsScreenPoint(pointer))
                        studio.screenToLogical(studio_viewport, pointer) orelse studio_viewport.logical_size.scale(0.5)
                    else
                        studio_viewport.logical_size.scale(0.5);
                    semantic_to_apply = studio_mode.droppedMediaCommand(
                        if (kind == .image) .image else .video,
                        position,
                    );
                    if (semantic_to_apply != null)
                        semantic_text = dropped_media_source_buffer[0..source_path_len];
                }
            }
        }
        if (studio_mode.capturesInput() and laser_pointer.show) {
            laser_pointer.show = false;
            laser_pointer.clearDrawing();
            rl.showCursor();
        }
        if (!studio_mode.definitionModeActive()) definition_preview_entry = null;
        // Apply preview diagnostics after the first workspace normalization.
        // That initialization deliberately clears stale Library selection, so
        // selecting earlier in the frame would produce a highlighted card but
        // leave the authored slide on the canvas in the resulting capture.
        if (diagnostics_library_preview_pending) |name| {
            const workspace_index = studioLibraryWorkspaceIndex(studio_workspace, name);
            if (workspace_index) |index| {
                if (!studio_mode.selectLibraryEntryForDiagnostics(studio_items, studio_workspace, index))
                    log.warn("diagnostics could not preview Library definition name={s}", .{name});
            } else {
                log.warn("diagnostics could not find Library definition name={s}", .{name});
            }
            diagnostics_library_preview_pending = null;
        }
        var library_preview_entry: ?studio.LibraryEntry = null;
        if (!export_controller.running and studio_mode.capturesInput()) {
            if (studio_mode.definitionModeActive()) {
                // The same detached cache now backs an editable projected
                // scene and must survive the read-only preview cleanup path.
            } else if (studio_mode.libraryPreviewIndex(studio_workspace)) |workspace_index| {
                const catalog_entry = studioLibraryEntry(
                    frame_studio_catalog,
                    studio_workspace_cache.library_catalog_indices.items,
                    workspace_index,
                );
                if (catalog_entry) |entry| {
                    const insertion_offset = switch (entry.kind) {
                        .element, .group => studio_workspace_cache.library_item_offset orelse entry.full_end,
                        .slide => studio_workspace_cache.library_slide_offset orelse entry.full_end,
                    };
                    if (studio_library_preview_cache.refresh(
                        G.slide_renderer,
                        G.source_revision,
                        G.editor_memory[0..G.source_len],
                        studio_workspace_cache.library_catalog_indices.items[workspace_index],
                        entry,
                        insertion_offset,
                        studio_items,
                        G.slideshow_filp orelse "untitled.sld",
                    )) |_| {
                        library_preview_entry = studio_workspace.library[workspace_index];
                    } else |err| {
                        studio_library_preview_cache.clear(G.slide_renderer);
                        studio_mode.dismissLibraryPreview();
                        studio_mode.setNotice(.edit_failed);
                        log.err("Studio Library preview failed: {any}", .{err});
                    }
                } else {
                    studio_library_preview_cache.clear(G.slide_renderer);
                    studio_mode.dismissLibraryPreview();
                    studio_mode.setNotice(.edit_failed);
                }
            } else if (studio_library_preview_cache.key != null or G.slide_renderer.hasStudioPreview()) {
                studio_library_preview_cache.clear(G.slide_renderer);
            }
        } else if (studio_library_preview_cache.key != null or G.slide_renderer.hasStudioPreview()) {
            studio_library_preview_cache.clear(G.slide_renderer);
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
        else if (studio_mode.capturesInput()) blk: {
            if (studio_preview.state()) |preview_state| break :blk .{
                .visible_through = preview_state.visible_through,
                .active_step = preview_state.active_step,
                .active_progress = preview_state.active_progress,
            };
            break :blk .{ .visible_through = if (studio_mode.active_morph_state) |state|
                G.slide_renderer.baseRevealStepCount(G.current_slide) + state + 1
            else if (studio_mode.visible_reveal_step) |step|
                step
            else
                G.slide_renderer.baseRevealStepCount(G.current_slide) };
        } else .{
            .visible_through = G.playback.visible_step,
            .active_step = G.playback.active_step,
            .active_progress = G.playback.activeStepProgress(now),
        };
        const transition_state: renderer.TransitionState = if (export_controller.running)
            .{}
        else if (studio_mode.capturesInput()) blk: {
            if (studio_preview.state()) |preview_state| {
                if (preview_state.transition_progress) |progress| {
                    if (G.current_slide > 0) break :blk .{
                        .previous_slide = G.current_slide - 1,
                        .previous_step = G.slide_renderer.stepCount(G.current_slide - 1),
                        .spec = G.slide_renderer.transitionForSlide(G.current_slide),
                        .progress = progress,
                        .direction = 1,
                    };
                }
            }
            break :blk .{};
        } else .{
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
        var video_overlay_consumed_click = false;
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
            if (export_controller.running or screenshot_poster_render_pending) {
                try G.slide_renderer.renderWithVideoPosters(
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
            } else {
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
            }
            if (clip_studio_canvas) rl.endScissorMode();
            video_overlay_consumed_click = G.slide_renderer.processVideoOverlay(
                G.current_slide,
                G.playback.visible_step,
                .{
                    .mouse = rl.getMousePosition(),
                    .pressed = rl.isMouseButtonPressed(.left),
                    .down = rl.isMouseButtonDown(.left),
                    .released = rl.isMouseButtonReleased(.left),
                },
                slide_tl,
                slide_size_in_window,
                internal_render_size,
                now,
                G.studio_ui_font,
                !export_controller.running and !studio_mode.capturesInput() and
                    !presenter_overlay_captures_input and !laser_pointer.show,
            );
            if (!export_controller.running) {
                if (definition_preview_entry != null) {
                    const canvas = studio_viewport.canvasBounds();
                    rl.beginScissorMode(
                        @intFromFloat(@floor(canvas.x)),
                        @intFromFloat(@floor(canvas.y)),
                        @intFromFloat(@ceil(canvas.width)),
                        @intFromFloat(@ceil(canvas.height)),
                    );
                    rl.drawRectangleRec(canvas, .{ .r = 13, .g = 18, .b = 29, .a = 255 });
                    G.slide_renderer.renderStudioDefinition(
                        slide_tl,
                        slide_size_in_window,
                        internal_render_size,
                    ) catch |err| log.err("Studio Definition mode render failed: {any}", .{err});
                    rl.endScissorMode();
                }
                studio_mode.draw(studio_items, studio_bounds.items, studio_viewport);
                if (library_preview_entry) |entry| {
                    const canvas = studio_viewport.canvasBounds();
                    const preview_viewport = studio.Studio.libraryPreviewRenderViewport(studio_viewport);
                    rl.beginScissorMode(
                        @intFromFloat(@floor(canvas.x)),
                        @intFromFloat(@floor(canvas.y)),
                        @intFromFloat(@ceil(canvas.width)),
                        @intFromFloat(@ceil(canvas.height)),
                    );
                    rl.drawRectangleRec(canvas, .{ .r = 13, .g = 18, .b = 29, .a = 255 });
                    G.slide_renderer.renderStudioPreview(
                        preview_viewport.slide_top_left,
                        preview_viewport.slide_size,
                        internal_render_size,
                    ) catch |err| log.err("Studio Library preview render failed: {any}", .{err});
                    studio_mode.drawLibraryPreviewOverlay(studio_viewport, entry);
                    rl.endScissorMode();
                }
                if (definition_preview_entry != null) studio_mode.drawDefinitionOverlay(studio_viewport);
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
            if (!studio_mode.capturesInput()) studio_mode.drawNoticeToast(studio_viewport);

            // The HUD is editor chrome like the laser and remote drawing above
            // it, so it must not be baked into a passive output. Both capture
            // paths render an ordinary frame and read it back, which would
            // otherwise put the overlay into the PDF and the screenshot.
            if (!export_controller.running and !screenshot_poster_render_pending)
                frame_diagnostics.draw(G.studio_ui_font, beast_mode, frameDiagnosticsPlacement(studio_viewport, slide_tl));
            property_prompt.draw(window_size, G.studio_ui_font, true);
            studio_file_browser.draw(window_size, G.studio_ui_font);
            if (!export_controller.running) {
                // Discovery chrome is intentionally last: command search and
                // hover help must remain legible above diagnostics and every
                // persistent Studio surface.
                studio_mode.drawDiscoveryOverlay(studio_items, studio_bounds.items, studio_viewport, studio_workspace);
            }
            if (presenter_pairing_visible and presenter_runtime.isRunning()) {
                drawPresenterPairingOverlay(
                    &presenter_qr,
                    &presenter_runtime,
                    &presenter_network,
                    presenter_runtime.phoneConnected(),
                    rl.getTime() < presenter_laptop_link_copied_until,
                    screenWidth,
                    screenHeight,
                );
            }
            if (display_picker.visible) drawDisplayPickerOverlay(&display_picker, screenWidth, screenHeight);
            if (showtime_overlay.visible) {
                if (showtime_report) |*report| drawShowtimeOverlay(&showtime_overlay, report, screenWidth, screenHeight);
            }
            goto_slide_picker.draw(
                studio_viewport,
                G.studio_ui_font,
                std.math.cast(usize, G.current_slide) orelse 0,
                G.slideshow.slides.items.len,
            );
            embedded_editor.draw(neovim_outer);
        }
        if (screenshot_poster_render_pending) {
            screenshot_poster_render_pending = false;
            screenshot_capture_pending = true;
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
                definition_edit_context,
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
                        if (definition_edit_context != null)
                            studio_mode.queueDefinitionSelectionIds(id_views[0..selection_ids.values.items.len])
                        else
                            studio_mode.selectItemsByIds(
                                currentStudioSceneItems(&studio_mode),
                                id_views[0..selection_ids.values.items.len],
                            );
                    }
                }
                if (inline_field_to_finish) |field| studio_mode.acceptInlineCommit(field);
                studio_mode.setNotice(if (customized_shared_property) .shared_template_customized else .none);
                if (semantic_from_neovim_field) embedded_editor.acceptApply(G.source_revision);
            } else |err| {
                if (semantic_from_neovim_field) {
                    const message = std.fmt.bufPrint(
                        &neovim_apply_message_buffer,
                        "Rayslides rejected this field: {s}",
                        .{@errorName(err)},
                    ) catch "Rayslides rejected this field edit";
                    embedded_editor.rejectApply(message);
                    studio_mode.setNotice(.none);
                    log.warn("Neovim field apply rejected: {any}", .{err});
                } else {
                    const invalid_prompt_value = switch (err) {
                        error.InvalidStudioNumber,
                        error.InvalidStudioDimension,
                        error.InvalidStudioColor,
                        error.InvalidStudioFontSize,
                        error.InvalidStudioOpacity,
                        error.InvalidStudioUnitInterval,
                        error.InvalidStudioVideoPoster,
                        error.InvalidStudioMediaPath,
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
                                error.UnsupportedDefinitionStructure => .definition_structure_unsupported,
                                error.StudioClipboardEmpty => .clipboard_empty,
                                error.RevealMorphBorn => .reveal_morph_born,
                                error.RevealSceneRequired => .reveal_scene_required,
                                error.RevealSharedTemplate => .reveal_shared_template,
                                error.TransitionNeedsSlideDirective => .transition_needs_slide_directive,
                                error.TransitionSharedUnavailable => .structural_source_locked,
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
                            error.UnsupportedDefinitionStructure => .definition_structure_unsupported,
                            error.InvalidMorphStateOffset,
                            error.NoAdjacentMorphState,
                            => .morph_structure_locked,
                            error.InvalidMorphState,
                            error.StudioSourcePatchInvalid,
                            => if (semanticCommandIsMorphTimeline(command)) .morph_structure_locked else .edit_failed,
                            error.StudioClipboardEmpty => .clipboard_empty,
                            error.RevealMorphBorn => .reveal_morph_born,
                            error.RevealSceneRequired => .reveal_scene_required,
                            error.RevealSharedTemplate => .reveal_shared_template,
                            error.TransitionNeedsSlideDirective => .transition_needs_slide_directive,
                            error.TransitionSharedUnavailable => .structural_source_locked,
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
                    (!diagnostics_neovim_editor or embedded_editor.readyForCapture()) and
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
        if (library_picker_active_at_frame_start and !studio_mode.libraryPickerActive()) {
            window_close_seen = false;
        }

        const keyboard_history_requested = !presenter_overlay_captures_input and !property_prompt.active and !studio_file_browser.active and !studio_mode.textEntryActive() and
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
        if (!presenter_overlay_captures_input and !export_controller.running and !studio_mode.capturesInput() and (rl.isKeyPressed(.space) or rl.isKeyPressed(.right) or rl.isKeyPressed(.page_down) or (!laser_pointer.show and !video_overlay_consumed_click and !G.slide_renderer.videoOverlayShieldsClick(rl.getMousePosition()) and rl.isMouseButtonPressed(.left)))) {
            advancePresentation(rl.getTime());
        }

        if (!presenter_overlay_captures_input and !export_controller.running and !studio_mode.capturesInput() and (rl.isKeyPressed(.backspace) or rl.isKeyPressed(.left) or rl.isKeyPressed(.page_up))) {
            reversePresentation(rl.getTime());
        }

        if (!presenter_overlay_captures_input and crowd_runtime.isRunning() and !export_controller.running and !studio_mode.capturesInput() and !shortcutModifierDown() and rl.isKeyPressed(.o)) {
            _ = crowd_runtime.toggleOpen();
        }
        if (!presenter_overlay_captures_input and crowd_runtime.isRunning() and !export_controller.running and !studio_mode.capturesInput() and rl.isKeyPressed(.v)) {
            _ = crowd_runtime.toggleReveal();
        }
        if (!presenter_overlay_captures_input and crowd_runtime.isRunning() and !export_controller.running and !studio_mode.capturesInput() and rl.isKeyPressed(.r)) {
            _ = crowd_runtime.resetActive();
        }

        if (!presenter_overlay_captures_input and !property_prompt.active and !studio_file_browser.active and !studio_mode.textEntryActive() and rl.isKeyPressed(.f)) {
            if (fullscreen_mode == .windowed) {
                enterPresentationFullscreen(
                    &fullscreen_mode,
                    if (rl.isKeyDown(.left_shift) or rl.isKeyDown(.right_shift)) .exclusive else .borderless,
                    display_picker.confirmed_monitor,
                    &windowed_width,
                    &windowed_height,
                    &screenWidth,
                    &screenHeight,
                );
            } else {
                leavePresentationFullscreen(
                    &fullscreen_mode,
                    display_picker.confirmed_monitor,
                    windowed_width,
                    windowed_height,
                    &screenWidth,
                    &screenHeight,
                );
            }
        }

        if (!presenter_overlay_captures_input and !property_prompt.active and !studio_file_browser.active and !studio_mode.textEntryActive() and (rl.isKeyPressed(.q) or
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

        if (!presenter_overlay_captures_input and !export_controller.running and !studio_mode.capturesInput() and G.slideshow.slides.items.len > 0) {
            switch (g_shortcut_action) {
                .first_slide => jumpToSlide(0, rl.getTime()),
                .last_slide => jumpToSlide(@intCast(G.slideshow.slides.items.len - 1), rl.getTime()),
                .none, .open_picker => {},
            }
        }

        if (!presenter_overlay_captures_input and !studio_mode.capturesInput() and !property_prompt.active and !studio_file_browser.active and rl.isKeyPressed(.b)) {
            beast_mode = !beast_mode;
            if (beast_mode) {
                rl.clearWindowState(.{ .vsync_hint = true });
                rl.setTargetFPS(0);
            } else {
                rl.setWindowState(.{ .vsync_hint = true });
                rl.setTargetFPS(60);
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

        if (!presenter_overlay_captures_input and !export_controller.running and !studio_mode.capturesInput() and rl.isKeyPressed(.m)) {
            if (rl.isKeyDown(.left_shift) or rl.isKeyDown(.right_shift)) {
                G.slide_renderer.stopVideosOnSlide(G.current_slide);
            } else {
                G.slide_renderer.toggleVideosOnSlide(G.current_slide, rl.getTime());
            }
        }

        // An external file change must never silently replace an unsaved
        // Studio document. Polling resumes after the buffer is saved.
        const do_reload = if (editorSourceDirty() or studio_mode.capturesInput()) false else checkAutoReload() catch false;
        if (do_reload) {
            G.slideshow_filp_to_load = G.slideshow_filp; // signal that we need to load
        }
    }
    if (showtime_cli_failed) return error.ShowtimePreflightFailed;
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
    // Navigation is disabled while a PDF export runs, so autoplay here cannot
    // disturb the deterministic poster-frame captures.
    G.slide_renderer.stopAllVideos();
    G.slide_renderer.autoplayVideosOnSlide(target, now);
}

fn jumpToSlide(target: i32, now: f64) void {
    if (target < 0 or target >= G.slideshow.slides.items.len) return;
    G.current_slide = target;
    G.playback.enterSlide(null, 0, 0, .{}, 1, now);
    // Navigation is disabled while a PDF export runs, so autoplay here cannot
    // disturb the deterministic poster-frame captures.
    G.slide_renderer.stopAllVideos();
    G.slide_renderer.autoplayVideosOnSlide(target, now);
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

fn neovimOwnsInput(active: bool, opened_this_frame: bool, closed_this_frame: bool) bool {
    return active or opened_this_frame or closed_this_frame;
}

test "Neovim retains exclusive input ownership across open and close frames" {
    try std.testing.expect(neovimOwnsInput(true, false, false));
    try std.testing.expect(neovimOwnsInput(false, true, false));
    try std.testing.expect(neovimOwnsInput(false, false, true));
    try std.testing.expect(!neovimOwnsInput(false, false, false));
}

fn neovimSourceDiagnostic(
    allocator: std.mem.Allocator,
    source: []const u8,
    max_bytes: usize,
    message_buffer: []u8,
) !?[]const u8 {
    if (source.len > max_bytes) {
        return std.fmt.bufPrint(
            message_buffer,
            "source exceeds Rayslides' {d}-byte limit",
            .{max_bytes},
        ) catch "source exceeds Rayslides' document limit";
    }
    if (!std.unicode.utf8ValidateSlice(source)) return "source is not valid UTF-8";

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const slideshow = try SlideShow.new(arena.allocator());
    const context = try parser.constructSlidesFromBuf(source, slideshow, arena.allocator());
    defer context.deinit();
    const first = if (context.parser_errors.items.len > 0)
        context.parser_errors.items[0]
    else
        return null;
    return if (first.message) |detail|
        std.fmt.bufPrint(
            message_buffer,
            "line {d}: {s} ({s})",
            .{ first.line_number, @errorName(first.parser_error), detail },
        ) catch "Rayslides parser rejected this write"
    else
        std.fmt.bufPrint(
            message_buffer,
            "line {d}: {s}",
            .{ first.line_number, @errorName(first.parser_error) },
        ) catch "Rayslides parser rejected this write";
}

test "Neovim source validation reports precise parser and encoding failures" {
    var message: [256]u8 = undefined;
    try std.testing.expect((try neovimSourceDiagnostic(
        std.testing.allocator,
        "@slide\n@box text=valid\n",
        1024,
        &message,
    )) == null);
    const parser_message = (try neovimSourceDiagnostic(
        std.testing.allocator,
        "@slide\n@box opacity=2\n",
        1024,
        &message,
    )).?;
    try std.testing.expect(std.mem.startsWith(u8, parser_message, "line 2:"));
    try std.testing.expectEqualStrings(
        "source is not valid UTF-8",
        (try neovimSourceDiagnostic(std.testing.allocator, "\xff", 1024, &message)).?,
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        (try neovimSourceDiagnostic(std.testing.allocator, "@slide\n", 2, &message)).?,
        "2-byte limit",
    ) != null);
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

/// Compact, renderer-independent summaries for every visible Library card.
/// Parsing/projecting is paid once per source/use-site key; steady frames only
/// borrow the fixed summaries. A malformed individual definition receives a
/// deterministic placeholder while valid neighbors remain browsable.
const StudioLibraryGalleryCache = struct {
    const Key = struct {
        revision: usize,
        item_insertion_offset: usize,
        slide_insertion_offset: usize,
        visible_count: usize,
    };

    allocator: std.mem.Allocator,
    key: ?Key = null,
    visuals: std.ArrayList(studio.LibraryVisual) = .empty,
    rebuild_count: usize = 0,
    projected_count: usize = 0,
    placeholder_count: usize = 0,

    fn init(allocator: std.mem.Allocator) StudioLibraryGalleryCache {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *StudioLibraryGalleryCache) void {
        self.visuals.deinit(self.allocator);
    }

    fn refresh(
        self: *StudioLibraryGalleryCache,
        revision: usize,
        source: []const u8,
        catalog: studio_catalog.Catalog,
        catalog_indices: []const usize,
        item_insertion_offset: usize,
        slide_insertion_offset: usize,
    ) !bool {
        const requested: Key = .{
            .revision = revision,
            .item_insertion_offset = item_insertion_offset,
            .slide_insertion_offset = slide_insertion_offset,
            .visible_count = catalog_indices.len,
        };
        if (self.key) |cached| if (std.meta.eql(cached, requested)) return false;

        var replacement = std.ArrayList(studio.LibraryVisual).empty;
        errdefer replacement.deinit(self.allocator);
        try replacement.ensureTotalCapacity(self.allocator, catalog_indices.len);
        var projected_count: usize = 0;
        var placeholder_count: usize = 0;
        for (catalog_indices) |catalog_index| {
            const visual = if (catalog_index < catalog.entries.len)
                self.buildVisual(
                    source,
                    catalog_index,
                    catalog.entries[catalog_index],
                    item_insertion_offset,
                    slide_insertion_offset,
                ) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => blk: {
                        placeholder_count += 1;
                        break :blk studio.LibraryVisual{};
                    },
                }
            else blk: {
                placeholder_count += 1;
                break :blk studio.LibraryVisual{};
            };
            if (visual.available) projected_count += 1;
            replacement.appendAssumeCapacity(visual);
        }

        self.visuals.deinit(self.allocator);
        self.visuals = replacement;
        self.key = requested;
        self.projected_count = projected_count;
        self.placeholder_count = placeholder_count;
        self.rebuild_count += 1;
        return true;
    }

    fn buildVisual(
        self: *StudioLibraryGalleryCache,
        source: []const u8,
        catalog_index: usize,
        entry: studio_catalog.Entry,
        item_insertion_offset: usize,
        slide_insertion_offset: usize,
    ) !studio.LibraryVisual {
        const insertion_offset = switch (entry.kind) {
            .element, .group => item_insertion_offset,
            .slide => slide_insertion_offset,
        };
        var id_buffer: [96]u8 = undefined;
        const instance_id = try unusedGalleryInstanceId(source, catalog_index, &id_buffer);
        const temporary_source = try studio_library_preview.buildSource(
            self.allocator,
            source,
            .{
                .kind = entry.kind,
                .name = entry.name,
                .insertion_offset = insertion_offset,
                .instance_id = instance_id,
            },
        );
        defer self.allocator.free(temporary_source);
        var graph = try ParsedSlideshowGraph.init(self.allocator, temporary_source);
        defer graph.deinit();
        if (graph.slideshow.slides.items.len == 0) return error.StudioLibraryPreviewMissing;
        const parsed = graph.slideshow.slides.items[graph.slideshow.slides.items.len - 1];
        const projected = try studio_library_preview.projectSlide(
            graph.slideshow_allocator,
            parsed,
            entry.kind,
            instance_id,
        );
        const items = if (projected.items) |list| list.items else &.{};
        return studio.libraryVisualFromItems(switch (entry.kind) {
            .element => .element,
            .group => .group,
            .slide => .slide_template,
        }, items);
    }
};

fn unusedGalleryInstanceId(source: []const u8, catalog_index: usize, buffer: *[96]u8) ![]const u8 {
    var serial = catalog_index;
    while (serial < catalog_index + 4096) : (serial += 1) {
        const candidate = try std.fmt.bufPrint(buffer, "__studio_gallery_{d}", .{serial});
        var needle_buffer: [112]u8 = undefined;
        const needle = try std.fmt.bufPrint(&needle_buffer, "id={s}", .{candidate});
        if (std.mem.indexOf(u8, source, needle) == null) return candidate;
    }
    return error.StudioLibraryPreviewIdUnavailable;
}

/// Owns the parser graph behind one selected Library definition and keeps the
/// renderer's detached preview synchronized with its exact source revision and
/// insertion context. This is intentionally separate from StudioWorkspaceCache:
/// catalog metadata is cheap and persistent, while preview parsing/rendering
/// occurs only for a selected definition.
const StudioLibraryPreviewCache = struct {
    const Key = struct {
        revision: usize,
        catalog_index: usize,
        insertion_offset: usize,
    };

    allocator: std.mem.Allocator,
    key: ?Key = null,
    graph: ?ParsedSlideshowGraph = null,
    projected_slide: ?*slides.Slide = null,
    rebuild_count: usize = 0,

    fn init(allocator: std.mem.Allocator) StudioLibraryPreviewCache {
        return .{ .allocator = allocator };
    }

    fn discardGraph(self: *StudioLibraryPreviewCache) void {
        if (self.graph) |*graph| graph.deinit();
        self.graph = null;
        self.projected_slide = null;
        self.key = null;
    }

    fn clear(
        self: *StudioLibraryPreviewCache,
        slide_renderer: *renderer.SlideshowRenderer,
    ) void {
        self.discardGraph();
        slide_renderer.clearStudioPreview();
    }

    fn deinit(
        self: *StudioLibraryPreviewCache,
        slide_renderer: *renderer.SlideshowRenderer,
    ) void {
        self.clear(slide_renderer);
    }

    fn refresh(
        self: *StudioLibraryPreviewCache,
        slide_renderer: *renderer.SlideshowRenderer,
        revision: usize,
        source: []const u8,
        catalog_index: usize,
        entry: studio_catalog.Entry,
        insertion_offset: usize,
        scene_items: []const slides.SlideItem,
        slideshow_filp: []const u8,
    ) !bool {
        const requested_key: Key = .{
            .revision = revision,
            .catalog_index = catalog_index,
            .insertion_offset = insertion_offset,
        };
        if (self.key) |cached| {
            if (std.meta.eql(cached, requested_key) and slide_renderer.hasStudioPreview()) return false;
        }

        var instance_id_buffer: [64]u8 = undefined;
        const instance_id = studio_library_preview.unusedInstanceId(
            scene_items,
            &instance_id_buffer,
        ) orelse return error.StudioLibraryPreviewIdUnavailable;
        const temporary_source = try studio_library_preview.buildSource(
            self.allocator,
            source,
            .{
                .kind = entry.kind,
                .name = entry.name,
                .insertion_offset = insertion_offset,
                .instance_id = instance_id,
            },
        );
        defer self.allocator.free(temporary_source);

        var replacement = try ParsedSlideshowGraph.init(self.allocator, temporary_source);
        defer replacement.deinit();
        if (replacement.slideshow.slides.items.len == 0) return error.StudioLibraryPreviewMissing;
        const parsed = replacement.slideshow.slides.items[replacement.slideshow.slides.items.len - 1];
        const projected = try studio_library_preview.projectSlide(
            replacement.slideshow_allocator,
            parsed,
            entry.kind,
            instance_id,
        );
        try slide_renderer.prepareStudioPreview(projected, slideshow_filp);

        self.discardGraph();
        self.graph = replacement;
        replacement.arena = null;
        replacement.parser_context = null;
        self.projected_slide = projected;
        self.key = requested_key;
        self.rebuild_count += 1;
        return true;
    }

    fn items(self: *StudioLibraryPreviewCache) []slides.SlideItem {
        const slide = self.projected_slide orelse return &.{};
        return if (slide.items) |*list| list.items else &.{};
    }
};

test "Studio Library preview cache key tracks source definition and use site" {
    const base: StudioLibraryPreviewCache.Key = .{
        .revision = 17,
        .catalog_index = 4,
        .insertion_offset = 912,
    };
    try std.testing.expect(std.meta.eql(base, base));

    var changed = base;
    changed.revision += 1;
    try std.testing.expect(!std.meta.eql(base, changed));

    changed = base;
    changed.catalog_index += 1;
    try std.testing.expect(!std.meta.eql(base, changed));

    changed = base;
    changed.insertion_offset += 1;
    try std.testing.expect(!std.meta.eql(base, changed));
}

test "Studio Library gallery caches projected ITEM GROUP and SLIDE cards" {
    const allocator = std.testing.allocator;
    const source =
        "@push card x=40 y=60 w=280 h=90 text=Card\n" ++
        "@pushgroup feature\n" ++
        "@box id=title x=120 y=100 w=600 h=100 text=Feature\n" ++
        "@box id=body x=120 y=260 w=900 h=220 text=Body\n" ++
        "@endgroup\n" ++
        "@box id=hero x=100 y=80 w=900 h=180 text=Chapter\n" ++
        "@pushslide chapter\n" ++
        "@slide\n";
    const catalog = try studio_catalog.discover(allocator, source);
    defer catalog.deinit();
    try std.testing.expectEqual(@as(usize, 3), catalog.entries.len);
    const indices = [_]usize{ 0, 1, 2 };
    var cache = StudioLibraryGalleryCache.init(allocator);
    defer cache.deinit();
    try std.testing.expect(try cache.refresh(9, source, catalog, &indices, source.len, source.len));
    try std.testing.expectEqual(@as(usize, 3), cache.visuals.items.len);
    try std.testing.expectEqual(@as(usize, 3), cache.projected_count);
    try std.testing.expectEqual(@as(usize, 0), cache.placeholder_count);
    try std.testing.expect(cache.visuals.items[0].content_bounds.width < studio.default_logical_size.x);
    try std.testing.expect(cache.visuals.items[1].total_item_count == 2);
    try std.testing.expectEqual(studio.default_logical_size.x, cache.visuals.items[2].content_bounds.width);
    try std.testing.expect(!try cache.refresh(9, source, catalog, &indices, source.len, source.len));
    try std.testing.expectEqual(@as(usize, 1), cache.rebuild_count);
}

test "large Library gallery rebuilds once and stays allocation-free on steady keys" {
    const allocator = std.testing.allocator;
    var source = std.ArrayList(u8).empty;
    defer source.deinit(allocator);
    const definition_count: usize = 32;
    for (0..definition_count) |index| {
        var line_buffer: [160]u8 = undefined;
        const line = try std.fmt.bufPrint(
            &line_buffer,
            "@push card_{d} x={d} y=40 w=240 h=80 text=Card {d}\n",
            .{ index, index * 4, index },
        );
        try source.appendSlice(allocator, line);
    }
    try source.appendSlice(allocator, "@slide\n");
    const catalog = try studio_catalog.discover(allocator, source.items);
    defer catalog.deinit();
    var indices: [definition_count]usize = undefined;
    for (&indices, 0..) |*index, value| index.* = value;
    var cache = StudioLibraryGalleryCache.init(allocator);
    defer cache.deinit();
    try std.testing.expect(try cache.refresh(
        41,
        source.items,
        catalog,
        &indices,
        source.items.len,
        source.items.len,
    ));
    try std.testing.expectEqual(definition_count, cache.visuals.items.len);
    try std.testing.expectEqual(definition_count, cache.projected_count);
    const capacity = cache.visuals.capacity;
    try std.testing.expect(!try cache.refresh(
        41,
        source.items,
        catalog,
        &indices,
        source.items.len,
        source.items.len,
    ));
    try std.testing.expectEqual(@as(usize, 1), cache.rebuild_count);
    try std.testing.expectEqual(capacity, cache.visuals.capacity);
}

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
        self.slide_renderer.video_cache.io = io;
        self.slide_renderer.texture_cache.io = io;
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

fn studioMediaSourcePath(selected_path: []const u8, output: []u8) usize {
    var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.Io.Dir.cwd().realPathFile(G.io, ".", &cwd_buffer) catch return 0;
    const cwd = cwd_buffer[0..cwd_len];
    const source_path = studioMediaPathFromSelection(
        G.allocator,
        cwd,
        G.slideshow_filp,
        selected_path,
    ) catch return 0;
    defer G.allocator.free(source_path);
    if (source_path.len > output.len) return 0;
    @memcpy(output[0..source_path.len], source_path);
    return source_path.len;
}

/// The one modal chooser for decks and media. Static because its entry arena
/// is far too large for the main loop's stack frame.
var studio_file_browser: file_browser.Browser = .{};

/// The directory Browse opens in: beside the current deck when there is one,
/// otherwise wherever the process was started.
fn studioBrowseStartDirectory(buffer: []u8) []const u8 {
    var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.Io.Dir.cwd().realPathFile(G.io, ".", &cwd_buffer) catch return "";
    const cwd = cwd_buffer[0..cwd_len];
    const deck_dir = if (G.slideshow_filp) |path| std.fs.path.dirname(path) orelse "." else ".";
    const absolute_deck_dir = std.fs.path.resolve(G.allocator, &.{ cwd, deck_dir }) catch return "";
    defer G.allocator.free(absolute_deck_dir);
    if (absolute_deck_dir.len > buffer.len) return "";
    @memcpy(buffer[0..absolute_deck_dir.len], absolute_deck_dir);
    return buffer[0..absolute_deck_dir.len];
}

fn beginStudioFileBrowse(purpose: file_browser.Purpose) void {
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    studio_file_browser.begin(G.io, purpose, studioBrowseStartDirectory(&directory_buffer));
}

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
    staged_renderer.video_cache.io = G.io;
    staged_renderer.texture_cache.io = G.io;
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
                "@state(morph) label=focus_{d} duration=0.35\n@set title_{d} x=140 color=#55d9ffff\n",
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

fn studioResolvedBoundsByIdentity(bounds: []const studio.ResolvedBounds, identity: usize) ?studio.ResolvedBounds {
    for (bounds) |entry| if (entry.identity == identity) return entry;
    return null;
}

/// The source attribute one media item's content comes from. Images always
/// use `img=`; a video is either a file (`vid=`) or a live camera (`cam=`).
fn mediaSourceAttributeKey(item: *const slides.SlideItem) []const u8 {
    if (item.kind == .img) return "img";
    return if (item.vid_is_camera) "cam" else "vid";
}

fn inheritedPropertyForStudioProperty(
    property: studio.AuthoredProperty,
    is_camera: bool,
) source_editor.InheritedProperty {
    return switch (property) {
        .text => .text,
        .x => .x,
        .y => .y,
        .width => .w,
        .height => .h,
        .foreground => .color,
        .background => .bg,
        .font_size => .fontsize,
        .corner_radius => .radius,
        .line_width => .stroke_width,
        .line_direction => .direction,
        .line_arrows => .arrow,
        .rotation => .rotation,
        .text_alignment => .text_align,
        .text_vertical_alignment => .valign,
        .opacity => .opacity,
        .image_source => .img,
        .video_source => if (is_camera) .cam else .vid,
        .media_fit => .fit,
        .media_focus_x => .focus_x,
        .media_focus_y => .focus_y,
        .video_poster => .poster,
        .video_volume => .volume,
        .video_autoplay => .autoplay,
        .video_loop => .loop,
        .video_muted => .muted,
        .camera_size => .video_size,
        .camera_format => .cam_format,
        .camera_poster => .poster_image,
        // Reveal ownership is handled by `set_item_reveal` (reset/remove
        // actions), never by the inherited-attribute reset path.
        .reveal => unreachable,
        .morph_state => unreachable,
        .transition => unreachable,
    };
}

fn studioPropertyOverrides(
    source_overrides: source_editor.InheritedPropertyOverrides,
    is_camera: bool,
) studio.PropertyOverrideSet {
    var result: studio.PropertyOverrideSet = .{};
    const properties = [_]studio.AuthoredProperty{
        .text,
        .x,
        .y,
        .width,
        .height,
        .foreground,
        .background,
        .font_size,
        .corner_radius,
        .line_width,
        .line_direction,
        .line_arrows,
        .rotation,
        .text_alignment,
        .text_vertical_alignment,
        .opacity,
        .image_source,
        .video_source,
        .media_fit,
        .media_focus_x,
        .media_focus_y,
        .video_poster,
        .video_volume,
        .video_autoplay,
        .video_loop,
        .video_muted,
        .camera_size,
        .camera_format,
        .camera_poster,
    };
    for (properties) |property| {
        if (source_overrides.contains(inheritedPropertyForStudioProperty(property, is_camera))) result.set(property);
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
                context.local_overrides = studioPropertyOverrides(overrides, item.vid_is_camera);
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

test "Studio composition capabilities expose button-based media overrides" {
    const allocator = std.testing.allocator;
    const source =
        "@push clip vid=assets/demo.mp4 w=640 fit=contain volume=0.8\n" ++
        "@slide\n" ++
        "@pop clip id=hero vid=assets/local.mp4 fit=cover autoplay loop muted volume=0.5\n";
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const deck = try slides.SlideShow.new(arena.allocator());
    const parser_context = try parser.constructSlidesFromBuf(source, deck, arena.allocator());
    defer parser_context.deinit();
    try std.testing.expectEqual(@as(usize, 0), parser_context.parser_errors.items.len);

    const slide = deck.slides.items[0];
    const items = slide.items.?.items;
    const studio_state: studio.Studio = .{
        .enabled = true,
        .selected_identity = items[0].identity,
        .selected_source = items[0].source,
    };
    const context = studioCompositionContext(allocator, source, slide, null, items, studio_state).?;
    try std.testing.expectEqual(studio.ReusableInstanceKind.component, context.kind);
    const owner = try studioResetOwner(source, slide, null, &items[0]);
    const source_overrides = try source_editor.inheritedPropertyOverrides(source, owner, items[0].id.?);
    try std.testing.expect(source_overrides.fit);
    try std.testing.expect(source_overrides.vid);
    try std.testing.expect(context.local_overrides.contains(.video_source));
    try std.testing.expect(context.local_overrides.contains(.media_fit));
    try std.testing.expect(context.local_overrides.contains(.video_autoplay));
    try std.testing.expect(context.local_overrides.contains(.video_loop));
    try std.testing.expect(context.local_overrides.contains(.video_muted));
    try std.testing.expect(context.local_overrides.contains(.video_volume));
    try std.testing.expect(context.resettable_overrides.contains(.media_fit));
    try std.testing.expectEqual(source_editor.InheritedProperty.fit, inheritedPropertyForStudioProperty(.media_fit, false));
    try std.testing.expectEqual(source_editor.InheritedProperty.vid, inheritedPropertyForStudioProperty(.video_source, false));
    try std.testing.expectEqual(source_editor.InheritedProperty.cam, inheritedPropertyForStudioProperty(.video_source, true));
    try std.testing.expectEqual(source_editor.InheritedProperty.autoplay, inheritedPropertyForStudioProperty(.video_autoplay, false));
    try std.testing.expectEqual(source_editor.InheritedProperty.loop, inheritedPropertyForStudioProperty(.video_loop, false));
    try std.testing.expectEqual(source_editor.InheritedProperty.muted, inheritedPropertyForStudioProperty(.video_muted, false));
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
    try std.testing.expectEqual(@as(u32, 0), context.local_overrides.bits);
}

test "Studio component materialization preserves effective box semantics" {
    const allocator = std.testing.allocator;
    const source =
        "@push card x=10 y=20 w=300 h=80 fontsize=40 align=center valign=middle color=#112233ff bg=#01020304 " ++
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
    try std.testing.expectEqual(before.text_alignment, after.text_alignment);
    try std.testing.expectEqual(before.text_vertical_alignment, after.text_vertical_alignment);
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

test "Studio media materialization preserves image and video authoring semantics" {
    const allocator = std.testing.allocator;
    const cases = [_]slides.SlideItem{
        .{
            .identity = 1,
            .id = "image",
            .kind = .img,
            .img_path = "assets/hero.png",
            .position = .{ .x = 10, .y = 20 },
            .size = .{ .x = 300, .y = 180 },
            .media_fit = .contain,
            .media_focus = .{ .x = 0.25, .y = 0.75 },
        },
        .{
            .identity = 2,
            .id = "video",
            .kind = .vid,
            .vid_path = "assets/demo.mp4",
            .position = .{ .x = 40, .y = 50 },
            .size = .{ .x = 640, .y = 360 },
            .media_fit = .cover,
            .media_focus = .{ .x = 0.8, .y = 0.2 },
            .vid_poster = 1.25,
            .vid_autoplay = true,
            .vid_loop = true,
            .vid_volume = 0.65,
            .vid_muted = true,
        },
    };
    for (cases) |before| {
        const snippet = try materializeStudioItem(allocator, &before);
        defer allocator.free(snippet);
        const direct_source = try std.fmt.allocPrint(allocator, "@slide\n{s}\n", .{snippet});
        defer allocator.free(direct_source);
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const deck = try slides.SlideShow.new(arena.allocator());
        const context = try parser.constructSlidesFromBuf(direct_source, deck, arena.allocator());
        defer context.deinit();
        try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
        const after = deck.slides.items[0].items.?.items[0];
        try std.testing.expectEqual(before.kind, after.kind);
        try std.testing.expectEqual(before.media_fit, after.media_fit);
        try std.testing.expectEqual(before.media_focus, after.media_focus);
        try std.testing.expectEqual(before.vid_poster, after.vid_poster);
        try std.testing.expectEqual(before.vid_autoplay, after.vid_autoplay);
        try std.testing.expectEqual(before.vid_loop, after.vid_loop);
        try std.testing.expectApproxEqAbs(before.vid_volume, after.vid_volume, 0.0001);
        try std.testing.expectEqual(before.vid_muted, after.vid_muted);
        if (before.img_path) |path| try std.testing.expectEqualStrings(path, after.img_path.?);
        if (before.vid_path) |path| try std.testing.expectEqualStrings(path, after.vid_path.?);
    }
}

test "Studio line materialization preserves complete authoring semantics" {
    const allocator = std.testing.allocator;
    const before: slides.SlideItem = .{
        .identity = 3,
        .id = "connector",
        .kind = .line,
        .position = .{ .x = 100, .y = 120 },
        .size = .{ .x = 640, .y = 240 },
        .line_width = 8,
        .line_direction = .up,
        .line_arrow_start = true,
        .line_arrow_end = true,
        .color = .{ .r = 51, .g = 204, .b = 255, .a = 255 },
        .opacity = 0.65,
        .locked = true,
    };
    const snippet = try materializeStudioItem(allocator, &before);
    defer allocator.free(snippet);
    try std.testing.expect(std.mem.startsWith(u8, snippet, "@line "));

    const direct_source = try std.fmt.allocPrint(allocator, "@slide\n{s}\n", .{snippet});
    defer allocator.free(direct_source);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const deck = try slides.SlideShow.new(arena.allocator());
    const context = try parser.constructSlidesFromBuf(direct_source, deck, arena.allocator());
    defer context.deinit();
    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    const after = deck.slides.items[0].items.?.items[0];
    try std.testing.expectEqual(slides.SlideItemKind.line, after.kind);
    try std.testing.expectEqual(before.position, after.position);
    try std.testing.expectEqual(before.size, after.size);
    try std.testing.expectApproxEqAbs(before.line_width, after.line_width, 0.0001);
    try std.testing.expectEqual(before.line_direction, after.line_direction);
    try std.testing.expectEqual(before.line_arrow_start, after.line_arrow_start);
    try std.testing.expectEqual(before.line_arrow_end, after.line_arrow_end);
    try std.testing.expectEqual(before.color, after.color);
    try std.testing.expectApproxEqAbs(before.opacity, after.opacity, 0.0001);
    try std.testing.expectEqual(before.locked, after.locked);
}

test "Studio detaches parsed reusable media without semantic loss" {
    const allocator = std.testing.allocator;
    const Harness = struct {
        fn expectMediaEqual(before: slides.SlideItem, after: slides.SlideItem) !void {
            try std.testing.expectEqual(before.kind, after.kind);
            try std.testing.expectEqualStrings(before.id.?, after.id.?);
            try std.testing.expectEqual(before.position, after.position);
            try std.testing.expectEqual(before.size, after.size);
            try std.testing.expectEqual(before.media_fit, after.media_fit);
            try std.testing.expectEqual(before.media_focus, after.media_focus);
            try std.testing.expectEqual(before.scale, after.scale);
            try std.testing.expectEqual(before.ratio, after.ratio);
            try std.testing.expectApproxEqAbs(before.opacity, after.opacity, 0.0001);
            try std.testing.expectEqual(before.visible, after.visible);
            try std.testing.expectEqual(before.locked, after.locked);
            if (before.img_path) |path| try std.testing.expectEqualStrings(path, after.img_path.?);
            if (before.vid_path) |path| try std.testing.expectEqualStrings(path, after.vid_path.?);
            try std.testing.expectEqual(before.vid_poster, after.vid_poster);
            try std.testing.expectEqual(before.vid_autoplay, after.vid_autoplay);
            try std.testing.expectEqual(before.vid_loop, after.vid_loop);
            try std.testing.expectApproxEqAbs(before.vid_volume, after.vid_volume, 0.0001);
            try std.testing.expectEqual(before.vid_muted, after.vid_muted);
            try std.testing.expectEqual(slides.SourceScope.direct, after.source.scope);
        }
    };

    const component_source =
        "@push clip vid=assets/shared.mp4 x=10 y=20 w=640 h=360 fit=contain focus_x=0.2 focus_y=0.8 poster=0.5 volume=0.9 opacity=0.7\n" ++
        "@slide\n" ++
        "@pop clip id=hero vid=assets/local.mp4 x=80 fit=cover focus_x=0.75 focus_y=0.25 poster=1.25 autoplay loop volume=0.6 muted opacity=0.8\n";
    var component_before_arena = std.heap.ArenaAllocator.init(allocator);
    defer component_before_arena.deinit();
    const component_before_deck = try slides.SlideShow.new(component_before_arena.allocator());
    const component_before_context = try parser.constructSlidesFromBuf(
        component_source,
        component_before_deck,
        component_before_arena.allocator(),
    );
    defer component_before_context.deinit();
    try std.testing.expectEqual(@as(usize, 0), component_before_context.parser_errors.items.len);
    const component_before = component_before_deck.slides.items[0].items.?.items[0];
    const component_snippet = try materializeStudioItem(allocator, &component_before);
    defer allocator.free(component_snippet);
    const component_offset = std.mem.indexOf(u8, component_source, "@pop clip").?;
    const component_info = try source_editor.inspectComponentInstanceForDetach(component_source, component_offset);
    const detached_component = try source_editor.detachComponentInstance(
        allocator,
        component_source,
        component_offset,
        component_info.definition_offset,
        component_snippet,
    );
    defer detached_component.deinit(allocator);
    var component_after_arena = std.heap.ArenaAllocator.init(allocator);
    defer component_after_arena.deinit();
    const component_after_deck = try slides.SlideShow.new(component_after_arena.allocator());
    const component_after_context = try parser.constructSlidesFromBuf(
        detached_component.source,
        component_after_deck,
        component_after_arena.allocator(),
    );
    defer component_after_context.deinit();
    try std.testing.expectEqual(@as(usize, 0), component_after_context.parser_errors.items.len);
    try Harness.expectMediaEqual(
        component_before,
        component_after_deck.slides.items[0].items.?.items[0],
    );

    const group_source =
        "@pushgroup media_group\n" ++
        "@box id=photo img=assets/hero.png x=10 y=20 w=0 h=0 scale=0.5 ratio=1.4 fit=contain focus_x=0.2 focus_y=0.8 opacity=0.7\n" ++
        "@box id=clip vid=assets/demo.mp4 x=600 y=20 w=640 h=360 fit=cover focus_x=0.9 focus_y=0.1 poster=1.25 autoplay loop volume=0.65 muted opacity=0.8\n" ++
        "@endgroup\n" ++
        "@slide\n" ++
        "@popgroup media_group id=hero\n";
    var group_before_arena = std.heap.ArenaAllocator.init(allocator);
    defer group_before_arena.deinit();
    const group_before_deck = try slides.SlideShow.new(group_before_arena.allocator());
    const group_before_context = try parser.constructSlidesFromBuf(
        group_source,
        group_before_deck,
        group_before_arena.allocator(),
    );
    defer group_before_context.deinit();
    try std.testing.expectEqual(@as(usize, 0), group_before_context.parser_errors.items.len);
    const group_before = group_before_deck.slides.items[0].items.?.items;
    try std.testing.expectEqual(@as(usize, 2), group_before.len);
    var group_snippets: [2][]u8 = undefined;
    var group_snippet_count: usize = 0;
    defer for (group_snippets[0..group_snippet_count]) |snippet| allocator.free(snippet);
    for (group_before, 0..) |*item, index| {
        group_snippets[index] = try materializeStudioItem(allocator, item);
        group_snippet_count += 1;
    }
    const group_offset = std.mem.indexOf(u8, group_source, "@popgroup media_group").?;
    const group_info = try source_editor.inspectReusableGroupInstance(allocator, group_source, group_offset);
    const detached_group = try source_editor.detachReusableGroupInstance(
        allocator,
        group_source,
        group_offset,
        group_info.definition_offset,
        &group_snippets,
    );
    defer detached_group.deinit(allocator);
    var group_after_arena = std.heap.ArenaAllocator.init(allocator);
    defer group_after_arena.deinit();
    const group_after_deck = try slides.SlideShow.new(group_after_arena.allocator());
    const group_after_context = try parser.constructSlidesFromBuf(
        detached_group.source,
        group_after_deck,
        group_after_arena.allocator(),
    );
    defer group_after_context.deinit();
    try std.testing.expectEqual(@as(usize, 0), group_after_context.parser_errors.items.len);
    const group_after = group_after_deck.slides.items[0].items.?.items;
    try std.testing.expectEqual(group_before.len, group_after.len);
    for (group_before, group_after) |before, after| try Harness.expectMediaEqual(before, after);
}

test "Studio media definitions survive rename cleanup and history" {
    const allocator = std.testing.allocator;
    const source =
        "@push clip vid=assets/demo.mp4 x=20 y=30 w=640 h=360 fit=cover focus_x=0.8 focus_y=0.2 poster=1.25 autoplay loop volume=0.65 muted\n" ++
        "@slide\n" ++
        "@pop clip id=hero\n" ++
        "@pushgroup unused_media\n" ++
        "@box id=photo img=assets/unused.png fit=contain\n" ++
        "@endgroup\n";
    var catalog = try studio_catalog.discover(allocator, source);
    defer catalog.deinit();
    try std.testing.expectEqual(@as(usize, 2), catalog.entries.len);
    const renamed = try studio_catalog.renameDefinition(allocator, source, catalog.entries[0], "movie");
    defer renamed.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, renamed.source, "@push movie vid=assets/demo.mp4") != null);
    try std.testing.expect(std.mem.indexOf(u8, renamed.source, "@pop movie id=hero") != null);
    const cleaned = try studio_catalog.cleanupUnusedDefinitions(allocator, renamed.source);
    defer cleaned.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, cleaned.source, "unused_image") == null);

    const Harness = struct {
        fn expectMedia(source_: []const u8) !void {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const deck = try slides.SlideShow.new(arena.allocator());
            const context = try parser.constructSlidesFromBuf(source_, deck, arena.allocator());
            defer context.deinit();
            try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
            const item = deck.slides.items[0].items.?.items[0];
            try std.testing.expectEqualStrings("hero", item.id.?);
            try std.testing.expectEqualStrings("assets/demo.mp4", item.vid_path.?);
            try std.testing.expectEqual(slides.MediaFit.cover, item.media_fit);
            try std.testing.expectEqual(rl.Vector2{ .x = 0.8, .y = 0.2 }, item.media_focus);
            try std.testing.expectEqual(@as(?f32, 1.25), item.vid_poster);
            try std.testing.expect(item.vid_autoplay);
            try std.testing.expect(item.vid_loop);
            try std.testing.expectApproxEqAbs(@as(f32, 0.65), item.vid_volume, 0.0001);
            try std.testing.expect(item.vid_muted);
        }
    };
    try Harness.expectMedia(source);
    try Harness.expectMedia(cleaned.source);

    var history = StudioHistory.init(allocator);
    defer history.deinit();
    try history.record(
        try allocator.dupe(u8, source),
        try allocator.dupe(u8, cleaned.source),
        0,
        0,
    );
    const undo_restore = (try history.prepareRestore(.undo)).?;
    try Harness.expectMedia(undo_restore.source);
    history.commitRestore(.undo);
    const redo_restore = (try history.prepareRestore(.redo)).?;
    try Harness.expectMedia(redo_restore.source);
    history.commitRestore(.redo);
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
    if (command == .set_common_property) {
        for (command.set_common_property.targets.slice()) |target| {
            if (target.edit_scope != .shared_template) continue;
            const item = studioItemByIdentity(items, target.item_identity) orelse continue;
            if (item.instance_source != null) return true;
        }
        return false;
    }
    const target: studio.CommandTarget = switch (command) {
        .edit_text => |value| value,
        .replace_media => |value| value,
        .set_media_fit => |value| value.target,
        .set_text_alignment => |value| value.target,
        .set_line_style => |value| value.target,
        .set_rotation => |value| value.target,
        .set_media_focus => |value| value.target,
        .set_video_poster => |value| value.target,
        .set_video_volume => |value| value.target,
        .set_video_toggle => |value| value.target,
        .set_camera_format => |value| value.target,
        .set_camera_size => |value| value.target,
        .replace_camera_poster => |value| value,
        .edit_numeric_geometry => |value| value.target,
        .set_foreground, .set_background => |value| value.target,
        .set_custom_foreground,
        .set_custom_background,
        .set_font_size,
        .set_corner_radius,
        .set_line_width,
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
    const patch = try starterDeckPatch(std.testing.allocator, pristine_untitled_source, .signal);
    defer patch.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(studio_new_deck.source(.signal), patch.source);
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
        .rotation = preview.rotation,
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
        .rotation = null,
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

fn studioRotationEligible(item: slides.SlideItem) bool {
    return item.kind == .textbox or item.kind == .line or item.kind == .img or item.kind == .vid;
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

fn canonicalStudioUnitInterval(input: []const u8, buffer: []u8) ![]const u8 {
    const value = try parseStudioFiniteFloat(input);
    if (value < 0 or value > 1) return error.InvalidStudioUnitInterval;
    return formatStudioFloat(buffer, value);
}

fn canonicalStudioVideoPoster(input: []const u8, buffer: []u8) ![]const u8 {
    const value = try parseStudioFiniteFloat(input);
    if (value < 0) return error.InvalidStudioVideoPoster;
    return formatStudioFloat(buffer, value);
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
/// Motion inspector fields patch one reveal property on every target; the
/// per-target current spec is resolved when the command is applied.
fn revealInlineCommand(commit: studio.InlineCommit) studio.ItemRevealCommand {
    const value = std.mem.trim(u8, commit.value, " \t\r\n");
    var patch: studio.RevealPatch = .{};
    switch (commit.field) {
        .reveal_delay => patch.delay = if (value.len == 0)
            .none
        else if (std.ascii.eqlIgnoreCase(value, "click"))
            .click
        else
            .{ .seconds = parseStudioFiniteFloat(value) catch 0 },
        .reveal_after => patch.after = if (value.len == 0) @as(?f32, null) else (parseStudioFiniteFloat(value) catch 0),
        .reveal_duration => patch.duration = parseStudioFiniteFloat(value) catch 0,
        else => {},
    }
    var targets = commit.targets;
    if (targets.count == 0) {
        targets.targets[0] = commit.target;
        targets.count = 1;
    }
    return .{ .targets = targets, .action = .patch, .patch = patch };
}

fn sceneInlineSemanticEdit(commit: studio.InlineCommit) InlineSemanticEdit {
    const state_index = commit.scene_state orelse 0;
    const value = std.mem.trim(u8, commit.value, " \t\r\n");
    const command: studio.SemanticCommand = switch (commit.field) {
        .state_label => if (value.len == 0) .{ .clear_morph_state_label = state_index } else .{ .rename_morph_state = state_index },
        .state_after => .{ .set_morph_state_timing = .{
            .state_index = state_index,
            .after = if (value.len == 0) @as(?f32, null) else (parseStudioFiniteFloat(value) catch 0),
        } },
        .state_duration => .{ .set_morph_state_timing = .{
            .state_index = state_index,
            .duration = parseStudioFiniteFloat(value) catch 0,
        } },
        .transition_duration => .{ .set_slide_transition = .{ .duration = parseStudioFiniteFloat(value) catch 0 } },
        else => unreachable,
    };
    return .{ .command = command, .value = value };
}

fn inlineSemanticEdit(commit: studio.InlineCommit) InlineSemanticEdit {
    if (studio.inlineFieldIsScene(commit.field)) return sceneInlineSemanticEdit(commit);
    if (studio.inlineFieldIsMotion(commit.field)) {
        return .{ .command = .{ .set_item_reveal = revealInlineCommand(commit) }, .value = commit.value };
    }
    if (commit.targets.count > 1) {
        const property: studio.CommonProperty = switch (commit.field) {
            .text => unreachable,
            .reveal_delay, .reveal_after, .reveal_duration => unreachable,
            .state_label, .state_after, .state_duration, .transition_duration => unreachable,
            .x => .x,
            .y => .y,
            .width => .width,
            .height => .height,
            .foreground => .foreground,
            .background => .background,
            .font_size => .font_size,
            .corner_radius => .corner_radius,
            .line_width => .line_width,
            .rotation => .rotation,
            .opacity => .opacity,
            .media_focus_x => .media_focus_x,
            .media_focus_y => .media_focus_y,
            .video_poster => .video_poster,
            .video_volume => .video_volume,
            .camera_size => unreachable,
        };
        return .{
            .command = .{ .set_common_property = .{
                .targets = commit.targets,
                .property = property,
                .value = commit.value,
            } },
            .value = commit.value,
        };
    }
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
        .corner_radius => .{ .set_corner_radius = commit.target },
        .line_width => .{ .set_line_width = commit.target },
        .rotation => .{ .set_rotation = .{ .target = commit.target } },
        .opacity => .{ .set_opacity = commit.target },
        .media_focus_x => .{ .set_media_focus = .{ .target = commit.target, .axis = .x } },
        .media_focus_y => .{ .set_media_focus = .{ .target = commit.target, .axis = .y } },
        .video_poster => .{ .set_video_poster = .{ .target = commit.target } },
        .video_volume => .{ .set_video_volume = .{ .target = commit.target } },
        .camera_size => .{ .set_camera_size = .{ .target = commit.target } },
        .reveal_delay, .reveal_after, .reveal_duration => unreachable,
        .state_label, .state_after, .state_duration, .transition_duration => unreachable,
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
        .corner_radius => {
            const value = parseStudioFiniteFloat(commit.value) catch return .invalid_corner_radius;
            if (value < 0) return .invalid_corner_radius;
        },
        .line_width => {
            const value = parseStudioFiniteFloat(commit.value) catch return .invalid_line_width;
            if (value <= 0) return .invalid_line_width;
        },
        .rotation => _ = parseStudioFiniteFloat(commit.value) catch return .invalid_rotation,
        .opacity => {
            var buffer: [64]u8 = undefined;
            _ = canonicalStudioOpacity(commit.value, &buffer) catch return .invalid_opacity;
        },
        .media_focus_x, .media_focus_y => {
            var buffer: [64]u8 = undefined;
            _ = canonicalStudioUnitInterval(commit.value, &buffer) catch return .invalid_unit_interval;
        },
        .video_poster => {
            var buffer: [64]u8 = undefined;
            _ = canonicalStudioVideoPoster(commit.value, &buffer) catch return .invalid_video_poster;
        },
        .video_volume => {
            var buffer: [64]u8 = undefined;
            _ = canonicalStudioUnitInterval(commit.value, &buffer) catch return .invalid_unit_interval;
        },
        .camera_size => {
            var buffer: [64]u8 = undefined;
            _ = canonicalStudioCameraSize(commit.value, &buffer) catch return .invalid_camera_size;
        },
        .reveal_delay => {
            const value = std.mem.trim(u8, commit.value, " \t\r\n");
            if (value.len != 0 and !std.ascii.eqlIgnoreCase(value, "click")) {
                const parsed = parseStudioFiniteFloat(value) catch return .invalid_delay;
                if (parsed < 0) return .invalid_delay;
            }
        },
        .reveal_after => {
            const value = std.mem.trim(u8, commit.value, " \t\r\n");
            if (value.len != 0) {
                const parsed = parseStudioFiniteFloat(value) catch return .invalid_seconds;
                if (parsed < 0) return .invalid_seconds;
            }
        },
        .reveal_duration => {
            const parsed = parseStudioFiniteFloat(commit.value) catch return .invalid_seconds;
            if (parsed < 0) return .invalid_seconds;
        },
        .state_label => {
            const value = std.mem.trim(u8, commit.value, " \t\r\n");
            if (value.len != 0 and !validReusableName(value)) return .invalid_state_label;
        },
        .state_after => {
            const value = std.mem.trim(u8, commit.value, " \t\r\n");
            if (value.len != 0) {
                const parsed = parseStudioFiniteFloat(value) catch return .invalid_seconds;
                if (parsed < 0) return .invalid_seconds;
            }
        },
        .state_duration, .transition_duration => {
            const parsed = parseStudioFiniteFloat(commit.value) catch return .invalid_seconds;
            if (parsed < 0) return .invalid_seconds;
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
    if (commit.targets.count > 1) {
        for (commit.targets.slice()) |target| {
            var single = commit;
            single.target = target;
            single.targets = .{};
            if (inlineCommitChangesValue(single, items, resolved_bounds)) return true;
        }
        return false;
    }
    if (studio.inlineFieldIsScene(commit.field)) return true;
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
        .corner_radius => changed: {
            const current = if (shared) |values| values.corner_radius else item.corner_radius;
            const submitted = parseStudioFiniteFloat(commit.value) catch return true;
            break :changed @abs(current - submitted) > 0.000001;
        },
        .line_width => changed: {
            const current = if (shared) |values| values.line_width else item.line_width;
            const submitted = parseStudioFiniteFloat(commit.value) catch return true;
            break :changed @abs(current - submitted) > 0.000001;
        },
        .rotation => changed: {
            const current = if (shared) |values| values.rotation else item.rotation;
            const submitted = parseStudioFiniteFloat(commit.value) catch return true;
            break :changed @abs(current - submitted) > 0.000001;
        },
        .opacity => changed: {
            const current = if (shared) |values| values.opacity else item.opacity;
            const submitted = canonicalOpacityValue(commit.value) catch return true;
            break :changed @abs(current - submitted) > 0.000001;
        },
        .media_focus_x => changed: {
            const current = if (shared) |values| values.media_focus.x else item.media_focus.x;
            const submitted = parseStudioFiniteFloat(commit.value) catch return true;
            break :changed @abs(current - submitted) > 0.000001;
        },
        .media_focus_y => changed: {
            const current = if (shared) |values| values.media_focus.y else item.media_focus.y;
            const submitted = parseStudioFiniteFloat(commit.value) catch return true;
            break :changed @abs(current - submitted) > 0.000001;
        },
        .video_poster => changed: {
            const current = if (shared) |values| values.vid_poster orelse 0 else item.vid_poster orelse 0;
            const submitted = parseStudioFiniteFloat(commit.value) catch return true;
            break :changed @abs(current - submitted) > 0.000001;
        },
        .video_volume => changed: {
            const current = if (shared) |values| values.vid_volume else item.vid_volume;
            const submitted = parseStudioFiniteFloat(commit.value) catch return true;
            break :changed @abs(current - submitted) > 0.000001;
        },
        .camera_size => changed: {
            const current = if (shared) |values| values.vid_camera_size else item.vid_camera_size;
            const submitted = studio.parseCameraSize(std.mem.trim(u8, commit.value, " \t\r\n")) orelse break :changed true;
            break :changed @as(i32, @intFromFloat(current.x)) != submitted.width or
                @as(i32, @intFromFloat(current.y)) != submitted.height;
        },
        .reveal_delay => changed: {
            const spec = item.animation orelse break :changed true;
            const value = std.mem.trim(u8, commit.value, " \t\r\n");
            if (value.len == 0) break :changed spec.delay != null or spec.first_waits;
            if (std.ascii.eqlIgnoreCase(value, "click")) break :changed !spec.first_waits;
            const parsed = parseStudioFiniteFloat(value) catch break :changed true;
            break :changed spec.first_waits or spec.delay == null or spec.delay.? != parsed;
        },
        .reveal_after => changed: {
            const spec = item.animation orelse break :changed true;
            const value = std.mem.trim(u8, commit.value, " \t\r\n");
            if (value.len == 0) break :changed spec.after != null;
            const parsed = parseStudioFiniteFloat(value) catch break :changed true;
            break :changed spec.after == null or spec.after.? != parsed;
        },
        .reveal_duration => changed: {
            const spec = item.animation orelse break :changed true;
            const parsed = parseStudioFiniteFloat(commit.value) catch break :changed true;
            break :changed spec.duration != parsed;
        },
        .state_label, .state_after, .state_duration, .transition_duration => true,
    };
}

/// Normalises an authored capture size to the single `WIDTHxHEIGHT` spelling
/// the parser accepts, so Studio never writes a variant it would then refuse
/// to load.
fn canonicalStudioCameraSize(input: []const u8, buffer: []u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    const size = studio.parseCameraSize(trimmed) orelse return error.InvalidStudioCameraSize;
    return std.fmt.bufPrint(buffer, "{d}x{d}", .{ size.width, size.height });
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
        error.InvalidStudioCornerRadius => .invalid_corner_radius,
        error.InvalidStudioLineWidth => .invalid_line_width,
        error.InvalidStudioRotation => .invalid_rotation,
        error.InvalidStudioOpacity => .invalid_opacity,
        error.InvalidStudioUnitInterval => .invalid_unit_interval,
        error.InvalidStudioVideoPoster => .invalid_video_poster,
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
    try std.testing.expectEqualStrings("0.75", try canonicalStudioUnitInterval("0.75", &number_buffer));
    try std.testing.expectError(error.InvalidStudioUnitInterval, canonicalStudioUnitInterval("1.01", &number_buffer));
    try std.testing.expectEqualStrings("6.25", try canonicalStudioVideoPoster("6.25", &number_buffer));
    try std.testing.expectError(error.InvalidStudioVideoPoster, canonicalStudioVideoPoster("-0.1", &number_buffer));
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
        .{ .field = .corner_radius, .value = "24", .tag = .set_corner_radius },
        .{ .field = .line_width, .value = "6", .tag = .set_line_width },
        .{ .field = .opacity, .value = "75%", .tag = .set_opacity },
        .{ .field = .media_focus_x, .value = "0.25", .tag = .set_media_focus },
        .{ .field = .media_focus_y, .value = "0.75", .tag = .set_media_focus },
        .{ .field = .video_poster, .value = "2.5", .tag = .set_video_poster },
        .{ .field = .video_volume, .value = "0.65", .tag = .set_video_volume },
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
    try std.testing.expectEqual(studio.InlineError.invalid_corner_radius, validateInlineCommit(.{
        .target = target,
        .field = .corner_radius,
        .value = "-1",
    }).?);
    try std.testing.expectEqual(studio.InlineError.invalid_line_width, validateInlineCommit(.{
        .target = target,
        .field = .line_width,
        .value = "0",
    }).?);
    try std.testing.expectEqual(studio.InlineError.invalid_opacity, validateInlineCommit(.{
        .target = target,
        .field = .opacity,
        .value = "101%",
    }).?);
    try std.testing.expectEqual(studio.InlineError.invalid_unit_interval, validateInlineCommit(.{
        .target = target,
        .field = .media_focus_x,
        .value = "-0.01",
    }).?);
    try std.testing.expectEqual(studio.InlineError.invalid_video_poster, validateInlineCommit(.{
        .target = target,
        .field = .video_poster,
        .value = "-1",
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
    try std.testing.expect(validateInlineCommit(.{
        .target = target,
        .field = .media_focus_y,
        .value = "1",
    }) == null);
    try std.testing.expect(validateInlineCommit(.{
        .target = target,
        .field = .video_volume,
        .value = "0.65",
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
    build_summaries: std.ArrayList(studio.RevealBuildSummary) = .empty,
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
        self.build_summaries.deinit(self.allocator);
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
        self.build_summaries.clearRetainingCapacity();
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
        builds: []const renderer.RevealBuild,
        source: []const u8,
    ) !bool {
        var rebuilt = false;
        if (self.morph_slide_index != slide_index) {
            self.morph_summaries.clearRetainingCapacity();
            self.build_summaries.clearRetainingCapacity();
            if (slide) |current| {
                if (current.items) |base_items| {
                    for (builds) |build| {
                        const owner = studioItemByIdentity(base_items.items, build.owner_identity);
                        try self.build_summaries.append(self.allocator, .{
                            .owner_identity = build.owner_identity,
                            .first_step = build.first_step,
                            .step_count = build.step_count,
                            .spec = build.spec,
                            .label = if (owner) |item| studioItemLabel(item.*) else "",
                            .authored_locally = if (owner) |item|
                                item.source.patchable and source_editor.itemAuthorsReveal(source, item.source.line_offset)
                            else
                                true,
                        });
                    }
                }
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
            .transition_effect = slide.transition.effect,
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
    try std.testing.expect(try cache.refreshScene(selected_index, selected, item_offset, slide_offset, &.{}, ""));
    try std.testing.expectEqual(definition_count, cache.library_entries.items.len);
    try std.testing.expectEqual(@as(usize, 1), cache.document_rebuild_count);
    try std.testing.expectEqual(@as(usize, 1), cache.scene_rebuild_count);

    // A steady Studio frame performs no catalog, slide-summary, morph, or
    // library rebuild regardless of deck size.
    try std.testing.expect(!try cache.refreshDocument(11, source_builder.items, slideshow));
    try std.testing.expect(!try cache.refreshScene(selected_index, selected, item_offset, slide_offset, &.{}, ""));
    try std.testing.expectEqual(@as(usize, 1), cache.document_rebuild_count);
    try std.testing.expectEqual(@as(usize, 1), cache.scene_rebuild_count);

    const next = slideshow.slides.items[selected_index + 1];
    try std.testing.expect(try cache.refreshScene(selected_index + 1, next, try source_editor.slideItemInsertionOffset(source_builder.items, next.pos_in_editor), try source_editor.slideEndOffset(source_builder.items, next.pos_in_editor), &.{}, ""));
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

fn studioLibraryWorkspaceIndex(workspace: studio.Workspace, name: []const u8) ?usize {
    if (name.len == 0) return null;
    for (workspace.library, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.name, name)) return index;
    }
    return null;
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
    if (!source_editor.semanticItemTextRequiresBody(text_value)) {
        return std.fmt.allocPrint(allocator, "{s} text={s}", .{ directive_without_text, text_value });
    }
    const encoded = try source_editor.encodeSemanticBodyText(allocator, text_value);
    defer allocator.free(encoded);
    return std.fmt.allocPrint(allocator, "{s}\n{s}", .{ directive_without_text, encoded });
}

test "Studio item snippets encode visual blank lines as parser spacers" {
    const snippet = try itemTextSnippet(std.testing.allocator, "@box id=body", "First\n \nSecond\n");
    defer std.testing.allocator.free(snippet);
    try std.testing.expectEqualStrings("@box id=body\nFirst\n_\nSecond\n_", snippet);
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

/// Emit the complete inline reveal form for a materialized item, including
/// the first-step delay, easing, and order so Detach stays lossless.
fn appendStudioRevealAttributes(directive: *std.ArrayList(u8), allocator: std.mem.Allocator, spec: animation.ItemSpec) !void {
    try directive.appendSlice(allocator, " anim=");
    try directive.appendSlice(allocator, animation.effectLiteral(spec.effect));
    try directive.appendSlice(allocator, " by=");
    try directive.appendSlice(allocator, animation.groupingLiteral(spec.by));
    if (spec.first_waits) {
        try directive.appendSlice(allocator, " delay=click");
    } else if (spec.delay) |delay| {
        try appendStudioToken(directive, allocator, " delay={d}", .{delay});
    }
    if (spec.after) |after| try appendStudioToken(directive, allocator, " after={d}", .{after});
    try appendStudioToken(directive, allocator, " duration={d}", .{spec.duration});
    if (spec.easing != .smooth) {
        try directive.appendSlice(allocator, " ease=");
        try directive.appendSlice(allocator, animation.easingLiteral(spec.easing));
    }
    if (spec.order != 0) try appendStudioToken(directive, allocator, " order={d}", .{spec.order});
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
/// literal directive. Detach is an explicit customization boundary, so values that
/// were previously inherited are intentionally made concrete. Auto-sized
/// media retain zero W/H plus their scale/ratio controls.
fn materializeStudioItem(allocator: std.mem.Allocator, item: *const slides.SlideItem) ![]u8 {
    if (item.kind != .textbox and item.kind != .img and item.kind != .vid and item.kind != .line)
        return error.UnsupportedComponentDetach;
    const id = try studioLiteralToken(item.id orelse return error.DetachedItemIdMismatch);

    var directive = std.ArrayList(u8).empty;
    defer directive.deinit(allocator);
    try directive.appendSlice(allocator, if (item.kind == .line) "@line id=" else "@box id=");
    try directive.appendSlice(allocator, id);
    try appendStudioToken(&directive, allocator, " x={d} y={d} w={d} h={d}", .{
        item.position.x,
        item.position.y,
        item.size.x,
        item.size.y,
    });

    if (item.kind == .line) {
        try appendStudioToken(&directive, allocator, " stroke_width={d}", .{item.line_width});
        try directive.appendSlice(allocator, " direction=");
        try directive.appendSlice(allocator, if (item.line_direction == .down) "down" else "up");
        try directive.appendSlice(allocator, " arrow=");
        try directive.appendSlice(allocator, if (item.line_arrow_start and item.line_arrow_end)
            "both"
        else if (item.line_arrow_start)
            "start"
        else if (item.line_arrow_end)
            "end"
        else
            "none");
        if (item.color) |color| {
            var color_buffer: [9]u8 = undefined;
            try directive.appendSlice(allocator, " color=");
            try directive.appendSlice(allocator, colorLiteral(&color_buffer, color));
        }
        if (@abs(item.rotation) > 0.000001)
            try appendStudioToken(&directive, allocator, " rotation={d}", .{item.rotation});
        try appendStudioToken(&directive, allocator, " opacity={d} visible={s} locked={s}", .{
            item.opacity,
            if (item.visible) "true" else "false",
            if (item.locked) "true" else "false",
        });
        if (item.animation) |spec| try appendStudioRevealAttributes(&directive, allocator, spec);
        return directive.toOwnedSlice(allocator);
    }

    if (item.img_path) |path| {
        try directive.appendSlice(allocator, " img=");
        try directive.appendSlice(allocator, try studioLiteralToken(path));
    }
    if (item.vid_path) |path| {
        try directive.appendSlice(allocator, if (item.vid_is_camera) " cam=" else " vid=");
        try directive.appendSlice(allocator, try studioLiteralToken(path));
    }
    if (item.kind == .img or item.kind == .vid) {
        if (item.media_fit != .stretch) {
            try directive.appendSlice(allocator, " fit=");
            try directive.appendSlice(allocator, switch (item.media_fit) {
                .stretch => unreachable,
                .contain => "contain",
                .cover => "cover",
            });
        }
        if (@abs(item.media_focus.x - 0.5) > 0.000001)
            try appendStudioToken(&directive, allocator, " focus_x={d}", .{item.media_focus.x});
        if (@abs(item.media_focus.y - 0.5) > 0.000001)
            try appendStudioToken(&directive, allocator, " focus_y={d}", .{item.media_focus.y});
    }
    if (item.kind == .vid) {
        if (item.vid_is_camera) {
            try appendStudioToken(&directive, allocator, " video_size={d}x{d}", .{ @as(i32, @intFromFloat(item.vid_camera_size.x)), @as(i32, @intFromFloat(item.vid_camera_size.y)) });
            if (item.vid_camera_format != .auto) {
                try directive.appendSlice(allocator, " cam_format=");
                try directive.appendSlice(allocator, item.vid_camera_format.attrValue());
            }
            if (item.vid_camera_poster) |poster_path| {
                try directive.appendSlice(allocator, " poster_image=");
                try directive.appendSlice(allocator, try studioLiteralToken(poster_path));
            }
        }
        if (item.vid_poster) |poster| try appendStudioToken(&directive, allocator, " poster={d}", .{poster});
        if (item.vid_autoplay) try directive.appendSlice(allocator, " autoplay");
        if (item.vid_loop) try directive.appendSlice(allocator, " loop");
        if (@abs(item.vid_volume - 1) > 0.000001)
            try appendStudioToken(&directive, allocator, " volume={d}", .{item.vid_volume});
        if (item.vid_muted) try directive.appendSlice(allocator, " muted");
    }
    if (item.fontSize) |font_size|
        try appendStudioToken(&directive, allocator, " fontsize={d}", .{font_size});
    if (item.corner_radius > 0)
        try appendStudioToken(&directive, allocator, " radius={d}", .{item.corner_radius});
    if (@abs(item.rotation) > 0.000001)
        try appendStudioToken(&directive, allocator, " rotation={d}", .{item.rotation});
    if (item.text_alignment != .left) {
        try directive.appendSlice(allocator, " align=");
        try directive.appendSlice(allocator, switch (item.text_alignment) {
            .left => unreachable,
            .center => "center",
            .right => "right",
        });
    }
    if (item.text_vertical_alignment != .top) {
        try directive.appendSlice(allocator, " valign=");
        try directive.appendSlice(allocator, switch (item.text_vertical_alignment) {
            .top => unreachable,
            .middle => "middle",
            .bottom => "bottom",
        });
    }
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
    if (item.animation) |spec| try appendStudioRevealAttributes(&directive, allocator, spec);

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

const StudioDefinitionEditContext = struct {
    kind: studio_catalog.Kind,
    scene: source_editor.ItemSceneAnchor,
};

fn studioEditSceneAnchor(
    slide: *const slides.Slide,
    morph_state: ?usize,
    definition: ?StudioDefinitionEditContext,
) !source_editor.ItemSceneAnchor {
    if (definition) |context| return context.scene;
    return studioItemSceneAnchor(slide, morph_state);
}

fn captureStudioClipboard(
    clipboard: *StudioClipboard,
    command: studio.CopyItemsCommand,
    slide: *const slides.Slide,
    morph_state: ?usize,
    definition: ?StudioDefinitionEditContext,
    items: []const slides.SlideItem,
    resolved_bounds: []const studio.ResolvedBounds,
) !void {
    if (command.count == 0 or command.count > studio.max_selection_items) return error.InvalidStudioClipboardBatch;
    const scene = try studioEditSceneAnchor(slide, morph_state, definition);

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

fn suspendStudioForSlidePicker(
    studio_mode: *studio.Studio,
    library_preview_cache: *StudioLibraryPreviewCache,
) void {
    const items = if (studio_mode.definitionModeActive())
        library_preview_cache.items()
    else
        currentStudioSceneItemsMutable(studio_mode);
    studio_mode.cancelActiveInteraction(items);
}

fn prepareStudioForSlideJump(
    studio_mode: *studio.Studio,
    library_preview_cache: *StudioLibraryPreviewCache,
) void {
    if (studio_mode.definitionModeActive()) {
        studio_mode.leaveDefinitionMode(library_preview_cache.items());
    }
    studio_mode.clearSelection(currentStudioSceneItemsMutable(studio_mode));
    studio_mode.active_morph_state = null;
    studio_mode.dismissLibraryPreview();
    studio_mode.setNotice(.none);
}

fn currentStudioSceneItemsMutable(studio_mode: *const studio.Studio) []slides.SlideItem {
    if (G.current_slide < 0 or G.current_slide >= G.slideshow.slides.items.len) return &.{};
    const slide = G.slideshow.slides.items[@intCast(G.current_slide)];
    if (studio_mode.active_morph_state) |state_index| {
        if (state_index >= slide.morph_states.items.len) return &.{};
        return slide.morph_states.items[state_index].items.items;
    }
    return if (slide.items) |*items| items.items else &.{};
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

fn applyStudioLiteralAttributeBatch(
    history: *StudioHistory,
    targets: []const studio.CommandTarget,
    slide: *const slides.Slide,
    morph_state: ?usize,
    items: []const slides.SlideItem,
    key: []const u8,
    value: []const u8,
) !void {
    if (targets.len == 0 or targets.len > studio.max_selection_items) return error.InvalidStudioPropertyBatch;
    const source = G.editor_memory[0..G.source_len];
    var edits: [studio.max_selection_items]source_editor.LiteralSourceEdit = undefined;
    var patches: [studio.max_selection_items][1]source_editor.LiteralAttributePatch = undefined;
    var snippets: [studio.max_selection_items]?[]u8 = @splat(null);
    defer for (snippets[0..targets.len]) |snippet| if (snippet) |owned| G.allocator.free(owned);

    for (targets, 0..) |target, index| {
        const item = studioItemByIdentity(items, target.item_identity) orelse return error.StudioItemMissing;
        patches[index][0] = .{ .key = key, .value = value };
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
                    snippets[index] = try std.fmt.allocPrint(G.allocator, "@set {s} {s}={s}", .{ id, key, value });
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
                snippets[index] = try std.fmt.allocPrint(G.allocator, "@set {s} {s}={s}", .{ id, key, value });
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

    return recordStudioPatch(history, try source_editor.applyLiteralEdits(G.allocator, source, edits[0..targets.len]));
}

fn applyStudioLockEdit(
    history: *StudioHistory,
    command: studio.SetLockedCommand,
    slide: *const slides.Slide,
    morph_state: ?usize,
    items: []const slides.SlideItem,
) !void {
    return applyStudioLiteralAttributeBatch(
        history,
        command.slice(),
        slide,
        morph_state,
        items,
        "locked",
        if (command.locked) "true" else "false",
    );
}

/// Minimal `order=` keys for a desired build sequence. Walking the sequence,
/// the key only increases where the next build sits earlier in the source
/// than the previous one; every other build keeps the previous key. Builds
/// that end up with key 0 need no `order=` at all.
fn revealOrderAssignments(source_positions: []const usize, orders: []i32) void {
    var current: i32 = 0;
    for (source_positions, 0..) |position, index| {
        if (index > 0 and position < source_positions[index - 1]) current += 1;
        orders[index] = current;
    }
}

test "reveal order assignments stay minimal and only rise on source inversions" {
    var orders: [4]i32 = undefined;
    revealOrderAssignments(&.{ 10, 20, 30, 40 }, &orders);
    try std.testing.expectEqualSlices(i32, &.{ 0, 0, 0, 0 }, &orders);
    revealOrderAssignments(&.{ 30, 10, 20, 40 }, &orders);
    try std.testing.expectEqualSlices(i32, &.{ 0, 1, 1, 1 }, &orders);
    revealOrderAssignments(&.{ 40, 30, 20, 10 }, &orders);
    try std.testing.expectEqualSlices(i32, &.{ 0, 1, 2, 3 }, &orders);
    var two: [2]i32 = undefined;
    revealOrderAssignments(&.{ 20, 10 }, &two);
    try std.testing.expectEqualSlices(i32, &.{ 0, 1 }, &two);
}

/// The current slide's incoming transition with its provenance.
fn studioTransitionSummary(slide: *const slides.Slide) studio.TransitionSummary {
    const source = G.editor_memory[0..G.source_len];
    const anchor_name = source_editor.directiveNameAt(source, slide.pos_in_editor);
    const can_author = anchor_name != null and
        (std.mem.eql(u8, anchor_name.?, "@slide") or std.mem.eql(u8, anchor_name.?, "@popslide"));
    const local = can_author and source_editor.directiveHasAttribute(source, slide.pos_in_editor, "transition");
    const provenance: studio.TransitionProvenance = if (local)
        .slide
    else if (slide.transition_authored)
        .template
    else if (G.slideshow.has_default_transition)
        .deck_default
    else
        .none;
    return .{
        .transition = slide.transition,
        .provenance = provenance,
        .template_name = source_editor.slideAnchorTemplateName(source, slide.pos_in_editor) orelse "",
        .deck = if (G.slideshow.has_default_transition) G.slideshow.default_transition else null,
        .can_author = can_author,
        .has_previous_slide = G.current_slide > 0,
    };
}

/// Editor-side live preview. It owns a deterministic clock and a schedule
/// built from the renderer's real step timeline; presentation playback,
/// export, and Presenter never see it.
const StudioMotionPreview = struct {
    schedule: ?motion_schedule.Schedule = null,
    playing: bool = false,
    paused: bool = false,
    looping: bool = false,
    clock: f32 = 0,
    slide: i32 = -1,
    revision: usize = 0,
    morph_state: ?usize = null,
    reveal_step: ?usize = null,

    fn active(self: StudioMotionPreview) bool {
        return self.schedule != null;
    }

    fn stop(self: *StudioMotionPreview, allocator: std.mem.Allocator) void {
        if (self.schedule) |schedule| schedule.deinit(allocator);
        const looping = self.looping;
        self.* = .{ .looping = looping };
    }

    /// Start from the scene Studio currently shows: BASE plays the whole
    /// slide (with its incoming transition when a previous slide exists), a
    /// build scene starts after that build, a state scene starts after it.
    fn start(
        self: *StudioMotionPreview,
        allocator: std.mem.Allocator,
        slide_renderer: *const renderer.SlideshowRenderer,
        slide: i32,
        revision: usize,
        morph_state: ?usize,
        reveal_step: ?usize,
    ) !void {
        self.stop(allocator);
        const steps = slide_renderer.stepsForSlide(slide);
        const start_step: usize = if (morph_state) |state_index|
            slide_renderer.baseRevealStepCount(slide) + state_index + 1
        else
            reveal_step orelse 0;
        const transition: ?animation.Transition = if (start_step == 0 and slide > 0)
            slide_renderer.transitionForSlide(slide)
        else
            null;
        self.schedule = try motion_schedule.build(allocator, steps, .{
            .start_step = start_step,
            .transition = transition,
        });
        self.slide = slide;
        self.revision = revision;
        self.morph_state = morph_state;
        self.reveal_step = reveal_step;
        self.clock = 0;
        self.playing = true;
        self.paused = false;
    }

    fn total(self: StudioMotionPreview) f32 {
        return if (self.schedule) |schedule| schedule.total else 0;
    }

    fn state(self: StudioMotionPreview) ?motion_schedule.State {
        const schedule = self.schedule orelse return null;
        return schedule.stateAt(self.clock);
    }

    fn advance(self: *StudioMotionPreview, frame_time: f32) void {
        if (!self.playing) return;
        const schedule = self.schedule orelse return;
        self.clock += @max(0, frame_time);
        if (self.clock >= schedule.total) {
            if (self.looping) {
                self.clock = 0;
            } else {
                self.clock = schedule.total;
                self.playing = false;
                self.paused = true;
            }
        }
    }

    fn seek(self: *StudioMotionPreview, seconds: f32) void {
        const schedule = self.schedule orelse return;
        self.clock = @max(0, @min(schedule.total, seconds));
        self.playing = false;
        self.paused = true;
    }
};

/// Short author-facing name for timeline cards and badges: the stable ID,
/// otherwise the first text line, otherwise the item kind.
fn studioItemLabel(item: slides.SlideItem) []const u8 {
    if (item.id) |id| return id;
    if (item.text) |text| {
        const first_line = if (std.mem.indexOfScalar(u8, text, '\n')) |newline| text[0..newline] else text;
        const trimmed = std.mem.trim(u8, first_line, " \t\r-> ");
        if (trimmed.len > 0) return trimmed;
    }
    return switch (item.kind) {
        .textbox => if (item.text == null) "Shape" else "Text",
        .img => "Image",
        .vid => "Video",
        .line => "Line",
        .background => "Background",
        .crowd => "Crowdplay",
    };
}

const StudioRevealTarget = struct {
    offset: usize,
    spec: ?animation.ItemSpec,
    text_item: bool,
};

/// Resolve the physical directive that owns a target's reveal. Instances edit
/// their own `@pop`/`@box` line; shared-template members require the explicit
/// shared scope because a slide-instance `@set` cannot carry a reveal.
fn studioRevealTarget(target: studio.CommandTarget, items: []const slides.SlideItem) !StudioRevealTarget {
    const item = studioItemByIdentity(items, target.item_identity) orelse return error.StudioItemMissing;
    if (item.locked) return error.StudioItemLocked;
    if (item.kind == .background) return error.ItemHasNoReveal;
    if (item.creation_morph_state != null) return error.RevealMorphBorn;
    if (target.edit_scope == .shared_template) {
        if (target.source.scope == .none or !target.source.patchable) return error.StudioItemHasNoPatchableSource;
        return .{ .offset = target.source.line_offset, .spec = item.animation, .text_item = item.kind == .textbox and item.text != null };
    }
    switch (item.source.scope) {
        .slide_template, .group_instance_member => return error.RevealSharedTemplate,
        else => {},
    }
    if (item.source.scope == .none or !item.source.patchable) return error.StudioItemHasNoPatchableSource;
    return .{ .offset = item.source.line_offset, .spec = item.animation, .text_item = item.kind == .textbox and item.text != null };
}

fn applyStudioRevealEdit(
    history: *StudioHistory,
    command: studio.ItemRevealCommand,
    items: []const slides.SlideItem,
    selection_ids: *StudioSelectionIds,
) !void {
    var all_have_ids = true;
    for (command.targets.slice()) |target| {
        const item = studioItemByIdentity(items, target.item_identity) orelse return error.StudioItemMissing;
        if (item.id) |id| try selection_ids.appendCopy(id) else all_have_ids = false;
    }
    if (!all_have_ids) selection_ids.clear();
    const patch = try studioRevealPatch(G.allocator, G.editor_memory[0..G.source_len], command, items) orelse return;
    try recordStudioPatch(history, patch);
}

/// Pure source transformation for one reveal command: every target is
/// resolved first (atomic refusal), then patched from the last directive
/// backwards so earlier offsets stay valid. Returns null when nothing
/// changes.
fn studioRevealPatch(
    allocator: std.mem.Allocator,
    original: []const u8,
    command: studio.ItemRevealCommand,
    items: []const slides.SlideItem,
) !?source_editor.PatchResult {
    var resolved: [studio.max_selection_items]StudioRevealTarget = undefined;
    for (command.targets.slice(), 0..) |target, index| {
        resolved[index] = try studioRevealTarget(target, items);
        for (resolved[0..index]) |previous| {
            if (previous.offset == resolved[index].offset) return error.InvalidStudioPropertyBatch;
        }
    }
    const count = command.targets.count;
    // Apply from the last directive backwards so earlier offsets stay valid
    // while decorator lines are inserted or removed.
    var order: [studio.max_selection_items]usize = undefined;
    for (0..count) |index| order[index] = index;
    var sorted: usize = 1;
    while (sorted < count) : (sorted += 1) {
        var moving = sorted;
        while (moving > 0 and resolved[order[moving]].offset > resolved[order[moving - 1]].offset) : (moving -= 1) {
            std.mem.swap(usize, &order[moving], &order[moving - 1]);
        }
    }

    var current: []u8 = try allocator.dupe(u8, original);
    errdefer allocator.free(current);
    var changed = false;
    for (order[0..count]) |index| {
        const target = resolved[index];
        const result: ?source_editor.PatchResult = switch (command.action) {
            .patch => patch: {
                // Line/bullet grouping only means something for text; other
                // kinds always reveal as one item.
                var base = target.spec orelse command.template;
                if (!target.text_item) base.by = .item;
                var spec = studio.applyRevealPatch(base, command.patch);
                if (!target.text_item) spec.by = .item;
                break :patch try source_editor.setItemReveal(allocator, current, target.offset, spec);
            },
            .remove => source_editor.removeItemReveal(allocator, current, target.offset) catch |err| switch (err) {
                error.NoLocalPropertyOverride => if (target.spec != null)
                    try source_editor.setItemReveal(allocator, current, target.offset, .{ .effect = .none })
                else
                    null,
                else => return err,
            },
            .reset => try source_editor.removeItemReveal(allocator, current, target.offset),
        };
        if (result) |patch| {
            allocator.free(current);
            current = patch.source;
            changed = true;
        }
    }
    if (!changed) {
        allocator.free(current);
        return null;
    }
    return .{
        .source = current,
        .byte_delta = @as(isize, @intCast(current.len)) - @as(isize, @intCast(original.len)),
    };
}

test "Studio reveal commands patch every target from the last directive backwards and reparse cleanly" {
    const allocator = std.testing.allocator;
    const source =
        "@push comp x=1 y=1 w=100 h=100 anim=fade\n" ++
        "@slide\n" ++
        "@box id=list x=100 y=100 w=400 h=300\n" ++
        "- one\n" ++
        "- two\n" ++
        "@pop comp id=inherited\n" ++
        "@box id=pic img=a.png x=1 y=1\n";
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const deck = try slides.SlideShow.new(arena.allocator());
    const context = try parser.constructSlidesFromBuf(source, deck, arena.allocator());
    defer context.deinit();
    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    const items = deck.slides.items[0].items.?.items;
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expect(items[1].animation != null); // inherited from @push

    var command: studio.ItemRevealCommand = .{ .action = .patch, .patch = .{ .trigger = .auto }, .template = .{ .effect = .fade, .by = .bullet } };
    for (items, 0..) |item, index| {
        command.targets.targets[index] = .{ .item_identity = item.identity, .source = item.source, .edit_scope = .direct };
    }
    command.targets.count = 3;
    const patched = (try studioRevealPatch(allocator, source, command, items)).?;
    defer patched.deinit(allocator);
    try std.testing.expectEqualStrings(
        "@push comp x=1 y=1 w=100 h=100 anim=fade\n" ++
            "@slide\n" ++
            "@anim(fade) by=bullet delay=0.5 after=0.8\n" ++
            "@box id=list x=100 y=100 w=400 h=300\n" ++
            "- one\n" ++
            "- two\n" ++
            "@anim(fade) delay=0.5 after=0.8\n" ++
            "@pop comp id=inherited\n" ++
            "@anim(fade) delay=0.5 after=0.8\n" ++
            "@box id=pic img=a.png x=1 y=1\n",
        patched.source,
    );
    var after_arena = std.heap.ArenaAllocator.init(allocator);
    defer after_arena.deinit();
    const after_deck = try slides.SlideShow.new(after_arena.allocator());
    const after_context = try parser.constructSlidesFromBuf(patched.source, after_deck, after_arena.allocator());
    defer after_context.deinit();
    try std.testing.expectEqual(@as(usize, 0), after_context.parser_errors.items.len);
    const after_items = after_deck.slides.items[0].items.?.items;
    try std.testing.expectEqual(@as(?f32, 0.5), after_items[0].animation.?.delay);
    try std.testing.expectEqual(animation.Grouping.bullet, after_items[0].animation.?.by);
    try std.testing.expectEqual(@as(?f32, 0.8), after_items[1].animation.?.after);

    // Remove on an inherited-only instance cancels with anim=none; on a
    // direct item it deletes the decorator. Both in one transaction.
    var remove: studio.ItemRevealCommand = .{ .action = .remove };
    remove.targets.targets[0] = .{ .item_identity = items[1].identity, .source = items[1].source, .edit_scope = .direct };
    remove.targets.targets[1] = .{ .item_identity = items[2].identity, .source = items[2].source, .edit_scope = .direct };
    remove.targets.count = 2;
    const removed = (try studioRevealPatch(allocator, source, remove, items)).?;
    defer removed.deinit(allocator);
    try std.testing.expectEqualStrings(
        "@push comp x=1 y=1 w=100 h=100 anim=fade\n" ++
            "@slide\n" ++
            "@box id=list x=100 y=100 w=400 h=300\n" ++
            "- one\n" ++
            "- two\n" ++
            "@anim(none)\n" ++
            "@pop comp id=inherited\n" ++
            "@box id=pic img=a.png x=1 y=1\n",
        removed.source,
    );

    // Morph-born and shared-template items are refused atomically.
    var born_items = [_]slides.SlideItem{items[0]};
    born_items[0].creation_morph_state = 0;
    var born: studio.ItemRevealCommand = .{ .action = .patch };
    born.targets.targets[0] = .{ .item_identity = born_items[0].identity, .source = born_items[0].source };
    born.targets.count = 1;
    try std.testing.expectError(error.RevealMorphBorn, studioRevealPatch(allocator, source, born, &born_items));
    var shared_items = [_]slides.SlideItem{items[0]};
    shared_items[0].source.scope = .slide_template;
    var shared: studio.ItemRevealCommand = .{ .action = .patch };
    shared.targets.targets[0] = .{ .item_identity = shared_items[0].identity, .source = shared_items[0].source };
    shared.targets.count = 1;
    try std.testing.expectError(error.RevealSharedTemplate, studioRevealPatch(allocator, source, shared, &shared_items));
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
    definition: ?StudioDefinitionEditContext,
    clipboard: *StudioClipboard,
    selection_ids: *StudioSelectionIds,
) !StudioSemanticEditResult {
    const slide = slide_opt orelse return error.NoStudioSlide;
    switch (command) {
        .save_document,
        .save_document_copy,
        .undo,
        .redo,
        .edit_source_neovim,
        .pair_presenter_phone,
        .open_document,
        .choose_presentation_display,
        .showtime_preflight,
        .create_portable_show,
        .edit_library_entry,
        .motion_preview,
        => return error.NonSourceStudioCommand,
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
                .image, .video => blk: {
                    const path = prompted_text orelse return error.StudioPromptMissing;
                    break :blk try studioMediaDirective(
                        &directive_buffer,
                        id,
                        if (add.kind == .image) .image else .video,
                        path,
                        add.position,
                        add.suggested_size,
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
                .line, .arrow => blk: {
                    var color_buffer: [9]u8 = undefined;
                    const color = colorLiteral(&color_buffer, studio.paletteColor(add.suggested_color orelse .blue));
                    break :blk try std.fmt.bufPrint(
                        &directive_buffer,
                        "@line id={s} x={d} y={d} w={d} h={d} stroke_width=6 color={s} arrow={s}",
                        .{
                            id,
                            add.position.x,
                            add.position.y,
                            add.suggested_size.x,
                            add.suggested_size.y,
                            color,
                            if (add.kind == .arrow) "end" else "none",
                        },
                    );
                },
            };
            // Structural reparse replaces every runtime identity. Retain the
            // authored ID so ordinary slides select the new item immediately
            // and Definition mode can bind a local GROUP member ID to its
            // qualified preview counterpart on the following frame.
            try selection_ids.appendCopy(id);
            if (add.kind == .text or add.kind == .bullets) {
                const raw_text = prompted_text orelse return error.StudioPromptMissing;
                const owned_text = if (add.kind == .bullets)
                    try normalizeBullets(G.allocator, raw_text)
                else
                    try G.allocator.dupe(u8, raw_text);
                defer G.allocator.free(owned_text);
                const snippet = try itemTextSnippet(G.allocator, directive, owned_text);
                defer G.allocator.free(snippet);
                if (definition) |context| {
                    try recordStudioPatch(history, try source_editor.insertSnippetAt(
                        G.allocator,
                        G.editor_memory[0..G.source_len],
                        try source_editor.itemSceneInsertionOffset(
                            G.editor_memory[0..G.source_len],
                            context.scene,
                        ),
                        snippet,
                    ));
                } else {
                    try insertStudioSnippet(history, slide, morph_state, snippet);
                }
            } else {
                if (definition) |context| {
                    try recordStudioPatch(history, try source_editor.insertSnippetAt(
                        G.allocator,
                        G.editor_memory[0..G.source_len],
                        try source_editor.itemSceneInsertionOffset(
                            G.editor_memory[0..G.source_len],
                            context.scene,
                        ),
                        directive,
                    ));
                } else {
                    try insertStudioSnippet(history, slide, morph_state, directive);
                }
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
            const scene = try studioEditSceneAnchor(slide, morph_state, definition);
            var targets: [studio.max_selection_items]source_editor.DuplicateItemTarget = undefined;
            for (batch.slice(), 0..) |target, index| {
                const item = studioItemByIdentity(items, target.item_identity) orelse return error.StudioItemMissing;
                const definition_shared = definition != null and definition.?.kind == .slide and
                    target.edit_scope == .shared_template;
                if (item.locked or (!definition_shared and target.edit_scope != .direct) or
                    !target.source.patchable)
                {
                    return error.UnsupportedItemDuplication;
                }
                if (definition == null) {
                    if (morph_state) |state_index| {
                        if (!itemBornInMorphState(slide, state_index, item) or item.state_source != null) {
                            return error.MorphItemDuplicationUnsupported;
                        }
                    } else switch (target.source.scope) {
                        .direct, .component_instance => {},
                        else => return error.UnsupportedItemDuplication,
                    }
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
            if (definition) |context| {
                const targets = [_]source_editor.DefinitionDeleteTarget{.{
                    .directive_offset = target.source.line_offset,
                    .item_id = item.id,
                }};
                try recordStudioPatch(history, try source_editor.deleteDefinitionItems(
                    G.allocator,
                    G.editor_memory[0..G.source_len],
                    context.scene,
                    &targets,
                ));
            } else if (morph_state) |state_index| {
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
            const scene = try studioEditSceneAnchor(slide, morph_state, definition);
            if (definition != null) {
                var definition_targets: [studio.max_selection_items]source_editor.DefinitionDeleteTarget = undefined;
                for (batch.slice(), 0..) |target, index| {
                    const item = studioItemByIdentity(items, target.item_identity) orelse
                        return error.StudioItemMissing;
                    if (item.locked or !target.source.patchable) return error.UnsupportedDefinitionStructure;
                    definition_targets[index] = .{
                        .directive_offset = target.source.line_offset,
                        .item_id = item.id,
                    };
                }
                try recordStudioPatch(history, try source_editor.deleteDefinitionItems(
                    G.allocator,
                    G.editor_memory[0..G.source_len],
                    scene,
                    definition_targets[0..batch.count],
                ));
                return .{};
            }
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
        .replace_media => |target| {
            const item = studioItemByIdentity(items, target.item_identity) orelse return error.StudioItemMissing;
            if (item.kind != .img and item.kind != .vid) return error.ItemHasNoEditableMedia;
            if (item.locked) return error.StudioItemLocked;
            const path = try studioMediaSourceValue(prompted_text orelse return error.StudioPromptMissing);
            // A live camera is authored with `cam=`, and writing `vid=` here
            // would leave both keys on the directive. The parser takes the
            // last one, so the device would then be probed as a video file
            // and the item would fail to load.
            try applyStudioLiteralAttribute(
                history,
                slide,
                morph_state,
                item,
                target.edit_scope,
                mediaSourceAttributeKey(item),
                path,
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
            if (item.kind != .textbox and item.kind != .line) return error.ItemHasNoForegroundColor;
            if (item.locked) return error.StudioItemLocked;
            var color_buffer: [9]u8 = undefined;
            const color = colorLiteral(&color_buffer, studio.paletteColor(change.color));
            try applyStudioLiteralAttribute(history, slide, morph_state, item, change.target.edit_scope, "color", color);
            return .{ .preserve_selection = true };
        },
        .set_custom_foreground => |target| {
            const item = studioItemByIdentity(items, target.item_identity) orelse return error.StudioItemMissing;
            if (item.kind != .textbox and item.kind != .line) return error.ItemHasNoForegroundColor;
            if (item.locked) return error.StudioItemLocked;
            var color_buffer: [9]u8 = undefined;
            const color = try canonicalStudioColor(prompted_text orelse return error.StudioPromptMissing, &color_buffer);
            try applyStudioLiteralAttribute(history, slide, morph_state, item, target.edit_scope, "color", color);
            return .{ .preserve_selection = true };
        },
        .set_background => |change| {
            const item = studioItemByIdentity(items, change.target.item_identity) orelse return error.StudioItemMissing;
            if (item.kind == .background or item.kind == .line) return error.ItemHasNoBackgroundColor;
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
            if (item.kind == .background or item.kind == .line) return error.ItemHasNoBackgroundColor;
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
        .set_corner_radius => |target| {
            const item = studioItemByIdentity(items, target.item_identity) orelse return error.StudioItemMissing;
            if (item.kind != .textbox or item.text != null) return error.ItemHasNoCornerRadius;
            if (item.locked) return error.StudioItemLocked;
            const radius = try parseStudioFiniteFloat(prompted_text orelse return error.StudioPromptMissing);
            if (radius < 0) return error.InvalidStudioCornerRadius;
            var value_buffer: [64]u8 = undefined;
            const value = try formatStudioFloat(&value_buffer, radius);
            try applyStudioLiteralAttribute(history, slide, morph_state, item, target.edit_scope, "radius", value);
            return .{ .preserve_selection = true };
        },
        .set_line_width => |target| {
            const item = studioItemByIdentity(items, target.item_identity) orelse return error.StudioItemMissing;
            if (item.kind != .line) return error.ItemHasNoLineWidth;
            if (item.locked) return error.StudioItemLocked;
            const width = try parseStudioFiniteFloat(prompted_text orelse return error.StudioPromptMissing);
            if (width <= 0) return error.InvalidStudioLineWidth;
            var value_buffer: [64]u8 = undefined;
            const value = try formatStudioFloat(&value_buffer, width);
            try applyStudioLiteralAttribute(history, slide, morph_state, item, target.edit_scope, "stroke_width", value);
            return .{ .preserve_selection = true };
        },
        .set_line_style => |change| {
            const item = studioItemByIdentity(items, change.target.item_identity) orelse return error.StudioItemMissing;
            if (item.kind != .line) return error.ItemHasNoLineStyle;
            if (item.locked) return error.StudioItemLocked;
            const shared = if (change.target.edit_scope == .shared_template) item.sharedTemplateValues() else null;
            switch (change.change) {
                .direction => |direction| {
                    const current = if (shared) |values| values.line_direction else item.line_direction;
                    if (current == direction) return .{ .source_changed = false, .preserve_selection = true };
                    try applyStudioLiteralAttribute(
                        history,
                        slide,
                        morph_state,
                        item,
                        change.target.edit_scope,
                        "direction",
                        if (direction == .down) "down" else "up",
                    );
                },
                .arrow_start, .arrow_end => {
                    var start = if (shared) |values| values.line_arrow_start else item.line_arrow_start;
                    var end = if (shared) |values| values.line_arrow_end else item.line_arrow_end;
                    switch (change.change) {
                        .arrow_start => |enabled| start = enabled,
                        .arrow_end => |enabled| end = enabled,
                        .direction => unreachable,
                    }
                    const current_start = if (shared) |values| values.line_arrow_start else item.line_arrow_start;
                    const current_end = if (shared) |values| values.line_arrow_end else item.line_arrow_end;
                    if (current_start == start and current_end == end)
                        return .{ .source_changed = false, .preserve_selection = true };
                    const value: []const u8 = if (start and end)
                        "both"
                    else if (start)
                        "start"
                    else if (end)
                        "end"
                    else
                        "none";
                    try applyStudioLiteralAttribute(history, slide, morph_state, item, change.target.edit_scope, "arrow", value);
                },
            }
            return .{ .preserve_selection = true };
        },
        .set_rotation => |change| {
            const item = studioItemByIdentity(items, change.target.item_identity) orelse return error.StudioItemMissing;
            if (!studioRotationEligible(item.*)) return error.ItemHasNoRotation;
            if (item.locked) return error.StudioItemLocked;
            const rotation = if (change.value) |value|
                value
            else
                try parseStudioFiniteFloat(prompted_text orelse return error.StudioPromptMissing);
            if (!std.math.isFinite(rotation)) return error.InvalidStudioRotation;
            const current = if (change.target.edit_scope == .shared_template)
                if (item.sharedTemplateValues()) |shared| shared.rotation else item.rotation
            else
                item.rotation;
            if (@abs(current - rotation) <= 0.000001)
                return .{ .source_changed = false, .preserve_selection = true };
            var value_buffer: [64]u8 = undefined;
            const value = try formatStudioFloat(&value_buffer, rotation);
            try applyStudioLiteralAttribute(history, slide, morph_state, item, change.target.edit_scope, "rotation", value);
            return .{ .preserve_selection = true };
        },
        .set_text_alignment => |change| {
            const item = studioItemByIdentity(items, change.target.item_identity) orelse return error.StudioItemMissing;
            if (item.kind != .textbox) return error.ItemHasNoFontSize;
            if (item.locked) return error.StudioItemLocked;
            const key: []const u8 = switch (change.change) {
                .horizontal => "align",
                .vertical => "valign",
            };
            const value: []const u8 = switch (change.change) {
                .horizontal => |alignment| switch (alignment) {
                    .left => "left",
                    .center => "center",
                    .right => "right",
                },
                .vertical => |alignment| switch (alignment) {
                    .top => "top",
                    .middle => "middle",
                    .bottom => "bottom",
                },
            };
            try applyStudioLiteralAttribute(history, slide, morph_state, item, change.target.edit_scope, key, value);
            return .{ .preserve_selection = true };
        },
        .set_common_property => |change| {
            if (change.targets.count < 2 or change.targets.count > studio.max_selection_items)
                return error.InvalidStudioPropertyBatch;

            for (change.targets.slice()) |target| {
                const item = studioItemByIdentity(items, target.item_identity) orelse return error.StudioItemMissing;
                if (item.locked) return error.StudioItemLocked;
                const compatible = switch (change.property) {
                    .x, .y, .width, .height, .opacity => item.kind != .background,
                    .rotation => studioRotationEligible(item.*),
                    .background => item.kind != .background and item.kind != .line,
                    .foreground => item.kind == .textbox or item.kind == .line,
                    .font_size, .text_alignment, .text_vertical_alignment => item.kind == .textbox,
                    .corner_radius => item.kind == .textbox and item.text == null,
                    .line_width => item.kind == .line,
                    .media_fit, .media_focus_x, .media_focus_y => item.kind == .img or item.kind == .vid,
                    .video_poster, .video_volume, .video_autoplay, .video_loop, .video_muted => item.kind == .vid,
                };
                if (!compatible) return error.IncompatibleStudioPropertyBatch;
            }

            const key: []const u8 = switch (change.property) {
                .x => "x",
                .y => "y",
                .width => "w",
                .height => "h",
                .foreground => "color",
                .background => "bg",
                .font_size => "fontsize",
                .corner_radius => "radius",
                .line_width => "stroke_width",
                .rotation => "rotation",
                .opacity => "opacity",
                .text_alignment => "align",
                .text_vertical_alignment => "valign",
                .media_fit => "fit",
                .media_focus_x => "focus_x",
                .media_focus_y => "focus_y",
                .video_poster => "poster",
                .video_volume => "volume",
                .video_autoplay => "autoplay",
                .video_loop => "loop",
                .video_muted => "muted",
            };
            var value_buffer: [64]u8 = undefined;
            var color_buffer: [9]u8 = undefined;
            const raw = change.value;
            const value: []const u8 = switch (change.property) {
                .x, .y => try formatStudioFloat(&value_buffer, try parseStudioFiniteFloat(raw)),
                .width, .height => value: {
                    const parsed = try parseStudioFiniteFloat(raw);
                    if (parsed < studio.default_min_item_size) return error.InvalidStudioDimension;
                    break :value try formatStudioFloat(&value_buffer, parsed);
                },
                .foreground => try canonicalStudioColor(raw, &color_buffer),
                .background => if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, raw, " \t\r\n"), "none"))
                    "none"
                else
                    try canonicalStudioColor(raw, &color_buffer),
                .font_size => try canonicalStudioFontSize(raw, &value_buffer),
                .corner_radius => radius: {
                    const parsed = try parseStudioFiniteFloat(raw);
                    if (parsed < 0) return error.InvalidStudioCornerRadius;
                    break :radius try formatStudioFloat(&value_buffer, parsed);
                },
                .line_width => width: {
                    const parsed = try parseStudioFiniteFloat(raw);
                    if (parsed <= 0) return error.InvalidStudioLineWidth;
                    break :width try formatStudioFloat(&value_buffer, parsed);
                },
                .rotation => try formatStudioFloat(&value_buffer, try parseStudioFiniteFloat(raw)),
                .opacity => try canonicalStudioOpacity(raw, &value_buffer),
                .media_focus_x, .media_focus_y, .video_volume => try canonicalStudioUnitInterval(raw, &value_buffer),
                .video_poster => try canonicalStudioVideoPoster(raw, &value_buffer),
                .text_alignment => if (std.mem.eql(u8, raw, "left") or std.mem.eql(u8, raw, "center") or std.mem.eql(u8, raw, "right"))
                    raw
                else
                    return error.InvalidStudioCommonProperty,
                .text_vertical_alignment => if (std.mem.eql(u8, raw, "top") or std.mem.eql(u8, raw, "middle") or std.mem.eql(u8, raw, "bottom"))
                    raw
                else
                    return error.InvalidStudioCommonProperty,
                .media_fit => if (std.mem.eql(u8, raw, "stretch") or std.mem.eql(u8, raw, "contain") or std.mem.eql(u8, raw, "cover"))
                    raw
                else
                    return error.InvalidStudioCommonProperty,
                .video_autoplay, .video_loop, .video_muted => if (std.mem.eql(u8, raw, "true") or std.mem.eql(u8, raw, "false"))
                    raw
                else
                    return error.InvalidStudioCommonProperty,
            };
            try applyStudioLiteralAttributeBatch(
                history,
                change.targets.slice(),
                slide,
                morph_state,
                items,
                key,
                value,
            );
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
        .set_media_fit => |change| {
            const item = studioItemByIdentity(items, change.target.item_identity) orelse return error.StudioItemMissing;
            if (item.kind != .img and item.kind != .vid) return error.ItemHasNoEditableMedia;
            if (item.locked) return error.StudioItemLocked;
            const current = if (change.target.edit_scope == .shared_template)
                if (item.sharedTemplateValues()) |shared| shared.media_fit else item.media_fit
            else
                item.media_fit;
            if (current == change.fit) return .{ .source_changed = false, .preserve_selection = true };
            const value: []const u8 = switch (change.fit) {
                .stretch => "stretch",
                .contain => "contain",
                .cover => "cover",
            };
            try applyStudioLiteralAttribute(history, slide, morph_state, item, change.target.edit_scope, "fit", value);
            return .{ .preserve_selection = true };
        },
        .set_media_focus => |change| {
            const item = studioItemByIdentity(items, change.target.item_identity) orelse return error.StudioItemMissing;
            if (item.kind != .img and item.kind != .vid) return error.ItemHasNoEditableMedia;
            if (item.locked) return error.StudioItemLocked;
            var value_buffer: [64]u8 = undefined;
            const value = try canonicalStudioUnitInterval(prompted_text orelse return error.StudioPromptMissing, &value_buffer);
            try applyStudioLiteralAttribute(
                history,
                slide,
                morph_state,
                item,
                change.target.edit_scope,
                if (change.axis == .x) "focus_x" else "focus_y",
                value,
            );
            return .{ .preserve_selection = true };
        },
        .replace_camera_poster => |target| {
            const item = studioItemByIdentity(items, target.item_identity) orelse return error.StudioItemMissing;
            if (item.kind != .vid or !item.vid_is_camera) return error.ItemHasNoEditableMedia;
            if (item.locked) return error.StudioItemLocked;
            const path = try studioMediaSourceValue(prompted_text orelse return error.StudioPromptMissing);
            try applyStudioLiteralAttribute(history, slide, morph_state, item, target.edit_scope, "poster_image", path);
            return .{ .preserve_selection = true };
        },
        .set_camera_format => |change| {
            const item = studioItemByIdentity(items, change.target.item_identity) orelse return error.StudioItemMissing;
            if (item.kind != .vid or !item.vid_is_camera) return error.ItemHasNoEditableMedia;
            if (item.locked) return error.StudioItemLocked;
            const current = if (change.target.edit_scope == .shared_template)
                if (item.sharedTemplateValues()) |shared| shared.vid_camera_format else item.vid_camera_format
            else
                item.vid_camera_format;
            if (current == change.format) return .{ .source_changed = false, .preserve_selection = true };
            try applyStudioLiteralAttribute(history, slide, morph_state, item, change.target.edit_scope, "cam_format", change.format.attrValue());
            return .{ .preserve_selection = true };
        },
        .set_camera_size => |change| {
            const item = studioItemByIdentity(items, change.target.item_identity) orelse return error.StudioItemMissing;
            if (item.kind != .vid or !item.vid_is_camera) return error.ItemHasNoEditableMedia;
            if (item.locked) return error.StudioItemLocked;
            var value_buffer: [64]u8 = undefined;
            const value = try canonicalStudioCameraSize(prompted_text orelse return error.StudioPromptMissing, &value_buffer);
            const current = if (change.target.edit_scope == .shared_template)
                if (item.sharedTemplateValues()) |shared| shared.vid_camera_size else item.vid_camera_size
            else
                item.vid_camera_size;
            var current_buffer: [64]u8 = undefined;
            const current_value = try std.fmt.bufPrint(&current_buffer, "{d}x{d}", .{
                @as(i32, @intFromFloat(current.x)),
                @as(i32, @intFromFloat(current.y)),
            });
            if (std.mem.eql(u8, current_value, value)) return .{ .source_changed = false, .preserve_selection = true };
            try applyStudioLiteralAttribute(history, slide, morph_state, item, change.target.edit_scope, "video_size", value);
            return .{ .preserve_selection = true };
        },
        .set_video_poster => |change| {
            const item = studioItemByIdentity(items, change.target.item_identity) orelse return error.StudioItemMissing;
            if (item.kind != .vid) return error.ItemHasNoEditableMedia;
            if (item.locked) return error.StudioItemLocked;
            const poster = if (change.value) |value| value else try parseStudioFiniteFloat(prompted_text orelse return error.StudioPromptMissing);
            if (!std.math.isFinite(poster) or poster < 0) return error.InvalidStudioVideoPoster;
            if (studioResolvedBoundsByIdentity(resolved_bounds, item.identity)) |bounds| {
                if (bounds.media_duration > 0 and poster > bounds.media_duration + 0.001)
                    return error.InvalidStudioVideoPoster;
            }
            const current = if (change.target.edit_scope == .shared_template)
                if (item.sharedTemplateValues()) |shared| shared.vid_poster orelse 0 else item.vid_poster orelse 0
            else
                item.vid_poster orelse 0;
            if (@abs(current - poster) <= 0.000001) return .{ .source_changed = false, .preserve_selection = true };
            var value_buffer: [64]u8 = undefined;
            const value = try formatStudioFloat(&value_buffer, poster);
            try applyStudioLiteralAttribute(history, slide, morph_state, item, change.target.edit_scope, "poster", value);
            return .{ .preserve_selection = true };
        },
        .set_video_volume => |change| {
            const item = studioItemByIdentity(items, change.target.item_identity) orelse return error.StudioItemMissing;
            if (item.kind != .vid) return error.ItemHasNoEditableMedia;
            if (item.locked) return error.StudioItemLocked;
            const volume = if (change.value) |value| value else try parseStudioFiniteFloat(prompted_text orelse return error.StudioPromptMissing);
            if (!std.math.isFinite(volume) or volume < 0 or volume > 1) return error.InvalidStudioUnitInterval;
            const current = if (change.target.edit_scope == .shared_template)
                if (item.sharedTemplateValues()) |shared| shared.vid_volume else item.vid_volume
            else
                item.vid_volume;
            if (@abs(current - volume) <= 0.000001) return .{ .source_changed = false, .preserve_selection = true };
            var value_buffer: [64]u8 = undefined;
            const value = try formatStudioFloat(&value_buffer, volume);
            try applyStudioLiteralAttribute(history, slide, morph_state, item, change.target.edit_scope, "volume", value);
            return .{ .preserve_selection = true };
        },
        .set_video_toggle => |change| {
            const item = studioItemByIdentity(items, change.target.item_identity) orelse return error.StudioItemMissing;
            if (item.kind != .vid) return error.ItemHasNoEditableMedia;
            if (item.locked) return error.StudioItemLocked;
            const shared = if (change.target.edit_scope == .shared_template) item.sharedTemplateValues() else null;
            const current = switch (change.property) {
                .autoplay => if (shared) |values| values.vid_autoplay else item.vid_autoplay,
                .loop => if (shared) |values| values.vid_loop else item.vid_loop,
                .muted => if (shared) |values| values.vid_muted else item.vid_muted,
            };
            if (current == change.enabled) return .{ .source_changed = false, .preserve_selection = true };
            const key: []const u8 = switch (change.property) {
                .autoplay => "autoplay",
                .loop => "loop",
                .muted => "muted",
            };
            try applyStudioLiteralAttribute(
                history,
                slide,
                morph_state,
                item,
                change.target.edit_scope,
                key,
                if (change.enabled) "true" else "false",
            );
            return .{ .preserve_selection = true };
        },
        .clear_background => |target| {
            const item = studioItemByIdentity(items, target.item_identity) orelse return error.StudioItemMissing;
            if (item.kind == .background or item.kind == .line) return error.ItemHasNoBackgroundColor;
            if (item.locked) return error.StudioItemLocked;
            try applyStudioLiteralAttribute(history, slide, morph_state, item, target.edit_scope, "bg", "none");
            return .{ .preserve_selection = true };
        },
        .reorder_items => |layer| {
            if (layer.count == 0 or layer.count > studio.max_selection_items) return error.InvalidStudioLayerBatch;
            if (layerCommandCrossesLocked(layer, items)) return error.LockedLayerBarrier;
            const scene = try studioEditSceneAnchor(slide, morph_state, definition);
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
            const scene = try studioEditSceneAnchor(slide, morph_state, definition);
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
        .set_morph_state_timing => |timing| {
            if (timing.state_index >= slide.morph_states.items.len) return error.InvalidMorphState;
            const state = slide.morph_states.items[timing.state_index];
            var changed = false;
            if (timing.after) |after| changed = changed or !std.meta.eql(state.spec.after, after);
            if (timing.duration) |duration| changed = changed or state.spec.duration != duration;
            if (timing.easing) |easing| changed = changed or state.spec.easing != easing;
            if (!changed) return .{ .source_changed = false, .morph_scene = .{ .active_state = timing.state_index }, .preserve_selection = true };
            try recordStudioPatch(history, try source_editor.setMorphStateTiming(
                G.allocator,
                G.editor_memory[0..G.source_len],
                slide.pos_in_editor,
                state.source.line_offset,
                .{ .after = timing.after, .duration = timing.duration, .easing = timing.easing },
            ));
            history.setLatestMorphScenes(morph_state, timing.state_index);
            return .{ .morph_scene = .{ .active_state = timing.state_index }, .preserve_selection = true };
        },
        .clear_morph_state_label => |state_index| {
            if (state_index >= slide.morph_states.items.len) return error.InvalidMorphState;
            const state = slide.morph_states.items[state_index];
            if (state.spec.label == null) return .{ .source_changed = false, .morph_scene = .{ .active_state = state_index }, .preserve_selection = true };
            const keys = [_][]const u8{"label"};
            try recordStudioPatch(history, try source_editor.removeLiteralAttributes(
                G.allocator,
                G.editor_memory[0..G.source_len],
                state.source.line_offset,
                &keys,
            ));
            history.setLatestMorphScenes(morph_state, state_index);
            return .{ .morph_scene = .{ .active_state = state_index }, .preserve_selection = true };
        },
        .reset_morph_object => |target| {
            const state_index = morph_state orelse return error.InvalidMorphState;
            if (state_index >= slide.morph_states.items.len) return error.InvalidMorphState;
            const item = studioItemByIdentity(items, target.item_identity) orelse return error.StudioItemMissing;
            const id = item.id orelse return error.MorphItemNeedsId;
            if (item.id) |value| try selection_ids.appendCopy(value);
            try recordStudioPatch(history, try source_editor.deleteMorphMutationsForItem(
                G.allocator,
                G.editor_memory[0..G.source_len],
                slide.pos_in_editor,
                slide.morph_states.items[state_index].source.line_offset,
                id,
            ));
            history.setLatestMorphScenes(morph_state, state_index);
            return .{ .morph_scene = .{ .active_state = state_index }, .preserve_selection = true };
        },
        .exit_morph_object => |exit| {
            const state_index = morph_state orelse return error.InvalidMorphState;
            if (state_index >= slide.morph_states.items.len) return error.InvalidMorphState;
            const item = studioItemByIdentity(items, exit.target.item_identity) orelse return error.StudioItemMissing;
            if (item.locked) return error.StudioItemLocked;
            const id = item.id orelse return error.MorphItemNeedsId;
            try selection_ids.appendCopy(id);
            const geometry = studio.itemGeometry(item.*, resolved_bounds);
            const margin: f32 = 100;
            var directive_buffer: [160]u8 = undefined;
            const directive = switch (exit.direction) {
                .left => try std.fmt.bufPrint(&directive_buffer, "@hide {s} x={d}", .{ id, -(geometry.size.x + margin) }),
                .right => try std.fmt.bufPrint(&directive_buffer, "@hide {s} x={d}", .{ id, studio.default_logical_size.x + margin }),
                .up => try std.fmt.bufPrint(&directive_buffer, "@hide {s} y={d}", .{ id, -(geometry.size.y + margin) }),
                .down => try std.fmt.bufPrint(&directive_buffer, "@hide {s} y={d}", .{ id, studio.default_logical_size.y + margin }),
            };
            const state_offset = slide.morph_states.items[state_index].source.line_offset;
            const insertion = try source_editor.morphStateEndOffset(G.editor_memory[0..G.source_len], state_offset);
            try recordStudioPatch(history, try source_editor.insertDirectiveAt(
                G.allocator,
                G.editor_memory[0..G.source_len],
                insertion,
                directive,
            ));
            history.setLatestMorphScenes(morph_state, state_index);
            return .{ .morph_scene = .{ .active_state = state_index }, .preserve_selection = true };
        },
        .set_slide_transition => |change| {
            const source = G.editor_memory[0..G.source_len];
            const anchor_name = source_editor.directiveNameAt(source, slide.pos_in_editor) orelse return error.TransitionNeedsSlideDirective;
            if (!(std.mem.eql(u8, anchor_name, "@slide") or std.mem.eql(u8, anchor_name, "@popslide"))) return error.TransitionNeedsSlideDirective;
            var anchor_offset = slide.pos_in_editor;
            if (change.shared) {
                const template_name = source_editor.slideAnchorTemplateName(source, slide.pos_in_editor) orelse return error.TransitionSharedUnavailable;
                const catalog = catalog_opt orelse return error.TransitionSharedUnavailable;
                var found: ?usize = null;
                for (catalog.entries, 0..) |entry, catalog_index| {
                    if (entry.kind != .slide or !std.mem.eql(u8, entry.name, template_name)) continue;
                    if (!catalog.isVisibleAt(catalog_index, slide.pos_in_editor)) continue;
                    found = entry.directive_offset;
                }
                anchor_offset = found orelse return error.TransitionSharedUnavailable;
            }
            if (change.inherit) {
                try recordStudioPatch(history, try source_editor.removeSlideTransition(G.allocator, source, anchor_offset));
                return .{ .preserve_selection = true };
            }
            var transition = if (slide.transition_authored or G.slideshow.has_default_transition) slide.transition else animation.Transition{};
            if (change.effect) |effect| {
                transition.effect = effect;
                if (transition.effect != .none and !slide.transition_authored and !G.slideshow.has_default_transition) {
                    transition.duration = (animation.Transition{}).duration;
                    transition.easing = .smooth;
                }
            }
            if (change.duration) |duration| transition.duration = duration;
            if (change.easing) |easing| transition.easing = easing;
            if (!change.shared and std.meta.eql(transition, slide.transition) and
                source_editor.directiveHasAttribute(source, anchor_offset, "transition"))
            {
                return .{ .source_changed = false, .preserve_selection = true };
            }
            try recordStudioPatch(history, try source_editor.setSlideTransition(G.allocator, source, anchor_offset, transition));
            return .{ .preserve_selection = true };
        },
        .set_deck_transition => |defaults| {
            try recordStudioPatch(history, try source_editor.setDeckTransitionDefaults(
                G.allocator,
                G.editor_memory[0..G.source_len],
                defaults,
            ));
            return .{ .preserve_selection = true };
        },
        .move_reveal_build => |move| {
            if (morph_state != null) return error.RevealSceneRequired;
            const builds = G.slide_renderer.revealBuilds(G.current_slide);
            if (builds.len < 2) return .{ .source_changed = false, .preserve_selection = true };
            var from: ?usize = null;
            for (builds, 0..) |build, index| if (build.owner_identity == move.owner_identity) {
                from = index;
            };
            const from_index = from orelse return error.StudioItemMissing;
            const to_index: usize = switch (move.direction) {
                .earlier => if (from_index == 0) return .{ .source_changed = false, .preserve_selection = true } else from_index - 1,
                .later => if (from_index + 1 >= builds.len) return .{ .source_changed = false, .preserve_selection = true } else from_index + 1,
            };
            if (builds.len > studio.max_selection_items) return error.InvalidStudioPropertyBatch;

            // Desired sequence: swap the two builds.
            var sequence: [studio.max_selection_items]usize = undefined;
            for (0..builds.len) |index| sequence[index] = index;
            std.mem.swap(usize, &sequence[from_index], &sequence[to_index]);
            var positions: [studio.max_selection_items]usize = undefined;
            var owners: [studio.max_selection_items]*const slides.SlideItem = undefined;
            for (sequence[0..builds.len], 0..) |build_index, slot| {
                const item = studioItemByIdentity(items, builds[build_index].owner_identity) orelse return error.StudioItemMissing;
                if (item.locked) return error.StudioItemLocked;
                if (item.source.scope == .none or !item.source.patchable) return error.StudioItemHasNoPatchableSource;
                if (item.source.scope == .slide_template or item.source.scope == .group_instance_member) return error.RevealSharedTemplate;
                owners[slot] = item;
                positions[slot] = item.source.line_offset;
            }
            var orders: [studio.max_selection_items]i32 = undefined;
            revealOrderAssignments(positions[0..builds.len], orders[0..builds.len]);

            // Apply from the last directive backwards so offsets stay valid.
            var apply_order: [studio.max_selection_items]usize = undefined;
            for (0..builds.len) |slot| apply_order[slot] = slot;
            var sorted: usize = 1;
            while (sorted < builds.len) : (sorted += 1) {
                var moving = sorted;
                while (moving > 0 and positions[apply_order[moving]] > positions[apply_order[moving - 1]]) : (moving -= 1) {
                    std.mem.swap(usize, &apply_order[moving], &apply_order[moving - 1]);
                }
            }
            const original = G.editor_memory[0..G.source_len];
            var current: []u8 = try G.allocator.dupe(u8, original);
            errdefer G.allocator.free(current);
            var changed = false;
            for (apply_order[0..builds.len]) |slot| {
                const item = owners[slot];
                const spec = item.animation orelse continue;
                if (spec.order == orders[slot]) continue;
                var updated = spec;
                updated.order = orders[slot];
                const patch = try source_editor.setItemReveal(G.allocator, current, item.source.line_offset, updated);
                G.allocator.free(current);
                current = patch.source;
                changed = true;
            }
            if (!changed) {
                G.allocator.free(current);
                return .{ .source_changed = false, .preserve_selection = true };
            }
            try recordStudioPatch(history, .{
                .source = current,
                .byte_delta = @as(isize, @intCast(current.len)) - @as(isize, @intCast(original.len)),
            });
            return .{ .preserve_selection = true };
        },
        .set_item_reveal => |reveal| {
            if (morph_state != null) return error.RevealSceneRequired;
            if (reveal.targets.count == 0 or reveal.targets.count > studio.max_selection_items)
                return error.InvalidStudioPropertyBatch;
            try applyStudioRevealEdit(history, reveal, items, selection_ids);
            return .{ .preserve_selection = true };
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
            const property = inheritedPropertyForStudioProperty(reset.property, item.vid_is_camera);
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
            const insertion_offset = if (definition) |context|
                try source_editor.itemSceneInsertionOffset(G.editor_memory[0..G.source_len], context.scene)
            else
                try studioItemInsertionOffset(slide, morph_state);
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
            if (definition == null and morph_state != null) return error.UnsupportedGroupInstance;
            const entry = studioLibraryEntry(catalog_opt, catalog_indices, workspace_index) orelse
                return error.StudioLibraryEntryMissing;
            if (entry.kind != .group) return error.StudioLibraryEntryMissing;
            var instance_buffer: [64]u8 = undefined;
            const instance_id = try nextStudioItemId(&instance_buffer);
            try recordStudioPatch(history, try source_editor.insertReusableGroupInstance(
                G.allocator,
                G.editor_memory[0..G.source_len],
                try studioEditSceneAnchor(slide, null, definition),
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

/// Attribute keys of one `@set/@show/@hide` line, comma-separated, for the
/// State section. Truncated summaries end with an ellipsis.
fn studioMutationKeys(source: []const u8, offset: usize, buffer: *[48]u8) u8 {
    if (offset >= source.len or source[offset] != '@') return 0;
    const line_end = std.mem.indexOfScalarPos(u8, source, offset, '\n') orelse source.len;
    var tokens = std.mem.tokenizeAny(u8, source[offset..line_end], " \t\r");
    _ = tokens.next(); // directive
    _ = tokens.next(); // target id
    var len: usize = 0;
    while (tokens.next()) |token| {
        const equals = std.mem.indexOfScalar(u8, token, '=') orelse continue;
        const key = token[0..equals];
        const needed = key.len + @as(usize, if (len > 0) 2 else 0);
        if (len + needed > buffer.len - 1) {
            if (len + 1 <= buffer.len) {
                buffer[len] = '~';
                len += 1;
            }
            break;
        }
        if (len > 0) {
            buffer[len] = ',';
            buffer[len + 1] = ' ';
            len += 2;
        }
        @memcpy(buffer[len .. len + key.len], key);
        len += key.len;
        if (std.mem.eql(u8, key, "text")) break;
    }
    return @intCast(len);
}

fn collectStudioStateChanges(
    output: *std.ArrayList(studio.StateChangeSummary),
    allocator: std.mem.Allocator,
    slide: *const slides.Slide,
    state_index: usize,
    items: []const slides.SlideItem,
) !void {
    output.clearRetainingCapacity();
    const source = G.editor_memory[0..G.source_len];
    for (items) |item| {
        if (item.kind == .background) continue;
        const born = item.creation_morph_state != null and item.creation_morph_state.? == state_index;
        const mutated = item.state_source_state != null and item.state_source_state.? == state_index;
        if (!born and !mutated) continue;
        var summary: studio.StateChangeSummary = .{
            .identity = item.identity,
            .label = studioItemLabel(item),
            .kind = .changed,
            .cross_fades = G.slide_renderer.morphOwnerCrossFades(G.current_slide, state_index, item.identity),
        };
        if (born) {
            summary.kind = .born;
        } else if (item.state_source) |mutation| {
            summary.keys_len = studioMutationKeys(source, mutation.line_offset, &summary.keys);
            const line_end = std.mem.indexOfScalarPos(u8, source, mutation.line_offset, '\n') orelse source.len;
            const line = source[@min(mutation.line_offset, source.len)..line_end];
            if (std.mem.startsWith(u8, line, "@hide")) summary.kind = .hidden else if (std.mem.startsWith(u8, line, "@show")) summary.kind = .shown;
        }
        try output.append(allocator, summary);
    }
    _ = slide;
}

fn collectStudioBounds(
    output: *std.ArrayList(studio.ResolvedBounds),
    render_bounds: *std.ArrayList(renderer.SlideshowRenderer.ItemRenderBounds),
    allocator: std.mem.Allocator,
    slide_number: i32,
    morph_state: ?usize,
    items: []const slides.SlideItem,
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
            .natural_size = entry.natural_size,
            .media_duration = entry.media_duration,
            .media_availability = entry.media_availability,
            .media_audio = entry.media_audio,
        });
    }
    try appendStudioUnavailableMediaBounds(output, allocator, items);
    return fragment_count;
}

fn collectStudioDefinitionBounds(
    output: *std.ArrayList(studio.ResolvedBounds),
    render_bounds: *std.ArrayList(renderer.SlideshowRenderer.ItemRenderBounds),
    allocator: std.mem.Allocator,
    items: []const slides.SlideItem,
) !usize {
    output.clearRetainingCapacity();
    const fragment_count = try G.slide_renderer.collectStudioPreviewBounds(allocator, render_bounds);
    try output.ensureUnusedCapacity(allocator, render_bounds.items.len);
    for (render_bounds.items) |entry| {
        const bounds = entry.bounds;
        try output.append(allocator, .{
            .identity = entry.owner_identity,
            .position = .{ .x = bounds.x, .y = bounds.y },
            .size = .{ .x = bounds.width, .y = bounds.height },
            .natural_size = entry.natural_size,
            .media_duration = entry.media_duration,
            .media_availability = entry.media_availability,
            .media_audio = entry.media_audio,
        });
    }
    try appendStudioUnavailableMediaBounds(output, allocator, items);
    return fragment_count;
}

fn unavailableMediaGeometry(item: slides.SlideItem) studio.Geometry {
    const fallback: rl.Vector2 = .{ .x = 640, .y = 360 };
    var size = item.size;
    if (size.x <= 0 and size.y <= 0) {
        size = fallback;
    } else if (size.x <= 0) {
        size.x = size.y * fallback.x / fallback.y;
    } else if (size.y <= 0) {
        size.y = size.x * fallback.y / fallback.x;
    }
    return .{ .position = item.position, .size = size };
}

fn appendStudioUnavailableMediaBounds(
    output: *std.ArrayList(studio.ResolvedBounds),
    allocator: std.mem.Allocator,
    items: []const slides.SlideItem,
) !void {
    for (items) |item| {
        if (item.kind != .img and item.kind != .vid) continue;
        if (studioResolvedBoundsByIdentity(output.items, item.identity) != null) continue;
        const geometry = unavailableMediaGeometry(item);
        try output.append(allocator, .{
            .identity = item.identity,
            .position = geometry.position,
            .size = geometry.size,
            .media_availability = if (item.kind == .img) .image_unavailable else .video_unavailable,
        });
    }
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
