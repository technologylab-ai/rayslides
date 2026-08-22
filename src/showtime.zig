//! Deterministic, non-mutating presentation readiness analysis and portable
//! show packaging. The analyzer consumes the live parser graph and the
//! renderer's already-materialized scenes; it never draws, seeks, navigates,
//! or rewrites the authored document.

const std = @import("std");
const rl = @import("raylib");
const slides = @import("slides.zig");
const renderer = @import("renderer.zig");
const studio_catalog = @import("studio_catalog.zig");

pub const slide_width: f32 = 1920;
pub const slide_height: f32 = 1080;
pub const max_findings: usize = 512;

pub const Severity = enum { error_, warning, info };
pub const Category = enum { deck, render, media, typography, layout, display, network, portable };
pub const Code = enum {
    deck_load_failed,
    parser_error,
    empty_deck,
    render_scene_missing,
    render_item_missing,
    media_unavailable,
    media_warning,
    media_path_absolute,
    media_path_parent_escape,
    missing_glyph,
    text_overflow,
    canvas_escape,
    duplicate_id,
    unstable_morph_id,
    display_unavailable,
    display_low_resolution,
    display_aspect_mismatch,
    display_low_refresh,
    vsync_disabled,
    presenter_unavailable,
    presenter_unreachable,
    presenter_not_connected,
    presenter_health_unmeasured,
    presenter_health_slow,
    presenter_health_failures,
    presenter_health_ready,
    crowdplay_unavailable,
    portable_not_created,
    portable_verified,
};

pub fn severityName(severity: Severity) []const u8 {
    return switch (severity) {
        .error_ => "error",
        .warning => "warning",
        .info => "info",
    };
}

pub const Finding = struct {
    severity: Severity,
    category: Category,
    code: Code,
    slide_index: ?usize = null,
    morph_state: ?usize = null,
    owner_identity: ?usize = null,
    source_line: ?usize = null,
    title: []u8,
    detail: []u8,

    fn deinit(self: Finding, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.detail);
    }
};

pub const RuntimeSnapshot = struct {
    monitor_count: usize = 0,
    selected_monitor: usize = 0,
    display_width: i32 = 0,
    display_height: i32 = 0,
    refresh_rate: i32 = 0,
    vsync_enabled: bool = true,
    fullscreen: bool = false,
    presenter_running: bool = false,
    presenter_reachable: bool = false,
    presenter_connected: bool = false,
    presenter_address: []const u8 = "",
    presenter_health_samples: u32 = 0,
    presenter_health_p95_ms: ?u32 = null,
    presenter_health_failures: u32 = 0,
    crowdplay_required: bool = false,
    crowdplay_running: bool = false,
};

pub const Summary = struct {
    slides: usize = 0,
    scenes: usize = 0,
    reveal_endpoints: usize = 0,
    items: usize = 0,
    render_fragments: usize = 0,
    reusable_definitions: usize = 0,
    assets: usize = 0,
    errors: usize = 0,
    warnings: usize = 0,
    info: usize = 0,
};

