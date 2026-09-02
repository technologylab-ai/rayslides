const std = @import("std");
const builtin = @import("builtin");
const session = @import("session.zig");

const wait_iterations = 500;
const wait_interval = std.Io.Duration.fromMilliseconds(10);

pub const Result = struct {
    ready: bool = false,
    rendered: bool = false,
    initial_cursor_line: bool = false,
    write_round_trip: bool = false,
    quit_closed_overlay: bool = false,
    rejected_wq_stayed_open: bool = false,
    dirty_q_stayed_open: bool = false,
    forced_quit_closed_overlay: bool = false,
    wq_applied_and_closed: bool = false,
    x_applied_and_closed: bool = false,
    zz_applied_and_closed: bool = false,
    zq_discarded_and_closed: bool = false,
    clean_qa_closed: bool = false,
    dirty_qa_stayed_open: bool = false,
    forced_qa_closed: bool = false,
    buffer_close_closed_overlay: bool = false,
    child_failure_closed_overlay: bool = false,
    repeated_writes_then_discard: bool = false,
    exact_source_round_trip: bool = false,
    focus_round_trip: bool = false,
    field_buffer_round_trip: bool = false,
    host_shutdown_reaped: bool = false,
};

pub fn run(io: std.Io, allocator: std.mem.Allocator, executable: []const u8) !Result {
    var result: Result = .{};
    try runBasicProbe(io, allocator, executable, &result);
    try runRejectedWriteProbe(io, allocator, executable, &result);
    result.wq_applied_and_closed = try runApplyAndCloseProbe(io, allocator, executable, .wq, 101);
    result.x_applied_and_closed = try runApplyAndCloseProbe(io, allocator, executable, .xit, 102);
    result.zz_applied_and_closed = try runApplyAndCloseProbe(io, allocator, executable, .zz, 103);
    result.zq_discarded_and_closed = try runDiscardAndCloseProbe(io, allocator, executable);
    try runQuitAllProbe(io, allocator, executable, &result);
    result.buffer_close_closed_overlay = try runBufferCloseProbe(io, allocator, executable);
    result.child_failure_closed_overlay = try runChildFailureProbe(io, allocator, executable);
    result.repeated_writes_then_discard = try runRepeatedWriteProbe(io, allocator, executable);
    result.exact_source_round_trip = try runExactSourceProbe(io, allocator, executable);
    result.focus_round_trip = try runFocusProbe(io, allocator, executable);
    result.field_buffer_round_trip = try runFieldBufferProbe(io, allocator, executable);
    result.host_shutdown_reaped = try runHostShutdownProbe(io, allocator, executable);
    return result;
}

fn runBasicProbe(
    io: std.Io,
    allocator: std.mem.Allocator,
    executable: []const u8,
    result: *Result,
) !void {
    const embedded = try openProbeAtLine(io, allocator, executable, "@slide\n@text hello\n", 73, 52, 14, 2);
    defer embedded.deinit();
    result.ready = true;

    var snapshot_revision: u64 = 0;
    for (0..wait_iterations) |_| {
        if (try embedded.snapshot(allocator, snapshot_revision)) |snapshot_value| {
            var snapshot = snapshot_value;
            snapshot_revision = snapshot.flush_revision;
            result.rendered = snapshot.width == 52 and snapshot.height == 14;
            result.initial_cursor_line = snapshot.cursor_row == 1;
            snapshot.deinit();
            if (result.rendered and result.initial_cursor_line) break;
        }
        try io.sleep(wait_interval, .awake);
    }
    if (!result.rendered) return error.SessionDidNotRender;
    if (!result.initial_cursor_line) return error.SessionDidNotPositionCursor;

    try embedded.input("Go@text changed<Esc>");
    try embedded.command("write");
    try expectApply(io, embedded, 73, "@slide\n@text hello\n@text changed\n", 74);
    result.write_round_trip = true;

    // The response wakes Neovim's nested rpcrequest loop. Let BufWriteCmd
    // clear 'modified' before issuing a distinct clean :q.
    try io.sleep(.fromMilliseconds(50), .awake);
    try embedded.command("quit");
    try waitForClose(io, embedded);
    result.quit_closed_overlay = true;
}

fn openProbe(
    io: std.Io,
    allocator: std.mem.Allocator,
    executable: []const u8,
    source: []const u8,
    revision: usize,
    width: usize,
    height: usize,
) !*session.Session {
    return openProbeAtLine(io, allocator, executable, source, revision, width, height, 1);
}

fn openProbeAtLine(
    io: std.Io,
    allocator: std.mem.Allocator,
    executable: []const u8,
    source: []const u8,
    revision: usize,
    width: usize,
    height: usize,
    initial_line: usize,
) !*session.Session {
    const embedded = try session.Session.start(io, allocator, executable, true, width, height, revision);
    errdefer embedded.deinit();
    try waitForState(io, embedded, .ready);
    if (!try embedded.openBufferAtLine(source, "src/nvim/runtime", .source, initial_line))
        return error.SessionDidNotOpenBuffer;
    try io.sleep(.fromMilliseconds(50), .awake);
    return embedded;
}

