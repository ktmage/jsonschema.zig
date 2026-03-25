const std = @import("std");
const validator = @import("../validator.zig");
const Context = validator.Context;
const json_pointer = @import("../json_pointer.zig");

pub fn validate(ctx: Context) void {
    const schema_obj = ctx.schema.object;
    const additional_items_value = schema_obj.get("additionalItems") orelse return;

    // additionalItems only applies when "items" is an array (tuple validation)
    const items_value = schema_obj.get("items") orelse return;
    const items_schemas = switch (items_value) {
        .array => |a| a,
        else => return, // items is not an array, additionalItems has no effect
    };

    const arr = switch (ctx.instance) {
        .array => |a| a,
        else => return, // non-arrays pass
    };

    // Only validate items beyond the tuple length
    if (arr.items.len <= items_schemas.items.len) return;

    const additional_path = json_pointer.appendProperty(ctx.allocator, ctx.schema_path, "additionalItems");

    switch (additional_items_value) {
        // false: no additional items allowed
        .bool => |b| {
            if (!b and arr.items.len > items_schemas.items.len) {
                ctx.addError("additionalItems", "Additional items are not allowed");
            }
        },
        // schema: additional items must match the schema
        .object => {
            for (items_schemas.items.len..arr.items.len) |i| {
                // Fast path: skip path allocation for valid items
                if (ctx.compiled != null and ctx.isSubschemaValid(additional_items_value, arr.items[i])) continue;

                const item_path = json_pointer.appendIndex(ctx.allocator, ctx.instance_path, i);
                const result = ctx.validateSubschema(
                    additional_items_value,
                    arr.items[i],
                    item_path,
                    additional_path,
                );
                defer result.deinit();
                if (!result.isValid()) {
                    for (result.errors) |err| {
                        ctx.errors.append(err) catch return;
                    }
                    @constCast(&result).errors = &.{};
                }
            }
        },
        else => return,
    }
}