pub const Report = struct {
    allocator: std.mem.Allocator,
    findings: std.ArrayList(Finding) = .empty,
    summary: Summary = .{},
    truncated: bool = false,

    pub fn init(allocator: std.mem.Allocator) Report {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Report) void {
        for (self.findings.items) |finding| finding.deinit(self.allocator);
        self.findings.deinit(self.allocator);
        self.* = .{ .allocator = self.allocator };
    }

    pub fn ready(self: *const Report) bool {
        return self.summary.errors == 0;
    }

    pub fn issueCount(self: *const Report) usize {
        return self.summary.errors + self.summary.warnings;
    }

    pub fn categoryCounts(self: *const Report, category: Category) struct { errors: usize, warnings: usize, info: usize } {
        var result = .{ .errors = @as(usize, 0), .warnings = @as(usize, 0), .info = @as(usize, 0) };
        for (self.findings.items) |finding| {
            if (finding.category != category) continue;
            switch (finding.severity) {
                .error_ => result.errors += 1,
                .warning => result.warnings += 1,
                .info => result.info += 1,
            }
        }
        return result;
    }

    pub fn add(
        self: *Report,
        severity: Severity,
        category: Category,
        code: Code,
        slide_index: ?usize,
        morph_state: ?usize,
        owner_identity: ?usize,
        source_line: ?usize,
        title: []const u8,
        detail: []const u8,
    ) !void {
        if (self.findings.items.len >= max_findings) {
            self.truncated = true;
            return;
        }
        try self.findings.append(self.allocator, .{
            .severity = severity,
            .category = category,
            .code = code,
            .slide_index = slide_index,
            .morph_state = morph_state,
            .owner_identity = owner_identity,
            .source_line = source_line,
            .title = try self.allocator.dupe(u8, title),
            .detail = try self.allocator.dupe(u8, detail),
        });
        switch (severity) {
            .error_ => self.summary.errors += 1,
            .warning => self.summary.warnings += 1,
            .info => self.summary.info += 1,
        }
    }

    fn addFmt(
        self: *Report,
        severity: Severity,
        category: Category,
        code: Code,
        slide_index: ?usize,
        morph_state: ?usize,
        owner_identity: ?usize,
        source_line: ?usize,
        comptime title_format: []const u8,
        title_args: anytype,
        comptime detail_format: []const u8,
        detail_args: anytype,
    ) !void {
        const title = try std.fmt.allocPrint(self.allocator, title_format, title_args);
        defer self.allocator.free(title);
        const detail = try std.fmt.allocPrint(self.allocator, detail_format, detail_args);
        defer self.allocator.free(detail);
        try self.add(severity, category, code, slide_index, morph_state, owner_identity, source_line, title, detail);
    }

    fn alreadyHas(self: *const Report, code: Code, slide_index: usize, owner_identity: usize) bool {
        for (self.findings.items) |finding| {
            if (finding.code == code and finding.slide_index == slide_index and finding.owner_identity == owner_identity) return true;
        }
        return false;
    }
};

fn sourceLine(item: slides.SlideItem) ?usize {
    const source = item.effectiveSource();
    return if (source.line_number > 0) source.line_number else null;
}

fn renderItemForOwner(items: []const renderer.SlideshowRenderer.ShowtimeRenderItem, owner: usize) ?renderer.SlideshowRenderer.ShowtimeRenderItem {
    for (items) |item| if (item.owner_identity == owner) return item;
    return null;
}

fn sceneItems(slide: *const slides.Slide, morph_state: ?usize) []const slides.SlideItem {
    if (morph_state) |state| return slide.morph_states.items[state].items.items;
    return slide.items.?.items;
}

fn mediaPath(item: slides.SlideItem) ?[]const u8 {
    return switch (item.kind) {
        .background, .img => item.img_path,
        .vid => item.vid_path,
        else => null,
    };
}

fn mediaStatusText(status: slides.MediaAvailability) struct { title: []const u8, fix: []const u8 } {
    return switch (status) {
        .ready => .{ .title = "Media ready", .fix = "No action needed." },
        .image_unavailable => .{ .title = "Image unavailable", .fix = "Choose a readable image file and run Showtime again." },
        .image_file_missing => .{ .title = "Image file is missing", .fix = "Replace the image or restore the file beside the deck." },
        .image_file_unreadable => .{ .title = "Image file is unreadable", .fix = "Fix file permissions or replace the image." },
        .image_decode_failed => .{ .title = "Image cannot be decoded", .fix = "Convert it to a supported PNG/JPEG image or replace it." },
        .video_unavailable => .{ .title = "Video unavailable", .fix = "Choose a readable video and verify ffmpeg/ffprobe." },
        .video_file_missing => .{ .title = "Video file is missing", .fix = "Replace the video or restore the file beside the deck." },
        .video_file_unreadable => .{ .title = "Video file is unreadable", .fix = "Fix file permissions or replace the video." },
        .video_tools_missing => .{ .title = "ffmpeg or ffprobe is unavailable", .fix = "Install both tools, then run Showtime again." },
        .video_probe_failed => .{ .title = "Video stream or codec probe failed", .fix = "Transcode the video to a supported format and retry." },
        .video_poster_decode_failed => .{ .title = "Video poster frame cannot be decoded", .fix = "Choose another poster time or transcode the video." },
        .video_poster_out_of_range => .{ .title = "Video poster time is outside the clip", .fix = "Choose a poster time within the reported duration." },
        .video_poster_fallback => .{ .title = "Video poster uses the first-frame fallback", .fix = "Review the poster or choose a reliably decodable timestamp." },
    };
}

