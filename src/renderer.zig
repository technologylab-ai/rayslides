const std = @import("std");
const TextureCache = @import("texturecache.zig");
const slides = @import("slides.zig");
const animation = @import("animation.zig");
const crowdplay = @import("crowdplay.zig");
const markdownlineparser = @import("markdownlineparser.zig");
const my_fonts = @import("fonts.zig");
const qrcode = @import("qrcode.zig");

const rl = @import("raylib");

const log = std.log.scoped(.renderer);

const RenderDistortion = struct { dx: f32 = 0.0, dy: f32 = 0.0 };

const RenderDistortionAnimation = struct { framecount: f32 = 0, scale: f32 = 10.0, running: bool = false };

pub var renderDistortion = RenderDistortion{};
pub var renderDistortionAnimation = RenderDistortionAnimation{};

pub fn updateRenderDistortion() void {
    renderDistortionAnimation.framecount += 1;
    renderDistortion.dx = std.math.cos(renderDistortionAnimation.framecount) * renderDistortionAnimation.scale;
    renderDistortion.dy = std.math.sin(renderDistortionAnimation.framecount) * renderDistortionAnimation.scale;
}

const RenderElementKind = enum {
    background,
    text,
    image,
    crowd,
};

const RenderElement = struct {
    kind: RenderElementKind = .background,
    position: rl.Vector2 = .{ .x = 0.0, .y = 0.0 },
    size: rl.Vector2 = .{ .x = 0.0, .y = 0.0 },
    color: ?rl.Color = .blank,
    text: ?[:0]const u8 = null,
    fontSize: ?i32 = null,
    fontStyle: my_fonts.FontStyle = .normal,
    underlined: bool = false,
    underline_width: ?i32 = null,
    line_height_factor: ?f32 = null,
    bullet_color: ?rl.Color = null,
    texture: ?rl.Texture2D = null,
    bullet_symbol: [*:0]const u8 = "",
    reveal_step: usize = 0,
    text_shadow: ?slides.TextShadow = null,
    crowd: ?slides.CrowdSpec = null,
};

const RenderedSlide = struct {
    elements: std.ArrayList(RenderElement) = undefined,
    steps: std.ArrayList(animation.Step) = undefined,
    transition: animation.Transition = .{},

    fn new(allocator: std.mem.Allocator) !*RenderedSlide {
        var self: *RenderedSlide = try allocator.create(RenderedSlide);
        self.* = .{};
        self.elements = std.ArrayList(RenderElement).empty;
        self.steps = std.ArrayList(animation.Step).empty;
        return self;
    }
};

pub const RevealState = struct {
    visible_through: usize = 0,
    active_step: ?usize = null,
    active_progress: f32 = 1.0,
};

pub const TransitionState = struct {
    previous_slide: ?i32 = null,
    previous_step: usize = 0,
    spec: animation.Transition = .{},
    progress: f32 = 1.0,
    direction: i8 = 1,
};

const RenderTransform = struct {
    offset: rl.Vector2 = .{ .x = 0, .y = 0 },
    opacity: f32 = 1.0,
};

