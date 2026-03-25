const std = @import("std");
const validator = @import("../validator.zig");
const Context = validator.Context;
const JsonPointer = @import("../json_pointer.zig");

pub fn validate(ctx: Context) void {
    const value = ctx.current_keyword_value orelse ctx.schema.object.get("properties") orelse return;
    const properties_schema = switch (value) {
        .object => |o| o,
        else => return,
    };

    const instance_obj = switch (ctx.instance) {
        .object => |o| o,
        else => return,
    };

    var it = properties_schema.iterator();
    while (it.next()) |entry| {
        const prop_name = entry.key_ptr.*;
        const prop_schema = entry.value_ptr.*;

        const instance_value = instance_obj.get(prop_name) orelse continue;

        // Fast path: check validity first without building paths
        if (ctx.compiled != null and ctx.isSubschemaValid(prop_schema, instance_value)) {
            continue; // valid — skip path allocation entirely
        }

        // Slow path: build paths and collect errors
        const base_schema_path = JsonPointer.appendProperty(ctx.allocator, ctx.schema_path, "properties");
        const prop_instance_path = JsonPointer.appendProperty(ctx.allocator, ctx.instance_path, prop_name);
        const prop_schema_path = JsonPointer.appendProperty(ctx.allocator, base_schema_path, prop_name);

        const result = ctx.validateSubschema(prop_schema, instance_value, prop_instance_path, prop_schema_path);
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
