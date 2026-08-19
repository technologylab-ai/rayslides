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
pub const default_snap_threshold_screen: f32 = 8;
pub const default_grid_spacing: f32 = 20;
pub const max_selection_items: usize = 64;

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

/// Logical slide coordinates for the currently active smart-alignment guides.
/// A null axis means no edge/center target captured within the snap threshold.
pub const SnapGuides = struct {
    vertical: ?f32 = null,
    horizontal: ?f32 = null,
};

pub const SnapResult = struct {
    geometry: Geometry,
    guides: SnapGuides = .{},
};

pub const AlignAction = enum {
    left,
    horizontal_center,
    right,
    top,
    vertical_center,
    bottom,
};

pub const DistributionAction = enum {
    horizontal,
    vertical,
};

/// Describes where an emitted edit should be applied. This is deliberately
/// separate from `SourceRef.scope`: an item cloned from a slide template keeps
/// the template directive as its source, while an ordinary Studio edit should
/// usually create or update an override beside the current `@popslide`.
pub const EditScope = enum {
    direct,
    local_instance,
    shared_template,
};

/// A complete, allocation-free description of one undoable source edit.
pub const GeometryCommand = struct {
    item_identity: usize,
    source: slides.SourceRef,
    edit_scope: EditScope = .direct,
    before_position: rl.Vector2,
    before_size: rl.Vector2,
    after_position: rl.Vector2,
    after_size: rl.Vector2,
    /// Optional geometry to persist when the displayed item is a customized
    /// slide-template instance but Alt targets the shared definition. Keeping
    /// this separate preserves effective-value previews while preventing an
    /// instance override from being baked into the shared source.
    source_after_position: ?rl.Vector2 = null,
    source_after_size: ?rl.Vector2 = null,
    /// False for both pointer moves and keyboard nudges.
    resized: bool,
};

