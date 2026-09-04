//! Studio chrome motion.
//!
//! Everything here is *decoration in time*: hover glows, press ripples, the
//! comet that runs around a hovered button, and the fold/slide reveals that
//! floating instruments (command palette, reusable picker, go-to-slide, the
//! embedded Neovim pane) play when they open and close. None of it changes
//! what the chrome means; the theme still spends its single accent on
//! "selected, active, or focused" and the motion only *approaches* it.
//!
//! Design constraints:
//!
//! * Studio draws with `self: Studio` by value, so per-widget timing cannot
//!   live on the Studio struct. It lives in this module's registry instead,
//!   keyed by the widget's screen rectangle. Buttons are re-drawn every frame,
//!   so "touch this rect" during draw is enough to keep an entry alive.
//! * Studio's update does not run while a modal owns the frame. Timing is
//!   therefore advanced once per frame from `beginFrame`, called by the main
//!   loop before anything draws, independent of which layer owns input.
//! * Every reveal settles in well under the diagnostics settle window, and
//!   ambient motion (the comet) only runs under a live pointer, so headless
//!   baseline captures stay pixel-deterministic. Captures also set
//!   `enabled = false`, which snaps every reveal to its target.
//! * Pure timing/geometry is separated from drawing so it can be unit tested
//!   with an explicit clock.

const std = @import("std");
const rl = @import("raylib");
const theme = @import("studio_theme.zig");

/// Master switch. Off snaps reveals to their targets and silences glows.
pub var enabled: bool = true;
/// Stretch every timer by this factor. `RAYSLIDES_MOTION_SLOW=8` makes a
/// 180 ms fold take 1.4 s so it can be reviewed frame by frame.
pub var time_scale: f32 = 1;

// ---------------------------------------------------------------------------
// Timing constants
// ---------------------------------------------------------------------------

pub const hover_rise_seconds: f32 = 0.11;
pub const hover_fall_seconds: f32 = 0.22;
pub const active_blend_seconds: f32 = 0.16;
pub const press_decay_seconds: f32 = 0.34;
/// One lap of the comet around a button perimeter, in perimeter lengths per
/// second. Small buttons therefore lap faster, which reads as "busy".
pub const comet_pixels_per_second: f32 = 240;
pub const comet_min_lap_seconds: f32 = 1.2;

/// Largest frame step the registry will integrate. A stall (window drag,
/// deck reparse) must not fling every animation to its end state at once.
pub const max_frame_step: f32 = 0.1;

// ---------------------------------------------------------------------------
// Easing
// ---------------------------------------------------------------------------

pub fn clamp01(value: f32) f32 {
    return std.math.clamp(value, 0, 1);
}

/// Cubic ease-out: fast start, gentle landing. The default for anything that
/// enters the screen.
pub fn easeOut(progress: f32) f32 {
    const p = clamp01(progress);
    const inv = 1 - p;
    return 1 - inv * inv * inv;
}

/// Cubic ease-in: things leaving the screen accelerate away.
pub fn easeIn(progress: f32) f32 {
    const p = clamp01(progress);
    return p * p * p;
}

/// Smoothstep for symmetric blends (hover in/out, active crossfades).
pub fn smooth(progress: f32) f32 {
    const p = clamp01(progress);
    return p * p * (3 - 2 * p);
}

pub fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * clamp01(t);
}

pub fn mixColor(a: rl.Color, b: rl.Color, t: f32) rl.Color {
    const k = clamp01(t);
    return .{
        .r = @intFromFloat(@round(lerp(@floatFromInt(a.r), @floatFromInt(b.r), k))),
        .g = @intFromFloat(@round(lerp(@floatFromInt(a.g), @floatFromInt(b.g), k))),
        .b = @intFromFloat(@round(lerp(@floatFromInt(a.b), @floatFromInt(b.b), k))),
        .a = @intFromFloat(@round(lerp(@floatFromInt(a.a), @floatFromInt(b.a), k))),
    };
}

fn scaledAlpha(color: rl.Color, factor: f32) rl.Color {
    const a: f32 = @floatFromInt(color.a);
    return theme.alpha(color, @intFromFloat(@round(clamp01(factor) * a)));
}

// ---------------------------------------------------------------------------
// Reveals: open/close progress for floating instruments
// ---------------------------------------------------------------------------

pub const RevealKind = enum(u8) {
    command_palette,
    reusable_picker,
    grid_settings,
    goto_slide,
    neovim,
    toast,
    prompt,
    file_browser,
    /// Inspector body wipe when the Objects / Properties / Motion tab changes.
    inspector_body,
};