fn hasParentEscape(path: []const u8) bool {
    var components = std.mem.tokenizeAny(u8, path, "/\\");
    while (components.next()) |component| if (std.mem.eql(u8, component, "..")) return true;
    return false;
}

fn outsideCanvas(bounds: rl.Rectangle) bool {
    const epsilon: f32 = 0.5;
    return bounds.x < -epsilon or bounds.y < -epsilon or
        bounds.x + bounds.width > slide_width + epsilon or
        bounds.y + bounds.height > slide_height + epsilon;
}

fn textOverflows(item: slides.SlideItem, bounds: rl.Rectangle) bool {
    if (item.kind != .textbox) return false;
    const epsilon: f32 = 1.0;
    const authored = rl.Rectangle{ .x = item.position.x, .y = item.position.y, .width = item.size.x, .height = item.size.y };
    if (item.size.x > 0 and
        (bounds.x < authored.x - epsilon or bounds.x + bounds.width > authored.x + authored.width + epsilon)) return true;
    if (item.size.y > 0 and
        (bounds.y < authored.y - epsilon or bounds.y + bounds.height > authored.y + authored.height + epsilon)) return true;
    return false;
}

fn analyzeRuntime(report: *Report, runtime: RuntimeSnapshot) !void {
    if (runtime.monitor_count == 0) {
        try report.add(.error_, .display, .display_unavailable, null, null, null, null, "No presentation display is available", "Connect or enable a display, then choose it explicitly with D.");
        return;
    }
    if (runtime.display_width < 1280 or runtime.display_height < 720) {
        try report.addFmt(.warning, .display, .display_low_resolution, null, null, null, null, "Selected display is only {d}×{d}", .{ runtime.display_width, runtime.display_height }, "Review fine text and media on the actual projector before showtime.", .{});
    }
    if (runtime.display_width > 0 and runtime.display_height > 0) {
        const aspect = @as(f32, @floatFromInt(runtime.display_width)) / @as(f32, @floatFromInt(runtime.display_height));
        if (@abs(aspect - (16.0 / 9.0)) > 0.04) {
            try report.addFmt(.warning, .display, .display_aspect_mismatch, null, null, null, null, "Selected display is {d:.2}:1, not 16:9", .{aspect}, "Rayslides will letterbox without stretching; verify the venue's visible frame.", .{});
        }
    }
    if (runtime.refresh_rate > 0 and runtime.refresh_rate < 50) {
        try report.addFmt(.warning, .display, .display_low_refresh, null, null, null, null, "Selected display refresh is {d} Hz", .{runtime.refresh_rate}, "Motion may look uneven; prefer a 50 Hz or faster projector mode.", .{});
    }
    if (!runtime.vsync_enabled) {
        try report.add(.warning, .display, .vsync_disabled, null, null, null, null, "Vsync is disabled", "Enable refresh-bound presentation frames to reduce tearing.");
    }
    if (runtime.presenter_running and !runtime.presenter_reachable) {
        try report.addFmt(.warning, .network, .presenter_unreachable, null, null, null, null, "Presenter Companion advertises an unreachable address", .{}, "Re-pair after choosing a LAN or hotspot address; current address: {s}", .{runtime.presenter_address});
    } else if (!runtime.presenter_running) {
        try report.add(.info, .network, .presenter_unavailable, null, null, null, null, "Presenter Companion is not paired", "This is optional. Pair it now if the talk depends on private notes or remote control.");
    } else if (!runtime.presenter_connected) {
        try report.add(.warning, .network, .presenter_not_connected, null, null, null, null, "No Presenter Companion client is connected", "Open the private phone or laptop link and rehearse controls before showtime.");
    } else if (runtime.presenter_health_samples == 0 or runtime.presenter_health_p95_ms == null) {
        try report.add(.warning, .network, .presenter_health_unmeasured, null, null, null, null, "Presenter connection health is still unmeasured", "Exercise navigation, Pointer, and Draw until the private client reports representative round trips.");
    } else if (runtime.presenter_health_failures > 0) {
        try report.addFmt(.warning, .network, .presenter_health_failures, null, null, null, null, "Presenter rehearsal recorded {d} failed request{s}", .{ runtime.presenter_health_failures, if (runtime.presenter_health_failures == 1) "" else "s" }, "Review the private Connection health panel, then retry on the intended venue Wi-Fi or hotspot.", .{});
    } else if (runtime.presenter_health_p95_ms.? > 250) {
        try report.addFmt(.warning, .network, .presenter_health_slow, null, null, null, null, "Presenter delivery p95 is {d} ms", .{runtime.presenter_health_p95_ms.?}, "Rehearse closer to the access point or use the presenter-phone hotspot; aim for p95 below 250 ms.", .{});
    } else {
        try report.addFmt(.info, .network, .presenter_health_ready, null, null, null, null, "Presenter delivery p95 is {d} ms across {d} samples", .{ runtime.presenter_health_p95_ms.?, runtime.presenter_health_samples }, "The private client has current, failure-free round-trip evidence.", .{});
    }
    if (runtime.crowdplay_required and !runtime.crowdplay_running) {
        try report.add(.error_, .network, .crowdplay_unavailable, null, null, null, null, "This deck needs Crowdplay, but its service is unavailable", "Fix the configured host/port before presenting interactive slides.");
    }
}

