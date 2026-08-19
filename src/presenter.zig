const std = @import("std");
const slides = @import("slides.zig");

pub const default_port: u16 = 7332;
pub const max_connections: u16 = 16;
pub const max_commands: usize = 32;
pub const connected_window_ms: i64 = 12_000;
pub const pointer_timeout_ms: i64 = 900;
pub const preview_file_type = ".png";
pub const preview_content_type = "image/png";
pub const max_preview_bytes: usize = 1024 * 1024;

pub fn FixedText(comptime capacity: usize) type {
    return struct {
        bytes: [capacity]u8 = @splat(0),
        len: u16 = 0,

        const Self = @This();

        pub fn set(self: *Self, value: []const u8) error{TooLong}!void {
            if (value.len > capacity) return error.TooLong;
            @memset(&self.bytes, 0);
            @memcpy(self.bytes[0..value.len], value);
            self.len = @intCast(value.len);
        }

        pub fn slice(self: *const Self) []const u8 {
            return self.bytes[0..self.len];
        }

        pub fn eql(self: *const Self, value: []const u8) bool {
            return std.mem.eql(u8, self.slice(), value);
        }
    };
}

pub const Command = enum {
    previous,
    next,
};

pub const QueuedCommand = struct {
    command: Command,
    sequence: u64,
};

pub const PublishInput = struct {
    current_slide: u32,
    slide_count: u32,
    visible_step: u32,
    step_count: u32,
    notes: []const u8,
    next_notes: []const u8,
    can_previous: bool,
    can_next: bool,
    pointer_enabled: bool,
};

pub const PointerSample = struct {
    active: bool = false,
    x: f32 = 0,
    y: f32 = 0,
    sequence: u64 = 0,
};

pub const Snapshot = struct {
    session_id: FixedText(24) = .{},
    revision: u64 = 1,
    current_slide: u32 = 0,
    slide_count: u32 = 0,
    visible_step: u32 = 0,
    step_count: u32 = 0,
    notes: FixedText(slides.max_speaker_notes_bytes) = .{},
    next_notes: FixedText(slides.max_speaker_notes_bytes) = .{},
    can_previous: bool = false,
    can_next: bool = false,
    pointer_enabled: bool = false,
    preview_ready: bool = false,
    preview_revision: u64 = 0,
};

