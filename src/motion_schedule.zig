//! Deterministic preview schedule for one logical slide.
//!
//! Studio's live preview needs to answer "what does the renderer show at
//! time t?" without driving the presentation clock. This module turns the
//! renderer's flat step timeline (reveal steps, then morph steps) plus an
//! optional incoming transition into absolute time windows. Click-gated
//! steps are given a fixed preview gap so the whole slide plays through, and
//! `stateAt` is a pure function of time so scrubbing backwards is exact.
const std = @import("std");
const animation = @import("animation.zig");

pub const default_click_gap: f32 = 0.75;

pub const Window = struct {
    /// 1-based step index in the slide timeline; 0 is the incoming transition.
    step: usize,
    start: f32,
    end: f32,

    pub fn duration(self: Window) f32 {
        return @max(0, self.end - self.start);
    }
};

pub const Options = struct {
    /// Steps already visible when the preview starts (the selected scene).
    start_step: usize = 0,
    /// Seconds inserted before a step that would wait for a presentation
    /// action, so previews never stall.
    click_gap: f32 = default_click_gap,
    /// Optional incoming transition played before the first step.
    transition: ?animation.Transition = null,
};

/// Renderer-facing snapshot for one preview time.
pub const State = struct {
    visible_through: usize,
    active_step: ?usize = null,
    active_progress: f32 = 0,
    /// Null when no transition is scheduled or it has finished.
    transition_progress: ?f32 = null,
    finished: bool = false,
};

pub const Schedule = struct {
    windows: []Window,
    start_step: usize,
    total: f32,

    pub fn deinit(self: Schedule, allocator: std.mem.Allocator) void {
        allocator.free(self.windows);
    }

    pub fn stateAt(self: Schedule, time: f32) State {
        var state: State = .{ .visible_through = self.start_step };
        for (self.windows) |window| {
            if (window.step == 0) {
                if (time < window.end) {
                    state.transition_progress = if (window.duration() <= 0) 1 else animation.clampProgress((time - window.start) / window.duration());
                    return state;
                }
                continue;
            }
            if (time >= window.end) {
                state.visible_through = window.step;
                continue;
            }
            if (time >= window.start) {
                state.active_step = window.step;
                state.active_progress = if (window.duration() <= 0) 1 else animation.clampProgress((time - window.start) / window.duration());
                // The renderer treats the active step as revealed-in-progress;
                // everything before it is fully visible.
                state.visible_through = window.step;
                return state;
            }
            return state;
        }
        state.finished = time >= self.total;
        return state;
    }

    /// Window that contains `time`, or the last window before it.
    pub fn windowIndexAt(self: Schedule, time: f32) ?usize {
        var result: ?usize = null;
        for (self.windows, 0..) |window, index| {
            if (time >= window.start) result = index else break;
        }
        return result;
    }
};

fn effectiveDuration(step: animation.Step) f32 {
    if (step.kind == .morph) return @max(0, step.duration);
    if (step.effect == .none or step.effect == .appear) return 0;
    return @max(0, step.duration);
}

pub fn build(allocator: std.mem.Allocator, steps: []const animation.Step, options: Options) !Schedule {
    var windows = std.ArrayList(Window).empty;
    errdefer windows.deinit(allocator);
    var clock: f32 = 0;
    if (options.transition) |transition| {
        if (transition.effect != .none and transition.effect != .appear and transition.duration > 0) {
            try windows.append(allocator, .{ .step = 0, .start = 0, .end = transition.duration });
            clock = transition.duration;
        }
    }
    const start_step = @min(options.start_step, steps.len);
    var step_index = start_step + 1;
    while (step_index <= steps.len) : (step_index += 1) {
        const step = steps[step_index - 1];
        const delay = step.after orelse options.click_gap;
        const start = clock + @max(0, delay);
        const end = start + effectiveDuration(step);
        try windows.append(allocator, .{ .step = step_index, .start = start, .end = end });
        clock = end;
    }
    return .{
        .windows = try windows.toOwnedSlice(allocator),
        .start_step = start_step,
        .total = clock,
    };
}

