const std = @import("std");

/// Resource limits are enforced while discovering the first complete
/// MessagePack value in a byte stream. Neovim and plugins are trusted like an
/// ordinary local editor configuration, but malformed or accidental giant
/// messages must still not exhaust the host process.
pub const Limits = struct {
    max_depth: usize = 64,
    max_container_items: usize = 1_000_000,
    max_blob_bytes: usize = 8 * 1024 * 1024,
    max_frame_bytes: usize = 16 * 1024 * 1024,
};

pub const ScanError = error{
    ReservedMarker,
    NestingTooDeep,
    ContainerTooLarge,
    BlobTooLarge,
    FrameTooLarge,
    IntegerOverflow,
};

/// Returns the byte length of the first complete MessagePack value, or null
/// when more bytes are required. Bytes after that value belong to the next RPC
/// message and are intentionally ignored.
pub fn frameLen(input: []const u8, limits: Limits) ScanError!?usize {
    if (input.len == 0) return null;
    return scanValue(input, 0, 0, limits);
}

fn scanValue(input: []const u8, start: usize, depth: usize, limits: Limits) ScanError!?usize {
    if (start >= input.len) return null;
    const marker = input[start];

    return switch (marker) {
        0x00...0x7f, 0xc0, 0xc2, 0xc3, 0xe0...0xff => scalarEnd(input, start, 1, limits),
        0x80...0x8f => scanMap(input, start, 1, marker & 0x0f, depth, limits),
        0x90...0x9f => scanArray(input, start, 1, marker & 0x0f, depth, limits),
        0xa0...0xbf => payloadEnd(input, start, 1, marker & 0x1f, limits),
        0xc1 => error.ReservedMarker,
        0xc4 => scanBlobWithLength(input, start, 1, 1, limits),
        0xc5 => scanBlobWithLength(input, start, 2, 1, limits),
        0xc6 => scanBlobWithLength(input, start, 4, 1, limits),
        0xc7 => scanBlobWithLength(input, start, 1, 2, limits),
        0xc8 => scanBlobWithLength(input, start, 2, 2, limits),
        0xc9 => scanBlobWithLength(input, start, 4, 2, limits),
        0xca, 0xce, 0xd2 => scalarEnd(input, start, 5, limits),
        0xcb, 0xcf, 0xd3 => scalarEnd(input, start, 9, limits),
        0xcc, 0xd0 => scalarEnd(input, start, 2, limits),
        0xcd, 0xd1 => scalarEnd(input, start, 3, limits),
        0xd4 => payloadEnd(input, start, 2, 1, limits),
        0xd5 => payloadEnd(input, start, 2, 2, limits),
        0xd6 => payloadEnd(input, start, 2, 4, limits),
        0xd7 => payloadEnd(input, start, 2, 8, limits),
        0xd8 => payloadEnd(input, start, 2, 16, limits),
        0xd9 => scanBlobWithLength(input, start, 1, 1, limits),
        0xda => scanBlobWithLength(input, start, 2, 1, limits),
        0xdb => scanBlobWithLength(input, start, 4, 1, limits),
        0xdc => scanContainerWithLength(input, start, 2, false, depth, limits),
        0xdd => scanContainerWithLength(input, start, 4, false, depth, limits),
        0xde => scanContainerWithLength(input, start, 2, true, depth, limits),
        0xdf => scanContainerWithLength(input, start, 4, true, depth, limits),
    };
}

fn scalarEnd(input: []const u8, start: usize, width: usize, limits: Limits) ScanError!?usize {
    const end = std.math.add(usize, start, width) catch return error.IntegerOverflow;
    if (end > limits.max_frame_bytes) return error.FrameTooLarge;
    if (end > input.len) return null;
    return end;
}

fn payloadEnd(
    input: []const u8,
    start: usize,
    header_width: usize,
    payload_len: usize,
    limits: Limits,
) ScanError!?usize {
    if (payload_len > limits.max_blob_bytes) return error.BlobTooLarge;
    const payload_start = std.math.add(usize, start, header_width) catch return error.IntegerOverflow;
    const end = std.math.add(usize, payload_start, payload_len) catch return error.IntegerOverflow;
    if (end > limits.max_frame_bytes) return error.FrameTooLarge;
    if (end > input.len) return null;
    return end;
}