/// One atomic multi-item geometry edit. Only `commands[0..count]` is valid.
/// The fixed storage keeps Studio allocation-free and makes ownership across
/// the update/integration boundary explicit.
pub const GeometryBatchCommand = struct {
    commands: [max_selection_items]GeometryCommand = undefined,
    count: usize = 0,

    pub fn slice(self: *const GeometryBatchCommand) []const GeometryCommand {
        return self.commands[0..self.count];
    }
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

fn isConcreteVisibleItem(item: slides.SlideItem, resolved_bounds: []const ResolvedBounds) bool {
    const geometry = itemGeometry(item, resolved_bounds);
    return item.kind != .background and item.visible and item.opacity > 0 and
        geometry.size.x > 0 and geometry.size.y > 0;
}

fn isSelectable(item: slides.SlideItem, resolved_bounds: []const ResolvedBounds) bool {
    return !item.locked and isConcreteVisibleItem(item, resolved_bounds);
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

const AxisSnap = struct {
    target: ?f32 = null,
    adjustment: f32 = 0,
    distance: f32 = std.math.inf(f32),
};

fn considerAxisSnap(best: *AxisSnap, anchor: f32, target: f32, threshold: f32) void {
    const adjustment = target - anchor;
    const distance = @abs(adjustment);
    if (distance <= threshold and distance < best.distance) {
        best.* = .{ .target = target, .adjustment = adjustment, .distance = distance };
    }
}

fn considerGeometryTargets(
    x_snap: *AxisSnap,
    y_snap: *AxisSnap,
    interaction: Interaction,
    candidate: Geometry,
    target: Geometry,
    threshold: rl.Vector2,
    minimum_size: f32,
    aspect_ratio: ?f32,
) void {
    const target_x = [_]f32{ target.position.x, target.position.x + target.size.x / 2, target.position.x + target.size.x };
    const target_y = [_]f32{ target.position.y, target.position.y + target.size.y / 2, target.position.y + target.size.y };
    switch (interaction) {
        .moving => {
            const anchors_x = [_]f32{ candidate.position.x, candidate.position.x + candidate.size.x / 2, candidate.position.x + candidate.size.x };
            const anchors_y = [_]f32{ candidate.position.y, candidate.position.y + candidate.size.y / 2, candidate.position.y + candidate.size.y };
            for (target_x) |target_value| for (anchors_x) |anchor| considerAxisSnap(x_snap, anchor, target_value, threshold.x);
            for (target_y) |target_value| for (anchors_y) |anchor| considerAxisSnap(y_snap, anchor, target_value, threshold.y);
        },
        .resizing => {
            const right = candidate.position.x + candidate.size.x;
            const bottom = candidate.position.y + candidate.size.y;
            for (target_x) |target_value| {
                const width = target_value - candidate.position.x;
                const ratio_ok = if (aspect_ratio) |ratio| ratio <= 0 or width / ratio >= minimum_size else true;
                if (width >= minimum_size and ratio_ok)
                    considerAxisSnap(x_snap, right, target_value, threshold.x);
            }
            for (target_y) |target_value| {
                const height = target_value - candidate.position.y;
                const ratio_ok = if (aspect_ratio) |ratio| ratio <= 0 or height * ratio >= minimum_size else true;
                if (height >= minimum_size and ratio_ok)
                    considerAxisSnap(y_snap, bottom, target_value, threshold.y);
            }
        },
        .idle => {},
    }
}

fn nearestGrid(value: f32, spacing: f32) f32 {
    if (spacing <= 0) return value;
    return @round(value / spacing) * spacing;
}

/// Snap one candidate geometry against the slide and all other selectable
/// items. Thresholds are logical-axis distances, normally converted from a
/// constant screen-pixel tolerance by the caller.
pub fn snapGeometry(
    candidate: Geometry,
    interaction: Interaction,
    logical_size: rl.Vector2,
    threshold: rl.Vector2,
    grid_enabled: bool,
    grid_spacing: f32,
    minimum_size: f32,
    aspect_ratio: ?f32,
    include_item_targets: bool,
    selected_identity: usize,
    items: []const slides.SlideItem,
    resolved_bounds: []const ResolvedBounds,
) SnapResult {
    const excluded = [_]usize{selected_identity};
    return snapGeometryExcluding(
        candidate,
        interaction,
        logical_size,
        threshold,
        grid_enabled,
        grid_spacing,
        minimum_size,
        aspect_ratio,
        include_item_targets,
        &excluded,
        items,
        resolved_bounds,
    );
}

fn snapGeometryExcluding(
    candidate: Geometry,
    interaction: Interaction,
    logical_size: rl.Vector2,
    threshold: rl.Vector2,
    grid_enabled: bool,
    grid_spacing: f32,
    minimum_size: f32,
    aspect_ratio: ?f32,
    include_item_targets: bool,
    excluded_identities: []const usize,
    items: []const slides.SlideItem,
    resolved_bounds: []const ResolvedBounds,
) SnapResult {
    if (interaction == .idle) return .{ .geometry = candidate };
    const valid_aspect_ratio = if (aspect_ratio) |value|
        if (value > 0 and std.math.isFinite(value)) value else null
    else
        null;

    var x_snap = AxisSnap{};
    var y_snap = AxisSnap{};
    considerGeometryTargets(
        &x_snap,
        &y_snap,
        interaction,
        candidate,
        .{ .position = .zero(), .size = logical_size },
        threshold,
        minimum_size,
        valid_aspect_ratio,
    );
    if (include_item_targets) {
        for (items) |item| {
            var excluded = false;
            for (excluded_identities) |identity| {
                if (item.identity == identity) {
                    excluded = true;
                    break;
                }
            }
            if (excluded or !isSelectable(item, resolved_bounds)) continue;
            considerGeometryTargets(
                &x_snap,
                &y_snap,
                interaction,
                candidate,
                itemGeometry(item, resolved_bounds),
                threshold,
                minimum_size,
                valid_aspect_ratio,
            );
        }
    }

    var result = SnapResult{ .geometry = candidate };
    switch (interaction) {
        .moving => {
            if (x_snap.target) |target| {
                result.geometry.position.x += x_snap.adjustment;
                result.guides.vertical = target;
            } else if (grid_enabled) {
                result.geometry.position.x = nearestGrid(result.geometry.position.x, grid_spacing);
            }
            if (y_snap.target) |target| {
                result.geometry.position.y += y_snap.adjustment;
                result.guides.horizontal = target;
            } else if (grid_enabled) {
                result.geometry.position.y = nearestGrid(result.geometry.position.y, grid_spacing);
            }
        },
        .resizing => {
            if (valid_aspect_ratio) |locked_ratio| {
                const normalized_x = if (x_snap.target != null) x_snap.distance / @max(threshold.x, 0.0001) else std.math.inf(f32);
                const normalized_y = if (y_snap.target != null) y_snap.distance / @max(threshold.y, 0.0001) else std.math.inf(f32);
                const prefer_x = normalized_x <= normalized_y;
                var snapped = false;
                var attempt: usize = 0;
                while (attempt < 2 and !snapped) : (attempt += 1) {
                    const use_x = if (attempt == 0) prefer_x else !prefer_x;
                    if (use_x) {
                        if (x_snap.target) |target| {
                            const width = target - candidate.position.x;
                            if (width >= minimum_size and width / locked_ratio >= minimum_size) {
                                result.geometry.size = .{ .x = width, .y = width / locked_ratio };
                                result.guides.vertical = target;
                                snapped = true;
                            }
                        }
                    } else if (y_snap.target) |target| {
                        const height = target - candidate.position.y;
                        if (height >= minimum_size and height * locked_ratio >= minimum_size) {
                            result.geometry.size = .{ .x = height * locked_ratio, .y = height };
                            result.guides.horizontal = target;
                            snapped = true;
                        }
                    }
                }
                if (!snapped and grid_enabled) {
                    const right = candidate.position.x + candidate.size.x;
                    const bottom = candidate.position.y + candidate.size.y;
                    const grid_right = nearestGrid(right, grid_spacing);
                    const grid_bottom = nearestGrid(bottom, grid_spacing);
                    const x_distance = @abs(grid_right - right);
                    const y_distance = @abs(grid_bottom - bottom);
                    const prefer_grid_x = x_distance <= y_distance;
                    attempt = 0;
                    while (attempt < 2 and !snapped) : (attempt += 1) {
                        if ((attempt == 0) == prefer_grid_x) {
                            const width = grid_right - candidate.position.x;
                            if (width >= minimum_size and width / locked_ratio >= minimum_size) {
                                result.geometry.size = .{ .x = width, .y = width / locked_ratio };
                                snapped = true;
                            }
                        } else {
                            const height = grid_bottom - candidate.position.y;
                            if (height >= minimum_size and height * locked_ratio >= minimum_size) {
                                result.geometry.size = .{ .x = height * locked_ratio, .y = height };
                                snapped = true;
                            }
                        }
                    }
                }
            } else {
                if (x_snap.target) |target| {
                    const width = target - candidate.position.x;
                    if (width >= minimum_size) {
                        result.geometry.size.x = width;
                        result.guides.vertical = target;
                    }
                } else if (grid_enabled) {
                    result.geometry.size.x = @max(minimum_size, nearestGrid(candidate.position.x + candidate.size.x, grid_spacing) - candidate.position.x);
                }
                if (y_snap.target) |target| {
                    const height = target - candidate.position.y;
                    if (height >= minimum_size) {
                        result.geometry.size.y = height;
                        result.guides.horizontal = target;
                    }
                } else if (grid_enabled) {
                    result.geometry.size.y = @max(minimum_size, nearestGrid(candidate.position.y + candidate.size.y, grid_spacing) - candidate.position.y);
                }
            }
        },
        .idle => {},
    }
    return result;
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

fn itemIndexByUniqueSource(items: []const slides.SlideItem, source: slides.SourceRef) ?usize {
    var match: ?usize = null;
    for (items, 0..) |item, index| {
        if (!sourceEqual(item.source, source)) continue;
        if (match != null) return null;
        match = index;
    }
    return match;
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
        .slide_instance_override => "local template override",
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
    shared_template_customized,
    shared_template_auto_size,
    local_override_needs_unique_id,
    duplicate_item_unsupported,
    multi_selection_property_unsupported,
    selection_capacity_reached,
    distribution_needs_three,
    generated_source_read_only,
    property_unavailable,
    base_scene_only,
    structural_source_locked,
    layer_selection_unsupported,
    copy_selection_unsupported,
    clipboard_empty,
    locked_item,
    library_name_conflict,
    library_entry_in_use,
    library_delete_unsupported,
    slide_template_promotion_locked,
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
    edit_scope: EditScope = .direct,
};

pub const LayerAction = enum {
    back,
    down,
    up,
    front,
};

pub const LayerCommand = struct {
    targets: [max_selection_items]CommandTarget = undefined,
    count: usize = 0,
    action: LayerAction,

    pub fn slice(self: *const LayerCommand) []const CommandTarget {
        return self.targets[0..self.count];
    }
};

pub const CopyItemsCommand = struct {
    targets: [max_selection_items]CommandTarget = undefined,
    count: usize = 0,

    pub fn slice(self: *const CopyItemsCommand) []const CommandTarget {
        return self.targets[0..self.count];
    }
};

pub const PasteItemsCommand = struct {
    offset: rl.Vector2 = .{ .x = 20, .y = 20 },
};

pub const SetLockedCommand = struct {
    targets: [max_selection_items]CommandTarget = undefined,
    count: usize = 0,
    locked: bool,

    pub fn slice(self: *const SetLockedCommand) []const CommandTarget {
        return self.targets[0..self.count];
    }
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
    use_count: usize = 0,
    deletable: bool = false,
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
    duplicate_item: CommandTarget,
    delete_item: CommandTarget,
    edit_text: CommandTarget,
    set_foreground: ColorCommand,
    set_background: ColorCommand,
    /// Removes an item's authored fill (`bg=none`). This remains a distinct
    /// intention so integrations never have to overload a palette color.
    clear_background: CommandTarget,
    reorder_items: LayerCommand,
    copy_items: CopyItemsCommand,
    paste_items: PasteItemsCommand,
    set_locked: SetLockedCommand,
    promote_to_reusable: CommandTarget,
    select_morph_scene: MorphSceneCommand,
    new_slide: void,
    select_slide: usize,
    duplicate_slide: usize,
    delete_slide: usize,
    move_slide: SlideMoveCommand,
    /// Promotes the indexed authored slide to a reusable `@pushslide`
    /// definition. The integration layer chooses and validates its name.
    promote_slide_to_template: usize,
    /// Creates a new slide using the indexed `slide_template` library entry.
    new_slide_from_template: usize,
    /// Renames the indexed source definition. The integration layer prompts
    /// for and validates the new name before applying the source edit.
    rename_library_entry: usize,
    /// Requests safe deletion of the indexed source definition. The source
    /// layer remains responsible for rejecting live or unsafe uses.
    delete_library_entry: usize,
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
    grid_toggle: rl.Rectangle,
    scene_previous: rl.Rectangle,
    scene_label: rl.Rectangle,
    scene_next: rl.Rectangle,
    properties: rl.Rectangle,
    edit_text: rl.Rectangle,
    duplicate_item: rl.Rectangle,
    delete_item: rl.Rectangle,
    promote: rl.Rectangle,
    foreground_swatches: [palette.len]rl.Rectangle,
    background_swatches: [palette.len]rl.Rectangle,
    clear_background: rl.Rectangle,
    align_buttons: [6]rl.Rectangle,
    distribute_buttons: [2]rl.Rectangle,
    layer_buttons: [4]rl.Rectangle,
    lock_item: rl.Rectangle,
};

pub const organizer_action_count = 6;
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
    library_use: rl.Rectangle,
    library_rename: rl.Rectangle,
    library_delete: rl.Rectangle,
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
    const library_action_gap: f32 = 4;
    const library_action_width: f32 = 40;
    const library_delete: rl.Rectangle = .{
        .x = library.x + library.width - 12 - library_action_width,
        .y = library.y + 5,
        .width = library_action_width,
        .height = 26,
    };
    const library_rename: rl.Rectangle = .{
        .x = library_delete.x - library_action_gap - library_action_width,
        .y = library_delete.y,
        .width = library_action_width,
        .height = library_delete.height,
    };
    const library_use: rl.Rectangle = .{
        .x = library_rename.x - library_action_gap - library_action_width,
        .y = library_delete.y,
        .width = library_action_width,
        .height = library_delete.height,
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
        .y = library.y + 40,
        .width = library.width - 16,
        .height = @max(0, library_pager_y - 5 - (library.y + 40)),
    };
    return .{
        .sidebar = sidebar,
        .organizer = organizer,
        .organizer_actions = organizer_actions,
        .slide_cards_clip = slide_cards_clip,
        .slide_page_previous = slide_page_previous,
        .slide_page_next = slide_page_next,
        .library = library,
        .library_use = library_use,
        .library_rename = library_rename,
        .library_delete = library_delete,
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
    const grid_width: f32 = 58;
    const scene_width: f32 = 132;
    const toolbar_width = margin * 2 + tool_size * 6 + gap * 5 + gap + new_slide_width + gap + grid_width + gap + scene_width;
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
    const grid_toggle: rl.Rectangle = .{
        .x = new_slide.x + new_slide.width + gap,
        .y = new_slide.y,
        .width = grid_width,
        .height = tool_size,
    };
    const scene_previous: rl.Rectangle = .{
        .x = grid_toggle.x + grid_toggle.width + gap,
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
        .height = 400,
    };
    const action_y = properties.y + 38;
    const action_gap: f32 = 4;
    const action_width: f32 = 54;
    const edit_text: rl.Rectangle = .{ .x = properties.x + 12, .y = action_y, .width = action_width, .height = 30 };
    const duplicate_item: rl.Rectangle = .{ .x = edit_text.x + action_width + action_gap, .y = action_y, .width = action_width, .height = 30 };
    const delete_item: rl.Rectangle = .{ .x = duplicate_item.x + action_width + action_gap, .y = action_y, .width = action_width, .height = 30 };
    const promote: rl.Rectangle = .{ .x = delete_item.x + action_width + action_gap, .y = action_y, .width = action_width, .height = 30 };

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
    const clear_background: rl.Rectangle = .{
        .x = properties.x + properties.width - 66,
        .y = properties.y + 140,
        .width = 54,
        .height = 22,
    };
    var align_buttons: [6]rl.Rectangle = undefined;
    const align_gap: f32 = 4;
    const align_width = (properties.width - 24 - align_gap * 5) / 6;
    for (&align_buttons, 0..) |*button, index| button.* = .{
        .x = properties.x + 12 + @as(f32, @floatFromInt(index)) * (align_width + align_gap),
        .y = properties.y + 232,
        .width = align_width,
        .height = 28,
    };
    const distribute_y = properties.y + 284;
    const distribute_gap: f32 = 6;
    const distribute_width = (properties.width - 24 - distribute_gap) / 2;
    const distribute_buttons = [2]rl.Rectangle{
        .{ .x = properties.x + 12, .y = distribute_y, .width = distribute_width, .height = 28 },
        .{ .x = properties.x + 12 + distribute_width + distribute_gap, .y = distribute_y, .width = distribute_width, .height = 28 },
    };
    var layer_buttons: [4]rl.Rectangle = undefined;
    const layer_y = properties.y + 354;
    const layer_width: f32 = 40;
    const layer_gap: f32 = 4;
    for (&layer_buttons, 0..) |*button, index| button.* = .{
        .x = properties.x + 12 + @as(f32, @floatFromInt(index)) * (layer_width + layer_gap),
        .y = layer_y,
        .width = layer_width,
        .height = 28,
    };
    const lock_item: rl.Rectangle = .{
        .x = properties.x + properties.width - 72,
        .y = layer_y,
        .width = 60,
        .height = 28,
    };
    return .{
        .toolbar = toolbar,
        .tool_buttons = tool_buttons,
        .new_slide = new_slide,
        .grid_toggle = grid_toggle,
        .scene_previous = scene_previous,
        .scene_label = scene_label,
        .scene_next = scene_next,
        .properties = properties,
        .edit_text = edit_text,
        .duplicate_item = duplicate_item,
        .delete_item = delete_item,
        .promote = promote,
        .foreground_swatches = foreground_swatches,
        .background_swatches = background_swatches,
        .clear_background = clear_background,
        .align_buttons = align_buttons,
        .distribute_buttons = distribute_buttons,
        .layer_buttons = layer_buttons,
        .lock_item = lock_item,
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
    toggle_grid_pressed: bool = false,
    lock_aspect_ratio: bool = false,
    disable_snapping: bool = false,
    align_action: ?AlignAction = null,
    distribute_action: ?DistributionAction = null,
    layer_action: ?LayerAction = null,
    copy_pressed: bool = false,
    paste_pressed: bool = false,
    toggle_lock_pressed: bool = false,
    toggle_selection: bool = false,
    select_all_pressed: bool = false,
    allow_shared_edit: bool = false,
    choose_tool: ?Tool = null,
    delete_pressed: bool = false,
    edit_text_pressed: bool = false,
    promote_pressed: bool = false,
    foreground_color: ?PaletteColor = null,
    background_color: ?PaletteColor = null,
    clear_background_pressed: bool = false,
    new_slide_pressed: bool = false,
    /// Negative selects the previous base/morph scene, positive the next.
    cycle_morph_scene: i8 = 0,
    /// Negative selects the previous slide, positive the next slide.
    select_slide_delta: i8 = 0,
    duplicate_slide_pressed: bool = false,
    delete_slide_pressed: bool = false,
    /// Negative moves the current slide up, positive moves it down.
    move_slide: i8 = 0,
    promote_slide_to_template_pressed: bool = false,
    /// Activates the selected library definition. Elements enter placement;
    /// slide templates create a slide.
    use_library_pressed: bool = false,
    rename_library_pressed: bool = false,
    delete_library_pressed: bool = false,
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
        if (keyPressedOrRepeated(.left)) nudge.x -= amount;
        if (keyPressedOrRepeated(.right)) nudge.x += amount;
        if (keyPressedOrRepeated(.up)) nudge.y -= amount;
        if (keyPressedOrRepeated(.down)) nudge.y += amount;
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
            .toggle_grid_pressed = !shortcut_modifier and rl.isKeyPressed(.g),
            .lock_aspect_ratio = shift,
            .disable_snapping = shortcut_modifier,
            .toggle_selection = shift,
            .select_all_pressed = shortcut_modifier and rl.isKeyPressed(.a),
            .layer_action = if (shortcut_modifier and rl.isKeyPressed(.left_bracket))
                if (shift) .back else .down
            else if (shortcut_modifier and rl.isKeyPressed(.right_bracket))
                if (shift) .front else .up
            else
                null,
            .copy_pressed = shortcut_modifier and rl.isKeyPressed(.c),
            .paste_pressed = shortcut_modifier and rl.isKeyPressed(.v),
            .toggle_lock_pressed = shortcut_modifier and rl.isKeyPressed(.l),
            .allow_shared_edit = alt,
            .choose_tool = choose_tool,
            .delete_pressed = !shortcut_modifier and rl.isKeyPressed(.backspace),
            .edit_text_pressed = rl.isKeyPressed(.enter),
            .promote_pressed = !shortcut_modifier and rl.isKeyPressed(.p),
            .new_slide_pressed = shortcut_modifier and rl.isKeyPressed(.n),
            .cycle_morph_scene = if (!shortcut_modifier and rl.isKeyPressed(.left_bracket))
                -1
            else if (!shortcut_modifier and rl.isKeyPressed(.right_bracket))
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
            .promote_slide_to_template_pressed = shortcut_modifier and shift and rl.isKeyPressed(.p),
            .use_library_pressed = rl.isKeyPressed(.enter),
            .rename_library_pressed = rl.isKeyPressed(.f2),
            .delete_library_pressed = shift and rl.isKeyPressed(.delete),
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
    source_before: Geometry = .{
        .position = .{ .x = 0, .y = 0 },
        .size = .{ .x = 0, .y = 0 },
    },
    source_after: Geometry = .{
        .position = .{ .x = 0, .y = 0 },
        .size = .{ .x = 0, .y = 0 },
    },
    separate_source_geometry: bool = false,
    edit_scope: EditScope = .direct,
};

const SelectionMember = struct {
    identity: usize,
    source: ?slides.SourceRef = null,
};

const GroupDragMember = struct {
    identity: usize,
    before: Geometry,
    authored_before: Geometry,
    source_before: Geometry,
    source_after: Geometry,
    separate_source_geometry: bool,
    after: Geometry,
    edit_scope: EditScope,
};

const SelectionGeometry = struct {
    identity: usize,
    item_index: usize,
    geometry: Geometry,
    authored_geometry: Geometry,
    source_geometry: Geometry,
    separate_source_geometry: bool,
    edit_scope: EditScope,
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
    additional_selection: [max_selection_items - 1]SelectionMember = undefined,
    additional_selection_count: usize = 0,
    interaction: Interaction = .idle,
    handle_size_screen: f32 = default_handle_size,
    min_item_size: f32 = default_min_item_size,
    snap_threshold_screen: f32 = default_snap_threshold_screen,
    grid_spacing: f32 = default_grid_spacing,
    grid_snapping: bool = false,
    snap_guides: SnapGuides = .{},
    drag: Drag = .{},
    preview: Geometry = .{
        .position = .{ .x = 0, .y = 0 },
        .size = .{ .x = 0, .y = 0 },
    },
    pending_semantic_command: ?SemanticCommand = null,
    pending_geometry_command: ?GeometryCommand = null,
    pending_geometry_batch: ?GeometryBatchCommand = null,
    group_drag: [max_selection_items]GroupDragMember = undefined,
    group_drag_count: usize = 0,
    group_bounds_before: Geometry = .{ .position = .zero(), .size = .zero() },
    group_bounds_after: Geometry = .{ .position = .zero(), .size = .zero() },
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
        self.snap_guides = .{};
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

    pub fn takeGeometryBatch(self: *Studio) ?GeometryBatchCommand {
        const command = self.pending_geometry_batch;
        self.pending_geometry_batch = null;
        return command;
    }

    pub fn peekGeometryBatch(self: Studio) ?GeometryBatchCommand {
        return self.pending_geometry_batch;
    }

    pub fn setTool(self: *Studio, tool: Tool, items: []slides.SlideItem) void {
        if (self.interaction != .idle) self.cancelInteraction(items);
        self.tool = tool;
        self.notice = .none;
    }

    pub fn setMorphStateCount(self: *Studio, count: usize) void {
        self.morph_state_count = count;
        if (self.active_morph_state) |state| {
            if (state >= count) {
                self.active_morph_state = null;
                self.clearSelectionState();
            }
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
        self.snap_guides = .{};
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
        self.snap_guides = .{};
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
            self.additional_selection_count = 0;
            self.group_drag_count = 0;
            self.selected_library_index = null;
            self.snap_guides = .{};
        }
    }

    pub fn disable(self: *Studio, items: []slides.SlideItem) void {
        if (self.interaction != .idle) self.cancelInteraction(items);
        self.enabled = false;
        self.tool = .select;
        self.active_morph_state = null;
        self.selected_identity = null;
        self.selected_source = null;
        self.additional_selection_count = 0;
        self.group_drag_count = 0;
        self.selected_library_index = null;
        self.snap_guides = .{};
    }

    pub fn clearSelection(self: *Studio, items: []slides.SlideItem) void {
        if (self.interaction != .idle) self.cancelInteraction(items);
        self.selected_identity = null;
        self.selected_source = null;
        self.additional_selection_count = 0;
        self.group_drag_count = 0;
        self.snap_guides = .{};
    }

    pub fn selectionCount(self: Studio) usize {
        return if (self.selected_identity == null) 0 else 1 + self.additional_selection_count;
    }

    /// Stable selection order: primary/last-clicked first, followed by the
    /// other members in the order they joined the selection.
    pub fn selectedIdentityAt(self: Studio, selection_index: usize) ?usize {
        if (selection_index >= self.selectionCount()) return null;
        if (selection_index == 0) return self.selected_identity;
        return self.additional_selection[selection_index - 1].identity;
    }

    pub fn isIdentitySelected(self: Studio, identity: usize) bool {
        if (self.selected_identity != null and self.selected_identity.? == identity) return true;
        for (self.additional_selection[0..self.additional_selection_count]) |member| {
            if (member.identity == identity) return true;
        }
        return false;
    }

    pub fn selectedIndex(self: Studio, items: []const slides.SlideItem) ?usize {
        const identity = self.selected_identity orelse return null;
        return itemIndexByIdentity(items, identity);
    }

    pub fn isItemLocked(_: Studio, item: slides.SlideItem) bool {
        return item.locked;
    }

    /// Rebinds Studio selection to the fresh IDs returned by a structural
    /// paste after its source rewrite/reparse has completed.
    pub fn selectItemsByIds(self: *Studio, items: []const slides.SlideItem, ids: []const []const u8) void {
        self.clearSelectionState();
        self.notice = .none;
        for (ids) |id| {
            if (self.selectionCount() >= max_selection_items) {
                self.notice = .selection_capacity_reached;
                break;
            }
            var match: ?usize = null;
            for (items, 0..) |item, index| {
                const item_id = item.id orelse continue;
                if (!std.mem.eql(u8, item_id, id)) continue;
                if (match != null) {
                    match = null;
                    break;
                }
                match = index;
            }
            const index = match orelse continue;
            // Structural rebinds may intentionally retain a freshly locked
            // selection for read-only copy and explicit unlock. Ordinary hit
            // testing/select-all still exclude locked items.
            if (items[index].kind == .background) continue;
            if (self.selected_identity == null) {
                self.setSingleSelection(items[index]);
            } else if (!self.isIdentitySelected(items[index].identity)) {
                self.additional_selection[self.additional_selection_count] = .{
                    .identity = items[index].identity,
                    .source = sourceForSelection(items[index]),
                };
                self.additional_selection_count += 1;
            }
        }
    }

    pub fn selectedGeometry(self: Studio, items: []const slides.SlideItem, resolved_bounds: []const ResolvedBounds) ?Geometry {
        const index = self.selectedIndex(items) orelse return null;
        if (self.interaction != .idle) return self.preview;
        return itemGeometry(items[index], resolved_bounds);
    }

    fn selectedBounds(self: Studio, items: []const slides.SlideItem, resolved_bounds: []const ResolvedBounds) ?Geometry {
        const count = self.selectionCount();
        if (count == 0) return null;
        var bounds: ?Geometry = null;
        for (0..count) |selection_index| {
            const identity = self.selectedIdentityAt(selection_index) orelse continue;
            const item_index = itemIndexByIdentity(items, identity) orelse continue;
            const geometry = itemGeometry(items[item_index], resolved_bounds);
            if (bounds) |*value| {
                const max_x = @max(value.position.x + value.size.x, geometry.position.x + geometry.size.x);
                const max_y = @max(value.position.y + value.size.y, geometry.position.y + geometry.size.y);
                value.position.x = @min(value.position.x, geometry.position.x);
                value.position.y = @min(value.position.y, geometry.position.y);
                value.size.x = max_x - value.position.x;
                value.size.y = max_y - value.position.y;
            } else {
                bounds = geometry;
            }
        }
        return bounds;
    }

    pub fn livePreview(self: Studio) ?LivePreview {
        return self.livePreviewAt(0);
    }

    pub fn livePreviewAt(self: Studio, selection_index: usize) ?LivePreview {
        if (!self.enabled or self.interaction == .idle) return null;
        if (self.group_drag_count > 1) {
            if (selection_index >= self.group_drag_count) return null;
            const member = self.group_drag[selection_index];
            return .{
                .item_identity = member.identity,
                .before = member.before,
                .after = member.after,
                .resized = false,
            };
        }
        if (selection_index != 0) return null;
        return .{
            .item_identity = self.selected_identity orelse return null,
            .before = self.drag.before,
            .after = self.preview,
            .resized = self.interaction == .resizing,
        };
    }

    pub fn liveSnapGuides(self: Studio) ?SnapGuides {
        if (!self.enabled or self.interaction == .idle) return null;
        return self.snap_guides;
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

    fn lockBadgeRect(viewport: Viewport, geometry: Geometry) ?rl.Rectangle {
        const rect = geometryToScreenRect(viewport, geometry) orelse return null;
        return .{
            .x = rect.x + 4,
            .y = rect.y + 4,
            .width = 48,
            .height = 20,
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

        if (input.paste_pressed) {
            if (self.interaction != .idle) self.cancelInteraction(items);
            self.tool = .select;
            self.notice = .none;
            self.pending_semantic_command = .{ .paste_items = .{} };
            return null;
        }
        if (input.copy_pressed) {
            _ = self.emitCopyItems(items);
            return null;
        }
        if (input.layer_action) |action| {
            _ = self.emitLayerCommand(items, action);
            return null;
        }
        if (input.toggle_lock_pressed) {
            _ = self.emitSelectedLockCommand(items, input.allow_shared_edit);
            return null;
        }

        if (input.select_all_pressed) {
            self.selectAll(items, resolved_bounds);
            return null;
        }

        if (input.toggle_grid_pressed) {
            self.grid_snapping = !self.grid_snapping;
            self.snap_guides = .{};
        }

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

        if (input.duplicate_slide_pressed and self.selected_identity != null) {
            _ = self.emitDuplicateItem(items, input.allow_shared_edit);
            return null;
        }
        if (input.align_action) |action| {
            return self.alignSelected(items, resolved_bounds, viewport.logical_size, action, input.allow_shared_edit);
        }
        if (input.distribute_action) |action| {
            self.distributeSelected(items, resolved_bounds, action, input.allow_shared_edit);
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
        if (input.clear_background_pressed) {
            _ = self.emitClearBackgroundCommand(items, input.allow_shared_edit);
            return null;
        }

        if (input.pointer_pressed and workspace.visible and
            self.handleWorkspaceClick(items, viewport, workspace, input.pointer_screen)) return null;
        if (input.pointer_pressed and self.handleUiClick(items, resolved_bounds, viewport, input.pointer_screen, input.allow_shared_edit)) {
            const command = self.pending_geometry_command;
            self.pending_geometry_command = null;
            return command;
        }
        if (input.pointer_pressed and self.handleLockedBadgeClick(
            items,
            resolved_bounds,
            viewport,
            input.pointer_screen,
            input.allow_shared_edit,
        )) return null;

        const pointer_logical = screenToLogical(viewport, input.pointer_screen);

        if (input.pointer_pressed and self.interaction == .idle and self.tool != .select) {
            if (viewport.containsScreenPoint(input.pointer_screen)) {
                if (pointer_logical) |pointer| self.emitAddCommand(pointer, workspace);
            }
            return null;
        }

        // The resize handle wins over Shift-click membership toggling so
        // Shift can retain its established aspect-lock meaning at gesture
        // start.
        if (input.pointer_pressed and self.interaction == .idle and self.selectionCount() == 1) {
            if (self.selectedGeometry(items, resolved_bounds)) |selected_geometry| {
                if (self.resizeHandleRect(viewport, selected_geometry)) |handle| {
                    if (pointInRectangle(input.pointer_screen, handle)) {
                        const selected_index = self.selectedIndex(items) orelse return null;
                        if (items[selected_index].locked) {
                            self.notice = .locked_item;
                            return null;
                        }
                        const edit_scope = self.editScopeForItem(items, selected_index, input.allow_shared_edit) orelse return null;
                        if (!sharedResizeSupported(items[selected_index], edit_scope)) {
                            self.notice = .shared_template_auto_size;
                            return null;
                        }
                        self.beginInteraction(
                            .resizing,
                            selected_geometry,
                            Geometry.fromItem(items[selected_index]),
                            sourceGeometryForEdit(items[selected_index], selected_geometry, edit_scope),
                            edit_scope == .shared_template and items[selected_index].instance_source != null,
                            pointer_logical orelse return null,
                            edit_scope,
                        );
                    }
                }
            }
        }

        if (input.pointer_pressed and self.interaction == .idle) {
            if (input.toggle_selection) {
                self.toggleSelectionAt(items, resolved_bounds, viewport, input.pointer_screen, pointer_logical);
                return null;
            }
            if (self.selectionCount() > 1) {
                const hit_index = if (viewport.containsScreenPoint(input.pointer_screen) and pointer_logical != null)
                    hitTest(items, resolved_bounds, pointer_logical.?)
                else
                    null;
                if (hit_index) |index| {
                    if (self.isIdentitySelected(items[index].identity)) {
                        self.makeSelectionPrimary(items[index].identity);
                        self.beginGroupMove(items, resolved_bounds, pointer_logical.?, input.allow_shared_edit);
                    } else {
                        self.selectAndBeginMove(items, resolved_bounds, viewport, input.pointer_screen, pointer_logical, input.allow_shared_edit);
                    }
                } else {
                    self.clearSelection(items);
                }
            } else if (self.selectedGeometry(items, resolved_bounds)) |selected_geometry| {
                if (self.resizeHandleRect(viewport, selected_geometry)) |handle| {
                    if (pointInRectangle(input.pointer_screen, handle)) {
                        const selected_index = self.selectedIndex(items) orelse return null;
                        if (items[selected_index].locked) {
                            self.notice = .locked_item;
                            return null;
                        }
                        const edit_scope = self.editScopeForItem(items, selected_index, input.allow_shared_edit) orelse return null;
                        if (!sharedResizeSupported(items[selected_index], edit_scope)) {
                            self.notice = .shared_template_auto_size;
                            return null;
                        }
                        self.beginInteraction(
                            .resizing,
                            selected_geometry,
                            Geometry.fromItem(items[selected_index]),
                            sourceGeometryForEdit(items[selected_index], selected_geometry, edit_scope),
                            edit_scope == .shared_template and items[selected_index].instance_source != null,
                            pointer_logical orelse return null,
                            edit_scope,
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
            if (pointer_logical) |pointer| {
                if (self.group_drag_count > 1)
                    self.applyGroupPointer(items, resolved_bounds, viewport, pointer, input.disable_snapping)
                else
                    self.applyPointer(
                        items,
                        resolved_bounds,
                        viewport,
                        pointer,
                        input.lock_aspect_ratio,
                        input.disable_snapping,
                    );
            }
        }

        if (self.interaction != .idle and input.pointer_released) {
            if (self.group_drag_count > 1) {
                self.finishGroupInteraction(items);
                return null;
            }
            return self.finishInteraction(items);
        }

        if (self.interaction == .idle and (input.nudge.x != 0 or input.nudge.y != 0)) {
            if (self.selectionCount() > 1) {
                self.applyGroupNudge(items, resolved_bounds, input.nudge, input.allow_shared_edit);
                return null;
            }
            const selected_index = self.selectedIndex(items) orelse return null;
            if (items[selected_index].locked) {
                self.notice = .locked_item;
                return null;
            }
            const edit_scope = self.editScopeForItem(items, selected_index, input.allow_shared_edit) orelse return null;
            return self.applyNudge(items, resolved_bounds, input.nudge, edit_scope);
        }

        return null;
    }

    fn selectedTarget(self: Studio, items: []const slides.SlideItem, edit_scope: EditScope) ?CommandTarget {
        const index = self.selectedIndex(items) orelse return null;
        return .{
            .item_identity = items[index].identity,
            .source = self.commandSource(items[index], edit_scope),
            .edit_scope = edit_scope,
        };
    }

    const TargetCommandKind = enum { delete_item, edit_text, promote_to_reusable };

    fn emitDuplicateItem(self: *Studio, items: []slides.SlideItem, allow_shared_edit: bool) bool {
        const index = self.selectedIndex(items) orelse return false;
        if (self.interaction != .idle) self.cancelInteraction(items);
        if (self.selectionCount() > 1) {
            self.notice = .multi_selection_property_unsupported;
            return true;
        }
        if (items[index].locked) {
            self.notice = .locked_item;
            return true;
        }
        const item = items[index];

        const edit_scope: EditScope = if (self.active_morph_state) |state_index| blk: {
            if (item.creation_morph_state == null or item.creation_morph_state.? != state_index or item.state_source != null) {
                self.notice = .duplicate_item_unsupported;
                return true;
            }
            break :blk self.editScopeForItem(items, index, false) orelse return true;
        } else switch (item.source.scope) {
            .direct, .component_instance => self.editScopeForItem(items, index, false) orelse return true,
            .slide_template => blk: {
                if (!allow_shared_edit) {
                    self.notice = .duplicate_item_unsupported;
                    return true;
                }
                const scope = self.editScopeForItem(items, index, true) orelse return true;
                if (scope != .shared_template) {
                    self.notice = .duplicate_item_unsupported;
                    return true;
                }
                break :blk scope;
            },
            else => {
                self.notice = .duplicate_item_unsupported;
                return true;
            },
        };

        self.pending_semantic_command = .{ .duplicate_item = self.selectedTarget(items, edit_scope) orelse return true };
        return true;
    }

    fn emitSelectedCommand(
        self: *Studio,
        items: []slides.SlideItem,
        allow_shared_edit: bool,
        kind: TargetCommandKind,
    ) bool {
        const index = self.selectedIndex(items) orelse return false;
        if (self.interaction != .idle) self.cancelInteraction(items);
        if (self.selectionCount() > 1) {
            self.notice = .multi_selection_property_unsupported;
            return true;
        }
        if (items[index].locked) {
            self.notice = .locked_item;
            return true;
        }
        const edit_scope = self.editScopeForItem(items, index, allow_shared_edit) orelse return true;
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
        const target = self.selectedTarget(items, edit_scope) orelse return true;
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
        if (self.selectionCount() > 1) {
            self.notice = .multi_selection_property_unsupported;
            return true;
        }
        if (items[index].locked) {
            self.notice = .locked_item;
            return true;
        }
        const edit_scope = self.editScopeForItem(items, index, allow_shared_edit) orelse return true;
        if (!background and items[index].kind != .textbox) {
            self.notice = .property_unavailable;
            return true;
        }
        if (background and self.active_morph_state != null) {
            self.notice = .base_scene_only;
            return true;
        }
        const command: ColorCommand = .{
            .target = self.selectedTarget(items, edit_scope) orelse return true,
            .color = color,
        };
        self.pending_semantic_command = if (background)
            .{ .set_background = command }
        else
            .{ .set_foreground = command };
        return true;
    }

    fn emitClearBackgroundCommand(
        self: *Studio,
        items: []slides.SlideItem,
        allow_shared_edit: bool,
    ) bool {
        const index = self.selectedIndex(items) orelse return false;
        if (self.interaction != .idle) self.cancelInteraction(items);
        if (self.selectionCount() > 1) {
            self.notice = .multi_selection_property_unsupported;
            return true;
        }
        if (items[index].locked) {
            self.notice = .locked_item;
            return true;
        }
        if (self.active_morph_state != null) {
            self.notice = .base_scene_only;
            return true;
        }
        const edit_scope = self.editScopeForItem(items, index, allow_shared_edit) orelse return true;
        self.pending_semantic_command = .{
            .clear_background = self.selectedTarget(items, edit_scope) orelse return true,
        };
        return true;
    }

    fn structuralTarget(
        self: *Studio,
        items: []const slides.SlideItem,
        item_index: usize,
        copy_only: bool,
    ) ?CommandTarget {
        const item = items[item_index];
        if ((!copy_only and item.locked) or item.kind == .crowd or item.kind == .background or !item.source.patchable) return null;
        if (itemIndexByUniqueSource(items, item.source) != item_index) return null;
        if (copy_only) {
            if (self.active_morph_state != null or item.source.scope != .direct) return null;
        } else if (self.active_morph_state) |state_index| {
            if (item.creation_morph_state == null or item.creation_morph_state.? != state_index or
                item.source.scope != .morph_item) return null;
        } else if (item.source.scope != .direct and item.source.scope != .component_instance) {
            return null;
        }
        return .{
            .item_identity = item.identity,
            .source = item.source,
            .edit_scope = .direct,
        };
    }

    fn emitLayerCommand(self: *Studio, items: []slides.SlideItem, action: LayerAction) bool {
        if (self.selectionCount() == 0) return false;
        if (self.interaction != .idle) self.cancelInteraction(items);
        var command = LayerCommand{ .action = action };
        // Paint order, rather than primary-selection order, preserves the
        // relative order of a multi-selection at its new layer destination.
        for (items, 0..) |item, item_index| {
            if (!self.isIdentitySelected(item.identity)) continue;
            const target = self.structuralTarget(items, item_index, false) orelse {
                self.notice = if (item.locked) .locked_item else .layer_selection_unsupported;
                return true;
            };
            command.targets[command.count] = target;
            command.count += 1;
        }
        if (command.count != self.selectionCount()) {
            self.notice = .layer_selection_unsupported;
            return true;
        }
        self.notice = .none;
        self.pending_semantic_command = .{ .reorder_items = command };
        return true;
    }

    fn emitCopyItems(self: *Studio, items: []slides.SlideItem) bool {
        if (self.selectionCount() == 0) return false;
        if (self.interaction != .idle) self.cancelInteraction(items);
        var command = CopyItemsCommand{};
        for (items, 0..) |item, item_index| {
            if (!self.isIdentitySelected(item.identity)) continue;
            const target = self.structuralTarget(items, item_index, true) orelse {
                self.notice = .copy_selection_unsupported;
                return true;
            };
            command.targets[command.count] = target;
            command.count += 1;
        }
        if (command.count != self.selectionCount()) {
            self.notice = .copy_selection_unsupported;
            return true;
        }
        self.notice = .none;
        self.pending_semantic_command = .{ .copy_items = command };
        return true;
    }

    fn emitSelectedLockCommand(
        self: *Studio,
        items: []slides.SlideItem,
        allow_shared_edit: bool,
    ) bool {
        if (self.selectionCount() == 0) return false;
        if (self.interaction != .idle) self.cancelInteraction(items);
        var all_locked = true;
        for (0..self.selectionCount()) |selection_index| {
            const identity = self.selectedIdentityAt(selection_index) orelse return true;
            const item_index = itemIndexByIdentity(items, identity) orelse return true;
            if (!items[item_index].locked) all_locked = false;
        }
        var command = SetLockedCommand{ .locked = !all_locked };
        for (items, 0..) |item, item_index| {
            if (!self.isIdentitySelected(item.identity)) continue;
            const edit_scope = self.editScopeForItem(items, item_index, allow_shared_edit) orelse return true;
            command.targets[command.count] = .{
                .item_identity = item.identity,
                .source = self.commandSource(item, edit_scope),
                .edit_scope = edit_scope,
            };
            command.count += 1;
        }
        if (command.count != self.selectionCount()) return true;
        self.pending_semantic_command = .{ .set_locked = command };
        return true;
    }

    fn handleLockedBadgeClick(
        self: *Studio,
        items: []slides.SlideItem,
        resolved_bounds: []const ResolvedBounds,
        viewport: Viewport,
        pointer: rl.Vector2,
        allow_shared_edit: bool,
    ) bool {
        if (!viewport.containsScreenPoint(pointer)) return false;
        var item_index = items.len;
        while (item_index > 0) {
            item_index -= 1;
            const item = items[item_index];
            if (!item.locked or !isConcreteVisibleItem(item, resolved_bounds)) continue;
            const badge = lockBadgeRect(viewport, itemGeometry(item, resolved_bounds)) orelse continue;
            if (!pointInRectangle(pointer, badge)) continue;
            const already_selected = self.selected_identity != null and self.selected_identity.? == item.identity and
                self.selectionCount() == 1;
            self.setSingleSelection(item);
            if (!already_selected) {
                self.notice = .locked_item;
                return true;
            }
            const edit_scope = self.editScopeForItem(items, item_index, allow_shared_edit) orelse return true;
            var command = SetLockedCommand{ .locked = false };
            command.targets[0] = .{
                .item_identity = item.identity,
                .source = self.commandSource(item, edit_scope),
                .edit_scope = edit_scope,
            };
            command.count = 1;
            self.pending_semantic_command = .{ .set_locked = command };
            return true;
        }
        return false;
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
            const changed_slide = self.last_workspace_slide != null;
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
            if (changed_slide) self.clearSelectionState() else self.snap_guides = .{};
            self.tool = .select;
        }

        const library_capacity = libraryRowCapacity(layout);
        self.library_first_visible = clampFirstVisible(
            self.library_first_visible,
            workspace.library.len,
            library_capacity,
        );
        if (self.selected_library_index) |index| {
            if (index >= workspace.library.len or !workspace.library[index].available) {
                self.selected_library_index = null;
            }
        }
    }

    fn handleWorkspaceKeyboard(self: *Studio, items: []slides.SlideItem, workspace: Workspace, input: FrameInput) bool {
        if (input.rename_library_pressed) {
            self.emitLibraryAction(items, workspace, .rename);
            return true;
        }
        if (input.delete_library_pressed) {
            self.emitLibraryAction(items, workspace, .delete);
            return true;
        }
        // Enter keeps its established edit-text meaning whenever a canvas
        // item is selected. With no canvas selection it becomes the natural
        // activation key for the persistent library selection.
        if (input.use_library_pressed and self.selected_identity == null and self.selected_library_index != null) {
            self.emitLibraryAction(items, workspace, .use);
            return true;
        }
        if (input.promote_slide_to_template_pressed) {
            if (summaryOffsetForSlide(workspace.slides, workspace.current_slide) != null) {
                self.prepareDeckCommand(items);
                self.pending_semantic_command = .{ .promote_slide_to_template = workspace.current_slide };
            }
            return true;
        }
        if (input.select_slide_delta != 0) {
            const current = summaryOffsetForSlide(workspace.slides, workspace.current_slide) orelse return true;
            const movement: isize = if (input.select_slide_delta < 0) -1 else 1;
            const desired: isize = @as(isize, @intCast(current)) + movement;
            if (desired >= 0 and desired < @as(isize, @intCast(workspace.slides.len))) {
                self.emitSlideSelection(items, workspace.slides[@intCast(desired)].index);
            }
            return true;
        }
        if (input.duplicate_slide_pressed and self.selected_identity == null) {
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
        if (input.move_slide != 0 and self.selected_identity == null) {
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
                    5 => if (summaryOffsetForSlide(workspace.slides, workspace.current_slide) != null) {
                        self.prepareDeckCommand(items);
                        self.pending_semantic_command = .{ .promote_slide_to_template = workspace.current_slide };
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

        if (pointInRectangle(pointer, layout.library_use)) {
            self.emitLibraryAction(items, workspace, .use);
            return true;
        }
        if (pointInRectangle(pointer, layout.library_rename)) {
            self.emitLibraryAction(items, workspace, .rename);
            return true;
        }
        if (pointInRectangle(pointer, layout.library_delete)) {
            self.emitLibraryAction(items, workspace, .delete);
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
            self.selected_library_index = entry_index;
            self.tool = .select;
            self.notice = .none;
            return true;
        }
        // Empty sidebar space is an input shield, never a canvas click.
        return true;
    }

    const LibraryAction = enum { use, rename, delete };

    fn emitLibraryAction(
        self: *Studio,
        items: []slides.SlideItem,
        workspace: Workspace,
        action: LibraryAction,
    ) void {
        const entry_index = self.selected_library_index orelse {
            self.notice = .property_unavailable;
            return;
        };
        if (entry_index >= workspace.library.len or !workspace.library[entry_index].available) {
            self.selected_library_index = null;
            self.tool = .select;
            self.notice = .property_unavailable;
            return;
        }
        const entry = workspace.library[entry_index];
        if (self.interaction != .idle) self.cancelInteraction(items);
        self.clearSelection(items);
        self.notice = .none;
        switch (action) {
            .use => switch (entry.kind) {
                .element => self.tool = .add_reusable,
                .slide_template => {
                    self.tool = .select;
                    self.active_morph_state = null;
                    self.pending_semantic_command = .{ .new_slide_from_template = entry_index };
                },
            },
            .rename => {
                self.tool = .select;
                self.pending_semantic_command = .{ .rename_library_entry = entry_index };
            },
            .delete => {
                self.tool = .select;
                if (!entry.deletable) {
                    self.notice = if (entry.kind == .slide_template)
                        .library_delete_unsupported
                    else
                        .library_entry_in_use;
                } else {
                    self.pending_semantic_command = .{ .delete_library_entry = entry_index };
                }
            },
        }
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
        resolved_bounds: []const ResolvedBounds,
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
            if (pointInRectangle(pointer, layout.grid_toggle)) {
                self.grid_snapping = !self.grid_snapping;
                self.snap_guides = .{};
            }
            if (pointInRectangle(pointer, layout.scene_previous)) self.cycleMorphState(items, -1);
            if (pointInRectangle(pointer, layout.scene_label) or pointInRectangle(pointer, layout.scene_next)) {
                self.cycleMorphState(items, 1);
            }
            return true;
        }
        if (pointInRectangle(pointer, layout.edit_text))
            return self.emitSelectedCommand(items, allow_shared_edit, .edit_text);
        if (pointInRectangle(pointer, layout.duplicate_item))
            return self.emitDuplicateItem(items, allow_shared_edit);
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
        if (pointInRectangle(pointer, layout.clear_background))
            return self.emitClearBackgroundCommand(items, allow_shared_edit);
        for (layout.align_buttons, 0..) |button, index| {
            if (pointInRectangle(pointer, button)) {
                self.pending_geometry_command = self.alignSelected(
                    items,
                    resolved_bounds,
                    viewport.logical_size,
                    @enumFromInt(index),
                    allow_shared_edit,
                );
                return true;
            }
        }
        for (layout.distribute_buttons, 0..) |button, index| {
            if (pointInRectangle(pointer, button)) {
                self.distributeSelected(
                    items,
                    resolved_bounds,
                    @enumFromInt(index),
                    allow_shared_edit,
                );
                return true;
            }
        }
        for (layout.layer_buttons, 0..) |button, index| {
            if (pointInRectangle(pointer, button))
                return self.emitLayerCommand(items, @enumFromInt(index));
        }
        if (pointInRectangle(pointer, layout.lock_item))
            return self.emitSelectedLockCommand(items, allow_shared_edit);
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

    fn sourceForSelection(item: slides.SlideItem) ?slides.SourceRef {
        return if (item.source.scope == .none) null else item.source;
    }

    fn setSingleSelection(self: *Studio, item: slides.SlideItem) void {
        self.selected_identity = item.identity;
        self.selected_source = sourceForSelection(item);
        self.additional_selection_count = 0;
        self.group_drag_count = 0;
        self.snap_guides = .{};
    }

    fn clearSelectionState(self: *Studio) void {
        self.interaction = .idle;
        self.selected_identity = null;
        self.selected_source = null;
        self.additional_selection_count = 0;
        self.group_drag_count = 0;
        self.snap_guides = .{};
    }

    fn removeAdditionalSelection(self: *Studio, member_index: usize) void {
        if (member_index >= self.additional_selection_count) return;
        var index = member_index;
        while (index + 1 < self.additional_selection_count) : (index += 1) {
            self.additional_selection[index] = self.additional_selection[index + 1];
        }
        self.additional_selection_count -= 1;
    }

    fn makeSelectionPrimary(self: *Studio, identity: usize) void {
        if (self.selected_identity == null or self.selected_identity.? == identity) return;
        for (self.additional_selection[0..self.additional_selection_count], 0..) |member, member_index| {
            if (member.identity != identity) continue;
            self.additional_selection[member_index] = .{
                .identity = self.selected_identity.?,
                .source = self.selected_source,
            };
            self.selected_identity = member.identity;
            self.selected_source = member.source;
            return;
        }
    }

    fn toggleSelectionAt(
        self: *Studio,
        items: []slides.SlideItem,
        resolved_bounds: []const ResolvedBounds,
        viewport: Viewport,
        pointer_screen: rl.Vector2,
        pointer_logical: ?rl.Vector2,
    ) void {
        if (!viewport.containsScreenPoint(pointer_screen)) return;
        const pointer = pointer_logical orelse return;
        const hit_index = hitTest(items, resolved_bounds, pointer) orelse return;
        const item = items[hit_index];
        if (self.selected_identity == null) {
            self.setSingleSelection(item);
            return;
        }
        if (self.selected_identity.? == item.identity) {
            if (self.additional_selection_count == 0) {
                self.clearSelectionState();
            } else {
                const replacement = self.additional_selection[self.additional_selection_count - 1];
                self.additional_selection_count -= 1;
                self.selected_identity = replacement.identity;
                self.selected_source = replacement.source;
                self.snap_guides = .{};
            }
            return;
        }
        for (self.additional_selection[0..self.additional_selection_count], 0..) |member, member_index| {
            if (member.identity == item.identity) {
                self.removeAdditionalSelection(member_index);
                self.snap_guides = .{};
                return;
            }
        }
        if (self.selectionCount() >= max_selection_items) {
            self.notice = .selection_capacity_reached;
            return;
        }
        self.additional_selection[self.additional_selection_count] = .{
            .identity = self.selected_identity.?,
            .source = self.selected_source,
        };
        self.additional_selection_count += 1;
        self.selected_identity = item.identity;
        self.selected_source = sourceForSelection(item);
        self.snap_guides = .{};
    }

    fn selectAll(self: *Studio, items: []slides.SlideItem, resolved_bounds: []const ResolvedBounds) void {
        if (self.interaction != .idle) self.cancelInteraction(items);
        var primary_index: ?usize = if (self.selectedIndex(items)) |index|
            if (isSelectable(items[index], resolved_bounds)) index else null
        else
            null;
        if (primary_index == null) {
            var index = items.len;
            while (index > 0) {
                index -= 1;
                if (isSelectable(items[index], resolved_bounds)) {
                    primary_index = index;
                    break;
                }
            }
        }
        const selected_index = primary_index orelse {
            self.clearSelectionState();
            return;
        };
        self.setSingleSelection(items[selected_index]);
        var overflow = false;
        for (items, 0..) |item, index| {
            if (index == selected_index or !isSelectable(item, resolved_bounds)) continue;
            if (self.selectionCount() >= max_selection_items) {
                overflow = true;
                continue;
            }
            self.additional_selection[self.additional_selection_count] = .{
                .identity = item.identity,
                .source = sourceForSelection(item),
            };
            self.additional_selection_count += 1;
        }
        self.notice = if (overflow) .selection_capacity_reached else .none;
    }

    fn validateSelection(self: *Studio, items: []slides.SlideItem, resolved_bounds: []const ResolvedBounds) void {
        if (self.selected_identity) |identity| {
            var index = itemIndexByIdentity(items, identity);
            if (self.selected_source) |source| {
                if (itemIndexByUniqueSource(items, source)) |rebound| {
                    index = rebound;
                    self.selected_identity = items[rebound].identity;
                    if (self.selected_identity.? != identity) self.snap_guides = .{};
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
                if (self.interaction != .idle) self.cancelInteraction(items);
                self.clearSelectionState();
                return;
            };
            if (items[selected_index].locked) {
                if (!isConcreteVisibleItem(items[selected_index], resolved_bounds)) {
                    self.clearSelectionState();
                    return;
                }
            } else if (!isSelectable(items[selected_index], resolved_bounds)) {
                if (self.interaction != .idle) self.cancelInteraction(items);
                self.clearSelectionState();
                return;
            }

            var retained: usize = 0;
            var member_index: usize = 0;
            while (member_index < self.additional_selection_count) : (member_index += 1) {
                const member = self.additional_selection[member_index];
                const rebound_index = if (member.source) |source|
                    itemIndexByUniqueSource(items, source) orelse itemIndexByIdentity(items, member.identity)
                else
                    itemIndexByIdentity(items, member.identity);
                const valid_index = rebound_index orelse continue;
                if (items[valid_index].locked) {
                    if (!isConcreteVisibleItem(items[valid_index], resolved_bounds)) continue;
                } else if (!isSelectable(items[valid_index], resolved_bounds)) continue;
                const rebound_identity = items[valid_index].identity;
                if (self.selected_identity != null and rebound_identity == self.selected_identity.?) continue;
                var duplicate = false;
                for (self.additional_selection[0..retained]) |retained_member| {
                    if (retained_member.identity == rebound_identity) {
                        duplicate = true;
                        break;
                    }
                }
                if (duplicate) continue;
                self.additional_selection[retained] = .{
                    .identity = rebound_identity,
                    .source = sourceForSelection(items[valid_index]),
                };
                retained += 1;
            }
            if (retained != self.additional_selection_count and self.interaction != .idle) {
                self.cancelInteraction(items);
            }
            self.additional_selection_count = retained;
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
            self.clearSelectionState();
            return;
        }
        const pointer = pointer_logical orelse {
            self.clearSelectionState();
            return;
        };
        const hit_index = hitTest(items, resolved_bounds, pointer) orelse {
            self.clearSelectionState();
            return;
        };
        self.setSingleSelection(items[hit_index]);
        const edit_scope = self.editScopeForItem(items, hit_index, allow_shared_edit) orelse return;
        self.beginInteraction(
            .moving,
            itemGeometry(items[hit_index], resolved_bounds),
            Geometry.fromItem(items[hit_index]),
            sourceGeometryForEdit(items[hit_index], itemGeometry(items[hit_index], resolved_bounds), edit_scope),
            edit_scope == .shared_template and items[hit_index].instance_source != null,
            pointer,
            edit_scope,
        );
    }

    fn itemIdIsUnique(items: []const slides.SlideItem, item_index: usize) bool {
        const id = items[item_index].id orelse return false;
        for (items, 0..) |other, other_index| {
            if (other_index == item_index) continue;
            if (other.id) |other_id| {
                if (std.mem.eql(u8, id, other_id)) return false;
            }
        }
        return true;
    }

    /// Resolves an action to its source-edit destination. Template clones with
    /// unique IDs default to a current-slide override; Alt deliberately opts
    /// into changing the shared template definition instead.
    fn editScopeForItem(
        self: *Studio,
        items: []const slides.SlideItem,
        item_index: usize,
        allow_shared_edit: bool,
    ) ?EditScope {
        const item = items[item_index];
        if (self.active_morph_state) |state_index| {
            if (item.state_source_state != null and item.state_source_state.? == state_index) {
                if (item.state_source != null and item.state_source.?.patchable) return .direct;
                self.notice = .generated_source_read_only;
                return null;
            }
            if (item.creation_morph_state != null and item.creation_morph_state.? == state_index) {
                if (item.source.patchable) return .direct;
                self.notice = .generated_source_read_only;
                return null;
            }
            // Morph-state placement remains under the integration layer's
            // existing state-local targeting; EditScope distinguishes only
            // base template-instance edits from shared template edits.
            if (itemIdIsUnique(items, item_index)) return .direct;
            self.notice = .local_override_needs_unique_id;
            return null;
        }

        if (item.source.scope == .slide_template) {
            if (allow_shared_edit) {
                if (item.instance_source != null) {
                    // Parser-provided authored values let geometry commands
                    // carry a distinct shared target while their preview
                    // remains in effective instance coordinates.
                    if (item.sharedTemplateValues() == null) {
                        self.notice = .generated_source_read_only;
                        return null;
                    }
                    self.notice = .shared_template_customized;
                }
                if (item.source.patchable) return .shared_template;
                self.notice = .generated_source_read_only;
                return null;
            }
            if (itemIdIsUnique(items, item_index)) return .local_instance;
            self.notice = .local_override_needs_unique_id;
            return null;
        }

        if (item.source.scope != .none and item.source.patchable) return .direct;
        self.notice = .generated_source_read_only;
        return null;
    }

    fn commandSource(self: Studio, item: slides.SlideItem, edit_scope: EditScope) slides.SourceRef {
        return switch (edit_scope) {
            .shared_template => item.source,
            .local_instance => item.effectiveBaseSource(),
            .direct => if (self.active_morph_state != null) item.effectiveSource() else item.effectiveBaseSource(),
        };
    }

    fn sourceGeometryForEdit(item: slides.SlideItem, displayed: Geometry, edit_scope: EditScope) Geometry {
        if (edit_scope == .shared_template) {
            if (item.sharedTemplateValues()) |shared| return .{
                .position = shared.position,
                .size = shared.size,
            };
        }
        return displayed;
    }

    fn selectionLayoutGeometry(entry: SelectionGeometry) Geometry {
        return if (entry.separate_source_geometry) entry.source_geometry else entry.geometry;
    }

    fn groupMemberLayoutGeometry(member: GroupDragMember) Geometry {
        return if (member.separate_source_geometry) member.source_before else member.before;
    }

    fn sharedResizeSupported(item: slides.SlideItem, edit_scope: EditScope) bool {
        if (edit_scope != .shared_template or item.instance_source == null) return true;
        const shared = item.sharedTemplateValues() orelse return false;
        return shared.size.x > 0 and shared.size.y > 0;
    }

    fn sourceAfterDisplayDelta(source_before: Geometry, display_before: Geometry, display_after: Geometry, resized: bool) Geometry {
        var after = source_before;
        after.position = add(source_before.position, subtract(display_after.position, display_before.position));
        if (resized) {
            after.size = .{
                .x = source_before.size.x * display_after.size.x / display_before.size.x,
                .y = source_before.size.y * display_after.size.y / display_before.size.y,
            };
        }
        return after;
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
        if (item.source.scope == .slide_template) return item.id != null or item.source.patchable;
        return item.source.scope != .none and item.source.patchable;
    }

    fn editDestinationLabel(self: Studio, item: slides.SlideItem) []const u8 {
        if (self.interaction != .idle) {
            return switch (self.drag.edit_scope) {
                .direct => sourceScopeLabel(if (self.active_morph_state != null) item.effectiveSource().scope else item.effectiveBaseSource().scope),
                .local_instance => "editing local instance override",
                .shared_template => if (item.instance_source != null)
                    "editing shared template (Alt) · local override remains"
                else
                    "editing shared template (Alt)",
            };
        }
        if (self.active_morph_state == null and item.source.scope == .slide_template) {
            if (item.id != null) {
                if (item.instance_source != null) return "local override active; Alt edits shared template";
                if (item.source.patchable) return "local instance override; Alt edits shared template";
                return "local instance override; shared source is generated/read-only";
            }
            if (item.source.patchable) return "shared template; add id for local edit (Alt edits shared)";
            return "generated shared template; add a literal id for local editing";
        }
        const source = if (self.active_morph_state != null) item.effectiveSource() else item.effectiveBaseSource();
        return sourceScopeLabel(source.scope);
    }

    fn groupDestinationLabel(self: Studio) []const u8 {
        if (self.group_drag_count < 2) return "multiple source destinations";
        const first_scope = self.group_drag[0].edit_scope;
        for (self.group_drag[1..self.group_drag_count]) |member| {
            if (member.edit_scope != first_scope) return "mixed source destinations";
        }
        return switch (first_scope) {
            .direct => "group edit · direct/state sources",
            .local_instance => "group edit · local instance overrides",
            .shared_template => "group edit · shared templates (Alt)",
        };
    }

    fn gatherSelectionGeometry(
        self: *Studio,
        items: []const slides.SlideItem,
        resolved_bounds: []const ResolvedBounds,
        allow_shared_edit: bool,
        output: *[max_selection_items]SelectionGeometry,
    ) ?usize {
        const count = self.selectionCount();
        if (count == 0 or count > max_selection_items) return null;
        for (0..count) |selection_index| {
            const identity = self.selectedIdentityAt(selection_index) orelse return null;
            const item_index = itemIndexByIdentity(items, identity) orelse return null;
            if (items[item_index].locked) {
                self.notice = .locked_item;
                return null;
            }
            const edit_scope = self.editScopeForItem(items, item_index, allow_shared_edit) orelse return null;
            const geometry = itemGeometry(items[item_index], resolved_bounds);
            output[selection_index] = .{
                .identity = identity,
                .item_index = item_index,
                .geometry = geometry,
                .authored_geometry = Geometry.fromItem(items[item_index]),
                .source_geometry = sourceGeometryForEdit(items[item_index], geometry, edit_scope),
                .separate_source_geometry = edit_scope == .shared_template and items[item_index].instance_source != null,
                .edit_scope = edit_scope,
            };
        }
        return count;
    }

    fn geometryBounds(geometries: []const SelectionGeometry) Geometry {
        std.debug.assert(geometries.len > 0);
        const first = selectionLayoutGeometry(geometries[0]);
        var min_x = first.position.x;
        var min_y = first.position.y;
        var max_x = min_x + first.size.x;
        var max_y = min_y + first.size.y;
        for (geometries[1..]) |entry| {
            const geometry = selectionLayoutGeometry(entry);
            min_x = @min(min_x, geometry.position.x);
            min_y = @min(min_y, geometry.position.y);
            max_x = @max(max_x, geometry.position.x + geometry.size.x);
            max_y = @max(max_y, geometry.position.y + geometry.size.y);
        }
        return .{
            .position = .{ .x = min_x, .y = min_y },
            .size = .{ .x = max_x - min_x, .y = max_y - min_y },
        };
    }

    fn applySelectionGeometryBatch(
        self: *Studio,
        items: []slides.SlideItem,
        entries: []const SelectionGeometry,
        after: []const Geometry,
    ) void {
        std.debug.assert(entries.len == after.len and entries.len <= max_selection_items);
        var batch = GeometryBatchCommand{};
        for (entries, after) |entry, layout_after| {
            const display_after = if (entry.separate_source_geometry) entry.geometry else layout_after;
            const source_changed = entry.separate_source_geometry and !geometryEqual(entry.source_geometry, layout_after);
            if (geometryEqual(entry.geometry, display_after) and !source_changed) continue;
            if (!geometryEqual(entry.geometry, display_after)) items[entry.item_index].position = display_after.position;
            batch.commands[batch.count] = .{
                .item_identity = entry.identity,
                .source = self.commandSource(items[entry.item_index], entry.edit_scope),
                .edit_scope = entry.edit_scope,
                .before_position = entry.geometry.position,
                .before_size = entry.geometry.size,
                .after_position = display_after.position,
                .after_size = display_after.size,
                .source_after_position = if (entry.separate_source_geometry) layout_after.position else null,
                .source_after_size = null,
                .resized = false,
            };
            batch.count += 1;
        }
        if (batch.count == 0) return;
        self.pending_geometry_batch = batch;
        self.dirty = true;
        self.copy_is_current = false;
    }

    fn beginGroupMove(
        self: *Studio,
        items: []slides.SlideItem,
        resolved_bounds: []const ResolvedBounds,
        pointer: rl.Vector2,
        allow_shared_edit: bool,
    ) void {
        var entries: [max_selection_items]SelectionGeometry = undefined;
        const count = self.gatherSelectionGeometry(items, resolved_bounds, allow_shared_edit, &entries) orelse return;
        if (count < 2) return;
        for (entries[0..count], 0..) |entry, index| {
            self.group_drag[index] = .{
                .identity = entry.identity,
                .before = entry.geometry,
                .authored_before = entry.authored_geometry,
                .source_before = entry.source_geometry,
                .source_after = entry.source_geometry,
                .separate_source_geometry = entry.separate_source_geometry,
                .after = entry.geometry,
                .edit_scope = entry.edit_scope,
            };
        }
        self.group_drag_count = count;
        self.group_bounds_before = geometryBounds(entries[0..count]);
        self.group_bounds_after = self.group_bounds_before;
        self.drag.pointer_start = pointer;
        self.interaction = .moving;
        self.preview = entries[0].geometry;
        self.snap_guides = .{};
    }

    fn applyGroupPointer(
        self: *Studio,
        items: []slides.SlideItem,
        resolved_bounds: []const ResolvedBounds,
        viewport: Viewport,
        pointer: rl.Vector2,
        disable_snapping: bool,
    ) void {
        if (self.group_drag_count < 2 or self.interaction != .moving) return;
        const raw_delta = roundVector(subtract(pointer, self.drag.pointer_start));
        var candidate = self.group_bounds_before;
        candidate.position = add(candidate.position, raw_delta);
        self.snap_guides = .{};

        if (!disable_snapping and (raw_delta.x != 0 or raw_delta.y != 0)) {
            const threshold: rl.Vector2 = if (viewport.valid()) .{
                .x = self.snap_threshold_screen * viewport.logical_size.x / viewport.slide_size.x,
                .y = self.snap_threshold_screen * viewport.logical_size.y / viewport.slide_size.y,
            } else .zero();
            var excluded: [max_selection_items]usize = undefined;
            var include_item_targets = true;
            for (self.group_drag[0..self.group_drag_count], 0..) |member, index| {
                excluded[index] = member.identity;
                if (member.edit_scope == .shared_template) include_item_targets = false;
            }
            const snapped = snapGeometryExcluding(
                candidate,
                .moving,
                viewport.logical_size,
                threshold,
                self.grid_snapping,
                self.grid_spacing,
                self.min_item_size,
                null,
                include_item_targets,
                excluded[0..self.group_drag_count],
                items,
                resolved_bounds,
            );
            candidate = snapped.geometry;
            self.snap_guides = snapped.guides;
        }

        const effective_delta = subtract(candidate.position, self.group_bounds_before.position);
        self.group_bounds_after = candidate;
        for (self.group_drag[0..self.group_drag_count]) |*member| {
            const item_index = itemIndexByIdentity(items, member.identity) orelse continue;
            const layout_before = groupMemberLayoutGeometry(member.*);
            var layout_after = layout_before;
            layout_after.position = add(layout_before.position, effective_delta);
            if (member.separate_source_geometry) {
                member.source_after = layout_after;
                member.after = member.before;
            } else {
                member.after = layout_after;
                items[item_index].position = member.after.position;
            }
        }
        self.preview = self.group_drag[0].after;
    }

    fn finishGroupInteraction(self: *Studio, items: []slides.SlideItem) void {
        var batch = GeometryBatchCommand{};
        for (self.group_drag[0..self.group_drag_count]) |member| {
            const source_changed = member.separate_source_geometry and
                !geometryEqual(member.source_before, member.source_after);
            if (geometryEqual(member.before, member.after) and !source_changed) continue;
            const item_index = itemIndexByIdentity(items, member.identity) orelse continue;
            batch.commands[batch.count] = .{
                .item_identity = member.identity,
                .source = self.commandSource(items[item_index], member.edit_scope),
                .edit_scope = member.edit_scope,
                .before_position = member.before.position,
                .before_size = member.before.size,
                .after_position = member.after.position,
                .after_size = member.after.size,
                .source_after_position = if (member.separate_source_geometry) member.source_after.position else null,
                .source_after_size = null,
                .resized = false,
            };
            batch.count += 1;
        }
        if (batch.count > 0) {
            self.pending_geometry_batch = batch;
            self.dirty = true;
            self.copy_is_current = false;
        } else if (self.selectedIndex(items)) |primary_index| {
            // A plain click without a drag selects only the clicked member;
            // a real drag preserves and moves the whole group.
            self.setSingleSelection(items[primary_index]);
        }
        self.interaction = .idle;
        self.snap_guides = .{};
        self.group_drag_count = 0;
    }

    fn applyGroupNudge(
        self: *Studio,
        items: []slides.SlideItem,
        resolved_bounds: []const ResolvedBounds,
        delta: rl.Vector2,
        allow_shared_edit: bool,
    ) void {
        var entries: [max_selection_items]SelectionGeometry = undefined;
        const count = self.gatherSelectionGeometry(items, resolved_bounds, allow_shared_edit, &entries) orelse return;
        if (count < 2) return;
        var after: [max_selection_items]Geometry = undefined;
        for (entries[0..count], 0..) |entry, index| {
            const before = selectionLayoutGeometry(entry);
            after[index] = before;
            after[index].position = add(before.position, delta);
        }
        self.applySelectionGeometryBatch(items, entries[0..count], after[0..count]);
    }

    fn beginInteraction(
        self: *Studio,
        interaction: Interaction,
        geometry: Geometry,
        authored_geometry: Geometry,
        source_geometry: Geometry,
        separate_source_geometry: bool,
        pointer: rl.Vector2,
        edit_scope: EditScope,
    ) void {
        self.interaction = interaction;
        self.group_drag_count = 0;
        self.snap_guides = .{};
        self.drag = .{
            .pointer_start = pointer,
            .before = geometry,
            .authored_before = authored_geometry,
            .source_before = source_geometry,
            .source_after = source_geometry,
            .separate_source_geometry = separate_source_geometry,
            .edit_scope = edit_scope,
        };
        self.preview = geometry;
    }

    fn applyPointer(
        self: *Studio,
        items: []slides.SlideItem,
        resolved_bounds: []const ResolvedBounds,
        viewport: Viewport,
        pointer: rl.Vector2,
        lock_aspect_ratio: bool,
        disable_snapping: bool,
    ) void {
        const index = self.selectedIndex(items) orelse return;
        const delta = subtract(pointer, self.drag.pointer_start);
        const moving_shared_source = self.drag.separate_source_geometry and self.interaction == .moving;
        var geometry = if (moving_shared_source) self.drag.source_before else self.drag.before;
        var aspect_ratio: ?f32 = null;
        switch (self.interaction) {
            .idle => return,
            .moving => geometry.position = roundVector(add(geometry.position, delta)),
            .resizing => {
                if (lock_aspect_ratio and self.drag.before.size.x > 0 and self.drag.before.size.y > 0) {
                    const ratio = self.drag.before.size.x / self.drag.before.size.y;
                    aspect_ratio = ratio;
                    if (@abs(delta.x) >= @abs(delta.y * ratio)) {
                        const width = @max(@max(self.min_item_size, self.min_item_size * ratio), self.drag.before.size.x + delta.x);
                        geometry.size = .{ .x = width, .y = width / ratio };
                    } else {
                        const height = @max(@max(self.min_item_size, self.min_item_size / ratio), self.drag.before.size.y + delta.y);
                        geometry.size = .{ .x = height * ratio, .y = height };
                    }
                } else {
                    geometry.size = roundVector(.{
                        .x = @max(self.min_item_size, self.drag.before.size.x + delta.x),
                        .y = @max(self.min_item_size, self.drag.before.size.y + delta.y),
                    });
                }
            },
        }
        self.snap_guides = .{};
        if (!disable_snapping and (delta.x != 0 or delta.y != 0)) {
            const threshold: rl.Vector2 = if (viewport.valid()) .{
                .x = self.snap_threshold_screen * viewport.logical_size.x / viewport.slide_size.x,
                .y = self.snap_threshold_screen * viewport.logical_size.y / viewport.slide_size.y,
            } else .zero();
            const snapped = snapGeometry(
                geometry,
                self.interaction,
                viewport.logical_size,
                threshold,
                self.grid_snapping,
                self.grid_spacing,
                self.min_item_size,
                aspect_ratio,
                self.drag.edit_scope != .shared_template,
                items[index].identity,
                items,
                resolved_bounds,
            );
            geometry = snapped.geometry;
            self.snap_guides = snapped.guides;
        }
        if (self.drag.separate_source_geometry) {
            self.drag.source_after = if (moving_shared_source)
                geometry
            else
                sourceAfterDisplayDelta(
                    self.drag.source_before,
                    self.drag.before,
                    geometry,
                    self.interaction == .resizing,
                );
            // A local override masks the shared edit on this instance. Keep
            // both the logical item and renderer preview truthful: only the
            // authored source target moves.
            self.preview = self.drag.before;
        } else {
            self.preview = geometry;
            items[index].position = geometry.position;
            if (self.interaction == .resizing) items[index].size = geometry.size;
        }
    }

    fn finishInteraction(self: *Studio, items: []slides.SlideItem) ?GeometryCommand {
        const interaction = self.interaction;
        self.interaction = .idle;
        self.group_drag_count = 0;
        self.snap_guides = .{};
        const identity = self.selected_identity orelse return null;
        const index = itemIndexByIdentity(items, identity) orelse return null;
        const after = self.preview;
        const source_after = if (self.drag.separate_source_geometry)
            self.drag.source_after
        else
            sourceAfterDisplayDelta(
                self.drag.source_before,
                self.drag.before,
                after,
                interaction == .resizing,
            );
        if (geometryEqual(self.drag.before, after) and
            (!self.drag.separate_source_geometry or geometryEqual(self.drag.source_before, source_after))) return null;
        self.dirty = true;
        self.copy_is_current = false;
        return .{
            .item_identity = identity,
            .source = self.commandSource(items[index], self.drag.edit_scope),
            .edit_scope = self.drag.edit_scope,
            .before_position = self.drag.before.position,
            .before_size = self.drag.before.size,
            .after_position = after.position,
            .after_size = after.size,
            .source_after_position = if (self.drag.separate_source_geometry) source_after.position else null,
            .source_after_size = if (self.drag.separate_source_geometry and interaction == .resizing)
                source_after.size
            else
                null,
            .resized = interaction == .resizing,
        };
    }

    fn cancelInteraction(self: *Studio, items: []slides.SlideItem) void {
        if (self.group_drag_count > 1) {
            for (self.group_drag[0..self.group_drag_count]) |member| {
                const item_index = itemIndexByIdentity(items, member.identity) orelse continue;
                items[item_index].position = member.authored_before.position;
                items[item_index].size = member.authored_before.size;
            }
        } else if (self.selectedIndex(items)) |index| {
            self.restoreBefore(&items[index]);
        }
        self.interaction = .idle;
        self.group_drag_count = 0;
        self.snap_guides = .{};
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
        edit_scope: EditScope,
    ) ?GeometryCommand {
        const identity = self.selected_identity orelse return null;
        const index = itemIndexByIdentity(items, identity) orelse return null;
        const before = itemGeometry(items[index], resolved_bounds);
        const source_before = sourceGeometryForEdit(items[index], before, edit_scope);
        const separate_source_geometry = edit_scope == .shared_template and items[index].instance_source != null;
        var source_after = source_before;
        source_after.position = add(source_before.position, delta);
        var after = before;
        if (!separate_source_geometry) {
            items[index].position = add(items[index].position, delta);
            after.position = items[index].position;
        }
        self.dirty = true;
        self.copy_is_current = false;
        return .{
            .item_identity = identity,
            .source = self.commandSource(items[index], edit_scope),
            .edit_scope = edit_scope,
            .before_position = before.position,
            .before_size = before.size,
            .after_position = after.position,
            .after_size = after.size,
            .source_after_position = if (separate_source_geometry)
                source_after.position
            else
                null,
            .source_after_size = null,
            .resized = false,
        };
    }

    fn alignSelected(
        self: *Studio,
        items: []slides.SlideItem,
        resolved_bounds: []const ResolvedBounds,
        logical_size: rl.Vector2,
        action: AlignAction,
        allow_shared_edit: bool,
    ) ?GeometryCommand {
        if (self.selectionCount() > 1) {
            self.alignGroupSelected(items, resolved_bounds, action, allow_shared_edit);
            return null;
        }
        const index = self.selectedIndex(items) orelse return null;
        if (self.interaction != .idle) self.cancelInteraction(items);
        if (items[index].locked) {
            self.notice = .locked_item;
            return null;
        }
        const edit_scope = self.editScopeForItem(items, index, allow_shared_edit) orelse return null;
        const before = itemGeometry(items[index], resolved_bounds);
        const separate_source_geometry = edit_scope == .shared_template and items[index].instance_source != null;
        var after = before;
        switch (action) {
            .left => after.position.x = 0,
            .horizontal_center => after.position.x = (logical_size.x - before.size.x) / 2,
            .right => after.position.x = logical_size.x - before.size.x,
            .top => after.position.y = 0,
            .vertical_center => after.position.y = (logical_size.y - before.size.y) / 2,
            .bottom => after.position.y = logical_size.y - before.size.y,
        }
        const source_before = sourceGeometryForEdit(items[index], before, edit_scope);
        var source_after = source_before;
        if (separate_source_geometry) {
            const needs_width = action == .horizontal_center or action == .right;
            const needs_height = action == .vertical_center or action == .bottom;
            if ((needs_width and source_before.size.x <= 0) or
                (needs_height and source_before.size.y <= 0))
            {
                self.notice = .shared_template_auto_size;
                return null;
            }
        }
        const source_layout_size: rl.Vector2 = .{
            .x = if (source_after.size.x > 0) source_after.size.x else before.size.x,
            .y = if (source_after.size.y > 0) source_after.size.y else before.size.y,
        };
        switch (action) {
            .left => source_after.position.x = 0,
            .horizontal_center => source_after.position.x = (logical_size.x - source_layout_size.x) / 2,
            .right => source_after.position.x = logical_size.x - source_layout_size.x,
            .top => source_after.position.y = 0,
            .vertical_center => source_after.position.y = (logical_size.y - source_layout_size.y) / 2,
            .bottom => source_after.position.y = logical_size.y - source_layout_size.y,
        }
        if (separate_source_geometry) after = before;
        if (geometryEqual(before, after) and
            (edit_scope != .shared_template or geometryEqual(source_before, source_after))) return null;
        if (!geometryEqual(before, after)) items[index].position = after.position;
        self.dirty = true;
        self.copy_is_current = false;
        return .{
            .item_identity = items[index].identity,
            .source = self.commandSource(items[index], edit_scope),
            .edit_scope = edit_scope,
            .before_position = before.position,
            .before_size = before.size,
            .after_position = after.position,
            .after_size = after.size,
            .source_after_position = if (separate_source_geometry)
                source_after.position
            else
                null,
            .source_after_size = null,
            .resized = false,
        };
    }

    fn alignGroupSelected(
        self: *Studio,
        items: []slides.SlideItem,
        resolved_bounds: []const ResolvedBounds,
        action: AlignAction,
        allow_shared_edit: bool,
    ) void {
        if (self.interaction != .idle) self.cancelInteraction(items);
        var entries: [max_selection_items]SelectionGeometry = undefined;
        const count = self.gatherSelectionGeometry(items, resolved_bounds, allow_shared_edit, &entries) orelse return;
        if (count < 2) return;
        for (entries[0..count]) |entry| {
            if (!entry.separate_source_geometry) continue;
            const source = entry.source_geometry;
            const needs_width = action == .horizontal_center or action == .right;
            const needs_height = action == .vertical_center or action == .bottom;
            if ((needs_width and source.size.x <= 0) or (needs_height and source.size.y <= 0)) {
                self.notice = .shared_template_auto_size;
                return;
            }
        }
        const bounds = geometryBounds(entries[0..count]);
        var after: [max_selection_items]Geometry = undefined;
        for (entries[0..count], 0..) |entry, index| {
            const before = selectionLayoutGeometry(entry);
            after[index] = before;
            switch (action) {
                .left => after[index].position.x = bounds.position.x,
                .horizontal_center => after[index].position.x = bounds.position.x + (bounds.size.x - before.size.x) / 2,
                .right => after[index].position.x = bounds.position.x + bounds.size.x - before.size.x,
                .top => after[index].position.y = bounds.position.y,
                .vertical_center => after[index].position.y = bounds.position.y + (bounds.size.y - before.size.y) / 2,
                .bottom => after[index].position.y = bounds.position.y + bounds.size.y - before.size.y,
            }
        }
        self.applySelectionGeometryBatch(items, entries[0..count], after[0..count]);
    }

    fn distributeSelected(
        self: *Studio,
        items: []slides.SlideItem,
        resolved_bounds: []const ResolvedBounds,
        action: DistributionAction,
        allow_shared_edit: bool,
    ) void {
        if (self.interaction != .idle) self.cancelInteraction(items);
        if (self.selectionCount() < 3) {
            self.notice = .distribution_needs_three;
            return;
        }
        var entries: [max_selection_items]SelectionGeometry = undefined;
        const count = self.gatherSelectionGeometry(items, resolved_bounds, allow_shared_edit, &entries) orelse return;
        if (count < 3) {
            self.notice = .distribution_needs_three;
            return;
        }
        for (entries[0..count]) |entry| {
            if (!entry.separate_source_geometry) continue;
            const extent = if (action == .horizontal) entry.source_geometry.size.x else entry.source_geometry.size.y;
            if (extent <= 0) {
                self.notice = .shared_template_auto_size;
                return;
            }
        }
        const bounds = geometryBounds(entries[0..count]);
        var order: [max_selection_items]usize = undefined;
        var after: [max_selection_items]Geometry = undefined;
        for (entries[0..count], 0..) |entry, index| {
            order[index] = index;
            after[index] = selectionLayoutGeometry(entry);
        }
        var index: usize = 1;
        while (index < count) : (index += 1) {
            const value = order[index];
            var insertion = index;
            while (insertion > 0) {
                const previous = order[insertion - 1];
                if (!distributionBefore(entries[value], entries[previous], action)) break;
                order[insertion] = previous;
                insertion -= 1;
            }
            order[insertion] = value;
        }

        var total_extent: f32 = 0;
        for (entries[0..count]) |entry| {
            const geometry = selectionLayoutGeometry(entry);
            total_extent += switch (action) {
                .horizontal => geometry.size.x,
                .vertical => geometry.size.y,
            };
        }
        const available_extent = switch (action) {
            .horizontal => bounds.size.x,
            .vertical => bounds.size.y,
        };
        const gap = (available_extent - total_extent) / @as(f32, @floatFromInt(count - 1));
        var cursor = switch (action) {
            .horizontal => bounds.position.x,
            .vertical => bounds.position.y,
        };
        for (order[0..count], 0..) |entry_index, ordinal| {
            const geometry = selectionLayoutGeometry(entries[entry_index]);
            switch (action) {
                .horizontal => {
                    after[entry_index].position.x = if (ordinal + 1 == count)
                        bounds.position.x + bounds.size.x - geometry.size.x
                    else
                        cursor;
                    cursor += geometry.size.x + gap;
                },
                .vertical => {
                    after[entry_index].position.y = if (ordinal + 1 == count)
                        bounds.position.y + bounds.size.y - geometry.size.y
                    else
                        cursor;
                    cursor += geometry.size.y + gap;
                },
            }
        }
        self.applySelectionGeometryBatch(items, entries[0..count], after[0..count]);
    }

    fn distributionBefore(a: SelectionGeometry, b: SelectionGeometry, action: DistributionAction) bool {
        const geometry_a = selectionLayoutGeometry(a);
        const geometry_b = selectionLayoutGeometry(b);
        const primary_a = if (action == .horizontal) geometry_a.position.x else geometry_a.position.y;
        const primary_b = if (action == .horizontal) geometry_b.position.x else geometry_b.position.y;
        if (primary_a != primary_b) return primary_a < primary_b;
        const secondary_a = if (action == .horizontal) geometry_a.position.y else geometry_a.position.x;
        const secondary_b = if (action == .horizontal) geometry_b.position.y else geometry_b.position.x;
        if (secondary_a != secondary_b) return secondary_a < secondary_b;
        return a.identity < b.identity;
    }

    /// Draw after the slide itself. While dragging, the original bounds remain
    /// visible as a subdued outline and the live geometry gets the accent.
    pub fn draw(self: Studio, items: []const slides.SlideItem, resolved_bounds: []const ResolvedBounds, viewport: Viewport) void {
        if (!self.enabled) return;

        if (self.grid_snapping) self.drawLogicalGrid(viewport);

        for (items) |item| {
            if (!item.locked or !isConcreteVisibleItem(item, resolved_bounds)) continue;
            const badge = lockBadgeRect(viewport, itemGeometry(item, resolved_bounds)) orelse continue;
            rl.drawRectangleRec(badge, .{ .r = 111, .g = 42, .b = 57, .a = 240 });
            rl.drawRectangleLinesEx(badge, 1, .{ .r = 255, .g = 112, .b = 132, .a = 255 });
            rl.drawText("LOCK", @intFromFloat(badge.x + 7), @intFromFloat(badge.y + 4), 11, .white);
        }

        if (self.interaction != .idle) {
            self.drawSnapGuides(viewport);
            const original_geometry = if (self.group_drag_count > 1) self.group_bounds_before else self.drag.before;
            if (geometryToScreenRect(viewport, original_geometry)) |original| {
                rl.drawRectangleLinesEx(original, 1, .{ .r = 255, .g = 255, .b = 255, .a = 105 });
            }
            if (self.group_drag_count <= 1 and self.drag.separate_source_geometry) {
                if (geometryToScreenRect(viewport, self.drag.source_after)) |source_rect| {
                    const shared_accent: rl.Color = .{ .r = 255, .g = 92, .b = 198, .a = 235 };
                    rl.drawRectangleLinesEx(source_rect, 2, shared_accent);
                    rl.drawText(
                        "SHARED SOURCE",
                        @intFromFloat(source_rect.x + 5),
                        @intFromFloat(source_rect.y + 5),
                        12,
                        shared_accent,
                    );
                    self.drawGeometryHud(viewport, source_rect, self.drag.source_after);
                }
            }
        }

        for (self.additional_selection[0..self.additional_selection_count]) |member| {
            const item_index = itemIndexByIdentity(items, member.identity) orelse continue;
            const geometry = itemGeometry(items[item_index], resolved_bounds);
            if (geometryToScreenRect(viewport, geometry)) |rect| {
                rl.drawRectangleLinesEx(rect, 2, .{ .r = 80, .g = 215, .b = 255, .a = 190 });
            }
        }

        if (self.selectedGeometry(items, resolved_bounds)) |geometry| {
            if (geometryToScreenRect(viewport, geometry)) |rect| {
                const selected_index = self.selectedIndex(items);
                const accent: rl.Color = if (selected_index) |index|
                    if (items[index].locked or !self.itemEditableInScene(items[index]))
                        .{ .r = 255, .g = 112, .b = 112, .a = 255 }
                    else if (self.active_morph_state == null and items[index].source.scope == .slide_template)
                        .{ .r = 247, .g = 164, .b = 29, .a = 255 }
                    else
                        .{ .r = 80, .g = 215, .b = 255, .a = 255 }
                else
                    .{ .r = 80, .g = 215, .b = 255, .a = 255 };
                rl.drawRectangleLinesEx(rect, 3, accent);
                if (selected_index) |index| {
                    if (self.selectionCount() == 1 and !items[index].locked and self.itemEditableInScene(items[index])) {
                        if (self.resizeHandleRect(viewport, geometry)) |handle| {
                            rl.drawRectangleRec(handle, accent);
                            rl.drawRectangleLinesEx(handle, 1, .white);
                        }
                    }
                }
                if (self.interaction != .idle and self.group_drag_count <= 1 and !self.drag.separate_source_geometry)
                    self.drawGeometryHud(viewport, rect, geometry);
            }
        }

        if (self.selectionCount() > 1) {
            const bounds = if (self.group_drag_count > 1) self.group_bounds_after else self.selectedBounds(items, resolved_bounds);
            if (bounds) |geometry| {
                if (geometryToScreenRect(viewport, geometry)) |rect| {
                    rl.drawRectangleLinesEx(rect, 2, .{ .r = 255, .g = 92, .b = 198, .a = 220 });
                    if (self.interaction != .idle) self.drawGeometryHud(viewport, rect, geometry);
                }
            }
        }

        self.drawToolbar(viewport);
        if (self.selected_identity != null) {
            const selected_locked = if (self.selectedIndex(items)) |index| items[index].locked else false;
            self.drawProperties(viewport, selected_locked);
        }
        self.drawStatus(items, resolved_bounds, viewport);
    }

    fn drawLogicalGrid(self: Studio, viewport: Viewport) void {
        if (!viewport.valid() or self.grid_spacing <= 0) return;
        const minor: rl.Color = .{ .r = 105, .g = 207, .b = 230, .a = 24 };
        const major: rl.Color = .{ .r = 105, .g = 207, .b = 230, .a = 52 };

        var index: usize = 0;
        var logical_x: f32 = 0;
        while (logical_x <= viewport.logical_size.x) : ({
            index += 1;
            logical_x = @as(f32, @floatFromInt(index)) * self.grid_spacing;
        }) {
            const screen = logicalToScreen(viewport, .{ .x = logical_x, .y = 0 }) orelse return;
            rl.drawLineEx(
                .{ .x = screen.x, .y = viewport.slide_top_left.y },
                .{ .x = screen.x, .y = viewport.slide_top_left.y + viewport.slide_size.y },
                if (index % 5 == 0) 1.25 else 1,
                if (index % 5 == 0) major else minor,
            );
        }

        index = 0;
        var logical_y: f32 = 0;
        while (logical_y <= viewport.logical_size.y) : ({
            index += 1;
            logical_y = @as(f32, @floatFromInt(index)) * self.grid_spacing;
        }) {
            const screen = logicalToScreen(viewport, .{ .x = 0, .y = logical_y }) orelse return;
            rl.drawLineEx(
                .{ .x = viewport.slide_top_left.x, .y = screen.y },
                .{ .x = viewport.slide_top_left.x + viewport.slide_size.x, .y = screen.y },
                if (index % 5 == 0) 1.25 else 1,
                if (index % 5 == 0) major else minor,
            );
        }
    }

    fn drawSnapGuides(self: Studio, viewport: Viewport) void {
        const color: rl.Color = .{ .r = 255, .g = 92, .b = 198, .a = 230 };
        if (self.snap_guides.vertical) |logical_x| {
            const screen = logicalToScreen(viewport, .{ .x = logical_x, .y = 0 }) orelse return;
            rl.drawLineEx(
                .{ .x = screen.x, .y = viewport.slide_top_left.y },
                .{ .x = screen.x, .y = viewport.slide_top_left.y + viewport.slide_size.y },
                1.5,
                color,
            );
        }
        if (self.snap_guides.horizontal) |logical_y| {
            const screen = logicalToScreen(viewport, .{ .x = 0, .y = logical_y }) orelse return;
            rl.drawLineEx(
                .{ .x = viewport.slide_top_left.x, .y = screen.y },
                .{ .x = viewport.slide_top_left.x + viewport.slide_size.x, .y = screen.y },
                1.5,
                color,
            );
        }
    }

    fn drawGeometryHud(_: Studio, viewport: Viewport, item_rect: rl.Rectangle, geometry: Geometry) void {
        var buffer: [128]u8 = undefined;
        const text = std.fmt.bufPrintZ(
            &buffer,
            "x {d:.1}  y {d:.1}  w {d:.1}  h {d:.1}",
            .{ geometry.position.x, geometry.position.y, geometry.size.x, geometry.size.y },
        ) catch return;
        const font_size: i32 = 14;
        const padding: f32 = 7;
        const width: f32 = @floatFromInt(rl.measureText(text, font_size));
        const hud_width = width + padding * 2;
        const hud_height: f32 = 28;
        const rect = geometryHudRectangle(viewport, item_rect, hud_width, hud_height);
        rl.drawRectangleRec(rect, .{ .r = 12, .g = 16, .b = 28, .a = 238 });
        rl.drawRectangleLinesEx(rect, 1, .{ .r = 255, .g = 92, .b = 198, .a = 220 });
        rl.drawText(text, @intFromFloat(rect.x + padding), @intFromFloat(rect.y + 7), font_size, .white);
    }

    fn geometryHudRectangle(viewport: Viewport, item_rect: rl.Rectangle, hud_width: f32, hud_height: f32) rl.Rectangle {
        const min_x = viewport.slide_top_left.x;
        const max_x = viewport.slide_top_left.x + viewport.slide_size.x - hud_width;
        const x = @max(min_x, @min(item_rect.x, max_x));
        const above_y = item_rect.y - hud_height - 6;
        const desired_y = if (above_y >= viewport.slide_top_left.y) above_y else item_rect.y + item_rect.height + 6;
        const min_y = viewport.slide_top_left.y;
        const max_y = viewport.slide_top_left.y + viewport.slide_size.y - hud_height;
        const y = @max(min_y, @min(desired_y, max_y));
        return .{ .x = x, .y = y, .width = hud_width, .height = hud_height };
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
        const action_labels = [_][:0]const u8{ "+", "Dup", "Del", "Up", "Down", "Tpl" };
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
        drawCompactButton(layout.library_use, "Use");
        drawCompactButton(layout.library_rename, "Ren");
        drawCompactButton(layout.library_delete, "Del");
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
            rl.drawText(name, @intFromFloat(row.x + 64), @intFromFloat(row.y + 8), 14, if (entry.available)
                .white
            else
                .{ .r = 130, .g = 136, .b = 149, .a = 255 });
            var usage_buffer: [48]u8 = undefined;
            const usage: [:0]const u8 = if (entry.use_count == 0)
                "unused"
            else
                std.fmt.bufPrintZ(&usage_buffer, "{d} use{s}", .{ entry.use_count, if (entry.use_count == 1) "" else "s" }) catch "used";
            rl.drawText(usage, @intFromFloat(row.x + 64), @intFromFloat(row.y + 27), 10, if (entry.deletable)
                .{ .r = 126, .g = 231, .b = 177, .a = 255 }
            else
                .{ .r = 168, .g = 179, .b = 198, .a = 255 });
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
        rl.drawRectangleRec(layout.grid_toggle, if (self.grid_snapping)
            .{ .r = 43, .g = 123, .b = 151, .a = 255 }
        else
            .{ .r = 31, .g = 38, .b = 55, .a = 245 });
        rl.drawRectangleLinesEx(layout.grid_toggle, if (self.grid_snapping) 2 else 1, if (self.grid_snapping)
            .{ .r = 80, .g = 215, .b = 255, .a = 255 }
        else
            .{ .r = 115, .g = 128, .b = 150, .a = 200 });
        const grid_label: [:0]const u8 = if (self.grid_snapping) "GRID ON" else "GRID";
        const grid_label_width = rl.measureText(grid_label, 11);
        rl.drawText(
            grid_label,
            @intFromFloat(layout.grid_toggle.x + (layout.grid_toggle.width - @as(f32, @floatFromInt(grid_label_width))) / 2),
            @intFromFloat(layout.grid_toggle.y + 15),
            11,
            .white,
        );
        drawActionButton(layout.scene_previous, "<");
        var scene_buffer: [32]u8 = undefined;
        const scene_label: [:0]const u8 = if (self.active_morph_state) |state|
            std.fmt.bufPrintZ(&scene_buffer, "STATE {d}/{d}", .{ state + 1, self.morph_state_count }) catch "MORPH"
        else
            "BASE";
        drawActionButton(layout.scene_label, scene_label);
        drawActionButton(layout.scene_next, ">");
    }

    fn drawProperties(self: Studio, viewport: Viewport, selected_locked: bool) void {
        const layout = uiLayout(viewport);
        drawStudioPanel(layout.properties);
        rl.drawText("PROPERTIES", @intFromFloat(layout.properties.x + 12), @intFromFloat(layout.properties.y + 11), 15, .white);
        drawActionButton(layout.edit_text, "Text");
        drawActionButton(layout.duplicate_item, "Dup");
        drawActionButton(layout.delete_item, "Del");
        drawActionButton(layout.promote, "Reuse");
        rl.drawText("FOREGROUND", @intFromFloat(layout.properties.x + 12), @intFromFloat(layout.properties.y + 82), 12, .{ .r = 185, .g = 196, .b = 215, .a = 255 });
        drawSwatches(layout.foreground_swatches);
        rl.drawText("BACKGROUND", @intFromFloat(layout.properties.x + 12), @intFromFloat(layout.properties.y + 146), 12, .{ .r = 185, .g = 196, .b = 215, .a = 255 });
        drawCompactButton(layout.clear_background, "None");
        drawSwatches(layout.background_swatches);
        rl.drawText(
            if (self.selectionCount() > 1) "ALIGN TO SELECTION" else "ALIGN TO SLIDE",
            @intFromFloat(layout.properties.x + 12),
            @intFromFloat(layout.properties.y + 210),
            12,
            .{ .r = 185, .g = 196, .b = 215, .a = 255 },
        );
        const align_labels = [_][:0]const u8{ "L", "HC", "R", "T", "VC", "B" };
        for (layout.align_buttons, align_labels) |button, label| drawCompactButton(button, label);
        rl.drawText("DISTRIBUTE", @intFromFloat(layout.properties.x + 12), @intFromFloat(layout.properties.y + 266), 12, .{ .r = 185, .g = 196, .b = 215, .a = 255 });
        const distribute_labels = [_][:0]const u8{ "H EQUAL GAP", "V EQUAL GAP" };
        for (layout.distribute_buttons, distribute_labels) |button, label| drawCompactButton(button, label);
        rl.drawText("LAYER", @intFromFloat(layout.properties.x + 12), @intFromFloat(layout.properties.y + 332), 12, .{ .r = 185, .g = 196, .b = 215, .a = 255 });
        const layer_labels = [_][:0]const u8{ "Back", "Down", "Up", "Front" };
        for (layout.layer_buttons, layer_labels) |button, label| drawCompactButton(button, label);
        drawCompactButton(layout.lock_item, if (selected_locked) "Unlock" else "Lock");
    }

    fn drawStatus(self: Studio, items: []const slides.SlideItem, resolved_bounds: []const ResolvedBounds, viewport: Viewport) void {
        const panel = statusPanel(viewport);
        rl.drawRectangleRec(panel, .{ .r = 10, .g = 14, .b = 24, .a = 225 });
        rl.drawRectangleLinesEx(panel, 1, .{ .r = 80, .g = 215, .b = 255, .a = 180 });

        var status_buffer: [512]u8 = undefined;
        const status_text = if (self.selected_identity) |identity| selected: {
            const geometry = if (self.selectionCount() > 1)
                self.selectedBounds(items, resolved_bounds) orelse break :selected "STUDIO · selection unavailable"
            else
                self.selectedGeometry(items, resolved_bounds) orelse break :selected "STUDIO · selection unavailable";
            const index = self.selectedIndex(items) orelse break :selected "STUDIO · selection unavailable";
            const item = items[index];
            const source = if (self.active_morph_state != null) item.effectiveSource() else item.effectiveBaseSource();
            const destination_label = if (self.selectionCount() > 1)
                self.groupDestinationLabel()
            else
                self.editDestinationLabel(item);
            break :selected std.fmt.bufPrintZ(
                &status_buffer,
                "STUDIO{s} · {d} selected · primary #{d} · {s}, line {d} · x {d:.0} y {d:.0} w {d:.0} h {d:.0}",
                .{ if (self.dirty) " *" else "", self.selectionCount(), identity, destination_label, source.line_number, geometry.position.x, geometry.position.y, geometry.size.x, geometry.size.y },
            ) catch "STUDIO · selected item";
        } else if (self.dirty) "STUDIO * · click an item to select it" else "STUDIO · click an item to select it";

        rl.drawText(status_text, @intFromFloat(panel.x + 12), @intFromFloat(panel.y + 9), 18, .white);
        rl.drawText(
            if (self.grid_snapping)
                "GRID ON · G toggle · Shift resize locks ratio · Cmd/Ctrl-drag bypasses snap"
            else
                "G grid · Shift resize locks ratio · Cmd/Ctrl-drag bypasses snap · [ ] morph scenes",
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
            .shared_template_customized => "Editing shared template; this slide keeps any local overrides",
            .shared_template_auto_size => "Shared resize needs explicit template width and height",
            .local_override_needs_unique_id => "Add a unique id=... to create a local override; Alt edits the shared template",
            .duplicate_item_unsupported => "Duplicate is not source-safe here; use a direct item, current-state birth, or Alt on a template item",
            .multi_selection_property_unsupported => "That property is single-item only; align, distribute, move, or nudge the selection",
            .selection_capacity_reached => "Selection is limited to 64 items; the remaining items were left unselected",
            .distribution_needs_three => "Equal-gap distribution needs at least three selected items",
            .generated_source_read_only => "Read-only in Studio: this item directive is produced with @let",
            .property_unavailable => "That property does not apply to this kind of item",
            .base_scene_only => "That action is available in the BASE scene",
            .structural_source_locked => "Slide structure is source-scoped here; no changes were made",
            .layer_selection_unsupported => "Layer changes need literal direct items in this scene; nothing moved",
            .copy_selection_unsupported => "Copy needs literal direct box items; nothing was copied",
            .clipboard_empty => "Copy one or more items before pasting",
            .locked_item => "Unlock this item before editing it",
            .library_name_conflict => "That library name is already defined",
            .library_entry_in_use => "Cannot delete: later source instances still use this reusable",
            .library_delete_unsupported => "Slide-template deletion is not source-safe yet",
            .slide_template_promotion_locked => "This slide cannot be promoted without changing its source semantics",
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

fn setTestSelection(studio: *Studio, items: []const slides.SlideItem, identities: []const usize) void {
    studio.clearSelectionState();
    if (identities.len == 0) return;
    const primary_index = itemIndexByIdentity(items, identities[0]) orelse unreachable;
    studio.setSingleSelection(items[primary_index]);
    studio.selected_source = null;
    for (identities[1..]) |identity| {
        _ = itemIndexByIdentity(items, identity) orelse unreachable;
        studio.additional_selection[studio.additional_selection_count] = .{
            .identity = identity,
            .source = null,
        };
        studio.additional_selection_count += 1;
    }
}

test "smart snapping aligns moving edges and centers with deterministic guides" {
    var items = [_]slides.SlideItem{
        testItem(1, .textbox, 0, 0, 200, 100),
        testItem(2, .textbox, 300, 400, 200, 100),
    };
    const slide_center = snapGeometry(
        .{ .position = .{ .x = 855, .y = 101 }, .size = .{ .x = 200, .y = 100 } },
        .moving,
        default_logical_size,
        .{ .x = 8, .y = 8 },
        false,
        default_grid_spacing,
        default_min_item_size,
        null,
        true,
        1,
        &items,
        &.{},
    );
    try std.testing.expectApproxEqAbs(@as(f32, 860), slide_center.geometry.position.x, 0.0001);
    try std.testing.expectEqual(@as(?f32, 960), slide_center.guides.vertical);

    items[1].position = .{ .x = 300, .y = 400 };
    const other_edge = snapGeometry(
        .{ .position = .{ .x = 505, .y = 250 }, .size = .{ .x = 100, .y = 100 } },
        .moving,
        default_logical_size,
        .{ .x = 8, .y = 8 },
        false,
        default_grid_spacing,
        default_min_item_size,
        null,
        true,
        1,
        &items,
        &.{},
    );
    try std.testing.expectApproxEqAbs(@as(f32, 500), other_edge.geometry.position.x, 0.0001);
    try std.testing.expectEqual(@as(?f32, 500), other_edge.guides.vertical);
}

test "grid snapping affects free axes while smart guides take priority" {
    const items = [_]slides.SlideItem{testItem(1, .textbox, 0, 0, 100, 100)};
    const grid = snapGeometry(
        .{ .position = .{ .x = 33, .y = 47 }, .size = .{ .x = 101, .y = 99 } },
        .moving,
        default_logical_size,
        .{ .x = 1, .y = 1 },
        true,
        20,
        default_min_item_size,
        null,
        true,
        1,
        &items,
        &.{},
    );
    try expectVector(.{ .x = 40, .y = 40 }, grid.geometry.position);
    try std.testing.expect(grid.guides.vertical == null and grid.guides.horizontal == null);

    const slide_edge = snapGeometry(
        .{ .position = .{ .x = 7, .y = 47 }, .size = .{ .x = 101, .y = 99 } },
        .moving,
        default_logical_size,
        .{ .x = 8, .y = 8 },
        true,
        20,
        default_min_item_size,
        null,
        true,
        1,
        &items,
        &.{},
    );
    try std.testing.expectApproxEqAbs(@as(f32, 0), slide_edge.geometry.position.x, 0.0001);
    try std.testing.expectEqual(@as(?f32, 0), slide_edge.guides.vertical);
    try std.testing.expectApproxEqAbs(@as(f32, 40), slide_edge.geometry.position.y, 0.0001);
}

test "resize snapping skips infeasible smart targets and falls back to grid" {
    const smart_items = [_]slides.SlideItem{
        testItem(1, .textbox, 10, 100, 6, 100),
        testItem(2, .textbox, 15, 500, 10, 10),
    };
    const smart = snapGeometry(
        .{ .position = .{ .x = 10, .y = 100 }, .size = .{ .x = 6, .y = 100 } },
        .resizing,
        default_logical_size,
        .{ .x = 8, .y = 8 },
        false,
        default_grid_spacing,
        default_min_item_size,
        null,
        true,
        1,
        &smart_items,
        &.{},
    );
    try std.testing.expectApproxEqAbs(@as(f32, 10), smart.geometry.size.x, 0.0001);
    try std.testing.expectEqual(@as(?f32, 20), smart.guides.vertical);

    const grid_items = [_]slides.SlideItem{
        testItem(1, .textbox, 10, 100, 6, 100),
        testItem(2, .textbox, 15, 500, 1, 10),
    };
    const grid = snapGeometry(
        .{ .position = .{ .x = 10, .y = 100 }, .size = .{ .x = 6, .y = 100 } },
        .resizing,
        default_logical_size,
        .{ .x = 8, .y = 8 },
        true,
        20,
        default_min_item_size,
        null,
        true,
        1,
        &grid_items,
        &.{},
    );
    try std.testing.expectApproxEqAbs(@as(f32, 10), grid.geometry.size.x, 0.0001);
    try std.testing.expect(grid.guides.vertical == null);
}

test "aspect locked resizing snaps one dominant edge then derives the other" {
    const items = [_]slides.SlideItem{
        testItem(1, .textbox, 100, 100, 200, 100),
        testItem(2, .textbox, 460, 300, 100, 100),
    };
    const result = snapGeometry(
        .{ .position = .{ .x = 100, .y = 100 }, .size = .{ .x = 355, .y = 177.5 } },
        .resizing,
        default_logical_size,
        .{ .x = 8, .y = 8 },
        false,
        default_grid_spacing,
        default_min_item_size,
        2,
        true,
        1,
        &items,
        &.{},
    );
    try expectVector(.{ .x = 360, .y = 180 }, result.geometry.size);
    try std.testing.expectEqual(@as(?f32, 460), result.guides.vertical);
    try std.testing.expect(result.guides.horizontal == null);
}

test "aspect locked snapping falls back when the nearest axis is too small" {
    const items = [_]slides.SlideItem{
        testItem(1, .textbox, 10, 10, 6, 3),
        testItem(2, .textbox, 15, 20, 100, 100),
    };
    const smart = snapGeometry(
        .{ .position = .{ .x = 10, .y = 10 }, .size = .{ .x = 6, .y = 3 } },
        .resizing,
        default_logical_size,
        .{ .x = 8, .y = 8 },
        false,
        default_grid_spacing,
        default_min_item_size,
        2,
        true,
        1,
        &items,
        &.{},
    );
    try expectVector(.{ .x = 20, .y = 10 }, smart.geometry.size);
    try std.testing.expect(smart.guides.vertical == null);
    try std.testing.expectEqual(@as(?f32, 20), smart.guides.horizontal);

    const grid = snapGeometry(
        .{ .position = .{ .x = 10, .y = 10 }, .size = .{ .x = 6, .y = 3 } },
        .resizing,
        default_logical_size,
        .{ .x = 0, .y = 0 },
        true,
        20,
        default_min_item_size,
        2,
        false,
        1,
        &items,
        &.{},
    );
    try expectVector(.{ .x = 20, .y = 10 }, grid.geometry.size);
}

test "smart snapping preserves fractional centers exactly" {
    const items = [_]slides.SlideItem{testItem(1, .textbox, 0, 0, 101, 50)};
    const result = snapGeometry(
        .{ .position = .{ .x = 449.8, .y = 100 }, .size = .{ .x = 101, .y = 50 } },
        .moving,
        .{ .x = 1000, .y = 500 },
        .{ .x = 2, .y = 2 },
        false,
        default_grid_spacing,
        default_min_item_size,
        null,
        true,
        1,
        &items,
        &.{},
    );
    try std.testing.expectApproxEqAbs(@as(f32, 449.5), result.geometry.position.x, 0.0001);
    try std.testing.expectEqual(@as(?f32, 500), result.guides.vertical);
}

test "shared template snapping excludes instance-local object guides" {
    const items = [_]slides.SlideItem{
        testItem(1, .textbox, 100, 100, 100, 100),
        testItem(2, .textbox, 500, 400, 200, 100),
    };
    const candidate: Geometry = .{ .position = .{ .x = 394, .y = 250 }, .size = .{ .x = 100, .y = 80 } };
    const local = snapGeometry(
        candidate,
        .moving,
        default_logical_size,
        .{ .x = 8, .y = 8 },
        false,
        default_grid_spacing,
        default_min_item_size,
        null,
        true,
        1,
        &items,
        &.{},
    );
    try std.testing.expectApproxEqAbs(@as(f32, 400), local.geometry.position.x, 0.0001);
    try std.testing.expectEqual(@as(?f32, 500), local.guides.vertical);

    const shared = snapGeometry(
        candidate,
        .moving,
        default_logical_size,
        .{ .x = 8, .y = 8 },
        false,
        default_grid_spacing,
        default_min_item_size,
        null,
        false,
        1,
        &items,
        &.{},
    );
    try std.testing.expectApproxEqAbs(candidate.position.x, shared.geometry.position.x, 0.0001);
    try std.testing.expect(shared.guides.vertical == null);
}

test "smart snap candidates use resolved auto image bounds and filter hidden items" {
    var items = [_]slides.SlideItem{
        testItem(1, .textbox, 100, 100, 100, 100),
        testItem(2, .img, 500, 100, 0, 0),
        testItem(3, .textbox, 494, 100, 100, 100),
    };
    items[2].visible = false;
    const bounds = [_]ResolvedBounds{.{
        .identity = 2,
        .position = .{ .x = 500, .y = 100 },
        .size = .{ .x = 240, .y = 120 },
    }};
    const result = snapGeometry(
        .{ .position = .{ .x = 394, .y = 260 }, .size = .{ .x = 100, .y = 80 } },
        .moving,
        default_logical_size,
        .{ .x = 8, .y = 8 },
        false,
        default_grid_spacing,
        default_min_item_size,
        null,
        true,
        1,
        &items,
        &bounds,
    );
    try std.testing.expectApproxEqAbs(@as(f32, 400), result.geometry.position.x, 0.0001);
    try std.testing.expectEqual(@as(?f32, 500), result.guides.vertical);
}

test "screen pixel snap threshold stays stable across viewport scales" {
    const scaled_viewport: Viewport = .{
        .slide_top_left = .zero(),
        .slide_size = .{ .x = 960, .y = 540 },
    };
    var scaled_items = [_]slides.SlideItem{
        testItem(1, .textbox, 100, 300, 100, 100),
        testItem(2, .textbox, 300, 700, 100, 100),
    };
    var scaled: Studio = .{ .enabled = true };
    _ = scaled.update(&scaled_items, &.{}, scaled_viewport, .{
        .pointer_screen = .{ .x = 60, .y = 160 },
        .pointer_pressed = true,
        .pointer_down = true,
    });
    _ = scaled.update(&scaled_items, &.{}, scaled_viewport, .{
        .pointer_screen = .{ .x = 103.5, .y = 160 },
        .pointer_down = true,
    });
    try std.testing.expectApproxEqAbs(@as(f32, 200), scaled_items[0].position.x, 0.0001);
    try std.testing.expectEqual(@as(?f32, 300), scaled.liveSnapGuides().?.vertical);

    var full_items = [_]slides.SlideItem{
        testItem(1, .textbox, 100, 300, 100, 100),
        testItem(2, .textbox, 300, 700, 100, 100),
    };
    var full: Studio = .{ .enabled = true };
    const full_viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    _ = full.update(&full_items, &.{}, full_viewport, .{
        .pointer_screen = .{ .x = 120, .y = 320 },
        .pointer_pressed = true,
        .pointer_down = true,
    });
    _ = full.update(&full_items, &.{}, full_viewport, .{
        .pointer_screen = .{ .x = 207, .y = 320 },
        .pointer_down = true,
    });
    try std.testing.expectApproxEqAbs(@as(f32, 187), full_items[0].position.x, 0.0001);
    try std.testing.expect(full.liveSnapGuides().?.vertical == null);
}

test "shortcut modifier bypasses snapping and cancel clears guides" {
    var items = [_]slides.SlideItem{
        testItem(1, .textbox, 100, 300, 100, 100),
        testItem(2, .textbox, 300, 700, 100, 100),
    };
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = .{ .x = 960, .y = 540 } };
    var studio: Studio = .{ .enabled = true };
    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 60, .y = 160 },
        .pointer_pressed = true,
        .pointer_down = true,
    });
    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 103.5, .y = 160 },
        .pointer_down = true,
        .disable_snapping = true,
    });
    try std.testing.expectApproxEqAbs(@as(f32, 187), items[0].position.x, 0.0001);
    try std.testing.expect(studio.liveSnapGuides().?.vertical == null);

    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 103.5, .y = 160 },
        .pointer_down = true,
    });
    try std.testing.expectEqual(@as(?f32, 300), studio.liveSnapGuides().?.vertical);
    _ = studio.update(&items, &.{}, viewport, .{ .cancel_pressed = true });
    try std.testing.expectEqual(Interaction.idle, studio.interaction);
    try std.testing.expect(studio.liveSnapGuides() == null);
    try std.testing.expect(studio.snap_guides.vertical == null and studio.snap_guides.horizontal == null);
    try expectVector(.{ .x = 100, .y = 300 }, items[0].position);
}

test "shift resize locks the authored aspect ratio" {
    var items = [_]slides.SlideItem{testItem(1, .textbox, 100, 100, 200, 100)};
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    var studio: Studio = .{ .enabled = true, .selected_identity = 1 };
    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 300, .y = 200 },
        .pointer_pressed = true,
        .pointer_down = true,
    });
    try std.testing.expectEqual(Interaction.resizing, studio.interaction);
    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 400, .y = 220 },
        .pointer_down = true,
        .lock_aspect_ratio = true,
        .disable_snapping = true,
    });
    try expectVector(.{ .x = 300, .y = 150 }, items[0].size);
}

test "grid toggle works from keyboard input and toolbar button" {
    var items: [0]slides.SlideItem = .{};
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    const layout = uiLayout(viewport);
    var studio: Studio = .{ .enabled = true };

    _ = studio.update(&items, &.{}, viewport, .{ .toggle_grid_pressed = true });
    try std.testing.expect(studio.grid_snapping);
    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = rectangleCenter(layout.grid_toggle),
        .pointer_pressed = true,
    });
    try std.testing.expect(!studio.grid_snapping);
}

