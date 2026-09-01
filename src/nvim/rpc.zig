const std = @import("std");
const c = @import("mpack.zig").c;

pub const Kind = enum {
    request,
    response,
    notification,
};

pub const DecodeError = error{
    MalformedMessage,
    UnexpectedShape,
    ValueOutOfRange,
};

pub const Node = c.mpack_node_t;

/// Borrowed view over one complete MessagePack-RPC frame. `frame` must remain
/// alive and the view must stay at a stable address from init through deinit,
/// because MPack nodes point both into the frame and back to this tree.
pub const View = struct {
    tree: c.mpack_tree_t = undefined,
    initialized: bool = false,

    pub fn init(self: *View, frame: []const u8) DecodeError!void {
        self.* = .{};
        c.mpack_tree_init_data(&self.tree, @ptrCast(frame.ptr), frame.len);
        self.initialized = true;
        c.mpack_tree_set_limits(&self.tree, frame.len, 1_000_000);
        c.mpack_tree_parse(&self.tree);
        if (c.mpack_tree_error(&self.tree) != c.mpack_ok) {
            self.deinit();
            return error.MalformedMessage;
        }
    }

    pub fn deinit(self: *View) void {
        if (!self.initialized) return;
        _ = c.mpack_tree_destroy(&self.tree);
        self.initialized = false;
    }

    pub fn kind(self: *View) DecodeError!Kind {
        const root_node = try self.root();
        const len = try self.arrayLen(root_node);
        if (len < 3) return error.UnexpectedShape;
        const marker = try self.uint(try self.arrayAt(root_node, 0));
        const message_kind: Kind = switch (marker) {
            0 => .request,
            1 => .response,
            2 => .notification,
            else => return error.UnexpectedShape,
        };
        const expected_len: usize = switch (message_kind) {
            .request, .response => 4,
            .notification => 3,
        };
        if (len != expected_len) return error.UnexpectedShape;
        return message_kind;
    }

    pub fn requestId(self: *View) DecodeError!u64 {
        const message_kind = try self.kind();
        if (message_kind == .notification) return error.UnexpectedShape;
        return self.uint(try self.arrayAt(try self.root(), 1));
    }

    pub fn method(self: *View) DecodeError![]const u8 {
        const message_kind = try self.kind();
        const index: usize = switch (message_kind) {
            .request => 2,
            .notification => 1,
            .response => return error.UnexpectedShape,
        };
        return self.string(try self.arrayAt(try self.root(), index));
    }

    pub fn params(self: *View) DecodeError!Node {
        const message_kind = try self.kind();
        const index: usize = switch (message_kind) {
            .request => 3,
            .notification => 2,
            .response => return error.UnexpectedShape,
        };
        const node = try self.arrayAt(try self.root(), index);
        if (c.mpack_node_type(node) != c.mpack_type_array) return error.UnexpectedShape;
        try self.check();
        return node;
    }

    pub fn responseError(self: *View) DecodeError!Node {
        if (try self.kind() != .response) return error.UnexpectedShape;
        return self.arrayAt(try self.root(), 2);
    }

    pub fn result(self: *View) DecodeError!Node {
        if (try self.kind() != .response) return error.UnexpectedShape;
        return self.arrayAt(try self.root(), 3);
    }

    pub fn root(self: *View) DecodeError!Node {
        if (!self.initialized) return error.MalformedMessage;
        const node = c.mpack_tree_root(&self.tree);
        try self.check();
        return node;
    }

    pub fn arrayLen(self: *View, node: Node) DecodeError!usize {
        const len = c.mpack_node_array_length(node);
        try self.check();
        return len;
    }

    pub fn arrayAt(self: *View, node: Node, index: usize) DecodeError!Node {
        const child = c.mpack_node_array_at(node, index);
        try self.check();
        return child;
    }

    pub fn uint(self: *View, node: Node) DecodeError!u64 {
        const value = c.mpack_node_u64(node);
        try self.check();
        return value;
    }

    pub fn int(self: *View, node: Node) DecodeError!i64 {
        const value = c.mpack_node_i64(node);
        try self.check();
        return value;
    }

    pub fn boolean(self: *View, node: Node) DecodeError!bool {
        const value = c.mpack_node_bool(node);
        try self.check();
        return value;
    }

    pub fn string(self: *View, node: Node) DecodeError![]const u8 {
        const len = c.mpack_node_strlen(node);
        const ptr = c.mpack_node_str(node);
        try self.check();
        if (len == 0) return "";
        if (ptr == null) return error.MalformedMessage;
        return @as([*]const u8, @ptrCast(ptr))[0..len];
    }

    pub fn isNil(self: *View, node: Node) DecodeError!bool {
        const nil_value = c.mpack_node_is_nil(node);
        try self.check();
        return nil_value;
    }

    pub fn mapLen(self: *View, node: Node) DecodeError!usize {
        const len = c.mpack_node_map_count(node);
        try self.check();
        return len;
    }

    pub fn mapKeyAt(self: *View, node: Node, index: usize) DecodeError!Node {
        const child = c.mpack_node_map_key_at(node, index);
        try self.check();
        return child;
    }

    pub fn mapValueAt(self: *View, node: Node, index: usize) DecodeError!Node {
        const child = c.mpack_node_map_value_at(node, index);
        try self.check();
        return child;
    }

    fn check(self: *View) DecodeError!void {
        if (c.mpack_tree_error(&self.tree) != c.mpack_ok) return error.MalformedMessage;
    }
};

