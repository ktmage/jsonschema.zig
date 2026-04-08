const std = @import("std");
const Regex = @import("regex/matcher.zig").Regex;

/// ECMA-262 compatible regex — Pure Zig implementation.
pub const EcmaRegex = struct {
    inner: Regex,

    /// Compile an ECMA-262 pattern. Returns null if compilation fails.
    pub fn compile(pattern: []const u8, allocator: std.mem.Allocator) ?EcmaRegex {
        const inner = Regex.compile(allocator, pattern) catch return null;
        return .{ .inner = inner };
    }

    /// Check if a string matches this pattern (unanchored search).
    pub fn matches(self: *const EcmaRegex, str: []const u8) bool {
        return self.inner.matches(str);
    }

    /// Free compiled regex resources.
    pub fn deinit(self: *EcmaRegex) void {
        self.inner.deinit();
    }
};
