const animation = @import("animation.zig");

pub const State = struct {
    visible_step: usize = 0,
    active_step: ?usize = null,
    active_started_at: f64 = 0,
    active_duration: f32 = 0,
    active_reverse: bool = false,
    stable_since: f64 = 0,
    auto_paused: bool = false,

    previous_slide: ?i32 = null,
    previous_step: usize = 0,
    transition: animation.Transition = .{},
    transition_started_at: f64 = 0,
    direction: i8 = 1,

    pub fn reset(self: *State, now: f64) void {
        self.* = .{ .stable_since = now };
    }

    pub fn enterSlide(
        self: *State,
        previous_slide: ?i32,
        previous_step: usize,
        initial_step: usize,
        transition: animation.Transition,
        direction: i8,
        now: f64,
    ) void {
        self.visible_step = initial_step;
        self.active_step = null;
        self.active_started_at = now;
        self.active_duration = 0;
        self.active_reverse = false;
        self.auto_paused = false;
        self.previous_slide = if (transition.effect == .none or transition.effect == .appear) null else previous_slide;
        self.previous_step = previous_step;
        self.transition = transition;
        self.transition_started_at = now;
        self.direction = direction;
        self.stable_since = now + if (transition.effect == .none or transition.effect == .appear) 0 else transition.duration;
    }

    pub fn settle(self: *State, now: f64) void {
        if (self.active_step != null and self.elementProgress(now) >= 1.0) {
            self.active_step = null;
            self.active_reverse = false;
            self.stable_since = self.active_started_at + self.active_duration;
        }
        if (self.previous_slide != null and self.transitionProgress(now) >= 1.0) {
            self.previous_slide = null;
        }
    }

    pub fn reveal(self: *State, step_index: usize, step: animation.Step, now: f64) void {
        self.visible_step = step_index;
        self.active_step = step_index;
        self.active_started_at = now;
        self.active_duration = effectiveDuration(step);
        self.active_reverse = false;
        self.auto_paused = false;
    }

    pub fn hide(self: *State, step_index: usize, step: animation.Step, now: f64) void {
        self.visible_step = step_index - 1;
        self.active_step = step_index;
        self.active_started_at = now;
        self.active_duration = effectiveDuration(step);
        self.active_reverse = true;
        self.auto_paused = true;
    }

    pub fn shouldAutoReveal(self: *const State, step: animation.Step, now: f64) bool {
        const delay = step.after orelse return false;
        return !self.auto_paused and self.active_step == null and now >= self.stable_since + delay;
    }

    pub fn activeStepProgress(self: *const State, now: f64) f32 {
        const progress = self.elementProgress(now);
        return if (self.active_reverse) 1.0 - progress else progress;
    }

    pub fn transitionProgress(self: *const State, now: f64) f32 {
        if (self.transition.effect == .none or self.transition.effect == .appear or self.transition.duration <= 0) return 1.0;
        return animation.clampProgress(@floatCast((now - self.transition_started_at) / self.transition.duration));
    }

    fn elementProgress(self: *const State, now: f64) f32 {
        if (self.active_duration <= 0) return 1.0;
        return animation.clampProgress(@floatCast((now - self.active_started_at) / self.active_duration));
    }

    fn effectiveDuration(step: animation.Step) f32 {
        if (step.effect == .none or step.effect == .appear) return 0;
        return step.duration;
    }
};

test "click and timed reveal playback" {
    const std = @import("std");
    var state = State{};
    state.reset(0);

    const clicked = animation.Step{ .effect = .fade, .after = null, .duration = 0.25 };
    state.reveal(1, clicked, 1.0);
    try std.testing.expectEqual(@as(usize, 1), state.visible_step);
    try std.testing.expect(state.activeStepProgress(1.125) > 0.4);
    state.settle(1.3);
    try std.testing.expectEqual(@as(?usize, null), state.active_step);

    const timed = animation.Step{ .effect = .fade, .after = 0.5, .duration = 0.2 };
    try std.testing.expect(!state.shouldAutoReveal(timed, 1.7));
    try std.testing.expect(state.shouldAutoReveal(timed, 1.8));

    state.hide(1, clicked, 2.0);
    try std.testing.expectEqual(@as(usize, 0), state.visible_step);
    try std.testing.expect(!state.shouldAutoReveal(timed, 3.0));
}