pub const Reveal = struct {
    /// 0 = fully stowed, 1 = fully present. Linear in time; readers ease it.
    progress: f32 = 0,
    open: bool = false,
    open_seconds: f32 = 0.18,
    close_seconds: f32 = 0.14,

    pub fn setOpen(self: *Reveal, open: bool) void {
        self.open = open;
        if (!enabled) self.progress = if (open) 1 else 0;
    }

    pub fn snap(self: *Reveal, open: bool) void {
        self.open = open;
        self.progress = if (open) 1 else 0;
    }

    pub fn advance(self: *Reveal, dt: f32) void {
        if (!enabled) {
            self.progress = if (self.open) 1 else 0;
            return;
        }
        const target: f32 = if (self.open) 1 else 0;
        if (self.progress == target) return;
        const seconds = if (self.open) self.open_seconds else self.close_seconds;
        const step = if (seconds <= 0) 1 else @max(0, dt) / seconds;
        self.progress = if (self.progress < target)
            @min(target, self.progress + step)
        else
            @max(target, self.progress - step);
    }

    /// Anything to draw at all?
    pub fn visible(self: Reveal) bool {
        return self.open or self.progress > 0.0005;
    }

    /// Still moving?
    pub fn animating(self: Reveal) bool {
        return self.progress != (if (self.open) @as(f32, 1) else @as(f32, 0));
    }

    /// Fully open and settled.
    pub fn settled(self: Reveal) bool {
        return self.open and self.progress >= 1;
    }

    /// Eased presence: ease-out while entering, ease-in while leaving, so an
    /// instrument arrives softly and departs briskly.
    pub fn presence(self: Reveal) f32 {
        if (self.open) return easeOut(self.progress);
        return 1 - easeIn(1 - self.progress);
    }
};

const reveal_count = @typeInfo(RevealKind).@"enum".fields.len;

var reveals: [reveal_count]Reveal = defaultReveals();

fn defaultReveals() [reveal_count]Reveal {
    var result: [reveal_count]Reveal = undefined;
    for (&result, 0..) |*entry, index| {
        entry.* = .{};
        switch (@as(RevealKind, @enumFromInt(index))) {
            .neovim => {
                entry.open_seconds = 0.24;
                entry.close_seconds = 0.18;
            },
            .toast => {
                entry.open_seconds = 0.16;
                entry.close_seconds = 0.12;
            },
            .prompt, .file_browser => {
                entry.open_seconds = 0.16;
                entry.close_seconds = 0.12;
            },
            .inspector_body => {
                entry.open_seconds = 0.15;
                entry.close_seconds = 0.01;
                entry.open = true;
                entry.progress = 1;
            },
            else => {},
        }
    }
    return result;
}

pub fn reveal(kind: RevealKind) *Reveal {
    return &reveals[@intFromEnum(kind)];
}

// ---------------------------------------------------------------------------
// Frame clock and pointer
// ---------------------------------------------------------------------------

var last_frame_time: ?f64 = null;
var frame_now: f64 = 0;
var frame_dt: f32 = 0;
/// Pointer available to chrome this frame; null while another surface (a
/// modal, the embedded editor, an unfocused window) owns it.
var frame_pointer: ?rl.Vector2 = null;
var frame_pressed: bool = false;
/// Set while a Studio overlay (palette, picker, grid popover) floats above the
/// docks: chrome underneath must not react to the pointer, but the overlay's
/// own controls may.
var overlay_shading_chrome: bool = false;
var drawing_overlay_layer: bool = false;

pub const FrameInput = struct {
    now: f64,
    pointer: ?rl.Vector2,
    pressed: bool = false,
};

/// Advance every timer once per frame. Call before drawing anything.
pub fn beginFrame(input: FrameInput) void {
    frame_now = input.now;
    frame_dt = if (last_frame_time) |previous|
        std.math.clamp(@as(f32, @floatCast(input.now - previous)), 0, max_frame_step) / @max(0.01, time_scale)
    else
        0;
    last_frame_time = input.now;
    frame_pointer = if (enabled) input.pointer else null;
    frame_pressed = input.pressed and frame_pointer != null;
    for (&reveals) |*entry| entry.advance(frame_dt);
    expireGlows();
}

pub fn beginFrameFromRaylib(pointer_available: bool) void {
    beginFrame(.{
        .now = rl.getTime(),
        .pointer = if (pointer_available and rl.isWindowFocused()) rl.getMousePosition() else null,
        .pressed = rl.isMouseButtonPressed(.left),
    });
}

pub fn frameDelta() f32 {
    return frame_dt;
}

pub fn now() f64 {
    return frame_now;
}

/// Studio tells the registry whether a floating overlay currently shades the
/// docks. Chrome drawn afterwards ignores the pointer until
/// `setOverlayLayer(true)` marks the overlay's own drawing.
pub fn setOverlayShadingChrome(active: bool) void {
    overlay_shading_chrome = active;
    drawing_overlay_layer = false;
}

pub fn setOverlayLayer(active: bool) void {
    drawing_overlay_layer = active;
}

fn pointerForLayer() ?rl.Vector2 {
    if (overlay_shading_chrome and !drawing_overlay_layer) return null;
    return frame_pointer;
}

/// Raw pointer for surfaces that manage their own layering (modals drawn by
/// the main loop).
pub fn pointer() ?rl.Vector2 {
    return frame_pointer;
}

pub fn pointerPressed() bool {
    return frame_pressed;
}

fn pointIn(point: rl.Vector2, rect: rl.Rectangle) bool {
    return rect.width > 0 and rect.height > 0 and
        point.x >= rect.x and point.y >= rect.y and
        point.x <= rect.x + rect.width and point.y <= rect.y + rect.height;
}

