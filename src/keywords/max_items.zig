const std = @import("std");
const validator = @import("../validator.zig");
const Context = validator.Context;

pub fn validate(ctx: Context) void {
    const schema_obj = ctx.schema.object;
    const value = schema_obj.get("maxItems") orelse return;

    const arr = switch (ctx.instance) {
        .array => |a| a,
        else => return, // non-arrays pass
    };

    const max_items: u64 = switch (value) {
        .integer => |n| if (n >= 0) @intCast(n) else return,
        .float => |f| if (f >= 0 and f == @trunc(f)) @intFromFloat(f) else return,
        else => return,
    };

    if (arr.items.len > max_items) {
        ctx.addError("maxItems", "Array has more items than maxItems");
    }
}
