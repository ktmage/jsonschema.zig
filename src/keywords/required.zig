const std = @import("std");
const validator = @import("../validator.zig");
const Context = validator.Context;

pub fn validate(ctx: Context) void {
    const value = ctx.current_keyword_value orelse ctx.schema.object.get("required") orelse return;
    const required_array = switch (value) {
        .array => |a| a.items,
        else => return,
    };

    // Only applies to objects
    switch (ctx.instance) {
        .object => |obj| {
            for (required_array) |item| {
                const name = switch (item) {
                    .string => |s| s,
                    else => continue,
                };
                if (obj.get(name) == null) {
                    const msg = std.fmt.allocPrint(
                        ctx.allocator,
                        "Required property '{s}' is missing",
                        .{name},
                    ) catch return;
                    ctx.addError("required", msg);
                }
            }
        },
        else => {},
    }
}
