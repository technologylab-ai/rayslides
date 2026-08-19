const std = @import("std");

/// Geometry values to write to one item directive. Width and height are left
/// untouched when they are null.
pub const GeometryPatch = struct {
    x: f32,
    y: f32,
    w: ?f32 = null,
    h: ?f32 = null,
};

/// Explicit position for a newly duplicated item. Duplication deliberately
/// leaves all sizing attributes untouched, including auto-image dimensions.
pub const DuplicateItemPlacement = struct {
    x: f32,
    y: f32,
};

/// Exact authored scene containing items that may be reordered or receive a
/// clipboard paste. Offsets always refer to the original source buffer.
pub const ItemSceneAnchor = union(enum) {
    base_slide: usize,
    morph_state: usize,
};

pub const LayerMove = enum {
    to_back,
    backward,
    forward,
    to_front,
};

/// One physically authored item to duplicate into an authored destination
/// scene. All offsets refer to the original source; caller order is retained.
pub const DuplicateItemTarget = struct {
    directive_offset: usize,
    new_id: []const u8,
    placement: DuplicateItemPlacement,
};

/// One atomic delete intention. Authored targets remove their complete source
/// unit and later morph dependencies. Hide targets append canonical `@hide`
/// mutations for inherited items in a template-instance base or morph state.
pub const DeleteItemTarget = union(enum) {
    authored: struct {
        directive_offset: usize,
        item_id: ?[]const u8,
    },
    hide: struct {
        item_id: []const u8,
    },
};

/// Owned clipboard source plus the exact component definition used by a
/// literal `@pop` instance. A direct `@box` has a null definition offset.
pub const CapturedItem = struct {
    snippet: []u8,
    component_definition_offset: ?usize = null,

    pub fn deinit(self: CapturedItem, allocator: std.mem.Allocator) void {
        allocator.free(self.snippet);
    }
};

/// One already-captured item to paste. The snippet is borrowed for the call;
/// the result owns its rewritten copy. Every caller-supplied ID must be unique
/// across both the destination document and this batch.
pub const CapturedPasteItem = struct {
    snippet: []const u8,
    component_definition_offset: ?usize = null,
    new_id: []const u8,
    placement: DuplicateItemPlacement,
};

/// One source operation in an atomic geometry rewrite. Every offset refers to
/// the original, unmodified source buffer. Insertions at the same offset are
/// emitted in caller order. Snippet bytes are borrowed only for the duration
/// of `applyGeometryEdits`; the returned source owns its copy.
pub const GeometrySourceEdit = union(enum) {
    patch: struct {
        directive_offset: usize,
        geometry: GeometryPatch,
    },
    insert: struct {
        insertion_offset: usize,
        snippet: []const u8,
    },
};

/// One literal attribute operation in an atomic rewrite. All offsets refer to
/// the original source. Patch slices and insertion snippets are borrowed only
/// for the duration of `applyLiteralEdits`.
pub const LiteralSourceEdit = union(enum) {
    patch: struct {
        directive_offset: usize,
        patches: []const LiteralAttributePatch,
    },
    insert: struct {
        insertion_offset: usize,
        snippet: []const u8,
    },
};

/// The caller owns `source` and must free it with the allocator passed to the
/// source-editing function that produced it.
pub const PatchResult = struct {
    source: []u8,
    byte_delta: isize,

    pub fn deinit(self: PatchResult, allocator: std.mem.Allocator) void {
        allocator.free(self.source);
    }
};

pub const PatchError = error{
    AmbiguousSlideTemplateLayout,
    AmbiguousSlideTemplateDependency,
    AmbiguousItemLayer,
    CannotDeleteOnlySlide,
    DuplicateAttribute,
    InvalidAttribute,
    InvalidColorLiteral,
    InvalidDirectiveOffset,
    InvalidDirectiveText,
    InvalidCoordinate,
    InvalidInsertionOffset,
    InvalidLiteralValue,
    InvalidMorphStateOffset,
    InvalidItemScene,
    InvalidReusableName,
    InvalidSlideOffset,
    InvalidSnippet,
    ItemIdCollision,
    NoAdjacentSlide,
    NoLayerChange,
    NotPromotableDirective,
    OverlappingSourceEdits,
    SlideTemplateNameCollision,
    SourceTooLarge,
    UnsupportedItemDuplication,
    UnsupportedClipboardItem,
    UnsupportedItemLayerMove,
    UnsupportedSlideTemplateOverride,
    UnsupportedSharedTemplateDeletion,
    UnsupportedSlidePromotion,
    UnsafeSlideGlobalDirective,
    UnsupportedBatchDeletion,
};

/// Exact physical bytes owned by one rendered slide.
///
/// For an explicitly authored slide, `start` is the `@slide` or `@popslide`
/// directive identified by `Slide.pos_in_editor`. For the sole implicit slide,
/// it is the first byte after an optional UTF-8 BOM. `end` is the next rendered
/// slide anchor or EOF, so base items, semantic morph states, comments, and
/// formatting travel together during organizer operations.
pub const LogicalSlideRange = struct {
    start: usize,
    end: usize,
    anchor_offset: usize,
    explicit_anchor: bool,
};

pub const SlideMoveDirection = enum {
    /// Put the selected slide immediately before its preceding slide.
    earlier,
    /// Put the selected slide immediately after its following slide.
    later,
};

/// One literal directive attribute to replace or insert. `text` is special:
/// as in the parser, its value owns the rest of the physical line and may
/// contain horizontal whitespace. Other values must be single tokens.
pub const LiteralAttributePatch = struct {
    key: []const u8,
    value: []const u8,
};

const ValuePatch = struct {
    key: []const u8,
    value: []const u8,
    value_span: ?Span = null,
};

const Span = struct {
    start: usize,
    end: usize,
};

const Edit = struct {
    start: usize,
    end: usize,
    replacement: []const u8,
};

/// Patch x/y and, when supplied, w/h on the directive beginning at
/// `directive_offset`.
///
/// Only value bytes belonging to existing geometry attributes are replaced.
/// Missing attributes are inserted before an inline `text=` attribute, whose
/// value owns the remainder of a rayslides directive. Every other byte in the
/// source, including line endings, comments, whitespace, and text content, is
/// copied unchanged.
pub fn patchGeometry(
    allocator: std.mem.Allocator,
    source: []const u8,
    directive_offset: usize,
    geometry: GeometryPatch,
) (std.mem.Allocator.Error || PatchError)!PatchResult {
    var x_buffer: [64]u8 = undefined;
    var y_buffer: [64]u8 = undefined;
    var w_buffer: [64]u8 = undefined;
    var h_buffer: [64]u8 = undefined;

    const x = try formatCoordinate(&x_buffer, geometry.x);
    const y = try formatCoordinate(&y_buffer, geometry.y);
    const w = if (geometry.w) |value| try formatCoordinate(&w_buffer, value) else null;
    const h = if (geometry.h) |value| try formatCoordinate(&h_buffer, value) else null;

    return patchGeometryText(allocator, source, directive_offset, .{
        .x = x,
        .y = y,
        .w = w,
        .h = h,
    });
}

/// Apply multiple already-resolved geometry source edits as one rewrite.
///
/// Every offset is interpreted against `source`, never against the result of a
/// preceding edit. The complete operation list is validated before any output
/// is produced, then applied from the greatest offset to the least so byte
/// length changes cannot invalidate later work. A patch and insertions may
/// share a directive offset: the patch is applied first and the snippets are
/// inserted before the patched directive. Multiple insertions at one offset
/// are emitted in their original caller order.
///
/// Insert offsets are intentionally low-level, for callers that have already
/// resolved a scoped base/state/template insertion anchor with this module's
/// boundary helpers. Each insertion is still required to be a literal,
/// single-directive snippet at a physical line boundary.
pub fn applyGeometryEdits(
    allocator: std.mem.Allocator,
    source: []const u8,
    edits: []const GeometrySourceEdit,
) (std.mem.Allocator.Error || PatchError)!PatchResult {
    try validateGeometrySourceEdits(source, edits);

    var order = try allocator.alloc(usize, edits.len);
    defer allocator.free(order);
    for (order, 0..) |*entry, index| entry.* = index;
    sortGeometrySourceEditOrder(edits, order);

    var working: ?[]u8 = try allocator.dupe(u8, source);
    errdefer if (working) |owned| allocator.free(owned);

    var group_start: usize = 0;
    while (group_start < order.len) {
        const offset = geometrySourceEditOffset(edits[order[group_start]]);
        var group_end = group_start + 1;
        while (group_end < order.len and geometrySourceEditOffset(edits[order[group_end]]) == offset) {
            group_end += 1;
        }

        var insertion_start = group_start;
        if (edits[order[group_start]] == .patch) {
            const patch = edits[order[group_start]].patch;
            const next = try patchGeometry(allocator, working.?, patch.directive_offset, patch.geometry);
            allocator.free(working.?);
            working = next.source;
            insertion_start += 1;
        }

        if (insertion_start < group_end) {
            const next = try insertGeometrySnippetGroupAt(
                allocator,
                working.?,
                offset,
                edits,
                order[insertion_start..group_end],
            );
            allocator.free(working.?);
            working = next.source;
        }
        group_start = group_end;
    }

    return .{
        .source = working.?,
        .byte_delta = try signedLengthDelta(working.?.len, source.len),
    };
}

/// Apply literal attribute patches and already-scoped directive insertions as
/// one source transaction. Every offset is resolved against the original
/// buffer. The complete batch is preflighted before allocation of the output;
/// edits then run from high offsets to low offsets. A patch and insertions may
/// share a directive start, in which case the patch is applied first and the
/// inserted snippets retain caller order before the patched directive.
pub fn applyLiteralEdits(
    allocator: std.mem.Allocator,
    source: []const u8,
    edits: []const LiteralSourceEdit,
) (std.mem.Allocator.Error || PatchError)!PatchResult {
    try validateLiteralSourceEdits(source, edits);

    var order = try allocator.alloc(usize, edits.len);
    defer allocator.free(order);
    for (order, 0..) |*entry, index| entry.* = index;
    sortLiteralSourceEditOrder(edits, order);

    var working: ?[]u8 = try allocator.dupe(u8, source);
    errdefer if (working) |owned| allocator.free(owned);

    var group_start: usize = 0;
    while (group_start < order.len) {
        const offset = literalSourceEditOffset(edits[order[group_start]]);
        var group_end = group_start + 1;
        while (group_end < order.len and literalSourceEditOffset(edits[order[group_end]]) == offset) {
            group_end += 1;
        }

        var insertion_start = group_start;
        if (edits[order[group_start]] == .patch) {
            const patch = edits[order[group_start]].patch;
            const next = try patchLiteralAttributes(
                allocator,
                working.?,
                patch.directive_offset,
                patch.patches,
            );
            allocator.free(working.?);
            working = next.source;
            insertion_start += 1;
        }
        if (insertion_start < group_end) {
            const next = try insertLiteralSnippetGroupAt(
                allocator,
                working.?,
                offset,
                edits,
                order[insertion_start..group_end],
            );
            allocator.free(working.?);
            working = next.source;
        }
        group_start = group_end;
    }

    return .{
        .source = working.?,
        .byte_delta = try signedLengthDelta(working.?.len, source.len),
    };
}

fn validateLiteralSourceEdits(source: []const u8, edits: []const LiteralSourceEdit) PatchError!void {
    for (edits, 0..) |edit, index| {
        switch (edit) {
            .patch => |patch| {
                const line = try directiveLine(source, patch.directive_offset);
                var affected_end = line.full_end;
                for (patch.patches, 0..) |attribute, attribute_index| {
                    try validateLiteralPatch(attribute);
                    for (patch.patches[0..attribute_index]) |previous| {
                        if (std.mem.eql(u8, attribute.key, previous.key)) return error.DuplicateAttribute;
                    }
                    if (std.mem.eql(u8, attribute.key, "text")) {
                        affected_end = itemBodyEndOffset(source, line.full_end);
                    }
                }
                for (edits[0..index]) |earlier| switch (earlier) {
                    .patch => |other| {
                        const other_line = try directiveLine(source, other.directive_offset);
                        var other_end = other_line.full_end;
                        for (other.patches) |attribute| {
                            if (std.mem.eql(u8, attribute.key, "text")) {
                                other_end = itemBodyEndOffset(source, other_line.full_end);
                            }
                        }
                        if (line.start < other_end and other_line.start < affected_end) {
                            return error.OverlappingSourceEdits;
                        }
                    },
                    .insert => |insert| {
                        if (insert.insertion_offset > line.start and insert.insertion_offset < affected_end) {
                            return error.OverlappingSourceEdits;
                        }
                    },
                };
                for (edits[index + 1 ..]) |later| switch (later) {
                    .insert => |insert| {
                        if (insert.insertion_offset > line.start and insert.insertion_offset < affected_end) {
                            return error.OverlappingSourceEdits;
                        }
                    },
                    .patch => {},
                };
            },
            .insert => |insert| {
                try validateSnippet(insert.snippet);
                if (!isPhysicalLineBoundary(source, insert.insertion_offset)) {
                    return error.InvalidInsertionOffset;
                }
            },
        }
    }
}

fn literalSourceEditOffset(edit: LiteralSourceEdit) usize {
    return switch (edit) {
        .patch => |patch| patch.directive_offset,
        .insert => |insert| insert.insertion_offset,
    };
}

fn literalSourceEditComesFirst(
    edits: []const LiteralSourceEdit,
    left_index: usize,
    right_index: usize,
) bool {
    const left_offset = literalSourceEditOffset(edits[left_index]);
    const right_offset = literalSourceEditOffset(edits[right_index]);
    if (left_offset != right_offset) return left_offset > right_offset;
    const left_is_patch = edits[left_index] == .patch;
    const right_is_patch = edits[right_index] == .patch;
    if (left_is_patch != right_is_patch) return left_is_patch;
    return left_index < right_index;
}

fn sortLiteralSourceEditOrder(edits: []const LiteralSourceEdit, order: []usize) void {
    var index: usize = 1;
    while (index < order.len) : (index += 1) {
        var moving = index;
        while (moving > 0 and literalSourceEditComesFirst(edits, order[moving], order[moving - 1])) : (moving -= 1) {
            std.mem.swap(usize, &order[moving], &order[moving - 1]);
        }
    }
}

fn insertLiteralSnippetGroupAt(
    allocator: std.mem.Allocator,
    source: []const u8,
    insertion_offset: usize,
    edits: []const LiteralSourceEdit,
    insertion_order: []const usize,
) (std.mem.Allocator.Error || PatchError)!PatchResult {
    if (!isPhysicalLineBoundary(source, insertion_offset)) return error.InvalidInsertionOffset;
    const newline = lineEndingNear(source, insertion_offset);
    const needs_separator = insertion_offset == source.len and
        source.len > 0 and
        !(source.len == utf8_bom.len and std.mem.eql(u8, source, utf8_bom)) and
        source[source.len - 1] != '\n';

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, source[0..insertion_offset]);
    if (needs_separator) try output.appendSlice(allocator, newline);
    for (insertion_order) |edit_index| {
        const snippet = edits[edit_index].insert.snippet;
        try appendNormalizedLines(allocator, &output, std.mem.trimEnd(u8, snippet, "\n"), newline);
        try output.appendSlice(allocator, newline);
    }
    try output.appendSlice(allocator, source[insertion_offset..]);
    return finishResult(allocator, &output, source.len);
}

fn validateGeometrySourceEdits(source: []const u8, edits: []const GeometrySourceEdit) PatchError!void {
    for (edits, 0..) |edit, index| {
        switch (edit) {
            .patch => |patch| {
                const line = try directiveLine(source, patch.directive_offset);
                try validateGeometryPatch(patch.geometry);

                // Two patches of the same physical directive would have
                // order-dependent attribute semantics. More generally, keep
                // this check range-based so any future multiline geometry
                // patch remains safe without changing the public contract.
                for (edits[0..index]) |earlier| switch (earlier) {
                    .patch => |other| {
                        const other_line = try directiveLine(source, other.directive_offset);
                        if (line.start < other_line.full_end and other_line.start < line.full_end) {
                            return error.OverlappingSourceEdits;
                        }
                    },
                    .insert => {},
                };
            },
            .insert => |insert| {
                try validateSnippet(insert.snippet);
                if (!isPhysicalLineBoundary(source, insert.insertion_offset)) {
                    return error.InvalidInsertionOffset;
                }
            },
        }
    }
}

fn validateGeometryPatch(geometry: GeometryPatch) PatchError!void {
    var x_buffer: [64]u8 = undefined;
    var y_buffer: [64]u8 = undefined;
    var w_buffer: [64]u8 = undefined;
    var h_buffer: [64]u8 = undefined;
    _ = try formatCoordinate(&x_buffer, geometry.x);
    _ = try formatCoordinate(&y_buffer, geometry.y);
    if (geometry.w) |value| _ = try formatCoordinate(&w_buffer, value);
    if (geometry.h) |value| _ = try formatCoordinate(&h_buffer, value);
}

fn geometrySourceEditOffset(edit: GeometrySourceEdit) usize {
    return switch (edit) {
        .patch => |patch| patch.directive_offset,
        .insert => |insert| insert.insertion_offset,
    };
}

fn geometrySourceEditComesFirst(
    edits: []const GeometrySourceEdit,
    left_index: usize,
    right_index: usize,
) bool {
    const left_offset = geometrySourceEditOffset(edits[left_index]);
    const right_offset = geometrySourceEditOffset(edits[right_index]);
    if (left_offset != right_offset) return left_offset > right_offset;

    const left_is_patch = edits[left_index] == .patch;
    const right_is_patch = edits[right_index] == .patch;
    if (left_is_patch != right_is_patch) return left_is_patch;
    return left_index < right_index;
}

fn sortGeometrySourceEditOrder(edits: []const GeometrySourceEdit, order: []usize) void {
    var index: usize = 1;
    while (index < order.len) : (index += 1) {
        var moving = index;
        while (moving > 0 and geometrySourceEditComesFirst(edits, order[moving], order[moving - 1])) : (moving -= 1) {
            std.mem.swap(usize, &order[moving], &order[moving - 1]);
        }
    }
}

fn insertGeometrySnippetGroupAt(
    allocator: std.mem.Allocator,
    source: []const u8,
    insertion_offset: usize,
    edits: []const GeometrySourceEdit,
    insertion_order: []const usize,
) (std.mem.Allocator.Error || PatchError)!PatchResult {
    // Validation happened against the original source. Descending application
    // guarantees lower offsets stay fixed, including this physical boundary.
    if (!isPhysicalLineBoundary(source, insertion_offset)) return error.InvalidInsertionOffset;

    const newline = lineEndingNear(source, insertion_offset);
    const needs_separator = insertion_offset == source.len and
        source.len > 0 and
        !(source.len == utf8_bom.len and std.mem.eql(u8, source, utf8_bom)) and
        source[source.len - 1] != '\n';

    var extra_capacity = newline.len;
    for (insertion_order) |edit_index| {
        const snippet = edits[edit_index].insert.snippet;
        extra_capacity = std.math.add(usize, extra_capacity, snippet.len) catch return error.SourceTooLarge;
        extra_capacity = std.math.add(usize, extra_capacity, newline.len) catch return error.SourceTooLarge;
    }
    const total_capacity = std.math.add(usize, source.len, extra_capacity) catch return error.SourceTooLarge;

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try output.ensureTotalCapacity(allocator, total_capacity);
    try output.appendSlice(allocator, source[0..insertion_offset]);
    if (needs_separator) try output.appendSlice(allocator, newline);
    for (insertion_order) |edit_index| {
        const snippet = edits[edit_index].insert.snippet;
        try appendNormalizedLines(allocator, &output, std.mem.trimEnd(u8, snippet, "\n"), newline);
        try output.appendSlice(allocator, newline);
    }
    try output.appendSlice(allocator, source[insertion_offset..]);
    return finishResult(allocator, &output, source.len);
}

const GeometryTextPatch = struct {
    x: []const u8,
    y: []const u8,
    w: ?[]const u8 = null,
    h: ?[]const u8 = null,
};

fn patchGeometryText(
    allocator: std.mem.Allocator,
    source: []const u8,
    directive_offset: usize,
    geometry: GeometryTextPatch,
) (std.mem.Allocator.Error || PatchError)!PatchResult {
    const line = try directiveLine(source, directive_offset);

    var requested: [4]ValuePatch = undefined;
    var requested_count: usize = 0;
    requested[requested_count] = .{ .key = "x", .value = geometry.x };
    requested_count += 1;
    requested[requested_count] = .{ .key = "y", .value = geometry.y };
    requested_count += 1;
    if (geometry.w) |value| {
        requested[requested_count] = .{ .key = "w", .value = value };
        requested_count += 1;
    }
    if (geometry.h) |value| {
        requested[requested_count] = .{ .key = "h", .value = value };
        requested_count += 1;
    }

    // Rayslides tokenizes directive attributes on spaces/tabs. Once `text=` is
    // encountered, its complete remainder is content rather than attributes.
    var insertion_point = trimHorizontalWhitespaceEnd(source, line.content_end, line.start);
    var insertion_precedes_text = false;
    var cursor = line.start;
    while (cursor < line.content_end) {
        while (cursor < line.content_end and isHorizontalWhitespace(source[cursor])) : (cursor += 1) {}
        if (cursor == line.content_end) break;

        const token_start = cursor;
        while (cursor < line.content_end and !isHorizontalWhitespace(source[cursor])) : (cursor += 1) {}
        const token_end = cursor;
        const token = source[token_start..token_end];

        const equals_index = std.mem.indexOfScalar(u8, token, '=') orelse continue;
        const key = token[0..equals_index];
        if (std.mem.eql(u8, key, "text")) {
            insertion_point = token_start;
            insertion_precedes_text = true;
            break;
        }

        for (requested[0..requested_count]) |*item| {
            if (std.mem.eql(u8, key, item.key)) {
                // Attribute duplicates are malformed but possible. The parser
                // uses the final value, so patch the effective occurrence.
                item.value_span = .{
                    .start = token_start + equals_index + 1,
                    .end = token_end,
                };
                break;
            }
        }
    }

    var insertion = std.ArrayList(u8).empty;
    defer insertion.deinit(allocator);

    var missing_count: usize = 0;
    for (requested[0..requested_count]) |item| {
        if (item.value_span == null) missing_count += 1;
    }
    if (missing_count > 0) {
        if (insertion_point == line.start or !isHorizontalWhitespace(source[insertion_point - 1])) {
            try insertion.append(allocator, ' ');
        }

        var emitted: usize = 0;
        for (requested[0..requested_count]) |item| {
            if (item.value_span != null) continue;
            if (emitted > 0) try insertion.append(allocator, ' ');
            try insertion.appendSlice(allocator, item.key);
            try insertion.append(allocator, '=');
            try insertion.appendSlice(allocator, item.value);
            emitted += 1;
        }

        if (insertion_precedes_text) try insertion.append(allocator, ' ');
    }

    var edits: [5]Edit = undefined;
    var edit_count: usize = 0;
    for (requested[0..requested_count]) |item| {
        if (item.value_span) |span| {
            edits[edit_count] = .{
                .start = span.start,
                .end = span.end,
                .replacement = item.value,
            };
            edit_count += 1;
        }
    }
    if (insertion.items.len > 0) {
        edits[edit_count] = .{
            .start = insertion_point,
            .end = insertion_point,
            .replacement = insertion.items,
        };
        edit_count += 1;
    }
    sortEditsByPosition(edits[0..edit_count]);

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try output.ensureTotalCapacity(allocator, source.len);

    var copied_until: usize = 0;
    for (edits[0..edit_count]) |edit| {
        try output.appendSlice(allocator, source[copied_until..edit.start]);
        try output.appendSlice(allocator, edit.replacement);
        copied_until = edit.end;
    }
    try output.appendSlice(allocator, source[copied_until..]);

    const byte_delta = try signedLengthDelta(output.items.len, source.len);
    const patched = try output.toOwnedSlice(allocator);
    return .{
        .source = patched,
        .byte_delta = byte_delta,
    };
}

/// Insert one complete directive immediately before `insertion_offset`.
///
/// The offset must be a physical line boundary (or EOF). The inserted line
/// uses the surrounding source's line ending. At EOF, a missing separator is
/// supplied before the directive. `directive` must begin with `@` and must not
/// contain a line ending.
pub fn insertDirectiveAt(
    allocator: std.mem.Allocator,
    source: []const u8,
    insertion_offset: usize,
    directive: []const u8,
) (std.mem.Allocator.Error || PatchError)!PatchResult {
    try validateDirectiveText(directive);
    return insertSnippetAt(allocator, source, insertion_offset, directive);
}

/// Insert a directive plus optional following body-text lines at an explicit
/// physical line boundary. LF separators in `snippet` are normalized to the
/// source's local line ending. Additional directive lines are rejected: one
/// call inserts exactly one item/state mutation and its body.
pub fn insertSnippetAt(
    allocator: std.mem.Allocator,
    source: []const u8,
    insertion_offset: usize,
    snippet: []const u8,
) (std.mem.Allocator.Error || PatchError)!PatchResult {
    try validateSnippet(snippet);
    if (!isPhysicalLineBoundary(source, insertion_offset)) return error.InvalidInsertionOffset;

    const newline = lineEndingNear(source, insertion_offset);
    const needs_separator = insertion_offset == source.len and
        source.len > 0 and
        !(source.len == utf8_bom.len and std.mem.eql(u8, source, utf8_bom)) and
        source[source.len - 1] != '\n';

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try output.ensureTotalCapacity(allocator, source.len + snippet.len + newline.len * 2);
    try output.appendSlice(allocator, source[0..insertion_offset]);
    if (needs_separator) try output.appendSlice(allocator, newline);
    try appendNormalizedLines(allocator, &output, std.mem.trimEnd(u8, snippet, "\n"), newline);
    try output.appendSlice(allocator, newline);
    try output.appendSlice(allocator, source[insertion_offset..]);

    return finishResult(allocator, &output, source.len);
}

/// Append a new item to the selected slide's base scene.
///
/// `slide_offset` identifies the physical `@slide` or `@popslide` line that
/// created the slide. The directive is inserted before the first morph state;
/// otherwise it is inserted before the next slide boundary, or at EOF. This
/// gives a newly added item topmost base-scene z-order without accidentally
/// creating it inside a morph state.
pub fn insertDirective(
    allocator: std.mem.Allocator,
    source: []const u8,
    slide_offset: usize,
    directive: []const u8,
) (std.mem.Allocator.Error || PatchError)!PatchResult {
    try validateDirectiveText(directive);
    return insertSnippet(allocator, source, slide_offset, directive);
}

/// Append a directive and optional body lines to a selected slide's base
/// scene. See `slideItemInsertionOffset` for its exact placement semantics.
pub fn insertSnippet(
    allocator: std.mem.Allocator,
    source: []const u8,
    slide_offset: usize,
    snippet: []const u8,
) (std.mem.Allocator.Error || PatchError)!PatchResult {
    const insertion_offset = try slideItemInsertionOffset(source, slide_offset);
    return insertSnippetAt(allocator, source, insertion_offset, snippet);
}

/// Add an instance-local mutation to the base scene of a slide created by a
/// literal `@popslide` directive.
///
/// Unlike `insertSnippet`, this deliberately refuses direct `@slide` and
/// implicit-slide anchors: writing `@set` there would be an ordinary base
/// mutation, not an override of a reusable slide template. The snippet must
/// begin with a literal `@set`, `@show`, or `@hide` and a literal item ID. It is
/// inserted after all existing base content and before the first morph state,
/// so the parser can apply it to the cloned template items without moving it
/// into a semantic-morph snapshot.
pub fn insertSlideTemplateOverride(
    allocator: std.mem.Allocator,
    source: []const u8,
    slide_offset: usize,
    snippet: []const u8,
) (std.mem.Allocator.Error || PatchError)!PatchResult {
    const insertion_offset = try slideTemplateOverrideInsertionOffset(source, slide_offset, snippet);
    return insertSnippetAt(allocator, source, insertion_offset, snippet);
}

/// Resolve and validate the source anchor for a new instance-local override
/// without changing the source. This lets callers include the returned offset
/// in `applyGeometryEdits` while retaining the same literal `@popslide` and
/// `@set`/`@show`/`@hide` safety checks as `insertSlideTemplateOverride`.
pub fn slideTemplateOverrideInsertionOffset(
    source: []const u8,
    slide_offset: usize,
    snippet: []const u8,
) PatchError!usize {
    _ = try slideTemplateInstanceBaseRegion(source, slide_offset);
    try validateSlideTemplateOverrideSnippet(snippet);
    return slideItemInsertionOffset(source, slide_offset);
}

/// Validate an existing instance-local override as an atomic geometry patch
/// target without changing the source. This rejects stale provenance, wrong
/// slide/state ownership, dynamic targets, and mismatched item IDs.
pub fn validateSlideTemplateOverrideGeometryTarget(
    source: []const u8,
    slide_offset: usize,
    override_offset: usize,
    item_id: []const u8,
) PatchError!void {
    return validateSlideTemplateOverrideTarget(source, slide_offset, override_offset, item_id);
}

/// Validate an existing parser-effective instance-local mutation as a generic
/// literal attribute target. This is the scoped preflight counterpart used by
/// atomic literal batches: a stale or forged offset cannot escape the selected
/// literal @popslide base region or target another item.
pub fn validateSlideTemplateOverrideTarget(
    source: []const u8,
    slide_offset: usize,
    override_offset: usize,
    item_id: []const u8,
) PatchError!void {
    return validateSlideTemplateOverrideLocation(source, slide_offset, override_offset, item_id);
}

/// Validate the parser-effective mutation for one item inside one exact morph
/// state. Callers planning an atomic literal batch pass the state that owns the
/// item's state_source, preventing a stale offset from patching another state,
/// slide, or target ID.
pub fn validateMorphMutationTarget(
    source: []const u8,
    state_offset: usize,
    mutation_offset: usize,
    item_id: []const u8,
) PatchError!void {
    if (!isLiteralItemId(item_id)) return error.InvalidLiteralValue;
    const state = directiveLine(source, state_offset) catch return error.InvalidMorphStateOffset;
    if (!isMorphStateDirective(directiveName(source[state.start..state.content_end]))) {
        return error.InvalidMorphStateOffset;
    }
    const scene = resolveDirectMorphItemScene(source, state_offset) catch
        return error.InvalidMorphStateOffset;
    const state_end = scene.end;
    if (mutation_offset < state.full_end or mutation_offset >= state_end) {
        return error.InvalidMorphStateOffset;
    }
    const mutation = directiveLine(source, mutation_offset) catch return error.InvalidMorphStateOffset;
    const text = source[mutation.start..mutation.content_end];
    const name = directiveName(text);
    if (!isMorphMutationDirective(name) or hasPotentialLetExpansion(text)) {
        return error.InvalidMorphStateOffset;
    }
    const target = validateSlideTemplateOverrideDirectiveLine(text) catch
        return error.InvalidMorphStateOffset;
    if (!std.mem.eql(u8, target, item_id)) return error.InvalidMorphStateOffset;

    var latest: ?usize = null;
    var cursor = state.full_end;
    while (cursor < state_end) {
        const line = physicalLineAt(source, cursor);
        const candidate = source[cursor..line.content_end];
        // A substituted physical line may become a later mutation or may
        // rewrite its target. Without evaluating the complete @let history we
        // cannot prove that this offset is parser-effective.
        if (hasPotentialLetExpansion(candidate)) return error.InvalidMorphStateOffset;
        if (cursor < line.content_end and source[cursor] == '@') {
            const candidate_name = directiveName(candidate);
            if (isMorphMutationDirective(candidate_name)) {
                const candidate_target = validateSlideTemplateOverrideDirectiveLine(candidate) catch
                    return error.InvalidMorphStateOffset;
                if (std.mem.eql(u8, candidate_target, item_id)) latest = cursor;
            }
        }
        cursor = line.full_end;
    }
    if (latest != mutation_offset) return error.InvalidMorphStateOffset;
}

/// Patch attributes on an already-authored instance-local override.
///
/// `override_offset` must identify a literal `@set`/`@show`/`@hide` for
/// `item_id` in the selected `@popslide` instance's base region. In particular,
/// a similarly named mutation in a later morph state or another slide cannot
/// be patched accidentally. `id=` remains read-only; callers must also honor
/// the parser provenance's `patchable` flag before editing an existing line.
pub fn patchSlideTemplateOverrideAttributes(
    allocator: std.mem.Allocator,
    source: []const u8,
    slide_offset: usize,
    override_offset: usize,
    item_id: []const u8,
    patches: []const LiteralAttributePatch,
) (std.mem.Allocator.Error || PatchError)!PatchResult {
    try validateSlideTemplateOverrideLocation(source, slide_offset, override_offset, item_id);
    for (patches) |patch| {
        if (std.mem.eql(u8, patch.key, "id")) return error.InvalidLiteralValue;
    }
    return patchLiteralAttributes(allocator, source, override_offset, patches);
}

/// Patch geometry on an already-authored instance-local override. This is the
/// scoped counterpart to `patchGeometry`: it prevents a stale provenance
/// offset from editing a mutation in a morph state or another slide.
pub fn patchSlideTemplateOverrideGeometry(
    allocator: std.mem.Allocator,
    source: []const u8,
    slide_offset: usize,
    override_offset: usize,
    item_id: []const u8,
    geometry: GeometryPatch,
) (std.mem.Allocator.Error || PatchError)!PatchResult {
    try validateSlideTemplateOverrideGeometryTarget(source, slide_offset, override_offset, item_id);
    return patchGeometry(allocator, source, override_offset, geometry);
}

/// Patch semantic text on an already-authored instance-local override while
/// retaining the same source-scope checks as attribute edits.
pub fn patchSlideTemplateOverrideText(
    allocator: std.mem.Allocator,
    source: []const u8,
    slide_offset: usize,
    override_offset: usize,
    item_id: []const u8,
    text_value: []const u8,
) (std.mem.Allocator.Error || PatchError)!PatchResult {
    try validateSlideTemplateOverrideLocation(source, slide_offset, override_offset, item_id);
    return patchItemText(allocator, source, override_offset, text_value);
}

