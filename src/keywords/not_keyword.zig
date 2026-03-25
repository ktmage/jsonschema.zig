const std = @import("std");
const validator = @import("../validator.zig");
const Context = validator.Context;
const JsonPointer = @import("../json_pointer.zig");

pub fn validate(ctx: Context) void {
    const schema_obj = ctx.schema.object;
    const sub_schema_value = schema_obj.get("not") orelse return;

    const path = JsonPointer.appendProperty(ctx.allocator, ctx.schema_path, "not");
    const result = ctx.validateSubschema(sub_schema_value, ctx.instance, ctx.instance_path, path);
    defer result.deinit();

    if (result.isValid()) {
        ctx.addError("not", "Instance must not be valid against the schema in not");
    }
}
