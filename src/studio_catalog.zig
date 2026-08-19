//! Source-backed catalog of reusable elements, groups, and slide templates.
//!
//! Entries borrow their names from the source buffer, while the catalog owns
//! only the entry array. Rebuild the catalog after every source edit; indices
//! and byte offsets are deliberately stable only for the source snapshot that
//! was scanned.

const std = @import("std");

pub const Kind = enum {
    element,
    group,
    slide,
};

/// One physical `@push`, `@pushgroup`, or `@pushslide` definition.
pub const Entry = struct {
    kind: Kind,
    /// Borrowed from the source passed to `discover`.
    name: []const u8,
    /// Start of the physical directive line, including a possible BOM offset.
    directive_offset: usize,
    /// Exact byte span of `name` in the original source.
    name_offset: usize,
    name_end: usize,
    /// End of physical content, excluding CR/LF, and end including CR/LF.
    line_end: usize,
    full_end: usize,
    /// False for names Studio cannot safely write back or instantiate.
    placeable: bool,
    /// Literal source-order-resolved uses owned by this definition, stopping
    /// at the next same-kind definition with the same name.
    use_count: usize = 0,
};

pub const Catalog = struct {
    entries: []Entry,
    source_len: usize,
    allocator: std.mem.Allocator,

    pub fn deinit(self: Catalog) void {
        self.allocator.free(self.entries);
    }

    /// Whether this exact definition is the latest same-kind, same-name
    /// definition before `insertion_offset`, matching the parser's maps.
    pub fn isVisibleAt(self: Catalog, entry_index: usize, insertion_offset: usize) bool {
        if (entry_index >= self.entries.len or insertion_offset > self.source_len) return false;
        const candidate = self.entries[entry_index];
        if (!candidate.placeable or candidate.directive_offset >= insertion_offset) return false;

        for (self.entries[entry_index + 1 ..]) |later| {
            if (later.directive_offset >= insertion_offset) break;
            if (sameDefinition(candidate, later)) return false;
        }
        return true;
    }

    /// Return the active definition of `name` at a proposed source insertion
    /// point. The result is an index into `entries`, not a retained pointer.
    pub fn findVisible(
        self: Catalog,
        kind: Kind,
        name: []const u8,
        insertion_offset: usize,
    ) ?usize {
        if (insertion_offset > self.source_len) return null;
        var found: ?usize = null;
        for (self.entries, 0..) |entry, index| {
            if (entry.directive_offset >= insertion_offset) break;
            if (entry.placeable and entry.kind == kind and std.mem.eql(u8, entry.name, name)) {
                found = index;
            }
        }
        return found;
    }

    pub fn visibleCount(self: Catalog, insertion_offset: usize) usize {
        var count: usize = 0;
        for (self.entries, 0..) |_, index| {
            if (self.isVisibleAt(index, insertion_offset)) count += 1;
        }
        return count;
    }

    /// Fill `output` with as many visible catalog indices as fit, in source
    /// order. The returned total may exceed `output.len`, allowing a caller to
    /// size storage without an allocation in the catalog layer.
    pub fn writeVisibleIndices(
        self: Catalog,
        insertion_offset: usize,
        output: []usize,
    ) usize {
        var total: usize = 0;
        for (self.entries, 0..) |_, index| {
            if (!self.isVisibleAt(index, insertion_offset)) continue;
            if (total < output.len) output[total] = index;
            total += 1;
        }
        return total;
    }
};

pub const EditResult = struct {
    source: []u8,
    byte_delta: isize,

    pub fn deinit(self: EditResult, allocator: std.mem.Allocator) void {
        allocator.free(self.source);
    }
};

pub const EditError = error{
    InvalidEntry,
    InvalidName,
    DynamicContextName,
    NameCollision,
    LiveUses,
    UnsafeGroupDelete,
    UnsafeSlideTemplateDelete,
    NoCleanupCandidates,
    SourceTooLarge,
};

pub const CleanupSummary = struct {
    /// Definitions that can be removed together without changing any rendered
    /// use or leaving a live definition with a missing dependency.
    removable_count: usize = 0,
    /// Unreferenced definitions whose physical ownership is too ambiguous to
    /// rewrite automatically. These remain visible for manual inspection.
    blocked_count: usize = 0,
};

const CleanupEdge = struct {
    owner: usize,
    dependency: usize,
};

const CleanupAnalysis = struct {
    catalog: Catalog,
    removable: []bool,
    owner_spans: []?Span,
    summary: CleanupSummary,
    allocator: std.mem.Allocator,

    fn deinit(self: CleanupAnalysis) void {
        self.catalog.deinit();
        self.allocator.free(self.removable);
        self.allocator.free(self.owner_spans);
    }
};

const Line = struct {
    start: usize,
    content_end: usize,
    trimmed_end: usize,
    full_end: usize,
};

const Directive = struct {
    kind: Kind,
    role: Role,
    name: []const u8,
    name_offset: usize,
    name_end: usize,
};

const Role = enum { definition, use };

const Span = struct {
    start: usize,
    end: usize,
};

/// Discover literal physical definitions in source order. Malformed
/// definitions without a name are ignored, just as they cannot be placed.
/// Names containing substitutions or unsupported punctuation remain visible
/// for inspection but have `placeable == false`.
pub fn discover(allocator: std.mem.Allocator, source: []const u8) std.mem.Allocator.Error!Catalog {
    var entries = std.ArrayList(Entry).empty;
    errdefer entries.deinit(allocator);

    var cursor = sourceStart(source);
    while (cursor < source.len) {
        const line = physicalLineAt(source, cursor);
        if (parseContextDirective(source, line)) |directive| {
            if (directive.role == .definition) {
                try entries.append(allocator, .{
                    .kind = directive.kind,
                    .name = directive.name,
                    .directive_offset = line.start,
                    .name_offset = directive.name_offset,
                    .name_end = directive.name_end,
                    .line_end = line.content_end,
                    .full_end = line.full_end,
                    .placeable = validName(directive.name),
                });
            }
        }
        cursor = line.full_end;
    }

    for (0..entries.items.len) |entry_index| {
        const use_count = countDefinitionUses(source, entries.items, entry_index);
        entries.items[entry_index].use_count = use_count;
    }

    return .{
        .entries = try entries.toOwnedSlice(allocator),
        .source_len = source.len,
        .allocator = allocator,
    };
}

