const std = @import("std");
const rl = @import("raylib");
const animation = @import("animation.zig");

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
    transition: animation.Transition = .{},
    morph_states: std.ArrayList(MorphState) = undefined,
    next_item_identity: usize = 1,

    // .

    pub fn new(a: std.mem.Allocator) !*Slide {
        log.debug("slide create 0 ", .{});
        var self: *Slide = try a.create(Slide);
        log.debug("slide create 2", .{});
        self.* = .{ .allocator = a };
        log.debug("slide create 3", .{});
        self.items = std.ArrayList(SlideItem).empty;
        self.morph_states = std.ArrayList(MorphState).empty;
        log.debug("slide create 4", .{});
        return self;
    }
    pub fn deinit(self: *Slide) void {
        self.items.deinit(self.allocator);
        for (self.morph_states.items) |*state| state.items.deinit(self.allocator);
        self.morph_states.deinit(self.allocator);
    }

    pub fn applyContext(self: *Slide, ctx: *ItemContext) void {
        if (ctx.fontSize) |fs| self.fontsize = fs;
        if (ctx.color) |col| self.text_color = col;
        if (ctx.bullet_color) |bul| self.bullet_color = bul;
        if (ctx.underline_width) |uw| self.underline_width = uw;
        if (ctx.bullet_symbol) |bs| self.bullet_symbol = bs;
        if (ctx.line_height_factor) |lhf| self.line_height_factor = lhf;
        if (ctx.transition) |transition| self.transition = transition;
    }

    pub fn fromSlide(orig: *Slide, a: std.mem.Allocator) !*Slide {
        var n = try new(a);
        n.fontsize = orig.fontsize;
        n.text_color = orig.text_color;
        n.bullet_color = orig.bullet_color;
        n.bullet_symbol = orig.bullet_symbol;
        n.underline_width = orig.underline_width;
        n.line_height_factor = orig.line_height_factor;
        n.transition = orig.transition;
        n.next_item_identity = orig.next_item_identity;
        try n.items.?.appendSlice(n.allocator, orig.items.?.items);
        for (orig.morph_states.items) |state| {
            var cloned_state = MorphState{ .spec = state.spec, .source = state.source };
            cloned_state.items = std.ArrayList(SlideItem).empty;
            try cloned_state.items.appendSlice(n.allocator, state.items.items);
            try n.morph_states.append(n.allocator, cloned_state);
        }
        return n;
    }

    pub fn currentItems(self: *Slide, active_state: ?usize) *std.ArrayList(SlideItem) {
        if (active_state) |state_index| return &self.morph_states.items[state_index].items;
        return &self.items.?;
    }

    pub fn beginMorphState(self: *Slide, spec: animation.MorphSpec, source_ref: SourceRef, previous_state: ?usize) !usize {
        const source = self.currentItems(previous_state);
        var state = MorphState{ .spec = spec, .source = source_ref };
        state.items = std.ArrayList(SlideItem).empty;
        try state.items.appendSlice(self.allocator, source.items);
        try self.morph_states.append(self.allocator, state);
        return self.morph_states.items.len - 1;
    }
};

pub const SlideItemKind = enum {
    background,
    textbox,
    img,
    crowd,
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
    CrowdSpecNull,
    CrowdIdNull,
    CrowdPromptNull,
    CrowdChoicesInvalid,
    CrowdIdTooLong,
    CrowdIdInvalid,
    CrowdPromptTooLong,
    CrowdChoiceTooLong,
};

pub const CrowdKind = enum {
    join,
    poll,
};

pub const CrowdSpec = struct {
    kind: CrowdKind,
    id: []const u8 = "",
    prompt: []const u8 = "",
    choices: []const []const u8 = &.{},
    initially_open: bool = true,
};

pub const crowd_default_position: rl.Vector2 = .{ .x = 100, .y = 80 };
pub const crowd_default_size: rl.Vector2 = .{ .x = 1720, .y = 920 };

pub const TextShadow = struct {
    enabled: bool = true,
    color: rl.Color = .black,
    offset: rl.Vector2 = .{ .x = 4.0, .y = 4.0 },
};

pub const MorphState = struct {
    spec: animation.MorphSpec = .{},
    /// Location of the @state directive that begins this snapshot. Editors
    /// use it as the insertion anchor when an item has no local override yet.
    source: SourceRef = .{},
    items: std.ArrayList(SlideItem) = undefined,
};

