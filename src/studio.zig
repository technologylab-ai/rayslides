//! Interaction and overlay logic for rayslides' visual Studio mode.
//!
//! This module handles selection, live geometry gestures, semantic property
//! controls, creation tools, and base/morph scene navigation. It deliberately
//! does not rewrite `.sld` source: `SlideItem` provenance lets the integration
//! layer consume the `GeometryCommand` and `SemanticCommand` intentions emitted
//! by `Studio.update`. During a geometry interaction the logical item is
//! mutated so the preview follows the pointer immediately; cancellation
//! restores the authored geometry.
//!
//! Studio operates on the item list for the scene selected by its caller: the
//! base slide items or one cumulative semantic-morph snapshot.

const std = @import("std");
const rl = @import("raylib");
const slides = @import("slides.zig");

pub const default_logical_size: rl.Vector2 = .{ .x = 1920, .y = 1080 };
pub const default_handle_size: f32 = 14;
pub const default_min_item_size: f32 = 8;

pub const SourceRef = slides.SourceRef;
pub const SourceScope = slides.SourceScope;

/// Concrete logical bounds resolved by the renderer. This is important for
/// images whose source only specifies one dimension (or neither): their raw
/// `SlideItem.size` contains zeroes even though the rendered image does not.
pub const ResolvedBounds = struct {
    identity: usize,
    position: rl.Vector2,
    size: rl.Vector2,
};

pub const Geometry = struct {
    position: rl.Vector2,
    size: rl.Vector2,

    pub fn fromItem(item: slides.SlideItem) Geometry {
        return .{ .position = item.position, .size = item.size };
    }

    pub fn applyTo(self: Geometry, item: *slides.SlideItem) void {
        item.position = self.position;
        item.size = self.size;
    }
};

/// A complete, allocation-free description of one undoable source edit.
pub const GeometryCommand = struct {
    item_identity: usize,
    source: slides.SourceRef,
    before_position: rl.Vector2,
    before_size: rl.Vector2,
    after_position: rl.Vector2,
    after_size: rl.Vector2,
    /// False for both pointer moves and keyboard nudges.
    resized: bool,
};

pub const EditCommand = GeometryCommand;

/// Transient geometry used by the renderer while the pointer is down. It is
/// never written to source; a completed gesture becomes a GeometryCommand.
pub const LivePreview = struct {
    item_identity: usize,
    before: Geometry,
    after: Geometry,
    resized: bool,
};

/// The already letterboxed region in which the slide is rendered.
pub const Viewport = struct {
    slide_top_left: rl.Vector2,
    slide_size: rl.Vector2,
    logical_size: rl.Vector2 = default_logical_size,

    pub fn valid(self: Viewport) bool {
        return self.slide_size.x > 0 and self.slide_size.y > 0 and
            self.logical_size.x > 0 and self.logical_size.y > 0;
    }

    pub fn containsScreenPoint(self: Viewport, point: rl.Vector2) bool {
        if (!self.valid()) return false;
        return point.x >= self.slide_top_left.x and
            point.y >= self.slide_top_left.y and
            point.x <= self.slide_top_left.x + self.slide_size.x and
            point.y <= self.slide_top_left.y + self.slide_size.y;
    }
};

pub fn logicalToScreen(viewport: Viewport, point: rl.Vector2) ?rl.Vector2 {
    if (!viewport.valid()) return null;
    return .{
        .x = viewport.slide_top_left.x + point.x * viewport.slide_size.x / viewport.logical_size.x,
        .y = viewport.slide_top_left.y + point.y * viewport.slide_size.y / viewport.logical_size.y,
    };
}

/// Conversion intentionally permits points outside the slide. A drag that
/// begins inside the canvas must continue naturally after crossing an edge.
pub fn screenToLogical(viewport: Viewport, point: rl.Vector2) ?rl.Vector2 {
    if (!viewport.valid()) return null;
    return .{
        .x = (point.x - viewport.slide_top_left.x) * viewport.logical_size.x / viewport.slide_size.x,
        .y = (point.y - viewport.slide_top_left.y) * viewport.logical_size.y / viewport.slide_size.y,
    };
}

pub fn geometryToScreenRect(viewport: Viewport, geometry: Geometry) ?rl.Rectangle {
    const top_left = logicalToScreen(viewport, geometry.position) orelse return null;
    if (!viewport.valid()) return null;
    return .{
        .x = top_left.x,
        .y = top_left.y,
        .width = geometry.size.x * viewport.slide_size.x / viewport.logical_size.x,
        .height = geometry.size.y * viewport.slide_size.y / viewport.logical_size.y,
    };
}

fn pointInGeometry(point: rl.Vector2, geometry: Geometry) bool {
    return point.x >= geometry.position.x and
        point.y >= geometry.position.y and
        point.x <= geometry.position.x + geometry.size.x and
        point.y <= geometry.position.y + geometry.size.y;
}

fn resolvedBoundsForIdentity(bounds: []const ResolvedBounds, identity: usize) ?ResolvedBounds {
    for (bounds) |resolved| {
        if (resolved.identity == identity) return resolved;
    }
    return null;
}

/// Keeps the authored position authoritative while filling missing image
/// dimensions from the renderer's resolved bounds.
pub fn itemGeometry(item: slides.SlideItem, resolved_bounds: []const ResolvedBounds) Geometry {
    const resolved = resolvedBoundsForIdentity(resolved_bounds, item.identity);
    return .{
        .position = item.position,
        .size = .{
            .x = if (item.size.x > 0) item.size.x else if (resolved) |value| value.size.x else item.size.x,
            .y = if (item.size.y > 0) item.size.y else if (resolved) |value| value.size.y else item.size.y,
        },
    };
}

fn isSelectable(item: slides.SlideItem, resolved_bounds: []const ResolvedBounds) bool {
    const geometry = itemGeometry(item, resolved_bounds);
    return item.kind != .background and item.visible and item.opacity > 0 and
        geometry.size.x > 0 and geometry.size.y > 0;
}

/// Returns the item index at `logical_point`, searching in reverse paint order.
/// Backgrounds and items without concrete bounds are deliberately ignored.
pub fn hitTest(items: []const slides.SlideItem, resolved_bounds: []const ResolvedBounds, logical_point: rl.Vector2) ?usize {
    var i = items.len;
    while (i > 0) {
        i -= 1;
        const item = items[i];
        if (!isSelectable(item, resolved_bounds)) continue;
        if (pointInGeometry(logical_point, itemGeometry(item, resolved_bounds))) return i;
    }
    return null;
}

pub fn itemIndexByIdentity(items: []const slides.SlideItem, identity: usize) ?usize {
    for (items, 0..) |item, index| {
        if (item.identity == identity) return index;
    }
    return null;
}

pub fn itemIndexBySource(items: []const slides.SlideItem, source: slides.SourceRef) ?usize {
    if (source.scope == .none) return null;
    for (items, 0..) |item, index| {
        if (sourceEqual(item.source, source)) return index;
    }
    return null;
}

fn sourceEqual(a: slides.SourceRef, b: slides.SourceRef) bool {
    return a.scope == b.scope and a.line_number == b.line_number and
        a.line_offset == b.line_offset and a.patchable == b.patchable;
}

fn sourceScopeLabel(scope: slides.SourceScope) []const u8 {
    return switch (scope) {
        .none => "source unknown",
        .direct => "direct item",
        .component_instance => "component instance",
        .slide_template => "shared layout item",
        .morph_item => "morph item",
    };
}

pub const Interaction = enum {
    idle,
    moving,
    resizing,
};

pub const Status = enum {
    inactive,
    ready,
    selected,
    moving,
    resizing,
};

pub const Notice = enum {
    none,
    saved,
    copy_saved,
    save_failed,
    source_changed_on_disk,
    edit_failed,
    undo_failed,
    shared_template_locked,
    generated_source_read_only,
    property_unavailable,
    base_scene_only,
    structural_source_locked,
};

/// The active canvas tool. Creation tools are deliberately one-shot: after a
/// canvas click emits an add command Studio returns to Select. This keeps the
/// presentation source as the authority while still making placement visual.
pub const Tool = enum {
    select,
    add_text,
    add_bullets,
    add_image,
    add_shape,
    add_reusable,
};

pub const NewItemKind = enum {
    text,
    bullets,
    image,
    shape,
};

pub const PaletteColor = enum {
    white,
    black,
    red,
    orange,
    yellow,
    green,
    cyan,
    blue,
};

pub const palette = [_]PaletteColor{ .white, .black, .red, .orange, .yellow, .green, .cyan, .blue };

pub fn paletteColor(value: PaletteColor) rl.Color {
    return switch (value) {
        .white => .{ .r = 245, .g = 247, .b = 252, .a = 255 },
        .black => .{ .r = 20, .g = 24, .b = 34, .a = 255 },
        .red => .{ .r = 244, .g = 92, .b = 92, .a = 255 },
        .orange => .{ .r = 247, .g = 164, .b = 29, .a = 255 },
        .yellow => .{ .r = 246, .g = 218, .b = 85, .a = 255 },
        .green => .{ .r = 86, .g = 204, .b = 139, .a = 255 },
        .cyan => .{ .r = 80, .g = 215, .b = 255, .a = 255 },
        .blue => .{ .r = 102, .g = 139, .b = 255, .a = 255 },
    };
}

pub const CommandTarget = struct {
    item_identity: usize,
    source: slides.SourceRef,
};

pub const AddItemCommand = struct {
    kind: NewItemKind,
    position: rl.Vector2,
    suggested_size: rl.Vector2,
    /// Shapes begin as a visible colored rectangle; other creation flows get
    /// their foreground from authored slide defaults.
    suggested_color: ?PaletteColor = null,
};

pub const ColorCommand = struct {
    target: CommandTarget,
    color: PaletteColor,
};

pub const MorphSceneCommand = struct {
    /// null selects the authored base scene; otherwise this is a zero-based
    /// morph-state index.
    active_state: ?usize,
};

pub const AddReusableCommand = struct {
    position: rl.Vector2,
    suggested_size: rl.Vector2,
    /// Index in the caller-provided Workspace.library slice. Null preserves
    /// the original prompt-driven `U` tool workflow.
    library_entry_index: ?usize = null,
};

pub const SlideMoveDirection = enum {
    up,
    down,
};

pub const SlideMoveCommand = struct {
    slide_index: usize,
    direction: SlideMoveDirection,
};

/// Compact, renderer-independent metadata for one organizer card. `index` is
/// the caller's stable slide index and need not match the summary's array
/// offset (although dense, ordered summaries are the natural representation).
pub const SlideSummary = struct {
    index: usize,
    title: []const u8 = "",
    item_count: usize = 0,
    morph_count: usize = 0,
};

pub const LibraryEntryKind = enum {
    element,
    slide_template,
};

/// A named, source-defined reusable shown in the Studio library. Studio never
/// retains `name`; commands use `library_entry_index`, so caller-owned strings
/// can safely be replaced after a reparse.
pub const LibraryEntry = struct {
    kind: LibraryEntryKind,
    name: []const u8,
    available: bool = true,
};

/// Optional deck-level UI supplied by the integration layer. The legacy
/// update/draw entry points use an invisible workspace, preserving the canvas-
/// only API for tests and alternate frontends.
pub const Workspace = struct {
    visible: bool = false,
    slides: []const SlideSummary = &.{},
    current_slide: usize = 0,
    library: []const LibraryEntry = &.{},
};

/// Source-level intentions emitted by the visual controls. Unlike
/// GeometryCommand, these never mutate SlideItem; the integration layer can
/// prompt for text/path details and atomically rewrite/reparse the `.sld`.
pub const SemanticCommand = union(enum) {
    add_item: AddItemCommand,
    delete_item: CommandTarget,
    edit_text: CommandTarget,
    set_foreground: ColorCommand,
    set_background: ColorCommand,
    promote_to_reusable: CommandTarget,
    select_morph_scene: MorphSceneCommand,
    new_slide: void,
    select_slide: usize,
    duplicate_slide: usize,
    delete_slide: usize,
    move_slide: SlideMoveCommand,
    /// Creates a new slide using the indexed `slide_template` library entry.
    new_slide_from_template: usize,
    /// The integration layer prompts for an existing @push name and inserts
    /// the corresponding @pop instance at this visual placement.
    add_reusable: AddReusableCommand,
};

/// Stable hit targets shared by drawing, mouse handling, and tests. Keeping
/// this layout in logical UI code also makes a future alternate frontend easy.
pub const UiLayout = struct {
    toolbar: rl.Rectangle,
    tool_buttons: [6]rl.Rectangle,
    new_slide: rl.Rectangle,
    scene_previous: rl.Rectangle,
    scene_label: rl.Rectangle,
    scene_next: rl.Rectangle,
    properties: rl.Rectangle,
    edit_text: rl.Rectangle,
    delete_item: rl.Rectangle,
    promote: rl.Rectangle,
    foreground_swatches: [palette.len]rl.Rectangle,
    background_swatches: [palette.len]rl.Rectangle,
};

pub const organizer_action_count = 5;
pub const slide_card_height: f32 = 88;
pub const slide_card_gap: f32 = 7;
pub const library_row_height: f32 = 46;
pub const library_row_gap: f32 = 6;
pub const workspace_min_height: f32 = 260;

/// Geometry for the deck-level sidebar. Dynamic card/row rectangles are
/// derived with slideCardRect/libraryRowRect so the layout remains allocation-
/// free even for very large decks.
pub const WorkspaceLayout = struct {
    sidebar: rl.Rectangle,
    organizer: rl.Rectangle,
    organizer_actions: [organizer_action_count]rl.Rectangle,
    slide_cards_clip: rl.Rectangle,
    slide_page_previous: rl.Rectangle,
    slide_page_next: rl.Rectangle,
    library: rl.Rectangle,
    library_rows_clip: rl.Rectangle,
    library_page_previous: rl.Rectangle,
    library_page_next: rl.Rectangle,
};

pub const SlidePreviewSlot = struct {
    /// Offset into Workspace.slides.
    summary_index: usize,
    /// Caller-defined slide index carried by that summary.
    slide_index: usize,
    rect: rl.Rectangle,
};

