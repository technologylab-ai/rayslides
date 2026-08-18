const std = @import("std");
const slides = @import("slides.zig");

pub const max_polls = 32;
pub const max_choices = 8;
pub const max_participants = 512;
pub const max_connections = 64;
pub const active_window_ms: i64 = 12_000;
pub const min_vote_interval_ms: i64 = 100;

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

pub const Poll = struct {
    id: FixedText(48) = .{},
    prompt: FixedText(192) = .{},
    choices: [max_choices]FixedText(64) = @splat(.{}),
    choice_count: u8 = 0,
    counts: [max_choices]u32 = @splat(0),
    open: bool = true,
    revealed: bool = false,

    fn matches(self: *const Poll, spec: slides.CrowdSpec) bool {
        if (!self.id.eql(spec.id) or !self.prompt.eql(spec.prompt) or self.choice_count != spec.choices.len) return false;
        for (spec.choices, 0..) |choice, index| {
            if (!self.choices[index].eql(choice)) return false;
        }
        return true;
    }
};

const Participant = struct {
    client_id: FixedText(64) = .{},
    display_name: FixedText(32) = .{},
    last_seen_ms: i64 = 0,
    last_vote_ms: i64 = 0,
    seed: u64 = 0,
};

const VoteSlot = struct {
    choice: ?u8 = null,
    seq: u32 = 0,
};

pub const ChoiceSnapshot = struct {
    id: u8 = 0,
    label: FixedText(64) = .{},
    votes: u32 = 0,
};

pub const PollSnapshot = struct {
    id: FixedText(48) = .{},
    prompt: FixedText(192) = .{},
    choices: [max_choices]ChoiceSnapshot = @splat(.{}),
    choice_count: u8 = 0,
    total: u32 = 0,
    open: bool = true,
    revealed: bool = false,
};

pub const ParticipantView = struct {
    seed: u64 = 0,
    choice: ?u8 = null,
};

pub const Snapshot = struct {
    session_id: FixedText(24) = .{},
    revision: u64 = 0,
    connected: u16 = 0,
    poll: ?PollSnapshot = null,
    participant_count: u16 = 0,
    participants: [max_participants]ParticipantView = @splat(.{}),
};

pub const ClientSelection = struct {
    choice: ?u8 = null,
    seq: u32 = 0,
};

pub const VoteResult = struct {
    changed: bool,
    revision: u64,
    selected: u8,
    seq: u32,
};

pub const VoteError = error{
    InvalidClient,
    UnknownParticipant,
    NoActivePoll,
    PollChanged,
    PollClosed,
    InvalidChoice,
    Capacity,
    RateLimited,
};