/// Add a literal, instance-local fill override for one inherited template
/// item. The emitted syntax is the parser's canonical `@set <id> bg=<value>`;
/// `background_literal` must be `#rrggbbaa` or `none`.
pub fn insertSlideTemplateBackgroundOverride(
    allocator: std.mem.Allocator,
    source: []const u8,
    slide_offset: usize,
    item_id: []const u8,
    background_literal: []const u8,
) (std.mem.Allocator.Error || PatchError)!PatchResult {
    try validateLiteralPatch(.{ .key = "bg", .value = background_literal });
    if (!isLiteralItemId(item_id)) return error.InvalidLiteralValue;

    const directive = try std.fmt.allocPrint(
        allocator,
        "@set {s} bg={s}",
        .{ item_id, background_literal },
    );
    defer allocator.free(directive);
    return insertSlideTemplateOverride(allocator, source, slide_offset, directive);
}

/// Patch the fill on the parser-effective instance-local mutation for an
/// inherited template item. The same slide, target-ID, and latest-mutation
/// provenance checks as every scoped template override remain in force.
pub fn patchSlideTemplateBackgroundOverride(
    allocator: std.mem.Allocator,
    source: []const u8,
    slide_offset: usize,
    override_offset: usize,
    item_id: []const u8,
    background_literal: []const u8,
) (std.mem.Allocator.Error || PatchError)!PatchResult {
    const patches = [_]LiteralAttributePatch{.{
        .key = "bg",
        .value = background_literal,
    }};
    return patchSlideTemplateOverrideAttributes(
        allocator,
        source,
        slide_offset,
        override_offset,
        item_id,
        &patches,
    );
}

/// Find the end of a slide's base scene: its first morph state, next slide
/// boundary, or EOF. This is where ordinary new items should be inserted.
pub fn slideItemInsertionOffset(source: []const u8, slide_offset: usize) PatchError!usize {
    return findSlideBoundary(source, slide_offset, true);
}

/// Find the boundary after the complete selected logical slide, including all
/// morph states. Inserting `@slide` here creates a new slide immediately after
/// the selected one instead of appending it to the whole file.
pub fn slideEndOffset(source: []const u8, slide_offset: usize) PatchError!usize {
    return findSlideBoundary(source, slide_offset, false);
}

/// Insert a blank rendered slide immediately after the selected slide.
///
/// A legacy implicit one-slide document has no physical anchor to insert
/// after. In that case this operation makes both slides explicit in one
/// atomic rewrite, preserving the original as slide one. Implicit documents
/// containing reusable definitions remain conservatively unsupported because
/// moving their definition boundary could change parser scoping.
pub fn insertBlankSlideAfter(
    allocator: std.mem.Allocator,
    source: []const u8,
    slide_offset: usize,
) (std.mem.Allocator.Error || PatchError)!PatchResult {
    const layout = try inspectSlideLayout(source);
    const range = try logicalSlideRange(source, slide_offset);
    if (range.explicit_anchor) {
        return insertDirectiveAt(allocator, source, range.end, "@slide");
    }
    if (layout.has_component_definition or layout.has_slide_template_definition) {
        return error.AmbiguousSlideTemplateLayout;
    }

    const newline = lineEndingNear(source, range.end);
    const payload = source[range.start..range.end];
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try output.ensureTotalCapacity(allocator, source.len + "@slide".len * 2 + newline.len * 3);
    try output.appendSlice(allocator, source[0..range.start]);
    try output.appendSlice(allocator, "@slide");
    try output.appendSlice(allocator, newline);
    try output.appendSlice(allocator, payload);
    if (payload.len > 0 and payload[payload.len - 1] != '\n') try output.appendSlice(allocator, newline);
    try output.appendSlice(allocator, "@slide");
    try output.appendSlice(allocator, newline);
    return finishResult(allocator, &output, source.len);
}

/// Resolve a parser `Slide.pos_in_editor` anchor to the exact physical source
/// range owned by that rendered slide.
///
/// Slide-template definitions before the first rendered slide remain outside
/// every range. A `@pushslide` after rendered-slide authoring has begun makes
/// raw range manipulation ambiguous: depending on parser state it can capture
/// rather than emit the apparent slide. Such layouts are rejected instead of
/// risking a semantic rewrite.
pub fn logicalSlideRange(source: []const u8, slide_offset: usize) PatchError!LogicalSlideRange {
    const layout = try inspectSlideLayout(source);
    if (layout.explicit_count == 0) {
        if (slide_offset != 0) return error.InvalidSlideOffset;
        return .{
            .start = sourceStart(source),
            .end = source.len,
            .anchor_offset = 0,
            .explicit_anchor = false,
        };
    }

    const anchor = directiveLine(source, slide_offset) catch return error.InvalidSlideOffset;
    const name = directiveName(source[anchor.start..anchor.content_end]);
    if (!isRenderedSlideAnchor(name)) return error.InvalidSlideOffset;

    var cursor = anchor.full_end;
    while (cursor < source.len) {
        const line = physicalLineAt(source, cursor);
        if (cursor < line.content_end and source[cursor] == '@') {
            const candidate = directiveName(source[cursor..line.content_end]);
            if (isRenderedSlideAnchor(candidate)) {
                return .{
                    .start = anchor.start,
                    .end = cursor,
                    .anchor_offset = anchor.start,
                    .explicit_anchor = true,
                };
            }
            // inspectSlideLayout already rejects this after the first anchor,
            // but retain the local guard so this routine stays conservative if
            // layout inspection is later relaxed.
            if (std.mem.eql(u8, candidate, "@pushslide")) {
                return error.AmbiguousSlideTemplateLayout;
            }
        }
        cursor = line.full_end;
    }
    return .{
        .start = anchor.start,
        .end = source.len,
        .anchor_offset = anchor.start,
        .explicit_anchor = true,
    };
}

/// Duplicate the complete selected slide immediately after itself.
///
/// An implicit one-slide document is first made explicit by adding `@slide`
/// anchors to the original and the copy. The optional BOM is never duplicated.
pub fn duplicateSlide(
    allocator: std.mem.Allocator,
    source: []const u8,
    slide_offset: usize,
) (std.mem.Allocator.Error || PatchError)!PatchResult {
    const layout = try inspectSlideLayout(source);
    const range = try logicalSlideRange(source, slide_offset);
    const newline = lineEndingNear(source, range.end);

    if (!range.explicit_anchor) {
        // Duplicating a whole implicit document would also duplicate reusable
        // definitions. A repeated @push can change which definition later
        // @pop instances resolve to, while @pushslide can mean the parser's
        // default final slide is not the apparent source block at all.
        if (layout.has_component_definition or layout.has_slide_template_definition) {
            return error.AmbiguousSlideTemplateLayout;
        }
        const payload = source[range.start..range.end];
        var output = std.ArrayList(u8).empty;
        errdefer output.deinit(allocator);
        try output.ensureTotalCapacity(allocator, source.len * 2 + newline.len * 4 + "@slide".len * 2);
        try output.appendSlice(allocator, source[0..range.start]);
        try output.appendSlice(allocator, "@slide");
        try output.appendSlice(allocator, newline);
        try output.appendSlice(allocator, payload);
        if (payload.len > 0 and payload[payload.len - 1] != '\n') try output.appendSlice(allocator, newline);
        try output.appendSlice(allocator, "@slide");
        try output.appendSlice(allocator, newline);
        try output.appendSlice(allocator, payload);
        return finishResult(allocator, &output, source.len);
    }

    try validateStructuralSlideRange(source, range);

    const selected = source[range.start..range.end];
    var insertion = std.ArrayList(u8).empty;
    defer insertion.deinit(allocator);
    if (range.end == source.len and selected.len > 0 and source[range.end - 1] != '\n') {
        try insertion.appendSlice(allocator, newline);
    }
    try insertion.appendSlice(allocator, selected);
    return replaceRange(allocator, source, range.end, range.end, insertion.items);
}

/// Delete one complete rendered slide while guaranteeing that the result still
/// contains at least one slide. Deleting the sole implicit or explicit slide
/// returns `error.CannotDeleteOnlySlide` without producing source.
pub fn deleteSlide(
    allocator: std.mem.Allocator,
    source: []const u8,
    slide_offset: usize,
) (std.mem.Allocator.Error || PatchError)!PatchResult {
    const layout = try inspectSlideLayout(source);
    const range = try logicalSlideRange(source, slide_offset);
    if (!range.explicit_anchor or layout.explicit_count <= 1) return error.CannotDeleteOnlySlide;
    try validateStructuralSlideRange(source, range);
    return replaceRange(allocator, source, range.start, range.end, "");
}

/// Move the complete selected slide across one adjacent rendered slide.
/// Template definitions before the deck remain fixed and byte-identical.
pub fn moveSlide(
    allocator: std.mem.Allocator,
    source: []const u8,
    slide_offset: usize,
    direction: SlideMoveDirection,
) (std.mem.Allocator.Error || PatchError)!PatchResult {
    const selected = try logicalSlideRange(source, slide_offset);
    if (!selected.explicit_anchor) return error.NoAdjacentSlide;

    switch (direction) {
        .earlier => {
            const previous_start = previousRenderedSlideAnchor(source, selected.start) orelse
                return error.NoAdjacentSlide;
            const previous = try logicalSlideRange(source, previous_start);
            if (previous.end != selected.start) return error.AmbiguousSlideTemplateLayout;
            try validateStructuralSlideRange(source, previous);
            try validateStructuralSlideRange(source, selected);

            var replacement = std.ArrayList(u8).empty;
            defer replacement.deinit(allocator);
            try appendSwappedSlideRanges(allocator, &replacement, source, previous, selected);
            return replaceRange(allocator, source, previous.start, selected.end, replacement.items);
        },
        .later => {
            if (selected.end == source.len) return error.NoAdjacentSlide;
            const following = try logicalSlideRange(source, selected.end);
            try validateStructuralSlideRange(source, selected);
            try validateStructuralSlideRange(source, following);

            var replacement = std.ArrayList(u8).empty;
            defer replacement.deinit(allocator);
            try appendSwappedSlideRanges(allocator, &replacement, source, selected, following);
            return replaceRange(allocator, source, selected.start, following.end, replacement.items);
        },
    }
}

/// Promote one complete rendered slide to a named slide template and leave an
/// equivalent `@popslide` instance at the selected deck position.
///
/// Rayslides' `@pushslide` syntax captures the slide authored immediately
/// before it. For an explicit deck the captured base scene is therefore moved
/// ahead of the first rendered anchor, where templates can be declared without
/// emitting an extra blank slide. The selected `@slide` becomes `@popslide`;
/// semantic morph states stay at the instance so they remain independently
/// editable and are not captured by the template.
///
/// This operation is deliberately conservative. It rejects name collisions,
/// template-backed instances, slide-level item defaults, dynamic directives,
/// dangling animations, dirty pre-deck parser state, and global/context
/// directives whose relocation could alter parsing. The returned source is
/// only produced when the physical rewrite is semantically local.
pub fn promoteSlideToTemplate(
    allocator: std.mem.Allocator,
    source: []const u8,
    slide_offset: usize,
    name: []const u8,
) (std.mem.Allocator.Error || PatchError)!PatchResult {
    if (!isReusableName(name)) return error.InvalidReusableName;
    if (hasSlideTemplateNamed(source, name)) return error.SlideTemplateNameCollision;

    const layout = try inspectSlideLayout(source);
    const selected = try logicalSlideRange(source, slide_offset);
    if (!selected.explicit_anchor) {
        try validateStructuralSlideRange(source, selected);
        const base_end = firstMorphStateOffset(source, selected.start, selected.end) orelse selected.end;
        try validatePromotableBase(source, selected.start, base_end);
        return promoteImplicitSlideToTemplate(allocator, source, base_end, name);
    }
    std.debug.assert(layout.explicit_count > 0);

    const anchor = try directiveLine(source, selected.anchor_offset);
    const anchor_name = directiveName(source[anchor.start..anchor.content_end]);
    // Flattening a @popslide instance would require expanding and dependency-
    // resolving the earlier template. Keep the source primitive exact instead.
    if (!std.mem.eql(u8, anchor_name, "@slide")) return error.UnsupportedSlidePromotion;
    try validatePromotableSlideAnchor(source, anchor);
    try validateStructuralSlideRange(source, selected);

    const template_insertion = firstRenderedSlideAnchor(source) orelse
        return error.InvalidSlideOffset;
    try validateTemplateInsertionContext(source, template_insertion);
    if (template_insertion < selected.start) {
        try validateStructuralSlideRange(source, .{
            .start = template_insertion,
            .end = selected.start,
            .anchor_offset = template_insertion,
            .explicit_anchor = true,
        });
        try validateNoDynamicDirectives(source, template_insertion, selected.start);
        try validateNoDanglingAnimation(source, template_insertion, selected.start);
    }

    const base_start = anchor.full_end;
    const base_end = firstMorphStateOffset(source, base_start, selected.end) orelse selected.end;
    try validatePromotableBase(source, base_start, base_end);
    return promoteExplicitSlideToTemplate(
        allocator,
        source,
        selected,
        anchor,
        template_insertion,
        base_start,
        base_end,
        name,
    );
}

/// Find the boundary after one morph state: the next `@state(morph)`, next
/// slide boundary, or EOF. Insert state-local `@set`, `@hide`, or born-item
/// directives at the returned physical line offset.
pub fn morphStateEndOffset(source: []const u8, state_directive_offset: usize) PatchError!usize {
    const state_line = directiveLine(source, state_directive_offset) catch return error.InvalidMorphStateOffset;
    const state_name = directiveName(source[state_line.start..state_line.content_end]);
    if (!isMorphStateDirective(state_name)) return error.InvalidMorphStateOffset;

    var cursor = state_line.full_end;
    while (cursor < source.len) {
        const line = physicalLineAt(source, cursor);
        if (cursor < line.content_end and source[cursor] == '@') {
            const name = directiveName(source[cursor..line.content_end]);
            if (isMorphStateDirective(name) or
                std.mem.eql(u8, name, "@slide") or
                std.mem.eql(u8, name, "@popslide") or
                std.mem.eql(u8, name, "@pushslide"))
            {
                return cursor;
            }
        }
        cursor = line.full_end;
    }
    return source.len;
}

/// Promote one direct `@box` item to a reusable component in place.
///
/// The directive token becomes `@push name`; all attributes, inline text, body
/// text, comments, whitespace, BOM, and line endings remain untouched. A
/// matching `@pop name` is inserted after the item's complete body/comment
/// region so the slide still contains an instance at the same z-order.
pub fn promoteItemToReusable(
    allocator: std.mem.Allocator,
    source: []const u8,
    directive_offset: usize,
    name: []const u8,
) (std.mem.Allocator.Error || PatchError)!PatchResult {
    if (!isReusableName(name)) return error.InvalidReusableName;
    const line = try directiveLine(source, directive_offset);
    const old_name = directiveName(source[line.start..line.content_end]);
    if (!std.mem.eql(u8, old_name, "@box")) return error.NotPromotableDirective;

    const item_end = itemBodyEndOffset(source, line.full_end);
    const newline = lineEndingNear(source, item_end);

    var id_spans = std.ArrayList(Span).empty;
    defer id_spans.deinit(allocator);
    var effective_id: ?[]const u8 = null;
    var cursor = line.start + old_name.len;
    while (cursor < line.content_end) {
        while (cursor < line.content_end and isHorizontalWhitespace(source[cursor])) : (cursor += 1) {}
        if (cursor == line.content_end) break;
        const token_start = cursor;
        while (cursor < line.content_end and !isHorizontalWhitespace(source[cursor])) : (cursor += 1) {}
        const token = source[token_start..cursor];
        const equals_index = std.mem.indexOfScalar(u8, token, '=') orelse continue;
        const key = token[0..equals_index];
        if (std.mem.eql(u8, key, "text")) break;
        if (!std.mem.eql(u8, key, "id")) continue;

        try id_spans.append(allocator, .{ .start = token_start, .end = cursor });
        const raw_value = token[equals_index + 1 ..];
        const parser_value_end = std.mem.indexOfScalar(u8, raw_value, '=') orelse raw_value.len;
        if (parser_value_end > 0) effective_id = raw_value[0..parser_value_end];
    }

    var push_name = std.ArrayList(u8).empty;
    defer push_name.deinit(allocator);
    try push_name.appendSlice(allocator, "@push ");
    try push_name.appendSlice(allocator, name);

    var pop_line = std.ArrayList(u8).empty;
    defer pop_line.deinit(allocator);
    if (item_end == source.len and source.len > 0 and source[source.len - 1] != '\n') {
        try pop_line.appendSlice(allocator, newline);
    }
    try pop_line.appendSlice(allocator, "@pop ");
    try pop_line.appendSlice(allocator, name);
    if (effective_id) |id| {
        try pop_line.appendSlice(allocator, " id=");
        try pop_line.appendSlice(allocator, id);
    }
    try pop_line.appendSlice(allocator, newline);

    var edits = std.ArrayList(Edit).empty;
    defer edits.deinit(allocator);
    try edits.append(allocator, .{
        .start = line.start,
        .end = line.start + old_name.len,
        .replacement = push_name.items,
    });
    for (id_spans.items) |span| {
        try edits.append(allocator, .{
            .start = span.start,
            .end = span.end,
            .replacement = "",
        });
    }
    try edits.append(allocator, .{
        .start = item_end,
        .end = item_end,
        .replacement = pop_line.items,
    });
    sortEditsByPosition(edits.items);
    return applyEdits(allocator, source, edits.items);
}

/// Duplicate one complete authored item immediately after itself and give the
/// clone a new literal ID.
///
/// The clone owns the same pending `@anim` decorators, directive formatting,
/// body text, comments, and blank lines as the original. Only its effective
/// `id=` value is replaced or inserted. Direct `@box` items and literal `@pop`
/// component instances are supported. `@crowd` is refused because rayslides
/// permits only one crowd item per slide; `@bg` is refused because the parser
/// forces every background to (0,0), defeating the clone placement contract.
/// Structural directives, morph mutations, generated `@let` source, and ID
/// collisions are rejected without producing a partial rewrite. The clone's
/// x/y are written explicitly in the same atomic edit; w/h/scale/ratio remain
/// byte-identical to the original.
pub fn duplicateItem(
    allocator: std.mem.Allocator,
    source: []const u8,
    directive_offset: usize,
    new_id: []const u8,
    placement: DuplicateItemPlacement,
) (std.mem.Allocator.Error || PatchError)!PatchResult {
    if (!isLiteralItemId(new_id)) return error.InvalidLiteralValue;
    if (hasLiteralItemId(source, new_id)) return error.ItemIdCollision;

    const line = directiveLine(source, directive_offset) catch
        return error.UnsupportedItemDuplication;
    const line_text = source[line.start..line.content_end];
    const name = directiveName(line_text);
    if (!(std.mem.eql(u8, name, "@box") or std.mem.eql(u8, name, "@pop"))) {
        return error.UnsupportedItemDuplication;
    }
    if (std.mem.eql(u8, name, "@pop")) {
        const component_name = directiveContextName(line_text, name.len) orelse
            return error.UnsupportedItemDuplication;
        if (!isReusableName(component_name)) return error.UnsupportedItemDuplication;
    }

    const owned_start = try itemOwnedAnimationStart(source, line.start);
    const item_end = itemBodyEndOffset(source, line.full_end);
    const owned_source = source[owned_start..item_end];
    if (hasPotentialLetExpansion(owned_source)) return error.UnsupportedItemDuplication;

    var x_buffer: [64]u8 = undefined;
    var y_buffer: [64]u8 = undefined;
    const x = try formatCoordinate(&x_buffer, placement.x);
    const y = try formatCoordinate(&y_buffer, placement.y);
    const clone_patches = [_]LiteralAttributePatch{
        .{ .key = "id", .value = new_id },
        .{ .key = "x", .value = x },
        .{ .key = "y", .value = y },
    };
    const cloned = try patchLiteralAttributes(
        allocator,
        owned_source,
        line.start - owned_start,
        &clone_patches,
    );
    defer cloned.deinit(allocator);

    const newline = lineEndingNear(source, item_end);
    var insertion = std.ArrayList(u8).empty;
    defer insertion.deinit(allocator);
    if (item_end == source.len and item_end > sourceStart(source) and source[item_end - 1] != '\n') {
        try insertion.appendSlice(allocator, newline);
    }
    try insertion.appendSlice(allocator, cloned.source);
    return replaceRange(allocator, source, item_end, item_end, insertion.items);
}

/// Reorder one or more complete authored items inside one exact direct base or
/// current morph-state scene. Selected relative order is stable. Any source
/// directive between renderer-adjacent item units is a hard barrier, so a move
/// can never cross a mutation, global default, slide, template, or state edge.
pub fn reorderItemsLayer(
    allocator: std.mem.Allocator,
    source: []const u8,
    scene: ItemSceneAnchor,
    directive_offsets: []const usize,
    move: LayerMove,
) (std.mem.Allocator.Error || PatchError)!PatchResult {
    const range = try resolveItemScene(source, scene);
    var units = std.ArrayList(ItemSourceUnit).empty;
    defer units.deinit(allocator);
    try collectSceneItemUnits(allocator, source, range, &units);
    if (directive_offsets.len == 0 or units.items.len == 0) return error.UnsupportedItemLayerMove;

    var selected = try allocator.alloc(bool, units.items.len);
    defer allocator.free(selected);
    @memset(selected, false);
    for (directive_offsets, 0..) |offset, offset_index| {
        for (directive_offsets[0..offset_index]) |previous| {
            if (previous == offset) return error.AmbiguousItemLayer;
        }
        var found: ?usize = null;
        for (units.items, 0..) |unit, unit_index| {
            if (unit.directive_offset == offset) {
                found = unit_index;
                break;
            }
        }
        if (found == null) return error.UnsupportedItemLayerMove;
        selected[found.?] = true;
    }

    // Physical adjacency defines independently reorderable layer segments.
    // Comments/body/blank lines already belong to the preceding unit, while
    // pending @anim belongs to the next. A mutation or pinned @bg therefore
    // creates a gap that no selected batch may cross.
    var segment_start = selectedIndex(selected) orelse return error.UnsupportedItemLayerMove;
    while (segment_start > 0 and units.items[segment_start - 1].end == units.items[segment_start].start) {
        segment_start -= 1;
    }
    var segment_end = segment_start + 1;
    while (segment_end < units.items.len and units.items[segment_end - 1].end == units.items[segment_end].start) {
        segment_end += 1;
    }
    for (selected, 0..) |is_selected, index| {
        if (is_selected and (index < segment_start or index >= segment_end)) {
            return error.UnsupportedItemLayerMove;
        }
    }

    var order = try allocator.alloc(usize, segment_end - segment_start);
    defer allocator.free(order);
    for (order, 0..) |*entry, index| entry.* = segment_start + index;
    switch (move) {
        .to_back => {
            var output: usize = 0;
            for (segment_start..segment_end) |index| if (selected[index]) {
                order[output] = index;
                output += 1;
            };
            for (segment_start..segment_end) |index| if (!selected[index]) {
                order[output] = index;
                output += 1;
            };
        },
        .backward => {
            var index: usize = 1;
            while (index < order.len) : (index += 1) {
                if (selected[order[index]] and !selected[order[index - 1]]) {
                    std.mem.swap(usize, &order[index], &order[index - 1]);
                }
            }
        },
        .forward => {
            var index = order.len - 1;
            while (index > 0) : (index -= 1) {
                if (selected[order[index - 1]] and !selected[order[index]]) {
                    std.mem.swap(usize, &order[index - 1], &order[index]);
                }
            }
        },
        .to_front => {
            var output: usize = 0;
            for (segment_start..segment_end) |index| if (!selected[index]) {
                order[output] = index;
                output += 1;
            };
            for (segment_start..segment_end) |index| if (selected[index]) {
                order[output] = index;
                output += 1;
            };
        },
    }

    var changed = false;
    for (order, 0..) |unit_index, index| {
        if (unit_index != segment_start + index) {
            changed = true;
            break;
        }
    }
    if (!changed) return error.NoLayerChange;

    const first = units.items[segment_start].start;
    const last = units.items[segment_end - 1].end;
    const newline = lineEndingNear(source, first);
    var replacement = std.ArrayList(u8).empty;
    defer replacement.deinit(allocator);
    for (order, 0..) |unit_index, output_index| {
        const unit = units.items[unit_index];
        try replacement.appendSlice(allocator, source[unit.start..unit.end]);
        if (output_index + 1 < order.len and
            (replacement.items.len == 0 or replacement.items[replacement.items.len - 1] != '\n'))
        {
            try replacement.appendSlice(allocator, newline);
        }
    }
    return replaceRange(allocator, source, first, last, replacement.items);
}

fn selectedIndex(selected: []const bool) ?usize {
    for (selected, 0..) |value, index| {
        if (value) return index;
    }
    return null;
}

pub fn reorderItemLayer(
    allocator: std.mem.Allocator,
    source: []const u8,
    scene: ItemSceneAnchor,
    directive_offset: usize,
    move: LayerMove,
) (std.mem.Allocator.Error || PatchError)!PatchResult {
    const offsets = [_]usize{directive_offset};
    return reorderItemsLayer(allocator, source, scene, &offsets, move);
}

/// Capture one complete literal direct box or component-instance unit for a
/// future paste. Component captures retain the exact latest preceding `@push`
/// definition offset so a destination cannot silently bind the clone to a
/// shadowing definition. The caller owns the returned bytes.
pub fn captureItemForPaste(
    allocator: std.mem.Allocator,
    source: []const u8,
    scene: ItemSceneAnchor,
    directive_offset: usize,
) (std.mem.Allocator.Error || PatchError)!CapturedItem {
    const captured = try captureItemView(allocator, source, scene, directive_offset);
    return .{
        .snippet = try allocator.dupe(u8, captured.snippet),
        .component_definition_offset = captured.component_definition_offset,
    };
}

/// Backward-compatible box-only capture. Use `captureItemForPaste` when a
/// literal `@pop` component instance should retain its definition metadata.
pub fn captureItemSnippet(
    allocator: std.mem.Allocator,
    source: []const u8,
    scene: ItemSceneAnchor,
    directive_offset: usize,
) (std.mem.Allocator.Error || PatchError)![]u8 {
    const captured = try captureItemView(allocator, source, scene, directive_offset);
    if (captured.component_definition_offset != null) return error.UnsupportedClipboardItem;
    return allocator.dupe(u8, captured.snippet);
}

const CapturedItemView = struct {
    snippet: []const u8,
    component_definition_offset: ?usize,
};

fn captureItemView(
    allocator: std.mem.Allocator,
    source: []const u8,
    scene: ItemSceneAnchor,
    directive_offset: usize,
) (std.mem.Allocator.Error || PatchError)!CapturedItemView {
    const range = try resolveItemScene(source, scene);
    var units = std.ArrayList(ItemSourceUnit).empty;
    defer units.deinit(allocator);
    collectSceneItemUnits(allocator, source, range, &units) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.UnsupportedClipboardItem,
    };
    for (units.items) |unit| {
        if (unit.directive_offset != directive_offset) continue;
        const line = directiveLine(source, directive_offset) catch
            return error.UnsupportedClipboardItem;
        const text = source[line.start..line.content_end];
        const name = directiveName(text);
        if (!(std.mem.eql(u8, name, "@box") or std.mem.eql(u8, name, "@pop"))) {
            return error.UnsupportedClipboardItem;
        }
        const snippet = source[unit.start..unit.end];
        const info = try validateCapturedItemSnippet(snippet);
        if (std.mem.eql(u8, name, "@box")) {
            if (info.component_name != null) return error.UnsupportedClipboardItem;
            return .{ .snippet = snippet, .component_definition_offset = null };
        }
        if (range.kind == .morph or info.component_name == null) {
            return error.UnsupportedClipboardItem;
        }
        const definition_offset = try resolveLiteralComponentDefinitionBefore(
            source,
            directive_offset,
            info.component_name.?,
        );
        return .{
            .snippet = snippet,
            .component_definition_offset = definition_offset,
        };
    }
    return error.UnsupportedClipboardItem;
}

/// Paste an ordered batch of independently revalidated captured box snippets
/// at the front of one direct/current-state scene. Every clone receives the
/// caller's unique ID and x/y, plus canonical `locked=false`; omitted w/h on
/// automatic images remain omitted. One insertion produces one PatchResult.
pub fn pasteCapturedItems(
    allocator: std.mem.Allocator,
    source: []const u8,
    destination_scene: ItemSceneAnchor,
    items: []const CapturedPasteItem,
) (std.mem.Allocator.Error || PatchError)!PatchResult {
    const range = try resolveItemScene(source, destination_scene);
    try validatePasteDestination(source, range);
    try validateNoDynamicItemIdentities(source);
    if (items.len == 0) return error.UnsupportedClipboardItem;

    for (items, 0..) |item, index| {
        if (!isLiteralItemId(item.new_id)) return error.InvalidLiteralValue;
        if (hasLiteralItemId(source, item.new_id)) return error.ItemIdCollision;
        for (items[0..index]) |previous| {
            if (std.mem.eql(u8, previous.new_id, item.new_id)) return error.ItemIdCollision;
        }
        const info = try validateCapturedItemSnippet(item.snippet);
        if (info.component_name) |component_name| {
            if (range.kind == .morph) return error.UnsupportedClipboardItem;
            const captured_definition = item.component_definition_offset orelse
                return error.UnsupportedClipboardItem;
            const destination_definition = try resolveLiteralComponentDefinitionBefore(
                source,
                range.end,
                component_name,
            );
            if (destination_definition != captured_definition) return error.UnsupportedClipboardItem;
        } else if (item.component_definition_offset != null) {
            return error.UnsupportedClipboardItem;
        }
        if (range.kind == .morph and capturedSnippetHasAnimation(item.snippet, info.directive_offset)) {
            return error.UnsupportedClipboardItem;
        }
        try validateCoordinate(item.placement.x);
        try validateCoordinate(item.placement.y);
    }

    const newline = lineEndingNear(source, range.end);
    var payload = std.ArrayList(u8).empty;
    defer payload.deinit(allocator);
    for (items) |item| {
        const info = try validateCapturedItemSnippet(item.snippet);
        var x_buffer: [64]u8 = undefined;
        var y_buffer: [64]u8 = undefined;
        const patches = [_]LiteralAttributePatch{
            .{ .key = "id", .value = item.new_id },
            .{ .key = "x", .value = try formatCoordinate(&x_buffer, item.placement.x) },
            .{ .key = "y", .value = try formatCoordinate(&y_buffer, item.placement.y) },
            .{ .key = "locked", .value = "false" },
        };
        const canonical = try patchLiteralAttributes(
            allocator,
            item.snippet,
            info.directive_offset,
            &patches,
        );
        defer canonical.deinit(allocator);
        try appendSourceWithLineEnding(allocator, &payload, canonical.source, newline);
        if (payload.items.len == 0 or payload.items[payload.items.len - 1] != '\n') {
            try payload.appendSlice(allocator, newline);
        }
    }

    var insertion = std.ArrayList(u8).empty;
    defer insertion.deinit(allocator);
    if (range.end == source.len and source.len > sourceStart(source) and source[source.len - 1] != '\n') {
        try insertion.appendSlice(allocator, newline);
    }
    try insertion.appendSlice(allocator, payload.items);
    return replaceRange(allocator, source, range.end, range.end, insertion.items);
}

pub fn pasteCapturedItem(
    allocator: std.mem.Allocator,
    source: []const u8,
    destination_scene: ItemSceneAnchor,
    item: CapturedPasteItem,
) (std.mem.Allocator.Error || PatchError)!PatchResult {
    const items = [_]CapturedPasteItem{item};
    return pasteCapturedItems(allocator, source, destination_scene, &items);
}

/// Atomically duplicate an ordered batch of physically authored direct boxes
/// and literal component instances into one destination scene. This is the
/// in-document counterpart of capture/paste and uses the same definition,
/// uniqueness, animation, and scene preflight before emitting one PatchResult.
pub fn duplicateItems(
    allocator: std.mem.Allocator,
    source: []const u8,
    source_scene: ItemSceneAnchor,
    destination_scene: ItemSceneAnchor,
    targets: []const DuplicateItemTarget,
) (std.mem.Allocator.Error || PatchError)!PatchResult {
    if (targets.len == 0) return error.UnsupportedItemDuplication;
    var paste_items = try allocator.alloc(CapturedPasteItem, targets.len);
    defer allocator.free(paste_items);

    for (targets, 0..) |target, index| {
        for (targets[0..index]) |previous| {
            if (previous.directive_offset == target.directive_offset) {
                return error.UnsupportedItemDuplication;
            }
        }
        const captured = try captureItemView(
            allocator,
            source,
            source_scene,
            target.directive_offset,
        );
        paste_items[index] = .{
            .snippet = captured.snippet,
            .component_definition_offset = captured.component_definition_offset,
            .new_id = target.new_id,
            .placement = target.placement,
        };
    }
    return pasteCapturedItems(allocator, source, destination_scene, paste_items);
}

/// Delete exactly the physical directive line beginning at `directive_offset`,
/// including its existing CRLF/LF terminator when present. Continuation text
/// on following physical lines is deliberately not removed.
pub fn deleteDirective(
    allocator: std.mem.Allocator,
    source: []const u8,
    directive_offset: usize,
) (std.mem.Allocator.Error || PatchError)!PatchResult {
    const line = try directiveLine(source, directive_offset);
    return replaceRange(allocator, source, line.start, line.full_end, "");
}

/// Delete one logical item: its directive plus following body-text lines up to
/// the next directive. Standalone comments and empty formatting lines survive.
/// Use `deleteDirective` when only the physical directive line is intended.
pub fn deleteItem(
    allocator: std.mem.Allocator,
    source: []const u8,
    directive_offset: usize,
) (std.mem.Allocator.Error || PatchError)!PatchResult {
    const line = try directiveLine(source, directive_offset);
    var edits = std.ArrayList(Edit).empty;
    defer edits.deinit(allocator);

    try appendItemDeletionEdits(allocator, source, line, &edits);
    sortEditsByPosition(edits.items);
    return applyEdits(allocator, source, edits.items);
}

