const std = @import("std");
const builtin = @import("builtin");
const framing = @import("framing.zig");
const grid = @import("grid.zig");
const rpc = @import("rpc.zig");
const source_format = @import("source_format.zig");

const log = std.log.scoped(.neovim);

pub const default_width = 100;
pub const default_height = 32;
pub const max_document_bytes = 2 * 1024 * 1024;
pub const stderr_tail_capacity = 16 * 1024;

const attach_request_id: u64 = 1;
const api_info_request_id: u64 = 2;

pub const State = enum {
    starting,
    ready,
    closed,
    failed,
};

pub const Failure = enum {
    none,
    stdout_closed,
    malformed_rpc,
    protocol_error,
    io_error,
};

pub const Apply = struct {
    /// Borrowed until the matching accept/reject call. The reader is parked,
    /// so this slice remains stable while the main thread validates it.
    source: []const u8,
    opening_revision: usize,
};

pub const BufferKind = enum {
    source,
    text,
    speaker_notes,

    fn name(self: BufferKind) []const u8 {
        return switch (self) {
            .source => "rayslides://document/current.sld",
            .text => "rayslides://field/text.sld",
            .speaker_notes => "rayslides://field/speaker-notes.sld",
        };
    }
};

const ApplyResponse = union(enum) {
    accepted,
    rejected: []u8,
};

const PendingApply = struct {
    request_id: u64,
    source: []u8,
    handed_to_main: bool = false,
    response: ?ApplyResponse = null,
};

pub const PaintCell = struct {
    cell: grid.Cell,
    highlight: grid.Highlight,
};

/// An immutable main-thread copy of one flushed line-grid state. No MPack
/// nodes, child-pipe storage, or hash-map entries escape the reader thread.
pub const Snapshot = struct {
    allocator: std.mem.Allocator,
    width: usize,
    height: usize,
    cells: []PaintCell,
    default_foreground: ?grid.Color,
    default_background: ?grid.Color,
    default_special: ?grid.Color,
    cursor_row: usize,
    cursor_col: usize,
    cursor_visible: bool,
    cursor_style: grid.CursorStyle,
    mode_name: [32]u8,
    mode_name_len: u8,
    mouse_enabled: bool,
    busy: bool,
    flush_revision: u64,

    pub fn deinit(self: *Snapshot) void {
        self.allocator.free(self.cells);
        self.* = undefined;
    }

    pub fn mode(self: *const Snapshot) []const u8 {
        return self.mode_name[0..self.mode_name_len];
    }
};