pub const Store = struct {
    session_id: FixedText(24) = .{},
    revision: u64 = 1,
    polls: [max_polls]Poll = @splat(.{}),
    poll_count: u8 = 0,
    active_poll: ?u8 = null,
    participants: [max_participants]Participant = @splat(.{}),
    participant_count: u16 = 0,
    votes: [max_polls][max_participants]VoteSlot = @splat(@splat(.{ .seq = 0 })),

    pub fn init(seed: u64) Store {
        var self = Store{};
        var buffer: [24]u8 = undefined;
        const session = std.fmt.bufPrint(&buffer, "{x:0>16}", .{seed}) catch unreachable;
        self.session_id.set(session) catch unreachable;
        return self;
    }

    pub fn configure(self: *Store, slideshow: *const slides.SlideShow) !void {
        var next_polls: [max_polls]Poll = @splat(.{});
        var next_votes: [max_polls][max_participants]VoteSlot = @splat(@splat(.{ .seq = 0 }));
        var next_count: u8 = 0;

        for (slideshow.slides.items) |slide| {
            if (slide.items) |items| {
                var crowd_items: usize = 0;
                for (items.items) |item| {
                    const spec = item.crowd orelse continue;
                    crowd_items += 1;
                    if (crowd_items > 1) return error.MultipleCrowdItems;
                    try validateCrowdSpec(spec);
                    if (spec.kind != .poll) continue;
                    if (findPollIn(next_polls[0..next_count], spec.id) != null) return error.DuplicatePoll;
                    if (next_count >= max_polls or spec.choices.len > max_choices) return error.Capacity;

                    var poll = Poll{ .open = spec.initially_open };
                    try poll.id.set(spec.id);
                    try poll.prompt.set(spec.prompt);
                    poll.choice_count = @intCast(spec.choices.len);
                    for (spec.choices, 0..) |choice, index| try poll.choices[index].set(choice);

                    if (self.findPoll(spec.id)) |old_index| {
                        const old = &self.polls[old_index];
                        if (old.matches(spec)) {
                            poll.open = old.open;
                            poll.revealed = old.revealed;
                            for (0..self.participant_count) |participant_index| {
                                const vote_slot = self.votes[old_index][participant_index];
                                const choice = vote_slot.choice orelse continue;
                                if (choice >= poll.choice_count) continue;
                                next_votes[next_count][participant_index] = vote_slot;
                                poll.counts[choice] += 1;
                            }
                        }
                    }
                    next_polls[next_count] = poll;
                    next_count += 1;
                }
            }
        }

        const old_active_id = if (self.active_poll) |index| self.polls[index].id else FixedText(48){};
        self.polls = next_polls;
        self.poll_count = next_count;
        self.votes = next_votes;
        self.active_poll = if (old_active_id.len > 0) findPollIn(self.polls[0..self.poll_count], old_active_id.slice()) else null;
        self.bump();
    }

    pub fn activate(self: *Store, spec: ?slides.CrowdSpec) void {
        const next: ?u8 = if (spec) |crowd|
            if (crowd.kind == .poll) self.findPoll(crowd.id) else null
        else
            null;
        if (self.active_poll != next) {
            self.active_poll = next;
            self.bump();
        }
    }

    pub fn join(self: *Store, client_id: []const u8, display_name: []const u8, now_ms: i64) !u16 {
        try validateClientId(client_id);
        if (display_name.len > 32) return error.InvalidClient;
        if (self.findParticipant(client_id)) |index| {
            const participant = &self.participants[index];
            participant.last_seen_ms = now_ms;
            if (!participant.display_name.eql(display_name)) {
                try participant.display_name.set(display_name);
                self.bump();
            }
            return index;
        }
        const index: u16 = if (self.participant_count < max_participants) blk: {
            const fresh = self.participant_count;
            self.participant_count += 1;
            break :blk fresh;
        } else blk: {
            for (self.participants[0..self.participant_count], 0..) |candidate, candidate_index| {
                if (now_ms - candidate.last_seen_ms <= active_window_ms) continue;
                const recycled: u16 = @intCast(candidate_index);
                for (0..self.poll_count) |poll_index| {
                    if (self.votes[poll_index][recycled].choice) |choice| {
                        self.polls[poll_index].counts[choice] -= 1;
                    }
                    self.votes[poll_index][recycled] = .{ .seq = 0 };
                }
                break :blk recycled;
            }
            return error.Capacity;
        };
        var participant = Participant{ .last_seen_ms = now_ms, .seed = std.hash.Wyhash.hash(0, client_id) };
        try participant.client_id.set(client_id);
        try participant.display_name.set(display_name);
        self.participants[index] = participant;
        self.bump();
        return index;
    }

    pub fn heartbeat(self: *Store, client_id: []const u8, now_ms: i64) bool {
        const index = self.findParticipant(client_id) orelse return false;
        self.participants[index].last_seen_ms = now_ms;
        return true;
    }

    pub fn vote(self: *Store, client_id: []const u8, poll_id: []const u8, choice: u8, seq: u32, now_ms: i64) VoteError!VoteResult {
        validateClientId(client_id) catch return error.InvalidClient;
        const participant_index = self.findParticipant(client_id) orelse return error.UnknownParticipant;
        self.participants[participant_index].last_seen_ms = now_ms;
        const poll_index = self.active_poll orelse return error.NoActivePoll;
        var poll = &self.polls[poll_index];
        if (!poll.id.eql(poll_id)) return error.PollChanged;
        if (!poll.open) return error.PollClosed;
        if (choice >= poll.choice_count) return error.InvalidChoice;

        const existing = &self.votes[poll_index][participant_index];
        if (existing.choice) |previous_choice| {
            if (seq <= existing.seq) {
                return .{ .changed = false, .revision = self.revision, .selected = previous_choice, .seq = existing.seq };
            }
            if (previous_choice == choice) {
                existing.seq = seq;
                self.participants[participant_index].last_vote_ms = now_ms;
                return .{ .changed = false, .revision = self.revision, .selected = previous_choice, .seq = seq };
            }
            const participant = &self.participants[participant_index];
            if (participant.last_vote_ms != 0 and now_ms - participant.last_vote_ms < min_vote_interval_ms) return error.RateLimited;
            poll.counts[previous_choice] -= 1;
            poll.counts[choice] += 1;
        } else {
            poll.counts[choice] += 1;
        }
        existing.* = .{ .choice = choice, .seq = seq };
        self.participants[participant_index].last_vote_ms = now_ms;
        self.bump();
        return .{ .changed = true, .revision = self.revision, .selected = choice, .seq = seq };
    }

    pub fn toggleOpen(self: *Store) bool {
        const index = self.active_poll orelse return false;
        self.polls[index].open = !self.polls[index].open;
        self.bump();
        return self.polls[index].open;
    }

    pub fn toggleReveal(self: *Store) bool {
        const index = self.active_poll orelse return false;
        self.polls[index].revealed = !self.polls[index].revealed;
        self.bump();
        return self.polls[index].revealed;
    }

    pub fn resetActive(self: *Store) bool {
        const poll_index = self.active_poll orelse return false;
        self.polls[poll_index].counts = @splat(0);
        for (0..self.participant_count) |participant_index| self.votes[poll_index][participant_index] = .{ .seq = 0 };
        self.bump();
        return true;
    }

    pub fn selection(self: *const Store, client_id: []const u8) ClientSelection {
        const participant = self.findParticipant(client_id) orelse return .{};
        const poll = self.active_poll orelse return .{};
        const found = self.votes[poll][participant];
        return .{ .choice = found.choice, .seq = found.seq };
    }

    pub fn snapshot(self: *const Store, now_ms: i64) Snapshot {
        return self.snapshotAt(self.active_poll, now_ms);
    }

    pub fn snapshotFor(self: *const Store, spec: ?slides.CrowdSpec, now_ms: i64) Snapshot {
        const poll_index: ?u8 = if (spec) |crowd|
            if (crowd.kind == .poll) self.findPoll(crowd.id) else null
        else
            null;
        return self.snapshotAt(poll_index, now_ms);
    }

    fn snapshotAt(self: *const Store, active_poll: ?u8, now_ms: i64) Snapshot {
        var result = Snapshot{ .revision = self.revision };
        result.session_id = self.session_id;

        if (active_poll) |poll_index| {
            const poll = &self.polls[poll_index];
            var poll_snapshot = PollSnapshot{
                .id = poll.id,
                .prompt = poll.prompt,
                .choice_count = poll.choice_count,
                .open = poll.open,
                .revealed = poll.revealed,
            };
            for (0..poll.choice_count) |index| {
                poll_snapshot.choices[index] = .{
                    .id = @intCast(index),
                    .label = poll.choices[index],
                    .votes = poll.counts[index],
                };
                poll_snapshot.total += poll.counts[index];
            }
            result.poll = poll_snapshot;
        }

        for (self.participants[0..self.participant_count], 0..) |participant, participant_index| {
            if (now_ms - participant.last_seen_ms > active_window_ms) continue;
            var view = ParticipantView{ .seed = participant.seed };
            if (active_poll) |poll_index| {
                view.choice = self.votes[poll_index][participant_index].choice;
            }
            result.participants[result.participant_count] = view;
            result.participant_count += 1;
        }
        result.connected = result.participant_count;
        return result;
    }

    fn findPoll(self: *const Store, id: []const u8) ?u8 {
        return findPollIn(self.polls[0..self.poll_count], id);
    }

    fn findParticipant(self: *const Store, client_id: []const u8) ?u16 {
        for (self.participants[0..self.participant_count], 0..) |participant, index| {
            if (participant.client_id.eql(client_id)) return @intCast(index);
        }
        return null;
    }

    fn bump(self: *Store) void {
        self.revision +%= 1;
        if (self.revision == 0) self.revision = 1;
    }
};

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    store: Store,
    public_url: FixedText(256) = .{},
    listener: ?std.Io.net.Server = null,
    serve_future: ?std.Io.Future(std.Io.Cancelable!void) = null,
    active_connections: std.atomic.Value(u16) = .init(0),
    port: u16 = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !Runtime {
        var random: [8]u8 = undefined;
        try io.randomSecure(&random);
        return .{
            .allocator = allocator,
            .io = io,
            .store = Store.init(std.mem.readInt(u64, &random, .little)),
        };
    }

    pub fn start(self: *Runtime, requested_port: u16, public_host: []const u8) !u16 {
        if (self.listener != null) return self.port;
        const address: std.Io.net.IpAddress = .{ .ip4 = .unspecified(requested_port) };
        self.listener = try address.listen(self.io, .{ .reuse_address = true });
        errdefer {
            self.listener.?.deinit(self.io);
            self.listener = null;
            self.port = 0;
            self.public_url.set("") catch unreachable;
        }
        self.port = self.listener.?.socket.address.getPort();
        var url_buffer: [256]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buffer, "http://{s}:{d}/", .{ public_host, self.port });
        try self.public_url.set(url);
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
        self.public_url.set("") catch unreachable;
    }

    pub fn configure(self: *Runtime, slideshow: *const slides.SlideShow) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.store.configure(slideshow);
    }

    pub fn activate(self: *Runtime, spec: ?slides.CrowdSpec) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.store.activate(spec);
    }

    pub fn snapshot(self: *Runtime) Snapshot {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.store.snapshot(self.nowMs());
    }

    pub fn snapshotFor(self: *Runtime, spec: ?slides.CrowdSpec) Snapshot {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.store.snapshotFor(spec, self.nowMs());
    }

    pub fn toggleOpen(self: *Runtime) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.store.toggleOpen();
    }

    pub fn toggleReveal(self: *Runtime) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.store.toggleReveal();
    }

    pub fn resetActive(self: *Runtime) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.store.resetActive();
    }

    pub fn isRunning(self: *const Runtime) bool {
        return self.listener != null;
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
                    std.log.err("Crowdplay accept failed: {t}", .{err});
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
                std.log.err("Crowdplay connection task failed: {t}", .{err});
                stream.close(self.io);
            };
        }
    }

    fn handleConnectionTask(self: *Runtime, stream: std.Io.net.Stream) std.Io.Cancelable!void {
        defer _ = self.active_connections.fetchSub(1, .acq_rel);
        self.handleConnection(stream) catch |err| std.log.warn("Crowdplay request failed: {t}", .{err});
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

        if (request.head.method == .GET and std.mem.eql(u8, path, "/")) {
            return request.respond(audience_html, .{
                .keep_alive = false,
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
                    .{ .name = "Cache-Control", .value = "no-store" },
                    .{ .name = "X-Content-Type-Options", .value = "nosniff" },
                    .{ .name = "Content-Security-Policy", .value = "default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; img-src 'self' data:" },
                },
            });
        }

        if (request.head.method == .GET and std.mem.eql(u8, path, "/api/v1/state")) {
            const client_id = queryValue(target, "client_id") orelse "";
            self.mutex.lockUncancelable(self.io);
            const joined = self.store.heartbeat(client_id, self.nowMs());
            const state = self.store.snapshot(self.nowMs());
            const selection = self.store.selection(client_id);
            self.mutex.unlock(self.io);
            return self.respondState(&request, state, selection, joined, .ok);
        }

        if (request.head.method == .POST and std.mem.eql(u8, path, "/api/v1/join")) {
            if (!hasJsonContentType(&request)) return respondError(&request, .unsupported_media_type, "Content-Type must be application/json");
            const body = self.readBody(&request) catch |err| switch (err) {
                error.BodyTooLarge, error.StreamTooLong => return respondError(&request, .payload_too_large, "request body too large"),
                else => return err,
            };
            defer self.allocator.free(body);
            const parsed = std.json.parseFromSlice(JoinRequest, self.allocator, body, .{}) catch {
                return respondError(&request, .bad_request, "invalid join request");
            };
            defer parsed.deinit();
            self.mutex.lockUncancelable(self.io);
            _ = self.store.join(parsed.value.client_id, parsed.value.display_name orelse "", self.nowMs()) catch |err| {
                self.mutex.unlock(self.io);
                return respondStoreError(&request, err);
            };
            const state = self.store.snapshot(self.nowMs());
            const selection = self.store.selection(parsed.value.client_id);
            self.mutex.unlock(self.io);
            return self.respondState(&request, state, selection, true, .ok);
        }

        if (request.head.method == .POST and std.mem.eql(u8, path, "/api/v1/vote")) {
            if (!hasJsonContentType(&request)) return respondError(&request, .unsupported_media_type, "Content-Type must be application/json");
            const body = self.readBody(&request) catch |err| switch (err) {
                error.BodyTooLarge, error.StreamTooLong => return respondError(&request, .payload_too_large, "request body too large"),
                else => return err,
            };
            defer self.allocator.free(body);
            const parsed = std.json.parseFromSlice(VoteRequest, self.allocator, body, .{}) catch {
                return respondError(&request, .bad_request, "invalid vote request");
            };
            defer parsed.deinit();
            self.mutex.lockUncancelable(self.io);
            _ = self.store.vote(parsed.value.client_id, parsed.value.poll_id, parsed.value.choice_id, parsed.value.seq, self.nowMs()) catch |err| {
                const state = self.store.snapshot(self.nowMs());
                const selection = self.store.selection(parsed.value.client_id);
                self.mutex.unlock(self.io);
                if (err == error.PollClosed or err == error.PollChanged or err == error.NoActivePoll) {
                    return self.respondState(&request, state, selection, true, .conflict);
                }
                return respondStoreError(&request, err);
            };
            const state = self.store.snapshot(self.nowMs());
            const selection = self.store.selection(parsed.value.client_id);
            self.mutex.unlock(self.io);
            return self.respondState(&request, state, selection, true, .ok);
        }

        if (request.head.method == .GET and std.mem.eql(u8, path, "/health")) {
            return request.respond("ok\n", .{ .keep_alive = false, .extra_headers = text_headers });
        }
        return respondError(&request, .not_found, "not found");
    }

    fn readBody(self: *Runtime, request: *std.http.Server.Request) ![]u8 {
        if (request.head.content_length) |length| {
            if (length > 4096) return error.BodyTooLarge;
        }
        var body_buffer: [4096]u8 = undefined;
        const reader = try request.readerExpectContinue(&body_buffer);
        return reader.allocRemaining(self.allocator, .limited(4096));
    }

    fn respondState(self: *Runtime, request: *std.http.Server.Request, state: Snapshot, selection: ClientSelection, joined: bool, status: std.http.Status) !void {
        var json_buffer: [16 * 1024]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&json_buffer);
        try stringifyState(&state, selection, joined, self.public_url.slice(), &writer);
        try request.respond(writer.buffered(), .{ .status = status, .keep_alive = false, .extra_headers = api_headers });
    }
};

