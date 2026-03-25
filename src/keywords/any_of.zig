const std = @import("std");
const validator = @import("../validator.zig");
const Context = validator.Context;
const JsonPointer = @import("../json_pointer.zig");

pub fn validate(ctx: Context) void {
    const schema_obj = ctx.schema.object;
    const value = schema_obj.get("anyOf") orelse return;
    const sub_schemas = switch (value) {
        .array => |a| a.items,
        else => return,
    };

    for (sub_schemas) |sub_schema| {
        if (ctx.isSubschemaValid(sub_schema, ctx.instance)) {
            return; // at least one matched
        }
    }

    ctx.addError("anyOf", "Instance does not match any schema in anyOf");
}
