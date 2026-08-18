const std = @import("std");
const slides = @import("slides.zig");
const fonts = @import("fonts.zig");
const rl = @import("raylib");

const log = std.log.scoped(.parser);

// NOTE:
// why we have context.current_context:
// @pop some_shit
// # now current_context is loaded with the pushed values, like the color etc
//
// @box x= y=
// # parsing context is loaded with x and y
// text text
// # text is added to the parsing context
//
// @pop other_shit
// # at this moment, the parsing context is complete, it can be commited
// # hence, the above @box with all text will be committed
// # before that: the parsing context is merged with the current context, so the text color is set etc
//
// # then other_shit is popped and put into the current_context
// # while parsing the other_shit line, parsing_context will be used
//
// @box
// more text

pub const ParserError = error{ Internal, Syntax };

pub const ParserErrorContext = struct {
    parser_error: anyerror,
    line_number: usize = 0,
    line_offset: usize = 0,
    message: ?[]const u8,
    formatted: ?[:0]const u8 = null,

    pub fn init(perr: anyerror, lineno: usize, line_offset: usize, message: ?[]const u8) ParserErrorContext {
        const pcx: ParserErrorContext = .{ .parser_error = perr, .line_number = lineno, .line_offset = line_offset, .message = message, .formatted = null };
        return pcx;
    }

    pub fn getFormattedStr(self: *ParserErrorContext, allocator: std.mem.Allocator) ![*:0]const u8 {
        if (self.formatted) |txt| {
            return txt.ptr;
        }
        if (self.message) |msg| {
            self.formatted = try std.fmt.allocPrintZ(allocator, "line {d}: {s} ({s})", .{ self.line_number, self.parser_error, msg });
        } else {
            self.formatted = try std.fmt.allocPrintZ(allocator, "line {d}: {s}", .{ self.line_number, self.parser_error });
        }

        return self.formatted.?.ptr;
    }
};

pub const ParserContext = struct {
    allocator: std.mem.Allocator,
    input: [:0]const u8 = undefined,

    let_substitutions: std.StringHashMap([]const u8),
    let_substituted_lines: std.ArrayList([]const u8),

    parsed_line_number: usize = 0,
    parsed_line_offset: usize = 0,

    parser_errors: std.ArrayList(ParserErrorContext) = undefined,

    first_slide_emitted: bool = false,

    slideshow: *slides.SlideShow = undefined,
    push_contexts: std.StringHashMap(slides.ItemContext),
    push_slides: std.StringHashMap(*slides.Slide),

    current_context: slides.ItemContext = slides.ItemContext{},
    current_slide: *slides.Slide,

    allErrorsCstrArray: ?[][*]const u8 = null,

    fontConfig: fonts.FontConfig = .{
        .opts = .{},
        .normal = null,
        .bold = null,
        .italic = null,
        .bolditalic = null,
        .zig = null,
    },
    custom_fonts_present: bool = false, // signal that fonts need to be loaded after parsing

    fn new(a: std.mem.Allocator) !*ParserContext {
        // .
        var self = try a.create(ParserContext);
        self.* = ParserContext{
            .allocator = a,
            .let_substitutions = std.StringHashMap([]const u8).init(a),
            .let_substituted_lines = std.ArrayList([]const u8).empty,
            .push_contexts = std.StringHashMap(slides.ItemContext).init(a),
            .push_slides = std.StringHashMap(*slides.Slide).init(a),
            .current_slide = try slides.Slide.new(a),
            .parser_errors = std.ArrayList(ParserErrorContext).empty,
            .allErrorsCstrArray = null,
        };
        self.fontConfig = .{
            .opts = .{},
            .normal = null,
            .bold = null,
            .italic = null,
            .bolditalic = null,
            .zig = null,
        };

        return self;
    }

    pub fn deinit(self: *ParserContext) void {
        self.parser_errors.deinit(self.allocator);
        self.push_contexts.deinit();
        self.push_slides.deinit();
        var it = self.let_substitutions.iterator();
        while (it.next()) |kv| {
            self.allocator.free(kv.key_ptr.*);
            self.allocator.free(kv.value_ptr.*);
        }
        for (self.let_substituted_lines.items) |line| {
            log.debug("FREEING line {s}", .{line});
            self.allocator.free(line);
        }
        self.let_substituted_lines.deinit(self.allocator);
    }

    fn logAllErrors(self: *ParserContext) void {
        for (self.parser_errors.items) |err| {
            if (err.message) |msg| {
                log.err("line {d}: {} ({s})", .{ err.line_number, err.parser_error, msg });
            } else {
                log.err("line {d}: {}", .{ err.line_number, err.parser_error });
            }
        }
    }
    pub fn allErrorsToCstrArray(self: *ParserContext, allocator: std.mem.Allocator) ![*]const [*]const u8 {
        if (self.allErrorsCstrArray) |ret| {
            return ret.ptr;
        }
        const howmany = self.parser_errors.items.len;
        var stringarray = try allocator.alloc([*]const u8, howmany);
        var i: usize = 0;
        for (self.parser_errors.items) |err| {
            // err is const, so this doesn't work: stringarray[i] = try err.getFormattedStr(allocator);
            var err2: ParserErrorContext = err;
            stringarray[i] = try err2.getFormattedStr(allocator);
            i += 1;
        }
        self.allErrorsCstrArray = stringarray;
        return stringarray.ptr;
    }
};

