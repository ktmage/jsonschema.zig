const std = @import("std");
const validator = @import("../validator.zig");
const Context = validator.Context;
const JsonPointer = @import("../json_pointer.zig");

pub fn validate(ctx: Context) void {
    const schema_obj = ctx.schema.object;
    const sub_schema_value = schema_obj.get("not") orelse return;

    if (ctx.isSubschemaValid(sub_schema_value, ctx.instance)) {
        ctx.addError("not", "Instance must not be valid against the schema in not");
    }
}
