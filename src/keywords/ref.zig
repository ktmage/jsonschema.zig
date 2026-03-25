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

    // Fast path for compiled schemas with local fragment-only $ref (#/...)
    // This avoids registry lookup and validateFull overhead entirely.
    if (ctx.compiled != null and ctx.registry == null) {
        const resolved = resolveLocalRef(ctx, ref_str) orelse {
            ctx.addError("$ref", "could not resolve $ref");
            return;
        };

        // Use the fast validateSubschema path (which skips validateFull when compiled)
        const result = ctx.validateSubschema(resolved, ctx.instance, ctx.instance_path, schema_path);
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

    // Try registry-based resolution with root tracking
    if (ctx.registry) |reg| {
        if (reg.resolveWithRoot(ctx.root_schema, effective_base, ref_str)) |res| {
            // For 2020-12 dynamic scope: if resolved target is in a different resource,
            // push that resource's root to the dynamic scope
            const pushed_scope = pushResourceScope(ctx, res.root, res.base_uri);

            // Fast path: if resolved to the same root and compiled is available, use fast sub-validation
            if (ctx.compiled != null and res.root.object.keys().ptr == ctx.root_schema.object.keys().ptr) {
                const result = ctx.validateSubschema(res.schema, ctx.instance, ctx.instance_path, schema_path);
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
                ctx.compiled,
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
    const resolved = resolveLocalRef(ctx, ref_str) orelse {
        ctx.addError("$ref", "could not resolve $ref");
        return;
    };

    if (ctx.compiled != null) {
        // Fast path: skip validateFull
        const result = ctx.validateSubschema(resolved, ctx.instance, ctx.instance_path, schema_path);
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
        ctx.compiled,
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

/// Resolve a local fragment-only $ref (e.g., "#/definitions/foo") against the root schema.
fn resolveLocalRef(ctx: Context, ref_str: []const u8) ?std.json.Value {
    if (ref_str.len > 0 and ref_str[0] == '#') {
        if (ref_str.len == 1) return ctx.root_schema;
        if (ref_str.len >= 2 and ref_str[1] == '/') {
            return schema_registry.resolvePointer(ctx.root_schema, ref_str[2..]);
        }
    }
    return null;
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
