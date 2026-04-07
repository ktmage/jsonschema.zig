const std = @import("std");
const c = @cImport({
    @cInclude("libregexp.h");
});

/// ECMA-262 compatible regex compiled via QuickJS libregexp.
pub const EcmaRegex = struct {
    bytecode: [*]u8,

    /// Compile an ECMA-262 pattern. Returns null if compilation fails.
    pub fn compile(pattern: []const u8, allocator: std.mem.Allocator) ?EcmaRegex {
        const pat_z = allocator.dupeZ(u8, pattern) catch return null;
        defer allocator.free(pat_z);

        var error_msg: [64]u8 = undefined;
        var plen: c_int = undefined;

        const bc = c.lre_compile(
            &plen,
            @ptrCast(&error_msg),
            error_msg.len,
            pat_z.ptr,
            @intCast(pattern.len),
            0, // flags
            null, // opaque
        );

        if (bc == null) return null;
        return .{ .bytecode = bc.? };
    }

    /// Check if a string matches this pattern (unanchored search like ECMA test()).
    pub fn matches(self: *const EcmaRegex, str: []const u8) bool {
        const capture_count = c.lre_get_capture_count(self.bytecode);
        const capture_size: usize = @intCast(capture_count * 2);

        // Stack-allocate capture buffer
        var capture_buf: [64][*c]u8 = undefined;
        const capture: [*c][*c]u8 = if (capture_size <= 64) &capture_buf else return false;

        const result = c.lre_exec(
            capture,
            self.bytecode,
            @ptrCast(str.ptr),
            0, // start index
            @intCast(str.len),
            0, // cbuf_type: 0 = 8-bit
            null, // opaque
        );
        return result == 1;
    }

    /// Free the compiled bytecode.
    pub fn deinit(self: *EcmaRegex) void {
        std.c.free(self.bytecode);
    }
};
