//! Headless integration coverage for Studio's source-authoring operations.
//!
//! These tests deliberately exercise the same source transformations used by
//! `main.zig`, then feed the result back through the real parser. This keeps
//! the authoring loop testable without creating a raylib window or loading
//! GPU-backed fonts.

const std = @import("std");
const parser = @import("parser.zig");
const slides = @import("slides.zig");
const source_editor = @import("source_editor.zig");
const studio_api = @import("studio.zig");

fn adoptPatch(allocator: std.mem.Allocator, source: *[]u8, patch: source_editor.PatchResult) void {
    allocator.free(source.*);
    source.* = patch.source;
}

test "Studio-created text bullets image and shape survive a source round trip" {
    const allocator = std.testing.allocator;
    var source = try allocator.dupe(u8, "@slide\n");
    defer allocator.free(source);

    adoptPatch(allocator, &source, try source_editor.insertSnippet(
        allocator,
        source,
        0,
        "@box id=studio_text x=100 y=120 w=500 h=160 text=Hello from Studio",
    ));
    adoptPatch(allocator, &source, try source_editor.insertSnippet(
        allocator,
        source,
        0,
        "@box id=studio_bullets x=140 y=320 w=620 h=260\n- First point\n- Second point",
    ));
    adoptPatch(allocator, &source, try source_editor.insertDirective(
        allocator,
        source,
        0,
        "@box id=studio_image img=assets/example.png x=900 y=120 w=640 h=360",
    ));
    adoptPatch(allocator, &source, try source_editor.insertDirective(
        allocator,
        source,
        0,
        "@box id=studio_shape x=900 y=560 w=420 h=180 color=#668bffff",
    ));

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const slideshow = try slides.SlideShow.new(arena.allocator());
    const context = try parser.constructSlidesFromBuf(source, slideshow, arena.allocator());
    defer context.deinit();

    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    try std.testing.expectEqual(@as(usize, 1), slideshow.slides.items.len);
    const items = slideshow.slides.items[0].items.?.items;
    try std.testing.expectEqual(@as(usize, 4), items.len);

    try std.testing.expectEqual(slides.SlideItemKind.textbox, items[0].kind);
    try std.testing.expectEqualStrings("studio_text", items[0].id.?);
    try std.testing.expectEqualStrings("Hello from Studio", items[0].text.?);
    try std.testing.expectEqual(@as(f32, 100), items[0].position.x);
    try std.testing.expectEqual(@as(f32, 160), items[0].size.y);

    try std.testing.expectEqual(slides.SlideItemKind.textbox, items[1].kind);
    try std.testing.expectEqualStrings("- First point\n- Second point", items[1].text.?);

    try std.testing.expectEqual(slides.SlideItemKind.img, items[2].kind);
    try std.testing.expectEqualStrings("assets/example.png", items[2].img_path.?);
    try std.testing.expectEqual(@as(f32, 640), items[2].size.x);

    // A colored @box remains a textbox-kind item with no text. The renderer
    // paints its color as the visible shape; only @bg becomes background-kind.
    try std.testing.expectEqual(slides.SlideItemKind.textbox, items[3].kind);
    try std.testing.expect(items[3].text == null);
    try std.testing.expectEqual(@as(u8, 0x66), items[3].color.?.r);
    try std.testing.expectEqual(@as(u8, 0x8b), items[3].color.?.g);
    try std.testing.expectEqual(@as(u8, 0xff), items[3].color.?.b);
    try std.testing.expectEqual(@as(u8, 0xff), items[3].color.?.a);
}

test "Studio new slide insertion stays after the selected slide and its morph states" {
    const allocator = std.testing.allocator;
    const original =
        "@slide\n" ++
        "@box id=first x=10 y=20 w=100 h=80 text=First\n" ++
        "@state(morph)\n" ++
        "@set first x=200\n" ++
        "@slide\n" ++
        "@box id=last x=30 y=40 w=100 h=80 text=Last\n";

    const insertion_offset = try source_editor.slideEndOffset(original, 0);
    const patch = try source_editor.insertDirectiveAt(allocator, original, insertion_offset, "@slide");
    defer patch.deinit(allocator);

    try std.testing.expectEqualStrings(
        "@slide\n" ++
            "@box id=first x=10 y=20 w=100 h=80 text=First\n" ++
            "@state(morph)\n" ++
            "@set first x=200\n" ++
            "@slide\n" ++
            "@slide\n" ++
            "@box id=last x=30 y=40 w=100 h=80 text=Last\n",
        patch.source,
    );

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const slideshow = try slides.SlideShow.new(arena.allocator());
    const context = try parser.constructSlidesFromBuf(patch.source, slideshow, arena.allocator());
    defer context.deinit();

    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    try std.testing.expectEqual(@as(usize, 3), slideshow.slides.items.len);
    try std.testing.expectEqual(@as(usize, 1), slideshow.slides.items[0].morph_states.items.len);
    try std.testing.expectEqual(@as(usize, 0), slideshow.slides.items[1].items.?.items.len);
    try std.testing.expectEqualStrings("last", slideshow.slides.items[2].items.?.items[0].id.?);
}

