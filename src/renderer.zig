const std = @import("std");
const TextureCache = @import("texturecache.zig");
const slides = @import("slides.zig");
const parser = @import("parser.zig");
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
    fontSize: ?f32 = null,
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
    opacity: f32 = 1.0,
    owner_identity: usize = 0,
    part_index: usize = 0,
    is_item_background: bool = false,
};

const RenderedScene = struct {
    elements: std.ArrayList(RenderElement),
    plan: MorphPlan,
    owned_text: std.ArrayList([:0]const u8),
    /// Arrays backing CrowdSpec.choices. The strings themselves are tracked
    /// by owned_text so all RenderElement slices remain valid after the
    /// parser arena is replaced.
    owned_crowd_choices: std.ArrayList([]const []const u8),

    fn deinit(self: *RenderedScene, allocator: std.mem.Allocator) void {
        self.elements.deinit(allocator);
        self.plan.draws.deinit(allocator);
        freeOwnedCrowdChoices(allocator, &self.owned_crowd_choices);
        freeOwnedText(allocator, &self.owned_text);
    }
};

const MorphDrawKind = enum {
    interpolate,
    source_fade,
    target_fade,
};

const MorphDraw = struct {
    kind: MorphDrawKind,
    source_index: ?usize = null,
    target_index: ?usize = null,
};

const MorphPlan = struct {
    draws: std.ArrayList(MorphDraw),
};

const RenderedSlide = struct {
    elements: std.ArrayList(RenderElement) = undefined,
    morph_scenes: std.ArrayList(RenderedScene) = undefined,
    steps: std.ArrayList(animation.Step) = undefined,
    /// Every heap-backed string referenced by base-scene RenderElements.
    /// Individual strings may be shared by several elements (bullet glyphs),
    /// so ownership lives here rather than on RenderElement itself.
    owned_text: std.ArrayList([:0]const u8) = undefined,
    owned_crowd_choices: std.ArrayList([]const []const u8) = undefined,
    transition: animation.Transition = .{},
    input_fingerprint: u64 = 0,

    fn new(allocator: std.mem.Allocator) !*RenderedSlide {
        var self: *RenderedSlide = try allocator.create(RenderedSlide);
        self.* = .{};
        self.elements = std.ArrayList(RenderElement).empty;
        self.morph_scenes = std.ArrayList(RenderedScene).empty;
        self.steps = std.ArrayList(animation.Step).empty;
        self.owned_text = std.ArrayList([:0]const u8).empty;
        self.owned_crowd_choices = std.ArrayList([]const []const u8).empty;
        return self;
    }

    fn deinit(self: *RenderedSlide, allocator: std.mem.Allocator) void {
        self.elements.deinit(allocator);
        for (self.morph_scenes.items) |*scene| scene.deinit(allocator);
        self.morph_scenes.deinit(allocator);
        self.steps.deinit(allocator);
        freeOwnedCrowdChoices(allocator, &self.owned_crowd_choices);
        freeOwnedText(allocator, &self.owned_text);
    }
};

fn freeOwnedText(allocator: std.mem.Allocator, owned_text: *std.ArrayList([:0]const u8)) void {
    for (owned_text.items) |text| allocator.free(text);
    owned_text.deinit(allocator);
}

fn freeOwnedCrowdChoices(allocator: std.mem.Allocator, owned_choices: *std.ArrayList([]const []const u8)) void {
    for (owned_choices.items) |choices| allocator.free(choices);
    owned_choices.deinit(allocator);
}

const RenderFingerprinter = struct {
    value: u64 = 0x72736c696465735f,

    fn addBytes(self: *RenderFingerprinter, bytes: []const u8) void {
        self.value = std.hash.Wyhash.hash(self.value, bytes);
    }

    fn addScalar(self: *RenderFingerprinter, value: anytype) void {
        var copy = value;
        self.addBytes(std.mem.asBytes(&copy));
    }

    fn addBool(self: *RenderFingerprinter, value: bool) void {
        self.addScalar(@as(u8, @intFromBool(value)));
    }

    fn addString(self: *RenderFingerprinter, value: []const u8) void {
        self.addScalar(value.len);
        self.addBytes(value);
    }

    fn addOptionalString(self: *RenderFingerprinter, value: ?[]const u8) void {
        self.addBool(value != null);
        if (value) |text| self.addString(text);
    }

    fn addF32(self: *RenderFingerprinter, value: f32) void {
        self.addScalar(@as(u32, @bitCast(value)));
    }

    fn addOptionalF32(self: *RenderFingerprinter, value: ?f32) void {
        self.addBool(value != null);
        if (value) |number| self.addF32(number);
    }

    fn addOptionalI32(self: *RenderFingerprinter, value: ?i32) void {
        self.addBool(value != null);
        if (value) |number| self.addScalar(number);
    }

    fn addVector(self: *RenderFingerprinter, value: rl.Vector2) void {
        self.addF32(value.x);
        self.addF32(value.y);
    }

    fn addColor(self: *RenderFingerprinter, value: rl.Color) void {
        self.addScalar(value.r);
        self.addScalar(value.g);
        self.addScalar(value.b);
        self.addScalar(value.a);
    }

    fn addOptionalColor(self: *RenderFingerprinter, value: ?rl.Color) void {
        self.addBool(value != null);
        if (value) |color| self.addColor(color);
    }

    fn addItemAnimation(self: *RenderFingerprinter, value: ?animation.ItemSpec) void {
        self.addBool(value != null);
        if (value) |spec| {
            self.addScalar(@as(u8, @intFromEnum(spec.effect)));
            self.addScalar(@as(u8, @intFromEnum(spec.by)));
            self.addOptionalF32(spec.after);
            self.addF32(spec.duration);
        }
    }

    fn addMorphSpec(self: *RenderFingerprinter, spec: animation.MorphSpec) void {
        self.addOptionalF32(spec.after);
        self.addF32(spec.duration);
        self.addScalar(@as(u8, @intFromEnum(spec.easing)));
    }

    fn addTextShadow(self: *RenderFingerprinter, value: ?slides.TextShadow) void {
        self.addBool(value != null);
        if (value) |shadow| {
            self.addBool(shadow.enabled);
            self.addColor(shadow.color);
            self.addVector(shadow.offset);
        }
    }

    fn addCrowd(self: *RenderFingerprinter, value: ?slides.CrowdSpec) void {
        self.addBool(value != null);
        if (value) |crowd| {
            self.addScalar(@as(u8, @intFromEnum(crowd.kind)));
            self.addString(crowd.id);
            self.addString(crowd.prompt);
            self.addScalar(crowd.choices.len);
            for (crowd.choices) |choice| self.addString(choice);
            self.addBool(crowd.initially_open);
        }
    }

    fn addItem(self: *RenderFingerprinter, item: slides.SlideItem) void {
        self.addScalar(item.identity);
        self.addScalar(@as(u8, @intFromEnum(item.kind)));
        self.addOptionalString(item.text);
        self.addOptionalI32(item.fontSize);
        self.addOptionalF32(item.line_height_factor);
        self.addOptionalColor(item.color);
        self.addOptionalColor(item.background_color);
        self.addOptionalString(item.img_path);
        self.addVector(item.position);
        self.addVector(item.size);
        self.addOptionalI32(item.underline_width);
        self.addOptionalColor(item.bullet_color);
        self.addOptionalString(item.bullet_symbol);
        self.addOptionalF32(item.scale);
        self.addOptionalF32(item.ratio);
        self.addItemAnimation(item.animation);
        self.addTextShadow(item.text_shadow);
        self.addCrowd(item.crowd);
        self.addF32(item.opacity);
        self.addBool(item.visible);
    }
};

/// Hashes only data consumed while constructing RenderedSlide. Source offsets,
/// parser ownership, reusable provenance, and other authoring metadata are
/// intentionally excluded: moving bytes before a slide must not invalidate an
/// otherwise identical render graph.
fn renderInputFingerprint(slide: *const slides.Slide, slideshow_filp: []const u8) u64 {
    var hash = RenderFingerprinter{};
    hash.addString(slideshow_filp);
    hash.addScalar(@as(u8, @intFromEnum(slide.transition.effect)));
    hash.addF32(slide.transition.duration);
    if (slide.items) |items| {
        hash.addScalar(items.items.len);
        for (items.items) |item| hash.addItem(item);
    } else {
        hash.addScalar(@as(usize, 0));
    }
    hash.addScalar(slide.morph_states.items.len);
    for (slide.morph_states.items) |state| {
        hash.addMorphSpec(state.spec);
        hash.addScalar(state.items.items.len);
        for (state.items.items) |item| hash.addItem(item);
    }
    return hash.value;
}

test "speaker notes are excluded from renderer fingerprints" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const slide = try slides.Slide.new(arena.allocator());
    const before = renderInputFingerprint(slide, "deck.sld");
    slide.speaker_notes = "This must never change projected or exported pixels.";
    slide.speaker_notes_source = .{ .line_number = 42, .line_offset = 900, .patchable = true };
    try std.testing.expectEqual(before, renderInputFingerprint(slide, "deck.sld"));
}

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

/// One transient Studio gesture. The renderer applies it at draw time, so the
/// object follows the pointer without reparsing the document on every frame.
pub const ItemGeometryPreview = struct {
    owner_identity: usize,
    before_position: rl.Vector2,
    before_size: rl.Vector2,
    after_position: rl.Vector2,
    after_size: rl.Vector2,
    resized: bool,
};

/// Multi-selection is deliberately bounded in Studio so live preview state
/// remains allocation-free inside the render loop.
pub const max_item_geometry_previews = 64;

const RenderTransform = struct {
    offset: rl.Vector2 = .{ .x = 0, .y = 0 },
    opacity: f32 = 1.0,
};

const BoundarySpacing = struct {
    leading: f32 = 0.0,
    trailing: f32 = 0.0,
};

fn fontStyleForFlags(styleflags: u8) my_fonts.FontStyle {
    const bold = styleflags & markdownlineparser.StyleFlags.bold > 0;
    const italic = styleflags & markdownlineparser.StyleFlags.italic > 0;
    if (bold and italic) return .bolditalic;
    if (styleflags & markdownlineparser.StyleFlags.zig > 0) return .zig;
    if (italic) return .italic;
    if (bold) return .bold;
    return .normal;
}

/// Whitespace at a font boundary uses the wider of the two adjacent space
/// advances. This is deliberately symmetric: body -> code must not look
/// cramped, and neither must code -> body merely because the parser assigns
/// the literal space to the body span.
fn inlineBoundarySpacing(text: []const u8, current_space: f32, previous_space: ?f32, next_space: ?f32) BoundarySpacing {
    var leading_count: usize = 0;
    while (leading_count < text.len and text[leading_count] == ' ') : (leading_count += 1) {}

    // An all-whitespace span is one boundary, not both a leading and trailing
    // boundary. Compare it with both neighbors and account for it once.
    if (leading_count == text.len) {
        const widest = @max(current_space, @max(previous_space orelse current_space, next_space orelse current_space));
        return .{ .leading = (widest - current_space) * @as(f32, @floatFromInt(leading_count)) };
    }

    var trailing_start = text.len;
    while (trailing_start > leading_count and text[trailing_start - 1] == ' ') : (trailing_start -= 1) {}
    const trailing_count = text.len - trailing_start;

    return .{
        .leading = (@max(current_space, previous_space orelse current_space) - current_space) * @as(f32, @floatFromInt(leading_count)),
        .trailing = (@max(current_space, next_space orelse current_space) - current_space) * @as(f32, @floatFromInt(trailing_count)),
    };
}