const Store = struct {
    preview_storage: []u8,
    preview_len: usize = 0,
    snapshot: Snapshot = .{},
    capability: FixedText(64) = .{},
    started_at_ms: i64 = 0,
    last_seen_ms: i64 = 0,
    last_command_sequence: u64 = 0,
    commands: [max_commands]QueuedCommand = @splat(.{ .command = .next, .sequence = 0 }),
    command_head: usize = 0,
    command_count: usize = 0,
    pointer: PointerSample = .{},
    pointer_last_seen_ms: i64 = 0,
    last_pointer_sequence: u64 = 0,

    fn resetSession(self: *Store, random: [40]u8, now_ms: i64) void {
        const preview_storage = self.preview_storage;
        const session_hex = std.fmt.bytesToHex(random[0..8], .lower);
        const capability_hex = std.fmt.bytesToHex(random[8..40], .lower);
        self.* = .{ .preview_storage = preview_storage, .started_at_ms = now_ms };
        self.snapshot.session_id.set(&session_hex) catch unreachable;
        self.capability.set(&capability_hex) catch unreachable;
    }

    fn authorized(self: *const Store, candidate: []const u8) bool {
        if (candidate.len != 64 or self.capability.len != 64) return false;
        var fixed: [64]u8 = undefined;
        @memcpy(fixed[0..], candidate);
        return std.crypto.timing_safe.eql([64]u8, fixed, self.capability.bytes);
    }

    fn publish(self: *Store, input: PublishInput) error{TooLong}!bool {
        if (input.notes.len > slides.max_speaker_notes_bytes or
            input.next_notes.len > slides.max_speaker_notes_bytes)
        {
            return error.TooLong;
        }
        const changed = self.snapshot.current_slide != input.current_slide or
            self.snapshot.slide_count != input.slide_count or
            self.snapshot.visible_step != input.visible_step or
            self.snapshot.step_count != input.step_count or
            self.snapshot.can_previous != input.can_previous or
            self.snapshot.can_next != input.can_next or
            self.snapshot.pointer_enabled != input.pointer_enabled or
            !self.snapshot.notes.eql(input.notes) or
            !self.snapshot.next_notes.eql(input.next_notes);
        if (!changed) return false;

        self.snapshot.current_slide = input.current_slide;
        self.snapshot.slide_count = input.slide_count;
        self.snapshot.visible_step = input.visible_step;
        self.snapshot.step_count = input.step_count;
        self.snapshot.can_previous = input.can_previous;
        self.snapshot.can_next = input.can_next;
        self.snapshot.pointer_enabled = input.pointer_enabled;
        try self.snapshot.notes.set(input.notes);
        try self.snapshot.next_notes.set(input.next_notes);
        self.bump();
        return true;
    }

    fn setPreview(self: *Store, bytes: []const u8) error{TooLong}!void {
        if (bytes.len == 0 or bytes.len > self.preview_storage.len) return error.TooLong;
        @memcpy(self.preview_storage[0..bytes.len], bytes);
        self.preview_len = bytes.len;
        self.snapshot.preview_ready = true;
        self.snapshot.preview_revision +%= 1;
        if (self.snapshot.preview_revision == 0) self.snapshot.preview_revision = 1;
        self.bump();
    }

    fn updatePointer(self: *Store, sample: PointerSample, now_ms: i64) error{InvalidPointer}!bool {
        if (sample.sequence == 0 or sample.sequence <= self.last_pointer_sequence) return false;
        if (!std.math.isFinite(sample.x) or !std.math.isFinite(sample.y) or
            sample.x < 0 or sample.x > 1 or sample.y < 0 or sample.y > 1)
        {
            return error.InvalidPointer;
        }
        self.pointer = sample;
        self.pointer_last_seen_ms = now_ms;
        self.last_pointer_sequence = sample.sequence;
        return true;
    }

    fn activePointer(self: *Store, now_ms: i64) ?PointerSample {
        if (!self.pointer.active) return null;
        if (self.pointer_last_seen_ms == 0 or now_ms - self.pointer_last_seen_ms > pointer_timeout_ms) {
            self.pointer.active = false;
            return null;
        }
        return self.pointer;
    }

    fn enqueue(self: *Store, command: Command, sequence: u64) error{Capacity}!bool {
        if (sequence == 0 or sequence <= self.last_command_sequence) return false;
        if (self.command_count >= self.commands.len) return error.Capacity;
        const tail = (self.command_head + self.command_count) % self.commands.len;
        self.commands[tail] = .{ .command = command, .sequence = sequence };
        self.command_count += 1;
        self.last_command_sequence = sequence;
        return true;
    }

    fn takeCommand(self: *Store) ?QueuedCommand {
        if (self.command_count == 0) return null;
        const command = self.commands[self.command_head];
        self.command_head = (self.command_head + 1) % self.commands.len;
        self.command_count -= 1;
        return command;
    }

    fn bump(self: *Store) void {
        self.snapshot.revision +%= 1;
        if (self.snapshot.revision == 0) self.snapshot.revision = 1;
    }
};

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    store: Store,
    base_url: FixedText(256) = .{},
    pairing_url: FixedText(384) = .{},
    listener: ?std.Io.net.Server = null,
    serve_future: ?std.Io.Future(std.Io.Cancelable!void) = null,
    active_connections: std.atomic.Value(u16) = .init(0),
    port: u16 = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !Runtime {
        const preview_storage = try allocator.alloc(u8, max_preview_bytes);
        return .{
            .allocator = allocator,
            .io = io,
            .store = .{ .preview_storage = preview_storage },
        };
    }

    pub fn deinit(self: *Runtime) void {
        self.stop();
        self.allocator.free(self.store.preview_storage);
    }

    pub fn start(self: *Runtime, requested_port: u16, public_host: []const u8) !u16 {
        if (self.listener != null) return self.port;
        const address: std.Io.net.IpAddress = .{ .ip4 = .unspecified(requested_port) };
        self.listener = try address.listen(self.io, .{ .reuse_address = true });
        errdefer {
            self.listener.?.deinit(self.io);
            self.listener = null;
            self.port = 0;
            self.base_url.set("") catch unreachable;
            self.pairing_url.set("") catch unreachable;
        }

        var random: [40]u8 = undefined;
        try self.io.randomSecure(&random);
        self.mutex.lockUncancelable(self.io);
        self.store.resetSession(random, self.nowMs());
        self.mutex.unlock(self.io);

        self.port = self.listener.?.socket.address.getPort();
        var base_buffer: [256]u8 = undefined;
        const base = try std.fmt.bufPrint(&base_buffer, "http://{s}:{d}", .{ public_host, self.port });
        try self.base_url.set(base);
        var pairing_buffer: [384]u8 = undefined;
        const pairing = try std.fmt.bufPrint(
            &pairing_buffer,
            "{s}/presenter/#{s}",
            .{ base, self.store.capability.slice() },
        );
        try self.pairing_url.set(pairing);
        self.serve_future = try self.io.concurrent(serve, .{self});
        return self.port;
    }

    pub fn stop(self: *Runtime) void {
        if (self.serve_future) |*future| {
            future.cancel(self.io) catch |err| switch (err) {
                error.Canceled => {},
            };
            self.serve_future = null;
        }
        if (self.listener) |*listener| {
            listener.deinit(self.io);
            self.listener = null;
        }
        self.port = 0;
        self.base_url.set("") catch unreachable;
        self.pairing_url.set("") catch unreachable;
    }

    pub fn isRunning(self: *const Runtime) bool {
        return self.listener != null;
    }

    pub fn publish(self: *Runtime, input: PublishInput) !bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.store.publish(input);
    }

    pub fn publishPreview(self: *Runtime, bytes: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.store.setPreview(bytes);
    }

    pub fn takeCommand(self: *Runtime) ?QueuedCommand {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.store.takeCommand();
    }

    pub fn phoneConnected(self: *Runtime) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.store.last_seen_ms != 0 and self.nowMs() - self.store.last_seen_ms <= connected_window_ms;
    }

    pub fn activePointer(self: *Runtime) ?PointerSample {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.store.activePointer(self.nowMs());
    }

    pub fn clearPointer(self: *Runtime) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.store.pointer.active = false;
    }

    fn nowMs(self: *const Runtime) i64 {
        return std.Io.Timestamp.now(self.io, .awake).toMilliseconds();
    }

    fn serve(self: *Runtime) std.Io.Cancelable!void {
        var connections: std.Io.Group = .init;
        defer connections.cancel(self.io);
        while (true) {
            var stream = self.listener.?.accept(self.io) catch |err| switch (err) {
                error.Canceled => |canceled| return canceled,
                else => {
                    std.log.err("Presenter Companion accept failed: {t}", .{err});
                    return;
                },
            };
            const previous_count = self.active_connections.fetchAdd(1, .acq_rel);
            if (previous_count >= max_connections) {
                _ = self.active_connections.fetchSub(1, .acq_rel);
                stream.close(self.io);
                continue;
            }
            connections.concurrent(self.io, handleConnectionTask, .{ self, stream }) catch |err| {
                _ = self.active_connections.fetchSub(1, .acq_rel);
                std.log.err("Presenter Companion connection task failed: {t}", .{err});
                stream.close(self.io);
            };
        }
    }

    fn handleConnectionTask(self: *Runtime, stream: std.Io.net.Stream) std.Io.Cancelable!void {
        defer _ = self.active_connections.fetchSub(1, .acq_rel);
        self.handleConnection(stream) catch |err| std.log.warn("Presenter Companion request failed: {t}", .{err});
    }

    fn handleConnection(self: *Runtime, stream: std.Io.net.Stream) !void {
        defer stream.close(self.io);
        var read_buffer: [8192]u8 = undefined;
        var write_buffer: [8192]u8 = undefined;
        var stream_reader = stream.reader(self.io, &read_buffer);
        var stream_writer = stream.writer(self.io, &write_buffer);
        var http_server: std.http.Server = .init(&stream_reader.interface, &stream_writer.interface);
        var request = try http_server.receiveHead();

        if (request.head.target.len > 2048) return respondError(&request, .uri_too_long, "request target too long");
        var target_buffer: [2048]u8 = undefined;
        @memcpy(target_buffer[0..request.head.target.len], request.head.target);
        const target = target_buffer[0..request.head.target.len];
        const path = if (std.mem.findScalar(u8, target, '?')) |index| target[0..index] else target;

        if (request.head.method == .GET and
            (std.mem.eql(u8, path, "/presenter") or std.mem.eql(u8, path, "/presenter/")))
        {
            return request.respond(presenter_html, .{
                .keep_alive = false,
                .extra_headers = page_headers,
            });
        }

        if (request.head.method == .GET and std.mem.eql(u8, path, "/api/v1/presenter/state")) {
            const token = queryValue(target, "token") orelse "";
            self.mutex.lockUncancelable(self.io);
            if (!self.store.authorized(token)) {
                self.mutex.unlock(self.io);
                return respondError(&request, .unauthorized, "presenter pairing required");
            }
            const now_ms = self.nowMs();
            self.store.last_seen_ms = now_ms;
            const snapshot = self.store.snapshot;
            const started_at_ms = self.store.started_at_ms;
            self.mutex.unlock(self.io);
            return respondState(&request, snapshot, now_ms, started_at_ms);
        }

        if (request.head.method == .GET and std.mem.eql(u8, path, "/api/v1/presenter/preview")) {
            const token = queryValue(target, "token") orelse "";
            self.mutex.lockUncancelable(self.io);
            if (!self.store.authorized(token)) {
                self.mutex.unlock(self.io);
                return respondError(&request, .unauthorized, "presenter pairing required");
            }
            self.store.last_seen_ms = self.nowMs();
            if (self.store.preview_len == 0) {
                self.mutex.unlock(self.io);
                return respondError(&request, .service_unavailable, "slide preview is not ready");
            }
            const preview = self.allocator.dupe(u8, self.store.preview_storage[0..self.store.preview_len]) catch |err| {
                self.mutex.unlock(self.io);
                return err;
            };
            self.mutex.unlock(self.io);
            defer self.allocator.free(preview);
            return request.respond(preview, .{ .keep_alive = false, .extra_headers = preview_headers });
        }

        if (request.head.method == .POST and std.mem.eql(u8, path, "/api/v1/presenter/command")) {
            const token = queryValue(target, "token") orelse "";
            self.mutex.lockUncancelable(self.io);
            const authorized = self.store.authorized(token);
            self.mutex.unlock(self.io);
            if (!authorized) return respondError(&request, .unauthorized, "presenter pairing required");
            if (!hasJsonContentType(&request)) return respondError(&request, .unsupported_media_type, "Content-Type must be application/json");
            const body = self.readBody(&request) catch |err| switch (err) {
                error.BodyTooLarge, error.StreamTooLong => return respondError(&request, .payload_too_large, "request body too large"),
                else => return err,
            };
            defer self.allocator.free(body);
            const parsed = std.json.parseFromSlice(CommandRequest, self.allocator, body, .{}) catch {
                return respondError(&request, .bad_request, "invalid presenter command");
            };
            defer parsed.deinit();
            const command = std.meta.stringToEnum(Command, parsed.value.command) orelse
                return respondError(&request, .bad_request, "unknown presenter command");
            self.mutex.lockUncancelable(self.io);
            self.store.last_seen_ms = self.nowMs();
            const queued = self.store.enqueue(command, parsed.value.seq) catch {
                self.mutex.unlock(self.io);
                return respondError(&request, .too_many_requests, "presenter command queue is full");
            };
            self.mutex.unlock(self.io);
            return respondCommand(&request, parsed.value.seq, queued);
        }

        if (request.head.method == .POST and std.mem.eql(u8, path, "/api/v1/presenter/pointer")) {
            const token = queryValue(target, "token") orelse "";
            self.mutex.lockUncancelable(self.io);
            const authorized = self.store.authorized(token);
            self.mutex.unlock(self.io);
            if (!authorized) return respondError(&request, .unauthorized, "presenter pairing required");
            if (!hasJsonContentType(&request)) return respondError(&request, .unsupported_media_type, "Content-Type must be application/json");
            const body = self.readBody(&request) catch |err| switch (err) {
                error.BodyTooLarge, error.StreamTooLong => return respondError(&request, .payload_too_large, "request body too large"),
                else => return err,
            };
            defer self.allocator.free(body);
            const parsed = std.json.parseFromSlice(PointerRequest, self.allocator, body, .{}) catch {
                return respondError(&request, .bad_request, "invalid pointer update");
            };
            defer parsed.deinit();
            const sample = PointerSample{
                .active = parsed.value.active,
                .x = parsed.value.x,
                .y = parsed.value.y,
                .sequence = parsed.value.seq,
            };
            self.mutex.lockUncancelable(self.io);
            self.store.last_seen_ms = self.nowMs();
            const accepted = self.store.updatePointer(sample, self.store.last_seen_ms) catch {
                self.mutex.unlock(self.io);
                return respondError(&request, .bad_request, "pointer coordinates must be normalized");
            };
            self.mutex.unlock(self.io);
            return respondPointer(&request, parsed.value.seq, accepted);
        }

        if (request.head.method == .GET and std.mem.eql(u8, path, "/health/presenter")) {
            return request.respond("ok\n", .{ .keep_alive = false, .extra_headers = text_headers });
        }
        return respondError(&request, .not_found, "not found");
    }

    fn readBody(self: *Runtime, request: *std.http.Server.Request) ![]u8 {
        if (request.head.content_length) |length| {
            if (length > 1024) return error.BodyTooLarge;
        }
        var body_buffer: [1024]u8 = undefined;
        const reader = try request.readerExpectContinue(&body_buffer);
        return reader.allocRemaining(self.allocator, .limited(1024));
    }
};

