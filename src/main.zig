const std = @import("std");
const builtin = @import("builtin");
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
const source_editor = @import("source_editor.zig");
const studio = @import("studio.zig");
const studio_catalog = @import("studio_catalog.zig");
const studio_prompt = @import("studio_prompt.zig");
const studio_roundtrip_test = @import("studio_roundtrip_test.zig");
const SlideShow = slides.SlideShow;

comptime {
    if (studio.max_selection_items > renderer.max_item_geometry_previews)
        @compileError("Studio selection capacity exceeds renderer preview capacity");
}

const log = std.log.scoped(.main);

test {
    std.testing.refAllDecls(parser);
    std.testing.refAllDecls(renderer);
    std.testing.refAllDecls(slides);
    std.testing.refAllDecls(source_editor);
    std.testing.refAllDecls(studio);
    std.testing.refAllDecls(studio_catalog);
    std.testing.refAllDecls(studio_prompt);
    std.testing.refAllDecls(studio_roundtrip_test);
}

const CrowdOptions = struct {
    enabled: bool = true,
    host: []const u8 = "localhost",
    host_explicit: bool = false,
    port: u16 = 7331,
};

const SourceChange = struct {
    before: []u8,
    after: []u8,
    before_slide: i32,
    after_slide: i32,
};

const SourceRestore = struct {
    source: []const u8,
    slide: i32,
};

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
        // Reserve before mutating redo ownership. If allocation fails, the
        // caller can roll the source back without silently losing redo.
        if (self.undo_stack.items.len < max_entries) {
            try self.undo_stack.ensureUnusedCapacity(self.allocator, 1);
        }
        self.clearStack(&self.redo_stack);
        if (self.undo_stack.items.len == max_entries) {
            const oldest = self.undo_stack.orderedRemove(0);
            self.allocator.free(oldest.before);
            self.allocator.free(oldest.after);
        }
        try self.undo_stack.append(self.allocator, .{
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

    fn undo(self: *StudioHistory) !?SourceRestore {
        const entry = self.undo_stack.pop() orelse return null;
        errdefer self.undo_stack.append(self.allocator, entry) catch {};
        try self.redo_stack.append(self.allocator, entry);
        return .{ .source = entry.before, .slide = entry.before_slide };
    }

    fn redo(self: *StudioHistory) !?SourceRestore {
        const entry = self.redo_stack.pop() orelse return null;
        errdefer self.redo_stack.append(self.allocator, entry) catch {};
        try self.undo_stack.append(self.allocator, entry);
        return .{ .source = entry.after, .slide = entry.after_slide };
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

    const undo = (try history.undo()).?;
    try std.testing.expectEqual(@as(i32, 0), undo.slide);
    try std.testing.expectEqualStrings("@slide\n@slide\n", undo.source);
    const redo = (try history.redo()).?;
    try std.testing.expectEqual(@as(i32, 1), redo.slide);
    try std.testing.expectEqualStrings("@slide\n@slide\n@slide\n", redo.source);
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

pub fn main(init: std.process.Init) anyerror!void {
    const gpa = init.gpa;
    const io = init.io;

    //--------------------------------------------------------------------------------------

    var crowd_options = CrowdOptions{};
    var crowd_host_buffer: [256]u8 = undefined;
    crowd_options.host = defaultCrowdHost(&crowd_host_buffer);
    var launch_studio = false;

    // get args
    const slideshow_to_load: ?[]const u8 = blk: {
        var args_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
        defer args_it.deinit();
        _ = args_it.skip();
        var slideshow_arg: ?[]const u8 = null;
        while (args_it.next()) |arg| {
            if (std.mem.startsWith(u8, arg, "--crowd-host=")) {
                crowd_options.host = try std.fmt.bufPrint(&crowd_host_buffer, "{s}", .{arg["--crowd-host=".len..]});
                crowd_options.host_explicit = true;
            } else if (std.mem.startsWith(u8, arg, "--crowd-port=")) {
                crowd_options.port = std.fmt.parseInt(u16, arg["--crowd-port=".len..], 10) catch std.process.fatal("Invalid --crowd-port value", .{});
            } else if (std.mem.eql(u8, arg, "--no-crowd")) {
                crowd_options.enabled = false;
            } else if (std.mem.eql(u8, arg, "--studio")) {
                launch_studio = true;
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

    const windowWidth: i32 = if (rl.getScreenWidth() >= 1920) 1920 else 1280;
    const windowHeight: i32 = if (rl.getScreenHeight() >= 1080) 1080 else 720;
    var screenWidth: i32 = windowWidth;
    var screenHeight: i32 = windowHeight;

    rl.setConfigFlags(.{ .window_resizable = true });
    rl.initWindow(screenWidth, screenHeight, "rayslides");
    // Studio owns Escape while editing (cancel drag, then leave Studio). Keep
    // Raylib from closing the process before the frame can consume the key.
    rl.setExitKey(.null);
    var first: bool = true;
    defer rl.closeWindow(); // Close window and OpenGL context

    // Initialize GPU-backed resources after the window and unload them before it closes.
    try G.init(gpa, io);
    defer G.deinit();
    if (slideshow_to_load) |path| {
        G.slideshow_filp_to_load = path;
    } else {
        try initializeUntitledSlideshow();
    }
    var crowd_runtime = try crowdplay.Runtime.init(gpa, io);
    defer crowd_runtime.stop();

    rl.setTargetFPS(61);
    var beast_mode: bool = false;

    // Main game loop
    var is_pre_rendered: bool = false;
    var export_controller: ExportController = try .init(gpa, io, null);
    defer export_controller.deinit();
    var laser_pointer: LaserPointer = try .init(gpa);
    defer laser_pointer.deinit();
    var banner: Banner = try .init(screenWidth, screenHeight);
    defer banner.deinit();
    var studio_mode: studio.Studio = .{
        .enabled = launch_studio or slideshow_to_load == null,
        .dirty = slideshow_to_load == null,
    };
    var property_prompt: studio_prompt.Prompt = .{};
    var pending_semantic_command: ?studio.SemanticCommand = null;
    var studio_history = StudioHistory.init(gpa);
    defer studio_history.deinit();
    var studio_clipboard = StudioClipboard.init(gpa);
    defer studio_clipboard.deinit();
    var studio_bounds = std.ArrayList(studio.ResolvedBounds).empty;
    defer studio_bounds.deinit(gpa);
    var studio_slide_summaries = std.ArrayList(studio.SlideSummary).empty;
    defer studio_slide_summaries.deinit(gpa);
    var studio_library_entries = std.ArrayList(studio.LibraryEntry).empty;
    defer studio_library_entries.deinit(gpa);
    var studio_library_catalog_indices = std.ArrayList(usize).empty;
    defer studio_library_catalog_indices.deinit(gpa);

    var manual_fullscreen: bool = false;
    var window_close_seen = false;

    while (true) {
        const window_close_now = rl.windowShouldClose();
        const window_close_requested = window_close_now and !window_close_seen;
        window_close_seen = window_close_now;
        // A modal property edit is not part of the persisted source yet. Do
        // not let the OS close button silently throw that draft away; after
        // submitting or cancelling it, Q/Escape (or a fresh close request)
        // follows the normal source-recovery path below.
        if (window_close_requested and !property_prompt.active and readyToQuitPreservingEdits(&studio_mode)) break;

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

        if (!property_prompt.active and rl.isKeyPressed(.s)) {
            if (studio_mode.capturesInput() or (editorSourceDirty() and shortcutModifierDown())) {
                if (shortcutModifierDown()) {
                    if (rl.isKeyDown(.left_shift) or rl.isKeyDown(.right_shift)) {
                        if (saveEditorSourceCopy()) |copy_path| {
                            if (G.slideshow_filp == null) {
                                adoptEditorSourcePath(copy_path) catch |err| {
                                    studio_mode.setNotice(.save_failed);
                                    log.err("Studio could not adopt saved document: {any}", .{err});
                                    gpa.free(copy_path);
                                    continue;
                                };
                                studio_mode.markSaved();
                                studio_mode.setNotice(.saved);
                            } else {
                                studio_mode.markCopySaved();
                            }
                            log.info("Studio copy saved to {s}", .{copy_path});
                            gpa.free(copy_path);
                        } else |err| {
                            studio_mode.setNotice(.save_failed);
                            log.err("Studio Save Copy failed: {any}", .{err});
                        }
                    } else {
                        const saved = if (G.slideshow_filp == null) saveUntitledEditorSource() else saveEditorSource();
                        if (saved) |_| {
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

        // Draw
        //----------------------------------------------------------------------------------
        rl.beginDrawing();
        defer rl.endDrawing();

        rl.clearBackground(.blank);

        // (re-) load slideshow
        if (G.slideshow_filp_to_load) |filp| {
            studio_mode = .{ .enabled = launch_studio };
            studio_history.clear();
            // Component clipboard entries carry source-order definition
            // provenance. Never let them cross a document reload where the
            // same name/offset could refer to unrelated source.
            studio_clipboard.clear();
            studio_bounds.clearRetainingCapacity();
            try loadSlideshow(filp);
            is_pre_rendered = false;
        }

        if (is_pre_rendered == false) {
            if (G.source_len > 0) {
                const slideshow_filp = G.slideshow_filp orelse "untitled.sld";
                log.info("LOADED!!!", .{});
                log.debug("I AM GOING TO PRE-RENDER!", .{});
                G.slide_renderer.preRender(G.slideshow, slideshow_filp) catch |err| {
                    log.err("Pre-rendering failed: {any}", .{err});
                };
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
                log.info("PRE-RENDERED!!!!", .{});
                is_pre_rendered = true;
            }
        }

        const now = rl.getTime();
        G.playback.settle(now);
        if (!export_controller.running and !studio_mode.capturesInput()) updateAutomaticReveal(now);
        const current_crowd_spec = crowdSpecForSlide(G.slideshow, G.current_slide);
        if (crowd_runtime.isRunning() and !export_controller.running) crowd_runtime.activate(current_crowd_spec);

        // render slide
        // G.slide_render_width = G.internal_render_size.x - ed_anim.current_size.x;
        // try G.slide_renderer.render(G.current_slide, slideAreaTL(), slideSizeInWindow(), G.internal_render_size);
        const internal_render_size: rl.Vector2 = .{ .x = 1920, .y = 1080 };
        if (!manual_fullscreen) {
            screenWidth = rl.getScreenWidth();
            screenHeight = rl.getScreenHeight();
        }
        const window_size: rl.Vector2 = .{ .x = @floatFromInt(screenWidth), .y = @floatFromInt(screenHeight) };
        const slide_size_in_window = slideSizeInWindow(internal_render_size, window_size);
        const slide_tl = slideAreaTL(internal_render_size, window_size);

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
        try collectStudioBounds(&studio_bounds, gpa, G.current_slide, studio_mode.active_morph_state, studio_items);
        const studio_viewport: studio.Viewport = .{
            .slide_top_left = slide_tl,
            .slide_size = slide_size_in_window,
            .logical_size = internal_render_size,
        };

        studio_slide_summaries.clearRetainingCapacity();
        studio_library_entries.clearRetainingCapacity();
        studio_library_catalog_indices.clearRetainingCapacity();
        var frame_studio_catalog: ?studio_catalog.Catalog = null;
        defer if (frame_studio_catalog) |catalog| catalog.deinit();
        var studio_workspace: studio.Workspace = .{};
        if (studio_mode.capturesInput()) {
            try collectStudioSlideSummaries(&studio_slide_summaries, gpa, G.slideshow);
            frame_studio_catalog = try studio_catalog.discover(gpa, G.editor_memory[0..G.source_len]);
            const item_insertion_offset = if (current_slide) |slide|
                studioItemInsertionOffset(slide, studio_mode.active_morph_state) catch slide.pos_in_editor
            else
                0;
            const slide_insertion_offset = if (current_slide) |slide|
                source_editor.slideEndOffset(G.editor_memory[0..G.source_len], slide.pos_in_editor) catch item_insertion_offset
            else
                item_insertion_offset;
            try collectStudioLibraryEntries(
                &studio_library_entries,
                &studio_library_catalog_indices,
                gpa,
                frame_studio_catalog.?,
                item_insertion_offset,
                slide_insertion_offset,
            );
            studio_workspace = .{
                .visible = true,
                .slides = studio_slide_summaries.items,
                .current_slide = if (G.current_slide >= 0) @intCast(G.current_slide) else 0,
                .library = studio_library_entries.items,
            };
        }

        var semantic_to_apply: ?studio.SemanticCommand = null;
        var semantic_text: ?[]const u8 = null;
        var studio_slide_to_select: ?usize = null;
        var source_graph_reparsed_this_frame = false;
        const prompt_was_active = property_prompt.active;
        if (prompt_was_active) {
            switch (property_prompt.updateFromRaylib()) {
                .none => {},
                .submitted => {
                    semantic_to_apply = pending_semantic_command;
                    semantic_text = property_prompt.text();
                    pending_semantic_command = null;
                    window_close_seen = false;
                },
                .cancelled => {
                    pending_semantic_command = null;
                    window_close_seen = false;
                },
            }
        }

        const studio_command: ?studio.GeometryCommand = if (!export_controller.running and !prompt_was_active)
            studio_mode.updateWithWorkspaceFromRaylib(studio_items, studio_bounds.items, studio_viewport, studio_workspace)
        else
            null;
        const studio_geometry_batch: ?studio.GeometryBatchCommand = studio_mode.takeGeometryBatch();
        if (!prompt_was_active) {
            if (studio_mode.takeSemanticCommand()) |command| {
                switch (command) {
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
                    .promote_slide_to_template => |slide_index| {
                        var suggested_name: [96]u8 = undefined;
                        const name = std.fmt.bufPrint(&suggested_name, "slide_template_{d}", .{slide_index + 1}) catch "slide_template";
                        pending_semantic_command = command;
                        property_prompt.begin(.reusable_name, name);
                    },
                    .rename_library_entry => |library_index| {
                        if (studioLibraryEntry(
                            frame_studio_catalog,
                            studio_library_catalog_indices.items,
                            library_index,
                        )) |entry| {
                            pending_semantic_command = command;
                            property_prompt.begin(.reusable_name, entry.name);
                        } else {
                            studio_mode.setNotice(.edit_failed);
                        }
                    },
                    .delete_library_entry => semantic_to_apply = command,
                    .add_reusable => |add| {
                        if (add.library_entry_index) |library_index| {
                            if (studioLibraryName(
                                frame_studio_catalog,
                                studio_library_catalog_indices.items,
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
                            studio_library_catalog_indices.items,
                            library_index,
                            .slide,
                        )) |name| {
                            semantic_to_apply = command;
                            semantic_text = name;
                        } else {
                            studio_mode.setNotice(.edit_failed);
                        }
                    },
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
        property_prompt.draw(window_size);
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
                studio_library_catalog_indices.items,
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
                if (invalid_prompt_value) {
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
                        => .structural_source_locked,
                        error.StudioClipboardEmpty => .clipboard_empty,
                        error.LockedLayerBarrier,
                        error.StudioItemLocked,
                        => .locked_item,
                        error.NameCollision => .library_name_conflict,
                        error.SlideTemplateNameCollision => .library_name_conflict,
                        error.LiveUses => .library_entry_in_use,
                        error.UnsafeSlideTemplateDelete => .library_delete_unsupported,
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

        if (!source_graph_reparsed_this_frame and studio_mode.capturesInput() and !property_prompt.active and shortcutModifierDown() and rl.isKeyPressed(.z)) {
            // Undo owns the source graph. End a transient pointer gesture before
            // reparsing so it cannot later release stale pre-undo geometry.
            // Source history may remove an item and recycle its numeric
            // identity onto a following sibling. Clear the source-bound
            // selection before reparsing so undo/redo can never retarget it.
            studio_mode.clearSelection(studio_items);
            const changed = if (rl.isKeyDown(.left_shift) or rl.isKeyDown(.right_shift))
                redoStudioEdit(&studio_history)
            else
                undoStudioEdit(&studio_history);
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
        // try G.slide_renderer.render(G.current_slide, .{ .x = 0.0, .y = 0.0 }, .{ .x = @floatFromInt(screenWidth), .y = @floatFromInt(screenHeight) }, .{ .x = 1920, .y = 1080 });
        if (beast_mode) {
            rl.drawFPS(20, 20);
        }

        if (export_controller.final_messagebox_message) |msg| {
            if (rg.messageBox(.{ .x = @floatFromInt(@divTrunc(screenWidth - 400, 2)), .y = 300, .width = 400, .height = 100 }, "Slideshow Export", msg, "OK") >= 0) {
                gpa.free(msg);
                export_controller.final_messagebox_message = null;
            }
        }

        if (laser_pointer.show and !studio_mode.capturesInput()) {
            try laser_pointer.draw();
        }

        if (banner.show) {
            banner.render();
        }

        //
        // hanlde keys
        //
        if (!export_controller.running and !studio_mode.capturesInput() and (rl.isKeyPressed(.space) or rl.isKeyPressed(.right) or rl.isKeyPressed(.page_down) or (!laser_pointer.show and rl.isMouseButtonPressed(.left)))) {
            advancePresentation(rl.getTime());
        }

        if (!export_controller.running and !studio_mode.capturesInput() and (rl.isKeyPressed(.backspace) or rl.isKeyPressed(.left) or rl.isKeyPressed(.page_up))) {
            reversePresentation(rl.getTime());
        }

        if (crowd_runtime.isRunning() and !export_controller.running and !studio_mode.capturesInput() and rl.isKeyPressed(.o)) {
            _ = crowd_runtime.toggleOpen();
        }
        if (crowd_runtime.isRunning() and !export_controller.running and !studio_mode.capturesInput() and rl.isKeyPressed(.v)) {
            _ = crowd_runtime.toggleReveal();
        }
        if (crowd_runtime.isRunning() and !export_controller.running and !studio_mode.capturesInput() and rl.isKeyPressed(.r)) {
            _ = crowd_runtime.resetActive();
        }

        // hack for M1 macbook 14" with low resolution set to : 1512 x 981
        if (first) {
            rl.toggleBorderlessWindowed();
            rl.toggleBorderlessWindowed();
            first = false;
        }

        if (!property_prompt.active and rl.isKeyPressed(.f)) {
            if (!manual_fullscreen) {
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
                screenWidth = windowWidth;
                screenHeight = windowHeight;
                if (rl.isKeyDown(.left_shift) or rl.isKeyDown(.right_shift)) {
                    rl.toggleFullscreen();
                } else {
                    rl.toggleBorderlessWindowed();
                }
                // rl.toggleFullscreen();
                rl.setWindowSize(windowWidth, windowHeight);
                manual_fullscreen = false;
            }
        }

        if (!property_prompt.active and (rl.isKeyPressed(.q) or
            (rl.isKeyPressed(.escape) and !studio_active_at_frame_start)))
        {
            if (readyToQuitPreservingEdits(&studio_mode)) break;
        }

        if (!export_controller.running and !studio_mode.capturesInput() and rl.isKeyPressed(.one)) {
            jumpToSlide(0, rl.getTime());
        }

        if (!export_controller.running and !studio_mode.capturesInput() and G.slideshow.slides.items.len > 0 and rl.isKeyPressed(.zero)) {
            jumpToSlide(@intCast(G.slideshow.slides.items.len - 1), rl.getTime());
        }

        if (!export_controller.running and !studio_mode.capturesInput() and G.slideshow.slides.items.len > 0 and rl.isKeyPressed(.g)) {
            if (rl.isKeyDown(.left_shift) or rl.isKeyDown(.right_shift)) {
                jumpToSlide(@intCast(G.slideshow.slides.items.len - 1), rl.getTime());
            } else {
                jumpToSlide(0, rl.getTime());
            }
        }

        if (!studio_mode.capturesInput() and !property_prompt.active and rl.isKeyPressed(.b)) {
            if (rl.isKeyDown(.left_shift) or rl.isKeyDown(.right_shift)) {
                banner.reset();
            } else {
                beast_mode = !beast_mode;
                if (beast_mode) {
                    rl.setTargetFPS(0);
                } else {
                    rl.setTargetFPS(61);
                }
            }
        }

        if (!studio_mode.capturesInput() and rl.isKeyPressed(.l)) {
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

        if (!studio_mode.capturesInput() and rl.isKeyPressed(.c)) {
            laser_pointer.clearDrawing();
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

const AppData = struct {
    allocator: std.mem.Allocator = undefined,
    io: std.Io = undefined,
    slideshow_arena: std.heap.ArenaAllocator = undefined,
    slideshow_allocator: std.mem.Allocator = undefined,
    fonts: fonts.AvailableFonts = .{},
    editor_memory: []u8 = undefined,
    loaded_content: []u8 = undefined, // we will check for dirty editor against this
    source_len: usize = 0,
    loaded_len: usize = 0,
    last_window_size: rl.Vector2 = .{ .x = 0.0, .y = 0.0 },
    content_window_size: rl.Vector2 = .{ .x = 0.0, .y = 0.0 },
    slide_renderer: *renderer.SlideshowRenderer = undefined,
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

    fn init(self: *AppData, gpa: std.mem.Allocator, io: std.Io) !void {
        self.allocator = gpa;
        self.io = io;

        self.slideshow_arena = std.heap.ArenaAllocator.init(gpa);
        self.slideshow_allocator = self.slideshow_arena.allocator();

        self.fonts = try fonts.AvailableFonts.init(.{});
        self.slideshow = try SlideShow.new(self.slideshow_allocator);
        self.slide_renderer = try renderer.SlideshowRenderer.new(self.slideshow_allocator, &self.fonts);
        self.playback.reset(rl.getTime());

        self.editor_memory = try self.allocator.alloc(u8, 128 * 1024);
        self.loaded_content = try self.allocator.alloc(u8, 128 * 1024);
        @memset(self.editor_memory, 0);
        @memset(self.loaded_content, 0);
    }

    fn deinit(self: *AppData) void {
        self.slide_renderer.deinit();
        self.fonts.deinit();
        self.allocator.free(self.editor_memory);
        self.allocator.free(self.loaded_content);
        self.slideshow_arena.deinit();
    }

    /// Rebuild only the parser/render graph. Document buffers, fonts, and
    /// Studio history deliberately survive so a visual edit can be reparsed
    /// without turning into a file reload.
    fn resetSlideshowGraph(self: *AppData) !void {
        self.slide_renderer.deinit();
        self.slideshow_arena.deinit();
        self.slideshow_arena = std.heap.ArenaAllocator.init(self.allocator);
        self.slideshow_allocator = self.slideshow_arena.allocator();
        self.slideshow = try SlideShow.new(self.slideshow_allocator);
        self.slide_renderer = try renderer.SlideshowRenderer.new(self.slideshow_allocator, &self.fonts);
    }

    fn reinit(self: *AppData) !void {
        self.deinit();
        try self.init(self.allocator, self.io);
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
    if (std.Io.Dir.cwd().openFile(G.io, filp, .{})) |f| {
        defer f.close(G.io);
        G.hot_reload_last_stat = try f.stat(G.io);

        var read_buffer: [4096]u8 = undefined;
        var file_reader = f.reader(G.io, &read_buffer);
        const input = try file_reader.interface.allocRemaining(G.allocator, .limited(G.editor_memory.len - 1));
        defer G.allocator.free(input);

        log.info("Read {d} bytes", .{input.len});

        if (input.len >= G.editor_memory.len) {
            // setStatusMsg("Loading failed!");
            std.log.err("Loading failed: File too large ({d} > {d})", .{ input.len, G.editor_memory.len });
            return;
        }
        // setStatusMsg(sliceToC(input));

        // parse the slideshow
        if (G.reinit()) |_| {
            // after reinit, the buffers are memset to zeros
            @memcpy(G.editor_memory[0..input.len], input);
            @memcpy(G.loaded_content[0..input.len], input);
            G.editor_memory[input.len] = 0;
            G.loaded_content[input.len] = 0;
            G.source_len = input.len;
            G.loaded_len = input.len;
            G.slideshow_filp = blk: {
                if (G.slideshow_filp) |existing| {
                    if (existing.ptr == filp.ptr) {
                        break :blk filp;
                    }
                }
                break :blk try std.fmt.bufPrint(&G.slideshow_filp_buffer, "{s}", .{filp});
            };
            std.log.debug("filp is now {s}", .{G.slideshow_filp.?});
            if (parser.constructSlidesFromBuf(G.editor_memory[0..input.len], G.slideshow, G.slideshow_allocator)) |pcontext| {
                defer pcontext.deinit();
                // ed_anim.parser_context = pcontext;
                // now reload fonts
                if (pcontext.custom_fonts_present) {
                    std.log.debug("reloading fonts", .{});
                    // FIXME: this needs to be done after GL has been initialized
                    //        so, loadSlideshow() must not be called before
                    //        raylib's update loop
                    try G.fonts.loadCustomFonts(pcontext.fontConfig, G.slideshow_filp.?);
                    std.log.debug("reloaded fonts", .{});
                }
            } else |err| {
                std.log.err("{any}", .{err});
                // setStatusMsg("Loading failed!");
            }

            if (true) {
                std.log.info("=================================", .{});
                std.log.info("          Load Summary:", .{});
                std.log.info("=================================", .{});
                std.log.info("Constructed {d} slides:", .{G.slideshow.slides.items.len});
                for (G.slideshow.slides.items, 0..) |slide, i| {
                    std.log.info("================================================", .{});
                    std.log.info("   slide {d} pos in editor: {}", .{ i, slide.pos_in_editor });
                    if (slide.items) |items| {
                        std.log.info("   slide {d} has {d} items", .{ i, items.items.len });
                        for (items.items) |item| {
                            item.printToLog();
                        }
                    } else {
                        std.log.info("   slide {d} has 0 items", .{i});
                    }
                }
            }
        } else |err| {
            // setStatusMsg("Loading failed!");
            std.log.err("Loading failed: {any}", .{err});
        }
    } else |err| {
        // setStatusMsg("Loading failed!");
        std.log.err("Loading failed: {any}", .{err});
    }
}

fn reparseEditorSource() !void {
    const previous_slide = G.current_slide;
    try G.resetSlideshowGraph();

    const context = try parser.constructSlidesFromBuf(
        G.editor_memory[0..G.source_len],
        G.slideshow,
        G.slideshow_allocator,
    );
    defer context.deinit();
    if (context.parser_errors.items.len != 0) return error.StudioSourcePatchInvalid;

    if (G.slideshow.slides.items.len == 0) {
        G.current_slide = 0;
    } else {
        G.current_slide = @min(previous_slide, @as(i32, @intCast(G.slideshow.slides.items.len - 1)));
    }
    G.playback.enterSlide(null, 0, 0, .{}, 1, rl.getTime());
}

fn initializeUntitledSlideshow() !void {
    const initial_source = "@slide\n";
    @memcpy(G.editor_memory[0..initial_source.len], initial_source);
    G.editor_memory[initial_source.len] = 0;
    G.source_len = initial_source.len;
    G.loaded_len = 0;
    G.slideshow_filp = null;
    G.hot_reload_last_stat = null;
    try reparseEditorSource();
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

fn saveEditorSourceCopy() ![]u8 {
    const path = G.slideshow_filp orelse "untitled.sld";
    const stem = if (std.mem.endsWith(u8, path, ".sld")) path[0 .. path.len - ".sld".len] else path;
    var sequence: usize = 1;
    const copy_path = while (sequence < 10_000) : (sequence += 1) {
        const candidate = if (sequence == 1)
            try std.fmt.allocPrint(G.allocator, "{s}.edited.sld", .{stem})
        else
            try std.fmt.allocPrint(G.allocator, "{s}.edited-{d}.sld", .{ stem, sequence });
        const reservation = std.Io.Dir.cwd().createFile(G.io, candidate, .{ .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => {
                G.allocator.free(candidate);
                continue;
            },
            else => {
                G.allocator.free(candidate);
                return err;
            },
        };
        reservation.close(G.io);
        break candidate;
    } else return error.TooManyEditedCopies;
    errdefer G.allocator.free(copy_path);
    errdefer std.Io.Dir.cwd().deleteFile(G.io, copy_path) catch {};
    try writeEditorSourceAtomically(copy_path, null);
    return copy_path;
}

fn adoptEditorSourcePath(path: []const u8) !void {
    G.slideshow_filp = try std.fmt.bufPrint(&G.slideshow_filp_buffer, "{s}", .{path});
    @memcpy(G.loaded_content[0..G.source_len], G.editor_memory[0..G.source_len]);
    if (G.loaded_len > G.source_len) @memset(G.loaded_content[G.source_len..G.loaded_len], 0);
    G.loaded_len = G.source_len;
    const file = try std.Io.Dir.cwd().openFile(G.io, G.slideshow_filp.?, .{});
    defer file.close(G.io);
    G.hot_reload_last_stat = try file.stat(G.io);
}

fn saveUntitledEditorSource() !void {
    const copy_path = try saveEditorSourceCopy();
    defer G.allocator.free(copy_path);
    try adoptEditorSourcePath(copy_path);
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
}

fn studioItemByIdentity(items: []const slides.SlideItem, identity: usize) ?*const slides.SlideItem {
    for (items) |*item| if (item.identity == identity) return item;
    return null;
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

    try replaceEditorSource(result.source);
    reparseEditorSource() catch |err| {
        replaceEditorSource(before) catch {};
        reparseEditorSource() catch {};
        return err;
    };
    history.record(before, result.source, before_slide, G.current_slide) catch |err| {
        replaceEditorSource(before) catch {};
        reparseEditorSource() catch {};
        return err;
    };
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
    const value = std.mem.trim(u8, input, " \t\r\n");
    if (value.len == 0) return error.InvalidStudioOpacity;
    const opacity = if (value[value.len - 1] == '%') blk: {
        const percent = try parseStudioFiniteFloat(value[0 .. value.len - 1]);
        break :blk percent / 100;
    } else try parseStudioFiniteFloat(value);
    if (opacity < 0.01 or opacity > 1) return error.InvalidStudioOpacity;
    return formatStudioFloat(buffer, opacity);
}

fn canonicalStudioFontSize(input: []const u8, buffer: []u8) ![]const u8 {
    const value = std.mem.trim(u8, input, " \t\r\n");
    const size = std.fmt.parseInt(i32, value, 10) catch return error.InvalidStudioFontSize;
    if (size <= 0 or size > 4096) return error.InvalidStudioFontSize;
    return std.fmt.bufPrint(buffer, "{d}", .{size});
}

test "Studio custom property values canonicalize safely" {
    var color_buffer: [9]u8 = undefined;
    try std.testing.expectEqualStrings("#aabbccff", try canonicalStudioColor(" #AaBbCc ", &color_buffer));
    try std.testing.expectEqualStrings("#01020304", try canonicalStudioColor("#01020304", &color_buffer));
    try std.testing.expectError(error.InvalidStudioColor, canonicalStudioColor("#12345g", &color_buffer));

    var number_buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("0.75", try canonicalStudioOpacity("75%", &number_buffer));
    try std.testing.expectEqualStrings("0.25", try canonicalStudioOpacity("0.25", &number_buffer));
    try std.testing.expectError(error.InvalidStudioOpacity, canonicalStudioOpacity("0", &number_buffer));
    try std.testing.expectError(error.InvalidStudioOpacity, canonicalStudioOpacity("0.5%", &number_buffer));
    try std.testing.expectError(error.InvalidStudioOpacity, canonicalStudioOpacity("101%", &number_buffer));
    try std.testing.expectEqualStrings("48", try canonicalStudioFontSize("48", &number_buffer));
    try std.testing.expectError(error.InvalidStudioFontSize, canonicalStudioFontSize("0", &number_buffer));
}

fn validReusableName(name: []const u8) bool {
    if (name.len == 0 or !(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name[1..]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-') return false;
    }
    return true;
}

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
            .slide => slide_insertion_offset,
        };
        if (!catalog.isVisibleAt(catalog_index, insertion_offset)) continue;
        try output.append(allocator, .{
            .kind = switch (entry.kind) {
                .element => .element,
                .slide => .slide_template,
            },
            .name = entry.name,
            .available = entry.placeable,
            .use_count = entry.use_count,
            .deletable = entry.kind == .element and entry.use_count == 0,
        });
        errdefer _ = output.pop();
        try catalog_indices.append(allocator, catalog_index);
    }
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

fn itemTextSnippet(
    allocator: std.mem.Allocator,
    directive_without_text: []const u8,
    text_value: []const u8,
) ![]u8 {
    if (std.mem.indexOfScalar(u8, text_value, '\r') != null) return error.InvalidStudioText;
    if (std.mem.indexOfScalar(u8, text_value, '\n') == null) {
        return std.fmt.allocPrint(allocator, "{s} text={s}", .{ directive_without_text, text_value });
    }
    var lines = std.mem.splitScalar(u8, text_value, '\n');
    while (lines.next()) |line| {
        if (line.len > 0 and (line[0] == '@' or line[0] == '#')) return error.InvalidStudioText;
    }
    return std.fmt.allocPrint(allocator, "{s}\n{s}", .{ directive_without_text, text_value });
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

const StudioSemanticEditResult = struct {
    source_changed: bool = true,
    slide_index: ?usize = null,
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
        .set_locked => |lock| {
            var all_have_ids = true;
            for (lock.slice()) |target| {
                const item = studioItemByIdentity(items, target.item_identity) orelse return error.StudioItemMissing;
                if (item.id) |id| try selection_ids.appendCopy(id) else all_have_ids = false;
            }
            if (!all_have_ids) selection_ids.clear();
            try applyStudioLockEdit(history, lock, slide, morph_state, items);
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

fn undoStudioEdit(history: *StudioHistory) !bool {
    const restore = try history.undo() orelse return false;
    try replaceEditorSource(restore.source);
    try reparseEditorSource();
    restoreStudioSlide(restore.slide);
    return true;
}

fn redoStudioEdit(history: *StudioHistory) !bool {
    const restore = try history.redo() orelse return false;
    try replaceEditorSource(restore.source);
    try reparseEditorSource();
    restoreStudioSlide(restore.slide);
    return true;
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
    allocator: std.mem.Allocator,
    slide_number: i32,
    morph_state: ?usize,
    items: []const slides.SlideItem,
) !void {
    output.clearRetainingCapacity();
    for (items) |item| {
        const bounds = G.slide_renderer.itemRenderBoundsForMorphState(slide_number, morph_state, item.identity) orelse continue;
        try output.append(allocator, .{
            .identity = item.identity,
            .position = .{ .x = bounds.x, .y = bounds.y },
            .size = .{ .x = bounds.width, .y = bounds.height },
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