/// Stable heap-owned embedded Neovim process. The blocking stdout and stderr
/// readers borrow this address until `deinit` joins them, so callers must not
/// copy or move the value returned by `start`.
pub const Session = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    child: std.process.Child,
    reader_thread: ?std.Thread = null,
    stderr_thread: ?std.Thread = null,
    state_mutex: std.Io.Mutex = .init,
    writer_mutex: std.Io.Mutex = .init,
    apply_condition: std.Io.Condition = .init,
    model: grid.Model,
    state_value: State = .starting,
    failure_value: Failure = .none,
    stopping: bool = false,
    attach_complete: bool = false,
    channel_id: ?u64 = null,
    buffer_configured: bool = false,
    close_requested: bool = false,
    opening_revision: usize,
    next_request_id: u64 = 3,
    pending_apply: ?PendingApply = null,
    source_format_value: ?source_format.Format = null,
    stderr_tail: [stderr_tail_capacity]u8 = undefined,
    stderr_start: usize = 0,
    stderr_len: usize = 0,

    pub fn start(
        io: std.Io,
        allocator: std.mem.Allocator,
        executable: []const u8,
        clean: bool,
        width: usize,
        height: usize,
        opening_revision: usize,
    ) !*Session {
        const argv: []const []const u8 = if (clean)
            &.{ executable, "--clean", "--embed" }
        else
            &.{ executable, "--embed" };
        var child = try std.process.spawn(io, .{
            .argv = argv,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
        });
        errdefer child.kill(io);

        const self = try allocator.create(Session);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .child = child,
            .model = grid.Model.init(allocator),
            .opening_revision = opening_revision,
        };
        errdefer self.model.deinit();

        self.reader_thread = try std.Thread.spawn(.{}, readerThreadMain, .{self});
        errdefer {
            terminateChildProcess(&self.child);
            self.reader_thread.?.join();
            self.reader_thread = null;
        }
        self.stderr_thread = try std.Thread.spawn(.{}, stderrThreadMain, .{self});
        errdefer {
            terminateChildProcess(&self.child);
            if (self.stderr_thread) |thread| thread.join();
            self.stderr_thread = null;
        }

        self.sendUiAttach(width, height) catch |err| {
            self.deinit();
            return err;
        };
        self.sendApiInfo() catch |err| {
            self.deinit();
            return err;
        };
        return self;
    }

    pub fn deinit(self: *Session) void {
        self.requestGracefulExit();
        self.state_mutex.lockUncancelable(self.io);
        self.stopping = true;
        self.state_mutex.unlock(self.io);
        self.apply_condition.broadcast(self.io);

        // Kill only our exact child before joining: blocked pipe readers wake
        // on EOF, and no descriptor is closed underneath a live reader.
        terminateChildProcess(&self.child);
        if (self.reader_thread) |thread| thread.join();
        if (self.stderr_thread) |thread| thread.join();
        self.reader_thread = null;
        self.stderr_thread = null;
        self.child.kill(self.io);

        if (self.pending_apply) |*pending| {
            self.allocator.free(pending.source);
            if (pending.response) |response| switch (response) {
                .accepted => {},
                .rejected => |message| self.allocator.free(message),
            };
        }
        self.pending_apply = null;
        if (self.source_format_value) |*format| format.deinit();
        self.source_format_value = null;
        self.model.deinit();
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    pub fn processId(self: *Session) ?std.process.Child.Id {
        return self.child.id;
    }

    pub fn state(self: *Session) State {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        return self.state_value;
    }

    pub fn failure(self: *Session) Failure {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        return self.failure_value;
    }

    pub fn shouldClose(self: *Session) bool {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        return self.close_requested or self.state_value == .closed or self.state_value == .failed;
    }

    pub fn channelId(self: *Session) ?u64 {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        return self.channel_id;
    }

    /// Configures a private `acwrite` buffer once the attach/API handshake has
    /// completed. Calling this while starting is harmless and returns false;
    /// callers can retry on the next GUI frame.
    pub fn openSourceBuffer(self: *Session, source: []const u8, runtime_path: []const u8) !bool {
        return self.openBuffer(source, runtime_path, .source);
    }

    pub fn openBuffer(
        self: *Session,
        source: []const u8,
        runtime_path: []const u8,
        kind: BufferKind,
    ) !bool {
        var format = try source_format.Format.init(self.allocator, source);
        var format_owned = true;
        defer if (format_owned) format.deinit();
        self.state_mutex.lockUncancelable(self.io);
        if (self.state_value != .ready or self.buffer_configured) {
            self.state_mutex.unlock(self.io);
            return false;
        }
        const channel_id = self.channel_id orelse {
            self.state_mutex.unlock(self.io);
            return false;
        };
        self.buffer_configured = true;
        self.source_format_value = format;
        format_owned = false;
        self.state_mutex.unlock(self.io);
        errdefer {
            self.state_mutex.lockUncancelable(self.io);
            self.buffer_configured = false;
            if (self.source_format_value) |*failed_format| failed_format.deinit();
            self.source_format_value = null;
            self.state_mutex.unlock(self.io);
        }

        var encoder = rpc.Encoder.init(self.allocator);
        defer encoder.deinit();
        const request_id = self.claimRequestId();
        try encoder.beginRequest(request_id, "nvim_exec_lua", 2);
        try encoder.writeString(open_buffer_lua);
        try encoder.writeArrayHeader(5);
        try encoder.writeUint(channel_id);
        try encoder.writeString(runtime_path);
        try encoder.writeString(kind.name());
        try encoder.writeString("rayslides");
        try writeSourceLines(&encoder, self.source_format_value.?.editorSource());
        try self.send(encoder.bytes());
        return true;
    }

    pub fn input(self: *Session, keys: []const u8) !void {
        if (keys.len == 0) return;
        var encoder = rpc.Encoder.init(self.allocator);
        defer encoder.deinit();
        try encoder.beginRequest(self.claimRequestId(), "nvim_input", 1);
        try encoder.writeString(keys);
        try self.send(encoder.bytes());
    }

    pub fn command(self: *Session, command_text: []const u8) !void {
        var encoder = rpc.Encoder.init(self.allocator);
        defer encoder.deinit();
        try encoder.beginRequest(self.claimRequestId(), "nvim_command", 1);
        try encoder.writeString(command_text);
        try self.send(encoder.bytes());
    }

    pub fn paste(self: *Session, text: []const u8) !void {
        if (text.len == 0) return;
        var encoder = rpc.Encoder.init(self.allocator);
        defer encoder.deinit();
        try encoder.beginRequest(self.claimRequestId(), "nvim_paste", 3);
        try encoder.writeString(text);
        try encoder.writeBool(false);
        try encoder.writeInt(-1);
        try self.send(encoder.bytes());
    }

    pub fn focus(self: *Session, focused: bool) !void {
        var encoder = rpc.Encoder.init(self.allocator);
        defer encoder.deinit();
        try encoder.beginRequest(self.claimRequestId(), "nvim_ui_set_focus", 1);
        try encoder.writeBool(focused);
        try self.send(encoder.bytes());
    }

    pub fn resize(self: *Session, width: usize, height: usize) !void {
        var encoder = rpc.Encoder.init(self.allocator);
        defer encoder.deinit();
        try encoder.beginRequest(self.claimRequestId(), "nvim_ui_try_resize", 2);
        try encoder.writeUint(width);
        try encoder.writeUint(height);
        try self.send(encoder.bytes());
    }

    pub fn mouse(
        self: *Session,
        button: []const u8,
        action: []const u8,
        modifier: []const u8,
        row: usize,
        col: usize,
    ) !void {
        var encoder = rpc.Encoder.init(self.allocator);
        defer encoder.deinit();
        try encoder.beginRequest(self.claimRequestId(), "nvim_input_mouse", 6);
        try encoder.writeString(button);
        try encoder.writeString(action);
        try encoder.writeString(modifier);
        try encoder.writeUint(grid.primary_grid_id);
        try encoder.writeUint(row);
        try encoder.writeUint(col);
        try self.send(encoder.bytes());
    }

    pub fn snapshot(self: *Session, allocator: std.mem.Allocator, after_revision: u64) !?Snapshot {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        if (self.model.flush_revision == 0 or self.model.flush_revision == after_revision) return null;

        const cells = try allocator.alloc(PaintCell, self.model.cells.len);
        errdefer allocator.free(cells);
        for (self.model.cells, cells) |cell_value, *paint| {
            paint.* = .{
                .cell = cell_value,
                .highlight = self.model.highlight(cell_value.highlight_id),
            };
        }
        return .{
            .allocator = allocator,
            .width = self.model.width,
            .height = self.model.height,
            .cells = cells,
            .default_foreground = self.model.default_foreground,
            .default_background = self.model.default_background,
            .default_special = self.model.default_special,
            .cursor_row = self.model.cursor_row,
            .cursor_col = self.model.cursor_col,
            .cursor_visible = self.model.cursor_visible,
            .cursor_style = self.model.cursor_style,
            .mode_name = self.model.mode_name,
            .mode_name_len = self.model.mode_name_len,
            .mouse_enabled = self.model.mouse_enabled,
            .busy = self.model.busy,
            .flush_revision = self.model.flush_revision,
        };
    }

    /// Transfers an apply candidate to the main thread exactly once. The
    /// reader remains blocked until `acceptApply` or `rejectApply` answers it.
    pub fn takeApply(self: *Session) ?Apply {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        const pending = if (self.pending_apply) |*value| value else return null;
        if (pending.handed_to_main) return null;
        pending.handed_to_main = true;
        return .{
            .source = pending.source,
            .opening_revision = self.opening_revision,
        };
    }

    pub fn acceptApply(self: *Session, accepted_revision: usize) void {
        self.state_mutex.lockUncancelable(self.io);
        self.opening_revision = accepted_revision;
        self.state_mutex.unlock(self.io);
        self.answerApply(.accepted);
    }

    pub fn rejectApply(self: *Session, message: []const u8) !void {
        const owned = try self.allocator.dupe(u8, message);
        self.answerApply(.{ .rejected = owned });
    }

    pub fn copyStderrTail(self: *Session, output: []u8) []const u8 {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        const count = @min(output.len, self.stderr_len);
        const skip = self.stderr_len - count;
        for (0..count) |index| {
            output[index] = self.stderr_tail[(self.stderr_start + skip + index) % self.stderr_tail.len];
        }
        return output[0..count];
    }

    fn answerApply(self: *Session, response: ApplyResponse) void {
        self.state_mutex.lockUncancelable(self.io);
        if (self.pending_apply) |*pending| {
            if (pending.handed_to_main and pending.response == null) {
                pending.response = response;
                self.state_mutex.unlock(self.io);
                self.apply_condition.signal(self.io);
                return;
            }
        }
        self.state_mutex.unlock(self.io);
        switch (response) {
            .accepted => {},
            .rejected => |message| self.allocator.free(message),
        }
    }

    fn sendUiAttach(self: *Session, width: usize, height: usize) !void {
        var encoder = rpc.Encoder.init(self.allocator);
        defer encoder.deinit();
        try encoder.beginRequest(attach_request_id, "nvim_ui_attach", 3);
        try encoder.writeUint(width);
        try encoder.writeUint(height);
        try encoder.writeMapHeader(2);
        try encoder.writeString("rgb");
        try encoder.writeBool(true);
        try encoder.writeString("ext_linegrid");
        try encoder.writeBool(true);
        try self.send(encoder.bytes());
    }

    fn sendApiInfo(self: *Session) !void {
        var encoder = rpc.Encoder.init(self.allocator);
        defer encoder.deinit();
        try encoder.beginRequest(api_info_request_id, "nvim_get_api_info", 0);
        try self.send(encoder.bytes());
    }

    fn claimRequestId(self: *Session) u64 {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        const result = self.next_request_id;
        self.next_request_id +%= 1;
        if (self.next_request_id < 3) self.next_request_id = 3;
        return result;
    }

    fn send(self: *Session, bytes: []const u8) !void {
        self.writer_mutex.lockUncancelable(self.io);
        defer self.writer_mutex.unlock(self.io);
        var buffer: [16 * 1024]u8 = undefined;
        var writer = self.child.stdin.?.writerStreaming(self.io, &buffer);
        try writer.interface.writeAll(bytes);
        try writer.interface.flush();
    }

    fn noteFailure(self: *Session, failure_value: Failure) void {
        self.state_mutex.lockUncancelable(self.io);
        if (!self.stopping and self.state_value != .closed) {
            self.state_value = .failed;
            self.failure_value = failure_value;
            self.close_requested = true;
        }
        self.state_mutex.unlock(self.io);
        self.apply_condition.broadcast(self.io);
    }

    fn requestGracefulExit(self: *Session) void {
        self.state_mutex.lockUncancelable(self.io);
        const should_request = !self.stopping and self.pending_apply == null and
            (self.state_value == .starting or self.state_value == .ready);
        self.state_mutex.unlock(self.io);
        if (!should_request) return;
        self.command("qa!") catch return;
        for (0..20) |_| {
            self.state_mutex.lockUncancelable(self.io);
            const finished = self.state_value == .closed or self.state_value == .failed;
            self.state_mutex.unlock(self.io);
            if (finished) return;
            self.io.sleep(.fromMilliseconds(10), .awake) catch return;
        }
    }
};

