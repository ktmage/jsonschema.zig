const std = @import("std");
const validator = @import("../validator.zig");
const Context = validator.Context;
const JsonPointer = @import("../json_pointer.zig");

pub fn validate(ctx: Context) void {
    // Use pre-extracted value if available
    const value = ctx.current_keyword_value orelse ctx.schema.object.get("dependentRequired") orelse return;
    const deps = switch (value) {
        .object => |o| o,
        else => return,
    };

    // Only applies to objects
    const instance_obj = switch (ctx.instance) {
        .object => |o| o,
        else => return,
    };

    var it = deps.iterator();
    while (it.next()) |entry| {
        const prop_name = entry.key_ptr.*;
        const dep_value = entry.value_ptr.*;

        // Only check dependency if the property exists in the instance
        if (instance_obj.get(prop_name) == null) continue;

        const dep_array = switch (dep_value) {
            .array => |a| a,
            else => continue,
        };

        for (dep_array.items) |item| {
            const required_name = switch (item) {
                .string => |s| s,
                else => continue,
            };
            if (instance_obj.get(required_name) == null) {
                const msg = std.fmt.allocPrint(
                    ctx.allocator,
                    "Property '{s}' depends on '{s}' which is missing",
                    .{ prop_name, required_name },
                ) catch return;
                ctx.addError("dependentRequired", msg);
            }
        }
    }
}
