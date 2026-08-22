const std = @import("std");
const builtin = @import("builtin");
const slides = @import("slides.zig");

const network_c = if (builtin.os.tag == .windows) struct {} else @cImport({
    @cInclude("ifaddrs.h");
    @cInclude("net/if.h");
    @cInclude("netinet/in.h");
});

const WindowsNetwork = struct {
    const windows = std.os.windows;
    const ws2 = windows.ws2_32;

    const SocketAddress = extern struct {
        address: ?*ws2.sockaddr,
        length: i32,
    };

    const UnicastAddress = extern struct {
        alignment: u64,
        next: ?*UnicastAddress,
        address: SocketAddress,
    };

    const AdapterAddress = extern struct {
        alignment: u64,
        next: ?*AdapterAddress,
        adapter_name: ?[*:0]u8,
        first_unicast: ?*UnicastAddress,
        first_anycast: ?*anyopaque,
        first_multicast: ?*anyopaque,
        first_dns_server: ?*anyopaque,
        dns_suffix: ?[*:0]u16,
        description: ?[*:0]u16,
        friendly_name: ?[*:0]u16,
        physical_address: [8]u8,
        physical_address_len: u32,
        flags: u32,
        mtu: u32,
        interface_type: u32,
        operating_status: u32,
    };

    const address_family_ipv4: u32 = 2;
    const no_error: u32 = 0;
    const skip_anycast: u32 = 0x0002;
    const skip_multicast: u32 = 0x0004;
    const skip_dns_server: u32 = 0x0008;
    const interface_up: u32 = 1;
    const interface_ethernet: u32 = 6;
    const interface_ppp: u32 = 23;
    const interface_loopback: u32 = 24;
    const interface_wifi: u32 = 71;
    const interface_tunnel: u32 = 131;

    extern "iphlpapi" fn GetAdaptersAddresses(
        family: u32,
        flags: u32,
        reserved: ?*anyopaque,
        addresses: *AdapterAddress,
        buffer_len: *u32,
    ) callconv(.winapi) u32;
};

pub const default_port: u16 = 7332;
pub const max_connections: u16 = 16;
pub const max_commands: usize = 32;
pub const max_drawing_events: usize = 256;
pub const connected_window_ms: i64 = 12_000;
pub const pointer_timeout_ms: i64 = 900;
pub const drawing_timeout_ms: i64 = 900;
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

pub const max_local_addresses: usize = 16;

pub const LocalAddressKind = enum {
    explicit,
    private_lan,
    public_lan,
    vpn,
    link_local,
    loopback,

    pub fn label(self: LocalAddressKind) []const u8 {
        return switch (self) {
            .explicit => "EXPLICIT ADDRESS",
            .private_lan => "PRIVATE LAN",
            .public_lan => "PUBLIC NETWORK",
            .vpn => "VPN / VIRTUAL",
            .link_local => "LINK-LOCAL ONLY",
            .loopback => "THIS COMPUTER ONLY",
        };
    }

    pub fn guidance(self: LocalAddressKind) []const u8 {
        return switch (self) {
            .explicit => "Verify the phone can reach this configured host",
            .private_lan => "Phone must be on the same Wi-Fi or hotspot",
            .public_lan => "Phone must be on this network; prefer a private hotspot",
            .vpn => "Phone must share this VPN; a Wi-Fi/hotspot address is safer",
            .link_local => "May not route between devices; use Wi-Fi or a phone hotspot",
            .loopback => "Only a browser on this computer can connect",
        };
    }
};

pub const LocalAddress = struct {
    host: FixedText(64) = .{},
    interface_name: FixedText(48) = .{},
    kind: LocalAddressKind = .loopback,

    pub fn init(host: []const u8, interface_name: []const u8, kind: LocalAddressKind) ?LocalAddress {
        var result: LocalAddress = .{ .kind = kind };
        result.host.set(host) catch return null;
        result.interface_name.set(interface_name) catch return null;
        return result;
    }

    fn rank(self: LocalAddress) u16 {
        return switch (self.kind) {
            .explicit => 600,
            .private_lan => 500,
            .public_lan => 400,
            .vpn => 300,
            .link_local => 100,
            .loopback => 0,
        };
    }
};