test "editing inherited morph geometry inserts a state-local set directive" {
    const allocator = std.testing.allocator;
    const original =
        "@slide\n" ++
        "@box id=hero x=10 y=20 w=100 h=80 text=Hero\n" ++
        "@state(morph)\n" ++
        "@set hero x=120 y=140\n" ++
        "@state(morph)\n" ++
        "@box id=caption x=40 y=50 w=300 h=80 text=Second state\n";

    const second_state_offset = std.mem.lastIndexOf(u8, original, "@state(morph)").?;
    const insertion_offset = try source_editor.morphStateEndOffset(original, second_state_offset);
    const patch = try source_editor.insertDirectiveAt(
        allocator,
        original,
        insertion_offset,
        "@set hero x=333 y=444 w=555 h=222",
    );
    defer patch.deinit(allocator);

    try std.testing.expect(std.mem.endsWith(
        u8,
        patch.source,
        "@box id=caption x=40 y=50 w=300 h=80 text=Second state\n" ++
            "@set hero x=333 y=444 w=555 h=222\n",
    ));

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const slideshow = try slides.SlideShow.new(arena.allocator());
    const context = try parser.constructSlidesFromBuf(patch.source, slideshow, arena.allocator());
    defer context.deinit();

    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    const slide = slideshow.slides.items[0];
    const base = slide.items.?.items[0];
    const state_one = slide.morph_states.items[0].items.items[0];
    const state_two = slide.morph_states.items[1].items.items[0];
    try std.testing.expectEqual(@as(f32, 10), base.position.x);
    try std.testing.expectEqual(@as(f32, 120), state_one.position.x);
    try std.testing.expectEqual(@as(f32, 333), state_two.position.x);
    try std.testing.expectEqual(@as(f32, 444), state_two.position.y);
    try std.testing.expectEqual(@as(f32, 555), state_two.size.x);
    try std.testing.expectEqual(@as(f32, 222), state_two.size.y);
    try std.testing.expectEqual(@as(?usize, 1), state_two.state_source_state);
    try std.testing.expectEqual(
        std.mem.indexOf(u8, patch.source, "@set hero x=333").?,
        state_two.effectiveSource().line_offset,
    );
}

test "morph color and multiline text edits round trip through one local override" {
    const allocator = std.testing.allocator;
    const original =
        "@slide\n" ++
        "@box id=hero x=10 y=20 w=500 h=160 color=#ffffffff text=Original\n" ++
        "@state(morph)\n";

    const state_offset = std.mem.indexOf(u8, original, "@state(morph)").?;
    const insertion_offset = try source_editor.morphStateEndOffset(original, state_offset);
    const color_patch = try source_editor.insertDirectiveAt(
        allocator,
        original,
        insertion_offset,
        "@set hero color=#f45c5cff",
    );
    defer color_patch.deinit(allocator);

    const set_offset = std.mem.indexOf(u8, color_patch.source, "@set hero").?;
    const text_patch = try source_editor.patchItemText(
        allocator,
        color_patch.source,
        set_offset,
        "Changed in Studio\nAcross two lines",
    );
    defer text_patch.deinit(allocator);

    try std.testing.expect(std.mem.endsWith(
        u8,
        text_patch.source,
        "@state(morph)\n" ++
            "@set hero color=#f45c5cff\n" ++
            "Changed in Studio\n" ++
            "Across two lines\n",
    ));

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const slideshow = try slides.SlideShow.new(arena.allocator());
    const context = try parser.constructSlidesFromBuf(text_patch.source, slideshow, arena.allocator());
    defer context.deinit();

    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    const slide = slideshow.slides.items[0];
    try std.testing.expectEqualStrings("Original", slide.items.?.items[0].text.?);
    const morphed = slide.morph_states.items[0].items.items[0];
    try std.testing.expectEqualStrings("Changed in Studio\nAcross two lines", morphed.text.?);
    try std.testing.expectEqual(@as(u8, 0xf4), morphed.color.?.r);
    try std.testing.expectEqual(@as(u8, 0x5c), morphed.color.?.g);
    try std.testing.expectEqual(@as(u8, 0x5c), morphed.color.?.b);
    try std.testing.expectEqual(@as(?usize, 0), morphed.state_source_state);
}