fn countDefinitionUses(source: []const u8, entries: []const Entry, entry_index: usize) usize {
    const entry = entries[entry_index];
    var end = source.len;
    for (entries[entry_index + 1 ..]) |later| {
        if (sameDefinition(entry, later)) {
            end = later.directive_offset;
            break;
        }
    }

    var count: usize = 0;
    var cursor = entry.full_end;
    while (cursor < end) {
        const line = physicalLineAt(source, cursor);
        if (parseContextDirective(source, line)) |directive| {
            if (directive.role == .use and directive.kind == entry.kind and
                std.mem.eql(u8, directive.name, entry.name))
            {
                count += 1;
            }
        }
        cursor = line.full_end;
    }
    return count;
}

/// Rename one definition and precisely those later uses that resolve to it:
/// from the definition through (but excluding) the next same-kind definition
/// with the old name. The target name must be globally unused for that kind;
/// this conservative rule prevents changing unrelated parser-map resolution.
pub fn renameDefinition(
    allocator: std.mem.Allocator,
    source: []const u8,
    entry: Entry,
    new_name: []const u8,
) (std.mem.Allocator.Error || EditError)!EditResult {
    if (!validName(new_name)) return error.InvalidName;
    const definition = try validateEntry(source, entry);
    if (!validName(definition.name)) return error.DynamicContextName;
    if (std.mem.eql(u8, definition.name, new_name)) return duplicateResult(allocator, source);

    try rejectDynamicNames(source, entry.kind);

    // A unique target keeps both existing valid uses and existing invalid uses
    // from changing which parser-map value they resolve to.
    var cursor = sourceStart(source);
    while (cursor < source.len) {
        const line = physicalLineAt(source, cursor);
        if (parseContextDirective(source, line)) |directive| {
            if (directive.kind == entry.kind and std.mem.eql(u8, directive.name, new_name)) {
                return error.NameCollision;
            }
        }
        cursor = line.full_end;
    }

    var spans = std.ArrayList(Span).empty;
    defer spans.deinit(allocator);
    try spans.append(allocator, .{ .start = definition.name_offset, .end = definition.name_end });

    cursor = definition.line.full_end;
    while (cursor < source.len) {
        const line = physicalLineAt(source, cursor);
        if (parseContextDirective(source, line)) |directive| {
            if (directive.kind == entry.kind and
                directive.role == .definition and
                std.mem.eql(u8, directive.name, definition.name))
            {
                break;
            }
            if (directive.kind == entry.kind and
                directive.role == .use and
                std.mem.eql(u8, directive.name, definition.name))
            {
                try spans.append(allocator, .{ .start = directive.name_offset, .end = directive.name_end });
            }
        }
        cursor = line.full_end;
    }

    return replaceSpans(allocator, source, spans.items, new_name);
}

/// Delete an unused reusable-element definition and its parser body text.
/// Comments and blank formatting lines are retained byte-for-byte. Slide
/// template deletion is deliberately rejected because `@pushslide` captures
/// the preceding slide and source ownership cannot be inferred safely.
pub fn deleteDefinition(
    allocator: std.mem.Allocator,
    source: []const u8,
    entry: Entry,
) (std.mem.Allocator.Error || EditError)!EditResult {
    const definition = try validateEntry(source, entry);
    if (!validName(definition.name)) return error.DynamicContextName;
    if (entry.kind == .slide) return error.UnsafeSlideTemplateDelete;
    try rejectDynamicNames(source, entry.kind);

    var cursor = definition.line.full_end;
    while (cursor < source.len) {
        const line = physicalLineAt(source, cursor);
        if (parseContextDirective(source, line)) |directive| {
            if (directive.kind == entry.kind and
                directive.role == .definition and
                std.mem.eql(u8, directive.name, definition.name))
            {
                break;
            }
            if (directive.kind == entry.kind and
                directive.role == .use and
                std.mem.eql(u8, directive.name, definition.name))
            {
                return error.LiveUses;
            }
        }
        cursor = line.full_end;
    }

    if (entry.kind == .group) {
        var block_cursor = definition.line.full_end;
        while (block_cursor < source.len) {
            const line = physicalLineAt(source, block_cursor);
            const text = source[line.start..line.trimmed_end];
            if (std.mem.indexOfScalar(u8, text, '$') != null) return error.UnsafeGroupDelete;
            const token = firstToken(text);
            if (std.mem.eql(u8, token, "@endgroup")) {
                if (std.mem.trim(u8, text["@endgroup".len..], " \t").len != 0) {
                    return error.UnsafeGroupDelete;
                }
                return removeSpans(allocator, source, &.{.{
                    .start = definition.line.start,
                    .end = line.full_end,
                }});
            }
            if (token.len > 0 and token[0] == '@' and !isSafeGroupBodyDirective(token)) {
                return error.UnsafeGroupDelete;
            }
            block_cursor = line.full_end;
        }
        return error.UnsafeGroupDelete;
    }

    var removals = std.ArrayList(Span).empty;
    defer removals.deinit(allocator);
    try removals.append(allocator, .{ .start = definition.line.start, .end = definition.line.full_end });

    // Body text belongs to the pending @push. Retaining it could attach that
    // text to the previous directive after deletion. Standalone comments and
    // blank layout are parser-neutral and intentionally survive.
    cursor = definition.line.full_end;
    while (cursor < source.len) {
        const line = physicalLineAt(source, cursor);
        if (line.trimmed_end > line.start and source[line.start] == '@') break;
        const content = source[line.start..line.trimmed_end];
        if (content.len > 0 and content[0] != '#') {
            try removals.append(allocator, .{ .start = line.start, .end = line.full_end });
        }
        cursor = line.full_end;
    }

    return removeSpans(allocator, source, removals.items);
}

/// Analyze parser-scoped reusable dependencies and report one conservative
/// fixed-point cleanup. A physical use in a rendered/root region keeps its
/// exact source-order-resolved definition alive. Uses inside a reachable group
/// or direct slide-template definition keep their dependencies alive; uses
/// owned only by dead definitions do not. Dynamic structural names reject the
/// analysis instead of guessing through @let expansion.
pub fn cleanupSummary(
    allocator: std.mem.Allocator,
    source: []const u8,
) (std.mem.Allocator.Error || EditError)!CleanupSummary {
    const analysis = try analyzeCleanup(allocator, source);
    defer analysis.deinit();
    return analysis.summary;
}

