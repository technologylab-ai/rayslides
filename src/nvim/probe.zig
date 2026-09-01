const std = @import("std");
const framing = @import("framing.zig");
const grid = @import("grid.zig");
const rpc = @import("rpc.zig");

pub const Result = struct {
    saw_grid_line: bool = false,
    saw_flush: bool = false,
    edited_buffer: bool = false,
    grid_width: usize = 0,
    grid_height: usize = 0,
};

const ProbeError = error{
    ChildClosedStream,
    NeovimRpcError,
    UnexpectedBufferContents,
    ChildExitFailed,
};

pub fn run(io: std.Io, allocator: std.mem.Allocator, executable: []const u8) !Result {
    var child = try std.process.spawn(io, .{
        .argv = &.{ executable, "--clean", "--embed" },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    defer if (child.id != null) child.kill(io);

    var stdin_buffer: [4096]u8 = undefined;
    var stdin_writer = child.stdin.?.writerStreaming(io, &stdin_buffer);
    var stdout_buffer: [16 * 1024]u8 = undefined;
    var stdout_reader = child.stdout.?.readerStreaming(io, &stdout_buffer);
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(allocator);
    var encoder = rpc.Encoder.init(allocator);
    defer encoder.deinit();
    var result: Result = .{};
    var grid_model = grid.Model.init(allocator);
    defer grid_model.deinit();

    try encoder.beginRequest(1, "nvim_ui_attach", 3);
    try encoder.writeUint(40);
    try encoder.writeUint(10);
    try encoder.writeMapHeader(2);
    try encoder.writeString("rgb");
    try encoder.writeBool(true);
    try encoder.writeString("ext_linegrid");
    try encoder.writeBool(true);
    try send(&stdin_writer.interface, encoder.bytes());
    std.debug.print("Neovim probe: waiting for UI attach\n", .{});
    try waitForResponse(&stdout_reader.interface, allocator, &pending, 1, null, &result, &grid_model);
    std.debug.print("Neovim probe: UI attached\n", .{});

    try encoder.beginRequest(2, "nvim_input", 1);
    try encoder.writeString("ihello<Esc>");
    try send(&stdin_writer.interface, encoder.bytes());
    try waitForResponse(&stdout_reader.interface, allocator, &pending, 2, null, &result, &grid_model);
    std.debug.print("Neovim probe: input accepted\n", .{});

    try encoder.beginRequest(3, "nvim_buf_get_lines", 4);
    try encoder.writeUint(0);
    try encoder.writeInt(0);
    try encoder.writeInt(-1);
    try encoder.writeBool(true);
    try send(&stdin_writer.interface, encoder.bytes());
    try waitForResponse(&stdout_reader.interface, allocator, &pending, 3, "hello", &result, &grid_model);
    result.edited_buffer = true;
    std.debug.print("Neovim probe: buffer round-trip verified\n", .{});

    try encoder.beginRequest(4, "nvim_command", 1);
    try encoder.writeString("qa!");
    try send(&stdin_writer.interface, encoder.bytes());
    std.debug.print("Neovim probe: waiting for clean child exit\n", .{});

    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) return error.ChildExitFailed,
        else => return error.ChildExitFailed,
    }
    if (!result.saw_grid_line or !result.saw_flush) return error.NeovimRpcError;
    result.grid_width = grid_model.width;
    result.grid_height = grid_model.height;
    if (result.grid_width != 40 or result.grid_height != 10) return error.NeovimRpcError;
    return result;
}

fn send(writer: *std.Io.Writer, bytes: []const u8) !void {
    try writer.writeAll(bytes);
    try writer.flush();
}

fn waitForResponse(
    reader: *std.Io.Reader,
    allocator: std.mem.Allocator,
    pending: *std.ArrayList(u8),
    wanted_id: u64,
    expected_line: ?[]const u8,
    result: *Result,
    grid_model: *grid.Model,
) !void {
    while (true) {
        while (try framing.frameLen(pending.items, .{})) |frame_len| {
            const matched = try inspectFrame(pending.items[0..frame_len], wanted_id, expected_line, result, grid_model);
            consumePrefix(pending, frame_len);
            if (matched) return;
        }

        reader.fillMore() catch |err| switch (err) {
            error.EndOfStream => return error.ChildClosedStream,
            else => |other| return other,
        };
        const chunk = reader.buffered();
        if (chunk.len == 0) continue;
        const limits: framing.Limits = .{};
        if (pending.items.len + chunk.len > limits.max_frame_bytes) return error.FrameTooLarge;
        try pending.appendSlice(allocator, chunk);
        reader.toss(chunk.len);
    }
}

fn inspectFrame(
    frame: []const u8,
    wanted_id: u64,
    expected_line: ?[]const u8,
    result: *Result,
    grid_model: *grid.Model,
) !bool {
    var view: rpc.View = .{};
    try view.init(frame);
    defer view.deinit();

    switch (try view.kind()) {
        .request => return false,
        .notification => {
            if (!std.mem.eql(u8, try view.method(), "redraw")) return false;
            _ = try grid_model.applyNotification(&view);
            const batches = try view.params();
            for (0..try view.arrayLen(batches)) |batch_index| {
                const batch = try view.arrayAt(batches, batch_index);
                if (try view.arrayLen(batch) == 0) continue;
                const name = try view.string(try view.arrayAt(batch, 0));
                if (std.mem.eql(u8, name, "grid_line")) result.saw_grid_line = true;
                if (std.mem.eql(u8, name, "flush")) result.saw_flush = true;
            }
            return false;
        },
        .response => {
            if (try view.requestId() != wanted_id) return false;
            if (!try view.isNil(try view.responseError())) return error.NeovimRpcError;
            if (expected_line) |line| {
                const response = try view.result();
                if (try view.arrayLen(response) != 1) return error.UnexpectedBufferContents;
                if (!std.mem.eql(u8, try view.string(try view.arrayAt(response, 0)), line))
                    return error.UnexpectedBufferContents;
            }
            return true;
        },
    }
}

fn consumePrefix(pending: *std.ArrayList(u8), count: usize) void {
    const remaining = pending.items.len - count;
    std.mem.copyForwards(u8, pending.items[0..remaining], pending.items[count..]);
    pending.items.len = remaining;
}

test "redraw inspection tolerates unknown groups and records essential events" {
    // [2, "redraw", [["future_event", [1]], ["grid_line"], ["flush"]]]
    const frame = [_]u8{
        0x93, 0x02, 0xa6, 'r', 'e',  'd',  'r',  'a',  'w',  0x93,
        0x92, 0xac, 'f',  'u', 't',  'u',  'r',  'e',  '_',  'e',
        'v',  'e',  'n',  't', 0x91, 0x91, 0x01, 0x91, 0xa9, 'g',
        'r',  'i',  'd',  '_', 'l',  'i',  'n',  'e',  0x91, 0xa5,
        'f',  'l',  'u',  's', 'h',
    };
    var result: Result = .{};
    var grid_model = grid.Model.init(std.testing.allocator);
    defer grid_model.deinit();
    try std.testing.expect(!try inspectFrame(&frame, 1, null, &result, &grid_model));
    try std.testing.expect(result.saw_grid_line);
    try std.testing.expect(result.saw_flush);
}
