const std = @import("std");

pub const c = @cImport({
    // Zig's translate-c currently tokenizes MPack's GCC `_Pragma` warning
    // wrapper as declarations. The compiled C sources still see Clang's
    // normal predefined macros; only the generated binding skips that wrapper.
    // Preload MPack's standard headers while the normal compiler macros are
    // present so undefining them below cannot perturb glibc's type choices.
    @cInclude("stddef.h");
    @cInclude("stdint.h");
    @cInclude("stdbool.h");
    @cInclude("inttypes.h");
    @cInclude("limits.h");
    @cInclude("string.h");
    @cInclude("stdlib.h");
    @cInclude("stdio.h");
    @cInclude("errno.h");
    @cInclude("stdarg.h");
    @cUndef("__GNUC__");
    @cUndef("__GNUC_MINOR__");
    @cDefine("MPACK_EXTENSIONS", "1");
    @cInclude("mpack.h");
});

test "pinned MPack C implementation is linked with extension support" {
    try std.testing.expectEqual(@as(c_int, 1), c.MPACK_EXTENSIONS);
    try std.testing.expectEqualStrings("mpack_ok", std.mem.span(c.mpack_error_to_string(c.mpack_ok)));
}