fn reportErrorInContext(err: anyerror, ctx: *ParserContext, msg: ?[]const u8) void {
    const pec = ParserErrorContext{
        .parser_error = err,
        .line_number = ctx.parsed_line_number,
        .line_offset = ctx.parsed_line_offset,
        .message = msg,
    };
    ctx.parser_errors.append(ctx.allocator, pec) catch |internal_err| {
        log.err("Could not add error to error list!", .{});
        log.err("    The error to be reported: {any}", .{err});
        log.err("    The error that prevented it: {any}", .{internal_err});
    };
}

fn reportErrorInParsingContext(err: anyerror, pctx: *const slides.ItemContext, ctx: *ParserContext, msg: ?[]const u8) void {
    const pec = ParserErrorContext.init(err, pctx.line_number, pctx.line_offset, msg);
    ctx.parser_errors.append(ctx.allocator, pec) catch |internal_err| {
        log.err("Could not add error to error list!", .{});
        log.err("    The error to be reported: {any}", .{err});
        log.err("    The error that prevented it: {any}", .{internal_err});
    };
}

pub fn constructSlidesFromBuf(input: []const u8, slideshow: *slides.SlideShow, allocator: std.mem.Allocator) !*ParserContext {
    var context: *ParserContext = try ParserContext.new(allocator);
    context.slideshow = slideshow;

    context.input = try allocator.dupeZ(u8, input);
    log.info("input len: {d}, context.input len: {d}", .{ input.len, context.input.len });
    // log.info("input is: {s}", .{context.input});

    const start: usize = if (std.mem.startsWith(u8, context.input, "\xEF\xBB\xBF")) 3 else 0;
    var it = std.mem.splitScalar(u8, input[start..], '\n');

    var parsing_item_context = slides.ItemContext{};

    while (it.next()) |line_untrimmed| {
        {
            const line_unprocessed = std.mem.trimEnd(u8, line_untrimmed, " \t\r");
            log.info("the line {d} is : len={d} {s}", .{ context.parsed_line_number, line_unprocessed.len, line_unprocessed });
            context.parsed_line_number += 1;
            defer context.parsed_line_offset += line_untrimmed.len + 1;

            if (line_unprocessed.len == 0) {
                log.debug("line {d} len == 0!", .{context.parsed_line_number});
                continue;
            }

            if (line_unprocessed[0] == 0) {
                log.debug("line {d} char[0] == 0!", .{context.parsed_line_number});
                continue;
            }

            log.info("Parsing line {d} at offset {d}", .{ context.parsed_line_number, context.parsed_line_offset });
            if (context.input[context.parsed_line_offset] != line_unprocessed[0]) {
                log.err(
                    "line {d} assumed to start at offset {} but saw {c}({}) instead of {c}({})",
                    .{
                        context.parsed_line_number,
                        context.parsed_line_offset,
                        line_unprocessed[0],
                        line_unprocessed[0],
                        context.input[context.parsed_line_offset],
                        context.input[context.parsed_line_offset],
                    },
                );
                return error.Overflow;
            }

            // try to handle let substitutions
            var subst_arena_state: std.heap.ArenaAllocator = .init(context.allocator);
            defer subst_arena_state.deinit();
            const subst_arena = subst_arena_state.allocator();
            const line = blk: {
                // if there's one $ or no $
                if (std.mem.indexOfScalar(u8, line_unprocessed, '$') == std.mem.lastIndexOfScalar(u8, line_unprocessed, '$')) {
                    break :blk line_unprocessed;
                }

                var line_current = line_unprocessed;
                // there might be sth to substitute
                // for each potential subst
                var subst_it = context.let_substitutions.iterator();
                while (subst_it.next()) |kv| {
                    var num_it: usize = 0;
                    while (std.mem.indexOf(u8, line_current, kv.key_ptr.*)) |found_pos| {
                        log.debug("it={d}: Found `{s}` at pos {d} in `{s}`", .{ num_it, kv.key_ptr.*, found_pos, line_current });
                        const replaced = try std.mem.replaceOwned(u8, subst_arena, line_current, kv.key_ptr.*, kv.value_ptr.*);
                        log.debug("it={d} replaced line is `{s}`", .{ num_it, replaced });
                        num_it += 1;
                        line_current = replaced;
                    }
                }
                const replacement_line = try context.allocator.dupe(u8, line_current);
                try context.let_substituted_lines.append(context.allocator, replacement_line);
                break :blk replacement_line;
            };

            // @let command
            if (std.mem.startsWith(u8, line, "@let")) {
                var let_it = std.mem.splitScalar(u8, line["@let".len..], '=');
                if (let_it.next()) |key| {
                    const value = let_it.rest();

                    log.debug("@let: replacement for `{s}` is `{s}`", .{ key, value });

                    const key_clean = std.mem.trim(u8, key, " \t");
                    const key_to_replace = try std.fmt.allocPrint(context.allocator, "${s}$", .{key_clean});
                    const value_clean = std.mem.trim(u8, value, " \t");

                    try context.let_substitutions.put(
                        try context.allocator.dupe(u8, key_to_replace),
                        try context.allocator.dupe(u8, value_clean),
                    );
                }
                continue;
            }

            if (std.mem.startsWith(u8, line, "#")) {
                continue;
            }

            if (std.mem.startsWith(u8, line, "@font")) {
                parseFontGlobals(line, slideshow, context) catch |err| {
                    reportErrorInContext(err, context, null);
                    continue;
                };
                continue;
            }

            if (std.mem.startsWith(u8, line, "@underline_width=")) {
                parseUnderlineWidth(line, slideshow, context) catch |err| {
                    reportErrorInContext(err, context, null);
                    continue;
                };
                continue;
            }

            if (std.mem.startsWith(u8, line, "@line_height=")) {
                parseLineHeight(line, slideshow, context) catch |err| {
                    reportErrorInContext(err, context, null);
                    continue;
                };
                continue;
            }

            if (std.mem.startsWith(u8, line, "@color=")) {
                parseDefaultColor(line, slideshow, context) catch |err| {
                    reportErrorInContext(err, context, null);
                    continue;
                };
                continue;
            }

            if (std.mem.startsWith(u8, line, "@bullet_color=")) {
                parseDefaultBulletColor(line, slideshow, context) catch |err| {
                    reportErrorInContext(err, context, null);
                    continue;
                };
                continue;
            }

            if (std.mem.startsWith(u8, line, "@bullet_symbol=")) {
                parseDefaultBulletSymbol(line, slideshow, context) catch |err| {
                    reportErrorInContext(err, context, null);
                    continue;
                };
                continue;
            }

            if (std.mem.startsWith(u8, line, "@")) {
                // commit current parsing_item_context
                commitParsingContext(&parsing_item_context, context) catch |err| {
                    reportErrorInContext(err, context, null);
                };
                // then parse current item context
                parsing_item_context = parseItemAttributes(line, context) catch |err| {
                    reportErrorInContext(err, context, null);
                    continue;
                };
                parsing_item_context.line_number = context.parsed_line_number;
                parsing_item_context.line_offset = context.parsed_line_offset;
            } else {
                // add text lines to current parsing context
                var text: []const u8 = "";
                var the_line = line;
                // make _ line an empty line
                if (line.len == 1 and line[0] == '_' or line[0] == '`') {
                    the_line = " ";
                }
                if (parsing_item_context.text) |txt| {
                    text = std.fmt.allocPrint(context.allocator, "{s}\n{s}", .{ txt, the_line }) catch |err| {
                        reportErrorInContext(err, context, null);
                        continue;
                    };
                } else {
                    text = std.fmt.allocPrint(context.allocator, "{s}", .{the_line}) catch |err| {
                        reportErrorInContext(err, context, null);
                        continue;
                    };
                }
                parsing_item_context.text = text;
            }
        }
    }
    // commit last slide
    commitParsingContext(&parsing_item_context, context) catch |err| {
        reportErrorInContext(err, context, null);
    };
    context.slideshow.slides.append(context.allocator, context.current_slide) catch |err| {
        reportErrorInContext(err, context, null);
    };

    if (context.parser_errors.items.len == 0) {
        log.info("OK. There were no errors.", .{});
    } else {
        log.info("There were errors!", .{});
        context.logAllErrors();
    }
    return context;
}