pub fn workspaceLayout(viewport: Viewport) WorkspaceLayout {
    const margin: f32 = 12;
    const gap: f32 = 8;
    const toolbar = uiLayout(viewport).toolbar;
    const status = statusPanel(viewport);
    const available_height = @max(0, status.y - gap - (toolbar.y + toolbar.height + gap));
    const sidebar_width = @min(@max(228, viewport.slide_size.x * 0.255), 304);
    const sidebar: rl.Rectangle = .{
        .x = viewport.slide_top_left.x + margin,
        .y = toolbar.y + toolbar.height + gap,
        .width = @min(sidebar_width, @max(120, viewport.slide_size.x - margin * 2)),
        .height = available_height,
    };
    const organizer_height = @min(@max(190, @floor(sidebar.height * 0.61)), @max(130, sidebar.height - 126));
    const organizer: rl.Rectangle = .{ .x = sidebar.x, .y = sidebar.y, .width = sidebar.width, .height = organizer_height };

    const action_gap: f32 = 4;
    const action_width = (organizer.width - 24 - action_gap * (organizer_action_count - 1)) / organizer_action_count;
    var organizer_actions: [organizer_action_count]rl.Rectangle = undefined;
    for (&organizer_actions, 0..) |*button, index| button.* = .{
        .x = organizer.x + 12 + @as(f32, @floatFromInt(index)) * (action_width + action_gap),
        .y = organizer.y + 34,
        .width = action_width,
        .height = 28,
    };
    const pager_width: f32 = 56;
    const pager_y = organizer.y + organizer.height - 29;
    const slide_page_previous: rl.Rectangle = .{
        .x = organizer.x + organizer.width - 12 - pager_width * 2 - action_gap,
        .y = pager_y,
        .width = pager_width,
        .height = 22,
    };
    const slide_page_next: rl.Rectangle = .{
        .x = slide_page_previous.x + pager_width + action_gap,
        .y = pager_y,
        .width = pager_width,
        .height = 22,
    };
    const slide_cards_clip: rl.Rectangle = .{
        .x = organizer.x + 8,
        .y = organizer.y + 70,
        .width = organizer.width - 16,
        .height = @max(0, pager_y - 5 - (organizer.y + 70)),
    };

    const library_y = organizer.y + organizer.height + gap;
    const library: rl.Rectangle = .{
        .x = sidebar.x,
        .y = library_y,
        .width = sidebar.width,
        .height = @max(92, sidebar.y + sidebar.height - library_y),
    };
    const library_pager_y = library.y + library.height - 29;
    const library_page_previous: rl.Rectangle = .{
        .x = library.x + library.width - 12 - pager_width * 2 - action_gap,
        .y = library_pager_y,
        .width = pager_width,
        .height = 22,
    };
    const library_page_next: rl.Rectangle = .{
        .x = library_page_previous.x + pager_width + action_gap,
        .y = library_pager_y,
        .width = pager_width,
        .height = 22,
    };
    const library_rows_clip: rl.Rectangle = .{
        .x = library.x + 8,
        .y = library.y + 36,
        .width = library.width - 16,
        .height = @max(0, library_pager_y - 5 - (library.y + 36)),
    };
    return .{
        .sidebar = sidebar,
        .organizer = organizer,
        .organizer_actions = organizer_actions,
        .slide_cards_clip = slide_cards_clip,
        .slide_page_previous = slide_page_previous,
        .slide_page_next = slide_page_next,
        .library = library,
        .library_rows_clip = library_rows_clip,
        .library_page_previous = library_page_previous,
        .library_page_next = library_page_next,
    };
}

pub fn slideCardCapacity(layout: WorkspaceLayout) usize {
    return rowsThatFit(layout.slide_cards_clip.height, slide_card_height, slide_card_gap);
}

pub fn libraryRowCapacity(layout: WorkspaceLayout) usize {
    return rowsThatFit(layout.library_rows_clip.height, library_row_height, library_row_gap);
}

pub fn slideCardRect(layout: WorkspaceLayout, visible_slot: usize) ?rl.Rectangle {
    if (visible_slot >= slideCardCapacity(layout)) return null;
    return .{
        .x = layout.slide_cards_clip.x,
        .y = layout.slide_cards_clip.y + @as(f32, @floatFromInt(visible_slot)) * (slide_card_height + slide_card_gap),
        .width = layout.slide_cards_clip.width,
        .height = slide_card_height,
    };
}

/// The 16:9 area reserved inside a slide card. Callers may render a true slide
/// thumbnail here between drawWorkspaceBackground and drawWorkspaceOverlay.
pub fn slidePreviewRect(card: rl.Rectangle) rl.Rectangle {
    const height = @min(card.height - 12, (card.width * 0.54) * 9 / 16);
    const width = height * 16 / 9;
    return .{ .x = card.x + 6, .y = card.y + (card.height - height) / 2, .width = width, .height = height };
}

pub fn libraryRowRect(layout: WorkspaceLayout, visible_slot: usize) ?rl.Rectangle {
    if (visible_slot >= libraryRowCapacity(layout)) return null;
    return .{
        .x = layout.library_rows_clip.x,
        .y = layout.library_rows_clip.y + @as(f32, @floatFromInt(visible_slot)) * (library_row_height + library_row_gap),
        .width = layout.library_rows_clip.width,
        .height = library_row_height,
    };
}

fn rowsThatFit(height: f32, row_height: f32, gap: f32) usize {
    if (height < row_height) return 0;
    return @intFromFloat(@floor((height + gap) / (row_height + gap)));
}

pub fn uiLayout(viewport: Viewport) UiLayout {
    const margin: f32 = 12;
    const gap: f32 = 6;
    const tool_size: f32 = 42;
    const new_slide_width: f32 = 74;
    const scene_width: f32 = 132;
    const toolbar_width = margin * 2 + tool_size * 6 + gap * 5 + gap + new_slide_width + gap + scene_width;
    const toolbar: rl.Rectangle = .{
        .x = viewport.slide_top_left.x + margin,
        .y = viewport.slide_top_left.y + margin,
        .width = toolbar_width,
        .height = tool_size + margin * 2,
    };
    var tool_buttons: [6]rl.Rectangle = undefined;
    for (&tool_buttons, 0..) |*button, index| button.* = .{
        .x = toolbar.x + margin + @as(f32, @floatFromInt(index)) * (tool_size + gap),
        .y = toolbar.y + margin,
        .width = tool_size,
        .height = tool_size,
    };
    const new_slide: rl.Rectangle = .{
        .x = tool_buttons[5].x + tool_buttons[5].width + gap,
        .y = toolbar.y + margin,
        .width = new_slide_width,
        .height = tool_size,
    };
    const scene_previous: rl.Rectangle = .{
        .x = new_slide.x + new_slide.width + gap,
        .y = new_slide.y,
        .width = 26,
        .height = tool_size,
    };
    const scene_label: rl.Rectangle = .{
        .x = scene_previous.x + scene_previous.width,
        .y = new_slide.y,
        .width = scene_width - 52,
        .height = tool_size,
    };
    const scene_next: rl.Rectangle = .{
        .x = scene_label.x + scene_label.width,
        .y = new_slide.y,
        .width = 26,
        .height = tool_size,
    };

    const property_width: f32 = 264;
    const properties: rl.Rectangle = .{
        .x = viewport.slide_top_left.x + viewport.slide_size.x - property_width - margin,
        .y = viewport.slide_top_left.y + margin,
        .width = property_width,
        .height = 224,
    };
    const action_y = properties.y + 38;
    const action_width: f32 = 72;
    const edit_text: rl.Rectangle = .{ .x = properties.x + 12, .y = action_y, .width = action_width, .height = 30 };
    const delete_item: rl.Rectangle = .{ .x = edit_text.x + action_width + gap, .y = action_y, .width = action_width, .height = 30 };
    const promote: rl.Rectangle = .{ .x = delete_item.x + action_width + gap, .y = action_y, .width = action_width, .height = 30 };

    var foreground_swatches: [palette.len]rl.Rectangle = undefined;
    var background_swatches: [palette.len]rl.Rectangle = undefined;
    const swatch_size: f32 = 24;
    for (&foreground_swatches, 0..) |*swatch, index| swatch.* = .{
        .x = properties.x + 12 + @as(f32, @floatFromInt(index)) * (swatch_size + gap),
        .y = properties.y + 105,
        .width = swatch_size,
        .height = swatch_size,
    };
    for (&background_swatches, 0..) |*swatch, index| swatch.* = .{
        .x = properties.x + 12 + @as(f32, @floatFromInt(index)) * (swatch_size + gap),
        .y = properties.y + 169,
        .width = swatch_size,
        .height = swatch_size,
    };
    return .{
        .toolbar = toolbar,
        .tool_buttons = tool_buttons,
        .new_slide = new_slide,
        .scene_previous = scene_previous,
        .scene_label = scene_label,
        .scene_next = scene_next,
        .properties = properties,
        .edit_text = edit_text,
        .delete_item = delete_item,
        .promote = promote,
        .foreground_swatches = foreground_swatches,
        .background_swatches = background_swatches,
    };
}

fn statusPanel(viewport: Viewport) rl.Rectangle {
    const panel_height: f32 = 103;
    return .{
        .x = viewport.slide_top_left.x + 12,
        .y = viewport.slide_top_left.y + viewport.slide_size.y - panel_height - 12,
        .width = @max(340, @min(900, viewport.slide_size.x - 24)),
        .height = panel_height,
    };
}

/// A testable input snapshot. `updateFromRaylib` is the convenient runtime
/// adapter; tests and other frontends can call `update` directly.
pub const FrameInput = struct {
    toggle_pressed: bool = false,
    cancel_pressed: bool = false,
    pointer_screen: rl.Vector2 = .{ .x = 0, .y = 0 },
    pointer_pressed: bool = false,
    pointer_down: bool = false,
    pointer_released: bool = false,
    nudge: rl.Vector2 = .{ .x = 0, .y = 0 },
    allow_shared_edit: bool = false,
    choose_tool: ?Tool = null,
    delete_pressed: bool = false,
    edit_text_pressed: bool = false,
    promote_pressed: bool = false,
    foreground_color: ?PaletteColor = null,
    background_color: ?PaletteColor = null,
    new_slide_pressed: bool = false,
    /// Negative selects the previous base/morph scene, positive the next.
    cycle_morph_scene: i8 = 0,
    /// Negative selects the previous slide, positive the next slide.
    select_slide_delta: i8 = 0,
    duplicate_slide_pressed: bool = false,
    delete_slide_pressed: bool = false,
    /// Negative moves the current slide up, positive moves it down.
    move_slide: i8 = 0,
    /// Positive/negative wheel delta; routed to the panel under the pointer.
    workspace_scroll: f32 = 0,

    pub fn fromRaylib() FrameInput {
        const shift = rl.isKeyDown(.left_shift) or rl.isKeyDown(.right_shift);
        const shortcut_modifier = rl.isKeyDown(.left_control) or rl.isKeyDown(.right_control) or
            rl.isKeyDown(.left_super) or rl.isKeyDown(.right_super);
        const alt = rl.isKeyDown(.left_alt) or rl.isKeyDown(.right_alt);
        const moving_slide = alt and shift;
        const amount: f32 = if (shift) 10 else 1;
        var nudge: rl.Vector2 = .{ .x = 0, .y = 0 };
        if (!moving_slide) {
            if (keyPressedOrRepeated(.left)) nudge.x -= amount;
            if (keyPressedOrRepeated(.right)) nudge.x += amount;
            if (keyPressedOrRepeated(.up)) nudge.y -= amount;
            if (keyPressedOrRepeated(.down)) nudge.y += amount;
        }
        const choose_tool: ?Tool = if (rl.isKeyPressed(.v))
            .select
        else if (rl.isKeyPressed(.t))
            .add_text
        else if (rl.isKeyPressed(.b))
            .add_bullets
        else if (rl.isKeyPressed(.i))
            .add_image
        else if (rl.isKeyPressed(.r))
            .add_shape
        else if (rl.isKeyPressed(.u))
            .add_reusable
        else
            null;
        return .{
            .toggle_pressed = rl.isKeyPressed(.e),
            .cancel_pressed = rl.isKeyPressed(.escape),
            .pointer_screen = rl.getMousePosition(),
            .pointer_pressed = rl.isMouseButtonPressed(.left),
            .pointer_down = rl.isMouseButtonDown(.left),
            .pointer_released = rl.isMouseButtonReleased(.left),
            .nudge = nudge,
            .allow_shared_edit = alt,
            .choose_tool = choose_tool,
            .delete_pressed = !shortcut_modifier and rl.isKeyPressed(.backspace),
            .edit_text_pressed = rl.isKeyPressed(.enter),
            .promote_pressed = rl.isKeyPressed(.p),
            .new_slide_pressed = shortcut_modifier and rl.isKeyPressed(.n),
            .cycle_morph_scene = if (rl.isKeyPressed(.left_bracket))
                -1
            else if (rl.isKeyPressed(.right_bracket))
                1
            else
                0,
            .select_slide_delta = if (rl.isKeyPressed(.page_up))
                -1
            else if (rl.isKeyPressed(.page_down))
                1
            else
                0,
            .duplicate_slide_pressed = shortcut_modifier and rl.isKeyPressed(.d),
            .delete_slide_pressed = shortcut_modifier and rl.isKeyPressed(.backspace),
            .move_slide = if (moving_slide and rl.isKeyPressed(.up))
                -1
            else if (moving_slide and rl.isKeyPressed(.down))
                1
            else
                0,
            .workspace_scroll = rl.getMouseWheelMove(),
        };
    }
};

fn keyPressedOrRepeated(key: rl.KeyboardKey) bool {
    return rl.isKeyPressed(key) or rl.isKeyPressedRepeat(key);
}

const Drag = struct {
    pointer_start: rl.Vector2 = .{ .x = 0, .y = 0 },
    before: Geometry = .{
        .position = .{ .x = 0, .y = 0 },
        .size = .{ .x = 0, .y = 0 },
    },
    authored_before: Geometry = .{
        .position = .{ .x = 0, .y = 0 },
        .size = .{ .x = 0, .y = 0 },
    },
};

