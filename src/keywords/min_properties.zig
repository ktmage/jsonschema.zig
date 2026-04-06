const std = @import("std");
const validator = @import("../validator.zig");
const Context = validator.Context;

pub fn validate(ctx: Context) void {
    // Use pre-extracted value if available
    const value = ctx.current_keyword_value orelse ctx.schema.object.get("minProperties") orelse return;

    const limit: u64 = switch (value) {
        .integer => |n| if (n >= 0) @intCast(n) else return,
        .float => |f| if (f >= 0 and f == @trunc(f)) @intFromFloat(f) else return,
        else => return,
    };

    // Only applies to objects
    const obj = switch (ctx.instance) {
        .object => |o| o,
        else => return,
    };

    if (obj.count() < limit) {
        const msg = std.fmt.allocPrint(ctx.allocator, "Object has {d} properties, minimum is {d}", .{ obj.count(), limit }) catch return;
        defer ctx.allocator.free(msg);
        ctx.addError("minProperties", msg);
    }
}
