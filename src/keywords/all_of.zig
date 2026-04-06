const std = @import("std");
const validator = @import("../validator.zig");
const Context = validator.Context;
const JsonPointer = @import("../json_pointer.zig");

pub fn validate(ctx: Context) void {
    const value = ctx.current_keyword_value orelse ctx.schema.object.get("allOf") orelse return;
    const sub_schemas = switch (value) {
        .array => |a| a.items,
        else => return,
    };

    var base_path: ?[]const u8 = null;
    for (sub_schemas, 0..) |sub_schema, i| {
        // Fast path: skip path allocation for valid sub-schemas
        if (ctx.compiled != null and ctx.isSubschemaValid(sub_schema, ctx.instance)) {
            continue;
        }

        // Failed — build paths and collect errors
        const bp = base_path orelse blk: {
            const p = JsonPointer.appendProperty(ctx.allocator, ctx.schema_path, "allOf");
            base_path = p;
            break :blk p;
        };
        const path = JsonPointer.appendIndex(ctx.allocator, bp, i);
        const result = ctx.validateSubschema(sub_schema, ctx.instance, ctx.instance_path, path);
        defer result.deinit();
        if (!result.isValid()) {
            for (result.errors) |err| {
                ctx.errors.append(.{
                    .instance_path = ctx.allocator.dupe(u8, err.instance_path) catch return,
                    .schema_path = ctx.allocator.dupe(u8, err.schema_path) catch return,
                    .keyword = err.keyword,
                    .message = ctx.allocator.dupe(u8, err.message) catch return,
                }) catch return;
            }
        }
    }
}
