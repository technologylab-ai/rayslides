const std = @import("std");

/// Geometry values to write to one item directive. Width and height are left
/// untouched when they are null.
pub const GeometryPatch = struct {
    x: f32,
    y: f32,
    w: ?f32 = null,
    h: ?f32 = null,
};

/// The caller owns `source` and must free it with the allocator passed to
/// `patchGeometry`.
pub const PatchResult = struct {
    source: []u8,
    byte_delta: isize,

    pub fn deinit(self: PatchResult, allocator: std.mem.Allocator) void {
        allocator.free(self.source);
    }
};

pub const PatchError = error{
    InvalidDirectiveOffset,
    InvalidCoordinate,
    SourceTooLarge,
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

const DirectiveLine = struct {
    start: usize,
    content_end: usize,
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

    return .{ .start = directive_offset, .content_end = content_end };
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
