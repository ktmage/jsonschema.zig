const std = @import("std");
const validator = @import("../validator.zig");
const Context = validator.Context;
const json_pointer = @import("../json_pointer.zig");

pub fn validate(ctx: Context) void {
    const schema_obj = ctx.schema.object;
    const contains_schema = schema_obj.get("contains") orelse return;

    const arr = switch (ctx.instance) {
        .array => |a| a,
        else => return, // non-arrays pass
    };

    const contains_path = json_pointer.appendProperty(ctx.allocator, ctx.schema_path, "contains");

    for (arr.items, 0..) |item, i| {
        const item_path = json_pointer.appendIndex(ctx.allocator, ctx.instance_path, i);
        const result = ctx.validateSubschema(
            contains_schema,
            item,
            item_path,
            contains_path,
        );
        defer result.deinit();
        if (result.isValid()) {
            return; // at least one item matches
        }
    }

    ctx.addError("contains", "No items match the contains schema");
}
