const std = @import("std");

pub const utf8_bom = "\xEF\xBB\xBF";

pub const Ending = enum {
    lf,
    crlf,
};

const LineRange = struct {
    start: usize,
    end: usize,
};

/// Exact disk/source formatting that Neovim's logical line API cannot carry.
/// The editor sees normalized UTF-8/LF text without a BOM; writes are rebuilt
/// with the accepted document's BOM and line-ending choices.
pub const Format = struct {
    allocator: std.mem.Allocator,
    normalized: []u8,
    lines: []LineRange,
    endings: []Ending,
    dominant: Ending,
    bom: bool,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) !Format {
        if (!std.unicode.utf8ValidateSlice(source)) return error.InvalidUtf8;
        const has_bom = std.mem.startsWith(u8, source, utf8_bom);
        const body = if (has_bom) source[utf8_bom.len..] else source;

        var normalized: std.ArrayList(u8) = .empty;
        errdefer normalized.deinit(allocator);
        var endings: std.ArrayList(Ending) = .empty;
        errdefer endings.deinit(allocator);
        var lf_count: usize = 0;
        var crlf_count: usize = 0;
        var index: usize = 0;
        while (index < body.len) {
            if (body[index] == '\r' and index + 1 < body.len and body[index + 1] == '\n') {
                try normalized.append(allocator, '\n');
                try endings.append(allocator, .crlf);
                crlf_count += 1;
                index += 2;
            } else if (body[index] == '\n') {
                try normalized.append(allocator, '\n');
                try endings.append(allocator, .lf);
                lf_count += 1;
                index += 1;
            } else {
                try normalized.append(allocator, body[index]);
                index += 1;
            }
        }

        const normalized_owned = try normalized.toOwnedSlice(allocator);
        errdefer allocator.free(normalized_owned);
        const lines = try collectLines(allocator, normalized_owned);
        const dominant: Ending = if (crlf_count > lf_count)
            .crlf
        else if (lf_count > crlf_count)
            .lf
        else if (endings.items.len > 0)
            endings.items[0]
        else
            .lf;
        return .{
            .allocator = allocator,
            .normalized = normalized_owned,
            .lines = lines,
            .endings = try endings.toOwnedSlice(allocator),
            .dominant = dominant,
            .bom = has_bom,
        };
    }

    pub fn deinit(self: *Format) void {
        self.allocator.free(self.normalized);
        self.allocator.free(self.lines);
        self.allocator.free(self.endings);
        self.* = undefined;
    }

    pub fn editorSource(self: *const Format) []const u8 {
        return self.normalized;
    }

    pub fn replaceBaseline(self: *Format, exact_source: []const u8) !void {
        const replacement = try Format.init(self.allocator, exact_source);
        self.deinit();
        self.* = replacement;
    }

    pub fn reconstruct(self: *const Format, editor_source: []const u8, max_bytes: usize) ![]u8 {
        if (!std.unicode.utf8ValidateSlice(editor_source)) return error.InvalidUtf8;
        const candidate_has_bom = std.mem.startsWith(u8, editor_source, utf8_bom);
        const candidate = if (candidate_has_bom) editor_source[utf8_bom.len..] else editor_source;
        const candidate_lines = try collectLines(self.allocator, candidate);
        defer self.allocator.free(candidate_lines);

        var prefix: usize = 0;
        while (prefix < self.lines.len and prefix < candidate_lines.len and
            lineEqual(self.normalized, self.lines[prefix], candidate, candidate_lines[prefix]))
        {
            prefix += 1;
        }
        var suffix: usize = 0;
        while (suffix < self.lines.len -| prefix and suffix < candidate_lines.len -| prefix) {
            const baseline_index = self.lines.len - 1 - suffix;
            const candidate_index = candidate_lines.len - 1 - suffix;
            if (!lineEqual(self.normalized, self.lines[baseline_index], candidate, candidate_lines[candidate_index])) break;
            suffix += 1;
        }

        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.allocator);
        if (self.bom or candidate_has_bom) try output.appendSlice(self.allocator, utf8_bom);
        const newline_count = std.mem.count(u8, candidate, "\n");
        for (candidate_lines, 0..) |line, line_index| {
            try appendBounded(&output, self.allocator, candidate[line.start..line.end], max_bytes);
            if (line_index >= newline_count) continue;
            const ending = self.endingForCandidateLine(
                candidate,
                candidate_lines,
                line_index,
                prefix,
                suffix,
            );
            try appendBounded(&output, self.allocator, switch (ending) {
                .lf => "\n",
                .crlf => "\r\n",
            }, max_bytes);
        }
        if (output.items.len > max_bytes) return error.DocumentTooLarge;
        return output.toOwnedSlice(self.allocator);
    }

    fn endingForCandidateLine(
        self: *const Format,
        candidate: []const u8,
        candidate_lines: []const LineRange,
        line_index: usize,
        prefix: usize,
        suffix: usize,
    ) Ending {
        if (line_index < prefix and line_index < self.endings.len) return self.endings[line_index];
        if (line_index >= candidate_lines.len -| suffix) {
            const distance_from_end = candidate_lines.len - line_index;
            if (distance_from_end <= self.lines.len) {
                const baseline_index = self.lines.len - distance_from_end;
                if (baseline_index < self.endings.len) return self.endings[baseline_index];
            }
        }
        if (line_index < self.lines.len and line_index < self.endings.len and
            lineEqual(self.normalized, self.lines[line_index], candidate, candidate_lines[line_index]))
        {
            return self.endings[line_index];
        }
        return self.dominant;
    }
};