pub fn analyze(
    allocator: std.mem.Allocator,
    slideshow: *const slides.SlideShow,
    render: *const renderer.SlideshowRenderer,
    source: []const u8,
    runtime: RuntimeSnapshot,
) !Report {
    var report = Report.init(allocator);
    errdefer report.deinit();
    report.summary.slides = slideshow.slides.items.len;
    if (slideshow.slides.items.len == 0) {
        try report.add(.error_, .deck, .empty_deck, null, null, null, null, "The deck has no slides", "Add at least one authored slide before presenting.");
    }

    var catalog = try studio_catalog.discover(allocator, source);
    defer catalog.deinit();
    report.summary.reusable_definitions = catalog.entries.len;
    var references = try collectAssetReferences(allocator, source);
    defer references.deinit(allocator);
    report.summary.assets = countUniqueAssetPaths(references.items);

    var observations = std.ArrayList(renderer.SlideshowRenderer.ShowtimeRenderItem).empty;
    defer observations.deinit(allocator);
    for (slideshow.slides.items, 0..) |slide, slide_index| {
        report.summary.reveal_endpoints += render.stepCount(@intCast(slide_index)) + 1;
        const scene_count = slide.morph_states.items.len + 1;
        report.summary.scenes += scene_count;
        for (0..scene_count) |scene_index| {
            const morph_state: ?usize = if (scene_index == 0) null else scene_index - 1;
            const items = sceneItems(slide, morph_state);
            report.summary.items += items.len;
            report.summary.render_fragments += try render.collectShowtimeRenderItems(
                allocator,
                &observations,
                @intCast(slide_index),
                morph_state,
            );
            if (items.len > 0 and observations.items.len == 0) {
                try report.addFmt(.error_, .render, .render_scene_missing, slide_index, morph_state, null, null, "Slide {d} scene produced no render graph", .{slide_index + 1}, "Re-open the source and inspect this slide's directives.", .{});
            }

            for (items, 0..) |item, item_index| {
                if (item.id) |id| {
                    for (items[0..item_index]) |previous| {
                        if (previous.id != null and std.mem.eql(u8, previous.id.?, id)) {
                            try report.addFmt(.error_, .deck, .duplicate_id, slide_index, morph_state, item.identity, sourceLine(item), "Duplicate object id “{s}”", .{id}, "Give every object in this scene a unique id.", .{});
                            break;
                        }
                    }
                } else if (slide.morph_states.items.len > 0 and item.kind != .background and
                    !report.alreadyHas(.unstable_morph_id, slide_index, item.identity))
                {
                    try report.addFmt(.warning, .deck, .unstable_morph_id, slide_index, morph_state, item.identity, sourceLine(item), "Morph object {d} has no stable id", .{item.identity}, "Add id=… so future source edits cannot change semantic matching by accident.", .{});
                }

                const rendered = renderItemForOwner(observations.items, item.identity);
                if (rendered == null) {
                    if (item.visible and item.kind != .background and !report.alreadyHas(.render_item_missing, slide_index, item.identity)) {
                        const path = mediaPath(item);
                        if (path) |value| {
                            try report.addFmt(.error_, .media, .render_item_missing, slide_index, morph_state, item.identity, sourceLine(item), "Object {d} cannot produce presentation pixels", .{item.identity}, "Check the media dependency “{s}”.", .{value});
                        } else {
                            try report.addFmt(.error_, .render, .render_item_missing, slide_index, morph_state, item.identity, sourceLine(item), "Object {d} cannot produce presentation pixels", .{item.identity}, "Inspect this object's text, geometry, and source ownership.", .{});
                        }
                    }
                    continue;
                }
                const observation = rendered.?;
                if (mediaPath(item)) |path| {
                    if (observation.media_availability != .ready) {
                        const status = mediaStatusText(observation.media_availability);
                        const severity: Severity = if (observation.media_availability.blocksPixels()) .error_ else .warning;
                        const code: Code = if (observation.media_availability.blocksPixels()) .media_unavailable else .media_warning;
                        if (!report.alreadyHas(code, slide_index, item.identity)) {
                            try report.addFmt(severity, .media, code, slide_index, morph_state, item.identity, sourceLine(item), "{s}: {s}", .{ status.title, std.fs.path.basename(path) }, "{s} Source: {s}", .{ status.fix, path });
                        }
                    }
                    if (std.fs.path.isAbsolute(path) and !report.alreadyHas(.media_path_absolute, slide_index, item.identity)) {
                        try report.addFmt(.warning, .portable, .media_path_absolute, slide_index, morph_state, item.identity, sourceLine(item), "Asset uses an absolute path", .{}, "Portable Show can copy and rewrite it; authored path: {s}", .{path});
                    } else if (hasParentEscape(path) and !report.alreadyHas(.media_path_parent_escape, slide_index, item.identity)) {
                        try report.addFmt(.warning, .portable, .media_path_parent_escape, slide_index, morph_state, item.identity, sourceLine(item), "Asset escapes the deck folder", .{}, "Portable Show can copy and rewrite it; authored path: {s}", .{path});
                    }
                }
                if (observation.first_missing_codepoint) |codepoint| {
                    if (!report.alreadyHas(.missing_glyph, slide_index, item.identity)) {
                        try report.addFmt(.error_, .typography, .missing_glyph, slide_index, morph_state, item.identity, sourceLine(item), "Font is missing Unicode U+{X:0>4}", .{codepoint}, "Replace the character or select a font containing this glyph.", .{});
                    }
                }
                if (observation.has_bounds) {
                    if (textOverflows(item, observation.unrotated_bounds) and !report.alreadyHas(.text_overflow, slide_index, item.identity)) {
                        try report.addFmt(.warning, .typography, .text_overflow, slide_index, morph_state, item.identity, sourceLine(item), "Text exceeds object {d}'s authored box", .{item.identity}, "Enlarge the box, shorten the text, or reduce its font size.", .{});
                    }
                    if (outsideCanvas(observation.bounds) and !report.alreadyHas(.canvas_escape, slide_index, item.identity)) {
                        try report.addFmt(.warning, .layout, .canvas_escape, slide_index, morph_state, item.identity, sourceLine(item), "Object {d} extends outside the 1920×1080 canvas", .{item.identity}, "Review the slide and every morph state; off-canvas animation staging may be intentional.", .{});
                    }
                }
            }
        }
    }
    try analyzeRuntime(&report, runtime);
    return report;
}

