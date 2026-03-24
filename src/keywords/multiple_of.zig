const std = @import("std");
const validator = @import("../validator.zig");
const Context = validator.Context;

pub fn validate(ctx: Context) void {
    const schema_obj = ctx.schema.object;
    const value = schema_obj.get("multipleOf") orelse return;

    const instance_num: f64 = switch (ctx.instance) {
        .integer => |n| @floatFromInt(n),
        .float => |f| f,
        else => return, // non-numbers pass
    };

    const divisor: f64 = switch (value) {
        .integer => |n| @floatFromInt(n),
        .float => |f| f,
        else => return,
    };

    if (divisor == 0) return;

    const remainder = @rem(instance_num, divisor);
    const tolerance: f64 = 1e-9;

    if (@abs(remainder) > tolerance and @abs(remainder) - @abs(divisor) < -tolerance) {
        ctx.addError("multipleOf", "Value must be a multiple of multipleOf");
    }
}