test "promoted Studio item remains reusable on another slide" {
    const allocator = std.testing.allocator;
    const original =
        "@slide\n" ++
        "@box id=badge x=80 y=90 w=320 h=100 color=#668bffff text=Reusable badge\n" ++
        "@slide\n" ++
        "@box id=existing x=10 y=20 w=100 h=80 text=Existing\n";

    const item_offset = std.mem.indexOf(u8, original, "@box id=badge").?;
    const promotion = try source_editor.promoteItemToReusable(
        allocator,
        original,
        item_offset,
        "studio_badge",
    );
    defer promotion.deinit(allocator);

    const second_slide_offset = std.mem.lastIndexOf(u8, promotion.source, "@slide").?;
    const reuse = try source_editor.insertDirective(
        allocator,
        promotion.source,
        second_slide_offset,
        "@pop studio_badge id=badge_copy x=900 y=700 w=480 h=120",
    );
    defer reuse.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, reuse.source, "@push studio_badge") != null);
    try std.testing.expect(std.mem.indexOf(u8, reuse.source, "@pop studio_badge id=badge") != null);
    try std.testing.expect(std.mem.indexOf(u8, reuse.source, "@pop studio_badge id=badge_copy") != null);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const slideshow = try slides.SlideShow.new(arena.allocator());
    const context = try parser.constructSlidesFromBuf(reuse.source, slideshow, arena.allocator());
    defer context.deinit();

    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    try std.testing.expectEqual(@as(usize, 2), slideshow.slides.items.len);
    const first_items = slideshow.slides.items[0].items.?.items;
    try std.testing.expectEqual(@as(usize, 1), first_items.len);
    try std.testing.expectEqualStrings("badge", first_items[0].id.?);
    try std.testing.expectEqualStrings("Reusable badge", first_items[0].text.?);

    const second_items = slideshow.slides.items[1].items.?.items;
    try std.testing.expectEqual(@as(usize, 2), second_items.len);
    try std.testing.expectEqualStrings("badge_copy", second_items[1].id.?);
    try std.testing.expectEqualStrings("Reusable badge", second_items[1].text.?);
    try std.testing.expectEqual(@as(f32, 900), second_items[1].position.x);
    try std.testing.expectEqual(@as(f32, 700), second_items[1].position.y);
    try std.testing.expectEqual(@as(f32, 480), second_items[1].size.x);
    try std.testing.expectEqual(@as(f32, 120), second_items[1].size.y);
}

test "Studio template-instance overrides stay local and feed later morph states" {
    const allocator = std.testing.allocator;
    var source = try allocator.dupe(
        u8,
        "@box id=hero x=10 y=20 w=300 h=120 color=#ffffffff text=Shared hero\n" ++
            "@pushslide layout\n" ++
            "@popslide layout\n" ++
            "@state(morph)\n" ++
            "@set hero y=700\n" ++
            "@popslide layout\n",
    );
    defer allocator.free(source);

    const first_instance = std.mem.indexOf(u8, source, "@popslide layout").?;
    adoptPatch(allocator, &source, try source_editor.insertSlideTemplateOverride(
        allocator,
        source,
        first_instance,
        "@set hero x=320",
    ));

    const local_set = std.mem.indexOf(u8, source, "@set hero x=320").?;
    adoptPatch(allocator, &source, try source_editor.patchSlideTemplateOverrideGeometry(
        allocator,
        source,
        first_instance,
        local_set,
        "hero",
        .{ .x = 360, .y = 240, .w = 520, .h = 180 },
    ));
    adoptPatch(allocator, &source, try source_editor.patchSlideTemplateOverrideAttributes(
        allocator,
        source,
        first_instance,
        local_set,
        "hero",
        &.{.{ .key = "color", .value = "#50d7ffff" }},
    ));
    adoptPatch(allocator, &source, try source_editor.patchSlideTemplateOverrideText(
        allocator,
        source,
        first_instance,
        local_set,
        "hero",
        "Only on this slide\nStill the same template",
    ));
    adoptPatch(allocator, &source, try source_editor.insertSlideTemplateOverride(
        allocator,
        source,
        first_instance,
        "@hide hero",
    ));

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const slideshow = try slides.SlideShow.new(arena.allocator());
    const context = try parser.constructSlidesFromBuf(source, slideshow, arena.allocator());
    defer context.deinit();

    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    try std.testing.expectEqual(@as(usize, 2), slideshow.slides.items.len);

    const local_base = slideshow.slides.items[0].items.?.items[0];
    try std.testing.expectApproxEqAbs(@as(f32, 360), local_base.position.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 240), local_base.position.y, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 520), local_base.size.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 180), local_base.size.y, 0.0001);
    try std.testing.expectEqualStrings("Only on this slide\nStill the same template", local_base.text.?);
    try std.testing.expectEqual(@as(u8, 0x50), local_base.color.?.r);
    try std.testing.expect(!local_base.visible);
    try std.testing.expectEqual(slides.SourceScope.slide_template, local_base.source.scope);
    try std.testing.expectEqual(slides.SourceScope.slide_instance_override, local_base.instance_source.?.scope);

    const local_morph = slideshow.slides.items[0].morph_states.items[0].items.items[0];
    try std.testing.expectApproxEqAbs(@as(f32, 360), local_morph.position.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 700), local_morph.position.y, 0.0001);
    try std.testing.expect(!local_morph.visible);

    const shared_second = slideshow.slides.items[1].items.?.items[0];
    try std.testing.expectApproxEqAbs(@as(f32, 10), shared_second.position.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 20), shared_second.position.y, 0.0001);
    try std.testing.expectEqualStrings("Shared hero", shared_second.text.?);
    try std.testing.expect(shared_second.visible);
    try std.testing.expect(shared_second.instance_source == null);
}