pub const AssetKind = enum { image, video, font };
pub const AssetReference = struct {
    kind: AssetKind,
    path: []const u8,
    value_start: usize,
    value_end: usize,
    source_line: usize,
};
pub const AssetReferences = struct {
    items: []AssetReference,
    allocator: std.mem.Allocator,
    pub fn deinit(self: *AssetReferences, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.allocator.free(self.items);
        self.items = &.{};
    }
};

fn assetKindForKey(key: []const u8) ?AssetKind {
    if (std.mem.eql(u8, key, "img")) return .image;
    if (std.mem.eql(u8, key, "vid")) return .video;
    if (std.mem.eql(u8, key, "@font") or std.mem.eql(u8, key, "@font_bold") or
        std.mem.eql(u8, key, "@font_italic") or std.mem.eql(u8, key, "@font_bold_italic") or
        std.mem.eql(u8, key, "@font_extra")) return .font;
    return null;
}

/// Discover every literal asset token, including unused reusable definitions
/// and local overrides. Rayslides' current attribute grammar deliberately has
/// no quoted paths, so token offsets are exact and safe to rewrite.
pub fn collectAssetReferences(allocator: std.mem.Allocator, source: []const u8) !AssetReferences {
    var refs = std.ArrayList(AssetReference).empty;
    errdefer refs.deinit(allocator);
    var line_start: usize = 0;
    var line_number: usize = 1;
    while (line_start < source.len) : (line_number += 1) {
        const relative_end = std.mem.indexOfScalar(u8, source[line_start..], '\n') orelse source.len - line_start;
        const line_end = line_start + relative_end;
        var cursor = line_start;
        while (cursor < line_end and (source[cursor] == ' ' or source[cursor] == '\t' or source[cursor] == '\r')) cursor += 1;
        if (cursor < line_end and source[cursor] != '#') {
            while (cursor < line_end) {
                while (cursor < line_end and (source[cursor] == ' ' or source[cursor] == '\t' or source[cursor] == '\r')) cursor += 1;
                if (cursor >= line_end or source[cursor] == '#') break;
                const token_start = cursor;
                while (cursor < line_end and source[cursor] != ' ' and source[cursor] != '\t' and source[cursor] != '\r') cursor += 1;
                const token = source[token_start..cursor];
                const equals = std.mem.indexOfScalar(u8, token, '=') orelse continue;
                const key = token[0..equals];
                if (std.mem.eql(u8, key, "text")) break;
                const kind = assetKindForKey(key) orelse continue;
                const value_start = token_start + equals + 1;
                if (value_start >= cursor) continue;
                try refs.append(allocator, .{
                    .kind = kind,
                    .path = source[value_start..cursor],
                    .value_start = value_start,
                    .value_end = cursor,
                    .source_line = line_number,
                });
            }
        }
        line_start = if (line_end < source.len) line_end + 1 else source.len;
    }
    return .{ .items = try refs.toOwnedSlice(allocator), .allocator = allocator };
}

