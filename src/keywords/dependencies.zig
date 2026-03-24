const std = @import("std");
const validator = @import("../validator.zig");
const Context = validator.Context;
const JsonPointer = @import("../json_pointer.zig");

pub fn validate(ctx: Context) void {
    const schema_obj = ctx.schema.object;
    const value = schema_obj.get("dependencies") orelse return;
    const deps = switch (value) {
        .object => |o| o,
        else => return,
    };

    // Only applies to objects
    const instance_obj = switch (ctx.instance) {
        .object => |o| o,
        else => return,
    };

    const base_schema_path = JsonPointer.appendProperty(ctx.allocator, ctx.schema_path, "dependencies");

    var it = deps.iterator();
    while (it.next()) |entry| {
        const prop_name = entry.key_ptr.*;
        const dep_value = entry.value_ptr.*;

        // Only check dependency if the property exists in the instance
        if (instance_obj.get(prop_name) == null) continue;

        const dep_schema_path = JsonPointer.appendProperty(ctx.allocator, base_schema_path, prop_name);

        switch (dep_value) {
            // Array form: if "prop_name" exists, all listed properties must also exist
            .array => |dep_array| {
                for (dep_array.items) |item| {
                    const required_name = switch (item) {
                        .string => |s| s,
                        else => continue,
                    };
                    if (instance_obj.get(required_name) == null) {
                        const msg = std.fmt.allocPrint(
                            ctx.allocator,
                            "Property '{s}' depends on '{s}' which is missing",
                            .{ prop_name, required_name },
                        ) catch return;
                        ctx.addError("dependencies", msg);
                    }
                }
            },
            // Schema form (object or boolean): if "prop_name" exists, the whole instance must match the schema
            .object, .bool => {
                const result = ctx.validateSubschema(dep_value, ctx.instance, ctx.instance_path, dep_schema_path);
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
            },
            else => {},
        }
    }
}
