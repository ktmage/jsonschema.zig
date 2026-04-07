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

        // Fast path: pure ASCII input can use 8-bit (Latin-1) mode directly
        if (!hasNonAscii(str)) {
            const result = c.lre_exec(
                capture,
                self.bytecode,
                @ptrCast(str.ptr),
                0, // start index
                @intCast(str.len),
                0, // cbuf_type: 0 = 8-bit (Latin-1)
                null, // opaque
            );
            return result == 1;
        }

        // Non-ASCII: decode UTF-8 to UTF-16LE for correct Unicode matching.
        // libregexp compiled patterns use Unicode codepoints, so we must
        // present non-ASCII input as UTF-16 (cbuf_type=1).
        var utf16_buf: [2048]u16 = undefined;
        const utf16_len = utf8ToUtf16(&utf16_buf, str) orelse return false;

        const result = c.lre_exec(
            capture,
            self.bytecode,
            @ptrCast(&utf16_buf),
            0, // start index
            @intCast(utf16_len),
            1, // cbuf_type: 1 = 16-bit (UTF-16)
            null, // opaque
        );
        return result == 1;
    }

    /// Free the compiled bytecode.
    pub fn deinit(self: *EcmaRegex) void {
        std.c.free(self.bytecode);
    }

    /// Check if any byte in the string is non-ASCII (>= 0x80).
    fn hasNonAscii(s: []const u8) bool {
        for (s) |b| {
            if (b >= 0x80) return true;
        }
        return false;
    }

    /// Convert UTF-8 to UTF-16LE in a fixed buffer. Returns the number of
    /// UTF-16 code units, or null if the buffer is too small or input is invalid.
    fn utf8ToUtf16(buf: []u16, utf8: []const u8) ?usize {
        var i: usize = 0;
        var out: usize = 0;
        while (i < utf8.len) {
            if (out >= buf.len) return null;
            const b = utf8[i];
            if (b < 0x80) {
                buf[out] = @intCast(b);
                out += 1;
                i += 1;
            } else if (b < 0xC0) {
                // Invalid continuation byte at start
                return null;
            } else if (b < 0xE0) {
                if (i + 1 >= utf8.len) return null;
                const cp: u32 = (@as(u32, b & 0x1F) << 6) | @as(u32, utf8[i + 1] & 0x3F);
                buf[out] = @intCast(cp);
                out += 1;
                i += 2;
            } else if (b < 0xF0) {
                if (i + 2 >= utf8.len) return null;
                const cp: u32 = (@as(u32, b & 0x0F) << 12) | (@as(u32, utf8[i + 1] & 0x3F) << 6) | @as(u32, utf8[i + 2] & 0x3F);
                buf[out] = @intCast(cp);
                out += 1;
                i += 3;
            } else {
                // 4-byte sequence (surrogate pair)
                if (i + 3 >= utf8.len) return null;
                if (out + 1 >= buf.len) return null;
                const cp: u32 = (@as(u32, b & 0x07) << 18) | (@as(u32, utf8[i + 1] & 0x3F) << 12) | (@as(u32, utf8[i + 2] & 0x3F) << 6) | @as(u32, utf8[i + 3] & 0x3F);
                const adjusted = cp - 0x10000;
                buf[out] = @intCast(0xD800 + (adjusted >> 10));
                buf[out + 1] = @intCast(0xDC00 + (adjusted & 0x3FF));
                out += 2;
                i += 4;
            }
        }
        return out;
    }
};
