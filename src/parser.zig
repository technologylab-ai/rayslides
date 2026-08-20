const std = @import("std");
const builtin = @import("builtin");
const slides = @import("slides.zig");
const fonts = @import("fonts.zig");
const animation = @import("animation.zig");
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

const ReusableGroupDefinition = struct {
    members: std.ArrayList(slides.SlideItem),
    /// Ordinary `@pop` changes the parser's inherited item context for the
    /// item after it. Preserve that observable tail only when the definition
    /// actually contains a `@pop`; box-only groups leave the caller's context
    /// untouched.
    post_context: ?slides.ItemContext = null,
};

const ReusableGroupBuilder = struct {
    name: []const u8,
    start_line_number: usize,
    start_line_offset: usize,
    members: std.ArrayList(slides.SlideItem) = .empty,
    parsing_item_context: slides.ItemContext = .{},
    pending_animation: ?animation.ItemSpec = null,
    pending_animation_source: slides.SourceRef = .{},
    local_context: slides.ItemContext,
    post_context: ?slides.ItemContext = null,
    nested_depth: usize = 0,
    valid: bool = true,
};

const SpeakerNotesBuilder = struct {
    text: std.ArrayList(u8) = .empty,
    source: slides.SourceRef,
    line_count: usize = 0,
    duplicate: bool = false,
    invalid: bool = false,

    fn appendLine(self: *SpeakerNotesBuilder, allocator: std.mem.Allocator, line: []const u8) !void {
        const separator: usize = if (self.line_count > 0) 1 else 0;
        if (line.len + separator > slides.max_speaker_notes_bytes -| self.text.items.len) {
            self.invalid = true;
            return error.SpeakerNotesTooLong;
        }
        if (separator != 0) try self.text.append(allocator, '\n');
        try self.text.appendSlice(allocator, line);
        self.line_count += 1;
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
    reusable_groups: std.StringHashMap(ReusableGroupDefinition),
    active_group: ?ReusableGroupBuilder = null,

    current_context: slides.ItemContext = slides.ItemContext{},
    current_slide: *slides.Slide,
    pending_animation: ?animation.ItemSpec = null,
    active_morph_state: ?usize = null,
    /// True while parsing the authored base scene of a successfully cloned
    /// @popslide instance. During this window @set/@show/@hide may override
    /// inherited template items without changing their shared definition.
    template_instance_base_open: bool = false,

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
            .reusable_groups = std.StringHashMap(ReusableGroupDefinition).init(a),
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
        var group_it = self.reusable_groups.valueIterator();
        while (group_it.next()) |group| group.members.deinit(self.allocator);
        self.reusable_groups.deinit();
        if (self.active_group) |*group| group.members.deinit(self.allocator);
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
        if (builtin.is_test) return;
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

fn isReusableName(name: []const u8) bool {
    if (name.len == 0 or !(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name[1..]) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-')) return false;
    }
    return true;
}

fn directiveWord(line: []const u8) []const u8 {
    var words = std.mem.tokenizeAny(u8, line, " \t");
    return words.next() orelse "";
}

fn beginReusableGroup(line: []const u8, context: *ParserContext) !void {
    var words = std.mem.tokenizeAny(u8, line, " \t");
    _ = words.next();
    const name = words.next() orelse "";
    var valid = true;
    if (!isReusableName(name)) {
        reportErrorInContext(ParserError.Syntax, context, "@pushgroup requires a literal reusable name");
        valid = false;
    }
    if (words.next() != null) {
        reportErrorInContext(ParserError.Syntax, context, "@pushgroup accepts only its literal name");
        valid = false;
    }
    if (context.pending_animation != null) {
        reportErrorInContext(ParserError.Syntax, context, "@anim must be followed by an item before @pushgroup");
        context.pending_animation = null;
    }
    context.active_group = .{
        .name = name,
        .start_line_number = context.parsed_line_number,
        .start_line_offset = context.parsed_line_offset,
        .local_context = context.current_context,
        .valid = valid,
    };
}

fn appendReusableGroupBodyLine(item_context: *slides.ItemContext, line: []const u8, context: *ParserContext) !void {
    var body_line = line;
    if ((line.len == 1 and line[0] == '_') or line[0] == '`') body_line = " ";
    item_context.text = if (item_context.text) |text|
        try std.fmt.allocPrint(context.allocator, "{s}\n{s}", .{ text, body_line })
    else
        try std.fmt.allocPrint(context.allocator, "{s}", .{body_line});
}

fn reusableGroupHasMember(builder: *const ReusableGroupBuilder, id: []const u8) bool {
    for (builder.members.items) |item| {
        if (item.id) |member_id| if (std.mem.eql(u8, member_id, id)) return true;
    }
    return false;
}

fn buildReusableGroupMember(
    item_context: *slides.ItemContext,
    builder: *ReusableGroupBuilder,
    context: *ParserContext,
) !?slides.SlideItem {
    const member_id = item_context.id orelse {
        reportErrorInParsingContext(ParserError.Syntax, item_context, context, "every reusable-group member requires an explicit id=");
        builder.valid = false;
        return null;
    };
    if (!isReusableName(member_id)) {
        reportErrorInParsingContext(ParserError.Syntax, item_context, context, "reusable-group member id= must be a literal reusable-name segment");
        builder.valid = false;
        return null;
    }
    if (reusableGroupHasMember(builder, member_id)) {
        const message = try std.fmt.allocPrint(context.allocator, "duplicate reusable-group member id `{s}`", .{member_id});
        reportErrorInParsingContext(ParserError.Syntax, item_context, context, message);
        builder.valid = false;
        return null;
    }

    if (builder.pending_animation) |pending| {
        if (item_context.animation == null) item_context.animation = pending;
        builder.pending_animation = null;
    }

    if (std.mem.eql(u8, item_context.directive, "@pop")) {
        const component_name = item_context.context_name orelse {
            builder.valid = false;
            return null;
        };
        const component = context.push_contexts.get(component_name) orelse {
            const message = try std.fmt.allocPrint(context.allocator, "cannot use @pop `{s}` in reusable group: was not pushed", .{component_name});
            reportErrorInParsingContext(ParserError.Syntax, item_context, context, message);
            builder.valid = false;
            return null;
        };
        builder.local_context = component;
        builder.local_context.text = null;
        builder.local_context.img_path = null;
        builder.post_context = builder.local_context;
        item_context.applyOtherIfNull(component);
    }

    mergeParserAndItemContext(item_context, &builder.local_context);
    var item = slides.SlideItem{};
    item.applyContext(item_context.*);
    item.source = .{
        .scope = .direct,
        .line_number = item_context.line_number,
        .line_offset = item_context.line_offset,
        .patchable = item_context.source_patchable,
    };
    item.applySlideDefaultsIfNecessary(context.current_slide);
    item.applySlideShowDefaultsIfNecessary(context.slideshow);
    item.kind = if (item.img_path != null) .img else .textbox;
    item.sanityCheck() catch |err| {
        reportErrorInParsingContext(err, item_context, context, "reusable-group member sanity check failed");
        builder.valid = false;
        return null;
    };
    return item;
}

fn commitReusableGroupParsingContext(builder: *ReusableGroupBuilder, context: *ParserContext) !void {
    const item_context = &builder.parsing_item_context;
    if (item_context.directive.len == 0) return;
    defer builder.parsing_item_context = .{};

    if (std.mem.eql(u8, item_context.directive, "@anim")) {
        if (item_context.text != null) {
            reportErrorInParsingContext(ParserError.Syntax, item_context, context, "@anim cannot own body text in a reusable group");
            builder.valid = false;
        }
        if (builder.pending_animation != null) {
            reportErrorInParsingContext(ParserError.Syntax, item_context, context, "@anim must be followed by one reusable-group member");
            builder.valid = false;
        }
        builder.pending_animation = item_context.animation orelse animation.ItemSpec{};
        builder.pending_animation_source = .{
            .line_number = item_context.line_number,
            .line_offset = item_context.line_offset,
        };
        return;
    }

    if (!std.mem.eql(u8, item_context.directive, "@box") and
        !std.mem.eql(u8, item_context.directive, "@pop"))
    {
        builder.valid = false;
        return;
    }
    if (try buildReusableGroupMember(item_context, builder, context)) |item| {
        try builder.members.append(context.allocator, item);
    }
}

fn installReusableGroup(context: *ParserContext, builder: *ReusableGroupBuilder) !void {
    if (builder.pending_animation != null) {
        const source = slides.ItemContext{
            .line_number = builder.pending_animation_source.line_number,
            .line_offset = builder.pending_animation_source.line_offset,
        };
        reportErrorInParsingContext(ParserError.Syntax, &source, context, "dangling @anim at end of reusable group");
        builder.valid = false;
    }
    if (!builder.valid) {
        builder.members.deinit(context.allocator);
        return;
    }
    const definition = ReusableGroupDefinition{
        .members = builder.members,
        .post_context = builder.post_context,
    };
    if (context.reusable_groups.getPtr(builder.name)) |old| {
        old.members.deinit(context.allocator);
        old.* = definition;
    } else {
        try context.reusable_groups.put(builder.name, definition);
    }
}

fn processReusableGroupLine(line: []const u8, context: *ParserContext) !void {
    var builder = &context.active_group.?;
    if (line.len == 0 or std.mem.startsWith(u8, line, "#")) return;
    if (std.mem.indexOfScalar(u8, line, '$') != null) {
        reportErrorInContext(ParserError.Syntax, context, "dynamic `$` expansion is forbidden in reusable-group definitions");
        builder.valid = false;
        return;
    }

    if (builder.nested_depth > 0) {
        if (std.mem.startsWith(u8, line, "@")) {
            const nested_directive = directiveWord(line);
            if (std.mem.eql(u8, nested_directive, "@pushgroup")) {
                builder.nested_depth += 1;
            } else if (std.mem.eql(u8, nested_directive, "@endgroup")) {
                builder.nested_depth -= 1;
            }
        }
        return;
    }

    if (!std.mem.startsWith(u8, line, "@")) {
        if (!std.mem.eql(u8, builder.parsing_item_context.directive, "@box") and
            !std.mem.eql(u8, builder.parsing_item_context.directive, "@pop"))
        {
            reportErrorInContext(ParserError.Syntax, context, "reusable-group body text must belong to a literal @box or @pop member");
            builder.valid = false;
            return;
        }
        try appendReusableGroupBodyLine(&builder.parsing_item_context, line, context);
        return;
    }

    const directive = directiveWord(line);
    if (std.mem.eql(u8, directive, "@endgroup")) {
        try commitReusableGroupParsingContext(builder, context);
        if (std.mem.trim(u8, line[directive.len..], " \t").len != 0) {
            reportErrorInContext(ParserError.Syntax, context, "@endgroup accepts no attributes");
            builder.valid = false;
        }
        try installReusableGroup(context, builder);
        context.active_group = null;
        return;
    }

    try commitReusableGroupParsingContext(builder, context);
    if (std.mem.eql(u8, directive, "@pushgroup")) {
        reportErrorInContext(ParserError.Syntax, context, "reusable-group definitions cannot nest");
        builder.valid = false;
        builder.nested_depth = 1;
        return;
    }
    if (!std.mem.eql(u8, directive, "@box") and
        !std.mem.eql(u8, directive, "@pop") and
        !std.mem.eql(u8, directive, "@anim") and
        !(std.mem.startsWith(u8, directive, "@anim(") and std.mem.endsWith(u8, directive, ")")))
    {
        reportErrorInContext(ParserError.Syntax, context, "only literal @box/@pop members and their @anim are allowed in a reusable group");
        builder.valid = false;
        return;
    }

    const error_count = context.parser_errors.items.len;
    builder.parsing_item_context = parseItemAttributes(line, context) catch |err| {
        if (context.parser_errors.items.len == error_count) reportErrorInContext(err, context, null);
        builder.valid = false;
        return;
    };
    if (context.parser_errors.items.len != error_count) builder.valid = false;
    builder.parsing_item_context.line_number = context.parsed_line_number;
    builder.parsing_item_context.line_offset = context.parsed_line_offset;
    builder.parsing_item_context.source_patchable = true;
}

/// Builds `slideshow` and returns its parser-side owner. The resulting slide
/// graph borrows slices from this context's input and expanded `@let` lines;
/// callers must keep the context alive until the slideshow graph is destroyed.
pub fn constructSlidesFromBuf(input: []const u8, slideshow: *slides.SlideShow, allocator: std.mem.Allocator) !*ParserContext {
    var context: *ParserContext = try ParserContext.new(allocator);
    context.slideshow = slideshow;

    context.input = try allocator.dupeZ(u8, input);
    log.info("input len: {d}, context.input len: {d}", .{ input.len, context.input.len });
    // log.info("input is: {s}", .{context.input});

    const start: usize = if (std.mem.startsWith(u8, context.input, "\xEF\xBB\xBF")) 3 else 0;
    context.parsed_line_offset = start;
    // All slices retained by SlideItem and template contexts must point into
    // parser-owned storage rather than the caller's transient editor buffer.
    var it = std.mem.splitScalar(u8, context.input[start..], '\n');

    var parsing_item_context = slides.ItemContext{};
    var speaker_notes_builder: ?SpeakerNotesBuilder = null;

    while (it.next()) |line_untrimmed| {
        {
            const line_unprocessed = std.mem.trimEnd(u8, line_untrimmed, " \t\r");
            log.info("the line {d} is : len={d} {s}", .{ context.parsed_line_number, line_unprocessed.len, line_unprocessed });
            context.parsed_line_number += 1;
            defer context.parsed_line_offset += line_untrimmed.len + 1;

            // Notes are an explicit block, so directive-looking prose remains
            // private text instead of mutating the slide. Empty lines remain
            // meaningful; only an exact, unindented @endnotes line closes it.
            if (speaker_notes_builder) |*builder| {
                if (std.mem.eql(u8, line_unprocessed, "@endnotes")) {
                    if (!builder.invalid and !builder.duplicate) {
                        context.current_slide.speaker_notes = try builder.text.toOwnedSlice(context.allocator);
                        context.current_slide.speaker_notes_source = builder.source;
                    } else {
                        builder.text.deinit(context.allocator);
                    }
                    speaker_notes_builder = null;
                    continue;
                }
                if (builder.invalid or builder.duplicate) continue;
                builder.appendLine(context.allocator, line_unprocessed) catch |err| {
                    reportErrorInContext(err, context, "speaker notes exceed the 8192-byte limit");
                };
                continue;
            }

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

            // Reusable-group definitions are parsed in a deliberately small,
            // transactional sub-language before @let/global handling. This
            // keeps forbidden directives and substitutions from mutating the
            // live slide or inherited item context while a block is open.
            if (context.active_group != null) {
                processReusableGroupLine(line_unprocessed, context) catch |err| {
                    reportErrorInContext(err, context, "could not parse reusable-group definition");
                    if (context.active_group) |*group| group.valid = false;
                };
                continue;
            }

            const raw_directive = directiveWord(line_unprocessed);
            if (std.mem.eql(u8, raw_directive, "@notes")) {
                commitParsingContext(&parsing_item_context, context) catch |err| {
                    reportErrorInContext(err, context, null);
                };
                parsing_item_context = .{};
                const has_attributes = std.mem.trim(u8, line_unprocessed[raw_directive.len..], " \t").len != 0;
                if (has_attributes) {
                    reportErrorInContext(ParserError.Syntax, context, "@notes accepts no attributes");
                }
                const duplicate = context.current_slide.speaker_notes != null;
                if (duplicate) {
                    reportErrorInContext(ParserError.Syntax, context, "a slide can contain only one @notes block");
                }
                speaker_notes_builder = .{
                    .source = .{
                        .scope = .direct,
                        .line_number = context.parsed_line_number,
                        .line_offset = context.parsed_line_offset,
                        .patchable = true,
                    },
                    .duplicate = duplicate,
                    .invalid = has_attributes,
                };
                continue;
            }
            if (std.mem.eql(u8, raw_directive, "@endnotes")) {
                reportErrorInContext(ParserError.Syntax, context, "@endnotes without an open @notes block");
                continue;
            }
            if (std.mem.eql(u8, raw_directive, "@pushgroup")) {
                commitParsingContext(&parsing_item_context, context) catch |err| {
                    reportErrorInContext(err, context, null);
                };
                parsing_item_context = .{};
                try beginReusableGroup(line_unprocessed, context);
                continue;
            }
            if (std.mem.eql(u8, raw_directive, "@endgroup")) {
                reportErrorInContext(ParserError.Syntax, context, "@endgroup without an open @pushgroup");
                continue;
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
                // Clear the committed context before parsing. A malformed
                // directive must never cause the preceding item/state to be
                // committed a second time at the next directive or EOF.
                parsing_item_context = .{};
                const error_count_before = context.parser_errors.items.len;
                parsing_item_context = parseItemAttributes(line, context) catch |err| {
                    // Attribute parsing reports contextual errors itself. Only
                    // add a generic record for failures without one (OOM, etc.).
                    if (context.parser_errors.items.len == error_count_before) {
                        reportErrorInContext(err, context, null);
                    }
                    continue;
                };
                parsing_item_context.line_number = context.parsed_line_number;
                parsing_item_context.line_offset = context.parsed_line_offset;
                // Expanded @let lines do not have a safe one-to-one mapping
                // back to their physical tokens. Keep them selectable in
                // Studio, but explicitly read-only until such a mapping exists.
                parsing_item_context.source_patchable = line.ptr == line_unprocessed.ptr;
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
    if (context.active_group) |*group| {
        const source = slides.ItemContext{
            .line_number = group.start_line_number,
            .line_offset = group.start_line_offset,
        };
        reportErrorInParsingContext(ParserError.Syntax, &source, context, "unclosed @pushgroup definition");
        group.members.deinit(context.allocator);
        context.active_group = null;
    }
    if (speaker_notes_builder) |*builder| {
        const source = slides.ItemContext{
            .line_number = builder.source.line_number,
            .line_offset = builder.source.line_offset,
        };
        reportErrorInParsingContext(ParserError.Syntax, &source, context, "unclosed @notes block");
        builder.text.deinit(context.allocator);
        speaker_notes_builder = null;
    }
    // commit last slide
    commitParsingContext(&parsing_item_context, context) catch |err| {
        reportErrorInContext(err, context, null);
    };
    validateCurrentMorphIds(context, &parsing_item_context) catch |err| {
        reportErrorInContext(err, context, "could not validate morph ids");
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
        if (std.mem.startsWith(u8, directive, "@anim(") and std.mem.endsWith(u8, directive, ")")) {
            item_context.directive = "@anim";
            var spec = animation.ItemSpec{};
            spec.effect = animation.parseEffect(directive["@anim(".len .. directive.len - 1]) catch |err| {
                reportErrorInContext(err, context, "unknown @anim effect");
                return ParserError.Syntax;
            };
            item_context.animation = spec;
        } else if (std.mem.startsWith(u8, directive, "@state(") and std.mem.endsWith(u8, directive, ")")) {
            const state_kind = directive["@state(".len .. directive.len - 1];
            if (!std.mem.eql(u8, state_kind, "morph")) {
                reportErrorInContext(ParserError.Syntax, context, "only @state(morph) is supported");
                return ParserError.Syntax;
            }
            item_context.directive = "@state";
            item_context.morph = .{};
        } else {
            item_context.directive = directive;
        }
    } else {
        return ParserError.Internal;
    }

    // check if directive needs to be followed by a name
    if (std.mem.eql(u8, item_context.directive, "@push") or
        std.mem.eql(u8, item_context.directive, "@pop") or
        std.mem.eql(u8, item_context.directive, "@pushslide") or
        std.mem.eql(u8, item_context.directive, "@popslide") or
        std.mem.eql(u8, item_context.directive, "@popgroup") or
        std.mem.eql(u8, item_context.directive, "@set") or
        std.mem.eql(u8, item_context.directive, "@show") or
        std.mem.eql(u8, item_context.directive, "@hide"))
    {
        if (word_it.next()) |name| {
            item_context.context_name = name;
            // log.info("context name : {s}", .{item_context.context_name.?});
        } else {
            reportErrorInContext(ParserError.Syntax, context, "context name missing!");
            return ParserError.Syntax;
        }
    }

    if (std.mem.eql(u8, item_context.directive, "@crowd")) {
        const action = word_it.next() orelse {
            reportErrorInContext(ParserError.Syntax, context, "@crowd requires `join` or `poll`");
            return ParserError.Syntax;
        };
        const kind: slides.CrowdKind = if (std.mem.eql(u8, action, "join"))
            .join
        else if (std.mem.eql(u8, action, "poll"))
            .poll
        else {
            reportErrorInContext(ParserError.Syntax, context, "unknown @crowd action; expected `join` or `poll`");
            return ParserError.Syntax;
        };
        item_context.crowd = .{ .kind = kind };
    }

    log.debug("Parsing {s}", .{item_context.directive});

    var text_words = std.ArrayList([]const u8).empty;
    defer text_words.deinit(context.allocator);
    var after_text_directive = false;
    var group_instance_id_seen = false;

    while (word_it.next()) |word| {
        if (!after_text_directive) {
            if (std.mem.eql(u8, item_context.directive, "@popgroup")) {
                const equals_index = std.mem.indexOfScalar(u8, word, '=') orelse {
                    reportErrorInContext(ParserError.Syntax, context, "@popgroup accepts only id=INSTANCE");
                    return ParserError.Syntax;
                };
                if (!std.mem.eql(u8, word[0..equals_index], "id") or
                    equals_index + 1 == word.len or
                    std.mem.indexOfScalar(u8, word[equals_index + 1 ..], '=') != null or
                    group_instance_id_seen)
                {
                    reportErrorInContext(ParserError.Syntax, context, "@popgroup requires exactly one id=INSTANCE attribute");
                    return ParserError.Syntax;
                }
                group_instance_id_seen = true;
            }
            // `text=` owns the complete remainder of the directive. Split at
            // only its first equals sign so inline examples such as
            // `id=hero_image` are preserved instead of being truncated to
            // the literal `` `id``.
            if (std.mem.indexOfScalar(u8, word, '=')) |equals_index| {
                if (std.mem.eql(u8, word[0..equals_index], "text")) {
                    after_text_directive = true;
                    const text_after_equal = word[equals_index + 1 ..];
                    if (text_after_equal.len > 0) try text_words.append(context.allocator, text_after_equal);
                    continue;
                }
            }
            if (std.mem.eql(u8, item_context.directive, "@anim") and std.mem.indexOfScalar(u8, word, '=') == null) {
                var spec = item_context.animation orelse animation.ItemSpec{};
                spec.effect = animation.parseEffect(word) catch |err| {
                    reportErrorInContext(err, context, "unknown @anim effect");
                    continue;
                };
                item_context.animation = spec;
                continue;
            }
            var attr_it = std.mem.tokenizeScalar(u8, word, '=');
            if (attr_it.next()) |attrname| {
                if (std.mem.eql(u8, attrname, "id")) {
                    if (attr_it.next()) |id| {
                        item_context.id = id;
                        if (item_context.crowd) |crowd_value| {
                            var crowd = crowd_value;
                            crowd.id = id;
                            item_context.crowd = crowd;
                        }
                    }
                }
                if (std.mem.eql(u8, attrname, "x")) {
                    if (attr_it.next()) |sizestr| {
                        const size = std.fmt.parseFloat(f32, sizestr) catch |err| {
                            reportErrorInContext(err, context, "cannot parse x=");
                            continue;
                        };
                        var pos: rl.Vector2 = item_context.position orelse .zero();
                        pos.x = size;
                        item_context.position = pos;
                        item_context.has_x = true;
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
                        item_context.has_y = true;
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
                        item_context.has_w = true;
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
                        item_context.has_h = true;
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
                if (std.mem.eql(u8, attrname, "bg")) {
                    if (attr_it.next()) |colorstr| {
                        item_context.has_background_color = true;
                        if (std.mem.eql(u8, colorstr, "none")) {
                            item_context.background_color = null;
                        } else {
                            const color = parseColorLiteral(colorstr, context) catch |err| {
                                reportErrorInContext(err, context, "cannot parse bg=");
                                item_context.has_background_color = false;
                                continue;
                            };
                            item_context.background_color = color;
                        }
                    }
                }
                if (std.mem.eql(u8, attrname, "opacity")) {
                    if (attr_it.next()) |opacitystr| {
                        const opacity = std.fmt.parseFloat(f32, opacitystr) catch |err| {
                            reportErrorInContext(err, context, "cannot parse opacity=");
                            continue;
                        };
                        if (opacity < 0 or opacity > 1) {
                            reportErrorInContext(ParserError.Syntax, context, "opacity= must be between 0 and 1");
                            continue;
                        }
                        item_context.opacity = opacity;
                    }
                }
                if (std.mem.eql(u8, attrname, "visible")) {
                    if (attr_it.next()) |visible_str| {
                        if (std.mem.eql(u8, visible_str, "true")) {
                            item_context.visible = true;
                        } else if (std.mem.eql(u8, visible_str, "false")) {
                            item_context.visible = false;
                        } else {
                            reportErrorInContext(ParserError.Syntax, context, "visible= must be true or false");
                        }
                    }
                }
                if (std.mem.eql(u8, attrname, "locked")) {
                    if (attr_it.next()) |locked_str| {
                        if (std.mem.eql(u8, locked_str, "true")) {
                            item_context.locked = true;
                        } else if (std.mem.eql(u8, locked_str, "false")) {
                            item_context.locked = false;
                        } else {
                            reportErrorInContext(ParserError.Syntax, context, "locked= must be true or false");
                        }
                    }
                }
                if (std.mem.eql(u8, attrname, "shadow")) {
                    if (attr_it.next()) |shadowstr| {
                        var shadow = item_context.text_shadow orelse slides.TextShadow{};
                        if (std.mem.eql(u8, shadowstr, "none")) {
                            shadow.enabled = false;
                            item_context.has_shadow_enabled = true;
                        } else {
                            shadow.color = parseColorLiteral(shadowstr, context) catch |err| {
                                reportErrorInContext(err, context, "cannot parse shadow=");
                                continue;
                            };
                            shadow.enabled = true;
                            item_context.has_shadow_enabled = true;
                            item_context.has_shadow_color = true;
                        }
                        item_context.text_shadow = shadow;
                    }
                }
                if (std.mem.eql(u8, attrname, "shadow_offset")) {
                    if (attr_it.next()) |offsetstr| {
                        const offset = std.fmt.parseFloat(f32, offsetstr) catch |err| {
                            reportErrorInContext(err, context, "cannot parse shadow_offset=");
                            continue;
                        };
                        var shadow = item_context.text_shadow orelse slides.TextShadow{};
                        shadow.offset = .{ .x = offset, .y = offset };
                        item_context.text_shadow = shadow;
                        item_context.has_shadow_x = true;
                        item_context.has_shadow_y = true;
                    }
                }
                if (std.mem.eql(u8, attrname, "shadow_x")) {
                    if (attr_it.next()) |offsetstr| {
                        const offset = std.fmt.parseFloat(f32, offsetstr) catch |err| {
                            reportErrorInContext(err, context, "cannot parse shadow_x=");
                            continue;
                        };
                        var shadow = item_context.text_shadow orelse slides.TextShadow{};
                        shadow.offset.x = offset;
                        item_context.text_shadow = shadow;
                        item_context.has_shadow_x = true;
                    }
                }
                if (std.mem.eql(u8, attrname, "shadow_y")) {
                    if (attr_it.next()) |offsetstr| {
                        const offset = std.fmt.parseFloat(f32, offsetstr) catch |err| {
                            reportErrorInContext(err, context, "cannot parse shadow_y=");
                            continue;
                        };
                        var shadow = item_context.text_shadow orelse slides.TextShadow{};
                        shadow.offset.y = offset;
                        item_context.text_shadow = shadow;
                        item_context.has_shadow_y = true;
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
                if (std.mem.eql(u8, attrname, "open") and item_context.crowd != null) {
                    if (attr_it.next()) |openstr| {
                        var crowd = item_context.crowd.?;
                        if (std.mem.eql(u8, openstr, "true") or std.mem.eql(u8, openstr, "yes") or std.mem.eql(u8, openstr, "1")) {
                            crowd.initially_open = true;
                        } else if (std.mem.eql(u8, openstr, "false") or std.mem.eql(u8, openstr, "no") or std.mem.eql(u8, openstr, "0")) {
                            crowd.initially_open = false;
                        } else {
                            reportErrorInContext(ParserError.Syntax, context, "@crowd open= must be true or false");
                        }
                        item_context.crowd = crowd;
                    }
                }
                if (std.mem.eql(u8, attrname, "anim") or std.mem.eql(u8, attrname, "effect")) {
                    if (attr_it.next()) |effectstr| {
                        var spec = item_context.animation orelse animation.ItemSpec{};
                        spec.effect = animation.parseEffect(effectstr) catch |err| {
                            reportErrorInContext(err, context, "unknown animation effect");
                            continue;
                        };
                        item_context.animation = spec;
                    }
                }
                if (std.mem.eql(u8, attrname, "by")) {
                    if (attr_it.next()) |groupstr| {
                        var spec = item_context.animation orelse animation.ItemSpec{};
                        spec.by = animation.parseGrouping(groupstr) catch |err| {
                            reportErrorInContext(err, context, "unknown animation grouping");
                            continue;
                        };
                        item_context.animation = spec;
                    }
                }
                if (std.mem.eql(u8, attrname, "after")) {
                    if (attr_it.next()) |delaystr| {
                        const delay = std.fmt.parseFloat(f32, delaystr) catch |err| {
                            reportErrorInContext(err, context, "cannot parse animation after=");
                            continue;
                        };
                        if (delay < 0) {
                            reportErrorInContext(ParserError.Syntax, context, "animation after= must not be negative");
                            continue;
                        }
                        if (std.mem.eql(u8, item_context.directive, "@state")) {
                            var spec = item_context.morph orelse animation.MorphSpec{};
                            spec.after = delay;
                            item_context.morph = spec;
                        } else {
                            var spec = item_context.animation orelse animation.ItemSpec{};
                            spec.after = delay;
                            item_context.animation = spec;
                        }
                    }
                }
                if (std.mem.eql(u8, attrname, "ease")) {
                    if (attr_it.next()) |easingstr| {
                        if (!std.mem.eql(u8, item_context.directive, "@state")) {
                            reportErrorInContext(ParserError.Syntax, context, "ease= is only valid on @state(morph)");
                            continue;
                        }
                        var spec = item_context.morph orelse animation.MorphSpec{};
                        spec.easing = animation.parseEasing(easingstr) catch |err| {
                            reportErrorInContext(err, context, "unknown morph easing");
                            continue;
                        };
                        item_context.morph = spec;
                    }
                }
                if (std.mem.eql(u8, attrname, "label")) {
                    if (attr_it.next()) |label| {
                        if (!std.mem.eql(u8, item_context.directive, "@state")) {
                            reportErrorInContext(ParserError.Syntax, context, "label= is only valid on @state(morph)");
                            continue;
                        }
                        if (!isMorphStateLabel(label)) {
                            reportErrorInContext(ParserError.Syntax, context, "morph state label must start with a letter or underscore and contain only letters, digits, _ or -");
                            continue;
                        }
                        var spec = item_context.morph orelse animation.MorphSpec{};
                        spec.label = label;
                        item_context.morph = spec;
                    }
                }
                if (std.mem.eql(u8, attrname, "transition")) {
                    if (attr_it.next()) |effectstr| {
                        var transition = item_context.transition orelse animation.Transition{};
                        transition.effect = animation.parseEffect(effectstr) catch |err| {
                            reportErrorInContext(err, context, "unknown slide transition");
                            continue;
                        };
                        item_context.transition = transition;
                    }
                }
                if (std.mem.eql(u8, attrname, "duration")) {
                    if (attr_it.next()) |durationstr| {
                        const duration = std.fmt.parseFloat(f32, durationstr) catch |err| {
                            reportErrorInContext(err, context, "cannot parse animation duration=");
                            continue;
                        };
                        if (duration < 0) {
                            reportErrorInContext(ParserError.Syntax, context, "animation duration= must not be negative");
                            continue;
                        }
                        if (std.mem.eql(u8, item_context.directive, "@state")) {
                            var spec = item_context.morph orelse animation.MorphSpec{};
                            spec.duration = duration;
                            item_context.morph = spec;
                        } else if (std.mem.eql(u8, item_context.directive, "@slide") or
                            std.mem.eql(u8, item_context.directive, "@popslide") or
                            std.mem.eql(u8, item_context.directive, "@pushslide"))
                        {
                            var transition = item_context.transition orelse animation.Transition{};
                            transition.duration = duration;
                            item_context.transition = transition;
                        } else {
                            var spec = item_context.animation orelse animation.ItemSpec{};
                            spec.duration = duration;
                            item_context.animation = spec;
                        }
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
    if (std.mem.eql(u8, item_context.directive, "@anim") and item_context.animation == null) {
        item_context.animation = animation.ItemSpec{};
    }
    if (std.mem.eql(u8, item_context.directive, "@state") and item_context.morph == null) {
        item_context.morph = animation.MorphSpec{};
    }
    return item_context;
}

fn isMorphStateLabel(label: []const u8) bool {
    if (label.len == 0 or !(std.ascii.isAlphabetic(label[0]) or label[0] == '_')) return false;
    for (label[1..]) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-')) return false;
    }
    return true;
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
    if (parsing_item_context.id == null) parsing_item_context.id = item_context.id;
    if (parsing_item_context.text == null) parsing_item_context.text = item_context.text;
    if (parsing_item_context.fontSize == null) parsing_item_context.fontSize = item_context.fontSize;
    if (parsing_item_context.color == null) parsing_item_context.color = item_context.color;
    if (!parsing_item_context.has_background_color and item_context.has_background_color) {
        parsing_item_context.background_color = item_context.background_color;
        parsing_item_context.has_background_color = true;
    }
    if (parsing_item_context.position) |own_position| {
        if (item_context.position) |inherited_position| {
            var merged = own_position;
            if (!parsing_item_context.has_x) merged.x = inherited_position.x;
            if (!parsing_item_context.has_y) merged.y = inherited_position.y;
            parsing_item_context.position = merged;
        }
    } else {
        parsing_item_context.position = item_context.position;
    }
    parsing_item_context.has_x = parsing_item_context.has_x or item_context.has_x;
    parsing_item_context.has_y = parsing_item_context.has_y or item_context.has_y;
    // Don't inherit size for image boxes - let renderer use auto-dimensions
    if (parsing_item_context.img_path == null) {
        if (parsing_item_context.size) |own_size| {
            if (item_context.size) |inherited_size| {
                var merged = own_size;
                if (!parsing_item_context.has_w) merged.x = inherited_size.x;
                if (!parsing_item_context.has_h) merged.y = inherited_size.y;
                parsing_item_context.size = merged;
            }
        } else {
            parsing_item_context.size = item_context.size;
        }
        parsing_item_context.has_w = parsing_item_context.has_w or item_context.has_w;
        parsing_item_context.has_h = parsing_item_context.has_h or item_context.has_h;
    }
    if (parsing_item_context.underline_width == null) parsing_item_context.underline_width = item_context.underline_width;
    if (parsing_item_context.line_height_factor == null) parsing_item_context.line_height_factor = item_context.line_height_factor;
    if (parsing_item_context.bullet_color == null) parsing_item_context.bullet_color = item_context.bullet_color;
    if (parsing_item_context.scale == null) parsing_item_context.scale = item_context.scale;
    if (parsing_item_context.ratio == null) parsing_item_context.ratio = item_context.ratio;
    if (parsing_item_context.animation == null) parsing_item_context.animation = item_context.animation;
    if (parsing_item_context.transition == null) parsing_item_context.transition = item_context.transition;
    if (parsing_item_context.text_shadow == null) parsing_item_context.text_shadow = item_context.text_shadow;
    if (parsing_item_context.opacity == null) parsing_item_context.opacity = item_context.opacity;
    if (parsing_item_context.visible == null) parsing_item_context.visible = item_context.visible;
}

fn findMorphTarget(items: []slides.SlideItem, target: []const u8) ?usize {
    var found: ?usize = null;
    for (items, 0..) |item, index| {
        if (item.id) |id| {
            if (std.mem.eql(u8, id, target)) {
                if (found != null) return null;
                found = index;
            }
        }
    }
    return found;
}

fn validateMorphIds(items: []const slides.SlideItem, context: *ParserContext, parsing_item_context: *const slides.ItemContext) !void {
    for (items, 0..) |item, index| {
        const id = item.id orelse continue;
        for (items[index + 1 ..]) |other| {
            if (other.id) |other_id| {
                if (std.mem.eql(u8, id, other_id)) {
                    const message = try std.fmt.allocPrint(context.allocator, "duplicate morph id `{s}` on one slide", .{id});
                    reportErrorInParsingContext(ParserError.Syntax, parsing_item_context, context, message);
                    return;
                }
            }
        }
    }
}

fn validateCurrentMorphIds(context: *ParserContext, parsing_item_context: *const slides.ItemContext) !void {
    if (context.current_slide.morph_states.items.len == 0) return;
    const final_state = context.current_slide.morph_states.items[context.current_slide.morph_states.items.len - 1];
    try validateMorphIds(final_state.items.items, context, parsing_item_context);
}

/// Rebuilds the renderer-facing crowd prompt/choices when @set changes the
/// item's body text. SlideItem.text alone is not used to draw crowd panels.
fn prepareCrowdTextMutation(
    parsing_item_context: *slides.ItemContext,
    item: *const slides.SlideItem,
    context: *ParserContext,
) !void {
    if (parsing_item_context.text == null or item.kind != .crowd) return;
    var crowd = item.crowd orelse return;
    crowd.prompt = "";
    crowd.choices = &.{};
    parsing_item_context.crowd = crowd;
    try finalizeCrowdSpec(parsing_item_context, context);
}

fn commitMorphMutation(parsing_item_context: *slides.ItemContext, context: *ParserContext) !void {
    const state_index = context.active_morph_state orelse {
        reportErrorInParsingContext(ParserError.Syntax, parsing_item_context, context, "@set/@show/@hide require a preceding @state(morph)");
        return;
    };
    const target = parsing_item_context.context_name orelse return;
    if (parsing_item_context.id != null) {
        reportErrorInParsingContext(ParserError.Syntax, parsing_item_context, context, "morph IDs are immutable; @set/@show/@hide cannot contain id=");
        parsing_item_context.id = null;
    }
    if (parsing_item_context.animation != null) {
        reportErrorInParsingContext(ParserError.Syntax, parsing_item_context, context, "morph mutations interpolate as part of their state; anim= is not valid here");
        parsing_item_context.animation = null;
    }
    const items = &context.current_slide.morph_states.items[state_index].items;
    const item_index = findMorphTarget(items.items, target) orelse {
        const message = try std.fmt.allocPrint(context.allocator, "morph target `{s}` is missing or ambiguous", .{target});
        reportErrorInParsingContext(ParserError.Syntax, parsing_item_context, context, message);
        return;
    };
    var item = &items.items[item_index];
    try prepareCrowdTextMutation(parsing_item_context, item, context);
    if (std.mem.eql(u8, parsing_item_context.directive, "@show")) parsing_item_context.visible = true;
    if (std.mem.eql(u8, parsing_item_context.directive, "@hide")) parsing_item_context.visible = false;
    item.applyPatch(parsing_item_context.*);
    item.state_source = .{
        .scope = .morph_item,
        .line_number = parsing_item_context.line_number,
        .line_offset = parsing_item_context.line_offset,
        .patchable = parsing_item_context.source_patchable,
    };
    item.state_source_state = state_index;
}

fn commitSlideInstanceMutation(parsing_item_context: *slides.ItemContext, context: *ParserContext) !void {
    const target = parsing_item_context.context_name orelse return;
    if (parsing_item_context.id != null) {
        reportErrorInParsingContext(ParserError.Syntax, parsing_item_context, context, "slide-template IDs are immutable; @set/@show/@hide cannot contain id=");
        parsing_item_context.id = null;
    }
    if (parsing_item_context.animation != null) {
        reportErrorInParsingContext(ParserError.Syntax, parsing_item_context, context, "slide-template base overrides are not animations; anim= is not valid here");
        parsing_item_context.animation = null;
    }

    const items = &context.current_slide.items.?;
    var found: ?usize = null;
    var ambiguous = false;
    for (items.items, 0..) |item, index| {
        const id = item.id orelse continue;
        if (!std.mem.eql(u8, id, target)) continue;
        if (found != null) {
            ambiguous = true;
            break;
        }
        found = index;
    }
    if (ambiguous or found == null) {
        const message = try std.fmt.allocPrint(context.allocator, "slide-template instance target `{s}` is missing or ambiguous", .{target});
        reportErrorInParsingContext(ParserError.Syntax, parsing_item_context, context, message);
        return;
    }

    var item = &items.items[found.?];
    if (item.source.scope != .slide_template) {
        const message = try std.fmt.allocPrint(context.allocator, "slide-template instance target `{s}` is not inherited from the template", .{target});
        reportErrorInParsingContext(ParserError.Syntax, parsing_item_context, context, message);
        return;
    }
    try prepareCrowdTextMutation(parsing_item_context, item, context);
    if (std.mem.eql(u8, parsing_item_context.directive, "@show")) parsing_item_context.visible = true;
    if (std.mem.eql(u8, parsing_item_context.directive, "@hide")) parsing_item_context.visible = false;
    item.applyPatch(parsing_item_context.*);
    item.instance_source = .{
        .scope = .slide_instance_override,
        .line_number = parsing_item_context.line_number,
        .line_offset = parsing_item_context.line_offset,
        .patchable = parsing_item_context.source_patchable,
    };
}

fn currentSlideHasExactId(context: *ParserContext, id: []const u8) bool {
    for (context.current_slide.currentItems(context.active_morph_state).items) |item| {
        if (item.id) |existing_id| {
            if (std.mem.eql(u8, existing_id, id)) return true;
        }
    }
    return false;
}

fn commitReusableGroupInstance(parsing_item_context: *slides.ItemContext, context: *ParserContext) !void {
    if (context.pending_animation != null) {
        reportErrorInParsingContext(ParserError.Syntax, parsing_item_context, context, "@anim cannot target @popgroup; animations belong to its literal members");
        context.pending_animation = null;
        return;
    }
    if (context.active_morph_state != null) {
        reportErrorInParsingContext(ParserError.Syntax, parsing_item_context, context, "@popgroup must be instantiated before the first @state(morph)");
        return;
    }

    const group_name = parsing_item_context.context_name orelse return;
    if (!isReusableName(group_name)) {
        reportErrorInParsingContext(ParserError.Syntax, parsing_item_context, context, "@popgroup name must be a literal reusable-name segment");
        return;
    }
    const instance_id = parsing_item_context.id orelse {
        reportErrorInParsingContext(ParserError.Syntax, parsing_item_context, context, "@popgroup requires id=INSTANCE");
        return;
    };
    if (!isReusableName(instance_id)) {
        reportErrorInParsingContext(ParserError.Syntax, parsing_item_context, context, "@popgroup id= must be a literal reusable-name segment");
        return;
    }
    if (parsing_item_context.text != null) {
        reportErrorInParsingContext(ParserError.Syntax, parsing_item_context, context, "@popgroup cannot own body text");
        return;
    }

    const definition = context.reusable_groups.get(group_name) orelse {
        const message = try std.fmt.allocPrint(context.allocator, "cannot @popgroup `{s}`: definition is missing or not complete", .{group_name});
        reportErrorInParsingContext(ParserError.Syntax, parsing_item_context, context, message);
        return;
    };

    var clones = std.ArrayList(slides.SlideItem).empty;
    defer clones.deinit(context.allocator);
    try clones.ensureTotalCapacity(context.allocator, definition.members.items.len);
    for (definition.members.items) |prototype| {
        const member_id = prototype.id.?;
        const effective_id = try std.fmt.allocPrint(context.allocator, "{s}.{s}", .{ instance_id, member_id });
        if (currentSlideHasExactId(context, effective_id)) {
            const message = try std.fmt.allocPrint(context.allocator, "reusable-group instance id `{s}` collides with an item on the current slide", .{effective_id});
            reportErrorInParsingContext(ParserError.Syntax, parsing_item_context, context, message);
            return;
        }

        var clone = prototype;
        clone.id = effective_id;
        clone.identity = context.current_slide.next_item_identity + clones.items.len;
        clone.creation_morph_state = null;
        clone.source = .{
            .scope = .group_instance_member,
            .line_number = parsing_item_context.line_number,
            .line_offset = parsing_item_context.line_offset,
            .patchable = parsing_item_context.source_patchable,
        };
        clone.group_member_source = prototype.source;
        clone.instance_source = null;
        clone.state_source = null;
        clone.state_source_state = null;
        clones.appendAssumeCapacity(clone);
    }

    try context.current_slide.items.?.appendSlice(context.allocator, clones.items);
    context.current_slide.next_item_identity += clones.items.len;
    if (definition.post_context) |post_context| context.current_context = post_context;
}

fn commitParsingContext(parsing_item_context: *slides.ItemContext, context: *ParserContext) !void {
    // .
    if (parsing_item_context.directive.len == 0) return;
    log.debug("{s} : text=`{?s}`", .{ parsing_item_context.directive, parsing_item_context.text });

    if (std.mem.eql(u8, parsing_item_context.directive, "@anim")) {
        if (context.active_morph_state != null) {
            reportErrorInParsingContext(ParserError.Syntax, parsing_item_context, context, "@anim is only valid before the first @state(morph) on a slide");
            return;
        }
        context.pending_animation = parsing_item_context.animation orelse animation.ItemSpec{};
        return;
    }

    if (std.mem.eql(u8, parsing_item_context.directive, "@state")) {
        if (context.pending_animation != null) {
            reportErrorInParsingContext(ParserError.Syntax, parsing_item_context, context, "@anim must be followed by an item before @state(morph)");
            context.pending_animation = null;
        }
        context.active_morph_state = try context.current_slide.beginMorphState(
            parsing_item_context.morph orelse animation.MorphSpec{},
            .{
                .scope = .morph_item,
                .line_number = parsing_item_context.line_number,
                .line_offset = parsing_item_context.line_offset,
                .patchable = parsing_item_context.source_patchable,
            },
            context.active_morph_state,
        );
        context.template_instance_base_open = false;
        context.current_context = .{};
        return;
    }

    if (std.mem.eql(u8, parsing_item_context.directive, "@set") or
        std.mem.eql(u8, parsing_item_context.directive, "@show") or
        std.mem.eql(u8, parsing_item_context.directive, "@hide"))
    {
        if (context.pending_animation != null) {
            reportErrorInParsingContext(ParserError.Syntax, parsing_item_context, context, "@anim must be followed by an item before @set/@show/@hide");
            context.pending_animation = null;
            return;
        }
        if (context.active_morph_state != null) {
            try commitMorphMutation(parsing_item_context, context);
        } else if (context.template_instance_base_open) {
            try commitSlideInstanceMutation(parsing_item_context, context);
        } else {
            reportErrorInParsingContext(ParserError.Syntax, parsing_item_context, context, "@set/@show/@hide require a @popslide base scene or a preceding @state(morph)");
        }
        return;
    }

    if (std.mem.eql(u8, parsing_item_context.directive, "@popgroup")) {
        try commitReusableGroupInstance(parsing_item_context, context);
        return;
    }

    const consumes_pending_animation = std.mem.eql(u8, parsing_item_context.directive, "@box") or
        std.mem.eql(u8, parsing_item_context.directive, "@pop") or
        std.mem.eql(u8, parsing_item_context.directive, "@bg") or
        std.mem.eql(u8, parsing_item_context.directive, "@crowd");
    if (consumes_pending_animation) {
        if (context.pending_animation) |pending| {
            if (parsing_item_context.animation == null) parsing_item_context.animation = pending;
            context.pending_animation = null;
        }
    }

    // switch over directives
    if (std.mem.eql(u8, parsing_item_context.directive, "@push")) {
        if (parsing_item_context.id != null) {
            reportErrorInParsingContext(ParserError.Syntax, parsing_item_context, context, "put id= on a @pop instance, not on its reusable @push template");
            parsing_item_context.id = null;
        }
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
        context.template_instance_base_open = false;
        if (context.current_slide.speaker_notes != null) {
            reportErrorInParsingContext(ParserError.Syntax, parsing_item_context, context, "@notes is slide-instance content and cannot be captured by @pushslide");
        }
        context.current_slide.applyContext(parsing_item_context);
        if (context.current_slide.morph_states.items.len > 0) {
            try validateCurrentMorphIds(context, parsing_item_context);
            reportErrorInParsingContext(
                ParserError.Syntax,
                parsing_item_context,
                context,
                "slide templates cannot contain morph states; add @state(morph) after @popslide",
            );
        } else if (parsing_item_context.context_name) |context_name| {
            for (context.current_slide.items.?.items) |*item| {
                // A template may itself be captured from a customized
                // @popslide instance. In that case the latest base override
                // is the source that actually authored the captured value.
                // Promote it to shared-template provenance for the new
                // definition instead of leaking an instance-local owner into
                // every future clone of the nested template.
                if (item.instance_source) |instance_source| item.source = instance_source;
                item.source.scope = .slide_template;
                item.instance_source = null;
                item.captureSharedTemplateValues();
            }
            try context.push_slides.put(context_name, context.current_slide);
        }
        context.current_slide = try slides.Slide.new(context.allocator);
        context.active_morph_state = null;
    }

    if (std.mem.eql(u8, parsing_item_context.directive, "@pop")) {
        // pop the context if present
        // also set the parsing context to the current context
        if (parsing_item_context.context_name) |context_name| {
            const ctx_opt = context.push_contexts.get(context_name);
            var component_source: ?slides.SourceRef = null;
            if (ctx_opt) |ctx| {
                context.current_context = ctx;
                context.current_context.text = null;
                context.current_context.img_path = null;
                parsing_item_context.applyOtherIfNull(ctx);
                component_source = .{
                    .scope = .direct,
                    .line_number = ctx.line_number,
                    .line_offset = ctx.line_offset,
                    .patchable = ctx.source_patchable,
                };
            } else {
                const errmsg = try std.fmt.allocPrint(context.allocator, "cannot @pop `{s}` : was not pushed!", .{context_name});
                reportErrorInParsingContext(ParserError.Syntax, parsing_item_context, context, errmsg);
            }
            _ = try commitItemToSlide(parsing_item_context, context);
            const committed_items = context.current_slide.currentItems(context.active_morph_state);
            committed_items.items[committed_items.items.len - 1].component_source = component_source;
        }
        return;
    }

    if (std.mem.eql(u8, parsing_item_context.directive, "@popslide")) {
        context.template_instance_base_open = false;
        // emit the current slide (if present) into the slideshow
        // then create a new slide (NOT deiniting the current one) with the **parsing** context's overrides
        // and make it the current slide
        // after that, clear the current item context
        if (context.first_slide_emitted) {
            try validateCurrentMorphIds(context, parsing_item_context);
            var previous_slide_context = parsing_item_context.*;
            previous_slide_context.transition = null;
            context.current_slide.applyContext(&previous_slide_context); // ignore the new slide's transition
            try context.slideshow.slides.append(context.allocator, context.current_slide);
        }
        context.first_slide_emitted = true;
        // pop the slide and reset the item context
        // (the latter is done by continue)
        if (parsing_item_context.context_name) |context_name| {
            const sld_opt = context.push_slides.get(context_name);
            if (sld_opt) |sld| {
                if (sld.morph_states.items.len > 0) {
                    reportErrorInParsingContext(
                        ParserError.Syntax,
                        parsing_item_context,
                        context,
                        "morphing slide templates are unsupported; add @state(morph) after @popslide",
                    );
                    context.current_slide = try slides.Slide.new(context.allocator);
                } else {
                    context.current_slide = try slides.Slide.fromSlide(sld, context.allocator);
                    context.current_slide.pos_in_editor = parsing_item_context.line_offset;
                    context.current_slide.line_in_editor = parsing_item_context.line_number;
                    if (parsing_item_context.transition) |transition| context.current_slide.transition = transition;
                    context.template_instance_base_open = true;
                }
            } else {
                const errmsg = try std.fmt.allocPrint(context.allocator, "cannot @popslide `{s}` : was not pushed!", .{context_name});
                reportErrorInParsingContext(ParserError.Syntax, parsing_item_context, context, errmsg);
            }
            // new slide, clear the current item context
            context.current_context = .{};
            context.active_morph_state = null;
        }
        return;
    }

    if (std.mem.eql(u8, parsing_item_context.directive, "@slide")) {
        context.template_instance_base_open = false;
        // emit the current slide (if present) into the slideshow
        // then create a new slide (NOT deiniting the current one) with the **parsing** context's overrides
        // and make it the current slide
        // after that, clear the current item context
        if (context.first_slide_emitted) {
            try validateCurrentMorphIds(context, parsing_item_context);
            var previous_slide_context = parsing_item_context.*;
            previous_slide_context.transition = null;
            context.current_slide.applyContext(&previous_slide_context); // ignore the new slide's transition
            try context.slideshow.slides.append(context.allocator, context.current_slide);
        }
        context.first_slide_emitted = true;

        context.current_slide = try slides.Slide.new(context.allocator);
        context.current_slide.pos_in_editor = parsing_item_context.line_offset; //context.parsed_line_offset;
        context.current_slide.line_in_editor = parsing_item_context.line_number; // context.parsed_line_number;
        context.current_slide.applyContext(parsing_item_context);
        context.current_context = .{}; // clear the current item context, to start fresh in each new slide
        context.active_morph_state = null;
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

    if (std.mem.eql(u8, parsing_item_context.directive, "@crowd")) {
        if (context.active_morph_state != null) {
            reportErrorInParsingContext(
                ParserError.Syntax,
                parsing_item_context,
                context,
                "@crowd must be declared before the first @state(morph); use @set/@show/@hide to morph it",
            );
            return;
        }
        try finalizeCrowdSpec(parsing_item_context, context);
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
    if (std.mem.eql(u8, parsing_item_context.directive, "@pop") and parsing_item_context.id == null) {
        parsing_item_context.id = parsing_item_context.context_name;
    }
    slide_item.applyContext(parsing_item_context.*);
    slide_item.source = .{
        .scope = if (parser_context.active_morph_state != null)
            .morph_item
        else if (std.mem.eql(u8, parsing_item_context.directive, "@pop"))
            .component_instance
        else
            .direct,
        .line_number = parsing_item_context.line_number,
        .line_offset = parsing_item_context.line_offset,
        .patchable = parsing_item_context.source_patchable,
    };
    slide_item.creation_morph_state = parser_context.active_morph_state;
    if (parser_context.active_morph_state != null and slide_item.animation != null) {
        reportErrorInParsingContext(ParserError.Syntax, parsing_item_context, parser_context, "items born inside morph states animate as part of the state; anim= is not valid here");
        slide_item.animation = null;
    }
    slide_item.identity = parser_context.current_slide.next_item_identity;
    parser_context.current_slide.next_item_identity += 1;
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
    if (std.mem.eql(u8, parsing_item_context.directive, "@crowd")) {
        slide_item.kind = .crowd;
        // Resolve omitted geometry before morph snapshots are cloned. Doing
        // this during drawing would make interpolation start from raw zeros
        // instead of the panel the audience actually saw.
        if (!parsing_item_context.has_x) slide_item.position.x = slides.crowd_default_position.x;
        if (!parsing_item_context.has_y) slide_item.position.y = slides.crowd_default_position.y;
        if (!parsing_item_context.has_w or slide_item.size.x <= 0) slide_item.size.x = slides.crowd_default_size.x;
        if (!parsing_item_context.has_h or slide_item.size.y <= 0) slide_item.size.y = slides.crowd_default_size.y;
    }
    if (slide_item.kind == .crowd) {
        for (parser_context.current_slide.items.?.items) |existing| {
            if (existing.kind == .crowd) {
                reportErrorInParsingContext(ParserError.Syntax, parsing_item_context, parser_context, "a slide can contain only one @crowd item");
                return ParserError.Syntax;
            }
        }
        const crowd = slide_item.crowd.?;
        if (crowd.kind == .poll) {
            for (parser_context.slideshow.slides.items) |existing_slide| {
                if (existing_slide.items) |existing_items| {
                    for (existing_items.items) |existing| {
                        const existing_crowd = existing.crowd orelse continue;
                        if (existing_crowd.kind == .poll and std.mem.eql(u8, existing_crowd.id, crowd.id)) {
                            reportErrorInParsingContext(ParserError.Syntax, parsing_item_context, parser_context, "@crowd poll id= must be unique across the deck");
                            return ParserError.Syntax;
                        }
                    }
                }
            }
        }
    }
    slide_item.sanityCheck() catch |err| {
        reportErrorInParsingContext(err, parsing_item_context, parser_context, "item sanity check failed");
        return err;
    };
    // log.info("\n\n\n ADDING {s} as {any}", .{ parsing_item_context.directive, slide_item.kind });
    try parser_context.current_slide.currentItems(parser_context.active_morph_state).append(parser_context.allocator, slide_item.*);
    return slide_item; // just FYI
}

fn finalizeCrowdSpec(item_context: *slides.ItemContext, parser_context: *ParserContext) !void {
    var crowd = item_context.crowd orelse return ParserError.Syntax;
    const body = std.mem.trim(u8, item_context.text orelse "", " \t\r\n");

    if (crowd.kind == .join) {
        crowd.prompt = if (body.len > 0) body else "Join the room";
        item_context.crowd = crowd;
        return;
    }

    var choices = std.ArrayList([]const u8).empty;
    defer choices.deinit(parser_context.allocator);
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "- ")) {
            const choice = std.mem.trim(u8, line[2..], " \t");
            if (choice.len > 0) try choices.append(parser_context.allocator, choice);
        } else if (crowd.prompt.len == 0) {
            crowd.prompt = line;
        } else {
            reportErrorInParsingContext(ParserError.Syntax, item_context, parser_context, "poll choices must start with `- `");
        }
    }
    crowd.choices = try choices.toOwnedSlice(parser_context.allocator);
    item_context.crowd = crowd;
}

test "speaker notes are private slide-level multiline content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const slideshow = try slides.SlideShow.new(allocator);

    const input =
        "@slide\n" ++
        "@box text=Visible\n" ++
        "@notes\n" ++
        "Open with the customer story.\n" ++
        "\n" ++
        "# This is a note, not a source comment.\n" ++
        "@slide is source to mention, not a directive here.\n" ++
        "@endnotes\n" ++
        "@slide\n" ++
        "@box text=Second\n";
    const context = try constructSlidesFromBuf(input, slideshow, allocator);
    defer context.deinit();

    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    try std.testing.expectEqual(@as(usize, 2), slideshow.slides.items.len);
    try std.testing.expectEqualStrings(
        "Open with the customer story.\n\n# This is a note, not a source comment.\n@slide is source to mention, not a directive here.",
        slideshow.slides.items[0].speaker_notes.?,
    );
    try std.testing.expectEqual(std.mem.indexOf(u8, input, "@notes").?, slideshow.slides.items[0].speaker_notes_source.?.line_offset);
    try std.testing.expect(slideshow.slides.items[1].speaker_notes == null);
    try std.testing.expectEqual(@as(usize, 1), slideshow.slides.items[0].items.?.items.len);
}

test "malformed and duplicate speaker-note blocks report parser errors" {
    const cases = [_][]const u8{
        "@slide\n@endnotes\n",
        "@slide\n@notes extra\nText\n@endnotes\n",
        "@slide\n@notes\nUnclosed\n",
        "@slide\n@notes\nOne\n@endnotes\n@notes\nTwo\n@endnotes\n",
        "@slide\n@notes\nTemplate note\n@endnotes\n@pushslide template\n",
    };
    for (cases) |input| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const slideshow = try slides.SlideShow.new(allocator);
        const context = try constructSlidesFromBuf(input, slideshow, allocator);
        defer context.deinit();
        try std.testing.expect(context.parser_errors.items.len > 0);
    }
}

test "animation annotations and slide transitions are parsed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const slideshow = try slides.SlideShow.new(allocator);

    const input =
        \\@bg color=#101010ff
        \\@pushslide content transition=fade duration=0.6
        \\@popslide content transition=slide-left duration=0.5
        \\@anim(fade) by=bullet after=1.0 duration=0.2
        \\@box x=100 y=100 w=800 h=600
        \\Always visible
        \\- First reveal
        \\- Second reveal
        \\@anim slide-up duration=0.4
        \\@box img=assets/example.png x=100 y=100
        \\@popslide content
        \\@box x=100 y=100 w=800 h=600 anim=slide-right duration=0.1
        \\Second slide
    ;

    const context = try constructSlidesFromBuf(input, slideshow, allocator);
    defer context.deinit();

    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    try std.testing.expectEqual(@as(usize, 2), slideshow.slides.items.len);
    const slide = slideshow.slides.items[0];
    try std.testing.expectEqual(animation.Effect.slide_left, slide.transition.effect);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), slide.transition.duration, 0.0001);
    try std.testing.expectEqual(@as(usize, 3), slide.items.?.items.len);

    const bullets = slide.items.?.items[1].animation.?;
    try std.testing.expectEqual(animation.Effect.fade, bullets.effect);
    try std.testing.expectEqual(animation.Grouping.bullet, bullets.by);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), bullets.after.?, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), bullets.duration, 0.0001);

    const image = slide.items.?.items[2].animation.?;
    try std.testing.expectEqual(animation.Effect.slide_up, image.effect);
    try std.testing.expectEqual(animation.Grouping.item, image.by);

    const second_slide = slideshow.slides.items[1];
    try std.testing.expectEqual(animation.Effect.fade, second_slide.transition.effect);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), second_slide.transition.duration, 0.0001);
    const inline_animation = second_slide.items.?.items[1].animation.?;
    try std.testing.expectEqual(animation.Effect.slide_right, inline_animation.effect);
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), inline_animation.duration, 0.0001);
}