fn parseFontGlobals(line: []const u8, slideshow: *slides.SlideShow, context: *ParserContext) !void {
    var it = std.mem.tokenizeScalar(u8, line, '=');
    if (it.next()) |word| {
        if (std.mem.eql(u8, word, "@fontsize")) {
            if (it.next()) |sizestr| {
                slideshow.default_fontsize = std.fmt.parseInt(i32, sizestr, 10) catch |err| {
                    reportErrorInContext(err, context, "@fonsize value not int-parseable");
                    return;
                };
                log.debug("global fontsize: {d}", .{slideshow.default_fontsize});
            }
        }
        if (std.mem.eql(u8, word, "@font")) {
            if (it.next()) |font| {
                context.fontConfig.normal = fonts.FontLoadDesc{ .ttf_filn = try context.allocator.dupe(u8, font) };
                log.debug("global font: {s}", .{context.fontConfig.normal.?.ttf_filn});
                context.custom_fonts_present = true;
            }
        }
        if (std.mem.eql(u8, word, "@font_bold")) {
            if (it.next()) |font_bold| {
                context.fontConfig.bold = fonts.FontLoadDesc{ .ttf_filn = try context.allocator.dupe(u8, font_bold) };
                log.debug("global font_bold: {s}", .{context.fontConfig.bold.?.ttf_filn});
                context.custom_fonts_present = true;
            }
        }
        if (std.mem.eql(u8, word, "@font_italic")) {
            if (it.next()) |font_italic| {
                context.fontConfig.italic = fonts.FontLoadDesc{ .ttf_filn = try context.allocator.dupe(u8, font_italic) };
                log.debug("global font_italic: {s}", .{context.fontConfig.italic.?.ttf_filn});
                context.custom_fonts_present = true;
            }
        }
        if (std.mem.eql(u8, word, "@font_bold_italic")) {
            if (it.next()) |font_bold_italic| {
                context.fontConfig.bolditalic = fonts.FontLoadDesc{ .ttf_filn = try context.allocator.dupe(u8, font_bold_italic) };
                log.debug("global font_bold_italic: {s}", .{context.fontConfig.bolditalic.?.ttf_filn});
                context.custom_fonts_present = true;
            }
        }
        if (std.mem.eql(u8, word, "@font_extra")) {
            if (it.next()) |font_zig| {
                context.fontConfig.zig = fonts.FontLoadDesc{ .ttf_filn = try context.allocator.dupe(u8, font_zig) };
                log.debug("global font_extra: {s}", .{context.fontConfig.zig.?.ttf_filn});
                context.custom_fonts_present = true;
            }
        }
    }
}

