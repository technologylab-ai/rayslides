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
pub const marquee_drag_threshold_screen: f32 = 3;
pub const max_selection_items: usize = 64;

/// Studio typography has a deliberate 14 px floor at the reference 1280x720
/// viewport. Controls scale up to 2x on large/full-screen displays, but never
/// shrink into the hard-to-read 10-12 px labels used by the first prototype.
pub const UiTypography = struct {
    pub const minimum: i32 = 14;
    pub const compact: i32 = 14;
    pub const body: i32 = 16;
    pub const heading: i32 = 18;
    pub const status_heading: i32 = 20;
};

pub fn uiScale(viewport: Viewport) f32 {
    if (!viewport.valid()) return 1;
    // Dock metrics are expressed in screen pixels by frameLayout. Scaling
    // their children again from the fitted canvas would overflow the chrome
    // on large displays.
    if (viewport.chrome != null) return 1;
    const reference_width: f32 = 1280;
    const reference_height: f32 = 720;
    return std.math.clamp(
        @min(viewport.slide_size.x / reference_width, viewport.slide_size.y / reference_height),
        1,
        2,
    );
}

fn scaledUiFont(scale: f32, base_size: i32) i32 {
    const scaled: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(base_size)) * scale));
    return @max(UiTypography.minimum, scaled);
}

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

pub const FrameMode = enum {
    wide,
    medium,
    compact,
    focus,
};

/// At widths where both docks would leave too little room for the slide, one
/// dock at a time is reserved beside the canvas. `none` is useful on compact
/// windows where the author wants the largest possible working surface.
pub const DockPanel = enum {
    none,
    slides,
    objects,
    properties,
};

/// Content displayed in the right-hand Studio dock. Keeping this independent
/// from DockPanel lets wide windows retain the slide organizer while authors
/// switch between the object stack and precise properties.
pub const InspectorPanel = enum {
    objects,
    properties,
};

const empty_frame_rectangle: rl.Rectangle = .{ .x = 0, .y = 0, .width = 0, .height = 0 };

/// Screen-space Studio chrome. Unlike the first Studio prototype, every
/// permanent control surface is outside the slide viewport.
pub const ChromeLayout = struct {
    content: rl.Rectangle,
    toolbar: rl.Rectangle = empty_frame_rectangle,
    left_dock: rl.Rectangle = empty_frame_rectangle,
    right_dock: rl.Rectangle = empty_frame_rectangle,
    status: rl.Rectangle = empty_frame_rectangle,
    left_visible: bool = false,
    right_visible: bool = false,
    visible: bool = false,
};

/// The complete editor frame for one window size. Callers render the slide at
/// `viewport`, then draw Studio overlays with that same viewport.
pub const FrameLayout = struct {
    mode: FrameMode,
    chrome: ChromeLayout,
    canvas_area: rl.Rectangle,
    viewport: Viewport,
};