pub const SlideshowRenderer = struct {
    renderedSlides: std.ArrayList(*RenderedSlide) = undefined,
    allocator: std.mem.Allocator = undefined,
    md_parser: markdownlineparser.MdLineParser = .{},
    texture_cache: TextureCache,
    fonts: *my_fonts.AvailableFonts,
    qr_code: qrcode.Code = .{},

    pub fn new(allocator: std.mem.Allocator, fonts: *my_fonts.AvailableFonts) !*SlideshowRenderer {
        var self: *SlideshowRenderer = try allocator.create(SlideshowRenderer);
        self.* = .{
            .texture_cache = .init(allocator),
            .fonts = fonts,
        };
        self.*.allocator = allocator;
        self.renderedSlides = std.ArrayList(*RenderedSlide).empty;
        self.md_parser.init(self.allocator);
        return self;
    }

    pub fn deinit(self: *SlideshowRenderer) void {
        self.texture_cache.deinit(self.allocator);
    }

    pub fn preRender(self: *SlideshowRenderer, slideshow: *const slides.SlideShow, slideshow_filp: []const u8) !void {
        log.debug("ENTER preRender", .{});
        if (slideshow.slides.items.len == 0) {
            log.warn("NO SLIDED!!!", .{});
            return;
        }

        self.renderedSlides.shrinkRetainingCapacity(0);

        for (slideshow.slides.items, 0..) |slide, i| {
            const slide_number = i + 1;

            if (slide.items == null or slide.items.?.items.len == 0) {
                log.warn("Slide {d} has NO ITEMS!", .{slide_number});
            }

            // add a renderedSlide
            const renderSlide = try RenderedSlide.new(self.allocator);
            renderSlide.transition = slide.transition;

            if (slide.items) |items| {
                for (items.items) |item| {
                    switch (item.kind) {
                        .background => try self.createBg(renderSlide, item, slideshow_filp),
                        .textbox => try self.preRenderTextBlock(renderSlide, item, slide_number),
                        .img => try self.createImg(renderSlide, item, slideshow_filp),
                        .crowd => try self.createCrowd(renderSlide, item),
                    }
                }
            }

            // now add the slide
            try self.renderedSlides.append(self.allocator, renderSlide);
        }
        log.debug("LEAVE preRender with {d} slides", .{self.renderedSlides.items.len});
    }

    pub fn stepCount(self: *const SlideshowRenderer, slide_number: i32) usize {
        if (slide_number < 0 or slide_number >= self.renderedSlides.items.len) return 0;
        return self.renderedSlides.items[@intCast(slide_number)].steps.items.len;
    }

    pub fn stepAt(self: *const SlideshowRenderer, slide_number: i32, step_index: usize) ?animation.Step {
        if (slide_number < 0 or slide_number >= self.renderedSlides.items.len or step_index == 0) return null;
        const steps = self.renderedSlides.items[@intCast(slide_number)].steps.items;
        if (step_index > steps.len) return null;
        return steps[step_index - 1];
    }

    pub fn transitionForSlide(self: *const SlideshowRenderer, slide_number: i32) animation.Transition {
        if (slide_number < 0 or slide_number >= self.renderedSlides.items.len) return .{};
        return self.renderedSlides.items[@intCast(slide_number)].transition;
    }

    fn appendStep(self: *SlideshowRenderer, renderSlide: *RenderedSlide, spec: animation.ItemSpec) !usize {
        try renderSlide.steps.append(self.allocator, animation.Step.fromItem(spec));
        return renderSlide.steps.items.len;
    }

    fn wholeItemStep(self: *SlideshowRenderer, renderSlide: *RenderedSlide, item: slides.SlideItem) !usize {
        if (item.animation) |spec| return try self.appendStep(renderSlide, spec);
        return 0;
    }

    fn createBg(self: *SlideshowRenderer, renderSlide: *RenderedSlide, item: slides.SlideItem, slideshow_filp: []const u8) !void {
        log.info("pre-rendering bg {}", .{item});
        if (item.img_path) |p| {
            const result = try self.texture_cache.getImageTexture(p, slideshow_filp);
            if (result) |tex_info| {
                const reveal_step = try self.wholeItemStep(renderSlide, item);
                try renderSlide.elements.append(self.allocator, RenderElement{ .kind = .background, .texture = tex_info.texture, .reveal_step = reveal_step });
            }
        } else {
            if (item.color) |color| {
                log.info("bg has color {}", .{color});
                const reveal_step = try self.wholeItemStep(renderSlide, item);
                try renderSlide.elements.append(self.allocator, RenderElement{ .kind = .background, .color = color, .reveal_step = reveal_step });
            } else {
                log.info("bg has NO COLOR", .{});
            }
        }
    }

    fn createCrowd(self: *SlideshowRenderer, renderSlide: *RenderedSlide, item: slides.SlideItem) !void {
        try renderSlide.elements.append(self.allocator, .{
            .kind = .crowd,
            .position = item.position,
            .size = item.size,
            .crowd = item.crowd,
            .reveal_step = try self.wholeItemStep(renderSlide, item),
        });
    }

    fn preRenderTextBlock(self: *SlideshowRenderer, renderSlide: *RenderedSlide, item: slides.SlideItem, slide_number: usize) !void {
        // for line in lines:
        //     if line is bulleted: emit bullet, adjust x pos
        //     render spans
        log.debug("ENTER preRenderTextBlock for slide {d} : {}", .{ slide_number, item });
        const spaces_per_indent: usize = 4;
        var fontSize: i32 = 0;
        var line_height_bullet_width: rl.Vector2 = .{ .x = 0.0, .y = 0.0 };
        var item_reveal_step: usize = 0;
        if (item.animation) |spec| {
            if (spec.by == .item) item_reveal_step = try self.appendStep(renderSlide, spec);
        }

        // box without text, but with color: render a colored box!
        if (item.text == null and item.color != null) {
            if (item_reveal_step == 0 and item.animation != null) {
                item_reveal_step = try self.appendStep(renderSlide, item.animation.?);
            }
            log.debug("preRenderTextBlock (color) creating RenderElement", .{});
            try renderSlide.elements.append(self.allocator, RenderElement{
                .kind = .text,
                .position = item.position,
                .size = item.size,
                .fontSize = null,
                .underline_width = null,
                .line_height_factor = null,
                .text = null,
                .color = item.color,
                .reveal_step = item_reveal_step,
            });
            log.debug("LEAVE preRenderTextBlock (color) for slide {d}", .{slide_number});
            return;
        }

        if (item.fontSize) |fs| {
            // TODO: this might be inaccurate if we use different fonts in the text block
            // whose pixel sizes vary significantly for given font sizes
            line_height_bullet_width = self.lineHightAndBulletWidthForFontSize(self.fonts.normal, fs);
            fontSize = fs;
        } else {
            // no fontsize  - error!
            log.err("No fontsize for text {?s}", .{item.text});
            return;
        }
        const bulletColor = item.bullet_color orelse {
            // no bullet color - error!
            log.err("No bullet color for text {?s}", .{item.text});
            return;
        };

        // actually, checking for a bullet symbol only makes sense if anywhere in the text a bulleted item exists
        // but we'll leave it like this for now
        // not sure I want to allocate here, though
        var bulletSymbol: [:0]const u8 = undefined;
        if (item.bullet_symbol) |bs| {
            bulletSymbol = try std.fmt.allocPrintSentinel(self.allocator, "{s}", .{bs}, 0);
        } else {
            // no bullet symbol - error
            log.err("No bullet symbol for text {?s}", .{item.text});
            return;
        }

        const color = item.color orelse return;
        const underline_width = item.underline_width orelse 0;
        const line_height_factor = item.line_height_factor orelse 1.0;

        if (item.text) |t| {
            const tl_pos = rl.Vector2{ .x = item.position.x, .y = item.position.y };
            var layoutContext = TextLayoutContext{
                .available_size = .{ .x = item.size.x, .y = item.size.y },
                .origin_pos = tl_pos,
                .current_pos = tl_pos,
                .fontSize = fontSize,
                .underline_width = @intCast(underline_width),
                .color = color,
                .text = "", // will be overridden immediately
                .current_line_height = line_height_bullet_width.y * line_height_factor, // will be overridden immediately but needed if text starts with empty line(s)
                .current_line_height_factor = line_height_factor,
                .reveal_step = item_reveal_step,
                .text_shadow = item.text_shadow,
            };

            // slide number
            var slideNumStr: [10]u8 = undefined;
            _ = try std.fmt.bufPrintZ(&slideNumStr, "{d}", .{slide_number});
            const new_t = try std.mem.replaceOwned(u8, self.allocator, t, "$slide_number", &slideNumStr);

            // split into lines
            var it = std.mem.splitScalar(u8, new_t, '\n');
            while (it.next()) |line| {
                if (line.len == 0) {
                    // empty line
                    layoutContext.current_pos.y += layoutContext.current_line_height;
                    continue;
                }
                // find out, if line is a list item:
                //    - starts with `-` or `>`
                var bullet_indent_in_spaces: usize = 0;
                const is_bulleted = self.countIndentOfBullet(line, &bullet_indent_in_spaces);
                var line_reveal_step = item_reveal_step;
                if (item.animation) |spec| {
                    const has_visible_content = std.mem.trim(u8, line, " \t").len > 0;
                    if (has_visible_content and startsLineStep(spec.by, is_bulleted)) line_reveal_step = try self.appendStep(renderSlide, spec);
                }
                const indent_level = bullet_indent_in_spaces / spaces_per_indent;
                const indent_in_pixels = line_height_bullet_width.x * @as(f32, @floatFromInt(indent_level));
                var available_width = item.size.x - indent_in_pixels;
                layoutContext.available_size.x = available_width;
                layoutContext.origin_pos.x = tl_pos.x + indent_in_pixels;
                layoutContext.current_pos.x = tl_pos.x + indent_in_pixels;
                layoutContext.fontSize = fontSize;
                layoutContext.underline_width = @intCast(underline_width);
                layoutContext.color = color;
                layoutContext.text = line;
                layoutContext.reveal_step = line_reveal_step;

                if (is_bulleted) {
                    // 1. add indented bullet symbol at the current pos
                    try renderSlide.elements.append(self.allocator, RenderElement{
                        .kind = .text,
                        .position = .{ .x = tl_pos.x + indent_in_pixels, .y = layoutContext.current_pos.y },
                        .size = .{ .x = available_width, .y = layoutContext.available_size.y },
                        .fontSize = fontSize,
                        .underline_width = underline_width,
                        .text = bulletSymbol,
                        .color = bulletColor,
                        .reveal_step = line_reveal_step,
                        .text_shadow = item.text_shadow,
                    });
                    // 2. increase indent by 1 and add indented text block
                    available_width -= line_height_bullet_width.x;
                    layoutContext.origin_pos.x += line_height_bullet_width.x;
                    layoutContext.current_pos.x = layoutContext.origin_pos.x;
                    layoutContext.available_size.x = available_width;
                    layoutContext.text = std.mem.trimStart(u8, line, " \t->");
                }

                try self.renderMdBlock(renderSlide, &layoutContext);

                // advance to the next line
                layoutContext.current_pos.x = tl_pos.x;
                layoutContext.current_pos.y += layoutContext.current_line_height;

                // don't render (much) beyond size
                //
                // with this check, we will not render anything that would start outside the size rect.
                // Also, lines using the regular font will not exceed the size rect.
                // however,
                // - if a line uses a bigger font (more pixels) than the regular font, we might still exceed the size rect by the delta
                // - we might still draw underlines beyond the size.y if the last line fits perfectly.
                if (layoutContext.current_pos.y >= tl_pos.y + item.size.y - line_height_bullet_width.y) {
                    break;
                }
            }
        }
        log.debug("LEAVE preRenderTextBlock for slide {d}", .{slide_number});
    }

    const TextLayoutContext = struct {
        origin_pos: rl.Vector2 = .{ .x = 0.0, .y = 0.0 },
        current_pos: rl.Vector2 = .{ .x = 0.0, .y = 0.0 },
        available_size: rl.Vector2 = .{ .x = 0.0, .y = 0.0 },
        current_line_height: f32 = 0,
        current_line_height_factor: f32 = 0,
        fontSize: i32 = 0,
        underline_width: usize = 0,
        color: rl.Color = .blank,
        text: []const u8 = undefined,
        reveal_step: usize = 0,
        text_shadow: ?slides.TextShadow = null,
    };

    fn renderMdBlock(self: *SlideshowRenderer, renderSlide: *RenderedSlide, layoutContext: *TextLayoutContext) !void {
        //     remember original pos. its X will need to be reset at every line wrap
        //     for span in spans:
        //         calc size.x of span
        //         if width > available_width:
        //             reduce width by chopping of words to the right until it fits
        //             repeat that for the remainding shit
        //             for split in splits:
        //                # treat them as lines.
        //             if lastsplit did not end with newline
        //                 we continue the next span right after the last split
        //
        //  the visible line hight is determined by the highest text span in the visible line!
        log.debug("ENTER renderMdBlock ", .{});
        self.md_parser.init(self.allocator);
        try self.md_parser.parseLine(layoutContext.text);
        if (self.md_parser.result_spans) |spans| {
            if (spans.items.len == 0) {
                log.debug("LEAVE1 preRenderTextBlock ", .{});
                return;
            }
            log.debug("SPANS:", .{});
            self.md_parser.logSpans();
            log.debug("ENDSPANS", .{});

            const default_color = layoutContext.color;

            var element = RenderElement{
                .kind = .text,
                .size = layoutContext.available_size,
                .color = default_color,
                .fontSize = layoutContext.fontSize,
                .underline_width = @intCast(layoutContext.underline_width),
                .reveal_step = layoutContext.reveal_step,
                .text_shadow = layoutContext.text_shadow,
            };

            for (spans.items) |span| {
                if (span.text.?[0] == 0) {
                    log.debug("SKIPPING ZERO LENGTH SPAN", .{});
                    continue;
                }
                log.debug("new span, len=: `{d}`", .{span.text.?.len});
                // work out the font
                var font_used: rl.Font = self.fonts.normal;
                element.fontStyle = .normal;
                element.underlined = span.styleflags & markdownlineparser.StyleFlags.underline > 0;

                if (span.styleflags & markdownlineparser.StyleFlags.bold > 0) {
                    element.fontStyle = .bold;
                    font_used = self.fonts.bold;
                }
                if (span.styleflags & markdownlineparser.StyleFlags.italic > 0) {
                    element.fontStyle = .italic;
                    font_used = self.fonts.italic;
                }
                if (span.styleflags & markdownlineparser.StyleFlags.zig > 0) {
                    element.fontStyle = .zig;
                    font_used = self.fonts.zig;
                }
                if (span.styleflags & (markdownlineparser.StyleFlags.bold | markdownlineparser.StyleFlags.italic) == (markdownlineparser.StyleFlags.bold | markdownlineparser.StyleFlags.italic)) {
                    element.fontStyle = .bolditalic;
                    font_used = self.fonts.bolditalic;
                }

                // work out the color
                element.color = default_color;
                if (span.styleflags & markdownlineparser.StyleFlags.colored > 0) {
                    if (span.color_override) |co| {
                        element.color = co;
                    } else {
                        log.debug("  ************************* NO COLOR OVERRIDE (styleflags: {x:02})", .{span.styleflags});
                        element.color = default_color;
                    }
                }

                // check the line hight of this span's fontstyle so we can check whether it wrapped
                // TODO: somehow we had ineffective code in here

                // check if whole span fits width. - let's be opportunistic!
                // if not, start chopping off from the right until it fits
                // keep rest for later
                // Q: is it better to try to pop words from the left until
                //    the text doesn't fit anymore?
                // A: probably yes. Lines can be pretty long and hence wrap
                //    multiple times. Trying to find the max amount of words
                //    that fit until the first break is necessary is faster
                //    in that case.
                //    Also, doing it this way makes it pretty straight-forward
                //    to wrap superlong words that wouldn't even fit the
                //    current line width - and can be broken down easily.
                //    --
                //    One more thing: as we're looping through the spans,
                //        we don't render from the start of the line but
                //        from the end of the last span.

                // check if whole line fits
                // orelse start wrapping (see above)
                //
                //

                var attempted_span_size: rl.Vector2 = undefined;
                var available_width: f32 = layoutContext.origin_pos.x + layoutContext.available_size.x - layoutContext.current_pos.x;
                var render_text_c = try self.styledTextblockSize_toCstring(span.text.?, layoutContext.fontSize, font_used, &attempted_span_size);
                log.debug("available_width: {d}, attempted_span_size: {d:3.0}", .{ available_width, attempted_span_size.x });
                if (attempted_span_size.x < available_width) {
                    // we did not wrap so the entire span can be output!
                    element.text = render_text_c;
                    element.position = layoutContext.current_pos;
                    element.size.x = attempted_span_size.x;
                    //element.size = attempted_span_size;
                    log.debug(">>>>>>> appending non-wrapping text element: {?s}@{d:3.0},{d:3.0}", .{ element.text, element.position.x, element.position.y });
                    try renderSlide.elements.append(self.allocator, element);
                    // advance render pos
                    layoutContext.current_pos.x += attempted_span_size.x;
                    // if something is rendered into the currend line, then adjust the line height if necessary
                    if (attempted_span_size.y > layoutContext.current_line_height) {
                        // TODO: check if this is correct: we multiply the new line height by the line_height_factor.
                        //       maybe we should only add the delta between lhf = 1.0 and current lhf
                        layoutContext.current_line_height = attempted_span_size.y * layoutContext.current_line_height_factor;
                    }
                } else {
                    // we need to check with how many words  we can get away with:
                    log.debug("  -> we need to check where to wrap!", .{});

                    // first, let's pseudo-split into words:
                    //   (what's so pseudo about that? we don't actually split, we just remember separator positions)
                    // we find the first index of word-separator, then the 2nd, ...
                    // and use it to determine the length of the slice
                    var lastIdxOfSpace: usize = 0;
                    var lastConsumedIdx: usize = 0;
                    var currentIdxOfSpace: usize = 0;
                    var wordCount: usize = 0;
                    // TODO: FIXME: we don't like tabs
                    while (true) {
                        log.debug("lastConsumedIdx: {}, lastIdxOfSpace: {}, currentIdxOfSpace: {}", .{ lastConsumedIdx, lastIdxOfSpace, currentIdxOfSpace });
                        if (std.mem.indexOfScalarPos(u8, span.text.?, currentIdxOfSpace, ' ')) |idx| {
                            currentIdxOfSpace = idx;
                            // look-ahead only allowed if there is more text
                            if (span.text.?.len > currentIdxOfSpace + 1) {
                                if (span.text.?[currentIdxOfSpace + 1] == ' ') {
                                    currentIdxOfSpace += 1; // jump over consecutive spaces
                                    continue;
                                }
                            }
                            if (currentIdxOfSpace == 0) {
                                // special case: we start with a space
                                // we start searching for the next space 1 after the last found one
                                if (currentIdxOfSpace + 1 < span.text.?.len) {
                                    currentIdxOfSpace += 1;
                                    continue;
                                } else {
                                    // in this case we better break or else we will loop forever
                                    break;
                                }
                            }
                            wordCount += 1;
                        } else {
                            log.debug("no more space found", .{});
                            if (wordCount == 0) {
                                wordCount = 1;
                            }
                            // no more space found, render the rest and then break
                            if (lastConsumedIdx < span.text.?.len - 1) {
                                // render the remainder
                                currentIdxOfSpace = span.text.?.len; //- 1;
                                log.debug("Trying with the remainder", .{});
                            } else {
                                break;
                            }
                        }
                        log.debug("current idx of spc {d}", .{currentIdxOfSpace});
                        // try if we fit. if we don't -> render up until last idx
                        var render_text = span.text.?[lastConsumedIdx..currentIdxOfSpace];
                        render_text_c = try self.styledTextblockSize_toCstring(render_text, layoutContext.fontSize, font_used, &attempted_span_size);
                        log.debug("   current available_width: {d}, attempted_span_size: {d:3.0}", .{ available_width, attempted_span_size.x });
                        if (attempted_span_size.x > available_width and wordCount > 1) {
                            // we wrapped!
                            // so render everything up until the last word
                            // then, render the new word in the new line?
                            if (wordCount == 1 and false) {
                                // special case: the first word wrapped, so we need to split it
                                // TODO: implement me
                                log.debug(">>>>>>>>>>>>> FIRST WORD !!!!!!!!!!!!!!!!!!! <<<<<<<<<<<<<<<<", .{});
                            } else {
                                // we check how large the current string (without that last word that caused wrapping) really is, to adjust our new current_pos.x:
                                available_width = layoutContext.origin_pos.x + layoutContext.available_size.x - layoutContext.current_pos.x;
                                const end_of_string_pos = if (lastIdxOfSpace > span.text.?.len) span.text.?.len else lastIdxOfSpace;
                                render_text = span.text.?[lastConsumedIdx..end_of_string_pos];
                                render_text_c = try self.styledTextblockSize_toCstring(render_text, layoutContext.fontSize, font_used, &attempted_span_size);
                                lastConsumedIdx = lastIdxOfSpace;
                                lastIdxOfSpace = currentIdxOfSpace;
                                element.text = render_text_c;
                                element.position = layoutContext.current_pos;
                                element.size.x = attempted_span_size.x;
                                // element.size = attempted_span_size;
                                log.debug(">>>>>>> appending wrapping text element: {?s} width={d:3.0}", .{ element.text, attempted_span_size.x });
                                try renderSlide.elements.append(self.allocator, element);
                                // advance render pos
                                layoutContext.current_pos.x += attempted_span_size.x;
                                // something is rendered into the currend line, so adjust the line height if necessary
                                if (attempted_span_size.y > layoutContext.current_line_height) {
                                    layoutContext.current_line_height = attempted_span_size.y * layoutContext.current_line_height_factor;
                                }

                                // we line break here and render the remaining word
                                //    hmmm. if we render the remaining word - further words are likely to be rendered, too
                                //    so maybe skip rendering it now?
                                log.debug(">>> BREAKING THE LINE, height: {}", .{layoutContext.current_line_height});
                                layoutContext.current_pos.x = layoutContext.origin_pos.x;
                                layoutContext.current_pos.y += layoutContext.current_line_height;
                                layoutContext.current_line_height = 0;
                                available_width = layoutContext.origin_pos.x + layoutContext.available_size.x - layoutContext.current_pos.x;
                            }
                        } else {
                            // if it's the last, uncommitted word
                            if (lastIdxOfSpace >= currentIdxOfSpace) {
                                available_width = layoutContext.origin_pos.x + layoutContext.available_size.x - layoutContext.current_pos.x;
                                render_text = span.text.?[lastConsumedIdx..currentIdxOfSpace];
                                render_text_c = try self.styledTextblockSize_toCstring(render_text, layoutContext.fontSize, font_used, &attempted_span_size);
                                lastConsumedIdx = lastIdxOfSpace;
                                lastIdxOfSpace = currentIdxOfSpace;
                                element.text = render_text_c;
                                element.position = layoutContext.current_pos;
                                // element.size = attempted_span_size;
                                log.debug(">>>>>>> appending final text element: {?s} width={d:3.0}", .{ element.text, attempted_span_size.x });
                                element.size.x = attempted_span_size.x;
                                try renderSlide.elements.append(self.allocator, element);
                                // advance render pos
                                layoutContext.current_pos.x += attempted_span_size.x;
                                // something is rendered into the currend line, so adjust the line height if necessary
                                if (attempted_span_size.y > layoutContext.current_line_height) {
                                    layoutContext.current_line_height = attempted_span_size.y * layoutContext.current_line_height_factor;
                                }

                                // let's not break the line because of the last word
                                // log.debug(">>> BREAKING THE LINE, height: {}", .{layoutContext.current_line_height});
                                // layoutContext.current_pos.x = layoutContext.origin_pos.x;
                                // layoutContext.current_pos.y += layoutContext.current_line_height;
                                // layoutContext.current_line_height = 0;
                                break; // it's the last word after all
                            }
                        }

                        lastIdxOfSpace = currentIdxOfSpace + 1;
                        // we start searching for the next space 1 after the last found one
                        if (currentIdxOfSpace + 1 < span.text.?.len) {
                            currentIdxOfSpace += 1;
                        } else {
                            //break;
                        }
                    }
                    // we could have run out of text to check for wrapping
                    // if that's the case: render the remainder
                }
            }
        } else {
            // no spans
            log.debug("LEAVE2 renderMdBlock ", .{});
            return;
        }
        log.debug("LEAVE3 renderMdBlock ", .{});
    }

    fn lineHightAndBulletWidthForFontSize(self: *SlideshowRenderer, font: rl.Font, fontsize: i32) rl.Vector2 {
        _ = self;
        var size: rl.Vector2 = .{ .x = 0.0, .y = 0.0 };
        var ret: rl.Vector2 = .{ .x = 0.0, .y = 0.0 };
        // TODO: this might be inaccurate if we use different fonts in the text block
        // whose pixel sizes vary significantly for given font sizes
        const text = "FontCheck";
        size = rl.measureTextEx(font, text, @floatFromInt(fontsize), 0);
        ret.y = size.y;
        const bullet_text = "> "; // TODO this should ideally honor the real bullet symbol but I don't care atm
        size = rl.measureTextEx(font, bullet_text, @floatFromInt(fontsize), 0);
        ret.x = size.x;
        return ret;
    }

    fn countIndentOfBullet(self: *SlideshowRenderer, line: []const u8, indent_out: *usize) bool {
        _ = self;
        var indent: usize = 0;
        for (line) |c| {
            if (c == '-' or c == '>') {
                indent_out.* = indent;
                return true;
            }
            if (c != ' ' and c != '\t') {
                return false;
            }
            if (c == ' ') {
                indent += 1;
            }
            if (c == '\t') {
                indent += 4;
                // TODO: make tab to spaces ratio configurable
            }
        }
        return false;
    }

    fn toCString(self: *SlideshowRenderer, text: []const u8) ![:0]const u8 {
        return try self.allocator.dupeZ(u8, text);
    }

    fn styledTextblockSize_toCstring(self: *SlideshowRenderer, text: []const u8, fontsize: i32, font: rl.Font, size_out: *rl.Vector2) ![:0]const u8 {
        const ctext = try self.toCString(text);
        log.debug("cstring: of {s} = `{s}`", .{ text, ctext });
        if (ctext[0] == 0) {
            size_out.x = 0;
            size_out.y = 0;
            return ctext;
        }
        size_out.* = rl.measureTextEx(font, ctext, @floatFromInt(fontsize), 0);
        return ctext;
    }

    fn createImg(self: *SlideshowRenderer, renderSlide: *RenderedSlide, item: slides.SlideItem, slideshow_filp: []const u8) !void {
        if (item.img_path) |p| {
            const result = self.texture_cache.getImageTexture(p, slideshow_filp) catch |err| {
                log.warn("Could not load image {s}: {}", .{ p, err });
                return; // Skip element
            };

            if (result) |tex_info| {
                const reveal_step = try self.wholeItemStep(renderSlide, item);
                var final_size = item.size;

                // Calculate dimensions if needed
                const natural_w: f32 = @floatFromInt(tex_info.natural_width);
                const natural_h: f32 = @floatFromInt(tex_info.natural_height);
                const aspect_ratio = natural_w / natural_h;

                const has_w = item.size.x > 0;
                const has_h = item.size.y > 0;

                if (!has_w and !has_h) {
                    // Neither specified: use natural dimensions with scale and ratio
                    var w = natural_w;
                    var h = natural_h;

                    // Apply scale
                    if (item.scale) |scale| {
                        w *= scale;
                        h *= scale;
                    }

                    // Apply ratio: w/h = ratio, so h = w/ratio
                    if (item.ratio) |ratio| {
                        h = w / ratio;
                    }

                    final_size = .{ .x = w, .y = h };
                } else if (has_w and !has_h) {
                    // Only width specified: calculate height from aspect ratio
                    final_size.y = final_size.x / aspect_ratio;
                } else if (!has_w and has_h) {
                    // Only height specified: calculate width from aspect ratio
                    final_size.x = final_size.y * aspect_ratio;
                }
                // else: both specified, use as-is

                try renderSlide.elements.append(self.allocator, RenderElement{
                    .kind = .image,
                    .position = item.position,
                    .size = final_size,
                    .texture = tex_info.texture,
                    .reveal_step = reveal_step,
                });
            }
        }
    }

    pub fn render(
        self: *SlideshowRenderer,
        slide_number: i32,
        reveal: RevealState,
        transition: TransitionState,
        pos: rl.Vector2,
        size: rl.Vector2,
        internal_render_size: rl.Vector2,
        crowd_snapshot: ?crowdplay.Snapshot,
        previous_crowd_snapshot: ?crowdplay.Snapshot,
        crowd_url: []const u8,
    ) !void {
        if (self.renderedSlides.items.len == 0 or slide_number < 0 or slide_number >= self.renderedSlides.items.len) return;

        const transition_progress = animation.eased(transition.progress);
        const transforms = slideTransitionTransforms(transition.spec.effect, transition_progress, transition.direction, size);

        if (transition.previous_slide) |previous_slide| {
            if (transition.spec.effect != .none and transition.spec.effect != .appear and transition_progress < 1.0) {
                try self.renderOneSlide(
                    previous_slide,
                    .{ .visible_through = transition.previous_step },
                    transforms.outgoing,
                    pos,
                    size,
                    internal_render_size,
                    previous_crowd_snapshot,
                    crowd_url,
                );
            }
        }
        try self.renderOneSlide(slide_number, reveal, transforms.incoming, pos, size, internal_render_size, crowd_snapshot, crowd_url);
    }

    fn renderOneSlide(
        self: *SlideshowRenderer,
        slide_number: i32,
        reveal: RevealState,
        slide_transform: RenderTransform,
        pos: rl.Vector2,
        size: rl.Vector2,
        internal_render_size: rl.Vector2,
        crowd_snapshot: ?crowdplay.Snapshot,
        crowd_url: []const u8,
    ) !void {
        if (slide_number < 0 or slide_number >= self.renderedSlides.items.len) return;
        const slide = self.renderedSlides.items[@intCast(slide_number)];

        for (slide.elements.items) |element| {
            var progress: f32 = 1.0;
            if (element.reveal_step > 0) {
                if (reveal.active_step != null and reveal.active_step.? == element.reveal_step) {
                    progress = reveal.active_progress;
                } else if (element.reveal_step > reveal.visible_through) {
                    progress = 0.0;
                }
            }
            if (progress <= 0) continue;

            const effect = if (element.reveal_step > 0) slide.steps.items[element.reveal_step - 1].effect else animation.Effect.none;
            const item_transform = itemAnimationTransform(effect, animation.eased(progress), size, internal_render_size);
            const transform = combineTransforms(slide_transform, item_transform);
            if (transform.opacity <= 0) continue;

            switch (element.kind) {
                .background => {
                    if (element.texture) |texture| {
                        renderImg(.{ .x = 0.0, .y = 0.0 }, internal_render_size, texture, .white, .blank, pos, size, internal_render_size, transform);
                    } else if (element.color) |color| {
                        renderBgColor(color, pos, size, transform);
                    }
                },
                .text => self.renderText(&element, pos, size, internal_render_size, transform),
                .image => {
                    if (element.texture) |texture| {
                        renderImg(element.position, element.size, texture, .white, .blank, pos, size, internal_render_size, transform);
                    }
                },
                .crowd => self.renderCrowd(&element, crowd_snapshot, crowd_url, pos, size, internal_render_size, transform),
            }
        }
    }

    fn renderCrowd(
        self: *SlideshowRenderer,
        item: *const RenderElement,
        snapshot_opt: ?crowdplay.Snapshot,
        crowd_url: []const u8,
        slide_tl: rl.Vector2,
        slide_size: rl.Vector2,
        internal_render_size: rl.Vector2,
        transform: RenderTransform,
    ) void {
        const spec = item.crowd orelse return;
        const snapshot = snapshot_opt orelse crowdplay.Snapshot{};
        var logical_pos = item.position;
        var logical_size = item.size;
        if (logical_size.x <= 0) {
            logical_pos.x = 100;
            logical_size.x = internal_render_size.x - 200;
        }
        if (logical_size.y <= 0) {
            logical_pos.y = 80;
            logical_size.y = internal_render_size.y - 160;
        }
        const screen_pos = translated(slidePosToRenderPos(logical_pos, slide_tl, slide_size, internal_render_size), transform.offset);
        const screen_size = slideSizeToRenderSize(logical_size, slide_size, internal_render_size);
        const slide_scale = slide_size.y / internal_render_size.y;
        const scale = @max(0.1, @min(slide_scale, @min(screen_size.x / 1000.0, screen_size.y / 600.0)));
        const panel = rl.Rectangle{ .x = screen_pos.x, .y = screen_pos.y, .width = screen_size.x, .height = screen_size.y };
        const opacity = transform.opacity;

        rl.drawRectangleRounded(panel, 0.04, 16, colorWithOpacity(.{ .r = 10, .g = 13, .b = 27, .a = 242 }, opacity));
        rl.drawRectangleRoundedLinesEx(panel, 0.04, 16, @max(1.0, 2.0 * scale), colorWithOpacity(.{ .r = 105, .g = 112, .b = 255, .a = 110 }, opacity));

        const connected_text = std.fmt.bufPrintZ(&crowd_text_buffer_a, "{d} live", .{snapshot.connected}) catch return;
        const pulse = @as(f32, 0.72) + @as(f32, 0.28) * std.math.sin(@as(f32, @floatCast(rl.getTime())) * 3.0);
        rl.drawCircleV(.{ .x = panel.x + panel.width - 194 * scale, .y = panel.y + 54 * scale }, (7.0 + pulse * 2.0) * scale, colorWithOpacity(.{ .r = 77, .g = 255, .b = 181, .a = 255 }, opacity));
        drawCrowdText(self.fonts.bold, connected_text, .{ .x = panel.x + panel.width - 172 * scale, .y = panel.y + 35 * scale }, 30 * scale, colorWithOpacity(.{ .r = 205, .g = 255, .b = 232, .a = 255 }, opacity));

        switch (spec.kind) {
            .join => self.renderCrowdJoin(spec, snapshot, crowd_url, panel, scale, opacity),
            .poll => self.renderCrowdPoll(spec, snapshot, crowd_url, panel, scale, opacity),
        }
    }

    fn renderCrowdJoin(self: *SlideshowRenderer, spec: slides.CrowdSpec, snapshot: crowdplay.Snapshot, crowd_url: []const u8, panel: rl.Rectangle, scale: f32, opacity: f32) void {
        const eyebrow = "CROWDPLAY\x00";
        drawCrowdText(self.fonts.bold, eyebrow, .{ .x = panel.x + 72 * scale, .y = panel.y + 52 * scale }, 24 * scale, colorWithOpacity(.{ .r = 147, .g = 156, .b = 255, .a = 255 }, opacity));
        const prompt = std.fmt.bufPrintZ(&crowd_text_buffer_b, "{s}", .{spec.prompt}) catch return;
        drawCrowdTextFitted(self.fonts.bold, prompt, .{ .x = panel.x + 72 * scale, .y = panel.y + 116 * scale }, 62 * scale, panel.width - 144 * scale, colorWithOpacity(.white, opacity));
        drawCrowdText(self.fonts.normal, "Open this address on your phone\x00", .{ .x = panel.x + 74 * scale, .y = panel.y + 214 * scale }, 28 * scale, colorWithOpacity(.{ .r = 177, .g = 185, .b = 214, .a = 255 }, opacity));

        const qr_side = @min(panel.width * 0.30, panel.height * 0.55);
        const qr_region = rl.Rectangle{
            .x = panel.x + panel.width - qr_side - 72 * scale,
            .y = panel.y + 184 * scale,
            .width = qr_side,
            .height = qr_side,
        };
        const url_panel = rl.Rectangle{ .x = panel.x + 72 * scale, .y = panel.y + 278 * scale, .width = panel.width - qr_side - 190 * scale, .height = 116 * scale };
        rl.drawRectangleRounded(url_panel, 0.16, 12, colorWithOpacity(.{ .r = 24, .g = 29, .b = 54, .a = 255 }, opacity));
        const url = std.fmt.bufPrintZ(&crowd_text_buffer_a, "{s}", .{if (crowd_url.len > 0) crowd_url else "Crowdplay server unavailable"}) catch return;
        drawCrowdTextFitted(self.fonts.bold, url, .{ .x = url_panel.x + 34 * scale, .y = url_panel.y + 34 * scale }, 34 * scale, url_panel.width - 68 * scale, colorWithOpacity(.{ .r = 113, .g = 242, .b = 255, .a = 255 }, opacity));
        if (crowd_url.len > 0 and self.qr_code.ensure(crowd_url)) drawQrCode(&self.qr_code, qr_region, opacity);

        drawSwarm(snapshot, null, .{
            .x = panel.x + panel.width * 0.30,
            .y = panel.y + panel.height * 0.70,
            .width = panel.width * 0.34,
            .height = panel.height * 0.22,
        }, scale, opacity);
        const people = std.fmt.bufPrintZ(&crowd_text_buffer_b, "{d} {s} in the room", .{ snapshot.connected, if (snapshot.connected == 1) "person" else "people" }) catch return;
        const measured = rl.measureTextEx(self.fonts.bold, people, 34 * scale, 0);
        drawCrowdText(self.fonts.bold, people, .{ .x = panel.x + (panel.width - measured.x) / 2, .y = panel.y + panel.height - 92 * scale }, 34 * scale, colorWithOpacity(.{ .r = 205, .g = 211, .b = 239, .a = 255 }, opacity));
    }

    fn renderCrowdPoll(self: *SlideshowRenderer, spec: slides.CrowdSpec, snapshot: crowdplay.Snapshot, crowd_url: []const u8, panel: rl.Rectangle, scale: f32, opacity: f32) void {
        const live_poll: ?crowdplay.PollSnapshot = if (snapshot.poll) |poll|
            if (poll.id.eql(spec.id)) poll else null
        else
            null;
        const available = crowd_url.len > 0 and live_poll != null;
        const open = if (live_poll) |poll| poll.open else false;
        const revealed = if (live_poll) |poll| poll.revealed else false;
        const total = if (live_poll) |poll| poll.total else 0;

        const poll_label = if (!available) "POLL OFFLINE\x00" else if (open) "LIVE POLL\x00" else "POLL LOCKED\x00";
        drawCrowdText(self.fonts.bold, poll_label, .{ .x = panel.x + 64 * scale, .y = panel.y + 42 * scale }, 23 * scale, colorWithOpacity(if (!available) .{ .r = 255, .g = 107, .b = 133, .a = 255 } else if (open) .{ .r = 77, .g = 255, .b = 181, .a = 255 } else .{ .r = 255, .g = 178, .b = 87, .a = 255 }, opacity));
        const question = std.fmt.bufPrintZ(&crowd_text_buffer_a, "{s}", .{spec.prompt}) catch return;
        drawCrowdTextFitted(self.fonts.bold, question, .{ .x = panel.x + 64 * scale, .y = panel.y + 92 * scale }, 48 * scale, panel.width - 128 * scale, colorWithOpacity(.white, opacity));

        const total_text = std.fmt.bufPrintZ(&crowd_text_buffer_b, "{d} {s}", .{ total, if (total == 1) "vote" else "votes" }) catch return;
        drawCrowdText(self.fonts.normal, total_text, .{ .x = panel.x + 66 * scale, .y = panel.y + 160 * scale }, 24 * scale, colorWithOpacity(.{ .r = 173, .g = 180, .b = 211, .a = 255 }, opacity));

        const count: usize = @min(spec.choices.len, crowdplay.max_choices);
        if (count == 0) return;
        const cards_top = panel.y + 214 * scale;
        const cards_bottom = panel.y + panel.height - 106 * scale;
        const gap = 13 * scale;
        const card_height = @max(8 * scale, (cards_bottom - cards_top - gap * @as(f32, @floatFromInt(count - 1))) / @as(f32, @floatFromInt(count)));
        var card_rects: [crowdplay.max_choices]rl.Rectangle = undefined;
        for (spec.choices[0..count], 0..) |choice_label, index| {
            const card = rl.Rectangle{
                .x = panel.x + 64 * scale,
                .y = cards_top + @as(f32, @floatFromInt(index)) * (card_height + gap),
                .width = panel.width - 128 * scale,
                .height = card_height,
            };
            card_rects[index] = card;
            const accent = crowdPalette(index);
            rl.drawRectangleRounded(card, 0.14, 10, colorWithOpacity(.{ .r = 24, .g = 29, .b = 54, .a = 245 }, opacity));
            const votes: u32 = if (live_poll) |poll| poll.choices[index].votes else 0;
            const fraction: f32 = if (revealed and total > 0) @as(f32, @floatFromInt(votes)) / @as(f32, @floatFromInt(total)) else 0;
            if (fraction > 0) {
                const fill = rl.Rectangle{ .x = card.x, .y = card.y, .width = @max(card.height, card.width * fraction), .height = card.height };
                rl.drawRectangleRounded(fill, 0.14, 10, colorWithOpacity(accent, opacity * 0.42));
            }
            rl.drawRectangleRoundedLinesEx(card, 0.14, 10, @max(1.0, 1.5 * scale), colorWithOpacity(accent, opacity * 0.52));
            const choice = std.fmt.bufPrintZ(&crowd_text_buffer_a, "{s}", .{choice_label}) catch continue;
            const label_width = card.width - (if (revealed) 245 * scale else 54 * scale);
            drawCrowdTextFitted(self.fonts.bold, choice, .{ .x = card.x + 27 * scale, .y = card.y + (card.height - 30 * scale) / 2 }, 28 * scale, label_width, colorWithOpacity(.white, opacity));
            if (revealed) {
                const percent: u32 = if (total > 0) @intFromFloat(@round(fraction * 100.0)) else 0;
                const result = std.fmt.bufPrintZ(&crowd_text_buffer_b, "{d}%  ·  {d}", .{ percent, votes }) catch continue;
                const measured = rl.measureTextEx(self.fonts.bold, result, 27 * scale, 0);
                drawCrowdText(self.fonts.bold, result, .{ .x = card.x + card.width - measured.x - 26 * scale, .y = card.y + (card.height - 29 * scale) / 2 }, 27 * scale, colorWithOpacity(accent, opacity));
            }
        }

        drawPollSwarm(snapshot, live_poll, card_rects[0..count], scale, opacity);
        const controls = if (crowd_url.len > 0) "O  open/lock     V  reveal     R  reset\x00" else "Crowdplay server unavailable\x00";
        drawCrowdText(self.fonts.normal, controls, .{ .x = panel.x + 66 * scale, .y = panel.y + panel.height - 65 * scale }, 21 * scale, colorWithOpacity(.{ .r = 137, .g = 144, .b = 177, .a = 255 }, opacity));
    }

    fn renderText(self: *SlideshowRenderer, item: *const RenderElement, slide_tl: rl.Vector2, slide_size: rl.Vector2, internal_render_size: rl.Vector2, transform: RenderTransform) void {
        if (item.text == null and item.color == null) {
            return;
        }
        // new: box without text, but with color: make a colored box
        if (item.text == null and item.color != null) {
            const startpos = translated(slidePosToRenderPos(item.position, slide_tl, slide_size, internal_render_size), transform.offset);
            const rendered_size = slideSizeToRenderSize(item.size, slide_size, internal_render_size);
            rl.drawRectangleRec(
                .{ .x = startpos.x, .y = startpos.y, .width = rendered_size.x, .height = rendered_size.y },
                colorWithOpacity(item.color.?, transform.opacity),
            );
            return;
        }

        // check for empty text
        if (item.text.?[0] == 0) {
            return;
        }
        var wrap_pos = item.position;
        wrap_pos.x += item.size.x;

        // we need to make the wrap pos slightly larger:
        // since for underline, sizes are pixel exact, later scaling of this might screw the wrapping - safety margin is 10 pixels here
        var wrap_offset = slidePosToRenderPos(.{ .x = 10, .y = 0 }, slide_tl, slide_size, internal_render_size).x;
        if (wrap_offset < 10) {
            wrap_offset = 10;
        }
        wrap_pos.x += wrap_offset;

        // imgui.igPushTextWrapPos(slidePosToRenderPos(wrap_pos, slide_tl, slide_size, internal_render_size).x);
        const fs = item.fontSize.?;
        const fsize = @as(f32, @floatFromInt(fs)) * slide_size.y / internal_render_size.y;
        const col = item.color;

        const font = switch (item.fontStyle) {
            .normal => self.fonts.normal,
            .bold => self.fonts.bold,
            .italic => self.fonts.italic,
            .bolditalic => self.fonts.bolditalic,
            .zig => self.fonts.zig,
        };

        // diplay the text
        const t = item.text.?;
        const startpos = translated(slidePosToRenderPos(item.position, slide_tl, slide_size, internal_render_size), transform.offset);
        const color = colorWithOpacity(col.?, transform.opacity);

        if (item.text_shadow) |shadow| {
            if (shadow.enabled) {
                const shadow_offset = slideSizeToRenderSize(shadow.offset, slide_size, internal_render_size);
                const shadow_pos = translated(startpos, shadow_offset);
                rl.drawTextEx(font, @as([:0]const u8, t), shadow_pos, fsize, 0.0, colorWithOpacity(shadow.color, transform.opacity));
            }
        }
        rl.drawTextEx(font, @as([:0]const u8, t), startpos, fsize, 0.0, color);

        // imgui.igPushStyleColor_Vec4(imgui.ImGuiCol_Text, col.?);
        // imgui.igText(t);
        // imgui.igPopStyleColor(1);
        // imgui.igPopTextWrapPos();

        //   we need to rely on the size here, so better make sure, the width is correct
        if (item.underlined) {
            // how to draw the line?
            var tl = item.position;
            tl.y += @as(f32, @floatFromInt(fs)) + 2.0;
            var br = tl;
            br.x += item.size.x;

            // imgui.igRenderFrame(slidePosToRenderPos(tl, slide_tl, slide_size, internal_render_size), slidePosToRenderPos(br, slide_tl, slide_size, internal_render_size), bgcolu32, true, 0.0);

            const line_startpos = translated(slidePosToRenderPos(tl, slide_tl, slide_size, internal_render_size), transform.offset);
            const line_endpos = translated(slidePosToRenderPos(br, slide_tl, slide_size, internal_render_size), transform.offset);
            rl.drawLineEx(line_startpos, line_endpos, 2.0, color);
        }
    }
};