test "Studio group geometry patches multiple direct items in one source result" {
    const allocator = std.testing.allocator;
    const original =
        "@slide\n" ++
        "@box id=left x=40 y=60 w=200 h=100 text=Left\n" ++
        "@box id=right x=320 y=60 w=200 h=100 text=Right\n";
    const left_offset = std.mem.indexOf(u8, original, "@box id=left").?;
    const right_offset = std.mem.indexOf(u8, original, "@box id=right").?;
    const edits = [_]source_editor.GeometrySourceEdit{
        .{ .patch = .{
            .directive_offset = left_offset,
            .geometry = .{ .x = 140, .y = 260 },
        } },
        .{ .patch = .{
            .directive_offset = right_offset,
            .geometry = .{ .x = 420, .y = 260 },
        } },
    };

    const patch = try source_editor.applyGeometryEdits(allocator, original, &edits);
    defer patch.deinit(allocator);

    try std.testing.expectEqualStrings(
        "@slide\n" ++
            "@box id=left x=140 y=260 w=200 h=100 text=Left\n" ++
            "@box id=right x=420 y=260 w=200 h=100 text=Right\n",
        patch.source,
    );
    try std.testing.expectEqual(
        @as(isize, @intCast(patch.source.len)) - @as(isize, @intCast(original.len)),
        patch.byte_delta,
    );

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const slideshow = try slides.SlideShow.new(arena.allocator());
    const context = try parser.constructSlidesFromBuf(patch.source, slideshow, arena.allocator());
    defer context.deinit();

    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    const items = slideshow.slides.items[0].items.?.items;
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("left", items[0].id.?);
    try std.testing.expectApproxEqAbs(@as(f32, 140), items[0].position.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 260), items[0].position.y, 0.0001);
    try std.testing.expectEqualStrings("right", items[1].id.?);
    try std.testing.expectApproxEqAbs(@as(f32, 420), items[1].position.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 260), items[1].position.y, 0.0001);
}

test "Studio group morph geometry inserts same-anchor sets in one source result" {
    const allocator = std.testing.allocator;
    const original =
        "@slide\n" ++
        "@box id=title x=80 y=100 w=600 h=120 text=Title\n" ++
        "@box id=art x=900 y=180 w=500 h=400 color=#668bffff\n" ++
        "@state(morph)\n";
    const state_offset = std.mem.indexOf(u8, original, "@state(morph)").?;
    const insertion_offset = try source_editor.morphStateEndOffset(original, state_offset);
    const edits = [_]source_editor.GeometrySourceEdit{
        .{ .insert = .{
            .insertion_offset = insertion_offset,
            .snippet = "@set title x=180 y=240",
        } },
        .{ .insert = .{
            .insertion_offset = insertion_offset,
            .snippet = "@set art x=1000 y=320",
        } },
    };

    const patch = try source_editor.applyGeometryEdits(allocator, original, &edits);
    defer patch.deinit(allocator);

    try std.testing.expect(std.mem.endsWith(
        u8,
        patch.source,
        "@state(morph)\n" ++
            "@set title x=180 y=240\n" ++
            "@set art x=1000 y=320\n",
    ));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, patch.source, "@set title"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, patch.source, "@set art"));

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const slideshow = try slides.SlideShow.new(arena.allocator());
    const context = try parser.constructSlidesFromBuf(patch.source, slideshow, arena.allocator());
    defer context.deinit();

    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    const slide = slideshow.slides.items[0];
    try std.testing.expectEqual(@as(usize, 1), slide.morph_states.items.len);
    const morphed = slide.morph_states.items[0].items.items;
    try std.testing.expectEqual(@as(usize, 2), morphed.len);
    try std.testing.expectEqualStrings("title", morphed[0].id.?);
    try std.testing.expectApproxEqAbs(@as(f32, 180), morphed[0].position.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 240), morphed[0].position.y, 0.0001);
    try std.testing.expectEqualStrings("art", morphed[1].id.?);
    try std.testing.expectApproxEqAbs(@as(f32, 1000), morphed[1].position.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 320), morphed[1].position.y, 0.0001);
}

test "Studio group geometry mixes direct patch and template-local insertion atomically" {
    const allocator = std.testing.allocator;
    const original =
        "@box id=hero x=10 y=20 w=300 h=120 text=Shared hero\n" ++
        "@pushslide layout\n" ++
        "@popslide layout\n" ++
        "@box id=local x=40 y=300 w=240 h=100 text=Local item\n" ++
        "@popslide layout\n";
    const first_instance = std.mem.indexOf(u8, original, "@popslide layout").?;
    const local_offset = std.mem.indexOf(u8, original, "@box id=local").?;
    const local_override = "@set hero x=360 y=220";
    const override_insertion = try source_editor.slideTemplateOverrideInsertionOffset(
        original,
        first_instance,
        local_override,
    );
    const edits = [_]source_editor.GeometrySourceEdit{
        .{ .patch = .{
            .directive_offset = local_offset,
            .geometry = .{ .x = 440, .y = 500 },
        } },
        .{ .insert = .{
            .insertion_offset = override_insertion,
            .snippet = local_override,
        } },
    };

    const patch = try source_editor.applyGeometryEdits(allocator, original, &edits);
    defer patch.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, patch.source, local_override));
    try std.testing.expect(std.mem.indexOf(
        u8,
        patch.source,
        "@box id=local x=440 y=500 w=240 h=100 text=Local item\n" ++
            "@set hero x=360 y=220\n" ++
            "@popslide layout\n",
    ) != null);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const slideshow = try slides.SlideShow.new(arena.allocator());
    const context = try parser.constructSlidesFromBuf(patch.source, slideshow, arena.allocator());
    defer context.deinit();

    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    try std.testing.expectEqual(@as(usize, 2), slideshow.slides.items.len);
    const first_items = slideshow.slides.items[0].items.?.items;
    try std.testing.expectEqual(@as(usize, 2), first_items.len);
    try std.testing.expectEqualStrings("hero", first_items[0].id.?);
    try std.testing.expectApproxEqAbs(@as(f32, 360), first_items[0].position.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 220), first_items[0].position.y, 0.0001);
    try std.testing.expectEqualStrings("local", first_items[1].id.?);
    try std.testing.expectApproxEqAbs(@as(f32, 440), first_items[1].position.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 500), first_items[1].position.y, 0.0001);
    try std.testing.expectEqual(slides.SourceScope.slide_instance_override, first_items[0].instance_source.?.scope);

    const second_items = slideshow.slides.items[1].items.?.items;
    try std.testing.expectEqual(@as(usize, 1), second_items.len);
    try std.testing.expectEqualStrings("hero", second_items[0].id.?);
    try std.testing.expectApproxEqAbs(@as(f32, 10), second_items[0].position.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 20), second_items[0].position.y, 0.0001);
    try std.testing.expect(second_items[0].instance_source == null);
}