test "schedule lays out click gaps delays transitions and morph steps in order" {
    const allocator = std.testing.allocator;
    const steps = [_]animation.Step{
        animation.Step.fromItemStep(.{ .effect = .fade, .delay = 0.5, .after = 0.8, .duration = 0.25 }, 0, 1),
        animation.Step.fromItemStep(.{ .effect = .fade, .delay = 0.5, .after = 0.8, .duration = 0.25 }, 1, 1),
        animation.Step.fromItemStep(.{ .effect = .appear }, 0, 2),
        animation.Step.fromMorph(.{ .duration = 1.0 }, 0),
    };
    const schedule = try build(allocator, &steps, .{ .transition = .{ .effect = .fade, .duration = 0.4 }, .click_gap = 0.5 });
    defer schedule.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 5), schedule.windows.len);
    try std.testing.expectEqual(@as(usize, 0), schedule.windows[0].step);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), schedule.windows[0].end, 0.0001);
    // Step 1: 0.4 + 0.5 delay, 0.25 long.
    try std.testing.expectApproxEqAbs(@as(f32, 0.9), schedule.windows[1].start, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.15), schedule.windows[1].end, 0.0001);
    // Step 2: after 0.8.
    try std.testing.expectApproxEqAbs(@as(f32, 1.95), schedule.windows[2].start, 0.0001);
    // Step 3 waits for a click: preview gap 0.5, instantaneous.
    try std.testing.expectApproxEqAbs(@as(f32, 2.7), schedule.windows[3].start, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 2.7), schedule.windows[3].end, 0.0001);
    // Morph: click gap then one second.
    try std.testing.expectApproxEqAbs(@as(f32, 3.2), schedule.windows[4].start, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 4.2), schedule.total, 0.0001);

    const during_transition = schedule.stateAt(0.2);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), during_transition.transition_progress.?, 0.0001);
    try std.testing.expectEqual(@as(usize, 0), during_transition.visible_through);

    const waiting = schedule.stateAt(0.6);
    try std.testing.expectEqual(@as(?f32, null), waiting.transition_progress);
    try std.testing.expectEqual(@as(?usize, null), waiting.active_step);
    try std.testing.expectEqual(@as(usize, 0), waiting.visible_through);

    const mid_first = schedule.stateAt(1.0);
    try std.testing.expectEqual(@as(?usize, 1), mid_first.active_step);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), mid_first.active_progress, 0.0001);

    const after_second = schedule.stateAt(2.5);
    try std.testing.expectEqual(@as(?usize, null), after_second.active_step);
    try std.testing.expectEqual(@as(usize, 2), after_second.visible_through);

    const mid_morph = schedule.stateAt(3.7);
    try std.testing.expectEqual(@as(?usize, 4), mid_morph.active_step);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), mid_morph.active_progress, 0.0001);

    const done = schedule.stateAt(9);
    try std.testing.expect(done.finished);
    try std.testing.expectEqual(@as(usize, 4), done.visible_through);
    try std.testing.expectEqual(@as(?usize, 4), schedule.windowIndexAt(9));
    try std.testing.expectEqual(@as(?usize, null), schedule.windowIndexAt(-1));
}

test "schedule can start from a later scene and scrubs backwards exactly" {
    const allocator = std.testing.allocator;
    const steps = [_]animation.Step{
        animation.Step.fromItemStep(.{ .effect = .fade, .duration = 0.2 }, 0, 1),
        animation.Step.fromItemStep(.{ .effect = .fade, .duration = 0.2 }, 0, 2),
        animation.Step.fromMorph(.{ .after = 0.1, .duration = 0.5 }, 0),
    };
    const schedule = try build(allocator, &steps, .{ .start_step = 2, .click_gap = 0.25 });
    defer schedule.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), schedule.windows.len);
    try std.testing.expectEqual(@as(usize, 3), schedule.windows[0].step);
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), schedule.windows[0].start, 0.0001);
    try std.testing.expectEqual(@as(usize, 2), schedule.stateAt(0).visible_through);
    const forward = schedule.stateAt(0.35);
    const back = schedule.stateAt(0.35);
    try std.testing.expectEqual(forward.active_step, back.active_step);
    try std.testing.expectApproxEqAbs(forward.active_progress, back.active_progress, 0.0001);
    try std.testing.expectEqual(@as(usize, 2), schedule.stateAt(0.05).visible_through);

    const empty = try build(allocator, &.{}, .{});
    defer empty.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), empty.windows.len);
    try std.testing.expect(empty.stateAt(0).finished);
}
