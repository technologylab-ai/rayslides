//! In-memory source projection for Studio Library previews.
//!
//! The authored document remains untouched. A preview appends one synthetic
//! use at the exact insertion offset already used by Studio's Library, then
//! the caller parses the temporary source and renders only the projected
//! definition. Bytes before the synthetic suffix retain their real source
//! offsets, which is the foundation for the later editable Definition mode.

const std = @import("std");
const slides = @import("slides.zig");
const studio_catalog = @import("studio_catalog.zig");
const source_editor = @import("source_editor.zig");

pub const Error = error{
    InvalidInsertionOffset,
    InvalidDefinitionName,
    InvalidPreviewInstanceId,
    PreviewItemMissing,
};

pub const Request = struct {
    kind: studio_catalog.Kind,
    name: []const u8,
    insertion_offset: usize,
    /// Used only for ITEM/GROUP projection and chosen not to collide with the
    /// current scene. SLIDE projection creates no synthetic item ID.
    instance_id: []const u8 = "__studio_preview_0",
};

/// Build parser input containing the exact source prefix plus one synthetic
/// definition use. The prefix ends at Studio's already-validated insertion
/// boundary, so source-order shadowing matches the corresponding **Use**
/// action instead of resolving against a later same-name definition.
pub fn buildSource(
    allocator: std.mem.Allocator,
    source: []const u8,
    request: Request,
) (std.mem.Allocator.Error || Error)![]u8 {
    if (request.insertion_offset > source.len) return error.InvalidInsertionOffset;
    if (!validName(request.name)) return error.InvalidDefinitionName;
    if (request.kind != .slide and !validName(request.instance_id)) {
        return error.InvalidPreviewInstanceId;
    }

    const directive = switch (request.kind) {
        .element => try std.fmt.allocPrint(
            allocator,
            "@pop {s} id={s}",
            .{ request.name, request.instance_id },
        ),
        .group => try std.fmt.allocPrint(
            allocator,
            "@popgroup {s} id={s}",
            .{ request.name, request.instance_id },
        ),
        .slide => try std.fmt.allocPrint(allocator, "@popslide {s}", .{request.name}),
    };
    defer allocator.free(directive);

    const prefix = source[0..request.insertion_offset];
    const needs_separator = prefix.len > 0 and prefix[prefix.len - 1] != '\n';
    const newline = lineEndingNear(source, request.insertion_offset);
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try output.ensureTotalCapacity(
        allocator,
        prefix.len + @intFromBool(needs_separator) * newline.len + directive.len + newline.len,
    );
    try output.appendSlice(allocator, prefix);
    if (needs_separator) try output.appendSlice(allocator, newline);
    try output.appendSlice(allocator, directive);
    try output.appendSlice(allocator, newline);
    return output.toOwnedSlice(allocator);
}

/// Return an ID root which cannot collide with an existing item or qualified
/// GROUP member in `items`. The returned slice borrows `buffer`.
pub fn unusedInstanceId(items: []const slides.SlideItem, buffer: []u8) ?[]const u8 {
    var suffix: usize = 0;
    while (suffix < 10_000) : (suffix += 1) {
        const candidate = std.fmt.bufPrint(buffer, "__studio_preview_{d}", .{suffix}) catch return null;
        if (!instanceIdCollides(items, candidate)) return candidate;
    }
    return null;
}

/// Isolate the synthetic ITEM/GROUP use from the parsed use-site slide. SLIDE
/// templates already produce a fresh complete slide and are returned as-is.
pub fn projectSlide(
    allocator: std.mem.Allocator,
    parsed: *slides.Slide,
    kind: studio_catalog.Kind,
    instance_id: []const u8,
) (std.mem.Allocator.Error || Error)!*slides.Slide {
    if (kind == .slide) return parsed;

    const preview = try slides.Slide.new(allocator);
    errdefer {
        preview.deinit();
        allocator.destroy(preview);
    }
    preview.fontsize = parsed.fontsize;
    preview.text_color = parsed.text_color;
    preview.bullet_color = parsed.bullet_color;
    preview.bullet_symbol = parsed.bullet_symbol;
    preview.underline_width = parsed.underline_width;
    preview.line_height_factor = parsed.line_height_factor;
    preview.transition = .{};

    for (parsed.items.?.items) |item| {
        const id = item.id orelse continue;
        const matches = switch (kind) {
            .element => std.mem.eql(u8, id, instance_id),
            .group => qualifiedMemberOf(id, instance_id),
            .slide => unreachable,
        };
        if (!matches) continue;
        var projected = item;
        projected.source = switch (kind) {
            .element => item.component_source orelse return error.PreviewItemMissing,
            .group => item.group_member_source orelse return error.PreviewItemMissing,
            .slide => unreachable,
        };
        projected.instance_source = null;
        projected.state_source = null;
        projected.state_source_state = null;
        projected.identity = preview.next_item_identity;
        preview.next_item_identity += 1;
        try preview.items.?.append(allocator, projected);
    }
    if (preview.items.?.items.len == 0) return error.PreviewItemMissing;
    return preview;
}