test "inline text preserves equals signs after text attribute" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const slideshow = try slides.SlideShow.new(allocator);

    const input =
        \\@slide
        \\@box text=`id=hero_image`
        \\@box text=`@set hero_image x=0 w=1920`
    ;

    const context = try constructSlidesFromBuf(input, slideshow, allocator);
    defer context.deinit();

    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    const items = slideshow.slides.items[0].items.?.items;
    try std.testing.expectEqualStrings("`id=hero_image`", items[0].text.?);
    try std.testing.expectEqualStrings("`@set hero_image x=0 w=1920`", items[1].text.?);
}

test "text shadows inherit from item templates and can be disabled" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const slideshow = try slides.SlideShow.new(allocator);

    const input =
        \\@push title x=100 y=100 w=800 h=200 shadow=#01020380 shadow_offset=2 shadow_y=3
        \\@slide
        \\@pop title text=Shadowed
        \\@pop title shadow=none text=Plain
    ;

    const context = try constructSlidesFromBuf(input, slideshow, allocator);
    defer context.deinit();

    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    try std.testing.expectEqual(@as(usize, 1), slideshow.slides.items.len);
    const items = slideshow.slides.items[0].items.?.items;
    try std.testing.expectEqual(@as(usize, 2), items.len);

    const inherited = items[0].text_shadow.?;
    try std.testing.expect(inherited.enabled);
    try std.testing.expectEqual(@as(u8, 1), inherited.color.r);
    try std.testing.expectEqual(@as(u8, 2), inherited.color.g);
    try std.testing.expectEqual(@as(u8, 3), inherited.color.b);
    try std.testing.expectEqual(@as(u8, 128), inherited.color.a);
    try std.testing.expectApproxEqAbs(@as(f32, 2), inherited.offset.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 3), inherited.offset.y, 0.0001);
    try std.testing.expect(!items[1].text_shadow.?.enabled);
}
test "crowd join and multiline poll directives are parsed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const slideshow = try slides.SlideShow.new(allocator);

    const input =
        \\@slide
        \\@crowd join x=120 y=90 w=1680 h=900
        \\Point your camera here
        \\@slide
        \\@crowd poll id=architecture open=false x=160 y=120 w=1600 h=840
        \\What should we build next?
        \\- A tiny compiler
        \\- A moon base
        \\- Both, obviously
    ;

    const context = try constructSlidesFromBuf(input, slideshow, allocator);
    defer context.deinit();

    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    try std.testing.expectEqual(@as(usize, 2), slideshow.slides.items.len);

    const join = slideshow.slides.items[0].items.?.items[0];
    try std.testing.expectEqual(slides.SlideItemKind.crowd, join.kind);
    try std.testing.expectEqual(slides.CrowdKind.join, join.crowd.?.kind);
    try std.testing.expectEqualStrings("Point your camera here", join.crowd.?.prompt);

    const poll = slideshow.slides.items[1].items.?.items[0];
    try std.testing.expectEqual(slides.SlideItemKind.crowd, poll.kind);
    try std.testing.expectEqual(slides.CrowdKind.poll, poll.crowd.?.kind);
    try std.testing.expectEqualStrings("architecture", poll.crowd.?.id);
    try std.testing.expectEqualStrings("What should we build next?", poll.crowd.?.prompt);
    try std.testing.expect(!poll.crowd.?.initially_open);
    try std.testing.expectEqual(@as(usize, 3), poll.crowd.?.choices.len);
    try std.testing.expectEqualStrings("A moon base", poll.crowd.?.choices[1]);
}

