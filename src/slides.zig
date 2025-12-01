const std = @import("std");
const rl = @import("raylib");

const log = std.log.scoped(.slides);

pub const SlideList = std.ArrayList(*Slide);

pub const SlideShow = struct {
    slides: SlideList = undefined,

    // defaults that can be overridden while parsing
    default_fontsize: i32 = 16,
    default_line_height_factor: f32 = 1.0,
    default_underline_width: i32 = 1,
    default_color: rl.Color = .light_gray,
    default_bullet_color: rl.Color = .red,
    default_bullet_symbol: []const u8 = ">",

    // TODO: maybe later: font encountered while parsing
    fonts: std.ArrayList([]u8) = undefined,
    fontsizes: std.ArrayList(i32) = undefined,

    pub fn new(a: std.mem.Allocator) !*SlideShow {
        var self = try a.create(SlideShow);
        self.* = .{};
        self.slides = SlideList.empty;
        // TODO: init font, fontsize arraylists
        return self;
    }

    pub fn deinit(self: *SlideShow, a: std.mem.Allocator) void {
        self.slides.deinit(a);
    }
};

pub const Slide = struct {
    allocator: std.mem.Allocator,
    pos_in_editor: usize = 0,
    line_in_editor: usize = 0,
    items: ?std.ArrayList(SlideItem) = null,
    fontsize: i32 = 16,
    text_color: rl.Color = .ray_white,
    bullet_color: rl.Color = .red,
    bullet_symbol: ?[]const u8 = null,
    underline_width: i32 = 1,
    line_height_factor: ?f32 = null,

    // .

    pub fn new(a: std.mem.Allocator) !*Slide {
        log.debug("slide create 0 ", .{});
        var self: *Slide = try a.create(Slide);
        log.debug("slide create 2", .{});
        self.* = .{ .allocator = a };
        log.debug("slide create 3", .{});
        self.items = std.ArrayList(SlideItem).empty;
        log.debug("slide create 4", .{});
        return self;
    }
    pub fn deinit(self: *Slide) void {
        self.items.deinit(self.allocator);
    }

    pub fn applyContext(self: *Slide, ctx: *ItemContext) void {
        if (ctx.fontSize) |fs| self.fontsize = fs;
        if (ctx.color) |col| self.text_color = col;
        if (ctx.bullet_color) |bul| self.bullet_color = bul;
        if (ctx.underline_width) |uw| self.underline_width = uw;
        if (ctx.bullet_symbol) |bs| self.bullet_symbol = bs;
        if (ctx.line_height_factor) |lhf| self.line_height_factor = lhf;
    }

    pub fn fromSlide(orig: *Slide, a: std.mem.Allocator) !*Slide {
        var n = try new(a);
        try n.items.?.appendSlice(n.allocator, orig.items.?.items);
        return n;
    }
};

pub const SlideItemKind = enum {
    background,
    textbox,
    img,
};

pub const SlideItemError = error{
    TextNull,
    LineHeightNull,
    ImgPathNull,
    FontSizeNull,
    ColorNull,
    UnderlineWidthNull,
    BulletColorNull,
    BulletSymbolNull,
};