const CommandRequest = struct {
    command: []const u8,
    seq: u64,
};

const PointerRequest = struct {
    active: bool,
    x: f32,
    y: f32,
    seq: u64,
};

const presenter_html = @embedFile("assets/presenter.html");

const page_headers: []const std.http.Header = &.{
    .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
    .{ .name = "Cache-Control", .value = "no-store" },
    .{ .name = "X-Content-Type-Options", .value = "nosniff" },
    .{ .name = "Referrer-Policy", .value = "no-referrer" },
    .{ .name = "Content-Security-Policy", .value = "default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; img-src 'self' data:" },
};

const api_headers: []const std.http.Header = &.{
    .{ .name = "Content-Type", .value = "application/json; charset=utf-8" },
    .{ .name = "Cache-Control", .value = "no-store" },
    .{ .name = "X-Content-Type-Options", .value = "nosniff" },
    .{ .name = "Referrer-Policy", .value = "no-referrer" },
};

const text_headers: []const std.http.Header = &.{
    .{ .name = "Content-Type", .value = "text/plain; charset=utf-8" },
    .{ .name = "Cache-Control", .value = "no-store" },
};

const preview_headers: []const std.http.Header = &.{
    .{ .name = "Content-Type", .value = preview_content_type },
    .{ .name = "Cache-Control", .value = "no-store" },
    .{ .name = "X-Content-Type-Options", .value = "nosniff" },
    .{ .name = "Referrer-Policy", .value = "no-referrer" },
};