fn readerThreadMain(self: *Session) void {
    readerLoop(self) catch |err| {
        log.warn("embedded Neovim stdout failed: {any}", .{err});
        self.noteFailure(switch (err) {
            error.MalformedMessage, error.UnexpectedShape, error.ValueOutOfRange => .malformed_rpc,
            error.FrameTooLarge, error.ContainerTooLarge => .protocol_error,
            else => .io_error,
        });
    };
}

fn readerLoop(self: *Session) !void {
    var read_buffer: [32 * 1024]u8 = undefined;
    var reader = self.child.stdout.?.readerStreaming(self.io, &read_buffer);
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(self.allocator);

    while (true) {
        while (try framing.frameLen(pending.items, .{})) |frame_len| {
            try inspectFrame(self, pending.items[0..frame_len]);
            consumePrefix(&pending, frame_len);
        }

        reader.interface.fillMore() catch |err| switch (err) {
            error.EndOfStream => {
                self.state_mutex.lockUncancelable(self.io);
                if (!self.stopping) {
                    self.state_value = .closed;
                    self.close_requested = true;
                }
                self.state_mutex.unlock(self.io);
                self.apply_condition.broadcast(self.io);
                return;
            },
            else => |other| return other,
        };
        const chunk = reader.interface.buffered();
        if (chunk.len == 0) continue;
        const limits: framing.Limits = .{};
        if (pending.items.len + chunk.len > limits.max_frame_bytes) return error.FrameTooLarge;
        try pending.appendSlice(self.allocator, chunk);
        reader.interface.toss(chunk.len);
    }
}

