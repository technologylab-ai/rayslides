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
const SlideShow = slides.SlideShow;

const log = std.log.scoped(.main);

const CrowdOptions = struct {
    enabled: bool = true,
    host: []const u8 = "localhost",
    host_explicit: bool = false,
    port: u16 = 7331,
};

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

    // get args
    const slideshow_to_load = blk: {
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
            } else if (slideshow_arg == null) {
                slideshow_arg = arg;
            } else {
                std.process.fatal("Unexpected argument: {s}", .{arg});
            }
        }
        const selected = slideshow_arg orelse std.process.fatal("No slideshow arg given!", .{});
        log.debug("loading... {s}", .{selected});
        break :blk try std.fmt.bufPrint(&G.slideshow_filp_to_load_buffer, "{s}", .{selected});
    };

    const windowWidth: i32 = if (rl.getScreenWidth() >= 1920) 1920 else 1280;
    const windowHeight: i32 = if (rl.getScreenHeight() >= 1080) 1080 else 720;
    var screenWidth: i32 = windowWidth;
    var screenHeight: i32 = windowHeight;

    rl.setConfigFlags(.{ .window_resizable = true });
    rl.initWindow(screenWidth, screenHeight, "rayslides");
    var first: bool = true;
    defer rl.closeWindow(); // Close window and OpenGL context

    // Initialize GPU-backed resources after the window and unload them before it closes.
    try G.init(gpa, io);
    defer G.deinit();
    G.slideshow_filp_to_load = slideshow_to_load;
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

    var manual_fullscreen: bool = false;

    while (!rl.windowShouldClose()) { // Detect window close button or ESC key
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

        if (rl.isKeyPressed(.s)) {
            if (rl.isKeyDown(.left_shift) or rl.isKeyDown(.right_shift)) {
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
            try loadSlideshow(filp);
            is_pre_rendered = false;
        }

        if (is_pre_rendered == false) {
            if (G.slideshow_filp) |slideshow_filp| {
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
        if (!export_controller.running) updateAutomaticReveal(now);
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
        const reveal_state: renderer.RevealState = if (export_controller.running)
            .{ .visible_through = G.slide_renderer.stepCount(G.current_slide) }
        else
            .{
                .visible_through = G.playback.visible_step,
                .active_step = G.playback.active_step,
                .active_progress = G.playback.activeStepProgress(now),
            };
        const transition_state: renderer.TransitionState = if (export_controller.running)
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

        if (laser_pointer.show) {
            try laser_pointer.draw();
        }

        if (banner.show) {
            banner.render();
        }

        //
        // hanlde keys
        //
        if (!export_controller.running and (rl.isKeyPressed(.space) or rl.isKeyPressed(.right) or rl.isKeyPressed(.page_down) or (!laser_pointer.show and rl.isMouseButtonPressed(.left)))) {
            advancePresentation(rl.getTime());
        }

        if (!export_controller.running and (rl.isKeyPressed(.backspace) or rl.isKeyPressed(.left) or rl.isKeyPressed(.page_up))) {
            reversePresentation(rl.getTime());
        }

        if (crowd_runtime.isRunning() and !export_controller.running and rl.isKeyPressed(.o)) {
            _ = crowd_runtime.toggleOpen();
        }
        if (crowd_runtime.isRunning() and !export_controller.running and rl.isKeyPressed(.v)) {
            _ = crowd_runtime.toggleReveal();
        }
        if (crowd_runtime.isRunning() and !export_controller.running and rl.isKeyPressed(.r)) {
            _ = crowd_runtime.resetActive();
        }

        // hack for M1 macbook 14" with low resolution set to : 1512 x 981
        if (first) {
            rl.toggleBorderlessWindowed();
            rl.toggleBorderlessWindowed();
            first = false;
        }

        if (rl.isKeyPressed(.f)) {
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

        if (rl.isKeyPressed(.q)) {
            break;
        }

        if (!export_controller.running and rl.isKeyPressed(.one)) {
            jumpToSlide(0, rl.getTime());
        }

        if (!export_controller.running and G.slideshow.slides.items.len > 0 and rl.isKeyPressed(.zero)) {
            jumpToSlide(@intCast(G.slideshow.slides.items.len - 1), rl.getTime());
        }

        if (!export_controller.running and G.slideshow.slides.items.len > 0 and rl.isKeyPressed(.g)) {
            if (rl.isKeyDown(.left_shift) or rl.isKeyDown(.right_shift)) {
                jumpToSlide(@intCast(G.slideshow.slides.items.len - 1), rl.getTime());
            } else {
                jumpToSlide(0, rl.getTime());
            }
        }

        if (rl.isKeyPressed(.b)) {
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

        if (rl.isKeyPressed(.l)) {
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

        if (rl.isKeyPressed(.c)) {
            laser_pointer.clearDrawing();
        }

        const do_reload = checkAutoReload() catch false;
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

fn advancePresentation(now: f64) void {
    G.playback.settle(now);
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
    last_window_size: rl.Vector2 = .{ .x = 0.0, .y = 0.0 },
    content_window_size: rl.Vector2 = .{ .x = 0.0, .y = 0.0 },
    slide_renderer: *renderer.SlideshowRenderer = undefined,
    slideshow_filp_buffer: [std.fs.max_path_bytes]u8 = undefined,
    slideshow_filp_to_load_buffer: [std.fs.max_path_bytes]u8 = undefined,
    slideshow_filp: ?[]const u8 = undefined,
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
        self.fonts.deinit();
        self.allocator.free(self.editor_memory);
        self.allocator.free(self.loaded_content);
        self.slideshow_arena.deinit();
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
        const input = try file_reader.interface.allocRemaining(G.allocator, .limited(G.editor_memory.len));
        defer G.allocator.free(input);

        log.info("Read {d} bytes", .{input.len});

        if (input.len > G.editor_memory.len) {
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