/// The already letterboxed region in which the slide is rendered.
pub const Viewport = struct {
    slide_top_left: rl.Vector2,
    slide_size: rl.Vector2,
    logical_size: rl.Vector2 = default_logical_size,
    /// Null preserves the legacy overlay layout for embedders that have not
    /// adopted the docked frame API yet.
    chrome: ?ChromeLayout = null,

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

fn insetRectangle(rect: rl.Rectangle, amount: f32) rl.Rectangle {
    return .{
        .x = rect.x + amount,
        .y = rect.y + amount,
        .width = @max(0, rect.width - amount * 2),
        .height = @max(0, rect.height - amount * 2),
    };
}

fn fitSlideViewport(rect: rl.Rectangle) Viewport {
    if (rect.width <= 0 or rect.height <= 0) return .{
        .slide_top_left = .{ .x = rect.x, .y = rect.y },
        .slide_size = .zero(),
    };
    const aspect = default_logical_size.x / default_logical_size.y;
    const width_from_height = rect.height * aspect;
    const size: rl.Vector2 = if (width_from_height <= rect.width)
        .{ .x = width_from_height, .y = rect.height }
    else
        .{ .x = rect.width, .y = rect.width / aspect };
    return .{
        .slide_top_left = .{
            .x = rect.x + (rect.width - size.x) / 2,
            .y = rect.y + (rect.height - size.y) / 2,
        },
        .slide_size = size,
    };
}

/// Builds a responsive docked editor surface. Wide windows reserve both
/// docks. Medium and compact windows reserve the requested dock only, so a
/// dock never becomes a canvas-covering drawer. Focus Canvas uses the complete
/// content rectangle and hides all permanent chrome.
pub fn frameLayout(
    content: rl.Rectangle,
    studio_visible: bool,
    focus_canvas: bool,
    active_dock: DockPanel,
) FrameLayout {
    const safe_content: rl.Rectangle = .{
        .x = content.x,
        .y = content.y,
        .width = @max(0, content.width),
        .height = @max(0, content.height),
    };
    if (!studio_visible or focus_canvas) {
        const canvas_area = insetRectangle(safe_content, if (studio_visible) 12 else 0);
        var viewport = fitSlideViewport(canvas_area);
        const chrome: ChromeLayout = .{ .content = safe_content };
        viewport.chrome = chrome;
        return .{
            .mode = .focus,
            .chrome = chrome,
            .canvas_area = canvas_area,
            .viewport = viewport,
        };
    }

    const mode: FrameMode = if (safe_content.width >= 1480 and safe_content.height >= 700)
        .wide
    else if (safe_content.width >= 1100 and safe_content.height >= 620)
        .medium
    else
        .compact;
    const compact_shell = mode == .compact;
    const gap: f32 = if (compact_shell) 8 else 10;
    const edge: f32 = 12;
    const toolbar_height: f32 = if (compact_shell) 64 else 70;
    const status_height: f32 = if (compact_shell) 76 else 116;
    const toolbar: rl.Rectangle = .{
        .x = safe_content.x,
        .y = safe_content.y,
        .width = safe_content.width,
        .height = @min(toolbar_height, safe_content.height),
    };
    const status_y = @max(toolbar.y + toolbar.height, safe_content.y + safe_content.height - status_height);
    const status: rl.Rectangle = .{
        .x = safe_content.x,
        .y = status_y,
        .width = safe_content.width,
        .height = @max(0, safe_content.y + safe_content.height - status_y),
    };
    const body_y = toolbar.y + toolbar.height + gap;
    const body_bottom = status.y - gap;
    const body: rl.Rectangle = .{
        .x = safe_content.x + edge,
        .y = body_y,
        .width = @max(0, safe_content.width - edge * 2),
        .height = @max(0, body_bottom - body_y),
    };

    const left_visible = mode == .wide or (mode != .wide and active_dock == .slides);
    const right_visible = mode == .wide or (mode != .wide and
        (active_dock == .objects or active_dock == .properties));
    const left_width: f32 = if (mode == .wide)
        std.math.clamp(safe_content.width * 0.16, 248, 304)
    else
        @min(@as(f32, 264), @max(@as(f32, 220), safe_content.width * 0.29));
    const right_width: f32 = if (mode == .wide)
        std.math.clamp(safe_content.width * 0.18, 304, 344)
    else
        @min(@as(f32, 304), @max(@as(f32, 272), safe_content.width * 0.32));
    const left_dock: rl.Rectangle = if (left_visible) .{
        .x = body.x,
        .y = body.y,
        .width = @min(left_width, body.width),
        .height = body.height,
    } else empty_frame_rectangle;
    const right_dock: rl.Rectangle = if (right_visible) .{
        .x = body.x + body.width - @min(right_width, body.width),
        .y = body.y,
        .width = @min(right_width, body.width),
        .height = body.height,
    } else empty_frame_rectangle;
    const canvas_left = body.x + if (left_visible) left_dock.width + gap else 0;
    const canvas_right = body.x + body.width - if (right_visible) right_dock.width + gap else 0;
    const canvas_area: rl.Rectangle = .{
        .x = canvas_left,
        .y = body.y,
        .width = @max(0, canvas_right - canvas_left),
        .height = body.height,
    };
    const chrome: ChromeLayout = .{
        .content = safe_content,
        .toolbar = toolbar,
        .left_dock = left_dock,
        .right_dock = right_dock,
        .status = status,
        .left_visible = left_visible,
        .right_visible = right_visible,
        .visible = true,
    };
    var viewport = fitSlideViewport(canvas_area);
    viewport.chrome = chrome;
    return .{
        .mode = mode,
        .chrome = chrome,
        .canvas_area = canvas_area,
        .viewport = viewport,
    };
}

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

fn clampLogicalPoint(point: rl.Vector2, logical_size: rl.Vector2) rl.Vector2 {
    return .{
        .x = std.math.clamp(point.x, 0, logical_size.x),
        .y = std.math.clamp(point.y, 0, logical_size.y),
    };
}

fn marqueeGeometry(marquee: Marquee) Geometry {
    const min_x = @min(marquee.start.x, marquee.current.x);
    const min_y = @min(marquee.start.y, marquee.current.y);
    return .{
        .position = .{ .x = min_x, .y = min_y },
        .size = .{
            .x = @max(marquee.start.x, marquee.current.x) - min_x,
            .y = @max(marquee.start.y, marquee.current.y) - min_y,
        },
    };
}

fn marqueeExceededDragThreshold(marquee: Marquee, viewport: Viewport) bool {
    if (!viewport.valid()) return false;
    const dx = @abs(marquee.current.x - marquee.start.x) * viewport.slide_size.x / viewport.logical_size.x;
    const dy = @abs(marquee.current.y - marquee.start.y) * viewport.slide_size.y / viewport.logical_size.y;
    return @max(dx, dy) >= marquee_drag_threshold_screen;
}

fn clipGeometryToSlide(geometry: Geometry, logical_size: rl.Vector2) ?Geometry {
    const min_x = @max(@as(f32, 0), geometry.position.x);
    const min_y = @max(@as(f32, 0), geometry.position.y);
    const max_x = @min(logical_size.x, geometry.position.x + geometry.size.x);
    const max_y = @min(logical_size.y, geometry.position.y + geometry.size.y);
    if (max_x <= min_x or max_y <= min_y) return null;
    return .{
        .position = .{ .x = min_x, .y = min_y },
        .size = .{ .x = max_x - min_x, .y = max_y - min_y },
    };
}

fn geometriesOverlap(a: Geometry, b: Geometry) bool {
    return a.position.x < b.position.x + b.size.x and
        a.position.x + a.size.x > b.position.x and
        a.position.y < b.position.y + b.size.y and
        a.position.y + a.size.y > b.position.y;
}

fn memberSliceContains(members: []const SelectionMember, identity: usize) bool {
    return memberSliceIndex(members, identity) != null;
}

fn memberSliceIndex(members: []const SelectionMember, identity: usize) ?usize {
    for (members, 0..) |member, index| {
        if (member.identity == identity) return index;
    }
    return null;
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

fn batchHasNonLocalSource(targets: []const CommandTarget, candidate: CommandTarget) bool {
    if (candidate.edit_scope == .local_instance) return false;
    for (targets) |target| {
        if (target.edit_scope == .local_instance) continue;
        if (sourceEqual(target.source, candidate.source)) return true;
    }
    return false;
}

fn sourceScopeLabel(scope: slides.SourceScope) []const u8 {
    return switch (scope) {
        .none => "source unknown",
        .direct => "direct item",
        .component_instance => "component instance",
        .group_instance_member => "group instance member",
        .slide_template => "shared layout item",
        .slide_instance_override => "local template override",
        .morph_item => "morph item",
    };
}

fn firstNonEmptyTextLine(value: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, value, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len > 0) return line;
    }
    return null;
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
    multi_duplicate_unsupported,
    multi_delete_unsupported,
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
    group_reusable_needs_source_support,
    override_reset_unsupported,
    detach_instance_unsupported,
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

/// One source-atomic item operation. Targets are stored in paint order so the
/// integration layer can preserve relative order while planning the rewrite.
pub const ItemBatchCommand = struct {
    targets: [max_selection_items]CommandTarget = undefined,
    count: usize = 0,

    pub fn slice(self: *const ItemBatchCommand) []const CommandTarget {
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

/// Applies one authored visibility value to an atomic selection. This is
/// distinct from opacity: hidden items stay present in paint order and can be
/// recovered from the Objects dock.
pub const SetVisibleCommand = struct {
    targets: [max_selection_items]CommandTarget = undefined,
    count: usize = 0,
    visible: bool,

    pub fn slice(self: *const SetVisibleCommand) []const CommandTarget {
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

/// One scalar geometry value to edit through a precise numeric prompt. The
/// request intentionally carries no value: Studio owns the hit target and
/// edit destination, while the integration layer owns text entry, validation,
/// and the eventual atomic source patch.
pub const GeometryField = enum {
    x,
    y,
    width,
    height,
};

pub const NumericGeometryRequest = struct {
    target: CommandTarget,
    field: GeometryField,
};

pub const InlineField = enum {
    text,
    x,
    y,
    width,
    height,
    foreground,
    background,
    font_size,
    opacity,
};

pub const InlineError = enum {
    invalid_utf8,
    too_long,
    invalid_number,
    non_positive_dimension,
    invalid_color,
    invalid_font_size,
    invalid_opacity,
    invalid_text,
    source_edit_failed,
};

/// A same-frame borrowed view into Studio's fixed inline editor buffer. The
/// integration must consume `value` synchronously before the next Studio
/// update; accept/reject then completes the handshake without a modal prompt.
pub const InlineCommit = struct {
    target: CommandTarget,
    field: InlineField,
    value: []const u8,
};

/// Exact Inspector properties whose effective value can be inherited from a
/// reusable definition and selectively restored by removing one local key.
pub const PropertyOverrideSet = struct {
    bits: u16 = 0,

    pub fn fromFields(fields: []const InlineField) PropertyOverrideSet {
        var result: PropertyOverrideSet = .{};
        for (fields) |field| result.set(field);
        return result;
    }

    pub fn set(self: *PropertyOverrideSet, field: InlineField) void {
        self.bits |= @as(u16, 1) << @intCast(@intFromEnum(field));
    }

    pub fn contains(self: PropertyOverrideSet, field: InlineField) bool {
        return self.bits & (@as(u16, 1) << @intCast(@intFromEnum(field))) != 0;
    }

    pub fn empty(self: PropertyOverrideSet) bool {
        return self.bits == 0;
    }
};

pub const ReusableInstanceKind = enum {
    none,
    component,
    group,
    slide_template,
};

pub const CompositionBlockReason = enum {
    none,
    not_instance,
    generated_source,
    morph_scene,
    ambiguous_instance,
    dependent_structure,
    integration_unavailable,
};

/// Integration-authored capability snapshot for the selected runtime item.
/// Studio copies this value and rechecks both identity and the selected item's
/// physical source before showing or emitting any composition action.
pub const CompositionContext = struct {
    item_identity: usize,
    selection_source: slides.SourceRef,
    kind: ReusableInstanceKind,
    local_overrides: PropertyOverrideSet = .{},
    resettable_overrides: PropertyOverrideSet = .{},
    reset_target: ?CommandTarget = null,
    detach_target: ?CommandTarget = null,
    detach_block: CompositionBlockReason = .not_instance,
};

pub const ResetOverrideCommand = struct {
    target: CommandTarget,
    field: InlineField,
};

pub const DetachInstanceCommand = struct {
    target: CommandTarget,
    kind: ReusableInstanceKind,
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
    group,
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
    duplicate_items: ItemBatchCommand,
    delete_item: CommandTarget,
    delete_items: ItemBatchCommand,
    edit_text: CommandTarget,
    edit_numeric_geometry: NumericGeometryRequest,
    set_foreground: ColorCommand,
    set_custom_foreground: CommandTarget,
    set_background: ColorCommand,
    set_custom_background: CommandTarget,
    set_font_size: CommandTarget,
    set_opacity: CommandTarget,
    /// Removes an item's authored fill (`bg=none`). This remains a distinct
    /// intention so integrations never have to overload a palette color.
    clear_background: CommandTarget,
    reorder_items: LayerCommand,
    copy_items: CopyItemsCommand,
    paste_items: PasteItemsCommand,
    set_locked: SetLockedCommand,
    set_visible: SetVisibleCommand,
    commit_inline: InlineCommit,
    reset_local_override: ResetOverrideCommand,
    detach_reusable_instance: DetachInstanceCommand,
    promote_to_reusable: CommandTarget,
    promote_items_to_group: ItemBatchCommand,
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
    /// Inserts an absolute-position @popgroup instance for this Library row.
    add_reusable_group: usize,
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
const empty_ui_rectangle: rl.Rectangle = .{ .x = 0, .y = 0, .width = 0, .height = 0 };

pub const UiLayout = struct {
    /// Scale applied to panel metrics and typography for this viewport.
    scale: f32 = 1,
    /// Denser vertical reflow used when the viewport cannot fit the full
    /// property rhythm above the status panel. Font sizes retain their floor.
    compact_properties: bool = false,
    /// Very short letterboxed viewports retain creation/precise properties
    /// and lock, while hiding lower layout groups that cannot fit safely.
    minimal_properties: bool = false,
    toolbar: rl.Rectangle,
    tool_buttons: [6]rl.Rectangle,
    new_slide: rl.Rectangle,
    grid_toggle: rl.Rectangle,
    scene_previous: rl.Rectangle,
    scene_label: rl.Rectangle,
    scene_next: rl.Rectangle,
    slides_dock_toggle: rl.Rectangle = empty_ui_rectangle,
    properties_dock_toggle: rl.Rectangle = empty_ui_rectangle,
    focus_canvas: rl.Rectangle = empty_ui_rectangle,
    properties: rl.Rectangle,
    edit_text: rl.Rectangle,
    duplicate_item: rl.Rectangle,
    delete_item: rl.Rectangle,
    promote: rl.Rectangle,
    geometry_fields: [4]rl.Rectangle = [_]rl.Rectangle{empty_ui_rectangle} ** 4,
    foreground_swatches: [palette.len]rl.Rectangle,
    custom_foreground: rl.Rectangle = empty_ui_rectangle,
    background_swatches: [palette.len]rl.Rectangle,
    custom_background: rl.Rectangle = empty_ui_rectangle,
    clear_background: rl.Rectangle,
    font_size: rl.Rectangle = empty_ui_rectangle,
    opacity: rl.Rectangle = empty_ui_rectangle,
    inline_error: rl.Rectangle = empty_ui_rectangle,
    align_buttons: [6]rl.Rectangle,
    distribute_buttons: [2]rl.Rectangle,
    layer_buttons: [4]rl.Rectangle,
    lock_item: rl.Rectangle,
};

fn emptyUiLayout(scale: f32) UiLayout {
    return .{
        .scale = scale,
        .toolbar = empty_ui_rectangle,
        .tool_buttons = [_]rl.Rectangle{empty_ui_rectangle} ** 6,
        .new_slide = empty_ui_rectangle,
        .grid_toggle = empty_ui_rectangle,
        .scene_previous = empty_ui_rectangle,
        .scene_label = empty_ui_rectangle,
        .scene_next = empty_ui_rectangle,
        .properties = empty_ui_rectangle,
        .edit_text = empty_ui_rectangle,
        .duplicate_item = empty_ui_rectangle,
        .delete_item = empty_ui_rectangle,
        .promote = empty_ui_rectangle,
        .foreground_swatches = [_]rl.Rectangle{empty_ui_rectangle} ** palette.len,
        .background_swatches = [_]rl.Rectangle{empty_ui_rectangle} ** palette.len,
        .clear_background = empty_ui_rectangle,
        .align_buttons = [_]rl.Rectangle{empty_ui_rectangle} ** 6,
        .distribute_buttons = [_]rl.Rectangle{empty_ui_rectangle} ** 2,
        .layer_buttons = [_]rl.Rectangle{empty_ui_rectangle} ** 4,
        .lock_item = empty_ui_rectangle,
    };
}

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
    if (viewport.chrome) |chrome| {
        if (!chrome.visible or !chrome.left_visible or chrome.left_dock.width <= 0 or chrome.left_dock.height <= 0)
            return emptyWorkspaceLayout();
        return workspaceLayoutInSidebar(chrome.left_dock, gap);
    }
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
    return workspaceLayoutInSidebar(sidebar, gap);
}

fn emptyWorkspaceLayout() WorkspaceLayout {
    return .{
        .sidebar = empty_frame_rectangle,
        .organizer = empty_frame_rectangle,
        .organizer_actions = [_]rl.Rectangle{empty_frame_rectangle} ** organizer_action_count,
        .slide_cards_clip = empty_frame_rectangle,
        .slide_page_previous = empty_frame_rectangle,
        .slide_page_next = empty_frame_rectangle,
        .library = empty_frame_rectangle,
        .library_use = empty_frame_rectangle,
        .library_rename = empty_frame_rectangle,
        .library_delete = empty_frame_rectangle,
        .library_rows_clip = empty_frame_rectangle,
        .library_page_previous = empty_frame_rectangle,
        .library_page_next = empty_frame_rectangle,
    };
}

fn workspaceLayoutInSidebar(sidebar: rl.Rectangle, gap: f32) WorkspaceLayout {
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

pub const object_row_height: f32 = 54;
pub const object_row_gap: f32 = 5;

/// Stable geometry for the tabbed Objects/Properties inspector. Rows are
/// intentionally derived separately so large scenes remain allocation-free.
pub const ObjectsLayout = struct {
    panel: rl.Rectangle,
    objects_tab: rl.Rectangle,
    properties_tab: rl.Rectangle,
    layer_actions: [4]rl.Rectangle,
    rows_clip: rl.Rectangle,
    page_previous: rl.Rectangle,
    page_next: rl.Rectangle,
};

fn emptyObjectsLayout() ObjectsLayout {
    return .{
        .panel = empty_frame_rectangle,
        .objects_tab = empty_frame_rectangle,
        .properties_tab = empty_frame_rectangle,
        .layer_actions = [_]rl.Rectangle{empty_frame_rectangle} ** 4,
        .rows_clip = empty_frame_rectangle,
        .page_previous = empty_frame_rectangle,
        .page_next = empty_frame_rectangle,
    };
}

pub fn objectsLayout(viewport: Viewport) ObjectsLayout {
    const chrome = viewport.chrome orelse return emptyObjectsLayout();
    if (!chrome.visible or !chrome.right_visible or chrome.right_dock.width <= 0 or chrome.right_dock.height <= 0)
        return emptyObjectsLayout();
    const panel = chrome.right_dock;
    const inset: f32 = 10;
    const gap: f32 = 5;
    const tab_width = (panel.width - inset * 2 - gap) / 2;
    const objects_tab: rl.Rectangle = .{
        .x = panel.x + inset,
        .y = panel.y + 7,
        .width = tab_width,
        .height = 28,
    };
    const properties_tab: rl.Rectangle = .{
        .x = objects_tab.x + objects_tab.width + gap,
        .y = objects_tab.y,
        .width = tab_width,
        .height = objects_tab.height,
    };
    const action_gap: f32 = 5;
    const action_width = (panel.width - inset * 2 - action_gap * 3) / 4;
    var layer_actions: [4]rl.Rectangle = undefined;
    for (&layer_actions, 0..) |*button, index| button.* = .{
        .x = panel.x + inset + @as(f32, @floatFromInt(index)) * (action_width + action_gap),
        .y = panel.y + 43,
        .width = action_width,
        .height = 29,
    };
    const pager_width: f32 = 58;
    const pager_y = panel.y + panel.height - 29;
    const page_next: rl.Rectangle = .{
        .x = panel.x + panel.width - inset - pager_width,
        .y = pager_y,
        .width = pager_width,
        .height = 22,
    };
    const page_previous: rl.Rectangle = .{
        .x = page_next.x - gap - pager_width,
        .y = pager_y,
        .width = pager_width,
        .height = page_next.height,
    };
    return .{
        .panel = panel,
        .objects_tab = objects_tab,
        .properties_tab = properties_tab,
        .layer_actions = layer_actions,
        .rows_clip = .{
            .x = panel.x + 7,
            .y = panel.y + 80,
            .width = panel.width - 14,
            .height = @max(0, pager_y - 6 - (panel.y + 80)),
        },
        .page_previous = page_previous,
        .page_next = page_next,
    };
}

pub fn objectRowCapacity(layout: ObjectsLayout) usize {
    return rowsThatFit(layout.rows_clip.height, object_row_height, object_row_gap);
}

pub fn objectRowRect(layout: ObjectsLayout, visible_slot: usize) ?rl.Rectangle {
    if (visible_slot >= objectRowCapacity(layout)) return null;
    return .{
        .x = layout.rows_clip.x,
        .y = layout.rows_clip.y + @as(f32, @floatFromInt(visible_slot)) * (object_row_height + object_row_gap),
        .width = layout.rows_clip.width,
        .height = object_row_height,
    };
}

pub fn objectVisibilityRect(row: rl.Rectangle) rl.Rectangle {
    return .{ .x = row.x + 5, .y = row.y + 8, .width = 36, .height = row.height - 16 };
}

pub fn objectLockRect(row: rl.Rectangle) rl.Rectangle {
    return .{ .x = row.x + row.width - 41, .y = row.y + 8, .width = 36, .height = row.height - 16 };
}

pub fn objectItemCount(items: []const slides.SlideItem) usize {
    return items.len;
}

/// Maps a front-to-back Objects-row offset to the slide's ordinary paint-
/// order item index. Background barriers are included as read-only rows so
/// the list never misrepresents the renderer's actual paint order.
pub fn objectIndexAtPaintOffset(items: []const slides.SlideItem, paint_offset: usize) ?usize {
    if (paint_offset >= items.len) return null;
    return items.len - paint_offset - 1;
}

fn objectPaintOffsetByIdentity(items: []const slides.SlideItem, identity: usize) ?usize {
    var offset: usize = 0;
    while (objectIndexAtPaintOffset(items, offset)) |index| : (offset += 1) {
        if (items[index].identity == identity) return offset;
    }
    return null;
}

fn rowsThatFit(height: f32, row_height: f32, gap: f32) usize {
    if (height < row_height) return 0;
    return @intFromFloat(@floor((height + gap) / (row_height + gap)));
}

pub fn uiLayout(viewport: Viewport) UiLayout {
    const scale = uiScale(viewport);
    if (viewport.chrome) |chrome| {
        if (!chrome.visible) return emptyUiLayout(scale);
    }
    const margin: f32 = 12 * scale;
    const docked = if (viewport.chrome) |chrome| chrome.visible else false;
    const compact_toolbar = if (viewport.chrome) |chrome| chrome.content.width < 1100 else false;
    const gap: f32 = @as(f32, if (compact_toolbar) 5 else 8) * scale;
    const tool_size: f32 = @as(f32, if (compact_toolbar) 40 else 46) * scale;
    const new_slide_width: f32 = @as(f32, if (compact_toolbar) 70 else 82) * scale;
    const grid_width: f32 = @as(f32, if (compact_toolbar) 58 else 66) * scale;
    const scene_width: f32 = @as(f32, if (compact_toolbar) 112 else 150) * scale;
    const toolbar_width = margin * 2 + tool_size * 6 + gap * 5 + gap + new_slide_width + gap + grid_width + gap + scene_width;
    const toolbar: rl.Rectangle = if (docked)
        viewport.chrome.?.toolbar
    else
        .{
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
        .width = 32 * scale,
        .height = tool_size,
    };
    const scene_label: rl.Rectangle = .{
        .x = scene_previous.x + scene_previous.width,
        .y = new_slide.y,
        .width = scene_width - 64 * scale,
        .height = tool_size,
    };
    const scene_next: rl.Rectangle = .{
        .x = scene_label.x + scene_label.width,
        .y = new_slide.y,
        .width = 32 * scale,
        .height = tool_size,
    };

    const dock_button_gap: f32 = gap;
    const focus_width: f32 = @as(f32, if (compact_toolbar) 64 else 76) * scale;
    const properties_toggle_width: f32 = @as(f32, if (compact_toolbar) 86 else 104) * scale;
    const slides_toggle_width: f32 = @as(f32, if (compact_toolbar) 68 else 82) * scale;
    const focus_canvas: rl.Rectangle = if (docked) .{
        .x = toolbar.x + toolbar.width - margin - focus_width,
        .y = toolbar.y + (toolbar.height - tool_size) / 2,
        .width = focus_width,
        .height = tool_size,
    } else empty_ui_rectangle;
    const show_dock_toggles = docked and !(viewport.chrome.?.left_visible and viewport.chrome.?.right_visible);
    const properties_dock_toggle: rl.Rectangle = if (show_dock_toggles) .{
        .x = focus_canvas.x - dock_button_gap - properties_toggle_width,
        .y = focus_canvas.y,
        .width = properties_toggle_width,
        .height = tool_size,
    } else empty_ui_rectangle;
    const slides_dock_toggle: rl.Rectangle = if (show_dock_toggles) .{
        .x = properties_dock_toggle.x - dock_button_gap - slides_toggle_width,
        .y = focus_canvas.y,
        .width = slides_toggle_width,
        .height = tool_size,
    } else empty_ui_rectangle;

    const property_width: f32 = if (docked and viewport.chrome.?.right_visible)
        viewport.chrome.?.right_dock.width
    else
        304 * scale;
    var properties: rl.Rectangle = if (docked) blk: {
        if (viewport.chrome.?.right_visible) break :blk viewport.chrome.?.right_dock;
        break :blk .{
            .x = viewport.chrome.?.content.x + viewport.chrome.?.content.width,
            .y = viewport.chrome.?.toolbar.y + viewport.chrome.?.toolbar.height,
            .width = property_width,
            .height = 0,
        };
    } else .{
        .x = viewport.slide_top_left.x + viewport.slide_size.x - property_width - margin,
        .y = viewport.slide_top_left.y + margin,
        .width = property_width,
        .height = 558 * scale,
    };
    if (!docked)
        properties.height = @min(properties.height, @max(0, statusPanel(viewport).y - gap - properties.y));
    const compact_properties = properties.height < 480 * scale;
    if (docked) {
        const inset: f32 = 10 * scale;
        const inner_width = @max(0, properties.width - inset * 2);
        const field_height: f32 = @as(f32, if (compact_properties) 32 else 34) * scale;
        const action_gap: f32 = 5 * scale;
        const action_width = (inner_width - action_gap * 3) / 4;
        const action_y = properties.y + 42 * scale;
        const duplicate_item: rl.Rectangle = .{ .x = properties.x + inset, .y = action_y, .width = action_width, .height = 28 * scale };
        const delete_item: rl.Rectangle = .{ .x = duplicate_item.x + action_width + action_gap, .y = action_y, .width = action_width, .height = duplicate_item.height };
        const promote: rl.Rectangle = .{ .x = delete_item.x + action_width + action_gap, .y = action_y, .width = action_width, .height = duplicate_item.height };
        const lock_item: rl.Rectangle = .{ .x = promote.x + action_width + action_gap, .y = action_y, .width = action_width, .height = duplicate_item.height };
        const edit_text: rl.Rectangle = .{
            .x = properties.x + inset,
            .y = properties.y + 78 * scale,
            .width = inner_width,
            .height = @as(f32, if (compact_properties) 36 else 54) * scale,
        };

        const geometry_gap: f32 = 5 * scale;
        const compact_geometry = compact_properties;
        const geometry_columns: usize = if (compact_geometry) 4 else 2;
        const geometry_rows: usize = if (compact_geometry) 1 else 2;
        const geometry_width = (inner_width - geometry_gap * @as(f32, @floatFromInt(geometry_columns - 1))) /
            @as(f32, @floatFromInt(geometry_columns));
        const geometry_y = edit_text.y + edit_text.height + 8 * scale;
        var geometry_fields: [4]rl.Rectangle = undefined;
        for (&geometry_fields, 0..) |*field, index| field.* = .{
            .x = properties.x + inset + @as(f32, @floatFromInt(index % geometry_columns)) * (geometry_width + geometry_gap),
            .y = geometry_y + @as(f32, @floatFromInt(index / geometry_columns)) * (field_height + geometry_gap),
            .width = geometry_width,
            .height = field_height,
        };
        const geometry_bottom = geometry_y + @as(f32, @floatFromInt(geometry_rows)) * field_height +
            @as(f32, @floatFromInt(geometry_rows - 1)) * geometry_gap;

        const custom_width: f32 = 100 * scale;
        const custom_foreground: rl.Rectangle = .{
            .x = properties.x + inset,
            .y = geometry_bottom + 8 * scale,
            .width = custom_width,
            .height = field_height,
        };
        const swatch_gap: f32 = 4 * scale;
        const swatch_size = @min(@as(f32, 24) * scale, (inner_width - swatch_gap * 7) / 8);
        var foreground_swatches: [palette.len]rl.Rectangle = undefined;
        for (&foreground_swatches, 0..) |*swatch, index| swatch.* = .{
            .x = properties.x + inset + @as(f32, @floatFromInt(index)) * (swatch_size + swatch_gap),
            .y = custom_foreground.y + custom_foreground.height + 4 * scale,
            .width = swatch_size,
            .height = swatch_size,
        };

        const custom_background: rl.Rectangle = .{
            .x = properties.x + inset + 64 * scale,
            .y = foreground_swatches[0].y + swatch_size + 6 * scale,
            .width = custom_width,
            .height = field_height,
        };
        const clear_background: rl.Rectangle = .{
            .x = properties.x + inset,
            .y = custom_background.y,
            .width = 56 * scale,
            .height = field_height,
        };
        var background_swatches: [palette.len]rl.Rectangle = undefined;
        for (&background_swatches, 0..) |*swatch, index| swatch.* = .{
            .x = properties.x + inset + @as(f32, @floatFromInt(index)) * (swatch_size + swatch_gap),
            .y = custom_background.y + custom_background.height + 4 * scale,
            .width = swatch_size,
            .height = swatch_size,
        };

        const scalar_gap: f32 = 8 * scale;
        const scalar_width = (inner_width - scalar_gap) / 2;
        const scalar_y = background_swatches[0].y + swatch_size + 6 * scale;
        const font_size: rl.Rectangle = .{ .x = properties.x + inset, .y = scalar_y, .width = scalar_width, .height = field_height };
        const opacity: rl.Rectangle = .{ .x = font_size.x + scalar_width + scalar_gap, .y = scalar_y, .width = scalar_width, .height = field_height };
        const inline_error: rl.Rectangle = .{
            .x = properties.x + inset,
            .y = scalar_y + field_height + 4 * scale,
            .width = inner_width,
            .height = @min(@as(f32, 34) * scale, @max(@as(f32, 0), properties.y + properties.height - (scalar_y + field_height + 4 * scale) - 4 * scale)),
        };

        const lower_y = inline_error.y + inline_error.height + 10 * scale;
        const lower_available = properties.y + properties.height - lower_y;
        const minimal_properties = lower_available < 118 * scale;
        const align_gap: f32 = 5 * scale;
        const align_width = (inner_width - align_gap * 5) / 6;
        var align_buttons: [6]rl.Rectangle = undefined;
        for (&align_buttons, 0..) |*button, index| button.* = .{
            .x = if (minimal_properties) properties.x else properties.x + inset + @as(f32, @floatFromInt(index)) * (align_width + align_gap),
            .y = if (minimal_properties) properties.y else lower_y,
            .width = if (minimal_properties) 0 else align_width,
            .height = if (minimal_properties) 0 else 30 * scale,
        };
        const distribute_gap: f32 = 8 * scale;
        const distribute_width = (inner_width - distribute_gap) / 2;
        const distribute_y = lower_y + 38 * scale;
        const distribute_buttons = [2]rl.Rectangle{
            .{ .x = if (minimal_properties) properties.x else properties.x + inset, .y = if (minimal_properties) properties.y else distribute_y, .width = if (minimal_properties) 0 else distribute_width, .height = if (minimal_properties) 0 else 30 * scale },
            .{ .x = if (minimal_properties) properties.x else properties.x + inset + distribute_width + distribute_gap, .y = if (minimal_properties) properties.y else distribute_y, .width = if (minimal_properties) 0 else distribute_width, .height = if (minimal_properties) 0 else 30 * scale },
        };
        const layer_y = lower_y + 76 * scale;
        const layer_width = (inner_width - align_gap * 3) / 4;
        var layer_buttons: [4]rl.Rectangle = undefined;
        for (&layer_buttons, 0..) |*button, index| button.* = .{
            .x = if (minimal_properties) properties.x else properties.x + inset + @as(f32, @floatFromInt(index)) * (layer_width + align_gap),
            .y = if (minimal_properties) properties.y else layer_y,
            .width = if (minimal_properties) 0 else layer_width,
            .height = if (minimal_properties) 0 else 28 * scale,
        };
        return .{
            .scale = scale,
            .compact_properties = compact_properties,
            .minimal_properties = minimal_properties,
            .toolbar = toolbar,
            .tool_buttons = tool_buttons,
            .new_slide = new_slide,
            .grid_toggle = grid_toggle,
            .scene_previous = scene_previous,
            .scene_label = scene_label,
            .scene_next = scene_next,
            .slides_dock_toggle = slides_dock_toggle,
            .properties_dock_toggle = properties_dock_toggle,
            .focus_canvas = focus_canvas,
            .properties = properties,
            .edit_text = edit_text,
            .duplicate_item = duplicate_item,
            .delete_item = delete_item,
            .promote = promote,
            .geometry_fields = geometry_fields,
            .foreground_swatches = foreground_swatches,
            .custom_foreground = custom_foreground,
            .background_swatches = background_swatches,
            .custom_background = custom_background,
            .clear_background = clear_background,
            .font_size = font_size,
            .opacity = opacity,
            .inline_error = inline_error,
            .align_buttons = align_buttons,
            .distribute_buttons = distribute_buttons,
            .layer_buttons = layer_buttons,
            .lock_item = lock_item,
        };
    }
    // The compact align/distribute/layer stack ends just below 450 px. Below
    // that height retain the primary geometry/color/type controls and lock,
    // rather than allowing the last row to leak into the status dock.
    const minimal_properties = properties.height < 456 * scale;
    const inset = 12 * scale;
    const inner_width = properties.width - inset * 2;
    const action_y = properties.y + @as(f32, if (compact_properties) 36 else 42) * scale;
    const action_gap: f32 = 6 * scale;
    const action_width = (inner_width - action_gap * 3) / 4;
    const action_height: f32 = @as(f32, if (compact_properties) 34 else 36) * scale;
    const edit_text: rl.Rectangle = .{ .x = properties.x + inset, .y = action_y, .width = action_width, .height = action_height };
    const duplicate_item: rl.Rectangle = .{ .x = edit_text.x + action_width + action_gap, .y = action_y, .width = action_width, .height = action_height };
    const delete_item: rl.Rectangle = .{ .x = duplicate_item.x + action_width + action_gap, .y = action_y, .width = action_width, .height = action_height };
    const promote: rl.Rectangle = .{ .x = delete_item.x + action_width + action_gap, .y = action_y, .width = action_width, .height = action_height };

    var geometry_fields: [4]rl.Rectangle = undefined;
    const geometry_gap: f32 = 6 * scale;
    const geometry_width = if (compact_properties)
        (inner_width - geometry_gap * 3) / 4
    else
        (inner_width - geometry_gap) / 2;
    for (&geometry_fields, 0..) |*button, index| button.* = .{
        .x = properties.x + inset + @as(f32, @floatFromInt(if (compact_properties) index else index % 2)) * (geometry_width + geometry_gap),
        .y = properties.y + @as(f32, if (compact_properties)
            94
        else
            108 + @as(f32, @floatFromInt(index / 2)) * 40) * scale,
        .width = geometry_width,
        .height = @as(f32, if (compact_properties) 34 else 36) * scale,
    };

    var foreground_swatches: [palette.len]rl.Rectangle = undefined;
    var background_swatches: [palette.len]rl.Rectangle = undefined;
    const swatch_size: f32 = @as(f32, if (compact_properties) 24 else 26) * scale;
    const swatch_gap = (inner_width - swatch_size * @as(f32, @floatFromInt(palette.len))) /
        @as(f32, @floatFromInt(palette.len - 1));
    for (&foreground_swatches, 0..) |*swatch, index| swatch.* = .{
        .x = properties.x + inset + @as(f32, @floatFromInt(index)) * (swatch_size + swatch_gap),
        .y = properties.y + @as(f32, if (compact_properties) 160 else 220) * scale,
        .width = swatch_size,
        .height = swatch_size,
    };
    for (&background_swatches, 0..) |*swatch, index| swatch.* = .{
        .x = properties.x + inset + @as(f32, @floatFromInt(index)) * (swatch_size + swatch_gap),
        .y = properties.y + @as(f32, if (compact_properties) 218 else 282) * scale,
        .width = swatch_size,
        .height = swatch_size,
    };
    const custom_foreground: rl.Rectangle = .{
        .x = properties.x + properties.width - inset - 84 * scale,
        .y = properties.y + @as(f32, if (compact_properties) 132 else 188) * scale,
        .width = 84 * scale,
        .height = @as(f32, if (compact_properties) 26 else 30) * scale,
    };
    const custom_background: rl.Rectangle = .{
        .x = custom_foreground.x,
        .y = properties.y + @as(f32, if (compact_properties) 190 else 250) * scale,
        .width = custom_foreground.width,
        .height = custom_foreground.height,
    };
    const clear_background: rl.Rectangle = .{
        .x = custom_background.x - 6 * scale - 58 * scale,
        .y = custom_background.y,
        .width = 58 * scale,
        .height = custom_background.height,
    };

    const scalar_gap: f32 = 8 * scale;
    const scalar_width = if (minimal_properties)
        (inner_width - scalar_gap * 2) / 3
    else
        (inner_width - scalar_gap) / 2;
    const font_size: rl.Rectangle = .{
        .x = properties.x + inset,
        .y = properties.y + @as(f32, if (minimal_properties) 264 else if (compact_properties) 270 else 334) * scale,
        .width = scalar_width,
        .height = @as(f32, if (minimal_properties) 32 else if (compact_properties) 34 else 36) * scale,
    };
    const opacity: rl.Rectangle = .{
        .x = font_size.x + scalar_width + scalar_gap,
        .y = font_size.y,
        .width = scalar_width,
        .height = font_size.height,
    };

    var align_buttons: [6]rl.Rectangle = undefined;
    const align_gap: f32 = 5 * scale;
    const align_width = (inner_width - align_gap * 5) / 6;
    for (&align_buttons, 0..) |*button, index| button.* = .{
        .x = if (minimal_properties) properties.x else properties.x + inset + @as(f32, @floatFromInt(index)) * (align_width + align_gap),
        .y = if (minimal_properties) properties.y else properties.y + @as(f32, if (compact_properties) 330 else 396) * scale,
        .width = if (minimal_properties) 0 else align_width,
        .height = if (minimal_properties) 0 else @as(f32, if (compact_properties) 32 else 34) * scale,
    };
    const distribute_y = properties.y + @as(f32, if (compact_properties) 388 else 456) * scale;
    const distribute_gap: f32 = 8 * scale;
    const distribute_width = (inner_width - distribute_gap) / 2;
    const distribute_buttons = [2]rl.Rectangle{
        .{ .x = if (minimal_properties) properties.x else properties.x + inset, .y = if (minimal_properties) properties.y else distribute_y, .width = if (minimal_properties) 0 else distribute_width, .height = if (minimal_properties) 0 else @as(f32, if (compact_properties) 32 else 34) * scale },
        .{ .x = if (minimal_properties) properties.x else properties.x + inset + distribute_width + distribute_gap, .y = if (minimal_properties) properties.y else distribute_y, .width = if (minimal_properties) 0 else distribute_width, .height = if (minimal_properties) 0 else @as(f32, if (compact_properties) 32 else 34) * scale },
    };
    var layer_buttons: [4]rl.Rectangle = undefined;
    const layer_y = properties.y + @as(f32, if (compact_properties) 423 else 520) * scale;
    const layer_gap: f32 = 5 * scale;
    const lock_width: f32 = 68 * scale;
    const layer_width = (inner_width - lock_width - 10 * scale - layer_gap * 3) / 4;
    for (&layer_buttons, 0..) |*button, index| button.* = .{
        .x = if (minimal_properties) properties.x else properties.x + inset + @as(f32, @floatFromInt(index)) * (layer_width + layer_gap),
        .y = if (minimal_properties) properties.y else layer_y,
        .width = if (minimal_properties) 0 else layer_width,
        .height = if (minimal_properties) 0 else @as(f32, if (compact_properties) 26 else 30) * scale,
    };
    const lock_item: rl.Rectangle = .{
        .x = if (minimal_properties) opacity.x + scalar_width + scalar_gap else properties.x + properties.width - inset - lock_width,
        .y = if (minimal_properties) font_size.y else layer_y,
        .width = if (minimal_properties) scalar_width else lock_width,
        .height = if (minimal_properties) font_size.height else @as(f32, if (compact_properties) 26 else 30) * scale,
    };
    return .{
        .scale = scale,
        .compact_properties = compact_properties,
        .minimal_properties = minimal_properties,
        .toolbar = toolbar,
        .tool_buttons = tool_buttons,
        .new_slide = new_slide,
        .grid_toggle = grid_toggle,
        .scene_previous = scene_previous,
        .scene_label = scene_label,
        .scene_next = scene_next,
        .slides_dock_toggle = slides_dock_toggle,
        .properties_dock_toggle = properties_dock_toggle,
        .focus_canvas = focus_canvas,
        .properties = properties,
        .edit_text = edit_text,
        .duplicate_item = duplicate_item,
        .delete_item = delete_item,
        .promote = promote,
        .geometry_fields = geometry_fields,
        .foreground_swatches = foreground_swatches,
        .custom_foreground = custom_foreground,
        .background_swatches = background_swatches,
        .custom_background = custom_background,
        .clear_background = clear_background,
        .font_size = font_size,
        .opacity = opacity,
        .align_buttons = align_buttons,
        .distribute_buttons = distribute_buttons,
        .layer_buttons = layer_buttons,
        .lock_item = lock_item,
    };
}

fn statusPanel(viewport: Viewport) rl.Rectangle {
    if (viewport.chrome) |chrome| return if (chrome.visible) chrome.status else empty_frame_rectangle;
    const scale = uiScale(viewport);
    const margin = 12 * scale;
    const panel_height: f32 = 116 * scale;
    return .{
        .x = viewport.slide_top_left.x + margin,
        .y = viewport.slide_top_left.y + viewport.slide_size.y - panel_height - margin,
        .width = @max(340 * scale, @min(960 * scale, viewport.slide_size.x - margin * 2)),
        .height = panel_height,
    };
}

/// A testable input snapshot. `updateFromRaylib` is the convenient runtime
/// adapter; tests and other frontends can call `update` directly.
pub const FrameInput = struct {
    inline_chars: [256]u8 = [_]u8{0} ** 256,
    inline_chars_len: usize = 0,
    inline_paste: ?[]const u8 = null,
    inline_backspace_pressed: bool = false,
    inline_delete_pressed: bool = false,
    inline_left_pressed: bool = false,
    inline_right_pressed: bool = false,
    inline_home_pressed: bool = false,
    inline_end_pressed: bool = false,
    inline_submit_pressed: bool = false,
    shortcut_modifier_down: bool = false,
    shift_down: bool = false,
    toggle_pressed: bool = false,
    toggle_focus_canvas_pressed: bool = false,
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
        var result: FrameInput = .{
            .inline_paste = if (shortcut_modifier and rl.isKeyPressed(.v)) rl.getClipboardText() else null,
            .inline_backspace_pressed = keyPressedOrRepeated(.backspace),
            .inline_delete_pressed = keyPressedOrRepeated(.delete),
            .inline_left_pressed = keyPressedOrRepeated(.left),
            .inline_right_pressed = keyPressedOrRepeated(.right),
            .inline_home_pressed = keyPressedOrRepeated(.home),
            .inline_end_pressed = keyPressedOrRepeated(.end),
            .inline_submit_pressed = rl.isKeyPressed(.enter),
            .shortcut_modifier_down = shortcut_modifier,
            .shift_down = shift,
            .toggle_pressed = rl.isKeyPressed(.e),
            .toggle_focus_canvas_pressed = rl.isKeyPressed(.tab),
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
        while (result.inline_chars_len < result.inline_chars.len) {
            const pressed = rl.getCharPressed();
            if (pressed <= 0) break;
            const codepoint = std.math.cast(u21, pressed) orelse continue;
            if (codepoint < 32 or codepoint == 127) continue;
            var encoded: [4]u8 = undefined;
            const encoded_len = std.unicode.utf8Encode(codepoint, &encoded) catch continue;
            if (encoded_len > result.inline_chars.len - result.inline_chars_len) break;
            @memcpy(result.inline_chars[result.inline_chars_len .. result.inline_chars_len + encoded_len], encoded[0..encoded_len]);
            result.inline_chars_len += encoded_len;
        }
        return result;
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

/// Marquee selection is deliberately separate from geometry Interaction:
/// none of the selected items is mutated while the rubber band is active.
const Marquee = struct {
    active: bool = false,
    start: rl.Vector2 = .zero(),
    current: rl.Vector2 = .zero(),
    extend: bool = false,
    snapshot: [max_selection_items]SelectionMember = undefined,
    snapshot_count: usize = 0,
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

pub const max_inline_input_bytes: usize = 8192;

const InlineEditor = struct {
    active: bool = false,
    field: InlineField = .x,
    target: CommandTarget = .{ .item_identity = 0, .source = .{} },
    buffer: [max_inline_input_bytes + 1]u8 = [_]u8{0} ** (max_inline_input_bytes + 1),
    opening_buffer: [max_inline_input_bytes + 1]u8 = [_]u8{0} ** (max_inline_input_bytes + 1),
    len: usize = 0,
    opening_len: usize = 0,
    cursor: usize = 0,
    select_all: bool = false,
    blocked_initial: bool = false,
    dirty: bool = false,
    awaiting_commit: bool = false,
    refresh_pending: bool = false,
    advance_after_accept: i8 = 0,
    next_field_after_accept: ?InlineField = null,
    next_scope_after_accept: ?EditScope = null,
    blur_after_accept: bool = false,
    stable_id_hash: ?u64 = null,
    error_value: ?InlineError = null,

    fn text(self: *const InlineEditor) []const u8 {
        return self.buffer[0..self.len];
    }
};

pub const Studio = struct {
    enabled: bool = false,
    /// Focus Canvas keeps editing/selection live while hiding all permanent
    /// chrome. The next frame should be obtained through layoutFrame().
    focus_canvas: bool = false,
    /// Below the wide breakpoint only this dock is reserved beside the slide.
    active_dock: DockPanel = .slides,
    /// Wide windows always reserve the right dock; this chooses its content.
    /// Compact windows remember the tab even while the inspector is closed.
    inspector_panel: InspectorPanel = .objects,
    /// A dedicated, narrow UI face supplied by the integration layer. A null
    /// font retains raylib's built-in text path for lightweight embedders and
    /// unit tests.
    ui_font: ?rl.Font = null,
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
    marquee: Marquee = .{},
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
    inline_editor: InlineEditor = .{},
    composition_context: ?CompositionContext = null,
    group_drag: [max_selection_items]GroupDragMember = undefined,
    group_drag_count: usize = 0,
    group_bounds_before: Geometry = .{ .position = .zero(), .size = .zero() },
    group_bounds_after: Geometry = .{ .position = .zero(), .size = .zero() },
    organizer_first_visible: usize = 0,
    library_first_visible: usize = 0,
    objects_first_visible: usize = 0,
    last_objects_primary: ?usize = null,
    selected_library_index: ?usize = null,
    last_workspace_slide: ?usize = null,

    pub fn capturesInput(self: Studio) bool {
        return self.enabled;
    }

    pub fn layoutFrame(self: Studio, content: rl.Rectangle) FrameLayout {
        return frameLayout(content, self.enabled, self.focus_canvas, self.active_dock);
    }

    pub fn setUiFont(self: *Studio, font: ?rl.Font) void {
        self.ui_font = font;
    }

    /// Copies capability metadata; no borrowed strings or slices survive the
    /// call. Passing null deliberately disables reset/detach until the
    /// integration can prove them safe again.
    pub fn setCompositionContext(self: *Studio, context: ?CompositionContext) void {
        self.composition_context = context;
    }

    pub fn inlineEditActive(self: Studio) bool {
        return self.inline_editor.active;
    }

    pub fn inlineEditField(self: Studio) ?InlineField {
        return if (self.inline_editor.active) self.inline_editor.field else null;
    }

    pub fn inlineEditText(self: *const Studio) []const u8 {
        return if (self.inline_editor.active) self.inline_editor.text() else "";
    }

    pub fn inlineEditError(self: Studio) ?InlineError {
        return if (self.inline_editor.active) self.inline_editor.error_value else null;
    }

    /// Completes a synchronous integration commit. The editor deliberately
    /// remains active; the next update refreshes the canonical value from the
    /// reparsed item before applying queued Tab traversal.
    pub fn acceptInlineCommit(self: *Studio, field: InlineField) void {
        if (!self.inline_editor.active or self.inline_editor.field != field or
            !self.inline_editor.awaiting_commit) return;
        self.inline_editor.awaiting_commit = false;
        self.inline_editor.refresh_pending = true;
        self.inline_editor.error_value = null;
        self.inline_editor.dirty = false;
    }

    /// Leaves the user's exact UTF-8 buffer and caret intact so a rejected
    /// value can be corrected without reopening or retyping the field.
    pub fn rejectInlineCommit(self: *Studio, field: InlineField, reason: InlineError) void {
        if (!self.inline_editor.active or self.inline_editor.field != field or
            !self.inline_editor.awaiting_commit) return;
        self.inline_editor.awaiting_commit = false;
        self.inline_editor.refresh_pending = false;
        self.inline_editor.advance_after_accept = 0;
        self.inline_editor.next_field_after_accept = null;
        self.inline_editor.next_scope_after_accept = null;
        self.inline_editor.blur_after_accept = false;
        self.inline_editor.error_value = reason;
    }

    fn cancelInlineEdit(self: *Studio) void {
        self.inline_editor = .{};
    }

    fn setInlineBuffer(self: *Studio, value: []const u8) bool {
        if (!std.unicode.utf8ValidateSlice(value)) {
            self.inline_editor.len = 0;
            self.inline_editor.opening_len = 0;
            self.inline_editor.cursor = 0;
            self.inline_editor.buffer[0] = 0;
            self.inline_editor.opening_buffer[0] = 0;
            self.inline_editor.error_value = .invalid_utf8;
            self.inline_editor.blocked_initial = true;
            return false;
        }
        if (value.len > max_inline_input_bytes) {
            self.inline_editor.len = 0;
            self.inline_editor.opening_len = 0;
            self.inline_editor.cursor = 0;
            self.inline_editor.buffer[0] = 0;
            self.inline_editor.opening_buffer[0] = 0;
            self.inline_editor.error_value = .too_long;
            self.inline_editor.blocked_initial = true;
            return false;
        }
        @memcpy(self.inline_editor.buffer[0..value.len], value);
        @memcpy(self.inline_editor.opening_buffer[0..value.len], value);
        self.inline_editor.buffer[value.len] = 0;
        self.inline_editor.opening_buffer[value.len] = 0;
        self.inline_editor.len = value.len;
        self.inline_editor.opening_len = value.len;
        self.inline_editor.cursor = value.len;
        self.inline_editor.error_value = null;
        self.inline_editor.blocked_initial = false;
        return true;
    }

    fn formatInlineFloat(buffer: []u8, value: f32) []const u8 {
        const raw = std.fmt.bufPrint(buffer, "{d:.3}", .{value}) catch return "";
        var end = raw.len;
        while (end > 0 and raw[end - 1] == '0') end -= 1;
        if (end > 0 and raw[end - 1] == '.') end -= 1;
        return raw[0..end];
    }

    fn formatInlineColor(buffer: *[9]u8, color: rl.Color) []const u8 {
        const digits = "0123456789abcdef";
        const components = [_]u8{ color.r, color.g, color.b, color.a };
        buffer[0] = '#';
        for (components, 0..) |component, index| {
            buffer[1 + index * 2] = digits[component >> 4];
            buffer[2 + index * 2] = digits[component & 0x0f];
        }
        return buffer;
    }

    fn inlineFieldApplies(field: InlineField, item: slides.SlideItem) bool {
        if (item.kind == .background) return false;
        return switch (field) {
            .text, .foreground, .font_size => item.kind == .textbox,
            .x, .y, .width, .height, .background, .opacity => true,
        };
    }

    fn inlineInitialValue(
        _: Studio,
        item: slides.SlideItem,
        resolved_bounds: []const ResolvedBounds,
        field: InlineField,
        edit_scope: EditScope,
        scalar_buffer: []u8,
        color_buffer: *[9]u8,
    ) []const u8 {
        const shared = if (edit_scope == .shared_template) item.sharedTemplateValues() else null;
        const geometry = if (shared) |values|
            Geometry{ .position = values.position, .size = values.size }
        else
            itemGeometry(item, resolved_bounds);
        return switch (field) {
            .text => if (shared) |values| values.text orelse "" else item.text orelse "",
            .x => formatInlineFloat(scalar_buffer, geometry.position.x),
            .y => formatInlineFloat(scalar_buffer, geometry.position.y),
            .width => formatInlineFloat(scalar_buffer, geometry.size.x),
            .height => formatInlineFloat(scalar_buffer, geometry.size.y),
            .foreground => formatInlineColor(color_buffer, if (shared) |values| values.color orelse .white else item.color orelse .white),
            .background => if (shared) |values|
                if (values.background_color) |color| formatInlineColor(color_buffer, color) else "none"
            else if (item.background_color) |color|
                formatInlineColor(color_buffer, color)
            else
                "none",
            .font_size => if (shared) |values|
                if (values.font_size) |size| std.fmt.bufPrint(scalar_buffer, "{d}", .{size}) catch "" else ""
            else if (item.fontSize) |size|
                std.fmt.bufPrint(scalar_buffer, "{d}", .{size}) catch ""
            else
                "",
            .opacity => formatInlineFloat(scalar_buffer, if (shared) |values| values.opacity else item.opacity),
        };
    }

    fn beginInlineEdit(
        self: *Studio,
        items: []slides.SlideItem,
        resolved_bounds: []const ResolvedBounds,
        field: InlineField,
        allow_shared_edit: bool,
    ) bool {
        const index = self.selectedIndex(items) orelse return false;
        if (self.selectionCount() != 1) {
            self.notice = .multi_selection_property_unsupported;
            return true;
        }
        const item = items[index];
        if (item.locked) {
            self.notice = .locked_item;
            return true;
        }
        if (!inlineFieldApplies(field, item)) {
            self.notice = .property_unavailable;
            return true;
        }
        if (self.interaction != .idle) self.cancelInteraction(items);
        const edit_scope = self.editScopeForItem(items, index, allow_shared_edit) orelse return true;
        const target: CommandTarget = .{
            .item_identity = item.identity,
            .source = self.commandSource(item, edit_scope),
            .edit_scope = edit_scope,
        };
        self.inline_editor = .{
            .active = true,
            .field = field,
            .target = target,
            .stable_id_hash = if (item.id != null and itemIdIsUnique(items, index))
                std.hash.Wyhash.hash(0, item.id.?)
            else
                null,
        };
        var scalar_buffer: [64]u8 = undefined;
        var color_buffer: [9]u8 = undefined;
        const initial = self.inlineInitialValue(item, resolved_bounds, field, edit_scope, &scalar_buffer, &color_buffer);
        _ = self.setInlineBuffer(initial);
        self.inline_editor.dirty = false;
        self.notice = .none;
        return true;
    }

    fn inlineValueError(field: InlineField, raw_value: []const u8) ?InlineError {
        if (!std.unicode.utf8ValidateSlice(raw_value)) return .invalid_utf8;
        const value = std.mem.trim(u8, raw_value, " \t\r\n");
        return switch (field) {
            .text => blk: {
                if (std.mem.indexOfScalar(u8, raw_value, '\r') != null) break :blk .invalid_text;
                if (std.mem.indexOfScalar(u8, raw_value, '\n') == null) break :blk null;
                var lines = std.mem.splitScalar(u8, raw_value, '\n');
                while (lines.next()) |line| {
                    if (line.len > 0 and (line[0] == '@' or line[0] == '#')) break :blk .invalid_text;
                }
                break :blk null;
            },
            .x, .y => blk: {
                const parsed = std.fmt.parseFloat(f32, value) catch break :blk .invalid_number;
                break :blk if (std.math.isFinite(parsed)) null else .invalid_number;
            },
            .width, .height => blk: {
                const parsed = std.fmt.parseFloat(f32, value) catch break :blk .invalid_number;
                if (!std.math.isFinite(parsed)) break :blk .invalid_number;
                break :blk if (parsed >= default_min_item_size) null else .non_positive_dimension;
            },
            .foreground, .background => blk: {
                if (field == .background and std.ascii.eqlIgnoreCase(value, "none")) break :blk null;
                if ((value.len != 7 and value.len != 9) or value[0] != '#') break :blk .invalid_color;
                for (value[1..]) |byte| if (!std.ascii.isHex(byte)) break :blk .invalid_color;
                break :blk null;
            },
            .font_size => blk: {
                const parsed = std.fmt.parseInt(i32, value, 10) catch break :blk .invalid_font_size;
                break :blk if (parsed > 0 and parsed <= 4096) null else .invalid_font_size;
            },
            .opacity => blk: {
                if (value.len == 0) break :blk .invalid_opacity;
                const percent = value[value.len - 1] == '%';
                const number = if (percent) std.mem.trim(u8, value[0 .. value.len - 1], " \t") else value;
                const parsed = std.fmt.parseFloat(f32, number) catch break :blk .invalid_opacity;
                if (!std.math.isFinite(parsed)) break :blk .invalid_opacity;
                const maximum: f32 = if (percent) 100 else 1;
                break :blk if (parsed >= 0 and parsed <= maximum) null else .invalid_opacity;
            },
        };
    }

    fn insertInlineBytes(self: *Studio, value: []const u8) bool {
        if (!std.unicode.utf8ValidateSlice(value)) {
            self.inline_editor.error_value = .invalid_utf8;
            return false;
        }
        const retained_len = if (self.inline_editor.select_all) 0 else self.inline_editor.len;
        if (value.len > max_inline_input_bytes - retained_len) {
            self.inline_editor.error_value = .too_long;
            return false;
        }
        if (self.inline_editor.select_all) {
            self.inline_editor.len = 0;
            self.inline_editor.cursor = 0;
            self.inline_editor.select_all = false;
        }
        const cursor = self.inline_editor.cursor;
        const old_len = self.inline_editor.len;
        std.mem.copyBackwards(
            u8,
            self.inline_editor.buffer[cursor + value.len .. old_len + value.len],
            self.inline_editor.buffer[cursor..old_len],
        );
        @memcpy(self.inline_editor.buffer[cursor .. cursor + value.len], value);
        self.inline_editor.len += value.len;
        self.inline_editor.cursor += value.len;
        self.inline_editor.buffer[self.inline_editor.len] = 0;
        self.updateInlineDirty();
        self.inline_editor.error_value = null;
        return true;
    }

    fn clearInlineSelection(self: *Studio) bool {
        if (!self.inline_editor.select_all) return false;
        self.inline_editor.len = 0;
        self.inline_editor.cursor = 0;
        self.inline_editor.buffer[0] = 0;
        self.inline_editor.select_all = false;
        self.updateInlineDirty();
        self.inline_editor.error_value = null;
        return true;
    }

    fn removeInlineBeforeCursor(self: *Studio) void {
        if (self.clearInlineSelection() or self.inline_editor.cursor == 0) return;
        const cursor = self.inline_editor.cursor;
        var start = cursor - 1;
        while (start > 0 and self.inline_editor.buffer[start] & 0xc0 == 0x80) start -= 1;
        std.mem.copyForwards(
            u8,
            self.inline_editor.buffer[start .. self.inline_editor.len - (cursor - start)],
            self.inline_editor.buffer[cursor..self.inline_editor.len],
        );
        self.inline_editor.len -= cursor - start;
        self.inline_editor.cursor = start;
        self.inline_editor.buffer[self.inline_editor.len] = 0;
        self.updateInlineDirty();
        self.inline_editor.error_value = null;
    }

    fn removeInlineAtCursor(self: *Studio) void {
        if (self.clearInlineSelection() or self.inline_editor.cursor >= self.inline_editor.len) return;
        const cursor = self.inline_editor.cursor;
        var end = cursor + 1;
        while (end < self.inline_editor.len and self.inline_editor.buffer[end] & 0xc0 == 0x80) end += 1;
        std.mem.copyForwards(
            u8,
            self.inline_editor.buffer[cursor .. self.inline_editor.len - (end - cursor)],
            self.inline_editor.buffer[end..self.inline_editor.len],
        );
        self.inline_editor.len -= end - cursor;
        self.inline_editor.buffer[self.inline_editor.len] = 0;
        self.updateInlineDirty();
        self.inline_editor.error_value = null;
    }

    fn moveInlineCursor(self: *Studio, direction: i8) void {
        self.inline_editor.select_all = false;
        if (direction < 0 and self.inline_editor.cursor > 0) {
            self.inline_editor.cursor -= 1;
            while (self.inline_editor.cursor > 0 and self.inline_editor.buffer[self.inline_editor.cursor] & 0xc0 == 0x80)
                self.inline_editor.cursor -= 1;
        } else if (direction > 0 and self.inline_editor.cursor < self.inline_editor.len) {
            self.inline_editor.cursor += 1;
            while (self.inline_editor.cursor < self.inline_editor.len and self.inline_editor.buffer[self.inline_editor.cursor] & 0xc0 == 0x80)
                self.inline_editor.cursor += 1;
        }
    }

    fn updateInlineDirty(self: *Studio) void {
        self.inline_editor.dirty = self.inline_editor.len != self.inline_editor.opening_len or
            !std.mem.eql(
                u8,
                self.inline_editor.buffer[0..self.inline_editor.len],
                self.inline_editor.opening_buffer[0..self.inline_editor.opening_len],
            );
    }

    fn queueInlineCommit(
        self: *Studio,
        advance: i8,
        next_field: ?InlineField,
        next_scope: ?EditScope,
    ) bool {
        if (!self.inline_editor.active or self.inline_editor.awaiting_commit) return true;
        if (self.inline_editor.blocked_initial) return true;
        if (inlineValueError(self.inline_editor.field, self.inline_editor.text())) |reason| {
            self.inline_editor.error_value = reason;
            self.inline_editor.advance_after_accept = 0;
            self.inline_editor.next_field_after_accept = null;
            self.inline_editor.next_scope_after_accept = null;
            self.inline_editor.blur_after_accept = false;
            return true;
        }
        self.inline_editor.advance_after_accept = advance;
        self.inline_editor.next_field_after_accept = next_field;
        self.inline_editor.next_scope_after_accept = next_scope;
        self.inline_editor.awaiting_commit = true;
        self.inline_editor.error_value = null;
        self.pending_semantic_command = .{ .commit_inline = .{
            .target = self.inline_editor.target,
            .field = self.inline_editor.field,
            .value = self.inline_editor.text(),
        } };
        return true;
    }

    fn nextInlineField(field: InlineField, direction: i8, item: slides.SlideItem) InlineField {
        const fields = [_]InlineField{ .text, .x, .y, .width, .height, .foreground, .background, .font_size, .opacity };
        var current: usize = 0;
        for (fields, 0..) |candidate, index| if (candidate == field) {
            current = index;
            break;
        };
        var step: usize = 0;
        while (step < fields.len) : (step += 1) {
            current = if (direction < 0)
                if (current == 0) fields.len - 1 else current - 1
            else
                (current + 1) % fields.len;
            if (inlineFieldApplies(fields[current], item)) return fields[current];
        }
        return field;
    }

    fn inlineFieldRect(layout: UiLayout, field: InlineField) rl.Rectangle {
        return switch (field) {
            .text => layout.edit_text,
            .x => layout.geometry_fields[0],
            .y => layout.geometry_fields[1],
            .width => layout.geometry_fields[2],
            .height => layout.geometry_fields[3],
            .foreground => layout.custom_foreground,
            .background => layout.custom_background,
            .font_size => layout.font_size,
            .opacity => layout.opacity,
        };
    }

    fn inlineFieldAtPoint(layout: UiLayout, item: slides.SlideItem, pointer: rl.Vector2) ?InlineField {
        const fields = [_]InlineField{ .text, .x, .y, .width, .height, .foreground, .background, .font_size, .opacity };
        for (fields) |field| {
            if (inlineFieldApplies(field, item) and pointInRectangle(pointer, inlineFieldRect(layout, field))) return field;
        }
        return null;
    }

    fn inlineOverrideFieldAtPoint(
        self: Studio,
        items: []const slides.SlideItem,
        layout: UiLayout,
        pointer: rl.Vector2,
    ) ?InlineField {
        const context = self.compositionContextForSelection(items) orelse return null;
        const fields = [_]InlineField{ .text, .x, .y, .width, .height, .foreground, .background, .font_size, .opacity };
        for (fields) |field| {
            if (!context.local_overrides.contains(field)) continue;
            if (pointInRectangle(pointer, inlineResetRect(inlineFieldRect(layout, field)))) return field;
        }
        return null;
    }

    fn inlinePropertiesVisible(self: Studio, viewport: Viewport) bool {
        const chrome = viewport.chrome orelse return false;
        return chrome.visible and chrome.right_visible and !self.focus_canvas and
            self.inspector_panel == .properties;
    }

    fn revealInlineProperties(self: *Studio) void {
        self.focus_canvas = false;
        self.active_dock = .properties;
        self.inspector_panel = .properties;
        self.notice = .none;
    }

    fn compositionContextForSelection(
        self: Studio,
        items: []const slides.SlideItem,
    ) ?CompositionContext {
        if (self.selectionCount() != 1) return null;
        const context = self.composition_context orelse return null;
        const item_index = self.selectedIndex(items) orelse return null;
        const item = items[item_index];
        if (context.item_identity != item.identity) return null;
        const source_matches = sourceEqual(context.selection_source, item.source) or
            sourceEqual(context.selection_source, item.effectiveBaseSource()) or
            sourceEqual(context.selection_source, item.effectiveSource());
        if (!source_matches) return null;
        return context;
    }

    fn inlineTargetStillMatches(self: Studio, items: []const slides.SlideItem, item_index: usize) bool {
        const item = items[item_index];
        if (self.inline_editor.stable_id_hash) |wanted_hash| {
            const id = item.id orelse return false;
            return itemIdIsUnique(items, item_index) and std.hash.Wyhash.hash(0, id) == wanted_hash;
        }
        return item.identity == self.inline_editor.target.item_identity;
    }

    fn refreshInlineEditor(
        self: *Studio,
        items: []slides.SlideItem,
        resolved_bounds: []const ResolvedBounds,
    ) void {
        if (!self.inline_editor.active or !self.inline_editor.refresh_pending) return;
        self.inline_editor.refresh_pending = false;
        const item_index = self.selectedIndex(items) orelse {
            self.inline_editor.error_value = .source_edit_failed;
            self.inline_editor.advance_after_accept = 0;
            self.inline_editor.next_field_after_accept = null;
            self.inline_editor.next_scope_after_accept = null;
            self.inline_editor.blur_after_accept = false;
            return;
        };
        if (self.selectionCount() != 1 or !self.inlineTargetStillMatches(items, item_index)) {
            self.inline_editor.error_value = .source_edit_failed;
            self.inline_editor.advance_after_accept = 0;
            self.inline_editor.next_field_after_accept = null;
            self.inline_editor.next_scope_after_accept = null;
            self.inline_editor.blur_after_accept = false;
            return;
        }
        const item = items[item_index];
        const previous_field = self.inline_editor.field;
        const previous_scope = self.inline_editor.target.edit_scope;
        const requested_next = self.inline_editor.next_field_after_accept;
        const requested_next_scope = self.inline_editor.next_scope_after_accept;
        const advance = self.inline_editor.advance_after_accept;
        const blur = self.inline_editor.blur_after_accept;
        self.inline_editor.target = .{
            .item_identity = item.identity,
            .source = self.commandSource(item, previous_scope),
            .edit_scope = previous_scope,
        };
        var scalar_buffer: [64]u8 = undefined;
        var color_buffer: [9]u8 = undefined;
        const canonical = self.inlineInitialValue(
            item,
            resolved_bounds,
            previous_field,
            previous_scope,
            &scalar_buffer,
            &color_buffer,
        );
        _ = self.setInlineBuffer(canonical);
        self.inline_editor.dirty = false;
        self.inline_editor.select_all = true;
        self.inline_editor.advance_after_accept = 0;
        self.inline_editor.next_field_after_accept = null;
        self.inline_editor.next_scope_after_accept = null;
        self.inline_editor.blur_after_accept = false;
        if (blur) {
            self.cancelInlineEdit();
            return;
        }
        const next_field = requested_next orelse if (advance != 0)
            nextInlineField(previous_field, advance, item)
        else
            return;
        const next_scope = requested_next_scope orelse previous_scope;
        _ = self.beginInlineEdit(items, resolved_bounds, next_field, next_scope == .shared_template);
        if (!self.inline_editor.active or self.inline_editor.target.edit_scope != next_scope) {
            self.inline_editor.error_value = .source_edit_failed;
            return;
        }
        self.inline_editor.select_all = true;
    }

    fn handleInlineEditor(
        self: *Studio,
        items: []slides.SlideItem,
        resolved_bounds: []const ResolvedBounds,
        viewport: Viewport,
        input: FrameInput,
    ) bool {
        self.refreshInlineEditor(items, resolved_bounds);
        if (!self.inline_editor.active) return false;
        if (input.cancel_pressed) {
            self.cancelInlineEdit();
            self.notice = .none;
            return true;
        }
        if (self.inline_editor.blocked_initial or self.inline_editor.awaiting_commit) return true;

        const item_index = self.selectedIndex(items) orelse {
            self.cancelInlineEdit();
            return true;
        };
        if (self.selectionCount() != 1 or !self.inlineTargetStillMatches(items, item_index)) {
            self.cancelInlineEdit();
            self.notice = .edit_failed;
            return true;
        }
        const item = items[item_index];
        const layout = uiLayout(viewport);
        if (input.pointer_pressed) {
            if (self.inlineOverrideFieldAtPoint(items, layout, input.pointer_screen)) |field| {
                if (self.inline_editor.dirty) {
                    self.inline_editor.blur_after_accept = true;
                    return self.queueInlineCommit(0, null, null);
                }
                self.cancelInlineEdit();
                _ = self.emitResetOverride(items, field);
                return true;
            }
            if (inlineFieldAtPoint(layout, item, input.pointer_screen)) |field| {
                if (field == self.inline_editor.field) {
                    self.inline_editor.select_all = true;
                    return true;
                }
                if (self.inline_editor.dirty) {
                    const next_scope = self.editScopeForItem(items, item_index, input.allow_shared_edit) orelse return true;
                    self.inline_editor.blur_after_accept = false;
                    return self.queueInlineCommit(0, field, next_scope);
                }
                _ = self.beginInlineEdit(items, resolved_bounds, field, input.allow_shared_edit);
                self.inline_editor.select_all = true;
                return true;
            }
            if (self.inline_editor.dirty) {
                self.inline_editor.blur_after_accept = true;
                _ = self.queueInlineCommit(0, null, null);
            } else {
                self.cancelInlineEdit();
                return false;
            }
            return true;
        }

        if (input.select_all_pressed) {
            self.inline_editor.select_all = true;
            return true;
        }
        if (input.copy_pressed) {
            const text: [:0]const u8 = self.inline_editor.buffer[0..self.inline_editor.len :0];
            rl.setClipboardText(text);
            return true;
        }
        if (input.inline_paste) |paste| _ = self.insertInlineBytes(paste);
        if (input.inline_home_pressed) {
            self.inline_editor.cursor = 0;
            self.inline_editor.select_all = false;
        }
        if (input.inline_end_pressed) {
            self.inline_editor.cursor = self.inline_editor.len;
            self.inline_editor.select_all = false;
        }
        if (input.inline_left_pressed) self.moveInlineCursor(-1);
        if (input.inline_right_pressed) self.moveInlineCursor(1);
        if (input.inline_backspace_pressed) self.removeInlineBeforeCursor();
        if (input.inline_delete_pressed) self.removeInlineAtCursor();
        if (!input.shortcut_modifier_down and input.inline_chars_len > 0)
            _ = self.insertInlineBytes(input.inline_chars[0..input.inline_chars_len]);

        if (input.toggle_focus_canvas_pressed) {
            const direction: i8 = if (input.shift_down) -1 else 1;
            if (self.inline_editor.dirty) {
                self.inline_editor.blur_after_accept = false;
                return self.queueInlineCommit(direction, null, null);
            }
            const next_field = nextInlineField(self.inline_editor.field, direction, item);
            _ = self.beginInlineEdit(
                items,
                resolved_bounds,
                next_field,
                self.inline_editor.target.edit_scope == .shared_template,
            );
            self.inline_editor.select_all = true;
            return true;
        }
        if (input.inline_submit_pressed) {
            if (self.inline_editor.field == .text and input.shift_down) {
                _ = self.insertInlineBytes("\n");
            } else if (self.inline_editor.dirty) {
                self.inline_editor.blur_after_accept = false;
                return self.queueInlineCommit(0, null, null);
            } else {
                self.inline_editor.select_all = true;
            }
            return true;
        }
        return true;
    }

    fn measureUiText(self: Studio, text: [:0]const u8, font_size: i32) f32 {
        const measured: f32 = if (self.ui_font) |font|
            rl.measureTextEx(font, text, @floatFromInt(font_size), 0).x
        else
            @floatFromInt(rl.measureText(text, font_size));
        if (measured > 0 or text.len == 0) return measured;
        // Unit tests and minimal embedders may ask for layout before raylib's
        // default font is initialized. A codepoint-based fallback keeps the
        // containment and caret logic deterministic without treating UTF-8
        // continuation bytes as separate glyphs.
        const codepoints = std.unicode.utf8CountCodepoints(text) catch text.len;
        return @as(f32, @floatFromInt(codepoints)) * @as(f32, @floatFromInt(font_size)) * 0.56;
    }

    fn drawUiText(self: Studio, text: [:0]const u8, position: rl.Vector2, font_size: i32, color: rl.Color) void {
        if (self.ui_font) |font| {
            rl.drawTextEx(font, text, position, @floatFromInt(font_size), 0, color);
        } else {
            rl.drawText(text, @intFromFloat(position.x), @intFromFloat(position.y), font_size, color);
        }
    }

    /// Copies a UTF-8 label into `buffer` and shortens it with an ellipsis
    /// until the rendered text fits the available width. The final scissor in
    /// callers remains a hard safety net for unusual font metrics.
    fn fitUiText(self: Studio, buffer: []u8, value: []const u8, font_size: i32, max_width: f32) [:0]const u8 {
        std.debug.assert(buffer.len >= 5);
        if (max_width <= 0) {
            buffer[0] = 0;
            return buffer[0..0 :0];
        }
        if (value.len < buffer.len) {
            @memcpy(buffer[0..value.len], value);
            buffer[value.len] = 0;
            const complete = buffer[0..value.len :0];
            if (self.measureUiText(complete, font_size) <= max_width) return complete;
        }

        const ellipsis = "…";
        var end = @min(value.len, buffer.len - ellipsis.len - 1);
        if (end < value.len) {
            while (end > 0 and value[end] & 0xc0 == 0x80) end -= 1;
        }
        while (true) {
            @memcpy(buffer[0..end], value[0..end]);
            @memcpy(buffer[end .. end + ellipsis.len], ellipsis);
            buffer[end + ellipsis.len] = 0;
            const candidate = buffer[0 .. end + ellipsis.len :0];
            if (self.measureUiText(candidate, font_size) <= max_width) return candidate;
            if (end == 0) {
                buffer[0] = 0;
                return buffer[0..0 :0];
            }
            end -= 1;
            while (end > 0 and value[end] & 0xc0 == 0x80) end -= 1;
        }
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
        self.marquee.active = false;
        // Library commands retain only a workspace index. Any source rewrite
        // can reorder the catalog, so a prior selection must not silently
        // resolve to a different reusable afterward.
        self.selected_library_index = null;
    }

    pub fn setNotice(self: *Studio, notice: Notice) void {
        self.notice = notice;
    }

    pub fn interactionActive(self: Studio) bool {
        return self.interaction != .idle or self.marquee.active;
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
        self.marquee.active = false;
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
        self.cancelInlineEdit();
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
        self.marquee.active = false;
    }

    pub fn toggle(self: *Studio, items: []slides.SlideItem) void {
        self.cancelInlineEdit();
        if (self.enabled and self.interaction != .idle) self.cancelInteraction(items);
        self.marquee.active = false;
        self.enabled = !self.enabled;
        if (!self.enabled) {
            self.composition_context = null;
            self.focus_canvas = false;
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
        self.cancelInlineEdit();
        if (self.interaction != .idle) self.cancelInteraction(items);
        self.marquee.active = false;
        self.composition_context = null;
        self.enabled = false;
        self.focus_canvas = false;
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
        self.cancelInlineEdit();
        if (self.interaction != .idle) self.cancelInteraction(items);
        self.marquee.active = false;
        self.composition_context = null;
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

    /// Rebinds one non-structural edit after source rewrite/reparse. A unique
    /// author ID wins when present; otherwise all known provenance layers are
    /// checked so legacy id-less direct items and customized template items
    /// retain a continuous selection across repeated property edits.
    pub fn selectItemByIdOrSource(
        self: *Studio,
        items: []const slides.SlideItem,
        id: ?[]const u8,
        source: slides.SourceRef,
    ) bool {
        var match: ?usize = null;
        if (id) |wanted_id| {
            var id_matches: usize = 0;
            for (items, 0..) |item, index| {
                const item_id = item.id orelse continue;
                if (!std.mem.eql(u8, item_id, wanted_id)) continue;
                id_matches += 1;
                match = index;
            }
            if (id_matches != 1) match = null;
        }
        if (match == null and source.scope != .none) {
            var source_matches_count: usize = 0;
            for (items, 0..) |item, index| {
                const source_matches = sourceEqual(item.source, source) or
                    (item.instance_source != null and sourceEqual(item.instance_source.?, source)) or
                    (item.state_source != null and sourceEqual(item.state_source.?, source));
                if (!source_matches) continue;
                source_matches_count += 1;
                match = index;
            }
            if (source_matches_count != 1) match = null;
        }
        const index = match orelse {
            self.clearSelectionState();
            return false;
        };
        if (items[index].kind == .background) {
            self.clearSelectionState();
            return false;
        }
        self.clearSelectionState();
        self.setSingleSelection(items[index]);
        self.notice = .none;
        return true;
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
        const scale = uiScale(viewport);
        return .{
            .x = rect.x + 4 * scale,
            .y = rect.y + 4 * scale,
            .width = 56 * scale,
            .height = 24 * scale,
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
        if (!self.enabled) {
            if (input.toggle_pressed) self.toggle(items);
            return null;
        }

        self.validateSelection(items, resolved_bounds);
        if (self.inline_editor.active and workspace.visible and self.last_workspace_slide != null and
            self.last_workspace_slide.? != workspace.current_slide)
        {
            self.cancelInlineEdit();
        }
        if (self.handleInlineEditor(items, resolved_bounds, viewport, input)) return null;
        if (input.toggle_pressed) {
            self.toggle(items);
            return null;
        }
        if (input.toggle_focus_canvas_pressed) {
            if (self.interaction != .idle) self.cancelInteraction(items);
            self.marquee.active = false;
            self.focus_canvas = !self.focus_canvas;
            self.snap_guides = .{};
            return null;
        }

        self.normalizeObjects(items, viewport);
        self.handleObjectsScroll(items, viewport, input);

        // A marquee owns the pointer until release. Keeping this path ahead
        // of shortcuts prevents an unrelated command from observing a
        // half-finished selection gesture.
        if (self.marquee.active) {
            if (input.cancel_pressed) {
                self.marquee.active = false;
                self.notice = .none;
                return null;
            }
            if (input.pointer_down or input.pointer_released) {
                if (screenToLogical(viewport, input.pointer_screen)) |pointer| {
                    self.marquee.current = clampLogicalPoint(pointer, viewport.logical_size);
                }
            }
            if (input.pointer_released) self.finishMarquee(items, resolved_bounds, viewport);
            return null;
        }

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
            if (self.inlinePropertiesVisible(viewport)) {
                _ = self.beginInlineEdit(items, resolved_bounds, .text, input.allow_shared_edit);
            } else if (viewport.chrome != null) {
                self.revealInlineProperties();
            } else {
                _ = self.emitSelectedCommand(items, input.allow_shared_edit, .edit_text);
            }
            return null;
        }
        if (input.promote_pressed) {
            _ = self.emitPromoteOrDetach(items, input.allow_shared_edit);
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
        if (input.pointer_pressed and self.handleUiClick(
            items,
            resolved_bounds,
            viewport,
            input.pointer_screen,
            input.toggle_selection,
            input.allow_shared_edit,
        )) {
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
            if (!viewport.containsScreenPoint(input.pointer_screen) or pointer_logical == null) {
                if (!input.toggle_selection) self.clearSelection(items);
                return null;
            }
            const pointer = pointer_logical.?;
            const hit_index = hitTest(items, resolved_bounds, pointer);
            if (input.toggle_selection) {
                if (hit_index != null) {
                    self.toggleSelectionAt(items, resolved_bounds, viewport, input.pointer_screen, pointer_logical);
                } else {
                    self.beginMarquee(pointer, true);
                }
                return null;
            }
            if (hit_index) |index| {
                // A selected member owns the gesture before empty-canvas
                // marquee selection is considered, preserving group moves.
                if (self.selectionCount() > 1 and self.isIdentitySelected(items[index].identity)) {
                    self.makeSelectionPrimary(items[index].identity);
                    self.beginGroupMove(items, resolved_bounds, pointer, input.allow_shared_edit);
                } else {
                    self.selectAndBeginMove(items, resolved_bounds, viewport, input.pointer_screen, pointer_logical, input.allow_shared_edit);
                }
            } else {
                self.beginMarquee(pointer, false);
            }
        }

        if (self.marquee.active) {
            if (input.pointer_released) self.finishMarquee(items, resolved_bounds, viewport);
            return null;
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

    fn emitResetOverride(
        self: *Studio,
        items: []slides.SlideItem,
        field: InlineField,
    ) bool {
        const item_index = self.selectedIndex(items) orelse return false;
        if (self.selectionCount() != 1) {
            self.notice = .multi_selection_property_unsupported;
            return true;
        }
        if (items[item_index].locked) {
            self.notice = .locked_item;
            return true;
        }
        const context = self.compositionContextForSelection(items) orelse {
            self.notice = .override_reset_unsupported;
            return true;
        };
        if (!context.local_overrides.contains(field) or
            !context.resettable_overrides.contains(field) or
            context.reset_target == null or
            context.reset_target.?.item_identity != items[item_index].identity)
        {
            self.notice = .override_reset_unsupported;
            return true;
        }
        self.notice = .none;
        self.pending_semantic_command = .{ .reset_local_override = .{
            .target = context.reset_target.?,
            .field = field,
        } };
        return true;
    }

    fn emitPromoteOrDetach(
        self: *Studio,
        items: []slides.SlideItem,
        allow_shared_edit: bool,
    ) bool {
        const item_index = self.selectedIndex(items) orelse return false;
        if (self.selectionCount() > 1) {
            if (self.active_morph_state != null) {
                self.notice = .group_reusable_needs_source_support;
                return true;
            }
            var command = ItemBatchCommand{};
            for (items, 0..) |candidate, candidate_index| {
                if (!self.isIdentitySelected(candidate.identity)) continue;
                if (candidate.locked) {
                    self.notice = .locked_item;
                    return true;
                }
                const target = self.structuralTarget(items, candidate_index, true) orelse {
                    self.notice = .group_reusable_needs_source_support;
                    return true;
                };
                if (batchHasNonLocalSource(command.slice(), target)) {
                    self.notice = .group_reusable_needs_source_support;
                    return true;
                }
                command.targets[command.count] = target;
                command.count += 1;
            }
            if (command.count != self.selectionCount()) {
                self.notice = .group_reusable_needs_source_support;
                return true;
            }
            self.notice = .none;
            self.pending_semantic_command = .{ .promote_items_to_group = command };
            return true;
        }
        const item = items[item_index];
        if (item.locked) {
            self.notice = .locked_item;
            return true;
        }
        if (self.compositionContextForSelection(items)) |context| {
            if (context.kind != .none) {
                if (self.active_morph_state != null or context.detach_target == null or
                    context.detach_target.?.item_identity != item.identity)
                {
                    self.notice = .detach_instance_unsupported;
                    return true;
                }
                self.notice = .none;
                self.pending_semantic_command = .{ .detach_reusable_instance = .{
                    .target = context.detach_target.?,
                    .kind = context.kind,
                } };
                return true;
            }
        } else if (item.source.scope == .component_instance or item.source.scope == .group_instance_member or
            item.source.scope == .slide_template)
        {
            self.notice = .detach_instance_unsupported;
            return true;
        }
        return self.emitSelectedCommand(items, allow_shared_edit, .promote_to_reusable);
    }

    fn emitDuplicateItem(self: *Studio, items: []slides.SlideItem, allow_shared_edit: bool) bool {
        if (self.selectionCount() == 0) return false;
        if (self.interaction != .idle) self.cancelInteraction(items);
        if (self.selectionCount() > 1) return self.emitDuplicateItems(items, allow_shared_edit);
        const index = self.selectedIndex(items) orelse return false;
        const target = self.duplicateTarget(items, index, allow_shared_edit, true) orelse return true;
        self.pending_semantic_command = .{ .duplicate_item = target };
        return true;
    }

    fn duplicateTarget(
        self: *Studio,
        items: []const slides.SlideItem,
        index: usize,
        allow_shared_edit: bool,
        allow_shared_definition: bool,
    ) ?CommandTarget {
        if (items[index].locked) {
            self.notice = .locked_item;
            return null;
        }
        const item = items[index];

        const edit_scope: EditScope = if (self.active_morph_state) |state_index| blk: {
            if (item.creation_morph_state == null or item.creation_morph_state.? != state_index or item.state_source != null) {
                self.notice = .duplicate_item_unsupported;
                return null;
            }
            break :blk self.editScopeForItem(items, index, false) orelse return null;
        } else switch (item.source.scope) {
            .direct, .component_instance => self.editScopeForItem(items, index, false) orelse return null,
            .slide_template => blk: {
                if (!allow_shared_definition or !allow_shared_edit) {
                    self.notice = .duplicate_item_unsupported;
                    return null;
                }
                const scope = self.editScopeForItem(items, index, true) orelse return null;
                if (scope != .shared_template) {
                    self.notice = .duplicate_item_unsupported;
                    return null;
                }
                break :blk scope;
            },
            else => {
                self.notice = .duplicate_item_unsupported;
                return null;
            },
        };

        return .{
            .item_identity = item.identity,
            .source = self.commandSource(item, edit_scope),
            .edit_scope = edit_scope,
        };
    }

    fn emitDuplicateItems(self: *Studio, items: []const slides.SlideItem, allow_shared_edit: bool) bool {
        var command = ItemBatchCommand{};
        for (items, 0..) |item, item_index| {
            if (!self.isIdentitySelected(item.identity)) continue;
            const target = self.duplicateTarget(items, item_index, allow_shared_edit, false) orelse {
                if (self.notice == .duplicate_item_unsupported) self.notice = .multi_duplicate_unsupported;
                return true;
            };
            if (batchHasNonLocalSource(command.slice(), target)) {
                self.notice = .multi_duplicate_unsupported;
                return true;
            }
            command.targets[command.count] = target;
            command.count += 1;
        }
        if (command.count != self.selectionCount()) {
            self.notice = .multi_duplicate_unsupported;
            return true;
        }
        self.notice = .none;
        self.pending_semantic_command = .{ .duplicate_items = command };
        return true;
    }

    fn emitDeleteItems(self: *Studio, items: []const slides.SlideItem, allow_shared_edit: bool) bool {
        var command = ItemBatchCommand{};
        for (items, 0..) |item, item_index| {
            if (!self.isIdentitySelected(item.identity)) continue;
            if (item.locked) {
                self.notice = .locked_item;
                return true;
            }
            const edit_scope = self.editScopeForItem(items, item_index, allow_shared_edit) orelse return true;
            // Dependency-aware shared-definition deletion remains a deliberate
            // single-target action in v1. Local instance and morph hides may
            // safely coexist with physically authored removals in one plan.
            if (edit_scope == .shared_template) {
                self.notice = .multi_delete_unsupported;
                return true;
            }
            const needs_identified_hide = if (self.active_morph_state) |state_index|
                item.creation_morph_state == null or item.creation_morph_state.? != state_index
            else
                edit_scope == .local_instance;
            if (needs_identified_hide and !itemIdIsUnique(items, item_index)) {
                self.notice = .local_override_needs_unique_id;
                return true;
            }
            const target_source = if (self.active_morph_state) |state_index|
                if (item.creation_morph_state != null and item.creation_morph_state.? == state_index)
                    item.source
                else
                    self.commandSource(item, edit_scope)
            else
                self.commandSource(item, edit_scope);
            const target: CommandTarget = .{
                .item_identity = item.identity,
                .source = target_source,
                .edit_scope = edit_scope,
            };
            if (batchHasNonLocalSource(command.slice(), target)) {
                self.notice = .multi_delete_unsupported;
                return true;
            }
            command.targets[command.count] = target;
            command.count += 1;
        }
        if (command.count != self.selectionCount()) {
            self.notice = .multi_delete_unsupported;
            return true;
        }
        self.notice = .none;
        self.pending_semantic_command = .{ .delete_items = command };
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
            if (kind == .delete_item) return self.emitDeleteItems(items, allow_shared_edit);
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
        const edit_scope = self.editScopeForItem(items, index, allow_shared_edit) orelse return true;
        self.pending_semantic_command = .{
            .clear_background = self.selectedTarget(items, edit_scope) orelse return true,
        };
        return true;
    }

    const PropertyRequestKind = union(enum) {
        numeric_geometry: GeometryField,
        custom_foreground,
        custom_background,
        font_size,
        opacity,
    };

    fn emitPropertyRequest(
        self: *Studio,
        items: []slides.SlideItem,
        allow_shared_edit: bool,
        request: PropertyRequestKind,
    ) bool {
        const index = self.selectedIndex(items) orelse return false;
        if (self.interaction != .idle) self.cancelInteraction(items);
        if (self.selectionCount() > 1) {
            self.notice = .multi_selection_property_unsupported;
            return true;
        }
        const item = items[index];
        if (item.locked) {
            self.notice = .locked_item;
            return true;
        }
        const applies = switch (request) {
            .numeric_geometry, .custom_background, .opacity => item.kind != .background,
            .custom_foreground, .font_size => item.kind == .textbox,
        };
        if (!applies) {
            self.notice = .property_unavailable;
            return true;
        }
        const edit_scope = self.editScopeForItem(items, index, allow_shared_edit) orelse return true;
        const target = self.selectedTarget(items, edit_scope) orelse return true;
        self.pending_semantic_command = switch (request) {
            .numeric_geometry => |field| .{ .edit_numeric_geometry = .{ .target = target, .field = field } },
            .custom_foreground => .{ .set_custom_foreground = target },
            .custom_background => .{ .set_custom_background = target },
            .font_size => .{ .set_font_size = target },
            .opacity => .{ .set_opacity = target },
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
        if (copy_only) {
            if (self.active_morph_state != null or
                (item.source.scope != .direct and item.source.scope != .component_instance)) return null;
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
            if (batchHasNonLocalSource(command.slice(), target)) {
                self.notice = .layer_selection_unsupported;
                return true;
            }
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
            if (batchHasNonLocalSource(command.slice(), target)) {
                self.notice = .copy_selection_unsupported;
                return true;
            }
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
        var command = SetLockedCommand{ .locked = false };
        for (items, 0..) |item, item_index| {
            if (!self.isIdentitySelected(item.identity)) continue;
            const edit_scope = self.editScopeForItem(items, item_index, allow_shared_edit) orelse return true;
            if (!lockedValueForScope(item, edit_scope)) all_locked = false;
            command.targets[command.count] = .{
                .item_identity = item.identity,
                .source = self.commandSource(item, edit_scope),
                .edit_scope = edit_scope,
            };
            command.count += 1;
        }
        if (command.count != self.selectionCount()) return true;
        command.locked = !all_locked;
        self.pending_semantic_command = .{ .set_locked = command };
        return true;
    }

    fn emitSelectedVisibilityCommand(
        self: *Studio,
        items: []slides.SlideItem,
        allow_shared_edit: bool,
    ) bool {
        if (self.selectionCount() == 0) return false;
        if (self.interaction != .idle) self.cancelInteraction(items);
        var all_hidden = true;
        var command = SetVisibleCommand{ .visible = false };
        for (items, 0..) |item, item_index| {
            if (!self.isIdentitySelected(item.identity)) continue;
            if (item.kind == .background) {
                self.notice = .property_unavailable;
                return true;
            }
            if (item.locked) {
                self.notice = .locked_item;
                return true;
            }
            const edit_scope = self.editScopeForItem(items, item_index, allow_shared_edit) orelse return true;
            if (visibleValueForScope(item, edit_scope)) all_hidden = false;
            command.targets[command.count] = .{
                .item_identity = item.identity,
                .source = self.commandSource(item, edit_scope),
                .edit_scope = edit_scope,
            };
            command.count += 1;
        }
        if (command.count != self.selectionCount()) return true;
        command.visible = all_hidden;
        self.notice = .none;
        self.pending_semantic_command = .{ .set_visible = command };
        return true;
    }

    fn visibleValueForScope(item: slides.SlideItem, edit_scope: EditScope) bool {
        if (edit_scope == .shared_template) {
            if (item.sharedTemplateValues()) |shared| return shared.visible;
        }
        return item.visible;
    }

    fn lockedValueForScope(item: slides.SlideItem, edit_scope: EditScope) bool {
        if (edit_scope == .shared_template) {
            if (item.sharedTemplateValues()) |shared| return shared.locked;
        }
        return item.locked;
    }

    /// Row affordances always affect exactly their row. Batch visibility and
    /// lock remain available through selection-level keyboard/properties
    /// commands, but a small eye/lock icon must never surprise-hide siblings.
    fn emitItemVisibilityCommand(
        self: *Studio,
        items: []slides.SlideItem,
        item_index: usize,
        allow_shared_edit: bool,
    ) bool {
        if (item_index >= items.len or items[item_index].kind == .background) {
            self.notice = .property_unavailable;
            return true;
        }
        const item = items[item_index];
        if (item.locked) {
            self.notice = .locked_item;
            return true;
        }
        const edit_scope = self.editScopeForItem(items, item_index, allow_shared_edit) orelse return true;
        var command = SetVisibleCommand{ .visible = !visibleValueForScope(item, edit_scope) };
        command.targets[0] = .{
            .item_identity = item.identity,
            .source = self.commandSource(item, edit_scope),
            .edit_scope = edit_scope,
        };
        command.count = 1;
        self.notice = .none;
        self.pending_semantic_command = .{ .set_visible = command };
        return true;
    }

    fn emitItemLockCommand(
        self: *Studio,
        items: []slides.SlideItem,
        item_index: usize,
        allow_shared_edit: bool,
    ) bool {
        if (item_index >= items.len or items[item_index].kind == .background) {
            self.notice = .property_unavailable;
            return true;
        }
        const item = items[item_index];
        const edit_scope = self.editScopeForItem(items, item_index, allow_shared_edit) orelse return true;
        var command = SetLockedCommand{ .locked = !lockedValueForScope(item, edit_scope) };
        command.targets[0] = .{
            .item_identity = item.identity,
            .source = self.commandSource(item, edit_scope),
            .edit_scope = edit_scope,
        };
        command.count = 1;
        self.notice = .none;
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

    fn normalizeObjects(self: *Studio, items: []const slides.SlideItem, viewport: Viewport) void {
        const layout = objectsLayout(viewport);
        const capacity = objectRowCapacity(layout);
        self.objects_first_visible = clampFirstVisible(
            self.objects_first_visible,
            objectItemCount(items),
            capacity,
        );
        const primary = self.selected_identity;
        if (primary == self.last_objects_primary) return;
        self.last_objects_primary = primary;
        if (primary) |identity| {
            if (objectPaintOffsetByIdentity(items, identity)) |offset| {
                self.objects_first_visible = revealIndex(
                    self.objects_first_visible,
                    offset,
                    objectItemCount(items),
                    capacity,
                );
            }
        }
    }

    fn toggleObjectSelection(self: *Studio, item: slides.SlideItem) void {
        if (item.kind == .background) {
            self.notice = .property_unavailable;
            return;
        }
        self.composition_context = null;
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
                self.last_objects_primary = null;
                self.snap_guides = .{};
            }
            return;
        }
        for (self.additional_selection[0..self.additional_selection_count], 0..) |member, member_index| {
            if (member.identity != item.identity) continue;
            self.removeAdditionalSelection(member_index);
            self.last_objects_primary = null;
            self.snap_guides = .{};
            return;
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
        self.last_objects_primary = null;
        self.snap_guides = .{};
        self.notice = .none;
    }

    fn handleObjectsScroll(self: *Studio, items: []const slides.SlideItem, viewport: Viewport, input: FrameInput) void {
        if (input.workspace_scroll == 0 or self.inspector_panel != .objects) return;
        const layout = objectsLayout(viewport);
        if (!pointInRectangle(input.pointer_screen, layout.panel)) return;
        self.objects_first_visible = scrollFirstVisible(
            self.objects_first_visible,
            objectItemCount(items),
            objectRowCapacity(layout),
            if (input.workspace_scroll > 0) -1 else 1,
        );
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
                .group => {
                    self.tool = .select;
                    self.active_morph_state = null;
                    self.pending_semantic_command = .{ .add_reusable_group = entry_index };
                },
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
        toggle_selection: bool,
        allow_shared_edit: bool,
    ) bool {
        const layout = uiLayout(viewport);
        const inspector = objectsLayout(viewport);
        const in_status = pointInRectangle(pointer, statusPanel(viewport));
        const in_toolbar = pointInRectangle(pointer, layout.toolbar);
        const in_inspector = pointInRectangle(pointer, inspector.panel);
        const legacy_properties = viewport.chrome == null and self.selected_identity != null and
            pointInRectangle(pointer, layout.properties);
        if (!in_status and !in_toolbar and !in_inspector and !legacy_properties) return false;
        if (self.interaction != .idle) self.cancelInteraction(items);
        if (in_status) return true;
        if (in_toolbar) {
            if (pointInRectangle(pointer, layout.slides_dock_toggle)) {
                self.active_dock = if (self.active_dock == .slides) .none else .slides;
                return true;
            }
            if (pointInRectangle(pointer, layout.properties_dock_toggle)) {
                const inspector_open = self.active_dock == .objects or self.active_dock == .properties;
                self.active_dock = if (inspector_open)
                    .none
                else if (self.inspector_panel == .objects)
                    .objects
                else
                    .properties;
                return true;
            }
            if (pointInRectangle(pointer, layout.focus_canvas)) {
                self.focus_canvas = true;
                return true;
            }
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
        if (in_inspector) {
            if (pointInRectangle(pointer, inspector.objects_tab)) {
                self.inspector_panel = .objects;
                self.active_dock = .objects;
                return true;
            }
            if (pointInRectangle(pointer, inspector.properties_tab)) {
                self.inspector_panel = .properties;
                self.active_dock = .properties;
                return true;
            }
            if (self.inspector_panel == .objects) {
                for (inspector.layer_actions, 0..) |button, index| {
                    if (pointInRectangle(pointer, button))
                        return self.emitLayerCommand(items, @enumFromInt(index));
                }
                if (pointInRectangle(pointer, inspector.page_previous)) {
                    self.objects_first_visible = pageFirstVisible(
                        self.objects_first_visible,
                        objectItemCount(items),
                        objectRowCapacity(inspector),
                        false,
                    );
                    return true;
                }
                if (pointInRectangle(pointer, inspector.page_next)) {
                    self.objects_first_visible = pageFirstVisible(
                        self.objects_first_visible,
                        objectItemCount(items),
                        objectRowCapacity(inspector),
                        true,
                    );
                    return true;
                }
                for (0..objectRowCapacity(inspector)) |visible_slot| {
                    const row = objectRowRect(inspector, visible_slot) orelse continue;
                    if (!pointInRectangle(pointer, row)) continue;
                    const paint_offset = self.objects_first_visible + visible_slot;
                    const item_index = objectIndexAtPaintOffset(items, paint_offset) orelse return true;
                    const item = items[item_index];
                    if (pointInRectangle(pointer, objectVisibilityRect(row)))
                        return self.emitItemVisibilityCommand(items, item_index, allow_shared_edit);
                    if (pointInRectangle(pointer, objectLockRect(row)))
                        return self.emitItemLockCommand(items, item_index, allow_shared_edit);
                    if (item.kind == .background) {
                        self.notice = .property_unavailable;
                        return true;
                    }
                    if (toggle_selection) {
                        self.toggleObjectSelection(item);
                    } else {
                        self.setSingleSelection(item);
                        self.notice = if (item.locked) .locked_item else .none;
                    }
                    self.tool = .select;
                    return true;
                }
                return true;
            }
            if (self.selected_identity == null) return true;
        }
        const inline_properties = viewport.chrome != null;
        if (inline_properties) {
            if (self.inlineOverrideFieldAtPoint(items, layout, pointer)) |field|
                return self.emitResetOverride(items, field);
        }
        if (pointInRectangle(pointer, layout.edit_text))
            return if (inline_properties)
                self.beginInlineEdit(items, resolved_bounds, .text, allow_shared_edit)
            else
                self.emitSelectedCommand(items, allow_shared_edit, .edit_text);
        if (pointInRectangle(pointer, layout.duplicate_item))
            return self.emitDuplicateItem(items, allow_shared_edit);
        if (pointInRectangle(pointer, layout.delete_item))
            return self.emitSelectedCommand(items, allow_shared_edit, .delete_item);
        if (pointInRectangle(pointer, layout.promote))
            return self.emitPromoteOrDetach(items, allow_shared_edit);
        for (layout.geometry_fields, 0..) |button, index| {
            if (pointInRectangle(pointer, button))
                return if (inline_properties)
                    self.beginInlineEdit(items, resolved_bounds, @enumFromInt(index + 1), allow_shared_edit)
                else
                    self.emitPropertyRequest(items, allow_shared_edit, .{ .numeric_geometry = @enumFromInt(index) });
        }
        if (pointInRectangle(pointer, layout.custom_foreground))
            return if (inline_properties)
                self.beginInlineEdit(items, resolved_bounds, .foreground, allow_shared_edit)
            else
                self.emitPropertyRequest(items, allow_shared_edit, .custom_foreground);
        for (layout.foreground_swatches, 0..) |swatch, index| {
            if (pointInRectangle(pointer, swatch))
                return self.emitColorCommand(items, allow_shared_edit, palette[index], false);
        }
        if (pointInRectangle(pointer, layout.custom_background))
            return if (inline_properties)
                self.beginInlineEdit(items, resolved_bounds, .background, allow_shared_edit)
            else
                self.emitPropertyRequest(items, allow_shared_edit, .custom_background);
        for (layout.background_swatches, 0..) |swatch, index| {
            if (pointInRectangle(pointer, swatch))
                return self.emitColorCommand(items, allow_shared_edit, palette[index], true);
        }
        if (pointInRectangle(pointer, layout.clear_background))
            return self.emitClearBackgroundCommand(items, allow_shared_edit);
        if (pointInRectangle(pointer, layout.font_size))
            return if (inline_properties)
                self.beginInlineEdit(items, resolved_bounds, .font_size, allow_shared_edit)
            else
                self.emitPropertyRequest(items, allow_shared_edit, .font_size);
        if (pointInRectangle(pointer, layout.opacity))
            return if (inline_properties)
                self.beginInlineEdit(items, resolved_bounds, .opacity, allow_shared_edit)
            else
                self.emitPropertyRequest(items, allow_shared_edit, .opacity);
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
        self.composition_context = null;
        self.selected_identity = item.identity;
        self.selected_source = sourceForSelection(item);
        self.additional_selection_count = 0;
        self.group_drag_count = 0;
        self.snap_guides = .{};
        self.last_objects_primary = null;
    }

    fn clearSelectionState(self: *Studio) void {
        self.composition_context = null;
        self.interaction = .idle;
        self.marquee.active = false;
        self.selected_identity = null;
        self.selected_source = null;
        self.additional_selection_count = 0;
        self.group_drag_count = 0;
        self.snap_guides = .{};
        self.last_objects_primary = null;
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
            self.composition_context = null;
            self.last_objects_primary = null;
            return;
        }
    }

    fn beginMarquee(self: *Studio, pointer: rl.Vector2, extend: bool) void {
        self.marquee = .{
            .active = true,
            .start = pointer,
            .current = pointer,
            .extend = extend,
        };
        const count = self.selectionCount();
        for (0..count) |selection_index| {
            self.marquee.snapshot[selection_index] = .{
                .identity = self.selectedIdentityAt(selection_index).?,
                .source = if (selection_index == 0)
                    self.selected_source
                else
                    self.additional_selection[selection_index - 1].source,
            };
        }
        self.marquee.snapshot_count = count;
        self.snap_guides = .{};
    }

    fn finishMarquee(
        self: *Studio,
        items: []const slides.SlideItem,
        resolved_bounds: []const ResolvedBounds,
        viewport: Viewport,
    ) void {
        const marquee = self.marquee;
        self.marquee.active = false;
        if (!marqueeExceededDragThreshold(marquee, viewport)) {
            if (!marquee.extend) self.clearSelectionState();
            return;
        }

        var result: [max_selection_items]SelectionMember = undefined;
        var result_count: usize = 0;
        if (!marquee.extend) {
            var hit_count: usize = 0;
            for (items) |item| {
                if (!self.marqueeIntersectsItem(marquee, item, resolved_bounds, viewport.logical_size)) continue;
                hit_count += 1;
                if (hit_count > max_selection_items) {
                    self.notice = .selection_capacity_reached;
                    return;
                }
                result[result_count] = .{ .identity = item.identity, .source = sourceForSelection(item) };
                result_count += 1;
            }
        } else {
            var removed_count: usize = 0;
            var added_count: usize = 0;
            for (items) |item| {
                if (!self.marqueeIntersectsItem(marquee, item, resolved_bounds, viewport.logical_size)) continue;
                if (memberSliceContains(marquee.snapshot[0..marquee.snapshot_count], item.identity))
                    removed_count += 1
                else
                    added_count += 1;
            }
            const retained_count = marquee.snapshot_count - removed_count;
            if (retained_count + added_count > max_selection_items) {
                self.notice = .selection_capacity_reached;
                return;
            }
            for (marquee.snapshot[0..marquee.snapshot_count]) |member| {
                const item_index = itemIndexByIdentity(items, member.identity);
                const toggled_off = if (item_index) |index|
                    self.marqueeIntersectsItem(marquee, items[index], resolved_bounds, viewport.logical_size)
                else
                    false;
                if (toggled_off) continue;
                result[result_count] = member;
                result_count += 1;
            }
            for (items) |item| {
                if (!self.marqueeIntersectsItem(marquee, item, resolved_bounds, viewport.logical_size) or
                    memberSliceContains(marquee.snapshot[0..marquee.snapshot_count], item.identity)) continue;
                result[result_count] = .{ .identity = item.identity, .source = sourceForSelection(item) };
                result_count += 1;
            }
        }

        if (result_count == 0) {
            self.clearSelectionState();
            self.notice = .none;
            return;
        }

        // Keep the gesture-start primary when Shift leaves it selected.
        // Otherwise make the topmost surviving paint-order item primary.
        var primary_index: ?usize = null;
        if (marquee.extend and marquee.snapshot_count > 0) {
            primary_index = memberSliceIndex(result[0..result_count], marquee.snapshot[0].identity);
        }
        if (primary_index == null) {
            var item_index = items.len;
            while (item_index > 0) {
                item_index -= 1;
                if (memberSliceIndex(result[0..result_count], items[item_index].identity)) |index| {
                    primary_index = index;
                    break;
                }
            }
        }
        if (primary_index) |index| {
            const primary = result[index];
            result[index] = result[0];
            result[0] = primary;
        }
        self.applySelectionMembers(result[0..result_count]);
        self.notice = .none;
    }

    fn marqueeIntersectsItem(
        self: Studio,
        marquee: Marquee,
        item: slides.SlideItem,
        resolved_bounds: []const ResolvedBounds,
        logical_size: rl.Vector2,
    ) bool {
        _ = self;
        if (!isSelectable(item, resolved_bounds)) return false;
        const clipped_item = clipGeometryToSlide(itemGeometry(item, resolved_bounds), logical_size) orelse return false;
        return geometriesOverlap(marqueeGeometry(marquee), clipped_item);
    }

    fn applySelectionMembers(self: *Studio, members: []const SelectionMember) void {
        self.composition_context = null;
        self.selected_identity = members[0].identity;
        self.selected_source = members[0].source;
        self.additional_selection_count = members.len - 1;
        for (members[1..], 0..) |member, index| self.additional_selection[index] = member;
        self.group_drag_count = 0;
        self.snap_guides = .{};
        self.last_objects_primary = null;
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
                self.last_objects_primary = null;
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
        self.last_objects_primary = null;
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
            // The Objects dock is the recovery path for hidden, zero-opacity,
            // and locked objects. Retain those selections, while still
            // cancelling a canvas gesture that has become non-interactive.
            if (items[selected_index].kind == .background) {
                self.clearSelectionState();
                return;
            }
            if (self.interaction != .idle and !isSelectable(items[selected_index], resolved_bounds))
                self.cancelInteraction(items);

            var retained: usize = 0;
            var member_index: usize = 0;
            while (member_index < self.additional_selection_count) : (member_index += 1) {
                const member = self.additional_selection[member_index];
                const rebound_index = if (member.source) |source|
                    itemIndexByUniqueSource(items, source) orelse itemIndexByIdentity(items, member.identity)
                else
                    itemIndexByIdentity(items, member.identity);
                const valid_index = rebound_index orelse continue;
                if (items[valid_index].kind == .background) continue;
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

        if (self.marquee.active) {
            if (geometryToScreenRect(viewport, marqueeGeometry(self.marquee))) |rect| {
                rl.drawRectangleRec(rect, .{ .r = 80, .g = 215, .b = 255, .a = 38 });
                rl.drawRectangleLinesEx(rect, 2, .{ .r = 80, .g = 215, .b = 255, .a = 230 });
            }
        }

        for (items) |item| {
            if (!item.locked or !isConcreteVisibleItem(item, resolved_bounds)) continue;
            const badge = lockBadgeRect(viewport, itemGeometry(item, resolved_bounds)) orelse continue;
            rl.drawRectangleRec(badge, .{ .r = 111, .g = 42, .b = 57, .a = 240 });
            rl.drawRectangleLinesEx(badge, 1, .{ .r = 255, .g = 112, .b = 132, .a = 255 });
            const badge_font = scaledUiFont(uiScale(viewport), UiTypography.compact);
            self.drawUiText(
                "LOCK",
                .{ .x = badge.x + 8 * uiScale(viewport), .y = badge.y + (badge.height - @as(f32, @floatFromInt(badge_font))) / 2 },
                badge_font,
                .white,
            );
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
                    self.drawUiText(
                        "SHARED SOURCE",
                        .{ .x = source_rect.x + 5, .y = source_rect.y + 5 },
                        scaledUiFont(uiScale(viewport), UiTypography.compact),
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

        const chrome_visible = if (viewport.chrome) |chrome| chrome.visible else true;
        if (chrome_visible) {
            self.drawToolbar(viewport);
            if (viewport.chrome != null and viewport.chrome.?.right_visible) {
                if (self.inspector_panel == .objects) {
                    self.drawObjects(items, viewport);
                } else {
                    const selected_locked = if (self.selectedIndex(items)) |index| items[index].locked else false;
                    self.drawProperties(items, resolved_bounds, viewport, selected_locked);
                }
            } else if (viewport.chrome == null and self.selected_identity != null) {
                const selected_locked = if (self.selectedIndex(items)) |index| items[index].locked else false;
                self.drawProperties(items, resolved_bounds, viewport, selected_locked);
            }
            self.drawStatus(items, resolved_bounds, viewport);
        }
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

    fn drawGeometryHud(self: Studio, viewport: Viewport, item_rect: rl.Rectangle, geometry: Geometry) void {
        var buffer: [128]u8 = undefined;
        const text = std.fmt.bufPrintZ(
            &buffer,
            "x {d:.1}  y {d:.1}  w {d:.1}  h {d:.1}",
            .{ geometry.position.x, geometry.position.y, geometry.size.x, geometry.size.y },
        ) catch return;
        const scale = uiScale(viewport);
        const font_size = scaledUiFont(scale, UiTypography.body);
        const padding: f32 = 8 * scale;
        const width = self.measureUiText(text, font_size);
        const hud_width = width + padding * 2;
        const hud_height: f32 = 32 * scale;
        const rect = geometryHudRectangle(viewport, item_rect, hud_width, hud_height);
        rl.drawRectangleRec(rect, .{ .r = 12, .g = 16, .b = 28, .a = 238 });
        rl.drawRectangleLinesEx(rect, 1, .{ .r = 255, .g = 92, .b = 198, .a = 220 });
        self.drawUiText(
            text,
            .{ .x = rect.x + padding, .y = rect.y + (rect.height - @as(f32, @floatFromInt(font_size))) / 2 },
            font_size,
            .white,
        );
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
        // Sidebar rows have fixed logical heights, so they scale more
        // conservatively than the canvas controls while still remaining
        // readable from a distance on large external displays.
        const font_scale = @min(uiScale(viewport), @as(f32, 1.4));
        const heading_font = scaledUiFont(font_scale, UiTypography.heading);
        const body_font = scaledUiFont(font_scale, UiTypography.body);
        const compact_font = scaledUiFont(font_scale, UiTypography.compact);
        self.drawUiText("SLIDES", .{ .x = layout.organizer.x + 12, .y = layout.organizer.y + 9 }, heading_font, .white);
        const action_labels = [_][:0]const u8{ "+", "Dup", "Del", "Up", "Down", "Tpl" };
        for (layout.organizer_actions, action_labels) |button, label| drawCompactButton(self, button, label);
        drawCompactButton(self, layout.slide_page_previous, "Prev");
        drawCompactButton(self, layout.slide_page_next, "Next");

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
            const text_width = @max(0, card.x + card.width - text_x - 7);
            if (text_width <= 0) continue;
            rl.beginScissorMode(
                @intFromFloat(@floor(text_x)),
                @intFromFloat(@floor(card.y + 2)),
                @intFromFloat(@ceil(text_width)),
                @intFromFloat(@ceil(card.height - 4)),
            );
            var line_buffer: [96]u8 = undefined;
            const slide_number = std.fmt.bufPrintZ(&line_buffer, "SLIDE {d}", .{summary.index + 1}) catch "SLIDE";
            self.drawUiText(slide_number, .{ .x = text_x, .y = card.y + 7 }, compact_font, if (active) border else .white);
            var title_buffer: [96]u8 = undefined;
            const title = self.fitUiText(&title_buffer, if (summary.title.len == 0) "Untitled" else summary.title, body_font, text_width);
            self.drawUiText(title, .{ .x = text_x, .y = card.y + 28 }, body_font, .white);
            var metadata_buffer: [96]u8 = undefined;
            const metadata = std.fmt.bufPrintZ(
                &metadata_buffer,
                "{d} items · {d} states",
                .{ summary.item_count, summary.morph_count },
            ) catch "slide details";
            var fitted_metadata_buffer: [96]u8 = undefined;
            const fitted_metadata = self.fitUiText(&fitted_metadata_buffer, metadata, compact_font, text_width);
            self.drawUiText(fitted_metadata, .{ .x = text_x, .y = card.y + 57 }, compact_font, .{ .r = 185, .g = 196, .b = 215, .a = 255 });
            rl.endScissorMode();
        }

        self.drawUiText("LIBRARY", .{ .x = layout.library.x + 12, .y = layout.library.y + 9 }, heading_font, .white);
        drawCompactButton(self, layout.library_use, "Use");
        drawCompactButton(self, layout.library_rename, "Ren");
        drawCompactButton(self, layout.library_delete, "Del");
        drawCompactButton(self, layout.library_page_previous, "Prev");
        drawCompactButton(self, layout.library_page_next, "Next");
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
            const badge: [:0]const u8 = switch (entry.kind) {
                .element => "ITEM",
                .group => "GROUP",
                .slide_template => "SLIDE",
            };
            const badge_rect: rl.Rectangle = .{ .x = row.x + 7, .y = row.y + 9, .width = 48, .height = 28 };
            rl.drawRectangleRec(badge_rect, switch (entry.kind) {
                .element => .{ .r = 43, .g = 123, .b = 151, .a = if (entry.available) 255 else 100 },
                .group => .{ .r = 170, .g = 91, .b = 126, .a = if (entry.available) 255 else 100 },
                .slide_template => .{ .r = 116, .g = 83, .b = 160, .a = if (entry.available) 255 else 100 },
            });
            const badge_width = self.measureUiText(badge, compact_font);
            self.drawUiText(badge, .{
                .x = badge_rect.x + (badge_rect.width - badge_width) / 2,
                .y = badge_rect.y + (badge_rect.height - @as(f32, @floatFromInt(compact_font))) / 2,
            }, compact_font, .white);
            const text_x = row.x + 64;
            const text_width = @max(0, row.x + row.width - text_x - 7);
            if (text_width <= 0) continue;
            rl.beginScissorMode(
                @intFromFloat(@floor(text_x)),
                @intFromFloat(@floor(row.y + 2)),
                @intFromFloat(@ceil(text_width)),
                @intFromFloat(@ceil(row.height - 4)),
            );
            var name_buffer: [128]u8 = undefined;
            const name = self.fitUiText(&name_buffer, entry.name, body_font, text_width);
            self.drawUiText(name, .{ .x = text_x, .y = row.y + 6 }, body_font, if (entry.available)
                .white
            else
                .{ .r = 130, .g = 136, .b = 149, .a = 255 });
            var usage_buffer: [48]u8 = undefined;
            const usage: [:0]const u8 = if (entry.use_count == 0)
                "unused"
            else
                std.fmt.bufPrintZ(&usage_buffer, "{d} use{s}", .{ entry.use_count, if (entry.use_count == 1) "" else "s" }) catch "used";
            self.drawUiText(usage, .{ .x = text_x, .y = row.y + 27 }, compact_font, if (entry.deletable)
                .{ .r = 126, .g = 231, .b = 177, .a = 255 }
            else
                .{ .r = 168, .g = 179, .b = 198, .a = 255 });
            rl.endScissorMode();
        }
    }

    fn drawInspectorTabs(self: Studio, viewport: Viewport) void {
        const layout = objectsLayout(viewport);
        drawToggleButton(self, layout.objects_tab, "Objects", self.inspector_panel == .objects);
        drawToggleButton(self, layout.properties_tab, "Properties", self.inspector_panel == .properties);
    }

    fn drawObjects(self: Studio, items: []const slides.SlideItem, viewport: Viewport) void {
        const layout = objectsLayout(viewport);
        if (layout.panel.width <= 0 or layout.panel.height <= 0) return;
        drawStudioPanel(layout.panel);
        self.drawInspectorTabs(viewport);
        const layer_labels = [_][:0]const u8{ "Back", "Down", "Up", "Front" };
        for (layout.layer_actions, layer_labels) |button, label| drawCompactButton(self, button, label);
        drawCompactButton(self, layout.page_previous, "Prev");
        drawCompactButton(self, layout.page_next, "Next");

        const scale = @min(uiScale(viewport), @as(f32, 1.4));
        const body_font = scaledUiFont(scale, UiTypography.body);
        const compact_font = scaledUiFont(scale, UiTypography.compact);
        const count = objectItemCount(items);
        for (0..objectRowCapacity(layout)) |visible_slot| {
            const paint_offset = self.objects_first_visible + visible_slot;
            const item_index = objectIndexAtPaintOffset(items, paint_offset) orelse break;
            const item = items[item_index];
            const row = objectRowRect(layout, visible_slot) orelse break;
            const selected = item.kind != .background and self.isIdentitySelected(item.identity);
            const row_color: rl.Color = if (selected)
                .{ .r = 35, .g = 77, .b = 94, .a = 255 }
            else if (item.kind == .background)
                .{ .r = 30, .g = 29, .b = 41, .a = 248 }
            else if (!item.visible or item.opacity <= 0)
                .{ .r = 23, .g = 27, .b = 36, .a = 245 }
            else
                .{ .r = 27, .g = 34, .b = 49, .a = 250 };
            rl.drawRectangleRec(row, row_color);
            rl.drawRectangleLinesEx(row, if (selected) 2 else 1, if (selected)
                .{ .r = 80, .g = 215, .b = 255, .a = 255 }
            else if (item.kind == .background)
                .{ .r = 153, .g = 116, .b = 177, .a = 210 }
            else
                .{ .r = 87, .g = 101, .b = 125, .a = 205 });

            const visibility = objectVisibilityRect(row);
            const lock = objectLockRect(row);
            if (item.kind == .background) {
                drawDisabledBadge(self, visibility, "BG");
                drawDisabledBadge(self, lock, "--");
            } else {
                drawToggleButton(self, visibility, if (item.visible) "Vis" else "Hid", item.visible);
                drawToggleButton(self, lock, if (item.locked) "L" else "U", item.locked);
            }

            const text_x = visibility.x + visibility.width + 7;
            const text_right = lock.x - 7;
            const text_width = @max(0, text_right - text_x);
            if (text_width <= 0) continue;
            rl.beginScissorMode(
                @intFromFloat(@floor(text_x)),
                @intFromFloat(@floor(row.y + 2)),
                @intFromFloat(@ceil(text_width)),
                @intFromFloat(@ceil(row.height - 4)),
            );
            var generated_name: [192]u8 = undefined;
            const raw_name: []const u8 = if (item.id) |id|
                std.fmt.bufPrint(&generated_name, "#{s}", .{id}) catch id
            else switch (item.kind) {
                .textbox => if (item.text) |value|
                    firstNonEmptyTextLine(value) orelse
                        (std.fmt.bufPrint(&generated_name, "Text · line {d}", .{item.source.line_number}) catch "Text")
                else
                    std.fmt.bufPrint(&generated_name, "Text · line {d}", .{item.source.line_number}) catch "Text",
                .img => if (item.img_path) |path| std.fs.path.basename(path) else "Image",
                .crowd => if (item.crowd) |crowd|
                    if (crowd.id.len > 0)
                        std.fmt.bufPrint(&generated_name, "{s} · {s}", .{ @tagName(crowd.kind), crowd.id }) catch "Crowd"
                    else
                        @tagName(crowd.kind)
                else
                    "Crowd",
                .background => "Background",
            };
            var fitted_name_buffer: [192]u8 = undefined;
            const fitted_name = self.fitUiText(&fitted_name_buffer, raw_name, body_font, text_width);
            self.drawUiText(fitted_name, .{ .x = text_x, .y = row.y + 6 }, body_font, if (!item.visible or item.opacity <= 0)
                .{ .r = 164, .g = 174, .b = 191, .a = 255 }
            else
                .white);

            const source = if (self.active_morph_state != null) item.effectiveSource() else item.effectiveBaseSource();
            const type_badge: []const u8 = switch (item.kind) {
                .background => "BG",
                .textbox => "Text",
                .img => "Image",
                .crowd => if (item.crowd) |crowd| switch (crowd.kind) {
                    .join => "Crowd join",
                    .poll => "Crowd poll",
                } else "Crowd",
            };
            const base_badge: []const u8 = switch (item.source.scope) {
                .none => "Unknown",
                .direct => "Direct",
                .component_instance => "Component",
                .group_instance_member => "Group member",
                .slide_template => "Shared",
                .slide_instance_override => "Override",
                .morph_item => "Morph",
            };
            var ownership_badge_buffer: [96]u8 = undefined;
            const local_badge: []const u8 = if (selected)
                if (self.compositionContextForSelection(items)) |context|
                    if (!context.local_overrides.empty()) blk: {
                        var fields_buffer: [64]u8 = undefined;
                        const fields = formatOverrideFields(&fields_buffer, context.local_overrides);
                        break :blk std.fmt.bufPrint(&ownership_badge_buffer, " · Local {s}", .{fields}) catch " · Local";
                    } else if (item.instance_source != null)
                        " · Local"
                    else
                        ""
                else if (item.instance_source != null)
                    " · Local"
                else
                    ""
            else if (item.instance_source != null)
                " · Local"
            else
                "";
            const morph_badge: []const u8 = if (self.active_morph_state) |active_state|
                if (item.creation_morph_state != null and item.creation_morph_state.? == active_state)
                    " · Born here"
                else if (item.state_source_state != null and item.state_source_state.? == active_state)
                    " · State local"
                else
                    " · Inherited"
            else
                "";
            var metadata_buffer: [192]u8 = undefined;
            const metadata = if (item.kind == .background)
                std.fmt.bufPrint(&metadata_buffer, "{s} · Paint barrier · {s}{s}{s} · line {d}", .{ type_badge, base_badge, local_badge, morph_badge, source.line_number }) catch "BG · Paint barrier"
            else if (!item.visible)
                std.fmt.bufPrint(&metadata_buffer, "{s} · {s}{s}{s} · hidden{s}", .{ type_badge, base_badge, local_badge, morph_badge, if (item.locked) " · locked" else "" }) catch type_badge
            else if (item.opacity <= 0)
                std.fmt.bufPrint(&metadata_buffer, "{s} · {s}{s}{s} · 0%{s}", .{ type_badge, base_badge, local_badge, morph_badge, if (item.locked) " · locked" else "" }) catch type_badge
            else
                std.fmt.bufPrint(&metadata_buffer, "{s} · {s}{s}{s} · {d:.0}%{s}", .{ type_badge, base_badge, local_badge, morph_badge, item.opacity * 100, if (item.locked) " · locked" else "" }) catch type_badge;
            var fitted_metadata_buffer: [192]u8 = undefined;
            const fitted_metadata = self.fitUiText(&fitted_metadata_buffer, metadata, compact_font, text_width);
            self.drawUiText(fitted_metadata, .{ .x = text_x, .y = row.y + 31 }, compact_font, .{ .r = 181, .g = 193, .b = 213, .a = 255 });
            rl.endScissorMode();
        }

        var page_buffer: [64]u8 = undefined;
        const first = if (count == 0) 0 else self.objects_first_visible + 1;
        const last = @min(count, self.objects_first_visible + objectRowCapacity(layout));
        const page_text = std.fmt.bufPrintZ(&page_buffer, "{d}–{d} / {d}", .{ first, last, count }) catch "Objects";
        self.drawUiText(page_text, .{ .x = layout.panel.x + 10, .y = layout.page_previous.y + 3 }, compact_font, .{ .r = 181, .g = 193, .b = 213, .a = 255 });
    }

    fn drawToolbar(self: Studio, viewport: Viewport) void {
        const layout = uiLayout(viewport);
        const body_font = scaledUiFont(layout.scale, UiTypography.body);
        const compact_font = scaledUiFont(layout.scale, UiTypography.compact);
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
            const font_size = body_font;
            const width = self.measureUiText(label, font_size);
            self.drawUiText(
                label,
                .{ .x = button.x + (button.width - width) / 2, .y = button.y + (button.height - @as(f32, @floatFromInt(font_size))) / 2 },
                font_size,
                .white,
            );
        }
        drawActionButton(self, layout.new_slide, "+ Slide");
        rl.drawRectangleRec(layout.grid_toggle, if (self.grid_snapping)
            .{ .r = 43, .g = 123, .b = 151, .a = 255 }
        else
            .{ .r = 31, .g = 38, .b = 55, .a = 245 });
        rl.drawRectangleLinesEx(layout.grid_toggle, if (self.grid_snapping) 2 else 1, if (self.grid_snapping)
            .{ .r = 80, .g = 215, .b = 255, .a = 255 }
        else
            .{ .r = 115, .g = 128, .b = 150, .a = 200 });
        const grid_label: [:0]const u8 = if (self.grid_snapping) "GRID ON" else "GRID";
        const grid_label_width = self.measureUiText(grid_label, compact_font);
        self.drawUiText(
            grid_label,
            .{ .x = layout.grid_toggle.x + (layout.grid_toggle.width - grid_label_width) / 2, .y = layout.grid_toggle.y + (layout.grid_toggle.height - @as(f32, @floatFromInt(compact_font))) / 2 },
            compact_font,
            .white,
        );
        drawActionButton(self, layout.scene_previous, "<");
        var scene_buffer: [32]u8 = undefined;
        const scene_label: [:0]const u8 = if (self.active_morph_state) |state|
            std.fmt.bufPrintZ(&scene_buffer, "STATE {d}/{d}", .{ state + 1, self.morph_state_count }) catch "MORPH"
        else
            "BASE";
        drawActionButton(self, layout.scene_label, scene_label);
        drawActionButton(self, layout.scene_next, ">");
        drawToggleButton(self, layout.slides_dock_toggle, "Slides", self.active_dock == .slides);
        drawToggleButton(
            self,
            layout.properties_dock_toggle,
            "Inspector",
            self.active_dock == .objects or self.active_dock == .properties,
        );
        drawActionButton(self, layout.focus_canvas, "Focus");
    }

    fn inlineItemsEqual(
        field: InlineField,
        a: slides.SlideItem,
        b: slides.SlideItem,
        resolved_bounds: []const ResolvedBounds,
    ) bool {
        if (!inlineFieldApplies(field, a) or !inlineFieldApplies(field, b)) return false;
        const a_geometry = itemGeometry(a, resolved_bounds);
        const b_geometry = itemGeometry(b, resolved_bounds);
        return switch (field) {
            .text => std.mem.eql(u8, a.text orelse "", b.text orelse ""),
            .x => a_geometry.position.x == b_geometry.position.x,
            .y => a_geometry.position.y == b_geometry.position.y,
            .width => a_geometry.size.x == b_geometry.size.x,
            .height => a_geometry.size.y == b_geometry.size.y,
            .foreground => std.meta.eql(a.color, b.color),
            .background => std.meta.eql(a.background_color, b.background_color),
            .font_size => a.fontSize == b.fontSize,
            .opacity => a.opacity == b.opacity,
        };
    }

    fn inlineDisplayValue(
        self: Studio,
        items: []const slides.SlideItem,
        resolved_bounds: []const ResolvedBounds,
        field: InlineField,
        scalar_buffer: []u8,
        color_buffer: *[9]u8,
    ) []const u8 {
        const primary_index = self.selectedIndex(items) orelse return "—";
        const primary = items[primary_index];
        if (!inlineFieldApplies(field, primary)) return "—";
        if (self.selectionCount() > 1) {
            if (field == .text) return "Mixed";
            for (1..self.selectionCount()) |selection_index| {
                const identity = self.selectedIdentityAt(selection_index) orelse return "Mixed";
                const index = itemIndexByIdentity(items, identity) orelse return "Mixed";
                if (!inlineItemsEqual(field, primary, items[index], resolved_bounds)) return "Mixed";
            }
        }
        return self.inlineInitialValue(primary, resolved_bounds, field, .direct, scalar_buffer, color_buffer);
    }

    const InlineDrawWindow = struct {
        display_start: usize,
        draw_x: f32,
        cursor_x: f32,
        cursor_y: f32,
        line_height: f32,
        horizontal_offset: f32,
    };

    fn inlineLineStart(value: []const u8, line_index: usize) usize {
        if (line_index == 0) return 0;
        var seen: usize = 0;
        for (value, 0..) |byte, index| {
            if (byte != '\n') continue;
            seen += 1;
            if (seen == line_index) return index + 1;
        }
        return value.len;
    }

    fn inlineDrawWindow(
        self: Studio,
        rect: rl.Rectangle,
        value_x: f32,
        value_y: f32,
        value_font: i32,
        multiline: bool,
        reserved_right: f32,
    ) InlineDrawWindow {
        const before_cursor = self.inline_editor.buffer[0..self.inline_editor.cursor];
        const cursor_line_start = if (std.mem.lastIndexOfScalar(u8, before_cursor, '\n')) |index| index + 1 else 0;
        const cursor_line = before_cursor[cursor_line_start..];
        var cursor_buffer: [max_inline_input_bytes + 1]u8 = undefined;
        @memcpy(cursor_buffer[0..cursor_line.len], cursor_line);
        cursor_buffer[cursor_line.len] = 0;
        const cursor_text: [:0]const u8 = cursor_buffer[0..cursor_line.len :0];
        const cursor_width = self.measureUiText(cursor_text, value_font);
        const available_width = @max(0, rect.x + rect.width - reserved_right - value_x - 6);
        const horizontal_offset = @max(0, cursor_width - @max(0, available_width - 2));

        const line_height = @as(f32, @floatFromInt(value_font + 2));
        const cursor_line_index = std.mem.count(u8, before_cursor, "\n");
        const available_height = @max(0, rect.y + rect.height - value_y - 4);
        const line_capacity = @max(
            @as(usize, 1),
            @as(usize, @intFromFloat(@floor(available_height / line_height))),
        );
        const first_line = if (multiline)
            cursor_line_index - @min(cursor_line_index, line_capacity - 1)
        else
            cursor_line_index;
        const display_start = inlineLineStart(self.inline_editor.text(), first_line);
        const relative_line = cursor_line_index - first_line;
        const maximum_cursor_x = @max(value_x, value_x + available_width - 2);
        return .{
            .display_start = display_start,
            .draw_x = value_x - horizontal_offset,
            .cursor_x = std.math.clamp(value_x + cursor_width - horizontal_offset, value_x, maximum_cursor_x),
            .cursor_y = value_y + @as(f32, @floatFromInt(relative_line)) * line_height,
            .line_height = line_height,
            .horizontal_offset = horizontal_offset,
        };
    }

    fn drawInlineField(
        self: Studio,
        rect: rl.Rectangle,
        label: [:0]const u8,
        value: []const u8,
        active: bool,
        invalid: bool,
        multiline: bool,
        local_override: bool,
        resettable_override: bool,
        viewport: Viewport,
    ) void {
        if (rect.width <= 0 or rect.height <= 0) return;
        const fill: rl.Color = if (active)
            .{ .r = 22, .g = 52, .b = 65, .a = 255 }
        else
            .{ .r = 25, .g = 31, .b = 45, .a = 250 };
        const border: rl.Color = if (invalid)
            .{ .r = 255, .g = 128, .b = 114, .a = 255 }
        else if (active)
            .{ .r = 80, .g = 215, .b = 255, .a = 255 }
        else
            .{ .r = 103, .g = 117, .b = 140, .a = 220 };
        rl.drawRectangleRec(rect, fill);
        rl.drawRectangleLinesEx(rect, if (active) 2 else 1, border);
        const label_font = @max(@as(i32, 14), scaledUiFont(uiScale(viewport), UiTypography.compact));
        const value_font = @max(@as(i32, 16), scaledUiFont(uiScale(viewport), UiTypography.body));
        const label_width = self.measureUiText(label, label_font);
        const value_x = if (multiline) rect.x + 7 else rect.x + 7 + label_width + 7;
        const value_y = inlineFieldValueY(rect, multiline, value_font);
        const reset_rect = inlineResetRect(rect);
        const reserved_right = if (local_override) reset_rect.width else 0;
        const draw_window: InlineDrawWindow = if (active)
            self.inlineDrawWindow(rect, value_x, value_y, value_font, multiline, reserved_right)
        else
            .{
                .display_start = 0,
                .draw_x = value_x,
                .cursor_x = value_x,
                .cursor_y = value_y,
                .line_height = @floatFromInt(value_font + 2),
                .horizontal_offset = 0,
            };
        self.drawUiText(label, .{ .x = rect.x + 7, .y = rect.y + if (multiline) 3 else (rect.height - @as(f32, @floatFromInt(label_font))) / 2 }, label_font, .{ .r = 164, .g = 180, .b = 204, .a = 255 });
        rl.beginScissorMode(
            @intFromFloat(@floor(value_x)),
            @intFromFloat(@floor(value_y)),
            @intFromFloat(@ceil(@max(0, rect.x + rect.width - reserved_right - value_x - 6))),
            @intFromFloat(@ceil(@max(0, rect.y + rect.height - value_y - 4))),
        );
        var display_buffer: [max_inline_input_bytes + 1]u8 = undefined;
        const bounded_len = @min(value.len, max_inline_input_bytes);
        const display_start = @min(draw_window.display_start, bounded_len);
        const display_len = bounded_len - display_start;
        @memcpy(display_buffer[0..display_len], value[display_start..bounded_len]);
        display_buffer[display_len] = 0;
        const display: [:0]const u8 = display_buffer[0..display_len :0];
        self.drawUiText(display, .{ .x = draw_window.draw_x, .y = value_y }, value_font, if (std.mem.eql(u8, value, "Mixed"))
            .{ .r = 255, .g = 190, .b = 104, .a = 255 }
        else
            .white);
        if (active and !self.inline_editor.blocked_initial and @mod(@as(i64, @intFromFloat(rl.getTime() * 2)), 2) == 0) {
            const cursor_height = @min(
                draw_window.line_height,
                @max(0, rect.y + rect.height - 4 - draw_window.cursor_y),
            );
            rl.drawRectangleRec(.{
                .x = draw_window.cursor_x,
                .y = draw_window.cursor_y,
                .width = 2,
                .height = cursor_height,
            }, border);
        }
        rl.endScissorMode();
        if (local_override) {
            rl.drawRectangleRec(reset_rect, if (resettable_override)
                .{ .r = 99, .g = 67, .b = 25, .a = 255 }
            else
                .{ .r = 50, .g = 45, .b = 39, .a = 255 });
            rl.drawRectangleLinesEx(reset_rect, 1, if (resettable_override)
                .{ .r = 247, .g = 164, .b = 29, .a = 255 }
            else
                .{ .r = 133, .g = 117, .b = 93, .a = 255 });
            const marker: [:0]const u8 = if (resettable_override) "R" else "L";
            const marker_font: i32 = 14;
            const marker_width = self.measureUiText(marker, marker_font);
            self.drawUiText(
                marker,
                .{
                    .x = reset_rect.x + (reset_rect.width - marker_width) / 2,
                    .y = reset_rect.y + (reset_rect.height - @as(f32, @floatFromInt(marker_font))) / 2,
                },
                marker_font,
                if (resettable_override) .{ .r = 255, .g = 205, .b = 116, .a = 255 } else .{ .r = 181, .g = 168, .b = 145, .a = 255 },
            );
        }
    }

    fn inlineTextIsMultiline(layout: UiLayout) bool {
        return !layout.compact_properties;
    }

    fn inlineFieldValueY(rect: rl.Rectangle, multiline: bool, value_font: i32) f32 {
        return if (multiline)
            rect.y + 20
        else
            rect.y + (rect.height - @as(f32, @floatFromInt(value_font))) / 2;
    }

    fn inlineResetRect(rect: rl.Rectangle) rl.Rectangle {
        const width = @min(@as(f32, 32), rect.width);
        return .{ .x = rect.x + rect.width - width, .y = rect.y, .width = width, .height = rect.height };
    }

    fn compositionKindLabel(kind: ReusableInstanceKind) []const u8 {
        return switch (kind) {
            .none => "Direct item",
            .component => "Component instance",
            .group => "Group instance",
            .slide_template => "Template instance",
        };
    }

    fn compositionBlockLabel(reason: CompositionBlockReason) []const u8 {
        return switch (reason) {
            .none => "available",
            .not_instance => "not a reusable instance",
            .generated_source => "generated source is read-only",
            .morph_scene => "detach is base-scene only",
            .ambiguous_instance => "instance boundary is ambiguous",
            .dependent_structure => "dependent source structure must remain shared",
            .integration_unavailable => "safe detach details are unavailable",
        };
    }

    fn formatOverrideFields(buffer: []u8, overrides: PropertyOverrideSet) []const u8 {
        const fields = [_]InlineField{ .text, .x, .y, .width, .height, .foreground, .background, .font_size, .opacity };
        const labels = [_][]const u8{ "Text", "X", "Y", "W", "H", "FG", "BG", "Font", "Opacity" };
        var used: usize = 0;
        for (fields, labels) |field, label| {
            if (!overrides.contains(field)) continue;
            const part = std.fmt.bufPrint(buffer[used..], "{s}{s}", .{ if (used == 0) "" else ", ", label }) catch break;
            used += part.len;
        }
        return buffer[0..used];
    }

    fn compositionHelp(
        self: Studio,
        items: []const slides.SlideItem,
        buffer: *[192]u8,
    ) ?[:0]const u8 {
        if (self.selectionCount() > 1)
            return std.fmt.bufPrintZ(buffer, "Selected group · Reuse creates one source-native component", .{}) catch null;
        const item_index = self.selectedIndex(items) orelse return null;
        const item = items[item_index];
        const context = self.compositionContextForSelection(items) orelse {
            return switch (item.source.scope) {
                .component_instance => std.fmt.bufPrintZ(buffer, "Component instance · waiting for safe detach details", .{}) catch null,
                .group_instance_member => std.fmt.bufPrintZ(buffer, "Group instance member · composition details pending", .{}) catch null,
                .slide_template => std.fmt.bufPrintZ(buffer, "Template instance · waiting for ownership details", .{}) catch null,
                else => std.fmt.bufPrintZ(buffer, "Direct item · properties belong to this slide", .{}) catch null,
            };
        };
        const kind = compositionKindLabel(context.kind);
        if (!context.local_overrides.empty()) {
            var fields_buffer: [96]u8 = undefined;
            const fields = formatOverrideFields(&fields_buffer, context.local_overrides);
            return std.fmt.bufPrintZ(
                buffer,
                "{s} · local {s} · {s}",
                .{ kind, fields, if (context.reset_target != null) "R resets one" else "local source is read-only" },
            ) catch null;
        }
        if (context.detach_target != null)
            return std.fmt.bufPrintZ(buffer, "{s} · inherited · Detach makes local boxes", .{kind}) catch null;
        return std.fmt.bufPrintZ(
            buffer,
            "{s} · inherited · {s}",
            .{ kind, compositionBlockLabel(context.detach_block) },
        ) catch null;
    }

    fn drawInlineProperties(
        self: Studio,
        items: []const slides.SlideItem,
        resolved_bounds: []const ResolvedBounds,
        viewport: Viewport,
        selected_locked: bool,
    ) void {
        const layout = uiLayout(viewport);
        drawCompactButton(self, layout.duplicate_item, "Dup");
        drawCompactButton(self, layout.delete_item, "Del");
        if (self.selectionCount() > 1) {
            drawCompactButton(self, layout.promote, "Reuse");
        } else if (self.compositionContextForSelection(items)) |context| {
            if (context.kind != .none) {
                if (context.detach_target != null)
                    drawCompactButton(self, layout.promote, "Detach")
                else
                    drawDisabledBadge(self, layout.promote, "Inherited");
            } else {
                drawCompactButton(self, layout.promote, "Reuse");
            }
        } else if (self.selectedIndex(items)) |index| {
            if (items[index].source.scope == .component_instance or items[index].source.scope == .group_instance_member or
                items[index].source.scope == .slide_template)
                drawDisabledBadge(self, layout.promote, "Instance")
            else
                drawCompactButton(self, layout.promote, "Reuse");
        } else {
            drawDisabledBadge(self, layout.promote, "Reuse");
        }
        drawCompactButton(self, layout.lock_item, if (selected_locked) "Unlock" else "Lock");

        const fields = [_]InlineField{ .text, .x, .y, .width, .height, .foreground, .background, .font_size, .opacity };
        const labels = [_][:0]const u8{ "TEXT", "X", "Y", "W", "H", "FG", "BG", "FONT", "OPACITY" };
        const composition = self.compositionContextForSelection(items);
        for (fields, labels) |field, label| {
            var scalar_buffer: [max_inline_input_bytes]u8 = undefined;
            var color_buffer: [9]u8 = undefined;
            const active = self.inline_editor.active and self.inline_editor.field == field;
            const value = if (active)
                self.inline_editor.text()
            else
                self.inlineDisplayValue(items, resolved_bounds, field, &scalar_buffer, &color_buffer);
            const local_override = if (composition) |context| context.local_overrides.contains(field) else false;
            const resettable_override = if (composition) |context|
                context.reset_target != null and context.resettable_overrides.contains(field)
            else
                false;
            self.drawInlineField(
                inlineFieldRect(layout, field),
                label,
                value,
                active,
                active and self.inline_editor.error_value != null,
                field == .text and inlineTextIsMultiline(layout),
                local_override,
                resettable_override,
                viewport,
            );
        }
        const selected_item: ?slides.SlideItem = if (self.selectionCount() == 1)
            if (self.selectedIndex(items)) |index| items[index] else null
        else
            null;
        drawSwatches(layout.foreground_swatches, if (selected_item) |item| item.color else null);
        drawCompactButton(self, layout.clear_background, "None");
        drawSwatches(layout.background_swatches, if (selected_item) |item| item.background_color else null);

        const error_font = @max(@as(i32, 14), scaledUiFont(layout.scale, UiTypography.compact));
        var composition_buffer: [192]u8 = undefined;
        if (layout.inline_error.height >= @as(f32, @floatFromInt(error_font))) {
            const message: ?[:0]const u8 = if (self.inline_editor.active) inline_error: {
                if (self.inline_editor.awaiting_commit) break :inline_error "Saving…";
                if (self.inline_editor.error_value) |reason| break :inline_error inlineErrorMessage(reason);
                if (self.inline_editor.target.edit_scope == .shared_template) break :inline_error "Shared template · Enter commits · Esc cancels";
                break :inline_error "Enter commits · Shift-Enter adds a text line · Tab moves";
            } else if (self.selectionCount() > 1)
                self.compositionHelp(items, &composition_buffer)
            else if (self.selectionCount() == 0)
                "Select an object to edit its properties"
            else
                self.compositionHelp(items, &composition_buffer);
            if (message) |text_value| {
                var fitted_buffer: [192]u8 = undefined;
                const fitted = self.fitUiText(&fitted_buffer, text_value, error_font, layout.inline_error.width);
                self.drawUiText(
                    fitted,
                    .{ .x = layout.inline_error.x, .y = layout.inline_error.y + 2 },
                    error_font,
                    if (self.inline_editor.error_value != null)
                        .{ .r = 255, .g = 150, .b = 126, .a = 255 }
                    else
                        .{ .r = 177, .g = 192, .b = 214, .a = 255 },
                );
            }
        }

        if (!layout.minimal_properties) {
            const align_labels = [_][:0]const u8{ "L", "HC", "R", "T", "VC", "B" };
            for (layout.align_buttons, align_labels) |button, label| drawCompactButton(self, button, label);
            const distribute_labels = [_][:0]const u8{ "H EQUAL GAP", "V EQUAL GAP" };
            for (layout.distribute_buttons, distribute_labels) |button, label| drawCompactButton(self, button, label);
            const layer_labels = [_][:0]const u8{ "Back", "Down", "Up", "Front" };
            for (layout.layer_buttons, layer_labels) |button, label| drawCompactButton(self, button, label);
        }
    }

    fn drawProperties(
        self: Studio,
        items: []const slides.SlideItem,
        resolved_bounds: []const ResolvedBounds,
        viewport: Viewport,
        selected_locked: bool,
    ) void {
        const layout = uiLayout(viewport);
        if (layout.properties.width <= 0 or layout.properties.height <= 0) return;
        const heading_font = scaledUiFont(layout.scale, UiTypography.heading);
        const body_font = scaledUiFont(layout.scale, UiTypography.body);
        const secondary: rl.Color = .{ .r = 205, .g = 214, .b = 230, .a = 255 };
        drawStudioPanel(layout.properties);
        if (viewport.chrome != null) {
            self.drawInspectorTabs(viewport);
            self.drawInlineProperties(items, resolved_bounds, viewport, selected_locked);
            return;
        } else {
            self.drawUiText("PROPERTIES", .{ .x = layout.properties.x + 12 * layout.scale, .y = layout.properties.y + 11 * layout.scale }, heading_font, .white);
        }
        drawActionButton(self, layout.edit_text, "Text");
        drawActionButton(self, layout.duplicate_item, "Dup");
        drawActionButton(self, layout.delete_item, "Del");
        drawActionButton(self, layout.promote, "Reuse");

        const selected_item: ?slides.SlideItem = if (self.selectionCount() == 1)
            if (self.selectedIndex(items)) |index| items[index] else null
        else
            null;
        const selected_geometry: ?Geometry = if (selected_item != null)
            itemGeometry(selected_item.?, resolved_bounds)
        else
            null;
        self.drawUiText("GEOMETRY", .{ .x = layout.properties.x + 12 * layout.scale, .y = layout.properties.y + @as(f32, if (layout.compact_properties) 75 else 85) * layout.scale }, body_font, secondary);
        var geometry_buffers: [4][32]u8 = undefined;
        const geometry_fallbacks = [_][:0]const u8{ "X --", "Y --", "W --", "H --" };
        for (layout.geometry_fields, 0..) |button, index| {
            const label = if (selected_geometry) |geometry| blk: {
                const value = switch (@as(GeometryField, @enumFromInt(index))) {
                    .x => geometry.position.x,
                    .y => geometry.position.y,
                    .width => geometry.size.x,
                    .height => geometry.size.y,
                };
                const prefix: []const u8 = switch (@as(GeometryField, @enumFromInt(index))) {
                    .x => "X",
                    .y => "Y",
                    .width => "W",
                    .height => "H",
                };
                break :blk if (layout.compact_properties)
                    std.fmt.bufPrintZ(&geometry_buffers[index], "{s} {d:.0}", .{ prefix, value }) catch geometry_fallbacks[index]
                else
                    std.fmt.bufPrintZ(&geometry_buffers[index], "{s} {d:.1}", .{ prefix, value }) catch geometry_fallbacks[index];
            } else geometry_fallbacks[index];
            drawActionButton(self, button, label);
        }

        self.drawUiText("FOREGROUND", .{ .x = layout.properties.x + 12 * layout.scale, .y = layout.properties.y + @as(f32, if (layout.compact_properties) 135 else 193) * layout.scale }, body_font, secondary);
        drawCompactButton(self, layout.custom_foreground, "Custom");
        drawSwatches(layout.foreground_swatches, if (selected_item) |item| item.color else null);
        self.drawUiText("BACKGROUND", .{ .x = layout.properties.x + 12 * layout.scale, .y = layout.properties.y + @as(f32, if (layout.compact_properties) 193 else 255) * layout.scale }, body_font, secondary);
        drawCompactButton(self, layout.clear_background, "None");
        drawCompactButton(self, layout.custom_background, "Custom");
        drawSwatches(layout.background_swatches, if (selected_item) |item| item.background_color else null);

        self.drawUiText("TYPE & OPACITY", .{ .x = layout.properties.x + 12 * layout.scale, .y = layout.properties.y + @as(f32, if (layout.compact_properties) 251 else 315) * layout.scale }, body_font, secondary);
        var font_buffer: [32]u8 = undefined;
        const font_label: [:0]const u8 = if (selected_item) |item|
            if (item.kind == .textbox and item.fontSize != null)
                std.fmt.bufPrintZ(&font_buffer, "Font {d}", .{item.fontSize.?}) catch "Font"
            else
                "Font --"
        else
            "Font --";
        drawActionButton(self, layout.font_size, font_label);
        var opacity_buffer: [32]u8 = undefined;
        const opacity_label: [:0]const u8 = if (selected_item) |item|
            if (layout.minimal_properties)
                std.fmt.bufPrintZ(&opacity_buffer, "Op {d:.0}%", .{item.opacity * 100}) catch "Opacity"
            else
                std.fmt.bufPrintZ(&opacity_buffer, "Opacity {d:.0}%", .{item.opacity * 100}) catch "Opacity"
        else if (layout.minimal_properties) "Op --" else "Opacity --";
        drawActionButton(self, layout.opacity, opacity_label);

        if (!layout.minimal_properties) {
            self.drawUiText(
                if (self.selectionCount() > 1) "ALIGN TO SELECTION" else "ALIGN TO SLIDE",
                .{ .x = layout.properties.x + 12 * layout.scale, .y = layout.properties.y + @as(f32, if (layout.compact_properties) 311 else 377) * layout.scale },
                body_font,
                secondary,
            );
            const align_labels = [_][:0]const u8{ "L", "HC", "R", "T", "VC", "B" };
            for (layout.align_buttons, align_labels) |button, label| drawCompactButton(self, button, label);
            self.drawUiText("DISTRIBUTE", .{ .x = layout.properties.x + 12 * layout.scale, .y = layout.properties.y + @as(f32, if (layout.compact_properties) 369 else 437) * layout.scale }, body_font, secondary);
            const distribute_labels = [_][:0]const u8{ "H EQUAL GAP", "V EQUAL GAP" };
            for (layout.distribute_buttons, distribute_labels) |button, label| drawCompactButton(self, button, label);
            if (!layout.compact_properties)
                self.drawUiText("LAYER", .{ .x = layout.properties.x + 12 * layout.scale, .y = layout.properties.y + 499 * layout.scale }, body_font, secondary);
            const layer_labels = [_][:0]const u8{ "Back", "Down", "Up", "Front" };
            for (layout.layer_buttons, layer_labels) |button, label| drawCompactButton(self, button, label);
        }
        drawCompactButton(self, layout.lock_item, if (selected_locked) "Unlock" else "Lock");
    }

    fn drawStatus(self: Studio, items: []const slides.SlideItem, resolved_bounds: []const ResolvedBounds, viewport: Viewport) void {
        const panel = statusPanel(viewport);
        if (panel.width <= 0 or panel.height <= 0) return;
        const scale = uiScale(viewport);
        const heading_font = scaledUiFont(scale, UiTypography.status_heading);
        const body_font = scaledUiFont(scale, UiTypography.body);
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

        self.drawUiText(status_text, .{ .x = panel.x + 12 * scale, .y = panel.y + 9 * scale }, heading_font, .white);
        const compact_status = panel.height < 100 * scale;
        if (compact_status and self.notice == .none) {
            self.drawUiText(
                if (self.grid_snapping) "GRID ON · G toggle · Tab Focus Canvas · Cmd/Ctrl-S save" else "G grid · Tab Focus Canvas · Cmd/Ctrl-S save",
                .{ .x = panel.x + 12 * scale, .y = panel.y + 43 * scale },
                body_font,
                .{ .r = 185, .g = 196, .b = 215, .a = 255 },
            );
        } else {
            self.drawUiText(
                if (self.grid_snapping)
                    "GRID ON · G toggle · Shift resize locks ratio · Cmd/Ctrl-drag bypasses snap"
                else
                    "G grid · Shift resize locks ratio · Cmd/Ctrl-drag bypasses snap · [ ] morph scenes",
                .{ .x = panel.x + 12 * scale, .y = panel.y + 39 * scale },
                body_font,
                .{ .r = 185, .g = 196, .b = 215, .a = 255 },
            );
            self.drawUiText(
                "Tab Focus Canvas  ·  Cmd/Ctrl-S save  ·  Shift-Cmd/Ctrl-S save copy  ·  Cmd/Ctrl-Z undo  ·  Shift-Cmd/Ctrl-Z redo",
                .{ .x = panel.x + 12 * scale, .y = panel.y + 64 * scale },
                body_font,
                .{ .r = 185, .g = 196, .b = 215, .a = 255 },
            );
        }
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
            .multi_duplicate_unsupported => "Duplicate selection is not source-safe here; no items were duplicated",
            .multi_delete_unsupported => "Delete selection is not source-safe here; no items were deleted",
            .multi_selection_property_unsupported => "That property is single-item only; align, distribute, move, or nudge the selection",
            .selection_capacity_reached => "Selection is limited to 64 items",
            .distribution_needs_three => "Equal-gap distribution needs at least three selected items",
            .generated_source_read_only => "Read-only in Studio: this item directive is produced with @let",
            .property_unavailable => "That property does not apply to this kind of item",
            .base_scene_only => "That action is available in the BASE scene",
            .structural_source_locked => "Slide structure is source-scoped here; no changes were made",
            .layer_selection_unsupported => "Layer changes need literal direct items in this scene; nothing moved",
            .copy_selection_unsupported => "Copy needs literal base-scene boxes or component instances; nothing was copied",
            .clipboard_empty => "Copy one or more items before pasting",
            .locked_item => "Unlock this item before editing it",
            .library_name_conflict => "That library name is already defined",
            .library_entry_in_use => "Cannot delete: later source instances still use this reusable",
            .library_delete_unsupported => "Slide-template deletion is not source-safe yet",
            .slide_template_promotion_locked => "This slide cannot be promoted without changing its source semantics",
            .group_reusable_needs_source_support => "Group reusable needs explicit component-group source-format support",
            .override_reset_unsupported => "That local property cannot be reset safely; no source change was made",
            .detach_instance_unsupported => "This reusable instance cannot be detached safely here",
        };
        if (notice_text) |message| {
            const notice_color: rl.Color = switch (self.notice) {
                .saved, .copy_saved => .{ .r = 126, .g = 231, .b = 177, .a = 255 },
                else => .{ .r = 255, .g = 145, .b = 132, .a = 255 },
            };
            self.drawUiText(message, .{ .x = panel.x + 12 * scale, .y = panel.y + @as(f32, if (compact_status) 43 else 89) * scale }, body_font, notice_color);
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

fn inlineErrorMessage(reason: InlineError) [:0]const u8 {
    return switch (reason) {
        .invalid_utf8 => "Invalid UTF-8; Esc cancels without changing source",
        .too_long => "Value exceeds 8 KiB; Esc cancels without changing source",
        .invalid_number => "Enter a finite number, such as 120 or -12.5",
        .non_positive_dimension => "Width and height must be at least 8",
        .invalid_color => "Use #RRGGBB, #RRGGBBAA, or none for BG",
        .invalid_font_size => "Font size must be a positive whole number",
        .invalid_opacity => "Use 0–1 or 0–100%",
        .invalid_text => "Text value is invalid; correct it and press Enter",
        .source_edit_failed => "Source changed; Esc cancels this guarded draft",
    };
}

fn drawStudioPanel(rect: rl.Rectangle) void {
    rl.drawRectangleRec(rect, .{ .r = 10, .g = 14, .b = 24, .a = 235 });
    rl.drawRectangleLinesEx(rect, 1, .{ .r = 80, .g = 215, .b = 255, .a = 180 });
}

fn drawActionButton(studio: Studio, rect: rl.Rectangle, label: [:0]const u8) void {
    if (rect.width <= 0 or rect.height <= 0) return;
    rl.drawRectangleRec(rect, .{ .r = 31, .g = 38, .b = 55, .a = 245 });
    rl.drawRectangleLinesEx(rect, 1, .{ .r = 115, .g = 128, .b = 150, .a = 200 });
    const font_size: i32 = @max(UiTypography.body, @as(i32, @intFromFloat(@round(rect.height * 0.4))));
    const width = studio.measureUiText(label, font_size);
    studio.drawUiText(
        label,
        .{ .x = rect.x + (rect.width - width) / 2, .y = rect.y + (rect.height - @as(f32, @floatFromInt(font_size))) / 2 },
        font_size,
        .white,
    );
}

fn drawCompactButton(studio: Studio, rect: rl.Rectangle, label: [:0]const u8) void {
    if (rect.width <= 0 or rect.height <= 0) return;
    rl.drawRectangleRec(rect, .{ .r = 31, .g = 38, .b = 55, .a = 245 });
    rl.drawRectangleLinesEx(rect, 1, .{ .r = 105, .g = 120, .b = 143, .a = 210 });
    const font_size: i32 = @max(UiTypography.compact, @as(i32, @intFromFloat(@round(rect.height * 0.4))));
    const width = studio.measureUiText(label, font_size);
    studio.drawUiText(
        label,
        .{ .x = rect.x + (rect.width - width) / 2, .y = rect.y + (rect.height - @as(f32, @floatFromInt(font_size))) / 2 },
        font_size,
        .white,
    );
}

fn drawDisabledBadge(studio: Studio, rect: rl.Rectangle, label: [:0]const u8) void {
    if (rect.width <= 0 or rect.height <= 0) return;
    rl.drawRectangleRec(rect, .{ .r = 24, .g = 25, .b = 33, .a = 225 });
    rl.drawRectangleLinesEx(rect, 1, .{ .r = 74, .g = 78, .b = 92, .a = 190 });
    const font_size: i32 = @max(UiTypography.compact, @as(i32, @intFromFloat(@round(rect.height * 0.4))));
    const width = studio.measureUiText(label, font_size);
    studio.drawUiText(
        label,
        .{ .x = rect.x + (rect.width - width) / 2, .y = rect.y + (rect.height - @as(f32, @floatFromInt(font_size))) / 2 },
        font_size,
        .{ .r = 130, .g = 137, .b = 153, .a = 255 },
    );
}

fn drawToggleButton(studio: Studio, rect: rl.Rectangle, label: [:0]const u8, active: bool) void {
    if (rect.width <= 0 or rect.height <= 0) return;
    rl.drawRectangleRec(rect, if (active)
        .{ .r = 43, .g = 123, .b = 151, .a = 255 }
    else
        .{ .r = 31, .g = 38, .b = 55, .a = 245 });
    rl.drawRectangleLinesEx(rect, if (active) 2 else 1, if (active)
        .{ .r = 80, .g = 215, .b = 255, .a = 255 }
    else
        .{ .r = 115, .g = 128, .b = 150, .a = 200 });
    const font_size: i32 = @max(UiTypography.compact, @as(i32, @intFromFloat(@round(rect.height * 0.4))));
    const width = studio.measureUiText(label, font_size);
    studio.drawUiText(
        label,
        .{ .x = rect.x + (rect.width - width) / 2, .y = rect.y + (rect.height - @as(f32, @floatFromInt(font_size))) / 2 },
        font_size,
        .white,
    );
}

fn drawSwatches(rects: [palette.len]rl.Rectangle, current: ?rl.Color) void {
    for (rects, palette) |rect, value| {
        const color = paletteColor(value);
        rl.drawRectangleRec(rect, color);
        const selected = if (current) |selected_color|
            selected_color.r == color.r and selected_color.g == color.g and selected_color.b == color.b and selected_color.a == color.a
        else
            false;
        rl.drawRectangleLinesEx(
            rect,
            if (selected) 3 else 1,
            if (selected) .{ .r = 80, .g = 215, .b = 255, .a = 255 } else .{ .r = 225, .g = 231, .b = 240, .a = 210 },
        );
    }
}

fn pointInRectangle(point: rl.Vector2, rect: rl.Rectangle) bool {
    return rect.width > 0 and rect.height > 0 and
        point.x >= rect.x and point.y >= rect.y and
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

test "plain marquee matches selectable items including read-only bounds but excludes edge contact" {
    var items = [_]slides.SlideItem{
        testItem(1, .textbox, 100, 300, 100, 80),
        testItem(2, .img, 300, 300, 0, 0),
        testItem(3, .textbox, 380, 300, 60, 80),
        testItem(4, .textbox, 200, 300, 60, 80),
        testItem(5, .textbox, 250, 300, 60, 80),
        testItem(6, .textbox, -20, 300, 100, 80),
        testItem(7, .textbox, 450, 300, 100, 80),
    };
    for (&items, 0..) |*item, index| item.source.line_offset = index + 1;
    items[2].locked = true;
    items[3].visible = false;
    items[4].source.patchable = false;
    const bounds = [_]ResolvedBounds{.{
        .identity = 2,
        .position = .{ .x = 300, .y = 300 },
        .size = .{ .x = 100, .y = 80 },
    }};
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    var studio: Studio = .{ .enabled = true, .selected_identity = 5 };

    _ = studio.update(&items, &bounds, viewport, .{
        .pointer_screen = .{ .x = 50, .y = 250 },
        .pointer_pressed = true,
        .pointer_down = true,
    });
    try std.testing.expect(studio.marquee.active);
    try std.testing.expect(studio.interactionActive());
    try std.testing.expectEqual(Interaction.idle, studio.interaction);
    _ = studio.update(&items, &bounds, viewport, .{
        .pointer_screen = .{ .x = 450, .y = 450 },
        .pointer_released = true,
    });

    try std.testing.expect(!studio.marquee.active);
    try std.testing.expectEqual(@as(usize, 4), studio.selectionCount());
    try std.testing.expect(studio.isIdentitySelected(1));
    try std.testing.expect(studio.isIdentitySelected(2));
    try std.testing.expect(studio.isIdentitySelected(6));
    try std.testing.expect(!studio.isIdentitySelected(3));
    try std.testing.expect(!studio.isIdentitySelected(4));
    try std.testing.expect(studio.isIdentitySelected(5));
    try std.testing.expect(!studio.isIdentitySelected(7));
    try std.testing.expectEqual(@as(?usize, 6), studio.selectedIdentityAt(0));
}

test "Shift marquee toggles against its snapshot and preserves or replaces primary predictably" {
    var items = [_]slides.SlideItem{
        testItem(1, .textbox, 100, 300, 100, 80),
        testItem(2, .textbox, 300, 300, 100, 80),
        testItem(3, .textbox, 500, 300, 100, 80),
    };
    for (&items, 0..) |*item, index| item.source.line_offset = index + 1;
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    var studio: Studio = .{ .enabled = true };
    setTestSelection(&studio, &items, &.{ 1, 2 });

    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 250, .y = 250 },
        .pointer_pressed = true,
        .pointer_down = true,
        .toggle_selection = true,
    });
    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 650, .y = 450 },
        .pointer_released = true,
    });
    try std.testing.expectEqual(@as(usize, 2), studio.selectionCount());
    try std.testing.expect(studio.isIdentitySelected(1));
    try std.testing.expect(studio.isIdentitySelected(3));
    try std.testing.expect(!studio.isIdentitySelected(2));
    try std.testing.expectEqual(@as(?usize, 1), studio.selectedIdentityAt(0));

    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 50, .y = 250 },
        .pointer_pressed = true,
        .pointer_down = true,
        .toggle_selection = true,
    });
    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 220, .y = 450 },
        .pointer_released = true,
    });
    try std.testing.expectEqual(@as(usize, 1), studio.selectionCount());
    try std.testing.expectEqual(@as(?usize, 3), studio.selectedIdentityAt(0));
}

test "marquee sub-threshold click and Escape have conventional selection semantics" {
    var items = [_]slides.SlideItem{testItem(1, .textbox, 100, 300, 100, 80)};
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    var studio: Studio = .{ .enabled = true, .selected_identity = 1 };

    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 50, .y = 250 },
        .pointer_pressed = true,
        .pointer_down = true,
        .toggle_selection = true,
    });
    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 51, .y = 251 },
        .pointer_released = true,
    });
    try std.testing.expectEqual(@as(?usize, 1), studio.selected_identity);

    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 50, .y = 250 },
        .pointer_pressed = true,
        .pointer_down = true,
    });
    _ = studio.update(&items, &.{}, viewport, .{ .cancel_pressed = true });
    try std.testing.expect(!studio.marquee.active);
    try std.testing.expectEqual(@as(?usize, 1), studio.selected_identity);

    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 50, .y = 250 },
        .pointer_pressed = true,
        .pointer_released = true,
    });
    try std.testing.expectEqual(@as(?usize, null), studio.selected_identity);
}

