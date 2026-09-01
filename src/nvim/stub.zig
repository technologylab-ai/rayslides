const std = @import("std");

/// Compile-time feature state exposed through the same module name as the real
/// integration. Application code can keep one narrow host API while the build
/// selects this zero-dependency implementation.
pub const compiled = false;

pub const StartError = error{NeovimSupportDisabled};

pub fn requireCompiledSupport() StartError!void {
    return error.NeovimSupportDisabled;
}

test "disabled Neovim module has no runtime support" {
    try std.testing.expect(!compiled);
    try std.testing.expectError(error.NeovimSupportDisabled, requireCompiledSupport());
}