fn qualifiedMemberOf(id: []const u8, root: []const u8) bool {
    return id.len > root.len and std.mem.startsWith(u8, id, root) and id[root.len] == '.';
}

fn instanceIdCollides(items: []const slides.SlideItem, candidate: []const u8) bool {
    for (items) |item| {
        const id = item.id orelse continue;
        if (std.mem.eql(u8, id, candidate) or qualifiedMemberOf(id, candidate)) return true;
    }
    return false;
}

fn validName(name: []const u8) bool {
    if (name.len == 0 or !(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name[1..]) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-')) return false;
    }
    return true;
}

fn lineEndingNear(source: []const u8, offset: usize) []const u8 {
    if (offset < source.len) {
        if (std.mem.indexOfScalar(u8, source[offset..], '\n')) |relative| {
            const newline = offset + relative;
            return if (newline > 0 and source[newline - 1] == '\r') "\r\n" else "\n";
        }
    }
    if (offset > 0) {
        if (std.mem.lastIndexOfScalar(u8, source[0..offset], '\n')) |newline| {
            return if (newline > 0 and source[newline - 1] == '\r') "\r\n" else "\n";
        }
    }
    return "\n";
}

test "preview source preserves exact prefix shadowing and line endings" {
    const source =
        "@push card text=Early\r\n" ++
        "@slide fontsize=37\r\n" ++
        "@push card text=Late\r\n";
    const insertion = std.mem.indexOf(u8, source, "@push card text=Late").?;
    const projected = try buildSource(std.testing.allocator, source, .{
        .kind = .element,
        .name = "card",
        .insertion_offset = insertion,
        .instance_id = "preview",
    });
    defer std.testing.allocator.free(projected);
    try std.testing.expectEqualSlices(u8, source[0..insertion], projected[0..insertion]);
    try std.testing.expect(std.mem.endsWith(u8, projected, "@pop card id=preview\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, projected, "text=Late") == null);
}

test "unused preview IDs avoid direct and qualified collisions" {
    var items = [_]slides.SlideItem{ .{}, .{} };
    items[0].id = "__studio_preview_0";
    items[1].id = "__studio_preview_1.title";
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("__studio_preview_2", unusedInstanceId(&items, &buffer).?);
}

test "ITEM GROUP and SLIDE definitions project through parser-clean temporary source" {
    const parser = @import("parser.zig");

    const element_source =
        "@push card x=40 y=50 w=300 h=80 text=Early\n" ++
        "@slide fontsize=37\n" ++
        "@push card x=900 text=Late\n";
    const element_insertion = std.mem.indexOf(u8, element_source, "@push card x=900").?;
    const element_temporary = try buildSource(std.testing.allocator, element_source, .{
        .kind = .element,
        .name = "card",
        .insertion_offset = element_insertion,
        .instance_id = "preview",
    });
    defer std.testing.allocator.free(element_temporary);
    try std.testing.expectEqualSlices(
        u8,
        element_source[0..element_insertion],
        element_temporary[0..element_insertion],
    );
    var element_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer element_arena.deinit();
    const element_deck = try slides.SlideShow.new(element_arena.allocator());
    const element_context = try parser.constructSlidesFromBuf(
        element_temporary,
        element_deck,
        element_arena.allocator(),
    );
    defer element_context.deinit();
    try std.testing.expectEqual(@as(usize, 0), element_context.parser_errors.items.len);
    const element_preview = try projectSlide(
        element_arena.allocator(),
        element_deck.slides.items[element_deck.slides.items.len - 1],
        .element,
        "preview",
    );
    try std.testing.expectEqual(@as(usize, 1), element_preview.items.?.items.len);
    try std.testing.expectEqualStrings("Early", element_preview.items.?.items[0].text.?);
    try std.testing.expectEqual(@as(?i32, 37), element_preview.items.?.items[0].fontSize);
    try std.testing.expectEqual(slides.SourceScope.direct, element_preview.items.?.items[0].source.scope);
    try std.testing.expectEqual(
        std.mem.indexOf(u8, element_source, "@push card x=40").?,
        element_preview.items.?.items[0].source.line_offset,
    );

    const group_source =
        "@pushgroup feature\n" ++
        "@box id=title x=100 y=120 text=Title\n" ++
        "@box id=body x=100 y=260 text=Body\n" ++
        "@endgroup\n" ++
        "@slide\n";
    const group_temporary = try buildSource(std.testing.allocator, group_source, .{
        .kind = .group,
        .name = "feature",
        .insertion_offset = group_source.len,
        .instance_id = "preview",
    });
    defer std.testing.allocator.free(group_temporary);
    var group_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer group_arena.deinit();
    const group_deck = try slides.SlideShow.new(group_arena.allocator());
    const group_context = try parser.constructSlidesFromBuf(group_temporary, group_deck, group_arena.allocator());
    defer group_context.deinit();
    try std.testing.expectEqual(@as(usize, 0), group_context.parser_errors.items.len);
    const group_preview = try projectSlide(
        group_arena.allocator(),
        group_deck.slides.items[group_deck.slides.items.len - 1],
        .group,
        "preview",
    );
    try std.testing.expectEqual(@as(usize, 2), group_preview.items.?.items.len);
    try std.testing.expectEqualStrings("preview.title", group_preview.items.?.items[0].id.?);
    try std.testing.expectEqualStrings("preview.body", group_preview.items.?.items[1].id.?);
    try std.testing.expectEqual(
        std.mem.indexOf(u8, group_source, "@box id=title").?,
        group_preview.items.?.items[0].source.line_offset,
    );
    try std.testing.expectEqual(
        std.mem.indexOf(u8, group_source, "@box id=body").?,
        group_preview.items.?.items[1].source.line_offset,
    );

    const slide_source =
        "@box id=title x=100 y=80 text=Template\n" ++
        "@pushslide chapter\n" ++
        "@slide\n";
    const slide_temporary = try buildSource(std.testing.allocator, slide_source, .{
        .kind = .slide,
        .name = "chapter",
        .insertion_offset = slide_source.len,
    });
    defer std.testing.allocator.free(slide_temporary);
    var slide_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer slide_arena.deinit();
    const slide_deck = try slides.SlideShow.new(slide_arena.allocator());
    const slide_context = try parser.constructSlidesFromBuf(slide_temporary, slide_deck, slide_arena.allocator());
    defer slide_context.deinit();
    try std.testing.expectEqual(@as(usize, 0), slide_context.parser_errors.items.len);
    const slide_preview = try projectSlide(
        slide_arena.allocator(),
        slide_deck.slides.items[slide_deck.slides.items.len - 1],
        .slide,
        "",
    );
    try std.testing.expectEqual(@as(usize, 1), slide_preview.items.?.items.len);
    try std.testing.expectEqualStrings("Template", slide_preview.items.?.items[0].text.?);
    try std.testing.expectEqual(slides.SourceScope.slide_template, slide_preview.items.?.items[0].source.scope);
}

test "projected ITEM property target patches the shared definition and fans out" {
    const parser = @import("parser.zig");
    const source =
        "@push card x=40 y=50 w=300 h=80 text=Original\n" ++
        "@slide\n" ++
        "@pop card id=first\n" ++
        "@slide\n" ++
        "@pop card id=second\n";
    const temporary = try buildSource(std.testing.allocator, source, .{
        .kind = .element,
        .name = "card",
        .insertion_offset = source.len,
        .instance_id = "preview",
    });
    defer std.testing.allocator.free(temporary);
    var preview_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer preview_arena.deinit();
    const preview_deck = try slides.SlideShow.new(preview_arena.allocator());
    const preview_context = try parser.constructSlidesFromBuf(temporary, preview_deck, preview_arena.allocator());
    defer preview_context.deinit();
    try std.testing.expectEqual(@as(usize, 0), preview_context.parser_errors.items.len);
    const projected = try projectSlide(
        preview_arena.allocator(),
        preview_deck.slides.items[preview_deck.slides.items.len - 1],
        .element,
        "preview",
    );
    const target = projected.items.?.items[0].source;
    try std.testing.expectEqual(std.mem.indexOf(u8, source, "@push card").?, target.line_offset);

    const patch = try source_editor.patchItemText(
        std.testing.allocator,
        source,
        target.line_offset,
        "Updated",
    );
    defer patch.deinit(std.testing.allocator);
    var result_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer result_arena.deinit();
    const result_deck = try slides.SlideShow.new(result_arena.allocator());
    const result_context = try parser.constructSlidesFromBuf(patch.source, result_deck, result_arena.allocator());
    defer result_context.deinit();
    try std.testing.expectEqual(@as(usize, 0), result_context.parser_errors.items.len);
    try std.testing.expectEqual(@as(usize, 2), result_deck.slides.items.len);
    try std.testing.expectEqualStrings("Updated", result_deck.slides.items[0].items.?.items[0].text.?);
    try std.testing.expectEqualStrings("Updated", result_deck.slides.items[1].items.?.items[0].text.?);
}