test "grid toggle on pointer release still finishes the active gesture" {
    var items = [_]slides.SlideItem{testItem(1, .textbox, 100, 300, 200, 100)};
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    var studio: Studio = .{ .enabled = true };
    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 120, .y = 320 },
        .pointer_pressed = true,
        .pointer_down = true,
    });
    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 220, .y = 320 },
        .pointer_down = true,
    });
    const command = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 220, .y = 320 },
        .pointer_released = true,
        .toggle_grid_pressed = true,
    }).?;
    try std.testing.expectEqual(Interaction.idle, studio.interaction);
    try std.testing.expect(studio.grid_snapping);
    try expectVector(.{ .x = 200, .y = 300 }, command.after_position);
}

test "geometry HUD stays inside the slide viewport" {
    const viewport: Viewport = .{
        .slide_top_left = .{ .x = 50, .y = 100 },
        .slide_size = .{ .x = 300, .y = 200 },
    };
    const rect = Studio.geometryHudRectangle(
        viewport,
        .{ .x = 100, .y = 100, .width = 100, .height = 200 },
        160,
        28,
    );
    try std.testing.expect(rect.x >= viewport.slide_top_left.x);
    try std.testing.expect(rect.x + rect.width <= viewport.slide_top_left.x + viewport.slide_size.x);
    try std.testing.expect(rect.y >= viewport.slide_top_left.y);
    try std.testing.expect(rect.y + rect.height <= viewport.slide_top_left.y + viewport.slide_size.y);
}