pub const Studio = struct {
    enabled: bool = false,
    tool: Tool = .select,
    active_morph_state: ?usize = null,
    morph_state_count: usize = 0,
    dirty: bool = false,
    copy_is_current: bool = false,
    notice: Notice = .none,
    selected_identity: ?usize = null,
    /// Source key keeps selection stable when applying a command reparses the
    /// deck and assigns fresh in-memory identities.
    selected_source: ?slides.SourceRef = null,
    interaction: Interaction = .idle,
    handle_size_screen: f32 = default_handle_size,
    min_item_size: f32 = default_min_item_size,
    drag: Drag = .{},
    preview: Geometry = .{
        .position = .{ .x = 0, .y = 0 },
        .size = .{ .x = 0, .y = 0 },
    },
    pending_semantic_command: ?SemanticCommand = null,
    organizer_first_visible: usize = 0,
    library_first_visible: usize = 0,
    selected_library_index: ?usize = null,
    last_workspace_slide: ?usize = null,

    pub fn capturesInput(self: Studio) bool {
        return self.enabled;
    }

    pub fn status(self: Studio) Status {
        if (!self.enabled) return .inactive;
        return switch (self.interaction) {
            .moving => .moving,
            .resizing => .resizing,
            .idle => if (self.selected_identity != null) .selected else .ready,
        };
    }

    pub fn markSaved(self: *Studio) void {
        self.dirty = false;
        self.copy_is_current = false;
    }

    pub fn markCopySaved(self: *Studio) void {
        self.copy_is_current = true;
        self.notice = .copy_saved;
    }

    pub fn markSourceChanged(self: *Studio) void {
        self.copy_is_current = false;
        // Library commands retain only a workspace index. Any source rewrite
        // can reorder the catalog, so a prior selection must not silently
        // resolve to a different reusable afterward.
        self.selected_library_index = null;
    }

    pub fn setNotice(self: *Studio, notice: Notice) void {
        self.notice = notice;
    }

    pub fn interactionActive(self: Studio) bool {
        return self.interaction != .idle;
    }

    /// Returns and clears the most recent non-geometry UI intention.
    pub fn takeSemanticCommand(self: *Studio) ?SemanticCommand {
        const command = self.pending_semantic_command;
        self.pending_semantic_command = null;
        return command;
    }

    pub fn peekSemanticCommand(self: Studio) ?SemanticCommand {
        return self.pending_semantic_command;
    }

    pub fn setTool(self: *Studio, tool: Tool, items: []slides.SlideItem) void {
        if (self.interaction != .idle) self.cancelInteraction(items);
        self.tool = tool;
        self.notice = .none;
    }

    pub fn setMorphStateCount(self: *Studio, count: usize) void {
        self.morph_state_count = count;
        if (self.active_morph_state) |state| {
            if (state >= count) self.active_morph_state = null;
        }
    }

    pub fn setActiveMorphState(self: *Studio, items: []slides.SlideItem, state: ?usize) void {
        const normalized = if (state) |index|
            if (index < self.morph_state_count) index else null
        else
            null;
        if (self.active_morph_state == normalized) return;
        self.clearSelection(items);
        self.active_morph_state = normalized;
        self.selected_library_index = null;
        self.tool = .select;
    }

    /// Cycles base -> state 1 ... state N -> base and emits the scene choice
    /// for the integration layer to switch both item slice and renderer state.
    pub fn cycleMorphState(self: *Studio, items: []slides.SlideItem, delta: i8) void {
        if (delta == 0 or self.morph_state_count == 0) return;
        const scene_count: isize = @intCast(self.morph_state_count + 1);
        const current: isize = if (self.active_morph_state) |state| @intCast(state + 1) else 0;
        const movement: isize = @intCast(delta);
        const next_scene = @mod(current + movement, scene_count);
        const next_state: ?usize = if (next_scene == 0) null else @intCast(next_scene - 1);
        self.clearSelection(items);
        self.active_morph_state = next_state;
        self.selected_library_index = null;
        self.tool = .select;
        self.pending_semantic_command = .{ .select_morph_scene = .{ .active_state = next_state } };
    }

    pub fn cancelActiveInteraction(self: *Studio, items: []slides.SlideItem) void {
        if (self.interaction != .idle) self.cancelInteraction(items);
    }

    pub fn toggle(self: *Studio, items: []slides.SlideItem) void {
        if (self.enabled and self.interaction != .idle) self.cancelInteraction(items);
        self.enabled = !self.enabled;
        if (!self.enabled) {
            self.tool = .select;
            self.active_morph_state = null;
            self.selected_identity = null;
            self.selected_source = null;
            self.selected_library_index = null;
        }
    }

    pub fn disable(self: *Studio, items: []slides.SlideItem) void {
        if (self.interaction != .idle) self.cancelInteraction(items);
        self.enabled = false;
        self.tool = .select;
        self.active_morph_state = null;
        self.selected_identity = null;
        self.selected_source = null;
        self.selected_library_index = null;
    }

    pub fn clearSelection(self: *Studio, items: []slides.SlideItem) void {
        if (self.interaction != .idle) self.cancelInteraction(items);
        self.selected_identity = null;
        self.selected_source = null;
    }

    pub fn selectedIndex(self: Studio, items: []const slides.SlideItem) ?usize {
        const identity = self.selected_identity orelse return null;
        return itemIndexByIdentity(items, identity);
    }

    pub fn selectedGeometry(self: Studio, items: []const slides.SlideItem, resolved_bounds: []const ResolvedBounds) ?Geometry {
        const index = self.selectedIndex(items) orelse return null;
        if (self.interaction != .idle) return self.preview;
        return itemGeometry(items[index], resolved_bounds);
    }

    pub fn livePreview(self: Studio) ?LivePreview {
        if (!self.enabled or self.interaction == .idle) return null;
        return .{
            .item_identity = self.selected_identity orelse return null,
            .before = self.drag.before,
            .after = self.preview,
            .resized = self.interaction == .resizing,
        };
    }

    pub fn resizeHandleRect(self: Studio, viewport: Viewport, geometry: Geometry) ?rl.Rectangle {
        const rect = geometryToScreenRect(viewport, geometry) orelse return null;
        const half = self.handle_size_screen / 2;
        return .{
            .x = rect.x + rect.width - half,
            .y = rect.y + rect.height - half,
            .width = self.handle_size_screen,
            .height = self.handle_size_screen,
        };
    }

    /// Updates Studio and mutates item geometry for immediate preview. A
    /// non-null return value represents one completed, undoable edit.
    pub fn update(
        self: *Studio,
        items: []slides.SlideItem,
        resolved_bounds: []const ResolvedBounds,
        viewport: Viewport,
        input: FrameInput,
    ) ?GeometryCommand {
        return self.updateWithWorkspace(items, resolved_bounds, viewport, .{}, input);
    }

    /// Extended update path for the organizer and reusable library. Workspace
    /// slices are borrowed only for this call; Studio retains indexes, never
    /// caller-owned strings or slice pointers.
    pub fn updateWithWorkspace(
        self: *Studio,
        items: []slides.SlideItem,
        resolved_bounds: []const ResolvedBounds,
        viewport: Viewport,
        workspace: Workspace,
        input: FrameInput,
    ) ?GeometryCommand {
        if (input.pointer_pressed or input.nudge.x != 0 or input.nudge.y != 0) self.notice = .none;
        if (input.toggle_pressed) {
            self.toggle(items);
            return null;
        }
        if (!self.enabled) return null;

        self.validateSelection(items, resolved_bounds);

        if (workspace.visible) {
            self.normalizeWorkspace(viewport, workspace);
            if (self.handleWorkspaceKeyboard(items, workspace, input)) return null;
            self.handleWorkspaceScroll(viewport, workspace, input);
        }

        if (input.choose_tool) |tool| self.setTool(tool, items);

        if (input.cycle_morph_scene != 0) {
            self.cycleMorphState(items, input.cycle_morph_scene);
            return null;
        }

        if (input.new_slide_pressed) {
            self.clearSelection(items);
            self.tool = .select;
            self.pending_semantic_command = .{ .new_slide = {} };
            return null;
        }

        if (input.cancel_pressed) {
            if (self.interaction != .idle) {
                self.cancelInteraction(items);
            } else if (self.tool != .select) {
                self.tool = .select;
            } else {
                self.disable(items);
            }
            return null;
        }

        if (input.delete_pressed) {
            _ = self.emitSelectedCommand(items, input.allow_shared_edit, .delete_item);
            return null;
        }
        if (input.edit_text_pressed) {
            _ = self.emitSelectedCommand(items, input.allow_shared_edit, .edit_text);
            return null;
        }
        if (input.promote_pressed) {
            _ = self.emitSelectedCommand(items, input.allow_shared_edit, .promote_to_reusable);
            return null;
        }
        if (input.foreground_color) |color| {
            _ = self.emitColorCommand(items, input.allow_shared_edit, color, false);
            return null;
        }
        if (input.background_color) |color| {
            _ = self.emitColorCommand(items, input.allow_shared_edit, color, true);
            return null;
        }

        if (input.pointer_pressed and workspace.visible and
            self.handleWorkspaceClick(items, viewport, workspace, input.pointer_screen)) return null;
        if (input.pointer_pressed and self.handleUiClick(items, viewport, input.pointer_screen, input.allow_shared_edit)) return null;

        const pointer_logical = screenToLogical(viewport, input.pointer_screen);

        if (input.pointer_pressed and self.interaction == .idle and self.tool != .select) {
            if (viewport.containsScreenPoint(input.pointer_screen)) {
                if (pointer_logical) |pointer| self.emitAddCommand(pointer, workspace);
            }
            return null;
        }

        if (input.pointer_pressed and self.interaction == .idle) {
            if (self.selectedGeometry(items, resolved_bounds)) |selected_geometry| {
                if (self.resizeHandleRect(viewport, selected_geometry)) |handle| {
                    if (pointInRectangle(input.pointer_screen, handle)) {
                        const selected_index = self.selectedIndex(items) orelse return null;
                        if (!self.canEditItem(items[selected_index], input.allow_shared_edit)) return null;
                        self.beginInteraction(
                            .resizing,
                            selected_geometry,
                            Geometry.fromItem(items[selected_index]),
                            pointer_logical orelse return null,
                        );
                    } else {
                        self.selectAndBeginMove(items, resolved_bounds, viewport, input.pointer_screen, pointer_logical, input.allow_shared_edit);
                    }
                } else {
                    self.selectAndBeginMove(items, resolved_bounds, viewport, input.pointer_screen, pointer_logical, input.allow_shared_edit);
                }
            } else {
                self.selectAndBeginMove(items, resolved_bounds, viewport, input.pointer_screen, pointer_logical, input.allow_shared_edit);
            }
        }

        if (self.interaction != .idle and (input.pointer_down or input.pointer_released)) {
            if (pointer_logical) |pointer| self.applyPointer(items, pointer);
        }

        if (self.interaction != .idle and input.pointer_released) {
            return self.finishInteraction(items);
        }

        if (self.interaction == .idle and (input.nudge.x != 0 or input.nudge.y != 0)) {
            const selected_index = self.selectedIndex(items) orelse return null;
            if (!self.canEditItem(items[selected_index], input.allow_shared_edit)) return null;
            return self.applyNudge(items, resolved_bounds, input.nudge);
        }

        return null;
    }

    fn selectedTarget(self: Studio, items: []const slides.SlideItem) ?CommandTarget {
        const index = self.selectedIndex(items) orelse return null;
        return .{ .item_identity = items[index].identity, .source = items[index].source };
    }

    const TargetCommandKind = enum { delete_item, edit_text, promote_to_reusable };

    fn emitSelectedCommand(
        self: *Studio,
        items: []slides.SlideItem,
        allow_shared_edit: bool,
        kind: TargetCommandKind,
    ) bool {
        const index = self.selectedIndex(items) orelse return false;
        if (self.interaction != .idle) self.cancelInteraction(items);
        if (!self.canEditItem(items[index], allow_shared_edit)) return true;
        if (kind == .edit_text and items[index].kind != .textbox and items[index].kind != .crowd) {
            self.notice = .property_unavailable;
            return true;
        }
        if (kind == .promote_to_reusable and self.active_morph_state != null) {
            self.notice = .base_scene_only;
            return true;
        }
        if (kind == .promote_to_reusable and
            (items[index].source.scope != .direct or
                items[index].kind == .crowd or
                items[index].kind == .background))
        {
            self.notice = .property_unavailable;
            return true;
        }
        const target = self.selectedTarget(items) orelse return true;
        self.pending_semantic_command = switch (kind) {
            .delete_item => .{ .delete_item = target },
            .edit_text => .{ .edit_text = target },
            .promote_to_reusable => .{ .promote_to_reusable = target },
        };
        return true;
    }

    fn emitColorCommand(
        self: *Studio,
        items: []slides.SlideItem,
        allow_shared_edit: bool,
        color: PaletteColor,
        background: bool,
    ) bool {
        const index = self.selectedIndex(items) orelse return false;
        if (self.interaction != .idle) self.cancelInteraction(items);
        if (!self.canEditItem(items[index], allow_shared_edit)) return true;
        if (!background and items[index].kind != .textbox) {
            self.notice = .property_unavailable;
            return true;
        }
        if (background and self.active_morph_state != null) {
            self.notice = .base_scene_only;
            return true;
        }
        const command: ColorCommand = .{
            .target = self.selectedTarget(items) orelse return true,
            .color = color,
        };
        self.pending_semantic_command = if (background)
            .{ .set_background = command }
        else
            .{ .set_foreground = command };
        return true;
    }

    fn emitAddCommand(self: *Studio, pointer: rl.Vector2, workspace: Workspace) void {
        if (self.tool == .add_reusable) {
            const selected_entry = if (self.selected_library_index) |index|
                if (index < workspace.library.len and workspace.library[index].available and
                    workspace.library[index].kind == .element) index else null
            else
                null;
            self.pending_semantic_command = .{ .add_reusable = .{
                .position = roundVector(pointer),
                .suggested_size = .{ .x = 600, .y = 200 },
                .library_entry_index = selected_entry,
            } };
            self.tool = .select;
            return;
        }
        const kind: NewItemKind = switch (self.tool) {
            .select => return,
            .add_text => .text,
            .add_bullets => .bullets,
            .add_image => .image,
            .add_shape => .shape,
            .add_reusable => unreachable,
        };
        self.pending_semantic_command = .{ .add_item = .{
            .kind = kind,
            .position = roundVector(pointer),
            .suggested_size = switch (kind) {
                .text => .{ .x = 600, .y = 120 },
                .bullets => .{ .x = 720, .y = 320 },
                .image => .{ .x = 640, .y = 360 },
                .shape => .{ .x = 480, .y = 270 },
            },
            .suggested_color = if (kind == .shape) .blue else null,
        } };
        self.tool = .select;
    }

    pub fn visibleSlidePreview(
        self: Studio,
        viewport: Viewport,
        workspace: Workspace,
        visible_slot: usize,
    ) ?SlidePreviewSlot {
        if (!workspace.visible) return null;
        const layout = workspaceLayout(viewport);
        if (layout.sidebar.height < workspace_min_height) return null;
        const card = slideCardRect(layout, visible_slot) orelse return null;
        const summary_index = self.organizer_first_visible + visible_slot;
        if (summary_index >= workspace.slides.len) return null;
        return .{
            .summary_index = summary_index,
            .slide_index = workspace.slides[summary_index].index,
            .rect = slidePreviewRect(card),
        };
    }

    pub fn visibleLibraryIndex(
        self: Studio,
        viewport: Viewport,
        workspace: Workspace,
        visible_slot: usize,
    ) ?usize {
        const layout = workspaceLayout(viewport);
        if (!workspace.visible or layout.sidebar.height < workspace_min_height or libraryRowRect(layout, visible_slot) == null) return null;
        const index = self.library_first_visible + visible_slot;
        return if (index < workspace.library.len) index else null;
    }

    fn normalizeWorkspace(self: *Studio, viewport: Viewport, workspace: Workspace) void {
        const layout = workspaceLayout(viewport);
        const slide_capacity = slideCardCapacity(layout);
        self.organizer_first_visible = clampFirstVisible(
            self.organizer_first_visible,
            workspace.slides.len,
            slide_capacity,
        );
        if (self.last_workspace_slide == null or self.last_workspace_slide.? != workspace.current_slide) {
            if (summaryOffsetForSlide(workspace.slides, workspace.current_slide)) |offset| {
                self.organizer_first_visible = revealIndex(
                    self.organizer_first_visible,
                    offset,
                    workspace.slides.len,
                    slide_capacity,
                );
            }
            self.last_workspace_slide = workspace.current_slide;
            self.selected_library_index = null;
            self.tool = .select;
        }

        const library_capacity = libraryRowCapacity(layout);
        self.library_first_visible = clampFirstVisible(
            self.library_first_visible,
            workspace.library.len,
            library_capacity,
        );
        if (self.selected_library_index) |index| {
            if (index >= workspace.library.len or workspace.library[index].kind != .element or
                !workspace.library[index].available)
            {
                self.selected_library_index = null;
            }
        }
    }

    fn handleWorkspaceKeyboard(self: *Studio, items: []slides.SlideItem, workspace: Workspace, input: FrameInput) bool {
        if (input.select_slide_delta != 0) {
            const current = summaryOffsetForSlide(workspace.slides, workspace.current_slide) orelse return true;
            const movement: isize = if (input.select_slide_delta < 0) -1 else 1;
            const desired: isize = @as(isize, @intCast(current)) + movement;
            if (desired >= 0 and desired < @as(isize, @intCast(workspace.slides.len))) {
                self.emitSlideSelection(items, workspace.slides[@intCast(desired)].index);
            }
            return true;
        }
        if (input.duplicate_slide_pressed) {
            if (summaryOffsetForSlide(workspace.slides, workspace.current_slide) != null) {
                self.prepareDeckCommand(items);
                self.pending_semantic_command = .{ .duplicate_slide = workspace.current_slide };
            }
            return true;
        }
        if (input.delete_slide_pressed) {
            if (workspace.slides.len <= 1) {
                self.notice = .property_unavailable;
            } else if (summaryOffsetForSlide(workspace.slides, workspace.current_slide) != null) {
                self.prepareDeckCommand(items);
                self.pending_semantic_command = .{ .delete_slide = workspace.current_slide };
            }
            return true;
        }
        if (input.move_slide != 0) {
            const offset = summaryOffsetForSlide(workspace.slides, workspace.current_slide) orelse return true;
            const direction: SlideMoveDirection = if (input.move_slide < 0) .up else .down;
            if ((direction == .up and offset > 0) or (direction == .down and offset + 1 < workspace.slides.len)) {
                self.prepareDeckCommand(items);
                self.pending_semantic_command = .{ .move_slide = .{
                    .slide_index = workspace.current_slide,
                    .direction = direction,
                } };
            }
            return true;
        }
        return false;
    }

    fn handleWorkspaceScroll(self: *Studio, viewport: Viewport, workspace: Workspace, input: FrameInput) void {
        if (input.workspace_scroll == 0) return;
        const layout = workspaceLayout(viewport);
        if (layout.sidebar.height < workspace_min_height) return;
        if (pointInRectangle(input.pointer_screen, layout.organizer)) {
            self.organizer_first_visible = scrollFirstVisible(
                self.organizer_first_visible,
                workspace.slides.len,
                slideCardCapacity(layout),
                if (input.workspace_scroll > 0) -1 else 1,
            );
        } else if (pointInRectangle(input.pointer_screen, layout.library)) {
            self.library_first_visible = scrollFirstVisible(
                self.library_first_visible,
                workspace.library.len,
                libraryRowCapacity(layout),
                if (input.workspace_scroll > 0) -1 else 1,
            );
        }
    }

    fn handleWorkspaceClick(
        self: *Studio,
        items: []slides.SlideItem,
        viewport: Viewport,
        workspace: Workspace,
        pointer: rl.Vector2,
    ) bool {
        const layout = workspaceLayout(viewport);
        if (layout.sidebar.height < workspace_min_height) return false;
        const in_organizer = pointInRectangle(pointer, layout.organizer);
        const in_library = pointInRectangle(pointer, layout.library);
        if (!in_organizer and !in_library) return false;
        if (self.interaction != .idle) self.cancelInteraction(items);

        if (in_organizer) {
            for (layout.organizer_actions, 0..) |button, action| {
                if (!pointInRectangle(pointer, button)) continue;
                switch (action) {
                    0 => {
                        self.prepareDeckCommand(items);
                        self.pending_semantic_command = .{ .new_slide = {} };
                    },
                    1 => if (workspace.slides.len > 0) {
                        self.prepareDeckCommand(items);
                        self.pending_semantic_command = .{ .duplicate_slide = workspace.current_slide };
                    },
                    2 => if (workspace.slides.len > 1) {
                        self.prepareDeckCommand(items);
                        self.pending_semantic_command = .{ .delete_slide = workspace.current_slide };
                    } else {
                        self.notice = .property_unavailable;
                    },
                    3, 4 => if (summaryOffsetForSlide(workspace.slides, workspace.current_slide)) |offset| {
                        const direction: SlideMoveDirection = if (action == 3) .up else .down;
                        if ((direction == .up and offset > 0) or (direction == .down and offset + 1 < workspace.slides.len)) {
                            self.prepareDeckCommand(items);
                            self.pending_semantic_command = .{ .move_slide = .{
                                .slide_index = workspace.current_slide,
                                .direction = direction,
                            } };
                        }
                    },
                    else => unreachable,
                }
                return true;
            }
            if (pointInRectangle(pointer, layout.slide_page_previous)) {
                self.organizer_first_visible = pageFirstVisible(
                    self.organizer_first_visible,
                    workspace.slides.len,
                    slideCardCapacity(layout),
                    false,
                );
                return true;
            }
            if (pointInRectangle(pointer, layout.slide_page_next)) {
                self.organizer_first_visible = pageFirstVisible(
                    self.organizer_first_visible,
                    workspace.slides.len,
                    slideCardCapacity(layout),
                    true,
                );
                return true;
            }
            for (0..slideCardCapacity(layout)) |visible_slot| {
                const card = slideCardRect(layout, visible_slot) orelse continue;
                if (!pointInRectangle(pointer, card)) continue;
                const summary_index = self.organizer_first_visible + visible_slot;
                if (summary_index < workspace.slides.len) {
                    self.emitSlideSelection(items, workspace.slides[summary_index].index);
                }
                return true;
            }
            return true;
        }

        if (pointInRectangle(pointer, layout.library_page_previous)) {
            self.library_first_visible = pageFirstVisible(
                self.library_first_visible,
                workspace.library.len,
                libraryRowCapacity(layout),
                false,
            );
            return true;
        }
        if (pointInRectangle(pointer, layout.library_page_next)) {
            self.library_first_visible = pageFirstVisible(
                self.library_first_visible,
                workspace.library.len,
                libraryRowCapacity(layout),
                true,
            );
            return true;
        }
        for (0..libraryRowCapacity(layout)) |visible_slot| {
            const row = libraryRowRect(layout, visible_slot) orelse continue;
            if (!pointInRectangle(pointer, row)) continue;
            const entry_index = self.library_first_visible + visible_slot;
            if (entry_index >= workspace.library.len) return true;
            const entry = workspace.library[entry_index];
            if (!entry.available) {
                self.notice = .property_unavailable;
                return true;
            }
            switch (entry.kind) {
                .element => {
                    self.selected_library_index = entry_index;
                    self.setTool(.add_reusable, items);
                },
                .slide_template => {
                    self.prepareDeckCommand(items);
                    self.pending_semantic_command = .{ .new_slide_from_template = entry_index };
                },
            }
            return true;
        }
        // Empty sidebar space is an input shield, never a canvas click.
        return true;
    }

    fn emitSlideSelection(self: *Studio, items: []slides.SlideItem, slide_index: usize) void {
        self.prepareDeckCommand(items);
        self.pending_semantic_command = .{ .select_slide = slide_index };
    }

    fn prepareDeckCommand(self: *Studio, items: []slides.SlideItem) void {
        self.clearSelection(items);
        self.tool = .select;
        self.active_morph_state = null;
        self.notice = .none;
    }

    fn handleUiClick(
        self: *Studio,
        items: []slides.SlideItem,
        viewport: Viewport,
        pointer: rl.Vector2,
        allow_shared_edit: bool,
    ) bool {
        const layout = uiLayout(viewport);
        const in_status = pointInRectangle(pointer, statusPanel(viewport));
        const in_toolbar = pointInRectangle(pointer, layout.toolbar);
        const in_properties = self.selected_identity != null and pointInRectangle(pointer, layout.properties);
        if (!in_status and !in_toolbar and !in_properties) return false;
        if (self.interaction != .idle) self.cancelInteraction(items);
        if (in_status) return true;
        if (in_toolbar) {
            for (layout.tool_buttons, 0..) |button, index| {
                if (pointInRectangle(pointer, button)) {
                    self.setTool(@enumFromInt(index), items);
                    break;
                }
            }
            if (pointInRectangle(pointer, layout.new_slide)) {
                self.clearSelection(items);
                self.tool = .select;
                self.pending_semantic_command = .{ .new_slide = {} };
            }
            if (pointInRectangle(pointer, layout.scene_previous)) self.cycleMorphState(items, -1);
            if (pointInRectangle(pointer, layout.scene_label) or pointInRectangle(pointer, layout.scene_next)) {
                self.cycleMorphState(items, 1);
            }
            return true;
        }
        if (pointInRectangle(pointer, layout.edit_text))
            return self.emitSelectedCommand(items, allow_shared_edit, .edit_text);
        if (pointInRectangle(pointer, layout.delete_item))
            return self.emitSelectedCommand(items, allow_shared_edit, .delete_item);
        if (pointInRectangle(pointer, layout.promote))
            return self.emitSelectedCommand(items, allow_shared_edit, .promote_to_reusable);
        for (layout.foreground_swatches, 0..) |swatch, index| {
            if (pointInRectangle(pointer, swatch))
                return self.emitColorCommand(items, allow_shared_edit, palette[index], false);
        }
        for (layout.background_swatches, 0..) |swatch, index| {
            if (pointInRectangle(pointer, swatch))
                return self.emitColorCommand(items, allow_shared_edit, palette[index], true);
        }
        // Clicking empty property-panel space must never reach the canvas.
        return true;
    }

    /// Runtime adapter. Call before ordinary presentation input and skip that
    /// input while `capturesInput()` is true.
    pub fn updateFromRaylib(
        self: *Studio,
        items: []slides.SlideItem,
        resolved_bounds: []const ResolvedBounds,
        viewport: Viewport,
    ) ?GeometryCommand {
        return self.update(items, resolved_bounds, viewport, FrameInput.fromRaylib());
    }

    pub fn updateWithWorkspaceFromRaylib(
        self: *Studio,
        items: []slides.SlideItem,
        resolved_bounds: []const ResolvedBounds,
        viewport: Viewport,
        workspace: Workspace,
    ) ?GeometryCommand {
        return self.updateWithWorkspace(items, resolved_bounds, viewport, workspace, FrameInput.fromRaylib());
    }

    fn validateSelection(self: *Studio, items: []slides.SlideItem, resolved_bounds: []const ResolvedBounds) void {
        if (self.selected_identity) |identity| {
            var index = itemIndexByIdentity(items, identity);
            if (self.selected_source) |source| {
                if (itemIndexBySource(items, source)) |rebound| {
                    index = rebound;
                    self.selected_identity = items[rebound].identity;
                } else if (index) |same_identity| {
                    // A preceding source patch may shift this directive's byte
                    // offset while logical identities remain stable.
                    self.selected_source = if (items[same_identity].source.scope == .none)
                        null
                    else
                        items[same_identity].source;
                }
            }
            const selected_index = index orelse {
                self.interaction = .idle;
                self.selected_identity = null;
                self.selected_source = null;
                return;
            };
            if (!isSelectable(items[selected_index], resolved_bounds)) {
                if (self.interaction != .idle) self.restoreBefore(&items[selected_index]);
                self.interaction = .idle;
                self.selected_identity = null;
                self.selected_source = null;
            }
        }
    }

    fn selectAndBeginMove(
        self: *Studio,
        items: []slides.SlideItem,
        resolved_bounds: []const ResolvedBounds,
        viewport: Viewport,
        pointer_screen: rl.Vector2,
        pointer_logical: ?rl.Vector2,
        allow_shared_edit: bool,
    ) void {
        if (!viewport.containsScreenPoint(pointer_screen)) {
            self.selected_identity = null;
            self.selected_source = null;
            return;
        }
        const pointer = pointer_logical orelse {
            self.selected_identity = null;
            self.selected_source = null;
            return;
        };
        const hit_index = hitTest(items, resolved_bounds, pointer) orelse {
            self.selected_identity = null;
            self.selected_source = null;
            return;
        };
        self.selected_identity = items[hit_index].identity;
        self.selected_source = if (items[hit_index].source.scope == .none) null else items[hit_index].source;
        if (!self.canEditItem(items[hit_index], allow_shared_edit)) return;
        self.beginInteraction(
            .moving,
            itemGeometry(items[hit_index], resolved_bounds),
            Geometry.fromItem(items[hit_index]),
            pointer,
        );
    }

    fn canEditItem(self: *Studio, item: slides.SlideItem, allow_shared_edit: bool) bool {
        if (!self.itemEditableInScene(item)) {
            self.notice = .generated_source_read_only;
            return false;
        }
        if (self.active_morph_state != null) return true;
        if (item.source.scope == .slide_template and !allow_shared_edit) {
            self.notice = .shared_template_locked;
            return false;
        }
        return true;
    }

    fn itemEditableInScene(self: Studio, item: slides.SlideItem) bool {
        if (self.active_morph_state) |state_index| {
            if (item.state_source_state != null and item.state_source_state.? == state_index) {
                return item.state_source != null and item.state_source.?.patchable;
            }
            // A creation directive can be patched directly only in the state
            // that actually owns it. Later cumulative snapshots need an ID so
            // the integration layer can append a local @set/@hide override.
            if (item.creation_morph_state != null and item.creation_morph_state.? == state_index) {
                return item.source.patchable;
            }
            // Inherited objects with IDs get a new local @set, so their base
            // or shared-template directive need not itself be writable.
            return item.id != null;
        }
        return item.source.scope != .none and item.source.patchable;
    }

    fn beginInteraction(
        self: *Studio,
        interaction: Interaction,
        geometry: Geometry,
        authored_geometry: Geometry,
        pointer: rl.Vector2,
    ) void {
        self.interaction = interaction;
        self.drag = .{
            .pointer_start = pointer,
            .before = geometry,
            .authored_before = authored_geometry,
        };
        self.preview = geometry;
    }

    fn applyPointer(self: *Studio, items: []slides.SlideItem, pointer: rl.Vector2) void {
        const index = self.selectedIndex(items) orelse return;
        const delta = subtract(pointer, self.drag.pointer_start);
        var geometry = self.drag.before;
        switch (self.interaction) {
            .idle => return,
            .moving => geometry.position = roundVector(add(self.drag.before.position, delta)),
            .resizing => {
                geometry.size = roundVector(.{
                    .x = @max(self.min_item_size, self.drag.before.size.x + delta.x),
                    .y = @max(self.min_item_size, self.drag.before.size.y + delta.y),
                });
            },
        }
        self.preview = geometry;
        items[index].position = geometry.position;
        if (self.interaction == .resizing) items[index].size = geometry.size;
    }

    fn finishInteraction(self: *Studio, items: []slides.SlideItem) ?GeometryCommand {
        const interaction = self.interaction;
        self.interaction = .idle;
        const identity = self.selected_identity orelse return null;
        const index = itemIndexByIdentity(items, identity) orelse return null;
        const after = self.preview;
        if (geometryEqual(self.drag.before, after)) return null;
        self.dirty = true;
        self.copy_is_current = false;
        return .{
            .item_identity = identity,
            .source = items[index].source,
            .before_position = self.drag.before.position,
            .before_size = self.drag.before.size,
            .after_position = after.position,
            .after_size = after.size,
            .resized = interaction == .resizing,
        };
    }

    fn cancelInteraction(self: *Studio, items: []slides.SlideItem) void {
        if (self.selectedIndex(items)) |index| self.restoreBefore(&items[index]);
        self.interaction = .idle;
    }

    fn restoreBefore(self: Studio, item: *slides.SlideItem) void {
        item.position = self.drag.authored_before.position;
        if (self.interaction == .resizing) item.size = self.drag.authored_before.size;
    }

    fn applyNudge(
        self: *Studio,
        items: []slides.SlideItem,
        resolved_bounds: []const ResolvedBounds,
        delta: rl.Vector2,
    ) ?GeometryCommand {
        const identity = self.selected_identity orelse return null;
        const index = itemIndexByIdentity(items, identity) orelse return null;
        const before = itemGeometry(items[index], resolved_bounds);
        items[index].position = add(items[index].position, delta);
        const after: Geometry = .{ .position = items[index].position, .size = before.size };
        self.dirty = true;
        self.copy_is_current = false;
        return .{
            .item_identity = identity,
            .source = items[index].source,
            .before_position = before.position,
            .before_size = before.size,
            .after_position = after.position,
            .after_size = after.size,
            .resized = false,
        };
    }

    /// Draw after the slide itself. While dragging, the original bounds remain
    /// visible as a subdued outline and the live geometry gets the accent.
    pub fn draw(self: Studio, items: []const slides.SlideItem, resolved_bounds: []const ResolvedBounds, viewport: Viewport) void {
        if (!self.enabled) return;

        if (self.interaction != .idle) {
            if (geometryToScreenRect(viewport, self.drag.before)) |original| {
                rl.drawRectangleLinesEx(original, 1, .{ .r = 255, .g = 255, .b = 255, .a = 105 });
            }
        }

        if (self.selectedGeometry(items, resolved_bounds)) |geometry| {
            if (geometryToScreenRect(viewport, geometry)) |rect| {
                const selected_index = self.selectedIndex(items);
                const accent: rl.Color = if (selected_index) |index|
                    if (!self.itemEditableInScene(items[index]))
                        .{ .r = 255, .g = 112, .b = 112, .a = 255 }
                    else if (self.active_morph_state == null and items[index].source.scope == .slide_template)
                        .{ .r = 247, .g = 164, .b = 29, .a = 255 }
                    else
                        .{ .r = 80, .g = 215, .b = 255, .a = 255 }
                else
                    .{ .r = 80, .g = 215, .b = 255, .a = 255 };
                rl.drawRectangleLinesEx(rect, 3, accent);
                if (selected_index) |index| {
                    if (self.itemEditableInScene(items[index])) {
                        if (self.resizeHandleRect(viewport, geometry)) |handle| {
                            rl.drawRectangleRec(handle, accent);
                            rl.drawRectangleLinesEx(handle, 1, .white);
                        }
                    }
                }
            }
        }

        self.drawToolbar(viewport);
        if (self.selected_identity != null) self.drawProperties(viewport);
        self.drawStatus(items, resolved_bounds, viewport);
    }

    /// Convenience draw path with placeholder thumbnail wells. Integrations
    /// that render true previews should instead call draw(), then
    /// drawWorkspaceBackground(), render each visibleSlidePreview(), and finish
    /// with drawWorkspaceOverlay().
    pub fn drawWithWorkspace(
        self: Studio,
        items: []const slides.SlideItem,
        resolved_bounds: []const ResolvedBounds,
        viewport: Viewport,
        workspace: Workspace,
    ) void {
        self.draw(items, resolved_bounds, viewport);
        self.drawWorkspaceBackground(viewport, workspace);
        self.drawWorkspaceOverlay(viewport, workspace);
    }

    pub fn drawWorkspaceBackground(self: Studio, viewport: Viewport, workspace: Workspace) void {
        if (!self.enabled or !workspace.visible) return;
        const layout = workspaceLayout(viewport);
        if (layout.sidebar.height < workspace_min_height) return;
        drawStudioPanel(layout.organizer);
        drawStudioPanel(layout.library);
        for (0..slideCardCapacity(layout)) |visible_slot| {
            const summary_index = self.organizer_first_visible + visible_slot;
            if (summary_index >= workspace.slides.len) break;
            const card = slideCardRect(layout, visible_slot) orelse break;
            rl.drawRectangleRec(card, .{ .r = 25, .g = 31, .b = 45, .a = 250 });
            rl.drawRectangleRec(slidePreviewRect(card), .{ .r = 4, .g = 7, .b = 13, .a = 255 });
        }
        for (0..libraryRowCapacity(layout)) |visible_slot| {
            const entry_index = self.library_first_visible + visible_slot;
            if (entry_index >= workspace.library.len) break;
            const row = libraryRowRect(layout, visible_slot) orelse break;
            const entry = workspace.library[entry_index];
            rl.drawRectangleRec(row, if (entry.available)
                .{ .r = 25, .g = 31, .b = 45, .a = 250 }
            else
                .{ .r = 22, .g = 25, .b = 32, .a = 245 });
        }
    }

    pub fn drawWorkspaceOverlay(self: Studio, viewport: Viewport, workspace: Workspace) void {
        if (!self.enabled or !workspace.visible) return;
        const layout = workspaceLayout(viewport);
        if (layout.sidebar.height < workspace_min_height) return;
        rl.drawText("SLIDES", @intFromFloat(layout.organizer.x + 12), @intFromFloat(layout.organizer.y + 10), 15, .white);
        const action_labels = [_][:0]const u8{ "+", "Dup", "Del", "Up", "Down" };
        for (layout.organizer_actions, action_labels) |button, label| drawCompactButton(button, label);
        drawCompactButton(layout.slide_page_previous, "Prev");
        drawCompactButton(layout.slide_page_next, "Next");

        for (0..slideCardCapacity(layout)) |visible_slot| {
            const summary_index = self.organizer_first_visible + visible_slot;
            if (summary_index >= workspace.slides.len) break;
            const summary = workspace.slides[summary_index];
            const card = slideCardRect(layout, visible_slot) orelse break;
            const active = summary.index == workspace.current_slide;
            const border: rl.Color = if (active)
                .{ .r = 80, .g = 215, .b = 255, .a = 255 }
            else
                .{ .r = 103, .g = 117, .b = 140, .a = 210 };
            rl.drawRectangleLinesEx(card, if (active) 3 else 1, border);
            rl.drawRectangleLinesEx(slidePreviewRect(card), 1, .{ .r = 145, .g = 158, .b = 180, .a = 220 });

            const preview = slidePreviewRect(card);
            const text_x = preview.x + preview.width + 9;
            var line_buffer: [96]u8 = undefined;
            const slide_number = std.fmt.bufPrintZ(&line_buffer, "SLIDE {d}", .{summary.index + 1}) catch "SLIDE";
            rl.drawText(slide_number, @intFromFloat(text_x), @intFromFloat(card.y + 9), 12, if (active) border else .white);
            var title_buffer: [96]u8 = undefined;
            const title = textForDraw(&title_buffer, if (summary.title.len == 0) "Untitled" else summary.title);
            rl.drawText(title, @intFromFloat(text_x), @intFromFloat(card.y + 30), 14, .white);
            var metadata_buffer: [96]u8 = undefined;
            const metadata = std.fmt.bufPrintZ(
                &metadata_buffer,
                "{d} items · {d} states",
                .{ summary.item_count, summary.morph_count },
            ) catch "slide details";
            rl.drawText(metadata, @intFromFloat(text_x), @intFromFloat(card.y + 57), 11, .{ .r = 168, .g = 179, .b = 198, .a = 255 });
        }

        rl.drawText("LIBRARY", @intFromFloat(layout.library.x + 12), @intFromFloat(layout.library.y + 10), 15, .white);
        drawCompactButton(layout.library_page_previous, "Prev");
        drawCompactButton(layout.library_page_next, "Next");
        for (0..libraryRowCapacity(layout)) |visible_slot| {
            const entry_index = self.library_first_visible + visible_slot;
            if (entry_index >= workspace.library.len) break;
            const entry = workspace.library[entry_index];
            const row = libraryRowRect(layout, visible_slot) orelse break;
            const selected = self.selected_library_index != null and self.selected_library_index.? == entry_index;
            const border: rl.Color = if (selected)
                .{ .r = 80, .g = 215, .b = 255, .a = 255 }
            else if (!entry.available)
                .{ .r = 85, .g = 90, .b = 102, .a = 180 }
            else
                .{ .r = 103, .g = 117, .b = 140, .a = 210 };
            rl.drawRectangleLinesEx(row, if (selected) 2 else 1, border);
            const badge: [:0]const u8 = if (entry.kind == .element) "ITEM" else "SLIDE";
            const badge_rect: rl.Rectangle = .{ .x = row.x + 7, .y = row.y + 9, .width = 48, .height = 28 };
            rl.drawRectangleRec(badge_rect, if (entry.kind == .element)
                .{ .r = 43, .g = 123, .b = 151, .a = if (entry.available) 255 else 100 }
            else
                .{ .r = 116, .g = 83, .b = 160, .a = if (entry.available) 255 else 100 });
            var name_buffer: [128]u8 = undefined;
            const name = textForDraw(&name_buffer, entry.name);
            rl.drawText(badge, @intFromFloat(badge_rect.x + 7), @intFromFloat(badge_rect.y + 7), 11, .white);
            rl.drawText(name, @intFromFloat(row.x + 64), @intFromFloat(row.y + 15), 14, if (entry.available)
                .white
            else
                .{ .r = 130, .g = 136, .b = 149, .a = 255 });
        }
    }

    fn drawToolbar(self: Studio, viewport: Viewport) void {
        const layout = uiLayout(viewport);
        drawStudioPanel(layout.toolbar);
        const tools = [_]Tool{ .select, .add_text, .add_bullets, .add_image, .add_shape, .add_reusable };
        for (layout.tool_buttons, tools) |button, tool| {
            const active = self.tool == tool;
            rl.drawRectangleRec(button, if (active)
                .{ .r = 43, .g = 123, .b = 151, .a = 255 }
            else
                .{ .r = 31, .g = 38, .b = 55, .a = 245 });
            rl.drawRectangleLinesEx(button, if (active) 2 else 1, if (active)
                .{ .r = 80, .g = 215, .b = 255, .a = 255 }
            else
                .{ .r = 115, .g = 128, .b = 150, .a = 200 });
            const label = toolLabel(tool);
            const font_size: i32 = 15;
            const width = rl.measureText(label, font_size);
            rl.drawText(
                label,
                @intFromFloat(button.x + (button.width - @as(f32, @floatFromInt(width))) / 2),
                @intFromFloat(button.y + 13),
                font_size,
                .white,
            );
        }
        drawActionButton(layout.new_slide, "+ Slide");
        drawActionButton(layout.scene_previous, "<");
        var scene_buffer: [32]u8 = undefined;
        const scene_label: [:0]const u8 = if (self.active_morph_state) |state|
            std.fmt.bufPrintZ(&scene_buffer, "STATE {d}/{d}", .{ state + 1, self.morph_state_count }) catch "MORPH"
        else
            "BASE";
        drawActionButton(layout.scene_label, scene_label);
        drawActionButton(layout.scene_next, ">");
    }

    fn drawProperties(_: Studio, viewport: Viewport) void {
        const layout = uiLayout(viewport);
        drawStudioPanel(layout.properties);
        rl.drawText("PROPERTIES", @intFromFloat(layout.properties.x + 12), @intFromFloat(layout.properties.y + 11), 15, .white);
        drawActionButton(layout.edit_text, "Text");
        drawActionButton(layout.delete_item, "Delete");
        drawActionButton(layout.promote, "Reuse");
        rl.drawText("FOREGROUND", @intFromFloat(layout.properties.x + 12), @intFromFloat(layout.properties.y + 82), 12, .{ .r = 185, .g = 196, .b = 215, .a = 255 });
        drawSwatches(layout.foreground_swatches);
        rl.drawText("BACKGROUND", @intFromFloat(layout.properties.x + 12), @intFromFloat(layout.properties.y + 146), 12, .{ .r = 185, .g = 196, .b = 215, .a = 255 });
        drawSwatches(layout.background_swatches);
    }

    fn drawStatus(self: Studio, items: []const slides.SlideItem, resolved_bounds: []const ResolvedBounds, viewport: Viewport) void {
        const panel = statusPanel(viewport);
        rl.drawRectangleRec(panel, .{ .r = 10, .g = 14, .b = 24, .a = 225 });
        rl.drawRectangleLinesEx(panel, 1, .{ .r = 80, .g = 215, .b = 255, .a = 180 });

        var status_buffer: [512]u8 = undefined;
        const status_text = if (self.selected_identity) |identity| selected: {
            const geometry = self.selectedGeometry(items, resolved_bounds) orelse break :selected "STUDIO · selection unavailable";
            const index = self.selectedIndex(items) orelse break :selected "STUDIO · selection unavailable";
            const source = if (self.active_morph_state != null) items[index].effectiveSource() else items[index].source;
            break :selected std.fmt.bufPrintZ(
                &status_buffer,
                "STUDIO{s} · item #{d} · {s}, line {d} · x {d:.0} y {d:.0} w {d:.0} h {d:.0}",
                .{ if (self.dirty) " *" else "", identity, sourceScopeLabel(source.scope), source.line_number, geometry.position.x, geometry.position.y, geometry.size.x, geometry.size.y },
            ) catch "STUDIO · selected item";
        } else if (self.dirty) "STUDIO * · click an item to select it" else "STUDIO · click an item to select it";

        rl.drawText(status_text, @intFromFloat(panel.x + 12), @intFromFloat(panel.y + 9), 18, .white);
        rl.drawText(
            "V select · T text · B bullets · I image · R shape · U library · Cmd/Ctrl-N slide · [ ] morph",
            @intFromFloat(panel.x + 12),
            @intFromFloat(panel.y + 35),
            14,
            .{ .r = 185, .g = 196, .b = 215, .a = 255 },
        );
        rl.drawText(
            "Cmd/Ctrl-S save  ·  Shift-Cmd/Ctrl-S save copy  ·  Cmd/Ctrl-Z undo  ·  Shift-Cmd/Ctrl-Z redo",
            @intFromFloat(panel.x + 12),
            @intFromFloat(panel.y + 55),
            14,
            .{ .r = 185, .g = 196, .b = 215, .a = 255 },
        );
        const notice_text: ?[:0]const u8 = switch (self.notice) {
            .none => null,
            .saved => "Saved to the original .sld",
            .copy_saved => "Saved an .edited.sld copy",
            .save_failed => "Save failed - see the log for details",
            .source_changed_on_disk => "Original changed on disk - use Save Copy to preserve this version",
            .edit_failed => "Edit rejected - the original source is unchanged",
            .undo_failed => "Undo/redo failed - see the log for details",
            .shared_template_locked => "Shared layout item: hold Alt to edit every slide that uses it",
            .generated_source_read_only => "Read-only in Studio: this item directive is produced with @let",
            .property_unavailable => "That property does not apply to this kind of item",
            .base_scene_only => "That action is available in the BASE scene",
            .structural_source_locked => "Slide structure is source-scoped here; no changes were made",
        };
        if (notice_text) |message| {
            const notice_color: rl.Color = switch (self.notice) {
                .saved, .copy_saved => .{ .r = 126, .g = 231, .b = 177, .a = 255 },
                else => .{ .r = 255, .g = 145, .b = 132, .a = 255 },
            };
            rl.drawText(message, @intFromFloat(panel.x + 12), @intFromFloat(panel.y + 75), 14, notice_color);
        }
    }
};