fn queryValue(target: []const u8, key: []const u8) ?[]const u8 {
    const question = std.mem.findScalar(u8, target, '?') orelse return null;
    var pairs = std.mem.splitScalar(u8, target[question + 1 ..], '&');
    while (pairs.next()) |pair| {
        const equal = std.mem.findScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..equal], key)) return pair[equal + 1 ..];
    }
    return null;
}

fn hasJsonContentType(request: *const std.http.Server.Request) bool {
    const raw = request.head.content_type orelse return false;
    const end = std.mem.findScalar(u8, raw, ';') orelse raw.len;
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, raw[0..end], " \t"), "application/json");
}

fn respondError(request: *std.http.Server.Request, status: std.http.Status, message: []const u8) !void {
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try std.json.Stringify.value(.{ .@"error" = message }, .{}, &writer);
    try request.respond(writer.buffered(), .{ .status = status, .keep_alive = false, .extra_headers = api_headers });
}

fn respondCommand(request: *std.http.Server.Request, sequence: u64, queued: bool) !void {
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try std.json.Stringify.value(.{ .sequence = sequence, .queued = queued }, .{}, &writer);
    try request.respond(writer.buffered(), .{ .keep_alive = false, .extra_headers = api_headers });
}

fn respondPointer(request: *std.http.Server.Request, sequence: u64, accepted: bool) !void {
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try std.json.Stringify.value(.{ .sequence = sequence, .accepted = accepted }, .{}, &writer);
    try request.respond(writer.buffered(), .{ .keep_alive = false, .extra_headers = api_headers });
}