fn boundaryWidth(raw_width: f32, boundary: BoundarySpacing, slice_start: usize, slice_end: usize, span_len: usize) f32 {
    return raw_width +
        (if (slice_start == 0) boundary.leading else 0.0) +
        (if (slice_end == span_len) boundary.trailing else 0.0);
}

fn boundaryLeadingOffset(boundary: BoundarySpacing, slice_start: usize) f32 {
    return if (slice_start == 0) boundary.leading else 0.0;
}

fn boundaryTrailingOffset(boundary: BoundarySpacing, slice_end: usize, span_len: usize) f32 {
    return if (slice_end == span_len) boundary.trailing else 0.0;
}

pub const SlideshowRenderer = struct {
    renderedSlides: std.ArrayList(*RenderedSlide) = undefined,
    allocator: std.mem.Allocator = undefined,
    md_parser: markdownlineparser.MdLineParser = .{},
    texture_cache: TextureCache,
    fonts: *my_fonts.AvailableFonts,
    qr_code: qrcode.Code = .{},
    item_geometry_previews: [max_item_geometry_previews]ItemGeometryPreview = undefined,
    item_geometry_preview_count: usize = 0,

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
        self.deinitRenderedSlides(&self.renderedSlides);
        self.md_parser.deinit();
        self.texture_cache.deinit();
        self.allocator.destroy(self);
    }

    fn destroyRenderedSlide(self: *SlideshowRenderer, rendered_slide: *RenderedSlide) void {
        rendered_slide.deinit(self.allocator);
        self.allocator.destroy(rendered_slide);
    }

    fn deinitRenderedSlides(self: *SlideshowRenderer, rendered_slides: *std.ArrayList(*RenderedSlide)) void {
        for (rendered_slides.items) |rendered_slide| self.destroyRenderedSlide(rendered_slide);
        rendered_slides.deinit(self.allocator);
        rendered_slides.* = std.ArrayList(*RenderedSlide).empty;
    }

    fn ownRenderedText(self: *SlideshowRenderer, render_slide: *RenderedSlide, text: []const u8) ![:0]const u8 {
        const owned = try self.allocator.dupeZ(u8, text);
        errdefer self.allocator.free(owned);
        try render_slide.owned_text.append(self.allocator, owned);
        return owned;
    }

    fn ownCrowdSpec(self: *SlideshowRenderer, render_slide: *RenderedSlide, crowd: slides.CrowdSpec) !slides.CrowdSpec {
        const owned_id = try self.ownRenderedText(render_slide, crowd.id);
        const owned_prompt = try self.ownRenderedText(render_slide, crowd.prompt);
        if (crowd.choices.len == 0) return .{
            .kind = crowd.kind,
            .id = owned_id,
            .prompt = owned_prompt,
            .initially_open = crowd.initially_open,
        };

        const owned_choices = try self.allocator.alloc([]const u8, crowd.choices.len);
        errdefer self.allocator.free(owned_choices);
        for (crowd.choices, 0..) |choice, index| {
            owned_choices[index] = try self.ownRenderedText(render_slide, choice);
        }
        try render_slide.owned_crowd_choices.append(self.allocator, owned_choices);
        return .{
            .kind = crowd.kind,
            .id = owned_id,
            .prompt = owned_prompt,
            .choices = owned_choices,
            .initially_open = crowd.initially_open,
        };
    }

    fn buildRenderedSlide(
        self: *SlideshowRenderer,
        slide: *const slides.Slide,
        slide_index: usize,
        slideshow_filp: []const u8,
        fingerprint: u64,
    ) !*RenderedSlide {
        const slide_number = slide_index + 1;

        if (slide.items == null or slide.items.?.items.len == 0) {
            log.warn("Slide {d} has NO ITEMS!", .{slide_number});
        }

        const render_slide = try RenderedSlide.new(self.allocator);
        errdefer self.destroyRenderedSlide(render_slide);
        render_slide.transition = slide.transition;
        render_slide.input_fingerprint = fingerprint;

        if (slide.items) |items| {
            for (items.items) |item| try self.preRenderItem(render_slide, item, slide_number, slideshow_filp);
        }
        for (slide.morph_states.items, 0..) |state, state_index| {
            const state_render = try RenderedSlide.new(self.allocator);
            var state_render_owned = true;
            errdefer if (state_render_owned) self.destroyRenderedSlide(state_render);
            for (state.items.items) |state_item| {
                var static_item = state_item;
                // Reveal steps belong to the base timeline and must not be
                // duplicated while materializing later state snapshots.
                static_item.animation = null;
                try self.preRenderItem(state_render, static_item, slide_number, slideshow_filp);
            }
            const source_elements = if (state_index == 0)
                render_slide.elements.items
            else
                render_slide.morph_scenes.items[state_index - 1].elements.items;
            var plan = try buildMorphPlan(self.allocator, source_elements, state_render.elements.items);
            var plan_owned = true;
            errdefer if (plan_owned) plan.draws.deinit(self.allocator);
            try render_slide.morph_scenes.ensureUnusedCapacity(self.allocator, 1);
            render_slide.morph_scenes.appendAssumeCapacity(.{
                .elements = state_render.elements,
                .plan = plan,
                .owned_text = state_render.owned_text,
                .owned_crowd_choices = state_render.owned_crowd_choices,
            });
            plan_owned = false;
            state_render.elements = std.ArrayList(RenderElement).empty;
            state_render.owned_text = std.ArrayList([:0]const u8).empty;
            state_render.owned_crowd_choices = std.ArrayList([]const []const u8).empty;
            state_render_owned = false;
            self.destroyRenderedSlide(state_render);
            try render_slide.steps.append(self.allocator, animation.Step.fromMorph(state.spec, state_index));
        }
        return render_slide;
    }

    pub const RebuildMode = enum { full, partial, unchanged };

    pub const RebuildResult = struct {
        mode: RebuildMode,
        rebuilt_slide_count: usize,
        total_slide_count: usize,
    };

    /// Compatibility entry point for callers that explicitly require a full
    /// graph replacement.
    pub fn preRender(self: *SlideshowRenderer, slideshow: *const slides.SlideShow, slideshow_filp: []const u8) !void {
        _ = try self.preRenderFull(slideshow, slideshow_filp);
    }

    fn preRenderFull(self: *SlideshowRenderer, slideshow: *const slides.SlideShow, slideshow_filp: []const u8) !RebuildResult {
        log.debug("ENTER full preRender", .{});
        if (slideshow.slides.items.len == 0) {
            log.warn("NO SLIDED!!!", .{});
        }

        // Build beside the live render graph. A failed image/text/morph build
        // leaves the currently displayed deck intact; success swaps ownership
        // and tears the previous graph down in one place.
        var rebuilt = std.ArrayList(*RenderedSlide).empty;
        errdefer self.deinitRenderedSlides(&rebuilt);

        for (slideshow.slides.items, 0..) |slide, index| {
            const fingerprint = renderInputFingerprint(slide, slideshow_filp);
            const render_slide = try self.buildRenderedSlide(slide, index, slideshow_filp, fingerprint);
            rebuilt.append(self.allocator, render_slide) catch |err| {
                self.destroyRenderedSlide(render_slide);
                return err;
            };
        }
        var previous = self.renderedSlides;
        self.renderedSlides = rebuilt;
        self.deinitRenderedSlides(&previous);
        log.debug("LEAVE full preRender with {d} slides", .{self.renderedSlides.items.len});
        return .{
            .mode = .full,
            .rebuilt_slide_count = self.renderedSlides.items.len,
            .total_slide_count = self.renderedSlides.items.len,
        };
    }

    /// Rebuilds only positions whose fully parsed, renderer-facing semantics
    /// changed. Slide-count changes deliberately take the full, transactional
    /// path. Every partial replacement is built beside the live graph and no
    /// old slide is retired until all replacements succeeded.
    pub fn preRenderChanged(self: *SlideshowRenderer, slideshow: *const slides.SlideShow, slideshow_filp: []const u8) !RebuildResult {
        const slide_count = slideshow.slides.items.len;
        if (self.renderedSlides.items.len != slide_count) return self.preRenderFull(slideshow, slideshow_filp);

        var replacements = try self.allocator.alloc(?*RenderedSlide, slide_count);
        defer self.allocator.free(replacements);
        @memset(replacements, null);
        errdefer for (replacements) |replacement| {
            if (replacement) |rendered_slide| self.destroyRenderedSlide(rendered_slide);
        };

        var changed_count: usize = 0;
        for (slideshow.slides.items, 0..) |slide, index| {
            const fingerprint = renderInputFingerprint(slide, slideshow_filp);
            if (self.renderedSlides.items[index].input_fingerprint == fingerprint) continue;
            replacements[index] = try self.buildRenderedSlide(slide, index, slideshow_filp, fingerprint);
            changed_count += 1;
        }
        if (changed_count == 0) return .{
            .mode = .unchanged,
            .rebuilt_slide_count = 0,
            .total_slide_count = slide_count,
        };

        for (replacements, 0..) |*replacement, index| {
            if (replacement.*) |new_slide| {
                const old_slide = self.renderedSlides.items[index];
                self.renderedSlides.items[index] = new_slide;
                replacement.* = null;
                self.destroyRenderedSlide(old_slide);
            }
        }
        return .{
            .mode = .partial,
            .rebuilt_slide_count = changed_count,
            .total_slide_count = slide_count,
        };
    }

    pub fn stepCount(self: *const SlideshowRenderer, slide_number: i32) usize {
        if (slide_number < 0 or slide_number >= self.renderedSlides.items.len) return 0;
        return self.renderedSlides.items[@intCast(slide_number)].steps.items.len;
    }

    /// Number of ordinary reveal steps before semantic morph states begin.
    /// Studio shows this stable base scene so every build item is selectable
    /// without accidentally editing an interpolated or later morph snapshot.
    pub fn baseRevealStepCount(self: *const SlideshowRenderer, slide_number: i32) usize {
        if (slide_number < 0 or slide_number >= self.renderedSlides.items.len) return 0;
        var count: usize = 0;
        for (self.renderedSlides.items[@intCast(slide_number)].steps.items) |step| {
            if (step.kind == .morph) break;
            count += 1;
        }
        return count;
    }

    pub fn setItemGeometryPreview(self: *SlideshowRenderer, preview: ?ItemGeometryPreview) void {
        if (preview) |value| {
            self.item_geometry_previews[0] = value;
            self.item_geometry_preview_count = 1;
        } else {
            self.item_geometry_preview_count = 0;
        }
    }

    pub fn setItemGeometryPreviews(self: *SlideshowRenderer, previews: []const ItemGeometryPreview) void {
        if (previews.len > max_item_geometry_previews) {
            // Never truncate a group preview: that would make the rendered
            // gesture disagree with the atomic source command. Studio enforces
            // the same fixed capacity before a selection can reach this API.
            self.item_geometry_preview_count = 0;
            return;
        }
        @memcpy(self.item_geometry_previews[0..previews.len], previews);
        self.item_geometry_preview_count = previews.len;
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

    /// Returns the union of the logical render fragments owned by one base
    /// SlideItem. Studio uses this for objects whose authored size is
    /// intentionally implicit, most notably auto-dimensioned images.
    pub fn itemRenderBounds(self: *const SlideshowRenderer, slide_number: i32, owner_identity: usize) ?rl.Rectangle {
        return self.itemRenderBoundsForMorphState(slide_number, null, owner_identity);
    }

    pub const ItemRenderBounds = struct {
        owner_identity: usize,
        bounds: rl.Rectangle,
    };

    /// Collect every rendered owner in one linear pass. Studio previously
    /// called itemRenderBoundsForMorphState once per SlideItem, rescanning all
    /// fragments each time; text-heavy slides therefore paid quadratic work
    /// on every frame. preRenderItem keeps an owner's fragments contiguous, so
    /// the same unions can be emitted allocation-amortized in paint order.
    pub fn collectItemRenderBoundsForMorphState(
        self: *const SlideshowRenderer,
        allocator: std.mem.Allocator,
        output: *std.ArrayList(ItemRenderBounds),
        slide_number: i32,
        morph_state: ?usize,
    ) !usize {
        output.clearRetainingCapacity();
        if (slide_number < 0 or slide_number >= self.renderedSlides.items.len) return 0;
        const slide = self.renderedSlides.items[@intCast(slide_number)];
        const elements = if (morph_state) |state_index| blk: {
            if (state_index >= slide.morph_scenes.items.len) return 0;
            break :blk slide.morph_scenes.items[state_index].elements.items;
        } else slide.elements.items;

        for (elements) |element| {
            if (element.kind == .background) continue;
            const right = element.position.x + element.size.x;
            const bottom = element.position.y + element.size.y;
            if (output.items.len > 0 and output.items[output.items.len - 1].owner_identity == element.owner_identity) {
                const previous = &output.items[output.items.len - 1].bounds;
                const left = @min(previous.x, element.position.x);
                const top = @min(previous.y, element.position.y);
                previous.* = .{
                    .x = left,
                    .y = top,
                    .width = @max(previous.x + previous.width, right) - left,
                    .height = @max(previous.y + previous.height, bottom) - top,
                };
            } else {
                try output.append(allocator, .{
                    .owner_identity = element.owner_identity,
                    .bounds = .{
                        .x = element.position.x,
                        .y = element.position.y,
                        .width = element.size.x,
                        .height = element.size.y,
                    },
                });
            }
        }
        return elements.len;
    }

    /// Logical bounds for an owner in either the base scene or one materialized
    /// semantic-morph snapshot. Studio uses the same scene for painting and
    /// hit-testing, so auto-sized images stay selectable while editing states.
    pub fn itemRenderBoundsForMorphState(
        self: *const SlideshowRenderer,
        slide_number: i32,
        morph_state: ?usize,
        owner_identity: usize,
    ) ?rl.Rectangle {
        if (slide_number < 0 or slide_number >= self.renderedSlides.items.len) return null;
        const slide = self.renderedSlides.items[@intCast(slide_number)];
        const elements = if (morph_state) |state_index| blk: {
            if (state_index >= slide.morph_scenes.items.len) return null;
            break :blk slide.morph_scenes.items[state_index].elements.items;
        } else slide.elements.items;
        var result: ?rl.Rectangle = null;
        for (elements) |element| {
            if (element.owner_identity != owner_identity or element.kind == .background) continue;
            const right = element.position.x + element.size.x;
            const bottom = element.position.y + element.size.y;
            if (result) |bounds| {
                const left = @min(bounds.x, element.position.x);
                const top = @min(bounds.y, element.position.y);
                result = .{
                    .x = left,
                    .y = top,
                    .width = @max(bounds.x + bounds.width, right) - left,
                    .height = @max(bounds.y + bounds.height, bottom) - top,
                };
            } else {
                result = .{
                    .x = element.position.x,
                    .y = element.position.y,
                    .width = element.size.x,
                    .height = element.size.y,
                };
            }
        }
        return result;
    }

    fn appendStep(self: *SlideshowRenderer, renderSlide: *RenderedSlide, spec: animation.ItemSpec) !usize {
        try renderSlide.steps.append(self.allocator, animation.Step.fromItem(spec));
        return renderSlide.steps.items.len;
    }

    fn wholeItemStep(self: *SlideshowRenderer, renderSlide: *RenderedSlide, item: slides.SlideItem) !usize {
        if (item.animation) |spec| return try self.appendStep(renderSlide, spec);
        return 0;
    }

    fn preRenderItem(
        self: *SlideshowRenderer,
        renderSlide: *RenderedSlide,
        item: slides.SlideItem,
        slide_number: usize,
        slideshow_filp: []const u8,
    ) !void {
        var rendered_item = item;
        // Hidden objects remain in state snapshots at zero opacity. Keeping
        // their geometry and identity makes @set + @hide move while fading,
        // and makes @show the exact reverse. They must not create dead reveal
        // clicks while hidden in the base state.
        if (!rendered_item.visible) rendered_item.animation = null;
        const first_element = renderSlide.elements.items.len;
        const has_item_background = itemBackgroundElement(rendered_item) != null;
        if (itemBackgroundElement(rendered_item)) |background| {
            // An item-owned fill is the first part of its owner group, so the
            // item's actual content always remains above it.
            try renderSlide.elements.append(self.allocator, background);
        }
        switch (rendered_item.kind) {
            .background => try self.createBg(renderSlide, rendered_item, slideshow_filp),
            .textbox => try self.preRenderTextBlock(renderSlide, rendered_item, slide_number),
            .img => try self.createImg(renderSlide, rendered_item, slideshow_filp),
            .crowd => try self.createCrowd(renderSlide, rendered_item),
        }
        if (has_item_background and renderSlide.elements.items.len > first_element + 1) {
            resolveItemBackgroundGeometry(
                &renderSlide.elements.items[first_element],
                renderSlide.elements.items[first_element + 1 ..],
            );
        }
        if (has_item_background and renderSlide.elements.items.len > first_element + 1) {
            // Enter with the first content fragment. This is the shared item
            // step for by-item animations and the first line/bullet step for
            // progressive text.
            renderSlide.elements.items[first_element].reveal_step = renderSlide.elements.items[first_element + 1].reveal_step;
        }
        for (renderSlide.elements.items[first_element..], 0..) |*element, emitted_index| {
            element.owner_identity = rendered_item.identity;
            // Backgrounds have their own semantic role. Foreground part
            // indexes stay stable when a state adds or removes `bg=`, which
            // lets the morph planner keep unchanged content above the fill.
            element.part_index = emitted_index - @intFromBool(has_item_background and emitted_index > 0);
            element.opacity = if (rendered_item.visible) rendered_item.opacity else 0.0;
        }
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
        const owned_crowd = if (item.crowd) |crowd| try self.ownCrowdSpec(renderSlide, crowd) else null;
        try renderSlide.elements.append(self.allocator, .{
            .kind = .crowd,
            .position = item.position,
            .size = item.size,
            .crowd = owned_crowd,
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
            bulletSymbol = try self.ownRenderedText(renderSlide, bs);
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
            const new_t = try replaceSlideNumber(self.allocator, t, slide_number);
            defer self.allocator.free(new_t);

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
                        .fontSize = @floatFromInt(fontSize),
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

    fn fontForStyle(self: *const SlideshowRenderer, style: my_fonts.FontStyle) rl.Font {
        return switch (style) {
            .normal => self.fonts.normal,
            .bold => self.fonts.bold,
            .italic => self.fonts.italic,
            .bolditalic => self.fonts.bolditalic,
            .zig => self.fonts.zig,
        };
    }

    fn spaceAdvanceForStyle(self: *const SlideshowRenderer, style: my_fonts.FontStyle, nominal_font_size: f32) f32 {
        const display_font_size = self.fonts.displaySizeForStyle(style, nominal_font_size);
        return self.fonts.measureTextWithFallback(self.fontForStyle(style), " ", display_font_size, 0).x;
    }

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
                .fontSize = @floatFromInt(layoutContext.fontSize),
                .underline_width = @intCast(layoutContext.underline_width),
                .reveal_step = layoutContext.reveal_step,
                .text_shadow = layoutContext.text_shadow,
            };

            for (spans.items, 0..) |span, span_index| {
                if (span.text.?[0] == 0) {
                    log.debug("SKIPPING ZERO LENGTH SPAN", .{});
                    continue;
                }
                log.debug("new span, len=: `{d}`", .{span.text.?.len});
                // work out the font
                element.fontStyle = fontStyleForFlags(span.styleflags);
                const font_used = self.fontForStyle(element.fontStyle);
                element.underlined = span.styleflags & markdownlineparser.StyleFlags.underline > 0;
                const nominal_font_size: f32 = @floatFromInt(layoutContext.fontSize);
                const display_font_size = self.fonts.displaySizeForStyle(element.fontStyle, nominal_font_size);
                const baseline_offset = self.fonts.baselineOffsetForStyle(element.fontStyle, nominal_font_size);
                element.fontSize = display_font_size;
                const current_space = self.spaceAdvanceForStyle(element.fontStyle, nominal_font_size);
                const previous_space = if (span_index > 0)
                    self.spaceAdvanceForStyle(fontStyleForFlags(spans.items[span_index - 1].styleflags), nominal_font_size)
                else
                    null;
                const next_space = if (span_index + 1 < spans.items.len)
                    self.spaceAdvanceForStyle(fontStyleForFlags(spans.items[span_index + 1].styleflags), nominal_font_size)
                else
                    null;
                const boundary_spacing = inlineBoundarySpacing(span.text.?, current_space, previous_space, next_space);
                if (boundary_spacing.leading > 0 or boundary_spacing.trailing > 0) {
                    log.debug(
                        "font-boundary spacing `{s}`: leading +{d:.2}px, trailing +{d:.2}px",
                        .{ span.text.?, boundary_spacing.leading, boundary_spacing.trailing },
                    );
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
                var render_text_c = try self.styledTextblockSize_toCstring(renderSlide, span.text.?, display_font_size, font_used, &attempted_span_size);
                const whole_span_width = boundaryWidth(attempted_span_size.x, boundary_spacing, 0, span.text.?.len, span.text.?.len);
                log.debug("available_width: {d}, attempted_span_size: {d:3.0}", .{ available_width, whole_span_width });
                if (whole_span_width < available_width) {
                    // we did not wrap so the entire span can be output!
                    element.text = render_text_c;
                    element.position = layoutContext.current_pos;
                    element.position.x += boundary_spacing.leading;
                    element.position.y += baseline_offset;
                    element.size.x = attempted_span_size.x + boundary_spacing.trailing;
                    //element.size = attempted_span_size;
                    log.debug(">>>>>>> appending non-wrapping text element: {?s}@{d:3.0},{d:3.0}", .{ element.text, element.position.x, element.position.y });
                    try renderSlide.elements.append(self.allocator, element);
                    // advance render pos
                    layoutContext.current_pos.x += whole_span_width;
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
                        render_text_c = try self.styledTextblockSize_toCstring(renderSlide, render_text, display_font_size, font_used, &attempted_span_size);
                        const candidate_width = boundaryWidth(attempted_span_size.x, boundary_spacing, lastConsumedIdx, currentIdxOfSpace, span.text.?.len);
                        log.debug("   current available_width: {d}, attempted_span_size: {d:3.0}", .{ available_width, candidate_width });
                        if (candidate_width > available_width and wordCount > 1) {
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
                                render_text_c = try self.styledTextblockSize_toCstring(renderSlide, render_text, display_font_size, font_used, &attempted_span_size);
                                const rendered_slice_start = lastConsumedIdx;
                                const rendered_width = boundaryWidth(attempted_span_size.x, boundary_spacing, rendered_slice_start, end_of_string_pos, span.text.?.len);
                                lastConsumedIdx = lastIdxOfSpace;
                                lastIdxOfSpace = currentIdxOfSpace;
                                element.text = render_text_c;
                                element.position = layoutContext.current_pos;
                                element.position.x += boundaryLeadingOffset(boundary_spacing, rendered_slice_start);
                                element.position.y += baseline_offset;
                                element.size.x = attempted_span_size.x + boundaryTrailingOffset(boundary_spacing, end_of_string_pos, span.text.?.len);
                                // element.size = attempted_span_size;
                                log.debug(">>>>>>> appending wrapping text element: {?s} width={d:3.0}", .{ element.text, rendered_width });
                                try renderSlide.elements.append(self.allocator, element);
                                // advance render pos
                                layoutContext.current_pos.x += rendered_width;
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
                                render_text_c = try self.styledTextblockSize_toCstring(renderSlide, render_text, display_font_size, font_used, &attempted_span_size);
                                const rendered_slice_start = lastConsumedIdx;
                                const rendered_width = boundaryWidth(attempted_span_size.x, boundary_spacing, rendered_slice_start, currentIdxOfSpace, span.text.?.len);
                                lastConsumedIdx = lastIdxOfSpace;
                                lastIdxOfSpace = currentIdxOfSpace;
                                element.text = render_text_c;
                                element.position = layoutContext.current_pos;
                                element.position.x += boundaryLeadingOffset(boundary_spacing, rendered_slice_start);
                                element.position.y += baseline_offset;
                                // element.size = attempted_span_size;
                                log.debug(">>>>>>> appending final text element: {?s} width={d:3.0}", .{ element.text, rendered_width });
                                element.size.x = attempted_span_size.x + boundaryTrailingOffset(boundary_spacing, currentIdxOfSpace, span.text.?.len);
                                try renderSlide.elements.append(self.allocator, element);
                                // advance render pos
                                layoutContext.current_pos.x += rendered_width;
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
        var size: rl.Vector2 = .{ .x = 0.0, .y = 0.0 };
        var ret: rl.Vector2 = .{ .x = 0.0, .y = 0.0 };
        // TODO: this might be inaccurate if we use different fonts in the text block
        // whose pixel sizes vary significantly for given font sizes
        const text = "FontCheck";
        size = self.fonts.measureTextWithFallback(font, text, @floatFromInt(fontsize), 0);
        ret.y = size.y;
        const bullet_text = "> "; // TODO this should ideally honor the real bullet symbol but I don't care atm
        size = self.fonts.measureTextWithFallback(font, bullet_text, @floatFromInt(fontsize), 0);
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

    fn styledTextblockSize_toCstring(self: *SlideshowRenderer, render_slide: *RenderedSlide, text: []const u8, fontsize: f32, font: rl.Font, size_out: *rl.Vector2) ![:0]const u8 {
        const ctext = try self.ownRenderedText(render_slide, text);
        log.debug("cstring: of {s} = `{s}`", .{ text, ctext });
        if (ctext[0] == 0) {
            size_out.x = 0;
            size_out.y = 0;
            return ctext;
        }
        size_out.* = self.fonts.measureTextWithFallback(font, ctext, fontsize, 0);
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

    /// Paint the final stable scene of one slide into a small Studio card.
    /// Thumbnail rendering deliberately ignores a live canvas geometry preview
    /// (item identities restart on every slide) and audience-only Crowdplay
    /// state, then restores the preview for the main canvas.
    pub fn renderStudioThumbnail(
        self: *SlideshowRenderer,
        slide_number: i32,
        pos: rl.Vector2,
        size: rl.Vector2,
        internal_render_size: rl.Vector2,
    ) !void {
        const preview_count = self.item_geometry_preview_count;
        self.item_geometry_preview_count = 0;
        defer self.item_geometry_preview_count = preview_count;
        try self.renderOneSlide(
            slide_number,
            .{ .visible_through = self.stepCount(slide_number) },
            .{},
            pos,
            size,
            internal_render_size,
            null,
            "",
        );
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

        if (reveal.active_step) |active_step| {
            if (active_step > 0 and active_step <= slide.steps.items.len) {
                const step = slide.steps.items[active_step - 1];
                if (step.kind == .morph and step.morph_state < slide.morph_scenes.items.len) {
                    const source_elements = if (step.morph_state == 0)
                        slide.elements.items
                    else
                        slide.morph_scenes.items[step.morph_state - 1].elements.items;
                    const target_elements = slide.morph_scenes.items[step.morph_state].elements.items;
                    self.renderMorph(
                        source_elements,
                        target_elements,
                        &slide.morph_scenes.items[step.morph_state].plan,
                        animation.applyEasing(step.easing, reveal.active_progress),
                        slide_transform,
                        pos,
                        size,
                        internal_render_size,
                        crowd_snapshot,
                        crowd_url,
                    );
                    return;
                }
            }
        }

        if (stableMorphState(slide, reveal.visible_through)) |state_index| {
            self.renderStaticElements(slide.morph_scenes.items[state_index].elements.items, slide_transform, pos, size, internal_render_size, crowd_snapshot, crowd_url);
            return;
        }

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

            self.renderElement(&element, pos, size, internal_render_size, transform, crowd_snapshot, crowd_url);
        }
    }

    fn renderStaticElements(
        self: *SlideshowRenderer,
        elements: []const RenderElement,
        slide_transform: RenderTransform,
        pos: rl.Vector2,
        size: rl.Vector2,
        internal_render_size: rl.Vector2,
        crowd_snapshot: ?crowdplay.Snapshot,
        crowd_url: []const u8,
    ) void {
        for (elements) |element| self.renderElement(&element, pos, size, internal_render_size, slide_transform, crowd_snapshot, crowd_url);
    }

    fn renderMorph(
        self: *SlideshowRenderer,
        source: []const RenderElement,
        target: []const RenderElement,
        plan: *const MorphPlan,
        progress: f32,
        slide_transform: RenderTransform,
        pos: rl.Vector2,
        size: rl.Vector2,
        internal_render_size: rl.Vector2,
        crowd_snapshot: ?crowdplay.Snapshot,
        crowd_url: []const u8,
    ) void {
        const opacity_progress = animation.clampProgress(progress);

        // Exact endpoints also preserve the source and target scenes' precise
        // stacking order if a future directive ever permits owner reordering.
        if (progress == 0.0) {
            self.renderStaticElements(source, slide_transform, pos, size, internal_render_size, crowd_snapshot, crowd_url);
            return;
        }
        if (progress == 1.0) {
            self.renderStaticElements(target, slide_transform, pos, size, internal_render_size, crowd_snapshot, crowd_url);
            return;
        }

        // Commands are precomputed in target owner order. Incompatible source
        // fragments are immediately adjacent to their target fragments, so a
        // compatible background cannot be painted over a foreground crossfade.
        for (plan.draws.items) |draw| {
            switch (draw.kind) {
                .interpolate => {
                    const source_element = &source[draw.source_index.?];
                    const target_element = &target[draw.target_index.?];
                    const interpolated = interpolateElement(source_element, target_element, progress);
                    self.renderElement(&interpolated, pos, size, internal_render_size, slide_transform, crowd_snapshot, crowd_url);
                },
                .source_fade => {
                    var transform = slide_transform;
                    transform.opacity *= 1.0 - opacity_progress;
                    self.renderElement(&source[draw.source_index.?], pos, size, internal_render_size, transform, crowd_snapshot, crowd_url);
                },
                .target_fade => {
                    var transform = slide_transform;
                    transform.opacity *= opacity_progress;
                    self.renderElement(&target[draw.target_index.?], pos, size, internal_render_size, transform, crowd_snapshot, crowd_url);
                },
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
            if (logical_pos.x == 0) logical_pos.x = slides.crowd_default_position.x;
            logical_size.x = slides.crowd_default_size.x;
        }
        if (logical_size.y <= 0) {
            if (logical_pos.y == 0) logical_pos.y = slides.crowd_default_position.y;
            logical_size.y = slides.crowd_default_size.y;
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

        drawPollSwarm(snapshot, card_rects[0..count], scale, opacity);
        const controls = if (crowd_url.len > 0) "O  open/lock     V  reveal     R  reset\x00" else "Crowdplay server unavailable\x00";
        drawCrowdText(self.fonts.normal, controls, .{ .x = panel.x + 66 * scale, .y = panel.y + panel.height - 65 * scale }, 21 * scale, colorWithOpacity(.{ .r = 137, .g = 144, .b = 177, .a = 255 }, opacity));
    }

    fn renderElement(
        self: *SlideshowRenderer,
        element: *const RenderElement,
        pos: rl.Vector2,
        size: rl.Vector2,
        internal_render_size: rl.Vector2,
        base_transform: RenderTransform,
        crowd_snapshot: ?crowdplay.Snapshot,
        crowd_url: []const u8,
    ) void {
        var previewed = if (geometryPreviewFor(
            self.item_geometry_previews[0..self.item_geometry_preview_count],
            element.owner_identity,
        )) |preview|
            elementWithGeometryPreview(element.*, preview)
        else
            element.*;
        const displayed = &previewed;
        var transform = base_transform;
        transform.opacity *= displayed.opacity;
        if (transform.opacity <= 0) return;
        switch (displayed.kind) {
            .background => {
                if (displayed.texture) |texture| {
                    renderImg(.{ .x = 0.0, .y = 0.0 }, internal_render_size, texture, .white, .blank, pos, size, internal_render_size, transform);
                } else if (displayed.color) |color| {
                    renderBgColor(color, pos, size, transform);
                }
            },
            .text => self.renderText(displayed, pos, size, internal_render_size, transform),
            .image => {
                if (displayed.texture) |texture| {
                    renderImg(displayed.position, displayed.size, texture, .white, .blank, pos, size, internal_render_size, transform);
                }
            },
            .crowd => self.renderCrowd(displayed, crowd_snapshot, crowd_url, pos, size, internal_render_size, transform),
        }
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
        const fsize = fs * slide_size.y / internal_render_size.y;
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
                self.fonts.drawTextWithFallback(font, t, shadow_pos, fsize, 0.0, colorWithOpacity(shadow.color, transform.opacity));
            }
        }
        self.fonts.drawTextWithFallback(font, t, startpos, fsize, 0.0, color);

        // imgui.igPushStyleColor_Vec4(imgui.ImGuiCol_Text, col.?);
        // imgui.igText(t);
        // imgui.igPopStyleColor(1);
        // imgui.igPopTextWrapPos();

        //   we need to rely on the size here, so better make sure, the width is correct
        if (item.underlined) {
            // how to draw the line?
            var tl = item.position;
            tl.y += fs + 2.0;
            var br = tl;
            br.x += item.size.x;

            // imgui.igRenderFrame(slidePosToRenderPos(tl, slide_tl, slide_size, internal_render_size), slidePosToRenderPos(br, slide_tl, slide_size, internal_render_size), bgcolu32, true, 0.0);

            const line_startpos = translated(slidePosToRenderPos(tl, slide_tl, slide_size, internal_render_size), transform.offset);
            const line_endpos = translated(slidePosToRenderPos(br, slide_tl, slide_size, internal_render_size), transform.offset);
            const underline_width = @as(f32, @floatFromInt(item.underline_width orelse 2)) * slide_size.y / internal_render_size.y;
            rl.drawLineEx(line_startpos, line_endpos, underline_width, color);
        }
    }
};

fn itemBackgroundElement(item: slides.SlideItem) ?RenderElement {
    if (item.kind == .background) return null;
    const color = item.background_color orelse return null;
    return .{
        .kind = .text,
        .position = item.position,
        .size = item.size,
        .fontSize = null,
        .underline_width = null,
        .line_height_factor = null,
        .text = null,
        .color = color,
        .is_item_background = true,
    };
}

/// Fill omitted dimensions from the content fragments produced for the same
/// owner. This keeps `bg=` useful for naturally-sized images without turning
/// an omitted image width or height into an explicit source value.
fn resolveItemBackgroundGeometry(background: *RenderElement, content: []const RenderElement) void {
    if (background.size.x > 0 and background.size.y > 0) return;

    var bounds: ?rl.Rectangle = null;
    for (content) |element| {
        if (element.kind == .background) continue;
        const right = element.position.x + element.size.x;
        const bottom = element.position.y + element.size.y;
        if (bounds) |current| {
            const left = @min(current.x, element.position.x);
            const top = @min(current.y, element.position.y);
            bounds = .{
                .x = left,
                .y = top,
                .width = @max(current.x + current.width, right) - left,
                .height = @max(current.y + current.height, bottom) - top,
            };
        } else {
            bounds = .{
                .x = element.position.x,
                .y = element.position.y,
                .width = element.size.x,
                .height = element.size.y,
            };
        }
    }
    const resolved = bounds orelse return;
    if (background.size.x <= 0) {
        background.position.x = resolved.x;
        background.size.x = resolved.width;
    }
    if (background.size.y <= 0) {
        background.position.y = resolved.y;
        background.size.y = resolved.height;
    }
}

fn elementWithGeometryPreview(element: RenderElement, preview: ItemGeometryPreview) RenderElement {
    if (element.kind == .background or element.owner_identity != preview.owner_identity) return element;

    var result = element;
    const move = rl.Vector2{
        .x = preview.after_position.x - preview.before_position.x,
        .y = preview.after_position.y - preview.before_position.y,
    };
    result.position.x += move.x;
    result.position.y += move.y;
    if (!preview.resized) return result;

    // Images, Crowdplay panels, and color-only rectangles can be resized
    // faithfully without rebuilding layout. Text keeps its glyph metrics and
    // reflows once the completed gesture is reparsed.
    const scalable = element.kind == .image or element.kind == .crowd or
        (element.kind == .text and element.text == null);
    if (!scalable or preview.before_size.x <= 0 or preview.before_size.y <= 0) return result;

    const scale_x = preview.after_size.x / preview.before_size.x;
    const scale_y = preview.after_size.y / preview.before_size.y;
    result.position = .{
        .x = preview.after_position.x + (element.position.x - preview.before_position.x) * scale_x,
        .y = preview.after_position.y + (element.position.y - preview.before_position.y) * scale_y,
    };
    result.size = .{ .x = element.size.x * scale_x, .y = element.size.y * scale_y };
    return result;
}

fn geometryPreviewFor(previews: []const ItemGeometryPreview, identity: usize) ?ItemGeometryPreview {
    for (previews) |preview| {
        if (preview.owner_identity == identity) return preview;
    }
    return null;
}

fn stableMorphState(slide: *const RenderedSlide, visible_through: usize) ?usize {
    var state_index: ?usize = null;
    const step_count = @min(visible_through, slide.steps.items.len);
    for (slide.steps.items[0..step_count]) |step| {
        if (step.kind == .morph) state_index = step.morph_state;
    }
    return state_index;
}

fn optionalTextEqual(a: ?[:0]const u8, b: ?[:0]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

fn optionalTextureEqual(a: ?rl.Texture2D, b: ?rl.Texture2D) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.?.id == b.?.id;
}

fn elementPayloadCompatible(a: *const RenderElement, b: *const RenderElement) bool {
    return a.kind == b.kind and
        optionalTextEqual(a.text, b.text) and
        optionalTextureEqual(a.texture, b.texture) and
        a.fontStyle == b.fontStyle and
        a.underlined == b.underlined;
}

const ElementGroup = struct {
    first: usize,
    len: usize,
};

fn indexOwnerGroups(groups: *std.AutoHashMap(usize, ElementGroup), elements: []const RenderElement) !void {
    var first: usize = 0;
    while (first < elements.len) {
        const owner_identity = elements[first].owner_identity;
        var end = first + 1;
        while (end < elements.len and elements[end].owner_identity == owner_identity) : (end += 1) {}
        try groups.put(owner_identity, .{ .first = first, .len = end - first });
        first = end;
    }
}

fn groupBackgroundIndex(elements: []const RenderElement, group: ElementGroup) ?usize {
    if (group.len == 0) return null;
    const index = group.first;
    return if (elements[index].is_item_background) index else null;
}

fn groupForeground(group: ElementGroup, background_index: ?usize) ElementGroup {
    const skip: usize = @intFromBool(background_index != null);
    return .{ .first = group.first + skip, .len = group.len - skip };
}

fn foregroundGroupsCompatible(source: []const RenderElement, source_group: ElementGroup, target: []const RenderElement, target_group: ElementGroup) bool {
    if (source_group.len != target_group.len) return false;
    for (0..source_group.len) |offset| {
        const source_element = &source[source_group.first + offset];
        const target_element = &target[target_group.first + offset];
        if (source_element.is_item_background or target_element.is_item_background or
            source_element.part_index != target_element.part_index or
            !elementPayloadCompatible(source_element, target_element)) return false;
    }
    return true;
}

fn appendOwnerMorphDraws(
    plan: *MorphPlan,
    allocator: std.mem.Allocator,
    source: []const RenderElement,
    source_group: ElementGroup,
    target: []const RenderElement,
    target_group: ElementGroup,
) !void {
    const source_background = groupBackgroundIndex(source, source_group);
    const target_background = groupBackgroundIndex(target, target_group);

    // Paint both background layers before any foreground fragment. Adding,
    // removing, or recoloring `bg=` can therefore never cover text that is
    // cross-fading within the same semantic owner.
    if (source_background) |source_index| {
        if (target_background) |target_index| {
            if (elementPayloadCompatible(&source[source_index], &target[target_index])) {
                try plan.draws.append(allocator, .{
                    .kind = .interpolate,
                    .source_index = source_index,
                    .target_index = target_index,
                });
            } else {
                try plan.draws.append(allocator, .{ .kind = .source_fade, .source_index = source_index });
                try plan.draws.append(allocator, .{ .kind = .target_fade, .target_index = target_index });
            }
        } else {
            try plan.draws.append(allocator, .{ .kind = .source_fade, .source_index = source_index });
        }
    } else if (target_background) |target_index| {
        try plan.draws.append(allocator, .{ .kind = .target_fade, .target_index = target_index });
    }

    const source_foreground = groupForeground(source_group, source_background);
    const target_foreground = groupForeground(target_group, target_background);
    if (foregroundGroupsCompatible(source, source_foreground, target, target_foreground)) {
        for (0..target_foreground.len) |offset| {
            try plan.draws.append(allocator, .{
                .kind = .interpolate,
                .source_index = source_foreground.first + offset,
                .target_index = target_foreground.first + offset,
            });
        }
    } else {
        for (0..source_foreground.len) |offset| {
            try plan.draws.append(allocator, .{ .kind = .source_fade, .source_index = source_foreground.first + offset });
        }
        for (0..target_foreground.len) |offset| {
            try plan.draws.append(allocator, .{ .kind = .target_fade, .target_index = target_foreground.first + offset });
        }
    }
}

fn buildMorphPlan(allocator: std.mem.Allocator, source: []const RenderElement, target: []const RenderElement) !MorphPlan {
    var plan = MorphPlan{ .draws = std.ArrayList(MorphDraw).empty };
    errdefer plan.draws.deinit(allocator);
    var source_groups = std.AutoHashMap(usize, ElementGroup).init(allocator);
    defer source_groups.deinit();
    var target_groups = std.AutoHashMap(usize, ElementGroup).init(allocator);
    defer target_groups.deinit();
    try indexOwnerGroups(&source_groups, source);
    try indexOwnerGroups(&target_groups, target);

    // Each owner's compatibility is computed once. Render elements belonging
    // to an item are contiguous and part-indexed by preRenderItem, so matching
    // is linear in the total number of generated fragments.
    var target_first: usize = 0;
    while (target_first < target.len) {
        const owner_identity = target[target_first].owner_identity;
        const target_group = target_groups.get(owner_identity).?;
        if (source_groups.get(owner_identity)) |source_group| {
            try appendOwnerMorphDraws(&plan, allocator, source, source_group, target, target_group);
        } else {
            for (0..target_group.len) |offset| {
                try plan.draws.append(allocator, .{ .kind = .target_fade, .target_index = target_group.first + offset });
            }
        }
        target_first += target_group.len;
    }

    // A failed/removed renderable has no target group. Normal @hide keeps the
    // owner with zero opacity and therefore takes the order-preserving path
    // above; this fallback only handles genuinely absent generated elements.
    var source_first: usize = 0;
    while (source_first < source.len) {
        const owner_identity = source[source_first].owner_identity;
        const source_group = source_groups.get(owner_identity).?;
        if (!target_groups.contains(owner_identity)) {
            for (0..source_group.len) |offset| {
                try plan.draws.append(allocator, .{ .kind = .source_fade, .source_index = source_group.first + offset });
            }
        }
        source_first += source_group.len;
    }
    return plan;
}

fn lerpF32(from: f32, to: f32, progress: f32) f32 {
    return from + (to - from) * progress;
}

fn lerpVector(from: rl.Vector2, to: rl.Vector2, progress: f32) rl.Vector2 {
    return .{
        .x = lerpF32(from.x, to.x, progress),
        .y = lerpF32(from.y, to.y, progress),
    };
}

fn lerpChannel(from: u8, to: u8, progress: f32) u8 {
    const p = animation.clampProgress(progress);
    const value = lerpF32(@floatFromInt(from), @floatFromInt(to), p);
    return @intFromFloat(@round(@max(0.0, @min(255.0, value))));
}

fn lerpColor(from: rl.Color, to: rl.Color, progress: f32) rl.Color {
    return .{
        .r = lerpChannel(from.r, to.r, progress),
        .g = lerpChannel(from.g, to.g, progress),
        .b = lerpChannel(from.b, to.b, progress),
        .a = lerpChannel(from.a, to.a, progress),
    };
}

fn invisibleShadow(reference: slides.TextShadow) slides.TextShadow {
    var result = reference;
    result.enabled = true;
    result.color.a = 0;
    return result;
}

fn effectiveShadow(value: ?slides.TextShadow, fallback: slides.TextShadow) slides.TextShadow {
    if (value) |shadow| {
        if (shadow.enabled) return shadow;
        return invisibleShadow(shadow);
    }
    return invisibleShadow(fallback);
}

fn lerpShadow(from: ?slides.TextShadow, to: ?slides.TextShadow, progress: f32) ?slides.TextShadow {
    if (progress == 0.0) return from;
    if (progress == 1.0) return to;
    if (from == null and to == null) return null;
    const fallback = from orelse to.?;
    const source = effectiveShadow(from, fallback);
    const target = effectiveShadow(to, fallback);
    return .{
        .enabled = true,
        .color = lerpColor(source.color, target.color, progress),
        .offset = lerpVector(source.offset, target.offset, progress),
    };
}

fn interpolateElement(from: *const RenderElement, to: *const RenderElement, progress: f32) RenderElement {
    if (progress == 0.0) return from.*;
    if (progress == 1.0) return to.*;
    const clamped = animation.clampProgress(progress);
    var result = to.*;
    result.position = lerpVector(from.position, to.position, progress);
    result.size = lerpVector(from.size, to.size, progress);
    result.size.x = @max(0.0, result.size.x);
    result.size.y = @max(0.0, result.size.y);
    result.opacity = lerpF32(from.opacity, to.opacity, clamped);
    if (from.color != null and to.color != null) result.color = lerpColor(from.color.?, to.color.?, clamped);
    if (from.fontSize != null and to.fontSize != null) result.fontSize = @max(1.0, lerpF32(from.fontSize.?, to.fontSize.?, progress));
    if (from.underline_width != null and to.underline_width != null) {
        result.underline_width = @intFromFloat(@round(lerpF32(
            @floatFromInt(from.underline_width.?),
            @floatFromInt(to.underline_width.?),
            clamped,
        )));
    }
    result.text_shadow = lerpShadow(from.text_shadow, to.text_shadow, progress);
    result.reveal_step = 0;
    return result;
}

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

fn pollChoiceCard(choice: ?u8, card_count: usize) ?usize {
    const index = choice orelse return null;
    if (index >= card_count) return null;
    return @intCast(index);
}

fn drawPollSwarm(snapshot: crowdplay.Snapshot, cards: []const rl.Rectangle, scale: f32, opacity: f32) void {
    if (cards.len == 0) return;
    const now: f32 = @floatCast(rl.getTime());
    const max_visible: usize = @min(snapshot.participant_count, 260);
    for (snapshot.participants[0..max_visible], 0..) |participant, index| {
        const choice_card = pollChoiceCard(participant.choice, cards.len);
        const card = if (choice_card) |card_index| cards[card_index] else cards[index % cards.len];
        const phase = seedUnit(participant.seed, 0) * std.math.tau + now * (0.18 + seedUnit(participant.seed, 16) * 0.32);
        var position: rl.Vector2 = undefined;
        if (choice_card != null) {
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
        const color = if (choice_card) |card_index| crowdPalette(card_index) else crowdPalette(@intCast((participant.seed +% index) % crowdplay.max_choices));
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

fn replaceSlideNumber(allocator: std.mem.Allocator, text: []const u8, slide_number: usize) ![]u8 {
    var buffer: [20]u8 = undefined;
    const number = try std.fmt.bufPrint(&buffer, "{d}", .{slide_number});
    return std.mem.replaceOwned(u8, allocator, text, "$slide_number", number);
}

test "line and bullet grouping leave surrounding content static" {
    try std.testing.expect(startsLineStep(.line, false));
    try std.testing.expect(startsLineStep(.line, true));
    try std.testing.expect(!startsLineStep(.bullet, false));
    try std.testing.expect(startsLineStep(.bullet, true));
    try std.testing.expect(!startsLineStep(.item, true));
}

test "slide number replacement excludes unused formatter bytes" {
    const rendered = try replaceSlideNumber(std.testing.allocator, "page $slide_number of $slide_number", 6);
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings("page 6 of 6", rendered);
}

test "repeated preRender releases slides morph scenes plans and owned text" {
    const allocator = std.testing.allocator;
    var unused_fonts: my_fonts.AvailableFonts = undefined;
    const renderer = try SlideshowRenderer.new(allocator, &unused_fonts);
    defer renderer.deinit();

    var slideshow: slides.SlideShow = .{ .slides = std.ArrayList(*slides.Slide).empty };
    defer slideshow.slides.deinit(allocator);
    var slide: slides.Slide = .{ .allocator = allocator };
    slide.items = std.ArrayList(slides.SlideItem).empty;
    slide.morph_states = std.ArrayList(slides.MorphState).empty;
    defer {
        slide.items.?.deinit(allocator);
        for (slide.morph_states.items) |*morph_state| morph_state.items.deinit(allocator);
        slide.morph_states.deinit(allocator);
    }

    try slide.items.?.append(allocator, .{
        .identity = 1,
        .kind = .background,
        .color = .black,
    });
    var state: slides.MorphState = .{};
    state.items = std.ArrayList(slides.SlideItem).empty;
    try state.items.append(allocator, .{
        .identity = 1,
        .kind = .background,
        .color = .white,
    });
    try slide.morph_states.append(allocator, state);
    try slideshow.slides.append(allocator, &slide);

    for (0..8) |_| {
        try renderer.preRender(&slideshow, "");
        try std.testing.expectEqual(@as(usize, 1), renderer.renderedSlides.items.len);
        const rendered_slide = renderer.renderedSlides.items[0];
        try std.testing.expectEqual(@as(usize, 1), rendered_slide.morph_scenes.items.len);
        try std.testing.expectEqual(@as(usize, 1), rendered_slide.steps.items.len);
        _ = try renderer.ownRenderedText(rendered_slide, "owned base text");
        const scene_text = try allocator.dupeZ(u8, "owned morph text");
        errdefer allocator.free(scene_text);
        try rendered_slide.morph_scenes.items[0].owned_text.append(allocator, scene_text);
    }

    // An empty successful rebuild is still a rebuild: it must retire the
    // previous graph rather than leave stale slides alive.
    slideshow.slides.clearRetainingCapacity();
    try renderer.preRender(&slideshow, "");
    try std.testing.expectEqual(@as(usize, 0), renderer.renderedSlides.items.len);
}

test "preRenderChanged preserves unchanged slides and replaces only semantic changes" {
    const allocator = std.testing.allocator;
    var unused_fonts: my_fonts.AvailableFonts = undefined;
    const renderer = try SlideshowRenderer.new(allocator, &unused_fonts);
    defer renderer.deinit();

    var slideshow: slides.SlideShow = .{ .slides = std.ArrayList(*slides.Slide).empty };
    defer slideshow.slides.deinit(allocator);
    var slide_a: slides.Slide = .{ .allocator = allocator };
    slide_a.items = std.ArrayList(slides.SlideItem).empty;
    slide_a.morph_states = std.ArrayList(slides.MorphState).empty;
    defer {
        slide_a.items.?.deinit(allocator);
        for (slide_a.morph_states.items) |*state| state.items.deinit(allocator);
        slide_a.morph_states.deinit(allocator);
    }
    var slide_b: slides.Slide = .{ .allocator = allocator };
    slide_b.items = std.ArrayList(slides.SlideItem).empty;
    slide_b.morph_states = std.ArrayList(slides.MorphState).empty;
    defer {
        slide_b.items.?.deinit(allocator);
        for (slide_b.morph_states.items) |*state| state.items.deinit(allocator);
        slide_b.morph_states.deinit(allocator);
    }
    try slide_a.items.?.append(allocator, .{
        .identity = 1,
        .kind = .background,
        .color = .black,
        .source = .{ .scope = .direct, .line_offset = 10, .patchable = true },
    });
    try slide_b.items.?.append(allocator, .{
        .identity = 1,
        .kind = .background,
        .color = .white,
        .source = .{ .scope = .direct, .line_offset = 20, .patchable = true },
    });
    try slideshow.slides.append(allocator, &slide_a);
    try slideshow.slides.append(allocator, &slide_b);

    const initial = try renderer.preRenderChanged(&slideshow, "deck.sld");
    try std.testing.expectEqual(SlideshowRenderer.RebuildMode.full, initial.mode);
    try std.testing.expectEqual(@as(usize, 2), initial.rebuilt_slide_count);
    const first_a = @intFromPtr(renderer.renderedSlides.items[0]);
    const first_b = @intFromPtr(renderer.renderedSlides.items[1]);

    // Parser/source ownership can move when earlier bytes are edited without
    // changing anything consumed by the renderer.
    slide_a.items.?.items[0].source.line_offset = 10_000;
    const unchanged = try renderer.preRenderChanged(&slideshow, "deck.sld");
    try std.testing.expectEqual(SlideshowRenderer.RebuildMode.unchanged, unchanged.mode);
    try std.testing.expectEqual(@as(usize, 0), unchanged.rebuilt_slide_count);
    try std.testing.expectEqual(first_a, @intFromPtr(renderer.renderedSlides.items[0]));
    try std.testing.expectEqual(first_b, @intFromPtr(renderer.renderedSlides.items[1]));

    slide_a.items.?.items[0].color = .red;
    const one_changed = try renderer.preRenderChanged(&slideshow, "deck.sld");
    try std.testing.expectEqual(SlideshowRenderer.RebuildMode.partial, one_changed.mode);
    try std.testing.expectEqual(@as(usize, 1), one_changed.rebuilt_slide_count);
    try std.testing.expect(first_a != @intFromPtr(renderer.renderedSlides.items[0]));
    try std.testing.expectEqual(first_b, @intFromPtr(renderer.renderedSlides.items[1]));
    try std.testing.expectEqual(rl.Color.red, renderer.renderedSlides.items[0].elements.items[0].color.?);

    const second_a = @intFromPtr(renderer.renderedSlides.items[0]);
    var morph_state: slides.MorphState = .{ .spec = .{ .duration = 0.9, .easing = .linear } };
    morph_state.items = std.ArrayList(slides.SlideItem).empty;
    try morph_state.items.append(allocator, .{
        .identity = 1,
        .kind = .background,
        .color = .blue,
    });
    try slide_b.morph_states.append(allocator, morph_state);
    const morph_changed = try renderer.preRenderChanged(&slideshow, "deck.sld");
    try std.testing.expectEqual(SlideshowRenderer.RebuildMode.partial, morph_changed.mode);
    try std.testing.expectEqual(@as(usize, 1), morph_changed.rebuilt_slide_count);
    try std.testing.expectEqual(second_a, @intFromPtr(renderer.renderedSlides.items[0]));
    try std.testing.expectEqual(@as(usize, 1), renderer.renderedSlides.items[1].morph_scenes.items.len);
    try std.testing.expectEqual(@as(usize, 1), renderer.renderedSlides.items[1].steps.items.len);

    var slide_c: slides.Slide = .{ .allocator = allocator };
    slide_c.items = std.ArrayList(slides.SlideItem).empty;
    slide_c.morph_states = std.ArrayList(slides.MorphState).empty;
    defer {
        slide_c.items.?.deinit(allocator);
        slide_c.morph_states.deinit(allocator);
    }
    try slide_c.items.?.append(allocator, .{ .identity = 1, .kind = .background, .color = .green });
    try slideshow.slides.append(allocator, &slide_c);
    const structural = try renderer.preRenderChanged(&slideshow, "deck.sld");
    try std.testing.expectEqual(SlideshowRenderer.RebuildMode.full, structural.mode);
    try std.testing.expectEqual(@as(usize, 3), structural.rebuilt_slide_count);
}

test "rendered Crowd data survives parser arena replacement" {
    const allocator = std.testing.allocator;
    var unused_fonts: my_fonts.AvailableFonts = undefined;
    const renderer = try SlideshowRenderer.new(allocator, &unused_fonts);
    defer renderer.deinit();

    var parser_arena = std.heap.ArenaAllocator.init(allocator);
    var parser_arena_live = true;
    defer if (parser_arena_live) parser_arena.deinit();
    const parser_allocator = parser_arena.allocator();
    const slideshow = try slides.SlideShow.new(parser_allocator);
    const slide = try slides.Slide.new(parser_allocator);
    const choices = try parser_allocator.alloc([]const u8, 2);
    choices[0] = try parser_allocator.dupe(u8, "Cyan");
    choices[1] = try parser_allocator.dupe(u8, "Magenta");
    try slide.items.?.append(parser_allocator, .{
        .identity = 1,
        .kind = .crowd,
        .position = .{ .x = 100, .y = 80 },
        .size = .{ .x = 1720, .y = 920 },
        .crowd = .{
            .kind = .poll,
            .id = try parser_allocator.dupe(u8, "palette"),
            .prompt = try parser_allocator.dupe(u8, "Pick a color"),
            .choices = choices,
        },
    });
    var morph_state: slides.MorphState = .{};
    morph_state.items = std.ArrayList(slides.SlideItem).empty;
    try morph_state.items.append(parser_allocator, .{
        .identity = 1,
        .kind = .crowd,
        .position = .{ .x = 120, .y = 90 },
        .size = .{ .x = 1700, .y = 900 },
        .crowd = .{
            .kind = .join,
            .id = try parser_allocator.dupe(u8, "joined"),
            .prompt = try parser_allocator.dupe(u8, "You are in"),
        },
    });
    try slide.morph_states.append(parser_allocator, morph_state);
    try slideshow.slides.append(parser_allocator, slide);

    _ = try renderer.preRenderChanged(slideshow, "deck.sld");
    parser_arena.deinit();
    parser_arena_live = false;

    const base_crowd = renderer.renderedSlides.items[0].elements.items[0].crowd.?;
    try std.testing.expectEqualStrings("palette", base_crowd.id);
    try std.testing.expectEqualStrings("Pick a color", base_crowd.prompt);
    try std.testing.expectEqual(@as(usize, 2), base_crowd.choices.len);
    try std.testing.expectEqualStrings("Cyan", base_crowd.choices[0]);
    try std.testing.expectEqualStrings("Magenta", base_crowd.choices[1]);

    const state_crowd = renderer.renderedSlides.items[0].morph_scenes.items[0].elements.items[0].crowd.?;
    try std.testing.expectEqualStrings("joined", state_crowd.id);
    try std.testing.expectEqualStrings("You are in", state_crowd.prompt);
}

test "shared source changes rebuild exactly the parsed dependent slides" {
    const allocator = std.testing.allocator;
    var unused_fonts: my_fonts.AvailableFonts = undefined;
    const renderer = try SlideshowRenderer.new(allocator, &unused_fonts);
    defer renderer.deinit();

    const original =
        "@push card x=10 y=20 w=300 h=80 color=#112233ff\n" ++
        "@slide\n" ++
        "@pop card id=first\n" ++
        "@slide\n" ++
        "@box id=unrelated x=40 y=50 w=100 h=70 color=#abcdef12\n" ++
        "@slide\n" ++
        "@pop card id=second\n";
    const changed =
        "@push card x=10 y=20 w=300 h=80 color=#ee3366ff\n" ++
        "@slide\n" ++
        "@pop card id=first\n" ++
        "@slide\n" ++
        "@box id=unrelated x=40 y=50 w=100 h=70 color=#abcdef12\n" ++
        "@slide\n" ++
        "@pop card id=second\n";

    var first_arena = std.heap.ArenaAllocator.init(allocator);
    const first_slideshow = try slides.SlideShow.new(first_arena.allocator());
    const first_context = try parser.constructSlidesFromBuf(original, first_slideshow, first_arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), first_context.parser_errors.items.len);
    try std.testing.expectEqual(@as(usize, 3), first_slideshow.slides.items.len);
    const initial = try renderer.preRenderChanged(first_slideshow, "deck.sld");
    try std.testing.expectEqual(SlideshowRenderer.RebuildMode.full, initial.mode);
    const unrelated_pointer = @intFromPtr(renderer.renderedSlides.items[1]);
    first_context.deinit();
    first_arena.deinit();

    var second_arena = std.heap.ArenaAllocator.init(allocator);
    defer second_arena.deinit();
    const second_slideshow = try slides.SlideShow.new(second_arena.allocator());
    const second_context = try parser.constructSlidesFromBuf(changed, second_slideshow, second_arena.allocator());
    defer second_context.deinit();
    try std.testing.expectEqual(@as(usize, 0), second_context.parser_errors.items.len);
    const selective = try renderer.preRenderChanged(second_slideshow, "deck.sld");
    try std.testing.expectEqual(SlideshowRenderer.RebuildMode.partial, selective.mode);
    try std.testing.expectEqual(@as(usize, 2), selective.rebuilt_slide_count);
    try std.testing.expectEqual(unrelated_pointer, @intFromPtr(renderer.renderedSlides.items[1]));
    try std.testing.expectEqual(@as(u8, 0xee), renderer.renderedSlides.items[0].elements.items[0].color.?.r);
    try std.testing.expectEqual(@as(u8, 0xee), renderer.renderedSlides.items[2].elements.items[0].color.?.r);
}

test "failed selective rebuild leaves every live slide untouched" {
    const backing_allocator = std.testing.allocator;
    var failing = std.testing.FailingAllocator.init(backing_allocator, .{});
    var unused_fonts: my_fonts.AvailableFonts = undefined;
    const renderer = try SlideshowRenderer.new(failing.allocator(), &unused_fonts);
    defer renderer.deinit();

    var slideshow: slides.SlideShow = .{ .slides = std.ArrayList(*slides.Slide).empty };
    defer slideshow.slides.deinit(backing_allocator);
    var slide_a: slides.Slide = .{ .allocator = backing_allocator };
    slide_a.items = std.ArrayList(slides.SlideItem).empty;
    slide_a.morph_states = std.ArrayList(slides.MorphState).empty;
    defer {
        slide_a.items.?.deinit(backing_allocator);
        slide_a.morph_states.deinit(backing_allocator);
    }
    var slide_b: slides.Slide = .{ .allocator = backing_allocator };
    slide_b.items = std.ArrayList(slides.SlideItem).empty;
    slide_b.morph_states = std.ArrayList(slides.MorphState).empty;
    defer {
        slide_b.items.?.deinit(backing_allocator);
        slide_b.morph_states.deinit(backing_allocator);
    }
    try slide_a.items.?.append(backing_allocator, .{ .identity = 1, .kind = .background, .color = .black });
    try slide_b.items.?.append(backing_allocator, .{ .identity = 1, .kind = .background, .color = .white });
    try slideshow.slides.append(backing_allocator, &slide_a);
    try slideshow.slides.append(backing_allocator, &slide_b);
    _ = try renderer.preRenderChanged(&slideshow, "deck.sld");
    const first_pointer = @intFromPtr(renderer.renderedSlides.items[0]);
    const second_pointer = @intFromPtr(renderer.renderedSlides.items[1]);

    slide_a.items.?.items[0].color = .red;
    slide_b.items.?.items[0].color = .blue;
    // replacements allocation + the first slide's struct/elements succeed;
    // constructing the second replacement then fails. No index may have
    // swapped yet.
    failing.fail_index = failing.alloc_index + 3;
    try std.testing.expectError(error.OutOfMemory, renderer.preRenderChanged(&slideshow, "deck.sld"));
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(first_pointer, @intFromPtr(renderer.renderedSlides.items[0]));
    try std.testing.expectEqual(second_pointer, @intFromPtr(renderer.renderedSlides.items[1]));
    try std.testing.expectEqual(rl.Color.black, renderer.renderedSlides.items[0].elements.items[0].color.?);
    try std.testing.expectEqual(rl.Color.white, renderer.renderedSlides.items[1].elements.items[0].color.?);
}

test "Studio owner bounds are collected in one render-fragment pass" {
    const allocator = std.testing.allocator;
    var unused_fonts: my_fonts.AvailableFonts = undefined;
    const renderer = try SlideshowRenderer.new(allocator, &unused_fonts);
    defer renderer.deinit();

    const rendered_slide = try RenderedSlide.new(allocator);
    var rendered_slide_owned = true;
    errdefer if (rendered_slide_owned) renderer.destroyRenderedSlide(rendered_slide);
    const owner_count: usize = 400;
    const fragments_per_owner: usize = 3;
    for (0..owner_count) |owner_index| {
        for (0..fragments_per_owner) |fragment_index| {
            try rendered_slide.elements.append(allocator, .{
                .kind = .text,
                .owner_identity = owner_index + 1,
                .part_index = fragment_index,
                .position = .{
                    .x = @floatFromInt(owner_index * 2 + fragment_index),
                    .y = @floatFromInt(owner_index + fragment_index * 4),
                },
                .size = .{ .x = 20, .y = 10 },
            });
        }
    }
    try renderer.renderedSlides.append(allocator, rendered_slide);
    rendered_slide_owned = false;

    var bounds = std.ArrayList(SlideshowRenderer.ItemRenderBounds).empty;
    defer bounds.deinit(allocator);
    const fragments_scanned = try renderer.collectItemRenderBoundsForMorphState(
        allocator,
        &bounds,
        0,
        null,
    );
    try std.testing.expectEqual(owner_count * fragments_per_owner, fragments_scanned);
    try std.testing.expectEqual(owner_count, bounds.items.len);

    for ([_]usize{ 0, owner_count / 2, owner_count - 1 }) |index| {
        const legacy = renderer.itemRenderBoundsForMorphState(0, null, index + 1).?;
        try std.testing.expectEqual(index + 1, bounds.items[index].owner_identity);
        try std.testing.expectEqual(legacy, bounds.items[index].bounds);
    }
}

test "inline font boundaries use the wider neighboring space in both directions" {
    const before_chunky = inlineBoundarySpacing("Add ", 4, null, 10);
    try std.testing.expectApproxEqAbs(@as(f32, 0), before_chunky.leading, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 6), before_chunky.trailing, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 18), boundaryWidth(12, before_chunky, 0, 4, 4), 0.0001);

    const after_chunky = inlineBoundarySpacing(" when", 4, 10, null);
    try std.testing.expectApproxEqAbs(@as(f32, 6), after_chunky.leading, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), after_chunky.trailing, 0.0001);

    const dense_on_both_sides = inlineBoundarySpacing(" ", 4, 10, 8);
    try std.testing.expectApproxEqAbs(@as(f32, 6), dense_on_both_sides.leading, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), dense_on_both_sides.trailing, 0.0001);
}

test "poll participant anchors to a valid selected choice before reveal" {
    try std.testing.expectEqual(@as(?usize, 1), pollChoiceCard(1, 4));
    try std.testing.expectEqual(@as(?usize, null), pollChoiceCard(null, 4));
    try std.testing.expectEqual(@as(?usize, null), pollChoiceCard(4, 4));
}

test "semantic morph interpolation preserves identity and continuous properties" {
    const same_text: [:0]const u8 = "same";
    const source = RenderElement{
        .kind = .text,
        .owner_identity = 7,
        .part_index = 0,
        .position = .{ .x = 100, .y = 200 },
        .size = .{ .x = 300, .y = 100 },
        .color = .{ .r = 0, .g = 10, .b = 20, .a = 100 },
        .text = same_text,
        .fontSize = 20,
        .opacity = 0.5,
    };
    const target = RenderElement{
        .kind = .text,
        .owner_identity = 7,
        .part_index = 0,
        .position = .{ .x = 300, .y = 400 },
        .size = .{ .x = 500, .y = 200 },
        .color = .{ .r = 100, .g = 110, .b = 120, .a = 200 },
        .text = same_text,
        .fontSize = 60,
        .opacity = 1.0,
        .text_shadow = .{ .color = .{ .r = 20, .g = 30, .b = 40, .a = 200 }, .offset = .{ .x = 8, .y = 10 } },
    };

    const halfway = interpolateElement(&source, &target, 0.5);
    try std.testing.expectEqual(@as(usize, 7), halfway.owner_identity);
    try std.testing.expectApproxEqAbs(@as(f32, 200), halfway.position.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 300), halfway.position.y, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 40), halfway.fontSize.?, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), halfway.opacity, 0.0001);
    try std.testing.expectEqual(@as(u8, 50), halfway.color.?.r);
    try std.testing.expectEqual(@as(u8, 100), halfway.text_shadow.?.color.a);
    try std.testing.expectEqual(source.position, interpolateElement(&source, &target, 0).position);
    try std.testing.expectEqual(target.position, interpolateElement(&source, &target, 1).position);
    const spring_position = interpolateElement(&source, &target, animation.applyEasing(.spring, 0.3)).position;
    try std.testing.expect(spring_position.x > target.position.x);
}

test "semantic morph matching survives reordered owners and rejects changed text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const one: [:0]const u8 = "one";
    const two: [:0]const u8 = "two";
    const changed: [:0]const u8 = "changed";
    const source = [_]RenderElement{
        .{ .kind = .text, .owner_identity = 1, .part_index = 0, .text = one },
        .{ .kind = .text, .owner_identity = 2, .part_index = 0, .text = two },
    };
    const reordered = [_]RenderElement{
        .{ .kind = .text, .owner_identity = 2, .part_index = 0, .text = two },
        .{ .kind = .text, .owner_identity = 1, .part_index = 0, .text = one },
    };
    const reordered_plan = try buildMorphPlan(allocator, &source, &reordered);
    try std.testing.expectEqual(@as(usize, 2), reordered_plan.draws.items.len);
    try std.testing.expectEqual(MorphDrawKind.interpolate, reordered_plan.draws.items[0].kind);
    try std.testing.expectEqual(@as(?usize, 1), reordered_plan.draws.items[0].source_index);
    try std.testing.expectEqual(@as(?usize, 0), reordered_plan.draws.items[1].source_index);

    var changed_target = reordered;
    changed_target[1].text = changed;
    const changed_plan = try buildMorphPlan(allocator, &source, &changed_target);
    try std.testing.expectEqual(@as(usize, 3), changed_plan.draws.items.len);
    try std.testing.expectEqual(MorphDrawKind.interpolate, changed_plan.draws.items[0].kind);
    try std.testing.expectEqual(MorphDrawKind.source_fade, changed_plan.draws.items[1].kind);
    try std.testing.expectEqual(MorphDrawKind.target_fade, changed_plan.draws.items[2].kind);
}