// ---------------------------------------------------------------------------
// Glow registry: per-rectangle hover / press / active state
// ---------------------------------------------------------------------------

pub const Glow = struct {
    /// Smoothed hover intensity 0..1.
    hover: f32 = 0,
    /// Press flash 1 → 0 after a click.
    press: f32 = 0,
    /// Smoothed "is active" blend 0..1 so toggles crossfade.
    active: f32 = 0,
    /// Comet position along the perimeter, in pixels from the top-left corner.
    comet: f32 = 0,
    /// Raw hover this frame.
    hovered: bool = false,
};

const GlowEntry = struct {
    key: u64 = 0,
    rect: rl.Rectangle = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    hover: f32 = 0,
    press: f32 = 0,
    active: f32 = 0,
    comet: f32 = 0,
    last_seen: f64 = -1,
    /// Frame stamp of the last touch, so one rect touched twice in a frame
    /// (label + surface) integrates once.
    last_frame: f64 = -1,
};

/// Enough for every visible chrome control plus overlay rows. Entries that
/// stop being drawn are recycled after `glow_expiry_seconds`.
const glow_capacity = 256;
const glow_expiry_seconds: f64 = 0.6;

var glows: [glow_capacity]GlowEntry = @splat(.{});

fn rectKey(rect: rl.Rectangle) u64 {
    // Quantise to whole pixels: layouts jitter by sub-pixel amounts between
    // frames when the window resizes, and that must not reset a glow.
    const x: i32 = @intFromFloat(@round(rect.x));
    const y: i32 = @intFromFloat(@round(rect.y));
    const w: i32 = @intFromFloat(@round(rect.width));
    const h: i32 = @intFromFloat(@round(rect.height));
    var hasher = std.hash.Wyhash.init(0x5a1de5);
    hasher.update(std.mem.asBytes(&x));
    hasher.update(std.mem.asBytes(&y));
    hasher.update(std.mem.asBytes(&w));
    hasher.update(std.mem.asBytes(&h));
    return hasher.final() | 1; // never 0, which marks a free slot
}

fn findOrCreate(key: u64, rect: rl.Rectangle, initial_active: bool) *GlowEntry {
    var oldest: *GlowEntry = &glows[0];
    for (&glows) |*entry| {
        if (entry.key == key) return entry;
        if (entry.key == 0) {
            oldest = entry;
            break;
        }
        if (entry.last_seen < oldest.last_seen) oldest = entry;
    }
    oldest.* = .{
        .key = key,
        .rect = rect,
        .active = if (initial_active) 1 else 0,
    };
    return oldest;
}

fn expireGlows() void {
    for (&glows) |*entry| {
        if (entry.key == 0) continue;
        if (frame_now - entry.last_seen > glow_expiry_seconds) entry.* = .{};
    }
}

pub fn resetForTests() void {
    glows = @splat(.{});
    reveals = defaultReveals();
    last_frame_time = null;
    frame_now = 0;
    frame_dt = 0;
    frame_pointer = null;
    frame_pressed = false;
    overlay_shading_chrome = false;
    drawing_overlay_layer = false;
    clip_depth = 0;
    glides = @splat(.{});
}

/// Register a control drawn at `rect` this frame and read back its motion
/// state. `active` is the control's logical on/off which the returned
/// `Glow.active` follows with a short crossfade.
pub fn touch(rect: rl.Rectangle, active: bool) Glow {
    return touchAt(rect, active, pointerForLayer());
}

/// `touch` with an explicit pointer, for surfaces that own the pointer
/// themselves (modal dialogs drawn above the chrome).
pub fn touchAt(rect: rl.Rectangle, active: bool, pointer_at: ?rl.Vector2) Glow {
    if (rect.width <= 0 or rect.height <= 0) return .{ .active = if (active) 1 else 0 };
    const key = rectKey(rect);
    const entry = findOrCreate(key, rect, active);
    const hovered = if (enabled) (if (pointer_at) |point| pointIn(point, rect) else false) else false;
    const first_touch_this_frame = entry.last_frame != frame_now;
    entry.last_seen = frame_now;
    if (first_touch_this_frame) {
        entry.last_frame = frame_now;
        const dt = frame_dt;
        if (!enabled) {
            entry.hover = 0;
            entry.press = 0;
            entry.active = if (active) 1 else 0;
        } else {
            if (hovered) {
                entry.hover = @min(1, entry.hover + dt / hover_rise_seconds);
                if (frame_pressed) entry.press = 1;
            } else {
                entry.hover = @max(0, entry.hover - dt / hover_fall_seconds);
            }
            entry.press = @max(0, entry.press - dt / press_decay_seconds);
            const active_target: f32 = if (active) 1 else 0;
            const active_step = dt / active_blend_seconds;
            entry.active = if (entry.active < active_target)
                @min(active_target, entry.active + active_step)
            else
                @max(active_target, entry.active - active_step);
            if (entry.hover > 0) {
                const perimeter = 2 * (rect.width + rect.height);
                const lap_seconds = @max(comet_min_lap_seconds, perimeter / comet_pixels_per_second);
                entry.comet = @mod(entry.comet + dt / lap_seconds * perimeter, perimeter);
            }
        }
    }
    return .{
        .hover = entry.hover,
        .press = entry.press,
        .active = entry.active,
        .comet = entry.comet,
        .hovered = hovered,
    };
}