test "Studio local template background stays instance owned through morph" {
    const allocator = std.testing.allocator;
    const original =
        "@box id=hero x=10 y=20 w=300 h=120 bg=#102030ff text=Shared hero\n" ++
        "@box id=keep x=40 y=200 w=200 h=80 text=Keep\n" ++
        "@pushslide layout\n" ++
        "@popslide layout\n" ++
        "@state(morph)\n" ++
        "@set keep x=140\n" ++
        "@popslide layout\n";
    const first_instance = std.mem.indexOf(u8, original, "@popslide layout").?;

    // One Studio action authors one instance-local background mutation.
    const patch = try source_editor.insertSlideTemplateBackgroundOverride(
        allocator,
        original,
        first_instance,
        "hero",
        "#a0b0c0d0",
    );
    defer patch.deinit(allocator);
    const local_override = std.mem.indexOf(u8, patch.source, "@set hero bg=#a0b0c0d0").?;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const slideshow = try slides.SlideShow.new(arena.allocator());
    const context = try parser.constructSlidesFromBuf(patch.source, slideshow, arena.allocator());
    defer context.deinit();

    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    try std.testing.expectEqual(@as(usize, 2), slideshow.slides.items.len);

    const customized = slideshow.slides.items[0];
    const local_base = customized.items.?.items[0];
    try std.testing.expectEqual(slides.SlideItemKind.textbox, local_base.kind);
    try std.testing.expectEqual(@as(u8, 0xa0), local_base.background_color.?.r);
    try std.testing.expectEqual(@as(u8, 0xd0), local_base.background_color.?.a);
    try std.testing.expectEqual(slides.SourceScope.slide_template, local_base.source.scope);
    try std.testing.expectEqual(slides.SourceScope.slide_instance_override, local_base.instance_source.?.scope);
    try std.testing.expectEqual(local_override, local_base.instance_source.?.line_offset);
    try std.testing.expectEqual(@as(u8, 0x10), local_base.sharedTemplateValues().?.background_color.?.r);

    // A morph that changes another item inherits both the local fill and its
    // instance-local provenance instead of reassigning it to the state.
    const local_morph = customized.morph_states.items[0].items.items[0];
    try std.testing.expectEqual(@as(u8, 0xa0), local_morph.background_color.?.r);
    try std.testing.expectEqual(local_override, local_morph.effectiveSource().line_offset);
    try std.testing.expectEqual(slides.SourceScope.slide_instance_override, local_morph.effectiveSource().scope);
    try std.testing.expect(local_morph.state_source == null);

    const ordinary = slideshow.slides.items[1].items.?.items[0];
    try std.testing.expectEqual(@as(u8, 0x10), ordinary.background_color.?.r);
    try std.testing.expectEqual(@as(u8, 0xff), ordinary.background_color.?.a);
    try std.testing.expect(ordinary.instance_source == null);
    try std.testing.expectEqual(slides.SourceScope.slide_template, ordinary.effectiveSource().scope);
}