/// Remove every safely unreachable reusable definition in one atomic source
/// rewrite. Element definitions retain standalone comments/blank formatting;
/// group blocks and direct slide-template captures are removed as complete
/// source-owned units. The graph is resolved before any bytes move.
pub fn cleanupUnusedDefinitions(
    allocator: std.mem.Allocator,
    source: []const u8,
) (std.mem.Allocator.Error || EditError)!EditResult {
    const analysis = try analyzeCleanup(allocator, source);
    defer analysis.deinit();
    if (analysis.summary.removable_count == 0) return error.NoCleanupCandidates;

    var removals = std.ArrayList(Span).empty;
    defer removals.deinit(allocator);
    for (analysis.catalog.entries, 0..) |entry, index| {
        if (!analysis.removable[index]) continue;
        switch (entry.kind) {
            .element => try appendElementDefinitionRemovalSpans(allocator, source, entry, &removals),
            .group, .slide => try removals.append(
                allocator,
                analysis.owner_spans[index] orelse return error.InvalidEntry,
            ),
        }
    }
    sortSpans(removals.items);
    var cursor: usize = 0;
    for (removals.items) |span| {
        if (span.start < cursor or span.end < span.start or span.end > source.len) {
            return error.InvalidEntry;
        }
        cursor = span.end;
    }
    return removeSpans(allocator, source, removals.items);
}

fn analyzeCleanup(
    allocator: std.mem.Allocator,
    source: []const u8,
) (std.mem.Allocator.Error || EditError)!CleanupAnalysis {
    try rejectDynamicNames(source, .element);
    try rejectDynamicNames(source, .group);
    try rejectDynamicNames(source, .slide);

    const catalog = try discover(allocator, source);
    errdefer catalog.deinit();
    const count = catalog.entries.len;
    const removable = try allocator.alloc(bool, count);
    errdefer allocator.free(removable);
    @memset(removable, false);
    const owner_spans = try allocator.alloc(?Span, count);
    errdefer allocator.free(owner_spans);
    @memset(owner_spans, null);
    const safe = try allocator.alloc(bool, count);
    defer allocator.free(safe);
    const reachable = try allocator.alloc(bool, count);
    defer allocator.free(reachable);
    const incoming = try allocator.alloc(bool, count);
    defer allocator.free(incoming);
    @memset(safe, false);
    @memset(reachable, false);
    @memset(incoming, false);

    for (catalog.entries, 0..) |entry, index| {
        if (!entry.placeable) continue;
        switch (entry.kind) {
            .element => safe[index] = true,
            .group => if (safeGroupDefinitionSpan(source, entry)) |span| {
                safe[index] = true;
                owner_spans[index] = span;
            },
            .slide => if (safeSlideTemplateDefinitionSpan(source, entry)) |span| {
                safe[index] = true;
                owner_spans[index] = span;
            },
        }
    }

    var edges = std.ArrayList(CleanupEdge).empty;
    defer edges.deinit(allocator);
    var scan_cursor = sourceStart(source);
    while (scan_cursor < source.len) {
        const line = physicalLineAt(source, scan_cursor);
        if (parseContextDirective(source, line)) |directive| {
            if (directive.role == .use) {
                if (resolveDefinitionIndex(
                    catalog.entries,
                    directive.kind,
                    directive.name,
                    line.start,
                )) |dependency| {
                    incoming[dependency] = true;
                    if (cleanupOwnerIndex(owner_spans, line.start)) |owner| {
                        try edges.append(allocator, .{ .owner = owner, .dependency = dependency });
                    } else {
                        reachable[dependency] = true;
                    }
                }
            }
        }
        scan_cursor = line.full_end;
    }

    // An unsafe definition stays in source and therefore acts as a root. Its
    // physical uses were deliberately not assigned an owner span above, so
    // they already keep their resolved dependencies alive as well.
    for (safe, 0..) |is_safe, index| {
        if (!is_safe) reachable[index] = true;
    }
    var changed = true;
    while (changed) {
        changed = false;
        for (edges.items) |edge| {
            if (reachable[edge.owner] and !reachable[edge.dependency]) {
                reachable[edge.dependency] = true;
                changed = true;
            }
        }
    }

    const context_blocked = retainContextBarrierDefinitions(
        source,
        catalog.entries,
        safe,
        owner_spans,
        reachable,
    );

    var summary = CleanupSummary{ .blocked_count = context_blocked };
    for (catalog.entries, 0..) |_, index| {
        if (safe[index] and !reachable[index]) {
            removable[index] = true;
            summary.removable_count += 1;
        } else if (!safe[index] and !incoming[index]) {
            summary.blocked_count += 1;
        }
    }
    return .{
        .catalog = catalog,
        .removable = removable,
        .owner_spans = owner_spans,
        .summary = summary,
        .allocator = allocator,
    };
}

/// Unused @push directives still clear the parser's persistent item context.
/// Keep exactly those that are required as semantic barriers after the other
/// planned definition spans disappear. This avoids a dead definition making
/// a later literal @box or reusable definition inherit an earlier @pop.
fn retainContextBarrierDefinitions(
    source: []const u8,
    entries: []const Entry,
    safe: []const bool,
    owner_spans: []const ?Span,
    reachable: []bool,
) usize {
    var context_may_be_nonempty = false;
    var blocked: usize = 0;
    var cursor = sourceStart(source);
    while (cursor < source.len) {
        var skipped = false;
        for (entries, 0..) |entry, index| {
            const span = owner_spans[index] orelse continue;
            if (span.start != cursor) continue;
            if (entry.kind == .group) {
                cursor = span.end;
                skipped = true;
                break;
            }
            if (entry.kind == .slide and safe[index] and !reachable[index]) {
                cursor = span.end;
                skipped = true;
                break;
            }
        }
        if (skipped) continue;

        const line = physicalLineAt(source, cursor);
        const text = source[line.start..line.trimmed_end];
        const token = firstToken(text);
        if (std.mem.eql(u8, token, "@slide") or
            std.mem.eql(u8, token, "@popslide") or
            std.mem.eql(u8, token, "@state") or
            (std.mem.startsWith(u8, token, "@state(") and std.mem.endsWith(u8, token, ")")))
        {
            context_may_be_nonempty = false;
        } else if (std.mem.eql(u8, token, "@pop") or std.mem.eql(u8, token, "@popgroup")) {
            context_may_be_nonempty = true;
        } else if (std.mem.eql(u8, token, "@push")) {
            if (definitionIndexAt(entries, line.start)) |index| {
                if (safe[index] and !reachable[index]) {
                    if (context_may_be_nonempty) {
                        reachable[index] = true;
                        blocked += 1;
                        context_may_be_nonempty = false;
                    }
                } else {
                    context_may_be_nonempty = false;
                }
            } else {
                context_may_be_nonempty = false;
            }
        }
        cursor = line.full_end;
    }
    return blocked;
}

