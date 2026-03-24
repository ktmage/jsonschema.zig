const std = @import("std");
const validator = @import("../validator.zig");
const Context = validator.Context;

pub fn validate(ctx: Context) void {
    const schema_obj = ctx.schema.object;
    const value = schema_obj.get("maxLength") orelse return;
    const instance_str = switch (ctx.instance) {
        .string => |s| s,
        else => return,
    };
    const max_length: u64 = switch (value) {
        .integer => |v| if (v >= 0) @intCast(v) else return,
        .float => |f| if (f >= 0 and f == @trunc(f)) @intFromFloat(f) else return,
        else => return,
    };
    const codepoint_count = std.unicode.utf8CountCodepoints(instance_str) catch return;
    if (codepoint_count > max_length) {
        const msg = std.fmt.allocPrint(
            ctx.allocator,
            "String is too long: {d} codepoints, maximum {d}",
            .{ codepoint_count, max_length },
        ) catch return;
        defer ctx.allocator.free(msg);
        ctx.addError("maxLength", msg);
    }
}