pub const LocalAddressDiscovery = struct {
    addresses: [max_local_addresses]LocalAddress = @splat(.{}),
    len: usize = 0,

    pub fn add(self: *LocalAddressDiscovery, candidate: LocalAddress) void {
        for (self.addresses[0..self.len]) |existing| {
            if (existing.host.eql(candidate.host.slice())) return;
        }
        if (self.len == self.addresses.len) return;
        self.addresses[self.len] = candidate;
        self.len += 1;
    }

    pub fn preferred(self: *const LocalAddressDiscovery) ?LocalAddress {
        var best: ?LocalAddress = null;
        for (self.addresses[0..self.len]) |candidate| {
            if (best == null or candidate.rank() > best.?.rank()) best = candidate;
        }
        return best;
    }
};

fn interfaceIsVirtual(name: []const u8) bool {
    const virtual_prefixes = [_][]const u8{
        "utun",   "tun",  "tap",    "ppp",   "ipsec", "wg",   "tailscale", "zt", "vpn",
        "docker", "veth", "bridge", "vmnet", "vbox",  "awdl", "llw",
    };
    for (virtual_prefixes) |prefix| {
        if (name.len >= prefix.len and std.ascii.eqlIgnoreCase(name[0..prefix.len], prefix)) return true;
    }
    return false;
}

fn classifyIpv4(bytes: [4]u8, interface_name: []const u8) LocalAddressKind {
    if (bytes[0] == 127) return .loopback;
    if (bytes[0] == 169 and bytes[1] == 254) return .link_local;
    if (interfaceIsVirtual(interface_name)) return .vpn;
    if (bytes[0] == 10 or
        (bytes[0] == 172 and bytes[1] >= 16 and bytes[1] <= 31) or
        (bytes[0] == 192 and bytes[1] == 168))
    {
        return .private_lan;
    }
    return .public_lan;
}

fn addIpv4Candidate(
    discovery: *LocalAddressDiscovery,
    bytes: [4]u8,
    interface_name: []const u8,
) void {
    if (bytes[0] == 0 and bytes[1] == 0 and bytes[2] == 0 and bytes[3] == 0) return;
    var host_buffer: [15]u8 = undefined;
    const host = std.fmt.bufPrint(
        &host_buffer,
        "{d}.{d}.{d}.{d}",
        .{ bytes[0], bytes[1], bytes[2], bytes[3] },
    ) catch return;
    if (LocalAddress.init(host, interface_name, classifyIpv4(bytes, interface_name))) |candidate|
        discovery.add(candidate);
}

/// Enumerate active IPv4 interfaces without opening a route or contacting the
/// Internet. IPv4 keeps QR addresses short and covers ordinary venue Wi-Fi and
/// phone hotspots; an explicit --presenter-host remains available for unusual
/// IPv6-only or policy-managed networks.
pub fn discoverLocalAddresses() LocalAddressDiscovery {
    var result: LocalAddressDiscovery = .{};
    if (comptime builtin.os.tag == .windows) {
        var adapter_buffer: [32 * 1024]u8 align(@alignOf(WindowsNetwork.AdapterAddress)) = undefined;
        var adapter_buffer_len: u32 = adapter_buffer.len;
        const adapters: *WindowsNetwork.AdapterAddress = @ptrCast(&adapter_buffer);
        const flags = WindowsNetwork.skip_anycast |
            WindowsNetwork.skip_multicast |
            WindowsNetwork.skip_dns_server;
        if (WindowsNetwork.GetAdaptersAddresses(
            WindowsNetwork.address_family_ipv4,
            flags,
            null,
            adapters,
            &adapter_buffer_len,
        ) == WindowsNetwork.no_error) {
            var adapter: ?*WindowsNetwork.AdapterAddress = adapters;
            while (adapter) |entry| : (adapter = entry.next) {
                if (entry.operating_status != WindowsNetwork.interface_up) continue;
                const interface_name: []const u8 = switch (entry.interface_type) {
                    WindowsNetwork.interface_wifi => "Wi-Fi",
                    WindowsNetwork.interface_ethernet => "Ethernet",
                    WindowsNetwork.interface_ppp, WindowsNetwork.interface_tunnel => "VPN",
                    WindowsNetwork.interface_loopback => "loopback",
                    else => "Network adapter",
                };
                var unicast = entry.first_unicast;
                while (unicast) |unicast_entry| : (unicast = unicast_entry.next) {
                    const address = unicast_entry.address.address orelse continue;
                    if (address.family != WindowsNetwork.ws2.AF.INET) continue;
                    const ipv4: *const WindowsNetwork.ws2.sockaddr.in = @ptrCast(@alignCast(address));
                    const bytes_ptr: *const [4]u8 = @ptrCast(&ipv4.addr);
                    addIpv4Candidate(&result, bytes_ptr.*, interface_name);
                }
            }
        }
        if (result.len == 0) result.add(LocalAddress.init("127.0.0.1", "loopback", .loopback).?);
        return result;
    }

    var head: ?*network_c.struct_ifaddrs = null;
    if (network_c.getifaddrs(&head) != 0) {
        result.add(LocalAddress.init("127.0.0.1", "loopback", .loopback).?);
        return result;
    }
    defer network_c.freeifaddrs(head);

    var cursor = head;
    while (cursor) |entry| : (cursor = entry.ifa_next) {
        if ((entry.ifa_flags & network_c.IFF_UP) == 0) continue;
        const address = entry.ifa_addr orelse continue;
        if (address.*.sa_family != network_c.AF_INET) continue;
        const ipv4: *const network_c.struct_sockaddr_in = @ptrCast(@alignCast(address));
        const bytes_ptr: *const [4]u8 = @ptrCast(&ipv4.sin_addr);
        addIpv4Candidate(&result, bytes_ptr.*, std.mem.span(entry.ifa_name));
    }
    if (result.len == 0) result.add(LocalAddress.init("127.0.0.1", "loopback", .loopback).?);
    return result;
}