test "invalid crowd polls report parser errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const slideshow = try slides.SlideShow.new(allocator);

    const input =
        \\@crowd poll
        \\Missing an id and enough choices
        \\- Lonely choice
    ;

    const context = try constructSlidesFromBuf(input, slideshow, allocator);
    defer context.deinit();
    try std.testing.expect(context.parser_errors.items.len >= 1);
}

test "malformed crowd directives do not recommit the previous item" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const slideshow = try slides.SlideShow.new(allocator);

    const input =
        \\@slide
        \\@box text=Safe
        \\@crowd wat
        \\orphaned text
        \\@slide
        \\@box text=Next
    ;

    const context = try constructSlidesFromBuf(input, slideshow, allocator);
    defer context.deinit();
    try std.testing.expect(context.parser_errors.items.len >= 1);
    try std.testing.expectEqual(@as(usize, 2), slideshow.slides.items.len);
    try std.testing.expectEqual(@as(usize, 1), slideshow.slides.items[0].items.?.items.len);
    try std.testing.expectEqualStrings("Safe", slideshow.slides.items[0].items.?.items[0].text.?);
}

test "crowd defaults and live spec survive semantic geometry morphs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const slideshow = try slides.SlideShow.new(allocator);

    const input =
        \\@slide
        \\@crowd poll id=audience
        \\Which path should we take?
        \\- Build it
        \\- Ship it
        \\@state(morph) duration=1.2
        \\@set audience x=300 w=1300 opacity=0.8
    ;

    const context = try constructSlidesFromBuf(input, slideshow, allocator);
    defer context.deinit();

    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    const slide = slideshow.slides.items[0];
    try std.testing.expectEqualStrings("audience", slide.items.?.items[0].crowd.?.id);
    try std.testing.expectEqualStrings("audience", slide.items.?.items[0].id.?);
    try std.testing.expectEqual(slides.crowd_default_position, slide.items.?.items[0].position);
    try std.testing.expectEqual(slides.crowd_default_size, slide.items.?.items[0].size);
    const morphed = slide.morph_states.items[0].items.items[0];
    try std.testing.expectEqual(slides.SlideItemKind.crowd, morphed.kind);
    try std.testing.expectEqualStrings("audience", morphed.crowd.?.id);
    try std.testing.expectApproxEqAbs(@as(f32, 300), morphed.position.x, 0.0001);
    try std.testing.expectApproxEqAbs(slides.crowd_default_position.y, morphed.position.y, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1300), morphed.size.x, 0.0001);
    try std.testing.expectApproxEqAbs(slides.crowd_default_size.y, morphed.size.y, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), morphed.opacity, 0.0001);
}

