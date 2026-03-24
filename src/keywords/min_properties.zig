const std = @import("std");
const validator = @import("../validator.zig");
const Context = validator.Context;

pub fn validate(ctx: Context) void {
    const schema_obj = ctx.schema.object;
    const value = schema_obj.get("minProperties") orelse return;

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
        ctx.addError("minProperties", "Object has too few properties");
    }
}