const SlideTransitionTransforms = struct {
    incoming: RenderTransform = .{},
    outgoing: RenderTransform = .{},
};

fn slideTransitionTransforms(effect: animation.Effect, progress: f32, direction: i8, slide_size: rl.Vector2) SlideTransitionTransforms {
    var result = SlideTransitionTransforms{};
    const direction_factor: f32 = if (direction < 0) -1.0 else 1.0;
    switch (effect) {
        .none, .appear => {},
        .fade => {
            result.incoming.opacity = progress;
            result.outgoing.opacity = 1.0 - progress;
        },
        .slide_left => {
            result.incoming.offset.x = (1.0 - progress) * slide_size.x * direction_factor;
            result.outgoing.offset.x = -progress * slide_size.x * direction_factor;
        },
        .slide_right => {
            result.incoming.offset.x = -(1.0 - progress) * slide_size.x * direction_factor;
            result.outgoing.offset.x = progress * slide_size.x * direction_factor;
        },
        .slide_up => {
            result.incoming.offset.y = (1.0 - progress) * slide_size.y * direction_factor;
            result.outgoing.offset.y = -progress * slide_size.y * direction_factor;
        },
        .slide_down => {
            result.incoming.offset.y = -(1.0 - progress) * slide_size.y * direction_factor;
            result.outgoing.offset.y = progress * slide_size.y * direction_factor;
        },
    }
    return result;
}