test "crowd items cannot be born inside a morph state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const slideshow = try slides.SlideShow.new(allocator);

    const input =
        \\@slide
        \\@box id=anchor text=Anchor
        \\@state(morph)
        \\@crowd join id=late
        \\Join late
    ;

    const context = try constructSlidesFromBuf(input, slideshow, allocator);
    defer context.deinit();

    try std.testing.expectEqual(@as(usize, 1), context.parser_errors.items.len);
    try std.testing.expectEqual(@as(usize, 1), slideshow.slides.items[0].morph_states.items[0].items.items.len);
}

test "semantic morph states are cumulative reversible snapshots" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const slideshow = try slides.SlideShow.new(allocator);

    const input =
        \\@push title x=100 y=80 w=900 h=120 fontsize=64 color=#ffffffff shadow=#010203ff shadow_x=2 shadow_y=3
        \\@slide
        \\@box id=hero img=assets/example.png x=1200 y=200 w=500 h=300 opacity=0.8
        \\@pop title y=90 text=Persistent title
        \\@state(morph) label=focus duration=0.75 ease=spring after=0.5
        \\@set hero x=0 y=0 w=1920 h=1080 opacity=1
        \\@hide title shadow_x=9
        \\@box id=caption x=100 y=900 w=1500 h=100 text=Born in state one
        \\@state duration=0.4 ease=linear
        \\@set hero x=200
        \\@show title y=40 color=#010203ff
        \\@set caption opacity=0.25
    ;

    const context = try constructSlidesFromBuf(input, slideshow, allocator);
    defer context.deinit();

    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    try std.testing.expectEqual(@as(usize, 1), slideshow.slides.items.len);
    const slide = slideshow.slides.items[0];
    try std.testing.expectEqual(@as(usize, 2), slide.items.?.items.len);
    try std.testing.expectEqual(@as(usize, 2), slide.morph_states.items.len);

    const base_hero = slide.items.?.items[0];
    try std.testing.expectEqual(@as(?usize, null), base_hero.creation_morph_state);
    try std.testing.expectApproxEqAbs(@as(f32, 100), slide.items.?.items[1].position.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 90), slide.items.?.items[1].position.y, 0.0001);
    const state_one = slide.morph_states.items[0];
    try std.testing.expectEqualStrings("focus", state_one.spec.label.?);
    try std.testing.expectEqual(animation.Easing.spring, state_one.spec.easing);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), state_one.spec.duration, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), state_one.spec.after.?, 0.0001);
    try std.testing.expectEqual(@as(usize, 3), state_one.items.items.len);
    try std.testing.expectEqual(base_hero.identity, state_one.items.items[0].identity);
    try std.testing.expectApproxEqAbs(@as(f32, 0), state_one.items.items[0].position.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), state_one.items.items[0].position.y, 0.0001);
    try std.testing.expect(!state_one.items.items[1].visible);
    try std.testing.expectEqual(@as(u8, 1), state_one.items.items[1].text_shadow.?.color.r);
    try std.testing.expectApproxEqAbs(@as(f32, 9), state_one.items.items[1].text_shadow.?.offset.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 3), state_one.items.items[1].text_shadow.?.offset.y, 0.0001);
    try std.testing.expectEqual(@as(?usize, 0), state_one.items.items[2].creation_morph_state);

    const state_two = slide.morph_states.items[1];
    try std.testing.expect(state_two.spec.label == null);
    try std.testing.expectEqual(animation.Easing.linear, state_two.spec.easing);
    try std.testing.expectEqual(@as(usize, 3), state_two.items.items.len);
    try std.testing.expectApproxEqAbs(@as(f32, 200), state_two.items.items[0].position.x, 0.0001);
    // A sparse x-only patch keeps the y inherited from state one.
    try std.testing.expectApproxEqAbs(@as(f32, 0), state_two.items.items[0].position.y, 0.0001);
    try std.testing.expect(state_two.items.items[1].visible);
    try std.testing.expectApproxEqAbs(@as(f32, 100), state_two.items.items[1].position.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 40), state_two.items.items[1].position.y, 0.0001);
    try std.testing.expectEqual(@as(u8, 1), state_two.items.items[1].color.?.r);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), state_two.items.items[2].opacity, 0.0001);
    try std.testing.expectEqual(@as(?usize, 0), state_two.items.items[2].creation_morph_state);
}