test "all align actions emit exact slide-relative geometry for resolved bounds" {
    const item = testItem(1, .img, 123, 234, 0, 0);
    var items = [_]slides.SlideItem{item};
    const bounds = [_]ResolvedBounds{.{
        .identity = 1,
        .position = .{ .x = 123, .y = 234 },
        .size = .{ .x = 101, .y = 51 },
    }};
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    const actions = [_]AlignAction{ .left, .horizontal_center, .right, .top, .vertical_center, .bottom };
    const expected = [_]rl.Vector2{
        .{ .x = 0, .y = 234 },
        .{ .x = 909.5, .y = 234 },
        .{ .x = 1819, .y = 234 },
        .{ .x = 123, .y = 0 },
        .{ .x = 123, .y = 514.5 },
        .{ .x = 123, .y = 1029 },
    };

    for (actions, expected) |action, expected_position| {
        items[0] = item;
        var studio: Studio = .{ .enabled = true, .selected_identity = 1 };
        const command = studio.update(&items, &bounds, viewport, .{ .align_action = action }).?;
        try expectVector(expected_position, command.after_position);
        try expectVector(.{ .x = 101, .y = 51 }, command.after_size);
        try std.testing.expectEqual(EditScope.direct, command.edit_scope);
        try expectVector(expected_position, items[0].position);
    }
}

