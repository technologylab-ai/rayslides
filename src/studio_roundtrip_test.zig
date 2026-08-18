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
