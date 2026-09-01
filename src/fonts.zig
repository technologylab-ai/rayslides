const std = @import("std");
const rl = @import("raylib");
const pathRelativeTo = @import("utils.zig").pathRelativeTo;

const log = std.log.scoped(.fonts);

pub const FontStyle = enum {
    normal,
    bold,
    italic,
    bolditalic,
    zig,
};

pub const FontLoadDesc = struct {
    ttf_filn: []const u8,
};

// this is a var because raylib wrapper demands a []u32
// The character set to load
pub var default_fontchars = [_]i32{
    // 95 standard printable ASCII chars
    32,  33,  34,  35,  36,  37,  38,  39,  40,  41,  42,  43,  44,  45,  46,
    47,  48,  49,  50,  51,  52,  53,  54,  55,  56,  57,  58,  59,  60,  61,
    62,  63,  64,  65,  66,  67,  68,  69,  70,  71,  72,  73,  74,  75,  76,
    77,  78,  79,  80,  81,  82,  83,  84,  85,  86,  87,  88,  89,  90,  91,
    92,  93,  94,  95,  96,  97,  98,  99,  100, 101, 102, 103, 104, 105, 106,
    107, 108, 109, 110, 111, 112, 113, 114, 115, 116, 117, 118, 119, 120, 121,
    122, 123, 124, 125, 126,

    // Custom characters (German umlauts, Eszett, Euro, Bullet)
    196, // Ä
    214, // Ö
    220, // Ü
    228, // ä
    246, // ö
    252, // ü
    223, // ß
    8364, // €
    8226, // •,

    // --- Common Punctuation & Symbols ---
    8211, // – (en dash)
    8212, // — (em dash)
    8216, // ‘ (left single quote)
    8217, // ’ (right single quote)
    8220, // “ (left double quote)
    8221, // ” (right double quote)
    8230, // … (ellipsis)
    183, // · (middle dot, used by Crowdplay poll results)
    169, // © (copyright)
    174, // ® (registered trademark)
    8482, // ™ (trademark)

    // --- Mathematical & Scientific ---
    176, // ° (degree symbol)
    177, // ± (plus-minus)
    181, // µ (micro sign / mu)
    215, // × (multiplication sign)
    247, // ÷ (division sign)
    8730, // √ (square root)
    8734, // ∞ (infinity)
    8747, // ∫ (integral)
    8776, // ≈ (almost equal to)
    8800, // ≠ (not equal to)
    8804, // ≤ (less than or equal to)
    8805, // ≥ (greater than or equal to)
    916, // Δ (uppercase delta)
    960, // π (lowercase pi)
    8592, // ← (left arrow)
    8594, // → (right arrow)
    8593, // ↑ (up arrow)
    8595, // ↓ (down arrow)
};

// Custom presentation fonts frequently omit arrows even when those
// codepoints are requested. Keep a small embedded Calibri atlas as a stable
// fallback for the directional glyphs used in diagrams and navigation hints.
pub var symbol_fontchars = [_]i32{
    '?',
    0x2190, // ←
    0x2191, // ↑
    0x2192, // →
    0x2193, // ↓
    0x2194, // ↔
    0x2195, // ↕
    0x2196, // ↖
    0x2197, // ↗
    0x2198, // ↘
    0x2199, // ↙
};

