const std = @import("std");
const validator = @import("../validator.zig");
const Context = validator.Context;
const JsonPointer = @import("../json_pointer.zig");

pub fn validate(ctx: Context) void {
    const schema_obj = ctx.schema.object;
    const ref_val = schema_obj.get("$ref") orelse return;
    const ref_str = switch (ref_val) {
        .string => |s| s,
        else => return,
    };

    // Resolve the $ref to a sub-schema
    const resolved = resolveRef(ctx.root_schema, ref_str) orelse {
        ctx.addError("$ref", "could not resolve $ref");
        return;
    };

    const schema_path = JsonPointer.appendProperty(ctx.allocator, ctx.schema_path, "$ref");
    const result = ctx.validateSubschema(resolved, ctx.instance, ctx.instance_path, schema_path);
    defer result.deinit();

    if (!result.isValid()) {
        for (result.errors) |err| {
            ctx.errors.append(.{
                .instance_path = ctx.allocator.dupe(u8, err.instance_path) catch return,
                .schema_path = ctx.allocator.dupe(u8, err.schema_path) catch return,
                .keyword = err.keyword,
                .message = ctx.allocator.dupe(u8, err.message) catch return,
            }) catch return;
        }
    }
}

/// Resolve a JSON reference string to a sub-schema.
/// Supports local fragment references (#, #/definitions/foo, #/if, etc.)
/// and percent-encoded pointers.
fn resolveRef(root: std.json.Value, ref: []const u8) ?std.json.Value {
    if (ref.len == 0) return null;
    if (ref[0] != '#') return null;

    // "#" alone refers to the root
    if (ref.len == 1) return root;

    // Must be "#/" followed by pointer tokens
    if (ref.len < 2 or ref[1] != '/') return null;

    const pointer = ref[2..];
    return resolvePointer(root, pointer);
}

/// Walk a JSON Pointer path (without leading /) through a JSON value.
fn resolvePointer(value: std.json.Value, pointer: []const u8) ?std.json.Value {
    var current = value;
    var remaining = pointer;

    while (remaining.len > 0) {
        const sep = std.mem.indexOfScalar(u8, remaining, '/');
        const token_raw = if (sep) |s| remaining[0..s] else remaining;
        remaining = if (sep) |s| remaining[s + 1 ..] else "";

        // Percent-decode then unescape JSON Pointer tokens
        const decoded = percentDecode(token_raw);
        const token = unescapeToken(decoded);

        switch (current) {
            .object => |obj| {
                current = obj.get(token) orelse return null;
            },
            .array => |arr| {
                const index = std.fmt.parseInt(usize, token, 10) catch return null;
                if (index >= arr.items.len) return null;
                current = arr.items[index];
            },
            else => return null,
        }
    }

    return current;
}

/// Percent-decode a string (e.g. "%25" -> "%", "%2F" -> "/")
fn percentDecode(input: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, input, '%') == null) return input;

    var buf: [4096]u8 = undefined;
    var len: usize = 0;
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '%' and i + 2 < input.len) {
            const hi = hexVal(input[i + 1]);
            const lo = hexVal(input[i + 2]);
            if (hi != null and lo != null) {
                if (len < buf.len) {
                    buf[len] = (hi.? << 4) | lo.?;
                    len += 1;
                }
                i += 3;
                continue;
            }
        }
        if (len < buf.len) {
            buf[len] = input[i];
            len += 1;
        }
        i += 1;
    }
    return buf[0..len];
}

fn hexVal(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

/// Unescape JSON Pointer token: ~1 -> /, ~0 -> ~
fn unescapeToken(token: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, token, '~') == null) return token;

    var buf: [4096]u8 = undefined;
    var len: usize = 0;
    var i: usize = 0;
    while (i < token.len) {
        if (token[i] == '~' and i + 1 < token.len) {
            if (token[i + 1] == '1') {
                if (len < buf.len) {
                    buf[len] = '/';
                    len += 1;
                }
                i += 2;
                continue;
            } else if (token[i + 1] == '0') {
                if (len < buf.len) {
                    buf[len] = '~';
                    len += 1;
                }
                i += 2;
                continue;
            }
        }
        if (len < buf.len) {
            buf[len] = token[i];
            len += 1;
        }
        i += 1;
    }
    return buf[0..len];
}