fn definitionIndexAt(entries: []const Entry, offset: usize) ?usize {
    for (entries, 0..) |entry, index| {
        if (entry.directive_offset == offset) return index;
        if (entry.directive_offset > offset) break;
    }
    return null;
}

fn safeGroupDefinitionSpan(source: []const u8, entry: Entry) ?Span {
    const definition = validateEntry(source, entry) catch return null;
    if (entry.kind != .group or !validName(definition.name)) return null;
    return safeGroupBlockSpanAt(source, definition.line.start);
}

fn safeGroupBlockSpanAt(source: []const u8, definition_offset: usize) ?Span {
    const opening = physicalLineAt(source, definition_offset);
    const opening_text = source[opening.start..opening.trimmed_end];
    if (!std.mem.eql(u8, firstToken(opening_text), "@pushgroup") or
        std.mem.indexOfScalar(u8, opening_text, '$') != null)
    {
        return null;
    }
    var member_count: usize = 0;
    var cursor = opening.full_end;
    while (cursor < source.len) {
        const line = physicalLineAt(source, cursor);
        const text = source[line.start..line.trimmed_end];
        if (std.mem.indexOfScalar(u8, text, '$') != null) return null;
        const token = firstToken(text);
        if (std.mem.eql(u8, token, "@endgroup")) {
            if (std.mem.trim(u8, text[token.len..], " \t").len != 0 or member_count == 0) {
                return null;
            }
            return .{ .start = opening.start, .end = line.full_end };
        }
        if (token.len > 0 and token[0] == '@') {
            if (!isSafeGroupBodyDirective(token)) return null;
            if (std.mem.eql(u8, token, "@box") or std.mem.eql(u8, token, "@pop")) {
                member_count += 1;
            }
        }
        cursor = line.full_end;
    }
    return null;
}

fn safeSlideTemplateDefinitionSpan(source: []const u8, entry: Entry) ?Span {
    const definition = validateEntry(source, entry) catch return null;
    if (entry.kind != .slide or !validName(definition.name)) return null;
    const definition_text = source[definition.line.start..definition.line.trimmed_end];
    if (std.mem.indexOfScalar(u8, definition_text, '$') != null) return null;

    var scan_start = sourceStart(source);
    var cursor = sourceStart(source);
    while (cursor < definition.line.start) {
        const line = physicalLineAt(source, cursor);
        if (line.full_end > definition.line.start) return null;
        if (line.trimmed_end > line.start and source[line.start] == '@' and
            std.mem.eql(u8, firstToken(source[line.start..line.trimmed_end]), "@pushslide"))
        {
            scan_start = line.full_end;
        }
        cursor = line.full_end;
    }
    if (cursor != definition.line.start) return null;

    var capture_start = definition.line.start;
    var saw_item = false;
    var pending_animation = false;
    cursor = scan_start;
    while (cursor < definition.line.start) {
        const line = physicalLineAt(source, cursor);
        if (line.full_end > definition.line.start) return null;
        const text = source[line.start..line.trimmed_end];
        if (std.mem.indexOfScalar(u8, text, '$') != null) return null;
        const token = firstToken(text);
        if (token.len == 0 or token[0] == '#') {
            cursor = line.full_end;
            continue;
        }
        if (std.mem.eql(u8, token, "@pushgroup")) {
            if (saw_item or pending_animation) return null;
            const group_span = safeGroupBlockSpanAt(source, line.start) orelse return null;
            if (group_span.end > definition.line.start) return null;
            cursor = group_span.end;
            continue;
        }
        if (token[0] != '@') {
            cursor = line.full_end;
            continue;
        }
        if (std.mem.eql(u8, token, "@push")) {
            if (saw_item or pending_animation) return null;
            cursor = line.full_end;
            continue;
        }
        if (isAnimationToken(token)) {
            if (pending_animation) return null;
            if (!saw_item) capture_start = line.start;
            pending_animation = true;
            cursor = line.full_end;
            continue;
        }
        if (isDirectSlideTemplateItemToken(token)) {
            if (!saw_item and !pending_animation) capture_start = line.start;
            saw_item = true;
            pending_animation = false;
            cursor = line.full_end;
            continue;
        }
        return null;
    }
    if (pending_animation) return null;

    // Capturing a slide can leave the final @pop/@popgroup item context active
    // in the parser. Removing the capture is equivalent only when no later
    // context-sensitive directive can observe it before an explicit rendered
    // slide boundary clears the context.
    cursor = definition.line.full_end;
    while (cursor < source.len) {
        const line = physicalLineAt(source, cursor);
        const text = source[line.start..line.trimmed_end];
        const token = firstToken(text);
        if (token.len == 0 or token[0] == '#') {
            cursor = line.full_end;
            continue;
        }
        if (token[0] != '@') return null;
        if (!std.mem.eql(u8, token, "@slide") and !std.mem.eql(u8, token, "@popslide")) {
            return null;
        }
        break;
    }
    return .{ .start = capture_start, .end = definition.line.full_end };
}

fn isAnimationToken(token: []const u8) bool {
    return std.mem.eql(u8, token, "@anim") or
        (std.mem.startsWith(u8, token, "@anim(") and std.mem.endsWith(u8, token, ")"));
}

fn isDirectSlideTemplateItemToken(token: []const u8) bool {
    return std.mem.eql(u8, token, "@box") or
        std.mem.eql(u8, token, "@pop") or
        std.mem.eql(u8, token, "@popgroup") or
        std.mem.eql(u8, token, "@bg") or
        std.mem.eql(u8, token, "@crowd");
}

fn resolveDefinitionIndex(
    entries: []const Entry,
    kind: Kind,
    name: []const u8,
    before_offset: usize,
) ?usize {
    var resolved: ?usize = null;
    for (entries, 0..) |entry, index| {
        if (entry.directive_offset >= before_offset) break;
        if (entry.kind == kind and std.mem.eql(u8, entry.name, name)) resolved = index;
    }
    return resolved;
}

fn cleanupOwnerIndex(owner_spans: []const ?Span, offset: usize) ?usize {
    var owner: ?usize = null;
    var owner_size: usize = std.math.maxInt(usize);
    for (owner_spans, 0..) |span_opt, index| {
        const span = span_opt orelse continue;
        if (offset < span.start or offset >= span.end) continue;
        const size = span.end - span.start;
        if (size < owner_size) {
            owner = index;
            owner_size = size;
        }
    }
    return owner;
}