// A deliberately useful, bounded emoji set keeps the generated GPU atlas
// small. Noto Emoji is monochrome here, so glyphs inherit the surrounding
// text color and work with opacity, shadows, and semantic morphs.
pub var emoji_fontchars = [_]i32{
    0x2139, // ℹ information
    0x21a9, // ↩ return arrow
    0x21aa, // ↪ return arrow
    0x23e9, // ⏩ fast-forward
    0x23ea, // ⏪ rewind
    0x23ed, // ⏭ next
    0x23ee, // ⏮ previous
    0x23f0, // ⏰ alarm
    0x23f8, // ⏸ pause
    0x23f9, // ⏹ stop
    0x23fa, // ⏺ record
    0x25b6, // ▶ play
    0x25c0, // ◀ reverse
    0x2600, // ☀ sun
    0x2601, // ☁ cloud
    0x2602, // ☂ umbrella
    0x2603, // ☃ snowman
    0x260e, // ☎ telephone
    0x2611, // ☑ checked box
    0x2615, // ☕ coffee
    0x267b, // ♻ recycle
    0x2699, // ⚙ gear
    0x26a0, // ⚠ warning
    0x26a1, // ⚡ lightning
    0x2705, // ✅ check
    0x2714, // ✔ heavy check
    0x2716, // ✖ heavy cross
    0x2728, // ✨ sparkles
    0x274c, // ❌ cross mark
    0x2753, // ❓ question
    0x2757, // ❗ exclamation
    0x2764, // ❤ heart
    0x27a1, // ➡ right arrow
    0x2b50, // ⭐ star
    0x1f389, // 🎉 party popper
    0x1f3af, // 🎯 target
    0x1f3c6, // 🏆 trophy
    0x1f440, // 👀 eyes
    0x1f44d, // 👍 thumbs up
    0x1f44e, // 👎 thumbs down
    0x1f44f, // 👏 clapping hands
    0x1f4a1, // 💡 light bulb
    0x1f4c8, // 📈 chart up
    0x1f4c9, // 📉 chart down
    0x1f4cc, // 📌 pushpin
    0x1f525, // 🔥 fire
    0x1f680, // 🚀 rocket
    0x1f6e0, // 🛠 tools
    0x1f916, // 🤖 robot
    0x1f9e0, // 🧠 brain
};

pub const FontConfig = struct {
    pub const Opts = struct {
        fontSize: i32 = 32,
        fontChars: ?[]i32 = default_fontchars[0..],
    };
    opts: Opts,
    gui_font_size: ?i32 = null,
    normal: ?FontLoadDesc = null,
    bold: ?FontLoadDesc = null,
    italic: ?FontLoadDesc = null,
    bolditalic: ?FontLoadDesc = null,
    zig: ?FontLoadDesc = null,
};

// rl.loadFontFromMemory(".ttf", fileData: ?[]const u8, fontSize: i32, null);
// rl.TextureFilter.bilinear

const fontdata_normal = @embedFile("assets/Calibri Light.ttf");
const fontdata_bold = @embedFile("assets/Calibri Regular.ttf"); // Calibri is the bold version of Calibri Light for us
const fontdata_italic = @embedFile("assets/Calibri Light Italic.ttf");
const fontdata_bolditalic = @embedFile("assets/Calibri Italic.ttf"); // Calibri is the bold version of Calibri Light for us
const fontdata_zig = @embedFile("assets/press-start-2p.ttf");
const fontdata_emoji = @embedFile("assets/NotoEmoji.ttf");

/// Load the same bounded monochrome emoji atlas used by presentation text as
/// an ordinary bitmap font. UI surfaces such as the embedded Neovim grid do
/// not run inside the presentation SDF shader, but should still render the
/// exact emoji repertoire Rayslides promises.
pub fn loadBitmapEmojiFont(requested_size: i32) !rl.Font {
    return rl.loadFontFromMemory(
        ".ttf",
        fontdata_emoji,
        requested_size,
        emoji_fontchars[0..],
    );
}

// SDF reconstruction, unlike a bitmap atlas, remains scale-independent; a
// 32-pixel source keeps startup and custom-font replacement responsive while
// the derivative-aware shader supplies crisp edges at every output scale.
const minimum_sdf_base_size: i32 = 32;
const sdf_fragment_shader: [:0]const u8 =
    "#version 330\n" ++
    "in vec2 fragTexCoord;\n" ++
    "in vec4 fragColor;\n" ++
    "uniform sampler2D texture0;\n" ++
    "uniform vec4 colDiffuse;\n" ++
    "out vec4 finalColor;\n" ++
    "void main() {\n" ++
    "  float distance = texture(texture0, fragTexCoord).a;\n" ++
    "  float smoothing = max(fwidth(distance), 0.0001);\n" ++
    "  float alpha = smoothstep(0.5 - smoothing, 0.5 + smoothing, distance);\n" ++
    "  finalColor = vec4(fragColor.rgb * colDiffuse.rgb, fragColor.a * colDiffuse.a * alpha);\n" ++
    "}\n";

fn sdfBaseSize(requested: i32) i32 {
    return @max(minimum_sdf_base_size, requested);
}

