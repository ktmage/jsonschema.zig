const std = @import("std");
const validator = @import("../validator.zig");
const Context = validator.Context;
const jsonEqual = @import("enum_keyword.zig").jsonEqual;

pub fn validate(ctx: Context) void {
    const schema_obj = ctx.schema.object;
    const const_value = schema_obj.get("const") orelse return;

    if (!jsonEqual(ctx.instance, const_value)) {
        ctx.addError("const", "Instance does not match the const value");
    }
}