/// Hover-only variant for rows and cards that have no active crossfade.
pub fn touchRow(rect: rl.Rectangle) Glow {
    return touch(rect, false);
}

// ---------------------------------------------------------------------------
// Perimeter walk for the comet
// ---------------------------------------------------------------------------

/// Point at `distance` pixels clockwise along the rectangle's edge from its
/// top-left corner. Wraps around.
pub fn perimeterPoint(rect: rl.Rectangle, distance: f32) rl.Vector2 {
    const w = @max(0, rect.width);
    const h = @max(0, rect.height);
    const perimeter = 2 * (w + h);
    if (perimeter <= 0) return .{ .x = rect.x, .y = rect.y };
    var d = @mod(distance, perimeter);
    if (d < 0) d += perimeter;
    if (d <= w) return .{ .x = rect.x + d, .y = rect.y };
    d -= w;
    if (d <= h) return .{ .x = rect.x + w, .y = rect.y + d };
    d -= h;
    if (d <= w) return .{ .x = rect.x + w - d, .y = rect.y + h };
    d -= w;
    return .{ .x = rect.x, .y = rect.y + h - d };
}

// ---------------------------------------------------------------------------
// Drawing helpers
// ---------------------------------------------------------------------------

fn inflate(rect: rl.Rectangle, amount: f32) rl.Rectangle {
    return .{
        .x = rect.x - amount,
        .y = rect.y - amount,
        .width = rect.width + amount * 2,
        .height = rect.height + amount * 2,
    };
}

/// The resting fill/border of a control, blended by hover and active state.
pub const ControlColors = struct {
    fill: rl.Color,
    border: rl.Color,
};

pub fn controlColors(glow: Glow) ControlColors {
    const hover = smooth(glow.hover);
    const active = smooth(glow.active);
    const rest_fill = mixColor(theme.control, theme.control_hover, hover);
    const on_fill = mixColor(theme.accent_fill, mixColor(theme.accent_fill, theme.accent, 0.22), hover);
    const rest_border = mixColor(theme.border_strong, theme.accent, hover * 0.85);
    const on_border = mixColor(theme.accent, theme.accent_bright, hover);
    return .{
        .fill = mixColor(rest_fill, on_fill, active),
        .border = mixColor(rest_border, on_border, active),
    };
}

/// Soft accent halo just outside a control. Cheap: three hairline outlines
/// stepping out with falling alpha.
pub fn drawHalo(rect: rl.Rectangle, intensity: f32, color: rl.Color) void {
    const k = clamp01(intensity);
    if (k <= 0.01) return;
    const spread = @max(3, @min(7, rect.height * 0.18));
    const rings = 4;
    var ring: usize = 0;
    while (ring < rings) : (ring += 1) {
        const step = @as(f32, @floatFromInt(ring + 1)) / @as(f32, @floatFromInt(rings));
        const outline = inflate(rect, step * spread);
        const falloff = (1 - step) * (1 - step);
        rl.drawRectangleLinesEx(outline, 1, scaledAlpha(color, k * falloff * 0.7));
    }
    // A faint inner wash so the light appears to come from the edge inwards.
    rl.drawRectangleRec(rect, scaledAlpha(color, k * 0.07));
}

/// The running light: a bright head with a fading tail sliding along the
/// perimeter. `intensity` scales the whole thing so it can fade with hover.
pub fn drawComet(rect: rl.Rectangle, distance: f32, intensity: f32, color: rl.Color) void {
    const k = clamp01(intensity);
    if (k <= 0.02) return;
    const perimeter = 2 * (rect.width + rect.height);
    if (perimeter <= 8) return;
    const tail_length = @min(perimeter * 0.5, @max(36, perimeter * 0.3));
    const samples: usize = 24;
    const spacing = tail_length / @as(f32, @floatFromInt(samples));
    var previous = perimeterPoint(rect, distance);
    var index: usize = 1;
    while (index <= samples) : (index += 1) {
        const back = @as(f32, @floatFromInt(index)) * spacing;
        const point = perimeterPoint(rect, distance - back);
        const fade = 1 - back / tail_length;
        const thickness = 1.5 + 1.5 * fade;
        rl.drawLineEx(previous, point, thickness, scaledAlpha(color, k * fade * fade));
        previous = point;
    }
    const head = perimeterPoint(rect, distance);
    rl.drawCircleV(head, 5, scaledAlpha(color, k * 0.3));
    rl.drawCircleV(head, 2.6, scaledAlpha(theme.text, k * 0.95));
}

/// Expanding, fading outline after a click.
pub fn drawPressRipple(rect: rl.Rectangle, press: f32, color: rl.Color) void {
    const k = clamp01(press);
    if (k <= 0.01) return;
    const travel = (1 - k) * @max(6, rect.height * 0.3);
    const outline = inflate(rect, travel);
    rl.drawRectangleLinesEx(outline, 1.5, scaledAlpha(color, k * k * 0.8));
    rl.drawRectangleRec(rect, scaledAlpha(color, k * 0.18));
}