test "semantic morph snapshots retain creation and effective state sources" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const slideshow = try slides.SlideShow.new(allocator);

    const input =
        \\@slide
        \\@box id=hero x=10 y=20 w=100 h=80 text=Hero
        \\@box id=steady x=30 y=40 w=120 h=90 text=Steady
        \\@state(morph)
        \\@set hero x=100
        \\@hide steady
        \\@state(morph)
        \\@show hero y=200
    ;

    const context = try constructSlidesFromBuf(input, slideshow, allocator);
    defer context.deinit();

    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    const slide = slideshow.slides.items[0];
    const base_hero = &slide.items.?.items[0];
    const base_steady = &slide.items.?.items[1];
    try std.testing.expect(base_hero.state_source == null);
    try std.testing.expect(base_steady.state_source == null);
    try std.testing.expectEqual(std.mem.indexOf(u8, input, "@box id=hero").?, base_hero.source.line_offset);
    try std.testing.expectEqual(base_hero.source.line_offset, base_hero.effectiveSource().line_offset);

    const state_one = slide.morph_states.items[0].items.items;
    try std.testing.expectEqual(@as(usize, 4), slide.morph_states.items[0].source.line_number);
    try std.testing.expectEqual(std.mem.indexOf(u8, input, "@state(morph)").?, slide.morph_states.items[0].source.line_offset);
    try std.testing.expect(slide.morph_states.items[0].source.patchable);
    try std.testing.expectEqual(base_hero.source.line_offset, state_one[0].source.line_offset);
    try std.testing.expectEqual(base_steady.source.line_offset, state_one[1].source.line_offset);
    try std.testing.expectEqual(slides.SourceScope.morph_item, state_one[0].state_source.?.scope);
    try std.testing.expectEqual(@as(?usize, 0), state_one[0].state_source_state);
    try std.testing.expectEqual(@as(?usize, 0), state_one[1].state_source_state);
    try std.testing.expect(state_one[0].state_source.?.patchable);
    try std.testing.expectEqual(@as(usize, 5), state_one[0].state_source.?.line_number);
    try std.testing.expectEqual(std.mem.indexOf(u8, input, "@set hero").?, state_one[0].effectiveSource().line_offset);
    try std.testing.expectEqual(std.mem.indexOf(u8, input, "@hide steady").?, state_one[1].effectiveSource().line_offset);

    const state_two = slide.morph_states.items[1].items.items;
    try std.testing.expectEqual(@as(usize, 7), slide.morph_states.items[1].source.line_number);
    try std.testing.expectEqual(base_hero.source.line_offset, state_two[0].source.line_offset);
    try std.testing.expectEqual(std.mem.indexOf(u8, input, "@show hero").?, state_two[0].effectiveSource().line_offset);
    try std.testing.expectEqual(@as(?usize, 1), state_two[0].state_source_state);
    // An item not touched in a later state keeps the directive that still
    // determines its effective state.
    try std.testing.expectEqual(state_one[1].effectiveSource().line_offset, state_two[1].effectiveSource().line_offset);
    try std.testing.expectEqual(@as(?usize, 0), state_two[1].state_source_state);
}