fn inspectFrame(self: *Session, frame: []const u8) !void {
    var view: rpc.View = .{};
    try view.init(frame);
    defer view.deinit();

    switch (try view.kind()) {
        .notification => try inspectNotification(self, &view),
        .response => try inspectResponse(self, &view),
        .request => try inspectRequest(self, &view),
    }
}

fn inspectNotification(self: *Session, view: *rpc.View) !void {
    const method = try view.method();
    if (std.mem.eql(u8, method, "redraw")) {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        _ = try self.model.applyNotification(view);
        return;
    }
    if (std.mem.eql(u8, method, "rayslides_closed")) {
        self.state_mutex.lockUncancelable(self.io);
        self.close_requested = true;
        self.state_mutex.unlock(self.io);
    }
}

fn inspectResponse(self: *Session, view: *rpc.View) !void {
    const id = try view.requestId();
    if (id != attach_request_id and id != api_info_request_id) return;
    if (!try view.isNil(try view.responseError())) return error.UnexpectedShape;

    self.state_mutex.lockUncancelable(self.io);
    defer self.state_mutex.unlock(self.io);
    if (id == attach_request_id) {
        self.attach_complete = true;
    } else {
        const result = try view.result();
        if (try view.arrayLen(result) < 1) return error.UnexpectedShape;
        self.channel_id = try view.uint(try view.arrayAt(result, 0));
    }
    if (self.attach_complete and self.channel_id != null and self.state_value == .starting) {
        self.state_value = .ready;
    }
}