/// Raylib's ordinary TTF loader bakes a bitmap atlas at one size. Building the
/// same Font object from signed-distance glyph data keeps presentation text
/// crisp when Studio zoom, HiDPI output, fullscreen, or export scales it far
/// away from that source size.
fn loadSdfFontFromMemory(data: []const u8, requested_size: i32, codepoints: ?[]const i32) !rl.Font {
    const base_size = sdfBaseSize(requested_size);
    const glyphs = try rl.loadFontData(data, base_size, codepoints, .sdf);
    errdefer rl.unloadFontData(glyphs);
    const atlas = try rl.genImageFontAtlas(glyphs, base_size, 0, 1);
    errdefer {
        rl.unloadImage(atlas[0]);
        rl.memFree(@ptrCast(atlas[1].ptr));
    }
    const texture = try rl.loadTextureFromImage(atlas[0]);
    rl.unloadImage(atlas[0]);
    rl.setTextureFilter(texture, .bilinear);
    return .{
        .baseSize = base_size,
        .glyphCount = @intCast(glyphs.len),
        .glyphPadding = 0,
        .texture = texture,
        .recs = atlas[1].ptr,
        .glyphs = glyphs.ptr,
    };
}

fn loadSdfFontFile(path: [:0]const u8, requested_size: i32, codepoints: ?[]const i32) !rl.Font {
    const data = try rl.loadFileData(path);
    defer rl.unloadFileData(data);
    return loadSdfFontFromMemory(data, requested_size, codepoints);
}

// gui font = try rl.getDefaultFont()