fn parseUnderlineWidth(line: []const u8, slideshow: *slides.SlideShow, context: *ParserContext) !void {
    var it = std.mem.tokenizeScalar(u8, line, '=');
    if (it.next()) |word| {
        if (std.mem.eql(u8, word, "@underline_width")) {
            if (it.next()) |sizestr| {
                slideshow.default_underline_width = std.fmt.parseInt(i32, sizestr, 10) catch |err| {
                    reportErrorInContext(err, context, "@underline_width value not int-parseable");
                    return;
                };

                log.debug("global underline_width: {d}", .{slideshow.default_underline_width});
            }
        }
    }
}

fn parseLineHeight(line: []const u8, slideshow: *slides.SlideShow, context: *ParserContext) !void {
    var it = std.mem.tokenizeScalar(u8, line, '=');
    if (it.next()) |word| {
        if (std.mem.eql(u8, word, "@line_height")) {
            if (it.next()) |sizestr| {
                slideshow.default_line_height_factor = std.fmt.parseFloat(f32, sizestr) catch |err| {
                    reportErrorInContext(err, context, "@line_height value not float-parseable");
                    return;
                };

                log.debug("global line_height_factor: {d}", .{slideshow.default_line_height_factor});
            }
        }
    }
}

fn parseDefaultColor(line: []const u8, slideshow: *slides.SlideShow, context: *ParserContext) !void {
    var it = std.mem.tokenizeScalar(u8, line, '=');
    if (it.next()) |word| {
        if (std.mem.eql(u8, word, "@color")) {
            slideshow.default_color = try parseColor(line[1..], context);
            log.debug("global default_color: {any}", .{slideshow.default_color});
        }
    }
}