fn waitForState(io: std.Io, embedded: *session.Session, wanted: session.State) !void {
    for (0..wait_iterations) |_| {
        const current = embedded.state();
        if (current == wanted) return;
        if (current == .failed or current == .closed) return error.SessionClosedBeforeReady;
        try io.sleep(wait_interval, .awake);
    }
    return error.SessionReadyTimedOut;
}

fn waitForClose(io: std.Io, embedded: *session.Session) !void {
    for (0..wait_iterations) |_| {
        if (embedded.shouldClose()) return;
        try io.sleep(wait_interval, .awake);
    }
    var stderr_buffer: [4096]u8 = undefined;
    const stderr_tail = embedded.copyStderrTail(&stderr_buffer);
    std.debug.print("session close timeout: state={s} failure={s} stderr={s}\n", .{
        @tagName(embedded.state()),
        @tagName(embedded.failure()),
        stderr_tail,
    });
    return error.SessionCloseTimedOut;
}

fn expectApply(
    io: std.Io,
    embedded: *session.Session,
    expected_revision: usize,
    expected_source: []const u8,
    accepted_revision: usize,
) !void {
    for (0..wait_iterations) |_| {
        if (embedded.takeApply()) |apply| {
            if (apply.opening_revision != expected_revision or
                !std.mem.eql(u8, apply.source, expected_source))
            {
                try embedded.rejectApply("unexpected session probe source");
                return error.UnexpectedApplySource;
            }
            embedded.acceptApply(accepted_revision);
            return;
        }
        try io.sleep(wait_interval, .awake);
    }
    return error.SessionWriteTimedOut;
}

fn expectNoApply(io: std.Io, embedded: *session.Session) !void {
    for (0..20) |_| {
        if (embedded.takeApply()) |_| {
            try embedded.rejectApply("unexpected apply during discard probe");
            return error.UnexpectedApplySource;
        }
        try io.sleep(wait_interval, .awake);
    }
}

fn runRejectedWriteProbe(
    io: std.Io,
    allocator: std.mem.Allocator,
    executable: []const u8,
    result: *Result,
) !void {
    const embedded = try openProbe(io, allocator, executable, "@slide\n", 91, 44, 10);
    defer embedded.deinit();
    try embedded.input("Go@definitely-invalid-probe<Esc>");
    try embedded.command("wq");

    for (0..wait_iterations) |_| {
        if (embedded.takeApply()) |_| {
            try embedded.rejectApply("line 2: intentional validation failure");
            break;
        }
        try io.sleep(wait_interval, .awake);
    } else return error.SessionWriteTimedOut;
    try io.sleep(.fromMilliseconds(100), .awake);
    result.rejected_wq_stayed_open = !embedded.shouldClose();
    if (!result.rejected_wq_stayed_open) return error.RejectedWriteClosedOverlay;

    try embedded.command("quit");
    try io.sleep(.fromMilliseconds(100), .awake);
    result.dirty_q_stayed_open = !embedded.shouldClose();
    if (!result.dirty_q_stayed_open) return error.DirtyQuitClosedOverlay;

    try embedded.command("quit!");
    try waitForClose(io, embedded);
    result.forced_quit_closed_overlay = true;
}

const ApplyCloseCommand = enum { wq, xit, zz };

fn runApplyAndCloseProbe(
    io: std.Io,
    allocator: std.mem.Allocator,
    executable: []const u8,
    kind: ApplyCloseCommand,
    revision: usize,
) !bool {
    const embedded = try openProbe(io, allocator, executable, "@slide\n", revision, 40, 9);
    defer embedded.deinit();
    try embedded.input("Go@text applied<Esc>");
    switch (kind) {
        .wq => try embedded.command("wq"),
        .xit => try embedded.command("xit"),
        .zz => try embedded.input("ZZ"),
    }
    try expectApply(io, embedded, revision, "@slide\n@text applied\n", revision + 1);
    try waitForClose(io, embedded);
    return true;
}

fn runDiscardAndCloseProbe(io: std.Io, allocator: std.mem.Allocator, executable: []const u8) !bool {
    const embedded = try openProbe(io, allocator, executable, "@slide\n", 110, 40, 9);
    defer embedded.deinit();
    try embedded.input("Go@text discarded<Esc>ZQ");
    try waitForClose(io, embedded);
    try expectNoApply(io, embedded);
    return true;
}