pub const AvailableFonts = struct {
    normal: rl.Font = undefined,
    bold: rl.Font = undefined,
    italic: rl.Font = undefined,
    bolditalic: rl.Font = undefined,
    zig: rl.Font = undefined,
    symbols: rl.Font = undefined,
    emoji: rl.Font = undefined,
    sdf_shader: rl.Shader = undefined,
    /// Optical correction for the display/code face. Fonts such as Press
    /// Start 2P use almost the entire em square while presentation fonts use
    /// considerably less, so equal nominal sizes do not look equal.
    zig_size_scale: f32 = 1.0,
    /// Vertical correction, expressed as a fraction of the nominal size, that
    /// aligns the code face's H baseline with the body face's H baseline.
    zig_baseline_offset: f32 = 0.0,

    pub fn init(opts: FontConfig.Opts) !AvailableFonts {
        const normal = try loadSdfFontFromMemory(fontdata_normal, opts.fontSize, opts.fontChars);
        errdefer rl.unloadFont(normal);
        const bold = try loadSdfFontFromMemory(fontdata_bold, opts.fontSize, opts.fontChars);
        errdefer rl.unloadFont(bold);
        const italic = try loadSdfFontFromMemory(fontdata_italic, opts.fontSize, opts.fontChars);
        errdefer rl.unloadFont(italic);
        const bolditalic = try loadSdfFontFromMemory(fontdata_bolditalic, opts.fontSize, opts.fontChars);
        errdefer rl.unloadFont(bolditalic);
        const zig = try loadSdfFontFromMemory(fontdata_zig, opts.fontSize, opts.fontChars);
        errdefer rl.unloadFont(zig);
        const symbols = try loadSdfFontFromMemory(fontdata_normal, opts.fontSize, symbol_fontchars[0..]);
        errdefer rl.unloadFont(symbols);
        const emoji = try loadSdfFontFromMemory(fontdata_emoji, opts.fontSize, emoji_fontchars[0..]);
        errdefer rl.unloadFont(emoji);
        const shader = try rl.loadShaderFromMemory(null, sdf_fragment_shader);
        errdefer rl.unloadShader(shader);
        var ret: AvailableFonts = .{
            .normal = normal,
            .bold = bold,
            .italic = italic,
            .bolditalic = bolditalic,
            .zig = zig,
            .symbols = symbols,
            .emoji = emoji,
            .sdf_shader = shader,
        };
        ret.updateStyleScales();
        return ret;
    }

    pub fn loadCustomFonts(self: *AvailableFonts, fontConfig: FontConfig, slideshow_filp: []const u8) !void {
        log.info("LOADING CUSTOM FONTS", .{});
        var temp_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (fontConfig.normal) |fontfile| {
            const realpath = try pathRelativeTo(fontfile.ttf_filn, slideshow_filp);
            const path = try std.fmt.bufPrintZ(&temp_buf, "{s}", .{realpath});
            const replacement = try loadSdfFontFile(path, fontConfig.opts.fontSize, fontConfig.opts.fontChars);
            rl.unloadFont(self.normal);
            self.normal = replacement;
            log.debug("Font {s} is ready: {}", .{ fontfile.ttf_filn, self.normal.isReady() });
        }

        if (fontConfig.bold) |fontfile| {
            const realpath = try pathRelativeTo(fontfile.ttf_filn, slideshow_filp);
            const path = try std.fmt.bufPrintZ(&temp_buf, "{s}", .{realpath});
            const replacement = try loadSdfFontFile(path, fontConfig.opts.fontSize, fontConfig.opts.fontChars);
            rl.unloadFont(self.bold);
            self.bold = replacement;
        }

        if (fontConfig.italic) |fontfile| {
            const realpath = try pathRelativeTo(fontfile.ttf_filn, slideshow_filp);
            const path = try std.fmt.bufPrintZ(&temp_buf, "{s}", .{realpath});
            const replacement = try loadSdfFontFile(path, fontConfig.opts.fontSize, fontConfig.opts.fontChars);
            rl.unloadFont(self.italic);
            self.italic = replacement;
        }

        if (fontConfig.bolditalic) |fontfile| {
            const realpath = try pathRelativeTo(fontfile.ttf_filn, slideshow_filp);
            const path = try std.fmt.bufPrintZ(&temp_buf, "{s}", .{realpath});
            const replacement = try loadSdfFontFile(path, fontConfig.opts.fontSize, fontConfig.opts.fontChars);
            rl.unloadFont(self.bolditalic);
            self.bolditalic = replacement;
        }

        if (fontConfig.zig) |fontfile| {
            const realpath = try pathRelativeTo(fontfile.ttf_filn, slideshow_filp);
            const path = try std.fmt.bufPrintZ(&temp_buf, "{s}", .{realpath});
            const replacement = try loadSdfFontFile(path, fontConfig.opts.fontSize, fontConfig.opts.fontChars);
            rl.unloadFont(self.zig);
            self.zig = replacement;
        }
        self.updateStyleScales();
    }

    pub fn displaySizeForStyle(self: *const AvailableFonts, style: FontStyle, nominal_size: f32) f32 {
        return nominal_size * switch (style) {
            .zig => self.zig_size_scale,
            else => 1.0,
        };
    }

    pub fn baselineOffsetForStyle(self: *const AvailableFonts, style: FontStyle, nominal_size: f32) f32 {
        return nominal_size * switch (style) {
            .zig => self.zig_baseline_offset,
            else => 0.0,
        };
    }

    fn updateStyleScales(self: *AvailableFonts) void {
        self.zig_size_scale = balancedDisplayScale(
            normalizedGlyphHeight(self.normal, 'H'),
            normalizedGlyphHeight(self.zig, 'H'),
        );
        self.zig_baseline_offset = balancedBaselineOffset(
            normalizedGlyphBottom(self.normal, 'H'),
            normalizedGlyphBottom(self.zig, 'H'),
            self.zig_size_scale,
        );
        log.info("code-font optical scale: {d:.2}, baseline shift: {d:.3}em", .{ self.zig_size_scale, self.zig_baseline_offset });
    }

    pub fn measureTextWithFallback(self: *const AvailableFonts, primary: rl.Font, text: []const u8, font_size: f32, spacing: f32) rl.Vector2 {
        if (text.len == 0) return .zero();
        var result = rl.Vector2{ .x = 0, .y = font_size };
        var line_width: f32 = 0;
        var line_glyphs: usize = 0;
        var byte_index: usize = 0;
        while (byte_index < text.len) {
            const codepoint = nextCodepoint(text, &byte_index);
            const choice = codepointFontChoice(codepoint);
            if (choice == .ignore) continue;
            if (codepoint == '\n') {
                result.x = @max(result.x, line_width);
                result.y += font_size;
                line_width = 0;
                line_glyphs = 0;
                continue;
            }
            if (line_glyphs > 0) line_width += spacing;
            line_width += glyphAdvance(self.fontForChoice(primary, choice), codepoint, font_size);
            line_glyphs += 1;
        }
        result.x = @max(result.x, line_width);
        return result;
    }

    pub fn drawTextWithFallback(
        self: *const AvailableFonts,
        primary: rl.Font,
        text: []const u8,
        position: rl.Vector2,
        font_size: f32,
        spacing: f32,
        tint: rl.Color,
    ) void {
        rl.beginShaderMode(self.sdf_shader);
        defer rl.endShaderMode();
        var cursor = position;
        var byte_index: usize = 0;
        while (byte_index < text.len) {
            const codepoint = nextCodepoint(text, &byte_index);
            const choice = codepointFontChoice(codepoint);
            if (choice == .ignore) continue;
            if (codepoint == '\n') {
                cursor.x = position.x;
                cursor.y += font_size;
                continue;
            }
            const font = self.fontForChoice(primary, choice);
            if (codepoint != ' ' and codepoint != '\t') {
                rl.drawTextCodepoint(font, codepoint, cursor, font_size, tint);
            }
            cursor.x += glyphAdvance(font, codepoint, font_size) + spacing;
        }
    }

    /// Whether the exact runtime face selected for a rendered text fragment
    /// contains `codepoint`. Showtime uses this after markdown/style
    /// expansion, so it reports the face rayslides will actually draw rather
    /// than guessing from the source text. Curated symbol and emoji
    /// codepoints are checked against their embedded fallback atlases.
    pub fn supportsCodepointForStyle(self: *const AvailableFonts, style: FontStyle, codepoint: u21) bool {
        const choice = codepointFontChoice(codepoint);
        if (choice == .ignore or codepoint == '\n' or codepoint == '\r' or codepoint == '\t' or codepoint == ' ') return true;
        const primary = switch (style) {
            .normal => self.normal,
            .bold => self.bold,
            .italic => self.italic,
            .bolditalic => self.bolditalic,
            .zig => self.zig,
        };
        return fontContainsCodepoint(self.fontForChoice(primary, choice), codepoint);
    }

    fn fontForChoice(self: *const AvailableFonts, primary: rl.Font, choice: CodepointFontChoice) rl.Font {
        return switch (choice) {
            .primary => primary,
            .symbol => self.symbols,
            .emoji => self.emoji,
            .ignore => unreachable,
        };
    }

    pub fn deinit(self: *AvailableFonts) void {
        rl.unloadFont(self.normal);
        rl.unloadFont(self.bold);
        rl.unloadFont(self.italic);
        rl.unloadFont(self.bolditalic);
        rl.unloadFont(self.zig);
        rl.unloadFont(self.symbols);
        rl.unloadFont(self.emoji);
        rl.unloadShader(self.sdf_shader);
    }
};