fn toolLabel(tool: Tool) [:0]const u8 {
    return switch (tool) {
        .select => "V",
        .add_text => "T",
        .add_bullets => "B",
        .add_image => "IMG",
        .add_shape => "RECT",
        .add_reusable => "LIB",
    };
}

fn drawStudioPanel(rect: rl.Rectangle) void {
    rl.drawRectangleRec(rect, .{ .r = 10, .g = 14, .b = 24, .a = 235 });
    rl.drawRectangleLinesEx(rect, 1, .{ .r = 80, .g = 215, .b = 255, .a = 180 });
}

fn drawActionButton(rect: rl.Rectangle, label: [:0]const u8) void {
    rl.drawRectangleRec(rect, .{ .r = 31, .g = 38, .b = 55, .a = 245 });
    rl.drawRectangleLinesEx(rect, 1, .{ .r = 115, .g = 128, .b = 150, .a = 200 });
    const font_size: i32 = 13;
    const width = rl.measureText(label, font_size);
    rl.drawText(
        label,
        @intFromFloat(rect.x + (rect.width - @as(f32, @floatFromInt(width))) / 2),
        @intFromFloat(rect.y + 8),
        font_size,
        .white,
    );
}

fn drawCompactButton(rect: rl.Rectangle, label: [:0]const u8) void {
    rl.drawRectangleRec(rect, .{ .r = 31, .g = 38, .b = 55, .a = 245 });
    rl.drawRectangleLinesEx(rect, 1, .{ .r = 105, .g = 120, .b = 143, .a = 210 });
    const font_size: i32 = 11;
    const width = rl.measureText(label, font_size);
    rl.drawText(
        label,
        @intFromFloat(rect.x + (rect.width - @as(f32, @floatFromInt(width))) / 2),
        @intFromFloat(rect.y + (rect.height - @as(f32, @floatFromInt(font_size))) / 2),
        font_size,
        .white,
    );
}