test "Studio shared edits update ordinary instances without unmasking customized values" {
    const allocator = std.testing.allocator;
    const original =
        "@box id=hero x=10 y=20 w=300 h=120 bg=#102030ff text=Original-shared\n" ++
        "@pushslide layout\n" ++
        "@popslide layout\n" ++
        "@set hero x=110 bg=#01020304 text=Local-only\n" ++
        "@popslide layout\n";
    const shared_offset = std.mem.indexOf(u8, original, "@box id=hero").?;
    const shared_changes = [_]source_editor.LiteralAttributePatch{
        .{ .key = "x", .value = "40" },
        .{ .key = "y", .value = "50" },
        .{ .key = "w", .value = "420" },
        .{ .key = "h", .value = "180" },
        .{ .key = "bg", .value = "#aabbccdd" },
        .{ .key = "text", .value = "Reworked-shared" },
    };

    // Geometry, semantic text, and fill are one shared-definition action and
    // therefore produce one undoable source result.
    const patch = try source_editor.patchLiteralAttributes(
        allocator,
        original,
        shared_offset,
        &shared_changes,
    );
    defer patch.deinit(allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const slideshow = try slides.SlideShow.new(arena.allocator());
    const context = try parser.constructSlidesFromBuf(patch.source, slideshow, arena.allocator());
    defer context.deinit();

    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    try std.testing.expectEqual(@as(usize, 2), slideshow.slides.items.len);

    const customized = slideshow.slides.items[0].items.?.items[0];
    try std.testing.expectApproxEqAbs(@as(f32, 110), customized.position.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 50), customized.position.y, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 420), customized.size.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 180), customized.size.y, 0.0001);
    try std.testing.expectEqualStrings("Local-only", customized.text.?);
    try std.testing.expectEqual(@as(u8, 0x01), customized.background_color.?.r);
    try std.testing.expectEqual(@as(u8, 0x04), customized.background_color.?.a);
    try std.testing.expectEqual(slides.SourceScope.slide_instance_override, customized.instance_source.?.scope);

    // Its immutable shared layer still refreshes, which is what allows later
    // shared edits to remain delta-based even from a customized instance.
    const shared = customized.sharedTemplateValues().?;
    try std.testing.expectApproxEqAbs(@as(f32, 40), shared.position.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 50), shared.position.y, 0.0001);
    try std.testing.expectEqualStrings("Reworked-shared", shared.text.?);
    try std.testing.expectEqual(@as(u8, 0xaa), shared.background_color.?.r);
    try std.testing.expectEqual(@as(u8, 0xdd), shared.background_color.?.a);

    const ordinary = slideshow.slides.items[1].items.?.items[0];
    try std.testing.expectApproxEqAbs(@as(f32, 40), ordinary.position.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 50), ordinary.position.y, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 420), ordinary.size.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 180), ordinary.size.y, 0.0001);
    try std.testing.expectEqualStrings("Reworked-shared", ordinary.text.?);
    try std.testing.expectEqual(@as(u8, 0xaa), ordinary.background_color.?.r);
    try std.testing.expectEqual(@as(u8, 0xdd), ordinary.background_color.?.a);
    try std.testing.expect(ordinary.instance_source == null);
}

test "Studio shared deletion removes dependent overrides and preserves unrelated content" {
    const allocator = std.testing.allocator;
    const original =
        "@box id=hero x=10 y=20 w=300 h=120 text=Shared hero\n" ++
        "Hero body\n" ++
        "# shared note survives\n" ++
        "@box id=keep x=20 y=30 w=200 h=80 text=Keep\n" ++
        "@pushslide layout\n" ++
        "@popslide layout\n" ++
        "@set hero bg=#10203040\n" ++
        "Local hero body\n" ++
        "# local note survives\n" ++
        "@set keep x=25\n" ++
        "@state(morph)\n" ++
        "@set hero x=400\n" ++
        "Morph hero body\n" ++
        "@set keep y=35\n" ++
        "@popslide layout\n" ++
        "@hide hero\n" ++
        "@state(morph)\n" ++
        "@show hero\n" ++
        "@set keep x=55\n" ++
        "@slide\n" ++
        "@box id=outsider x=700 y=80 w=240 h=100 text=Unrelated\n";
    const representative = std.mem.indexOf(u8, original, "@popslide layout").?;
    const shared_hero = std.mem.indexOf(u8, original, "@box id=hero").?;

    // Shared deletion is one source transaction spanning the definition and
    // every base/morph dependency of all instances bound to it.
    const patch = try source_editor.deleteSharedSlideTemplateItem(
        allocator,
        original,
        representative,
        shared_hero,
        "hero",
    );
    defer patch.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, patch.source, "@box id=hero"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, patch.source, "@set hero"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, patch.source, "@hide hero"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, patch.source, "@show hero"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, patch.source, "@popslide layout"));
    try std.testing.expect(std.mem.indexOf(u8, patch.source, "# shared note survives") != null);
    try std.testing.expect(std.mem.indexOf(u8, patch.source, "# local note survives") != null);
    try std.testing.expect(std.mem.indexOf(u8, patch.source, "@set keep x=25") != null);
    try std.testing.expect(std.mem.indexOf(u8, patch.source, "@set keep y=35") != null);
    try std.testing.expect(std.mem.indexOf(u8, patch.source, "@set keep x=55") != null);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const slideshow = try slides.SlideShow.new(arena.allocator());
    const context = try parser.constructSlidesFromBuf(patch.source, slideshow, arena.allocator());
    defer context.deinit();

    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    try std.testing.expectEqual(@as(usize, 3), slideshow.slides.items.len);
    const shared_template = context.push_slides.get("layout").?;
    try std.testing.expectEqual(@as(usize, 1), shared_template.items.?.items.len);
    try std.testing.expectEqualStrings("keep", shared_template.items.?.items[0].id.?);

    const first = slideshow.slides.items[0];
    try std.testing.expectEqual(@as(usize, 1), first.items.?.items.len);
    try std.testing.expectEqualStrings("keep", first.items.?.items[0].id.?);
    try std.testing.expectApproxEqAbs(@as(f32, 25), first.items.?.items[0].position.x, 0.0001);
    try std.testing.expectEqual(@as(usize, 1), first.morph_states.items.len);
    try std.testing.expectEqual(@as(usize, 1), first.morph_states.items[0].items.items.len);
    try std.testing.expectApproxEqAbs(@as(f32, 35), first.morph_states.items[0].items.items[0].position.y, 0.0001);

    const second = slideshow.slides.items[1];
    try std.testing.expectEqual(@as(usize, 1), second.items.?.items.len);
    try std.testing.expectEqualStrings("keep", second.items.?.items[0].id.?);
    try std.testing.expectEqual(@as(usize, 1), second.morph_states.items.len);
    try std.testing.expectEqual(@as(usize, 1), second.morph_states.items[0].items.items.len);
    try std.testing.expectApproxEqAbs(@as(f32, 55), second.morph_states.items[0].items.items[0].position.x, 0.0001);

    const unrelated = slideshow.slides.items[2].items.?.items;
    try std.testing.expectEqual(@as(usize, 1), unrelated.len);
    try std.testing.expectEqualStrings("outsider", unrelated[0].id.?);
    try std.testing.expectEqualStrings("Unrelated", unrelated[0].text.?);
}