test "marquee capacity overflow is atomic and retains the gesture-start selection" {
    var items: [66]slides.SlideItem = undefined;
    for (&items, 0..) |*item, index| {
        const x: f32 = @floatFromInt(20 + (index % 13) * 100);
        const y: f32 = @floatFromInt(300 + (index / 13) * 80);
        item.* = testItem(index + 1, .textbox, x, y, 20, 20);
        item.source.line_offset = index + 1;
    }
    items[65].position = .{ .x = 1700, .y = 900 };
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    var studio: Studio = .{ .enabled = true, .selected_identity = 66 };

    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 5, .y = 200 },
        .pointer_pressed = true,
        .pointer_down = true,
    });
    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 1500, .y = 800 },
        .pointer_released = true,
    });
    try std.testing.expectEqual(@as(usize, 1), studio.selectionCount());
    try std.testing.expectEqual(@as(?usize, 66), studio.selectedIdentityAt(0));
    try std.testing.expectEqual(Notice.selection_capacity_reached, studio.notice);

    studio.notice = .none;
    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 5, .y = 200 },
        .pointer_pressed = true,
        .pointer_down = true,
        .toggle_selection = true,
    });
    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 1500, .y = 800 },
        .pointer_released = true,
    });
    try std.testing.expectEqual(@as(usize, 1), studio.selectionCount());
    try std.testing.expectEqual(@as(?usize, 66), studio.selectedIdentityAt(0));
    try std.testing.expectEqual(Notice.selection_capacity_reached, studio.notice);
}