test "semantic morph plan keeps a changed foreground above its background" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const old_text: [:0]const u8 = "old";
    const new_text: [:0]const u8 = "new";
    const source = [_]RenderElement{
        .{ .kind = .background, .owner_identity = 1, .part_index = 0, .color = .black },
        .{ .kind = .text, .owner_identity = 2, .part_index = 0, .text = old_text },
    };
    const target = [_]RenderElement{
        .{ .kind = .background, .owner_identity = 1, .part_index = 0, .color = .white },
        .{ .kind = .text, .owner_identity = 2, .part_index = 0, .text = new_text },
    };

    const plan = try buildMorphPlan(allocator, &source, &target);
    try std.testing.expectEqual(@as(usize, 3), plan.draws.items.len);
    try std.testing.expectEqual(MorphDrawKind.interpolate, plan.draws.items[0].kind);
    try std.testing.expectEqual(@as(?usize, 0), plan.draws.items[0].target_index);
    try std.testing.expectEqual(MorphDrawKind.source_fade, plan.draws.items[1].kind);
    try std.testing.expectEqual(@as(?usize, 1), plan.draws.items[1].source_index);
    try std.testing.expectEqual(MorphDrawKind.target_fade, plan.draws.items[2].kind);
    try std.testing.expectEqual(@as(?usize, 1), plan.draws.items[2].target_index);
}