/// Describes the authoring construct that owns a logical item's source.
///
/// `slide_template` items keep the position of their original item directive,
/// not the position of the `@pushslide`/`@popslide` that captured or cloned
/// them. This makes the reference useful for precise source edits.
pub const SourceScope = enum(u8) {
    none,
    direct,
    component_instance,
    /// A member emitted by a literal `@popgroup` call. Its source points at
    /// the structural call rather than pretending that every emitted member
    /// is an independently patchable item directive.
    group_instance_member,
    slide_template,
    slide_instance_override,
    morph_item,
};

pub const SourceRef = struct {
    scope: SourceScope = .none,
    line_number: usize = 0,
    line_offset: usize = 0,
    /// False when @let expansion means this physical source line cannot be
    /// rewritten without a token-to-source mapping.
    patchable: bool = false,
};

/// The values authored by the shared slide-template definition, before an
/// individual `@popslide` instance or a semantic-morph state customizes the
/// item. Keeping this small, immutable layer beside the renderer-facing
/// effective values lets an editor apply a delta to the shared definition
/// without accidentally baking an instance-local value into every clone.
pub const TemplateItemValues = struct {
    text: ?[]const u8 = null,
    font_size: ?i32 = null,
    color: ?rl.Color = null,
    background_color: ?rl.Color = null,
    position: rl.Vector2 = .zero(),
    size: rl.Vector2 = .zero(),
    opacity: f32 = 1.0,
    visible: bool = true,
    locked: bool = false,
};