test "Shift click toggles membership and keeps the last added item primary" {
    var items = [_]slides.SlideItem{
        testItem(1, .textbox, 100, 300, 100, 80),
        testItem(2, .textbox, 300, 300, 100, 80),
        testItem(3, .textbox, 500, 300, 100, 80),
    };
    for (&items, 0..) |*item, index| item.source.line_offset = (index + 1) * 10;
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    var studio: Studio = .{ .enabled = true };

    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 120, .y = 320 },
        .pointer_pressed = true,
        .pointer_released = true,
    });
    try std.testing.expectEqual(@as(usize, 1), studio.selectionCount());
    try std.testing.expectEqual(@as(?usize, 1), studio.selectedIdentityAt(0));

    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 320, .y = 320 },
        .pointer_pressed = true,
        .toggle_selection = true,
    });
    try std.testing.expectEqual(@as(usize, 2), studio.selectionCount());
    try std.testing.expectEqual(@as(?usize, 2), studio.selectedIdentityAt(0));
    try std.testing.expectEqual(@as(?usize, 1), studio.selectedIdentityAt(1));

    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 520, .y = 320 },
        .pointer_pressed = true,
        .toggle_selection = true,
    });
    try std.testing.expectEqual(@as(usize, 3), studio.selectionCount());
    try std.testing.expectEqual(@as(?usize, 3), studio.selectedIdentityAt(0));

    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 320, .y = 320 },
        .pointer_pressed = true,
        .toggle_selection = true,
    });
    try std.testing.expectEqual(@as(usize, 2), studio.selectionCount());
    try std.testing.expect(!studio.isIdentitySelected(2));

    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 120, .y = 320 },
        .pointer_pressed = true,
        .pointer_released = true,
    });
    try std.testing.expectEqual(@as(usize, 1), studio.selectionCount());
    try std.testing.expectEqual(@as(?usize, 1), studio.selectedIdentityAt(0));
}