fn parseDefaultBulletColor(line: []const u8, slideshow: *slides.SlideShow, context: *ParserContext) !void {
    var it = std.mem.tokenizeScalar(u8, line, '=');
    if (it.next()) |word| {
        if (std.mem.eql(u8, word, "@bullet_color")) {
            slideshow.default_bullet_color = try parseColor(line[8..], context); // line[8] is beginning of word 'color' inside @bullet_color
            log.debug("global default_bullet_color: {any}", .{slideshow.default_bullet_color});
        }
    }
}

fn parseDefaultBulletSymbol(line: []const u8, slideshow: *slides.SlideShow, context: *ParserContext) !void {
    var it = std.mem.tokenizeScalar(u8, line, '=');
    if (it.next()) |word| {
        if (std.mem.eql(u8, word, "@bullet_symbol")) {
            if (it.next()) |sym| {
                slideshow.default_bullet_symbol = try context.allocator.dupe(u8, sym);
                log.debug("global default_bullet_symbol: {s}", .{slideshow.default_bullet_symbol});
            }
        }
    }
}

fn parseColor(s: []const u8, context: *ParserContext) !rl.Color {
    var it = std.mem.tokenizeScalar(u8, s, '=');
    var ret: rl.Color = .blank;
    if (it.next()) |word| {
        if (std.mem.eql(u8, word, "color")) {
            if (it.next()) |colorstr| {
                ret = try parseColorLiteral(colorstr, context);
            }
        }
    }
    return ret;
}

fn parseColorLiteral(colorstr: []const u8, context: *ParserContext) !rl.Color {
    if (colorstr.len != 9 or colorstr[0] != '#') {
        const errmsg = try std.fmt.allocPrint(context.allocator, "color string '{s}' not 9 chars long or missing #", .{colorstr});
        reportErrorInContext(ParserError.Syntax, context, errmsg);
        return ParserError.Syntax;
    }
    const coloru32 = std.fmt.parseInt(u32, colorstr[1..], 16) catch |err| {
        const errmsg = try std.fmt.allocPrint(context.allocator, "color string '{s}' not hex-parsable", .{colorstr});
        reportErrorInContext(err, context, errmsg);
        return ParserError.Syntax;
    };
    return rl.Color.fromInt(coloru32);
}