/// Draw the full decoration set for a control: halo, ripple, and comet.
/// Call after the control's own fill/border so the light sits on top.
pub fn drawControlMotion(rect: rl.Rectangle, glow: Glow) void {
    if (!enabled) return;
    drawHalo(rect, glow.hover, theme.accent);
    drawPressRipple(rect, glow.press, theme.accent_bright);
    drawComet(rect, glow.comet, glow.hover, theme.accent_bright);
}

/// Scrim colour for a modal at the given presence.
pub fn scrimAt(presence: f32) rl.Color {
    return scaledAlpha(theme.scrim, presence);
}

pub fn inflateRect(rect: rl.Rectangle, amount: f32) rl.Rectangle {
    return inflate(rect, amount);
}

/// Wash for hovered rows/cards: a barely-there fill plus a hairline.
pub fn drawRowHover(rect: rl.Rectangle, hover: f32) void {
    const k = smooth(hover);
    if (k <= 0.01) return;
    rl.drawRectangleRec(rect, scaledAlpha(theme.accent, k * 0.08));
    rl.drawRectangleLinesEx(rect, 1, scaledAlpha(theme.accent, k * 0.35));
}

// ---------------------------------------------------------------------------
// Scissor stack for fold reveals
// ---------------------------------------------------------------------------
//
// raylib's scissor is a single global rectangle; `endScissorMode` disables
// clipping entirely. Overlays that clip their own row lists would therefore
// punch through an outer fold clip. This tiny stack intersects nested clips
// and restores the parent on pop.

const clip_capacity = 6;
var clip_stack: [clip_capacity]rl.Rectangle = undefined;
var clip_depth: usize = 0;

fn intersect(a: rl.Rectangle, b: rl.Rectangle) rl.Rectangle {
    const x0 = @max(a.x, b.x);
    const y0 = @max(a.y, b.y);
    const x1 = @min(a.x + a.width, b.x + b.width);
    const y1 = @min(a.y + a.height, b.y + b.height);
    return .{ .x = x0, .y = y0, .width = @max(0, x1 - x0), .height = @max(0, y1 - y0) };
}

fn applyClip(rect: rl.Rectangle) void {
    rl.beginScissorMode(
        @intFromFloat(@floor(rect.x)),
        @intFromFloat(@floor(rect.y)),
        @intFromFloat(@ceil(@max(0, rect.width))),
        @intFromFloat(@ceil(@max(0, rect.height))),
    );
}

pub fn pushClip(rect: rl.Rectangle) void {
    const effective = if (clip_depth > 0) intersect(clip_stack[clip_depth - 1], rect) else rect;
    if (clip_depth < clip_capacity) {
        clip_stack[clip_depth] = effective;
        clip_depth += 1;
    }
    applyClip(effective);
}

pub fn popClip() void {
    if (clip_depth > 0) clip_depth -= 1;
    if (clip_depth > 0) {
        applyClip(clip_stack[clip_depth - 1]);
    } else {
        rl.endScissorMode();
    }
}

pub fn clipDepth() usize {
    return clip_depth;
}

// ---------------------------------------------------------------------------
// Glides: one rectangle chasing another (the inspector tab indicator)
// ---------------------------------------------------------------------------

pub const GlideSlot = enum(u8) {
    inspector_tab,
};

const Glide = struct {
    rect: rl.Rectangle = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    target_key: u64 = 0,
    initialized: bool = false,
    last_frame: f64 = -1,
};

const glide_count = @typeInfo(GlideSlot).@"enum".fields.len;
var glides: [glide_count]Glide = @splat(.{});

pub const glide_seconds: f32 = 0.16;

/// Move the slot's rectangle toward `target` and return where it is now. The
/// first call and any jump larger than twice the target's width (a window
/// resize relaid the strip) snap instead of gliding. Returns whether the
/// target changed this frame so callers can kick off a companion effect.
pub const GlideResult = struct {
    rect: rl.Rectangle,
    retargeted: bool,
};

pub fn glide(slot: GlideSlot, target: rl.Rectangle) GlideResult {
    const entry = &glides[@intFromEnum(slot)];
    const key = rectKey(target);
    var retargeted = false;
    if (!entry.initialized or !enabled) {
        entry.rect = target;
        entry.initialized = true;
        entry.target_key = key;
        entry.last_frame = frame_now;
        return .{ .rect = entry.rect, .retargeted = false };
    }
    if (entry.target_key != key) {
        retargeted = true;
        entry.target_key = key;
        const jump = @abs(target.x - entry.rect.x) + @abs(target.y - entry.rect.y);
        if (jump > target.width * 2 + target.height * 2) entry.rect = target;
    }
    if (entry.last_frame != frame_now) {
        entry.last_frame = frame_now;
        // Exponential approach: the same fraction of the remaining distance
        // each frame, so the indicator lands softly without overshoot.
        const k = 1 - @exp(-frame_dt / (glide_seconds * 0.35));
        entry.rect.x = lerp(entry.rect.x, target.x, k);
        entry.rect.y = lerp(entry.rect.y, target.y, k);
        entry.rect.width = lerp(entry.rect.width, target.width, k);
        entry.rect.height = lerp(entry.rect.height, target.height, k);
        if (@abs(entry.rect.x - target.x) < 0.5 and @abs(entry.rect.width - target.width) < 0.5) {
            entry.rect = target;
        }
    }
    return .{ .rect = entry.rect, .retargeted = retargeted };
}