test "Studio lock round trip retains a read-only copy selection" {
    const allocator = std.testing.allocator;
    const source = "@slide\n@box id=hero x=100 y=120 w=320 h=140 text=Hero\n";
    const directive_offset = std.mem.indexOf(u8, source, "@box").?;
    const lock_patch = [_]source_editor.LiteralAttributePatch{.{ .key = "locked", .value = "true" }};
    const edits = [_]source_editor.LiteralSourceEdit{.{ .patch = .{
        .directive_offset = directive_offset,
        .patches = &lock_patch,
    } }};
    const patch = try source_editor.applyLiteralEdits(allocator, source, &edits);
    defer patch.deinit(allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const slideshow = try slides.SlideShow.new(arena.allocator());
    const context = try parser.constructSlidesFromBuf(patch.source, slideshow, arena.allocator());
    defer context.deinit();
    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);

    const items = slideshow.slides.items[0].items.?.items;
    try std.testing.expect(items[0].locked);
    var studio: studio_api.Studio = .{ .enabled = true };
    studio.selectItemsByIds(items, &.{"hero"});
    try std.testing.expectEqual(@as(?usize, items[0].identity), studio.selected_identity);

    const viewport: studio_api.Viewport = .{
        .slide_top_left = .zero(),
        .slide_size = studio_api.default_logical_size,
    };
    _ = studio.update(items, &.{}, viewport, .{ .copy_pressed = true });
    switch (studio.takeSemanticCommand().?) {
        .copy_items => |copy| try std.testing.expectEqual(items[0].identity, copy.targets[0].item_identity),
        else => return error.UnexpectedSemanticCommand,
    }
}

test "Studio batch duplicate keeps direct and component items in one source transaction" {
    const allocator = std.testing.allocator;
    const source =
        "@push card x=30 y=40 w=220 h=90 text=Reusable card\n" ++
        "@slide\n" ++
        "@box id=title x=100 y=80 w=500 h=100 text=Title\n" ++
        "@pop card id=card_one x=200 y=260\n";
    const scene: source_editor.ItemSceneAnchor = .{
        .base_slide = std.mem.indexOf(u8, source, "@slide").?,
    };
    const targets = [_]source_editor.DuplicateItemTarget{
        .{
            .directive_offset = std.mem.indexOf(u8, source, "@box id=title").?,
            .new_id = "title_copy",
            .placement = .{ .x = 120, .y = 100 },
        },
        .{
            .directive_offset = std.mem.indexOf(u8, source, "@pop card").?,
            .new_id = "card_copy",
            .placement = .{ .x = 220, .y = 280 },
        },
    };

    const patch = try source_editor.duplicateItems(allocator, source, scene, scene, &targets);
    defer patch.deinit(allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const slideshow = try slides.SlideShow.new(arena.allocator());
    const context = try parser.constructSlidesFromBuf(patch.source, slideshow, arena.allocator());
    defer context.deinit();
    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);

    const items = slideshow.slides.items[0].items.?.items;
    try std.testing.expectEqual(@as(usize, 4), items.len);
    try std.testing.expectEqualStrings("title_copy", items[2].id.?);
    try std.testing.expectEqualStrings("card_copy", items[3].id.?);
    try std.testing.expectEqualStrings("Reusable card", items[3].text.?);
    try std.testing.expectEqual(slides.SourceScope.component_instance, items[3].source.scope);
    try std.testing.expectApproxEqAbs(@as(f32, 220), items[3].position.x, 0.0001);
}