fn countUniqueAssetPaths(refs: []const AssetReference) usize {
    var count: usize = 0;
    for (refs, 0..) |reference, index| {
        var seen = false;
        for (refs[0..index]) |previous| {
            if (std.mem.eql(u8, previous.path, reference.path)) {
                seen = true;
                break;
            }
        }
        if (!seen) count += 1;
    }
    return count;
}

pub const PortableAsset = struct {
    source_path: []u8,
    absolute_path: []u8,
    portable_path: []u8,

    fn deinit(self: PortableAsset, allocator: std.mem.Allocator) void {
        allocator.free(self.source_path);
        allocator.free(self.absolute_path);
        allocator.free(self.portable_path);
    }
};

pub const PortablePlan = struct {
    allocator: std.mem.Allocator,
    rewritten_source: []u8,
    assets: []PortableAsset,

    pub fn deinit(self: *PortablePlan) void {
        self.allocator.free(self.rewritten_source);
        for (self.assets) |asset| asset.deinit(self.allocator);
        self.allocator.free(self.assets);
        self.* = undefined;
    }
};

fn sanitizeBasename(output: []u8, path: []const u8) []const u8 {
    const basename = std.fs.path.basename(path);
    var len: usize = 0;
    for (basename) |byte| {
        if (len >= output.len) break;
        output[len] = if (std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '-' or byte == '_') byte else '_';
        len += 1;
    }
    if (len == 0) {
        const fallback = "asset";
        @memcpy(output[0..fallback.len], fallback);
        return output[0..fallback.len];
    }
    return output[0..len];
}

fn portableNameCollides(assets: []const PortableAsset, portable_path: []const u8) bool {
    for (assets) |asset| if (std.mem.eql(u8, asset.portable_path, portable_path)) return true;
    return false;
}

fn uniquePortablePath(allocator: std.mem.Allocator, assets: []const PortableAsset, source_path: []const u8) ![]u8 {
    var basename_buffer: [256]u8 = undefined;
    const basename = sanitizeBasename(&basename_buffer, source_path);
    var candidate = try std.fmt.allocPrint(allocator, "assets/{s}", .{basename});
    if (!portableNameCollides(assets, candidate)) return candidate;
    allocator.free(candidate);
    const extension = std.fs.path.extension(basename);
    const stem = basename[0 .. basename.len - extension.len];
    const hash = std.hash.Wyhash.hash(0x73686f7774696d65, source_path);
    candidate = try std.fmt.allocPrint(allocator, "assets/{s}-{x:0>8}{s}", .{ stem, @as(u32, @truncate(hash)), extension });
    var suffix: usize = 2;
    while (portableNameCollides(assets, candidate)) : (suffix += 1) {
        allocator.free(candidate);
        candidate = try std.fmt.allocPrint(allocator, "assets/{s}-{x:0>8}-{d}{s}", .{ stem, @as(u32, @truncate(hash)), suffix, extension });
    }
    return candidate;
}