/// Delete an item and every later `@set`, `@show`, or `@hide` targeting
/// `item_id` before the next slide boundary. This is the safe semantic delete
/// for a base or state-born morph item: plain `deleteItem` deliberately remains
/// the smaller source primitive for callers that do not want cascading edits.
pub fn deleteItemCascadingMorphMutations(
    allocator: std.mem.Allocator,
    source: []const u8,
    directive_offset: usize,
    item_id: []const u8,
) (std.mem.Allocator.Error || PatchError)!PatchResult {
    if (item_id.len == 0 or std.mem.indexOfAny(u8, item_id, " \t\r\n=") != null) {
        return error.InvalidLiteralValue;
    }
    const item_line = try directiveLine(source, directive_offset);
    var edits = std.ArrayList(Edit).empty;
    defer edits.deinit(allocator);
    try appendItemDeletionEdits(allocator, source, item_line, &edits);

    var cursor = item_line.full_end;
    while (cursor < source.len) {
        const line = physicalLineAt(source, cursor);
        if (cursor < line.content_end and source[cursor] == '@') {
            const name = directiveName(source[cursor..line.content_end]);
            if (isSlideBoundaryDirective(name)) break;
            if (isMorphMutationDirective(name)) {
                const target = directiveContextName(source[cursor..line.content_end], name.len);
                if (target != null and std.mem.eql(u8, target.?, item_id)) {
                    try edits.append(allocator, .{
                        .start = cursor,
                        .end = line.full_end,
                        .replacement = "",
                    });
                    try appendBodyDeletionEdits(allocator, source, line.full_end, &edits);
                }
            }
        }
        cursor = line.full_end;
    }
    sortEditsByPosition(edits.items);
    return applyEdits(allocator, source, edits.items);
}

const BatchDeleteDependency = struct {
    id: []const u8,
    authored_offset: usize,
};

/// Atomically delete physically authored items and/or hide inherited items in
/// one exact base/current-state scene. Authored removal owns pending `@anim`,
/// the complete directive body/comments, and every later literal morph
/// mutation targeting its unique ID before the next rendered slide. Hide
/// targets become canonical state/base-local `@hide` lines at the scene end.
/// Shared template definitions, backgrounds, generated dependencies, stale
/// offsets, duplicate targets, and ambiguous IDs reject before any output is
/// produced.
pub fn deleteItems(
    allocator: std.mem.Allocator,
    source: []const u8,
    scene: ItemSceneAnchor,
    targets: []const DeleteItemTarget,
) (std.mem.Allocator.Error || PatchError)!PatchResult {
    if (targets.len == 0) return error.UnsupportedBatchDeletion;
    const range = resolveItemScene(source, scene) catch return error.UnsupportedBatchDeletion;
    const logical_end = try batchDeleteLogicalSlideEnd(source, range);

    var units = std.ArrayList(ItemSourceUnit).empty;
    defer units.deinit(allocator);
    collectSceneItemUnits(allocator, source, range, &units) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.UnsupportedBatchDeletion,
    };

    var edits = std.ArrayList(Edit).empty;
    defer edits.deinit(allocator);
    var dependencies = std.ArrayList(BatchDeleteDependency).empty;
    defer dependencies.deinit(allocator);
    var hide_ids = std.ArrayList([]const u8).empty;
    defer hide_ids.deinit(allocator);

    for (targets, 0..) |target, target_index| {
        switch (target) {
            .authored => |authored| {
                for (targets[0..target_index]) |previous| switch (previous) {
                    .authored => |prior| if (prior.directive_offset == authored.directive_offset) {
                        return error.UnsupportedBatchDeletion;
                    },
                    .hide => {},
                };

                const unit = findItemSourceUnit(units.items, authored.directive_offset) orelse
                    return error.UnsupportedBatchDeletion;
                const line = directiveLine(source, authored.directive_offset) catch
                    return error.UnsupportedBatchDeletion;
                const text = source[line.start..line.content_end];
                const name = directiveName(text);
                if (!(std.mem.eql(u8, name, "@box") or std.mem.eql(u8, name, "@pop")) or
                    hasPotentialLetExpansion(source[unit.start..unit.end]) or
                    directiveHasDynamicIdentity(text, name))
                {
                    return error.UnsupportedBatchDeletion;
                }
                const actual_id = literalEmittedItemId(text, name);
                if (authored.item_id) |expected_id| {
                    if (!isLiteralItemId(expected_id) or actual_id == null or
                        !std.mem.eql(u8, expected_id, actual_id.?))
                    {
                        return error.UnsupportedBatchDeletion;
                    }
                    if (batchDeleteIdSeen(dependencies.items, hide_ids.items, expected_id)) {
                        return error.UnsupportedBatchDeletion;
                    }
                    try dependencies.append(allocator, .{
                        .id = expected_id,
                        .authored_offset = authored.directive_offset,
                    });
                } else if (actual_id != null) {
                    // Omitting a real ID would skip dependency cleanup.
                    return error.UnsupportedBatchDeletion;
                }
                try edits.append(allocator, .{
                    .start = unit.start,
                    .end = unit.end,
                    .replacement = "",
                });
            },
            .hide => |hide| {
                if (range.kind == .base or !isLiteralItemId(hide.item_id) or
                    batchDeleteIdSeen(dependencies.items, hide_ids.items, hide.item_id))
                {
                    return error.UnsupportedBatchDeletion;
                }
                try hide_ids.append(allocator, hide.item_id);
            },
        }
    }

    try appendBatchDeleteDependencyEdits(
        allocator,
        source,
        range.start,
        logical_end,
        dependencies.items,
        &edits,
    );

    var hide_payload = std.ArrayList(u8).empty;
    defer hide_payload.deinit(allocator);
    if (hide_ids.items.len > 0) {
        const newline = lineEndingNear(source, range.end);
        if (batchInsertionNeedsSeparator(source, range.end, edits.items)) {
            try hide_payload.appendSlice(allocator, newline);
        }
        for (hide_ids.items) |id| {
            try hide_payload.appendSlice(allocator, "@hide ");
            try hide_payload.appendSlice(allocator, id);
            try hide_payload.appendSlice(allocator, newline);
        }
        try edits.append(allocator, .{
            .start = range.end,
            .end = range.end,
            .replacement = hide_payload.items,
        });
    }

    sortEditsByPosition(edits.items);
    try validateNonOverlappingEdits(edits.items);
    return applyEdits(allocator, source, edits.items);
}

/// Delete one item from the exact shared slide-template definition used by a
/// representative `@popslide` instance, together with every instance-local or
/// morph-state mutation that depends on that item.
///
/// The representative instance is resolved source-order-wise to the latest
/// preceding literal `@pushslide` of the same name. Only later instances still
/// bound to that exact definition are visited; the first same-name definition
/// shadows it and ends the dependency window. The selected definition must be
/// a direct, literal capture rather than a generated or nested/captured slide.
/// Pass a stable `item_id` to remove dependent mutations. An id-less shared
/// item may pass null: its exact directive is still deleted, while mutation
/// matching is unnecessary because it cannot be targeted. Dynamic structural
/// directives, duplicate IDs, locally colliding IDs, and nested template
/// captures make ownership ambiguous and reject the complete operation before
/// any source bytes are changed.
pub fn deleteSharedSlideTemplateItem(
    allocator: std.mem.Allocator,
    source: []const u8,
    instance_slide_offset: usize,
    shared_directive_offset: usize,
    item_id: ?[]const u8,
) (std.mem.Allocator.Error || PatchError)!PatchResult {
    if (item_id) |id| {
        if (!isLiteralItemId(id)) return error.InvalidLiteralValue;
    }

    const resolved = try resolveSlideTemplateDefinitionForInstance(source, instance_slide_offset);
    try validateDirectSharedTemplateItem(
        source,
        resolved.definition,
        shared_directive_offset,
        item_id,
    );

    const shared_line = directiveLine(source, shared_directive_offset) catch
        return error.UnsupportedSharedTemplateDeletion;
    var edits = std.ArrayList(Edit).empty;
    defer edits.deinit(allocator);
    try appendItemDeletionEdits(allocator, source, shared_line, &edits);

    var cursor = resolved.definition.full_end;
    while (cursor < source.len) {
        const line = physicalLineAt(source, cursor);
        if (cursor < line.content_end and source[cursor] == '@') {
            const text = source[cursor..line.content_end];
            const name = directiveName(text);

            if (std.mem.eql(u8, name, "@pushslide")) {
                if (hasPotentialLetExpansion(text)) {
                    return error.AmbiguousSlideTemplateDependency;
                }
                const pushed_name = directiveContextName(text, name.len) orelse
                    return error.AmbiguousSlideTemplateDependency;
                if (std.mem.eql(u8, pushed_name, resolved.name)) break;
            } else if (std.mem.eql(u8, name, "@popslide")) {
                if (hasPotentialLetExpansion(text)) {
                    return error.AmbiguousSlideTemplateDependency;
                }
                const popped_name = directiveContextName(text, name.len) orelse
                    return error.AmbiguousSlideTemplateDependency;
                if (std.mem.eql(u8, popped_name, resolved.name)) {
                    const end = try appendSharedTemplateInstanceDependencyEdits(
                        allocator,
                        source,
                        line,
                        item_id,
                        &edits,
                    );
                    cursor = end;
                    continue;
                }
            }
        }
        cursor = line.full_end;
    }

    sortEditsByPosition(edits.items);
    return applyEdits(allocator, source, edits.items);
}

fn appendItemDeletionEdits(
    allocator: std.mem.Allocator,
    source: []const u8,
    line: DirectiveLine,
    edits: *std.ArrayList(Edit),
) std.mem.Allocator.Error!void {

    // `@anim` is a pending decorator: the parser applies it to the next item
    // directive. Leaving it behind when that item is deleted silently moves
    // the animation to the following item instead. Treat immediately preceding
    // animation directives (with comments/body lines between them and the
    // item) as part of the item's semantic source ownership.
    var decorator_before = line.start;
    while (previousDirectiveLine(source, decorator_before)) |decorator| {
        const name = directiveName(source[decorator.start..decorator.content_end]);
        if (!isAnimationDirective(name)) break;
        try edits.append(allocator, .{
            .start = decorator.start,
            .end = decorator.full_end,
            .replacement = "",
        });
        // Parser body text attached to @anim is ignored, but retaining it after
        // the decorator is removed could attach it to an earlier item. Match
        // item deletion semantics: remove text, retain comments/blank layout.
        try appendBodyDeletionEdits(allocator, source, decorator.full_end, edits);
        decorator_before = decorator.start;
    }
    try edits.append(allocator, .{
        .start = line.start,
        .end = line.full_end,
        .replacement = "",
    });
    try appendBodyDeletionEdits(allocator, source, line.full_end, edits);
}

/// Return the safe z-order insertion point immediately below the item at
/// `directive_offset`. When one or more pending `@anim`/`@anim(...)`
/// decorators immediately precede the item, the returned offset is before the
/// earliest decorator so an inserted item cannot steal its animation.
/// Comments, blank lines, and decorator body lines do not break ownership.
pub fn itemInsertionOffsetBeforeAnimations(source: []const u8, directive_offset: usize) PatchError!usize {
    const line = try directiveLine(source, directive_offset);
    var insertion_offset = line.start;
    while (previousDirectiveLine(source, insertion_offset)) |decorator| {
        const name = directiveName(source[decorator.start..decorator.content_end]);
        if (!isAnimationDirective(name)) break;
        insertion_offset = decorator.start;
    }
    return insertion_offset;
}

/// Replace exactly one directive's content while retaining its existing line
/// ending and every byte outside that physical line.
pub fn replaceDirectiveLine(
    allocator: std.mem.Allocator,
    source: []const u8,
    directive_offset: usize,
    directive: []const u8,
) (std.mem.Allocator.Error || PatchError)!PatchResult {
    try validateDirectiveText(directive);
    const line = try directiveLine(source, directive_offset);
    return replaceRange(allocator, source, line.start, line.content_end, directive);
}

/// Patch literal token attributes on one directive without reformatting it.
///
/// Existing attributes retain all surrounding whitespace and only their
/// effective (last) value bytes are replaced. Missing attributes are inserted
/// before `text=`. A `text` patch is also semantic: following body-text lines
/// are removed so stale text cannot be appended by the parser. For multiline
/// text, prefer `patchItemText`.
pub fn patchLiteralAttributes(
    allocator: std.mem.Allocator,
    source: []const u8,
    directive_offset: usize,
    patches: []const LiteralAttributePatch,
) (std.mem.Allocator.Error || PatchError)!PatchResult {
    const line = try directiveLine(source, directive_offset);

    for (patches, 0..) |patch, index| {
        try validateLiteralPatch(patch);
        for (patches[0..index]) |previous| {
            if (std.mem.eql(u8, patch.key, previous.key)) return error.DuplicateAttribute;
        }
    }

    if (patches.len == 0) {
        const copy = try allocator.dupe(u8, source);
        return .{ .source = copy, .byte_delta = 0 };
    }

    var spans = try allocator.alloc(?Span, patches.len);
    defer allocator.free(spans);
    @memset(spans, null);

    var text_token_start: ?usize = null;
    var cursor = line.start;
    while (cursor < line.content_end) {
        while (cursor < line.content_end and isHorizontalWhitespace(source[cursor])) : (cursor += 1) {}
        if (cursor == line.content_end) break;

        const token_start = cursor;
        while (cursor < line.content_end and !isHorizontalWhitespace(source[cursor])) : (cursor += 1) {}
        const token_end = cursor;
        const token = source[token_start..token_end];
        const equals_index = std.mem.indexOfScalar(u8, token, '=') orelse continue;
        const key = token[0..equals_index];

        if (std.mem.eql(u8, key, "text")) {
            text_token_start = token_start;
            for (patches, 0..) |patch, patch_index| {
                if (std.mem.eql(u8, patch.key, "text")) {
                    spans[patch_index] = .{
                        .start = token_start + equals_index + 1,
                        .end = line.content_end,
                    };
                    break;
                }
            }
            break;
        }

        for (patches, 0..) |patch, patch_index| {
            if (std.mem.eql(u8, patch.key, key)) {
                // Match parser semantics: for malformed duplicates, the last
                // token before text= is the effective value.
                spans[patch_index] = .{
                    .start = token_start + equals_index + 1,
                    .end = token_end,
                };
                break;
            }
        }
    }

    const insertion_point = text_token_start orelse
        trimHorizontalWhitespaceEnd(source, line.content_end, line.start);
    var insertion = std.ArrayList(u8).empty;
    defer insertion.deinit(allocator);
    var emitted: usize = 0;

    // Token attributes must precede text= because text owns the remainder.
    for (patches, 0..) |patch, patch_index| {
        if (spans[patch_index] != null or std.mem.eql(u8, patch.key, "text")) continue;
        if (emitted == 0 and
            (insertion_point == line.start or !isHorizontalWhitespace(source[insertion_point - 1])))
        {
            try insertion.append(allocator, ' ');
        } else if (emitted > 0) {
            try insertion.append(allocator, ' ');
        }
        try insertion.appendSlice(allocator, patch.key);
        try insertion.append(allocator, '=');
        try insertion.appendSlice(allocator, patch.value);
        emitted += 1;
    }

    const text_patch_index = findPatch(patches, "text");
    if (text_patch_index != null and spans[text_patch_index.?] == null) {
        if ((emitted == 0 and
            (insertion_point == line.start or !isHorizontalWhitespace(source[insertion_point - 1]))) or
            emitted > 0)
        {
            try insertion.append(allocator, ' ');
        }
        try insertion.appendSlice(allocator, "text=");
        try insertion.appendSlice(allocator, patches[text_patch_index.?].value);
        emitted += 1;
    } else if (emitted > 0 and text_token_start != null) {
        try insertion.append(allocator, ' ');
    }

    var edits = std.ArrayList(Edit).empty;
    defer edits.deinit(allocator);
    for (patches, 0..) |patch, patch_index| {
        if (spans[patch_index]) |span| {
            try edits.append(allocator, .{
                .start = span.start,
                .end = span.end,
                .replacement = patch.value,
            });
        }
    }
    if (insertion.items.len > 0) {
        try edits.append(allocator, .{
            .start = insertion_point,
            .end = insertion_point,
            .replacement = insertion.items,
        });
    }
    if (text_patch_index != null) {
        try appendBodyDeletionEdits(allocator, source, line.full_end, &edits);
    }
    sortEditsByPosition(edits.items);
    return applyEdits(allocator, source, edits.items);
}

/// Replace an item's semantic text, whether its current source uses inline
/// `text=` or following body lines. Single-line text is written inline;
/// multiline text is written as body lines using the file's local line ending.
/// Existing body comments and empty formatting lines are preserved.
pub fn patchItemText(
    allocator: std.mem.Allocator,
    source: []const u8,
    directive_offset: usize,
    text_value: []const u8,
) (std.mem.Allocator.Error || PatchError)!PatchResult {
    if (std.mem.indexOfScalar(u8, text_value, '\r') != null) return error.InvalidLiteralValue;
    if (std.mem.indexOfScalar(u8, text_value, '\n') == null) {
        const patches = [_]LiteralAttributePatch{.{ .key = "text", .value = text_value }};
        return patchLiteralAttributes(allocator, source, directive_offset, &patches);
    }
    try validateBodyText(text_value);

    const line = try directiveLine(source, directive_offset);
    var edits = std.ArrayList(Edit).empty;
    defer edits.deinit(allocator);

    if (findInlineTextToken(source, line)) |span| {
        try edits.append(allocator, .{
            .start = span.start,
            .end = line.content_end,
            .replacement = "",
        });
    }

    const newline = lineEndingNear(source, line.start);
    var body = std.ArrayList(u8).empty;
    defer body.deinit(allocator);
    if (line.full_end == line.content_end) try body.appendSlice(allocator, newline);
    try appendNormalizedLines(allocator, &body, text_value, newline);
    try body.appendSlice(allocator, newline);
    try edits.append(allocator, .{
        .start = line.full_end,
        .end = line.full_end,
        .replacement = body.items,
    });
    try appendBodyDeletionEdits(allocator, source, line.full_end, &edits);

    sortEditsByPosition(edits.items);
    return applyEdits(allocator, source, edits.items);
}

const utf8_bom = "\xEF\xBB\xBF";

const SlideLayout = struct {
    explicit_count: usize = 0,
    has_component_definition: bool = false,
    has_slide_template_definition: bool = false,
};

/// Validate the subset of slide layouts that can be rearranged purely by
/// physical source ranges. `@pushslide` definitions are safe before the first
/// rendered anchor. Once rendered slides begin, another push can capture the
/// apparent current slide and makes textual adjacency diverge from parser
/// adjacency, so organizer operations must decline the edit.
fn inspectSlideLayout(source: []const u8) PatchError!SlideLayout {
    var layout = SlideLayout{};
    var saw_rendered_anchor = false;
    var cursor = sourceStart(source);
    while (cursor < source.len) {
        const line = physicalLineAt(source, cursor);
        if (cursor < line.content_end and source[cursor] == '@') {
            const name = directiveName(source[cursor..line.content_end]);
            if (isRenderedSlideAnchor(name)) {
                saw_rendered_anchor = true;
                layout.explicit_count += 1;
            } else if (std.mem.eql(u8, name, "@pushslide")) {
                layout.has_slide_template_definition = true;
                if (saw_rendered_anchor) return error.AmbiguousSlideTemplateLayout;
            } else if (std.mem.eql(u8, name, "@push")) {
                layout.has_component_definition = true;
            }
        }
        cursor = line.full_end;
    }
    if (layout.explicit_count == 0 and layout.has_slide_template_definition) {
        return error.AmbiguousSlideTemplateLayout;
    }
    return layout;
}

/// Physical slide ranges are safe to duplicate/delete/reorder only when every
/// directive they own is local scene content. Parser context definitions and
/// defaults (`@push`, `@let`, fonts, colors, and unknown future directives)
/// can affect later slides even when a rewritten deck still parses, so the
/// organizer must leave those layouts untouched until it has dependency-aware
/// ownership analysis.
fn validateStructuralSlideRange(source: []const u8, range: LogicalSlideRange) PatchError!void {
    var cursor = range.start;
    while (cursor < range.end) {
        const line = physicalLineAt(source, cursor);
        if (cursor < line.content_end and source[cursor] == '@') {
            const name = directiveName(source[cursor..line.content_end]);
            if (!isSlideOwnedStructuralDirective(name)) return error.UnsafeSlideGlobalDirective;
        }
        cursor = line.full_end;
    }
}

fn isSlideOwnedStructuralDirective(name: []const u8) bool {
    return isRenderedSlideAnchor(name) or
        std.mem.eql(u8, name, "@box") or
        std.mem.eql(u8, name, "@crowd") or
        std.mem.eql(u8, name, "@bg") or
        std.mem.eql(u8, name, "@pop") or
        std.mem.eql(u8, name, "@anim") or
        (std.mem.startsWith(u8, name, "@anim(") and std.mem.endsWith(u8, name, ")")) or
        isMorphStateDirective(name) or
        std.mem.eql(u8, name, "@set") or
        std.mem.eql(u8, name, "@show") or
        std.mem.eql(u8, name, "@hide");
}

fn previousRenderedSlideAnchor(source: []const u8, before: usize) ?usize {
    var previous: ?usize = null;
    var cursor = sourceStart(source);
    while (cursor < before) {
        const line = physicalLineAt(source, cursor);
        if (cursor < line.content_end and source[cursor] == '@') {
            const name = directiveName(source[cursor..line.content_end]);
            if (isRenderedSlideAnchor(name)) previous = cursor;
        }
        cursor = line.full_end;
    }
    return previous;
}

/// Append adjacent `left` then `right` ranges in swapped order. If the source
/// ends without a line terminator, the left range's final line ending is moved
/// between the newly leading right range and left range. This keeps the result
/// valid without inventing a byte or leaving an extra terminator at EOF.
fn appendSwappedSlideRanges(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    source: []const u8,
    left: LogicalSlideRange,
    right: LogicalSlideRange,
) std.mem.Allocator.Error!void {
    std.debug.assert(left.end == right.start);
    try output.ensureTotalCapacity(allocator, right.end - left.start);
    try output.appendSlice(allocator, source[right.start..right.end]);

    var left_content_end = left.end;
    if (right.end == source.len and right.end > right.start and source[right.end - 1] != '\n') {
        std.debug.assert(left_content_end > left.start and source[left_content_end - 1] == '\n');
        const separator_start = if (left_content_end >= 2 and source[left_content_end - 2] == '\r')
            left_content_end - 2
        else
            left_content_end - 1;
        try output.appendSlice(allocator, source[separator_start..left_content_end]);
        left_content_end = separator_start;
    }
    try output.appendSlice(allocator, source[left.start..left_content_end]);
}

fn promoteImplicitSlideToTemplate(
    allocator: std.mem.Allocator,
    source: []const u8,
    base_end: usize,
    name: []const u8,
) (std.mem.Allocator.Error || PatchError)!PatchResult {
    const newline = lineEndingNear(source, base_end);
    const content_start = sourceStart(source);
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try output.ensureTotalCapacity(allocator, source.len + name.len * 2 + 32);
    try output.appendSlice(allocator, source[0..base_end]);
    if (base_end > content_start and source[base_end - 1] != '\n') {
        try output.appendSlice(allocator, newline);
    }
    try output.appendSlice(allocator, "@pushslide ");
    try output.appendSlice(allocator, name);
    try output.appendSlice(allocator, newline);
    try output.appendSlice(allocator, "@popslide ");
    try output.appendSlice(allocator, name);
    try output.appendSlice(allocator, newline);
    try output.appendSlice(allocator, source[base_end..]);
    return finishResult(allocator, &output, source.len);
}

fn promoteExplicitSlideToTemplate(
    allocator: std.mem.Allocator,
    source: []const u8,
    selected: LogicalSlideRange,
    anchor: DirectiveLine,
    template_insertion: usize,
    base_start: usize,
    base_end: usize,
    name: []const u8,
) (std.mem.Allocator.Error || PatchError)!PatchResult {
    std.debug.assert(template_insertion <= selected.start);
    std.debug.assert(anchor.start == selected.start);
    const newline = lineEndingNear(source, anchor.start);
    const slide_directive = "@slide";

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try output.ensureTotalCapacity(allocator, source.len + name.len * 2 + 32);
    try output.appendSlice(allocator, source[0..template_insertion]);
    try output.appendSlice(allocator, source[base_start..base_end]);
    if (base_end > base_start and source[base_end - 1] != '\n') {
        try output.appendSlice(allocator, newline);
    }
    try output.appendSlice(allocator, "@pushslide ");
    try output.appendSlice(allocator, name);
    try output.appendSlice(allocator, newline);

    try output.appendSlice(allocator, source[template_insertion..selected.start]);
    try output.appendSlice(allocator, "@popslide ");
    try output.appendSlice(allocator, name);
    // Preserve every byte after the original directive token, including
    // transition attributes, horizontal formatting, and its line ending.
    try output.appendSlice(allocator, source[anchor.start + slide_directive.len .. anchor.full_end]);
    try output.appendSlice(allocator, source[base_end..]);
    return finishResult(allocator, &output, source.len);
}

fn hasSlideTemplateNamed(source: []const u8, sought: []const u8) bool {
    var cursor = sourceStart(source);
    while (cursor < source.len) {
        const line = physicalLineAt(source, cursor);
        if (cursor < line.content_end and source[cursor] == '@') {
            const directive = directiveName(source[cursor..line.content_end]);
            if (std.mem.eql(u8, directive, "@pushslide")) {
                const existing = directiveContextName(source[cursor..line.content_end], directive.len);
                if (existing != null and std.mem.eql(u8, existing.?, sought)) return true;
            }
        }
        cursor = line.full_end;
    }
    return false;
}

fn firstRenderedSlideAnchor(source: []const u8) ?usize {
    var cursor = sourceStart(source);
    while (cursor < source.len) {
        const line = physicalLineAt(source, cursor);
        if (cursor < line.content_end and source[cursor] == '@') {
            if (isRenderedSlideAnchor(directiveName(source[cursor..line.content_end]))) return cursor;
        }
        cursor = line.full_end;
    }
    return null;
}

fn firstMorphStateOffset(source: []const u8, start: usize, end: usize) ?usize {
    var cursor = start;
    while (cursor < end) {
        const line = physicalLineAt(source, cursor);
        if (cursor < line.content_end and source[cursor] == '@') {
            if (isMorphStateDirective(directiveName(source[cursor..line.content_end]))) return cursor;
        }
        cursor = line.full_end;
    }
    return null;
}

fn validatePromotableSlideAnchor(source: []const u8, line: DirectiveLine) PatchError!void {
    if (std.mem.indexOfScalar(u8, source[line.start..line.content_end], '$') != null) {
        return error.UnsupportedSlidePromotion;
    }
    const name = directiveName(source[line.start..line.content_end]);
    var cursor = line.start + name.len;
    while (cursor < line.content_end) {
        while (cursor < line.content_end and isHorizontalWhitespace(source[cursor])) : (cursor += 1) {}
        if (cursor == line.content_end) break;
        const token_start = cursor;
        while (cursor < line.content_end and !isHorizontalWhitespace(source[cursor])) : (cursor += 1) {}
        const token = source[token_start..cursor];
        const equals = std.mem.indexOfScalar(u8, token, '=') orelse continue;
        const key = token[0..equals];
        if (std.mem.eql(u8, key, "text")) break;
        if (isSlideItemDefaultAttribute(key)) return error.UnsupportedSlidePromotion;
    }
}

fn isSlideItemDefaultAttribute(key: []const u8) bool {
    return std.mem.eql(u8, key, "fontsize") or
        std.mem.eql(u8, key, "color") or
        std.mem.eql(u8, key, "bullet_color") or
        std.mem.eql(u8, key, "bullet_symbol") or
        std.mem.eql(u8, key, "underline_width") or
        std.mem.eql(u8, key, "line_height");
}

/// The parser discards an orphan pre-deck current slide when the first
/// `@slide` is encountered. Inserting a template there would capture it
/// instead, so require the current slide and pending animation to have been
/// reset by the most recent `@pushslide` (or to have remained untouched).
fn validateTemplateInsertionContext(source: []const u8, insertion: usize) PatchError!void {
    var dirty_slide = false;
    var pending_animation = false;
    var cursor = sourceStart(source);
    while (cursor < insertion) {
        const line = physicalLineAt(source, cursor);
        if (cursor < line.content_end and source[cursor] == '@') {
            const content = source[cursor..line.content_end];
            if (std.mem.indexOfScalar(u8, content, '$') != null) return error.UnsupportedSlidePromotion;
            const name = directiveName(content);
            if (std.mem.eql(u8, name, "@pushslide")) {
                dirty_slide = false;
                pending_animation = false;
            } else if (isAnimationDirective(name)) {
                pending_animation = true;
            } else if (directiveEmitsSlideItem(name)) {
                dirty_slide = true;
                pending_animation = false;
            } else if (isMorphStateDirective(name) or isMorphMutationDirective(name)) {
                dirty_slide = true;
            }
        }
        cursor = line.full_end;
    }
    if (dirty_slide or pending_animation) return error.UnsupportedSlidePromotion;
}

fn directiveEmitsSlideItem(name: []const u8) bool {
    return std.mem.eql(u8, name, "@box") or
        std.mem.eql(u8, name, "@bg") or
        std.mem.eql(u8, name, "@crowd") or
        std.mem.eql(u8, name, "@pop");
}

fn validatePromotableBase(source: []const u8, start: usize, end: usize) PatchError!void {
    try validateNoDynamicDirectives(source, start, end);

    // Body text immediately after a slide anchor belongs to that anchor and
    // would acquire a different owner when the anchor is replaced by moved
    // template bytes. Comments and blank formatting are ownership-neutral.
    var cursor = start;
    while (cursor < end) {
        const line = physicalLineAt(source, cursor);
        const content = source[cursor..line.content_end];
        if (content.len == 0 or content[0] == '#') {
            cursor = line.full_end;
            continue;
        }
        if (content[0] != '@') return error.UnsupportedSlidePromotion;
        break;
    }

    try validateNoDanglingAnimation(source, start, end);
}

fn validateNoDynamicDirectives(source: []const u8, start: usize, end: usize) PatchError!void {
    var cursor = start;
    while (cursor < end) {
        const line = physicalLineAt(source, cursor);
        if (cursor < line.content_end and source[cursor] == '@' and
            std.mem.indexOfScalar(u8, source[cursor..line.content_end], '$') != null)
        {
            return error.UnsupportedSlidePromotion;
        }
        cursor = line.full_end;
    }
}

fn validateNoDanglingAnimation(source: []const u8, start: usize, end: usize) PatchError!void {
    var pending_animation = false;
    var cursor = start;
    while (cursor < end) {
        const line = physicalLineAt(source, cursor);
        if (cursor < line.content_end and source[cursor] == '@') {
            const name = directiveName(source[cursor..line.content_end]);
            if (isAnimationDirective(name)) {
                pending_animation = true;
            } else if (directiveEmitsSlideItem(name)) {
                pending_animation = false;
            }
        }
        cursor = line.full_end;
    }
    if (pending_animation) return error.UnsupportedSlidePromotion;
}

const SlideTemplateInstanceBaseRegion = struct {
    anchor: DirectiveLine,
    end: usize,
};

const ResolvedSlideTemplateDefinition = struct {
    name: []const u8,
    definition: DirectiveLine,
};

fn resolveSlideTemplateDefinitionForInstance(
    source: []const u8,
    instance_slide_offset: usize,
) PatchError!ResolvedSlideTemplateDefinition {
    const instance = directiveLine(source, instance_slide_offset) catch
        return error.UnsupportedSharedTemplateDeletion;
    const instance_text = source[instance.start..instance.content_end];
    const instance_directive = directiveName(instance_text);
    if (!std.mem.eql(u8, instance_directive, "@popslide") or
        hasPotentialLetExpansion(instance_text))
    {
        return error.UnsupportedSharedTemplateDeletion;
    }
    const template_name = directiveContextName(instance_text, instance_directive.len) orelse
        return error.UnsupportedSharedTemplateDeletion;
    if (!isReusableName(template_name)) return error.UnsupportedSharedTemplateDeletion;

    var latest: ?DirectiveLine = null;
    var resolution_ambiguous = false;
    var cursor = sourceStart(source);
    while (cursor < instance.start) {
        const line = physicalLineAt(source, cursor);
        if (line.full_end > instance.start) return error.UnsupportedSharedTemplateDeletion;
        if (cursor < line.content_end and source[cursor] == '@') {
            const text = source[cursor..line.content_end];
            const name = directiveName(text);
            if (std.mem.eql(u8, name, "@pushslide")) {
                if (hasPotentialLetExpansion(text)) {
                    // A generated name after the last known matching
                    // definition may have shadowed it.
                    if (latest != null) resolution_ambiguous = true;
                } else if (directiveContextName(text, name.len)) |candidate| {
                    if (std.mem.eql(u8, candidate, template_name)) {
                        latest = line;
                        resolution_ambiguous = false;
                    }
                }
            }
        }
        cursor = line.full_end;
    }
    if (cursor != instance.start or latest == null or resolution_ambiguous) {
        return error.AmbiguousSlideTemplateDependency;
    }
    return .{ .name = template_name, .definition = latest.? };
}