/// Restart a reveal from zero (a wipe that replays every time).
pub fn replay(kind: RevealKind) void {
    const entry = reveal(kind);
    entry.open = true;
    entry.progress = if (enabled) 0 else 1;
}

/// Accent bar under a tab strip indicator, with a soft glow so the glide
/// reads even between two neighbouring tabs of the same colour.
pub fn drawTabIndicator(rect: rl.Rectangle) void {
    if (!enabled or rect.width <= 0) return;
    const bar_height: f32 = 2;
    const bar: rl.Rectangle = .{
        .x = rect.x + 1,
        .y = rect.y + rect.height - bar_height - 1,
        .width = @max(0, rect.width - 2),
        .height = bar_height,
    };
    rl.drawRectangleRec(bar, theme.accent_bright);
    rl.drawRectangleRec(.{ .x = bar.x, .y = bar.y - 2, .width = bar.width, .height = 2 }, scaledAlpha(theme.accent_bright, 0.35));
    rl.drawRectangleRec(.{ .x = bar.x, .y = bar.y - 4, .width = bar.width, .height = 2 }, scaledAlpha(theme.accent_bright, 0.12));
}

// ---------------------------------------------------------------------------
// Fold reveal geometry for floating panels
// ---------------------------------------------------------------------------

pub const Fold = struct {
    /// Vertical drift applied to the whole panel (positive = pushed down).
    offset_y: f32,
    /// Clip rectangle exposing the panel from the top edge downwards.
    clip: rl.Rectangle,
    /// Scrim alpha factor 0..1.
    scrim: f32,
    /// Alpha factor for the scan line at the fold edge.
    edge: f32,
    edge_y: f32,
};

/// Fold geometry for a panel opening from its top edge. `presence` is the
/// reveal's eased presence.
pub fn foldFromTop(panel: rl.Rectangle, presence: f32, scale: f32) Fold {
    const p = clamp01(presence);
    const drift = (1 - p) * 16 * scale;
    const exposed = panel.height * p;
    // The bottom margin grows with presence so the drop shadow beneath the
    // panel is fully visible once it has settled, without the fold edge
    // ever exposing it early.
    const margin = 24 * scale;
    return .{
        .offset_y = drift,
        .clip = .{
            .x = panel.x - margin,
            .y = panel.y + drift - margin,
            .width = panel.width + margin * 2,
            .height = exposed + margin + margin * p,
        },
        .scrim = p,
        .edge = if (p >= 1) 0 else (1 - p) * 0.9 + 0.1,
        .edge_y = panel.y + drift + exposed,
    };
}

/// Wipe geometry for content revealed in place from its top edge, without the
/// drift a floating panel gets. Used for the inspector body on a tab switch.
pub fn wipeFromTop(rect: rl.Rectangle, presence: f32) Fold {
    const p = clamp01(presence);
    const exposed = rect.height * p;
    return .{
        .offset_y = 0,
        .clip = .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = exposed },
        .scrim = p,
        .edge = if (p >= 1) 0 else (1 - p) * 0.8 + 0.2,
        .edge_y = rect.y + exposed,
    };
}

pub fn shiftRect(rect: rl.Rectangle, dx: f32, dy: f32) rl.Rectangle {
    return .{ .x = rect.x + dx, .y = rect.y + dy, .width = rect.width, .height = rect.height };
}

/// Horizontal scan line at the fold edge, brighter while the fold is moving.
pub fn drawFoldEdge(fold: Fold, panel_x: f32, panel_width: f32) void {
    if (fold.edge <= 0.01) return;
    const y = @round(fold.edge_y);
    rl.drawLineEx(.{ .x = panel_x, .y = y }, .{ .x = panel_x + panel_width, .y = y }, 1.5, scaledAlpha(theme.accent_bright, fold.edge));
    rl.drawLineEx(.{ .x = panel_x, .y = y + 2 }, .{ .x = panel_x + panel_width, .y = y + 2 }, 1, scaledAlpha(theme.accent, fold.edge * 0.35));
}

/// Slide geometry for a pane entering from the right edge of the screen.
pub fn slideFromRight(final: rl.Rectangle, presence: f32, screen_width: f32) rl.Rectangle {
    const p = clamp01(presence);
    const start_x = screen_width + 8;
    return .{
        .x = lerp(start_x, final.x, p),
        .y = final.y,
        .width = final.width,
        .height = final.height,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "reveal glides open and closed with asymmetric easing" {
    resetForTests();
    defer resetForTests();
    var r = Reveal{ .open_seconds = 0.2, .close_seconds = 0.1 };
    try std.testing.expect(!r.visible());
    r.setOpen(true);
    try std.testing.expect(r.visible());
    try std.testing.expect(r.animating());
    r.advance(0.1);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), r.progress, 0.0001);
    try std.testing.expect(r.presence() > 0.5); // ease-out arrives early
    r.advance(0.1);
    try std.testing.expect(r.settled());
    r.setOpen(false);
    r.advance(0.05);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), r.progress, 0.0001);
    try std.testing.expect(r.presence() > 0.5); // ease-in lingers, then whips away
    r.advance(0.05);
    try std.testing.expect(!r.visible());
}

