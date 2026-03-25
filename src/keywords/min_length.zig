const std = @import("std");
const validator = @import("../validator.zig");
const Context = validator.Context;

pub fn validate(ctx: Context) void {
    // Use pre-extracted value if available
    const value = ctx.current_keyword_value orelse ctx.schema.object.get("minLength") orelse return;
    const instance_str = switch (ctx.instance) {
        .string => |s| s,
        else => return,
    };
    const min_length: u64 = switch (value) {
        .integer => |v| if (v >= 0) @intCast(v) else return,
        .float => |f| if (f >= 0 and f == @trunc(f)) @intFromFloat(f) else return,
        else => return,
    };
    const codepoint_count = std.unicode.utf8CountCodepoints(instance_str) catch return;
    if (codepoint_count < min_length) {
        const msg = std.fmt.allocPrint(
            ctx.allocator,
            "String is too short: {d} codepoints, minimum {d}",
            .{ codepoint_count, min_length },
        ) catch return;
        defer ctx.allocator.free(msg);
        ctx.addError("minLength", msg);
    }
}
