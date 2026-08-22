const std = @import("std");
const rl = @import("raylib");
const pathRelativeTo = @import("utils.zig").pathRelativeTo;
const svg = @cImport({
    @cInclude("svg_rasterizer.h");
});

allocator: std.mem.Allocator,
/// Optional only for renderer unit tests. The app supplies its I/O backend so
/// missing/unreadable files can be distinguished from image decode failures.
io: ?std.Io = null,
path2tex: std.StringHashMap(TextureWithDimensions),

const Self = @This();

pub const TextureWithDimensions = struct {
    texture: rl.Texture2D,
    natural_width: i32,
    natural_height: i32,
};

pub fn init(alloc: std.mem.Allocator) Self {
    return .{
        .allocator = alloc,
        .path2tex = std.StringHashMap(TextureWithDimensions).init(alloc),
    };
}

pub fn getImageTexture(
    self: *Self,
    p: []const u8,
    refpath: ?[]const u8,
    requested_size: ?rl.Vector2,
) !?TextureWithDimensions {
    const realpath = try pathRelativeTo(p, refpath);
    const is_svg = std.ascii.eqlIgnoreCase(std.fs.path.extension(realpath), ".svg");
    const requested_width = requestedDimension(if (requested_size) |size| size.x else 0);
    const requested_height = requestedDimension(if (requested_size) |size| size.y else 0);
    const cache_key = if (is_svg)
        try std.fmt.allocPrint(self.allocator, "{s}#svg:{d}x{d}", .{ realpath, requested_width, requested_height })
    else
        try self.allocator.dupe(u8, realpath);
    defer self.allocator.free(cache_key);
    if (self.path2tex.get(cache_key)) |cached| return cached;

    if (self.io) |io| {
        {
            const file = try std.Io.Dir.cwd().openFile(io, realpath, .{});
            defer file.close(io);
            _ = try file.stat(io);
        }
    }

    // New image, needs to be loaded first. SVG is rasterized in-process at a
    // box-aware 2x resolution, so Studio zoom, HiDPI presentation, and export
    // do not depend on an external converter or a tiny intrinsic bitmap.
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const zpath = try std.fmt.bufPrintZ(&path_buffer, "{s}", .{realpath});
    const result: TextureWithDimensions = if (is_svg) svg_result: {
        var raster: svg.RayslidesSvgImage = std.mem.zeroes(svg.RayslidesSvgImage);
        if (svg.rayslides_svg_rasterize_file(zpath.ptr, requested_width, requested_height, &raster) != 0 or
            raster.pixels == null or raster.width <= 0 or raster.height <= 0)
            return error.InvalidSvg;
        defer svg.rayslides_svg_image_free(&raster);
        const image = rl.Image{
            .data = @ptrCast(raster.pixels),
            .width = raster.width,
            .height = raster.height,
            .mipmaps = 1,
            .format = .uncompressed_r8g8b8a8,
        };
        const texture = try rl.loadTextureFromImage(image);
        rl.setTextureFilter(texture, .bilinear);
        break :svg_result .{
            .texture = texture,
            .natural_width = raster.natural_width,
            .natural_height = raster.natural_height,
        };
    } else bitmap_result: {
        const image = try rl.loadImage(zpath);
        defer rl.unloadImage(image);
        break :bitmap_result .{
            .texture = try rl.loadTextureFromImage(image),
            .natural_width = image.width,
            .natural_height = image.height,
        };
    };
    try self.path2tex.put(try self.allocator.dupe(u8, cache_key), result);
    return result;
}

fn requestedDimension(value: f32) i32 {
    if (!std.math.isFinite(value) or value <= 0) return 0;
    return @intFromFloat(@ceil(@min(value, @as(f32, 4096))));
}

pub fn deinit(self: *Self) void {
    var it = self.path2tex.iterator();
    while (it.next()) |entry| {
        const texture = entry.value_ptr.texture;
        const path = entry.key_ptr.*;
        rl.unloadTexture(texture);
        self.allocator.free(path);
    }
    self.path2tex.deinit();
}

test "bundled SVG rasterizer produces box-aware RGBA pixels without external tools" {
    var raster: svg.RayslidesSvgImage = std.mem.zeroes(svg.RayslidesSvgImage);
    try std.testing.expectEqual(
        @as(c_int, 0),
        svg.rayslides_svg_rasterize_file("testslides/assets/studio-vector.svg", 320, 180, &raster),
    );
    defer svg.rayslides_svg_image_free(&raster);
    try std.testing.expectEqual(@as(c_int, 640), raster.natural_width);
    try std.testing.expectEqual(@as(c_int, 360), raster.natural_height);
    try std.testing.expect(raster.width >= 640 and raster.height >= 360);
    const byte_count: usize = @intCast(raster.width * raster.height * 4);
    const pixels: [*]const u8 = @ptrCast(raster.pixels);
    var has_visible_pixel = false;
    var index: usize = 3;
    while (index < byte_count) : (index += 4) {
        if (pixels[index] != 0) {
            has_visible_pixel = true;
            break;
        }
    }
    try std.testing.expect(has_visible_pixel);
}