fn validateDirectSharedTemplateItem(
    source: []const u8,
    definition: DirectiveLine,
    shared_directive_offset: usize,
    item_id: ?[]const u8,
) PatchError!void {
    const definition_text = source[definition.start..definition.content_end];
    if (!std.mem.eql(u8, directiveName(definition_text), "@pushslide") or
        hasPotentialLetExpansion(definition_text))
    {
        return error.UnsupportedSharedTemplateDeletion;
    }

    // @pushslide resets the parser's in-progress slide. With no intervening
    // rendered anchor, bytes after the previous @pushslide form this direct
    // definition's complete capture region. A @slide/@popslide here means the
    // definition captures another authored or cloned slide and is deliberately
    // outside this exact source primitive.
    var capture_start = sourceStart(source);
    var cursor = sourceStart(source);
    while (cursor < definition.start) {
        const line = physicalLineAt(source, cursor);
        if (line.full_end > definition.start) return error.UnsupportedSharedTemplateDeletion;
        if (cursor < line.content_end and source[cursor] == '@') {
            const text = source[cursor..line.content_end];
            if (std.mem.eql(u8, directiveName(text), "@pushslide")) capture_start = line.full_end;
        }
        cursor = line.full_end;
    }
    if (cursor != definition.start or shared_directive_offset < capture_start or
        shared_directive_offset >= definition.start)
    {
        return error.UnsupportedSharedTemplateDeletion;
    }
    _ = itemOwnedAnimationStart(source, shared_directive_offset) catch
        return error.UnsupportedSharedTemplateDeletion;

    var matching_ids: usize = 0;
    var selected_found = false;
    cursor = capture_start;
    while (cursor < definition.start) {
        const line = physicalLineAt(source, cursor);
        if (line.full_end > definition.start) return error.UnsupportedSharedTemplateDeletion;
        if (cursor < line.content_end and source[cursor] == '@') {
            const text = source[cursor..line.content_end];
            const name = directiveName(text);

            if (std.mem.eql(u8, name, "@slide") or
                std.mem.eql(u8, name, "@popslide") or
                isMorphStateDirective(name) or
                isMorphMutationDirective(name))
            {
                return error.UnsupportedSharedTemplateDeletion;
            }
            if (hasPotentialLetExpansion(text) and
                (directiveEmitsSlideItem(name) or isAnimationDirective(name)))
            {
                return error.UnsupportedSharedTemplateDeletion;
            }

            if (directiveEmitsSlideItem(name)) {
                // Malformed/dynamic identity tokens such as `id=` or a
                // generated @pop name cannot be treated as an id-less item:
                // the parser may retain an earlier duplicate id token.
                if (directiveHasDynamicIdentity(text, name)) {
                    return error.UnsupportedSharedTemplateDeletion;
                }
                const candidate_id = literalEmittedItemId(text, name);
                if (item_id) |sought| {
                    if (candidate_id != null and std.mem.eql(u8, candidate_id.?, sought)) {
                        matching_ids += 1;
                        if (cursor == shared_directive_offset) selected_found = true;
                    } else if (cursor == shared_directive_offset) {
                        return error.UnsupportedSharedTemplateDeletion;
                    }
                } else if (cursor == shared_directive_offset) {
                    if (candidate_id != null) return error.UnsupportedSharedTemplateDeletion;
                    selected_found = true;
                }
            } else if (cursor == shared_directive_offset) {
                return error.UnsupportedSharedTemplateDeletion;
            }
        } else if (cursor == shared_directive_offset) {
            return error.UnsupportedSharedTemplateDeletion;
        }
        cursor = line.full_end;
    }
    if (!selected_found or (item_id != null and matching_ids != 1)) {
        return error.AmbiguousSlideTemplateDependency;
    }
}

fn appendSharedTemplateInstanceDependencyEdits(
    allocator: std.mem.Allocator,
    source: []const u8,
    instance: DirectiveLine,
    item_id: ?[]const u8,
    edits: *std.ArrayList(Edit),
) (std.mem.Allocator.Error || PatchError)!usize {
    var cursor = instance.full_end;
    while (cursor < source.len) {
        const line = physicalLineAt(source, cursor);
        if (cursor < line.content_end and source[cursor] == '@') {
            const text = source[cursor..line.content_end];
            const name = directiveName(text);
            if (isSlideBoundaryDirective(name)) {
                // A @pushslide directly closes this instance by capturing it
                // as another reusable definition. Deleting the inherited item
                // would then have transitive dependencies outside this exact
                // definition, so decline instead of leaving them dangling.
                if (std.mem.eql(u8, name, "@pushslide")) {
                    return error.UnsupportedSharedTemplateDeletion;
                }
                return cursor;
            }

            if (item_id == null) {
                cursor = line.full_end;
                continue;
            } else if (directiveEmitsSlideItem(name)) {
                // A let-expanded item can introduce or replace id= even when
                // no identity token is visible in the physical source. Treat
                // every generated instance-local item as a possible collision
                // with the shared item being removed.
                if (hasPotentialLetExpansion(text) or directiveHasDynamicIdentity(text, name)) {
                    return error.AmbiguousSlideTemplateDependency;
                }
                if (literalEmittedItemId(text, name)) |candidate_id| {
                    if (std.mem.eql(u8, candidate_id, item_id.?)) {
                        return error.AmbiguousSlideTemplateDependency;
                    }
                }
            } else if (isMorphMutationDirective(name)) {
                const target = directiveContextName(text, name.len) orelse
                    return error.AmbiguousSlideTemplateDependency;
                if (!isLiteralItemId(target)) return error.AmbiguousSlideTemplateDependency;
                if (std.mem.eql(u8, target, item_id.?)) {
                    if (hasPotentialLetExpansion(text)) {
                        return error.UnsupportedSharedTemplateDeletion;
                    }
                    const animation_start = itemOwnedAnimationStart(source, cursor) catch
                        return error.UnsupportedSharedTemplateDeletion;
                    if (animation_start != cursor) return error.UnsupportedSharedTemplateDeletion;
                    try edits.append(allocator, .{
                        .start = cursor,
                        .end = line.full_end,
                        .replacement = "",
                    });
                    try appendBodyDeletionEdits(allocator, source, line.full_end, edits);
                }
            }
        }
        cursor = line.full_end;
    }
    return source.len;
}

fn literalEmittedItemId(line: []const u8, name: []const u8) ?[]const u8 {
    if (!directiveEmitsSlideItem(name)) return null;
    if (effectiveLiteralId(line, name.len)) |id| return id;
    if (std.mem.eql(u8, name, "@pop")) {
        const component_name = directiveContextName(line, name.len) orelse return null;
        if (isLiteralItemId(component_name)) return component_name;
    }
    return null;
}

fn directiveHasDynamicIdentity(line: []const u8, name: []const u8) bool {
    if (std.mem.eql(u8, name, "@pop")) {
        const component_name = directiveContextName(line, name.len) orelse return true;
        if (!isLiteralItemId(component_name)) return true;
    }

    var cursor = name.len;
    while (cursor < line.len) {
        while (cursor < line.len and isHorizontalWhitespace(line[cursor])) : (cursor += 1) {}
        if (cursor == line.len) break;
        const token_start = cursor;
        while (cursor < line.len and !isHorizontalWhitespace(line[cursor])) : (cursor += 1) {}
        const token = line[token_start..cursor];
        const equals = std.mem.indexOfScalar(u8, token, '=') orelse continue;
        const key = token[0..equals];
        if (std.mem.eql(u8, key, "text")) break;
        if (std.mem.eql(u8, key, "id") and !isLiteralItemId(token[equals + 1 ..])) return true;
    }
    return false;
}

fn slideTemplateInstanceBaseRegion(
    source: []const u8,
    slide_offset: usize,
) PatchError!SlideTemplateInstanceBaseRegion {
    const anchor = directiveLine(source, slide_offset) catch
        return error.UnsupportedSlideTemplateOverride;
    const anchor_text = source[anchor.start..anchor.content_end];
    const name = directiveName(anchor_text);
    if (!std.mem.eql(u8, name, "@popslide")) return error.UnsupportedSlideTemplateOverride;
    const template_name = directiveContextName(anchor_text, name.len) orelse
        return error.UnsupportedSlideTemplateOverride;
    if (!isReusableName(template_name)) return error.UnsupportedSlideTemplateOverride;

    return .{
        .anchor = anchor,
        .end = findSlideBoundary(source, slide_offset, true) catch
            return error.UnsupportedSlideTemplateOverride,
    };
}

fn validateSlideTemplateOverrideSnippet(snippet: []const u8) PatchError!void {
    try validateSnippet(snippet);

    const content = std.mem.trimEnd(u8, snippet, "\n");
    const first_line_end = std.mem.indexOfScalar(u8, content, '\n') orelse content.len;
    const directive = content[0..first_line_end];
    _ = try validateSlideTemplateOverrideDirectiveLine(directive);
}

fn validateSlideTemplateOverrideDirectiveLine(line: []const u8) PatchError![]const u8 {
    const name = directiveName(line);
    if (!isMorphMutationDirective(name)) return error.UnsupportedSlideTemplateOverride;

    var cursor = name.len;
    while (cursor < line.len and isHorizontalWhitespace(line[cursor])) : (cursor += 1) {}
    if (cursor == line.len) return error.InvalidLiteralValue;
    const target_start = cursor;
    while (cursor < line.len and !isHorizontalWhitespace(line[cursor])) : (cursor += 1) {}
    const target = line[target_start..cursor];
    if (!isLiteralItemId(target)) return error.InvalidLiteralValue;

    while (cursor < line.len) {
        while (cursor < line.len and isHorizontalWhitespace(line[cursor])) : (cursor += 1) {}
        if (cursor == line.len) break;
        const token_start = cursor;
        while (cursor < line.len and !isHorizontalWhitespace(line[cursor])) : (cursor += 1) {}
        const token = line[token_start..cursor];
        const equals = std.mem.indexOfScalar(u8, token, '=') orelse return error.InvalidLiteralValue;
        const key = token[0..equals];
        if (std.mem.eql(u8, key, "id")) return error.InvalidLiteralValue;
        if (std.mem.eql(u8, key, "text")) {
            try validateLiteralPatch(.{ .key = key, .value = line[token_start + equals + 1 ..] });
            break;
        }
        try validateLiteralPatch(.{ .key = key, .value = token[equals + 1 ..] });
    }
    return target;
}

fn validateSlideTemplateOverrideLocation(
    source: []const u8,
    slide_offset: usize,
    override_offset: usize,
    item_id: []const u8,
) PatchError!void {
    if (!isLiteralItemId(item_id)) return error.InvalidLiteralValue;
    const region = try slideTemplateInstanceBaseRegion(source, slide_offset);
    if (override_offset < region.anchor.full_end or override_offset >= region.end) {
        return error.UnsupportedSlideTemplateOverride;
    }
    const line = directiveLine(source, override_offset) catch
        return error.UnsupportedSlideTemplateOverride;
    if (line.content_end > region.end) return error.UnsupportedSlideTemplateOverride;
    const target = validateSlideTemplateOverrideDirectiveLine(source[line.start..line.content_end]) catch |err| switch (err) {
        error.InvalidLiteralValue => return error.InvalidLiteralValue,
        else => return error.UnsupportedSlideTemplateOverride,
    };
    if (!std.mem.eql(u8, target, item_id)) return error.UnsupportedSlideTemplateOverride;

    // Provenance should always point at the parser-effective mutation. Refuse
    // a stale earlier line instead of reporting success for an edit that a
    // later @set/@show/@hide would continue to mask.
    var latest_matching_offset: ?usize = null;
    var cursor = region.anchor.full_end;
    while (cursor < region.end) {
        const candidate_line = physicalLineAt(source, cursor);
        const candidate = source[cursor..candidate_line.content_end];
        // A let-expanded physical line can introduce a later override or
        // rewrite its target. Reject the whole provenance check rather than
        // bless an offset whose parser-effective ownership is ambiguous.
        if (hasPotentialLetExpansion(candidate)) return error.UnsupportedSlideTemplateOverride;
        if (cursor < candidate_line.content_end and source[cursor] == '@') {
            const candidate_name = directiveName(candidate);
            if (isMorphMutationDirective(candidate_name)) {
                if (directiveContextName(candidate, candidate_name.len)) |candidate_target| {
                    if (std.mem.eql(u8, candidate_target, item_id)) latest_matching_offset = cursor;
                }
            }
        }
        cursor = candidate_line.full_end;
    }
    if (latest_matching_offset != override_offset) return error.UnsupportedSlideTemplateOverride;
}

fn findSlideBoundary(source: []const u8, slide_offset: usize, stop_at_state: bool) PatchError!usize {
    var cursor: usize = undefined;
    if (directiveLine(source, slide_offset)) |slide_line| {
        const slide_name = directiveName(source[slide_line.start..slide_line.content_end]);
        if (std.mem.eql(u8, slide_name, "@slide") or std.mem.eql(u8, slide_name, "@popslide")) {
            cursor = slide_line.full_end;
        } else {
            if (slide_offset != 0 or hasExplicitSlideBoundary(source)) return error.InvalidSlideOffset;
            cursor = sourceStart(source);
        }
    } else |_| {
        if (slide_offset != 0 or hasExplicitSlideBoundary(source)) return error.InvalidSlideOffset;
        cursor = sourceStart(source);
    }
    while (cursor < source.len) {
        const line = physicalLineAt(source, cursor);
        if (cursor < line.content_end and source[cursor] == '@') {
            const name = directiveName(source[cursor..line.content_end]);
            if ((stop_at_state and isMorphStateDirective(name)) or
                std.mem.eql(u8, name, "@slide") or
                std.mem.eql(u8, name, "@popslide") or
                std.mem.eql(u8, name, "@pushslide"))
            {
                return cursor;
            }
        }
        cursor = line.full_end;
    }
    return source.len;
}

fn sourceStart(source: []const u8) usize {
    return if (std.mem.startsWith(u8, source, utf8_bom)) utf8_bom.len else 0;
}

fn isMorphStateDirective(name: []const u8) bool {
    return std.mem.eql(u8, name, "@state") or std.mem.eql(u8, name, "@state(morph)");
}

fn isAnimationDirective(name: []const u8) bool {
    return std.mem.eql(u8, name, "@anim") or
        (std.mem.startsWith(u8, name, "@anim(") and std.mem.endsWith(u8, name, ")"));
}

fn isMorphMutationDirective(name: []const u8) bool {
    return std.mem.eql(u8, name, "@set") or
        std.mem.eql(u8, name, "@show") or
        std.mem.eql(u8, name, "@hide");
}

fn isSlideBoundaryDirective(name: []const u8) bool {
    return isRenderedSlideAnchor(name) or
        std.mem.eql(u8, name, "@pushslide");
}

fn isRenderedSlideAnchor(name: []const u8) bool {
    return std.mem.eql(u8, name, "@slide") or std.mem.eql(u8, name, "@popslide");
}

fn directiveContextName(line: []const u8, directive_name_len: usize) ?[]const u8 {
    var cursor = directive_name_len;
    while (cursor < line.len and isHorizontalWhitespace(line[cursor])) : (cursor += 1) {}
    if (cursor == line.len) return null;
    const start = cursor;
    while (cursor < line.len and !isHorizontalWhitespace(line[cursor])) : (cursor += 1) {}
    return line[start..cursor];
}

fn hasExplicitSlideBoundary(source: []const u8) bool {
    var cursor = sourceStart(source);
    while (cursor < source.len) {
        const line = physicalLineAt(source, cursor);
        if (cursor < line.content_end and source[cursor] == '@') {
            const name = directiveName(source[cursor..line.content_end]);
            if (isSlideBoundaryDirective(name)) return true;
        }
        cursor = line.full_end;
    }
    return false;
}

fn appendBodyDeletionEdits(
    allocator: std.mem.Allocator,
    source: []const u8,
    body_start: usize,
    edits: *std.ArrayList(Edit),
) std.mem.Allocator.Error!void {
    var cursor = body_start;
    while (cursor < source.len) {
        const line = physicalLineAt(source, cursor);
        const content = source[cursor..line.content_end];
        if (content.len > 0 and content[0] == '@') break;
        if (content.len > 0 and content[0] != '#') {
            try edits.append(allocator, .{
                .start = cursor,
                .end = line.full_end,
                .replacement = "",
            });
        }
        cursor = line.full_end;
    }
}

fn itemBodyEndOffset(source: []const u8, body_start: usize) usize {
    var cursor = body_start;
    while (cursor < source.len) {
        const line = physicalLineAt(source, cursor);
        if (cursor < line.content_end and source[cursor] == '@') return cursor;
        cursor = line.full_end;
    }
    return source.len;
}

const ItemSceneKind = enum { base, template_base, morph };

const ItemSceneRange = struct {
    start: usize,
    end: usize,
    kind: ItemSceneKind,
};

const ItemSourceUnit = struct {
    start: usize,
    end: usize,
    directive_offset: usize,
};

fn resolveItemScene(source: []const u8, anchor: ItemSceneAnchor) PatchError!ItemSceneRange {
    return switch (anchor) {
        .base_slide => |slide_offset| resolveDirectBaseItemScene(source, slide_offset),
        .morph_state => |state_offset| resolveDirectMorphItemScene(source, state_offset),
    };
}

fn resolveDirectBaseItemScene(source: []const u8, slide_offset: usize) PatchError!ItemSceneRange {
    if (directiveLine(source, slide_offset)) |line| {
        const name = directiveName(source[line.start..line.content_end]);
        if (std.mem.eql(u8, name, "@slide") or std.mem.eql(u8, name, "@popslide")) {
            const end = findSlideBoundary(source, slide_offset, true) catch return error.InvalidItemScene;
            if (itemSceneEndsAtTemplateCapture(source, end)) return error.InvalidItemScene;
            return .{
                .start = line.full_end,
                .end = end,
                .kind = if (std.mem.eql(u8, name, "@popslide")) .template_base else .base,
            };
        }
        if (slide_offset != 0 or hasExplicitSlideBoundary(source)) return error.InvalidItemScene;
    } else |_| {
        if (slide_offset != 0 or hasExplicitSlideBoundary(source)) return error.InvalidItemScene;
    }
    return .{
        .start = sourceStart(source),
        .end = findSlideBoundary(source, 0, true) catch return error.InvalidItemScene,
        .kind = .base,
    };
}

fn resolveDirectMorphItemScene(source: []const u8, state_offset: usize) PatchError!ItemSceneRange {
    const state = directiveLine(source, state_offset) catch return error.InvalidItemScene;
    if (!isMorphStateDirective(directiveName(source[state.start..state.content_end]))) {
        return error.InvalidItemScene;
    }

    const Owner = enum { implicit, direct, template_instance, template_definition };
    var owner: Owner = .implicit;
    var cursor = sourceStart(source);
    while (cursor < state.start) {
        const line = physicalLineAt(source, cursor);
        if (line.full_end > state.start) return error.InvalidItemScene;
        if (cursor < line.content_end and source[cursor] == '@') {
            const name = directiveName(source[cursor..line.content_end]);
            if (std.mem.eql(u8, name, "@slide")) {
                owner = .direct;
            } else if (std.mem.eql(u8, name, "@popslide")) {
                owner = .template_instance;
            } else if (std.mem.eql(u8, name, "@pushslide")) {
                owner = .template_definition;
            }
        }
        cursor = line.full_end;
    }
    if (cursor != state.start or owner == .template_definition) {
        return error.InvalidItemScene;
    }
    const end = morphStateEndOffset(source, state_offset) catch return error.InvalidItemScene;
    if (itemSceneEndsAtTemplateCapture(source, end)) return error.InvalidItemScene;
    return .{
        .start = state.full_end,
        .end = end,
        .kind = .morph,
    };
}

fn itemSceneEndsAtTemplateCapture(source: []const u8, end: usize) bool {
    if (end >= source.len or source[end] != '@') return false;
    const line = directiveLine(source, end) catch return true;
    return std.mem.eql(u8, directiveName(source[line.start..line.content_end]), "@pushslide");
}

fn collectSceneItemUnits(
    allocator: std.mem.Allocator,
    source: []const u8,
    range: ItemSceneRange,
    units: *std.ArrayList(ItemSourceUnit),
) (std.mem.Allocator.Error || PatchError)!void {
    validateNoDanglingAnimation(source, range.start, range.end) catch
        return error.UnsupportedItemLayerMove;
    var cursor = range.start;
    while (cursor < range.end) {
        const line = physicalLineAt(source, cursor);
        if (line.full_end > range.end) return error.InvalidItemScene;
        if (cursor < line.content_end and source[cursor] == '@') {
            const text = source[cursor..line.content_end];
            const name = directiveName(text);
            if (isAnimationDirective(name)) {
                // Ownership is attached when the following item is visited.
            } else if (std.mem.eql(u8, name, "@bg")) {
                // Backgrounds are a pinned floor. Excluding their owned unit
                // leaves a physical gap between reorderable layer segments;
                // it also makes selecting @bg itself unsupported.
            } else if (directiveEmitsSlideItem(name)) {
                if (hasPotentialLetExpansion(text) or directiveHasDynamicIdentity(text, name)) {
                    return error.UnsupportedItemLayerMove;
                }
                if (std.mem.eql(u8, name, "@pop")) {
                    const component = directiveContextName(text, name.len) orelse
                        return error.UnsupportedItemLayerMove;
                    if (!isReusableName(component)) return error.UnsupportedItemLayerMove;
                }
                const owned_start = itemOwnedAnimationStart(source, cursor) catch
                    return error.UnsupportedItemLayerMove;
                if (owned_start < range.start) return error.UnsupportedItemLayerMove;
                const end = itemBodyEndOffset(source, line.full_end);
                if (end > range.end) return error.InvalidItemScene;
                if (hasPotentialLetExpansion(source[owned_start..end])) {
                    return error.UnsupportedItemLayerMove;
                }
                try units.append(allocator, .{
                    .start = owned_start,
                    .end = end,
                    .directive_offset = cursor,
                });
            } else if (!((range.kind == .morph or range.kind == .template_base) and
                isMorphMutationDirective(name)))
            {
                return error.UnsupportedItemLayerMove;
            }
        }
        cursor = line.full_end;
    }
}

fn findItemSourceUnit(units: []const ItemSourceUnit, directive_offset: usize) ?ItemSourceUnit {
    for (units) |unit| {
        if (unit.directive_offset == directive_offset) return unit;
    }
    return null;
}

fn batchDeleteIdSeen(
    dependencies: []const BatchDeleteDependency,
    hide_ids: []const []const u8,
    id: []const u8,
) bool {
    for (dependencies) |dependency| {
        if (std.mem.eql(u8, dependency.id, id)) return true;
    }
    for (hide_ids) |hidden| {
        if (std.mem.eql(u8, hidden, id)) return true;
    }
    return false;
}

fn batchDeleteLogicalSlideEnd(source: []const u8, range: ItemSceneRange) PatchError!usize {
    var cursor = range.end;
    while (cursor < source.len) {
        const line = physicalLineAt(source, cursor);
        if (cursor < line.content_end and source[cursor] == '@') {
            const name = directiveName(source[cursor..line.content_end]);
            if (isRenderedSlideAnchor(name)) return cursor;
            // This authored slide is being captured as a shared definition;
            // group deletion deliberately has no shared/transitive mode.
            if (std.mem.eql(u8, name, "@pushslide")) {
                return error.UnsupportedBatchDeletion;
            }
        }
        cursor = line.full_end;
    }
    return source.len;
}

fn appendBatchDeleteDependencyEdits(
    allocator: std.mem.Allocator,
    source: []const u8,
    slide_start: usize,
    slide_end: usize,
    dependencies: []const BatchDeleteDependency,
    edits: *std.ArrayList(Edit),
) (std.mem.Allocator.Error || PatchError)!void {
    var identity_counts = try allocator.alloc(usize, dependencies.len);
    defer allocator.free(identity_counts);
    @memset(identity_counts, 0);

    var cursor = slide_start;
    while (cursor < slide_end) {
        const line = physicalLineAt(source, cursor);
        if (line.full_end > slide_end) return error.UnsupportedBatchDeletion;
        const text = source[cursor..line.content_end];
        if (hasPotentialLetExpansion(text)) return error.UnsupportedBatchDeletion;

        if (cursor < line.content_end and source[cursor] == '@') {
            const name = directiveName(text);
            if (directiveEmitsSlideItem(name)) {
                if (directiveHasDynamicIdentity(text, name)) {
                    return error.UnsupportedBatchDeletion;
                }
                if (literalEmittedItemId(text, name)) |candidate_id| {
                    for (dependencies, 0..) |dependency, index| {
                        if (std.mem.eql(u8, dependency.id, candidate_id)) {
                            identity_counts[index] += 1;
                        }
                    }
                }
            } else if (isMorphMutationDirective(name)) {
                const target = validateSlideTemplateOverrideDirectiveLine(text) catch
                    return error.UnsupportedBatchDeletion;
                var dependency_index: ?usize = null;
                for (dependencies, 0..) |dependency, index| {
                    if (cursor > dependency.authored_offset and
                        std.mem.eql(u8, dependency.id, target))
                    {
                        dependency_index = index;
                        break;
                    }
                }
                if (dependency_index != null) {
                    const animation_start = itemOwnedAnimationStart(source, cursor) catch
                        return error.UnsupportedBatchDeletion;
                    if (animation_start != cursor) return error.UnsupportedBatchDeletion;
                    const dependency_end = itemBodyEndOffset(source, line.full_end);
                    if (dependency_end > slide_end or
                        hasPotentialLetExpansion(source[cursor..dependency_end]))
                    {
                        return error.UnsupportedBatchDeletion;
                    }
                    try edits.append(allocator, .{
                        .start = cursor,
                        .end = dependency_end,
                        .replacement = "",
                    });
                    cursor = dependency_end;
                    continue;
                }
            }
        }
        cursor = line.full_end;
    }
    for (identity_counts) |count| {
        if (count != 1) return error.UnsupportedBatchDeletion;
    }
}

fn batchInsertionNeedsSeparator(source: []const u8, insertion_offset: usize, deletions: []const Edit) bool {
    if (insertion_offset == 0 or insertion_offset == sourceStart(source)) return false;
    var preceding = insertion_offset;
    var found = true;
    while (found) {
        found = false;
        for (deletions) |edit| {
            if (edit.replacement.len == 0 and edit.end == preceding and edit.start < edit.end) {
                preceding = edit.start;
                found = true;
                break;
            }
        }
    }
    return preceding > sourceStart(source) and source[preceding - 1] != '\n';
}

fn validatePasteDestination(source: []const u8, range: ItemSceneRange) PatchError!void {
    var pending_animation = false;
    var cursor = range.start;
    while (cursor < range.end) {
        const line = physicalLineAt(source, cursor);
        if (line.full_end > range.end) return error.InvalidItemScene;
        if (cursor < line.content_end and source[cursor] == '@') {
            const text = source[cursor..line.content_end];
            const name = directiveName(text);
            if (isAnimationDirective(name)) {
                if (hasPotentialLetExpansion(text)) return error.UnsupportedClipboardItem;
                pending_animation = true;
            } else if (directiveEmitsSlideItem(name)) {
                pending_animation = false;
            } else if ((range.kind == .morph or range.kind == .template_base) and
                isMorphMutationDirective(name))
            {
                if (pending_animation) return error.UnsupportedClipboardItem;
            } else {
                return error.UnsupportedClipboardItem;
            }
        }
        cursor = line.full_end;
    }
    if (pending_animation) return error.UnsupportedClipboardItem;
}

fn validateNoDynamicItemIdentities(source: []const u8) PatchError!void {
    var cursor = sourceStart(source);
    while (cursor < source.len) {
        const line = physicalLineAt(source, cursor);
        const text = source[cursor..line.content_end];
        // A generated physical line can become an item directive after @let
        // expansion, so global ID uniqueness cannot be proven in such a deck.
        if (hasPotentialLetExpansion(text)) return error.UnsupportedClipboardItem;
        if (cursor < line.content_end and source[cursor] == '@') {
            const name = directiveName(text);
            if (directiveEmitsSlideItem(name) and directiveHasDynamicIdentity(text, name)) {
                return error.UnsupportedClipboardItem;
            }
        }
        cursor = line.full_end;
    }
}

const CapturedSnippetInfo = struct {
    directive_offset: usize,
    component_name: ?[]const u8,
};

fn validateCapturedItemSnippet(snippet: []const u8) PatchError!CapturedSnippetInfo {
    if (snippet.len == 0 or std.mem.startsWith(u8, snippet, utf8_bom) or
        hasPotentialLetExpansion(snippet))
    {
        return error.UnsupportedClipboardItem;
    }
    for (snippet, 0..) |byte, index| {
        if (byte == '\r' and (index + 1 == snippet.len or snippet[index + 1] != '\n')) {
            return error.UnsupportedClipboardItem;
        }
    }

    var item_offset: ?usize = null;
    var component_name: ?[]const u8 = null;
    var saw_animation = false;
    var cursor: usize = 0;
    while (cursor < snippet.len) {
        const line = physicalLineAt(snippet, cursor);
        const text = snippet[cursor..line.content_end];
        if (text.len > 0 and text[0] == '@') {
            const name = directiveName(text);
            if (item_offset == null and isAnimationDirective(name)) {
                saw_animation = true;
            } else if (item_offset == null and
                (std.mem.eql(u8, name, "@box") or std.mem.eql(u8, name, "@pop")))
            {
                if (directiveHasDynamicIdentity(text, name)) return error.UnsupportedClipboardItem;
                var attributes_start = name.len;
                if (std.mem.eql(u8, name, "@pop")) {
                    const component = directiveContextName(text, name.len) orelse
                        return error.UnsupportedClipboardItem;
                    if (!isReusableName(component)) return error.UnsupportedClipboardItem;
                    component_name = component;
                    attributes_start = @intFromPtr(component.ptr) - @intFromPtr(text.ptr) + component.len;
                }
                try validateClipboardDirectiveAttributes(text, attributes_start);
                item_offset = cursor;
            } else {
                return error.UnsupportedClipboardItem;
            }
        } else if (item_offset == null and !saw_animation) {
            // A captured unit begins at its directive (or earliest owned
            // animation), never at detached formatting/prose.
            return error.UnsupportedClipboardItem;
        }
        cursor = line.full_end;
    }
    return .{
        .directive_offset = item_offset orelse return error.UnsupportedClipboardItem,
        .component_name = component_name,
    };
}

fn validateClipboardDirectiveAttributes(line: []const u8, attributes_start: usize) PatchError!void {
    var cursor = attributes_start;
    while (cursor < line.len) {
        while (cursor < line.len and isHorizontalWhitespace(line[cursor])) : (cursor += 1) {}
        if (cursor == line.len) break;
        const token_start = cursor;
        while (cursor < line.len and !isHorizontalWhitespace(line[cursor])) : (cursor += 1) {}
        const token = line[token_start..cursor];
        const equals = std.mem.indexOfScalar(u8, token, '=') orelse
            return error.UnsupportedClipboardItem;
        const key = token[0..equals];
        const value = token[equals + 1 ..];
        if (!isAttributeName(key)) return error.UnsupportedClipboardItem;
        if (std.mem.eql(u8, key, "text")) return;
        validateLiteralPatch(.{ .key = key, .value = value }) catch
            return error.UnsupportedClipboardItem;

        var earlier_cursor = attributes_start;
        while (earlier_cursor < token_start) {
            while (earlier_cursor < token_start and isHorizontalWhitespace(line[earlier_cursor])) : (earlier_cursor += 1) {}
            if (earlier_cursor == token_start) break;
            const earlier_start = earlier_cursor;
            while (earlier_cursor < token_start and !isHorizontalWhitespace(line[earlier_cursor])) : (earlier_cursor += 1) {}
            const earlier = line[earlier_start..earlier_cursor];
            const earlier_equals = std.mem.indexOfScalar(u8, earlier, '=') orelse
                return error.UnsupportedClipboardItem;
            if (std.mem.eql(u8, earlier[0..earlier_equals], key)) {
                return error.UnsupportedClipboardItem;
            }
        }
    }
}

fn capturedSnippetHasAnimation(snippet: []const u8, item_offset: usize) bool {
    if (item_offset != 0) return true;
    const line = physicalLineAt(snippet, item_offset);
    const text = snippet[line.start..line.content_end];
    const name = directiveName(text);
    var cursor = name.len;
    while (cursor < text.len) {
        while (cursor < text.len and isHorizontalWhitespace(text[cursor])) : (cursor += 1) {}
        if (cursor == text.len) break;
        const token_start = cursor;
        while (cursor < text.len and !isHorizontalWhitespace(text[cursor])) : (cursor += 1) {}
        const token = text[token_start..cursor];
        const equals = std.mem.indexOfScalar(u8, token, '=') orelse continue;
        const key = token[0..equals];
        if (std.mem.eql(u8, key, "text")) break;
        if (std.mem.eql(u8, key, "anim") or std.mem.eql(u8, key, "effect")) return true;
    }
    return false;
}

fn appendSourceWithLineEnding(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    source: []const u8,
    newline: []const u8,
) std.mem.Allocator.Error!void {
    var cursor: usize = 0;
    while (cursor < source.len) {
        const line = physicalLineAt(source, cursor);
        try output.appendSlice(allocator, source[line.start..line.content_end]);
        if (line.full_end > line.content_end) try output.appendSlice(allocator, newline);
        cursor = line.full_end;
    }
}

fn validateCoordinate(value: f32) PatchError!void {
    if (!std.math.isFinite(value)) return error.InvalidCoordinate;
}

fn itemOwnedAnimationStart(source: []const u8, item_start: usize) PatchError!usize {
    var pending_start: ?usize = null;
    var pending_crossed_directive = false;
    var cursor = sourceStart(source);
    while (cursor < item_start) {
        const line = physicalLineAt(source, cursor);
        if (line.full_end > item_start) return error.UnsupportedItemDuplication;
        if (cursor < line.content_end and source[cursor] == '@') {
            const name = directiveName(source[cursor..line.content_end]);
            if (isAnimationDirective(name)) {
                if (pending_start == null) pending_start = cursor;
            } else if (directiveEmitsSlideItem(name)) {
                pending_start = null;
                pending_crossed_directive = false;
            } else if (pending_start != null) {
                // The parser can carry a pending animation across global and
                // context directives. Copying that contiguous range would also
                // duplicate those structural directives, while omitting it
                // would lose the item's animation. Decline the ambiguous case.
                pending_crossed_directive = true;
            }
        }
        cursor = line.full_end;
    }
    if (cursor != item_start) return error.UnsupportedItemDuplication;
    if (pending_start) |start| {
        if (pending_crossed_directive) return error.UnsupportedItemDuplication;
        return start;
    }
    return item_start;
}

fn hasPotentialLetExpansion(value: []const u8) bool {
    const first = std.mem.indexOfScalar(u8, value, '$') orelse return false;
    const last = std.mem.lastIndexOfScalar(u8, value, '$') orelse return false;
    return first != last;
}

