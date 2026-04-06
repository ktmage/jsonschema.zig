const std = @import("std");
const validator = @import("../validator.zig");
const Context = validator.Context;

pub fn validate(ctx: Context) void {
    // Use pre-extracted value if available
    const value = ctx.current_keyword_value orelse ctx.schema.object.get("minItems") orelse return;

    const arr = switch (ctx.instance) {
        .array => |a| a,
        else => return, // non-arrays pass
    };

    const min_items: u64 = switch (value) {
        .integer => |n| if (n >= 0) @intCast(n) else return,
        .float => |f| if (f >= 0 and f == @trunc(f)) @intFromFloat(f) else return,
        else => return,
    };

    if (arr.items.len < min_items) {
        const msg = std.fmt.allocPrint(ctx.allocator, "Array has {d} items, minimum is {d}", .{ arr.items.len, min_items }) catch return;
        defer ctx.allocator.free(msg);
        ctx.addError("minItems", msg);
    }
}