fn textForDraw(buffer: []u8, value: []const u8) [:0]const u8 {
    std.debug.assert(buffer.len >= 5);
    if (value.len < buffer.len) {
        @memcpy(buffer[0..value.len], value);
        buffer[value.len] = 0;
        return buffer[0..value.len :0];
    }
    var end = buffer.len - 4;
    while (end > 0 and value[end] & 0xc0 == 0x80) end -= 1;
    @memcpy(buffer[0..end], value[0..end]);
    @memcpy(buffer[end .. end + 3], "...");
    buffer[end + 3] = 0;
    return buffer[0 .. end + 3 :0];
}

fn drawSwatches(rects: [palette.len]rl.Rectangle) void {
    for (rects, palette) |rect, value| {
        rl.drawRectangleRec(rect, paletteColor(value));
        rl.drawRectangleLinesEx(rect, 1, .{ .r = 225, .g = 231, .b = 240, .a = 210 });
    }
}

fn pointInRectangle(point: rl.Vector2, rect: rl.Rectangle) bool {
    return point.x >= rect.x and point.y >= rect.y and
        point.x <= rect.x + rect.width and point.y <= rect.y + rect.height;
}

fn summaryOffsetForSlide(summaries: []const SlideSummary, slide_index: usize) ?usize {
    for (summaries, 0..) |summary, offset| {
        if (summary.index == slide_index) return offset;
    }
    return null;
}