/// Resolve the parser-effective literal component definition at one source
/// position. Any preceding let-expanded line could synthesize or rename a
/// shadowing `@push`, so component clipboard provenance is intentionally
/// unavailable in such a prefix.
fn resolveLiteralComponentDefinitionBefore(
    source: []const u8,
    before_offset: usize,
    component_name: []const u8,
) PatchError!usize {
    if (!isReusableName(component_name) or
        before_offset > source.len or
        !isPhysicalLineBoundary(source, before_offset))
    {
        return error.UnsupportedClipboardItem;
    }

    var latest: ?usize = null;
    var cursor = sourceStart(source);
    while (cursor < before_offset) {
        const line = physicalLineAt(source, cursor);
        if (line.full_end > before_offset) return error.UnsupportedClipboardItem;
        const text = source[cursor..line.content_end];
        if (hasPotentialLetExpansion(text)) return error.UnsupportedClipboardItem;
        if (cursor < line.content_end and source[cursor] == '@') {
            const name = directiveName(text);
            if (std.mem.eql(u8, name, "@push")) {
                const candidate = directiveContextName(text, name.len) orelse
                    return error.UnsupportedClipboardItem;
                if (!isReusableName(candidate)) return error.UnsupportedClipboardItem;
                if (std.mem.eql(u8, candidate, component_name)) latest = cursor;
            }
        }
        cursor = line.full_end;
    }
    if (cursor != before_offset) return error.UnsupportedClipboardItem;
    return latest orelse error.UnsupportedClipboardItem;
}

fn hasLiteralItemId(source: []const u8, sought: []const u8) bool {
    var cursor = sourceStart(source);
    while (cursor < source.len) {
        const line = physicalLineAt(source, cursor);
        if (cursor < line.content_end and source[cursor] == '@') {
            const line_text = source[cursor..line.content_end];
            const name = directiveName(line_text);
            if (effectiveLiteralId(line_text, name.len)) |id| {
                if (std.mem.eql(u8, id, sought)) return true;
            } else if (std.mem.eql(u8, name, "@pop")) {
                // A component instance without explicit id= inherits its
                // component name as its item ID in the parser.
                if (directiveContextName(line_text, name.len)) |component_name| {
                    if (isLiteralItemId(component_name) and std.mem.eql(u8, component_name, sought)) {
                        return true;
                    }
                }
            }
        }
        cursor = line.full_end;
    }
    return false;
}

fn effectiveLiteralId(line: []const u8, directive_name_len: usize) ?[]const u8 {
    var effective: ?[]const u8 = null;
    var cursor = directive_name_len;
    while (cursor < line.len) {
        while (cursor < line.len and isHorizontalWhitespace(line[cursor])) : (cursor += 1) {}
        if (cursor == line.len) break;
        const token_start = cursor;
        while (cursor < line.len and !isHorizontalWhitespace(line[cursor])) : (cursor += 1) {}
        const token = line[token_start..cursor];
        const equals = std.mem.indexOfScalar(u8, token, '=') orelse continue;
        const key = token[0..equals];
        if (std.mem.eql(u8, key, "text")) break;
        if (!std.mem.eql(u8, key, "id")) continue;
        const raw_value = token[equals + 1 ..];
        const parser_value_end = std.mem.indexOfScalar(u8, raw_value, '=') orelse raw_value.len;
        const value = raw_value[0..parser_value_end];
        effective = if (isLiteralItemId(value)) value else null;
    }
    return effective;
}

fn findInlineTextToken(source: []const u8, line: DirectiveLine) ?Span {
    var cursor = line.start;
    while (cursor < line.content_end) {
        while (cursor < line.content_end and isHorizontalWhitespace(source[cursor])) : (cursor += 1) {}
        if (cursor == line.content_end) break;
        const token_start = cursor;
        while (cursor < line.content_end and !isHorizontalWhitespace(source[cursor])) : (cursor += 1) {}
        const token = source[token_start..cursor];
        const equals_index = std.mem.indexOfScalar(u8, token, '=') orelse continue;
        if (std.mem.eql(u8, token[0..equals_index], "text")) {
            return .{ .start = token_start, .end = line.content_end };
        }
    }
    return null;
}

fn validateBodyText(value: []const u8) PatchError!void {
    var lines = std.mem.splitScalar(u8, value, '\n');
    while (lines.next()) |line| {
        if (line.len > 0 and (line[0] == '@' or line[0] == '#')) return error.InvalidLiteralValue;
    }
}

fn validateSnippet(snippet: []const u8) PatchError!void {
    if (snippet.len == 0 or std.mem.indexOfScalar(u8, snippet, '\r') != null) return error.InvalidSnippet;
    const content = std.mem.trimEnd(u8, snippet, "\n");
    if (content.len == 0) return error.InvalidSnippet;

    var lines = std.mem.splitScalar(u8, content, '\n');
    const directive = lines.next() orelse return error.InvalidSnippet;
    validateDirectiveText(directive) catch return error.InvalidSnippet;
    while (lines.next()) |line| {
        if (line.len > 0 and line[0] == '@') return error.InvalidSnippet;
    }
}

fn appendNormalizedLines(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    value: []const u8,
    newline: []const u8,
) std.mem.Allocator.Error!void {
    var pieces = std.mem.splitScalar(u8, value, '\n');
    var first = true;
    while (pieces.next()) |piece| {
        if (!first) try output.appendSlice(allocator, newline);
        try output.appendSlice(allocator, piece);
        first = false;
    }
}

fn findPatch(patches: []const LiteralAttributePatch, key: []const u8) ?usize {
    for (patches, 0..) |patch, index| {
        if (std.mem.eql(u8, patch.key, key)) return index;
    }
    return null;
}

fn validateLiteralPatch(patch: LiteralAttributePatch) PatchError!void {
    if (!isAttributeName(patch.key)) return error.InvalidAttribute;
    const is_text = std.mem.eql(u8, patch.key, "text");
    if (!is_text and patch.value.len == 0) return error.InvalidLiteralValue;
    for (patch.value) |byte| {
        if (byte == '\r' or byte == '\n' or
            (!is_text and (isHorizontalWhitespace(byte) or byte == '=')))
        {
            return error.InvalidLiteralValue;
        }
    }
    if (isColorAttribute(patch.key) and !validColorLiteral(patch.key, patch.value)) {
        return error.InvalidColorLiteral;
    }
}

fn isAttributeName(key: []const u8) bool {
    if (key.len == 0 or !(std.ascii.isAlphabetic(key[0]) or key[0] == '_')) return false;
    for (key[1..]) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-')) return false;
    }
    return true;
}

fn isReusableName(name: []const u8) bool {
    return isAttributeName(name);
}

fn isLiteralItemId(id: []const u8) bool {
    return id.len > 0 and std.mem.indexOfAny(u8, id, " \t\r\n=$") == null;
}

fn isColorAttribute(key: []const u8) bool {
    return std.mem.eql(u8, key, "color") or
        std.mem.eql(u8, key, "bg") or
        std.mem.eql(u8, key, "bullet_color") or
        std.mem.eql(u8, key, "shadow");
}

fn validColorLiteral(key: []const u8, value: []const u8) bool {
    if ((std.mem.eql(u8, key, "shadow") or std.mem.eql(u8, key, "bg")) and
        std.mem.eql(u8, value, "none")) return true;
    if (value.len != 9 or value[0] != '#') return false;
    for (value[1..]) |byte| {
        if (!std.ascii.isHex(byte)) return false;
    }
    return true;
}

fn validateDirectiveText(directive: []const u8) PatchError!void {
    if (directive.len < 2 or directive[0] != '@') return error.InvalidDirectiveText;
    for (directive) |byte| {
        if (byte == '\r' or byte == '\n') return error.InvalidDirectiveText;
    }
    const name = directiveName(directive);
    if (name.len < 2) return error.InvalidDirectiveText;
}

fn directiveName(line: []const u8) []const u8 {
    var end: usize = 0;
    while (end < line.len and !isHorizontalWhitespace(line[end])) : (end += 1) {}
    return line[0..end];
}

fn isPhysicalLineBoundary(source: []const u8, offset: usize) bool {
    if (offset > source.len) return false;
    if (offset == source.len) return true;
    if (offset == 0) return !std.mem.startsWith(u8, source, utf8_bom);
    if (offset == utf8_bom.len and std.mem.startsWith(u8, source, utf8_bom)) return true;
    return source[offset - 1] == '\n';
}

fn lineEndingNear(source: []const u8, offset: usize) []const u8 {
    if (offset < source.len) {
        if (std.mem.indexOfScalar(u8, source[offset..], '\n')) |relative| {
            const newline = offset + relative;
            return if (newline > offset and source[newline - 1] == '\r') "\r\n" else "\n";
        }
    }
    if (offset > 0) {
        if (std.mem.lastIndexOfScalar(u8, source[0..offset], '\n')) |newline| {
            return if (newline > 0 and source[newline - 1] == '\r') "\r\n" else "\n";
        }
    }
    return "\n";
}

fn physicalLineAt(source: []const u8, start: usize) DirectiveLine {
    const line_end = if (std.mem.indexOfScalar(u8, source[start..], '\n')) |relative|
        start + relative
    else
        source.len;
    const content_end = if (line_end > start and source[line_end - 1] == '\r') line_end - 1 else line_end;
    const full_end = if (line_end < source.len) line_end + 1 else line_end;
    return .{ .start = start, .content_end = content_end, .full_end = full_end };
}

fn previousPhysicalLine(source: []const u8, before: usize) ?DirectiveLine {
    const first_content = sourceStart(source);
    if (before <= first_content) return null;

    var line_end = before;
    if (line_end > 0 and source[line_end - 1] == '\n') line_end -= 1;
    const content_end = if (line_end > 0 and source[line_end - 1] == '\r') line_end - 1 else line_end;
    const physical_start = if (std.mem.lastIndexOfScalar(u8, source[0..content_end], '\n')) |newline|
        newline + 1
    else
        0;
    const content_start = if (physical_start == 0 and first_content != 0) first_content else physical_start;
    return .{
        .start = content_start,
        .content_end = content_end,
        .full_end = before,
    };
}

/// Find the closest preceding physical line that the parser treats as a
/// directive. Non-directive body, comments, and blank lines are skipped; they
/// remain in place when callers use the result as an insertion anchor.
fn previousDirectiveLine(source: []const u8, before: usize) ?DirectiveLine {
    var cursor = before;
    while (previousPhysicalLine(source, cursor)) |line| {
        if (line.start < line.content_end and source[line.start] == '@') {
            return directiveLine(source, line.start) catch return null;
        }
        // The physical start differs from the directive start only on a BOM
        // line, which cannot precede another line without a newline terminator.
        cursor = if (line.start == sourceStart(source) and sourceStart(source) != 0)
            0
        else
            line.start;
    }
    return null;
}

fn replaceRange(
    allocator: std.mem.Allocator,
    source: []const u8,
    start: usize,
    end: usize,
    replacement: []const u8,
) (std.mem.Allocator.Error || PatchError)!PatchResult {
    const edit = [_]Edit{.{ .start = start, .end = end, .replacement = replacement }};
    return applyEdits(allocator, source, &edit);
}

fn applyEdits(
    allocator: std.mem.Allocator,
    source: []const u8,
    edits: []const Edit,
) (std.mem.Allocator.Error || PatchError)!PatchResult {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try output.ensureTotalCapacity(allocator, source.len);

    var copied_until: usize = 0;
    for (edits) |edit| {
        try output.appendSlice(allocator, source[copied_until..edit.start]);
        try output.appendSlice(allocator, edit.replacement);
        copied_until = edit.end;
    }
    try output.appendSlice(allocator, source[copied_until..]);
    return finishResult(allocator, &output, source.len);
}

fn finishResult(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    old_length: usize,
) (std.mem.Allocator.Error || PatchError)!PatchResult {
    const byte_delta = try signedLengthDelta(output.items.len, old_length);
    return .{
        .source = try output.toOwnedSlice(allocator),
        .byte_delta = byte_delta,
    };
}

const DirectiveLine = struct {
    start: usize,
    content_end: usize,
    full_end: usize,
};

fn directiveLine(source: []const u8, directive_offset: usize) PatchError!DirectiveLine {
    if (directive_offset >= source.len or source[directive_offset] != '@') {
        return error.InvalidDirectiveOffset;
    }

    const physical_line_start = if (std.mem.lastIndexOfScalar(u8, source[0..directive_offset], '\n')) |newline|
        newline + 1
    else
        0;
    const expected_start = if (physical_line_start == 0 and std.mem.startsWith(u8, source, "\xEF\xBB\xBF"))
        3
    else
        physical_line_start;
    if (directive_offset != expected_start) return error.InvalidDirectiveOffset;

    const line_end = if (std.mem.indexOfScalar(u8, source[directive_offset..], '\n')) |relative|
        directive_offset + relative
    else
        source.len;
    const content_end = if (line_end > directive_offset and source[line_end - 1] == '\r')
        line_end - 1
    else
        line_end;

    var directive_end = directive_offset;
    while (directive_end < content_end and !isHorizontalWhitespace(source[directive_end])) : (directive_end += 1) {}
    if (directive_end == directive_offset + 1) return error.InvalidDirectiveOffset;

    const full_end = if (line_end < source.len) line_end + 1 else line_end;
    return .{ .start = directive_offset, .content_end = content_end, .full_end = full_end };
}

fn formatCoordinate(buffer: *[64]u8, value: f32) PatchError![]const u8 {
    if (!std.math.isFinite(value)) return error.InvalidCoordinate;
    const normalized: f32 = if (value == 0) 0 else value;
    return std.fmt.bufPrint(buffer, "{d}", .{normalized}) catch return error.InvalidCoordinate;
}

fn isHorizontalWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t';
}

fn trimHorizontalWhitespaceEnd(source: []const u8, end: usize, lower_bound: usize) usize {
    var result = end;
    while (result > lower_bound and isHorizontalWhitespace(source[result - 1])) : (result -= 1) {}
    return result;
}

fn sortEditsByPosition(edits: []Edit) void {
    var index: usize = 1;
    while (index < edits.len) : (index += 1) {
        var moving = index;
        while (moving > 0 and edits[moving].start < edits[moving - 1].start) : (moving -= 1) {
            std.mem.swap(Edit, &edits[moving], &edits[moving - 1]);
        }
    }
}

fn validateNonOverlappingEdits(edits: []const Edit) PatchError!void {
    if (edits.len < 2) return;
    for (edits[0 .. edits.len - 1], edits[1..]) |left, right| {
        if (right.start < left.end) return error.OverlappingSourceEdits;
    }
}

fn signedLengthDelta(new_length: usize, old_length: usize) PatchError!isize {
    if (new_length >= old_length) {
        return std.math.cast(isize, new_length - old_length) orelse error.SourceTooLarge;
    }
    const magnitude = std.math.cast(isize, old_length - new_length) orelse return error.SourceTooLarge;
    return -magnitude;
}

fn expectPatch(
    source: []const u8,
    directive: []const u8,
    geometry: GeometryTextPatch,
    expected: []const u8,
) !void {
    const allocator = std.testing.allocator;
    const offset = std.mem.indexOf(u8, source, directive) orelse return error.TestUnexpectedResult;
    const result = try patchGeometryText(allocator, source, offset, geometry);
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings(expected, result.source);
    const expected_delta = try signedLengthDelta(expected.len, source.len);
    try std.testing.expectEqual(expected_delta, result.byte_delta);
}

test "replaces only existing geometry value bytes" {
    const source =
        "# x=999 remains a comment\n" ++
        "@box  img=hero.png  x=100\ty=200 w=300 h=400 color=#aabbccdd text=Keep x=7 and y=8 exactly\n" ++
        "# trailing comment\n";
    const expected =
        "# x=999 remains a comment\n" ++
        "@box  img=hero.png  x=10.5\ty=-20 w=640 h=480 color=#aabbccdd text=Keep x=7 and y=8 exactly\n" ++
        "# trailing comment\n";

    try expectPatch(source, "@box", .{
        .x = "10.5",
        .y = "-20",
        .w = "640",
        .h = "480",
    }, expected);
}

test "inserts missing attributes immediately before inline text" {
    const source = "@pop title  color=#ffffffff   text=Hello = world  x=not-an-attribute\n";
    const expected = "@pop title  color=#ffffffff   x=42 y=84 w=900 h=120 text=Hello = world  x=not-an-attribute\n";

    try expectPatch(source, "@pop", .{
        .x = "42",
        .y = "84",
        .w = "900",
        .h = "120",
    }, expected);
}

test "mixed replacement and insertion preserves surrounding spacing" {
    const source = "@box\tx=1   color=#fff\ty=2\ttext=Words\n";
    const expected = "@box\tx=11   color=#fff\ty=22\tw=333 h=444 text=Words\n";

    try expectPatch(source, "@box", .{
        .x = "11",
        .y = "22",
        .w = "333",
        .h = "444",
    }, expected);
}

test "appends missing attributes before preserved trailing whitespace" {
    const source = "@box img=hero.png  \nnext line\n";
    const expected = "@box img=hero.png x=12 y=34  \nnext line\n";

    try expectPatch(source, "@box", .{ .x = "12", .y = "34" }, expected);
}

test "preserves CRLF line endings and patches the selected directive" {
    const source = "@box x=1 y=2 text=First\r\n@box x=3 text=Second y=inside text\r\n";
    const expected = "@box x=1 y=2 text=First\r\n@box x=30 y=40 text=Second y=inside text\r\n";

    try expectPatch(source, "@box x=3", .{ .x = "30", .y = "40" }, expected);
}

test "omitted dimensions remain byte-identical" {
    const source = "@box x=1 y=2 w=00300 h=00400 text=Image\n";
    const expected = "@box x=9 y=8 w=00300 h=00400 text=Image\n";

    try expectPatch(source, "@box", .{ .x = "9", .y = "8" }, expected);
}

test "patches empty values and the parser-effective duplicate" {
    const source = "@box x=old x= y=first y=last text=Duplicate geometry\n";
    const expected = "@box x=old x=50 y=first y=60 text=Duplicate geometry\n";

    try expectPatch(source, "@box", .{ .x = "50", .y = "60" }, expected);
}

test "numeric API formats finite decimal coordinates" {
    const allocator = std.testing.allocator;
    const source = "@set hero x=0 y=0\n";
    const result = try patchGeometry(allocator, source, 0, .{
        .x = 12.5,
        .y = -3.25,
        .w = 640,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("@set hero x=12.5 y=-3.25 w=640\n", result.source);
    try std.testing.expectEqual(@as(isize, 13), result.byte_delta);
}

test "numeric API rejects non-finite coordinates" {
    try std.testing.expectError(error.InvalidCoordinate, patchGeometry(
        std.testing.allocator,
        "@box\n",
        0,
        .{ .x = std.math.nan(f32), .y = 0 },
    ));
}

test "accepts a directive after a UTF-8 BOM" {
    const source = "\xEF\xBB\xBF@box text=Hello\n";
    const expected = "\xEF\xBB\xBF@box x=1 y=2 text=Hello\n";

    try expectPatch(source, "@box", .{ .x = "1", .y = "2" }, expected);
}

test "rejects offsets that do not begin a directive line" {
    const source = "# comment\n@box x=1 y=2\n";

    try std.testing.expectError(
        error.InvalidDirectiveOffset,
        patchGeometry(std.testing.allocator, source, source.len, .{ .x = 1, .y = 2 }),
    );
    try std.testing.expectError(
        error.InvalidDirectiveOffset,
        patchGeometry(std.testing.allocator, source, 2, .{ .x = 1, .y = 2 }),
    );
    const directive_offset = std.mem.indexOf(u8, source, "@box") orelse unreachable;
    try std.testing.expectError(
        error.InvalidDirectiveOffset,
        patchGeometry(std.testing.allocator, source, directive_offset + 1, .{ .x = 1, .y = 2 }),
    );
}

test "atomic geometry edits mix patches and insertion on original BOM CRLF offsets" {
    const parser = @import("parser.zig");
    const slides = @import("slides.zig");
    const source =
        "\xEF\xBB\xBF@slide\r\n" ++
        "@box id=first x=1 y=2 w=30 h=40 text=One\r\n" ++
        "# between\r\n" ++
        "@box id=second x=5 y=6 text=Two\r\n";
    const first_offset = std.mem.indexOf(u8, source, "@box id=first") orelse unreachable;
    const second_offset = std.mem.indexOf(u8, source, "@box id=second") orelse unreachable;
    const edits = [_]GeometrySourceEdit{
        .{ .insert = .{
            .insertion_offset = second_offset,
            .snippet = "@box id=middle x=30 y=40 text=Inserted",
        } },
        .{ .patch = .{
            .directive_offset = first_offset,
            .geometry = .{ .x = 100, .y = 200 },
        } },
        .{ .patch = .{
            .directive_offset = second_offset,
            .geometry = .{ .x = 500, .y = 600, .w = 70, .h = 80 },
        } },
    };
    const expected =
        "\xEF\xBB\xBF@slide\r\n" ++
        "@box id=first x=100 y=200 w=30 h=40 text=One\r\n" ++
        "# between\r\n" ++
        "@box id=middle x=30 y=40 text=Inserted\r\n" ++
        "@box id=second x=500 y=600 w=70 h=80 text=Two\r\n";

    const result = try applyGeometryEdits(std.testing.allocator, source, &edits);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(expected, result.source);
    try std.testing.expectEqual(try signedLengthDelta(expected.len, source.len), result.byte_delta);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const deck = try slides.SlideShow.new(arena.allocator());
    const context = try parser.constructSlidesFromBuf(result.source, deck, arena.allocator());
    defer context.deinit();
    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    const items = deck.slides.items[0].items.?.items;
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqualStrings("first", items[0].id.?);
    try std.testing.expectApproxEqAbs(@as(f32, 100), items[0].position.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 200), items[0].position.y, 0.0001);
    try std.testing.expectEqualStrings("middle", items[1].id.?);
    try std.testing.expectEqualStrings("second", items[2].id.?);
    try std.testing.expectApproxEqAbs(@as(f32, 500), items[2].position.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 600), items[2].position.y, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 70), items[2].size.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 80), items[2].size.y, 0.0001);
}

test "atomic geometry edits keep descending original offsets stable" {
    const source =
        "@slide\n" ++
        "@box id=low text=Missing attributes grow this lower line\n" ++
        "@box id=high x=3 y=4 text=Higher source offset\n";
    const low_offset = std.mem.indexOf(u8, source, "@box id=low") orelse unreachable;
    const high_offset = std.mem.indexOf(u8, source, "@box id=high") orelse unreachable;
    const edits = [_]GeometrySourceEdit{
        .{ .patch = .{
            .directive_offset = low_offset,
            .geometry = .{ .x = 10, .y = 20, .w = 30, .h = 40 },
        } },
        .{ .patch = .{
            .directive_offset = high_offset,
            .geometry = .{ .x = 300, .y = 400 },
        } },
    };
    const expected =
        "@slide\n" ++
        "@box id=low x=10 y=20 w=30 h=40 text=Missing attributes grow this lower line\n" ++
        "@box id=high x=300 y=400 text=Higher source offset\n";

    const result = try applyGeometryEdits(std.testing.allocator, source, &edits);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(expected, result.source);
}

test "atomic geometry edits retain caller order for shared unterminated EOF insertion" {
    const source = "@slide";
    const edits = [_]GeometrySourceEdit{
        .{ .insert = .{ .insertion_offset = source.len, .snippet = "@box id=first x=1 y=2" } },
        .{ .insert = .{ .insertion_offset = source.len, .snippet = "@box id=second x=3 y=4" } },
        .{ .insert = .{ .insertion_offset = source.len, .snippet = "@box id=third x=5 y=6" } },
    };
    const expected =
        "@slide\n" ++
        "@box id=first x=1 y=2\n" ++
        "@box id=second x=3 y=4\n" ++
        "@box id=third x=5 y=6\n";

    const result = try applyGeometryEdits(std.testing.allocator, source, &edits);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(expected, result.source);
    try std.testing.expectEqual(try signedLengthDelta(expected.len, source.len), result.byte_delta);
}

test "atomic geometry edits reject overlapping stale and invalid operations" {
    const source = "@slide\n@box id=one x=1 y=2\n@box id=two x=3 y=4\n";
    const first_offset = std.mem.indexOf(u8, source, "@box id=one") orelse unreachable;

    const overlapping = [_]GeometrySourceEdit{
        .{ .patch = .{ .directive_offset = first_offset, .geometry = .{ .x = 10, .y = 20 } } },
        .{ .patch = .{ .directive_offset = first_offset, .geometry = .{ .x = 30, .y = 40 } } },
    };
    try std.testing.expectError(
        error.OverlappingSourceEdits,
        applyGeometryEdits(std.testing.allocator, source, &overlapping),
    );

    const stale_patch = [_]GeometrySourceEdit{
        .{ .patch = .{ .directive_offset = first_offset + 1, .geometry = .{ .x = 10, .y = 20 } } },
    };
    try std.testing.expectError(
        error.InvalidDirectiveOffset,
        applyGeometryEdits(std.testing.allocator, source, &stale_patch),
    );

    const stale_insert = [_]GeometrySourceEdit{
        .{ .insert = .{ .insertion_offset = first_offset + 1, .snippet = "@box id=three" } },
    };
    try std.testing.expectError(
        error.InvalidInsertionOffset,
        applyGeometryEdits(std.testing.allocator, source, &stale_insert),
    );

    const invalid_snippet = [_]GeometrySourceEdit{
        .{ .patch = .{ .directive_offset = first_offset, .geometry = .{ .x = 10, .y = 20 } } },
        .{ .insert = .{ .insertion_offset = source.len, .snippet = "@box id=three\n@slide" } },
    };
    try std.testing.expectError(
        error.InvalidSnippet,
        applyGeometryEdits(std.testing.allocator, source, &invalid_snippet),
    );

    const invalid_coordinate = [_]GeometrySourceEdit{
        .{ .patch = .{
            .directive_offset = first_offset,
            .geometry = .{ .x = std.math.inf(f32), .y = 20 },
        } },
    };
    try std.testing.expectError(
        error.InvalidCoordinate,
        applyGeometryEdits(std.testing.allocator, source, &invalid_coordinate),
    );
}

test "empty atomic geometry edit returns an owned unchanged result" {
    const source = "\xEF\xBB\xBF@slide\r\n";
    const result = try applyGeometryEdits(std.testing.allocator, source, &.{});
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(source, result.source);
    try std.testing.expectEqual(@as(isize, 0), result.byte_delta);
}

test "geometry patch reparses into the edited logical item" {
    const parser = @import("parser.zig");
    const slides = @import("slides.zig");
    const original =
        "@slide\n" ++
        "@box id=hero x=100 y=200 w=300 h=150 text=Hello\n";

    var first_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer first_arena.deinit();
    const first_deck = try slides.SlideShow.new(first_arena.allocator());
    const first_context = try parser.constructSlidesFromBuf(original, first_deck, first_arena.allocator());
    defer first_context.deinit();
    try std.testing.expectEqual(@as(usize, 0), first_context.parser_errors.items.len);
    const source_ref = first_deck.slides.items[0].items.?.items[0].source;

    const result = try patchGeometry(std.testing.allocator, original, source_ref.line_offset, .{
        .x = 420,
        .y = 315,
        .w = 640,
        .h = 360,
    });
    defer result.deinit(std.testing.allocator);

    var second_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer second_arena.deinit();
    const second_deck = try slides.SlideShow.new(second_arena.allocator());
    const second_context = try parser.constructSlidesFromBuf(result.source, second_deck, second_arena.allocator());
    defer second_context.deinit();
    try std.testing.expectEqual(@as(usize, 0), second_context.parser_errors.items.len);
    const item = second_deck.slides.items[0].items.?.items[0];
    try std.testing.expectApproxEqAbs(@as(f32, 420), item.position.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 315), item.position.y, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 640), item.size.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 360), item.size.y, 0.0001);
}

test "editing a slide-template clone updates its shared definition" {
    const parser = @import("parser.zig");
    const slides = @import("slides.zig");
    const original =
        "@box id=footer x=80 y=1000 w=400 h=40 text=Shared footer\n" ++
        "@pushslide content\n" ++
        "@popslide content\n";

    var first_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer first_arena.deinit();
    const first_deck = try slides.SlideShow.new(first_arena.allocator());
    const first_context = try parser.constructSlidesFromBuf(original, first_deck, first_arena.allocator());
    defer first_context.deinit();
    const clone = first_deck.slides.items[0].items.?.items[0];
    try std.testing.expectEqual(slides.SourceScope.slide_template, clone.source.scope);

    const result = try patchGeometry(std.testing.allocator, original, clone.source.line_offset, .{
        .x = 120,
        .y = 1020,
    });
    defer result.deinit(std.testing.allocator);

    var second_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer second_arena.deinit();
    const second_deck = try slides.SlideShow.new(second_arena.allocator());
    const second_context = try parser.constructSlidesFromBuf(result.source, second_deck, second_arena.allocator());
    defer second_context.deinit();
    try std.testing.expectEqual(@as(usize, 0), second_context.parser_errors.items.len);
    const edited_clone = second_deck.slides.items[0].items.?.items[0];
    try std.testing.expectApproxEqAbs(@as(f32, 120), edited_clone.position.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1020), edited_clone.position.y, 0.0001);
    try std.testing.expectEqual(slides.SourceScope.slide_template, edited_clone.source.scope);
}

fn expectSourceResult(result: PatchResult, original: []const u8, expected: []const u8) !void {
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(expected, result.source);
    try std.testing.expectEqual(try signedLengthDelta(expected.len, original.len), result.byte_delta);
}

test "explicit snippet insertion preserves BOM and local CRLF" {
    const source =
        "\xEF\xBB\xBF@slide\r\n" ++
        "@box x=1 y=2 text=Existing\r\n";
    const insertion_offset = std.mem.indexOf(u8, source, "@box").?;
    const expected =
        "\xEF\xBB\xBF@slide\r\n" ++
        "@crowd join x=10 y=20\r\n" ++
        "Join this room\r\n" ++
        "@box x=1 y=2 text=Existing\r\n";

    const result = try insertSnippetAt(
        std.testing.allocator,
        source,
        insertion_offset,
        "@crowd join x=10 y=20\nJoin this room",
    );
    try expectSourceResult(result, source, expected);
}

test "explicit insertion supplies a separator at EOF without a newline" {
    const source = "@slide";
    const expected = "@slide\n@box text=New\n";
    const result = try insertDirectiveAt(std.testing.allocator, source, source.len, "@box text=New");
    try expectSourceResult(result, source, expected);
}

test "slide insertion appends before first morph state" {
    const source =
        "@slide\n" ++
        "@box id=base text=Base\n" ++
        "@state(morph) duration=1\n" ++
        "@set base x=100\n" ++
        "@slide\n" ++
        "@box text=Second\n";
    const expected =
        "@slide\n" ++
        "@box id=base text=Base\n" ++
        "@box id=new x=20 y=30 text=Topmost\n" ++
        "@state(morph) duration=1\n" ++
        "@set base x=100\n" ++
        "@slide\n" ++
        "@box text=Second\n";

    const result = try insertDirective(
        std.testing.allocator,
        source,
        0,
        "@box id=new x=20 y=30 text=Topmost",
    );
    try expectSourceResult(result, source, expected);
}