fn parseItemAttributes(line: []const u8, context: *ParserContext) !slides.ItemContext {
    var item_context = slides.ItemContext{};
    var word_it = std.mem.tokenizeAny(u8, line, " \t");
    if (word_it.next()) |directive| {
        item_context.directive = directive;
    } else {
        return ParserError.Internal;
    }

    // check if directive needs to be followed by a name
    if (std.mem.eql(u8, item_context.directive, "@push") or
        std.mem.eql(u8, item_context.directive, "@pop") or
        std.mem.eql(u8, item_context.directive, "@pushslide") or
        std.mem.eql(u8, item_context.directive, "@popslide"))
    {
        if (word_it.next()) |name| {
            item_context.context_name = name;
            // log.info("context name : {s}", .{item_context.context_name.?});
        } else {
            reportErrorInContext(ParserError.Syntax, context, "context name missing!");
            return ParserError.Syntax;
        }
    }

    log.debug("Parsing {s}", .{item_context.directive});

    var text_words = std.ArrayList([]const u8).empty;
    defer text_words.deinit(context.allocator);
    var after_text_directive = false;

    while (word_it.next()) |word| {
        if (!after_text_directive) {
            var attr_it = std.mem.tokenizeScalar(u8, word, '=');
            if (attr_it.next()) |attrname| {
                if (std.mem.eql(u8, attrname, "x")) {
                    if (attr_it.next()) |sizestr| {
                        const size = std.fmt.parseFloat(f32, sizestr) catch |err| {
                            reportErrorInContext(err, context, "cannot parse x=");
                            continue;
                        };
                        var pos: rl.Vector2 = item_context.position orelse .zero();
                        pos.x = size;
                        item_context.position = pos;
                    }
                }
                if (std.mem.eql(u8, attrname, "y")) {
                    if (attr_it.next()) |sizestr| {
                        const size = std.fmt.parseFloat(f32, sizestr) catch |err| {
                            reportErrorInContext(err, context, "cannot parse y=");
                            continue;
                        };
                        var pos: rl.Vector2 = item_context.position orelse .zero();
                        pos.y = size;
                        item_context.position = pos;
                    }
                }
                if (std.mem.eql(u8, attrname, "w")) {
                    if (attr_it.next()) |sizestr| {
                        const width = std.fmt.parseFloat(f32, sizestr) catch |err| {
                            reportErrorInContext(err, context, "cannot parse w=");
                            continue;
                        };
                        var size: rl.Vector2 = item_context.size orelse .zero();
                        size.x = width;
                        item_context.size = size;
                    }
                }
                if (std.mem.eql(u8, attrname, "h")) {
                    if (attr_it.next()) |sizestr| {
                        const height = std.fmt.parseFloat(f32, sizestr) catch |err| {
                            reportErrorInContext(err, context, "cannot parse h=");
                            continue;
                        };
                        var size: rl.Vector2 = item_context.size orelse .zero();
                        size.y = height;
                        item_context.size = size;
                    }
                }
                if (std.mem.eql(u8, attrname, "fontsize")) {
                    if (attr_it.next()) |sizestr| {
                        const size = std.fmt.parseInt(i32, sizestr, 10) catch |err| {
                            reportErrorInContext(err, context, "cannot parse fontsize=");
                            continue;
                        };
                        item_context.fontSize = size;
                    }
                }
                if (std.mem.eql(u8, attrname, "color")) {
                    if (attr_it.next()) |colorstr| {
                        const color = parseColorLiteral(colorstr, context) catch |err| {
                            reportErrorInContext(err, context, "cannot parse color=");
                            continue;
                        };
                        item_context.color = color;
                    }
                }
                if (std.mem.eql(u8, attrname, "bullet_color")) {
                    if (attr_it.next()) |colorstr| {
                        const color = parseColorLiteral(colorstr, context) catch |err| {
                            reportErrorInContext(err, context, "cannot parse bullet_color=");
                            continue;
                        };
                        item_context.bullet_color = color;
                    }
                }
                if (std.mem.eql(u8, attrname, "bullet_symbol")) {
                    if (attr_it.next()) |sym| {
                        item_context.bullet_symbol = try context.allocator.dupe(u8, sym);
                    }
                }
                if (std.mem.eql(u8, attrname, "underline_width")) {
                    if (attr_it.next()) |sizestr| {
                        const width = std.fmt.parseInt(i32, sizestr, 10) catch |err| {
                            reportErrorInContext(err, context, "cannot parse underline_width=");
                            continue;
                        };
                        item_context.underline_width = width;
                    }
                }
                if (std.mem.eql(u8, attrname, "line_height")) {
                    if (attr_it.next()) |sizestr| {
                        const height = std.fmt.parseFloat(f32, sizestr) catch |err| {
                            reportErrorInContext(err, context, "cannot parse line_height=");
                            continue;
                        };
                        item_context.line_height_factor = height;
                    }
                }
                if (std.mem.eql(u8, attrname, "text")) {
                    after_text_directive = true;
                    if (attr_it.next()) |textafterequal| {
                        try text_words.append(context.allocator, textafterequal);
                    }
                }
                if (std.mem.eql(u8, attrname, "img")) {
                    if (attr_it.next()) |imgpath| {
                        item_context.img_path = imgpath;
                    }
                }
                if (std.mem.eql(u8, attrname, "scale")) {
                    if (attr_it.next()) |scalestr| {
                        const scale_val = std.fmt.parseFloat(f32, scalestr) catch |err| {
                            reportErrorInContext(err, context, "cannot parse scale=");
                            continue;
                        };
                        item_context.scale = scale_val;
                    }
                }
                if (std.mem.eql(u8, attrname, "ratio")) {
                    if (attr_it.next()) |ratiostr| {
                        const ratio_val = std.fmt.parseFloat(f32, ratiostr) catch |err| {
                            reportErrorInContext(err, context, "cannot parse ratio=");
                            continue;
                        };
                        item_context.ratio = ratio_val;
                    }
                }
            }
        } else {
            try text_words.append(context.allocator, word);
        }
    }
    if (text_words.items.len > 0) {
        item_context.text = try std.mem.join(context.allocator, " ", text_words.items);
    }
    return item_context;
}