fn maxFirstVisible(item_count: usize, capacity: usize) usize {
    if (capacity == 0 or item_count <= capacity) return 0;
    return item_count - capacity;
}

fn clampFirstVisible(first: usize, item_count: usize, capacity: usize) usize {
    return @min(first, maxFirstVisible(item_count, capacity));
}

fn revealIndex(first: usize, index: usize, item_count: usize, capacity: usize) usize {
    if (capacity == 0) return 0;
    if (index < first) return index;
    if (index >= first + capacity) return @min(index - capacity + 1, maxFirstVisible(item_count, capacity));
    return clampFirstVisible(first, item_count, capacity);
}

fn scrollFirstVisible(first: usize, item_count: usize, capacity: usize, direction: i8) usize {
    const maximum = maxFirstVisible(item_count, capacity);
    if (direction < 0) return first -| 1;
    if (direction > 0) return @min(first + 1, maximum);
    return @min(first, maximum);
}

fn pageFirstVisible(first: usize, item_count: usize, capacity: usize, forward: bool) usize {
    if (capacity == 0) return 0;
    const maximum = maxFirstVisible(item_count, capacity);
    if (forward) return @min(first + capacity, maximum);
    return first -| capacity;
}

fn add(a: rl.Vector2, b: rl.Vector2) rl.Vector2 {
    return .{ .x = a.x + b.x, .y = a.y + b.y };
}

fn subtract(a: rl.Vector2, b: rl.Vector2) rl.Vector2 {
    return .{ .x = a.x - b.x, .y = a.y - b.y };
}

fn roundVector(value: rl.Vector2) rl.Vector2 {
    return .{ .x = @round(value.x), .y = @round(value.y) };
}

fn geometryEqual(a: Geometry, b: Geometry) bool {
    return a.position.x == b.position.x and a.position.y == b.position.y and
        a.size.x == b.size.x and a.size.y == b.size.y;
}

fn testItem(identity: usize, kind: slides.SlideItemKind, x: f32, y: f32, w: f32, h: f32) slides.SlideItem {
    return .{
        .identity = identity,
        .source = .{ .scope = .direct, .patchable = true },
        .kind = kind,
        .position = .{ .x = x, .y = y },
        .size = .{ .x = w, .y = h },
    };
}

fn expectVector(expected: rl.Vector2, actual: rl.Vector2) !void {
    try std.testing.expectApproxEqAbs(expected.x, actual.x, 0.0001);
    try std.testing.expectApproxEqAbs(expected.y, actual.y, 0.0001);
}

test "coordinate conversion round trips through a letterboxed viewport" {
    const viewport: Viewport = .{
        .slide_top_left = .{ .x = 100, .y = 50 },
        .slide_size = .{ .x = 960, .y = 540 },
    };
    const logical: rl.Vector2 = .{ .x = 640, .y = 360 };
    const screen = logicalToScreen(viewport, logical).?;
    try expectVector(.{ .x = 420, .y = 230 }, screen);
    try expectVector(logical, screenToLogical(viewport, screen).?);
    try std.testing.expect(viewport.containsScreenPoint(.{ .x = 100, .y = 50 }));
    try std.testing.expect(!viewport.containsScreenPoint(.{ .x = 99, .y = 50 }));
}

test "invalid viewport conversion is rejected" {
    const viewport: Viewport = .{
        .slide_top_left = .{ .x = 0, .y = 0 },
        .slide_size = .{ .x = 0, .y = 540 },
    };
    try std.testing.expect(logicalToScreen(viewport, .{ .x = 1, .y = 1 }) == null);
    try std.testing.expect(screenToLogical(viewport, .{ .x = 1, .y = 1 }) == null);
}

test "hit testing uses reverse z order and skips non-selectable items" {
    var items = [_]slides.SlideItem{
        testItem(1, .background, 0, 0, 1920, 1080),
        testItem(2, .textbox, 100, 100, 300, 200),
        testItem(3, .img, 150, 120, 300, 200),
        testItem(4, .textbox, 150, 120, 0, 200),
        testItem(5, .textbox, 150, 120, 300, 200),
    };
    items[4].visible = false;
    try std.testing.expectEqual(@as(?usize, 2), hitTest(&items, &.{}, .{ .x = 175, .y = 150 }));
    try std.testing.expectEqual(@as(?usize, null), hitTest(&items, &.{}, .{ .x = 20, .y = 20 }));
}

test "move drag emits before and after geometry with layout clone provenance" {
    var items = [_]slides.SlideItem{testItem(42, .textbox, 100, 200, 400, 180)};
    items[0].source = .{ .line_number = 12, .line_offset = 812, .scope = .slide_template, .patchable = true };
    const viewport: Viewport = .{
        .slide_top_left = .{ .x = 0, .y = 0 },
        .slide_size = default_logical_size,
    };
    var studio: Studio = .{ .enabled = true };

    try std.testing.expect(studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 120, .y = 220 },
        .pointer_pressed = true,
        .pointer_down = true,
        .allow_shared_edit = true,
    }) == null);
    try std.testing.expectEqual(Interaction.moving, studio.interaction);
    try std.testing.expectEqual(@as(?usize, 42), studio.selected_identity);

    try std.testing.expect(studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 170, .y = 250 },
        .pointer_down = true,
        .allow_shared_edit = true,
    }) == null);
    try expectVector(.{ .x = 150, .y = 230 }, items[0].position);

    const command = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 170, .y = 250 },
        .pointer_released = true,
        .allow_shared_edit = true,
    }).?;
    try std.testing.expect(!command.resized);
    try std.testing.expectEqual(SourceScope.slide_template, command.source.scope);
    try std.testing.expectEqual(@as(usize, 812), command.source.line_offset);
    try expectVector(.{ .x = 100, .y = 200 }, command.before_position);
    try expectVector(.{ .x = 150, .y = 230 }, command.after_position);
    try std.testing.expectEqual(Interaction.idle, studio.interaction);
    try std.testing.expect(studio.dirty);
}

test "bottom-right handle resizes and enforces a logical minimum" {
    var items = [_]slides.SlideItem{testItem(7, .img, 100, 100, 200, 100)};
    const viewport: Viewport = .{
        .slide_top_left = .{ .x = 0, .y = 0 },
        .slide_size = default_logical_size,
    };
    var studio: Studio = .{ .enabled = true, .selected_identity = 7 };

    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 300, .y = 200 },
        .pointer_pressed = true,
        .pointer_down = true,
    });
    try std.testing.expectEqual(Interaction.resizing, studio.interaction);

    const command = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 80, .y = 80 },
        .pointer_released = true,
    }).?;
    try std.testing.expect(command.resized);
    try expectVector(.{ .x = 8, .y = 8 }, command.after_size);
    try expectVector(.{ .x = 100, .y = 100 }, command.after_position);
}