fn itemAnimationTransform(effect: animation.Effect, progress: f32, slide_size: rl.Vector2, internal_render_size: rl.Vector2) RenderTransform {
    var result = RenderTransform{};
    const travel_x = 90.0 * slide_size.x / internal_render_size.x;
    const travel_y = 90.0 * slide_size.y / internal_render_size.y;
    switch (effect) {
        .none => {},
        .appear => result.opacity = if (progress >= 1.0) 1.0 else 0.0,
        .fade => result.opacity = progress,
        .slide_left => {
            result.offset.x = (1.0 - progress) * travel_x;
            result.opacity = progress;
        },
        .slide_right => {
            result.offset.x = -(1.0 - progress) * travel_x;
            result.opacity = progress;
        },
        .slide_up => {
            result.offset.y = (1.0 - progress) * travel_y;
            result.opacity = progress;
        },
        .slide_down => {
            result.offset.y = -(1.0 - progress) * travel_y;
            result.opacity = progress;
        },
    }
    return result;
}

fn combineTransforms(a: RenderTransform, b: RenderTransform) RenderTransform {
    return .{
        .offset = .{ .x = a.offset.x + b.offset.x, .y = a.offset.y + b.offset.y },
        .opacity = a.opacity * b.opacity,
    };
}

var crowd_text_buffer_a: [512]u8 = undefined;
var crowd_text_buffer_b: [512]u8 = undefined;