pub const SlideItem = struct {
    /// Stable within a logical slide and preserved by morph snapshots.
    identity: usize = 0,
    /// The semantic-morph state in which this item was created. Null means the
    /// item belongs to the authored base scene. Unlike `state_source_state`,
    /// this never changes when later snapshots apply @set/@show/@hide, so an
    /// editor can distinguish an item born in the selected state from an
    /// id-less item merely inherited from an earlier state.
    creation_morph_state: ?usize = null,
    /// Optional author-facing target for @set/@show/@hide.
    id: ?[]const u8 = null,
    /// Location and authoring scope of the directive that created this item.
    source: SourceRef = .{},
    /// Original literal `@box`/`@pop` line inside a reusable-group
    /// definition. `source` remains the `@popgroup` structural owner for an
    /// emitted instance, while this reference enables an editor to offer an
    /// explicit shared-definition edit without conflating the two scopes.
    group_member_source: ?SourceRef = null,
    /// Location of the most recent instance-local @set/@show/@hide directive
    /// applied to a slide-template item in the authored base scene. The
    /// creation source above deliberately remains the shared @pushslide item,
    /// so editors can distinguish and target the local override without
    /// changing every instance of the template.
    instance_source: ?SourceRef = null,
    /// Location of the most recent @set/@show/@hide directive that produced
    /// this item in a semantic-morph snapshot. The creation source above is
    /// deliberately retained, so an editor can target either the base item or
    /// the effective state override. Null means the snapshot still gets all
    /// of its values from the creation directive (or an earlier item birth).
    state_source: ?SourceRef = null,
    /// Index of the state that owns `state_source`. This is copied into later
    /// cumulative snapshots along with the item, allowing an editor to tell a
    /// local override from one inherited from an earlier state.
    state_source_state: ?usize = null,
    /// Snapshot of this item's shared `@pushslide` values. It is refreshed
    /// only when a slide template is captured, then survives instance and
    /// morph patches unchanged.
    shared_template_values: ?TemplateItemValues = null,
    kind: SlideItemKind = .background,
    text: ?[]const u8 = null,
    fontSize: ?i32 = null,
    line_height_factor: ?f32 = null,
    color: ?rl.Color = .blank,
    /// Optional fill behind this individual item. This is separate from an
    /// `@bg` slide-background item and does not affect item ordering.
    background_color: ?rl.Color = null,
    img_path: ?[]const u8 = null,
    position: rl.Vector2 = .{ .x = 0.0, .y = 0.0 },
    size: rl.Vector2 = .{ .x = 0.0, .y = 0.0 },

    underline_width: ?i32 = null,
    bullet_color: ?rl.Color = null,
    bullet_symbol: ?[]const u8 = null,

    // Image auto-dimension parameters
    scale: ?f32 = null,
    ratio: ?f32 = null,
    animation: ?animation.ItemSpec = null,
    text_shadow: ?TextShadow = null,
    crowd: ?CrowdSpec = null,
    opacity: f32 = 1.0,
    visible: bool = true,
    /// Persistent editor guard. Rendering is unchanged; Studio prevents
    /// accidental geometry and structural edits until the item is unlocked.
    locked: bool = false,

    pub fn new(a: std.mem.Allocator) !*SlideItem {
        const self = try a.create(SlideItem);
        self.* = .{};
        return self;
    }

    /// Source to patch when editing this item's authored base scene. A local
    /// slide-template override wins over the shared creation directive.
    pub fn effectiveBaseSource(self: *const SlideItem) SourceRef {
        return self.instance_source orelse self.source;
    }

    /// Source to patch when editing this item's currently displayed morph
    /// state. State-local overrides win over instance-local base overrides,
    /// which in turn win over the shared creation directive.
    pub fn effectiveSource(self: *const SlideItem) SourceRef {
        return self.state_source orelse self.instance_source orelse self.source;
    }

    /// Returns the immutable shared authoring layer for a slide-template
    /// clone. Non-template items intentionally have no such layer.
    pub fn sharedTemplateValues(self: *const SlideItem) ?TemplateItemValues {
        if (self.source.scope != .slide_template) return null;
        return self.shared_template_values;
    }

    /// Establishes a fresh shared authoring layer from the item's currently
    /// effective values. The parser calls this exactly at `@pushslide`
    /// capture boundaries, including nested captures.
    pub fn captureSharedTemplateValues(self: *SlideItem) void {
        self.shared_template_values = .{
            .text = self.text,
            .font_size = self.fontSize,
            .color = self.color,
            .background_color = self.background_color,
            .position = self.position,
            .size = self.size,
            .opacity = self.opacity,
            .visible = self.visible,
            .locked = self.locked,
        };
    }
    pub fn deinit(_: *Slide) void {
        // empty
    }

    pub fn applyContext(self: *SlideItem, context: ItemContext) void {
        if (context.text) |text| self.text = text;

        if (context.img_path) |img_path| self.img_path = img_path;
        if (context.fontSize) |fontsize| self.fontSize = fontsize;
        if (context.color) |color| self.color = color;
        if (context.has_background_color) self.background_color = context.background_color;
        if (context.position) |position| self.position = position;
        if (context.size) |size| self.size = size;
        if (context.underline_width) |w| self.underline_width = w;
        if (context.bullet_color) |color| self.bullet_color = color;
        if (context.bullet_symbol) |symbol| self.bullet_symbol = symbol;
        if (context.line_height_factor) |lhf| self.line_height_factor = lhf;
        if (context.scale) |s| self.scale = s;
        if (context.ratio) |r| self.ratio = r;
        if (context.animation) |anim| self.animation = anim;
        if (context.text_shadow) |shadow| self.text_shadow = shadow;
        if (context.crowd) |crowd| self.crowd = crowd;
        if (context.id) |id| self.id = id;
        if (context.opacity) |opacity| self.opacity = opacity;
        if (context.visible) |visible| self.visible = visible;
        if (context.locked) |locked| self.locked = locked;
    }

    pub fn applyPatch(self: *SlideItem, context: ItemContext) void {
        if (context.text) |text| self.text = text;
        if (context.crowd) |crowd| self.crowd = crowd;
        if (context.img_path) |img_path| self.img_path = img_path;
        if (context.fontSize) |fontsize| self.fontSize = fontsize;
        if (context.color) |color| self.color = color;
        if (context.has_background_color) self.background_color = context.background_color;
        if (context.position) |position| {
            if (context.has_x) self.position.x = position.x;
            if (context.has_y) self.position.y = position.y;
        }
        if (context.size) |size| {
            if (context.has_w) self.size.x = size.x;
            if (context.has_h) self.size.y = size.y;
        }
        if (context.underline_width) |width| self.underline_width = width;
        if (context.bullet_color) |color| self.bullet_color = color;
        if (context.bullet_symbol) |symbol| self.bullet_symbol = symbol;
        if (context.line_height_factor) |factor| self.line_height_factor = factor;
        if (context.scale) |scale| self.scale = scale;
        if (context.ratio) |ratio| self.ratio = ratio;
        if (context.text_shadow) |patch| {
            var shadow = self.text_shadow orelse TextShadow{};
            if (context.has_shadow_enabled) shadow.enabled = patch.enabled;
            if (context.has_shadow_color) shadow.color = patch.color;
            if (context.has_shadow_x) shadow.offset.x = patch.offset.x;
            if (context.has_shadow_y) shadow.offset.y = patch.offset.y;
            self.text_shadow = shadow;
        }
        if (context.opacity) |opacity| self.opacity = opacity;
        if (context.visible) |visible| self.visible = visible;
        if (context.locked) |locked| self.locked = locked;
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
        if (self.kind == .crowd) {
            const crowd = self.crowd orelse return SlideItemError.CrowdSpecNull;
            if (crowd.prompt.len == 0) return SlideItemError.CrowdPromptNull;
            if (crowd.prompt.len > 192) return SlideItemError.CrowdPromptTooLong;
            if (crowd.kind == .poll) {
                if (crowd.id.len == 0) return SlideItemError.CrowdIdNull;
                if (crowd.id.len > 48) return SlideItemError.CrowdIdTooLong;
                for (crowd.id) |char| {
                    if (!std.ascii.isAlphanumeric(char) and char != '-' and char != '_') return SlideItemError.CrowdIdInvalid;
                }
                if (crowd.choices.len < 2) return SlideItemError.CrowdChoicesInvalid;
                if (crowd.choices.len > 8) return SlideItemError.CrowdChoicesInvalid;
                for (crowd.choices) |choice| {
                    if (choice.len == 0) return SlideItemError.CrowdChoicesInvalid;
                    if (choice.len > 64) return SlideItemError.CrowdChoiceTooLong;
                }
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
                log.info(indent ++ " shadow: {any}", .{self.text_shadow});
                log.info(indent ++ "opacity: {d}", .{self.opacity});
            },
            .crowd => {
                log.info(indent ++ "Kind: Crowdplay", .{});
                log.info(indent ++ "  spec: {any}", .{self.crowd});
                log.info(indent ++ "   pos: {any}", .{self.position});
                log.info(indent ++ "  size: {any}", .{self.size});
            },
        }
        log.info(indent ++ "-----------------------", .{});
    }
};