// - @push       -- merge: parser context, current item context --> pushed item
// - @pushslide  -- pushed slide just from parser context, clear current item context just as with @page
// - @pop        -- merge: current item context with parser context --> current item context
//                       e.g. "@pop some_shit x=1" -- pop and override
// - @popslide   -- just pop the slide, clear current item context
// - @slide      -- just create and emit slide with parser context (and not item context!), clear current item context
//                       we don't want to merge current item context with @slide: we would inherit the shit from any
//                       previous item!
// - @box        -- merge: parser context, current item context -> emitted box
//                       diese Software eure "normale" Software ist und   also, see override rules below for instantiating a box.
// - @bg         -- merge: parser context, current item context -> emitted bg item
//
//
// Instantiating a box:
// override all unset settings by:
// - item context values : use SlideItem.applyContext(ItemContext)
// - slide defaults
// - slideshow defaults
//
fn mergeParserAndItemContext(parsing_item_context: *slides.ItemContext, item_context: *slides.ItemContext) void {
    if (parsing_item_context.text == null) parsing_item_context.text = item_context.text;
    if (parsing_item_context.fontSize == null) parsing_item_context.fontSize = item_context.fontSize;
    if (parsing_item_context.color == null) parsing_item_context.color = item_context.color;
    if (parsing_item_context.position == null) parsing_item_context.position = item_context.position;
    // Don't inherit size for image boxes - let renderer use auto-dimensions
    if (parsing_item_context.size == null and parsing_item_context.img_path == null) {
        parsing_item_context.size = item_context.size;
    }
    if (parsing_item_context.underline_width == null) parsing_item_context.underline_width = item_context.underline_width;
    if (parsing_item_context.line_height_factor == null) parsing_item_context.line_height_factor = item_context.line_height_factor;
    if (parsing_item_context.bullet_color == null) parsing_item_context.bullet_color = item_context.bullet_color;
    if (parsing_item_context.scale == null) parsing_item_context.scale = item_context.scale;
    if (parsing_item_context.ratio == null) parsing_item_context.ratio = item_context.ratio;
}