const JoinRequest = struct {
    client_id: []const u8,
    display_name: ?[]const u8 = null,
};

const VoteRequest = struct {
    client_id: []const u8,
    poll_id: []const u8,
    choice_id: u8,
    seq: u32,
};

const api_headers: []const std.http.Header = &.{
    .{ .name = "Content-Type", .value = "application/json; charset=utf-8" },
    .{ .name = "Cache-Control", .value = "no-store" },
    .{ .name = "X-Content-Type-Options", .value = "nosniff" },
};

const text_headers: []const std.http.Header = &.{
    .{ .name = "Content-Type", .value = "text/plain; charset=utf-8" },
    .{ .name = "Cache-Control", .value = "no-store" },
};

const audience_html = @embedFile("assets/crowdplay.html");

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

fn respondStoreError(request: *std.http.Server.Request, err: anyerror) !void {
    return switch (err) {
        error.Capacity => respondError(request, .too_many_requests, "room is full"),
        error.RateLimited => respondError(request, .too_many_requests, "please wait before voting again"),
        error.UnknownParticipant => respondError(request, .unauthorized, "join before voting"),
        error.InvalidChoice, error.InvalidClient, error.TooLong => respondError(request, .bad_request, "invalid request"),
        else => respondError(request, .bad_request, "request rejected"),
    };
}