test "item background morphs below changed or unchanged foreground content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const old_text: [:0]const u8 = "old";
    const new_text: [:0]const u8 = "new";
    const source = [_]RenderElement{
        .{ .kind = .text, .owner_identity = 7, .part_index = 0, .is_item_background = true, .color = .black },
        .{ .kind = .text, .owner_identity = 7, .part_index = 0, .text = old_text },
    };
    const changed = [_]RenderElement{
        .{ .kind = .text, .owner_identity = 7, .part_index = 0, .is_item_background = true, .color = .white },
        .{ .kind = .text, .owner_identity = 7, .part_index = 0, .text = new_text },
    };

    const changed_plan = try buildMorphPlan(allocator, &source, &changed);
    try std.testing.expectEqual(@as(usize, 3), changed_plan.draws.items.len);
    try std.testing.expectEqual(MorphDrawKind.interpolate, changed_plan.draws.items[0].kind);
    try std.testing.expectEqual(@as(?usize, 0), changed_plan.draws.items[0].target_index);
    try std.testing.expectEqual(MorphDrawKind.source_fade, changed_plan.draws.items[1].kind);
    try std.testing.expectEqual(@as(?usize, 1), changed_plan.draws.items[1].source_index);
    try std.testing.expectEqual(MorphDrawKind.target_fade, changed_plan.draws.items[2].kind);
    try std.testing.expectEqual(@as(?usize, 1), changed_plan.draws.items[2].target_index);

    const without_background = [_]RenderElement{
        .{ .kind = .text, .owner_identity = 7, .part_index = 0, .text = old_text },
    };
    const added_plan = try buildMorphPlan(allocator, &without_background, &source);
    try std.testing.expectEqual(@as(usize, 2), added_plan.draws.items.len);
    try std.testing.expectEqual(MorphDrawKind.target_fade, added_plan.draws.items[0].kind);
    try std.testing.expectEqual(@as(?usize, 0), added_plan.draws.items[0].target_index);
    try std.testing.expectEqual(MorphDrawKind.interpolate, added_plan.draws.items[1].kind);
    try std.testing.expectEqual(@as(?usize, 0), added_plan.draws.items[1].source_index);
    try std.testing.expectEqual(@as(?usize, 1), added_plan.draws.items[1].target_index);

    const removed_plan = try buildMorphPlan(allocator, &source, &without_background);
    try std.testing.expectEqual(@as(usize, 2), removed_plan.draws.items.len);
    try std.testing.expectEqual(MorphDrawKind.source_fade, removed_plan.draws.items[0].kind);
    try std.testing.expectEqual(@as(?usize, 0), removed_plan.draws.items[0].source_index);
    try std.testing.expectEqual(MorphDrawKind.interpolate, removed_plan.draws.items[1].kind);
    try std.testing.expectEqual(@as(?usize, 1), removed_plan.draws.items[1].source_index);
    try std.testing.expectEqual(@as(?usize, 0), removed_plan.draws.items[1].target_index);
}