test "let-expanded semantic morph sources are read only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const slideshow = try slides.SlideShow.new(allocator);

    const input =
        "@let move=x=100 y=200\n" ++
        "@slide\n" ++
        "@box id=hero x=10 y=20 w=100 h=80 text=Hero\n" ++
        "@state(morph)\n" ++
        "@set hero $move$\n";

    const context = try constructSlidesFromBuf(input, slideshow, allocator);
    defer context.deinit();

    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    const item = slideshow.slides.items[0].morph_states.items[0].items.items[0];
    try std.testing.expect(item.state_source != null);
    try std.testing.expectEqual(slides.SourceScope.morph_item, item.state_source.?.scope);
    try std.testing.expectEqual(@as(?usize, 0), item.state_source_state);
    try std.testing.expect(!item.effectiveSource().patchable);
    try std.testing.expectEqual(std.mem.indexOf(u8, input, "@set hero").?, item.effectiveSource().line_offset);
    // Only the @set line is expanded. The literal @state directive remains a
    // safe insertion anchor for a later local Studio override.
    try std.testing.expect(slideshow.slides.items[0].morph_states.items[0].source.patchable);
}

test "semantic morph mutations report unknown and ambiguous targets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const slideshow = try slides.SlideShow.new(allocator);

    const input =
        \\@slide
        \\@box id=same x=0 y=0 w=100 h=100 text=One
        \\@box id=same x=100 y=0 w=100 h=100 text=Two
        \\@state(morph)
        \\@set same x=200
        \\@hide missing
    ;

    const context = try constructSlidesFromBuf(input, slideshow, allocator);
    defer context.deinit();
    try std.testing.expectEqual(@as(usize, 3), context.parser_errors.items.len);
}

test "malformed directive does not replay the preceding item" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const slideshow = try slides.SlideShow.new(allocator);

    const input =
        \\@slide
        \\@box id=hero x=10 y=20 w=100 h=80 text=Only once
        \\@state(wrong)
    ;

    const context = try constructSlidesFromBuf(input, slideshow, allocator);
    defer context.deinit();
    try std.testing.expectEqual(@as(usize, 1), context.parser_errors.items.len);
    try std.testing.expectEqual(@as(usize, 1), slideshow.slides.items.len);
    try std.testing.expectEqual(@as(usize, 1), slideshow.slides.items[0].items.?.items.len);
}

test "item templates merge sparse geometry and reject template ids" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const slideshow = try slides.SlideShow.new(allocator);

    const input =
        \\@push title id=wrong x=100 y=80 w=900 h=120
        \\@slide
        \\@pop title x=500 h=200 text=Sparse override
    ;

    const context = try constructSlidesFromBuf(input, slideshow, allocator);
    defer context.deinit();
    try std.testing.expectEqual(@as(usize, 1), context.parser_errors.items.len);
    const item = slideshow.slides.items[0].items.?.items[0];
    try std.testing.expectEqualStrings("title", item.id.?);
    try std.testing.expectApproxEqAbs(@as(f32, 500), item.position.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 80), item.position.y, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 900), item.size.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 200), item.size.y, 0.0001);
}

test "logical items retain directive source scope line and offset" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const slideshow = try slides.SlideShow.new(allocator);

    const input =
        \\@push title x=100 y=80 w=900 h=120
        \\@box id=template_box text=From template
        \\@pushslide content
        \\@popslide content
        \\@box id=direct text=Direct
        \\@pop title text=Component
    ;

    const context = try constructSlidesFromBuf(input, slideshow, allocator);
    defer context.deinit();

    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    try std.testing.expectEqual(@as(usize, 1), slideshow.slides.items.len);

    const direct = slideshow.slides.items[0].items.?.items[1];
    try std.testing.expectEqual(slides.SourceScope.direct, direct.source.scope);
    try std.testing.expect(direct.source.patchable);
    try std.testing.expectEqual(@as(usize, 5), direct.source.line_number);
    try std.testing.expectEqual(std.mem.indexOf(u8, input, "@box id=direct").?, direct.source.line_offset);

    const component = slideshow.slides.items[0].items.?.items[2];
    try std.testing.expectEqual(slides.SourceScope.component_instance, component.source.scope);
    try std.testing.expect(component.source.patchable);
    try std.testing.expectEqual(@as(usize, 6), component.source.line_number);
    try std.testing.expectEqual(std.mem.indexOf(u8, input, "@pop title text=Component").?, component.source.line_offset);
    try std.testing.expectEqual(slides.SourceScope.direct, component.component_source.?.scope);
    try std.testing.expect(component.component_source.?.patchable);
    try std.testing.expectEqual(@as(usize, 1), component.component_source.?.line_number);
    try std.testing.expectEqual(std.mem.indexOf(u8, input, "@push title").?, component.component_source.?.line_offset);

    const template_item = slideshow.slides.items[0].items.?.items[0];
    try std.testing.expectEqual(slides.SourceScope.slide_template, template_item.source.scope);
    try std.testing.expect(template_item.source.patchable);
    try std.testing.expectEqual(@as(usize, 2), template_item.source.line_number);
    try std.testing.expectEqual(std.mem.indexOf(u8, input, "@box id=template_box").?, template_item.source.line_offset);
}

test "BOM-aware provenance starts at the physical directive" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const slideshow = try slides.SlideShow.new(allocator);
    const input = "\xEF\xBB\xBF@slide\n@box x=10 y=20 w=100 h=50 text=BOM\n";

    const context = try constructSlidesFromBuf(input, slideshow, allocator);
    defer context.deinit();
    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    const item = slideshow.slides.items[0].items.?.items[0];
    try std.testing.expect(item.source.patchable);
    try std.testing.expectEqual(std.mem.indexOf(u8, input, "@box").?, item.source.line_offset);
}

test "let-expanded item directives are explicitly read-only provenance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const slideshow = try slides.SlideShow.new(allocator);
    const input =
        "@let body=text=Hello\n" ++
        "@slide\n" ++
        "@box x=10 y=20 w=100 h=50 $body$\n";

    const context = try constructSlidesFromBuf(input, slideshow, allocator);
    defer context.deinit();
    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    const item = slideshow.slides.items[0].items.?.items[0];
    try std.testing.expectEqual(slides.SourceScope.direct, item.source.scope);
    try std.testing.expect(!item.source.patchable);
    try std.testing.expectEqual(std.mem.indexOf(u8, input, "@box").?, item.source.line_offset);
}

test "morph states are rejected inside reusable slide templates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const slideshow = try slides.SlideShow.new(allocator);

    const input =
        \\@slide
        \\@box id=same x=0 y=0 w=100 h=100 text=One
        \\@box id=same x=100 y=0 w=100 h=100 text=Two
        \\@state(morph)
        \\@pushslide invalid
    ;

    const context = try constructSlidesFromBuf(input, slideshow, allocator);
    defer context.deinit();
    // Duplicate IDs are still validated before the active state is reset,
    // and the unsupported morphing template is reported separately.
    try std.testing.expectEqual(@as(usize, 2), context.parser_errors.items.len);
    try std.testing.expect(context.push_slides.get("invalid") == null);
}

test "slide template instances support local base set show and hide overrides" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const slideshow = try slides.SlideShow.new(allocator);

    const input =
        \\@box id=hero x=10 y=20 w=100 h=80 text=Hero
        \\@box id=caption x=30 y=40 w=120 h=90 visible=false text=Caption
        \\@box id=badge x=50 y=60 w=140 h=100 text=Badge
        \\@pushslide layout
        \\@popslide layout
        \\@set hero x=300 text=Local hero
        \\@show caption y=400
        \\@hide badge
    ;

    const context = try constructSlidesFromBuf(input, slideshow, allocator);
    defer context.deinit();

    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    try std.testing.expectEqual(@as(usize, 1), slideshow.slides.items.len);

    const template = context.push_slides.get("layout").?;
    try std.testing.expectApproxEqAbs(@as(f32, 10), template.items.?.items[0].position.x, 0.0001);
    try std.testing.expectEqualStrings("Hero", template.items.?.items[0].text.?);
    try std.testing.expect(!template.items.?.items[1].visible);
    try std.testing.expect(template.items.?.items[0].instance_source == null);

    const instance = slideshow.slides.items[0].items.?.items;
    try std.testing.expectApproxEqAbs(@as(f32, 300), instance[0].position.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 20), instance[0].position.y, 0.0001);
    try std.testing.expectEqualStrings("Local hero", instance[0].text.?);
    try std.testing.expect(instance[1].visible);
    try std.testing.expectApproxEqAbs(@as(f32, 400), instance[1].position.y, 0.0001);
    try std.testing.expect(!instance[2].visible);

    for (instance) |item| try std.testing.expectEqual(slides.SourceScope.slide_template, item.source.scope);
    try std.testing.expectEqual(slides.SourceScope.slide_instance_override, instance[0].instance_source.?.scope);
    try std.testing.expectEqual(@as(usize, 6), instance[0].instance_source.?.line_number);
    try std.testing.expectEqual(std.mem.indexOf(u8, input, "@set hero").?, instance[0].effectiveBaseSource().line_offset);
    try std.testing.expectEqual(std.mem.indexOf(u8, input, "@show caption").?, instance[1].effectiveBaseSource().line_offset);
    try std.testing.expectEqual(std.mem.indexOf(u8, input, "@hide badge").?, instance[2].effectiveSource().line_offset);
    try std.testing.expect(instance[0].effectiveBaseSource().patchable);
}