test "pressing a selected member starts group movement instead of a marquee or group resize" {
    var items = [_]slides.SlideItem{
        testItem(1, .textbox, 100, 300, 100, 80),
        testItem(2, .textbox, 300, 300, 100, 80),
    };
    items[0].source.line_offset = 1;
    items[1].source.line_offset = 2;
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    var studio: Studio = .{ .enabled = true };
    setTestSelection(&studio, &items, &.{ 2, 1 });

    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 120, .y = 320 },
        .pointer_pressed = true,
        .pointer_down = true,
    });
    try std.testing.expectEqual(Interaction.moving, studio.interaction);
    try std.testing.expectEqual(@as(usize, 2), studio.group_drag_count);
    try std.testing.expect(!studio.marquee.active);
    _ = studio.update(&items, &.{}, viewport, .{ .cancel_pressed = true });
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

test "multi-selection single-item properties are refused and duplicate preflights the whole selection" {
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
    try std.testing.expectEqual(Notice.multi_duplicate_unsupported, studio.notice);
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

test "multi duplicate emits one paint-ordered atomic intention for direct and component sources" {
    var items = [_]slides.SlideItem{
        testItem(191, .textbox, 100, 100, 100, 80),
        testItem(192, .textbox, 300, 100, 100, 80),
        testItem(193, .img, 500, 100, 100, 80),
    };
    items[0].source = .{ .scope = .direct, .line_number = 1, .line_offset = 10, .patchable = true };
    items[1].source = .{ .scope = .component_instance, .line_number = 2, .line_offset = 20, .patchable = true };
    items[2].source = .{ .scope = .direct, .line_number = 3, .line_offset = 30, .patchable = true };
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    var studio: Studio = .{ .enabled = true };
    setTestSelection(&studio, &items, &.{ 193, 191, 192 });

    _ = studio.update(&items, &.{}, viewport, .{ .duplicate_slide_pressed = true });
    switch (studio.takeSemanticCommand().?) {
        .duplicate_items => |command| {
            try std.testing.expectEqual(@as(usize, 3), command.count);
            try std.testing.expectEqual(@as(usize, 191), command.targets[0].item_identity);
            try std.testing.expectEqual(@as(usize, 192), command.targets[1].item_identity);
            try std.testing.expectEqual(@as(usize, 193), command.targets[2].item_identity);
            for (command.slice()) |target| try std.testing.expectEqual(EditScope.direct, target.edit_scope);
        },
        else => return error.UnexpectedSemanticCommand,
    }
}

test "multi duplicate rejects templates shared targets locks and duplicate physical sources atomically" {
    var items = [_]slides.SlideItem{
        testItem(194, .textbox, 100, 100, 100, 80),
        testItem(195, .textbox, 300, 100, 100, 80),
    };
    items[0].source = .{ .scope = .direct, .line_offset = 10, .patchable = true };
    items[1].source = .{ .scope = .slide_template, .line_offset = 20, .patchable = true };
    items[1].id = "template-item";
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    var studio: Studio = .{ .enabled = true };
    setTestSelection(&studio, &items, &.{ 194, 195 });

    _ = studio.update(&items, &.{}, viewport, .{ .duplicate_slide_pressed = true, .allow_shared_edit = true });
    try std.testing.expect(studio.takeSemanticCommand() == null);
    try std.testing.expectEqual(Notice.multi_duplicate_unsupported, studio.notice);

    items[1].source = items[0].source;
    items[1].source.scope = .component_instance;
    items[0].source.scope = .component_instance;
    _ = studio.update(&items, &.{}, viewport, .{ .duplicate_slide_pressed = true });
    try std.testing.expect(studio.takeSemanticCommand() == null);
    try std.testing.expectEqual(Notice.multi_duplicate_unsupported, studio.notice);

    items[1].source.line_offset = 20;
    items[1].locked = true;
    setTestSelection(&studio, &items, &.{ 194, 195 });
    try std.testing.expectEqual(@as(usize, 2), studio.selectionCount());
    _ = studio.update(&items, &.{}, viewport, .{ .duplicate_slide_pressed = true });
    try std.testing.expectEqual(@as(usize, 2), studio.selectionCount());
    try std.testing.expect(studio.takeSemanticCommand() == null);
    try std.testing.expectEqual(Notice.locked_item, studio.notice);
}

test "multi duplicate supports only unmodified births in the current morph state" {
    var items = [_]slides.SlideItem{
        testItem(196, .textbox, 100, 100, 100, 80),
        testItem(197, .textbox, 300, 100, 100, 80),
    };
    for (&items, 0..) |*item, index| {
        item.source = .{ .scope = .morph_item, .line_offset = (index + 1) * 10, .patchable = true };
        item.creation_morph_state = 0;
    }
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    var studio: Studio = .{ .enabled = true, .active_morph_state = 0, .morph_state_count = 1 };
    setTestSelection(&studio, &items, &.{ 197, 196 });

    _ = studio.update(&items, &.{}, viewport, .{ .duplicate_slide_pressed = true });
    try std.testing.expect(std.meta.activeTag(studio.takeSemanticCommand().?) == .duplicate_items);

    items[1].state_source = .{ .scope = .morph_item, .line_offset = 40, .patchable = true };
    items[1].state_source_state = 0;
    _ = studio.update(&items, &.{}, viewport, .{ .duplicate_slide_pressed = true });
    try std.testing.expect(studio.takeSemanticCommand() == null);
    try std.testing.expectEqual(Notice.multi_duplicate_unsupported, studio.notice);
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

test "multi delete mixes physical removal and identified local hide in one paint-ordered intention" {
    var items = [_]slides.SlideItem{
        testItem(198, .textbox, 100, 100, 100, 80),
        testItem(199, .textbox, 300, 100, 100, 80),
    };
    items[0].source = .{ .scope = .direct, .line_number = 1, .line_offset = 10, .patchable = true };
    items[1].source = .{ .scope = .slide_template, .line_number = 2, .line_offset = 20, .patchable = true };
    items[1].instance_source = .{ .scope = .slide_instance_override, .line_number = 8, .line_offset = 80, .patchable = true };
    items[1].id = "local-item";
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    var studio: Studio = .{ .enabled = true };
    setTestSelection(&studio, &items, &.{ 199, 198 });

    _ = studio.update(&items, &.{}, viewport, .{ .delete_pressed = true });
    switch (studio.takeSemanticCommand().?) {
        .delete_items => |command| {
            try std.testing.expectEqual(@as(usize, 2), command.count);
            try std.testing.expectEqual(@as(usize, 198), command.targets[0].item_identity);
            try std.testing.expectEqual(EditScope.direct, command.targets[0].edit_scope);
            try std.testing.expectEqual(@as(usize, 199), command.targets[1].item_identity);
            try std.testing.expectEqual(EditScope.local_instance, command.targets[1].edit_scope);
            try std.testing.expectEqual(@as(usize, 80), command.targets[1].source.line_offset);
        },
        else => return error.UnexpectedSemanticCommand,
    }
}

test "multi delete rejects shared-definition locked generated and ambiguous targets without a partial command" {
    var items = [_]slides.SlideItem{
        testItem(200, .textbox, 100, 100, 100, 80),
        testItem(201, .textbox, 300, 100, 100, 80),
    };
    items[0].source = .{ .scope = .direct, .line_offset = 10, .patchable = true };
    items[1].source = .{ .scope = .slide_template, .line_offset = 20, .patchable = true };
    items[1].id = "shared-item";
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    var studio: Studio = .{ .enabled = true };
    setTestSelection(&studio, &items, &.{ 200, 201 });

    _ = studio.update(&items, &.{}, viewport, .{ .delete_pressed = true, .allow_shared_edit = true });
    try std.testing.expect(studio.takeSemanticCommand() == null);
    try std.testing.expectEqual(Notice.multi_delete_unsupported, studio.notice);

    items[1].source = .{ .scope = .direct, .line_offset = 20, .patchable = true };
    items[1].locked = true;
    _ = studio.update(&items, &.{}, viewport, .{ .delete_pressed = true });
    try std.testing.expect(studio.takeSemanticCommand() == null);
    try std.testing.expectEqual(Notice.locked_item, studio.notice);

    items[1].locked = false;
    items[1].source.patchable = false;
    _ = studio.update(&items, &.{}, viewport, .{ .delete_pressed = true });
    try std.testing.expect(studio.takeSemanticCommand() == null);
    try std.testing.expectEqual(Notice.generated_source_read_only, studio.notice);

    items[1].source = items[0].source;
    _ = studio.update(&items, &.{}, viewport, .{ .delete_pressed = true });
    try std.testing.expect(studio.takeSemanticCommand() == null);
    try std.testing.expectEqual(Notice.multi_delete_unsupported, studio.notice);
}

test "multi delete accepts a current-state birth plus an identified inherited morph hide" {
    var items = [_]slides.SlideItem{
        testItem(202, .textbox, 100, 100, 100, 80),
        testItem(203, .textbox, 300, 100, 100, 80),
    };
    items[0].source = .{ .scope = .morph_item, .line_offset = 10, .patchable = true };
    items[0].creation_morph_state = 0;
    items[0].state_source = .{ .scope = .morph_item, .line_offset = 11, .patchable = true };
    items[0].state_source_state = 0;
    items[1].source = .{ .scope = .direct, .line_offset = 20, .patchable = true };
    items[1].id = "inherited";
    items[1].state_source = .{ .scope = .morph_item, .line_offset = 21, .patchable = true };
    items[1].state_source_state = 0;
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    var studio: Studio = .{ .enabled = true, .active_morph_state = 0, .morph_state_count = 1 };
    setTestSelection(&studio, &items, &.{ 203, 202 });

    _ = studio.update(&items, &.{}, viewport, .{ .delete_pressed = true });
    switch (studio.takeSemanticCommand().?) {
        .delete_items => |command| {
            try std.testing.expectEqual(@as(usize, 2), command.count);
            try std.testing.expectEqual(@as(usize, 202), command.targets[0].item_identity);
            try std.testing.expectEqual(@as(usize, 10), command.targets[0].source.line_offset);
            try std.testing.expectEqual(@as(usize, 203), command.targets[1].item_identity);
            try std.testing.expectEqual(@as(usize, 21), command.targets[1].source.line_offset);
        },
        else => return error.UnexpectedSemanticCommand,
    }

    items[1].id = null;
    _ = studio.update(&items, &.{}, viewport, .{ .delete_pressed = true });
    try std.testing.expect(studio.takeSemanticCommand() == null);
    try std.testing.expectEqual(Notice.local_override_needs_unique_id, studio.notice);
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

test "background clear emits direct local shared and morph targets" {
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
    switch (studio.takeSemanticCommand().?) {
        .clear_background => |target| try std.testing.expectEqual(EditScope.direct, target.edit_scope),
        else => return error.UnexpectedSemanticCommand,
    }

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

test "promotion is direct-only while instances require detach capability" {
    var items = [_]slides.SlideItem{testItem(88, .textbox, 100, 100, 300, 100)};
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = default_logical_size };
    var studio: Studio = .{ .enabled = true, .selected_identity = 88 };

    items[0].source.scope = .component_instance;
    _ = studio.update(&items, &.{}, viewport, .{ .promote_pressed = true });
    try std.testing.expect(studio.takeSemanticCommand() == null);
    try std.testing.expectEqual(Notice.detach_instance_unsupported, studio.notice);

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
        .pointer_screen = .{ .x = 120, .y = 160 },
        .pointer_pressed = true,
        .pointer_down = true,
    });
    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 220, .y = 220 },
        .pointer_down = true,
    });
    try expectVector(.{ .x = 200, .y = 160 }, items[0].position);
    _ = studio.update(&items, &.{}, viewport, .{ .delete_pressed = true });
    try std.testing.expectEqual(Interaction.idle, studio.interaction);
    try expectVector(.{ .x = 100, .y = 100 }, items[0].position);
    try std.testing.expect(std.meta.activeTag(studio.takeSemanticCommand().?) == .delete_item);

    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 120, .y = 160 },
        .pointer_pressed = true,
        .pointer_down = true,
    });
    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 260, .y = 240 },
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
        .{ .kind = .group, .name = "hero_pair" },
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
        .add_reusable_group => |entry_index| try std.testing.expectEqual(@as(usize, 1), entry_index),
        else => return error.UnexpectedSemanticCommand,
    }

    _ = studio.updateWithWorkspace(&items, &.{}, viewport, workspace, .{
        .pointer_screen = rectangleCenter(libraryRowRect(layout, 2).?),
        .pointer_pressed = true,
    });
    try std.testing.expectEqual(@as(?usize, 2), studio.selected_library_index);
    try std.testing.expect(studio.takeSemanticCommand() == null);

    _ = studio.updateWithWorkspace(&items, &.{}, viewport, workspace, .{
        .pointer_screen = rectangleCenter(layout.library_use),
        .pointer_pressed = true,
    });
    switch (studio.takeSemanticCommand().?) {
        .new_slide_from_template => |entry_index| try std.testing.expectEqual(@as(usize, 2), entry_index),
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
    switch (studio.takeSemanticCommand().?) {
        .copy_items => |command| {
            try std.testing.expectEqual(@as(usize, 2), command.count);
            try std.testing.expectEqual(SourceScope.component_instance, command.targets[1].source.scope);
        },
        else => return error.UnexpectedSemanticCommand,
    }

    items[0].source = items[1].source;
    _ = studio.update(&items, &.{}, viewport, .{ .copy_pressed = true });
    try std.testing.expect(studio.takeSemanticCommand() == null);
    try std.testing.expectEqual(Notice.copy_selection_unsupported, studio.notice);

    items[0].locked = true;
    items[0].source = .{ .scope = .direct, .line_number = 1, .line_offset = 10, .patchable = true };
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

test "precise property controls emit field-specific single-item intentions" {
    var items = [_]slides.SlideItem{testItem(301, .textbox, 100.5, 200.25, 320.75, 140.5)};
    items[0].id = "hero";
    items[0].fontSize = 42;
    items[0].opacity = 0.65;
    items[0].source = .{ .scope = .direct, .line_number = 7, .line_offset = 70, .patchable = true };
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = .{ .x = 1280, .y = 720 } };
    const layout = uiLayout(viewport);
    var studio: Studio = .{ .enabled = true, .selected_identity = 301 };

    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = rectangleCenter(layout.geometry_fields[@intFromEnum(GeometryField.width)]),
        .pointer_pressed = true,
    });
    switch (studio.takeSemanticCommand().?) {
        .edit_numeric_geometry => |request| {
            try std.testing.expectEqual(GeometryField.width, request.field);
            try std.testing.expectEqual(@as(usize, 301), request.target.item_identity);
            try std.testing.expectEqual(EditScope.direct, request.target.edit_scope);
        },
        else => return error.UnexpectedSemanticCommand,
    }

    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = rectangleCenter(layout.custom_foreground),
        .pointer_pressed = true,
    });
    try std.testing.expect(std.meta.activeTag(studio.takeSemanticCommand().?) == .set_custom_foreground);

    studio.active_morph_state = 0;
    studio.morph_state_count = 1;
    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = rectangleCenter(layout.custom_background),
        .pointer_pressed = true,
    });
    switch (studio.takeSemanticCommand().?) {
        .set_custom_background => |target| try std.testing.expectEqual(EditScope.direct, target.edit_scope),
        else => return error.UnexpectedSemanticCommand,
    }
    studio.active_morph_state = null;

    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = rectangleCenter(layout.font_size),
        .pointer_pressed = true,
    });
    try std.testing.expect(std.meta.activeTag(studio.takeSemanticCommand().?) == .set_font_size);
    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = rectangleCenter(layout.opacity),
        .pointer_pressed = true,
    });
    try std.testing.expect(std.meta.activeTag(studio.takeSemanticCommand().?) == .set_opacity);
}