test "select all filters the scene and reports the fixed selection capacity" {
    var items: [66]slides.SlideItem = undefined;
    for (&items, 0..) |*item, index| {
        item.* = testItem(index + 1, .textbox, @floatFromInt(index * 20), 300, 10, 10);
        item.source.line_offset = index + 1;
    }
    items[65].visible = false;
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    var studio: Studio = .{ .enabled = true };

    _ = studio.update(&items, &.{}, viewport, .{ .select_all_pressed = true });
    try std.testing.expectEqual(max_selection_items, studio.selectionCount());
    try std.testing.expectEqual(Notice.selection_capacity_reached, studio.notice);
    try std.testing.expectEqual(@as(?usize, 65), studio.selectedIdentityAt(0));
    try std.testing.expect(!studio.isIdentitySelected(64));
    try std.testing.expect(!studio.isIdentitySelected(66));
    studio.toggleSelectionAt(&items, &.{}, viewport, .{ .x = 1265, .y = 305 }, .{ .x = 1265, .y = 305 });
    try std.testing.expectEqual(max_selection_items, studio.selectionCount());
    try std.testing.expect(!studio.isIdentitySelected(64));
    try std.testing.expectEqual(Notice.selection_capacity_reached, studio.notice);
}

test "group nudge queues one primary-first atomic geometry batch" {
    var items = [_]slides.SlideItem{
        testItem(1, .textbox, 100, 300, 100, 80),
        testItem(2, .textbox, 300, 400, 120, 90),
    };
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    var studio: Studio = .{ .enabled = true };
    setTestSelection(&studio, &items, &.{ 2, 1 });

    try std.testing.expect(studio.update(&items, &.{}, viewport, .{ .nudge = .{ .x = 5, .y = -2 } }) == null);
    try std.testing.expectEqual(@as(usize, 2), studio.peekGeometryBatch().?.count);
    const batch = studio.takeGeometryBatch().?;
    try std.testing.expectEqual(@as(usize, 2), batch.count);
    try std.testing.expectEqual(@as(usize, 2), batch.commands[0].item_identity);
    try std.testing.expectEqual(@as(usize, 1), batch.commands[1].item_identity);
    try expectVector(.{ .x = 305, .y = 398 }, batch.commands[0].after_position);
    try expectVector(.{ .x = 105, .y = 298 }, batch.commands[1].after_position);
    try std.testing.expectEqual(EditScope.direct, batch.commands[0].edit_scope);
    try std.testing.expect(studio.takeGeometryBatch() == null);
}

test "group move previews every member and release queues only the batch" {
    var items = [_]slides.SlideItem{
        testItem(1, .textbox, 100, 300, 100, 80),
        testItem(2, .textbox, 300, 400, 120, 90),
    };
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    var studio: Studio = .{ .enabled = true };
    setTestSelection(&studio, &items, &.{ 2, 1 });

    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 120, .y = 320 },
        .pointer_pressed = true,
        .pointer_down = true,
    });
    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 170, .y = 340 },
        .pointer_down = true,
        .disable_snapping = true,
    });
    try std.testing.expectEqual(Interaction.moving, studio.interaction);
    const primary_preview = studio.livePreviewAt(0).?;
    const other_preview = studio.livePreviewAt(1).?;
    try std.testing.expectEqual(@as(usize, 1), primary_preview.item_identity);
    try std.testing.expectEqual(@as(usize, 2), other_preview.item_identity);
    try expectVector(.{ .x = 150, .y = 320 }, primary_preview.after.position);
    try expectVector(.{ .x = 350, .y = 420 }, other_preview.after.position);
    try std.testing.expect(studio.livePreviewAt(2) == null);

    try std.testing.expect(studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 170, .y = 340 },
        .pointer_released = true,
        .disable_snapping = true,
    }) == null);
    try std.testing.expectEqual(Interaction.idle, studio.interaction);
    const batch = studio.takeGeometryBatch().?;
    try std.testing.expectEqual(@as(usize, 2), batch.count);
    try std.testing.expectEqual(@as(usize, 1), batch.commands[0].item_identity);
    try std.testing.expectEqual(@as(usize, 2), batch.commands[1].item_identity);
}

test "group snap uses union bounds and excludes every selected member" {
    var items = [_]slides.SlideItem{
        testItem(1, .textbox, 100, 300, 100, 80),
        testItem(2, .textbox, 300, 300, 100, 80),
        testItem(3, .textbox, 600, 700, 100, 80),
    };
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    var studio: Studio = .{ .enabled = true };
    setTestSelection(&studio, &items, &.{ 1, 2 });

    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 120, .y = 320 },
        .pointer_pressed = true,
        .pointer_down = true,
    });
    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 125, .y = 320 },
        .pointer_down = true,
    });
    try expectVector(.{ .x = 105, .y = 300 }, items[0].position);
    try expectVector(.{ .x = 305, .y = 300 }, items[1].position);

    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 314, .y = 320 },
        .pointer_down = true,
    });
    try expectVector(.{ .x = 300, .y = 300 }, items[0].position);
    try expectVector(.{ .x = 500, .y = 300 }, items[1].position);
    try std.testing.expectEqual(@as(?f32, 600), studio.liveSnapGuides().?.vertical);
}

test "group cancel restores every authored position and emits no batch" {
    var items = [_]slides.SlideItem{
        testItem(1, .textbox, 100, 300, 100, 80),
        testItem(2, .img, 300, 400, 0, 0),
    };
    const bounds = [_]ResolvedBounds{.{
        .identity = 2,
        .position = .{ .x = 300, .y = 400 },
        .size = .{ .x = 120, .y = 90 },
    }};
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    var studio: Studio = .{ .enabled = true };
    setTestSelection(&studio, &items, &.{ 2, 1 });

    _ = studio.update(&items, &bounds, viewport, .{
        .pointer_screen = .{ .x = 320, .y = 420 },
        .pointer_pressed = true,
        .pointer_down = true,
    });
    _ = studio.update(&items, &bounds, viewport, .{
        .pointer_screen = .{ .x = 370, .y = 450 },
        .pointer_down = true,
        .disable_snapping = true,
    });
    try expectVector(.{ .x = 350, .y = 430 }, items[1].position);
    _ = studio.update(&items, &bounds, viewport, .{ .cancel_pressed = true });
    try std.testing.expectEqual(Interaction.idle, studio.interaction);
    try expectVector(.{ .x = 100, .y = 300 }, items[0].position);
    try expectVector(.{ .x = 300, .y = 400 }, items[1].position);
    try expectVector(.zero(), items[1].size);
    try std.testing.expect(studio.takeGeometryBatch() == null);
    try std.testing.expectEqual(@as(usize, 2), studio.selectionCount());
}

test "multi-selection align modes target the original selection bounds" {
    const original = [_]slides.SlideItem{
        testItem(1, .textbox, 100, 100, 100, 50),
        testItem(2, .textbox, 300, 200, 200, 100),
        testItem(3, .textbox, 600, 400, 50, 150),
    };
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    const actions = [_]AlignAction{ .left, .horizontal_center, .right, .top, .vertical_center, .bottom };
    const expected = [6][3]rl.Vector2{
        .{ .{ .x = 100, .y = 100 }, .{ .x = 100, .y = 200 }, .{ .x = 100, .y = 400 } },
        .{ .{ .x = 325, .y = 100 }, .{ .x = 275, .y = 200 }, .{ .x = 350, .y = 400 } },
        .{ .{ .x = 550, .y = 100 }, .{ .x = 450, .y = 200 }, .{ .x = 600, .y = 400 } },
        .{ .{ .x = 100, .y = 100 }, .{ .x = 300, .y = 100 }, .{ .x = 600, .y = 100 } },
        .{ .{ .x = 100, .y = 300 }, .{ .x = 300, .y = 275 }, .{ .x = 600, .y = 250 } },
        .{ .{ .x = 100, .y = 500 }, .{ .x = 300, .y = 450 }, .{ .x = 600, .y = 400 } },
    };

    for (actions, expected) |action, expected_positions| {
        var items = original;
        var studio: Studio = .{ .enabled = true };
        setTestSelection(&studio, &items, &.{ 2, 1, 3 });
        try std.testing.expect(studio.update(&items, &.{}, viewport, .{ .align_action = action }) == null);
        for (items, expected_positions) |item, expected_position| try expectVector(expected_position, item.position);
        try std.testing.expect(studio.takeGeometryBatch() != null);
    }
}

test "equal-gap distribution sorts geometrically and preserves fractional outer bounds" {
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    var horizontal_items = [_]slides.SlideItem{
        testItem(1, .textbox, 100, 50, 100, 40),
        testItem(2, .textbox, 260, 200, 75, 75),
        testItem(3, .textbox, 600, 500, 50, 50),
    };
    var horizontal: Studio = .{ .enabled = true };
    setTestSelection(&horizontal, &horizontal_items, &.{ 3, 1, 2 });
    _ = horizontal.update(&horizontal_items, &.{}, viewport, .{ .distribute_action = .horizontal });
    try std.testing.expectApproxEqAbs(@as(f32, 100), horizontal_items[0].position.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 362.5), horizontal_items[1].position.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 600), horizontal_items[2].position.x, 0.0001);
    try std.testing.expect(horizontal.takeGeometryBatch() != null);

    var vertical_items = [_]slides.SlideItem{
        testItem(1, .textbox, 100, 50, 100, 40),
        testItem(2, .textbox, 260, 200, 75, 75),
        testItem(3, .textbox, 600, 500, 50, 50),
    };
    var vertical: Studio = .{ .enabled = true };
    setTestSelection(&vertical, &vertical_items, &.{ 3, 1, 2 });
    _ = vertical.update(&vertical_items, &.{}, viewport, .{ .distribute_action = .vertical });
    try std.testing.expectApproxEqAbs(@as(f32, 50), vertical_items[0].position.y, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 257.5), vertical_items[1].position.y, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 500), vertical_items[2].position.y, 0.0001);
    try std.testing.expect(vertical.takeGeometryBatch() != null);
}

test "distribution tie breaks are selection-order independent and negative gaps are exact" {
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    var tied_items = [_]slides.SlideItem{
        testItem(1, .textbox, 100, 300, 50, 40),
        testItem(2, .textbox, 100, 100, 50, 40),
        testItem(3, .textbox, 400, 200, 50, 40),
    };
    var tied: Studio = .{ .enabled = true };
    setTestSelection(&tied, &tied_items, &.{ 1, 3, 2 });
    _ = tied.update(&tied_items, &.{}, viewport, .{ .distribute_action = .horizontal });
    try std.testing.expectApproxEqAbs(@as(f32, 250), tied_items[0].position.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 100), tied_items[1].position.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 400), tied_items[2].position.x, 0.0001);

    var overlapping_items = [_]slides.SlideItem{
        testItem(1, .textbox, 0, 100, 100, 40),
        testItem(2, .textbox, 20, 200, 100, 40),
        testItem(3, .textbox, 50, 300, 100, 40),
    };
    var overlapping: Studio = .{ .enabled = true };
    setTestSelection(&overlapping, &overlapping_items, &.{ 2, 3, 1 });
    _ = overlapping.update(&overlapping_items, &.{}, viewport, .{ .distribute_action = .horizontal });
    try std.testing.expectApproxEqAbs(@as(f32, 0), overlapping_items[0].position.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 25), overlapping_items[1].position.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 50), overlapping_items[2].position.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 150), overlapping_items[2].position.x + overlapping_items[2].size.x, 0.0001);
}

test "distribution requires three selected items and leaves geometry untouched" {
    var items = [_]slides.SlideItem{
        testItem(1, .textbox, 100, 300, 100, 80),
        testItem(2, .textbox, 300, 300, 100, 80),
    };
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    var studio: Studio = .{ .enabled = true };
    setTestSelection(&studio, &items, &.{ 1, 2 });
    _ = studio.update(&items, &.{}, viewport, .{ .distribute_action = .horizontal });
    try std.testing.expectEqual(Notice.distribution_needs_three, studio.notice);
    try std.testing.expect(studio.takeGeometryBatch() == null);
    try expectVector(.{ .x = 100, .y = 300 }, items[0].position);
    try expectVector(.{ .x = 300, .y = 300 }, items[1].position);
}

test "mixed unsafe selection refuses atomically before preview mutation" {
    var items = [_]slides.SlideItem{
        testItem(1, .textbox, 100, 300, 100, 80),
        testItem(2, .textbox, 300, 300, 100, 80),
    };
    items[1].source = .{ .scope = .slide_template, .line_number = 9, .line_offset = 90, .patchable = true };
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    var studio: Studio = .{ .enabled = true };
    setTestSelection(&studio, &items, &.{ 1, 2 });

    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 120, .y = 320 },
        .pointer_pressed = true,
        .pointer_down = true,
    });
    try std.testing.expectEqual(Interaction.idle, studio.interaction);
    try std.testing.expectEqual(Notice.local_override_needs_unique_id, studio.notice);
    try expectVector(.{ .x = 100, .y = 300 }, items[0].position);
    try expectVector(.{ .x = 300, .y = 300 }, items[1].position);
    try std.testing.expect(studio.livePreviewAt(0) == null);
    try std.testing.expect(studio.takeGeometryBatch() == null);

    _ = studio.update(&items, &.{}, viewport, .{ .nudge = .{ .x = 10, .y = 0 } });
    try expectVector(.{ .x = 100, .y = 300 }, items[0].position);
    try expectVector(.{ .x = 300, .y = 300 }, items[1].position);
    try std.testing.expect(studio.takeGeometryBatch() == null);
}

test "any shared-template group member disables instance object guides" {
    var items = [_]slides.SlideItem{
        testItem(1, .textbox, 100, 300, 100, 80),
        testItem(2, .textbox, 300, 300, 100, 80),
        testItem(3, .textbox, 500, 700, 100, 80),
    };
    items[1].source = .{ .scope = .slide_template, .line_number = 9, .line_offset = 90, .patchable = true };
    items[1].id = "shared";
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };

    var local: Studio = .{ .enabled = true };
    setTestSelection(&local, &items, &.{ 1, 2 });
    _ = local.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 120, .y = 320 },
        .pointer_pressed = true,
        .pointer_down = true,
    });
    _ = local.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 214, .y = 320 },
        .pointer_down = true,
    });
    try expectVector(.{ .x = 200, .y = 300 }, items[0].position);
    local.cancelActiveInteraction(&items);

    var shared: Studio = .{ .enabled = true };
    setTestSelection(&shared, &items, &.{ 1, 2 });
    _ = shared.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 120, .y = 320 },
        .pointer_pressed = true,
        .pointer_down = true,
        .allow_shared_edit = true,
    });
    _ = shared.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 214, .y = 320 },
        .pointer_down = true,
    });
    try expectVector(.{ .x = 194, .y = 300 }, items[0].position);
    try std.testing.expect(shared.liveSnapGuides().?.vertical == null);
    _ = shared.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 214, .y = 320 },
        .pointer_released = true,
    });
    const shared_batch = shared.takeGeometryBatch().?;
    try std.testing.expectEqual(EditScope.direct, shared_batch.commands[0].edit_scope);
    try std.testing.expectEqual(EditScope.shared_template, shared_batch.commands[1].edit_scope);
}

test "multi-selection semantic properties are refused without targeting primary" {
    var items = [_]slides.SlideItem{
        testItem(1, .textbox, 100, 300, 100, 80),
        testItem(2, .textbox, 300, 300, 100, 80),
    };
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    var studio: Studio = .{ .enabled = true };
    setTestSelection(&studio, &items, &.{ 1, 2 });

    _ = studio.update(&items, &.{}, viewport, .{ .edit_text_pressed = true });
    try std.testing.expectEqual(Notice.multi_selection_property_unsupported, studio.notice);
    try std.testing.expect(studio.takeSemanticCommand() == null);
    _ = studio.update(&items, &.{}, viewport, .{ .duplicate_slide_pressed = true });
    try std.testing.expectEqual(Notice.multi_selection_property_unsupported, studio.notice);
    try std.testing.expect(studio.takeSemanticCommand() == null);
}

test "multi-selection rebinds primary and members by source after reparse" {
    var items = [_]slides.SlideItem{
        testItem(1, .textbox, 100, 300, 100, 80),
        testItem(2, .textbox, 300, 300, 100, 80),
    };
    items[0].source.line_offset = 10;
    items[1].source.line_offset = 20;
    var studio: Studio = .{ .enabled = true };
    studio.setSingleSelection(items[1]);
    studio.additional_selection[0] = .{ .identity = 1, .source = items[0].source };
    studio.additional_selection_count = 1;

    items[0].identity = 101;
    items[1].identity = 202;
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    _ = studio.update(&items, &.{}, viewport, .{});
    try std.testing.expectEqual(@as(?usize, 202), studio.selectedIdentityAt(0));
    try std.testing.expectEqual(@as(?usize, 101), studio.selectedIdentityAt(1));
}

test "Shift on a single resize handle starts aspect resize instead of toggling selection" {
    var items = [_]slides.SlideItem{testItem(1, .textbox, 100, 100, 200, 100)};
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    var studio: Studio = .{ .enabled = true, .selected_identity = 1 };
    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 300, .y = 200 },
        .pointer_pressed = true,
        .pointer_down = true,
        .toggle_selection = true,
        .lock_aspect_ratio = true,
    });
    try std.testing.expectEqual(Interaction.resizing, studio.interaction);
    try std.testing.expectEqual(@as(usize, 1), studio.selectionCount());
    const command = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 400, .y = 220 },
        .pointer_released = true,
        .toggle_selection = true,
        .lock_aspect_ratio = true,
        .disable_snapping = true,
    }).?;
    try expectVector(.{ .x = 300, .y = 150 }, command.after_size);
}

test "multi-selection primary handle starts a group move and never resizes" {
    var items = [_]slides.SlideItem{
        testItem(1, .textbox, 100, 100, 200, 100),
        testItem(2, .textbox, 500, 300, 100, 80),
    };
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    var studio: Studio = .{ .enabled = true };
    setTestSelection(&studio, &items, &.{ 1, 2 });
    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 300, .y = 200 },
        .pointer_pressed = true,
        .pointer_down = true,
    });
    try std.testing.expectEqual(Interaction.moving, studio.interaction);
    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 350, .y = 220 },
        .pointer_released = true,
        .disable_snapping = true,
    });
    try expectVector(.{ .x = 200, .y = 100 }, items[0].size);
    try expectVector(.{ .x = 100, .y = 80 }, items[1].size);
    const batch = studio.takeGeometryBatch().?;
    for (batch.slice()) |command| try std.testing.expect(!command.resized);
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
        // The scope is captured when the gesture begins; releasing Alt before
        // the mouse button must not redirect a shared edit into the instance.
        .allow_shared_edit = false,
    }).?;
    try std.testing.expect(!command.resized);
    try std.testing.expectEqual(SourceScope.slide_template, command.source.scope);
    try std.testing.expectEqual(EditScope.shared_template, command.edit_scope);
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

test "idless template geometry is local-read-only but Alt edits shared" {
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
    try std.testing.expectEqual(Notice.local_override_needs_unique_id, studio.notice);

    const command = studio.update(&items, &.{}, viewport, .{
        .nudge = .{ .x = 10, .y = 0 },
        .allow_shared_edit = true,
    }).?;
    try std.testing.expectEqual(slides.SourceScope.slide_template, command.source.scope);
    try std.testing.expectEqual(EditScope.shared_template, command.edit_scope);
    try expectVector(.{ .x = 110, .y = 100 }, command.after_position);
}