test "morph states inherit instance base overrides and layer state overrides" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const slideshow = try slides.SlideShow.new(allocator);

    const input =
        \\@box id=hero x=10 y=20 w=100 h=80 text=Hero
        \\@box id=caption x=30 y=40 w=120 h=90 text=Caption
        \\@pushslide layout
        \\@popslide layout
        \\@set hero x=100
        \\@hide caption
        \\@state(morph)
        \\@set hero y=200
        \\@state(morph)
        \\@show caption x=300
    ;

    const context = try constructSlidesFromBuf(input, slideshow, allocator);
    defer context.deinit();

    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    const slide = slideshow.slides.items[0];
    try std.testing.expectEqual(@as(usize, 2), slide.morph_states.items.len);
    const base = slide.items.?.items;
    try std.testing.expectApproxEqAbs(@as(f32, 100), base[0].position.x, 0.0001);
    try std.testing.expect(!base[1].visible);

    const first = slide.morph_states.items[0].items.items;
    try std.testing.expectApproxEqAbs(@as(f32, 100), first[0].position.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 200), first[0].position.y, 0.0001);
    try std.testing.expectEqual(std.mem.indexOf(u8, input, "@set hero x=100").?, first[0].effectiveBaseSource().line_offset);
    try std.testing.expectEqual(std.mem.indexOf(u8, input, "@set hero y=200").?, first[0].effectiveSource().line_offset);
    try std.testing.expect(!first[1].visible);
    try std.testing.expect(first[1].state_source == null);
    try std.testing.expectEqual(std.mem.indexOf(u8, input, "@hide caption").?, first[1].effectiveSource().line_offset);

    const second = slide.morph_states.items[1].items.items;
    try std.testing.expectApproxEqAbs(@as(f32, 100), second[0].position.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 200), second[0].position.y, 0.0001);
    try std.testing.expectEqual(@as(?usize, 0), second[0].state_source_state);
    try std.testing.expect(second[1].visible);
    try std.testing.expectApproxEqAbs(@as(f32, 300), second[1].position.x, 0.0001);
    try std.testing.expectEqual(@as(?usize, 1), second[1].state_source_state);
    try std.testing.expectEqual(std.mem.indexOf(u8, input, "@show caption").?, second[1].effectiveSource().line_offset);
}

test "base mutations require a live slide-template instance and inherited target" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const slideshow = try slides.SlideShow.new(allocator);

    const input =
        \\@box id=inherited x=10 y=20 w=100 h=80 text=Inherited
        \\@pushslide layout
        \\@popslide layout
        \\@box id=local x=1 y=2 w=3 h=4 text=Decoration
        \\@set inherited x=50
        \\@set local x=60
        \\@slide
        \\@box id=direct x=5 y=6 w=7 h=8 text=Direct
        \\@set direct x=70
    ;

    const context = try constructSlidesFromBuf(input, slideshow, allocator);
    defer context.deinit();

    try std.testing.expectEqual(@as(usize, 2), context.parser_errors.items.len);
    try std.testing.expectEqual(@as(usize, 2), slideshow.slides.items.len);
    const instance = slideshow.slides.items[0].items.?.items;
    try std.testing.expectApproxEqAbs(@as(f32, 50), instance[0].position.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1), instance[1].position.x, 0.0001);
    try std.testing.expect(instance[1].instance_source == null);
    try std.testing.expectApproxEqAbs(@as(f32, 5), slideshow.slides.items[1].items.?.items[0].position.x, 0.0001);
}

test "instance base mutations reject missing and duplicate ids" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const slideshow = try slides.SlideShow.new(allocator);

    const input =
        \\@box id=same x=0 y=0 w=100 h=100 text=One
        \\@box id=same x=100 y=0 w=100 h=100 text=Two
        \\@pushslide layout
        \\@popslide layout
        \\@set same x=200
        \\@hide missing
    ;

    const context = try constructSlidesFromBuf(input, slideshow, allocator);
    defer context.deinit();

    try std.testing.expectEqual(@as(usize, 2), context.parser_errors.items.len);
    const items = slideshow.slides.items[0].items.?.items;
    try std.testing.expectApproxEqAbs(@as(f32, 0), items[0].position.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 100), items[1].position.x, 0.0001);
    try std.testing.expect(items[0].instance_source == null);
    try std.testing.expect(items[1].instance_source == null);
}

test "let-expanded instance override provenance is read only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const slideshow = try slides.SlideShow.new(allocator);

    const input =
        "@let move=x=100 y=200\n" ++
        "@box id=hero x=10 y=20 w=100 h=80 text=Hero\n" ++
        "@pushslide layout\n" ++
        "@popslide layout\n" ++
        "@set hero $move$\n";

    const context = try constructSlidesFromBuf(input, slideshow, allocator);
    defer context.deinit();

    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    const item = slideshow.slides.items[0].items.?.items[0];
    try std.testing.expectApproxEqAbs(@as(f32, 100), item.position.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 200), item.position.y, 0.0001);
    try std.testing.expectEqual(slides.SourceScope.slide_template, item.source.scope);
    try std.testing.expect(item.source.patchable);
    try std.testing.expectEqual(slides.SourceScope.slide_instance_override, item.instance_source.?.scope);
    try std.testing.expect(!item.effectiveBaseSource().patchable);
    try std.testing.expectEqual(std.mem.indexOf(u8, input, "@set hero").?, item.effectiveBaseSource().line_offset);
}

test "pending item animation rejects an instance mutation and does not leak" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const slideshow = try slides.SlideShow.new(allocator);

    const input =
        \\@box id=hero x=10 y=20 w=100 h=80 text=Hero
        \\@pushslide layout
        \\@popslide layout
        \\@anim fade
        \\@set hero x=200
        \\@box id=decoration x=1 y=2 w=3 h=4 text=Decoration
    ;

    const context = try constructSlidesFromBuf(input, slideshow, allocator);
    defer context.deinit();

    try std.testing.expectEqual(@as(usize, 1), context.parser_errors.items.len);
    const items = slideshow.slides.items[0].items.?.items;
    try std.testing.expectApproxEqAbs(@as(f32, 10), items[0].position.x, 0.0001);
    try std.testing.expect(items[0].instance_source == null);
    try std.testing.expect(items[1].animation == null);
}

test "nested slide templates promote captured instance overrides to shared provenance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const slideshow = try slides.SlideShow.new(allocator);

    const input =
        \\@box id=hero x=10 y=20 w=100 h=80 text=Original
        \\@pushslide first
        \\@popslide first
        \\@set hero x=100 text=Captured
        \\@pushslide second
        \\@popslide second
        \\@set hero x=200
    ;

    const context = try constructSlidesFromBuf(input, slideshow, allocator);
    defer context.deinit();

    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    const captured = context.push_slides.get("second").?.items.?.items[0];
    try std.testing.expectApproxEqAbs(@as(f32, 100), captured.position.x, 0.0001);
    try std.testing.expectEqualStrings("Captured", captured.text.?);
    try std.testing.expectEqual(slides.SourceScope.slide_template, captured.source.scope);
    try std.testing.expectEqual(std.mem.indexOf(u8, input, "@set hero x=100").?, captured.source.line_offset);
    try std.testing.expect(captured.instance_source == null);

    // Capturing `second` closes the in-progress first instance, leaving the
    // parser's historical empty boundary slide before the rendered clone.
    const rendered = slideshow.slides.items[1].items.?.items[0];
    try std.testing.expectApproxEqAbs(@as(f32, 200), rendered.position.x, 0.0001);
    try std.testing.expectEqual(std.mem.indexOf(u8, input, "@set hero x=100").?, rendered.source.line_offset);
    try std.testing.expectEqual(std.mem.indexOf(u8, input, "@set hero x=200").?, rendered.instance_source.?.line_offset);
}

test "crowd text mutations rebuild the renderer-facing prompt" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const slideshow = try slides.SlideShow.new(allocator);

    const input =
        \\@crowd join id=audience
        \\Shared invitation
        \\@pushslide room
        \\@popslide room
        \\@set audience
        \\Local invitation
        \\@state(morph)
        \\@set audience
        \\Morph invitation
        \\@popslide room
    ;

    const context = try constructSlidesFromBuf(input, slideshow, allocator);
    defer context.deinit();

    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    try std.testing.expectEqualStrings("Shared invitation", context.push_slides.get("room").?.items.?.items[0].crowd.?.prompt);
    try std.testing.expectEqualStrings("Local invitation", slideshow.slides.items[0].items.?.items[0].crowd.?.prompt);
    try std.testing.expectEqualStrings("Morph invitation", slideshow.slides.items[0].morph_states.items[0].items.items[0].crowd.?.prompt);
    try std.testing.expectEqualStrings("Shared invitation", slideshow.slides.items[1].items.?.items[0].crowd.?.prompt);
}

test "item backgrounds inherit and support local and morph set or clear mutations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const slideshow = try slides.SlideShow.new(allocator);

    const input =
        \\@box id=hero x=10 y=20 w=300 h=100 color=#112233ff bg=#203040ff text=Hero
        \\@pushslide layout
        \\@popslide layout
        \\@set hero bg=#50607080
        \\@state(morph)
        \\@set hero bg=none
        \\@popslide layout
    ;

    const context = try constructSlidesFromBuf(input, slideshow, allocator);
    defer context.deinit();

    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    const template_item = context.push_slides.get("layout").?.items.?.items[0];
    try std.testing.expectEqual(@as(u8, 0x20), template_item.background_color.?.r);
    try std.testing.expectEqual(@as(u8, 0x40), template_item.background_color.?.b);
    try std.testing.expectEqual(@as(u8, 0x20), template_item.sharedTemplateValues().?.background_color.?.r);

    const instance = slideshow.slides.items[0];
    try std.testing.expectEqual(@as(u8, 0x50), instance.items.?.items[0].background_color.?.r);
    try std.testing.expectEqual(@as(u8, 0x80), instance.items.?.items[0].background_color.?.a);
    try std.testing.expect(instance.morph_states.items[0].items.items[0].background_color == null);
    // Neither local mutation changes the captured template layer.
    try std.testing.expectEqual(
        @as(u8, 0x20),
        instance.morph_states.items[0].items.items[0].sharedTemplateValues().?.background_color.?.r,
    );
}

test "slide-template text and image property layers preserve shared font size and opacity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const slideshow = try slides.SlideShow.new(allocator);

    const input =
        \\@box id=caption x=10 y=20 w=500 h=120 fontsize=40 color=#112233ff bg=#203040ff opacity=0.9 text=Shared
        \\@box id=photo img=assets/example.png x=600 y=20 w=320 h=200 fontsize=30 color=#213243ff bg=#304050ff opacity=0.8
        \\@pushslide layout
        \\@popslide layout
        \\@set caption fontsize=50 color=#405060ff bg=none opacity=0.7
        \\@set photo fontsize=35 color=#506070ff bg=#607080ff opacity=0.6
        \\@state(morph)
        \\@set caption fontsize=60 color=#708090ff bg=#8090a0ff opacity=0.5
        \\@set photo fontsize=45 color=#90a0b0ff bg=none opacity=0.4
    ;

    const context = try constructSlidesFromBuf(input, slideshow, allocator);
    defer context.deinit();

    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);

    const template_items = context.push_slides.get("layout").?.items.?.items;
    try std.testing.expectEqual(@as(?i32, 40), template_items[0].fontSize);
    try std.testing.expectEqual(@as(?i32, 40), template_items[0].sharedTemplateValues().?.font_size);
    try std.testing.expectApproxEqAbs(@as(f32, 0.9), template_items[0].sharedTemplateValues().?.opacity, 0.0001);
    try std.testing.expectEqual(@as(?i32, 30), template_items[1].fontSize);
    try std.testing.expectEqual(@as(?i32, 30), template_items[1].sharedTemplateValues().?.font_size);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), template_items[1].sharedTemplateValues().?.opacity, 0.0001);

    const instance = slideshow.slides.items[0];
    const local_caption = instance.items.?.items[0];
    const local_photo = instance.items.?.items[1];
    try std.testing.expectEqual(@as(?i32, 50), local_caption.fontSize);
    try std.testing.expectApproxEqAbs(@as(f32, 0.7), local_caption.opacity, 0.0001);
    try std.testing.expectEqual(@as(u8, 0x40), local_caption.color.?.r);
    try std.testing.expect(local_caption.background_color == null);
    try std.testing.expectEqual(@as(?i32, 40), local_caption.sharedTemplateValues().?.font_size);
    try std.testing.expectApproxEqAbs(@as(f32, 0.9), local_caption.sharedTemplateValues().?.opacity, 0.0001);
    try std.testing.expectEqual(@as(?i32, 35), local_photo.fontSize);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), local_photo.opacity, 0.0001);
    try std.testing.expectEqual(@as(u8, 0x50), local_photo.color.?.r);
    try std.testing.expectEqual(@as(u8, 0x60), local_photo.background_color.?.r);
    try std.testing.expectEqual(@as(?i32, 30), local_photo.sharedTemplateValues().?.font_size);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), local_photo.sharedTemplateValues().?.opacity, 0.0001);

    const morphed = instance.morph_states.items[0].items.items;
    try std.testing.expectEqual(@as(?i32, 60), morphed[0].fontSize);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), morphed[0].opacity, 0.0001);
    try std.testing.expectEqual(@as(u8, 0x70), morphed[0].color.?.r);
    try std.testing.expectEqual(@as(u8, 0x80), morphed[0].background_color.?.r);
    try std.testing.expectEqual(@as(?i32, 40), morphed[0].sharedTemplateValues().?.font_size);
    try std.testing.expectApproxEqAbs(@as(f32, 0.9), morphed[0].sharedTemplateValues().?.opacity, 0.0001);
    try std.testing.expectEqual(@as(?i32, 45), morphed[1].fontSize);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), morphed[1].opacity, 0.0001);
    try std.testing.expectEqual(@as(u8, 0x90), morphed[1].color.?.r);
    try std.testing.expect(morphed[1].background_color == null);
    try std.testing.expectEqual(@as(?i32, 30), morphed[1].sharedTemplateValues().?.font_size);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), morphed[1].sharedTemplateValues().?.opacity, 0.0001);
}