fn inspectRequest(self: *Session, view: *rpc.View) !void {
    const request_id = try view.requestId();
    if (!std.mem.eql(u8, try view.method(), "rayslides_apply")) {
        try sendRpcError(self, request_id, "unsupported Rayslides RPC method");
        return;
    }

    const params = try view.params();
    if (try view.arrayLen(params) != 3) {
        try sendRpcError(self, request_id, "invalid Rayslides apply request");
        return;
    }
    _ = try view.uint(try view.arrayAt(params, 0)); // buffer handle, reserved
    const lines = try view.arrayAt(params, 1);
    const final_eol = try view.boolean(try view.arrayAt(params, 2));
    const editor_source = try sourceFromLines(self.allocator, view, lines, final_eol);
    defer self.allocator.free(editor_source);
    const source = if (self.source_format_value) |*format|
        try format.reconstruct(editor_source, max_document_bytes)
    else
        try self.allocator.dupe(u8, editor_source);

    self.state_mutex.lockUncancelable(self.io);
    if (self.pending_apply != null or self.stopping) {
        self.state_mutex.unlock(self.io);
        self.allocator.free(source);
        try sendRpcError(self, request_id, "another Rayslides apply is already pending");
        return;
    }
    self.pending_apply = .{ .request_id = request_id, .source = source };
    self.state_mutex.unlock(self.io);

    self.state_mutex.lockUncancelable(self.io);
    while (!self.stopping and self.pending_apply.?.response == null) {
        self.apply_condition.waitUncancelable(self.io, &self.state_mutex);
    }
    if (self.stopping) {
        self.state_mutex.unlock(self.io);
        return;
    }
    const completed = self.pending_apply.?;
    self.pending_apply = null;
    self.state_mutex.unlock(self.io);
    defer self.allocator.free(completed.source);

    switch (completed.response.?) {
        .accepted => {
            if (self.source_format_value) |*format| {
                format.replaceBaseline(completed.source) catch |err|
                    log.warn("could not retain accepted Neovim source formatting baseline: {any}", .{err});
            }
            try sendRpcSuccess(self, completed.request_id);
        },
        .rejected => |message| {
            defer self.allocator.free(message);
            try sendRpcError(self, completed.request_id, message);
        },
    }
}

