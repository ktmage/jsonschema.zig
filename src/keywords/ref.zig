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
            // For 2020-12 dynamic scope: if resolved target is in a different resource,
            // push that resource's root to the dynamic scope
            const pushed_scope = pushResourceScope(ctx, res.root, res.base_uri);

            const result = jsonschema.validateFull(
                ctx.allocator,
                res.root,
                res.schema,
                ctx.instance,
                ctx.instance_path,
                schema_path,
                ctx.registry,
                res.base_uri,
                ctx.dynamic_scope,
            );
            defer result.deinit();

            if (pushed_scope) popResourceScope(ctx);

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
        ctx.dynamic_scope,
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

/// Push a schema resource to the dynamic scope if it's not already there.
/// Returns true if pushed (caller must pop).
fn pushResourceScope(ctx: Context, root: std.json.Value, base_uri: []const u8) bool {
    const ds = ctx.dynamic_scope orelse return false;

    // Check if this resource is already in the scope (avoid duplicates)
    for (ds.items) |entry| {
        if (std.mem.eql(u8, entry.base_uri, base_uri)) return false;
    }

    ds.append(.{ .base_uri = base_uri, .schema = root }) catch return false;
    return true;
}

fn popResourceScope(ctx: Context) void {
    const ds = ctx.dynamic_scope orelse return;
    if (ds.items.len > 0) _ = ds.pop();
}