fn stringifyState(state: *const Snapshot, selection: ClientSelection, joined: bool, public_url: []const u8, writer: *std.Io.Writer) !void {
    const WireChoice = struct { id: u8, label: []const u8, votes: u32 };
    const WirePoll = struct {
        id: []const u8,
        prompt: []const u8,
        open: bool,
        revealed: bool,
        total: u32,
        vote_seq: u32,
        selected: ?u8,
        choices: []const WireChoice,
    };
    const WireState = struct {
        session_id: []const u8,
        revision: u64,
        joined: bool,
        connected: u16,
        server_name: []const u8,
        url: []const u8,
        poll: ?WirePoll,
    };

    var choices: [max_choices]WireChoice = undefined;
    var wire_poll: ?WirePoll = null;
    if (state.poll) |*poll| {
        const reveal_results = poll.revealed;
        for (poll.choices[0..poll.choice_count], 0..) |*choice, index| {
            choices[index] = .{ .id = choice.id, .label = choice.label.slice(), .votes = if (reveal_results) choice.votes else 0 };
        }
        wire_poll = .{
            .id = poll.id.slice(),
            .prompt = poll.prompt.slice(),
            .open = poll.open,
            .revealed = poll.revealed,
            .total = if (reveal_results) poll.total else 0,
            .vote_seq = selection.seq,
            .selected = selection.choice,
            .choices = choices[0..poll.choice_count],
        };
    }
    try std.json.Stringify.value(WireState{
        .session_id = state.session_id.slice(),
        .revision = state.revision,
        .joined = joined,
        .connected = state.connected,
        .server_name = "rayslides Crowdplay",
        .url = public_url,
        .poll = wire_poll,
    }, .{}, writer);
}