fn scanBlobWithLength(
    input: []const u8,
    start: usize,
    length_width: usize,
    extra_header_width: usize,
    limits: Limits,
) ScanError!?usize {
    const payload_len = readUnsigned(input, start + 1, length_width) orelse return null;
    const header_width = std.math.add(usize, 1 + length_width, extra_header_width - 1) catch
        return error.IntegerOverflow;
    return payloadEnd(input, start, header_width, payload_len, limits);
}

fn scanContainerWithLength(
    input: []const u8,
    start: usize,
    length_width: usize,
    is_map: bool,
    depth: usize,
    limits: Limits,
) ScanError!?usize {
    const count = readUnsigned(input, start + 1, length_width) orelse return null;
    if (count > limits.max_container_items) return error.ContainerTooLarge;
    const header_width = 1 + length_width;
    return if (is_map)
        scanMap(input, start, header_width, count, depth, limits)
    else
        scanArray(input, start, header_width, count, depth, limits);
}

fn scanArray(
    input: []const u8,
    start: usize,
    header_width: usize,
    value_count: usize,
    depth: usize,
    limits: Limits,
) ScanError!?usize {
    if (value_count > limits.max_container_items) return error.ContainerTooLarge;
    return scanContainer(input, start, header_width, value_count, depth, limits);
}

fn scanMap(
    input: []const u8,
    start: usize,
    header_width: usize,
    pair_count: usize,
    depth: usize,
    limits: Limits,
) ScanError!?usize {
    if (pair_count > limits.max_container_items) return error.ContainerTooLarge;
    const value_count = std.math.mul(usize, pair_count, 2) catch return error.IntegerOverflow;
    return scanContainer(input, start, header_width, value_count, depth, limits);
}

fn scanContainer(
    input: []const u8,
    start: usize,
    header_width: usize,
    value_count: usize,
    depth: usize,
    limits: Limits,
) ScanError!?usize {
    if (depth >= limits.max_depth) return error.NestingTooDeep;
    var cursor = std.math.add(usize, start, header_width) catch return error.IntegerOverflow;
    if (cursor > limits.max_frame_bytes) return error.FrameTooLarge;
    if (cursor > input.len) return null;

    for (0..value_count) |_| {
        cursor = (try scanValue(input, cursor, depth + 1, limits)) orelse return null;
    }
    return cursor;
}

fn readUnsigned(input: []const u8, start: usize, width: usize) ?usize {
    const end = std.math.add(usize, start, width) catch return null;
    if (end > input.len) return null;
    return switch (width) {
        1 => input[start],
        2 => std.mem.readInt(u16, input[start..end][0..2], .big),
        4 => std.math.cast(usize, std.mem.readInt(u32, input[start..end][0..4], .big)),
        else => unreachable,
    };
}

test "incremental RPC request framing and concatenated messages" {
    const request = [_]u8{
        0x94, 0x00, 0x01, 0xae,
        'n',  'v',  'i',  'm',
        '_',  'u',  'i',  '_',
        'a',  't',  't',  'a',
        'c',  'h',  0x93, 0x28,
        0x0a, 0x82, 0xa3, 'r',
        'g',  'b',  0xc3, 0xac,
        'e',  'x',  't',  '_',
        'l',  'i',  'n',  'e',
        'g',  'r',  'i',  'd',
        0xc3,
    };

    for (0..request.len) |prefix_len| {
        try std.testing.expectEqual(@as(?usize, null), try frameLen(request[0..prefix_len], .{}));
    }
    try std.testing.expectEqual(@as(?usize, request.len), try frameLen(&request, .{}));

    const joined = request ++ request;
    try std.testing.expectEqual(@as(?usize, request.len), try frameLen(&joined, .{}));
}

