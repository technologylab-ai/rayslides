const std = @import("std");

pub const Effect = enum {
    none,
    appear,
    fade,
    slide_left,
    slide_right,
    slide_up,
    slide_down,
};

pub const Grouping = enum {
    item,
    line,
    bullet,
};

pub const Easing = enum {
    linear,
    smooth,
    spring,
};

pub const StepKind = enum {
    reveal,
    morph,
};

pub const ItemSpec = struct {
    effect: Effect = .fade,
    by: Grouping = .item,
    /// null means that the next presentation action starts this step.
    after: ?f32 = null,
    duration: f32 = 0.3,
};

pub const MorphSpec = struct {
    /// Optional author-facing label for Studio's state timeline. Labels are
    /// source identifiers rather than runtime targets; morph mutations still
    /// address stable item `id=` values.
    label: ?[]const u8 = null,
    /// null means that the next presentation action starts this state.
    after: ?f32 = null,
    duration: f32 = 0.6,
    easing: Easing = .smooth,
};

pub const Step = struct {
    kind: StepKind = .reveal,
    effect: Effect,
    after: ?f32,
    duration: f32,
    easing: Easing = .smooth,
    /// Zero-based target snapshot for morph steps.
    morph_state: usize = 0,

    pub fn fromItem(spec: ItemSpec) Step {
        return .{
            .kind = .reveal,
            .effect = spec.effect,
            .after = spec.after,
            .duration = spec.duration,
        };
    }

    pub fn fromMorph(spec: MorphSpec, state_index: usize) Step {
        return .{
            .kind = .morph,
            .effect = .none,
            .after = spec.after,
            .duration = spec.duration,
            .easing = spec.easing,
            .morph_state = state_index,
        };
    }
};

pub const Transition = struct {
    effect: Effect = .none,
    duration: f32 = 0.4,
};

pub fn parseEffect(value: []const u8) !Effect {
    if (std.mem.eql(u8, value, "none")) return .none;
    if (std.mem.eql(u8, value, "appear")) return .appear;
    if (std.mem.eql(u8, value, "fade")) return .fade;
    if (std.mem.eql(u8, value, "slide-left")) return .slide_left;
    if (std.mem.eql(u8, value, "slide-right")) return .slide_right;
    if (std.mem.eql(u8, value, "slide-up")) return .slide_up;
    if (std.mem.eql(u8, value, "slide-down")) return .slide_down;
    return error.InvalidAnimationEffect;
}

pub fn parseGrouping(value: []const u8) !Grouping {
    if (std.mem.eql(u8, value, "item")) return .item;
    if (std.mem.eql(u8, value, "line")) return .line;
    if (std.mem.eql(u8, value, "bullet")) return .bullet;
    return error.InvalidAnimationGrouping;
}

pub fn parseEasing(value: []const u8) !Easing {
    if (std.mem.eql(u8, value, "linear")) return .linear;
    if (std.mem.eql(u8, value, "smooth")) return .smooth;
    if (std.mem.eql(u8, value, "spring")) return .spring;
    return error.InvalidAnimationEasing;
}

pub fn clampProgress(progress: f32) f32 {
    return @max(0.0, @min(1.0, progress));
}

pub fn eased(progress: f32) f32 {
    const p = clampProgress(progress);
    return p * p * (3.0 - 2.0 * p);
}

pub fn applyEasing(easing: Easing, progress: f32) f32 {
    const p = clampProgress(progress);
    if (p == 0.0 or p == 1.0) return p;
    return switch (easing) {
        .linear => p,
        .smooth => eased(p),
        // A small, quickly damped overshoot. Geometry may travel beyond its
        // destination briefly; colors and opacity are clamped by their lerps.
        .spring => 1.0 - @exp(-6.0 * p) * @cos(10.0 * p),
    };
}

test "animation vocabulary" {
    try std.testing.expectEqual(Effect.slide_left, try parseEffect("slide-left"));
    try std.testing.expectEqual(Grouping.bullet, try parseGrouping("bullet"));
    try std.testing.expectEqual(Easing.spring, try parseEasing("spring"));
    try std.testing.expectError(error.InvalidAnimationEffect, parseEffect("sparkle"));
    try std.testing.expectError(error.InvalidAnimationEasing, parseEasing("rubber"));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), eased(0.5), 0.0001);
    try std.testing.expect(applyEasing(.spring, 0.8) > 0.9);
}