test "nested slide templates refresh and preserve their shared authored value layer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const slideshow = try slides.SlideShow.new(allocator);

    const input =
        \\@box id=hero x=10 y=20 w=300 h=100 fontsize=36 color=#112233ff bg=#203040ff opacity=0.8 text=Original
        \\@pushslide first
        \\@popslide first
        \\@set hero x=100 fontsize=44 color=#405060ff bg=none opacity=0.6 text=Captured
        \\@hide hero
        \\@pushslide second
        \\@popslide second
        \\@set hero y=200 fontsize=52 color=#708090ff bg=#90a0b0ff text=Local
        \\@show hero
        \\@state(morph)
        \\@set hero x=300 fontsize=60 color=#a0b0c0ff bg=none opacity=0.2 text=Morph
    ;

    const context = try constructSlidesFromBuf(input, slideshow, allocator);
    defer context.deinit();

    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);

    const first = context.push_slides.get("first").?.items.?.items[0];
    const first_values = first.sharedTemplateValues().?;
    try std.testing.expectApproxEqAbs(@as(f32, 10), first_values.position.x, 0.0001);
    try std.testing.expectEqualStrings("Original", first_values.text.?);
    try std.testing.expectEqual(@as(?i32, 36), first_values.font_size);
    try std.testing.expectEqual(@as(u8, 0x11), first_values.color.?.r);
    try std.testing.expectEqual(@as(u8, 0x20), first_values.background_color.?.r);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), first_values.opacity, 0.0001);
    try std.testing.expect(first_values.visible);

    const second = context.push_slides.get("second").?.items.?.items[0];
    const captured_values = second.sharedTemplateValues().?;
    try std.testing.expectApproxEqAbs(@as(f32, 100), captured_values.position.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 20), captured_values.position.y, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 300), captured_values.size.x, 0.0001);
    try std.testing.expectEqualStrings("Captured", captured_values.text.?);
    try std.testing.expectEqual(@as(?i32, 44), captured_values.font_size);
    try std.testing.expectEqual(@as(u8, 0x40), captured_values.color.?.r);
    try std.testing.expect(captured_values.background_color == null);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), captured_values.opacity, 0.0001);
    try std.testing.expect(!captured_values.visible);
    try std.testing.expectEqual(
        std.mem.indexOf(u8, input, "@hide hero").?,
        second.source.line_offset,
    );

    // Later instance and morph patches change only effective values. Both
    // cumulative layers retain the nested template's captured authored data.
    const rendered = slideshow.slides.items[1];
    const local = rendered.items.?.items[0];
    try std.testing.expectApproxEqAbs(@as(f32, 100), local.position.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 200), local.position.y, 0.0001);
    try std.testing.expectEqualStrings("Local", local.text.?);
    try std.testing.expectEqual(@as(?i32, 52), local.fontSize);
    try std.testing.expect(local.visible);
    try std.testing.expectEqual(@as(u8, 0x90), local.background_color.?.r);
    try std.testing.expectEqualStrings("Captured", local.sharedTemplateValues().?.text.?);
    try std.testing.expectEqual(@as(?i32, 44), local.sharedTemplateValues().?.font_size);
    try std.testing.expect(!local.sharedTemplateValues().?.visible);

    const morphed = rendered.morph_states.items[0].items.items[0];
    try std.testing.expectApproxEqAbs(@as(f32, 300), morphed.position.x, 0.0001);
    try std.testing.expectEqualStrings("Morph", morphed.text.?);
    try std.testing.expectEqual(@as(?i32, 60), morphed.fontSize);
    try std.testing.expectEqual(@as(u8, 0xa0), morphed.color.?.r);
    try std.testing.expect(morphed.background_color == null);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), morphed.opacity, 0.0001);
    try std.testing.expectEqualStrings("Captured", morphed.sharedTemplateValues().?.text.?);
    try std.testing.expectEqual(@as(?i32, 44), morphed.sharedTemplateValues().?.font_size);
    try std.testing.expectApproxEqAbs(@as(f32, 100), morphed.sharedTemplateValues().?.position.x, 0.0001);
    try std.testing.expect(morphed.sharedTemplateValues().?.background_color == null);
}

test "component item background can explicitly clear an inherited fill" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const slideshow = try slides.SlideShow.new(allocator);

    const input =
        \\@push card x=10 y=20 w=300 h=100 bg=#102030ff
        \\@slide
        \\@pop card text=Filled
        \\@pop card bg=none text=Clear
    ;

    const context = try constructSlidesFromBuf(input, slideshow, allocator);
    defer context.deinit();

    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    const items = slideshow.slides.items[0].items.?.items;
    try std.testing.expectEqual(@as(u8, 0x10), items[0].background_color.?.r);
    try std.testing.expect(items[1].background_color == null);
}

test "editor locks inherit and can be overridden locally and in morph states" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const slideshow = try slides.SlideShow.new(allocator);

    const input =
        \\@box id=hero x=10 y=20 w=300 h=100 locked=true text=Hero
        \\@pushslide layout
        \\@popslide layout
        \\@set hero locked=false
        \\@state(morph)
        \\@set hero locked=true
        \\@popslide layout
    ;

    const context = try constructSlidesFromBuf(input, slideshow, allocator);
    defer context.deinit();

    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    const shared = context.push_slides.get("layout").?.items.?.items[0];
    try std.testing.expect(shared.locked);
    try std.testing.expect(shared.sharedTemplateValues().?.locked);

    const customized = slideshow.slides.items[0];
    try std.testing.expect(!customized.items.?.items[0].locked);
    try std.testing.expect(customized.items.?.items[0].sharedTemplateValues().?.locked);
    try std.testing.expect(customized.morph_states.items[0].items.items[0].locked);
    try std.testing.expect(customized.morph_states.items[0].items.items[0].sharedTemplateValues().?.locked);

    const ordinary = slideshow.slides.items[1].items.?.items[0];
    try std.testing.expect(ordinary.locked);
    try std.testing.expect(ordinary.instance_source == null);
}

test "invalid editor lock values are rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const slideshow = try slides.SlideShow.new(allocator);

    const context = try constructSlidesFromBuf(
        "@slide\n@box id=hero w=100 h=100 locked=maybe text=Hero\n",
        slideshow,
        allocator,
    );
    defer context.deinit();
    try std.testing.expectEqual(@as(usize, 1), context.parser_errors.items.len);
    try std.testing.expect(!slideshow.slides.items[0].items.?.items[0].locked);
}

test "reusable groups emit ordered fresh members and remain morph targets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const slideshow = try slides.SlideShow.new(allocator);

    const input =
        \\@push badge x=700 y=80 w=220 h=70 color=#ffeeaaff
        \\@slide
        \\@pushgroup feature-card
        \\@anim fade duration=0.4
        \\@box id=title x=120 y=140 w=500 h=100 fontsize=48 text=Reusable title
        \\@pop badge id=tag text=New
        \\@endgroup
        \\@popgroup feature-card id=primary
        \\@box id=after text=Inherited after group
        \\@popgroup feature-card id=secondary
        \\@state(morph) duration=0.7
        \\@set primary.title x=300 text=Moved title
    ;

    const context = try constructSlidesFromBuf(input, slideshow, allocator);
    defer context.deinit();
    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);

    const slide = slideshow.slides.items[0];
    const items = slide.items.?.items;
    try std.testing.expectEqual(@as(usize, 5), items.len);
    try std.testing.expectEqualStrings("primary.title", items[0].id.?);
    try std.testing.expectEqualStrings("primary.tag", items[1].id.?);
    try std.testing.expectEqualStrings("after", items[2].id.?);
    try std.testing.expectEqualStrings("secondary.title", items[3].id.?);
    try std.testing.expectEqualStrings("secondary.tag", items[4].id.?);
    try std.testing.expectEqualStrings("Reusable title", items[0].text.?);
    try std.testing.expectEqualStrings("New", items[1].text.?);
    try std.testing.expectEqual(animation.Effect.fade, items[0].animation.?.effect);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), items[0].animation.?.duration, 0.0001);
    try std.testing.expectEqual(slides.SourceScope.group_instance_member, items[0].source.scope);
    try std.testing.expectEqual(std.mem.indexOf(u8, input, "@popgroup feature-card").?, items[0].source.line_offset);
    try std.testing.expectEqual(std.mem.indexOf(u8, input, "@box id=title").?, items[0].group_member_source.?.line_offset);
    try std.testing.expectEqual(std.mem.indexOf(u8, input, "@pop badge id=tag").?, items[1].group_member_source.?.line_offset);
    try std.testing.expect(items[0].identity != items[1].identity);
    try std.testing.expect(items[0].identity != items[3].identity);
    try std.testing.expect(items[1].identity != items[4].identity);
    // The definition's final @pop context is reproduced by the call, just as
    // the literal promoted sequence would affect the item that follows it.
    try std.testing.expectApproxEqAbs(@as(f32, 700), items[2].position.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 80), items[2].position.y, 0.0001);

    const morphed = slide.morph_states.items[0].items.items;
    try std.testing.expectEqualStrings("primary.title", morphed[0].id.?);
    try std.testing.expectApproxEqAbs(@as(f32, 300), morphed[0].position.x, 0.0001);
    try std.testing.expectEqualStrings("Moved title", morphed[0].text.?);
    try std.testing.expectEqual(slides.SourceScope.morph_item, morphed[0].state_source.?.scope);
}

test "reusable groups require complete prior definitions and later definitions shadow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const slideshow = try slides.SlideShow.new(allocator);

    const input =
        \\@slide
        \\@popgroup card id=too-early
        \\@pushgroup card
        \\@box id=body x=1 y=2 w=3 h=4 text=First
        \\@endgroup
        \\@popgroup card id=one
        \\@pushgroup card
        \\@box id=body x=10 y=20 w=30 h=40 text=Second
        \\@endgroup
        \\@popgroup card id=two
    ;

    const context = try constructSlidesFromBuf(input, slideshow, allocator);
    defer context.deinit();
    try std.testing.expectEqual(@as(usize, 1), context.parser_errors.items.len);
    const items = slideshow.slides.items[0].items.?.items;
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("one.body", items[0].id.?);
    try std.testing.expectEqualStrings("First", items[0].text.?);
    try std.testing.expectEqualStrings("two.body", items[1].id.?);
    try std.testing.expectEqualStrings("Second", items[1].text.?);
    try std.testing.expectApproxEqAbs(@as(f32, 10), items[1].position.x, 0.0001);
}

test "reusable group id collisions reject an entire instance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const slideshow = try slides.SlideShow.new(allocator);

    const input =
        \\@slide
        \\@pushgroup pair
        \\@box id=left x=10 y=20 w=30 h=40 text=Left
        \\@box id=right x=50 y=20 w=30 h=40 text=Right
        \\@endgroup
        \\@box id=dupe.right x=0 y=0 w=1 h=1 text=Existing
        \\@popgroup pair id=dupe
    ;

    const context = try constructSlidesFromBuf(input, slideshow, allocator);
    defer context.deinit();
    try std.testing.expectEqual(@as(usize, 1), context.parser_errors.items.len);
    const items = slideshow.slides.items[0].items.?.items;
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("dupe.right", items[0].id.?);
}

test "malformed reusable groups emit nothing and do not poison slide context" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const slideshow = try slides.SlideShow.new(allocator);

    const input =
        \\@push inherited x=900 y=800 w=70 h=60
        \\@slide
        \\@pushgroup broken
        \\@pop inherited id=inside text=Would leak context
        \\@pushgroup nested
        \\@box id=nested-item x=1 y=2 w=3 h=4 text=Nested
        \\@endgroup
        \\@box id=still-inside x=not-a-number y=2 w=3 h=4 text=Still inside outer block
        \\@bg color=#101010ff
        \\@endgroup
        \\@popgroup broken id=nope
        \\@box id=healthy x=11 y=22 w=33 h=44 text=Healthy
    ;

    const context = try constructSlidesFromBuf(input, slideshow, allocator);
    defer context.deinit();
    try std.testing.expect(context.parser_errors.items.len >= 2);
    const items = slideshow.slides.items[0].items.?.items;
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("healthy", items[0].id.?);
    try std.testing.expectApproxEqAbs(@as(f32, 11), items[0].position.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 22), items[0].position.y, 0.0001);
}

test "reusable group syntax rejects dynamic names missing ids dangling anim and unclosed blocks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const slideshow = try slides.SlideShow.new(allocator);

    const input =
        \\@slide
        \\@pushgroup bad$name
        \\@anim fade
        \\@box x=1 y=2 w=3 h=4 text=Missing id
        \\@pushgroup nested
        \\@box id=member x=1 y=2 w=3 h=4 text=Nested
    ;

    const context = try constructSlidesFromBuf(input, slideshow, allocator);
    defer context.deinit();
    try std.testing.expect(context.parser_errors.items.len >= 3);
    try std.testing.expectEqual(@as(usize, 0), slideshow.slides.items[0].items.?.items.len);
    try std.testing.expectEqual(@as(usize, 0), context.reusable_groups.count());
}