fn assetForSourcePath(assets: []const PortableAsset, path: []const u8) ?usize {
    for (assets, 0..) |asset, index| if (std.mem.eql(u8, asset.source_path, path)) return index;
    return null;
}

pub fn planPortable(
    allocator: std.mem.Allocator,
    source: []const u8,
    deck_path: []const u8,
) !PortablePlan {
    var refs = try collectAssetReferences(allocator, source);
    defer refs.deinit(allocator);
    var assets = std.ArrayList(PortableAsset).empty;
    errdefer {
        for (assets.items) |asset| asset.deinit(allocator);
        assets.deinit(allocator);
    }
    const deck_dir = std.fs.path.dirname(deck_path) orelse ".";
    for (refs.items) |reference| {
        if (assetForSourcePath(assets.items, reference.path) != null) continue;
        const absolute = if (std.fs.path.isAbsolute(reference.path))
            try allocator.dupe(u8, reference.path)
        else
            try std.fs.path.resolve(allocator, &.{ deck_dir, reference.path });
        errdefer allocator.free(absolute);
        const portable_path = try uniquePortablePath(allocator, assets.items, reference.path);
        errdefer allocator.free(portable_path);
        try assets.append(allocator, .{
            .source_path = try allocator.dupe(u8, reference.path),
            .absolute_path = absolute,
            .portable_path = portable_path,
        });
    }

    var rewritten = std.ArrayList(u8).empty;
    errdefer rewritten.deinit(allocator);
    var cursor: usize = 0;
    for (refs.items) |reference| {
        try rewritten.appendSlice(allocator, source[cursor..reference.value_start]);
        const asset_index = assetForSourcePath(assets.items, reference.path).?;
        try rewritten.appendSlice(allocator, assets.items[asset_index].portable_path);
        cursor = reference.value_end;
    }
    try rewritten.appendSlice(allocator, source[cursor..]);
    return .{
        .allocator = allocator,
        .rewritten_source = try rewritten.toOwnedSlice(allocator),
        .assets = try assets.toOwnedSlice(allocator),
    };
}

pub const PortableResult = struct {
    deck_path: []u8,
    asset_count: usize,
    allocator: std.mem.Allocator,
    pub fn deinit(self: *PortableResult) void {
        self.allocator.free(self.deck_path);
        self.* = undefined;
    }
};

/// Create a new, non-overwriting folder containing a normal `.sld` and normal
/// assets. The original source and asset files are never changed.
pub fn createPortableFolder(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: []const u8,
    deck_path: []const u8,
    destination: []const u8,
) !PortableResult {
    if (destination.len == 0) return error.InvalidPortableDestination;
    var plan = try planPortable(allocator, source, deck_path);
    defer plan.deinit();
    const cwd = std.Io.Dir.cwd();
    try cwd.createDir(io, destination, .default_dir);
    const assets_dir = try std.fs.path.join(allocator, &.{ destination, "assets" });
    defer allocator.free(assets_dir);
    try cwd.createDirPath(io, assets_dir);
    for (plan.assets) |asset| {
        const target = try std.fs.path.join(allocator, &.{ destination, asset.portable_path });
        defer allocator.free(target);
        try std.Io.Dir.copyFile(cwd, asset.absolute_path, cwd, target, io, .{ .replace = false, .make_path = true });
    }
    const original_name = std.fs.path.basename(deck_path);
    const deck_name = if (std.mem.endsWith(u8, original_name, ".sld")) original_name else "show.sld";
    const output_deck = try std.fs.path.join(allocator, &.{ destination, deck_name });
    errdefer allocator.free(output_deck);
    try cwd.writeFile(io, .{ .sub_path = output_deck, .data = plan.rewritten_source, .flags = .{ .exclusive = true } });
    return .{ .deck_path = output_deck, .asset_count = plan.assets.len, .allocator = allocator };
}