fn appendElementDefinitionRemovalSpans(
    allocator: std.mem.Allocator,
    source: []const u8,
    entry: Entry,
    removals: *std.ArrayList(Span),
) (std.mem.Allocator.Error || EditError)!void {
    const definition = try validateEntry(source, entry);
    if (entry.kind != .element) return error.InvalidEntry;
    try removals.append(allocator, .{
        .start = definition.line.start,
        .end = definition.line.full_end,
    });
    var cursor = definition.line.full_end;
    while (cursor < source.len) {
        const line = physicalLineAt(source, cursor);
        if (line.trimmed_end > line.start and source[line.start] == '@') break;
        const content = source[line.start..line.trimmed_end];
        if (content.len > 0 and content[0] != '#') {
            try removals.append(allocator, .{ .start = line.start, .end = line.full_end });
        }
        cursor = line.full_end;
    }
}

fn sortSpans(spans: []Span) void {
    for (1..spans.len) |index| {
        const value = spans[index];
        var destination = index;
        while (destination > 0 and spans[destination - 1].start > value.start) : (destination -= 1) {
            spans[destination] = spans[destination - 1];
        }
        spans[destination] = value;
    }
}

const ValidatedEntry = struct {
    line: Line,
    name: []const u8,
    name_offset: usize,
    name_end: usize,
};

fn validateEntry(source: []const u8, entry: Entry) EditError!ValidatedEntry {
    if (entry.directive_offset >= source.len) return error.InvalidEntry;
    if (entry.directive_offset != sourceStart(source) and source[entry.directive_offset - 1] != '\n') {
        return error.InvalidEntry;
    }
    const line = physicalLineAt(source, entry.directive_offset);
    if (line.start != entry.directive_offset) return error.InvalidEntry;
    const directive = parseContextDirective(source, line) orelse return error.InvalidEntry;
    if (directive.role != .definition or directive.kind != entry.kind) return error.InvalidEntry;
    if (directive.name_offset != entry.name_offset or directive.name_end != entry.name_end) return error.InvalidEntry;
    if (!std.mem.eql(u8, directive.name, entry.name)) return error.InvalidEntry;
    return .{
        .line = line,
        .name = directive.name,
        .name_offset = directive.name_offset,
        .name_end = directive.name_end,
    };
}

fn rejectDynamicNames(source: []const u8, kind: Kind) EditError!void {
    var cursor = sourceStart(source);
    while (cursor < source.len) {
        const line = physicalLineAt(source, cursor);
        // A substituted first token could turn into @push/@pop even when the
        // physical source is not classifiable. Source edits cannot safely
        // determine its parser-map scope without evaluating all @let state.
        if (line.trimmed_end > line.start) {
            var token_end = line.start;
            while (token_end < line.trimmed_end and !isHorizontalWhitespace(source[token_end])) : (token_end += 1) {}
            const token = source[line.start..token_end];
            if ((token[0] == '@' or token[0] == '$') and
                std.mem.indexOfScalar(u8, token, '$') != null)
            {
                return error.DynamicContextName;
            }
        }
        if (parseContextDirective(source, line)) |directive| {
            if (directive.kind == kind and std.mem.indexOfScalar(u8, directive.name, '$') != null) {
                return error.DynamicContextName;
            }
        }
        cursor = line.full_end;
    }
}

fn parseContextDirective(source: []const u8, line: Line) ?Directive {
    if (line.trimmed_end <= line.start or source[line.start] != '@') return null;
    var token_end = line.start;
    while (token_end < line.trimmed_end and !isHorizontalWhitespace(source[token_end])) : (token_end += 1) {}
    const token = source[line.start..token_end];

    const classification: struct { Kind, Role } =
        if (std.mem.eql(u8, token, "@push"))
            .{ .element, .definition }
        else if (std.mem.eql(u8, token, "@pop"))
            .{ .element, .use }
        else if (std.mem.eql(u8, token, "@pushgroup"))
            .{ .group, .definition }
        else if (std.mem.eql(u8, token, "@popgroup"))
            .{ .group, .use }
        else if (std.mem.eql(u8, token, "@pushslide"))
            .{ .slide, .definition }
        else if (std.mem.eql(u8, token, "@popslide"))
            .{ .slide, .use }
        else
            return null;

    var name_start = token_end;
    while (name_start < line.trimmed_end and isHorizontalWhitespace(source[name_start])) : (name_start += 1) {}
    if (name_start == line.trimmed_end) return null;
    var name_end = name_start;
    while (name_end < line.trimmed_end and !isHorizontalWhitespace(source[name_end])) : (name_end += 1) {}

    return .{
        .kind = classification[0],
        .role = classification[1],
        .name = source[name_start..name_end],
        .name_offset = name_start,
        .name_end = name_end,
    };
}

fn firstToken(text: []const u8) []const u8 {
    var end: usize = 0;
    while (end < text.len and !isHorizontalWhitespace(text[end])) : (end += 1) {}
    return text[0..end];
}

fn isSafeGroupBodyDirective(token: []const u8) bool {
    return std.mem.eql(u8, token, "@box") or
        std.mem.eql(u8, token, "@pop") or
        std.mem.eql(u8, token, "@anim") or
        (std.mem.startsWith(u8, token, "@anim(") and std.mem.endsWith(u8, token, ")"));
}

fn physicalLineAt(source: []const u8, start: usize) Line {
    var content_end = std.mem.indexOfScalarPos(u8, source, start, '\n') orelse source.len;
    const full_end = if (content_end < source.len) content_end + 1 else content_end;
    if (content_end > start and source[content_end - 1] == '\r') content_end -= 1;
    var trimmed_end = content_end;
    while (trimmed_end > start and isHorizontalWhitespace(source[trimmed_end - 1])) : (trimmed_end -= 1) {}
    return .{
        .start = start,
        .content_end = content_end,
        .trimmed_end = trimmed_end,
        .full_end = full_end,
    };
}

fn sameDefinition(a: Entry, b: Entry) bool {
    return a.kind == b.kind and std.mem.eql(u8, a.name, b.name);
}

fn validName(name: []const u8) bool {
    if (name.len == 0 or !(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name[1..]) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-')) return false;
    }
    return true;
}

fn isHorizontalWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t';
}

fn sourceStart(source: []const u8) usize {
    return if (std.mem.startsWith(u8, source, "\xEF\xBB\xBF")) 3 else 0;
}

fn replaceSpans(
    allocator: std.mem.Allocator,
    source: []const u8,
    spans: []const Span,
    replacement: []const u8,
) (std.mem.Allocator.Error || EditError)!EditResult {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    var cursor: usize = 0;
    for (spans) |span| {
        if (span.start < cursor or span.end < span.start or span.end > source.len) return error.InvalidEntry;
        try output.appendSlice(allocator, source[cursor..span.start]);
        try output.appendSlice(allocator, replacement);
        cursor = span.end;
    }
    try output.appendSlice(allocator, source[cursor..]);
    return finishResult(allocator, &output, source.len);
}