test "all scalar and extension widths are framed" {
    const cases = [_][]const u8{
        &.{0x00},
        &.{0xff},
        &.{0xc0},
        &.{0xc2},
        &.{ 0xcc, 0x01 },
        &.{ 0xcd, 0x00, 0x01 },
        &.{ 0xce, 0x00, 0x00, 0x00, 0x01 },
        &.{ 0xcf, 0, 0, 0, 0, 0, 0, 0, 1 },
        &.{ 0xca, 0, 0, 0, 0 },
        &.{ 0xcb, 0, 0, 0, 0, 0, 0, 0, 0 },
        &.{ 0xd0, 0 },
        &.{ 0xd1, 0, 0 },
        &.{ 0xd2, 0, 0, 0, 0 },
        &.{ 0xd3, 0, 0, 0, 0, 0, 0, 0, 0 },
        &.{ 0xd4, 1, 0xaa },
        &.{ 0xd5, 1, 0xaa, 0xbb },
        &.{ 0xd6, 1, 0xaa, 0xbb, 0xcc, 0xdd },
        &.{ 0xd7, 1, 0, 0, 0, 0, 0, 0, 0, 0 },
        &.{ 0xd8, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        &.{ 0xc7, 3, 42, 'a', 'b', 'c' },
        &.{ 0xc8, 0, 1, 42, 'x' },
        &.{ 0xc9, 0, 0, 0, 1, 42, 'x' },
    };
    for (cases) |encoded| {
        try std.testing.expectEqual(@as(?usize, encoded.len), try frameLen(encoded, .{}));
        if (encoded.len > 1) {
            try std.testing.expectEqual(@as(?usize, null), try frameLen(encoded[0 .. encoded.len - 1], .{}));
        }
    }
}

test "strings binaries arrays and maps are framed without interpreting values" {
    const cases = [_][]const u8{
        &.{ 0xa3, 's', 'l', 'd' },
        &.{ 0xd9, 3, 's', 'l', 'd' },
        &.{ 0xda, 0, 3, 's', 'l', 'd' },
        &.{ 0xdb, 0, 0, 0, 3, 's', 'l', 'd' },
        &.{ 0xc4, 2, 0, 1 },
        &.{ 0xc5, 0, 2, 0, 1 },
        &.{ 0xc6, 0, 0, 0, 2, 0, 1 },
        &.{ 0x92, 0x01, 0x02 },
        &.{ 0xdc, 0, 2, 0x01, 0x02 },
        &.{ 0xdd, 0, 0, 0, 2, 0x01, 0x02 },
        &.{ 0x81, 0xa1, 'a', 0x01 },
        &.{ 0xde, 0, 1, 0xa1, 'a', 0x01 },
        &.{ 0xdf, 0, 0, 0, 1, 0xa1, 'a', 0x01 },
    };
    for (cases) |encoded| {
        try std.testing.expectEqual(@as(?usize, encoded.len), try frameLen(encoded, .{}));
    }
}

test "invalid and resource-exhausting frames fail before allocation" {
    try std.testing.expectError(error.ReservedMarker, frameLen(&.{0xc1}, .{}));
    try std.testing.expectError(error.NestingTooDeep, frameLen(&.{ 0x91, 0x91, 0x90 }, .{ .max_depth = 2 }));
    try std.testing.expectError(error.ContainerTooLarge, frameLen(&.{ 0x93, 0, 0, 0 }, .{ .max_container_items = 2 }));
    try std.testing.expectError(error.ContainerTooLarge, frameLen(&.{ 0xdd, 0, 0, 0, 3 }, .{ .max_container_items = 2 }));
    try std.testing.expectError(error.ContainerTooLarge, frameLen(&.{ 0xdf, 0, 0, 0, 2 }, .{ .max_container_items = 1 }));
    try std.testing.expectError(error.BlobTooLarge, frameLen(&.{ 0xd9, 4 }, .{ .max_blob_bytes = 3 }));
    try std.testing.expectError(error.FrameTooLarge, frameLen(&.{ 0xd9, 4 }, .{ .max_frame_bytes = 5 }));
}
