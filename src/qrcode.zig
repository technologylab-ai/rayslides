const std = @import("std");

const c = @cImport({
    @cInclude("qrcodegen.h");
});

pub const Code = struct {
    temp: [c.qrcodegen_BUFFER_LEN_MAX]u8 = @splat(0),
    modules: [c.qrcodegen_BUFFER_LEN_MAX]u8 = @splat(0),
    encoded_url: [256:0]u8 = @splat(0),
    encoded_len: u16 = 0,
    matrix_size: i32 = 0,

    pub fn ensure(self: *Code, url: []const u8) bool {
        if (url.len == 0 or url.len > 256) return false;
        if (self.encoded_len == url.len and std.mem.eql(u8, self.encoded_url[0..self.encoded_len], url)) return self.matrix_size > 0;

        @memset(&self.encoded_url, 0);
        @memcpy(self.encoded_url[0..url.len], url);
        self.encoded_len = @intCast(url.len);
        const success = c.qrcodegen_encodeText(
            &self.encoded_url,
            &self.temp,
            &self.modules,
            c.qrcodegen_Ecc_MEDIUM,
            c.qrcodegen_VERSION_MIN,
            c.qrcodegen_VERSION_MAX,
            c.qrcodegen_Mask_AUTO,
            true,
        );
        self.matrix_size = if (success) c.qrcodegen_getSize(&self.modules) else 0;
        return success;
    }

    pub fn size(self: *const Code) i32 {
        return self.matrix_size;
    }

    pub fn module(self: *const Code, x: i32, y: i32) bool {
        if (self.matrix_size <= 0 or x < 0 or y < 0 or x >= self.matrix_size or y >= self.matrix_size) return false;
        return c.qrcodegen_getModule(&self.modules, x, y);
    }
};

test "QR codes are generated and cached" {
    var code = Code{};
    try std.testing.expect(code.ensure("http://rayslides.local:7331/"));
    try std.testing.expect(code.size() >= 21);
    const size = code.size();
    try std.testing.expect(code.ensure("http://rayslides.local:7331/"));
    try std.testing.expectEqual(size, code.size());
    try std.testing.expect(code.module(0, 0));
}