test "presenter address discovery classifies and ranks venue interfaces" {
    try std.testing.expectEqual(LocalAddressKind.loopback, classifyIpv4(.{ 127, 0, 0, 1 }, "lo0"));
    try std.testing.expectEqual(LocalAddressKind.link_local, classifyIpv4(.{ 169, 254, 4, 2 }, "en0"));
    try std.testing.expectEqual(LocalAddressKind.private_lan, classifyIpv4(.{ 192, 168, 1, 8 }, "en0"));
    try std.testing.expectEqual(LocalAddressKind.private_lan, classifyIpv4(.{ 172, 20, 10, 2 }, "en1"));
    try std.testing.expectEqual(LocalAddressKind.vpn, classifyIpv4(.{ 10, 8, 0, 4 }, "utun4"));
    try std.testing.expectEqual(LocalAddressKind.public_lan, classifyIpv4(.{ 100, 64, 1, 2 }, "en0"));

    var discovery: LocalAddressDiscovery = .{};
    discovery.add(LocalAddress.init("127.0.0.1", "lo0", .loopback).?);
    discovery.add(LocalAddress.init("10.8.0.4", "utun4", .vpn).?);
    discovery.add(LocalAddress.init("172.20.10.2", "en1", .private_lan).?);
    discovery.add(LocalAddress.init("172.20.10.2", "duplicate", .public_lan).?);
    try std.testing.expectEqual(@as(usize, 3), discovery.len);
    try std.testing.expectEqualStrings("172.20.10.2", discovery.preferred().?.host.slice());
    try std.testing.expectEqualStrings("Phone must be on the same Wi-Fi or hotspot", discovery.preferred().?.kind.guidance());
}

pub const Command = enum {
    previous,
    next,
    clear_drawing,
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
    drawing_enabled: bool,
};

pub const PointerSample = struct {
    active: bool = false,
    x: f32 = 0,
    y: f32 = 0,
    sequence: u64 = 0,
};

pub const DrawingPhase = enum {
    begin,
    move,
    end,
};

pub const DrawingEvent = struct {
    phase: DrawingPhase = .end,
    x: f32 = 0,
    y: f32 = 0,
    sequence: u64 = 0,
};

pub const LatencyMetric = struct {
    samples: u16 = 0,
    failures: u16 = 0,
    median_ms: ?u32 = null,
    p95_ms: ?u32 = null,
};

