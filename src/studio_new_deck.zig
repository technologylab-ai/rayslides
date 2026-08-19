//! Self-contained starter decks for Studio's no-file authoring flow.
//!
//! These are deliberately ordinary `.sld` sources rather than a second
//! project format. Choosing a starter replaces only the pristine untitled
//! placeholder and records the complete source as one undoable Studio edit.

const std = @import("std");

pub const Preset = enum {
    blank,
    midnight,
    paper,
    aurora,
};

pub const all = [_]Preset{ .blank, .midnight, .paper, .aurora };

pub fn title(preset: Preset) [:0]const u8 {
    return switch (preset) {
        .blank => "Blank canvas",
        .midnight => "Midnight",
        .paper => "Editorial",
        .aurora => "Aurora",
    };
}

pub fn description(preset: Preset) [:0]const u8 {
    return switch (preset) {
        .blank => "One clean slide, ready for anything",
        .midnight => "Cinematic dark title and content layouts",
        .paper => "Warm, precise, publication-style layouts",
        .aurora => "Bold color, glass panels, and bright accents",
    };
}

pub fn expectedSlideCount(preset: Preset) usize {
    return switch (preset) {
        .blank => 1,
        .midnight, .paper, .aurora => 2,
    };
}

pub fn source(preset: Preset) []const u8 {
    return switch (preset) {
        .blank => blank_source,
        .midnight => midnight_source,
        .paper => paper_source,
        .aurora => aurora_source,
    };
}

const blank_source =
    "# Created in Rayslides Studio\n" ++
    "@fontsize=36\n" ++
    "@color=#e8eef7ff\n" ++
    "\n" ++
    "@slide transition=fade duration=0.35\n" ++
    "@bg color=#0b1220ff\n";

const midnight_source =
    "# Midnight starter · created in Rayslides Studio\n" ++
    "@fontsize=36\n" ++
    "@color=#e8f0fbff\n" ++
    "\n" ++
    "@pushgroup midnight_footer\n" ++
    "@box id=rule x=120 y=985 w=1680 h=3 bg=#29425cff\n" ++
    "@endgroup\n" ++
    "\n" ++
    "@bg color=#07111fff\n" ++
    "@box id=eyebrow x=120 y=150 w=1100 h=44 fontsize=24 color=#61dafbff text=YOUR STORY / 2026\n" ++
    "@box id=title x=112 y=250 w=1540 h=230 fontsize=102 color=#f8fbffff\n" ++
    "@box id=subtitle x=120 y=560 w=1280 h=110 fontsize=38 color=#9fb5c9ff\n" ++
    "@box id=accent x=120 y=760 w=420 h=14 bg=#ffb547ff\n" ++
    "@popgroup midnight_footer id=footer\n" ++
    "@box id=page x=1735 y=1002 w=70 h=34 fontsize=18 color=#6f8ca8ff text=$slide_number\n" ++
    "@pushslide midnight_title\n" ++
    "\n" ++
    "@bg color=#07111fff\n" ++
    "@box id=title x=120 y=100 w=1540 h=100 fontsize=60 color=#f8fbffff\n" ++
    "@box id=kicker x=120 y=238 w=500 h=42 fontsize=22 color=#61dafbff text=KEY IDEA\n" ++
    "@box id=body x=120 y=315 w=1240 h=430 fontsize=38 color=#b9cad9ff line_height=1.35\n" ++
    "@box id=aside x=1445 y=315 w=355 h=430 fontsize=28 color=#07111fff bg=#ffb547ff\n" ++
    "@popgroup midnight_footer id=footer\n" ++
    "@box id=page x=1735 y=1002 w=70 h=34 fontsize=18 color=#6f8ca8ff text=$slide_number\n" ++
    "@pushslide midnight_content\n" ++
    "\n" ++
    "@popslide midnight_title transition=fade duration=0.45\n" ++
    "@set title text=Untitled, but not uninspired\n" ++
    "@set subtitle text=Replace this line with the promise your audience should remember.\n" ++
    "\n" ++
    "@popslide midnight_content transition=slide-left duration=0.45\n" ++
    "@set title text=Make one point beautifully\n" ++
    "@set body text=- Lead with the idea\n- Keep the structure visible\n- Let the details support the story\n" ++
    "@set aside text=42%\nmore clarity\n";