fn appendBounded(list: *std.ArrayList(u8), allocator: std.mem.Allocator, bytes: []const u8, max_bytes: usize) !void {
    if (bytes.len > max_bytes -| list.items.len) return error.DocumentTooLarge;
    try list.appendSlice(allocator, bytes);
}

fn collectLines(allocator: std.mem.Allocator, normalized: []const u8) ![]LineRange {
    var result: std.ArrayList(LineRange) = .empty;
    errdefer result.deinit(allocator);
    var start: usize = 0;
    for (normalized, 0..) |byte, index| {
        if (byte != '\n') continue;
        try result.append(allocator, .{ .start = start, .end = index });
        start = index + 1;
    }
    if (start < normalized.len or normalized.len == 0 or normalized[normalized.len - 1] != '\n') {
        try result.append(allocator, .{ .start = start, .end = normalized.len });
    }
    return result.toOwnedSlice(allocator);
}

fn lineEqual(a: []const u8, a_range: LineRange, b: []const u8, b_range: LineRange) bool {
    return std.mem.eql(u8, a[a_range.start..a_range.end], b[b_range.start..b_range.end]);
}

test "format hides and restores UTF-8 BOM CRLF and final newline" {
    const source = utf8_bom ++ "@slide\r\n@box text=hello\r\n";
    var format = try Format.init(std.testing.allocator, source);
    defer format.deinit();
    try std.testing.expectEqualStrings("@slide\n@box text=hello\n", format.editorSource());
    const reconstructed = try format.reconstruct(format.editorSource(), 1024);
    defer std.testing.allocator.free(reconstructed);
    try std.testing.expectEqualStrings(source, reconstructed);
}

test "mixed endings survive unchanged lines around an insertion" {
    const source = "a\r\nb\nc\r\n";
    var format = try Format.init(std.testing.allocator, source);
    defer format.deinit();
    const reconstructed = try format.reconstruct("a\nb\nx\nc\n", 1024);
    defer std.testing.allocator.free(reconstructed);
    try std.testing.expectEqualStrings("a\r\nb\nx\r\nc\r\n", reconstructed);
}

test "missing final newline and a changed line retain their format contract" {
    var format = try Format.init(std.testing.allocator, utf8_bom ++ "one\r\ntwo");
    defer format.deinit();
    const reconstructed = try format.reconstruct("one\nchanged", 1024);
    defer std.testing.allocator.free(reconstructed);
    try std.testing.expectEqualStrings(utf8_bom ++ "one\r\nchanged", reconstructed);
}

test "accepted writes become the next exact baseline" {
    var format = try Format.init(std.testing.allocator, "a\nb\n");
    defer format.deinit();
    try format.replaceBaseline("a\r\nb\r\n");
    const reconstructed = try format.reconstruct("a\nb\n", 1024);
    defer std.testing.allocator.free(reconstructed);
    try std.testing.expectEqualStrings("a\r\nb\r\n", reconstructed);
}

test "invalid UTF-8 and reconstructed size limits are rejected" {
    try std.testing.expectError(error.InvalidUtf8, Format.init(std.testing.allocator, "\xff"));
    var format = try Format.init(std.testing.allocator, "a\n");
    defer format.deinit();
    try std.testing.expectError(error.DocumentTooLarge, format.reconstruct("abcdef", 3));
}