fn findPollIn(polls: []const Poll, id: []const u8) ?u8 {
    for (polls, 0..) |poll, index| if (poll.id.eql(id)) return @intCast(index);
    return null;
}

fn validateClientId(client_id: []const u8) error{InvalidClient}!void {
    if (client_id.len < 8 or client_id.len > 64) return error.InvalidClient;
    for (client_id) |char| {
        if (!std.ascii.isAlphanumeric(char) and char != '-' and char != '_') return error.InvalidClient;
    }
}

fn validateCrowdSpec(spec: slides.CrowdSpec) !void {
    if (spec.prompt.len == 0 or spec.prompt.len > 192) return error.InvalidPrompt;
    if (spec.kind == .join) return;
    if (spec.id.len == 0 or spec.id.len > 48) return error.InvalidPollId;
    for (spec.id) |char| {
        if (!std.ascii.isAlphanumeric(char) and char != '-' and char != '_') return error.InvalidPollId;
    }
    if (spec.choices.len < 2 or spec.choices.len > max_choices) return error.InvalidChoices;
    for (spec.choices) |choice| {
        if (choice.len == 0 or choice.len > 64) return error.InvalidChoices;
    }
}

test "one participant gets one replaceable, idempotent vote" {
    var store = Store.init(0xCAFE);
    var poll = Poll{};
    try poll.id.set("future");
    try poll.prompt.set("Where next?");
    try poll.choices[0].set("Moon");
    try poll.choices[1].set("Mars");
    poll.choice_count = 2;
    store.polls[0] = poll;
    store.poll_count = 1;
    store.active_poll = 0;

    _ = try store.join("browser-0001", "Ada", 100);
    const first = try store.vote("browser-0001", "future", 0, 1, 101);
    try std.testing.expect(first.changed);
    const duplicate = try store.vote("browser-0001", "future", 0, 1, 102);
    try std.testing.expect(!duplicate.changed);
    try std.testing.expectError(error.RateLimited, store.vote("browser-0001", "future", 1, 2, 150));
    _ = try store.vote("browser-0001", "future", 1, 2, 201);

    const snapshot = store.snapshot(202);
    try std.testing.expectEqual(@as(u32, 0), snapshot.poll.?.choices[0].votes);
    try std.testing.expectEqual(@as(u32, 1), snapshot.poll.?.choices[1].votes);
    try std.testing.expectEqual(@as(u32, 1), snapshot.poll.?.total);
    try std.testing.expectEqual(@as(?u8, 1), store.selection("browser-0001").choice);
}

