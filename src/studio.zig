//! First vertical slice of rayslides' visual Studio mode.
//!
//! This module deliberately knows how to edit geometry, but not how to rewrite
//! `.sld` source. `SlideItem.source` supplies provenance and the integration
//! layer consumes the small `GeometryCommand` values returned by
//! `Studio.update`. During an interaction the logical item is mutated so the
//! selection/preview overlay follows the pointer immediately. On cancellation
//! the original geometry is restored.
//!
//! Studio operates on the base slide item list. Callers should pass
//! `slide.items.?.items`; editing a morph snapshot is a later, separate mode.

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
};

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

    pub fn fromRaylib() FrameInput {
        const shift = rl.isKeyDown(.left_shift) or rl.isKeyDown(.right_shift);
        const amount: f32 = if (shift) 10 else 1;
        var nudge: rl.Vector2 = .{ .x = 0, .y = 0 };
        if (keyPressedOrRepeated(.left)) nudge.x -= amount;
        if (keyPressedOrRepeated(.right)) nudge.x += amount;
        if (keyPressedOrRepeated(.up)) nudge.y -= amount;
        if (keyPressedOrRepeated(.down)) nudge.y += amount;
        return .{
            .toggle_pressed = rl.isKeyPressed(.e),
            .cancel_pressed = rl.isKeyPressed(.escape),
            .pointer_screen = rl.getMousePosition(),
            .pointer_pressed = rl.isMouseButtonPressed(.left),
            .pointer_down = rl.isMouseButtonDown(.left),
            .pointer_released = rl.isMouseButtonReleased(.left),
            .nudge = nudge,
            .allow_shared_edit = rl.isKeyDown(.left_alt) or rl.isKeyDown(.right_alt),
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
    }

    pub fn setNotice(self: *Studio, notice: Notice) void {
        self.notice = notice;
    }

    pub fn interactionActive(self: Studio) bool {
        return self.interaction != .idle;
    }

    pub fn cancelActiveInteraction(self: *Studio, items: []slides.SlideItem) void {
        if (self.interaction != .idle) self.cancelInteraction(items);
    }

    pub fn toggle(self: *Studio, items: []slides.SlideItem) void {
        if (self.enabled and self.interaction != .idle) self.cancelInteraction(items);
        self.enabled = !self.enabled;
        if (!self.enabled) {
            self.selected_identity = null;
            self.selected_source = null;
        }
    }

    pub fn disable(self: *Studio, items: []slides.SlideItem) void {
        if (self.interaction != .idle) self.cancelInteraction(items);
        self.enabled = false;
        self.selected_identity = null;
        self.selected_source = null;
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
        if (input.pointer_pressed or input.nudge.x != 0 or input.nudge.y != 0) self.notice = .none;
        if (input.toggle_pressed) {
            self.toggle(items);
            return null;
        }
        if (!self.enabled) return null;

        self.validateSelection(items, resolved_bounds);

        if (input.cancel_pressed) {
            if (self.interaction != .idle) {
                self.cancelInteraction(items);
            } else {
                self.disable(items);
            }
            return null;
        }

        const pointer_logical = screenToLogical(viewport, input.pointer_screen);

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
        if (item.source.scope == .none or !item.source.patchable) {
            self.notice = .generated_source_read_only;
            return false;
        }
        if (item.source.scope == .slide_template and !allow_shared_edit) {
            self.notice = .shared_template_locked;
            return false;
        }
        return true;
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
                    if (!items[index].source.patchable)
                        .{ .r = 255, .g = 112, .b = 112, .a = 255 }
                    else if (items[index].source.scope == .slide_template)
                        .{ .r = 247, .g = 164, .b = 29, .a = 255 }
                    else
                        .{ .r = 80, .g = 215, .b = 255, .a = 255 }
                else
                    .{ .r = 80, .g = 215, .b = 255, .a = 255 };
                rl.drawRectangleLinesEx(rect, 3, accent);
                if (selected_index) |index| {
                    if (items[index].source.patchable) {
                        if (self.resizeHandleRect(viewport, geometry)) |handle| {
                            rl.drawRectangleRec(handle, accent);
                            rl.drawRectangleLinesEx(handle, 1, .white);
                        }
                    }
                }
            }
        }

        self.drawStatus(items, resolved_bounds, viewport);
    }

    fn drawStatus(self: Studio, items: []const slides.SlideItem, resolved_bounds: []const ResolvedBounds, viewport: Viewport) void {
        const panel_height: f32 = 103;
        const panel: rl.Rectangle = .{
            .x = viewport.slide_top_left.x + 12,
            .y = viewport.slide_top_left.y + viewport.slide_size.y - panel_height - 12,
            .width = @max(340, @min(900, viewport.slide_size.x - 24)),
            .height = panel_height,
        };
        rl.drawRectangleRec(panel, .{ .r = 10, .g = 14, .b = 24, .a = 225 });
        rl.drawRectangleLinesEx(panel, 1, .{ .r = 80, .g = 215, .b = 255, .a = 180 });

        var status_buffer: [512]u8 = undefined;
        const status_text = if (self.selected_identity) |identity| selected: {
            const geometry = self.selectedGeometry(items, resolved_bounds) orelse break :selected "STUDIO · selection unavailable";
            const index = self.selectedIndex(items) orelse break :selected "STUDIO · selection unavailable";
            const source = items[index].source;
            break :selected std.fmt.bufPrintZ(
                &status_buffer,
                "STUDIO{s} · item #{d} · {s}, line {d} · x {d:.0} y {d:.0} w {d:.0} h {d:.0}",
                .{ if (self.dirty) " *" else "", identity, sourceScopeLabel(source.scope), source.line_number, geometry.position.x, geometry.position.y, geometry.size.x, geometry.size.y },
            ) catch "STUDIO · selected item";
        } else if (self.dirty) "STUDIO * · click an item to select it" else "STUDIO · click an item to select it";

        rl.drawText(status_text, @intFromFloat(panel.x + 12), @intFromFloat(panel.y + 9), 18, .white);
        rl.drawText(
            "E exit  ·  drag move  ·  corner resize  ·  arrows nudge  ·  Shift 10px  ·  Alt shared  ·  Esc cancel",
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

fn pointInRectangle(point: rl.Vector2, rect: rl.Rectangle) bool {
    return point.x >= rect.x and point.y >= rect.y and
        point.x <= rect.x + rect.width and point.y <= rect.y + rect.height;
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
    var items = [_]slides.SlideItem{testItem(11, .textbox, 10, 20, 100, 100)};
    const viewport: Viewport = .{
        .slide_top_left = .{ .x = 0, .y = 0 },
        .slide_size = default_logical_size,
    };
    var studio: Studio = .{ .enabled = true };
    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 20, .y = 30 },
        .pointer_pressed = true,
        .pointer_down = true,
    });
    _ = studio.update(&items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 70, .y = 80 },
        .pointer_down = true,
    });
    try expectVector(.{ .x = 60, .y = 70 }, items[0].position);

    _ = studio.update(&items, &.{}, viewport, .{ .toggle_pressed = true });
    try std.testing.expect(!studio.enabled);
    try std.testing.expectEqual(@as(?usize, null), studio.selected_identity);
    try std.testing.expectEqual(Interaction.idle, studio.interaction);
    try expectVector(.{ .x = 10, .y = 20 }, items[0].position);
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
    var old_items = [_]slides.SlideItem{testItem(30, .textbox, 20, 30, 100, 80)};
    old_items[0].source = .{ .scope = .direct, .line_number = 4, .line_offset = 123, .patchable = true };
    const viewport: Viewport = .{
        .slide_top_left = .{ .x = 0, .y = 0 },
        .slide_size = default_logical_size,
    };
    var studio: Studio = .{ .enabled = true };
    _ = studio.update(&old_items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 40, .y = 50 },
        .pointer_pressed = true,
        .pointer_down = true,
    });
    _ = studio.update(&old_items, &.{}, viewport, .{
        .pointer_screen = .{ .x = 40, .y = 50 },
        .pointer_released = true,
    });
    try std.testing.expectEqual(@as(?usize, 30), studio.selected_identity);

    var reparsed = [_]slides.SlideItem{testItem(91, .textbox, 20, 30, 100, 80)};
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