test "identified template geometry defaults to a local instance override" {
    var items = [_]slides.SlideItem{testItem(73, .textbox, 100, 100, 300, 100)};
    items[0].source = .{ .scope = .slide_template, .line_number = 5, .line_offset = 44, .patchable = true };
    items[0].id = "hero";
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    var studio: Studio = .{ .enabled = true, .selected_identity = 73 };

    const nudge = studio.update(&items, &.{}, viewport, .{ .nudge = .{ .x = 4, .y = -2 } }).?;
    try std.testing.expectEqual(EditScope.local_instance, nudge.edit_scope);
    try std.testing.expectEqual(slides.SourceScope.slide_template, nudge.source.scope);
    try expectVector(.{ .x = 104, .y = 98 }, nudge.after_position);

    items[0].position = .{ .x = 100, .y = 100 };
    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 400, .y = 200 },
        .pointer_pressed = true,
        .pointer_down = true,
    });
    try std.testing.expectEqual(Interaction.resizing, studio.interaction);
    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 440, .y = 230 },
        .pointer_down = true,
    });
    const resize = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 440, .y = 230 },
        .pointer_released = true,
    }).?;
    try std.testing.expect(resize.resized);
    try std.testing.expectEqual(EditScope.local_instance, resize.edit_scope);
    try expectVector(.{ .x = 340, .y = 130 }, resize.after_size);
}

test "duplicate template IDs cannot create an ambiguous local override" {
    var items = [_]slides.SlideItem{
        testItem(731, .textbox, 100, 100, 300, 100),
        testItem(732, .textbox, 500, 100, 300, 100),
    };
    for (&items) |*item| {
        item.source = .{ .scope = .slide_template, .line_number = 5, .line_offset = 44, .patchable = true };
        item.id = "hero";
    }
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    var studio: Studio = .{ .enabled = true, .selected_identity = 731 };

    try std.testing.expect(studio.update(&items, &.{}, viewport, .{ .nudge = .{ .x = 4, .y = 0 } }) == null);
    try std.testing.expectEqual(Notice.local_override_needs_unique_id, studio.notice);
    try expectVector(.{ .x = 100, .y = 100 }, items[0].position);
}

test "local template geometry targets an existing instance override" {
    var items = [_]slides.SlideItem{testItem(74, .textbox, 100, 100, 300, 100)};
    items[0].id = "hero";
    items[0].source = .{ .scope = .slide_template, .line_number = 4, .line_offset = 40, .patchable = true };
    items[0].instance_source = .{ .scope = .slide_instance_override, .line_number = 12, .line_offset = 180, .patchable = true };
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    var studio: Studio = .{ .enabled = true, .selected_identity = 74 };

    const command = studio.update(&items, &.{}, viewport, .{ .nudge = .{ .x = 1, .y = 0 } }).?;
    try std.testing.expectEqual(EditScope.local_instance, command.edit_scope);
    try std.testing.expectEqual(slides.SourceScope.slide_instance_override, command.source.scope);
    try std.testing.expectEqual(@as(usize, 180), command.source.line_offset);
}

test "a customized instance emits shared nudge and text edits from the authored layer" {
    var items = [_]slides.SlideItem{testItem(76, .textbox, 500, 100, 300, 100)};
    items[0].id = "hero";
    items[0].source = .{ .scope = .slide_template, .line_number = 4, .line_offset = 40, .patchable = true };
    items[0].instance_source = .{ .scope = .slide_instance_override, .line_number = 12, .line_offset = 180, .patchable = true };
    items[0].shared_template_values = .{
        .position = .{ .x = 100, .y = 80 },
        .size = .{ .x = 260, .y = 90 },
        .text = "Shared hero",
    };
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    var studio: Studio = .{ .enabled = true, .selected_identity = 76 };

    const nudge = studio.update(&items, &.{}, viewport, .{
        .nudge = .{ .x = 10, .y = 0 },
        .allow_shared_edit = true,
    }).?;
    try expectVector(.{ .x = 500, .y = 100 }, nudge.after_position);
    try expectVector(.{ .x = 500, .y = 100 }, items[0].position);
    try expectVector(.{ .x = 110, .y = 80 }, nudge.source_after_position.?);
    try std.testing.expectEqual(Notice.shared_template_customized, studio.notice);

    _ = studio.update(&items, &.{}, viewport, .{
        .edit_text_pressed = true,
        .allow_shared_edit = true,
    });
    switch (studio.takeSemanticCommand().?) {
        .edit_text => |target| try std.testing.expectEqual(EditScope.shared_template, target.edit_scope),
        else => return error.UnexpectedSemanticCommand,
    }
    try std.testing.expectEqual(Notice.shared_template_customized, studio.notice);
}

test "customized shared move and resize keep display preview geometry separate from source targets" {
    var items = [_]slides.SlideItem{testItem(761, .textbox, 500, 100, 300, 100)};
    items[0].id = "hero";
    items[0].source = .{ .scope = .slide_template, .line_number = 4, .line_offset = 40, .patchable = true };
    items[0].instance_source = .{ .scope = .slide_instance_override, .line_number = 12, .line_offset = 180, .patchable = true };
    items[0].shared_template_values = .{
        .position = .{ .x = 100, .y = 80 },
        .size = .{ .x = 250, .y = 80 },
    };
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    var studio: Studio = .{ .enabled = true };

    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 550, .y = 130 },
        .pointer_pressed = true,
        .pointer_down = true,
        .allow_shared_edit = true,
        .disable_snapping = true,
    });
    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 580, .y = 150 },
        .pointer_down = true,
        .allow_shared_edit = true,
        .disable_snapping = true,
    });
    const live = studio.livePreview().?;
    try expectVector(live.before.position, live.after.position);
    try expectVector(.{ .x = 500, .y = 100 }, items[0].position);
    try expectVector(.{ .x = 130, .y = 100 }, studio.drag.source_after.position);
    const move = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 580, .y = 150 },
        .pointer_released = true,
        .allow_shared_edit = true,
        .disable_snapping = true,
    }).?;
    try expectVector(.{ .x = 500, .y = 100 }, move.after_position);
    try expectVector(move.before_position, move.after_position);
    try expectVector(.{ .x = 130, .y = 100 }, move.source_after_position.?);
    try std.testing.expect(move.source_after_size == null);

    // Simulate reparse: the local instance override still supplies the
    // effective geometry while the shared layer reflects the persisted move.
    items[0].position = .{ .x = 500, .y = 100 };
    items[0].size = .{ .x = 300, .y = 100 };
    items[0].shared_template_values.?.position = move.source_after_position.?;
    studio.selected_identity = 761;
    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 800, .y = 200 },
        .pointer_pressed = true,
        .pointer_down = true,
        .allow_shared_edit = true,
    });
    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 830, .y = 220 },
        .pointer_down = true,
        .allow_shared_edit = true,
        .disable_snapping = true,
    });
    const resize = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 830, .y = 220 },
        .pointer_released = true,
        .allow_shared_edit = true,
        .disable_snapping = true,
    }).?;
    try expectVector(.{ .x = 300, .y = 100 }, resize.after_size);
    try expectVector(resize.before_size, resize.after_size);
    try expectVector(.{ .x = 275, .y = 96 }, resize.source_after_size.?);
    try expectVector(.{ .x = 130, .y = 100 }, resize.source_after_position.?);
}

test "customized shared align uses authored template geometry" {
    var items = [_]slides.SlideItem{testItem(762, .textbox, 400, 100, 600, 120)};
    items[0].id = "hero";
    items[0].source = .{ .scope = .slide_template, .line_number = 4, .line_offset = 40, .patchable = true };
    items[0].instance_source = .{ .scope = .slide_instance_override, .line_number = 12, .line_offset = 180, .patchable = true };
    items[0].shared_template_values = .{
        .position = .{ .x = 100, .y = 80 },
        .size = .{ .x = 300, .y = 100 },
    };
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    var studio: Studio = .{ .enabled = true, .selected_identity = 762 };

    const command = studio.update(&items, &.{}, viewport, .{
        .align_action = .horizontal_center,
        .allow_shared_edit = true,
    }).?;
    try expectVector(.{ .x = 400, .y = 100 }, command.after_position);
    try expectVector(command.before_position, command.after_position);
    try expectVector(.{ .x = 810, .y = 80 }, command.source_after_position.?);
}

test "group align uses shared authored geometry while customized display stays stable" {
    var items = [_]slides.SlideItem{
        testItem(765, .textbox, 1000, 100, 400, 100),
        testItem(766, .textbox, 300, 200, 200, 100),
        testItem(767, .textbox, 800, 300, 100, 100),
    };
    items[0].id = "custom";
    items[0].source = .{ .scope = .slide_template, .line_number = 4, .line_offset = 40, .patchable = true };
    items[0].instance_source = .{ .scope = .slide_instance_override, .line_number = 20, .line_offset = 200, .patchable = true };
    items[0].shared_template_values = .{ .position = .{ .x = 100, .y = 100 }, .size = .{ .x = 100, .y = 100 } };
    items[1].id = "ordinary";
    items[1].source = .{ .scope = .slide_template, .line_number = 5, .line_offset = 50, .patchable = true };
    items[1].shared_template_values = .{ .position = items[1].position, .size = items[1].size };
    items[2].id = "direct";
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    var studio: Studio = .{ .enabled = true };
    setTestSelection(&studio, &items, &.{ 765, 766, 767 });

    try std.testing.expect(studio.update(&items, &.{}, viewport, .{
        .align_action = .horizontal_center,
        .allow_shared_edit = true,
    }) == null);
    const batch = studio.takeGeometryBatch().?;
    try std.testing.expectEqual(@as(usize, 3), batch.count);
    var customized: ?GeometryCommand = null;
    var ordinary: ?GeometryCommand = null;
    var direct: ?GeometryCommand = null;
    for (batch.slice()) |command| switch (command.item_identity) {
        765 => customized = command,
        766 => ordinary = command,
        767 => direct = command,
        else => return error.UnexpectedGeometryCommand,
    };
    try expectVector(.{ .x = 1000, .y = 100 }, items[0].position);
    try expectVector(customized.?.before_position, customized.?.after_position);
    try expectVector(.{ .x = 450, .y = 100 }, customized.?.source_after_position.?);
    try std.testing.expectEqual(EditScope.shared_template, customized.?.edit_scope);
    try expectVector(.{ .x = 400, .y = 200 }, ordinary.?.after_position);
    try std.testing.expect(ordinary.?.source_after_position == null);
    try std.testing.expectEqual(EditScope.shared_template, ordinary.?.edit_scope);
    try expectVector(.{ .x = 450, .y = 300 }, direct.?.after_position);
    try std.testing.expectEqual(EditScope.direct, direct.?.edit_scope);
    try std.testing.expectEqual(Notice.shared_template_customized, studio.notice);
}

test "group distribution uses shared layout and supports a direct auto-sized member" {
    var items = [_]slides.SlideItem{
        testItem(768, .textbox, 0, 100, 50, 100),
        testItem(769, .textbox, 900, 200, 500, 100),
        testItem(770, .textbox, 350, 300, 100, 100),
        testItem(771, .img, 700, 400, 0, 0),
    };
    items[0].id = "first";
    items[1].id = "custom";
    items[1].source = .{ .scope = .slide_template, .line_number = 4, .line_offset = 40, .patchable = true };
    items[1].instance_source = .{ .scope = .slide_instance_override, .line_number = 20, .line_offset = 200, .patchable = true };
    items[1].shared_template_values = .{ .position = .{ .x = 150, .y = 200 }, .size = .{ .x = 100, .y = 100 } };
    items[2].id = "ordinary";
    items[2].source = .{ .scope = .slide_template, .line_number = 5, .line_offset = 50, .patchable = true };
    items[2].shared_template_values = .{ .position = items[2].position, .size = items[2].size };
    items[3].id = "auto";
    const bounds = [_]ResolvedBounds{.{
        .identity = 771,
        .position = .{ .x = 700, .y = 400 },
        .size = .{ .x = 50, .y = 100 },
    }};
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    var studio: Studio = .{ .enabled = true };
    setTestSelection(&studio, &items, &.{ 768, 769, 770, 771 });

    _ = studio.update(&items, &bounds, viewport, .{
        .distribute_action = .horizontal,
        .allow_shared_edit = true,
    });
    const batch = studio.takeGeometryBatch().?;
    try std.testing.expectEqual(@as(usize, 2), batch.count);
    var customized: ?GeometryCommand = null;
    var ordinary: ?GeometryCommand = null;
    for (batch.slice()) |command| switch (command.item_identity) {
        769 => customized = command,
        770 => ordinary = command,
        else => return error.UnexpectedGeometryCommand,
    };
    try expectVector(.{ .x = 900, .y = 200 }, items[1].position);
    try expectVector(customized.?.before_position, customized.?.after_position);
    try expectVector(.{ .x = 200, .y = 200 }, customized.?.source_after_position.?);
    try expectVector(.{ .x = 450, .y = 300 }, ordinary.?.after_position);
    try std.testing.expect(ordinary.?.source_after_position == null);
    try expectVector(.{ .x = 700, .y = 400 }, items[3].position);
}

test "customized shared semantic colors and delete retain the shared target" {
    var items = [_]slides.SlideItem{testItem(763, .textbox, 500, 100, 300, 100)};
    items[0].id = "hero";
    items[0].source = .{ .scope = .slide_template, .line_number = 4, .line_offset = 40, .patchable = true };
    items[0].instance_source = .{ .scope = .slide_instance_override, .line_number = 12, .line_offset = 180, .patchable = true };
    items[0].shared_template_values = .{
        .text = "Shared hero",
        .color = .white,
        .background_color = .black,
        .position = .{ .x = 100, .y = 80 },
        .size = .{ .x = 260, .y = 90 },
    };
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    var studio: Studio = .{ .enabled = true, .selected_identity = 763 };

    _ = studio.update(&items, &.{}, viewport, .{ .foreground_color = .orange, .allow_shared_edit = true });
    switch (studio.takeSemanticCommand().?) {
        .set_foreground => |command| try std.testing.expectEqual(EditScope.shared_template, command.target.edit_scope),
        else => return error.UnexpectedSemanticCommand,
    }
    _ = studio.update(&items, &.{}, viewport, .{ .background_color = .blue, .allow_shared_edit = true });
    switch (studio.takeSemanticCommand().?) {
        .set_background => |command| try std.testing.expectEqual(EditScope.shared_template, command.target.edit_scope),
        else => return error.UnexpectedSemanticCommand,
    }
    _ = studio.update(&items, &.{}, viewport, .{ .delete_pressed = true, .allow_shared_edit = true });
    switch (studio.takeSemanticCommand().?) {
        .delete_item => |target| try std.testing.expectEqual(EditScope.shared_template, target.edit_scope),
        else => return error.UnexpectedSemanticCommand,
    }
}

test "customized shared resize refuses an auto-sized authored layer" {
    var items = [_]slides.SlideItem{testItem(764, .img, 500, 100, 300, 100)};
    items[0].id = "hero";
    items[0].source = .{ .scope = .slide_template, .line_number = 4, .line_offset = 40, .patchable = true };
    items[0].instance_source = .{ .scope = .slide_instance_override, .line_number = 12, .line_offset = 180, .patchable = true };
    items[0].shared_template_values = .{ .position = .{ .x = 100, .y = 80 }, .size = .zero() };
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    var studio: Studio = .{ .enabled = true, .selected_identity = 764 };

    try std.testing.expect(studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 800, .y = 200 },
        .pointer_pressed = true,
        .pointer_down = true,
        .allow_shared_edit = true,
    }) == null);
    try std.testing.expectEqual(Interaction.idle, studio.interaction);
    try std.testing.expectEqual(Notice.shared_template_auto_size, studio.notice);
}

test "template status labels distinguish local and shared destinations" {
    var item = testItem(75, .textbox, 100, 100, 300, 100);
    item.source = .{ .scope = .slide_template, .line_number = 4, .line_offset = 40, .patchable = true };
    item.id = "hero";
    var studio: Studio = .{ .enabled = true };

    try std.testing.expectEqualStrings("local instance override; Alt edits shared template", studio.editDestinationLabel(item));
    item.instance_source = .{ .scope = .slide_instance_override, .patchable = true };
    try std.testing.expectEqualStrings("local override active; Alt edits shared template", studio.editDestinationLabel(item));
    item.instance_source = null;
    item.id = null;
    try std.testing.expectEqualStrings("shared template; add id for local edit (Alt edits shared)", studio.editDestinationLabel(item));

    studio.interaction = .moving;
    studio.drag.edit_scope = .shared_template;
    try std.testing.expectEqualStrings("editing shared template (Alt)", studio.editDestinationLabel(item));
    item.instance_source = .{ .scope = .slide_instance_override, .patchable = true };
    try std.testing.expectEqualStrings(
        "editing shared template (Alt) · local override remains",
        studio.editDestinationLabel(item),
    );
    studio.drag.edit_scope = .local_instance;
    try std.testing.expectEqualStrings("editing local instance override", studio.editDestinationLabel(item));
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

test "duplicate shortcut targets an item and falls back to the current slide" {
    var items = [_]slides.SlideItem{testItem(181, .textbox, 100, 100, 300, 100)};
    items[0].source = .{ .scope = .direct, .line_number = 7, .line_offset = 72, .patchable = true };
    const summaries = [_]SlideSummary{.{ .index = 4 }};
    const workspace: Workspace = .{ .visible = true, .slides = &summaries, .current_slide = 4 };
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    var studio: Studio = .{ .enabled = true, .selected_identity = 181 };

    _ = studio.updateWithWorkspace(&items, &.{}, viewport, workspace, .{ .duplicate_slide_pressed = true });
    switch (studio.takeSemanticCommand().?) {
        .duplicate_item => |target| {
            try std.testing.expectEqual(@as(usize, 181), target.item_identity);
            try std.testing.expectEqual(EditScope.direct, target.edit_scope);
            try std.testing.expectEqual(@as(usize, 72), target.source.line_offset);
        },
        else => return error.UnexpectedSemanticCommand,
    }

    studio.clearSelection(&items);
    _ = studio.updateWithWorkspace(&items, &.{}, viewport, workspace, .{ .duplicate_slide_pressed = true });
    switch (studio.takeSemanticCommand().?) {
        .duplicate_slide => |slide_index| try std.testing.expectEqual(@as(usize, 4), slide_index),
        else => return error.UnexpectedSemanticCommand,
    }
}

test "duplicate property button dispatches the selected direct item" {
    var items = [_]slides.SlideItem{testItem(182, .textbox, 100, 100, 300, 100)};
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    const layout = uiLayout(viewport);
    var studio: Studio = .{ .enabled = true, .selected_identity = 182 };

    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = rectangleCenter(layout.duplicate_item),
        .pointer_pressed = true,
    });
    switch (studio.takeSemanticCommand().?) {
        .duplicate_item => |target| try std.testing.expectEqual(@as(usize, 182), target.item_identity),
        else => return error.UnexpectedSemanticCommand,
    }
}

test "template duplication is shared-only including customized instances" {
    var items = [_]slides.SlideItem{testItem(183, .textbox, 100, 100, 300, 100)};
    items[0].source = .{ .scope = .slide_template, .line_number = 9, .line_offset = 99, .patchable = true };
    items[0].id = "hero";
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    var studio: Studio = .{ .enabled = true, .selected_identity = 183 };

    _ = studio.update(&items, &.{}, viewport, .{ .duplicate_slide_pressed = true });
    try std.testing.expect(studio.takeSemanticCommand() == null);
    try std.testing.expectEqual(Notice.duplicate_item_unsupported, studio.notice);

    _ = studio.update(&items, &.{}, viewport, .{ .duplicate_slide_pressed = true, .allow_shared_edit = true });
    switch (studio.takeSemanticCommand().?) {
        .duplicate_item => |target| try std.testing.expectEqual(EditScope.shared_template, target.edit_scope),
        else => return error.UnexpectedSemanticCommand,
    }

    items[0].instance_source = .{ .scope = .slide_instance_override, .line_number = 20, .line_offset = 220, .patchable = true };
    items[0].shared_template_values = .{ .position = items[0].position, .size = items[0].size };
    _ = studio.update(&items, &.{}, viewport, .{ .duplicate_slide_pressed = true, .allow_shared_edit = true });
    switch (studio.takeSemanticCommand().?) {
        .duplicate_item => |target| try std.testing.expectEqual(EditScope.shared_template, target.edit_scope),
        else => return error.UnexpectedSemanticCommand,
    }
}

test "morph duplication allows only an unmodified current-state birth" {
    var items = [_]slides.SlideItem{testItem(184, .textbox, 100, 100, 300, 100)};
    items[0].source = .{ .scope = .morph_item, .line_number = 5, .line_offset = 50, .patchable = true };
    items[0].creation_morph_state = 0;
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    var studio: Studio = .{
        .enabled = true,
        .selected_identity = 184,
        .active_morph_state = 0,
        .morph_state_count = 2,
    };

    _ = studio.update(&items, &.{}, viewport, .{ .duplicate_slide_pressed = true });
    switch (studio.takeSemanticCommand().?) {
        .duplicate_item => |target| try std.testing.expectEqual(EditScope.direct, target.edit_scope),
        else => return error.UnexpectedSemanticCommand,
    }

    items[0].state_source = .{ .scope = .morph_item, .line_number = 6, .line_offset = 60, .patchable = true };
    items[0].state_source_state = 0;
    _ = studio.update(&items, &.{}, viewport, .{ .duplicate_slide_pressed = true });
    try std.testing.expect(studio.takeSemanticCommand() == null);
    try std.testing.expectEqual(Notice.duplicate_item_unsupported, studio.notice);

    items[0].state_source = null;
    items[0].state_source_state = null;
    studio.active_morph_state = 1;
    _ = studio.update(&items, &.{}, viewport, .{ .duplicate_slide_pressed = true });
    try std.testing.expect(studio.takeSemanticCommand() == null);
    try std.testing.expectEqual(Notice.duplicate_item_unsupported, studio.notice);
}

test "identified template text edits default local and Alt selects shared" {
    var items = [_]slides.SlideItem{testItem(82, .textbox, 100, 100, 300, 100)};
    items[0].source = .{ .scope = .slide_template, .line_number = 9, .line_offset = 99, .patchable = true };
    items[0].id = "hero";
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    var studio: Studio = .{ .enabled = true, .selected_identity = 82 };

    _ = studio.update(&items, &.{}, viewport, .{ .edit_text_pressed = true });
    switch (studio.takeSemanticCommand().?) {
        .edit_text => |target| {
            try std.testing.expectEqual(@as(usize, 82), target.item_identity);
            try std.testing.expectEqual(EditScope.local_instance, target.edit_scope);
        },
        else => return error.UnexpectedSemanticCommand,
    }

    _ = studio.update(&items, &.{}, viewport, .{ .edit_text_pressed = true, .allow_shared_edit = true });
    switch (studio.takeSemanticCommand().?) {
        .edit_text => |target| {
            try std.testing.expectEqual(@as(usize, 82), target.item_identity);
            try std.testing.expectEqual(EditScope.shared_template, target.edit_scope);
        },
        else => return error.UnexpectedSemanticCommand,
    }
}

test "identified template delete and foreground color emit local targets" {
    var items = [_]slides.SlideItem{testItem(89, .textbox, 100, 100, 300, 100)};
    items[0].source = .{ .scope = .slide_template, .line_number = 9, .line_offset = 99, .patchable = true };
    items[0].id = "hero";
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    var studio: Studio = .{ .enabled = true, .selected_identity = 89 };

    _ = studio.update(&items, &.{}, viewport, .{ .delete_pressed = true });
    switch (studio.takeSemanticCommand().?) {
        .delete_item => |target| {
            try std.testing.expectEqual(EditScope.local_instance, target.edit_scope);
            try std.testing.expectEqual(@as(usize, 89), target.item_identity);
        },
        else => return error.UnexpectedSemanticCommand,
    }

    _ = studio.update(&items, &.{}, viewport, .{ .foreground_color = .orange });
    switch (studio.takeSemanticCommand().?) {
        .set_foreground => |command| {
            try std.testing.expectEqual(PaletteColor.orange, command.color);
            try std.testing.expectEqual(EditScope.local_instance, command.target.edit_scope);
        },
        else => return error.UnexpectedSemanticCommand,
    }
}