pub const SlideItem = struct {
    kind: SlideItemKind = .background,
    text: ?[]const u8 = null,
    fontSize: ?i32 = null,
    line_height_factor: ?f32 = null,
    color: ?rl.Color = .blank,
    img_path: ?[]const u8 = null,
    position: rl.Vector2 = .{ .x = 0.0, .y = 0.0 },
    size: rl.Vector2 = .{ .x = 0.0, .y = 0.0 },

    underline_width: ?i32 = null,
    bullet_color: ?rl.Color = null,
    bullet_symbol: ?[]const u8 = null,

    // Image auto-dimension parameters
    scale: ?f32 = null,
    ratio: ?f32 = null,

    pub fn new(a: std.mem.Allocator) !*SlideItem {
        const self = try a.create(SlideItem);
        self.* = .{};
        return self;
    }
    pub fn deinit(_: *Slide) void {
        // empty
    }

    pub fn applyContext(self: *SlideItem, context: ItemContext) void {
        if (context.text) |text| self.text = text;

        if (context.img_path) |img_path| self.img_path = img_path;
        if (context.fontSize) |fontsize| self.fontSize = fontsize;
        if (context.color) |color| self.color = color;
        if (context.position) |position| self.position = position;
        if (context.size) |size| self.size = size;
        if (context.underline_width) |w| self.underline_width = w;
        if (context.bullet_color) |color| self.bullet_color = color;
        if (context.bullet_symbol) |symbol| self.bullet_symbol = symbol;
        if (context.line_height_factor) |lhf| self.line_height_factor = lhf;
        if (context.scale) |s| self.scale = s;
        if (context.ratio) |r| self.ratio = r;
    }
    pub fn applySlideDefaultsIfNecessary(self: *SlideItem, slide: *Slide) void {
        if (self.fontSize == null) self.fontSize = slide.fontsize;
        if (self.color == null) self.color = slide.text_color;
        if (self.underline_width == null) self.underline_width = slide.underline_width;
        if (self.bullet_color == null) self.bullet_color = slide.bullet_color;
        if (self.bullet_symbol == null) self.bullet_symbol = slide.bullet_symbol;
        if (self.line_height_factor == null) self.line_height_factor = slide.line_height_factor;
    }

    pub fn applySlideShowDefaultsIfNecessary(self: *SlideItem, slideshow: *SlideShow) void {
        self.fontSize = self.fontSize orelse slideshow.default_fontsize;
        self.color = self.color orelse slideshow.default_color;
        self.underline_width = self.underline_width orelse slideshow.default_underline_width;
        self.bullet_color = self.bullet_color orelse slideshow.default_bullet_color;
        self.bullet_symbol = self.bullet_symbol orelse slideshow.default_bullet_symbol;
        self.line_height_factor = self.line_height_factor orelse slideshow.default_line_height_factor;
    }

    pub fn sanityCheck(self: *SlideItem) SlideItemError!void {
        if (self.text == null and self.color == null and self.kind == .textbox) return SlideItemError.TextNull;
        if (self.line_height_factor == null and self.kind == .textbox) return SlideItemError.LineHeightNull;
        if (self.fontSize == null and self.kind == .textbox) return SlideItemError.FontSizeNull;
        if (self.color == null and self.kind == .textbox) return SlideItemError.ColorNull;
        if (self.underline_width == null and self.kind == .textbox) return SlideItemError.UnderlineWidthNull;
        if (self.bullet_color == null and self.kind == .textbox) return SlideItemError.BulletColorNull;
        if (self.bullet_symbol == null and self.kind == .textbox) return SlideItemError.BulletSymbolNull;

        if (self.img_path == null and (self.kind == .img)) return SlideItemError.ImgPathNull;
        if (self.kind == .background) {
            if (self.img_path == null and self.color == null) {
                return SlideItemError.ColorNull;
            }
        }
    }

    pub fn printToLog(self: *const SlideItem) void {
        const indent = "    ";
        switch (self.kind) {
            .background => {
                log.info(indent ++ "Kind: Background", .{});
                if (self.img_path) |img_path| {
                    log.info(indent ++ "   img: {any}", .{img_path});
                    log.info(indent ++ "   pos: {any}", .{self.position});
                    log.info(indent ++ "  size: {any}", .{self.size});
                } else {
                    log.info(indent ++ " color: {any}", .{self.color});
                }
            },
            .img => {
                log.info(indent ++ "Kind: Image", .{});
                log.info(indent ++ "   img: {any}", .{self.img_path});
                log.info(indent ++ "   pos: {any}", .{self.position});
                log.info(indent ++ "  size: {any}", .{self.size});
            },
            .textbox => {
                log.info(indent ++ "Kind: TextBox", .{});
                log.info(indent ++ "   pos: {any}", .{self.position});
                log.info(indent ++ "  size: {any}", .{self.size});
                if (self.text) |text| {
                    log.info(indent ++ "  text:({d}) `{s}`", .{ text.len, text });
                } else {
                    log.info(indent ++ "  text: (null)", .{});
                }
                log.info(indent ++ " fsize: {any}", .{self.fontSize});
                log.info(indent ++ "uwidth: {any}", .{self.underline_width});
                log.info(indent ++ "bcolor: {any}", .{self.bullet_color});
                log.info(indent ++ "bsymbl: {any}", .{self.bullet_symbol});
                log.info(indent ++ "  line_height_factor: {any}", .{self.line_height_factor});
            },
        }
        log.info(indent ++ "-----------------------", .{});
    }
};

pub const ItemContext = struct {
    directive: []const u8 = undefined, // @push, @slide, ...
    context_name: ?[]const u8 = null,
    text: ?[]const u8 = null,
    fontSize: ?i32 = null,
    line_height_factor: ?f32 = null,
    color: ?rl.Color = null,
    img_path: ?[]const u8 = null,
    position: ?rl.Vector2 = null,
    size: ?rl.Vector2 = null,
    underline_width: ?i32 = null,
    bullet_color: ?rl.Color = null,
    bullet_symbol: ?[]const u8 = null,
    line_number: usize = 0,
    line_offset: usize = 0,

    // Image auto-dimension parameters
    scale: ?f32 = null,
    ratio: ?f32 = null,

    pub fn applyOtherIfNull(self: *ItemContext, other: ItemContext) void {
        if (self.text == null) {
            if (other.text) |text| self.text = text;
        }

        if (self.img_path == null) {
            if (other.img_path) |img_path| self.img_path = img_path;
        }
        if (self.fontSize == null) {
            if (other.fontSize) |fontsize| self.fontSize = fontsize;
        }
        if (self.color == null) {
            if (other.color) |color| self.color = color;
        }
        if (self.position == null) {
            if (other.position) |position| self.position = position;
        }
        if (self.size == null) {
            if (other.size) |size| self.size = size;
        }
        if (self.underline_width == null) {
            if (other.underline_width) |w| self.underline_width = w;
        }
        if (self.bullet_color == null) {
            if (other.bullet_color) |color| self.bullet_color = color;
        }
        if (self.bullet_symbol == null) {
            if (other.bullet_symbol) |symbol| self.bullet_symbol = symbol;
        }

        if (self.line_height_factor == null) {
            if (other.line_height_factor) |lhf| self.line_height_factor = lhf;
        }
        if (self.scale == null) {
            if (other.scale) |s| self.scale = s;
        }
        if (self.ratio == null) {
            if (other.ratio) |r| self.ratio = r;
        }
    }
};