fn sendRpcSuccess(self: *Session, request_id: u64) !void {
    var encoder = rpc.Encoder.init(self.allocator);
    defer encoder.deinit();
    try encoder.beginResponse(request_id);
    try encoder.writeNil();
    try encoder.writeBool(true);
    try self.send(encoder.bytes());
}

fn sendRpcError(self: *Session, request_id: u64, message: []const u8) !void {
    var encoder = rpc.Encoder.init(self.allocator);
    defer encoder.deinit();
    try encoder.beginResponse(request_id);
    try encoder.writeString(message);
    try encoder.writeNil();
    try self.send(encoder.bytes());
}

fn sourceFromLines(allocator: std.mem.Allocator, view: *rpc.View, lines: rpc.Node, final_eol: bool) ![]u8 {
    const line_count = try view.arrayLen(lines);
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    for (0..line_count) |line_index| {
        const line = try view.string(try view.arrayAt(lines, line_index));
        if (line_index != 0) try result.append(allocator, '\n');
        if (result.items.len + line.len > max_document_bytes) return error.DocumentTooLarge;
        try result.appendSlice(allocator, line);
    }
    if (final_eol) try result.append(allocator, '\n');
    if (result.items.len > max_document_bytes) return error.DocumentTooLarge;
    return try result.toOwnedSlice(allocator);
}

fn writeSourceLines(encoder: *rpc.Encoder, source: []const u8) !void {
    const final_eol = source.len > 0 and source[source.len - 1] == '\n';
    const body = if (final_eol) source[0 .. source.len - 1] else source;
    const line_count: usize = if (body.len == 0) 1 else std.mem.count(u8, body, "\n") + 1;
    try encoder.writeArrayHeader(2);
    try encoder.writeArrayHeader(line_count);
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| try encoder.writeString(line);
    try encoder.writeBool(final_eol);
}

fn stderrThreadMain(self: *Session) void {
    var read_buffer: [4096]u8 = undefined;
    var reader = self.child.stderr.?.readerStreaming(self.io, &read_buffer);
    while (true) {
        reader.interface.fillMore() catch return;
        const chunk = reader.interface.buffered();
        if (chunk.len == 0) continue;
        self.state_mutex.lockUncancelable(self.io);
        appendStderrTail(self, chunk);
        self.state_mutex.unlock(self.io);
        reader.interface.toss(chunk.len);
    }
}

fn appendStderrTail(self: *Session, bytes: []const u8) void {
    for (bytes) |byte| {
        if (self.stderr_len < self.stderr_tail.len) {
            self.stderr_tail[(self.stderr_start + self.stderr_len) % self.stderr_tail.len] = byte;
            self.stderr_len += 1;
        } else {
            self.stderr_tail[self.stderr_start] = byte;
            self.stderr_start = (self.stderr_start + 1) % self.stderr_tail.len;
        }
    }
}

fn consumePrefix(pending: *std.ArrayList(u8), count: usize) void {
    const remaining = pending.items.len - count;
    std.mem.copyForwards(u8, pending.items[0..remaining], pending.items[count..]);
    pending.items.len = remaining;
}

fn terminateChildProcess(child: *std.process.Child) void {
    const id = child.id orelse return;
    if (builtin.os.tag == .windows) {
        _ = std.os.windows.ntdll.NtTerminateProcess(id, .CONTROL_C_EXIT);
    } else {
        std.posix.kill(id, std.posix.SIG.KILL) catch {};
    }
}