fn drawCrowdText(font: rl.Font, text: [:0]const u8, pos: rl.Vector2, size: f32, color: rl.Color) void {
    rl.drawTextEx(font, text, pos, @max(1.0, size), 0, color);
}

fn drawCrowdTextFitted(font: rl.Font, text: [:0]const u8, pos: rl.Vector2, size: f32, max_width: f32, color: rl.Color) void {
    const base_size = @max(1.0, size);
    const measured = rl.measureTextEx(font, text, base_size, 0).x;
    const fitted = if (measured > max_width and measured > 0) @max(1.0, base_size * max_width / measured) else base_size;
    rl.drawTextEx(font, text, pos, fitted, 0, color);
}

fn drawQrCode(code: *const qrcode.Code, region: rl.Rectangle, opacity: f32) void {
    const matrix_size = code.size();
    if (matrix_size <= 0) return;
    const quiet_modules: i32 = 4;
    const full_modules = matrix_size + quiet_modules * 2;
    const module_pixels = @floor(@min(region.width, region.height) / @as(f32, @floatFromInt(full_modules)));
    if (module_pixels < 1) return;
    const rendered_side = module_pixels * @as(f32, @floatFromInt(full_modules));
    const left = region.x + (region.width - rendered_side) * 0.5;
    const top = region.y + (region.height - rendered_side) * 0.5;
    rl.drawRectangleRec(.{ .x = left, .y = top, .width = rendered_side, .height = rendered_side }, colorWithOpacity(.white, opacity));
    for (0..@intCast(matrix_size)) |y| {
        for (0..@intCast(matrix_size)) |x| {
            if (!code.module(@intCast(x), @intCast(y))) continue;
            rl.drawRectangleRec(.{
                .x = left + @as(f32, @floatFromInt(@as(i32, @intCast(x)) + quiet_modules)) * module_pixels,
                .y = top + @as(f32, @floatFromInt(@as(i32, @intCast(y)) + quiet_modules)) * module_pixels,
                .width = module_pixels,
                .height = module_pixels,
            }, colorWithOpacity(.black, opacity));
        }
    }
}

