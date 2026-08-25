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
    /// Optional first-step delay. When set, the first step of this item's
    /// build starts automatically `delay` seconds after the slide (or the
    /// previous step) settles; later steps keep using `after`. When null,
    /// the first step uses `after` exactly like every other step.
    delay: ?f32 = null,
    /// `delay=click`: the first step waits for a presentation action even
    /// when later steps run automatically through `after`.
    first_waits: bool = false,
    duration: f32 = 0.3,
    easing: Easing = .smooth,
    /// Reveal order key. Steps sort by `(order, source position)`, so the
    /// default of 0 keeps reveal order equal to paint order.
    order: i32 = 0,

    /// Effective automatic delay of the step at `step_index` within this
    /// item's build (0 = first step).
    pub fn afterForStep(self: ItemSpec, step_index: usize) ?f32 {
        if (step_index == 0) return if (self.first_waits) null else self.delay orelse self.after;
        return self.after;
    }
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
    /// Stable `SlideItem.identity` of the item that owns a reveal step;
    /// 0 for morph steps. Studio groups contiguous steps by owner.
    owner_identity: usize = 0,
    /// Reveal order key copied from the owning spec (reveal steps only).
    order: i32 = 0,

    pub fn fromItem(spec: ItemSpec) Step {
        return fromItemStep(spec, 0, 0);
    }

    /// Build the reveal step at `step_index` (0 = first) of one item's
    /// build. Only the first step honors the optional `delay`.
    pub fn fromItemStep(spec: ItemSpec, step_index: usize, owner_identity: usize) Step {
        return .{
            .kind = .reveal,
            .effect = spec.effect,
            .after = spec.afterForStep(step_index),
            .duration = spec.duration,
            .easing = spec.easing,
            .owner_identity = owner_identity,
            .order = spec.order,
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
    easing: Easing = .smooth,
};

pub fn effectLiteral(effect: Effect) []const u8 {
    return switch (effect) {
        .none => "none",
        .appear => "appear",
        .fade => "fade",
        .slide_left => "slide-left",
        .slide_right => "slide-right",
        .slide_up => "slide-up",
        .slide_down => "slide-down",
    };
}

pub fn groupingLiteral(grouping: Grouping) []const u8 {
    return switch (grouping) {
        .item => "item",
        .line => "line",
        .bullet => "bullet",
    };
}

pub fn easingLiteral(easing: Easing) []const u8 {
    return switch (easing) {
        .linear => "linear",
        .smooth => "smooth",
        .spring => "spring",
    };
}

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
    try std.testing.expectEqualStrings("slide-left", effectLiteral(.slide_left));
    try std.testing.expectEqualStrings("bullet", groupingLiteral(.bullet));
    try std.testing.expectEqualStrings("spring", easingLiteral(.spring));
}

test "first-step delay applies only to the first reveal step" {
    const both = ItemSpec{ .delay = 0.5, .after = 0.8 };
    try std.testing.expectEqual(@as(?f32, 0.5), both.afterForStep(0));
    try std.testing.expectEqual(@as(?f32, 0.8), both.afterForStep(1));
    try std.testing.expectEqual(@as(?f32, 0.8), both.afterForStep(7));

    const delay_only = ItemSpec{ .delay = 0.5 };
    try std.testing.expectEqual(@as(?f32, 0.5), delay_only.afterForStep(0));
    try std.testing.expectEqual(@as(?f32, null), delay_only.afterForStep(1));

    const after_only = ItemSpec{ .after = 0.8 };
    try std.testing.expectEqual(@as(?f32, 0.8), after_only.afterForStep(0));

    const click_then_auto = ItemSpec{ .first_waits = true, .after = 0.8 };
    try std.testing.expectEqual(@as(?f32, null), click_then_auto.afterForStep(0));
    try std.testing.expectEqual(@as(?f32, 0.8), click_then_auto.afterForStep(1));

    const step = Step.fromItemStep(.{ .effect = .slide_up, .easing = .spring, .delay = 1 }, 0, 42);
    try std.testing.expectEqual(Easing.spring, step.easing);
    try std.testing.expectEqual(@as(usize, 42), step.owner_identity);
    try std.testing.expectEqual(@as(?f32, 1), step.after);
    try std.testing.expectEqual(@as(?f32, null), Step.fromItemStep(.{ .delay = 1 }, 1, 42).after);
}