test "slide template override insertion targets the literal instance base and preserves CRLF" {
    const source =
        "\xEF\xBB\xBF@box id=hero text=Template\r\n" ++
        "@pushslide layout\r\n" ++
        "@popslide layout transition=fade\r\n" ++
        "@set hero x=10\r\n" ++
        "@box id=local text=Instance-only item\r\n" ++
        "# base note stays before the override\r\n" ++
        "@state(morph) duration=0.5\r\n" ++
        "@hide hero\r\n";
    const expected =
        "\xEF\xBB\xBF@box id=hero text=Template\r\n" ++
        "@pushslide layout\r\n" ++
        "@popslide layout transition=fade\r\n" ++
        "@set hero x=10\r\n" ++
        "@box id=local text=Instance-only item\r\n" ++
        "# base note stays before the override\r\n" ++
        "@set hero color=#102030ff text=Local hero costs $20\r\n" ++
        "@state(morph) duration=0.5\r\n" ++
        "@hide hero\r\n";
    const slide_offset = std.mem.indexOf(u8, source, "@popslide").?;
    const result = try insertSlideTemplateOverride(
        std.testing.allocator,
        source,
        slide_offset,
        "@set hero color=#102030ff text=Local hero costs $20",
    );

    const parser = @import("parser.zig");
    const slides = @import("slides.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const deck = try slides.SlideShow.new(arena.allocator());
    const context = try parser.constructSlidesFromBuf(result.source, deck, arena.allocator());
    defer context.deinit();
    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    const hero = deck.slides.items[0].items.?.items[0];
    try std.testing.expectEqualStrings("Local hero costs $20", hero.text.?);
    try std.testing.expectEqual(slides.SourceScope.slide_template, hero.source.scope);
    try std.testing.expectEqual(slides.SourceScope.slide_instance_override, hero.instance_source.?.scope);
    try std.testing.expectEqual(std.mem.indexOf(u8, result.source, "@set hero color").?, hero.instance_source.?.line_offset);

    try expectSourceResult(result, source, expected);
}

test "slide template override insertion rejects direct dynamic and nonliteral edits" {
    const direct = "@slide\n@box id=hero text=Direct\n";
    try std.testing.expectError(
        error.UnsupportedSlideTemplateOverride,
        insertSlideTemplateOverride(std.testing.allocator, direct, 0, "@hide hero"),
    );

    const implicit = "@box id=hero text=Implicit\n";
    try std.testing.expectError(
        error.UnsupportedSlideTemplateOverride,
        insertSlideTemplateOverride(std.testing.allocator, implicit, 0, "@hide hero"),
    );

    const dynamic = "@popslide $layout$\n";
    try std.testing.expectError(
        error.UnsupportedSlideTemplateOverride,
        insertSlideTemplateOverride(std.testing.allocator, dynamic, 0, "@hide hero"),
    );

    const dynamic_attribute = "@popslide layout duration=$duration$\n";
    const inserted = try insertSlideTemplateOverride(
        std.testing.allocator,
        dynamic_attribute,
        0,
        "@hide hero",
    );
    try expectSourceResult(
        inserted,
        dynamic_attribute,
        "@popslide layout duration=$duration$\n@hide hero\n",
    );

    const instance = "@popslide layout\n";
    try std.testing.expectError(
        error.UnsupportedSlideTemplateOverride,
        insertSlideTemplateOverride(std.testing.allocator, instance, 0, "@let x=20"),
    );
    try std.testing.expectError(
        error.InvalidLiteralValue,
        insertSlideTemplateOverride(std.testing.allocator, instance, 0, "@set hero=card x=20"),
    );
    try std.testing.expectError(
        error.InvalidLiteralValue,
        insertSlideTemplateOverride(std.testing.allocator, instance, 0, "@set hero id=renamed"),
    );
    try std.testing.expectError(
        error.InvalidLiteralValue,
        insertSlideTemplateOverride(std.testing.allocator, instance, 0, "@set $hero$ x=20"),
    );
    try std.testing.expectError(
        error.InvalidLiteralValue,
        insertSlideTemplateOverride(std.testing.allocator, instance, 0, "@hide hero accidental"),
    );
}

test "slide template override patch stays inside the selected instance base" {
    const source =
        "@popslide layout\r\n" ++
        "@set hero  x=10 text=Old local text\r\n" ++
        "@state(morph)\r\n" ++
        "@set hero x=200\r\n" ++
        "@popslide layout\r\n" ++
        "@set hero x=300\r\n";
    const slide_offset = std.mem.indexOf(u8, source, "@popslide").?;
    const base_override = std.mem.indexOf(u8, source, "@set hero  x=10").?;
    const state_override = std.mem.indexOf(u8, source, "@set hero x=200").?;
    const next_override = std.mem.indexOf(u8, source, "@set hero x=300").?;

    const result = try patchSlideTemplateOverrideGeometry(
        std.testing.allocator,
        source,
        slide_offset,
        base_override,
        "hero",
        .{ .x = 40, .y = 50 },
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "@popslide layout\r\n" ++
            "@set hero  x=40 y=50 text=Old local text\r\n" ++
            "@state(morph)\r\n" ++
            "@set hero x=200\r\n" ++
            "@popslide layout\r\n" ++
            "@set hero x=300\r\n",
        result.source,
    );

    const color_result = try patchSlideTemplateOverrideAttributes(
        std.testing.allocator,
        source,
        slide_offset,
        base_override,
        "hero",
        &.{.{ .key = "color", .value = "#abcdef80" }},
    );
    defer color_result.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(
        u8,
        color_result.source,
        "@set hero  x=10 color=#abcdef80 text=Old local text\r\n",
    ) != null);

    const text_result = try patchSlideTemplateOverrideText(
        std.testing.allocator,
        source,
        slide_offset,
        base_override,
        "hero",
        "Price $20",
    );
    defer text_result.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(
        u8,
        text_result.source,
        "@set hero  x=10 text=Price $20\r\n",
    ) != null);

    try std.testing.expectError(
        error.UnsupportedSlideTemplateOverride,
        patchSlideTemplateOverrideAttributes(
            std.testing.allocator,
            source,
            slide_offset,
            state_override,
            "hero",
            &.{.{ .key = "x", .value = "40" }},
        ),
    );
    try std.testing.expectError(
        error.UnsupportedSlideTemplateOverride,
        patchSlideTemplateOverrideAttributes(
            std.testing.allocator,
            source,
            slide_offset,
            next_override,
            "hero",
            &.{.{ .key = "x", .value = "40" }},
        ),
    );
    try std.testing.expectError(
        error.UnsupportedSlideTemplateOverride,
        patchSlideTemplateOverrideAttributes(
            std.testing.allocator,
            source,
            slide_offset,
            base_override,
            "other",
            &.{.{ .key = "x", .value = "40" }},
        ),
    );
    try std.testing.expectError(
        error.InvalidLiteralValue,
        patchSlideTemplateOverrideAttributes(
            std.testing.allocator,
            source,
            slide_offset,
            base_override,
            "hero",
            &.{.{ .key = "id", .value = "renamed" }},
        ),
    );
}

test "slide template override patch rejects a parser-masked earlier mutation" {
    const source =
        "@popslide layout\n" ++
        "@set hero x=10\n" ++
        "@show hero x=20\n" ++
        "@state(morph)\n";
    const first = std.mem.indexOf(u8, source, "@set hero").?;
    const latest = std.mem.indexOf(u8, source, "@show hero").?;

    try std.testing.expectError(
        error.UnsupportedSlideTemplateOverride,
        patchSlideTemplateOverrideGeometry(
            std.testing.allocator,
            source,
            0,
            first,
            "hero",
            .{ .x = 30, .y = 40 },
        ),
    );
    const result = try patchSlideTemplateOverrideGeometry(
        std.testing.allocator,
        source,
        0,
        latest,
        "hero",
        .{ .x = 30, .y = 40 },
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.source, "@show hero x=30 y=40\n") != null);
}

test "scoped mutation validation rejects let-expanded shadowing" {
    const instance =
        "@popslide layout\n" ++
        "@set hero x=10\n" ++
        "$later_override$\n" ++
        "@state(morph)\n";
    try std.testing.expectError(
        error.UnsupportedSlideTemplateOverride,
        validateSlideTemplateOverrideTarget(
            instance,
            0,
            std.mem.indexOf(u8, instance, "@set hero").?,
            "hero",
        ),
    );

    const morph =
        "@slide\n" ++
        "@box id=hero text=Hero\n" ++
        "@state(morph)\n" ++
        "@set hero x=20\n" ++
        "$later_mutation$\n" ++
        "@slide\n";
    try std.testing.expectError(
        error.InvalidMorphStateOffset,
        validateMorphMutationTarget(
            morph,
            std.mem.indexOf(u8, morph, "@state").?,
            std.mem.indexOf(u8, morph, "@set hero").?,
            "hero",
        ),
    );
}

test "slide boundaries distinguish base insertion from complete slide end" {
    const source =
        "@slide\n" ++
        "@box text=Base\n" ++
        "@state(morph)\n" ++
        "@box id=born text=Later\n" ++
        "@popslide content\n";
    try std.testing.expectEqual(std.mem.indexOf(u8, source, "@state").?, try slideItemInsertionOffset(source, 0));
    try std.testing.expectEqual(std.mem.indexOf(u8, source, "@popslide").?, try slideEndOffset(source, 0));

    const end = try slideEndOffset(source, 0);
    const expected =
        "@slide\n" ++
        "@box text=Base\n" ++
        "@state(morph)\n" ++
        "@box id=born text=Later\n" ++
        "@slide\n" ++
        "@popslide content\n";
    const result = try insertDirectiveAt(std.testing.allocator, source, end, "@slide");
    try expectSourceResult(result, source, expected);
}

test "morph state end finds next state slide boundary and EOF" {
    const source =
        "\xEF\xBB\xBF@slide\r\n" ++
        "@box id=hero text=Base\r\n" ++
        "@state(morph) duration=1\r\n" ++
        "@set hero x=100\r\n" ++
        "@state(morph) duration=2\r\n" ++
        "@hide hero\r\n" ++
        "@slide\r\n" ++
        "@state(morph)\r\n" ++
        "@box id=born text=Born";
    const first_state = std.mem.indexOf(u8, source, "@state(morph) duration=1").?;
    const second_state = std.mem.indexOf(u8, source, "@state(morph) duration=2").?;
    const next_slide = std.mem.indexOfPos(u8, source, second_state, "@slide").?;
    const final_state = std.mem.lastIndexOf(u8, source, "@state(morph)").?;
    try std.testing.expectEqual(second_state, try morphStateEndOffset(source, first_state));
    try std.testing.expectEqual(next_slide, try morphStateEndOffset(source, second_state));
    try std.testing.expectEqual(source.len, try morphStateEndOffset(source, final_state));
    try std.testing.expectError(error.InvalidMorphStateOffset, morphStateEndOffset(source, 3));
}

test "bare morph state is a base and state insertion boundary" {
    const source =
        "@slide\n" ++
        "@box id=hero text=Base\n" ++
        "@state duration=1\n" ++
        "@set hero x=100\n" ++
        "@state\n" ++
        "@hide hero\n";
    const first_state = std.mem.indexOf(u8, source, "@state duration=1").?;
    const second_state = std.mem.indexOfPos(u8, source, first_state + 1, "@state").?;

    try std.testing.expectEqual(first_state, try slideItemInsertionOffset(source, 0));
    try std.testing.expectEqual(second_state, try morphStateEndOffset(source, first_state));
    try std.testing.expectEqual(source.len, try morphStateEndOffset(source, second_state));

    const inserted = try insertDirectiveAt(
        std.testing.allocator,
        source,
        try slideItemInsertionOffset(source, 0),
        "@box id=top text=Still base",
    );
    defer inserted.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, inserted.source, "@box id=top text=Still base\n@state") != null);
}

test "unambiguous implicit slide supports base item and new slide boundaries" {
    const source =
        "# one implicit slide\n" ++
        "@box id=hero text=Base\n" ++
        "@state\n" ++
        "@set hero x=100\n";
    const state = std.mem.indexOf(u8, source, "@state").?;
    try std.testing.expectEqual(state, try slideItemInsertionOffset(source, 0));
    try std.testing.expectEqual(source.len, try slideEndOffset(source, 0));

    const ambiguous = "@pushslide template\n@box text=Implicit after a template\n";
    try std.testing.expectError(error.InvalidSlideOffset, slideItemInsertionOffset(ambiguous, 0));
}

test "logical slide range owns base morph formatting and comments" {
    const source =
        "\xEF\xBB\xBF# template preface\r\n" ++
        "@box text=Template\r\n" ++
        "@pushslide base\r\n" ++
        "# deck preface\r\n" ++
        "@popslide base transition=fade\r\n" ++
        "@box id=hero text=First\r\n" ++
        "@state(morph) duration=0.5\r\n" ++
        "@set hero x=400\r\n" ++
        "# belongs to first\r\n" ++
        "@slide\r\n" ++
        "@box text=Second\r\n";
    const first = std.mem.indexOf(u8, source, "@popslide").?;
    const second = std.mem.indexOfPos(u8, source, first, "@slide").?;
    const range = try logicalSlideRange(source, first);

    try std.testing.expect(range.explicit_anchor);
    try std.testing.expectEqual(first, range.start);
    try std.testing.expectEqual(second, range.end);
    try std.testing.expectEqual(first, range.anchor_offset);
    try std.testing.expectEqualStrings(
        "@popslide base transition=fade\r\n" ++
            "@box id=hero text=First\r\n" ++
            "@state(morph) duration=0.5\r\n" ++
            "@set hero x=400\r\n" ++
            "# belongs to first\r\n",
        source[range.start..range.end],
    );

    const implicit = "\xEF\xBB\xBF# only\r\n@box text=Implicit";
    const implicit_range = try logicalSlideRange(implicit, 0);
    try std.testing.expect(!implicit_range.explicit_anchor);
    try std.testing.expectEqual(@as(usize, 3), implicit_range.start);
    try std.testing.expectEqual(implicit.len, implicit_range.end);
}

test "duplicate explicit slide retains its full morph source byte for byte" {
    const parser = @import("parser.zig");
    const slides = @import("slides.zig");
    const source =
        "@slide\n" ++
        "@box id=hero text=First\n" ++
        "@state(morph) duration=0.5\n" ++
        "@set hero x=400\n" ++
        "# trailing note\n" ++
        "@slide\n" ++
        "@box text=Second\n";
    const duplicated = try duplicateSlide(std.testing.allocator, source, 0);
    defer duplicated.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "@slide\n" ++
            "@box id=hero text=First\n" ++
            "@state(morph) duration=0.5\n" ++
            "@set hero x=400\n" ++
            "# trailing note\n" ++
            "@slide\n" ++
            "@box id=hero text=First\n" ++
            "@state(morph) duration=0.5\n" ++
            "@set hero x=400\n" ++
            "# trailing note\n" ++
            "@slide\n" ++
            "@box text=Second\n",
        duplicated.source,
    );

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const deck = try slides.SlideShow.new(arena.allocator());
    const context = try parser.constructSlidesFromBuf(duplicated.source, deck, arena.allocator());
    defer context.deinit();
    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    try std.testing.expectEqual(@as(usize, 3), deck.slides.items.len);
    try std.testing.expectEqual(@as(usize, 1), deck.slides.items[0].morph_states.items.len);
    try std.testing.expectEqual(@as(usize, 1), deck.slides.items[1].morph_states.items.len);
    try std.testing.expectApproxEqAbs(
        deck.slides.items[0].morph_states.items[0].items.items[0].position.x,
        deck.slides.items[1].morph_states.items[0].items.items[0].position.x,
        0.0001,
    );
}

test "duplicate implicit BOM CRLF slide creates two explicit valid slides" {
    const parser = @import("parser.zig");
    const slides = @import("slides.zig");
    const source = "\xEF\xBB\xBF# retained\r\n@box text=Implicit";
    const expected =
        "\xEF\xBB\xBF@slide\r\n" ++
        "# retained\r\n" ++
        "@box text=Implicit\r\n" ++
        "@slide\r\n" ++
        "# retained\r\n" ++
        "@box text=Implicit";
    const duplicated = try duplicateSlide(std.testing.allocator, source, 0);
    defer duplicated.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(expected, duplicated.source);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, duplicated.source, utf8_bom));

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const deck = try slides.SlideShow.new(arena.allocator());
    const context = try parser.constructSlidesFromBuf(duplicated.source, deck, arena.allocator());
    defer context.deinit();
    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    try std.testing.expectEqual(@as(usize, 2), deck.slides.items.len);
    try std.testing.expectEqualStrings("Implicit", deck.slides.items[0].items.?.items[0].text.?);
    try std.testing.expectEqualStrings("Implicit", deck.slides.items[1].items.?.items[0].text.?);
}

test "blank slide after implicit deck preserves the original as slide one" {
    const parser = @import("parser.zig");
    const slides = @import("slides.zig");
    const source = "\xEF\xBB\xBF# retained\r\n@box text=Original";
    const expected =
        "\xEF\xBB\xBF@slide\r\n" ++
        "# retained\r\n" ++
        "@box text=Original\r\n" ++
        "@slide\r\n";
    const inserted = try insertBlankSlideAfter(std.testing.allocator, source, 0);
    defer inserted.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(expected, inserted.source);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, inserted.source, utf8_bom));

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const deck = try slides.SlideShow.new(arena.allocator());
    const context = try parser.constructSlidesFromBuf(inserted.source, deck, arena.allocator());
    defer context.deinit();
    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    try std.testing.expectEqual(@as(usize, 2), deck.slides.items.len);
    try std.testing.expectEqualStrings("Original", deck.slides.items[0].items.?.items[0].text.?);
    try std.testing.expectEqual(@as(usize, 0), deck.slides.items[1].items.?.items.len);
}

test "duplicate implicit slide rejects reusable definitions" {
    const reusable_source =
        "@push title x=100 y=100 text=Template\n" ++
        "@pop title text=Rendered\n";
    try std.testing.expectError(
        error.AmbiguousSlideTemplateLayout,
        duplicateSlide(std.testing.allocator, reusable_source, 0),
    );
    try std.testing.expectError(
        error.AmbiguousSlideTemplateLayout,
        insertBlankSlideAfter(std.testing.allocator, reusable_source, 0),
    );

    // With no rendered anchor, @pushslide captures rather than emits the
    // apparent block; treating the parser's default position zero as a plain
    // implicit slide would therefore be unsafe.
    const slide_template_source =
        "@box text=Template\n" ++
        "@pushslide content\n";
    try std.testing.expectError(
        error.AmbiguousSlideTemplateLayout,
        logicalSlideRange(slide_template_source, 0),
    );
    try std.testing.expectError(
        error.AmbiguousSlideTemplateLayout,
        duplicateSlide(std.testing.allocator, slide_template_source, 0),
    );
}

test "duplicate popslide keeps template prefix fixed and reparses clones" {
    const parser = @import("parser.zig");
    const slides = @import("slides.zig");
    const source =
        "# definitions\n" ++
        "@box id=header text=Header\n" ++
        "@pushslide content\n" ++
        "@popslide content\n" ++
        "@box text=One\n" ++
        "@popslide content\n" ++
        "@box text=Two\n";
    const selected = std.mem.indexOf(u8, source, "@popslide").?;
    const duplicated = try duplicateSlide(std.testing.allocator, source, selected);
    defer duplicated.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.startsWith(
        u8,
        duplicated.source,
        "# definitions\n@box id=header text=Header\n@pushslide content\n",
    ));
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, duplicated.source, "@popslide content"));

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const deck = try slides.SlideShow.new(arena.allocator());
    const context = try parser.constructSlidesFromBuf(duplicated.source, deck, arena.allocator());
    defer context.deinit();
    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    try std.testing.expectEqual(@as(usize, 3), deck.slides.items.len);
    try std.testing.expectEqualStrings("One", deck.slides.items[0].items.?.items[1].text.?);
    try std.testing.expectEqualStrings("One", deck.slides.items[1].items.?.items[1].text.?);
    try std.testing.expectEqualStrings("Two", deck.slides.items[2].items.?.items[1].text.?);
}

test "delete complete slide preserves unrelated CRLF bytes" {
    const source =
        "\xEF\xBB\xBF# prefix\r\n" ++
        "@slide\r\n" ++
        "@box text=One\r\n" ++
        "@slide transition=fade\r\n" ++
        "@box id=middle text=Two\r\n" ++
        "@state\r\n" ++
        "@hide middle\r\n" ++
        "# middle tail\r\n" ++
        "@slide\r\n" ++
        "@box text=Three";
    const middle = std.mem.indexOf(u8, source, "@slide transition").?;
    const deleted = try deleteSlide(std.testing.allocator, source, middle);
    try expectSourceResult(
        deleted,
        source,
        "\xEF\xBB\xBF# prefix\r\n" ++
            "@slide\r\n" ++
            "@box text=One\r\n" ++
            "@slide\r\n" ++
            "@box text=Three",
    );
}

test "delete refuses to remove the only logical slide" {
    try std.testing.expectError(
        error.CannotDeleteOnlySlide,
        deleteSlide(std.testing.allocator, "@slide\n@box text=Only\n", 0),
    );
    try std.testing.expectError(
        error.CannotDeleteOnlySlide,
        deleteSlide(std.testing.allocator, "# implicit\n@box text=Only", 0),
    );
}

test "structural slide edits reject owned global context directives" {
    const source =
        "@slide\n" ++
        "@color #112233ff\n" ++
        "@push card text=Shared\n" ++
        "@pop card\n" ++
        "@slide\n" ++
        "@pop card\n";
    const first = std.mem.indexOf(u8, source, "@slide").?;
    const second = std.mem.indexOfPos(u8, source, first + 1, "@slide").?;

    try std.testing.expectError(
        error.UnsafeSlideGlobalDirective,
        duplicateSlide(std.testing.allocator, source, first),
    );
    try std.testing.expectError(
        error.UnsafeSlideGlobalDirective,
        deleteSlide(std.testing.allocator, source, first),
    );
    try std.testing.expectError(
        error.UnsafeSlideGlobalDirective,
        moveSlide(std.testing.allocator, source, first, .later),
    );
    try std.testing.expectError(
        error.UnsafeSlideGlobalDirective,
        moveSlide(std.testing.allocator, source, second, .earlier),
    );
}

test "move slide earlier and later swaps complete adjacent ranges" {
    const source =
        "# prefix\n" ++
        "@slide\n" ++
        "@box text=One\n" ++
        "# one tail\n" ++
        "@slide transition=fade\n" ++
        "@box id=two text=Two\n" ++
        "@state\n" ++
        "@set two x=200\n" ++
        "# two tail\n" ++
        "@slide\n" ++
        "@box text=Three";
    const second = std.mem.indexOf(u8, source, "@slide transition").?;
    const moved_earlier = try moveSlide(std.testing.allocator, source, second, .earlier);
    defer moved_earlier.deinit(std.testing.allocator);
    const earlier_expected =
        "# prefix\n" ++
        "@slide transition=fade\n" ++
        "@box id=two text=Two\n" ++
        "@state\n" ++
        "@set two x=200\n" ++
        "# two tail\n" ++
        "@slide\n" ++
        "@box text=One\n" ++
        "# one tail\n" ++
        "@slide\n" ++
        "@box text=Three";
    try std.testing.expectEqualStrings(earlier_expected, moved_earlier.source);

    const first = std.mem.indexOf(u8, source, "@slide\n").?;
    const moved_later = try moveSlide(std.testing.allocator, source, first, .later);
    defer moved_later.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(earlier_expected, moved_later.source);
    try std.testing.expectError(
        error.NoAdjacentSlide,
        moveSlide(std.testing.allocator, source, first, .earlier),
    );
    const third = std.mem.lastIndexOf(u8, source, "@slide\n").?;
    try std.testing.expectError(
        error.NoAdjacentSlide,
        moveSlide(std.testing.allocator, source, third, .later),
    );
}

test "moving unterminated final slide transfers existing line ending" {
    const source =
        "@slide\r\n" ++
        "@box text=One\r\n" ++
        "@slide\r\n" ++
        "@box text=Two";
    const first = std.mem.indexOf(u8, source, "@slide").?;
    const second = std.mem.lastIndexOf(u8, source, "@slide").?;
    const expected =
        "@slide\r\n" ++
        "@box text=Two\r\n" ++
        "@slide\r\n" ++
        "@box text=One";

    const earlier = try moveSlide(std.testing.allocator, source, second, .earlier);
    defer earlier.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(expected, earlier.source);
    try std.testing.expectEqual(@as(isize, 0), earlier.byte_delta);

    const later = try moveSlide(std.testing.allocator, source, first, .later);
    defer later.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(expected, later.source);
    try std.testing.expectEqual(@as(isize, 0), later.byte_delta);
}

test "slide operations reject ambiguous template captures after rendered slides" {
    const source =
        "@slide\n" ++
        "@box text=Looks rendered\n" ++
        "@pushslide late_template\n" ++
        "@popslide late_template\n";
    try std.testing.expectError(error.AmbiguousSlideTemplateLayout, logicalSlideRange(source, 0));
    try std.testing.expectError(
        error.AmbiguousSlideTemplateLayout,
        duplicateSlide(std.testing.allocator, source, 0),
    );
    try std.testing.expectError(
        error.AmbiguousSlideTemplateLayout,
        deleteSlide(std.testing.allocator, source, 0),
    );
    try std.testing.expectError(
        error.AmbiguousSlideTemplateLayout,
        moveSlide(std.testing.allocator, source, 0, .later),
    );
    const push = std.mem.indexOf(u8, source, "@pushslide").?;
    try std.testing.expectError(error.AmbiguousSlideTemplateLayout, logicalSlideRange(source, push));
}

test "logical slide range rejects non-anchor offsets" {
    const source = "@slide\n@box text=One\n@slide\n";
    const item = std.mem.indexOf(u8, source, "@box").?;
    try std.testing.expectError(error.InvalidSlideOffset, logicalSlideRange(source, item));
    try std.testing.expectError(error.InvalidSlideOffset, logicalSlideRange(source, source.len));
}

test "promote explicit slide moves its base to the library and preserves morph instance" {
    const parser = @import("parser.zig");
    const slides = @import("slides.zig");
    const source =
        "@slide transition=fade duration=0.6\n" ++
        "@box id=hero x=100 y=200 text=Hero\n" ++
        "# base explanation\n" ++
        "@state(morph) duration=0.5\n" ++
        "@set hero x=440\n" ++
        "# state explanation\n" ++
        "@slide\n" ++
        "@box text=Second\n";
    const expected =
        "@box id=hero x=100 y=200 text=Hero\n" ++
        "# base explanation\n" ++
        "@pushslide feature\n" ++
        "@popslide feature transition=fade duration=0.6\n" ++
        "@state(morph) duration=0.5\n" ++
        "@set hero x=440\n" ++
        "# state explanation\n" ++
        "@slide\n" ++
        "@box text=Second\n";

    const promoted = try promoteSlideToTemplate(std.testing.allocator, source, 0, "feature");
    defer promoted.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(expected, promoted.source);
    try std.testing.expectEqual(try signedLengthDelta(expected.len, source.len), promoted.byte_delta);

    var original_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer original_arena.deinit();
    const original_deck = try slides.SlideShow.new(original_arena.allocator());
    const original_context = try parser.constructSlidesFromBuf(source, original_deck, original_arena.allocator());
    defer original_context.deinit();

    var promoted_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer promoted_arena.deinit();
    const promoted_deck = try slides.SlideShow.new(promoted_arena.allocator());
    const promoted_context = try parser.constructSlidesFromBuf(promoted.source, promoted_deck, promoted_arena.allocator());
    defer promoted_context.deinit();

    try std.testing.expectEqual(@as(usize, 0), original_context.parser_errors.items.len);
    try std.testing.expectEqual(@as(usize, 0), promoted_context.parser_errors.items.len);
    try std.testing.expectEqual(original_deck.slides.items.len, promoted_deck.slides.items.len);
    try std.testing.expectEqual(@as(usize, 2), promoted_deck.slides.items.len);
    const original_first = original_deck.slides.items[0];
    const promoted_first = promoted_deck.slides.items[0];
    try std.testing.expectEqual(original_first.transition.effect, promoted_first.transition.effect);
    try std.testing.expectApproxEqAbs(original_first.transition.duration, promoted_first.transition.duration, 0.0001);
    try std.testing.expectEqual(original_first.items.?.items.len, promoted_first.items.?.items.len);
    try std.testing.expectEqualStrings(original_first.items.?.items[0].text.?, promoted_first.items.?.items[0].text.?);
    try std.testing.expectEqual(slides.SourceScope.slide_template, promoted_first.items.?.items[0].source.scope);
    try std.testing.expectEqual(@as(usize, 1), promoted_first.morph_states.items.len);
    try std.testing.expectApproxEqAbs(
        original_first.morph_states.items[0].spec.duration,
        promoted_first.morph_states.items[0].spec.duration,
        0.0001,
    );
    try std.testing.expectApproxEqAbs(
        original_first.morph_states.items[0].items.items[0].position.x,
        promoted_first.morph_states.items[0].items.items[0].position.x,
        0.0001,
    );
}

test "promote middle slide preserves BOM CRLF prefix and deck order" {
    const parser = @import("parser.zig");
    const slides = @import("slides.zig");
    const source =
        "\xEF\xBB\xBF@box id=old x=5 y=6 text=Old template\r\n" ++
        "@pushslide old\r\n" ++
        "# deck begins\r\n" ++
        "@slide\r\n" ++
        "@box text=First\r\n" ++
        "@slide transition=slide-left duration=0.4\r\n" ++
        "@box x=30 y=40 text=Promoted\r\n" ++
        "@slide\r\n" ++
        "@box text=Third";
    const selected = std.mem.indexOf(u8, source, "@slide transition").?;
    const expected =
        "\xEF\xBB\xBF@box id=old x=5 y=6 text=Old template\r\n" ++
        "@pushslide old\r\n" ++
        "# deck begins\r\n" ++
        "@box x=30 y=40 text=Promoted\r\n" ++
        "@pushslide middle\r\n" ++
        "@slide\r\n" ++
        "@box text=First\r\n" ++
        "@popslide middle transition=slide-left duration=0.4\r\n" ++
        "@slide\r\n" ++
        "@box text=Third";

    const promoted = try promoteSlideToTemplate(std.testing.allocator, source, selected, "middle");
    defer promoted.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(expected, promoted.source);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, promoted.source, utf8_bom));

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const deck = try slides.SlideShow.new(arena.allocator());
    const context = try parser.constructSlidesFromBuf(promoted.source, deck, arena.allocator());
    defer context.deinit();
    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    try std.testing.expectEqual(@as(usize, 3), deck.slides.items.len);
    try std.testing.expectEqualStrings("First", deck.slides.items[0].items.?.items[0].text.?);
    try std.testing.expectEqualStrings("Promoted", deck.slides.items[1].items.?.items[0].text.?);
    try std.testing.expectEqualStrings("Third", deck.slides.items[2].items.?.items[0].text.?);
    try std.testing.expectEqual(slides.SourceScope.slide_template, deck.slides.items[1].items.?.items[0].source.scope);
}

test "promote implicit BOM CRLF slide preserves one slide and morph semantics" {
    const parser = @import("parser.zig");
    const slides = @import("slides.zig");
    const source =
        "\xEF\xBB\xBF@box id=hero x=10 y=20 text=Implicit\r\n" ++
        "@state(morph) duration=0.3\r\n" ++
        "@set hero y=240";
    const expected =
        "\xEF\xBB\xBF@box id=hero x=10 y=20 text=Implicit\r\n" ++
        "@pushslide implicit_card\r\n" ++
        "@popslide implicit_card\r\n" ++
        "@state(morph) duration=0.3\r\n" ++
        "@set hero y=240";
    const promoted = try promoteSlideToTemplate(std.testing.allocator, source, 0, "implicit_card");
    defer promoted.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(expected, promoted.source);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const deck = try slides.SlideShow.new(arena.allocator());
    const context = try parser.constructSlidesFromBuf(promoted.source, deck, arena.allocator());
    defer context.deinit();
    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    try std.testing.expectEqual(@as(usize, 1), deck.slides.items.len);
    try std.testing.expectEqualStrings("Implicit", deck.slides.items[0].items.?.items[0].text.?);
    try std.testing.expectEqual(slides.SourceScope.slide_template, deck.slides.items[0].items.?.items[0].source.scope);
    try std.testing.expectEqual(@as(usize, 1), deck.slides.items[0].morph_states.items.len);
    try std.testing.expectApproxEqAbs(
        @as(f32, 240),
        deck.slides.items[0].morph_states.items[0].items.items[0].position.y,
        0.0001,
    );
}

test "promoted slide keeps reusable component dependencies resolved from prefix" {
    const parser = @import("parser.zig");
    const slides = @import("slides.zig");
    const source =
        "@push card x=10 y=20 w=300 h=80 text=Shared component\n" ++
        "@slide\n" ++
        "@pop card id=hero\n";
    const expected =
        "@push card x=10 y=20 w=300 h=80 text=Shared component\n" ++
        "@pop card id=hero\n" ++
        "@pushslide layout\n" ++
        "@popslide layout\n";
    const selected = std.mem.indexOf(u8, source, "@slide").?;
    const promoted = try promoteSlideToTemplate(std.testing.allocator, source, selected, "layout");
    defer promoted.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(expected, promoted.source);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const deck = try slides.SlideShow.new(arena.allocator());
    const context = try parser.constructSlidesFromBuf(promoted.source, deck, arena.allocator());
    defer context.deinit();
    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    try std.testing.expectEqual(@as(usize, 1), deck.slides.items.len);
    try std.testing.expectEqualStrings("Shared component", deck.slides.items[0].items.?.items[0].text.?);
    try std.testing.expectEqualStrings("hero", deck.slides.items[0].items.?.items[0].id.?);
    try std.testing.expectEqual(slides.SourceScope.slide_template, deck.slides.items[0].items.?.items[0].source.scope);
}

test "slide promotion rejects collisions template instances defaults and unsafe context" {
    const collision =
        "@box text=Existing\n" ++
        "@pushslide feature\n" ++
        "@slide\n" ++
        "@box text=Selected\n";
    const selected = std.mem.indexOf(u8, collision, "@slide").?;
    try std.testing.expectError(
        error.SlideTemplateNameCollision,
        promoteSlideToTemplate(std.testing.allocator, collision, selected, "feature"),
    );
    try std.testing.expectError(
        error.InvalidReusableName,
        promoteSlideToTemplate(std.testing.allocator, collision, selected, "not valid"),
    );

    const template_backed =
        "@box text=Template\n" ++
        "@pushslide old\n" ++
        "@popslide old\n";
    const pop = std.mem.indexOf(u8, template_backed, "@popslide").?;
    try std.testing.expectError(
        error.UnsupportedSlidePromotion,
        promoteSlideToTemplate(std.testing.allocator, template_backed, pop, "new"),
    );

    const item_defaults = "@slide fontsize=72 color=#ffffffff\n@box text=Inherited\n";
    try std.testing.expectError(
        error.UnsupportedSlidePromotion,
        promoteSlideToTemplate(std.testing.allocator, item_defaults, 0, "styled"),
    );

    const global_between =
        "@slide\n" ++
        "@box text=First\n" ++
        "@color #112233ff\n" ++
        "@slide\n" ++
        "@box text=Second\n";
    const second = std.mem.lastIndexOf(u8, global_between, "@slide").?;
    try std.testing.expectError(
        error.UnsafeSlideGlobalDirective,
        promoteSlideToTemplate(std.testing.allocator, global_between, second, "second"),
    );
}

test "slide promotion rejects dirty prefix raw prose dynamic source and dangling animation" {
    const dirty_prefix =
        "@box text=Discarded before deck\n" ++
        "@slide\n" ++
        "@box text=Selected\n";
    const selected = std.mem.indexOf(u8, dirty_prefix, "@slide").?;
    try std.testing.expectError(
        error.UnsupportedSlidePromotion,
        promoteSlideToTemplate(std.testing.allocator, dirty_prefix, selected, "clean"),
    );

    const raw_prose = "@slide\nThis is anchor body text\n@box text=Selected\n";
    try std.testing.expectError(
        error.UnsupportedSlidePromotion,
        promoteSlideToTemplate(std.testing.allocator, raw_prose, 0, "raw"),
    );

    const dynamic = "@slide\n@box x=$hero_x$ text=Selected\n";
    try std.testing.expectError(
        error.UnsupportedSlidePromotion,
        promoteSlideToTemplate(std.testing.allocator, dynamic, 0, "dynamic"),
    );

    const dangling_animation = "@slide\n@box text=Selected\n@anim(fade) duration=0.4\n";
    try std.testing.expectError(
        error.UnsupportedSlidePromotion,
        promoteSlideToTemplate(std.testing.allocator, dangling_animation, 0, "animated"),
    );

    const inherited_animation =
        "@slide\n" ++
        "@box text=First\n" ++
        "@anim(fade) duration=0.4\n" ++
        "@slide\n" ++
        "@box text=Would consume pending animation\n";
    const second = std.mem.lastIndexOf(u8, inherited_animation, "@slide").?;
    try std.testing.expectError(
        error.UnsupportedSlidePromotion,
        promoteSlideToTemplate(std.testing.allocator, inherited_animation, second, "animated_second"),
    );
}

