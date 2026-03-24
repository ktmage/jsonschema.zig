const std = @import("std");
const validator = @import("../validator.zig");
const Context = validator.Context;
const JsonPointer = @import("../json_pointer.zig");
const schema_registry = @import("../schema_registry.zig");
const SchemaRegistry = schema_registry.SchemaRegistry;
const jsonschema = @import("../main.zig");

pub fn validate(ctx: Context) void {
    const schema_obj = ctx.schema.object;
    const ref_val = schema_obj.get("$ref") orelse return;
    const ref_str = switch (ref_val) {
        .string => |s| s,
        else => return,
    };

    const schema_path = JsonPointer.appendProperty(ctx.allocator, ctx.schema_path, "$ref");

    // In Draft 7, $ref ignores sibling keywords including $id.
    // So we resolve $ref against the *parent* base_uri, not one modified by a sibling $id.
    const effective_base = ctx.ref_base_uri;

    // Try registry-based resolution with root tracking
    if (ctx.registry) |reg| {
        if (reg.resolveWithRoot(ctx.root_schema, effective_base, ref_str)) |res| {
            const result = jsonschema.validateFull(
                ctx.allocator,
                res.root,
                res.schema,
                ctx.instance,
                ctx.instance_path,
                schema_path,
                ctx.registry,
                res.base_uri,
            );
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
            return;
        }
    }

    // Fall back to local fragment resolution against root
    const resolved = blk: {
        if (ref_str.len > 0 and ref_str[0] == '#') {
            if (ref_str.len == 1) break :blk ctx.root_schema;
            if (ref_str.len >= 2 and ref_str[1] == '/') {
                break :blk schema_registry.resolvePointer(ctx.root_schema, ref_str[2..]) orelse {
                    ctx.addError("$ref", "could not resolve $ref");
                    return;
                };
            }
        }
        ctx.addError("$ref", "could not resolve $ref");
        return;
    };

    const result = jsonschema.validateFull(
        ctx.allocator,
        ctx.root_schema,
        resolved,
        ctx.instance,
        ctx.instance_path,
        schema_path,
        ctx.registry,
        effective_base,
    );
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
