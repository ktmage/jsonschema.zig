const std = @import("std");
const validator = @import("../validator.zig");
const Context = validator.Context;
const JsonPointer = @import("../json_pointer.zig");
const c = @cImport(@cInclude("regex.h"));
const compiled_mod = @import("../compiled.zig");

pub fn validate(ctx: Context) void {
    const value = ctx.current_keyword_value orelse ctx.schema.object.get("patternProperties") orelse return;
    const pattern_schemas = switch (value) {
        .object => |o| o,
        else => return,
    };

    // Only applies to objects
    const instance_obj = switch (ctx.instance) {
        .object => |o| o,
        else => return,
    };

    const base_schema_path = JsonPointer.appendProperty(ctx.allocator, ctx.schema_path, "patternProperties");

    var pattern_it = pattern_schemas.iterator();
    while (pattern_it.next()) |pattern_entry| {
        const pattern = pattern_entry.key_ptr.*;
        const sub_schema = pattern_entry.value_ptr.*;

        const pattern_schema_path = JsonPointer.appendProperty(ctx.allocator, base_schema_path, pattern);

        // Pre-lookup compiled node once per pattern's sub_schema
        const sub_node: ?*const compiled_mod.CompiledNode = if (ctx.compiled) |comp| comp.getNode(sub_schema) else null;

        // Null-terminate the pattern for POSIX regex
        const pattern_z = ctx.allocator.dupeZ(u8, pattern) catch continue;

        var regex: c.regex_t = undefined;
        const comp_result = c.regcomp(&regex, pattern_z.ptr, c.REG_EXTENDED | c.REG_NOSUB);
        if (comp_result != 0) continue;
        defer c.regfree(&regex);

        var instance_it = instance_obj.iterator();
        while (instance_it.next()) |instance_entry| {
            const prop_name = instance_entry.key_ptr.*;
            const prop_value = instance_entry.value_ptr.*;

            // Null-terminate the property name for POSIX regex
            const prop_name_z = ctx.allocator.dupeZ(u8, prop_name) catch continue;

            if (c.regexec(&regex, prop_name_z.ptr, 0, null, 0) == 0) {
                // Fast path: skip path allocation for valid properties (node pre-looked-up)
                if (ctx.compiled != null and ctx.isSubschemaValidWithNode(sub_schema, prop_value, sub_node)) continue;

                const prop_instance_path = JsonPointer.appendProperty(ctx.allocator, ctx.instance_path, prop_name);

                const result = ctx.validateSubschema(sub_schema, prop_value, prop_instance_path, pattern_schema_path);
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
    }
}

/// Check if a property name matches any pattern in patternProperties.
/// Used by additional_properties to determine which properties are "covered".
pub fn matchesAnyPattern(allocator: std.mem.Allocator, prop_name: []const u8, pattern_props: std.json.ObjectMap) bool {
    const prop_name_z = allocator.dupeZ(u8, prop_name) catch return false;

    var it = pattern_props.iterator();
    while (it.next()) |entry| {
        const pattern = entry.key_ptr.*;
        const pattern_z = allocator.dupeZ(u8, pattern) catch continue;

        var regex: c.regex_t = undefined;
        const comp_result = c.regcomp(&regex, pattern_z.ptr, c.REG_EXTENDED | c.REG_NOSUB);
        if (comp_result != 0) continue;
        defer c.regfree(&regex);

        if (c.regexec(&regex, prop_name_z.ptr, 0, null, 0) == 0) {
            return true;
        }
    }
    return false;
}