fn crowdPalette(index: usize) rl.Color {
    const colors = [_]rl.Color{
        .{ .r = 111, .g = 124, .b = 255, .a = 255 },
        .{ .r = 255, .g = 91, .b = 159, .a = 255 },
        .{ .r = 46, .g = 224, .b = 190, .a = 255 },
        .{ .r = 255, .g = 184, .b = 76, .a = 255 },
        .{ .r = 87, .g = 195, .b = 255, .a = 255 },
        .{ .r = 185, .g = 112, .b = 255, .a = 255 },
        .{ .r = 255, .g = 116, .b = 95, .a = 255 },
        .{ .r = 128, .g = 234, .b = 116, .a = 255 },
    };
    return colors[index % colors.len];
}

fn seedUnit(seed: u64, shift: u6) f32 {
    return @as(f32, @floatFromInt((seed >> shift) & 0xffff)) / 65535.0;
}

fn drawSwarm(snapshot: crowdplay.Snapshot, choice: ?u8, region: rl.Rectangle, scale: f32, opacity: f32) void {
    const now: f32 = @floatCast(rl.getTime());
    const max_visible: usize = @min(snapshot.participant_count, 220);
    for (snapshot.participants[0..max_visible], 0..) |participant, index| {
        if (choice != null and participant.choice != choice) continue;
        const phase = seedUnit(participant.seed, 0) * std.math.tau + now * (0.22 + seedUnit(participant.seed, 16) * 0.36);
        const orbit_x = (0.12 + seedUnit(participant.seed, 32) * 0.38) * region.width;
        const orbit_y = (0.12 + seedUnit(participant.seed, 48) * 0.35) * region.height;
        const position = rl.Vector2{
            .x = region.x + region.width * 0.5 + std.math.cos(phase) * orbit_x,
            .y = region.y + region.height * 0.5 + std.math.sin(phase * 1.17) * orbit_y,
        };
        const color = crowdPalette(@intCast((participant.seed +% index) % crowdplay.max_choices));
        const radius = (4.0 + seedUnit(participant.seed, 8) * 5.0) * scale;
        rl.drawCircleV(position, radius * 1.9, colorWithOpacity(color, opacity * 0.12));
        rl.drawCircleV(position, radius, colorWithOpacity(color, opacity * 0.90));
    }
}

