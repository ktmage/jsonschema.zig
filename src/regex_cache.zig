const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @cImport(@cInclude("regex.h"));

/// A cache for compiled POSIX regex patterns.
/// Avoids repeated regcomp() calls for the same pattern string.
pub const RegexCache = struct {
    cache: std.StringHashMap(*c.regex_t),
    allocator: Allocator,

    pub fn init(allocator: Allocator) RegexCache {
        return .{
            .cache = std.StringHashMap(*c.regex_t).init(allocator),
            .allocator = allocator,
        };
    }

    /// Get a compiled regex for the given pattern, compiling and caching it if needed.
    /// Returns null if the pattern fails to compile.
    pub fn getOrCompile(self: *RegexCache, pattern: []const u8) ?*c.regex_t {
        // Check cache first
        if (self.cache.get(pattern)) |cached| {
            return cached;
        }

        // Compile new regex
        const pattern_z = self.allocator.dupeZ(u8, pattern) catch return null;
        defer self.allocator.free(pattern_z);

        const regex_ptr = self.allocator.create(c.regex_t) catch return null;
        const comp_result = c.regcomp(regex_ptr, pattern_z.ptr, c.REG_EXTENDED | c.REG_NOSUB);
        if (comp_result != 0) {
            self.allocator.destroy(regex_ptr);
            return null;
        }

        // Store in cache with a durable key
        const key = self.allocator.dupe(u8, pattern) catch {
            c.regfree(regex_ptr);
            self.allocator.destroy(regex_ptr);
            return null;
        };
        self.cache.put(key, regex_ptr) catch {
            self.allocator.free(key);
            c.regfree(regex_ptr);
            self.allocator.destroy(regex_ptr);
            return null;
        };

        return regex_ptr;
    }

    /// Execute a cached regex against a null-terminated string.
    /// Returns true if the pattern matches.
    pub fn matches(self: *RegexCache, pattern: []const u8, input_z: [*:0]const u8) ?bool {
        const regex_ptr = self.getOrCompile(pattern) orelse return null;
        return c.regexec(regex_ptr, input_z, 0, null, 0) == 0;
    }

    pub fn deinit(self: *RegexCache) void {
        var it = self.cache.iterator();
        while (it.next()) |entry| {
            c.regfree(entry.value_ptr.*);
            self.allocator.destroy(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.cache.deinit();
    }
};