fn removeSpans(
    allocator: std.mem.Allocator,
    source: []const u8,
    spans: []const Span,
) (std.mem.Allocator.Error || EditError)!EditResult {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    var cursor: usize = 0;
    for (spans) |span| {
        if (span.start < cursor or span.end < span.start or span.end > source.len) return error.InvalidEntry;
        try output.appendSlice(allocator, source[cursor..span.start]);
        cursor = span.end;
    }
    try output.appendSlice(allocator, source[cursor..]);
    return finishResult(allocator, &output, source.len);
}

fn duplicateResult(allocator: std.mem.Allocator, source: []const u8) std.mem.Allocator.Error!EditResult {
    return .{ .source = try allocator.dupe(u8, source), .byte_delta = 0 };
}

fn finishResult(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    original_len: usize,
) (std.mem.Allocator.Error || EditError)!EditResult {
    const patched_len = output.items.len;
    const delta: isize = if (patched_len >= original_len)
        std.math.cast(isize, patched_len - original_len) orelse return error.SourceTooLarge
    else
        -(std.math.cast(isize, original_len - patched_len) orelse return error.SourceTooLarge);
    return .{ .source = try output.toOwnedSlice(allocator), .byte_delta = delta };
}

test "catalog discovers borrowed element and slide definitions with exact offsets" {
    const source =
        "\xEF\xBB\xBF# library\r\n" ++
        "@push  title\t x=10\r\n" ++
        "@pushslide content transition=fade\r\n" ++
        "  @push ignored\r\n" ++
        "# @push commented\r\n" ++
        "@push $DYNAMIC$\r\n";
    var catalog = try discover(std.testing.allocator, source);
    defer catalog.deinit();

    try std.testing.expectEqual(@as(usize, 3), catalog.entries.len);
    try std.testing.expectEqual(Kind.element, catalog.entries[0].kind);
    try std.testing.expectEqualStrings("title", catalog.entries[0].name);
    try std.testing.expectEqual(std.mem.indexOf(u8, source, "@push  title").?, catalog.entries[0].directive_offset);
    try std.testing.expectEqual(std.mem.indexOf(u8, source, "title").?, catalog.entries[0].name_offset);
    try std.testing.expect(catalog.entries[0].placeable);
    try std.testing.expectEqual(Kind.slide, catalog.entries[1].kind);
    try std.testing.expectEqualStrings("content", catalog.entries[1].name);
    try std.testing.expect(!catalog.entries[2].placeable);
}

test "source-order visibility returns only the latest same-kind definition" {
    const source =
        "@push card x=1\n" ++
        "@pushslide card\n" ++
        "@slide\n" ++
        "@pop card\n" ++
        "@push card x=2\n" ++
        "@slide\n";
    var catalog = try discover(std.testing.allocator, source);
    defer catalog.deinit();

    const first_use = std.mem.indexOf(u8, source, "@pop card").?;
    try std.testing.expect(catalog.isVisibleAt(0, first_use));
    try std.testing.expect(catalog.isVisibleAt(1, first_use));
    try std.testing.expectEqual(@as(?usize, 0), catalog.findVisible(.element, "card", first_use));
    try std.testing.expectEqual(@as(?usize, 1), catalog.findVisible(.slide, "card", first_use));

    const eof = source.len;
    try std.testing.expect(!catalog.isVisibleAt(0, eof));
    try std.testing.expect(catalog.isVisibleAt(2, eof));
    try std.testing.expectEqual(@as(?usize, 2), catalog.findVisible(.element, "card", eof));
    try std.testing.expectEqual(@as(usize, 1), catalog.entries[0].use_count);
    try std.testing.expectEqual(@as(usize, 0), catalog.entries[1].use_count);
    try std.testing.expectEqual(@as(usize, 0), catalog.entries[2].use_count);

    var indices: [1]usize = undefined;
    try std.testing.expectEqual(@as(usize, 2), catalog.writeVisibleIndices(eof, &indices));
    try std.testing.expectEqual(@as(usize, 1), indices[0]);
}

test "rename follows parser source-order scope and preserves BOM CRLF formatting" {
    const source =
        "\xEF\xBB\xBF@push card  x=1\r\n" ++
        "@pop card id=one\r\n" ++
        "# keep card in prose\r\n" ++
        "@push card x=2\r\n" ++
        "@pop card id=two\r\n";
    var catalog = try discover(std.testing.allocator, source);
    defer catalog.deinit();

    const renamed = try renameDefinition(std.testing.allocator, source, catalog.entries[0], "badge");
    defer renamed.deinit(std.testing.allocator);
    const expected =
        "\xEF\xBB\xBF@push badge  x=1\r\n" ++
        "@pop badge id=one\r\n" ++
        "# keep card in prose\r\n" ++
        "@push card x=2\r\n" ++
        "@pop card id=two\r\n";
    try std.testing.expectEqualStrings(expected, renamed.source);

    var after = try discover(std.testing.allocator, renamed.source);
    defer after.deinit();
    try std.testing.expectEqualStrings("badge", after.entries[0].name);
    try std.testing.expectEqualStrings("card", after.entries[1].name);
}

test "slide template rename updates only its scoped popslide uses" {
    const source =
        "@pushslide content\n" ++
        "@popslide content\n" ++
        "@push content\n" ++
        "@pop content\n" ++
        "@pushslide content\n" ++
        "@popslide content\n";
    var catalog = try discover(std.testing.allocator, source);
    defer catalog.deinit();

    const renamed = try renameDefinition(std.testing.allocator, source, catalog.entries[0], "standard");
    defer renamed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "@pushslide standard\n" ++
            "@popslide standard\n" ++
            "@push content\n" ++
            "@pop content\n" ++
            "@pushslide content\n" ++
            "@popslide content\n",
        renamed.source,
    );
}

