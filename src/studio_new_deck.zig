//! Self-contained starter decks for Studio's no-file authoring flow.
//!
//! The starter sources live beside the code as ordinary `.sld` files and are
//! embedded into the executable. Choosing one replaces only the pristine
//! untitled placeholder and records the complete source as one undoable edit.

const std = @import("std");

pub const Preset = enum {
    studio,
    folio,
    ember,
    signal,
};

pub const all = [_]Preset{ .studio, .folio, .ember, .signal };

pub fn title(preset: Preset) [:0]const u8 {
    return switch (preset) {
        .studio => "Studio",
        .folio => "Folio",
        .ember => "Ember",
        .signal => "Signal",
    };
}

pub fn description(preset: Preset) [:0]const u8 {
    return switch (preset) {
        .studio => "Navy, cyan, and amber with cinematic depth",
        .folio => "Editorial ivory, cobalt type, and crisp structure",
        .ember => "Aubergine, coral, and warm expressive energy",
        .signal => "Acid lime, ultramarine, and graphic impact",
    };
}

pub fn expectedSlideCount(_: Preset) usize {
    return 2;
}

pub fn source(preset: Preset) []const u8 {
    return switch (preset) {
        .studio => @embedFile("starters/studio.sld"),
        .folio => @embedFile("starters/folio.sld"),
        .ember => @embedFile("starters/ember.sld"),
        .signal => @embedFile("starters/signal.sld"),
    };
}

test "every starter is a self-contained parser-clean deck" {
    const parser = @import("parser.zig");
    const slides = @import("slides.zig");
    for (all) |preset| {
        const deck_source = source(preset);
        try std.testing.expect(std.mem.startsWith(u8, deck_source, "#"));
        try std.testing.expect(std.mem.indexOf(u8, deck_source, "@font=") == null);
        try std.testing.expect(std.mem.indexOf(u8, deck_source, "img=") == null);

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const deck = try slides.SlideShow.new(arena.allocator());
        const context = try parser.constructSlidesFromBuf(deck_source, deck, arena.allocator());
        defer context.deinit();
        if (context.parser_errors.items.len != 0) {
            std.debug.print("starter '{s}' failed to parse:\n", .{title(preset)});
            for (context.parser_errors.items) |parser_error| {
                std.debug.print("  line {d}: {s}\n", .{
                    parser_error.line_number,
                    parser_error.message orelse @errorName(parser_error.parser_error),
                });
            }
        }
        try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
        try std.testing.expectEqual(expectedSlideCount(preset), deck.slides.items.len);
    }
}

test "starters expose reusable slide layouts and a group" {
    for (all) |preset| {
        const deck_source = source(preset);
        try std.testing.expect(std.mem.count(u8, deck_source, "@pushslide ") >= 2);
        try std.testing.expect(std.mem.indexOf(u8, deck_source, "@pushgroup ") != null);
        try std.testing.expect(std.mem.count(u8, deck_source, "@popslide ") >= 2);
        try std.testing.expect(std.mem.indexOf(u8, deck_source, "$slide_number") != null);
    }
}