test "presentation font atlases use a derivative-aware SDF floor" {
    try std.testing.expectEqual(@as(i32, 32), sdfBaseSize(16));
    try std.testing.expectEqual(@as(i32, 96), sdfBaseSize(96));
    try std.testing.expect(std.mem.indexOf(u8, sdf_fragment_shader, "fwidth(distance)") != null);
}

pub const CodepointFontChoice = enum {
    primary,
    symbol,
    emoji,
    ignore,
};

fn codepointIn(chars: []const i32, codepoint: u21) bool {
    for (chars) |candidate| {
        if (candidate == codepoint) return true;
    }
    return false;
}

pub fn codepointFontChoice(codepoint: u21) CodepointFontChoice {
    // Variation selectors and joiners affect emoji shaping. Rayslides draws a
    // portable monochrome codepoint fallback, so they must not become tofu.
    if (codepoint == 0x200d or codepoint == 0xfe0e or codepoint == 0xfe0f) return .ignore;
    if (codepointIn(symbol_fontchars[0..], codepoint)) return .symbol;
    if (codepointIn(emoji_fontchars[0..], codepoint)) return .emoji;
    return .primary;
}

fn nextCodepoint(text: []const u8, byte_index: *usize) u21 {
    const sequence_len = std.unicode.utf8ByteSequenceLength(text[byte_index.*]) catch {
        byte_index.* += 1;
        return '?';
    };
    const end = byte_index.* + sequence_len;
    if (end > text.len) {
        byte_index.* += 1;
        return '?';
    }
    const codepoint = std.unicode.utf8Decode(text[byte_index.*..end]) catch {
        byte_index.* += 1;
        return '?';
    };
    byte_index.* = end;
    return codepoint;
}

