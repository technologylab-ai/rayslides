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

pub const ItemSpec = struct {
    effect: Effect = .fade,
    by: Grouping = .item,
    /// null means that the next presentation action starts this step.
    after: ?f32 = null,
    duration: f32 = 0.3,
};

pub const Step = struct {
    effect: Effect,
    after: ?f32,
    duration: f32,

    pub fn fromItem(spec: ItemSpec) Step {
        return .{
            .effect = spec.effect,
            .after = spec.after,
            .duration = spec.duration,
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

pub fn clampProgress(progress: f32) f32 {
    return @max(0.0, @min(1.0, progress));
}

pub fn eased(progress: f32) f32 {
    const p = clampProgress(progress);
    return p * p * (3.0 - 2.0 * p);
}

test "animation vocabulary" {
    try std.testing.expectEqual(Effect.slide_left, try parseEffect("slide-left"));
    try std.testing.expectEqual(Grouping.bullet, try parseGrouping("bullet"));
    try std.testing.expectError(error.InvalidAnimationEffect, parseEffect("sparkle"));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), eased(0.5), 0.0001);
}