/// Browser-measured, secret-free delivery evidence retained only for the
/// current pairing session. Notes, URLs, capability, and client identity are
/// intentionally absent so Showtime may report it safely.
pub const ClientHealth = struct {
    state: LatencyMetric = .{},
    command: LatencyMetric = .{},
    pointer: LatencyMetric = .{},
    drawing: LatencyMetric = .{},
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
    drawing_enabled: bool = false,
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
    drawing_events: [max_drawing_events]DrawingEvent = @splat(.{}),
    drawing_head: usize = 0,
    drawing_count: usize = 0,
    drawing_open: bool = false,
    drawing_last_seen_ms: i64 = 0,
    drawing_position: struct { x: f32 = 0, y: f32 = 0 } = .{},
    last_drawing_sequence: u64 = 0,
    client_health: ClientHealth = .{},
    client_health_seen_ms: i64 = 0,

    fn resetSession(self: *Store, random: [40]u8, now_ms: i64) void {
        const preview_storage = self.preview_storage;
        const session_hex = std.fmt.bytesToHex(random[0..8], .lower);
        const capability_hex = std.fmt.bytesToHex(random[8..40], .lower);
        self.* = .{ .preview_storage = preview_storage, .started_at_ms = now_ms };
        self.snapshot.session_id.set(&session_hex) catch unreachable;
        self.capability.set(&capability_hex) catch unreachable;
    }

    fn invalidateSession(self: *Store) void {
        const preview_storage = self.preview_storage;
        self.* = .{ .preview_storage = preview_storage };
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
            self.snapshot.drawing_enabled != input.drawing_enabled or
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
        self.snapshot.drawing_enabled = input.drawing_enabled;
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

    fn enqueueDrawing(self: *Store, event: DrawingEvent, now_ms: i64) error{ InvalidDrawing, Capacity }!bool {
        if (event.sequence == 0 or event.sequence <= self.last_drawing_sequence) return false;
        if (!std.math.isFinite(event.x) or !std.math.isFinite(event.y) or
            event.x < 0 or event.x > 1 or event.y < 0 or event.y > 1)
        {
            return error.InvalidDrawing;
        }
        if (self.drawing_count >= self.drawing_events.len) {
            if (event.phase != .move or self.drawing_count == 0) return error.Capacity;
            const tail = (self.drawing_head + self.drawing_count - 1) % self.drawing_events.len;
            if (self.drawing_events[tail].phase != .move) return error.Capacity;
            self.drawing_events[tail] = event;
        } else {
            const tail = (self.drawing_head + self.drawing_count) % self.drawing_events.len;
            self.drawing_events[tail] = event;
            self.drawing_count += 1;
        }
        self.drawing_open = event.phase != .end;
        self.drawing_last_seen_ms = now_ms;
        self.drawing_position = .{ .x = event.x, .y = event.y };
        self.last_drawing_sequence = event.sequence;
        return true;
    }

    fn takeDrawing(self: *Store, now_ms: i64) ?DrawingEvent {
        if (self.drawing_count > 0) {
            const event = self.drawing_events[self.drawing_head];
            self.drawing_head = (self.drawing_head + 1) % self.drawing_events.len;
            self.drawing_count -= 1;
            return event;
        }
        if (!self.drawing_open or self.drawing_last_seen_ms == 0 or
            now_ms - self.drawing_last_seen_ms <= drawing_timeout_ms)
        {
            return null;
        }
        self.drawing_open = false;
        return .{
            .phase = .end,
            .x = self.drawing_position.x,
            .y = self.drawing_position.y,
            .sequence = self.last_drawing_sequence,
        };
    }

    fn clearDrawingInput(self: *Store) void {
        self.drawing_head = 0;
        self.drawing_count = 0;
        self.drawing_open = false;
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

        self.port = self.listener.?.socket.address.getPort();
        try self.installSession(public_host);
        self.serve_future = try self.io.concurrent(serve, .{self});
        return self.port;
    }

    /// Rotate both the session identity and private capability while keeping
    /// the listener/port alive. Network changes therefore produce a fresh QR;
    /// returning to the previous venue network can never revive its old URL.
    pub fn rePair(self: *Runtime, public_host: []const u8) !void {
        if (self.listener == null) return error.NotRunning;
        try self.installSession(public_host);
    }

    fn installSession(self: *Runtime, public_host: []const u8) !void {
        var base_buffer: [256]u8 = undefined;
        const base = try std.fmt.bufPrint(&base_buffer, "http://{s}:{d}", .{ public_host, self.port });
        var random: [40]u8 = undefined;
        try self.io.randomSecure(&random);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.store.resetSession(random, self.nowMs());
        var pairing_buffer: [384]u8 = undefined;
        const pairing = try std.fmt.bufPrint(
            &pairing_buffer,
            "{s}/presenter/#{s}",
            .{ base, self.store.capability.slice() },
        );
        try self.base_url.set(base);
        try self.pairing_url.set(pairing);
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
        self.mutex.lockUncancelable(self.io);
        self.store.invalidateSession();
        self.mutex.unlock(self.io);
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

    pub fn clientHealth(self: *Runtime) ?ClientHealth {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.store.client_health_seen_ms == 0 or
            self.nowMs() - self.store.client_health_seen_ms > connected_window_ms)
        {
            return null;
        }
        return self.store.client_health;
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

    pub fn takeDrawing(self: *Runtime) ?DrawingEvent {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.store.takeDrawing(self.nowMs());
    }

    pub fn clearDrawingInput(self: *Runtime) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.store.clearDrawingInput();
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
        self.handleConnection(stream) catch |err| switch (err) {
            // Browsers routinely open and abandon speculative HTTP
            // connections. They never reached a request and are not a venue
            // failure worth alarming the presenter about.
            error.HttpRequestTruncated => {},
            else => std.log.warn("Presenter Companion request failed: {t}", .{err}),
        };
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
            if (!self.store.authorized(token)) {
                self.mutex.unlock(self.io);
                return respondError(&request, .unauthorized, "presenter pairing required");
            }
            const accepted_at_ms = self.nowMs();
            self.store.last_seen_ms = accepted_at_ms;
            const queued = self.store.enqueue(command, parsed.value.seq) catch {
                self.mutex.unlock(self.io);
                return respondError(&request, .too_many_requests, "presenter command queue is full");
            };
            self.mutex.unlock(self.io);
            return respondCommand(&request, parsed.value.seq, queued, accepted_at_ms);
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
            if (!self.store.authorized(token)) {
                self.mutex.unlock(self.io);
                return respondError(&request, .unauthorized, "presenter pairing required");
            }
            const accepted_at_ms = self.nowMs();
            self.store.last_seen_ms = accepted_at_ms;
            const accepted = self.store.updatePointer(sample, accepted_at_ms) catch {
                self.mutex.unlock(self.io);
                return respondError(&request, .bad_request, "pointer coordinates must be normalized");
            };
            self.mutex.unlock(self.io);
            return respondPointer(&request, parsed.value.seq, accepted, accepted_at_ms);
        }

        if (request.head.method == .POST and std.mem.eql(u8, path, "/api/v1/presenter/drawing")) {
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
            const parsed = std.json.parseFromSlice(DrawingRequest, self.allocator, body, .{}) catch {
                return respondError(&request, .bad_request, "invalid drawing update");
            };
            defer parsed.deinit();
            const phase = std.meta.stringToEnum(DrawingPhase, parsed.value.phase) orelse
                return respondError(&request, .bad_request, "unknown drawing phase");
            const event = DrawingEvent{
                .phase = phase,
                .x = parsed.value.x,
                .y = parsed.value.y,
                .sequence = parsed.value.seq,
            };
            self.mutex.lockUncancelable(self.io);
            if (!self.store.authorized(token)) {
                self.mutex.unlock(self.io);
                return respondError(&request, .unauthorized, "presenter pairing required");
            }
            const accepted_at_ms = self.nowMs();
            self.store.last_seen_ms = accepted_at_ms;
            const queued = self.store.enqueueDrawing(event, accepted_at_ms) catch |err| switch (err) {
                error.InvalidDrawing => {
                    self.mutex.unlock(self.io);
                    return respondError(&request, .bad_request, "drawing coordinates must be normalized");
                },
                error.Capacity => {
                    self.mutex.unlock(self.io);
                    return respondError(&request, .too_many_requests, "drawing queue is full");
                },
            };
            self.mutex.unlock(self.io);
            return respondDrawing(&request, parsed.value.seq, queued, accepted_at_ms);
        }

        if (request.head.method == .POST and std.mem.eql(u8, path, "/api/v1/presenter/health")) {
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
            const parsed = std.json.parseFromSlice(ClientHealth, self.allocator, body, .{}) catch {
                return respondError(&request, .bad_request, "invalid connection health report");
            };
            defer parsed.deinit();
            if (!validClientHealth(parsed.value))
                return respondError(&request, .bad_request, "connection health values are out of range");
            self.mutex.lockUncancelable(self.io);
            if (!self.store.authorized(token)) {
                self.mutex.unlock(self.io);
                return respondError(&request, .unauthorized, "presenter pairing required");
            }
            const accepted_at_ms = self.nowMs();
            self.store.last_seen_ms = accepted_at_ms;
            self.store.client_health = parsed.value;
            self.store.client_health_seen_ms = accepted_at_ms;
            self.mutex.unlock(self.io);
            return respondHealth(&request, accepted_at_ms);
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

const DrawingRequest = struct {
    phase: []const u8,
    x: f32,
    y: f32,
    seq: u64,
};

fn validLatencyMetric(metric: LatencyMetric) bool {
    if (metric.samples > 80 or metric.failures > 10_000) return false;
    if (metric.median_ms) |value| if (value > 60_000) return false;
    if (metric.p95_ms) |value| if (value > 60_000) return false;
    if (metric.samples == 0 and (metric.median_ms != null or metric.p95_ms != null)) return false;
    return true;
}

fn validClientHealth(health: ClientHealth) bool {
    return validLatencyMetric(health.state) and
        validLatencyMetric(health.command) and
        validLatencyMetric(health.pointer) and
        validLatencyMetric(health.drawing);
}

const presenter_html = @embedFile("assets/presenter.html");

test "embedded Presenter Companion keeps phone and intentional laptop workflows" {
    try std.testing.expect(std.mem.indexOf(u8, presenter_html, "@media (min-width: 900px) and (min-height: 600px)") != null);
    try std.testing.expect(std.mem.indexOf(u8, presenter_html, "@media (orientation: landscape) and (max-height: 599px)") != null);
    try std.testing.expect(std.mem.indexOf(u8, presenter_html, "document.body.dataset.presenterMode = mode;") != null);
    try std.testing.expect(std.mem.indexOf(u8, presenter_html, "--landscape-surface-width: clamp(240px, calc(177.7778dvh - 258px), 440px)") != null);
    try std.testing.expect(std.mem.indexOf(u8, presenter_html, "body[data-presenter-mode=\"draw\"] .drawing-actions") != null);
    try std.testing.expect(std.mem.indexOf(u8, presenter_html, "Laptop companion · ←/→ navigate") != null);
    try std.testing.expect(std.mem.indexOf(u8, presenter_html, "grid-template-columns: minmax(0, 1.75fr)") != null);
    try std.testing.expect(std.mem.indexOf(u8, presenter_html, "document.addEventListener(\"keydown\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, presenter_html, "rayslidesPresenterDiagnostics") != null);
    try std.testing.expect(std.mem.indexOf(u8, presenter_html, "controls p95") != null);
    try std.testing.expect(std.mem.indexOf(u8, presenter_html, "/api/v1/presenter/health") != null);
    try std.testing.expect(std.mem.indexOf(u8, presenter_html, "visibilitychange") != null);
    try std.testing.expect(std.mem.indexOf(u8, presenter_html, "window.addEventListener(\"hashchange\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, presenter_html, "nextFragment !== token") != null);
    try std.testing.expect(std.mem.indexOf(u8, presenter_html, "function suspendDisconnectedControls()") != null);
    try std.testing.expect(std.mem.indexOf(u8, presenter_html, "if (failures > 2) suspendDisconnectedControls();") != null);
    try std.testing.expect(std.mem.indexOf(u8, presenter_html, "navigator.sendBeacon") != null);
    try std.testing.expect(std.mem.indexOf(u8, presenter_html, "navigator.wakeLock.request") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, presenter_html, "const pointer = mode === \"pointer\";"));
    try std.testing.expect(std.mem.indexOf(u8, presenter_html, "https://") == null);
}

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

fn respondCommand(request: *std.http.Server.Request, sequence: u64, queued: bool, accepted_at_ms: i64) !void {
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try std.json.Stringify.value(.{ .sequence = sequence, .queued = queued, .accepted_at_ms = accepted_at_ms }, .{}, &writer);
    try request.respond(writer.buffered(), .{ .keep_alive = false, .extra_headers = api_headers });
}

fn respondPointer(request: *std.http.Server.Request, sequence: u64, accepted: bool, accepted_at_ms: i64) !void {
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try std.json.Stringify.value(.{ .sequence = sequence, .accepted = accepted, .accepted_at_ms = accepted_at_ms }, .{}, &writer);
    try request.respond(writer.buffered(), .{ .keep_alive = false, .extra_headers = api_headers });
}

fn respondDrawing(request: *std.http.Server.Request, sequence: u64, queued: bool, accepted_at_ms: i64) !void {
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try std.json.Stringify.value(.{ .sequence = sequence, .queued = queued, .accepted_at_ms = accepted_at_ms }, .{}, &writer);
    try request.respond(writer.buffered(), .{ .keep_alive = false, .extra_headers = api_headers });
}

fn respondHealth(request: *std.http.Server.Request, accepted_at_ms: i64) !void {
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try std.json.Stringify.value(.{ .accepted = true, .accepted_at_ms = accepted_at_ms }, .{}, &writer);
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
        drawing_enabled: bool,
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
        .drawing_enabled = snapshot.drawing_enabled,
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
        .drawing_enabled = true,
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

    try std.testing.expect(try store.enqueueDrawing(.{ .phase = .begin, .x = 0.1, .y = 0.2, .sequence = 1 }, 300));
    try std.testing.expect(try store.enqueueDrawing(.{ .phase = .move, .x = 0.3, .y = 0.4, .sequence = 2 }, 301));
    try std.testing.expect(try store.enqueueDrawing(.{ .phase = .end, .x = 0.5, .y = 0.6, .sequence = 3 }, 302));
    try std.testing.expect(!try store.enqueueDrawing(.{ .phase = .move, .x = 0.7, .y = 0.8, .sequence = 2 }, 303));
    try std.testing.expectEqual(DrawingPhase.begin, store.takeDrawing(304).?.phase);
    try std.testing.expectEqual(DrawingPhase.move, store.takeDrawing(304).?.phase);
    try std.testing.expectEqual(DrawingPhase.end, store.takeDrawing(304).?.phase);
    try std.testing.expect(store.takeDrawing(304) == null);
    try std.testing.expectError(
        error.InvalidDrawing,
        store.enqueueDrawing(.{ .phase = .begin, .x = 1.1, .y = 0, .sequence = 4 }, 305),
    );
    try std.testing.expect(try store.enqueueDrawing(.{ .phase = .begin, .x = 0.7, .y = 0.8, .sequence = 5 }, 400));
    try std.testing.expectEqual(DrawingPhase.begin, store.takeDrawing(400).?.phase);
    try std.testing.expect(store.takeDrawing(400 + drawing_timeout_ms) == null);
    try std.testing.expectEqual(DrawingPhase.end, store.takeDrawing(400 + drawing_timeout_ms + 1).?.phase);
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

test "re-pairing after a network change invalidates the old capability" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var runtime = try Runtime.init(allocator, io);
    defer runtime.deinit();
    const port = try runtime.start(0, "192.168.1.20");
    var old_capability: [64]u8 = undefined;
    @memcpy(&old_capability, runtime.store.capability.slice());
    var old_session: [16]u8 = undefined;
    @memcpy(&old_session, runtime.store.snapshot.session_id.slice());

    try runtime.rePair("172.20.10.2");
    try std.testing.expectEqual(port, runtime.port);
    try std.testing.expectEqualStrings("http://172.20.10.2", runtime.base_url.slice()[0.."http://172.20.10.2".len]);
    try std.testing.expect(!std.mem.eql(u8, &old_capability, runtime.store.capability.slice()));
    try std.testing.expect(!std.mem.eql(u8, &old_session, runtime.store.snapshot.session_id.slice()));
    try std.testing.expect(!runtime.phoneConnected());

    const old_request = try std.fmt.allocPrint(
        allocator,
        "GET /api/v1/presenter/state?token={s} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
        .{old_capability},
    );
    defer allocator.free(old_request);
    const old_response = try rawHttp(allocator, io, port, old_request);
    defer allocator.free(old_response);
    try std.testing.expect(std.mem.indexOf(u8, old_response, "401 Unauthorized") != null);

    const new_request = try std.fmt.allocPrint(
        allocator,
        "GET /api/v1/presenter/state?token={s} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
        .{runtime.store.capability.slice()},
    );
    defer allocator.free(new_request);
    const new_response = try rawHttp(allocator, io, port, new_request);
    defer allocator.free(new_response);
    try std.testing.expect(std.mem.indexOf(u8, new_response, "200 OK") != null);

    runtime.stop();
    try std.testing.expectEqual(@as(u16, 0), runtime.store.capability.len);
}

test "stop and restart clears stale input and never revives a capability" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var runtime = try Runtime.init(allocator, io);
    defer runtime.deinit();
    const port = try runtime.start(0, "127.0.0.1");
    var old_capability: [64]u8 = undefined;
    @memcpy(&old_capability, runtime.store.capability.slice());

    runtime.mutex.lockUncancelable(io);
    try std.testing.expect(try runtime.store.enqueue(.next, 9));
    try std.testing.expect(try runtime.store.updatePointer(.{ .active = true, .x = 0.4, .y = 0.6, .sequence = 8 }, runtime.nowMs()));
    try std.testing.expect(try runtime.store.enqueueDrawing(.{ .phase = .begin, .x = 0.2, .y = 0.3, .sequence = 7 }, runtime.nowMs()));
    runtime.mutex.unlock(io);

    runtime.stop();
    try std.testing.expect(!runtime.isRunning());
    try std.testing.expect(runtime.takeCommand() == null);
    try std.testing.expect(runtime.activePointer() == null);
    try std.testing.expect(runtime.takeDrawing() == null);

    try std.testing.expectEqual(port, try runtime.start(port, "127.0.0.1"));
    try std.testing.expect(!std.mem.eql(u8, &old_capability, runtime.store.capability.slice()));
    runtime.mutex.lockUncancelable(io);
    try std.testing.expect(try runtime.store.enqueue(.previous, 1));
    runtime.mutex.unlock(io);
    try std.testing.expectEqual(Command.previous, runtime.takeCommand().?.command);

    const stale_request = try std.fmt.allocPrint(
        allocator,
        "GET /api/v1/presenter/state?token={s} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
        .{old_capability},
    );
    defer allocator.free(stale_request);
    const stale_response = try rawHttp(allocator, io, port, stale_request);
    defer allocator.free(stale_response);
    try std.testing.expect(std.mem.indexOf(u8, stale_response, "401 Unauthorized") != null);
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
        .drawing_enabled = true,
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
    const denied_drawing = try rawHttp(allocator, io, port, "POST /api/v1/presenter/drawing HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}");
    defer allocator.free(denied_drawing);
    try std.testing.expect(std.mem.indexOf(u8, denied_drawing, "401 Unauthorized") != null);

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
    try std.testing.expect(std.mem.indexOf(u8, state_response, "\"drawing_enabled\":true") != null);

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
    try std.testing.expect(std.mem.indexOf(u8, command_response, "\"accepted_at_ms\":") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, pointer_response, "\"accepted_at_ms\":") != null);
    const pointer = runtime.activePointer().?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), pointer.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), pointer.y, 0.0001);
    runtime.clearPointer();
    try std.testing.expect(runtime.activePointer() == null);

    const drawing_body = "{\"phase\":\"begin\",\"x\":0.15,\"y\":0.85,\"seq\":1}";
    const drawing_request = try std.fmt.allocPrint(
        allocator,
        "POST /api/v1/presenter/drawing?token={s} HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ runtime.store.capability.slice(), drawing_body.len, drawing_body },
    );
    defer allocator.free(drawing_request);
    const drawing_response = try rawHttp(allocator, io, port, drawing_request);
    defer allocator.free(drawing_response);
    try std.testing.expect(std.mem.indexOf(u8, drawing_response, "\"queued\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, drawing_response, "\"accepted_at_ms\":") != null);
    const drawing = runtime.takeDrawing().?;
    try std.testing.expectEqual(DrawingPhase.begin, drawing.phase);
    try std.testing.expectApproxEqAbs(@as(f32, 0.15), drawing.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.85), drawing.y, 0.0001);

    const clear_body = "{\"command\":\"clear_drawing\",\"seq\":2}";
    const clear_request = try std.fmt.allocPrint(
        allocator,
        "POST /api/v1/presenter/command?token={s} HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ runtime.store.capability.slice(), clear_body.len, clear_body },
    );
    defer allocator.free(clear_request);
    const clear_response = try rawHttp(allocator, io, port, clear_request);
    defer allocator.free(clear_response);
    try std.testing.expect(std.mem.indexOf(u8, clear_response, "\"queued\":true") != null);
    try std.testing.expectEqual(Command.clear_drawing, runtime.takeCommand().?.command);

    const health_body = "{\"state\":{\"samples\":40,\"failures\":0,\"median_ms\":18,\"p95_ms\":42},\"command\":{\"samples\":4,\"failures\":0,\"median_ms\":25,\"p95_ms\":63},\"pointer\":{\"samples\":12,\"failures\":1,\"median_ms\":31,\"p95_ms\":91},\"drawing\":{\"samples\":8,\"failures\":0,\"median_ms\":35,\"p95_ms\":97}}";
    const health_request = try std.fmt.allocPrint(
        allocator,
        "POST /api/v1/presenter/health?token={s} HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ runtime.store.capability.slice(), health_body.len, health_body },
    );
    defer allocator.free(health_request);
    const health_response = try rawHttp(allocator, io, port, health_request);
    defer allocator.free(health_response);
    try std.testing.expect(std.mem.indexOf(u8, health_response, "\"accepted\":true") != null);
    const health = runtime.clientHealth().?;
    try std.testing.expectEqual(@as(u16, 40), health.state.samples);
    try std.testing.expectEqual(@as(?u32, 97), health.drawing.p95_ms);
    try std.testing.expectEqual(@as(u16, 1), health.pointer.failures);
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
        .drawing_enabled = true,
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
    const drawing_route_on_audience = try rawHttp(allocator, io, audience_port, "POST /api/v1/presenter/drawing HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
    defer allocator.free(drawing_route_on_audience);
    try std.testing.expect(std.mem.indexOf(u8, drawing_route_on_audience, "404 Not Found") != null);

    presenter_runtime.stop();
    const audience_after_presenter_stop = try rawHttp(allocator, io, audience_port, "GET /health HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    defer allocator.free(audience_after_presenter_stop);
    try std.testing.expect(std.mem.indexOf(u8, audience_after_presenter_stop, "200 OK") != null);
}