fn runQuitAllProbe(
    io: std.Io,
    allocator: std.mem.Allocator,
    executable: []const u8,
    result: *Result,
) !void {
    {
        const embedded = try openProbe(io, allocator, executable, "@slide\n", 120, 40, 9);
        defer embedded.deinit();
        try embedded.command("qa");
        try waitForClose(io, embedded);
        result.clean_qa_closed = true;
    }
    {
        const embedded = try openProbe(io, allocator, executable, "@slide\n", 121, 40, 9);
        defer embedded.deinit();
        try embedded.input("Go@text dirty<Esc>");
        try embedded.command("qa");
        try io.sleep(.fromMilliseconds(100), .awake);
        result.dirty_qa_stayed_open = !embedded.shouldClose();
        if (!result.dirty_qa_stayed_open) return error.DirtyQuitAllClosedOverlay;
        try embedded.command("qa!");
        try waitForClose(io, embedded);
        try expectNoApply(io, embedded);
        result.forced_qa_closed = true;
    }
}

fn runBufferCloseProbe(io: std.Io, allocator: std.mem.Allocator, executable: []const u8) !bool {
    const embedded = try openProbe(io, allocator, executable, "@slide\n", 130, 40, 9);
    defer embedded.deinit();
    try embedded.command("enew");
    try waitForClose(io, embedded);
    return true;
}

fn runChildFailureProbe(io: std.Io, allocator: std.mem.Allocator, executable: []const u8) !bool {
    const embedded = try openProbe(io, allocator, executable, "@slide\n", 140, 40, 9);
    defer embedded.deinit();
    try embedded.command("lua vim.uv.kill(vim.fn.getpid(), 9)");
    try waitForClose(io, embedded);
    return embedded.state() == .closed or embedded.state() == .failed;
}

fn runRepeatedWriteProbe(io: std.Io, allocator: std.mem.Allocator, executable: []const u8) !bool {
    const embedded = try openProbe(io, allocator, executable, "@slide\n", 150, 40, 9);
    defer embedded.deinit();

    try embedded.input("Go@text one<Esc>");
    try embedded.command("write");
    try expectApply(io, embedded, 150, "@slide\n@text one\n", 151);
    try io.sleep(.fromMilliseconds(50), .awake);

    try embedded.input("Go@text two<Esc>");
    try embedded.command("write");
    try expectApply(io, embedded, 151, "@slide\n@text one\n@text two\n", 152);
    try io.sleep(.fromMilliseconds(50), .awake);

    try embedded.input("Go@text discarded<Esc>ZQ");
    try waitForClose(io, embedded);
    try expectNoApply(io, embedded);
    return true;
}

fn runExactSourceProbe(io: std.Io, allocator: std.mem.Allocator, executable: []const u8) !bool {
    const exact = "\xef\xbb\xbf@slide\r\n@text exact";
    const embedded = try openProbe(io, allocator, executable, exact, 160, 40, 9);
    defer embedded.deinit();
    try embedded.command("write");
    try expectApply(io, embedded, 160, exact, 161);
    try io.sleep(.fromMilliseconds(50), .awake);
    try embedded.command("quit");
    try waitForClose(io, embedded);
    return true;
}

fn runFocusProbe(io: std.Io, allocator: std.mem.Allocator, executable: []const u8) !bool {
    const embedded = try openProbe(io, allocator, executable, "@slide\n", 170, 40, 9);
    defer embedded.deinit();
    try embedded.focus(false);
    try io.sleep(.fromMilliseconds(30), .awake);
    try embedded.focus(true);
    try io.sleep(.fromMilliseconds(30), .awake);
    if (embedded.shouldClose()) return error.FocusTransitionClosedOverlay;
    try embedded.command("quit");
    try waitForClose(io, embedded);
    return true;
}

fn runFieldBufferProbe(io: std.Io, allocator: std.mem.Allocator, executable: []const u8) !bool {
    const embedded = try session.Session.start(io, allocator, executable, true, 40, 9, 175);
    defer embedded.deinit();
    try waitForState(io, embedded, .ready);
    if (!try embedded.openBuffer("First line", "src/nvim/runtime", .speaker_notes))
        return error.SessionDidNotOpenBuffer;
    try io.sleep(.fromMilliseconds(50), .awake);
    try embedded.input("GoSecond line<Esc>");
    try embedded.command("write");
    try expectApply(io, embedded, 175, "First line\nSecond line", 176);
    try io.sleep(.fromMilliseconds(50), .awake);
    try embedded.command("quit");
    try waitForClose(io, embedded);
    return true;
}

fn runHostShutdownProbe(io: std.Io, allocator: std.mem.Allocator, executable: []const u8) !bool {
    const embedded = try openProbe(io, allocator, executable, "@slide\n", 180, 40, 9);
    const process_id = embedded.processId() orelse return error.SessionProcessIdMissing;
    embedded.deinit();
    return switch (builtin.os.tag) {
        .linux, .macos => !try processExists(process_id),
        else => true,
    };
}

fn processExists(process_id: std.process.Child.Id) !bool {
    std.posix.kill(process_id, @enumFromInt(0)) catch |err| switch (err) {
        error.ProcessNotFound => return false,
        error.PermissionDenied => return true,
        else => return err,
    };
    return true;
}