test "Studio component clipboard proves its reusable definition at paste time" {
    const allocator = std.testing.allocator;
    const source =
        "@push card x=10 y=20 w=200 h=80 text=Original card\n" ++
        "@slide\n" ++
        "@pop card id=first\n" ++
        "@slide\n" ++
        "@box id=target text=Target\n";
    const first_slide = std.mem.indexOf(u8, source, "@slide").?;
    const second_slide = std.mem.lastIndexOf(u8, source, "@slide").?;
    const captured = try source_editor.captureItemForPaste(
        allocator,
        source,
        .{ .base_slide = first_slide },
        std.mem.indexOf(u8, source, "@pop card").?,
    );
    defer captured.deinit(allocator);
    try std.testing.expect(captured.component_definition_offset != null);

    const patch = try source_editor.pasteCapturedItem(allocator, source, .{
        .base_slide = second_slide,
    }, .{
        .snippet = captured.snippet,
        .component_definition_offset = captured.component_definition_offset,
        .new_id = "pasted_card",
        .placement = .{ .x = 500, .y = 300 },
    });
    defer patch.deinit(allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const slideshow = try slides.SlideShow.new(arena.allocator());
    const context = try parser.constructSlidesFromBuf(patch.source, slideshow, arena.allocator());
    defer context.deinit();
    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    const pasted = slideshow.slides.items[1].items.?.items[1];
    try std.testing.expectEqualStrings("pasted_card", pasted.id.?);
    try std.testing.expectEqualStrings("Original card", pasted.text.?);
    try std.testing.expectEqual(slides.SourceScope.component_instance, pasted.source.scope);

    // The exact definition offset is part of the clipboard proof. A stale or
    // forged proof is rejected rather than letting the @pop silently resolve
    // to whichever same-named component is in scope at the destination.
    try std.testing.expectError(error.UnsupportedClipboardItem, source_editor.pasteCapturedItem(
        allocator,
        source,
        .{ .base_slide = second_slide },
        .{
            .snippet = captured.snippet,
            .component_definition_offset = captured.component_definition_offset.? + 1,
            .new_id = "wrong_card",
            .placement = .{ .x = 1, .y = 2 },
        },
    ));
}

test "Studio batch delete mixes authored removal with a template-instance hide" {
    const allocator = std.testing.allocator;
    const source =
        "@box id=shared x=10 y=20 text=Shared\n" ++
        "@pushslide layout\n" ++
        "@popslide layout\n" ++
        "@box id=local x=30 y=40 text=Local\n" ++
        "@state(morph)\n" ++
        "@set local x=300\n" ++
        "@set shared y=200\n" ++
        "@popslide layout\n";
    const instance = std.mem.indexOf(u8, source, "@popslide layout").?;
    const targets = [_]source_editor.DeleteItemTarget{
        .{ .authored = .{
            .directive_offset = std.mem.indexOf(u8, source, "@box id=local").?,
            .item_id = "local",
        } },
        .{ .hide = .{ .item_id = "shared" } },
    };
    const patch = try source_editor.deleteItems(
        allocator,
        source,
        .{ .base_slide = instance },
        &targets,
    );
    defer patch.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, patch.source, "@box id=local") == null);
    try std.testing.expect(std.mem.indexOf(u8, patch.source, "@set local") == null);
    try std.testing.expect(std.mem.indexOf(u8, patch.source, "@hide shared\n@state(morph)") != null);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const slideshow = try slides.SlideShow.new(arena.allocator());
    const context = try parser.constructSlidesFromBuf(patch.source, slideshow, arena.allocator());
    defer context.deinit();
    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    try std.testing.expectEqual(@as(usize, 2), slideshow.slides.items.len);
    const first_base = slideshow.slides.items[0].items.?.items;
    try std.testing.expectEqual(@as(usize, 1), first_base.len);
    try std.testing.expectEqualStrings("shared", first_base[0].id.?);
    try std.testing.expect(!first_base[0].visible);
    try std.testing.expectEqual(@as(usize, 1), slideshow.slides.items[1].items.?.items.len);
    try std.testing.expectEqualStrings("shared", slideshow.slides.items[1].items.?.items[0].id.?);
}

test "Studio morph batch deletion removes a current-state birth and all later dependencies" {
    const allocator = std.testing.allocator;
    const source =
        "@slide\n" ++
        "@box id=base x=10 y=20 text=Base\n" ++
        "@state(morph)\n" ++
        "@box id=born x=30 y=40 text=Born\n" ++
        "@set born x=300\n" ++
        "@state(morph)\n" ++
        "@show born\n" ++
        "@set born y=400\n";
    const first_state = std.mem.indexOf(u8, source, "@state(morph)").?;
    const targets = [_]source_editor.DeleteItemTarget{
        .{ .authored = .{
            .directive_offset = std.mem.indexOf(u8, source, "@box id=born").?,
            .item_id = "born",
        } },
        .{ .hide = .{ .item_id = "base" } },
    };
    const patch = try source_editor.deleteItems(
        allocator,
        source,
        .{ .morph_state = first_state },
        &targets,
    );
    defer patch.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, patch.source, "@box id=born") == null);
    try std.testing.expect(std.mem.indexOf(u8, patch.source, "@set born") == null);
    try std.testing.expect(std.mem.indexOf(u8, patch.source, "@show born") == null);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const slideshow = try slides.SlideShow.new(arena.allocator());
    const context = try parser.constructSlidesFromBuf(patch.source, slideshow, arena.allocator());
    defer context.deinit();
    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    try std.testing.expectEqual(@as(usize, 2), slideshow.slides.items[0].morph_states.items.len);
    for (slideshow.slides.items[0].morph_states.items) |state| {
        try std.testing.expectEqual(@as(usize, 1), state.items.items.len);
        try std.testing.expectEqualStrings("base", state.items.items[0].id.?);
        try std.testing.expect(!state.items.items[0].visible);
    }
}