test "closed polls reject votes and reset removes only their votes" {
    var store = Store.init(1);
    var poll = Poll{ .open = false };
    try poll.id.set("locked");
    try poll.prompt.set("Locked?");
    try poll.choices[0].set("Yes");
    try poll.choices[1].set("No");
    poll.choice_count = 2;
    store.polls[0] = poll;
    store.poll_count = 1;
    store.active_poll = 0;
    _ = try store.join("browser-0002", "", 100);
    try std.testing.expectError(error.PollClosed, store.vote("browser-0002", "locked", 0, 1, 101));
    try std.testing.expect(store.toggleOpen());
    try std.testing.expect(store.toggleReveal());
    try std.testing.expect(store.snapshot(102).poll.?.revealed);
    try std.testing.expect(!store.toggleReveal());
    _ = try store.vote("browser-0002", "locked", 0, 1, 102);
    try std.testing.expect(store.resetActive());
    try std.testing.expectEqual(@as(u32, 0), store.snapshot(103).poll.?.total);
}

test "inactive participants age out of connected snapshots" {
    var store = Store.init(2);
    _ = try store.join("browser-0003", "Grace", 0);
    try std.testing.expectEqual(@as(u16, 1), store.snapshot(active_window_ms).connected);
    try std.testing.expectEqual(@as(u16, 0), store.snapshot(active_window_ms + 1).connected);
}