test "reveal snaps when motion is disabled" {
    resetForTests();
    defer resetForTests();
    enabled = false;
    defer enabled = true;
    var r = Reveal{};
    r.setOpen(true);
    try std.testing.expectEqual(@as(f32, 1), r.progress);
    r.setOpen(false);
    try std.testing.expectEqual(@as(f32, 0), r.progress);
}

test "frame clock clamps stalls and advances registered reveals" {
    resetForTests();
    defer resetForTests();
    reveal(.command_palette).setOpen(true);
    beginFrame(.{ .now = 10, .pointer = null });
    try std.testing.expectEqual(@as(f32, 0), frameDelta());
    beginFrame(.{ .now = 15, .pointer = null }); // five second stall
    try std.testing.expectEqual(max_frame_step, frameDelta());
    try std.testing.expect(reveal(.command_palette).progress > 0);
    try std.testing.expect(reveal(.command_palette).progress < 1);
}

test "hover glow rises under the pointer and decays after it leaves" {
    resetForTests();
    defer resetForTests();
    const rect: rl.Rectangle = .{ .x = 10, .y = 10, .width = 80, .height = 24 };
    const inside: rl.Vector2 = .{ .x = 20, .y = 20 };
    const outside: rl.Vector2 = .{ .x = 200, .y = 200 };
    beginFrame(.{ .now = 0, .pointer = inside });
    var glow = touch(rect, false);
    try std.testing.expect(glow.hovered);
    try std.testing.expectEqual(@as(f32, 0), glow.hover);
    var t: f64 = 0;
    while (t < 0.3) : (t += 1.0 / 60.0) {
        beginFrame(.{ .now = t, .pointer = inside });
        glow = touch(rect, false);
    }
    try std.testing.expectEqual(@as(f32, 1), glow.hover);
    try std.testing.expect(glow.comet > 0);
    while (t < 0.8) : (t += 1.0 / 60.0) {
        beginFrame(.{ .now = t, .pointer = outside });
        glow = touch(rect, false);
    }
    try std.testing.expect(!glow.hovered);
    try std.testing.expectEqual(@as(f32, 0), glow.hover);
}

test "touching a rect twice in one frame integrates once" {
    resetForTests();
    defer resetForTests();
    const rect: rl.Rectangle = .{ .x = 0, .y = 0, .width = 50, .height = 20 };
    const inside: rl.Vector2 = .{ .x = 5, .y = 5 };
    beginFrame(.{ .now = 0, .pointer = inside });
    _ = touch(rect, false);
    beginFrame(.{ .now = 0.05, .pointer = inside });
    const first = touch(rect, false);
    const second = touch(rect, false);
    try std.testing.expectEqual(first.hover, second.hover);
    try std.testing.expect(first.hover > 0);
}

test "press flashes on click and active state crossfades" {
    resetForTests();
    defer resetForTests();
    const rect: rl.Rectangle = .{ .x = 0, .y = 0, .width = 50, .height = 20 };
    const inside: rl.Vector2 = .{ .x = 5, .y = 5 };
    beginFrame(.{ .now = 0, .pointer = inside });
    var glow = touch(rect, false);
    try std.testing.expectEqual(@as(f32, 0), glow.active);
    beginFrame(.{ .now = 0.016, .pointer = inside, .pressed = true });
    glow = touch(rect, true);
    try std.testing.expect(glow.press > 0.9);
    try std.testing.expect(glow.active > 0 and glow.active < 1);
    var t: f64 = 0.032;
    while (t < 1) : (t += 1.0 / 60.0) {
        beginFrame(.{ .now = t, .pointer = null });
        glow = touch(rect, true);
    }
    try std.testing.expectEqual(@as(f32, 0), glow.press);
    try std.testing.expectEqual(@as(f32, 1), glow.active);
}

test "controls under an overlay ignore the pointer while the overlay may use it" {
    resetForTests();
    defer resetForTests();
    const rect: rl.Rectangle = .{ .x = 0, .y = 0, .width = 50, .height = 20 };
    const inside: rl.Vector2 = .{ .x = 5, .y = 5 };
    beginFrame(.{ .now = 0, .pointer = inside });
    setOverlayShadingChrome(true);
    try std.testing.expect(!touch(rect, false).hovered);
    setOverlayLayer(true);
    try std.testing.expect(touch(rect, false).hovered);
    setOverlayShadingChrome(false);
    try std.testing.expect(touch(rect, false).hovered);
}

test "stale glow entries are recycled" {
    resetForTests();
    defer resetForTests();
    const rect: rl.Rectangle = .{ .x = 0, .y = 0, .width = 50, .height = 20 };
    beginFrame(.{ .now = 0, .pointer = .{ .x = 5, .y = 5 } });
    _ = touch(rect, false);
    beginFrame(.{ .now = 0.05, .pointer = .{ .x = 5, .y = 5 } });
    _ = touch(rect, false);
    try std.testing.expect(glows[0].key != 0);
    beginFrame(.{ .now = 5, .pointer = null });
    try std.testing.expectEqual(@as(u64, 0), glows[0].key);
}