fn commitParsingContext(parsing_item_context: *slides.ItemContext, context: *ParserContext) !void {
    // .
    log.debug("{s} : text=`{?s}`", .{ parsing_item_context.directive, parsing_item_context.text });

    // switch over directives
    if (std.mem.eql(u8, parsing_item_context.directive, "@push")) {
        mergeParserAndItemContext(parsing_item_context, &context.current_context);
        if (parsing_item_context.context_name) |context_name| {
            try context.push_contexts.put(context_name, parsing_item_context.*);
        }
        // just to make sure this context remains active -- TODO: why?!??!? isn't it better cleared out after the push?
        // context.current_context = parsing_item_context.*;
        // context.current_context.text = null;
        // context.current_context.img_path = null;
        context.current_context = .{}; // TODO: we better cleared the context after the push
        return;
    }

    if (std.mem.eql(u8, parsing_item_context.directive, "@pushslide")) {
        context.current_slide.applyContext(parsing_item_context);
        if (parsing_item_context.context_name) |context_name| {
            try context.push_slides.put(context_name, context.current_slide);
        }
        context.current_slide = try slides.Slide.new(context.allocator);
    }

    if (std.mem.eql(u8, parsing_item_context.directive, "@pop")) {
        // pop the context if present
        // also set the parsing context to the current context
        if (parsing_item_context.context_name) |context_name| {
            const ctx_opt = context.push_contexts.get(context_name);
            if (ctx_opt) |ctx| {
                context.current_context = ctx;
                context.current_context.text = null;
                context.current_context.img_path = null;
                parsing_item_context.applyOtherIfNull(ctx);
            } else {
                const errmsg = try std.fmt.allocPrint(context.allocator, "cannot @pop `{s}` : was not pushed!", .{context_name});
                reportErrorInParsingContext(ParserError.Syntax, parsing_item_context, context, errmsg);
            }
            _ = try commitItemToSlide(parsing_item_context, context);
        }
        return;
    }

    if (std.mem.eql(u8, parsing_item_context.directive, "@popslide")) {
        // emit the current slide (if present) into the slideshow
        // then create a new slide (NOT deiniting the current one) with the **parsing** context's overrides
        // and make it the current slide
        // after that, clear the current item context
        if (context.first_slide_emitted) {
            context.current_slide.applyContext(parsing_item_context); //  ignore current item context, it's a @slide
            try context.slideshow.slides.append(context.allocator, context.current_slide);
        }
        context.first_slide_emitted = true;
        // pop the slide and reset the item context
        // (the latter is done by continue)
        if (parsing_item_context.context_name) |context_name| {
            const sld_opt = context.push_slides.get(context_name);
            if (sld_opt) |sld| {
                context.current_slide = try slides.Slide.fromSlide(sld, context.allocator);
                context.current_slide.pos_in_editor = parsing_item_context.line_offset;
                context.current_slide.line_in_editor = parsing_item_context.line_number;
            } else {
                const errmsg = try std.fmt.allocPrint(context.allocator, "cannot @popslide `{s}` : was not pushed!", .{context_name});
                reportErrorInParsingContext(ParserError.Syntax, parsing_item_context, context, errmsg);
            }
            // new slide, clear the current item context
            context.current_context = .{};
        }
        return;
    }

    if (std.mem.eql(u8, parsing_item_context.directive, "@slide")) {
        // emit the current slide (if present) into the slideshow
        // then create a new slide (NOT deiniting the current one) with the **parsing** context's overrides
        // and make it the current slide
        // after that, clear the current item context
        if (context.first_slide_emitted) {
            context.current_slide.applyContext(parsing_item_context); //  ignore current item context, it's a @slide
            try context.slideshow.slides.append(context.allocator, context.current_slide);
        }
        context.first_slide_emitted = true;

        context.current_slide = try slides.Slide.new(context.allocator);
        context.current_slide.pos_in_editor = parsing_item_context.line_offset; //context.parsed_line_offset;
        context.current_slide.line_in_editor = parsing_item_context.line_number; // context.parsed_line_number;
        context.current_context = .{}; // clear the current item context, to start fresh in each new slide
        return;
    }

    if (std.mem.eql(u8, parsing_item_context.directive, "@box")) {
        // set kind to img if img attribute is present else set it to textbox
        // but first, merge shit
        // - @box        -- merge: parser context, current item context -> emitted box
        //                         also, see override rules below for instantiating a box.
        //
        // Instantiating a box:
        // override all unset settings by:
        // - item context values : use SlideItem.applyContext(ItemContext)
        // - slide defaults
        // - slideshow defaults

        // const slide_item = try commitItemToSlide(parsing_item_context, context);
        // var text = slide_item.text orelse "";
        // log.info("added a box item: `{s}`", .{text});
        _ = try commitItemToSlide(parsing_item_context, context);
        return;
    }

    // @bg is just for convenience. x=0, y=0, w=render_width, h=render_hight
    if (std.mem.eql(u8, parsing_item_context.directive, "@bg")) {
        // well, we can see if fun features emerge when we do all the merges
        parsing_item_context.position = rl.Vector2.zero();
        _ = try commitItemToSlide(parsing_item_context, context);
        return;
    }
}

fn commitItemToSlide(parsing_item_context: *slides.ItemContext, parser_context: *ParserContext) !*slides.SlideItem {
    mergeParserAndItemContext(parsing_item_context, &parser_context.current_context);
    var slide_item = try slides.SlideItem.new(parser_context.allocator);
    slide_item.applyContext(parsing_item_context.*);
    slide_item.applySlideDefaultsIfNecessary(parser_context.*.current_slide);
    slide_item.applySlideShowDefaultsIfNecessary(parser_context.slideshow);
    if (slide_item.img_path != null) {
        slide_item.kind = .img;
    } else {
        slide_item.kind = .textbox;
    }
    if (std.mem.eql(u8, parsing_item_context.directive, "@bg")) {
        slide_item.kind = .background;
    }
    // log.info("\n\n\n ADDING {s} as {any}", .{ parsing_item_context.directive, slide_item.kind });
    try parser_context.current_slide.items.?.append(parser_context.allocator, slide_item.*);

    slide_item.sanityCheck() catch |err| {
        reportErrorInParsingContext(err, parsing_item_context, parser_context, "item sanity check failed");
    };
    return slide_item; // just FYI
}