fn glyphAdvance(font: rl.Font, codepoint: u21, font_size: f32) f32 {
    const index: usize = @intCast(rl.getGlyphIndex(font, codepoint));
    const scale = font_size / @as(f32, @floatFromInt(font.baseSize));
    const advance = font.glyphs[index].advanceX;
    if (advance != 0) return @as(f32, @floatFromInt(advance)) * scale;
    return font.recs[index].width * scale;
}

fn fontContainsCodepoint(font: rl.Font, codepoint: u21) bool {
    if (font.baseSize <= 0 or font.glyphCount <= 0) return false;
    const raw_index = rl.getGlyphIndex(font, codepoint);
    if (raw_index < 0 or raw_index >= font.glyphCount) return false;
    return font.glyphs[@intCast(raw_index)].value == codepoint;
}

fn normalizedGlyphHeight(font: rl.Font, codepoint: u21) f32 {
    if (font.baseSize <= 0 or font.glyphCount <= 0) return 0;
    const raw_index = rl.getGlyphIndex(font, codepoint);
    if (raw_index < 0 or raw_index >= font.glyphCount) return 0;
    const index: usize = @intCast(raw_index);
    return font.recs[index].height / @as(f32, @floatFromInt(font.baseSize));
}

fn normalizedGlyphBottom(font: rl.Font, codepoint: u21) f32 {
    if (font.baseSize <= 0 or font.glyphCount <= 0) return 0;
    const raw_index = rl.getGlyphIndex(font, codepoint);
    if (raw_index < 0 or raw_index >= font.glyphCount) return 0;
    const index: usize = @intCast(raw_index);
    const offset_y: f32 = @floatFromInt(font.glyphs[index].offsetY);
    return (offset_y + font.recs[index].height) / @as(f32, @floatFromInt(font.baseSize));
}

fn balancedDisplayScale(reference_height: f32, target_height: f32) f32 {
    if (reference_height <= 0 or target_height <= 0) return 1.0;
    // Keep code a touch more prominent than the surrounding face, but bound
    // the correction so unusual custom fonts never become tiny or enlarged.
    return std.math.clamp(reference_height / target_height * 1.08, 0.65, 1.0);
}

fn balancedBaselineOffset(reference_bottom: f32, target_bottom: f32, target_scale: f32) f32 {
    if (reference_bottom <= 0 or target_bottom <= 0 or target_scale <= 0) return 0;
    return std.math.clamp(reference_bottom - target_bottom * target_scale, -0.25, 0.25);
}

test "presentation glyphs select portable fallbacks" {
    try std.testing.expectEqual(CodepointFontChoice.primary, codepointFontChoice('A'));
    try std.testing.expectEqual(CodepointFontChoice.primary, codepointFontChoice('·'));
    try std.testing.expectEqual(CodepointFontChoice.symbol, codepointFontChoice('→'));
    try std.testing.expectEqual(CodepointFontChoice.emoji, codepointFontChoice('🚀'));
    try std.testing.expectEqual(CodepointFontChoice.emoji, codepointFontChoice('✅'));
    try std.testing.expectEqual(CodepointFontChoice.ignore, codepointFontChoice(0xfe0f));
}

test "optical code sizing balances oversized em boxes" {
    const scale = balancedDisplayScale(0.69, 1.0);
    try std.testing.expect(scale > 0.7);
    try std.testing.expect(scale < 0.8);
    try std.testing.expectEqual(@as(f32, 1.0), balancedDisplayScale(1.0, 0.5));
    try std.testing.expectEqual(@as(f32, 1.0), balancedDisplayScale(0, 1.0));
}

test "optical baseline correction aligns scaled glyph bottoms" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.125), balancedBaselineOffset(0.8, 0.9, 0.75), 0.0001);
    try std.testing.expectEqual(@as(f32, 0), balancedBaselineOffset(0, 0.9, 0.75));
}

test "fallback decoder preserves raylib invalid UTF-8 tolerance" {
    const text = [_]u8{ 0xe2, 'x' };
    var index: usize = 0;
    try std.testing.expectEqual(@as(u21, '?'), nextCodepoint(&text, &index));
    try std.testing.expectEqual(@as(usize, 1), index);
    try std.testing.expectEqual(@as(u21, 'x'), nextCodepoint(&text, &index));
    try std.testing.expectEqual(@as(usize, 2), index);
}