test "expired participant slots are recycled without retaining votes" {
    var store = Store.init(3);
    var poll = Poll{};
    try poll.id.set("recycle");
    try poll.prompt.set("Still here?");
    try poll.choices[0].set("Yes");
    try poll.choices[1].set("No");
    poll.choice_count = 2;
    store.polls[0] = poll;
    store.poll_count = 1;
    store.active_poll = 0;

    var id_buffer: [32]u8 = undefined;
    for (0..max_participants) |index| {
        const id = try std.fmt.bufPrint(&id_buffer, "browser-{d:0>4}", .{index});
        _ = try store.join(id, "", 0);
    }
    _ = try store.vote("browser-0000", "recycle", 0, 1, 1);
    _ = try store.join("browser-newcomer", "", active_window_ms + 1);

    try std.testing.expectEqual(@as(u16, max_participants), store.participant_count);
    try std.testing.expect(store.findParticipant("browser-0000") == null);
    try std.testing.expect(store.findParticipant("browser-newcomer") != null);
    try std.testing.expectEqual(@as(u32, 0), store.snapshot(active_window_ms + 1).poll.?.total);
}

test "reconfigure preserves unchanged poll votes and rejects duplicate ids" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const slideshow = try slides.SlideShow.new(allocator);
    const slide = try slides.Slide.new(allocator);
    const spec = slides.CrowdSpec{ .kind = .poll, .id = "stable", .prompt = "Keep votes?", .choices = &.{ "Yes", "Absolutely" } };
    try slide.items.?.append(allocator, .{ .kind = .crowd, .crowd = spec });
    try slideshow.slides.append(allocator, slide);

    var store = Store.init(4);
    try store.configure(slideshow);
    store.activate(spec);
    _ = try store.join("browser-stable", "", 10);
    _ = try store.vote("browser-stable", "stable", 1, 1, 11);
    try store.configure(slideshow);
    try std.testing.expectEqual(@as(u32, 1), store.snapshot(12).poll.?.total);
    try std.testing.expectEqual(@as(?u8, 1), store.selection("browser-stable").choice);

    const duplicate_slide = try slides.Slide.new(allocator);
    try duplicate_slide.items.?.append(allocator, .{ .kind = .crowd, .crowd = spec });
    try slideshow.slides.append(allocator, duplicate_slide);
    try std.testing.expectError(error.DuplicatePoll, store.configure(slideshow));
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
    return reader.interface.allocRemaining(allocator, .limited(32 * 1024));
}