test "property requests honor local shared lock group and item-kind guards" {
    var items = [_]slides.SlideItem{
        testItem(302, .textbox, 100, 100, 300, 100),
        testItem(303, .textbox, 500, 100, 300, 100),
    };
    items[0].id = "template-hero";
    items[0].source = .{ .scope = .slide_template, .line_number = 9, .line_offset = 90, .patchable = true };
    items[1].source = .{ .scope = .direct, .line_number = 12, .line_offset = 120, .patchable = true };
    const viewport: Viewport = .{ .slide_top_left = .zero(), .slide_size = .{ .x = 1280, .y = 720 } };
    const layout = uiLayout(viewport);
    var studio: Studio = .{ .enabled = true, .selected_identity = 302 };

    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = rectangleCenter(layout.geometry_fields[@intFromEnum(GeometryField.x)]),
        .pointer_pressed = true,
    });
    switch (studio.takeSemanticCommand().?) {
        .edit_numeric_geometry => |request| try std.testing.expectEqual(EditScope.local_instance, request.target.edit_scope),
        else => return error.UnexpectedSemanticCommand,
    }
    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = rectangleCenter(layout.geometry_fields[@intFromEnum(GeometryField.x)]),
        .pointer_pressed = true,
        .allow_shared_edit = true,
    });
    switch (studio.takeSemanticCommand().?) {
        .edit_numeric_geometry => |request| try std.testing.expectEqual(EditScope.shared_template, request.target.edit_scope),
        else => return error.UnexpectedSemanticCommand,
    }

    items[0].locked = true;
    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = rectangleCenter(layout.opacity),
        .pointer_pressed = true,
    });
    try std.testing.expect(studio.takeSemanticCommand() == null);
    try std.testing.expectEqual(Notice.locked_item, studio.notice);
    items[0].locked = false;

    setTestSelection(&studio, &items, &.{ 302, 303 });
    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = rectangleCenter(layout.opacity),
        .pointer_pressed = true,
    });
    try std.testing.expect(studio.takeSemanticCommand() == null);
    try std.testing.expectEqual(Notice.multi_selection_property_unsupported, studio.notice);

    studio.setSingleSelection(items[0]);
    items[0].kind = .img;
    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = rectangleCenter(layout.font_size),
        .pointer_pressed = true,
    });
    try std.testing.expect(studio.takeSemanticCommand() == null);
    try std.testing.expectEqual(Notice.property_unavailable, studio.notice);
}

