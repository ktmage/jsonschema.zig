const std = @import("std");
const validator = @import("../validator.zig");
const Context = validator.Context;

pub fn validate(ctx: Context) void {
    // Use pre-extracted value if available
    const value = ctx.current_keyword_value orelse ctx.schema.object.get("exclusiveMaximum") orelse return;

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

    if (instance_num >= limit) {
        const msg = std.fmt.allocPrint(ctx.allocator, "{d} is greater than or equal to the exclusive maximum of {d}", .{ instance_num, limit }) catch return;
        defer ctx.allocator.free(msg);
        ctx.addError("exclusiveMaximum", msg);
    }
}