test "stable semantic state follows morph steps in the shared timeline" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const slide = try RenderedSlide.new(allocator);
    try slide.steps.append(allocator, animation.Step.fromItem(.{ .effect = .fade }));
    try slide.steps.append(allocator, animation.Step.fromMorph(.{}, 0));
    try slide.steps.append(allocator, animation.Step.fromMorph(.{}, 1));

    try std.testing.expectEqual(@as(?usize, null), stableMorphState(slide, 1));
    try std.testing.expectEqual(@as(?usize, 0), stableMorphState(slide, 2));
    try std.testing.expectEqual(@as(?usize, 1), stableMorphState(slide, 3));
    try std.testing.expectEqual(@as(?usize, 1), stableMorphState(slide, 99));
}

test "Studio geometry preview moves all fragments and resizes visual surfaces" {
    const move: ItemGeometryPreview = .{
        .owner_identity = 7,
        .before_position = .{ .x = 100, .y = 200 },
        .before_size = .{ .x = 400, .y = 300 },
        .after_position = .{ .x = 130, .y = 180 },
        .after_size = .{ .x = 400, .y = 300 },
        .resized = false,
    };
    const text: RenderElement = .{
        .kind = .text,
        .owner_identity = 7,
        .position = .{ .x = 120, .y = 230 },
        .size = .{ .x = 80, .y = 30 },
        .text = "hello",
    };
    const moved = elementWithGeometryPreview(text, move);
    try std.testing.expectApproxEqAbs(@as(f32, 150), moved.position.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 210), moved.position.y, 0.0001);

    var resize = move;
    resize.after_position = move.before_position;
    resize.after_size = .{ .x = 800, .y = 150 };
    resize.resized = true;
    const image: RenderElement = .{
        .kind = .image,
        .owner_identity = 7,
        .position = .{ .x = 150, .y = 250 },
        .size = .{ .x = 200, .y = 100 },
    };
    const resized = elementWithGeometryPreview(image, resize);
    try std.testing.expectApproxEqAbs(@as(f32, 200), resized.position.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 225), resized.position.y, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 400), resized.size.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 50), resized.size.y, 0.0001);

    const text_resize = elementWithGeometryPreview(text, resize);
    try std.testing.expectEqual(text.position, text_resize.position);
    try std.testing.expectEqual(text.size, text_resize.size);
}

