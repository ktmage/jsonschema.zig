const std = @import("std");
const validator = @import("../validator.zig");
const Context = validator.Context;

pub fn validate(ctx: Context) void {
    const schema_obj = ctx.schema.object;
    const value = schema_obj.get("maximum") orelse return;

    const instance_num: f64 = switch (ctx.instance) {
        .integer => |n| @floatFromInt(n),
        .float => |f| f,
        else => return, // non-numbers pass
    };

    const limit: f64 = switch (value) {
        .integer => |n| @floatFromInt(n),
        .float => |f| f,
        else => return,
    };

    if (instance_num > limit) {
        ctx.addError("maximum", "Value must be less than or equal to maximum");
    }
}
