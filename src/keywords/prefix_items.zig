const std = @import("std");
const validator = @import("../validator.zig");
const Context = validator.Context;
const json_pointer = @import("../json_pointer.zig");

pub fn validate(ctx: Context) void {
    const schema_obj = ctx.schema.object;
    const prefix_items_value = schema_obj.get("prefixItems") orelse return;
    const schemas = switch (prefix_items_value) {
        .array => |a| a,
        else => return,
    };

    const arr = switch (ctx.instance) {
        .array => |a| a,
        else => return, // non-arrays pass
    };

    const base_path = json_pointer.appendProperty(ctx.allocator, ctx.schema_path, "prefixItems");
    const count = @min(arr.items.len, schemas.items.len);
    for (0..count) |i| {
        const schema_i_path = json_pointer.appendIndex(ctx.allocator, base_path, i);
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
}