test "Studio geometry preview batches resolve by item identity" {
    const previews = [_]ItemGeometryPreview{
        .{
            .owner_identity = 7,
            .before_position = .{ .x = 0, .y = 0 },
            .before_size = .{ .x = 10, .y = 10 },
            .after_position = .{ .x = 20, .y = 30 },
            .after_size = .{ .x = 10, .y = 10 },
            .resized = false,
        },
        .{
            .owner_identity = 9,
            .before_position = .{ .x = 100, .y = 100 },
            .before_size = .{ .x = 20, .y = 20 },
            .after_position = .{ .x = 80, .y = 90 },
            .after_size = .{ .x = 20, .y = 20 },
            .resized = false,
        },
    };

    try std.testing.expectEqual(@as(usize, 7), geometryPreviewFor(&previews, 7).?.owner_identity);
    try std.testing.expectEqual(@as(usize, 9), geometryPreviewFor(&previews, 9).?.owner_identity);
    try std.testing.expect(geometryPreviewFor(&previews, 8) == null);
}

test "item-owned background is a bounded color part behind its content" {
    const item = slides.SlideItem{
        .kind = .textbox,
        .position = .{ .x = 120, .y = 240 },
        .size = .{ .x = 640, .y = 180 },
        .background_color = .{ .r = 12, .g = 34, .b = 56, .a = 200 },
    };
    const background = itemBackgroundElement(item).?;
    try std.testing.expectEqual(RenderElementKind.text, background.kind);
    try std.testing.expect(background.text == null);
    try std.testing.expectEqual(item.position, background.position);
    try std.testing.expectEqual(item.size, background.size);
    try std.testing.expectEqual(@as(u8, 12), background.color.?.r);
    try std.testing.expectEqual(@as(u8, 200), background.color.?.a);

    var without = item;
    without.background_color = null;
    try std.testing.expect(itemBackgroundElement(without) == null);
    var slide_background = item;
    slide_background.kind = .background;
    try std.testing.expect(itemBackgroundElement(slide_background) == null);
}

test "item-owned background resolves omitted image dimensions from content" {
    var background: RenderElement = .{
        .kind = .text,
        .position = .{ .x = 120, .y = 240 },
        .size = .zero(),
        .color = .black,
    };
    const content = [_]RenderElement{.{
        .kind = .image,
        .position = .{ .x = 120, .y = 240 },
        .size = .{ .x = 640, .y = 360 },
    }};

    resolveItemBackgroundGeometry(&background, &content);
    try std.testing.expectEqual(content[0].position, background.position);
    try std.testing.expectEqual(content[0].size, background.size);

    // An explicitly authored dimension remains authoritative while the other
    // dimension can still follow the resolved image aspect.
    background = .{
        .kind = .text,
        .position = .{ .x = 50, .y = 240 },
        .size = .{ .x = 500, .y = 0 },
        .color = .black,
    };
    resolveItemBackgroundGeometry(&background, &content);
    try std.testing.expectApproxEqAbs(@as(f32, 50), background.position.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 500), background.size.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 240), background.position.y, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 360), background.size.y, 0.0001);
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
