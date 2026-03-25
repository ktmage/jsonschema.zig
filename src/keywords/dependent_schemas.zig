const std = @import("std");
const validator = @import("../validator.zig");
const Context = validator.Context;
const JsonPointer = @import("../json_pointer.zig");

pub fn validate(ctx: Context) void {
    const value = ctx.current_keyword_value orelse ctx.schema.object.get("dependentSchemas") orelse return;
    const deps = switch (value) {
        .object => |o| o,
        else => return,
    };

    // Only applies to objects
    const instance_obj = switch (ctx.instance) {
        .object => |o| o,
        else => return,
    };

    const base_schema_path = JsonPointer.appendProperty(ctx.allocator, ctx.schema_path, "dependentSchemas");

    var it = deps.iterator();
    while (it.next()) |entry| {
        const prop_name = entry.key_ptr.*;
        const dep_schema = entry.value_ptr.*;

        // Only check dependency if the property exists in the instance
        if (instance_obj.get(prop_name) == null) continue;

        // Fast path: skip path allocation for valid schema dependencies
        if (ctx.compiled != null and ctx.isSubschemaValid(dep_schema, ctx.instance)) continue;

        const dep_schema_path = JsonPointer.appendProperty(ctx.allocator, base_schema_path, prop_name);

        // Schema form: the whole instance must match the schema
        const result = ctx.validateSubschema(dep_schema, ctx.instance, ctx.instance_path, dep_schema_path);
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