fn drawPollSwarm(snapshot: crowdplay.Snapshot, poll: ?crowdplay.PollSnapshot, cards: []const rl.Rectangle, scale: f32, opacity: f32) void {
    if (cards.len == 0) return;
    const revealed = if (poll) |active| active.revealed else false;
    const now: f32 = @floatCast(rl.getTime());
    const max_visible: usize = @min(snapshot.participant_count, 260);
    for (snapshot.participants[0..max_visible], 0..) |participant, index| {
        const show_choice = revealed and participant.choice != null and participant.choice.? < cards.len;
        const card = if (show_choice) cards[participant.choice.?] else cards[index % cards.len];
        const phase = seedUnit(participant.seed, 0) * std.math.tau + now * (0.18 + seedUnit(participant.seed, 16) * 0.32);
        var position: rl.Vector2 = undefined;
        if (show_choice) {
            position = .{
                .x = card.x + card.width * (0.22 + seedUnit(participant.seed, 32) * 0.54) + std.math.cos(phase) * 15 * scale,
                .y = card.y + card.height * 0.5 + std.math.sin(phase * 1.31) * @max(4.0 * scale, card.height * 0.24),
            };
        } else {
            const full_top = cards[0].y;
            const full_bottom = cards[cards.len - 1].y + cards[cards.len - 1].height;
            position = .{
                .x = cards[0].x + cards[0].width * (0.18 + seedUnit(participant.seed, 32) * 0.64) + std.math.cos(phase) * 20 * scale,
                .y = full_top + (full_bottom - full_top) * seedUnit(participant.seed, 48) + std.math.sin(phase * 1.19) * 14 * scale,
            };
        }
        const color = if (show_choice) crowdPalette(participant.choice.?) else crowdPalette(@intCast((participant.seed +% index) % crowdplay.max_choices));
        const radius = (3.4 + seedUnit(participant.seed, 8) * 4.3) * scale;
        rl.drawCircleV(position, radius * 1.9, colorWithOpacity(color, opacity * 0.13));
        rl.drawCircleV(position, radius, colorWithOpacity(color, opacity * 0.92));
    }
}