test "group catalog discovers scopes renames uses and deletes an unused block" {
    const source =
        "\xEF\xBB\xBF@pushgroup feature\r\n" ++
        "@box id=title x=10 text=Feature\r\n" ++
        "# owned group note\r\n" ++
        "@endgroup\r\n" ++
        "@slide\r\n" ++
        "@popgroup feature id=one\r\n" ++
        "@pushgroup unused\r\n" ++
        "@box id=badge text=Unused\r\n" ++
        "@endgroup\r\n";
    var catalog = try discover(std.testing.allocator, source);
    defer catalog.deinit();
    try std.testing.expectEqual(@as(usize, 2), catalog.entries.len);
    try std.testing.expectEqual(Kind.group, catalog.entries[0].kind);
    try std.testing.expectEqualStrings("feature", catalog.entries[0].name);
    try std.testing.expectEqual(@as(usize, 1), catalog.entries[0].use_count);
    try std.testing.expectEqual(@as(?usize, 0), catalog.findVisible(
        .group,
        "feature",
        std.mem.indexOf(u8, source, "@popgroup feature").?,
    ));

    const renamed = try renameDefinition(std.testing.allocator, source, catalog.entries[0], "hero");
    defer renamed.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, renamed.source, "@pushgroup hero\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, renamed.source, "@popgroup hero id=one\r\n") != null);

    var renamed_catalog = try discover(std.testing.allocator, renamed.source);
    defer renamed_catalog.deinit();
    const deleted = try deleteDefinition(
        std.testing.allocator,
        renamed.source,
        renamed_catalog.entries[1],
    );
    defer deleted.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, deleted.source, "@pushgroup unused") == null);
    try std.testing.expect(std.mem.indexOf(u8, deleted.source, "id=badge") == null);
    try std.testing.expect(std.mem.indexOf(u8, deleted.source, "@pushgroup hero") != null);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parser = @import("parser.zig");
    const slides = @import("slides.zig");
    const deck = try slides.SlideShow.new(arena.allocator());
    const context = try parser.constructSlidesFromBuf(deleted.source, deck, arena.allocator());
    defer context.deinit();
    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    try std.testing.expectEqualStrings("one.title", deck.slides.items[0].items.?.items[0].id.?);
}

test "group catalog refuses live and malformed block deletion" {
    const live =
        "@pushgroup card\n" ++
        "@box id=title text=Card\n" ++
        "@endgroup\n" ++
        "@slide\n" ++
        "@popgroup card id=one\n";
    var live_catalog = try discover(std.testing.allocator, live);
    defer live_catalog.deinit();
    try std.testing.expectError(
        error.LiveUses,
        deleteDefinition(std.testing.allocator, live, live_catalog.entries[0]),
    );

    const malformed = "@pushgroup broken\n@box id=title text=Broken\n";
    var malformed_catalog = try discover(std.testing.allocator, malformed);
    defer malformed_catalog.deinit();
    try std.testing.expectError(
        error.UnsafeGroupDelete,
        deleteDefinition(std.testing.allocator, malformed, malformed_catalog.entries[0]),
    );

    const forbidden =
        "@pushgroup broken\n" ++
        "@box id=title text=Broken\n" ++
        "@slide\n" ++
        "@box id=outside text=Must survive\n" ++
        "@endgroup\n";
    var forbidden_catalog = try discover(std.testing.allocator, forbidden);
    defer forbidden_catalog.deinit();
    try std.testing.expectError(
        error.UnsafeGroupDelete,
        deleteDefinition(std.testing.allocator, forbidden, forbidden_catalog.entries[0]),
    );
}

test "cleanup sweeps an unreachable reusable dependency chain to a fixed point" {
    const source =
        "\xEF\xBB\xBF@push atom x=10 y=20 text=Atom\r\n" ++
        "# component documentation survives\r\n" ++
        "@pushgroup pair\r\n" ++
        "@pop atom id=left x=100\r\n" ++
        "@box id=right x=500 text=Right\r\n" ++
        "@endgroup\r\n" ++
        "@push live text=Live\r\n" ++
        "@popgroup pair id=template_instance\r\n" ++
        "@pushslide unused_layout\r\n" ++
        "@slide\r\n" ++
        "@pop live id=visible\r\n";
    const summary = try cleanupSummary(std.testing.allocator, source);
    try std.testing.expectEqual(@as(usize, 3), summary.removable_count);
    try std.testing.expectEqual(@as(usize, 0), summary.blocked_count);

    const cleaned = try cleanupUnusedDefinitions(std.testing.allocator, source);
    defer cleaned.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, cleaned.source, "@push atom") == null);
    try std.testing.expect(std.mem.indexOf(u8, cleaned.source, "@pushgroup pair") == null);
    try std.testing.expect(std.mem.indexOf(u8, cleaned.source, "@pushslide unused_layout") == null);
    try std.testing.expect(std.mem.indexOf(u8, cleaned.source, "template_instance") == null);
    try std.testing.expect(std.mem.indexOf(u8, cleaned.source, "# component documentation survives\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, cleaned.source, "@push live text=Live\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, cleaned.source, "@pop live id=visible\r\n") != null);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parser = @import("parser.zig");
    const slides = @import("slides.zig");
    const deck = try slides.SlideShow.new(arena.allocator());
    const context = try parser.constructSlidesFromBuf(cleaned.source, deck, arena.allocator());
    defer context.deinit();
    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    try std.testing.expectEqual(@as(usize, 1), deck.slides.items.len);
    try std.testing.expectEqualStrings("visible", deck.slides.items[0].items.?.items[0].id.?);
}

test "cleanup keeps dependencies of live and structurally blocked slide templates" {
    const live =
        "@push atom text=Atom\n" ++
        "@pushgroup pair\n" ++
        "@pop atom id=left\n" ++
        "@box id=right text=Right\n" ++
        "@endgroup\n" ++
        "@popgroup pair id=template_instance\n" ++
        "@pushslide layout\n" ++
        "@popslide layout\n";
    const live_summary = try cleanupSummary(std.testing.allocator, live);
    try std.testing.expectEqual(@as(usize, 0), live_summary.removable_count);
    try std.testing.expectError(
        error.NoCleanupCandidates,
        cleanupUnusedDefinitions(std.testing.allocator, live),
    );

    const blocked =
        "@push atom text=Atom\n" ++
        "@box id=owned text=Owned\n" ++
        "@color fg=#ffffffff\n" ++
        "@pop atom id=inside\n" ++
        "@pushslide unsafe\n" ++
        "@slide\n" ++
        "@box id=visible text=Visible\n";
    const blocked_summary = try cleanupSummary(std.testing.allocator, blocked);
    try std.testing.expectEqual(@as(usize, 0), blocked_summary.removable_count);
    try std.testing.expectEqual(@as(usize, 1), blocked_summary.blocked_count);

    const leaking_context =
        "@push atom x=10 color=#112233ff\n" ++
        "@pop atom id=inside text=Inside\n" ++
        "@pushslide unsafe\n" ++
        "@box id=following y=200 text=Following\n";
    const leaking_summary = try cleanupSummary(std.testing.allocator, leaking_context);
    try std.testing.expectEqual(@as(usize, 0), leaking_summary.removable_count);
    try std.testing.expectEqual(@as(usize, 1), leaking_summary.blocked_count);
}