test "property layout stays contained and typography remains legible" {
    try std.testing.expect(UiTypography.compact >= 14);
    try std.testing.expect(UiTypography.body >= 16);
    try std.testing.expect(UiTypography.heading >= 18);
    const viewports = [_]Viewport{
        .{ .slide_top_left = .zero(), .slide_size = .{ .x = 1280, .y = 720 } },
        .{ .slide_top_left = .zero(), .slide_size = .{ .x = 900, .y = 600 } },
        .{ .slide_top_left = .zero(), .slide_size = .{ .x = 900, .y = 506 } },
    };
    for (viewports) |viewport| {
        const layout = uiLayout(viewport);
        try std.testing.expect(!rectanglesOverlap(layout.properties, statusPanel(viewport)));
        const fixed = [_]rl.Rectangle{
            layout.edit_text,
            layout.duplicate_item,
            layout.delete_item,
            layout.promote,
            layout.custom_foreground,
            layout.custom_background,
            layout.clear_background,
            layout.font_size,
            layout.opacity,
            layout.lock_item,
        };
        for (fixed) |rect| try expectRectangleContained(layout.properties, rect);
        for (layout.geometry_fields) |rect| try expectRectangleContained(layout.properties, rect);
        for (layout.foreground_swatches) |rect| try expectRectangleContained(layout.properties, rect);
        for (layout.background_swatches) |rect| try expectRectangleContained(layout.properties, rect);
        for (layout.align_buttons) |rect| try expectRectangleContained(layout.properties, rect);
        for (layout.distribute_buttons) |rect| try expectRectangleContained(layout.properties, rect);
        for (layout.layer_buttons) |rect| try expectRectangleContained(layout.properties, rect);
    }
    try std.testing.expect(!uiLayout(viewports[0]).compact_properties);
    try std.testing.expect(uiLayout(viewports[1]).compact_properties);
    try std.testing.expect(uiLayout(viewports[2]).minimal_properties);

    const full_screen: Viewport = .{ .slide_top_left = .zero(), .slide_size = .{ .x = 2560, .y = 1440 } };
    try std.testing.expectApproxEqAbs(@as(f32, 2), uiScale(full_screen), 0.0001);
    try std.testing.expect(uiLayout(full_screen).edit_text.height > uiLayout(viewports[0]).edit_text.height);
}