test "keyboard nudge is one complete command" {
    var items = [_]slides.SlideItem{testItem(9, .textbox, 10, 20, 30, 40)};
    items[0].source = .{ .line_number = 2, .line_offset = 99, .scope = .direct, .patchable = true };
    var studio: Studio = .{ .enabled = true, .selected_identity = 9 };
    const command = studio.update(&items, &.{}, .{
        .slide_top_left = .{ .x = 0, .y = 0 },
        .slide_size = default_logical_size,
    }, .{ .nudge = .{ .x = -10, .y = 1 } }).?;
    try std.testing.expect(!command.resized);
    try expectVector(.{ .x = 0, .y = 21 }, command.after_position);
    try std.testing.expectEqual(SourceScope.direct, command.source.scope);
}

test "toggle during a drag restores geometry and clears selection" {
    var items = [_]slides.SlideItem{testItem(11, .textbox, 10, 220, 100, 100)};
    const viewport: Viewport = .{
        .slide_top_left = .{ .x = 0, .y = 0 },
        .slide_size = default_logical_size,
    };
    var studio: Studio = .{ .enabled = true };
    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 20, .y = 230 },
        .pointer_pressed = true,
        .pointer_down = true,
    });
    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 70, .y = 280 },
        .pointer_down = true,
    });
    try expectVector(.{ .x = 60, .y = 270 }, items[0].position);

    _ = studio.update(&items, &.{}, viewport, .{ .toggle_pressed = true });
    try std.testing.expect(!studio.enabled);
    try std.testing.expectEqual(@as(?usize, null), studio.selected_identity);
    try std.testing.expectEqual(Interaction.idle, studio.interaction);
    try expectVector(.{ .x = 10, .y = 220 }, items[0].position);
}

test "resolved renderer bounds make an auto-sized image selectable" {
    const items = [_]slides.SlideItem{testItem(21, .img, 500, 300, 0, 0)};
    const bounds = [_]ResolvedBounds{.{
        .identity = 21,
        .position = .{ .x = 500, .y = 300 },
        .size = .{ .x = 640, .y = 360 },
    }};
    try std.testing.expectEqual(@as(?usize, 0), hitTest(&items, &bounds, .{ .x = 700, .y = 400 }));
    const geometry = itemGeometry(items[0], &bounds);
    try expectVector(.{ .x = 640, .y = 360 }, geometry.size);
}

test "selection rebinds by source after item identities change" {
    var old_items = [_]slides.SlideItem{testItem(30, .textbox, 20, 300, 100, 80)};
    old_items[0].source = .{ .scope = .direct, .line_number = 4, .line_offset = 123, .patchable = true };
    const viewport: Viewport = .{
        .slide_top_left = .{ .x = 0, .y = 0 },
        .slide_size = default_logical_size,
    };
    var studio: Studio = .{ .enabled = true };
    _ = studio.update(&old_items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 40, .y = 320 },
        .pointer_pressed = true,
        .pointer_down = true,
    });
    _ = studio.update(&old_items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 40, .y = 320 },
        .pointer_released = true,
    });
    try std.testing.expectEqual(@as(?usize, 30), studio.selected_identity);

    var reparsed = [_]slides.SlideItem{testItem(91, .textbox, 20, 300, 100, 80)};
    reparsed[0].source = old_items[0].source;
    _ = studio.update(&reparsed, &.{}, viewport, .{});
    try std.testing.expectEqual(@as(?usize, 91), studio.selected_identity);
    try std.testing.expectEqual(Status.selected, studio.status());
}

test "cancelled auto-image resize restores authored zero size" {
    var items = [_]slides.SlideItem{testItem(55, .img, 100, 100, 0, 0)};
    const bounds = [_]ResolvedBounds{.{
        .identity = 55,
        .position = .{ .x = 100, .y = 100 },
        .size = .{ .x = 200, .y = 100 },
    }};
    const viewport: Viewport = .{
        .slide_top_left = .{ .x = 0, .y = 0 },
        .slide_size = default_logical_size,
    };
    var studio: Studio = .{ .enabled = true, .selected_identity = 55 };
    _ = studio.update(&items, &bounds, viewport, .{
        .pointer_screen = .{ .x = 300, .y = 200 },
        .pointer_pressed = true,
        .pointer_down = true,
    });
    _ = studio.update(&items, &bounds, viewport, .{
        .pointer_screen = .{ .x = 350, .y = 250 },
        .pointer_down = true,
    });
    try expectVector(.{ .x = 250, .y = 150 }, items[0].size);
    _ = studio.update(&items, &bounds, viewport, .{ .cancel_pressed = true });
    try expectVector(.{ .x = 0, .y = 0 }, items[0].size);
    try std.testing.expectEqual(Interaction.idle, studio.interaction);
}

test "shared template geometry requires an explicit Alt gesture" {
    var items = [_]slides.SlideItem{testItem(71, .textbox, 100, 100, 300, 100)};
    items[0].source = .{ .scope = .slide_template, .line_number = 5, .line_offset = 44, .patchable = true };
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    var studio: Studio = .{ .enabled = true };

    try std.testing.expect(studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 150, .y = 130 },
        .pointer_pressed = true,
        .pointer_down = true,
    }) == null);
    try std.testing.expectEqual(@as(?usize, 71), studio.selected_identity);
    try std.testing.expectEqual(Interaction.idle, studio.interaction);
    try std.testing.expectEqual(Notice.shared_template_locked, studio.notice);

    const command = studio.update(&items, &.{}, viewport, .{
        .nudge = .{ .x = 10, .y = 0 },
        .allow_shared_edit = true,
    }).?;
    try std.testing.expectEqual(slides.SourceScope.slide_template, command.source.scope);
    try expectVector(.{ .x = 110, .y = 100 }, command.after_position);
}

test "let-expanded source stays selectable but cannot emit an edit" {
    var items = [_]slides.SlideItem{testItem(72, .textbox, 100, 100, 300, 100)};
    items[0].source = .{ .scope = .direct, .line_number = 3, .line_offset = 25, .patchable = false };
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    var studio: Studio = .{ .enabled = true };

    try std.testing.expect(studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 150, .y = 130 },
        .pointer_pressed = true,
        .pointer_down = true,
    }) == null);
    try std.testing.expectEqual(@as(?usize, 72), studio.selected_identity);
    try std.testing.expectEqual(Interaction.idle, studio.interaction);
    try std.testing.expectEqual(Notice.generated_source_read_only, studio.notice);
    try std.testing.expect(studio.update(&items, &.{}, viewport, .{ .nudge = .{ .x = 1, .y = 0 } }) == null);
    try expectVector(.{ .x = 100, .y = 100 }, items[0].position);
}

test "one-shot creation tool emits placement without mutating slide items" {
    var items = [_]slides.SlideItem{testItem(80, .textbox, 10, 20, 100, 40)};
    const original = items[0];
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    var studio: Studio = .{ .enabled = true, .tool = .add_bullets };

    try std.testing.expect(studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 321.4, .y = 245.6 },
        .pointer_pressed = true,
    }) == null);
    try std.testing.expectEqual(Tool.select, studio.tool);
    try expectVector(original.position, items[0].position);
    try expectVector(original.size, items[0].size);

    const semantic = studio.takeSemanticCommand().?;
    switch (semantic) {
        .add_item => |command| {
            try std.testing.expectEqual(NewItemKind.bullets, command.kind);
            try expectVector(.{ .x = 321, .y = 246 }, command.position);
            try expectVector(.{ .x = 720, .y = 320 }, command.suggested_size);
        },
        else => return error.UnexpectedSemanticCommand,
    }
    try std.testing.expect(studio.peekSemanticCommand() == null);
}

test "shape tool suggests a colored rectangle-sized item" {
    var items: [0]slides.SlideItem = .{};
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    var studio: Studio = .{ .enabled = true, .tool = .add_shape };

    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 700, .y = 400 },
        .pointer_pressed = true,
    });
    switch (studio.takeSemanticCommand().?) {
        .add_item => |command| {
            try std.testing.expectEqual(NewItemKind.shape, command.kind);
            try expectVector(.{ .x = 700, .y = 400 }, command.position);
            try expectVector(.{ .x = 480, .y = 270 }, command.suggested_size);
            try std.testing.expectEqual(@as(?PaletteColor, .blue), command.suggested_color);
        },
        else => return error.UnexpectedSemanticCommand,
    }
    try std.testing.expectEqual(Tool.select, studio.tool);
}

test "reusable library tool emits a positioned pop-insertion intent" {
    var items: [0]slides.SlideItem = .{};
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    var studio: Studio = .{ .enabled = true, .tool = .add_reusable };

    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 900.2, .y = 500.8 },
        .pointer_pressed = true,
    });
    switch (studio.takeSemanticCommand().?) {
        .add_reusable => |command| {
            try expectVector(.{ .x = 900, .y = 501 }, command.position);
            try expectVector(.{ .x = 600, .y = 200 }, command.suggested_size);
        },
        else => return error.UnexpectedSemanticCommand,
    }
    try std.testing.expectEqual(Tool.select, studio.tool);
}

test "new slide toolbar action clears selection and emits a semantic command" {
    var items = [_]slides.SlideItem{testItem(84, .textbox, 100, 100, 300, 100)};
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    const layout = uiLayout(viewport);
    var studio: Studio = .{ .enabled = true, .tool = .add_image, .selected_identity = 84 };

    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = rectangleCenter(layout.new_slide),
        .pointer_pressed = true,
    });
    try std.testing.expectEqual(@as(?usize, null), studio.selected_identity);
    try std.testing.expectEqual(Tool.select, studio.tool);
    switch (studio.takeSemanticCommand().?) {
        .new_slide => {},
        else => return error.UnexpectedSemanticCommand,
    }
}

test "property hit targets emit delete and color commands" {
    var items = [_]slides.SlideItem{testItem(81, .textbox, 100, 100, 300, 100)};
    items[0].source = .{ .scope = .direct, .line_number = 7, .line_offset = 72, .patchable = true };
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    const layout = uiLayout(viewport);
    var studio: Studio = .{ .enabled = true, .selected_identity = 81 };

    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = rectangleCenter(layout.delete_item),
        .pointer_pressed = true,
    });
    switch (studio.takeSemanticCommand().?) {
        .delete_item => |target| {
            try std.testing.expectEqual(@as(usize, 81), target.item_identity);
            try std.testing.expectEqual(@as(usize, 72), target.source.line_offset);
        },
        else => return error.UnexpectedSemanticCommand,
    }

    const cyan_index = @intFromEnum(PaletteColor.cyan);
    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = rectangleCenter(layout.foreground_swatches[cyan_index]),
        .pointer_pressed = true,
    });
    switch (studio.takeSemanticCommand().?) {
        .set_foreground => |command| {
            try std.testing.expectEqual(PaletteColor.cyan, command.color);
            try std.testing.expectEqual(@as(usize, 81), command.target.item_identity);
        },
        else => return error.UnexpectedSemanticCommand,
    }
    try expectVector(.{ .x = 100, .y = 100 }, items[0].position);
}

test "keyboard property commands respect shared template lock" {
    var items = [_]slides.SlideItem{testItem(82, .textbox, 100, 100, 300, 100)};
    items[0].source = .{ .scope = .slide_template, .line_number = 9, .line_offset = 99, .patchable = true };
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    var studio: Studio = .{ .enabled = true, .selected_identity = 82 };

    _ = studio.update(&items, &.{}, viewport, .{ .edit_text_pressed = true });
    try std.testing.expect(studio.takeSemanticCommand() == null);
    try std.testing.expectEqual(Notice.shared_template_locked, studio.notice);

    _ = studio.update(&items, &.{}, viewport, .{ .edit_text_pressed = true, .allow_shared_edit = true });
    switch (studio.takeSemanticCommand().?) {
        .edit_text => |target| try std.testing.expectEqual(@as(usize, 82), target.item_identity),
        else => return error.UnexpectedSemanticCommand,
    }
}

test "promotion is offered only for direct base box items" {
    var items = [_]slides.SlideItem{testItem(88, .textbox, 100, 100, 300, 100)};
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    var studio: Studio = .{ .enabled = true, .selected_identity = 88 };

    items[0].source.scope = .component_instance;
    _ = studio.update(&items, &.{}, viewport, .{ .promote_pressed = true });
    try std.testing.expect(studio.takeSemanticCommand() == null);
    try std.testing.expectEqual(Notice.property_unavailable, studio.notice);

    items[0].source.scope = .direct;
    items[0].kind = .crowd;
    _ = studio.update(&items, &.{}, viewport, .{ .promote_pressed = true });
    try std.testing.expect(studio.takeSemanticCommand() == null);
    try std.testing.expectEqual(Notice.property_unavailable, studio.notice);

    items[0].kind = .textbox;
    _ = studio.update(&items, &.{}, viewport, .{ .promote_pressed = true });
    try std.testing.expect(std.meta.activeTag(studio.takeSemanticCommand().?) == .promote_to_reusable);
}

test "morph scene cycles through states and base while clearing selection" {
    var items = [_]slides.SlideItem{testItem(83, .textbox, 100, 100, 300, 100)};
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    var studio: Studio = .{
        .enabled = true,
        .selected_identity = 83,
        .tool = .add_reusable,
        .selected_library_index = 0,
    };
    studio.setMorphStateCount(2);

    _ = studio.update(&items, &.{}, viewport, .{ .cycle_morph_scene = 1 });
    try std.testing.expectEqual(@as(?usize, 0), studio.active_morph_state);
    try std.testing.expectEqual(@as(?usize, null), studio.selected_identity);
    try std.testing.expectEqual(@as(?usize, null), studio.selected_library_index);
    try std.testing.expectEqual(Tool.select, studio.tool);
    switch (studio.takeSemanticCommand().?) {
        .select_morph_scene => |command| try std.testing.expectEqual(@as(?usize, 0), command.active_state),
        else => return error.UnexpectedSemanticCommand,
    }

    studio.cycleMorphState(&items, 1);
    try std.testing.expectEqual(@as(?usize, 1), studio.active_morph_state);
    _ = studio.takeSemanticCommand();
    studio.cycleMorphState(&items, 1);
    try std.testing.expectEqual(@as(?usize, null), studio.active_morph_state);
    _ = studio.takeSemanticCommand();
    studio.cycleMorphState(&items, -1);
    try std.testing.expectEqual(@as(?usize, 1), studio.active_morph_state);
}

