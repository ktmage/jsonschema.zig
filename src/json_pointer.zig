const std = @import("std");
const Allocator = std.mem.Allocator;

/// Append a property name to a JSON Pointer path.
/// e.g. append("/properties", "name") => "/properties/name"
pub fn appendProperty(allocator: Allocator, base: []const u8, property: []const u8) []const u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, escapeToken(allocator, property) }) catch base;
}

/// Append an array index to a JSON Pointer path.
/// e.g. append("/items", 0) => "/items/0"
pub fn appendIndex(allocator: Allocator, base: []const u8, index: usize) []const u8 {
    return std.fmt.allocPrint(allocator, "{s}/{d}", .{ base, index }) catch base;
}

/// Escape a JSON Pointer token (RFC 6901):
/// '~' => '~0', '/' => '~1'
fn escapeToken(allocator: Allocator, token: []const u8) []const u8 {
    var needs_escape = false;
    for (token) |c| {
        if (c == '~' or c == '/') {
            needs_escape = true;
            break;
        }
    }
    if (!needs_escape) return token;

    var buf = std.ArrayList(u8).init(allocator);
    for (token) |c| {
        switch (c) {
            '~' => buf.appendSlice("~0") catch return token,
            '/' => buf.appendSlice("~1") catch return token,
            else => buf.append(c) catch return token,
        }
    }
    return buf.toOwnedSlice() catch token;
}