test "docked frame keeps permanent chrome outside a sixteen by nine canvas" {
    const cases = [_]struct {
        size: rl.Vector2,
        expected_mode: FrameMode,
    }{
        .{ .size = .{ .x = 1920, .y = 1080 }, .expected_mode = .wide },
        .{ .size = .{ .x = 1600, .y = 900 }, .expected_mode = .wide },
        .{ .size = .{ .x = 1280, .y = 720 }, .expected_mode = .medium },
        .{ .size = .{ .x = 900, .y = 600 }, .expected_mode = .compact },
        .{ .size = .{ .x = 900, .y = 506 }, .expected_mode = .compact },
        .{ .size = .{ .x = 2560, .y = 1440 }, .expected_mode = .wide },
    };
    const requested_docks = [_]DockPanel{ .slides, .objects, .properties };
    for (cases) |case| {
        for (requested_docks) |requested_dock| {
            const content: rl.Rectangle = .{ .x = 37, .y = 19, .width = case.size.x, .height = case.size.y };
            const frame = frameLayout(content, true, false, requested_dock);
            try std.testing.expectEqual(case.expected_mode, frame.mode);
            try std.testing.expect(frame.chrome.visible);
            try std.testing.expect(frame.viewport.valid());
            try std.testing.expectApproxEqAbs(
                @as(f32, 16.0 / 9.0),
                frame.viewport.slide_size.x / frame.viewport.slide_size.y,
                0.0001,
            );
            const logical_probe: rl.Vector2 = .{ .x = 713.5, .y = 402.25 };
            const screen_probe = logicalToScreen(frame.viewport, logical_probe).?;
            try expectVector(logical_probe, screenToLogical(frame.viewport, screen_probe).?);
            const slide_rect: rl.Rectangle = .{
                .x = frame.viewport.slide_top_left.x,
                .y = frame.viewport.slide_top_left.y,
                .width = frame.viewport.slide_size.x,
                .height = frame.viewport.slide_size.y,
            };
            try expectRectangleContained(frame.canvas_area, slide_rect);
            try std.testing.expect(!rectanglesOverlap(frame.chrome.toolbar, slide_rect));
            try std.testing.expect(!rectanglesOverlap(frame.chrome.status, slide_rect));
            if (frame.chrome.left_visible)
                try std.testing.expect(!rectanglesOverlap(frame.chrome.left_dock, slide_rect));
            if (frame.chrome.right_visible)
                try std.testing.expect(!rectanglesOverlap(frame.chrome.right_dock, slide_rect));

            const controls = uiLayout(frame.viewport);
            try expectRectangleContained(frame.chrome.toolbar, controls.toolbar);
            for (controls.tool_buttons) |button| try expectRectangleContained(frame.chrome.toolbar, button);
            try expectRectangleContained(frame.chrome.toolbar, controls.new_slide);
            try expectRectangleContained(frame.chrome.toolbar, controls.grid_toggle);
            try expectRectangleContained(frame.chrome.toolbar, controls.scene_previous);
            try expectRectangleContained(frame.chrome.toolbar, controls.scene_label);
            try expectRectangleContained(frame.chrome.toolbar, controls.scene_next);
            try expectRectangleContained(frame.chrome.toolbar, controls.slides_dock_toggle);
            try expectRectangleContained(frame.chrome.toolbar, controls.properties_dock_toggle);
            try expectRectangleContained(frame.chrome.toolbar, controls.focus_canvas);
            try std.testing.expectEqual(@as(f32, 1), controls.scale);
            if (frame.chrome.right_visible) {
                try expectRectangleContained(frame.chrome.right_dock, controls.properties);
                const objects = objectsLayout(frame.viewport);
                try expectRectangleContained(frame.chrome.right_dock, objects.panel);
                try expectRectangleContained(objects.panel, objects.objects_tab);
                try expectRectangleContained(objects.panel, objects.properties_tab);
                try expectRectangleContained(objects.panel, objects.rows_clip);
                try expectRectangleContained(objects.panel, objects.page_previous);
                try expectRectangleContained(objects.panel, objects.page_next);
                for (objects.layer_actions) |control| try expectRectangleContained(objects.panel, control);
                for (0..objectRowCapacity(objects)) |visible_slot|
                    try expectRectangleContained(objects.rows_clip, objectRowRect(objects, visible_slot).?);
                const property_controls = [_]rl.Rectangle{
                    controls.edit_text,
                    controls.duplicate_item,
                    controls.delete_item,
                    controls.promote,
                    controls.custom_foreground,
                    controls.custom_background,
                    controls.clear_background,
                    controls.font_size,
                    controls.opacity,
                    controls.lock_item,
                };
                for (property_controls) |control| try expectRectangleContained(controls.properties, control);
                for (controls.geometry_fields) |control| try expectRectangleContained(controls.properties, control);
                for (controls.foreground_swatches) |control| try expectRectangleContained(controls.properties, control);
                for (controls.background_swatches) |control| try expectRectangleContained(controls.properties, control);
                for (controls.align_buttons) |control| try expectRectangleContained(controls.properties, control);
                for (controls.distribute_buttons) |control| try expectRectangleContained(controls.properties, control);
                for (controls.layer_buttons) |control| try expectRectangleContained(controls.properties, control);
            }
            if (frame.chrome.left_visible)
                try expectRectangleContained(frame.chrome.left_dock, workspaceLayout(frame.viewport).sidebar);
        }
    }

    const compact = frameLayout(.{ .x = 0, .y = 0, .width = 900, .height = 600 }, true, false, .slides);
    try std.testing.expect(compact.viewport.slide_size.x >= 600);
    try std.testing.expect(compact.viewport.slide_size.y >= 330);
    const minimum_compact = frameLayout(.{ .x = 0, .y = 0, .width = 900, .height = 506 }, true, false, .slides);
    const minimum_workspace = workspaceLayout(minimum_compact.viewport);
    try std.testing.expect(slideCardCapacity(minimum_workspace) >= 1);
    try std.testing.expect(libraryRowCapacity(minimum_workspace) >= 1);
}

test "medium dock controls switch reserved space without overlaying the canvas" {
    var items = [_]slides.SlideItem{testItem(501, .textbox, 100, 100, 200, 80)};
    var studio: Studio = .{ .enabled = true, .active_dock = .slides };
    const content: rl.Rectangle = .{ .x = 0, .y = 0, .width = 1280, .height = 720 };
    const slides_frame = studio.layoutFrame(content);
    try std.testing.expect(slides_frame.chrome.left_visible);
    try std.testing.expect(!slides_frame.chrome.right_visible);

    const controls = uiLayout(slides_frame.viewport);
    _ = studio.update(&items, &.{}, slides_frame.viewport, .{
        .pointer_screen = rectangleCenter(controls.properties_dock_toggle),
        .pointer_pressed = true,
    });
    try std.testing.expectEqual(DockPanel.objects, studio.active_dock);
    try std.testing.expectEqual(InspectorPanel.objects, studio.inspector_panel);
    const objects_frame = studio.layoutFrame(content);
    try std.testing.expect(!objects_frame.chrome.left_visible);
    try std.testing.expect(objects_frame.chrome.right_visible);
    try std.testing.expect(!rectanglesOverlap(
        objects_frame.chrome.right_dock,
        .{
            .x = objects_frame.viewport.slide_top_left.x,
            .y = objects_frame.viewport.slide_top_left.y,
            .width = objects_frame.viewport.slide_size.x,
            .height = objects_frame.viewport.slide_size.y,
        },
    ));

    const inspector = objectsLayout(objects_frame.viewport);
    _ = studio.update(&items, &.{}, objects_frame.viewport, .{
        .pointer_screen = rectangleCenter(inspector.properties_tab),
        .pointer_pressed = true,
    });
    try std.testing.expectEqual(DockPanel.properties, studio.active_dock);
    try std.testing.expectEqual(InspectorPanel.properties, studio.inspector_panel);
    const properties_frame = studio.layoutFrame(content);

    const property_controls = uiLayout(properties_frame.viewport);
    _ = studio.update(&items, &.{}, properties_frame.viewport, .{
        .pointer_screen = rectangleCenter(property_controls.properties_dock_toggle),
        .pointer_pressed = true,
    });
    try std.testing.expectEqual(DockPanel.none, studio.active_dock);
    const canvas_frame = studio.layoutFrame(content);
    try std.testing.expect(!canvas_frame.chrome.left_visible);
    try std.testing.expect(!canvas_frame.chrome.right_visible);
    try std.testing.expect(canvas_frame.canvas_area.width > objects_frame.canvas_area.width);
    try std.testing.expect(canvas_frame.viewport.slide_size.x >= objects_frame.viewport.slide_size.x);
}

test "inline property layout stays legible and contained at compact minimum" {
    const frame = frameLayout(.{ .x = 0, .y = 0, .width = 900, .height = 506 }, true, false, .properties);
    const layout = uiLayout(frame.viewport);
    try std.testing.expect(frame.chrome.right_visible);
    const fields = [_]rl.Rectangle{
        layout.edit_text,
        layout.geometry_fields[0],
        layout.geometry_fields[1],
        layout.geometry_fields[2],
        layout.geometry_fields[3],
        layout.custom_foreground,
        layout.custom_background,
        layout.font_size,
        layout.opacity,
    };
    for (fields) |field| {
        try expectRectangleContained(layout.properties, field);
        try std.testing.expect(field.height >= 32);
        const reset = Studio.inlineResetRect(field);
        try expectRectangleContained(field, reset);
        try std.testing.expectEqual(@as(f32, 32), reset.width);
        try std.testing.expect(reset.height >= 32);
    }
    try std.testing.expect(layout.compact_properties);
    try std.testing.expect(!Studio.inlineTextIsMultiline(layout));
    const compact_value_font: i32 = 16;
    const compact_value_y = Studio.inlineFieldValueY(layout.edit_text, false, compact_value_font);
    try std.testing.expect(compact_value_y >= layout.edit_text.y);
    try std.testing.expect(compact_value_y + @as(f32, @floatFromInt(compact_value_font)) <=
        layout.edit_text.y + layout.edit_text.height);
    try expectRectangleContained(layout.properties, layout.inline_error);
    try std.testing.expect(layout.inline_error.height >= 14);
    for (layout.foreground_swatches) |swatch| try expectRectangleContained(layout.properties, swatch);
    for (layout.background_swatches) |swatch| try expectRectangleContained(layout.properties, swatch);
}

test "roomy inspector uses two-row geometry fields with representative values" {
    const frame = frameLayout(.{ .x = 0, .y = 0, .width = 1280, .height = 720 }, true, false, .properties);
    const layout = uiLayout(frame.viewport);
    try std.testing.expect(!layout.compact_properties);
    try std.testing.expectEqual(layout.geometry_fields[0].y, layout.geometry_fields[1].y);
    try std.testing.expect(layout.geometry_fields[2].y > layout.geometry_fields[0].y);
    try std.testing.expectEqual(layout.geometry_fields[2].y, layout.geometry_fields[3].y);

    const labels = [_][:0]const u8{ "X", "Y", "W", "H" };
    const samples = [_][:0]const u8{ "1920", "-1080", "123.456", "-987.654" };
    const studio: Studio = .{};
    for (layout.geometry_fields, labels, samples) |field, label, sample| {
        const reset = Studio.inlineResetRect(field);
        try expectRectangleContained(field, reset);
        try std.testing.expectEqual(@as(f32, 32), reset.width);
        const value_x = field.x + 7 + studio.measureUiText(label, 14) + 7;
        const available = field.x + field.width - value_x - 6;
        try std.testing.expect(studio.measureUiText(sample, 16) <= available);
    }
}

test "inline draw window keeps long ASCII caret inside compact scalar field" {
    const frame = frameLayout(.{ .x = 0, .y = 0, .width = 900, .height = 506 }, true, false, .properties);
    const layout = uiLayout(frame.viewport);
    try std.testing.expect(layout.compact_properties);
    var studio: Studio = .{};
    studio.inline_editor.active = true;
    studio.inline_editor.field = .x;
    var long_value: [256]u8 = undefined;
    @memset(&long_value, '9');
    try std.testing.expect(studio.setInlineBuffer(&long_value));
    const field = layout.geometry_fields[0];
    const value_x = field.x + 7 + studio.measureUiText("X", 14) + 7;
    const value_y = Studio.inlineFieldValueY(field, false, 16);
    const reset = Studio.inlineResetRect(field);
    const window = studio.inlineDrawWindow(field, value_x, value_y, 16, false, reset.width);
    try std.testing.expect(window.horizontal_offset > 0);
    try std.testing.expect(window.draw_x < value_x);
    try std.testing.expect(window.cursor_x >= value_x);
    try std.testing.expect(window.cursor_x + 2 <= reset.x - 6);
    try std.testing.expect(window.cursor_y >= field.y);
    try std.testing.expect(window.cursor_y + window.line_height <= field.y + field.height - 4);
}

test "inline draw window keeps multibyte tail and active multiline line visible" {
    const frame = frameLayout(.{ .x = 0, .y = 0, .width = 1280, .height = 720 }, true, false, .properties);
    const layout = uiLayout(frame.viewport);
    try std.testing.expect(!layout.compact_properties);
    try std.testing.expect(Studio.inlineTextIsMultiline(layout));
    var studio: Studio = .{};
    studio.inline_editor.active = true;
    studio.inline_editor.field = .text;
    var value: [512]u8 = undefined;
    const prefix = "first line\nsecond line\n";
    @memcpy(value[0..prefix.len], prefix);
    var value_len = prefix.len;
    for (0..100) |_| {
        @memcpy(value[value_len..][0..3], "€");
        value_len += 3;
    }
    try std.testing.expect(studio.setInlineBuffer(value[0..value_len]));
    const field = layout.edit_text;
    const value_x = field.x + 7;
    const value_y = Studio.inlineFieldValueY(field, true, 16);
    const window = studio.inlineDrawWindow(field, value_x, value_y, 16, true, 0);
    try std.testing.expect(window.display_start >= prefix.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(studio.inlineEditText()[window.display_start..]));
    try std.testing.expect(window.horizontal_offset > 0);
    try std.testing.expect(window.cursor_x >= value_x);
    try std.testing.expect(window.cursor_x + 2 <= field.x + field.width - 6);
    try std.testing.expect(window.cursor_y >= value_y);
    try std.testing.expect(window.cursor_y + window.line_height <= field.y + field.height - 4);
}

test "docked property click starts inline edit and captures shared ownership" {
    var items = [_]slides.SlideItem{testItem(640, .textbox, 100, 120, 300, 80)};
    items[0].id = "hero";
    items[0].source = .{ .scope = .slide_template, .line_offset = 10, .patchable = true };
    items[0].shared_template_values = .{
        .position = .{ .x = 20, .y = 30 },
        .size = .{ .x = 200, .y = 60 },
    };
    var studio: Studio = .{
        .enabled = true,
        .active_dock = .properties,
        .inspector_panel = .properties,
        .selected_identity = 640,
    };
    const frame = studio.layoutFrame(.{ .x = 0, .y = 0, .width = 1280, .height = 720 });
    const layout = uiLayout(frame.viewport);
    _ = studio.update(&items, &.{}, frame.viewport, .{
        .pointer_screen = rectangleCenter(layout.geometry_fields[0]),
        .pointer_pressed = true,
        .allow_shared_edit = true,
    });
    try std.testing.expect(studio.inlineEditActive());
    try std.testing.expectEqual(@as(?InlineField, .x), studio.inlineEditField());
    try std.testing.expectEqualStrings("20", studio.inlineEditText());
    try std.testing.expectEqual(EditScope.shared_template, studio.inline_editor.target.edit_scope);
    try std.testing.expect(studio.takeSemanticCommand() == null);
}

test "pristine inline click away reaches the intended palette action" {
    var items = [_]slides.SlideItem{testItem(648, .textbox, 100, 120, 300, 80)};
    items[0].source = .{ .scope = .direct, .line_offset = 10, .patchable = true };
    var studio: Studio = .{
        .enabled = true,
        .active_dock = .properties,
        .inspector_panel = .properties,
        .selected_identity = 648,
    };
    const frame = studio.layoutFrame(.{ .x = 0, .y = 0, .width = 1280, .height = 720 });
    const layout = uiLayout(frame.viewport);
    _ = studio.update(&items, &.{}, frame.viewport, .{
        .pointer_screen = rectangleCenter(layout.geometry_fields[0]),
        .pointer_pressed = true,
    });
    try std.testing.expect(studio.inlineEditActive());

    const cyan_index = @intFromEnum(PaletteColor.cyan);
    _ = studio.update(&items, &.{}, frame.viewport, .{
        .pointer_screen = rectangleCenter(layout.foreground_swatches[cyan_index]),
        .pointer_pressed = true,
    });
    try std.testing.expect(!studio.inlineEditActive());
    switch (studio.takeSemanticCommand().?) {
        .set_foreground => |command| {
            try std.testing.expectEqual(PaletteColor.cyan, command.color);
            try std.testing.expectEqual(@as(usize, 648), command.target.item_identity);
        },
        else => return error.UnexpectedSemanticCommand,
    }
}

test "dirty inline field switch preserves the clicked shared scope after accept" {
    var items = [_]slides.SlideItem{testItem(649, .textbox, 100, 120, 300, 80)};
    items[0].id = "hero";
    items[0].source = .{ .scope = .slide_template, .line_offset = 10, .patchable = true };
    items[0].shared_template_values = .{
        .position = .{ .x = 20, .y = 30 },
        .size = .{ .x = 200, .y = 60 },
    };
    var studio: Studio = .{
        .enabled = true,
        .active_dock = .properties,
        .inspector_panel = .properties,
        .selected_identity = 649,
    };
    const frame = studio.layoutFrame(.{ .x = 0, .y = 0, .width = 1280, .height = 720 });
    const layout = uiLayout(frame.viewport);
    _ = studio.update(&items, &.{}, frame.viewport, .{
        .pointer_screen = rectangleCenter(layout.geometry_fields[0]),
        .pointer_pressed = true,
    });
    try std.testing.expectEqual(EditScope.local_instance, studio.inline_editor.target.edit_scope);
    _ = studio.update(&items, &.{}, frame.viewport, .{ .select_all_pressed = true });
    var typed = FrameInput{};
    @memcpy(typed.inline_chars[0..3], "125");
    typed.inline_chars_len = 3;
    _ = studio.update(&items, &.{}, frame.viewport, typed);
    _ = studio.update(&items, &.{}, frame.viewport, .{
        .pointer_screen = rectangleCenter(layout.geometry_fields[1]),
        .pointer_pressed = true,
        .allow_shared_edit = true,
    });
    switch (studio.takeSemanticCommand().?) {
        .commit_inline => |commit| {
            try std.testing.expectEqual(InlineField.x, commit.field);
            try std.testing.expectEqual(EditScope.local_instance, commit.target.edit_scope);
        },
        else => return error.UnexpectedSemanticCommand,
    }
    items[0].position.x = 125;
    studio.acceptInlineCommit(.x);
    _ = studio.update(&items, &.{}, frame.viewport, .{});
    try std.testing.expectEqual(@as(?InlineField, .y), studio.inlineEditField());
    try std.testing.expectEqual(EditScope.shared_template, studio.inline_editor.target.edit_scope);
    try std.testing.expectEqualStrings("30", studio.inlineEditText());
}

test "local override reset targets one exact property and explains ownership" {
    var items = [_]slides.SlideItem{testItem(655, .textbox, 100, 120, 300, 80)};
    items[0].id = "hero";
    items[0].source = .{ .scope = .slide_template, .line_offset = 10, .patchable = true };
    items[0].instance_source = .{ .scope = .slide_instance_override, .line_offset = 40, .patchable = true };
    items[0].shared_template_values = .{ .position = .{ .x = 20, .y = 30 }, .size = .{ .x = 200, .y = 60 } };
    var studio: Studio = .{
        .enabled = true,
        .active_dock = .properties,
        .inspector_panel = .properties,
        .selected_identity = 655,
    };
    studio.setCompositionContext(.{
        .item_identity = 655,
        .selection_source = items[0].instance_source.?,
        .kind = .slide_template,
        .local_overrides = PropertyOverrideSet.fromFields(&.{ .x, .foreground }),
        .resettable_overrides = PropertyOverrideSet.fromFields(&.{.x}),
        .reset_target = .{
            .item_identity = 655,
            .source = items[0].instance_source.?,
            .edit_scope = .local_instance,
        },
        .detach_block = .dependent_structure,
    });
    var help_buffer: [192]u8 = undefined;
    const help = studio.compositionHelp(&items, &help_buffer).?;
    try std.testing.expect(std.mem.indexOf(u8, help, "Template instance") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "X, FG") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "R resets one") != null);

    const frame = studio.layoutFrame(.{ .x = 0, .y = 0, .width = 900, .height = 506 });
    const layout = uiLayout(frame.viewport);
    _ = studio.update(&items, &.{}, frame.viewport, .{
        .pointer_screen = rectangleCenter(Studio.inlineResetRect(layout.geometry_fields[0])),
        .pointer_pressed = true,
    });
    switch (studio.takeSemanticCommand().?) {
        .reset_local_override => |command| {
            try std.testing.expectEqual(InlineField.x, command.field);
            try std.testing.expectEqual(@as(usize, 655), command.target.item_identity);
            try std.testing.expectEqual(@as(usize, 40), command.target.source.line_offset);
            try std.testing.expectEqual(EditScope.local_instance, command.target.edit_scope);
        },
        else => return error.UnexpectedSemanticCommand,
    }

    _ = studio.update(&items, &.{}, frame.viewport, .{
        .pointer_screen = rectangleCenter(Studio.inlineResetRect(layout.custom_foreground)),
        .pointer_pressed = true,
    });
    try std.testing.expect(studio.takeSemanticCommand() == null);
    try std.testing.expectEqual(Notice.override_reset_unsupported, studio.notice);

    items[0].locked = true;
    _ = studio.update(&items, &.{}, frame.viewport, .{
        .pointer_screen = rectangleCenter(Studio.inlineResetRect(layout.geometry_fields[0])),
        .pointer_pressed = true,
    });
    try std.testing.expect(studio.takeSemanticCommand() == null);
    try std.testing.expectEqual(Notice.locked_item, studio.notice);
}

test "stale composition source cannot retarget an override reset" {
    var items = [_]slides.SlideItem{testItem(656, .textbox, 100, 120, 300, 80)};
    items[0].id = "hero";
    items[0].source = .{ .scope = .slide_template, .line_offset = 10, .patchable = true };
    items[0].instance_source = .{ .scope = .slide_instance_override, .line_offset = 40, .patchable = true };
    var studio: Studio = .{
        .enabled = true,
        .active_dock = .properties,
        .inspector_panel = .properties,
        .selected_identity = 656,
    };
    const stale_source: slides.SourceRef = .{ .scope = .slide_instance_override, .line_offset = 999, .patchable = true };
    studio.setCompositionContext(.{
        .item_identity = 656,
        .selection_source = stale_source,
        .kind = .slide_template,
        .local_overrides = PropertyOverrideSet.fromFields(&.{.x}),
        .resettable_overrides = PropertyOverrideSet.fromFields(&.{.x}),
        .reset_target = .{ .item_identity = 656, .source = stale_source, .edit_scope = .local_instance },
    });
    try std.testing.expect(studio.compositionContextForSelection(&items) == null);
    const frame = studio.layoutFrame(.{ .x = 0, .y = 0, .width = 900, .height = 506 });
    const field = uiLayout(frame.viewport).geometry_fields[0];
    _ = studio.update(&items, &.{}, frame.viewport, .{
        .pointer_screen = rectangleCenter(Studio.inlineResetRect(field)),
        .pointer_pressed = true,
    });
    try std.testing.expect(studio.takeSemanticCommand() == null);
    try std.testing.expectEqual(@as(?InlineField, .x), studio.inlineEditField());
}

test "detach requires an identity-safe integration capability" {
    var items = [_]slides.SlideItem{testItem(657, .textbox, 100, 120, 300, 80)};
    items[0].source = .{ .scope = .component_instance, .line_offset = 70, .patchable = true };
    var studio: Studio = .{
        .enabled = true,
        .active_dock = .properties,
        .inspector_panel = .properties,
        .selected_identity = 657,
    };
    const target: CommandTarget = .{ .item_identity = 657, .source = items[0].source };
    studio.setCompositionContext(.{
        .item_identity = 657,
        .selection_source = items[0].source,
        .kind = .component,
        .detach_target = target,
        .detach_block = .none,
    });
    const frame = studio.layoutFrame(.{ .x = 0, .y = 0, .width = 900, .height = 506 });
    const promote = uiLayout(frame.viewport).promote;
    _ = studio.update(&items, &.{}, frame.viewport, .{
        .pointer_screen = rectangleCenter(promote),
        .pointer_pressed = true,
    });
    switch (studio.takeSemanticCommand().?) {
        .detach_reusable_instance => |command| {
            try std.testing.expectEqual(ReusableInstanceKind.component, command.kind);
            try std.testing.expectEqual(@as(usize, 70), command.target.source.line_offset);
        },
        else => return error.UnexpectedSemanticCommand,
    }

    studio.setCompositionContext(.{
        .item_identity = 657,
        .selection_source = items[0].source,
        .kind = .component,
        .detach_block = .generated_source,
    });
    var help_buffer: [192]u8 = undefined;
    const help = studio.compositionHelp(&items, &help_buffer).?;
    try std.testing.expect(std.mem.indexOf(u8, help, "generated source is read-only") != null);
    _ = studio.update(&items, &.{}, frame.viewport, .{
        .pointer_screen = rectangleCenter(promote),
        .pointer_pressed = true,
    });
    try std.testing.expect(studio.takeSemanticCommand() == null);
    try std.testing.expectEqual(Notice.detach_instance_unsupported, studio.notice);
}

test "group reusable emits one atomic source-native promotion" {
    var items = [_]slides.SlideItem{
        testItem(658, .textbox, 100, 120, 300, 80),
        testItem(659, .img, 500, 120, 240, 160),
    };
    for (&items, 0..) |*item, index|
        item.source = .{ .scope = .direct, .line_offset = 10 + index * 10, .patchable = true };
    var studio: Studio = .{ .enabled = true, .active_dock = .properties, .inspector_panel = .properties };
    setTestSelection(&studio, &items, &.{ 658, 659 });
    const frame = studio.layoutFrame(.{ .x = 0, .y = 0, .width = 900, .height = 506 });
    _ = studio.update(&items, &.{}, frame.viewport, .{
        .pointer_screen = rectangleCenter(uiLayout(frame.viewport).promote),
        .pointer_pressed = true,
    });
    switch (studio.takeSemanticCommand().?) {
        .promote_items_to_group => |command| {
            try std.testing.expectEqual(@as(usize, 2), command.count);
            try std.testing.expectEqual(@as(usize, 10), command.targets[0].source.line_offset);
            try std.testing.expectEqual(@as(usize, 20), command.targets[1].source.line_offset);
        },
        else => return error.UnexpectedSemanticCommand,
    }
    try std.testing.expectEqual(Notice.none, studio.notice);
    var help_buffer: [192]u8 = undefined;
    try std.testing.expectEqualStrings(
        "Selected group · Reuse creates one source-native component",
        studio.compositionHelp(&items, &help_buffer).?,
    );
}