pub const Encoder = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) Encoder {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Encoder) void {
        self.buffer.deinit(self.allocator);
    }

    pub fn reset(self: *Encoder) void {
        self.buffer.clearRetainingCapacity();
    }

    pub fn bytes(self: *const Encoder) []const u8 {
        return self.buffer.items;
    }

    pub fn beginRequest(self: *Encoder, id: u64, method_name: []const u8, param_count: usize) !void {
        self.reset();
        try self.writeArrayHeader(4);
        try self.writeUint(0);
        try self.writeUint(id);
        try self.writeString(method_name);
        try self.writeArrayHeader(param_count);
    }

    pub fn beginNotification(self: *Encoder, method_name: []const u8, param_count: usize) !void {
        self.reset();
        try self.writeArrayHeader(3);
        try self.writeUint(2);
        try self.writeString(method_name);
        try self.writeArrayHeader(param_count);
    }

    pub fn beginResponse(self: *Encoder, id: u64) !void {
        self.reset();
        try self.writeArrayHeader(4);
        try self.writeUint(1);
        try self.writeUint(id);
    }

    pub fn writeNil(self: *Encoder) !void {
        try self.buffer.append(self.allocator, 0xc0);
    }

    pub fn writeBool(self: *Encoder, value: bool) !void {
        try self.buffer.append(self.allocator, if (value) 0xc3 else 0xc2);
    }

    pub fn writeUint(self: *Encoder, value: u64) !void {
        if (value <= 0x7f) {
            try self.buffer.append(self.allocator, @intCast(value));
        } else if (value <= std.math.maxInt(u8)) {
            try self.buffer.append(self.allocator, 0xcc);
            try self.appendInt(u8, @intCast(value));
        } else if (value <= std.math.maxInt(u16)) {
            try self.buffer.append(self.allocator, 0xcd);
            try self.appendInt(u16, @intCast(value));
        } else if (value <= std.math.maxInt(u32)) {
            try self.buffer.append(self.allocator, 0xce);
            try self.appendInt(u32, @intCast(value));
        } else {
            try self.buffer.append(self.allocator, 0xcf);
            try self.appendInt(u64, value);
        }
    }

    pub fn writeInt(self: *Encoder, value: i64) !void {
        if (value >= 0) return self.writeUint(@intCast(value));
        if (value >= -32) {
            try self.buffer.append(self.allocator, @bitCast(@as(i8, @intCast(value))));
        } else if (value >= std.math.minInt(i8)) {
            try self.buffer.append(self.allocator, 0xd0);
            try self.appendInt(i8, @intCast(value));
        } else if (value >= std.math.minInt(i16)) {
            try self.buffer.append(self.allocator, 0xd1);
            try self.appendInt(i16, @intCast(value));
        } else if (value >= std.math.minInt(i32)) {
            try self.buffer.append(self.allocator, 0xd2);
            try self.appendInt(i32, @intCast(value));
        } else {
            try self.buffer.append(self.allocator, 0xd3);
            try self.appendInt(i64, value);
        }
    }

    pub fn writeString(self: *Encoder, value: []const u8) !void {
        if (value.len <= 31) {
            try self.buffer.append(self.allocator, 0xa0 | @as(u8, @intCast(value.len)));
        } else if (value.len <= std.math.maxInt(u8)) {
            try self.buffer.append(self.allocator, 0xd9);
            try self.appendInt(u8, @intCast(value.len));
        } else if (value.len <= std.math.maxInt(u16)) {
            try self.buffer.append(self.allocator, 0xda);
            try self.appendInt(u16, @intCast(value.len));
        } else if (value.len <= std.math.maxInt(u32)) {
            try self.buffer.append(self.allocator, 0xdb);
            try self.appendInt(u32, @intCast(value.len));
        } else return error.StringTooLong;
        try self.buffer.appendSlice(self.allocator, value);
    }

    pub fn writeArrayHeader(self: *Encoder, count: usize) !void {
        if (count <= 15) {
            try self.buffer.append(self.allocator, 0x90 | @as(u8, @intCast(count)));
        } else if (count <= std.math.maxInt(u16)) {
            try self.buffer.append(self.allocator, 0xdc);
            try self.appendInt(u16, @intCast(count));
        } else if (count <= std.math.maxInt(u32)) {
            try self.buffer.append(self.allocator, 0xdd);
            try self.appendInt(u32, @intCast(count));
        } else return error.ContainerTooLarge;
    }

    pub fn writeMapHeader(self: *Encoder, count: usize) !void {
        if (count <= 15) {
            try self.buffer.append(self.allocator, 0x80 | @as(u8, @intCast(count)));
        } else if (count <= std.math.maxInt(u16)) {
            try self.buffer.append(self.allocator, 0xde);
            try self.appendInt(u16, @intCast(count));
        } else if (count <= std.math.maxInt(u32)) {
            try self.buffer.append(self.allocator, 0xdf);
            try self.appendInt(u32, @intCast(count));
        } else return error.ContainerTooLarge;
    }

    fn appendInt(self: *Encoder, comptime T: type, value: T) !void {
        var encoded: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &encoded, value, .big);
        try self.buffer.appendSlice(self.allocator, &encoded);
    }
};

