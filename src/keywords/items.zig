const std = @import("std");
const validator = @import("../validator.zig");
const Context = validator.Context;
const json_pointer = @import("../json_pointer.zig");

pub fn validate(ctx: Context) void {
    const schema_obj = ctx.schema.object;
    const items_value = schema_obj.get("items") orelse return;

    const arr = switch (ctx.instance) {
        .array => |a| a,
        else => return, // non-arrays pass
    };

    switch (items_value) {
        // Single schema: all items must match
        .object, .bool => {
            const items_path = json_pointer.appendProperty(ctx.allocator, ctx.schema_path, "items");
            for (arr.items, 0..) |item, i| {
                const item_path = json_pointer.appendIndex(ctx.allocator, ctx.instance_path, i);
                const result = ctx.validateSubschema(
                    items_value,
                    item,
                    item_path,
                    items_path,
                );
                defer result.deinit();
                if (!result.isValid()) {
                    for (result.errors) |err| {
                        ctx.errors.append(err) catch return;
                    }
                    // Prevent double-free: clear the result's errors slice
                    // since we transferred ownership to ctx.errors
                    @constCast(&result).errors = &.{};
                }
            }
        },
        // Array of schemas (tuple validation): positional match
        .array => |schemas| {
            const items_path = json_pointer.appendProperty(ctx.allocator, ctx.schema_path, "items");
            const count = @min(arr.items.len, schemas.items.len);
            for (0..count) |i| {
                const schema_i_path = json_pointer.appendIndex(ctx.allocator, items_path, i);
                const item_path = json_pointer.appendIndex(ctx.allocator, ctx.instance_path, i);
                const result = ctx.validateSubschema(
                    schemas.items[i],
                    arr.items[i],
                    item_path,
                    schema_i_path,
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
