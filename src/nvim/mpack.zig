const std = @import("std");

pub const c = @import("mpack_c");

test "pinned MPack C implementation is linked with extension support" {
    try std.testing.expectEqual(@as(c_int, 1), c.MPACK_EXTENSIONS);
    try std.testing.expectEqualStrings("mpack_ok", std.mem.span(c.mpack_error_to_string(c.mpack_ok)));
}
