const std = @import("std");
const validator = @import("../validator.zig");
const Context = validator.Context;
const JsonPointer = @import("../json_pointer.zig");

pub fn validate(ctx: Context) void {
    const schema_obj = ctx.schema.object;
    const names_schema = schema_obj.get("propertyNames") orelse return;

    // Only applies to objects
    const instance_obj = switch (ctx.instance) {
        .object => |o| o,
        else => return,
    };

    const names_schema_path = JsonPointer.appendProperty(ctx.allocator, ctx.schema_path, "propertyNames");

    var it = instance_obj.iterator();
    while (it.next()) |entry| {
        const prop_name = entry.key_ptr.*;

        // Treat the property name as a JSON string value for validation
        const name_value = std.json.Value{ .string = prop_name };

        // Fast path: skip path allocation for valid property names
        if (ctx.compiled != null and ctx.isSubschemaValid(names_schema, name_value)) continue;

        const prop_instance_path = JsonPointer.appendProperty(ctx.allocator, ctx.instance_path, prop_name);

        const result = ctx.validateSubschema(names_schema, name_value, prop_instance_path, names_schema_path);
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