const paper_source =
    "# Editorial starter · created in Rayslides Studio\n" ++
    "@fontsize=36\n" ++
    "@color=#24303aff\n" ++
    "\n" ++
    "@pushgroup editorial_footer\n" ++
    "@box id=label x=120 y=1000 w=900 h=30 fontsize=17 color=#7f776eff text=RAYSLIDES / WORKING DRAFT\n" ++
    "@endgroup\n" ++
    "\n" ++
    "@bg color=#f3eee5ff\n" ++
    "@box id=folio x=120 y=115 w=120 h=34 fontsize=20 color=#b2533eff text=01 / OPEN\n" ++
    "@box id=title x=120 y=245 w=1540 h=250 fontsize=94 color=#20282fff\n" ++
    "@box id=subtitle x=125 y=585 w=1100 h=120 fontsize=36 color=#6c665fff\n" ++
    "@box id=rule x=125 y=805 w=1680 h=4 bg=#b2533eff\n" ++
    "@popgroup editorial_footer id=footer\n" ++
    "@box id=page x=1740 y=1000 w=65 h=30 fontsize=17 color=#7f776eff text=$slide_number\n" ++
    "@pushslide editorial_title\n" ++
    "\n" ++
    "@bg color=#f3eee5ff\n" ++
    "@box id=section x=120 y=105 w=260 h=36 fontsize=19 color=#b2533eff text=SECTION / 01\n" ++
    "@box id=title x=120 y=180 w=1500 h=100 fontsize=58 color=#20282fff\n" ++
    "@box id=body x=120 y=350 w=1060 h=460 fontsize=37 color=#3f494fff line_height=1.4\n" ++
    "@box id=quote x=1320 y=350 w=480 h=360 fontsize=34 color=#f3eee5ff bg=#26343dff\n" ++
    "@popgroup editorial_footer id=footer\n" ++
    "@box id=page x=1740 y=1000 w=65 h=30 fontsize=17 color=#7f776eff text=$slide_number\n" ++
    "@pushslide editorial_content\n" ++
    "\n" ++
    "@popslide editorial_title transition=fade duration=0.4\n" ++
    "@set title text=A considered beginning\n" ++
    "@set subtitle text=An editorial system for arguments, research, and stories with room to breathe.\n" ++
    "\n" ++
    "@popslide editorial_content transition=slide-left duration=0.4\n" ++
    "@set title text=Structure creates confidence\n" ++
    "@set body text=- Establish the frame\n- Develop the evidence\n- End with a clear implication\n" ++
    "@set quote text=\"Clarity is a form of respect.\"\n";

const aurora_source =
    "# Aurora starter · created in Rayslides Studio\n" ++
    "@fontsize=36\n" ++
    "@color=#eff8ffff\n" ++
    "\n" ++
    "@pushgroup aurora_footer\n" ++
    "@box id=brand x=120 y=1000 w=580 h=30 fontsize=18 color=#8fb8d8ff text=IDEAS IN MOTION\n" ++
    "@endgroup\n" ++
    "\n" ++
    "@bg color=#071426ff\n" ++
    "@box id=glow x=1080 y=100 w=700 h=700 bg=#2a68ff55\n" ++
    "@box id=signal x=1280 y=235 w=420 h=420 bg=#e84fd980\n" ++
    "@box id=eyebrow x=120 y=155 w=820 h=40 fontsize=23 color=#71e5ffff text=NEW DECK / AURORA\n" ++
    "@box id=title x=112 y=250 w=1080 h=250 fontsize=100 color=#ffffffff\n" ++
    "@box id=subtitle x=120 y=610 w=1040 h=120 fontsize=36 color=#a9c4dcff\n" ++
    "@popgroup aurora_footer id=footer\n" ++
    "@box id=page x=1740 y=1000 w=65 h=30 fontsize=18 color=#8fb8d8ff text=$slide_number\n" ++
    "@pushslide aurora_title\n" ++
    "\n" ++
    "@bg color=#071426ff\n" ++
    "@box id=title x=120 y=105 w=1500 h=100 fontsize=60 color=#ffffffff\n" ++
    "@box id=body x=120 y=310 w=1040 h=440 fontsize=38 color=#c1d7e8ff line_height=1.38\n" ++
    "@box id=panel x=1280 y=270 w=520 h=520 bg=#142b48ee\n" ++
    "@box id=metric x=1340 y=350 w=400 h=150 fontsize=92 color=#71e5ffff\n" ++
    "@box id=caption x=1340 y=560 w=380 h=110 fontsize=28 color=#d98ce9ff\n" ++
    "@popgroup aurora_footer id=footer\n" ++
    "@box id=page x=1740 y=1000 w=65 h=30 fontsize=18 color=#8fb8d8ff text=$slide_number\n" ++
    "@pushslide aurora_content\n" ++
    "\n" ++
    "@popslide aurora_title transition=fade duration=0.45\n" ++
    "@set title text=Make the future visible\n" ++
    "@set subtitle text=A vivid system for product stories, launches, and ambitious ideas.\n" ++
    "\n" ++
    "@popslide aurora_content transition=slide-left duration=0.45\n" ++
    "@set title text=Momentum, made legible\n" ++
    "@set body text=- Name the change\n- Show the evidence\n- Give the audience a next move\n" ++
    "@set metric text=3.2×\n" ++
    "@set caption text=Faster from first thought to a presentation-ready narrative.\n";

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

test "designed starters expose reusable slide layouts and a group" {
    for (all[1..]) |preset| {
        const deck_source = source(preset);
        try std.testing.expect(std.mem.count(u8, deck_source, "@pushslide ") >= 2);
        try std.testing.expect(std.mem.indexOf(u8, deck_source, "@pushgroup ") != null);
        try std.testing.expect(std.mem.count(u8, deck_source, "@popslide ") >= 2);
        try std.testing.expect(std.mem.indexOf(u8, deck_source, "$slide_number") != null);
    }
}