test "perimeter walk visits every edge clockwise and wraps" {
    const rect: rl.Rectangle = .{ .x = 10, .y = 20, .width = 100, .height = 40 };
    const p0 = perimeterPoint(rect, 0);
    try std.testing.expectEqual(@as(f32, 10), p0.x);
    try std.testing.expectEqual(@as(f32, 20), p0.y);
    const top = perimeterPoint(rect, 50);
    try std.testing.expectEqual(@as(f32, 60), top.x);
    try std.testing.expectEqual(@as(f32, 20), top.y);
    const right = perimeterPoint(rect, 120);
    try std.testing.expectEqual(@as(f32, 110), right.x);
    try std.testing.expectEqual(@as(f32, 40), right.y);
    const bottom = perimeterPoint(rect, 190);
    try std.testing.expectEqual(@as(f32, 60), bottom.x);
    try std.testing.expectEqual(@as(f32, 60), bottom.y);
    const left = perimeterPoint(rect, 260);
    try std.testing.expectEqual(@as(f32, 10), left.x);
    try std.testing.expectEqual(@as(f32, 40), left.y);
    const wrapped = perimeterPoint(rect, 280 + 50);
    try std.testing.expectEqual(top.x, wrapped.x);
    try std.testing.expectEqual(top.y, wrapped.y);
}

test "fold exposes the panel from the top and settles without drift" {
    const panel: rl.Rectangle = .{ .x = 100, .y = 50, .width = 400, .height = 300 };
    const half = foldFromTop(panel, 0.5, 1);
    try std.testing.expectEqual(@as(f32, 8), half.offset_y);
    // Half exposed plus the top margin plus half of the growing bottom margin.
    try std.testing.expectApproxEqAbs(@as(f32, 150 + 24 + 12), half.clip.height, 0.001);
    try std.testing.expect(half.edge > 0);
    const full = foldFromTop(panel, 1, 1);
    try std.testing.expectEqual(@as(f32, 0), full.offset_y);
    try std.testing.expectEqual(@as(f32, 0), full.edge);
    // Fully open, the clip clears the panel and its drop shadow.
    try std.testing.expect(full.clip.y + full.clip.height >= panel.y + panel.height + 12);
}

test "slide from right lands on the final rectangle" {
    const final: rl.Rectangle = .{ .x = 40, .y = 30, .width = 800, .height = 500 };
    const start = slideFromRight(final, 0, 1000);
    try std.testing.expect(start.x >= 1000);
    const landed = slideFromRight(final, 1, 1000);
    try std.testing.expectEqual(final.x, landed.x);
    try std.testing.expectEqual(final.width, landed.width);
}

test "clip stack intersects nested clips" {
    resetForTests();
    defer resetForTests();
    const outer: rl.Rectangle = .{ .x = 0, .y = 0, .width = 100, .height = 50 };
    const inner: rl.Rectangle = .{ .x = 50, .y = 20, .width = 100, .height = 100 };
    const clipped = intersect(outer, inner);
    try std.testing.expectEqual(@as(f32, 50), clipped.x);
    try std.testing.expectEqual(@as(f32, 20), clipped.y);
    try std.testing.expectEqual(@as(f32, 50), clipped.width);
    try std.testing.expectEqual(@as(f32, 30), clipped.height);
}

test "glide snaps on first use, retargets once, and converges" {
    resetForTests();
    defer resetForTests();
    const a: rl.Rectangle = .{ .x = 0, .y = 0, .width = 100, .height = 30 };
    const b: rl.Rectangle = .{ .x = 110, .y = 0, .width = 100, .height = 30 };
    beginFrame(.{ .now = 0, .pointer = null });
    const first = glide(.inspector_tab, a);
    try std.testing.expect(!first.retargeted);
    try std.testing.expectEqual(a.x, first.rect.x);
    beginFrame(.{ .now = 1.0 / 60.0, .pointer = null });
    const moved = glide(.inspector_tab, b);
    try std.testing.expect(moved.retargeted);
    try std.testing.expect(moved.rect.x > a.x and moved.rect.x < b.x);
    var t: f64 = 2.0 / 60.0;
    var last = moved;
    while (t < 1) : (t += 1.0 / 60.0) {
        beginFrame(.{ .now = t, .pointer = null });
        last = glide(.inspector_tab, b);
        try std.testing.expect(!last.retargeted);
    }
    try std.testing.expectEqual(b.x, last.rect.x);
}

test "replay restarts a reveal from zero" {
    resetForTests();
    defer resetForTests();
    try std.testing.expect(reveal(.inspector_body).settled());
    replay(.inspector_body);
    try std.testing.expectEqual(@as(f32, 0), reveal(.inspector_body).progress);
    try std.testing.expect(reveal(.inspector_body).open);
    beginFrame(.{ .now = 0, .pointer = null });
    beginFrame(.{ .now = 0.5, .pointer = null });
    try std.testing.expect(reveal(.inspector_body).progress > 0);
}