const open_buffer_lua =
    \\local channel, runtime, name, filetype, source = ...
    \\vim.opt.runtimepath:prepend(runtime)
    \\local diagnostic_ns = vim.api.nvim_create_namespace('rayslides-embedded-editor')
    \\local lines, final_eol = source[1], source[2]
    \\local old_buf = vim.api.nvim_get_current_buf()
    \\local buf = vim.api.nvim_create_buf(true, false)
    \\vim.api.nvim_buf_set_name(buf, name)
    \\vim.api.nvim_set_current_buf(buf)
    \\if old_buf ~= buf and vim.api.nvim_buf_is_valid(old_buf) then
    \\  vim.api.nvim_buf_delete(old_buf, { force = true })
    \\end
    \\vim.bo[buf].buftype = 'acwrite'
    \\vim.bo[buf].bufhidden = 'wipe'
    \\vim.bo[buf].swapfile = false
    \\vim.bo[buf].filetype = filetype
    \\vim.bo[buf].syntax = filetype
    \\vim.api.nvim_buf_set_lines(buf, 0, -1, true, lines)
    \\vim.bo[buf].endofline = final_eol
    \\vim.bo[buf].modified = false
    \\vim.api.nvim_create_autocmd('BufWriteCmd', { buffer = buf, callback = function()
    \\  vim.diagnostic.reset(diagnostic_ns, buf)
    \\  local current = vim.api.nvim_buf_get_lines(buf, 0, -1, true)
    \\  local ok, result = pcall(vim.rpcrequest, channel, 'rayslides_apply', buf, current, vim.bo[buf].endofline)
    \\  if not ok then
    \\    local message = tostring(result)
    \\    local line = tonumber(message:match('line%s+(%d+)'))
    \\    if line then
    \\      pcall(vim.api.nvim_win_set_cursor, 0, { math.max(1, line), 0 })
    \\      vim.diagnostic.set(diagnostic_ns, buf, { {
    \\        lnum = math.max(0, line - 1), col = 0, severity = vim.diagnostic.severity.ERROR,
    \\        message = message, source = 'Rayslides',
    \\      } })
    \\    end
    \\    error(message)
    \\  end
    \\  if result ~= true then error('Rayslides rejected the source update') end
    \\  vim.bo[buf].modified = false
    \\end })
    \\vim.api.nvim_create_autocmd({ 'BufWinLeave', 'BufWipeout' }, { buffer = buf, once = true, callback = function()
    \\  vim.rpcnotify(channel, 'rayslides_closed', buf)
    \\end })
;

test "source line transport preserves final-newline state" {
    const cases = [_][]const u8{ "", "one", "one\n", "one\ntwo", "one\ntwo\n" };
    for (cases) |source| {
        var encoder = rpc.Encoder.init(std.testing.allocator);
        defer encoder.deinit();
        try encoder.beginRequest(9, "x", 1);
        try writeSourceLines(&encoder, source);

        var view: rpc.View = .{};
        try view.init(encoder.bytes());
        defer view.deinit();
        const pair = try view.arrayAt(try view.params(), 0);
        const reconstructed = try sourceFromLines(
            std.testing.allocator,
            &view,
            try view.arrayAt(pair, 0),
            try view.boolean(try view.arrayAt(pair, 1)),
        );
        defer std.testing.allocator.free(reconstructed);
        try std.testing.expectEqualStrings(source, reconstructed);
    }
}

test "stderr tail remains bounded and retains newest bytes" {
    var fake: Session = undefined;
    fake.stderr_start = 0;
    fake.stderr_len = 0;
    @memset(&fake.stderr_tail, 0);
    var bytes: [stderr_tail_capacity + 7]u8 = undefined;
    for (&bytes, 0..) |*byte, index| byte.* = @truncate(index);
    appendStderrTail(&fake, &bytes);
    try std.testing.expectEqual(stderr_tail_capacity, fake.stderr_len);
    for (0..stderr_tail_capacity) |index| {
        try std.testing.expectEqual(bytes[index + 7], fake.stderr_tail[(fake.stderr_start + index) % fake.stderr_tail.len]);
    }
}