test "promotion preserves inline item formatting comments BOM and CRLF" {
    const source =
        "\xEF\xBB\xBF@slide\r\n" ++
        "@box  x=10\ty=20 color=#01020304 text=Hello world\r\n" ++
        "# item explanation\r\n" ++
        "@slide\r\n";
    const box = std.mem.indexOf(u8, source, "@box").?;
    const expected =
        "\xEF\xBB\xBF@slide\r\n" ++
        "@push hero  x=10\ty=20 color=#01020304 text=Hello world\r\n" ++
        "# item explanation\r\n" ++
        "@pop hero\r\n" ++
        "@slide\r\n";

    const result = try promoteItemToReusable(std.testing.allocator, source, box, "hero");
    try expectSourceResult(result, source, expected);
}

test "promotion retains body bullets and reparses an equivalent instance" {
    const parser = @import("parser.zig");
    const slides = @import("slides.zig");
    const source =
        "@slide\n" ++
        "@box x=100 y=200 w=600 h=400 color=#AABBCCDD\n" ++
        "- First\n" ++
        "# retained note\n" ++
        "- Second\n" ++
        "@slide\n";
    const box = std.mem.indexOf(u8, source, "@box").?;
    const expected =
        "@slide\n" ++
        "@push bullet_list x=100 y=200 w=600 h=400 color=#AABBCCDD\n" ++
        "- First\n" ++
        "# retained note\n" ++
        "- Second\n" ++
        "@pop bullet_list\n" ++
        "@slide\n";
    const result = try promoteItemToReusable(std.testing.allocator, source, box, "bullet_list");
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(expected, result.source);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const deck = try slides.SlideShow.new(arena.allocator());
    const context = try parser.constructSlidesFromBuf(result.source, deck, arena.allocator());
    defer context.deinit();
    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    const item = deck.slides.items[0].items.?.items[0];
    try std.testing.expectEqualStrings("- First\n- Second", item.text.?);
    try std.testing.expectEqualStrings("bullet_list", item.id.?);
    try std.testing.expectApproxEqAbs(@as(f32, 100), item.position.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 200), item.position.y, 0.0001);
    try std.testing.expectEqual(slides.SourceScope.component_instance, item.source.scope);
}

test "promotion moves effective id from reusable push to pop instance" {
    const parser = @import("parser.zig");
    const slides = @import("slides.zig");
    const source =
        "@slide\n" ++
        "@box  id=old\tid=stable x=100 y=200 text=Identified\n";
    const box = std.mem.indexOf(u8, source, "@box").?;
    const expected =
        "@slide\n" ++
        "@push reusable  \t x=100 y=200 text=Identified\n" ++
        "@pop reusable id=stable\n";
    const result = try promoteItemToReusable(std.testing.allocator, source, box, "reusable");
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(expected, result.source);
    try std.testing.expect(std.mem.indexOf(u8, result.source, "@push reusable id=") == null);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const deck = try slides.SlideShow.new(arena.allocator());
    const context = try parser.constructSlidesFromBuf(result.source, deck, arena.allocator());
    defer context.deinit();
    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    const item = deck.slides.items[0].items.?.items[0];
    try std.testing.expectEqualStrings("stable", item.id.?);
    try std.testing.expectEqualStrings("Identified", item.text.?);
    try std.testing.expectEqual(slides.SourceScope.component_instance, item.source.scope);
}

test "promotion validates directive and reusable name" {
    const source = "@slide\n@crowd join\n";
    try std.testing.expectError(
        error.InvalidReusableName,
        promoteItemToReusable(std.testing.allocator, source, 0, "two words"),
    );
    try std.testing.expectError(
        error.NotPromotableDirective,
        promoteItemToReusable(std.testing.allocator, source, 0, "hero"),
    );
}

test "item duplication preserves BOM CRLF multiline body comments and replaces clone id" {
    const parser = @import("parser.zig");
    const slides = @import("slides.zig");
    const source =
        "\xEF\xBB\xBF@slide\r\n" ++
        "@box  id=hero\tx=10 y=20 w=300 h=180 color=#102030ff\r\n" ++
        "- First\r\n" ++
        "# item explanation\r\n" ++
        "- Second\r\n" ++
        "@box id=tail text=Tail\r\n";
    const expected =
        "\xEF\xBB\xBF@slide\r\n" ++
        "@box  id=hero\tx=10 y=20 w=300 h=180 color=#102030ff\r\n" ++
        "- First\r\n" ++
        "# item explanation\r\n" ++
        "- Second\r\n" ++
        "@box  id=hero_copy\tx=30 y=40 w=300 h=180 color=#102030ff\r\n" ++
        "- First\r\n" ++
        "# item explanation\r\n" ++
        "- Second\r\n" ++
        "@box id=tail text=Tail\r\n";
    const item_offset = std.mem.indexOf(u8, source, "@box  id=hero").?;
    const result = try duplicateItem(
        std.testing.allocator,
        source,
        item_offset,
        "hero_copy",
        .{ .x = 30, .y = 40 },
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(expected, result.source);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, result.source, utf8_bom));

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const deck = try slides.SlideShow.new(arena.allocator());
    const context = try parser.constructSlidesFromBuf(result.source, deck, arena.allocator());
    defer context.deinit();
    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    const items = deck.slides.items[0].items.?.items;
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqualStrings("hero", items[0].id.?);
    try std.testing.expectEqualStrings("hero_copy", items[1].id.?);
    try std.testing.expectEqualStrings("- First\n- Second", items[0].text.?);
    try std.testing.expectEqualStrings(items[0].text.?, items[1].text.?);
    try std.testing.expectApproxEqAbs(@as(f32, 30), items[1].position.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 40), items[1].position.y, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 10), items[0].position.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 20), items[0].position.y, 0.0001);
    try std.testing.expectApproxEqAbs(items[0].size.x, items[1].size.x, 0.0001);
}

test "item duplication inserts missing id and retains unterminated EOF" {
    const source = "@slide\n@box x=5 y=6 text=No ID";
    const expected =
        "@slide\n" ++
        "@box x=5 y=6 text=No ID\n" ++
        "@box x=25 y=26 id=copy text=No ID";
    const item_offset = std.mem.indexOf(u8, source, "@box").?;
    const result = try duplicateItem(
        std.testing.allocator,
        source,
        item_offset,
        "copy",
        .{ .x = 25, .y = 26 },
    );
    try expectSourceResult(result, source, expected);
}

test "component instance duplication preserves pop resolution and changes only clone id" {
    const parser = @import("parser.zig");
    const slides = @import("slides.zig");
    const source =
        "@push card x=20 y=30 w=200 h=80 text=Card\n" ++
        "@slide\n" ++
        "@pop card id=first\n" ++
        "@box id=tail text=Tail\n";
    const expected =
        "@push card x=20 y=30 w=200 h=80 text=Card\n" ++
        "@slide\n" ++
        "@pop card id=first\n" ++
        "@pop card id=second x=40 y=50\n" ++
        "@box id=tail text=Tail\n";
    const pop_offset = std.mem.indexOf(u8, source, "@pop card").?;
    const result = try duplicateItem(
        std.testing.allocator,
        source,
        pop_offset,
        "second",
        .{ .x = 40, .y = 50 },
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(expected, result.source);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const deck = try slides.SlideShow.new(arena.allocator());
    const context = try parser.constructSlidesFromBuf(result.source, deck, arena.allocator());
    defer context.deinit();
    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    const items = deck.slides.items[0].items.?.items;
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqualStrings("first", items[0].id.?);
    try std.testing.expectEqualStrings("second", items[1].id.?);
    try std.testing.expectEqual(slides.SourceScope.component_instance, items[0].source.scope);
    try std.testing.expectEqual(slides.SourceScope.component_instance, items[1].source.scope);
    try std.testing.expectEqualStrings(items[0].text.?, items[1].text.?);
    try std.testing.expectApproxEqAbs(@as(f32, 40), items[1].position.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 50), items[1].position.y, 0.0001);
}

test "item duplication copies owned animation decorators and their formatting" {
    const parser = @import("parser.zig");
    const slides = @import("slides.zig");
    const source =
        "@slide\n" ++
        "@anim(fade) duration=0.4\n" ++
        "# animation note\n" ++
        "@box id=hero x=10 y=20 text=Animated\n" ++
        "# item note\n" ++
        "@box id=tail text=Tail\n";
    const expected =
        "@slide\n" ++
        "@anim(fade) duration=0.4\n" ++
        "# animation note\n" ++
        "@box id=hero x=10 y=20 text=Animated\n" ++
        "# item note\n" ++
        "@anim(fade) duration=0.4\n" ++
        "# animation note\n" ++
        "@box id=hero_copy x=30 y=40 text=Animated\n" ++
        "# item note\n" ++
        "@box id=tail text=Tail\n";
    const item_offset = std.mem.indexOf(u8, source, "@box id=hero").?;
    const result = try duplicateItem(
        std.testing.allocator,
        source,
        item_offset,
        "hero_copy",
        .{ .x = 30, .y = 40 },
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(expected, result.source);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const deck = try slides.SlideShow.new(arena.allocator());
    const context = try parser.constructSlidesFromBuf(result.source, deck, arena.allocator());
    defer context.deinit();
    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    const items = deck.slides.items[0].items.?.items;
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expect(items[0].animation != null);
    try std.testing.expect(items[1].animation != null);
    try std.testing.expectEqual(items[0].animation.?.effect, items[1].animation.?.effect);
    try std.testing.expectApproxEqAbs(items[0].animation.?.duration, items[1].animation.?.duration, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 30), items[1].position.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 40), items[1].position.y, 0.0001);
}

test "image duplication offsets position without materializing automatic dimensions" {
    const parser = @import("parser.zig");
    const slides = @import("slides.zig");
    const source =
        "@slide\n" ++
        "@box id=photo img=photo.png x=100 y=200 scale=0.5 ratio=1.4\n";
    const item_offset = std.mem.indexOf(u8, source, "@box").?;
    const result = try duplicateItem(
        std.testing.allocator,
        source,
        item_offset,
        "photo_copy",
        .{ .x = 120, .y = 220 },
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "@slide\n" ++
            "@box id=photo img=photo.png x=100 y=200 scale=0.5 ratio=1.4\n" ++
            "@box id=photo_copy img=photo.png x=120 y=220 scale=0.5 ratio=1.4\n",
        result.source,
    );
    try std.testing.expect(std.mem.indexOf(u8, result.source, "photo_copy") != null);
    try std.testing.expect(std.mem.indexOfPos(u8, result.source, std.mem.indexOf(u8, result.source, "photo_copy").?, " w=") == null);
    try std.testing.expect(std.mem.indexOfPos(u8, result.source, std.mem.indexOf(u8, result.source, "photo_copy").?, " h=") == null);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const deck = try slides.SlideShow.new(arena.allocator());
    const context = try parser.constructSlidesFromBuf(result.source, deck, arena.allocator());
    defer context.deinit();
    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    const items = deck.slides.items[0].items.?.items;
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqual(slides.SlideItemKind.img, items[1].kind);
    try std.testing.expectApproxEqAbs(@as(f32, 120), items[1].position.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 220), items[1].position.y, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), items[1].scale.?, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.4), items[1].ratio.?, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), items[1].size.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), items[1].size.y, 0.0001);
}

test "item duplication rejects structural mutation crowd generated and colliding source" {
    const placement: DuplicateItemPlacement = .{ .x = 20, .y = 20 };
    const structural =
        "@slide\n" ++
        "@box id=hero text=Hero\n" ++
        "@state(morph)\n" ++
        "@set hero x=20\n";
    const state = std.mem.indexOf(u8, structural, "@state").?;
    const mutation = std.mem.indexOf(u8, structural, "@set").?;
    try std.testing.expectError(
        error.UnsupportedItemDuplication,
        duplicateItem(std.testing.allocator, structural, 0, "slide_copy", placement),
    );
    try std.testing.expectError(
        error.UnsupportedItemDuplication,
        duplicateItem(std.testing.allocator, structural, state, "state_copy", placement),
    );
    try std.testing.expectError(
        error.UnsupportedItemDuplication,
        duplicateItem(std.testing.allocator, structural, mutation, "mutation_copy", placement),
    );

    const crowd = "@slide\n@crowd join id=room text=Join\n";
    try std.testing.expectError(
        error.UnsupportedItemDuplication,
        duplicateItem(std.testing.allocator, crowd, std.mem.indexOf(u8, crowd, "@crowd").?, "other_room", placement),
    );
    const background = "@slide\n@bg id=back color=#102030ff\n";
    try std.testing.expectError(
        error.UnsupportedItemDuplication,
        duplicateItem(std.testing.allocator, background, std.mem.indexOf(u8, background, "@bg").?, "back_copy", placement),
    );

    const dynamic = "@slide\n@box id=hero x=$left$ text=Generated\n";
    try std.testing.expectError(
        error.UnsupportedItemDuplication,
        duplicateItem(std.testing.allocator, dynamic, std.mem.indexOf(u8, dynamic, "@box").?, "hero_copy", placement),
    );
    const dynamic_body = "@slide\n@box id=hero\n$title$\n";
    try std.testing.expectError(
        error.UnsupportedItemDuplication,
        duplicateItem(std.testing.allocator, dynamic_body, std.mem.indexOf(u8, dynamic_body, "@box").?, "hero_copy", placement),
    );

    const collision = "@slide\n@box id=hero text=Hero\n@box id=used text=Used\n";
    try std.testing.expectError(
        error.ItemIdCollision,
        duplicateItem(std.testing.allocator, collision, std.mem.indexOf(u8, collision, "@box").?, "used", placement),
    );
    try std.testing.expectError(
        error.InvalidLiteralValue,
        duplicateItem(std.testing.allocator, collision, std.mem.indexOf(u8, collision, "@box").?, "$copy$", placement),
    );
    try std.testing.expectError(
        error.UnsupportedItemDuplication,
        duplicateItem(std.testing.allocator, collision, 2, "copy", placement),
    );
    try std.testing.expectError(
        error.InvalidCoordinate,
        duplicateItem(
            std.testing.allocator,
            collision,
            std.mem.indexOf(u8, collision, "@box").?,
            "copy",
            .{ .x = std.math.nan(f32), .y = 20 },
        ),
    );
}

test "item duplication rejects ambiguous pending animation and dynamic pop name" {
    const placement: DuplicateItemPlacement = .{ .x = 20, .y = 20 };
    const crossed_global =
        "@slide\n" ++
        "@anim(fade)\n" ++
        "@color=#ffffffff\n" ++
        "@box id=hero text=Hero\n";
    const item_offset = std.mem.indexOf(u8, crossed_global, "@box").?;
    try std.testing.expectError(
        error.UnsupportedItemDuplication,
        duplicateItem(std.testing.allocator, crossed_global, item_offset, "hero_copy", placement),
    );

    const dynamic_pop = "@slide\n@pop $component$ id=hero\n";
    const pop_offset = std.mem.indexOf(u8, dynamic_pop, "@pop").?;
    try std.testing.expectError(
        error.UnsupportedItemDuplication,
        duplicateItem(std.testing.allocator, dynamic_pop, pop_offset, "hero_copy", placement),
    );

    const implicit_pop_collision =
        "@push card text=Card\n" ++
        "@slide\n" ++
        "@box id=hero text=Hero\n" ++
        "@pop card\n";
    try std.testing.expectError(
        error.ItemIdCollision,
        duplicateItem(
            std.testing.allocator,
            implicit_pop_collision,
            std.mem.indexOf(u8, implicit_pop_collision, "@box").?,
            "card",
            placement,
        ),
    );
}

test "multi item layer reorder preserves ownership order BOM CRLF and EOF validity" {
    const parser = @import("parser.zig");
    const slides = @import("slides.zig");
    const source =
        "\xEF\xBB\xBF@slide\r\n" ++
        "@anim(fade) duration=0.4\r\n" ++
        "# animation note\r\n" ++
        "@box id=a x=10 y=20\r\n" ++
        "A body\r\n" ++
        "# A note\r\n" ++
        "@box id=b x=20 y=30 text=B\r\n" ++
        "@box id=c x=30 y=40 text=C";
    const expected =
        "\xEF\xBB\xBF@slide\r\n" ++
        "@box id=c x=30 y=40 text=C\r\n" ++
        "@anim(fade) duration=0.4\r\n" ++
        "# animation note\r\n" ++
        "@box id=a x=10 y=20\r\n" ++
        "A body\r\n" ++
        "# A note\r\n" ++
        "@box id=b x=20 y=30 text=B\r\n";
    const offsets = [_]usize{
        std.mem.indexOf(u8, source, "@box id=a").?,
        std.mem.indexOf(u8, source, "@box id=b").?,
    };
    const result = try reorderItemsLayer(
        std.testing.allocator,
        source,
        .{ .base_slide = utf8_bom.len },
        &offsets,
        .forward,
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(expected, result.source);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, result.source, utf8_bom));

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const deck = try slides.SlideShow.new(arena.allocator());
    const context = try parser.constructSlidesFromBuf(result.source, deck, arena.allocator());
    defer context.deinit();
    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    const items = deck.slides.items[0].items.?.items;
    try std.testing.expectEqualStrings("c", items[0].id.?);
    try std.testing.expectEqualStrings("a", items[1].id.?);
    try std.testing.expectEqualStrings("b", items[2].id.?);
    try std.testing.expect(items[1].animation != null);
    try std.testing.expectEqualStrings("A body", items[1].text.?);

    try std.testing.expectError(error.NoLayerChange, reorderItemLayer(
        std.testing.allocator,
        source,
        .{ .base_slide = utf8_bom.len },
        std.mem.indexOf(u8, source, "@box id=c").?,
        .to_front,
    ));
}

test "layer operations support local popslide items and births but honor mutation barriers" {
    const parser = @import("parser.zig");
    const slides = @import("slides.zig");
    const source =
        "@box id=shared text=Shared\n" ++
        "@pushslide layout\n" ++
        "@popslide layout\n" ++
        "@set shared x=100\n" ++
        "@box id=local_a text=Local A\n" ++
        "@box id=local_b text=Local B\n" ++
        "@state(morph)\n" ++
        "@set shared y=200\n" ++
        "@box id=born_a text=Born A\n" ++
        "@box id=born_b text=Born B\n";
    const slide_offset = std.mem.indexOf(u8, source, "@popslide").?;
    const state_offset = std.mem.indexOf(u8, source, "@state").?;
    const base_moved = try reorderItemLayer(
        std.testing.allocator,
        source,
        .{ .base_slide = slide_offset },
        std.mem.indexOf(u8, source, "@box id=local_a").?,
        .forward,
    );
    defer base_moved.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, base_moved.source, "@box id=local_b").? <
        std.mem.indexOf(u8, base_moved.source, "@box id=local_a").?);

    const morph_moved = try reorderItemLayer(
        std.testing.allocator,
        source,
        .{ .morph_state = state_offset },
        std.mem.indexOf(u8, source, "@box id=born_a").?,
        .forward,
    );
    defer morph_moved.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, morph_moved.source, "@box id=born_b").? <
        std.mem.indexOf(u8, morph_moved.source, "@box id=born_a").?);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const deck = try slides.SlideShow.new(arena.allocator());
    const context = try parser.constructSlidesFromBuf(morph_moved.source, deck, arena.allocator());
    defer context.deinit();
    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    const state_items = deck.slides.items[0].morph_states.items[0].items.items;
    try std.testing.expectEqualStrings("born_b", state_items[state_items.len - 2].id.?);
    try std.testing.expectEqualStrings("born_a", state_items[state_items.len - 1].id.?);

    const barrier =
        "@slide\n" ++
        "@box id=a text=A\n" ++
        "@color=#ffffffff\n" ++
        "@box id=b text=B\n";
    try std.testing.expectError(error.UnsupportedItemLayerMove, reorderItemLayer(
        std.testing.allocator,
        barrier,
        .{ .base_slide = 0 },
        std.mem.indexOf(u8, barrier, "@box id=a").?,
        .forward,
    ));
}

test "layer operations pin background floors in base and morph scenes" {
    const parser = @import("parser.zig");
    const slides = @import("slides.zig");
    const base =
        "@slide\n" ++
        "@box id=buried text=Buried\n" ++
        "@bg id=background color=#101010ff\n" ++
        "@box id=a text=A\n" ++
        "@box id=b text=B\n";
    const base_result = try reorderItemLayer(
        std.testing.allocator,
        base,
        .{ .base_slide = 0 },
        std.mem.indexOf(u8, base, "@box id=b text=B").?,
        .to_back,
    );
    defer base_result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "@slide\n" ++
            "@box id=buried text=Buried\n" ++
            "@bg id=background color=#101010ff\n" ++
            "@box id=b text=B\n" ++
            "@box id=a text=A\n",
        base_result.source,
    );
    try std.testing.expectError(error.NoLayerChange, reorderItemLayer(
        std.testing.allocator,
        base,
        .{ .base_slide = 0 },
        std.mem.indexOf(u8, base, "@box id=a").?,
        .backward,
    ));
    try std.testing.expectError(error.UnsupportedItemLayerMove, reorderItemLayer(
        std.testing.allocator,
        base,
        .{ .base_slide = 0 },
        std.mem.indexOf(u8, base, "@bg").?,
        .forward,
    ));

    const morph =
        "@slide\n" ++
        "@box id=base text=Base\n" ++
        "@state(morph)\n" ++
        "@box id=born_below text=Below\n" ++
        "@bg id=morph_background color=#202020ff\n" ++
        "@box id=born_a text=A\n" ++
        "@box id=born_b text=B\n";
    const morph_result = try reorderItemLayer(
        std.testing.allocator,
        morph,
        .{ .morph_state = std.mem.indexOf(u8, morph, "@state").? },
        std.mem.indexOf(u8, morph, "@box id=born_b text=B").?,
        .backward,
    );
    defer morph_result.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, morph_result.source, "@bg id=morph_background").? <
        std.mem.indexOf(u8, morph_result.source, "@box id=born_b text=B").?);
    try std.testing.expect(std.mem.indexOf(u8, morph_result.source, "@box id=born_b text=B").? <
        std.mem.indexOf(u8, morph_result.source, "@box id=born_a text=A").?);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const deck = try slides.SlideShow.new(arena.allocator());
    const context = try parser.constructSlidesFromBuf(morph_result.source, deck, arena.allocator());
    defer context.deinit();
    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
}

test "item scene operations reject slides captured as template definitions" {
    const captured_base =
        "@slide\n" ++
        "@box id=a text=A\n" ++
        "@box id=b text=B\n" ++
        "@pushslide saved\n" ++
        "@popslide saved\n";
    const a = std.mem.indexOf(u8, captured_base, "@box id=a").?;
    try std.testing.expectError(error.InvalidItemScene, reorderItemLayer(
        std.testing.allocator,
        captured_base,
        .{ .base_slide = 0 },
        a,
        .forward,
    ));
    try std.testing.expectError(error.InvalidItemScene, captureItemSnippet(
        std.testing.allocator,
        captured_base,
        .{ .base_slide = 0 },
        a,
    ));

    const captured_morph =
        "@slide\n" ++
        "@box id=a text=A\n" ++
        "@state(morph)\n" ++
        "@box id=born text=Born\n" ++
        "@pushslide saved\n" ++
        "@popslide saved\n";
    const state = std.mem.indexOf(u8, captured_morph, "@state").?;
    const paste: CapturedPasteItem = .{
        .snippet = "@box id=old text=Copy\n",
        .new_id = "copy",
        .placement = .{ .x = 10, .y = 20 },
    };
    try std.testing.expectError(error.InvalidItemScene, pasteCapturedItem(
        std.testing.allocator,
        captured_morph,
        .{ .morph_state = state },
        paste,
    ));

    // Rejected source operations return no PatchResult, so the caller-owned
    // source remains byte-for-byte untouched.
    try std.testing.expectEqualStrings(
        "@slide\n@box id=a text=A\n@box id=b text=B\n@pushslide saved\n@popslide saved\n",
        captured_base,
    );
}

test "clipboard capture and atomic paste preserve boxes and unlock copies" {
    const parser = @import("parser.zig");
    const slides = @import("slides.zig");
    const source =
        "\xEF\xBB\xBF@slide\r\n" ++
        "@anim(fade) duration=0.4\r\n" ++
        "@box id=photo img=photo.png x=100 y=200 scale=0.5 ratio=1.4 locked=true\r\n" ++
        "# photo note\r\n" ++
        "@box id=caption x=40 y=50 locked=true\r\n" ++
        "Caption body\r\n" ++
        "@slide\r\n" ++
        "@box id=target text=Target";
    const first_slide = utf8_bom.len;
    const second_slide = std.mem.lastIndexOf(u8, source, "@slide").?;
    const photo = try captureItemSnippet(
        std.testing.allocator,
        source,
        .{ .base_slide = first_slide },
        std.mem.indexOf(u8, source, "@box id=photo").?,
    );
    defer std.testing.allocator.free(photo);
    const caption = try captureItemSnippet(
        std.testing.allocator,
        source,
        .{ .base_slide = first_slide },
        std.mem.indexOf(u8, source, "@box id=caption").?,
    );
    defer std.testing.allocator.free(caption);
    const paste_items = [_]CapturedPasteItem{
        .{ .snippet = photo, .new_id = "photo_copy", .placement = .{ .x = 300, .y = 400 } },
        .{ .snippet = caption, .new_id = "caption_copy", .placement = .{ .x = 500, .y = 600 } },
    };
    const pasted = try pasteCapturedItems(
        std.testing.allocator,
        source,
        .{ .base_slide = second_slide },
        &paste_items,
    );
    defer pasted.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, pasted.source, utf8_bom));
    try std.testing.expect(std.mem.indexOf(u8, pasted.source, "id=photo_copy") != null);
    try std.testing.expect(std.mem.indexOf(u8, pasted.source, "id=caption_copy") != null);
    try std.testing.expect(std.mem.indexOf(u8, pasted.source, "id=photo_copy img=photo.png x=300 y=400 scale=0.5 ratio=1.4 locked=false") != null);
    try std.testing.expect(std.mem.indexOf(u8, pasted.source, "photo_copy img=photo.png x=300 y=400 w=") == null);
    try std.testing.expect(std.mem.indexOf(u8, pasted.source, "photo_copy img=photo.png x=300 y=400 h=") == null);
    try std.testing.expect(std.mem.endsWith(u8, pasted.source, "Caption body\r\n"));

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const deck = try slides.SlideShow.new(arena.allocator());
    const context = try parser.constructSlidesFromBuf(pasted.source, deck, arena.allocator());
    defer context.deinit();
    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    const items = deck.slides.items[1].items.?.items;
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqualStrings("photo_copy", items[1].id.?);
    try std.testing.expect(!items[1].locked);
    try std.testing.expectApproxEqAbs(@as(f32, 300), items[1].position.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), items[1].size.x, 0.0001);
    try std.testing.expect(items[1].animation != null);
    try std.testing.expectEqualStrings("caption_copy", items[2].id.?);
    try std.testing.expectEqualStrings("Caption body", items[2].text.?);
    try std.testing.expect(!items[2].locked);
}

test "component clipboard preserves exact definition and rejects unsafe destinations" {
    const parser = @import("parser.zig");
    const slides = @import("slides.zig");
    const source =
        "\xEF\xBB\xBF@push card img=photo.png scale=0.5 ratio=1.4\r\n" ++
        "@slide\r\n" ++
        "@anim(fade) duration=0.4\r\n" ++
        "@pop card id=first x=10 y=20 locked=true\r\n" ++
        "# owned pop note\r\n" ++
        "@slide\r\n" ++
        "@box id=target text=Target\r\n" ++
        "@state(morph)\r\n";
    const first_slide = std.mem.indexOf(u8, source, "@slide").?;
    const second_slide = std.mem.lastIndexOf(u8, source, "@slide").?;
    const captured = try captureItemForPaste(
        std.testing.allocator,
        source,
        .{ .base_slide = first_slide },
        std.mem.indexOf(u8, source, "@pop card").?,
    );
    defer captured.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?usize, utf8_bom.len), captured.component_definition_offset);
    try std.testing.expectError(error.UnsupportedClipboardItem, captureItemSnippet(
        std.testing.allocator,
        source,
        .{ .base_slide = first_slide },
        std.mem.indexOf(u8, source, "@pop card").?,
    ));

    const item: CapturedPasteItem = .{
        .snippet = captured.snippet,
        .component_definition_offset = captured.component_definition_offset,
        .new_id = "card_copy",
        .placement = .{ .x = 100, .y = 200 },
    };
    const pasted = try pasteCapturedItem(
        std.testing.allocator,
        source,
        .{ .base_slide = second_slide },
        item,
    );
    defer pasted.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(
        u8,
        pasted.source,
        "@pop card id=card_copy x=100 y=200 locked=false\r\n# owned pop note\r\n@state",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, pasted.source, "id=card_copy x=100 y=200 w=") == null);
    try std.testing.expect(std.mem.indexOf(u8, pasted.source, "id=card_copy x=100 y=200 h=") == null);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const deck = try slides.SlideShow.new(arena.allocator());
    const context = try parser.constructSlidesFromBuf(pasted.source, deck, arena.allocator());
    defer context.deinit();
    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    const copied = deck.slides.items[1].items.?.items[1];
    try std.testing.expectEqualStrings("card_copy", copied.id.?);
    try std.testing.expectEqual(slides.SourceScope.component_instance, copied.source.scope);
    try std.testing.expect(!copied.locked);
    try std.testing.expect(copied.animation != null);
    try std.testing.expectApproxEqAbs(@as(f32, 0), copied.size.x, 0.0001);

    try std.testing.expectError(error.UnsupportedClipboardItem, pasteCapturedItem(
        std.testing.allocator,
        source,
        .{ .morph_state = std.mem.indexOf(u8, source, "@state").? },
        item,
    ));

    const shadowed =
        "@push card text=First\n" ++
        "@push card text=Second\n" ++
        "@slide\n" ++
        "@box id=target text=Target\n";
    const shadow_item: CapturedPasteItem = .{
        .snippet = "@pop card id=old\n",
        .component_definition_offset = 0,
        .new_id = "copy",
        .placement = .{ .x = 1, .y = 2 },
    };
    try std.testing.expectError(error.UnsupportedClipboardItem, pasteCapturedItem(
        std.testing.allocator,
        shadowed,
        .{ .base_slide = std.mem.indexOf(u8, shadowed, "@slide").? },
        shadow_item,
    ));

    const shifted =
        "# inserted before captured definition\n" ++
        "@push card text=First\n" ++
        "@slide\n";
    try std.testing.expectError(error.UnsupportedClipboardItem, pasteCapturedItem(
        std.testing.allocator,
        shifted,
        .{ .base_slide = std.mem.indexOf(u8, shifted, "@slide").? },
        shadow_item,
    ));

    const generated =
        "@let attrs=text=Generated\n" ++
        "$definition$\n" ++
        "@push card text=Card\n" ++
        "@slide\n";
    const generated_item: CapturedPasteItem = .{
        .snippet = "@pop card id=old\n",
        .component_definition_offset = std.mem.indexOf(u8, generated, "@push card").?,
        .new_id = "copy",
        .placement = .{ .x = 1, .y = 2 },
    };
    try std.testing.expectError(error.UnsupportedClipboardItem, pasteCapturedItem(
        std.testing.allocator,
        generated,
        .{ .base_slide = std.mem.indexOf(u8, generated, "@slide").? },
        generated_item,
    ));
}

test "batch duplication atomically copies boxes and exact component instances" {
    const parser = @import("parser.zig");
    const slides = @import("slides.zig");
    const source =
        "@push card text=Card\n" ++
        "@slide\n" ++
        "@box id=photo img=photo.png x=10 y=20 scale=0.5 ratio=1.4 locked=true\n" ++
        "# photo note\n" ++
        "@pop card id=card_one x=30 y=40 locked=true\n" ++
        "# card note";
    const slide = std.mem.indexOf(u8, source, "@slide").?;
    const targets = [_]DuplicateItemTarget{
        .{
            .directive_offset = std.mem.indexOf(u8, source, "@box id=photo").?,
            .new_id = "photo_copy",
            .placement = .{ .x = 110, .y = 120 },
        },
        .{
            .directive_offset = std.mem.indexOf(u8, source, "@pop card").?,
            .new_id = "card_copy",
            .placement = .{ .x = 130, .y = 140 },
        },
    };
    const result = try duplicateItems(
        std.testing.allocator,
        source,
        .{ .base_slide = slide },
        .{ .base_slide = slide },
        &targets,
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(
        u8,
        result.source,
        "@box id=photo_copy img=photo.png x=110 y=120 scale=0.5 ratio=1.4 locked=false",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        result.source,
        "@pop card id=card_copy x=130 y=140 locked=false",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, result.source, "photo_copy img=photo.png x=110 y=120 w=") == null);
    try std.testing.expect(std.mem.endsWith(u8, result.source, "# card note\n"));

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const deck = try slides.SlideShow.new(arena.allocator());
    const context = try parser.constructSlidesFromBuf(result.source, deck, arena.allocator());
    defer context.deinit();
    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    const items = deck.slides.items[0].items.?.items;
    try std.testing.expectEqual(@as(usize, 4), items.len);
    try std.testing.expectEqualStrings("photo_copy", items[2].id.?);
    try std.testing.expectEqualStrings("card_copy", items[3].id.?);
    try std.testing.expect(!items[2].locked);
    try std.testing.expect(!items[3].locked);

    const colliding = [_]DuplicateItemTarget{
        .{
            .directive_offset = targets[0].directive_offset,
            .new_id = "same",
            .placement = .{ .x = 1, .y = 2 },
        },
        .{
            .directive_offset = targets[1].directive_offset,
            .new_id = "same",
            .placement = .{ .x = 3, .y = 4 },
        },
    };
    try std.testing.expectError(error.ItemIdCollision, duplicateItems(
        std.testing.allocator,
        source,
        .{ .base_slide = slide },
        .{ .base_slide = slide },
        &colliding,
    ));
}