fn respondState(request: *std.http.Server.Request, snapshot: Snapshot, now_ms: i64, started_at_ms: i64) !void {
    const WireState = struct {
        session_id: []const u8,
        revision: u64,
        current_slide: u32,
        slide_count: u32,
        visible_step: u32,
        step_count: u32,
        notes: []const u8,
        next_notes: []const u8,
        can_previous: bool,
        can_next: bool,
        pointer_enabled: bool,
        preview_ready: bool,
        preview_revision: u64,
        elapsed_ms: i64,
        server_now_ms: i64,
    };
    var buffer: [128 * 1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try std.json.Stringify.value(WireState{
        .session_id = snapshot.session_id.slice(),
        .revision = snapshot.revision,
        .current_slide = snapshot.current_slide,
        .slide_count = snapshot.slide_count,
        .visible_step = snapshot.visible_step,
        .step_count = snapshot.step_count,
        .notes = snapshot.notes.slice(),
        .next_notes = snapshot.next_notes.slice(),
        .can_previous = snapshot.can_previous,
        .can_next = snapshot.can_next,
        .pointer_enabled = snapshot.pointer_enabled,
        .preview_ready = snapshot.preview_ready,
        .preview_revision = snapshot.preview_revision,
        .elapsed_ms = @max(@as(i64, 0), now_ms - started_at_ms),
        .server_now_ms = now_ms,
    }, .{}, &writer);
    try request.respond(writer.buffered(), .{ .keep_alive = false, .extra_headers = api_headers });
}

test "presentation state revisions and command sequences are stable" {
    var preview_storage: [64]u8 = undefined;
    var store = Store{ .preview_storage = &preview_storage };
    store.resetSession(@splat(7), 100);
    const input = PublishInput{
        .current_slide = 2,
        .slide_count = 10,
        .visible_step = 1,
        .step_count = 3,
        .notes = "Current cue",
        .next_notes = "Next cue",
        .can_previous = true,
        .can_next = true,
        .pointer_enabled = true,
    };
    try std.testing.expect(try store.publish(input));
    const revision = store.snapshot.revision;
    try std.testing.expect(!try store.publish(input));
    try std.testing.expectEqual(revision, store.snapshot.revision);
    try std.testing.expect(try store.enqueue(.next, 4));
    try std.testing.expect(!try store.enqueue(.next, 4));
    try std.testing.expect(!try store.enqueue(.previous, 3));
    try std.testing.expectEqual(Command.next, store.takeCommand().?.command);
    try std.testing.expect(store.takeCommand() == null);
    try store.setPreview("fake-png");
    try std.testing.expect(store.snapshot.preview_ready);
    try std.testing.expectEqualStrings("fake-png", store.preview_storage[0..store.preview_len]);
    try std.testing.expect(try store.updatePointer(.{ .active = true, .x = 0.25, .y = 0.75, .sequence = 8 }, 200));
    try std.testing.expect(!try store.updatePointer(.{ .active = false, .x = 0, .y = 0, .sequence = 7 }, 201));
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), store.activePointer(300).?.x, 0.0001);
    try std.testing.expect(store.activePointer(200 + pointer_timeout_ms + 1) == null);
}

