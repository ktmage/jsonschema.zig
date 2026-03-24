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

    const base_path = JsonPointer.appendProperty(ctx.allocator, ctx.schema_path, "anyOf");

    for (sub_schemas, 0..) |sub_schema, i| {
        const path = JsonPointer.appendIndex(ctx.allocator, base_path, i);
        const result = ctx.validateSubschema(sub_schema, ctx.instance, ctx.instance_path, path);
        defer result.deinit();
        if (result.isValid()) {
            return; // at least one matched
        }
    }

    ctx.addError("anyOf", "Instance does not match any schema in anyOf");
}