test "active inline editor consumes Studio toggle key and receives its text" {
    var items = [_]slides.SlideItem{testItem(650, .textbox, 100, 120, 300, 80)};
    items[0].text = "original";
    items[0].source = .{ .scope = .direct, .line_offset = 10, .patchable = true };
    var studio: Studio = .{
        .enabled = true,
        .active_dock = .properties,
        .inspector_panel = .properties,
        .selected_identity = 650,
    };
    const frame = studio.layoutFrame(.{ .x = 0, .y = 0, .width = 1280, .height = 720 });
    _ = studio.update(&items, &.{}, frame.viewport, .{
        .pointer_screen = rectangleCenter(uiLayout(frame.viewport).edit_text),
        .pointer_pressed = true,
    });
    var typed = FrameInput{ .toggle_pressed = true };
    typed.inline_chars[0] = 'e';
    typed.inline_chars_len = 1;
    _ = studio.update(&items, &.{}, frame.viewport, typed);
    try std.testing.expect(studio.enabled);
    try std.testing.expect(studio.inlineEditActive());
    try std.testing.expectEqualStrings("originale", studio.inlineEditText());
}

test "docked textbox click and Enter both open the inline text field" {
    var items = [_]slides.SlideItem{testItem(653, .textbox, 100, 120, 300, 80)};
    items[0].text = "editable";
    items[0].source = .{ .scope = .direct, .line_offset = 10, .patchable = true };
    var studio: Studio = .{
        .enabled = true,
        .active_dock = .properties,
        .inspector_panel = .properties,
        .selected_identity = 653,
    };
    const frame = studio.layoutFrame(.{ .x = 0, .y = 0, .width = 1280, .height = 720 });
    _ = studio.update(&items, &.{}, frame.viewport, .{
        .pointer_screen = rectangleCenter(uiLayout(frame.viewport).edit_text),
        .pointer_pressed = true,
    });
    try std.testing.expectEqual(@as(?InlineField, .text), studio.inlineEditField());
    try std.testing.expect(studio.takeSemanticCommand() == null);
    _ = studio.update(&items, &.{}, frame.viewport, .{ .cancel_pressed = true });

    _ = studio.update(&items, &.{}, frame.viewport, .{ .edit_text_pressed = true });
    try std.testing.expectEqual(@as(?InlineField, .text), studio.inlineEditField());
    try std.testing.expectEqualStrings("editable", studio.inlineEditText());
    try std.testing.expect(studio.takeSemanticCommand() == null);
}

test "docked Enter reveals Properties before opening an inline editor" {
    var items = [_]slides.SlideItem{testItem(654, .textbox, 100, 120, 300, 80)};
    items[0].text = "editable";
    items[0].source = .{ .scope = .direct, .line_offset = 10, .patchable = true };
    const summaries = [_]SlideSummary{.{ .index = 0 }};
    const workspace: Workspace = .{ .visible = true, .slides = &summaries, .current_slide = 0 };
    const content: rl.Rectangle = .{ .x = 0, .y = 0, .width = 900, .height = 506 };

    var slides_studio: Studio = .{
        .enabled = true,
        .active_dock = .slides,
        .inspector_panel = .properties,
        .selected_identity = 654,
    };
    const slides_frame = slides_studio.layoutFrame(content);
    try std.testing.expect(!slides_frame.chrome.right_visible);
    _ = slides_studio.updateWithWorkspace(&items, &.{}, slides_frame.viewport, workspace, .{ .edit_text_pressed = true });
    try std.testing.expect(!slides_studio.inlineEditActive());
    try std.testing.expectEqual(DockPanel.properties, slides_studio.active_dock);
    try std.testing.expectEqual(InspectorPanel.properties, slides_studio.inspector_panel);

    var objects_studio: Studio = .{
        .enabled = true,
        .active_dock = .objects,
        .inspector_panel = .objects,
        .selected_identity = 654,
    };
    const objects_frame = objects_studio.layoutFrame(content);
    try std.testing.expect(objects_frame.chrome.right_visible);
    _ = objects_studio.updateWithWorkspace(&items, &.{}, objects_frame.viewport, workspace, .{ .edit_text_pressed = true });
    try std.testing.expect(!objects_studio.inlineEditActive());
    try std.testing.expectEqual(DockPanel.properties, objects_studio.active_dock);
    try std.testing.expectEqual(InspectorPanel.properties, objects_studio.inspector_panel);

    var focus_studio: Studio = .{
        .enabled = true,
        .focus_canvas = true,
        .active_dock = .properties,
        .inspector_panel = .properties,
        .selected_identity = 654,
    };
    const focus_frame = focus_studio.layoutFrame(content);
    try std.testing.expect(!focus_frame.chrome.visible);
    _ = focus_studio.updateWithWorkspace(&items, &.{}, focus_frame.viewport, workspace, .{ .edit_text_pressed = true });
    try std.testing.expect(!focus_studio.inlineEditActive());
    try std.testing.expect(!focus_studio.focus_canvas);
    try std.testing.expectEqual(DockPanel.properties, focus_studio.active_dock);

    var properties_studio: Studio = .{
        .enabled = true,
        .active_dock = .properties,
        .inspector_panel = .properties,
        .selected_identity = 654,
    };
    const properties_frame = properties_studio.layoutFrame(content);
    try std.testing.expect(properties_frame.chrome.right_visible);
    _ = properties_studio.updateWithWorkspace(&items, &.{}, properties_frame.viewport, workspace, .{ .edit_text_pressed = true });
    try std.testing.expectEqual(@as(?InlineField, .text), properties_studio.inlineEditField());
}

test "inline Tab commits then advances only after accept and consumes Focus Canvas" {
    var items = [_]slides.SlideItem{testItem(641, .textbox, 100, 120, 300, 80)};
    items[0].source = .{ .scope = .direct, .line_offset = 10, .patchable = true };
    var studio: Studio = .{
        .enabled = true,
        .active_dock = .properties,
        .inspector_panel = .properties,
        .selected_identity = 641,
    };
    const frame = studio.layoutFrame(.{ .x = 0, .y = 0, .width = 1280, .height = 720 });
    const layout = uiLayout(frame.viewport);
    _ = studio.update(&items, &.{}, frame.viewport, .{
        .pointer_screen = rectangleCenter(layout.geometry_fields[0]),
        .pointer_pressed = true,
    });
    _ = studio.update(&items, &.{}, frame.viewport, .{ .select_all_pressed = true });
    var typed = FrameInput{};
    @memcpy(typed.inline_chars[0..3], "125");
    typed.inline_chars_len = 3;
    _ = studio.update(&items, &.{}, frame.viewport, typed);
    _ = studio.update(&items, &.{}, frame.viewport, .{ .toggle_focus_canvas_pressed = true });
    try std.testing.expectEqual(@as(?InlineField, .x), studio.inlineEditField());
    try std.testing.expect(!studio.focus_canvas);
    switch (studio.takeSemanticCommand().?) {
        .commit_inline => |commit| {
            try std.testing.expectEqual(InlineField.x, commit.field);
            try std.testing.expectEqualStrings("125", commit.value);
        },
        else => return error.UnexpectedSemanticCommand,
    }
    items[0].position.x = 125;
    studio.acceptInlineCommit(.x);
    _ = studio.update(&items, &.{}, frame.viewport, .{});
    try std.testing.expectEqual(@as(?InlineField, .y), studio.inlineEditField());
    try std.testing.expectEqualStrings("120", studio.inlineEditText());
    try std.testing.expect(studio.inline_editor.select_all);
}

test "pristine auto-sized field traverses without invalid write" {
    var items = [_]slides.SlideItem{testItem(642, .img, 100, 120, 0, 0)};
    items[0].source = .{ .scope = .direct, .line_offset = 10, .patchable = true };
    var studio: Studio = .{
        .enabled = true,
        .active_dock = .properties,
        .inspector_panel = .properties,
        .selected_identity = 642,
    };
    const frame = studio.layoutFrame(.{ .x = 0, .y = 0, .width = 1280, .height = 720 });
    const layout = uiLayout(frame.viewport);
    _ = studio.update(&items, &.{}, frame.viewport, .{
        .pointer_screen = rectangleCenter(layout.geometry_fields[2]),
        .pointer_pressed = true,
    });
    try std.testing.expectEqualStrings("0", studio.inlineEditText());
    _ = studio.update(&items, &.{}, frame.viewport, .{ .toggle_focus_canvas_pressed = true });
    try std.testing.expectEqual(@as(?InlineField, .height), studio.inlineEditField());
    try std.testing.expect(studio.takeSemanticCommand() == null);
    _ = studio.update(&items, &.{}, frame.viewport, .{
        .toggle_focus_canvas_pressed = true,
        .shift_down = true,
    });
    try std.testing.expectEqual(@as(?InlineField, .width), studio.inlineEditField());
    try std.testing.expect(!studio.focus_canvas);
}

test "invalid inline draft retains exact bytes focus and caret contract" {
    var items = [_]slides.SlideItem{testItem(643, .textbox, 100, 120, 300, 80)};
    items[0].source = .{ .scope = .direct, .line_offset = 10, .patchable = true };
    var studio: Studio = .{
        .enabled = true,
        .active_dock = .properties,
        .inspector_panel = .properties,
        .selected_identity = 643,
    };
    const frame = studio.layoutFrame(.{ .x = 0, .y = 0, .width = 1280, .height = 720 });
    const layout = uiLayout(frame.viewport);
    _ = studio.update(&items, &.{}, frame.viewport, .{
        .pointer_screen = rectangleCenter(layout.opacity),
        .pointer_pressed = true,
    });
    _ = studio.update(&items, &.{}, frame.viewport, .{ .select_all_pressed = true });
    var typed = FrameInput{};
    @memcpy(typed.inline_chars[0..4], "101%");
    typed.inline_chars_len = 4;
    _ = studio.update(&items, &.{}, frame.viewport, typed);
    const cursor_before = studio.inline_editor.cursor;
    _ = studio.update(&items, &.{}, frame.viewport, .{ .inline_submit_pressed = true });
    try std.testing.expect(studio.takeSemanticCommand() == null);
    try std.testing.expectEqual(@as(?InlineError, .invalid_opacity), studio.inlineEditError());
    try std.testing.expectEqualStrings("101%", studio.inlineEditText());
    try std.testing.expectEqual(cursor_before, studio.inline_editor.cursor);
    try std.testing.expect(studio.inlineEditActive());
}

test "inline text validation permits single-line markers and blocks multiline source bodies" {
    try std.testing.expect(Studio.inlineValueError(.text, "@slide") == null);
    try std.testing.expect(Studio.inlineValueError(.text, "#hashtag") == null);
    try std.testing.expectEqual(
        @as(?InlineError, .invalid_text),
        Studio.inlineValueError(.text, "Safe\n@slide"),
    );
    try std.testing.expectEqual(
        @as(?InlineError, .invalid_text),
        Studio.inlineValueError(.text, "Safe\n# comment"),
    );
}

test "oversized initial inline text is blocked except Escape" {
    var oversized: [max_inline_input_bytes + 1]u8 = undefined;
    @memset(&oversized, 'x');
    var items = [_]slides.SlideItem{testItem(644, .textbox, 100, 120, 300, 80)};
    items[0].text = &oversized;
    items[0].source = .{ .scope = .direct, .line_offset = 10, .patchable = true };
    var studio: Studio = .{
        .enabled = true,
        .active_dock = .properties,
        .inspector_panel = .properties,
        .selected_identity = 644,
    };
    const frame = studio.layoutFrame(.{ .x = 0, .y = 0, .width = 1280, .height = 720 });
    const layout = uiLayout(frame.viewport);
    _ = studio.update(&items, &.{}, frame.viewport, .{
        .pointer_screen = rectangleCenter(layout.edit_text),
        .pointer_pressed = true,
    });
    try std.testing.expect(studio.inlineEditActive());
    try std.testing.expect(studio.inline_editor.blocked_initial);
    try std.testing.expectEqual(@as(?InlineError, .too_long), studio.inlineEditError());
    var typed = FrameInput{};
    typed.inline_chars[0] = 'y';
    typed.inline_chars_len = 1;
    _ = studio.update(&items, &.{}, frame.viewport, typed);
    _ = studio.update(&items, &.{}, frame.viewport, .{ .inline_submit_pressed = true });
    try std.testing.expectEqualStrings("", studio.inlineEditText());
    try std.testing.expect(studio.takeSemanticCommand() == null);
    _ = studio.update(&items, &.{}, frame.viewport, .{ .cancel_pressed = true });
    try std.testing.expect(!studio.inlineEditActive());
}

test "oversized UTF-8 replacement preserves pristine inline selection" {
    var oversized: [max_inline_input_bytes + 1]u8 = undefined;
    for (0..oversized.len / 3) |index|
        @memcpy(oversized[index * 3 ..][0..3], "€");
    try std.testing.expect(std.unicode.utf8ValidateSlice(&oversized));

    var items = [_]slides.SlideItem{testItem(651, .textbox, 100, 120, 300, 80)};
    items[0].text = "unchanged";
    items[0].source = .{ .scope = .direct, .line_offset = 10, .patchable = true };
    var studio: Studio = .{
        .enabled = true,
        .active_dock = .properties,
        .inspector_panel = .properties,
        .selected_identity = 651,
    };
    const frame = studio.layoutFrame(.{ .x = 0, .y = 0, .width = 1280, .height = 720 });
    _ = studio.update(&items, &.{}, frame.viewport, .{
        .pointer_screen = rectangleCenter(uiLayout(frame.viewport).edit_text),
        .pointer_pressed = true,
    });
    _ = studio.update(&items, &.{}, frame.viewport, .{ .select_all_pressed = true });
    const cursor_before = studio.inline_editor.cursor;
    try std.testing.expect(!studio.inline_editor.dirty);
    try std.testing.expect(studio.inline_editor.select_all);

    _ = studio.update(&items, &.{}, frame.viewport, .{ .inline_paste = &oversized });
    try std.testing.expectEqualStrings("unchanged", studio.inlineEditText());
    try std.testing.expectEqual(cursor_before, studio.inline_editor.cursor);
    try std.testing.expect(studio.inline_editor.select_all);
    try std.testing.expect(!studio.inline_editor.dirty);
    try std.testing.expectEqual(@as(?InlineError, .too_long), studio.inlineEditError());
}

test "oversized UTF-8 replacement preserves dirty inline draft and selection" {
    var oversized: [max_inline_input_bytes + 1]u8 = undefined;
    for (0..oversized.len / 3) |index|
        @memcpy(oversized[index * 3 ..][0..3], "€");
    try std.testing.expect(std.unicode.utf8ValidateSlice(&oversized));

    var items = [_]slides.SlideItem{testItem(652, .textbox, 100, 120, 300, 80)};
    items[0].text = "opening";
    items[0].source = .{ .scope = .direct, .line_offset = 10, .patchable = true };
    var studio: Studio = .{
        .enabled = true,
        .active_dock = .properties,
        .inspector_panel = .properties,
        .selected_identity = 652,
    };
    const frame = studio.layoutFrame(.{ .x = 0, .y = 0, .width = 1280, .height = 720 });
    _ = studio.update(&items, &.{}, frame.viewport, .{
        .pointer_screen = rectangleCenter(uiLayout(frame.viewport).edit_text),
        .pointer_pressed = true,
    });
    _ = studio.update(&items, &.{}, frame.viewport, .{ .select_all_pressed = true });
    _ = studio.update(&items, &.{}, frame.viewport, .{ .inline_paste = "€" });
    try std.testing.expect(studio.inline_editor.dirty);
    _ = studio.update(&items, &.{}, frame.viewport, .{ .select_all_pressed = true });
    const cursor_before = studio.inline_editor.cursor;

    _ = studio.update(&items, &.{}, frame.viewport, .{ .inline_paste = &oversized });
    try std.testing.expectEqualStrings("€", studio.inlineEditText());
    try std.testing.expectEqual(cursor_before, studio.inline_editor.cursor);
    try std.testing.expect(studio.inline_editor.select_all);
    try std.testing.expect(studio.inline_editor.dirty);
    try std.testing.expectEqual(@as(?InlineError, .too_long), studio.inlineEditError());
}

test "inline multi-selection reports homogeneous and Mixed values but refuses edits" {
    var items = [_]slides.SlideItem{
        testItem(645, .textbox, 100, 120, 300, 80),
        testItem(646, .textbox, 100, 220, 300, 80),
    };
    items[0].source = .{ .scope = .direct, .line_offset = 10, .patchable = true };
    items[1].source = .{ .scope = .direct, .line_offset = 20, .patchable = true };
    var studio: Studio = .{ .enabled = true, .active_dock = .properties, .inspector_panel = .properties };
    setTestSelection(&studio, &items, &.{ 645, 646 });
    var scalar_buffer: [64]u8 = undefined;
    var color_buffer: [9]u8 = undefined;
    try std.testing.expectEqualStrings("100", studio.inlineDisplayValue(&items, &.{}, .x, &scalar_buffer, &color_buffer));
    try std.testing.expectEqualStrings("Mixed", studio.inlineDisplayValue(&items, &.{}, .y, &scalar_buffer, &color_buffer));
    try std.testing.expectEqualStrings("Mixed", studio.inlineDisplayValue(&items, &.{}, .text, &scalar_buffer, &color_buffer));
    const frame = studio.layoutFrame(.{ .x = 0, .y = 0, .width = 1280, .height = 720 });
    _ = studio.update(&items, &.{}, frame.viewport, .{
        .pointer_screen = rectangleCenter(uiLayout(frame.viewport).geometry_fields[0]),
        .pointer_pressed = true,
    });
    try std.testing.expect(!studio.inlineEditActive());
    try std.testing.expectEqual(Notice.multi_selection_property_unsupported, studio.notice);
}

test "Crowd text click and Enter share the truthful unavailable result" {
    var items = [_]slides.SlideItem{testItem(647, .crowd, 100, 120, 300, 80)};
    items[0].source = .{ .scope = .direct, .line_offset = 10, .patchable = true };
    items[0].crowd = .{ .kind = .join, .prompt = "Join this room" };
    var studio: Studio = .{
        .enabled = true,
        .active_dock = .properties,
        .inspector_panel = .properties,
        .selected_identity = 647,
    };
    const frame = studio.layoutFrame(.{ .x = 0, .y = 0, .width = 1280, .height = 720 });
    _ = studio.update(&items, &.{}, frame.viewport, .{
        .pointer_screen = rectangleCenter(uiLayout(frame.viewport).edit_text),
        .pointer_pressed = true,
    });
    try std.testing.expect(!studio.inlineEditActive());
    try std.testing.expectEqual(Notice.property_unavailable, studio.notice);
    try std.testing.expect(studio.takeSemanticCommand() == null);

    studio.notice = .none;
    _ = studio.update(&items, &.{}, frame.viewport, .{ .edit_text_pressed = true });
    try std.testing.expect(!studio.inlineEditActive());
    try std.testing.expectEqual(Notice.property_unavailable, studio.notice);
    try std.testing.expect(studio.takeSemanticCommand() == null);
}

test "objects inspector mirrors reverse paint order including background barriers" {
    const items = [_]slides.SlideItem{
        testItem(601, .textbox, 10, 10, 100, 40),
        testItem(602, .background, 0, 0, 1920, 1080),
        testItem(603, .img, 30, 30, 200, 100),
    };
    try std.testing.expectEqual(@as(usize, 3), objectItemCount(&items));
    try std.testing.expectEqual(@as(?usize, 2), objectIndexAtPaintOffset(&items, 0));
    try std.testing.expectEqual(@as(?usize, 1), objectIndexAtPaintOffset(&items, 1));
    try std.testing.expectEqual(@as(?usize, 0), objectIndexAtPaintOffset(&items, 2));
    try std.testing.expectEqual(@as(?usize, null), objectIndexAtPaintOffset(&items, 3));
}

test "objects inspector selects hidden zero opacity and locked rows by runtime identity" {
    var items = [_]slides.SlideItem{
        testItem(610, .background, 0, 0, 1920, 1080),
        testItem(611, .textbox, 10, 10, 100, 40),
        testItem(612, .textbox, 30, 30, 100, 40),
        testItem(613, .textbox, 50, 50, 100, 40),
    };
    items[1].visible = false;
    items[2].opacity = 0;
    items[3].locked = true;
    var studio: Studio = .{ .enabled = true, .active_dock = .objects };
    const frame = studio.layoutFrame(.{ .x = 0, .y = 0, .width = 1280, .height = 720 });
    const layout = objectsLayout(frame.viewport);
    const locked_row = objectRowRect(layout, 0).?;
    _ = studio.update(&items, &.{}, frame.viewport, .{
        .pointer_screen = .{ .x = locked_row.x + 72, .y = locked_row.y + locked_row.height / 2 },
        .pointer_pressed = true,
    });
    try std.testing.expectEqual(@as(?usize, 613), studio.selected_identity);
    try std.testing.expectEqual(@as(usize, 1), studio.selectionCount());

    const zero_row = objectRowRect(layout, 1).?;
    _ = studio.update(&items, &.{}, frame.viewport, .{
        .pointer_screen = .{ .x = zero_row.x + 72, .y = zero_row.y + zero_row.height / 2 },
        .pointer_pressed = true,
        .toggle_selection = true,
    });
    try std.testing.expectEqual(@as(?usize, 612), studio.selected_identity);
    try std.testing.expect(studio.isIdentitySelected(613));
    try std.testing.expectEqual(@as(usize, 2), studio.selectionCount());

    const hidden_row = objectRowRect(layout, 2).?;
    _ = studio.update(&items, &.{}, frame.viewport, .{
        .pointer_screen = .{ .x = hidden_row.x + 72, .y = hidden_row.y + hidden_row.height / 2 },
        .pointer_pressed = true,
        .toggle_selection = true,
    });
    _ = studio.update(&items, &.{}, frame.viewport, .{});
    try std.testing.expectEqual(@as(?usize, 611), studio.selected_identity);
    try std.testing.expect(studio.isIdentitySelected(612));
    try std.testing.expect(studio.isIdentitySelected(613));
    try std.testing.expectEqual(@as(usize, 3), studio.selectionCount());
}

test "objects row eye is exact refuses locked items and preserves zero opacity" {
    var items = [_]slides.SlideItem{
        testItem(620, .textbox, 10, 10, 100, 40),
        testItem(621, .textbox, 30, 30, 100, 40),
    };
    items[0].source = .{ .scope = .direct, .line_offset = 10, .patchable = true };
    items[1].source = .{ .scope = .direct, .line_offset = 20, .patchable = true };
    items[0].opacity = 0;
    var studio: Studio = .{ .enabled = true, .active_dock = .objects };
    setTestSelection(&studio, &items, &.{ 620, 621 });
    const frame = studio.layoutFrame(.{ .x = 0, .y = 0, .width = 1280, .height = 720 });
    const layout = objectsLayout(frame.viewport);
    const zero_row = objectRowRect(layout, 1).?;
    _ = studio.update(&items, &.{}, frame.viewport, .{
        .pointer_screen = rectangleCenter(objectVisibilityRect(zero_row)),
        .pointer_pressed = true,
    });
    switch (studio.takeSemanticCommand().?) {
        .set_visible => |command| {
            try std.testing.expectEqual(@as(usize, 1), command.count);
            try std.testing.expectEqual(@as(usize, 620), command.targets[0].item_identity);
            try std.testing.expect(!command.visible);
        },
        else => return error.UnexpectedSemanticCommand,
    }
    try std.testing.expectEqual(@as(usize, 2), studio.selectionCount());
    try std.testing.expectEqual(@as(f32, 0), items[0].opacity);

    items[1].locked = true;
    const locked_row = objectRowRect(layout, 0).?;
    _ = studio.update(&items, &.{}, frame.viewport, .{
        .pointer_screen = rectangleCenter(objectVisibilityRect(locked_row)),
        .pointer_pressed = true,
    });
    try std.testing.expect(studio.takeSemanticCommand() == null);
    try std.testing.expectEqual(Notice.locked_item, studio.notice);
    _ = studio.update(&items, &.{}, frame.viewport, .{
        .pointer_screen = rectangleCenter(objectLockRect(locked_row)),
        .pointer_pressed = true,
    });
    switch (studio.takeSemanticCommand().?) {
        .set_locked => |command| {
            try std.testing.expectEqual(@as(usize, 1), command.count);
            try std.testing.expectEqual(@as(usize, 621), command.targets[0].item_identity);
            try std.testing.expect(!command.locked);
        },
        else => return error.UnexpectedSemanticCommand,
    }
}

test "objects row Alt visibility toggles the shared authored layer" {
    var items = [_]slides.SlideItem{testItem(630, .textbox, 10, 10, 100, 40)};
    items[0].id = "hero";
    items[0].visible = false;
    items[0].source = .{ .scope = .slide_template, .line_offset = 10, .patchable = true };
    items[0].shared_template_values = .{
        .position = items[0].position,
        .size = items[0].size,
        .visible = true,
    };
    var studio: Studio = .{ .enabled = true, .active_dock = .objects };
    const frame = studio.layoutFrame(.{ .x = 0, .y = 0, .width = 1280, .height = 720 });
    const row = objectRowRect(objectsLayout(frame.viewport), 0).?;
    _ = studio.update(&items, &.{}, frame.viewport, .{
        .pointer_screen = rectangleCenter(objectVisibilityRect(row)),
        .pointer_pressed = true,
        .allow_shared_edit = true,
    });
    switch (studio.takeSemanticCommand().?) {
        .set_visible => |command| {
            try std.testing.expectEqual(EditScope.shared_template, command.targets[0].edit_scope);
            try std.testing.expect(!command.visible);
        },
        else => return error.UnexpectedSemanticCommand,
    }
    items[0].shared_template_values.?.locked = true;
    _ = studio.update(&items, &.{}, frame.viewport, .{
        .pointer_screen = rectangleCenter(objectLockRect(row)),
        .pointer_pressed = true,
        .allow_shared_edit = true,
    });
    switch (studio.takeSemanticCommand().?) {
        .set_locked => |command| {
            try std.testing.expectEqual(EditScope.shared_template, command.targets[0].edit_scope);
            try std.testing.expect(!command.locked);
        },
        else => return error.UnexpectedSemanticCommand,
    }
}

test "Focus Canvas hides chrome but preserves selection and restores with Tab" {
    var items = [_]slides.SlideItem{testItem(502, .textbox, 100, 100, 200, 80)};
    var studio: Studio = .{ .enabled = true, .selected_identity = 502, .active_dock = .properties };
    const content: rl.Rectangle = .{ .x = 0, .y = 0, .width = 1280, .height = 720 };
    const normal = studio.layoutFrame(content);

    _ = studio.update(&items, &.{}, normal.viewport, .{ .toggle_focus_canvas_pressed = true });
    try std.testing.expect(studio.focus_canvas);
    try std.testing.expectEqual(@as(?usize, 502), studio.selected_identity);
    const focused = studio.layoutFrame(content);
    try std.testing.expectEqual(FrameMode.focus, focused.mode);
    try std.testing.expect(!focused.chrome.visible);
    try std.testing.expectEqual(@as(f32, 0), uiLayout(focused.viewport).toolbar.width);
    try std.testing.expectEqual(@as(f32, 0), statusPanel(focused.viewport).height);
    try std.testing.expectEqual(@as(f32, 0), workspaceLayout(focused.viewport).sidebar.width);
    try std.testing.expect(focused.viewport.slide_size.x > normal.viewport.slide_size.x);

    _ = studio.update(&items, &.{}, focused.viewport, .{ .toggle_focus_canvas_pressed = true });
    try std.testing.expect(!studio.focus_canvas);
    try std.testing.expectEqual(@as(?usize, 502), studio.selected_identity);
    try std.testing.expect(studio.layoutFrame(content).chrome.visible);
}

test "canvas selection does not move a responsive dock during pointer gesture" {
    var items = [_]slides.SlideItem{testItem(503, .textbox, 100, 100, 200, 80)};
    items[0].source = .{ .scope = .direct, .line_number = 2, .line_offset = 20, .patchable = true };
    var studio: Studio = .{ .enabled = true, .active_dock = .slides };
    const frame = studio.layoutFrame(.{ .x = 0, .y = 0, .width = 1280, .height = 720 });
    const pointer = logicalToScreen(frame.viewport, .{ .x = 150, .y = 120 }).?;
    _ = studio.update(&items, &.{}, frame.viewport, .{
        .pointer_screen = pointer,
        .pointer_pressed = true,
        .pointer_down = true,
    });
    try std.testing.expectEqual(Interaction.moving, studio.interaction);
    try std.testing.expectEqual(DockPanel.slides, studio.active_dock);
}

test "single item rebind prefers unique IDs and falls back to every source layer" {
    const direct_source: slides.SourceRef = .{ .scope = .direct, .line_number = 4, .line_offset = 40, .patchable = true };
    var direct_items = [_]slides.SlideItem{testItem(401, .textbox, 100, 100, 200, 80)};
    direct_items[0].source = direct_source;
    var studio: Studio = .{ .enabled = true, .selected_identity = 99 };
    try std.testing.expect(studio.selectItemByIdOrSource(&direct_items, null, direct_source));
    try std.testing.expectEqual(@as(?usize, 401), studio.selected_identity);

    var identified = [_]slides.SlideItem{testItem(402, .textbox, 100, 100, 200, 80)};
    identified[0].id = "stable";
    identified[0].source = .{ .scope = .direct, .line_number = 7, .line_offset = 700, .patchable = true };
    try std.testing.expect(studio.selectItemByIdOrSource(&identified, "stable", direct_source));
    try std.testing.expectEqual(@as(?usize, 402), studio.selected_identity);

    const instance_source: slides.SourceRef = .{ .scope = .slide_instance_override, .line_number = 20, .line_offset = 200, .patchable = true };
    var customized = [_]slides.SlideItem{testItem(403, .textbox, 100, 100, 200, 80)};
    customized[0].source = .{ .scope = .slide_template, .line_number = 2, .line_offset = 20, .patchable = true };
    customized[0].instance_source = instance_source;
    try std.testing.expect(studio.selectItemByIdOrSource(&customized, null, instance_source));
    try std.testing.expectEqual(@as(?usize, 403), studio.selected_identity);

    var ambiguous = [_]slides.SlideItem{
        testItem(404, .textbox, 100, 100, 200, 80),
        testItem(405, .textbox, 400, 100, 200, 80),
    };
    ambiguous[0].source = direct_source;
    ambiguous[1].source = direct_source;
    try std.testing.expect(!studio.selectItemByIdOrSource(&ambiguous, null, direct_source));
    try std.testing.expectEqual(@as(?usize, null), studio.selected_identity);
}

fn rectangleCenter(rect: rl.Rectangle) rl.Vector2 {
    return .{ .x = rect.x + rect.width / 2, .y = rect.y + rect.height / 2 };
}

fn rectanglesOverlap(a: rl.Rectangle, b: rl.Rectangle) bool {
    return a.x < b.x + b.width and a.x + a.width > b.x and
        a.y < b.y + b.height and a.y + a.height > b.y;
}

fn expectRectangleContained(outer: rl.Rectangle, inner: rl.Rectangle) !void {
    if (inner.width <= 0 or inner.height <= 0) return;
    try std.testing.expect(inner.x >= outer.x and inner.y >= outer.y);
    try std.testing.expect(inner.x + inner.width <= outer.x + outer.width + 0.001);
    try std.testing.expect(inner.y + inner.height <= outer.y + outer.height + 0.001);
}