fn rawHttp(allocator: std.mem.Allocator, io: std.Io, port: u16, request: []const u8) ![]u8 {
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    var stream = try address.connect(io, .{ .mode = .stream, .protocol = .tcp });
    defer stream.close(io);
    var write_buffer: [4096]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.writeAll(request);
    try writer.interface.flush();
    var read_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    return reader.interface.allocRemaining(allocator, .limited(192 * 1024));
}

test "presenter HTTP is private and queues authenticated commands" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var runtime = try Runtime.init(allocator, io);
    defer runtime.deinit();
    const port = try runtime.start(0, "127.0.0.1");
    _ = try runtime.publish(.{
        .current_slide = 0,
        .slide_count = 2,
        .visible_step = 0,
        .step_count = 1,
        .notes = "Private cue",
        .next_notes = "Upcoming cue",
        .can_previous = false,
        .can_next = true,
        .pointer_enabled = true,
    });
    try runtime.publishPreview("fake-png-preview");

    const page = try rawHttp(allocator, io, port, "GET /presenter/ HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    defer allocator.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "200 OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "Private cue") == null);
    try std.testing.expect(std.mem.indexOf(u8, page, runtime.store.capability.slice()) == null);

    const denied = try rawHttp(allocator, io, port, "GET /api/v1/presenter/state HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    defer allocator.free(denied);
    try std.testing.expect(std.mem.indexOf(u8, denied, "401 Unauthorized") != null);
    const denied_preview = try rawHttp(allocator, io, port, "GET /api/v1/presenter/preview HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    defer allocator.free(denied_preview);
    try std.testing.expect(std.mem.indexOf(u8, denied_preview, "401 Unauthorized") != null);

    const state_request = try std.fmt.allocPrint(
        allocator,
        "GET /api/v1/presenter/state?token={s} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
        .{runtime.store.capability.slice()},
    );
    defer allocator.free(state_request);
    const state_response = try rawHttp(allocator, io, port, state_request);
    defer allocator.free(state_response);
    try std.testing.expect(std.mem.indexOf(u8, state_response, "\"notes\":\"Private cue\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, state_response, "\"preview_ready\":true") != null);

    const preview_request = try std.fmt.allocPrint(
        allocator,
        "GET /api/v1/presenter/preview?token={s} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
        .{runtime.store.capability.slice()},
    );
    defer allocator.free(preview_request);
    const preview_response = try rawHttp(allocator, io, port, preview_request);
    defer allocator.free(preview_response);
    try std.testing.expect(std.mem.indexOf(u8, preview_response, "Content-Type: image/png") != null);
    try std.testing.expect(std.mem.indexOf(u8, preview_response, "fake-png-preview") != null);

    const body = "{\"command\":\"next\",\"seq\":1}";
    const command_request = try std.fmt.allocPrint(
        allocator,
        "POST /api/v1/presenter/command?token={s} HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ runtime.store.capability.slice(), body.len, body },
    );
    defer allocator.free(command_request);
    const command_response = try rawHttp(allocator, io, port, command_request);
    defer allocator.free(command_response);
    try std.testing.expect(std.mem.indexOf(u8, command_response, "\"queued\":true") != null);
    try std.testing.expectEqual(Command.next, runtime.takeCommand().?.command);

    const pointer_body = "{\"active\":true,\"x\":0.2,\"y\":0.8,\"seq\":1}";
    const pointer_request = try std.fmt.allocPrint(
        allocator,
        "POST /api/v1/presenter/pointer?token={s} HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ runtime.store.capability.slice(), pointer_body.len, pointer_body },
    );
    defer allocator.free(pointer_request);
    const pointer_response = try rawHttp(allocator, io, port, pointer_request);
    defer allocator.free(pointer_response);
    try std.testing.expect(std.mem.indexOf(u8, pointer_response, "\"accepted\":true") != null);
    const pointer = runtime.activePointer().?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), pointer.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), pointer.y, 0.0001);
    runtime.clearPointer();
    try std.testing.expect(runtime.activePointer() == null);
}