test "template background color emits local and shared targets" {
    var items = [_]slides.SlideItem{testItem(90, .textbox, 100, 100, 300, 100)};
    items[0].source = .{ .scope = .slide_template, .line_number = 9, .line_offset = 99, .patchable = true };
    items[0].id = "hero";
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    var studio: Studio = .{ .enabled = true, .selected_identity = 90 };

    _ = studio.update(&items, &.{}, viewport, .{ .background_color = .blue });
    switch (studio.takeSemanticCommand().?) {
        .set_background => |command| {
            try std.testing.expectEqual(PaletteColor.blue, command.color);
            try std.testing.expectEqual(EditScope.local_instance, command.target.edit_scope);
        },
        else => return error.UnexpectedSemanticCommand,
    }

    _ = studio.update(&items, &.{}, viewport, .{ .background_color = .blue, .allow_shared_edit = true });
    switch (studio.takeSemanticCommand().?) {
        .set_background => |command| {
            try std.testing.expectEqual(PaletteColor.blue, command.color);
            try std.testing.expectEqual(EditScope.shared_template, command.target.edit_scope);
        },
        else => return error.UnexpectedSemanticCommand,
    }
}

test "background clear emits direct local and shared targets and stays base-scene only" {
    var items = [_]slides.SlideItem{testItem(901, .textbox, 100, 100, 300, 100)};
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    var studio: Studio = .{ .enabled = true, .selected_identity = 901 };

    _ = studio.update(&items, &.{}, viewport, .{ .clear_background_pressed = true });
    switch (studio.takeSemanticCommand().?) {
        .clear_background => |target| try std.testing.expectEqual(EditScope.direct, target.edit_scope),
        else => return error.UnexpectedSemanticCommand,
    }

    items[0].id = "hero";
    items[0].source = .{ .scope = .slide_template, .line_number = 9, .line_offset = 99, .patchable = true };
    items[0].shared_template_values = .{ .position = items[0].position, .size = items[0].size, .background_color = .blue };
    _ = studio.update(&items, &.{}, viewport, .{ .clear_background_pressed = true });
    switch (studio.takeSemanticCommand().?) {
        .clear_background => |target| try std.testing.expectEqual(EditScope.local_instance, target.edit_scope),
        else => return error.UnexpectedSemanticCommand,
    }
    _ = studio.update(&items, &.{}, viewport, .{ .clear_background_pressed = true, .allow_shared_edit = true });
    switch (studio.takeSemanticCommand().?) {
        .clear_background => |target| try std.testing.expectEqual(EditScope.shared_template, target.edit_scope),
        else => return error.UnexpectedSemanticCommand,
    }

    studio.active_morph_state = 0;
    studio.morph_state_count = 1;
    _ = studio.update(&items, &.{}, viewport, .{ .clear_background_pressed = true });
    try std.testing.expect(studio.takeSemanticCommand() == null);
    try std.testing.expectEqual(Notice.base_scene_only, studio.notice);

    studio.active_morph_state = null;
    const layout = uiLayout(viewport);
    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = rectangleCenter(layout.clear_background),
        .pointer_pressed = true,
    });
    try std.testing.expect(std.meta.activeTag(studio.takeSemanticCommand().?) == .clear_background);
}

test "idless template semantic actions need IDs but Alt can delete shared" {
    var items = [_]slides.SlideItem{testItem(91, .textbox, 100, 100, 300, 100)};
    items[0].source = .{ .scope = .slide_template, .line_number = 9, .line_offset = 99, .patchable = true };
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    var studio: Studio = .{ .enabled = true, .selected_identity = 91 };

    _ = studio.update(&items, &.{}, viewport, .{ .delete_pressed = true });
    try std.testing.expect(studio.takeSemanticCommand() == null);
    try std.testing.expectEqual(Notice.local_override_needs_unique_id, studio.notice);

    _ = studio.update(&items, &.{}, viewport, .{ .delete_pressed = true, .allow_shared_edit = true });
    switch (studio.takeSemanticCommand().?) {
        .delete_item => |target| {
            try std.testing.expectEqual(EditScope.shared_template, target.edit_scope);
            try std.testing.expectEqual(@as(usize, 99), target.source.line_offset);
        },
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
    try std.testing.expectEqual(Notice.local_override_needs_unique_id, inherited.notice);

    items[0].id = "born";
    const inherited_command = inherited.update(&items, &.{}, viewport, .{ .nudge = .{ .x = 1, .y = 0 } }).?;
    try std.testing.expectEqual(EditScope.direct, inherited_command.edit_scope);
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

    _ = studio.updateWithWorkspace(&items, &.{}, viewport, workspace, .{
        .pointer_screen = rectangleCenter(layout.organizer_actions[5]),
        .pointer_pressed = true,
    });
    switch (studio.takeSemanticCommand().?) {
        .promote_slide_to_template => |index| try std.testing.expectEqual(@as(usize, 20), index),
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

test "library selection persists while Use places elements or creates template slides" {
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
    try std.testing.expectEqual(Tool.select, studio.tool);
    try std.testing.expectEqual(@as(?usize, 0), studio.selected_library_index);
    try std.testing.expect(studio.takeSemanticCommand() == null);

    _ = studio.updateWithWorkspace(&items, &.{}, viewport, workspace, .{
        .pointer_screen = rectangleCenter(layout.library_use),
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
    try std.testing.expectEqual(@as(?usize, 1), studio.selected_library_index);
    try std.testing.expect(studio.takeSemanticCommand() == null);

    _ = studio.updateWithWorkspace(&items, &.{}, viewport, workspace, .{
        .pointer_screen = rectangleCenter(layout.library_use),
        .pointer_pressed = true,
    });
    switch (studio.takeSemanticCommand().?) {
        .new_slide_from_template => |entry_index| try std.testing.expectEqual(@as(usize, 1), entry_index),
        else => return error.UnexpectedSemanticCommand,
    }
}

test "library management buttons and shortcuts target the persistent selection" {
    var items = [_]slides.SlideItem{testItem(130, .textbox, 100, 100, 200, 80)};
    const summaries = [_]SlideSummary{.{ .index = 0 }};
    const entries = [_]LibraryEntry{
        .{ .kind = .element, .name = "card", .deletable = true },
        .{ .kind = .slide_template, .name = "chapter" },
    };
    const workspace: Workspace = .{ .visible = true, .slides = &summaries, .current_slide = 0, .library = &entries };
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    const layout = workspaceLayout(viewport);
    var studio: Studio = .{ .enabled = true, .selected_identity = 130 };

    _ = studio.updateWithWorkspace(&items, &.{}, viewport, workspace, .{
        .pointer_screen = rectangleCenter(libraryRowRect(layout, 1).?),
        .pointer_pressed = true,
    });
    try std.testing.expectEqual(@as(?usize, 1), studio.selected_library_index);
    try std.testing.expectEqual(@as(?usize, 130), studio.selected_identity);

    _ = studio.updateWithWorkspace(&items, &.{}, viewport, workspace, .{
        .pointer_screen = rectangleCenter(layout.library_rename),
        .pointer_pressed = true,
    });
    try std.testing.expectEqual(@as(?usize, null), studio.selected_identity);
    try std.testing.expectEqual(@as(?usize, 1), studio.selected_library_index);
    switch (studio.takeSemanticCommand().?) {
        .rename_library_entry => |entry_index| try std.testing.expectEqual(@as(usize, 1), entry_index),
        else => return error.UnexpectedSemanticCommand,
    }

    _ = studio.updateWithWorkspace(&items, &.{}, viewport, workspace, .{ .delete_library_pressed = true });
    try std.testing.expect(studio.takeSemanticCommand() == null);
    try std.testing.expectEqual(Notice.library_delete_unsupported, studio.notice);

    _ = studio.updateWithWorkspace(&items, &.{}, viewport, workspace, .{
        .pointer_screen = rectangleCenter(libraryRowRect(layout, 0).?),
        .pointer_pressed = true,
    });
    _ = studio.updateWithWorkspace(&items, &.{}, viewport, workspace, .{ .delete_library_pressed = true });
    switch (studio.takeSemanticCommand().?) {
        .delete_library_entry => |entry_index| try std.testing.expectEqual(@as(usize, 0), entry_index),
        else => return error.UnexpectedSemanticCommand,
    }

    _ = studio.updateWithWorkspace(&items, &.{}, viewport, workspace, .{ .rename_library_pressed = true });
    switch (studio.takeSemanticCommand().?) {
        .rename_library_entry => |entry_index| try std.testing.expectEqual(@as(usize, 0), entry_index),
        else => return error.UnexpectedSemanticCommand,
    }
}

test "library Enter activation yields to selected canvas item editing" {
    var items = [_]slides.SlideItem{testItem(131, .textbox, 100, 100, 200, 80)};
    const summaries = [_]SlideSummary{.{ .index = 0 }};
    const entries = [_]LibraryEntry{.{ .kind = .element, .name = "card" }};
    const workspace: Workspace = .{ .visible = true, .slides = &summaries, .current_slide = 0, .library = &entries };
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    var studio: Studio = .{ .enabled = true, .selected_identity = 131, .selected_library_index = 0, .last_workspace_slide = 0 };

    _ = studio.updateWithWorkspace(&items, &.{}, viewport, workspace, .{
        .use_library_pressed = true,
        .edit_text_pressed = true,
    });
    try std.testing.expectEqual(Tool.select, studio.tool);
    switch (studio.takeSemanticCommand().?) {
        .edit_text => |target| try std.testing.expectEqual(@as(usize, 131), target.item_identity),
        else => return error.UnexpectedSemanticCommand,
    }

    studio.selected_identity = null;
    _ = studio.updateWithWorkspace(&items, &.{}, viewport, workspace, .{
        .use_library_pressed = true,
        .edit_text_pressed = true,
    });
    try std.testing.expectEqual(Tool.add_reusable, studio.tool);
    try std.testing.expect(studio.takeSemanticCommand() == null);
}

test "used reusable definitions cannot emit a delete command" {
    var items: [0]slides.SlideItem = .{};
    const summaries = [_]SlideSummary{.{ .index = 0 }};
    const entries = [_]LibraryEntry{.{
        .kind = .element,
        .name = "card",
        .use_count = 2,
        .deletable = false,
    }};
    const workspace: Workspace = .{ .visible = true, .slides = &summaries, .library = &entries };
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    var studio: Studio = .{ .enabled = true, .selected_library_index = 0, .last_workspace_slide = 0 };

    _ = studio.updateWithWorkspace(&items, &.{}, viewport, workspace, .{ .delete_library_pressed = true });
    try std.testing.expect(studio.takeSemanticCommand() == null);
    try std.testing.expectEqual(Notice.library_entry_in_use, studio.notice);
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

    studio.selected_identity = null;
    _ = studio.updateWithWorkspace(&items, &.{}, viewport, workspace, .{ .move_slide = -1 });
    switch (studio.takeSemanticCommand().?) {
        .move_slide => |command| try std.testing.expectEqual(SlideMoveDirection.up, command.direction),
        else => return error.UnexpectedSemanticCommand,
    }
    try expectVector(.{ .x = 100, .y = 100 }, items[0].position);
}

test "Alt Shift arrows nudge a shared item but reorder with no canvas selection" {
    var items = [_]slides.SlideItem{testItem(122, .textbox, 100, 100, 200, 80)};
    items[0].source = .{ .scope = .slide_template, .line_number = 4, .line_offset = 40, .patchable = true };
    const summaries = [_]SlideSummary{ .{ .index = 1 }, .{ .index = 2 } };
    const workspace: Workspace = .{ .visible = true, .slides = &summaries, .current_slide = 2 };
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    var studio: Studio = .{ .enabled = true, .selected_identity = 122 };

    const command = studio.updateWithWorkspace(&items, &.{}, viewport, workspace, .{
        .nudge = .{ .x = 10, .y = 0 },
        .move_slide = -1,
        .allow_shared_edit = true,
    }).?;
    try std.testing.expectEqual(EditScope.shared_template, command.edit_scope);
    try expectVector(.{ .x = 110, .y = 100 }, command.after_position);
    try std.testing.expect(studio.takeSemanticCommand() == null);

    studio.clearSelection(&items);
    try std.testing.expect(studio.updateWithWorkspace(&items, &.{}, viewport, workspace, .{
        .nudge = .{ .x = 10, .y = 0 },
        .move_slide = -1,
        .allow_shared_edit = true,
    }) == null);
    switch (studio.takeSemanticCommand().?) {
        .move_slide => |move| {
            try std.testing.expectEqual(@as(usize, 2), move.slide_index);
            try std.testing.expectEqual(SlideMoveDirection.up, move.direction);
        },
        else => return error.UnexpectedSemanticCommand,
    }
    try expectVector(.{ .x = 110, .y = 100 }, items[0].position);
}

test "layer commands preserve selected paint order and reject unsafe members atomically" {
    var items = [_]slides.SlideItem{
        testItem(201, .textbox, 100, 100, 100, 80),
        testItem(202, .textbox, 300, 100, 100, 80),
        testItem(203, .textbox, 500, 100, 100, 80),
    };
    for (&items, 0..) |*item, index| item.source = .{
        .scope = .direct,
        .line_number = index + 1,
        .line_offset = (index + 1) * 100,
        .patchable = true,
    };
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    var studio: Studio = .{ .enabled = true };
    setTestSelection(&studio, &items, &.{ 203, 201 });

    _ = studio.update(&items, &.{}, viewport, .{ .layer_action = .front });
    switch (studio.takeSemanticCommand().?) {
        .reorder_items => |command| {
            try std.testing.expectEqual(LayerAction.front, command.action);
            try std.testing.expectEqual(@as(usize, 2), command.count);
            try std.testing.expectEqual(@as(usize, 201), command.targets[0].item_identity);
            try std.testing.expectEqual(@as(usize, 203), command.targets[1].item_identity);
        },
        else => return error.UnexpectedSemanticCommand,
    }

    items[2].source.scope = .slide_template;
    _ = studio.update(&items, &.{}, viewport, .{ .layer_action = .down });
    try std.testing.expect(studio.takeSemanticCommand() == null);
    try std.testing.expectEqual(Notice.layer_selection_unsupported, studio.notice);
}

test "layer commands allow a unique component instance and current morph birth" {
    var items = [_]slides.SlideItem{testItem(204, .textbox, 100, 100, 100, 80)};
    items[0].source = .{ .scope = .component_instance, .line_number = 4, .line_offset = 40, .patchable = true };
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    var studio: Studio = .{ .enabled = true, .selected_identity = 204 };

    _ = studio.update(&items, &.{}, viewport, .{ .layer_action = .up });
    try std.testing.expect(std.meta.activeTag(studio.takeSemanticCommand().?) == .reorder_items);

    items[0].source.scope = .morph_item;
    items[0].creation_morph_state = 0;
    studio.active_morph_state = 0;
    studio.morph_state_count = 1;
    _ = studio.update(&items, &.{}, viewport, .{ .layer_action = .back });
    switch (studio.takeSemanticCommand().?) {
        .reorder_items => |command| try std.testing.expectEqual(LayerAction.back, command.action),
        else => return error.UnexpectedSemanticCommand,
    }
}

test "copy emits literal direct items in paint order and paste is one offset intention" {
    var items = [_]slides.SlideItem{
        testItem(205, .textbox, 100, 100, 100, 80),
        testItem(206, .img, 300, 100, 100, 80),
    };
    items[0].id = "one";
    items[1].id = "two";
    items[0].source = .{ .scope = .direct, .line_number = 1, .line_offset = 10, .patchable = true };
    items[1].source = .{ .scope = .direct, .line_number = 2, .line_offset = 20, .patchable = true };
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    var studio: Studio = .{ .enabled = true };
    setTestSelection(&studio, &items, &.{ 206, 205 });

    _ = studio.update(&items, &.{}, viewport, .{ .copy_pressed = true });
    switch (studio.takeSemanticCommand().?) {
        .copy_items => |command| {
            try std.testing.expectEqual(@as(usize, 2), command.count);
            try std.testing.expectEqual(@as(usize, 205), command.targets[0].item_identity);
            try std.testing.expectEqual(@as(usize, 206), command.targets[1].item_identity);
        },
        else => return error.UnexpectedSemanticCommand,
    }

    studio.setNotice(.clipboard_empty);
    try std.testing.expectEqual(Notice.clipboard_empty, studio.notice);
    _ = studio.update(&items, &.{}, viewport, .{ .paste_pressed = true });
    try std.testing.expectEqual(Notice.none, studio.notice);
    switch (studio.takeSemanticCommand().?) {
        .paste_items => |command| try expectVector(.{ .x = 20, .y = 20 }, command.offset),
        else => return error.UnexpectedSemanticCommand,
    }

    items[1].source.scope = .component_instance;
    _ = studio.update(&items, &.{}, viewport, .{ .copy_pressed = true });
    try std.testing.expect(studio.takeSemanticCommand() == null);
    try std.testing.expectEqual(Notice.copy_selection_unsupported, studio.notice);

    items[0].locked = true;
    studio.setSingleSelection(items[0]);
    _ = studio.update(&items, &.{}, viewport, .{ .copy_pressed = true });
    switch (studio.takeSemanticCommand().?) {
        .copy_items => |command| try std.testing.expectEqual(@as(usize, 205), command.targets[0].item_identity),
        else => return error.UnexpectedSemanticCommand,
    }
}

test "paste integration can select all new IDs in requested order" {
    var items = [_]slides.SlideItem{
        testItem(207, .textbox, 100, 100, 100, 80),
        testItem(208, .textbox, 300, 100, 100, 80),
        testItem(209, .textbox, 500, 100, 100, 80),
    };
    items[0].id = "old";
    items[1].id = "paste-b";
    items[2].id = "paste-a";
    // Source rewrites may intentionally retain a newly locked selection so
    // the user can copy or unlock it without hunting for the badge again.
    items[2].locked = true;
    var studio: Studio = .{ .enabled = true, .selected_identity = 207 };

    studio.selectItemsByIds(&items, &.{ "paste-a", "paste-b" });
    try std.testing.expectEqual(@as(usize, 2), studio.selectionCount());
    try std.testing.expectEqual(@as(?usize, 209), studio.selectedIdentityAt(0));
    try std.testing.expectEqual(@as(?usize, 208), studio.selectedIdentityAt(1));
}

test "lock commands use direct local shared and morph targets" {
    var items = [_]slides.SlideItem{testItem(210, .textbox, 100, 100, 100, 80)};
    items[0].id = "hero";
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    var studio: Studio = .{ .enabled = true, .selected_identity = 210 };

    _ = studio.update(&items, &.{}, viewport, .{ .toggle_lock_pressed = true });
    switch (studio.takeSemanticCommand().?) {
        .set_locked => |command| {
            try std.testing.expect(command.locked);
            try std.testing.expectEqual(EditScope.direct, command.targets[0].edit_scope);
        },
        else => return error.UnexpectedSemanticCommand,
    }

    items[0].source = .{ .scope = .slide_template, .line_number = 4, .line_offset = 40, .patchable = true };
    items[0].shared_template_values = .{ .position = items[0].position, .size = items[0].size };
    _ = studio.update(&items, &.{}, viewport, .{ .toggle_lock_pressed = true });
    switch (studio.takeSemanticCommand().?) {
        .set_locked => |command| try std.testing.expectEqual(EditScope.local_instance, command.targets[0].edit_scope),
        else => return error.UnexpectedSemanticCommand,
    }
    _ = studio.update(&items, &.{}, viewport, .{ .toggle_lock_pressed = true, .allow_shared_edit = true });
    switch (studio.takeSemanticCommand().?) {
        .set_locked => |command| try std.testing.expectEqual(EditScope.shared_template, command.targets[0].edit_scope),
        else => return error.UnexpectedSemanticCommand,
    }

    items[0].source = .{ .scope = .morph_item, .line_number = 8, .line_offset = 80, .patchable = true };
    items[0].creation_morph_state = 0;
    items[0].shared_template_values = null;
    studio.active_morph_state = 0;
    studio.morph_state_count = 1;
    _ = studio.update(&items, &.{}, viewport, .{ .toggle_lock_pressed = true });
    switch (studio.takeSemanticCommand().?) {
        .set_locked => |command| {
            try std.testing.expect(command.locked);
            try std.testing.expectEqual(slides.SourceScope.morph_item, command.targets[0].source.scope);
        },
        else => return error.UnexpectedSemanticCommand,
    }
}

test "locked items are skipped by canvas selection select-all snapping and atomic groups" {
    var items = [_]slides.SlideItem{
        testItem(211, .textbox, 100, 100, 100, 80),
        testItem(212, .textbox, 300, 100, 100, 80),
    };
    items[0].source = .{ .scope = .direct, .line_number = 1, .line_offset = 10, .patchable = true };
    items[1].source = .{ .scope = .direct, .line_number = 2, .line_offset = 20, .patchable = true };
    items[1].locked = true;
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    var studio: Studio = .{ .enabled = true };

    try std.testing.expect(hitTest(&items, &.{}, .{ .x = 320, .y = 120 }) == null);
    _ = studio.update(&items, &.{}, viewport, .{ .select_all_pressed = true });
    try std.testing.expectEqual(@as(usize, 1), studio.selectionCount());
    try std.testing.expectEqual(@as(?usize, 211), studio.selected_identity);

    const snapped = snapGeometry(
        .{ .position = .{ .x = 196, .y = 100 }, .size = .{ .x = 100, .y = 80 } },
        .moving,
        default_logical_size,
        .{ .x = 8, .y = 8 },
        false,
        20,
        8,
        null,
        true,
        211,
        &items,
        &.{},
    );
    try std.testing.expect(snapped.guides.vertical == null);

    setTestSelection(&studio, &items, &.{ 211, 212 });
    _ = studio.update(&items, &.{}, viewport, .{ .layer_action = .front });
    try std.testing.expect(studio.takeSemanticCommand() == null);
    try std.testing.expectEqual(@as(usize, 2), studio.selectionCount());
    try std.testing.expectEqual(Notice.locked_item, studio.notice);
}

test "locked badge unlocks topmost item and property panels win overlapping clicks" {
    var items = [_]slides.SlideItem{
        testItem(213, .textbox, 100, 100, 100, 80),
        testItem(214, .textbox, 100, 100, 100, 80),
    };
    items[0].id = "under";
    items[1].id = "top";
    items[0].locked = true;
    items[1].locked = true;
    items[0].source = .{ .scope = .direct, .line_number = 1, .line_offset = 10, .patchable = true };
    items[1].source = .{ .scope = .direct, .line_number = 2, .line_offset = 20, .patchable = true };
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    var studio: Studio = .{ .enabled = true };

    const badge = Studio.lockBadgeRect(viewport, itemGeometry(items[1], &.{})).?;
    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = rectangleCenter(badge),
        .pointer_pressed = true,
    });
    try std.testing.expect(studio.takeSemanticCommand() == null);
    try std.testing.expectEqual(@as(?usize, 214), studio.selected_identity);
    _ = studio.update(&items, &.{}, viewport, .{});
    try std.testing.expectEqual(@as(?usize, 214), studio.selected_identity);
    try std.testing.expect(studio.update(&items, &.{}, viewport, .{ .nudge = .{ .x = 10, .y = 0 } }) == null);
    try expectVector(.{ .x = 100, .y = 100 }, items[1].position);
    try std.testing.expectEqual(Notice.locked_item, studio.notice);

    _ = studio.update(&items, &.{}, viewport, .{ .copy_pressed = true });
    try std.testing.expect(std.meta.activeTag(studio.takeSemanticCommand().?) == .copy_items);

    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = rectangleCenter(badge),
        .pointer_pressed = true,
    });
    switch (studio.takeSemanticCommand().?) {
        .set_locked => |command| {
            try std.testing.expect(!command.locked);
            try std.testing.expectEqual(@as(usize, 214), command.targets[0].item_identity);
        },
        else => return error.UnexpectedSemanticCommand,
    }
    try std.testing.expectEqual(@as(?usize, 214), studio.selected_identity);

    // Put a locked badge beneath the visible properties panel. The panel
    // button must consume the click before canvas badge handling.
    const layout = uiLayout(viewport);
    items[0].position = .{ .x = layout.layer_buttons[2].x - 4, .y = layout.layer_buttons[2].y - 4 };
    items[1].locked = false;
    studio.setSingleSelection(items[1]);
    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = rectangleCenter(layout.layer_buttons[2]),
        .pointer_pressed = true,
    });
    try std.testing.expect(std.meta.activeTag(studio.takeSemanticCommand().?) == .reorder_items);
}

fn rectangleCenter(rect: rl.Rectangle) rl.Vector2 {
    return .{ .x = rect.x + rect.width / 2, .y = rect.y + rect.height / 2 };
}