test "morph scene toolbar controls cycle without bracket keys" {
    var items = [_]slides.SlideItem{testItem(84, .textbox, 100, 100, 300, 100)};
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    const layout = uiLayout(viewport);
    var studio: Studio = .{ .enabled = true };
    studio.setMorphStateCount(2);

    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = rectangleCenter(layout.scene_next),
        .pointer_pressed = true,
    });
    try std.testing.expectEqual(@as(?usize, 0), studio.active_morph_state);
    _ = studio.takeSemanticCommand();

    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = rectangleCenter(layout.scene_previous),
        .pointer_pressed = true,
    });
    try std.testing.expectEqual(@as(?usize, null), studio.active_morph_state);
    _ = studio.takeSemanticCommand();

    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = rectangleCenter(layout.scene_label),
        .pointer_pressed = true,
    });
    try std.testing.expectEqual(@as(?usize, 0), studio.active_morph_state);
}

test "leaving Studio resets morph scene to base" {
    var items = [_]slides.SlideItem{testItem(85, .textbox, 100, 100, 300, 100)};
    var studio: Studio = .{ .enabled = true, .active_morph_state = 1, .morph_state_count = 2 };

    studio.toggle(&items);
    try std.testing.expect(!studio.enabled);
    try std.testing.expectEqual(@as(?usize, null), studio.active_morph_state);

    studio.enabled = true;
    studio.active_morph_state = 0;
    studio.disable(&items);
    try std.testing.expectEqual(@as(?usize, null), studio.active_morph_state);
}

test "idless morph births are editable only in their creation state" {
    var items = [_]slides.SlideItem{testItem(86, .textbox, 100, 100, 300, 100)};
    items[0].source = .{ .scope = .morph_item, .line_number = 5, .line_offset = 50, .patchable = true };
    items[0].creation_morph_state = 0;
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };

    var local: Studio = .{ .enabled = true, .active_morph_state = 0, .morph_state_count = 2, .selected_identity = 86 };
    const local_command = local.update(&items, &.{}, viewport, .{ .nudge = .{ .x = 1, .y = 0 } }).?;
    try expectVector(.{ .x = 101, .y = 100 }, local_command.after_position);

    items[0].position = .{ .x = 100, .y = 100 };
    var inherited: Studio = .{ .enabled = true, .active_morph_state = 1, .morph_state_count = 2, .selected_identity = 86 };
    try std.testing.expect(inherited.update(&items, &.{}, viewport, .{ .nudge = .{ .x = 1, .y = 0 } }) == null);
    try expectVector(.{ .x = 100, .y = 100 }, items[0].position);
    try std.testing.expectEqual(Notice.generated_source_read_only, inherited.notice);

    items[0].id = "born";
    const inherited_command = inherited.update(&items, &.{}, viewport, .{ .nudge = .{ .x = 1, .y = 0 } }).?;
    try expectVector(.{ .x = 101, .y = 100 }, inherited_command.after_position);
}

test "semantic keyboard and panel actions cancel active geometry first" {
    var items = [_]slides.SlideItem{testItem(87, .textbox, 100, 100, 300, 100)};
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    const layout = uiLayout(viewport);
    var studio: Studio = .{ .enabled = true };

    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 120, .y = 120 },
        .pointer_pressed = true,
        .pointer_down = true,
    });
    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 220, .y = 180 },
        .pointer_down = true,
    });
    try expectVector(.{ .x = 200, .y = 160 }, items[0].position);
    _ = studio.update(&items, &.{}, viewport, .{ .delete_pressed = true });
    try std.testing.expectEqual(Interaction.idle, studio.interaction);
    try expectVector(.{ .x = 100, .y = 100 }, items[0].position);
    try std.testing.expect(std.meta.activeTag(studio.takeSemanticCommand().?) == .delete_item);

    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 120, .y = 120 },
        .pointer_pressed = true,
        .pointer_down = true,
    });
    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 260, .y = 200 },
        .pointer_down = true,
    });
    try expectVector(.{ .x = 240, .y = 180 }, items[0].position);
    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = rectangleCenter(layout.delete_item),
        .pointer_pressed = true,
    });
    try std.testing.expectEqual(Interaction.idle, studio.interaction);
    try expectVector(.{ .x = 100, .y = 100 }, items[0].position);
    try std.testing.expect(std.meta.activeTag(studio.takeSemanticCommand().?) == .delete_item);
}

test "workspace layout exposes bounded slide thumbnail slots" {
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    const layout = workspaceLayout(viewport);
    try std.testing.expect(slideCardCapacity(layout) >= 2);
    try std.testing.expect(libraryRowCapacity(layout) >= 1);
    const first = slideCardRect(layout, 0).?;
    const second = slideCardRect(layout, 1).?;
    const preview = slidePreviewRect(first);
    try std.testing.expect(pointInRectangle(.{ .x = preview.x, .y = preview.y }, first));
    try std.testing.expect(pointInRectangle(.{ .x = preview.x + preview.width, .y = preview.y + preview.height }, first));
    try std.testing.expect(first.y + first.height < second.y);
    try std.testing.expect(!pointInRectangle(rectangleCenter(layout.library), layout.organizer));

    const short_viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = .{ .x = 900, .y = 360 } };
    const short_layout = workspaceLayout(short_viewport);
    try std.testing.expect(short_layout.sidebar.height < workspace_min_height);
    const summaries = [_]SlideSummary{.{ .index = 0 }};
    const short_workspace: Workspace = .{ .visible = true, .slides = &summaries };
    const short_studio: Studio = .{ .enabled = true };
    try std.testing.expect(short_studio.visibleSlidePreview(short_viewport, short_workspace, 0) == null);
}

test "organizer card selects a slide and shields the canvas beneath it" {
    var items = [_]slides.SlideItem{testItem(120, .textbox, 0, 0, 600, 800)};
    const summaries = [_]SlideSummary{
        .{ .index = 2, .title = "Opening" },
        .{ .index = 4, .title = "Details" },
        .{ .index = 9, .title = "Finish" },
    };
    const workspace: Workspace = .{ .visible = true, .slides = &summaries, .current_slide = 2 };
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    const second_card = slideCardRect(workspaceLayout(viewport), 1).?;
    var studio: Studio = .{ .enabled = true };

    _ = studio.updateWithWorkspace(&items, &.{}, viewport, workspace, .{
        .pointer_screen = rectangleCenter(second_card),
        .pointer_pressed = true,
        .pointer_down = true,
    });
    try std.testing.expectEqual(Interaction.idle, studio.interaction);
    try std.testing.expectEqual(@as(?usize, null), studio.selected_identity);
    switch (studio.takeSemanticCommand().?) {
        .select_slide => |index| try std.testing.expectEqual(@as(usize, 4), index),
        else => return error.UnexpectedSemanticCommand,
    }
}

test "organizer actions emit duplicate delete and bounded move commands" {
    var items: [0]slides.SlideItem = .{};
    const summaries = [_]SlideSummary{
        .{ .index = 10 },
        .{ .index = 20 },
        .{ .index = 30 },
    };
    const workspace: Workspace = .{ .visible = true, .slides = &summaries, .current_slide = 20 };
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    const layout = workspaceLayout(viewport);
    var studio: Studio = .{ .enabled = true };

    _ = studio.updateWithWorkspace(&items, &.{}, viewport, workspace, .{
        .pointer_screen = rectangleCenter(layout.organizer_actions[1]),
        .pointer_pressed = true,
    });
    switch (studio.takeSemanticCommand().?) {
        .duplicate_slide => |index| try std.testing.expectEqual(@as(usize, 20), index),
        else => return error.UnexpectedSemanticCommand,
    }

    _ = studio.updateWithWorkspace(&items, &.{}, viewport, workspace, .{
        .pointer_screen = rectangleCenter(layout.organizer_actions[3]),
        .pointer_pressed = true,
    });
    switch (studio.takeSemanticCommand().?) {
        .move_slide => |command| {
            try std.testing.expectEqual(@as(usize, 20), command.slide_index);
            try std.testing.expectEqual(SlideMoveDirection.up, command.direction);
        },
        else => return error.UnexpectedSemanticCommand,
    }

    _ = studio.updateWithWorkspace(&items, &.{}, viewport, workspace, .{
        .pointer_screen = rectangleCenter(layout.organizer_actions[2]),
        .pointer_pressed = true,
    });
    switch (studio.takeSemanticCommand().?) {
        .delete_slide => |index| try std.testing.expectEqual(@as(usize, 20), index),
        else => return error.UnexpectedSemanticCommand,
    }
}

test "organizer paging and wheel scrolling expose later summaries" {
    var items: [0]slides.SlideItem = .{};
    var summaries: [18]SlideSummary = undefined;
    for (&summaries, 0..) |*summary, index| summary.* = .{ .index = index };
    const workspace: Workspace = .{ .visible = true, .slides = &summaries, .current_slide = 0 };
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    const layout = workspaceLayout(viewport);
    var studio: Studio = .{ .enabled = true };

    _ = studio.updateWithWorkspace(&items, &.{}, viewport, workspace, .{
        .pointer_screen = rectangleCenter(layout.slide_page_next),
        .pointer_pressed = true,
    });
    const page_start = studio.organizer_first_visible;
    try std.testing.expect(page_start > 0);
    const preview = studio.visibleSlidePreview(viewport, workspace, 0).?;
    try std.testing.expectEqual(page_start, preview.summary_index);
    try std.testing.expectEqual(page_start, preview.slide_index);

    _ = studio.updateWithWorkspace(&items, &.{}, viewport, workspace, .{
        .pointer_screen = rectangleCenter(layout.organizer),
        .workspace_scroll = 1,
    });
    try std.testing.expectEqual(page_start - 1, studio.organizer_first_visible);
}

test "library item selects a named placement while slide template creates directly" {
    var items: [0]slides.SlideItem = .{};
    const summaries = [_]SlideSummary{.{ .index = 0 }};
    const entries = [_]LibraryEntry{
        .{ .kind = .element, .name = "page_number" },
        .{ .kind = .slide_template, .name = "chapter" },
    };
    const workspace: Workspace = .{ .visible = true, .slides = &summaries, .current_slide = 0, .library = &entries };
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    const layout = workspaceLayout(viewport);
    var studio: Studio = .{ .enabled = true };

    _ = studio.updateWithWorkspace(&items, &.{}, viewport, workspace, .{
        .pointer_screen = rectangleCenter(libraryRowRect(layout, 0).?),
        .pointer_pressed = true,
    });
    try std.testing.expectEqual(Tool.add_reusable, studio.tool);
    try std.testing.expectEqual(@as(?usize, 0), studio.selected_library_index);
    try std.testing.expect(studio.takeSemanticCommand() == null);

    _ = studio.updateWithWorkspace(&items, &.{}, viewport, workspace, .{
        .pointer_screen = .{ .x = 850, .y = 500 },
        .pointer_pressed = true,
    });
    switch (studio.takeSemanticCommand().?) {
        .add_reusable => |command| {
            try std.testing.expectEqual(@as(?usize, 0), command.library_entry_index);
            try expectVector(.{ .x = 850, .y = 500 }, command.position);
        },
        else => return error.UnexpectedSemanticCommand,
    }

    _ = studio.updateWithWorkspace(&items, &.{}, viewport, workspace, .{
        .pointer_screen = rectangleCenter(libraryRowRect(layout, 1).?),
        .pointer_pressed = true,
    });
    switch (studio.takeSemanticCommand().?) {
        .new_slide_from_template => |entry_index| try std.testing.expectEqual(@as(usize, 1), entry_index),
        else => return error.UnexpectedSemanticCommand,
    }
}

test "library selection cannot drift across slides or source rewrites" {
    var items = [_]slides.SlideItem{};
    const summaries = [_]SlideSummary{ .{ .index = 0 }, .{ .index = 1 } };
    const entries = [_]LibraryEntry{.{ .kind = .element, .name = "card" }};
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    var studio: Studio = .{
        .enabled = true,
        .tool = .add_reusable,
        .selected_library_index = 0,
        .last_workspace_slide = 0,
    };

    _ = studio.updateWithWorkspace(&items, &.{}, viewport, .{
        .visible = true,
        .slides = &summaries,
        .current_slide = 1,
        .library = &entries,
    }, .{});
    try std.testing.expectEqual(@as(?usize, null), studio.selected_library_index);
    try std.testing.expectEqual(Tool.select, studio.tool);

    studio.selected_library_index = 0;
    studio.markSourceChanged();
    try std.testing.expectEqual(@as(?usize, null), studio.selected_library_index);
}

test "workspace keyboard navigation and reorder do not nudge canvas items" {
    var items = [_]slides.SlideItem{testItem(121, .textbox, 100, 100, 200, 80)};
    const summaries = [_]SlideSummary{ .{ .index = 1 }, .{ .index = 2 }, .{ .index = 3 } };
    const workspace: Workspace = .{ .visible = true, .slides = &summaries, .current_slide = 2 };
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    var studio: Studio = .{ .enabled = true, .selected_identity = 121 };

    _ = studio.updateWithWorkspace(&items, &.{}, viewport, workspace, .{ .select_slide_delta = 1 });
    switch (studio.takeSemanticCommand().?) {
        .select_slide => |index| try std.testing.expectEqual(@as(usize, 3), index),
        else => return error.UnexpectedSemanticCommand,
    }
    try expectVector(.{ .x = 100, .y = 100 }, items[0].position);

    studio.selected_identity = 121;
    _ = studio.updateWithWorkspace(&items, &.{}, viewport, workspace, .{ .move_slide = -1 });
    switch (studio.takeSemanticCommand().?) {
        .move_slide => |command| try std.testing.expectEqual(SlideMoveDirection.up, command.direction),
        else => return error.UnexpectedSemanticCommand,
    }
    try expectVector(.{ .x = 100, .y = 100 }, items[0].position);
}

fn rectangleCenter(rect: rl.Rectangle) rl.Vector2 {
    return .{ .x = rect.x + rect.width / 2, .y = rect.y + rect.height / 2 };
}