test "cleanup retains an unused push that clears a live persistent component context" {
    const source =
        "@push base x=10 color=#112233ff\n" ++
        "@slide\n" ++
        "@pop base id=first text=First\n" ++
        "@push unused text=Only a context barrier\n" ++
        "@box id=following y=200 text=Following\n";
    const summary = try cleanupSummary(std.testing.allocator, source);
    try std.testing.expectEqual(@as(usize, 0), summary.removable_count);
    try std.testing.expectEqual(@as(usize, 1), summary.blocked_count);
    try std.testing.expectError(
        error.NoCleanupCandidates,
        cleanupUnusedDefinitions(std.testing.allocator, source),
    );
}

test "cleanup resolves shadowed definition uses exactly" {
    const source =
        "@push card text=Old\n" ++
        "@push card text=New\n" ++
        "@slide\n" ++
        "@pop card id=visible\n";
    const summary = try cleanupSummary(std.testing.allocator, source);
    try std.testing.expectEqual(@as(usize, 1), summary.removable_count);
    const cleaned = try cleanupUnusedDefinitions(std.testing.allocator, source);
    defer cleaned.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, cleaned.source, "text=Old") == null);
    try std.testing.expect(std.mem.indexOf(u8, cleaned.source, "text=New") != null);
}

test "rename rejects target collisions and dynamic context tokens" {
    const collision = "@push one\n@push two\n";
    var catalog = try discover(std.testing.allocator, collision);
    defer catalog.deinit();
    try std.testing.expectError(
        error.NameCollision,
        renameDefinition(std.testing.allocator, collision, catalog.entries[0], "two"),
    );

    const dynamic = "@push one\n@pop $WHICH$\n";
    var dynamic_catalog = try discover(std.testing.allocator, dynamic);
    defer dynamic_catalog.deinit();
    try std.testing.expectError(
        error.DynamicContextName,
        renameDefinition(std.testing.allocator, dynamic, dynamic_catalog.entries[0], "renamed"),
    );

    const dynamic_directive = "@push one\n$DIRECTIVE$ one\n";
    var directive_catalog = try discover(std.testing.allocator, dynamic_directive);
    defer directive_catalog.deinit();
    try std.testing.expectError(
        error.DynamicContextName,
        renameDefinition(std.testing.allocator, dynamic_directive, directive_catalog.entries[0], "renamed"),
    );
}

test "delete refuses live uses and safely removes unused element body" {
    const live = "@push card\nTemplate\n@pop card\n";
    var live_catalog = try discover(std.testing.allocator, live);
    defer live_catalog.deinit();
    try std.testing.expectError(
        error.LiveUses,
        deleteDefinition(std.testing.allocator, live, live_catalog.entries[0]),
    );

    const unused =
        "\xEF\xBB\xBF@slide\r\n" ++
        "@push unused x=1\r\n" ++
        "Template body\r\n" ++
        "# preserved explanation\r\n" ++
        "\r\n" ++
        "@slide\r\n";
    var unused_catalog = try discover(std.testing.allocator, unused);
    defer unused_catalog.deinit();
    const deleted = try deleteDefinition(std.testing.allocator, unused, unused_catalog.entries[0]);
    defer deleted.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "\xEF\xBB\xBF@slide\r\n" ++
            "# preserved explanation\r\n" ++
            "\r\n" ++
            "@slide\r\n",
        deleted.source,
    );
}

test "slide deletion is rejected even when unused" {
    const source = "@box text=Template\n@pushslide content\n";
    var catalog = try discover(std.testing.allocator, source);
    defer catalog.deinit();
    try std.testing.expectError(
        error.UnsafeSlideTemplateDelete,
        deleteDefinition(std.testing.allocator, source, catalog.entries[0]),
    );
}

test "renamed and deleted catalogs round-trip through the slideshow parser" {
    const parser = @import("parser.zig");
    const slides = @import("slides.zig");

    const source =
        "\xEF\xBB\xBF@push card x=20 y=30 w=200 h=80\r\n" ++
        "@slide\r\n" ++
        "@pop card text=First\r\n" ++
        "@push unused x=1\r\n" ++
        "Unused body\r\n" ++
        "# keep this note\r\n" ++
        "@slide\r\n";
    var catalog = try discover(std.testing.allocator, source);
    defer catalog.deinit();

    const renamed = try renameDefinition(std.testing.allocator, source, catalog.entries[0], "badge");
    defer renamed.deinit(std.testing.allocator);
    var renamed_catalog = try discover(std.testing.allocator, renamed.source);
    defer renamed_catalog.deinit();
    const deleted = try deleteDefinition(std.testing.allocator, renamed.source, renamed_catalog.entries[1]);
    defer deleted.deinit(std.testing.allocator);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const slideshow = try slides.SlideShow.new(allocator);
    const context = try parser.constructSlidesFromBuf(deleted.source, slideshow, allocator);
    defer context.deinit();

    try std.testing.expectEqual(@as(usize, 0), context.parser_errors.items.len);
    try std.testing.expectEqual(@as(usize, 2), slideshow.slides.items.len);
    try std.testing.expect(std.mem.indexOf(u8, deleted.source, "@push badge") != null);
    try std.testing.expect(std.mem.indexOf(u8, deleted.source, "@pop badge") != null);
    try std.testing.expect(std.mem.indexOf(u8, deleted.source, "unused") == null);
    try std.testing.expect(std.mem.indexOf(u8, deleted.source, "# keep this note\r\n") != null);

    const slide_source =
        "@box x=0 y=0 w=1920 h=1080 color=#101010ff\n" ++
        "@pushslide content\n" ++
        "@popslide content\n" ++
        "@box text=Instantiated\n";
    var slide_catalog = try discover(std.testing.allocator, slide_source);
    defer slide_catalog.deinit();
    const slide_renamed = try renameDefinition(
        std.testing.allocator,
        slide_source,
        slide_catalog.entries[0],
        "standard",
    );
    defer slide_renamed.deinit(std.testing.allocator);

    const slide_show = try slides.SlideShow.new(allocator);
    const slide_context = try parser.constructSlidesFromBuf(slide_renamed.source, slide_show, allocator);
    defer slide_context.deinit();
    try std.testing.expectEqual(@as(usize, 0), slide_context.parser_errors.items.len);
    try std.testing.expect(std.mem.indexOf(u8, slide_renamed.source, "@pushslide standard") != null);
    try std.testing.expect(std.mem.indexOf(u8, slide_renamed.source, "@popslide standard") != null);
}
