const std = @import("std");
const validator = @import("../validator.zig");
const Context = validator.Context;
const JsonPointer = @import("../json_pointer.zig");
const pattern_properties = @import("pattern_properties.zig");

pub fn validate(ctx: Context) void {
    const schema_obj = ctx.schema.object;
    const additional = schema_obj.get("additionalProperties") orelse return;

    // Only applies to objects
    const instance_obj = switch (ctx.instance) {
        .object => |o| o,
        else => return,
    };

    // Determine which properties are "covered" by properties and patternProperties
    const props_schema = if (schema_obj.get("properties")) |v| switch (v) {
        .object => |o| o,
        else => null,
    } else null;

    const pattern_props = if (schema_obj.get("patternProperties")) |v| switch (v) {
        .object => |o| o,
        else => null,
    } else null;

    const additional_schema_path = JsonPointer.appendProperty(ctx.allocator, ctx.schema_path, "additionalProperties");

    var it = instance_obj.iterator();
    while (it.next()) |entry| {
        const prop_name = entry.key_ptr.*;
        const prop_value = entry.value_ptr.*;

        // Check if property is covered by "properties"
        if (props_schema) |ps| {
            if (ps.get(prop_name) != null) continue;
        }

        // Check if property is covered by "patternProperties"
        if (pattern_props) |pp| {
            if (pattern_properties.matchesAnyPattern(ctx.allocator, prop_name, pp)) continue;
        }

        // This is an additional property
        switch (additional) {
            .bool => |b| {
                if (!b) {
                    const msg = std.fmt.allocPrint(
                        ctx.allocator,
                        "Additional property '{s}' is not allowed",
                        .{prop_name},
                    ) catch return;
                    ctx.addError("additionalProperties", msg);
                }
                // true means any additional properties are allowed
            },
            .object => {
                // Fast path: skip path allocation for valid properties
                if (ctx.compiled != null and ctx.isSubschemaValid(additional, prop_value)) continue;

                // Additional properties must validate against this schema
                const prop_instance_path = JsonPointer.appendProperty(ctx.allocator, ctx.instance_path, prop_name);

                const result = ctx.validateSubschema(additional, prop_value, prop_instance_path, additional_schema_path);
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