pub fn jsonAlloc(allocator: std.mem.Allocator, report: *const Report) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer, .options = .{ .whitespace = .indent_2 } };
    try json.beginObject();
    try json.objectField("schema");
    try json.write(@as(u32, 1));
    try json.objectField("ready");
    try json.write(report.ready());
    try json.objectField("summary");
    try json.write(report.summary);
    try json.objectField("truncated");
    try json.write(report.truncated);
    try json.objectField("findings");
    try json.beginArray();
    for (report.findings.items) |finding| {
        try json.beginObject();
        try json.objectField("severity");
        try json.write(severityName(finding.severity));
        try json.objectField("category");
        try json.write(@tagName(finding.category));
        try json.objectField("code");
        try json.write(@tagName(finding.code));
        try json.objectField("slide");
        try json.write(if (finding.slide_index) |index| index + 1 else null);
        try json.objectField("morph_state");
        try json.write(if (finding.morph_state) |index| index + 1 else null);
        try json.objectField("owner_identity");
        try json.write(finding.owner_identity);
        try json.objectField("source_line");
        try json.write(finding.source_line);
        try json.objectField("title");
        try json.write(finding.title);
        try json.objectField("detail");
        try json.write(finding.detail);
        try json.endObject();
    }
    try json.endArray();
    try json.endObject();
    try output.writer.writeByte('\n');
    return output.toOwnedSlice();
}

test "asset discovery covers image video fonts overrides and ignores text" {
    const source =
        "@font=fonts/talk.ttf\n" ++
        "@push card img=art/hero.png text=literal vid=nope.mp4\n" ++
        "@box vid=clips/demo.mp4\n" ++
        "@set hero img=../alternate.png\n" ++
        "# @box img=comment.png\n";
    var refs = try collectAssetReferences(std.testing.allocator, source);
    defer refs.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 4), refs.items.len);
    try std.testing.expectEqual(AssetKind.font, refs.items[0].kind);
    try std.testing.expectEqualStrings("art/hero.png", refs.items[1].path);
    try std.testing.expectEqualStrings("clips/demo.mp4", refs.items[2].path);
    try std.testing.expectEqualStrings("../alternate.png", refs.items[3].path);
}

test "text overflow uses unrotated painted coordinates for rotated owners" {
    const item = slides.SlideItem{
        .kind = .textbox,
        .position = .{ .x = 200, .y = 300 },
        .size = .{ .x = 320, .y = 120 },
        .rotation = -12,
    };
    const painted = rl.Rectangle{
        .x = item.position.x,
        .y = item.position.y,
        .width = item.size.x,
        .height = item.size.y,
    };
    try std.testing.expect(!textOverflows(item, painted));

    var escaped = painted;
    escaped.width += 3;
    try std.testing.expect(textOverflows(item, escaped));
}

test "portable planning rewrites collisions deterministically and leaves source ordinary" {
    const source =
        "@font=/external/A/talk.ttf\n" ++
        "@slide\n" ++
        "@box img=one/hero.png\n" ++
        "@box vid=two/hero.png\n" ++
        "@box img=one/hero.png\n";
    var plan = try planPortable(std.testing.allocator, source, "/talk/deck.sld");
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 3), plan.assets.len);
    try std.testing.expect(std.mem.indexOf(u8, plan.rewritten_source, "@font=assets/talk.ttf") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan.rewritten_source, "img=assets/hero.png") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan.rewritten_source, "vid=assets/hero-") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan.rewritten_source, "/external/") == null);
}

test "report JSON is stable and secret-free by construction" {
    var report = Report.init(std.testing.allocator);
    defer report.deinit();
    try report.add(.warning, .network, .presenter_unavailable, null, null, null, null, "Presenter not paired", "Optional");
    const encoded = try jsonAlloc(std.testing.allocator, &report);
    defer std.testing.allocator.free(encoded);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"ready\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"severity\": \"warning\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "error_") == null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "capability") == null);
}

test "Presenter health turns measured venue failures into an actionable warning" {
    var report = Report.init(std.testing.allocator);
    defer report.deinit();
    try analyzeRuntime(&report, .{
        .monitor_count = 1,
        .display_width = 1920,
        .display_height = 1080,
        .refresh_rate = 60,
        .presenter_running = true,
        .presenter_reachable = true,
        .presenter_connected = true,
        .presenter_health_samples = 44,
        .presenter_health_p95_ms = 82,
        .presenter_health_failures = 1,
    });
    try std.testing.expectEqual(@as(usize, 1), report.summary.warnings);
    try std.testing.expectEqual(Code.presenter_health_failures, report.findings.items[0].code);
}