test "Presenter Companion and Crowdplay remain independent servers" {
    const crowdplay = @import("crowdplay.zig");
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var audience_runtime = try crowdplay.Runtime.init(allocator, io);
    defer audience_runtime.stop();
    const audience_port = try audience_runtime.start(0, "127.0.0.1");

    var presenter_runtime = try Runtime.init(allocator, io);
    defer presenter_runtime.deinit();
    const presenter_port = try presenter_runtime.start(0, "127.0.0.1");
    try std.testing.expect(audience_port != presenter_port);
    _ = try presenter_runtime.publish(.{
        .current_slide = 0,
        .slide_count = 1,
        .visible_step = 0,
        .step_count = 0,
        .notes = "Private split-server cue",
        .next_notes = "",
        .can_previous = false,
        .can_next = false,
        .pointer_enabled = true,
    });

    const audience_health = try rawHttp(allocator, io, audience_port, "GET /health HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    defer allocator.free(audience_health);
    try std.testing.expect(std.mem.indexOf(u8, audience_health, "200 OK") != null);
    const presenter_health = try rawHttp(allocator, io, presenter_port, "GET /health/presenter HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    defer allocator.free(presenter_health);
    try std.testing.expect(std.mem.indexOf(u8, presenter_health, "200 OK") != null);

    const audience_state = try rawHttp(allocator, io, audience_port, "GET /api/v1/state HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    defer allocator.free(audience_state);
    try std.testing.expect(std.mem.indexOf(u8, audience_state, "200 OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, audience_state, "Private split-server cue") == null);
    const presenter_route_on_audience = try rawHttp(allocator, io, audience_port, "GET /presenter/ HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    defer allocator.free(presenter_route_on_audience);
    try std.testing.expect(std.mem.indexOf(u8, presenter_route_on_audience, "404 Not Found") != null);
    const preview_route_on_audience = try rawHttp(allocator, io, audience_port, "GET /api/v1/presenter/preview HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    defer allocator.free(preview_route_on_audience);
    try std.testing.expect(std.mem.indexOf(u8, preview_route_on_audience, "404 Not Found") != null);

    presenter_runtime.stop();
    const audience_after_presenter_stop = try rawHttp(allocator, io, audience_port, "GET /health HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    defer allocator.free(audience_after_presenter_stop);
    try std.testing.expect(std.mem.indexOf(u8, audience_after_presenter_stop, "200 OK") != null);
}