test "RPC view validates and exposes request response and notification shapes" {
    const cases = [_]struct {
        bytes: []const u8,
        kind: Kind,
    }{
        .{ .bytes = &.{ 0x94, 0x00, 0x07, 0xa1, 'm', 0x90 }, .kind = .request },
        .{ .bytes = &.{ 0x94, 0x01, 0x07, 0xc0, 0xa2, 'o', 'k' }, .kind = .response },
        .{ .bytes = &.{ 0x93, 0x02, 0xa6, 'r', 'e', 'd', 'r', 'a', 'w', 0x90 }, .kind = .notification },
    };
    for (cases) |case| {
        var view: View = .{};
        try view.init(case.bytes);
        defer view.deinit();
        try std.testing.expectEqual(case.kind, try view.kind());
    }
}

test "RPC encoder produces a canonical UI attach request understood by MPack" {
    var encoder = Encoder.init(std.testing.allocator);
    defer encoder.deinit();
    try encoder.beginRequest(1, "nvim_ui_attach", 3);
    try encoder.writeUint(40);
    try encoder.writeUint(10);
    try encoder.writeMapHeader(2);
    try encoder.writeString("rgb");
    try encoder.writeBool(true);
    try encoder.writeString("ext_linegrid");
    try encoder.writeBool(true);

    var view: View = .{};
    try view.init(encoder.bytes());
    defer view.deinit();
    try std.testing.expectEqual(Kind.request, try view.kind());
    try std.testing.expectEqual(@as(u64, 1), try view.requestId());
    try std.testing.expectEqualStrings("nvim_ui_attach", try view.method());
    try std.testing.expectEqual(@as(usize, 3), try view.arrayLen(try view.params()));
}

test "RPC encoder uses compact signed and unsigned integer forms" {
    var encoder = Encoder.init(std.testing.allocator);
    defer encoder.deinit();
    try encoder.writeInt(-1);
    try encoder.writeInt(-33);
    try encoder.writeUint(128);
    try encoder.writeUint(65_536);
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0xd0, 0xdf, 0xcc, 0x80, 0xce, 0x00, 0x01, 0x00, 0x00 }, encoder.bytes());
}