test "HTTP join, vote, and state flow works over loopback" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var runtime = try Runtime.init(allocator, io);
    defer runtime.stop();

    var poll = Poll{};
    try poll.id.set("launch");
    try poll.prompt.set("Ready?");
    try poll.choices[0].set("Yes");
    try poll.choices[1].set("Absolutely");
    poll.choice_count = 2;
    runtime.store.polls[0] = poll;
    runtime.store.poll_count = 1;
    runtime.store.active_poll = 0;

    const port = try runtime.start(0, "127.0.0.1");
    const health = try rawHttp(allocator, io, port, "GET /health HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    defer allocator.free(health);
    try std.testing.expect(std.mem.indexOf(u8, health, "200 OK") != null);

    const join_body = "{\"client_id\":\"browser-http-1\",\"display_name\":\"Ada\"}";
    const join_request = try std.fmt.allocPrint(allocator, "POST /api/v1/join HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ join_body.len, join_body });
    defer allocator.free(join_request);
    const join_response = try rawHttp(allocator, io, port, join_request);
    defer allocator.free(join_response);
    try std.testing.expect(std.mem.indexOf(u8, join_response, "200 OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, join_response, "\"connected\":1") != null);

    const vote_body = "{\"client_id\":\"browser-http-1\",\"poll_id\":\"launch\",\"choice_id\":1,\"seq\":1}";
    const vote_request = try std.fmt.allocPrint(allocator, "POST /api/v1/vote HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ vote_body.len, vote_body });
    defer allocator.free(vote_request);
    const vote_response = try rawHttp(allocator, io, port, vote_request);
    defer allocator.free(vote_response);
    try std.testing.expect(std.mem.indexOf(u8, vote_response, "200 OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, vote_response, "\"selected\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, vote_response, "\"votes\":0") != null);

    try std.testing.expect(runtime.toggleReveal());

    const state_response = try rawHttp(allocator, io, port, "GET /api/v1/state?client_id=browser-http-1&revision=0 HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    defer allocator.free(state_response);
    try std.testing.expect(std.mem.indexOf(u8, state_response, "\"prompt\":\"Ready?\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, state_response, "\"total\":1") != null);

    const wrong_type_body = "{\"client_id\":\"browser-http-2\"}";
    const wrong_type_request = try std.fmt.allocPrint(allocator, "POST /api/v1/join HTTP/1.1\r\nHost: localhost\r\nContent-Type: text/plain\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ wrong_type_body.len, wrong_type_body });
    defer allocator.free(wrong_type_request);
    const wrong_type_response = try rawHttp(allocator, io, port, wrong_type_request);
    defer allocator.free(wrong_type_response);
    try std.testing.expect(std.mem.indexOf(u8, wrong_type_response, "415 Unsupported Media Type") != null);

    runtime.stop();
    try std.testing.expect(!runtime.isRunning());
    try std.testing.expectEqual(@as(usize, 0), runtime.public_url.slice().len);
    const restarted_port = try runtime.start(0, "127.0.0.1");
    const restarted_health = try rawHttp(allocator, io, restarted_port, "GET /health HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    defer allocator.free(restarted_health);
    try std.testing.expect(std.mem.indexOf(u8, restarted_health, "200 OK") != null);
}
