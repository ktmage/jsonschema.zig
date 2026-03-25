const std = @import("std");
const validator = @import("../validator.zig");
const Context = validator.Context;
const json_pointer = @import("../json_pointer.zig");
const compiled_mod = @import("../compiled.zig");

pub fn validate(ctx: Context) void {
    const schema_obj = ctx.schema.object;
    const items_value = schema_obj.get("items") orelse return;

    const arr = switch (ctx.instance) {
        .array => |a| a,
        else => return, // non-arrays pass
    };

    // Detect 2020-12 mode: if prefixItems is present, items is always a single schema
    // that applies to items AFTER prefixItems
    const has_prefix_items = schema_obj.get("prefixItems") != null;

    // Pre-lookup the compiled node for items_value once (used across all iterations)
    const items_node: ?*const compiled_mod.CompiledNode = if (ctx.compiled) |c| c.getNode(items_value) else null;

    if (has_prefix_items) {
        // 2020-12 behavior: items applies to items beyond prefixItems
        const prefix_count = blk: {
            const pi = schema_obj.get("prefixItems") orelse break :blk @as(usize, 0);
            break :blk switch (pi) {
                .array => |a| a.items.len,
                else => 0,
            };
        };

        // items is always a single schema in 2020-12 mode
        if (arr.items.len <= prefix_count) return;

        // Fast path: skip path allocation for valid items using pre-looked-up node
        if (ctx.compiled != null) {
            var all_valid = true;
            for (prefix_count..arr.items.len) |i| {
                if (!ctx.isSubschemaValidWithNode(items_value, arr.items[i], items_node)) {
                    all_valid = false;
                    break;
                }
            }
            if (all_valid) return;
        }

        const items_path = json_pointer.appendProperty(ctx.allocator, ctx.schema_path, "items");
        for (prefix_count..arr.items.len) |i| {
            const item_path = json_pointer.appendIndex(ctx.allocator, ctx.instance_path, i);
            const result = ctx.validateSubschema(
                items_value,
                arr.items[i],
                item_path,
                items_path,
            );
            defer result.deinit();
            if (!result.isValid()) {
                for (result.errors) |err| {
                    ctx.errors.append(err) catch return;
                }
                @constCast(&result).errors = &.{};
            }
        }
    } else {
        // Draft 7 behavior
        switch (items_value) {
            // Single schema: all items must match
            .object, .bool => {
                for (arr.items, 0..) |item, i| {
                    // Fast path: skip path allocation for valid items (node pre-looked-up)
                    if (ctx.compiled != null and ctx.isSubschemaValidWithNode(items_value, item, items_node)) continue;

                    const items_path = json_pointer.appendProperty(ctx.allocator, ctx.schema_path, "items");
                    const item_path = json_pointer.appendIndex(ctx.allocator, ctx.instance_path, i);
                    const result = ctx.validateSubschema(items_value, item, item_path, items_path);
                    defer result.deinit();
                    if (!result.isValid()) {
                        for (result.errors) |err| {
                            ctx.errors.append(err) catch return;
                        }
                        @constCast(&result).errors = &.{};
                    }
                }
            },
            // Array of schemas (tuple validation): positional match (Draft 7 only)
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
}