fn translated(pos: rl.Vector2, offset: rl.Vector2) rl.Vector2 {
    return .{ .x = pos.x + offset.x, .y = pos.y + offset.y };
}

fn colorWithOpacity(color: rl.Color, opacity: f32) rl.Color {
    var result = color;
    result.a = @intFromFloat(@round(@as(f32, @floatFromInt(color.a)) * animation.clampProgress(opacity)));
    return result;
}

fn startsLineStep(grouping: animation.Grouping, is_bulleted: bool) bool {
    return grouping == .line or (grouping == .bullet and is_bulleted);
}

test "line and bullet grouping leave surrounding content static" {
    try std.testing.expect(startsLineStep(.line, false));
    try std.testing.expect(startsLineStep(.line, true));
    try std.testing.expect(!startsLineStep(.bullet, false));
    try std.testing.expect(startsLineStep(.bullet, true));
    try std.testing.expect(!startsLineStep(.item, true));
}

pub fn slidePosToRenderPos(pos: rl.Vector2, slide_tl: rl.Vector2, slide_size: rl.Vector2, internal_render_size: rl.Vector2) rl.Vector2 {
    var my_tl: rl.Vector2 = .{
        .x = slide_tl.x + pos.x * slide_size.x / internal_render_size.x,
        .y = slide_tl.y + pos.y * slide_size.y / internal_render_size.y,
    };

    if (renderDistortionAnimation.running and pos.y > 0) {
        my_tl.x += renderDistortion.dx;
        my_tl.y += renderDistortion.dy;
    }
    return my_tl;
}

pub fn slideSizeToRenderSize(size: rl.Vector2, slide_size: rl.Vector2, internal_render_size: rl.Vector2) rl.Vector2 {
    const my_size: rl.Vector2 = .{
        .x = size.x * slide_size.x / internal_render_size.x,
        .y = size.y * slide_size.y / internal_render_size.y,
    };
    return my_size;
}

fn renderImg(pos: rl.Vector2, size: rl.Vector2, texture: rl.Texture2D, tint_color: rl.Color, border_color: rl.Color, slide_tl: rl.Vector2, slide_size: rl.Vector2, internal_render_size: rl.Vector2, transform: RenderTransform) void {
    // position the img in the slide
    const my_tl = translated(slidePosToRenderPos(pos, slide_tl, slide_size, internal_render_size), transform.offset);
    const my_size = slideSizeToRenderSize(size, slide_size, internal_render_size);

    // imgui.igSetCursorPos(my_tl);
    // imgui.igImage(@intToPtr(*zt.gl.Texture, @ptrToInt(&texture)).imguiId(), my_size, uv_min, uv_max, tint_color, border_color);

    texture.drawPro(
        // origin: 0/0 to texture size
        .{ .x = 0.0, .y = 0.0, .width = @floatFromInt(texture.width), .height = @floatFromInt(texture.height) },
        // dest: top left to given size
        .{ .x = my_tl.x, .y = my_tl.y, .width = my_size.x, .height = my_size.y },
        // origin relative to dest rect
        .{ .x = 0.0, .y = 0.0 },
        // rotation
        0.0,
        // tint
        colorWithOpacity(tint_color, transform.opacity),
    );

    // TODO: Border
    _ = border_color;
}

fn renderBgColor(bgcol: rl.Color, slide_tl: rl.Vector2, slide_size: rl.Vector2, transform: RenderTransform) void {
    rl.drawRectangleRec(
        .{ .x = slide_tl.x + transform.offset.x, .y = slide_tl.y + transform.offset.y, .width = slide_size.x, .height = slide_size.y },
        colorWithOpacity(bgcol, transform.opacity),
    );
}