test "clipboard paste supports popslide morph births and rejects animated snippets" {
    const parser = @import("parser.zig");
    const slides = @import("slides.zig");
    const destination =
        "@box id=shared text=Shared\n" ++
        "@pushslide layout\n" ++
        "@popslide layout\n" ++
        "@state(morph)\n" ++
        "@set shared x=100\n";
    const state = std.mem.indexOf(u8, destination, "@state").?;
    const plain: CapturedPasteItem = .{
        .snippet = "@box id=old x=1 y=2 locked=true text=Born",
        .new_id = "born_copy",
        .placement = .{ .x = 300, .y = 400 },
    };
    const pasted = try pasteCapturedItem(
        std.testing.allocator,
        destination,
        .{ .morph_state = state },
        plain,
    );
    defer pasted.deinit(std.testing.allocator);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const deck = try slides.SlideShow.new(arena.allocator());
    const context = try parser.constructSlidesFromBuf(pasted.source, deck, arena.allocator());
    defer context.deinit();
    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    const state_items = deck.slides.items[0].morph_states.items[0].items.items;
    const born = state_items[state_items.len - 1];
    try std.testing.expectEqualStrings("born_copy", born.id.?);
    try std.testing.expect(!born.locked);

    const decorated: CapturedPasteItem = .{
        .snippet = "@anim(fade)\n@box id=old text=Animated\n",
        .new_id = "decorated_copy",
        .placement = .{ .x = 10, .y = 20 },
    };
    try std.testing.expectError(error.UnsupportedClipboardItem, pasteCapturedItem(
        std.testing.allocator,
        destination,
        .{ .morph_state = state },
        decorated,
    ));
    const inline_item: CapturedPasteItem = .{
        .snippet = "@box id=old anim=fade text=Animated\n",
        .new_id = "inline_copy",
        .placement = .{ .x = 10, .y = 20 },
    };
    try std.testing.expectError(error.UnsupportedClipboardItem, pasteCapturedItem(
        std.testing.allocator,
        destination,
        .{ .morph_state = state },
        inline_item,
    ));
}

test "clipboard rejects unsupported generated instance and colliding snippets atomically" {
    const destination = "@slide\n@box id=used text=Used\n";
    const rejected = [_]CapturedPasteItem{
        .{ .snippet = "@bg id=back color=#ffffffff\n", .new_id = "back_copy", .placement = .{ .x = 0, .y = 0 } },
        .{ .snippet = "@crowd join id=room\n", .new_id = "room_copy", .placement = .{ .x = 0, .y = 0 } },
        .{ .snippet = "@pop card id=card\n", .new_id = "card_copy", .placement = .{ .x = 0, .y = 0 } },
        .{ .snippet = "@box id=old x=$left$\n", .new_id = "dynamic_copy", .placement = .{ .x = 0, .y = 0 } },
    };
    for (rejected) |item| {
        try std.testing.expectError(error.UnsupportedClipboardItem, pasteCapturedItem(
            std.testing.allocator,
            destination,
            .{ .base_slide = 0 },
            item,
        ));
    }
    const collision: CapturedPasteItem = .{
        .snippet = "@box id=old text=Copy\n",
        .new_id = "used",
        .placement = .{ .x = 1, .y = 2 },
    };
    try std.testing.expectError(error.ItemIdCollision, pasteCapturedItem(
        std.testing.allocator,
        destination,
        .{ .base_slide = 0 },
        collision,
    ));
    try std.testing.expectEqualStrings("@slide\n@box id=used text=Used\n", destination);
}

test "atomic literal edits patch and insert in original-offset caller order" {
    const parser = @import("parser.zig");
    const slides = @import("slides.zig");
    const source =
        "\xEF\xBB\xBF@slide\r\n" ++
        "@box id=a locked=false text=A\r\n" ++
        "@box id=b text=B";
    const a = std.mem.indexOf(u8, source, "@box id=a").?;
    const b = std.mem.indexOf(u8, source, "@box id=b").?;
    const lock_a = [_]LiteralAttributePatch{.{ .key = "locked", .value = "true" }};
    const lock_b = [_]LiteralAttributePatch{.{ .key = "locked", .value = "false" }};
    const edits = [_]LiteralSourceEdit{
        .{ .patch = .{ .directive_offset = a, .patches = &lock_a } },
        .{ .insert = .{ .insertion_offset = b, .snippet = "@box id=c text=C" } },
        .{ .insert = .{ .insertion_offset = b, .snippet = "@box id=d text=D" } },
        .{ .patch = .{ .directive_offset = b, .patches = &lock_b } },
    };
    const result = try applyLiteralEdits(std.testing.allocator, source, &edits);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "\xEF\xBB\xBF@slide\r\n" ++
            "@box id=a locked=true text=A\r\n" ++
            "@box id=c text=C\r\n" ++
            "@box id=d text=D\r\n" ++
            "@box id=b locked=false text=B",
        result.source,
    );

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const deck = try slides.SlideShow.new(arena.allocator());
    const context = try parser.constructSlidesFromBuf(result.source, deck, arena.allocator());
    defer context.deinit();
    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    const items = deck.slides.items[0].items.?.items;
    try std.testing.expect(items[0].locked);
    try std.testing.expectEqualStrings("c", items[1].id.?);
    try std.testing.expectEqualStrings("d", items[2].id.?);
    try std.testing.expect(!items[3].locked);
}

test "deletes only the exact selected physical directive" {
    const source =
        "\xEF\xBB\xBF@slide\r\n" ++
        "@box id=same text=First\r\n" ++
        "@box id=same text=Second\r\n" ++
        "# retained\r\n";
    const selected = std.mem.indexOf(u8, source, "@box id=same text=Second").?;
    const expected =
        "\xEF\xBB\xBF@slide\r\n" ++
        "@box id=same text=First\r\n" ++
        "# retained\r\n";

    const result = try deleteDirective(std.testing.allocator, source, selected);
    try expectSourceResult(result, source, expected);
}

test "semantic item deletion removes body text and retains comments" {
    const source =
        "@slide\n" ++
        "@box id=remove\n" ++
        "- old bullet\n" ++
        "# retained explanation\n" ++
        "- another old bullet\n" ++
        "@box id=keep text=Keep\n";
    const expected =
        "@slide\n" ++
        "# retained explanation\n" ++
        "@box id=keep text=Keep\n";
    const offset = std.mem.indexOf(u8, source, "@box id=remove").?;
    const result = try deleteItem(std.testing.allocator, source, offset);
    try expectSourceResult(result, source, expected);
}

test "semantic item deletion owns pending animation decorators" {
    const source =
        "@slide\n" ++
        "@anim(fade) duration=0.4\n" ++
        "ignored decorator body\n" ++
        "# first retained note\n" ++
        "@anim slide-up\n" ++
        "# second retained note\n" ++
        "@box id=remove\n" ++
        "Removed text\n" ++
        "@box id=keep text=Keep\n";
    const item_offset = std.mem.indexOf(u8, source, "@box id=remove").?;
    const first_animation = std.mem.indexOf(u8, source, "@anim(fade)").?;
    try std.testing.expectEqual(
        first_animation,
        try itemInsertionOffsetBeforeAnimations(source, item_offset),
    );

    const expected =
        "@slide\n" ++
        "# first retained note\n" ++
        "# second retained note\n" ++
        "@box id=keep text=Keep\n";
    const result = try deleteItem(std.testing.allocator, source, item_offset);
    try expectSourceResult(result, source, expected);
}

test "insertion before an animated item cannot steal its decorator" {
    const source =
        "@slide\n" ++
        "@anim(fade) duration=0.4\n" ++
        "# animation explanation\n" ++
        "@box id=hero text=Hero\n";
    const item_offset = std.mem.indexOf(u8, source, "@box id=hero").?;
    const insertion_offset = try itemInsertionOffsetBeforeAnimations(source, item_offset);
    const result = try insertDirectiveAt(
        std.testing.allocator,
        source,
        insertion_offset,
        "@box id=background color=#102030ff",
    );
    const expected =
        "@slide\n" ++
        "@box id=background color=#102030ff\n" ++
        "@anim(fade) duration=0.4\n" ++
        "# animation explanation\n" ++
        "@box id=hero text=Hero\n";
    try expectSourceResult(result, source, expected);
}

test "cascading semantic deletion removes later morph mutations only on current slide" {
    const parser = @import("parser.zig");
    const slides = @import("slides.zig");
    const source =
        "@slide\n" ++
        "@box id=remove text=Remove\n" ++
        "@box id=keep text=Keep\n" ++
        "@state\n" ++
        "@set remove\n" ++
        "Changed text\n" ++
        "# retained mutation note\n" ++
        "@set keep x=200\n" ++
        "@state(morph)\n" ++
        "@hide remove\n" ++
        "@slide\n" ++
        "@box id=remove text=Same ID on next slide\n";
    const item_offset = std.mem.indexOf(u8, source, "@box id=remove").?;
    const expected =
        "@slide\n" ++
        "@box id=keep text=Keep\n" ++
        "@state\n" ++
        "# retained mutation note\n" ++
        "@set keep x=200\n" ++
        "@state(morph)\n" ++
        "@slide\n" ++
        "@box id=remove text=Same ID on next slide\n";
    const result = try deleteItemCascadingMorphMutations(
        std.testing.allocator,
        source,
        item_offset,
        "remove",
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(expected, result.source);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const deck = try slides.SlideShow.new(arena.allocator());
    const context = try parser.constructSlidesFromBuf(result.source, deck, arena.allocator());
    defer context.deinit();
    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    try std.testing.expectEqual(@as(usize, 2), deck.slides.items.len);
    try std.testing.expectEqualStrings("remove", deck.slides.items[1].items.?.items[0].id.?);
}

test "batch deletion mixes local removal and inherited hide in a popslide base" {
    const parser = @import("parser.zig");
    const slides = @import("slides.zig");
    const source =
        "\xEF\xBB\xBF@push card img=photo.png scale=0.5\r\n" ++
        "@box id=shared text=Shared\r\n" ++
        "@pushslide layout\r\n" ++
        "@popslide layout\r\n" ++
        "@set shared x=10\r\n" ++
        "@anim(fade) duration=0.4\r\n" ++
        "# owned animation note\r\n" ++
        "@box id=local x=20 y=30\r\n" ++
        "Local body\r\n" ++
        "# owned local note\r\n" ++
        "@pop card id=component x=40 y=50\r\n" ++
        "# owned component note\r\n" ++
        "@state(morph)\r\n" ++
        "@set local x=200\r\n" ++
        "# owned local mutation note\r\n" ++
        "@hide component\r\n" ++
        "@set shared y=100\r\n" ++
        "@slide\r\n" ++
        "@box id=local text=Same ID next slide\r\n";
    const targets = [_]DeleteItemTarget{
        .{ .authored = .{
            .directive_offset = std.mem.indexOf(u8, source, "@box id=local x=").?,
            .item_id = "local",
        } },
        .{ .hide = .{ .item_id = "shared" } },
        .{ .authored = .{
            .directive_offset = std.mem.indexOf(u8, source, "@pop card id=component").?,
            .item_id = "component",
        } },
    };
    const result = try deleteItems(
        std.testing.allocator,
        source,
        .{ .base_slide = std.mem.indexOf(u8, source, "@popslide").? },
        &targets,
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, result.source, utf8_bom));
    try std.testing.expect(std.mem.indexOf(u8, result.source, "@hide shared\r\n@state(morph)") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.source, "@box id=local x=") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.source, "@pop card id=component") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.source, "@set local") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.source, "@hide component") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.source, "owned local") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.source, "owned component") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.source, "@box id=local text=Same ID next slide") != null);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const deck = try slides.SlideShow.new(arena.allocator());
    const context = try parser.constructSlidesFromBuf(result.source, deck, arena.allocator());
    defer context.deinit();
    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    try std.testing.expectEqual(@as(usize, 2), deck.slides.items.len);
    try std.testing.expectEqualStrings("local", deck.slides.items[1].items.?.items[0].id.?);
}

test "batch deletion handles morph births and rejects generated dependencies atomically" {
    const parser = @import("parser.zig");
    const slides = @import("slides.zig");
    const source =
        "@push card text=Card\n" ++
        "@slide\n" ++
        "@box id=base text=Base\n" ++
        "@state(morph)\n" ++
        "@box id=born text=Born\n" ++
        "# born note\n" ++
        "@pop card id=born_card\n" ++
        "@set born x=100\n";
    const targets = [_]DeleteItemTarget{
        .{ .authored = .{
            .directive_offset = std.mem.indexOf(u8, source, "@box id=born").?,
            .item_id = "born",
        } },
        .{ .authored = .{
            .directive_offset = std.mem.indexOf(u8, source, "@pop card id=born_card").?,
            .item_id = "born_card",
        } },
        .{ .hide = .{ .item_id = "base" } },
    };
    const result = try deleteItems(
        std.testing.allocator,
        source,
        .{ .morph_state = std.mem.indexOf(u8, source, "@state").? },
        &targets,
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.endsWith(u8, result.source, "@state(morph)\n@hide base\n"));

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const deck = try slides.SlideShow.new(arena.allocator());
    const context = try parser.constructSlidesFromBuf(result.source, deck, arena.allocator());
    defer context.deinit();
    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);

    const dynamic =
        "@slide\n" ++
        "@box id=remove text=Remove\n" ++
        "@state(morph)\n" ++
        "@set remove $move$\n";
    const dynamic_target = [_]DeleteItemTarget{.{ .authored = .{
        .directive_offset = std.mem.indexOf(u8, dynamic, "@box").?,
        .item_id = "remove",
    } }};
    try std.testing.expectError(error.UnsupportedBatchDeletion, deleteItems(
        std.testing.allocator,
        dynamic,
        .{ .base_slide = 0 },
        &dynamic_target,
    ));
    try std.testing.expectEqualStrings(
        "@slide\n@box id=remove text=Remove\n@state(morph)\n@set remove $move$\n",
        dynamic,
    );

    const direct_hide = [_]DeleteItemTarget{.{ .hide = .{ .item_id = "base" } }};
    try std.testing.expectError(error.UnsupportedBatchDeletion, deleteItems(
        std.testing.allocator,
        "@slide\n@box id=base text=Base\n",
        .{ .base_slide = 0 },
        &direct_hide,
    ));
}

test "batch deletion of a morph birth removes same and later state mutations" {
    const parser = @import("parser.zig");
    const slides = @import("slides.zig");
    const source =
        "@slide\n" ++
        "@box id=base text=Base\n" ++
        "@state(morph)\n" ++
        "@box id=born text=Born\n" ++
        "@set born x=100\n" ++
        "# same-state dependency\n" ++
        "@state(morph)\n" ++
        "@show born y=200\n" ++
        "# later-state dependency\n";
    const target = [_]DeleteItemTarget{.{ .authored = .{
        .directive_offset = std.mem.indexOf(u8, source, "@box id=born").?,
        .item_id = "born",
    } }};
    const result = try deleteItems(
        std.testing.allocator,
        source,
        .{ .morph_state = std.mem.indexOf(u8, source, "@state").? },
        &target,
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.source, "born") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.source, "dependency") == null);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const deck = try slides.SlideShow.new(arena.allocator());
    const context = try parser.constructSlidesFromBuf(result.source, deck, arena.allocator());
    defer context.deinit();
    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
}

test "shared template deletion owns item animation body and exact instance dependencies" {
    const parser = @import("parser.zig");
    const slides = @import("slides.zig");
    const source =
        "\xEF\xBB\xBF@anim(fade) duration=0.4\r\n" ++
        "ignored animation body\r\n" ++
        "# retained animation note\r\n" ++
        "@box id=hero x=10 y=20 w=300 h=100\r\n" ++
        "Shared hero body\r\n" ++
        "# retained shared note\r\n" ++
        "@box id=keep x=0 y=0 w=10 h=10 text=Keep\r\n" ++
        "@pushslide layout\r\n" ++
        "@popslide layout\r\n" ++
        "@set hero bg=#10203040\r\n" ++
        "Local hero body\r\n" ++
        "# retained local note\r\n" ++
        "@set keep x=20\r\n" ++
        "@state(morph)\r\n" ++
        "@hide hero\r\n" ++
        "@show keep\r\n" ++
        "@slide\r\n" ++
        "@popslide layout\r\n" ++
        "@state(morph)\r\n" ++
        "@set hero x=500\r\n" ++
        "Morph hero body\r\n" ++
        "@slide\r\n" ++
        "@pushslide reset\r\n" ++
        "@box id=hero x=900 y=20 w=300 h=100 text=Shadow hero\r\n" ++
        "@pushslide layout\r\n" ++
        "@popslide layout\r\n" ++
        "@set hero x=1000\r\n";
    const expected =
        "\xEF\xBB\xBF# retained animation note\r\n" ++
        "# retained shared note\r\n" ++
        "@box id=keep x=0 y=0 w=10 h=10 text=Keep\r\n" ++
        "@pushslide layout\r\n" ++
        "@popslide layout\r\n" ++
        "# retained local note\r\n" ++
        "@set keep x=20\r\n" ++
        "@state(morph)\r\n" ++
        "@show keep\r\n" ++
        "@slide\r\n" ++
        "@popslide layout\r\n" ++
        "@state(morph)\r\n" ++
        "@slide\r\n" ++
        "@pushslide reset\r\n" ++
        "@box id=hero x=900 y=20 w=300 h=100 text=Shadow hero\r\n" ++
        "@pushslide layout\r\n" ++
        "@popslide layout\r\n" ++
        "@set hero x=1000\r\n";
    const representative = std.mem.indexOf(u8, source, "@popslide layout").?;
    const shared = std.mem.indexOf(u8, source, "@box id=hero x=10").?;
    const result = try deleteSharedSlideTemplateItem(
        std.testing.allocator,
        source,
        representative,
        shared,
        "hero",
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(expected, result.source);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, result.source, "\xEF\xBB\xBF"));

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const deck = try slides.SlideShow.new(arena.allocator());
    const context = try parser.constructSlidesFromBuf(result.source, deck, arena.allocator());
    defer context.deinit();
    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    // The same ID belonging to the later, shadowing definition survives.
    const final_slide = deck.slides.items[deck.slides.items.len - 1];
    try std.testing.expectEqualStrings("hero", final_slide.items.?.items[0].id.?);
    try std.testing.expectApproxEqAbs(@as(f32, 1000), final_slide.items.?.items[0].position.x, 0.0001);
}

test "shared template deletion rejects dynamic nested and colliding ownership" {
    const dynamic_item =
        "@let attrs=id=hero x=0 y=0\n" ++
        "@box $attrs$\n" ++
        "@pushslide layout\n" ++
        "@popslide layout\n";
    try std.testing.expectError(error.UnsupportedSharedTemplateDeletion, deleteSharedSlideTemplateItem(
        std.testing.allocator,
        dynamic_item,
        std.mem.indexOf(u8, dynamic_item, "@popslide").?,
        std.mem.indexOf(u8, dynamic_item, "@box").?,
        "hero",
    ));

    const dynamic_shadow =
        "@box id=hero\n" ++
        "@pushslide layout\n" ++
        "@let generated=layout\n" ++
        "@pushslide $generated$\n" ++
        "@popslide layout\n";
    try std.testing.expectError(error.AmbiguousSlideTemplateDependency, deleteSharedSlideTemplateItem(
        std.testing.allocator,
        dynamic_shadow,
        std.mem.indexOf(u8, dynamic_shadow, "@popslide").?,
        std.mem.indexOf(u8, dynamic_shadow, "@box").?,
        "hero",
    ));

    const nested_capture =
        "@box id=hero\n" ++
        "@pushslide layout\n" ++
        "@popslide layout\n" ++
        "@pushslide derived\n" ++
        "@popslide derived\n";
    try std.testing.expectError(error.UnsupportedSharedTemplateDeletion, deleteSharedSlideTemplateItem(
        std.testing.allocator,
        nested_capture,
        std.mem.indexOf(u8, nested_capture, "@popslide layout").?,
        std.mem.indexOf(u8, nested_capture, "@box").?,
        "hero",
    ));

    const duplicate_definition =
        "@box id=hero text=One\n" ++
        "@box id=hero text=Two\n" ++
        "@pushslide layout\n" ++
        "@popslide layout\n";
    try std.testing.expectError(error.AmbiguousSlideTemplateDependency, deleteSharedSlideTemplateItem(
        std.testing.allocator,
        duplicate_definition,
        std.mem.indexOf(u8, duplicate_definition, "@popslide").?,
        std.mem.indexOf(u8, duplicate_definition, "@box").?,
        "hero",
    ));

    const local_collision =
        "@box id=hero text=Shared\n" ++
        "@pushslide layout\n" ++
        "@popslide layout\n" ++
        "@box id=hero text=Local\n";
    try std.testing.expectError(error.AmbiguousSlideTemplateDependency, deleteSharedSlideTemplateItem(
        std.testing.allocator,
        local_collision,
        std.mem.indexOf(u8, local_collision, "@popslide").?,
        std.mem.indexOf(u8, local_collision, "@box").?,
        "hero",
    ));

    const malformed_duplicate_id =
        "@box id=hero id= text=Not safely idless\n" ++
        "@pushslide layout\n" ++
        "@popslide layout\n";
    try std.testing.expectError(error.UnsupportedSharedTemplateDeletion, deleteSharedSlideTemplateItem(
        std.testing.allocator,
        malformed_duplicate_id,
        std.mem.indexOf(u8, malformed_duplicate_id, "@popslide").?,
        std.mem.indexOf(u8, malformed_duplicate_id, "@box").?,
        null,
    ));

    const unsafe_animation_dependency =
        "@box id=hero text=Shared\n" ++
        "@pushslide layout\n" ++
        "@popslide layout\n" ++
        "@anim fade\n" ++
        "@set hero x=10\n";
    try std.testing.expectError(error.UnsupportedSharedTemplateDeletion, deleteSharedSlideTemplateItem(
        std.testing.allocator,
        unsafe_animation_dependency,
        std.mem.indexOf(u8, unsafe_animation_dependency, "@popslide").?,
        std.mem.indexOf(u8, unsafe_animation_dependency, "@box").?,
        "hero",
    ));
}

test "failed shared deletion preserves let-expanded instance item source" {
    const box_source =
        "@box id=hero text=Shared\n" ++
        "@pushslide layout\n" ++
        "@popslide layout\n" ++
        "@let attrs=id=hero x=100\n" ++
        "@box $attrs$ text=Generated local box\n";
    const box_input = try std.testing.allocator.dupe(u8, box_source);
    defer std.testing.allocator.free(box_input);
    const box_before = try std.testing.allocator.dupe(u8, box_input);
    defer std.testing.allocator.free(box_before);
    try std.testing.expectError(error.AmbiguousSlideTemplateDependency, deleteSharedSlideTemplateItem(
        std.testing.allocator,
        box_input,
        std.mem.indexOf(u8, box_input, "@popslide").?,
        std.mem.indexOf(u8, box_input, "@box id=hero").?,
        "hero",
    ));
    try std.testing.expectEqualStrings(box_before, box_input);

    const pop_source =
        "@push card x=10 y=10 text=Card\n" ++
        "@box id=hero text=Shared\n" ++
        "@pushslide layout\n" ++
        "@popslide layout\n" ++
        "@let attrs=id=hero x=200\n" ++
        "@pop card $attrs$\n";
    const pop_input = try std.testing.allocator.dupe(u8, pop_source);
    defer std.testing.allocator.free(pop_input);
    const pop_before = try std.testing.allocator.dupe(u8, pop_input);
    defer std.testing.allocator.free(pop_before);
    try std.testing.expectError(error.AmbiguousSlideTemplateDependency, deleteSharedSlideTemplateItem(
        std.testing.allocator,
        pop_input,
        std.mem.indexOf(u8, pop_input, "@popslide").?,
        std.mem.indexOf(u8, pop_input, "@box id=hero").?,
        "hero",
    ));
    try std.testing.expectEqualStrings(pop_before, pop_input);
}

test "shared template deletion supports an exact idless item" {
    const source =
        "@box x=10 y=20 text=Untargetable\n" ++
        "@box id=keep text=Keep\n" ++
        "@pushslide layout\n" ++
        "@popslide layout\n";
    const result = try deleteSharedSlideTemplateItem(
        std.testing.allocator,
        source,
        std.mem.indexOf(u8, source, "@popslide").?,
        std.mem.indexOf(u8, source, "@box x=10").?,
        null,
    );
    try expectSourceResult(
        result,
        source,
        "@box id=keep text=Keep\n@pushslide layout\n@popslide layout\n",
    );
}

test "scoped template background overrides insert patch clear and reparse" {
    const parser = @import("parser.zig");
    const slides = @import("slides.zig");
    const source =
        "\xEF\xBB\xBF@box id=hero bg=#01020304 text=Hero\r\n" ++
        "@pushslide layout\r\n" ++
        "@popslide layout\r\n" ++
        "@set hero x=10\r\n";
    const slide_offset = std.mem.indexOf(u8, source, "@popslide").?;
    const inserted = try insertSlideTemplateBackgroundOverride(
        std.testing.allocator,
        source,
        slide_offset,
        "hero",
        "#A0B0C0D0",
    );
    defer inserted.deinit(std.testing.allocator);
    const inserted_line = std.mem.indexOf(u8, inserted.source, "@set hero bg=#A0B0C0D0").?;
    try std.testing.expectEqualStrings(
        "\xEF\xBB\xBF@box id=hero bg=#01020304 text=Hero\r\n" ++
            "@pushslide layout\r\n" ++
            "@popslide layout\r\n" ++
            "@set hero x=10\r\n" ++
            "@set hero bg=#A0B0C0D0\r\n",
        inserted.source,
    );

    var inserted_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer inserted_arena.deinit();
    const inserted_deck = try slides.SlideShow.new(inserted_arena.allocator());
    const inserted_context = try parser.constructSlidesFromBuf(
        inserted.source,
        inserted_deck,
        inserted_arena.allocator(),
    );
    defer inserted_context.deinit();
    try std.testing.expectEqual(@as(usize, 0), inserted_context.parser_errors.items.len);
    const fill = inserted_deck.slides.items[0].items.?.items[0].background_color.?;
    try std.testing.expectEqual(@as(u8, 0xA0), fill.r);
    try std.testing.expectEqual(@as(u8, 0xD0), fill.a);

    const cleared = try patchSlideTemplateBackgroundOverride(
        std.testing.allocator,
        inserted.source,
        slide_offset,
        inserted_line,
        "hero",
        "none",
    );
    defer cleared.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, cleared.source, "@set hero bg=none") != null);

    var cleared_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer cleared_arena.deinit();
    const cleared_deck = try slides.SlideShow.new(cleared_arena.allocator());
    const cleared_context = try parser.constructSlidesFromBuf(
        cleared.source,
        cleared_deck,
        cleared_arena.allocator(),
    );
    defer cleared_context.deinit();
    try std.testing.expectEqual(@as(usize, 0), cleared_context.parser_errors.items.len);
    try std.testing.expect(cleared_deck.slides.items[0].items.?.items[0].background_color == null);

    try std.testing.expectError(error.InvalidColorLiteral, insertSlideTemplateBackgroundOverride(
        std.testing.allocator,
        source,
        slide_offset,
        "hero",
        "#abc",
    ));
}

test "deletes and replaces final directives without a terminator" {
    const source = "# heading\n@box text=Old";
    const offset = std.mem.indexOf(u8, source, "@box").?;

    const replaced = try replaceDirectiveLine(std.testing.allocator, source, offset, "@crowd join text=Join");
    try expectSourceResult(replaced, source, "# heading\n@crowd join text=Join");

    const deleted = try deleteDirective(std.testing.allocator, source, offset);
    try expectSourceResult(deleted, source, "# heading\n");
}

test "literal attribute patch preserves formatting comments CRLF and BOM" {
    const source =
        "\xEF\xBB\xBF# deck\r\n" ++
        "@box  color=#01020304\timg=old.png  text=Old words\r\n" ++
        "old body that must not survive\r\n" ++
        "# retained body comment\r\n" ++
        "@slide\r\n";
    const offset = std.mem.indexOf(u8, source, "@box").?;
    const expected =
        "\xEF\xBB\xBF# deck\r\n" ++
        "@box  color=#AABBCCDD\timg=new.png  text=Fresh words\r\n" ++
        "# retained body comment\r\n" ++
        "@slide\r\n";
    const patches = [_]LiteralAttributePatch{
        .{ .key = "color", .value = "#AABBCCDD" },
        .{ .key = "img", .value = "new.png" },
        .{ .key = "text", .value = "Fresh words" },
    };

    const result = try patchLiteralAttributes(std.testing.allocator, source, offset, &patches);
    try expectSourceResult(result, source, expected);
}

test "missing literal attributes are inserted before text" {
    const source = "@box\tx=1  text=Words and = signs  \n";
    const expected = "@box\tx=1  color=#10203040 id=hero text=Words and = signs  \n";
    const patches = [_]LiteralAttributePatch{
        .{ .key = "color", .value = "#10203040" },
        .{ .key = "id", .value = "hero" },
    };
    const result = try patchLiteralAttributes(std.testing.allocator, source, 0, &patches);
    try expectSourceResult(result, source, expected);
}

test "literal patch changes parser-effective duplicate" {
    const source = "@box color=#01010101 color=#02020202 text=Duplicate\n";
    const expected = "@box color=#01010101 color=#A0B0C0D0 text=Duplicate\n";
    const patch = [_]LiteralAttributePatch{.{ .key = "color", .value = "#A0B0C0D0" }};
    const result = try patchLiteralAttributes(std.testing.allocator, source, 0, &patch);
    try expectSourceResult(result, source, expected);
}

test "crowd literal and text patches reparse to edited semantics" {
    const parser = @import("parser.zig");
    const slides = @import("slides.zig");
    const source =
        "@slide\n" ++
        "@crowd join x=10 y=20\n" ++
        "Old prompt\n";
    const crowd_offset = std.mem.indexOf(u8, source, "@crowd").?;
    const attrs = [_]LiteralAttributePatch{
        .{ .key = "id", .value = "room" },
        .{ .key = "open", .value = "false" },
    };
    const first = try patchLiteralAttributes(std.testing.allocator, source, crowd_offset, &attrs);
    defer first.deinit(std.testing.allocator);
    const second = try patchItemText(std.testing.allocator, first.source, crowd_offset, "Join us now");
    defer second.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(
        "@slide\n@crowd join x=10 y=20 id=room open=false text=Join us now\n",
        second.source,
    );
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const deck = try slides.SlideShow.new(arena.allocator());
    const context = try parser.constructSlidesFromBuf(second.source, deck, arena.allocator());
    defer context.deinit();
    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    const item = deck.slides.items[0].items.?.items[0];
    try std.testing.expectEqualStrings("room", item.crowd.?.id);
    try std.testing.expectEqualStrings("Join us now", item.crowd.?.prompt);
    try std.testing.expect(!item.crowd.?.initially_open);
}

test "multiline item text replaces inline and body text but retains comments" {
    const source =
        "@box x=1 text=Inline\r\n" ++
        "old line one\r\n" ++
        "# explanation stays\r\n" ++
        "old line two\r\n" ++
        "@box text=Next\r\n";
    const expected =
        "@box x=1 \r\n" ++
        "- First\r\n" ++
        "- Second\r\n" ++
        "# explanation stays\r\n" ++
        "@box text=Next\r\n";
    const result = try patchItemText(std.testing.allocator, source, 0, "- First\n- Second");
    try expectSourceResult(result, source, expected);
}

test "single-line text that resembles source syntax remains safely inline" {
    const source = "@box x=1\n@slide\n";
    const expected = "@box x=1 text=@slide # still literal\n@slide\n";
    const result = try patchItemText(std.testing.allocator, source, 0, "@slide # still literal");
    try expectSourceResult(result, source, expected);
}

test "inserted bullet snippet reparses as one box" {
    const parser = @import("parser.zig");
    const slides = @import("slides.zig");
    const source = "@slide\n@slide\n@box text=Next\n";
    const result = try insertSnippet(
        std.testing.allocator,
        source,
        0,
        "@box x=100 y=100 w=600 h=400\n- First item\n- Second item",
    );
    defer result.deinit(std.testing.allocator);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const deck = try slides.SlideShow.new(arena.allocator());
    const context = try parser.constructSlidesFromBuf(result.source, deck, arena.allocator());
    defer context.deinit();
    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    try std.testing.expectEqual(@as(usize, 2), deck.slides.items.len);
    const item = deck.slides.items[0].items.?.items[0];
    try std.testing.expectEqualStrings("- First item\n- Second item", item.text.?);
}

test "source editing APIs reject ambiguous unsafe input" {
    const source = "@slide\n@box text=Safe\n";
    try std.testing.expectError(
        error.InvalidInsertionOffset,
        insertDirectiveAt(std.testing.allocator, source, 2, "@box"),
    );
    try std.testing.expectError(
        error.InvalidSnippet,
        insertSnippetAt(std.testing.allocator, source, source.len, "@box\n@slide"),
    );
    try std.testing.expectError(
        error.InvalidSlideOffset,
        slideItemInsertionOffset(source, std.mem.indexOf(u8, source, "@box").?),
    );
    try std.testing.expectError(
        error.InvalidColorLiteral,
        patchLiteralAttributes(std.testing.allocator, source, source.len - "@box text=Safe\n".len, &.{
            .{ .key = "color", .value = "red" },
        }),
    );
    try std.testing.expectError(
        error.InvalidLiteralValue,
        patchLiteralAttributes(std.testing.allocator, source, source.len - "@box text=Safe\n".len, &.{
            .{ .key = "img", .value = "two words.png" },
        }),
    );
    try std.testing.expectError(
        error.InvalidLiteralValue,
        patchItemText(std.testing.allocator, source, source.len - "@box text=Safe\n".len, "@slide\nOops"),
    );
}