pub const ItemContext = struct {
    directive: []const u8 = "", // @push, @slide, ...
    context_name: ?[]const u8 = null,
    id: ?[]const u8 = null,
    text: ?[]const u8 = null,
    fontSize: ?i32 = null,
    line_height_factor: ?f32 = null,
    color: ?rl.Color = null,
    /// Tri-state item fill: `has_background_color == false` means omitted,
    /// while true pairs with a color or null for `bg=none`.
    background_color: ?rl.Color = null,
    has_background_color: bool = false,
    img_path: ?[]const u8 = null,
    position: ?rl.Vector2 = null,
    size: ?rl.Vector2 = null,
    has_x: bool = false,
    has_y: bool = false,
    has_w: bool = false,
    has_h: bool = false,
    underline_width: ?i32 = null,
    bullet_color: ?rl.Color = null,
    bullet_symbol: ?[]const u8 = null,
    line_number: usize = 0,
    line_offset: usize = 0,
    source_patchable: bool = false,

    // Image auto-dimension parameters
    scale: ?f32 = null,
    ratio: ?f32 = null,
    animation: ?animation.ItemSpec = null,
    transition: ?animation.Transition = null,
    text_shadow: ?TextShadow = null,
    crowd: ?CrowdSpec = null,
    has_shadow_enabled: bool = false,
    has_shadow_color: bool = false,
    has_shadow_x: bool = false,
    has_shadow_y: bool = false,
    morph: ?animation.MorphSpec = null,
    opacity: ?f32 = null,
    visible: ?bool = null,
    locked: ?bool = null,

    pub fn applyOtherIfNull(self: *ItemContext, other: ItemContext) void {
        if (self.text == null) {
            if (other.text) |text| self.text = text;
        }
        if (self.id == null) {
            if (other.id) |id| self.id = id;
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
        if (!self.has_background_color and other.has_background_color) {
            self.background_color = other.background_color;
            self.has_background_color = true;
        }
        if (self.position) |own_position| {
            if (other.position) |inherited_position| {
                var merged = own_position;
                if (!self.has_x) merged.x = inherited_position.x;
                if (!self.has_y) merged.y = inherited_position.y;
                self.position = merged;
            }
        } else if (other.position) |position| {
            self.position = position;
        }
        self.has_x = self.has_x or other.has_x;
        self.has_y = self.has_y or other.has_y;
        if (self.size) |own_size| {
            if (other.size) |inherited_size| {
                var merged = own_size;
                if (!self.has_w) merged.x = inherited_size.x;
                if (!self.has_h) merged.y = inherited_size.y;
                self.size = merged;
            }
        } else if (other.size) |size| {
            self.size = size;
        }
        self.has_w = self.has_w or other.has_w;
        self.has_h = self.has_h or other.has_h;
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
        if (self.animation == null) {
            if (other.animation) |anim| self.animation = anim;
        }
        if (self.transition == null) {
            if (other.transition) |transition| self.transition = transition;
        }
        if (self.crowd == null) {
            if (other.crowd) |crowd| self.crowd = crowd;
        }
        if (self.text_shadow) |own_shadow| {
            if (other.text_shadow) |inherited_shadow| {
                var merged = own_shadow;
                if (!self.has_shadow_enabled) merged.enabled = inherited_shadow.enabled;
                if (!self.has_shadow_color) merged.color = inherited_shadow.color;
                if (!self.has_shadow_x) merged.offset.x = inherited_shadow.offset.x;
                if (!self.has_shadow_y) merged.offset.y = inherited_shadow.offset.y;
                self.text_shadow = merged;
            }
        } else if (other.text_shadow) |shadow| {
            self.text_shadow = shadow;
        }
        self.has_shadow_enabled = self.has_shadow_enabled or other.has_shadow_enabled;
        self.has_shadow_color = self.has_shadow_color or other.has_shadow_color;
        self.has_shadow_x = self.has_shadow_x or other.has_shadow_x;
        self.has_shadow_y = self.has_shadow_y or other.has_shadow_y;
        if (self.opacity == null) {
            if (other.opacity) |opacity| self.opacity = opacity;
        }
        if (self.visible == null) {
            if (other.visible) |visible| self.visible = visible;
        }
        if (self.locked == null) {
            if (other.locked) |locked| self.locked = locked;
        }
    }
};

test "slide cloning preserves morph source provenance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const original = try Slide.new(allocator);
    try original.items.?.append(allocator, .{
        .identity = 1,
        .source = .{ .scope = .direct, .line_number = 2, .line_offset = 7, .patchable = true },
        .instance_source = .{ .scope = .slide_instance_override, .line_number = 3, .line_offset = 21, .patchable = true },
        .shared_template_values = .{
            .text = "shared",
            .font_size = 42,
            .position = .{ .x = 10, .y = 20 },
            .size = .{ .x = 300, .y = 80 },
            .background_color = .{ .r = 1, .g = 2, .b = 3, .a = 4 },
        },
    });
    const state_index = try original.beginMorphState(
        .{},
        .{ .scope = .morph_item, .line_number = 3, .line_offset = 42, .patchable = true },
        null,
    );
    original.morph_states.items[state_index].items.items[0].state_source = .{
        .scope = .morph_item,
        .line_number = 4,
        .line_offset = 56,
        .patchable = true,
    };
    original.morph_states.items[state_index].items.items[0].state_source_state = state_index;
    original.morph_states.items[state_index].items.items[0].creation_morph_state = state_index;

    const clone = try Slide.fromSlide(original, allocator);
    try std.testing.expectEqual(@as(usize, 1), clone.morph_states.items.len);
    try std.testing.expectEqual(@as(usize, 21), clone.items.?.items[0].effectiveBaseSource().line_offset);
    try std.testing.expectEqual(SourceScope.slide_instance_override, clone.items.?.items[0].effectiveBaseSource().scope);
    try std.testing.expectEqual(@as(usize, 42), clone.morph_states.items[0].source.line_offset);
    try std.testing.expectEqual(@as(usize, 21), clone.morph_states.items[0].items.items[0].effectiveBaseSource().line_offset);
    try std.testing.expectEqual(@as(usize, 56), clone.morph_states.items[0].items.items[0].effectiveSource().line_offset);
    try std.testing.expectEqual(@as(?usize, 0), clone.morph_states.items[0].items.items[0].state_source_state);
    try std.testing.expectEqual(@as(?usize, 0), clone.morph_states.items[0].items.items[0].creation_morph_state);
    const cloned_values = clone.morph_states.items[0].items.items[0].shared_template_values.?;
    try std.testing.expectEqualStrings("shared", cloned_values.text.?);
    try std.testing.expectEqual(@as(?i32, 42), cloned_values.font_size);
    try std.testing.expectApproxEqAbs(@as(f32, 10), cloned_values.position.x, 0.0001);
    try std.testing.expectEqual(@as(u8, 4), cloned_values.background_color.?.a);
}
