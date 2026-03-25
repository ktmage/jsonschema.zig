const std = @import("std");
const validator = @import("../validator.zig");
const Context = validator.Context;
const JsonPointer = @import("../json_pointer.zig");
const schema_registry = @import("../schema_registry.zig");
const SchemaRegistry = schema_registry.SchemaRegistry;
const jsonschema = @import("../main.zig");

pub fn validate(ctx: Context) void {
    const schema_obj = ctx.schema.object;
    const ref_val = schema_obj.get("$dynamicRef") orelse return;
    const ref_str = switch (ref_val) {
        .string => |s| s,
        else => return,
    };

    const schema_path = JsonPointer.appendProperty(ctx.allocator, ctx.schema_path, "$dynamicRef");

    // Step 1: Resolve $dynamicRef as a normal $ref first
    const initial_result = resolveInitial(ctx, ref_str);
    if (initial_result == null) {
        ctx.addError("$dynamicRef", "could not resolve $dynamicRef");
        return;
    }
    const initial = initial_result.?;

    // Step 2: Check if the initially resolved schema has a $dynamicAnchor
    // with the same name as the fragment in $dynamicRef
    const fragment = getFragment(ref_str);
    if (fragment) |anchor_name| {
        if (hasDynamicAnchor(initial.schema, anchor_name)) {
            // Walk the dynamic scope to find the first (outermost) schema resource
            // that has a $dynamicAnchor with this name
            if (ctx.dynamic_scope) |ds| {
                // Search from bottom (outermost) to top (innermost) of the scope stack
                for (ds.items) |scope_entry| {
                    if (findDynamicAnchorInResource(scope_entry.schema, anchor_name)) |anchor_schema| {
                        // Found a dynamic anchor in the scope — validate against it
                        const result = jsonschema.validateFull(
                            ctx.allocator,
                            scope_entry.schema,
                            anchor_schema,
                            ctx.instance,
                            ctx.instance_path,
                            schema_path,
                            ctx.registry,
                            scope_entry.base_uri,
                            ctx.dynamic_scope,
                            ctx.compiled,
                        );
                        defer result.deinit();
                        appendErrors(ctx, result);
                        return;
                    }
                }
            }

            // Also check registry for schemas with this dynamic anchor
            if (ctx.registry) |reg| {
                if (ctx.dynamic_scope) |ds| {
                    for (ds.items) |scope_entry| {
                        if (scope_entry.base_uri.len > 0) {
                            const anchor_uri = std.fmt.allocPrint(ctx.allocator, "{s}#{s}", .{ scope_entry.base_uri, anchor_name }) catch continue;
                            if (reg.anchors.get(anchor_uri)) |anchor_schema| {
                                // Check if this anchor is a $dynamicAnchor
                                if (hasDynamicAnchor(anchor_schema, anchor_name)) {
                                    const result = jsonschema.validateFull(
                                        ctx.allocator,
                                        scope_entry.schema,
                                        anchor_schema,
                                        ctx.instance,
                                        ctx.instance_path,
                                        schema_path,
                                        ctx.registry,
                                        scope_entry.base_uri,
                                        ctx.dynamic_scope,
                                        ctx.compiled,
                                    );
                                    defer result.deinit();
                                    appendErrors(ctx, result);
                                    return;
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // Fall back to initial resolution (normal $ref behavior)
    const result = jsonschema.validateFull(
        ctx.allocator,
        initial.root,
        initial.schema,
        ctx.instance,
        ctx.instance_path,
        schema_path,
        ctx.registry,
        initial.base_uri,
        ctx.dynamic_scope,
        ctx.compiled,
    );
    defer result.deinit();
    appendErrors(ctx, result);
}

const ResolveResult = struct {
    schema: std.json.Value,
    root: std.json.Value,
    base_uri: []const u8,
};

fn resolveInitial(ctx: Context, ref_str: []const u8) ?ResolveResult {
    // Try registry first
    if (ctx.registry) |reg| {
        if (reg.resolveWithRoot(ctx.root_schema, ctx.base_uri, ref_str)) |res| {
            return .{ .schema = res.schema, .root = res.root, .base_uri = res.base_uri };
        }
    }

    // Fall back to local resolution
    if (ref_str.len > 0 and ref_str[0] == '#') {
        if (ref_str.len == 1) return .{ .schema = ctx.root_schema, .root = ctx.root_schema, .base_uri = ctx.base_uri };
        if (ref_str.len >= 2 and ref_str[1] == '/') {
            if (schema_registry.resolvePointer(ctx.root_schema, ref_str[2..])) |s| {
                return .{ .schema = s, .root = ctx.root_schema, .base_uri = ctx.base_uri };
            }
        }
        // Try as anchor
        if (ref_str.len > 1) {
            const anchor_name = ref_str[1..];
            if (findAnchorInSchema(ctx.root_schema, anchor_name)) |s| {
                return .{ .schema = s, .root = ctx.root_schema, .base_uri = ctx.base_uri };
            }
        }
    }

    return null;
}

fn getFragment(ref: []const u8) ?[]const u8 {
    // Get the fragment part of the ref (after #)
    const hash_pos = std.mem.indexOfScalar(u8, ref, '#') orelse return null;
    const fragment = ref[hash_pos + 1 ..];
    // Only return plain anchors (not JSON pointers starting with /)
    if (fragment.len == 0 or fragment[0] == '/') return null;
    return fragment;
}

fn hasDynamicAnchor(schema: std.json.Value, anchor_name: []const u8) bool {
    const obj = switch (schema) {
        .object => |o| o,
        else => return false,
    };
    const da = obj.get("$dynamicAnchor") orelse return false;
    const da_str = switch (da) {
        .string => |s| s,
        else => return false,
    };
    return std.mem.eql(u8, da_str, anchor_name);
}

/// Search within a single schema resource for a $dynamicAnchor.
/// Does NOT cross $id boundaries (child schemas with their own $id are separate resources).
pub fn findDynamicAnchorInResource(schema: std.json.Value, anchor_name: []const u8) ?std.json.Value {
    return findDynamicAnchorRecursive(schema, anchor_name, true);
}

fn findDynamicAnchorRecursive(schema: std.json.Value, anchor_name: []const u8, is_root: bool) ?std.json.Value {
    const obj = switch (schema) {
        .object => |o| o,
        else => return null,
    };

    // If not root and this schema has $id, it's a separate resource — stop
    if (!is_root and obj.get("$id") != null) return null;

    // Check if this schema has the matching $dynamicAnchor
    if (obj.get("$dynamicAnchor")) |da_val| {
        const da_str = switch (da_val) {
            .string => |s| s,
            else => "",
        };
        if (std.mem.eql(u8, da_str, anchor_name)) return schema;
    }

    // Recurse into subschemas
    var it = obj.iterator();
    while (it.next()) |entry| {
        const k = entry.key_ptr.*;
        const v = entry.value_ptr.*;
        if (std.mem.eql(u8, k, "$ref") or std.mem.eql(u8, k, "$dynamicRef")) continue;
        switch (v) {
            .object => {
                if (findDynamicAnchorRecursive(v, anchor_name, false)) |s| return s;
            },
            .array => |arr| {
                for (arr.items) |item| {
                    if (findDynamicAnchorRecursive(item, anchor_name, false)) |s| return s;
                }
            },
            else => {},
        }
    }

    return null;
}

fn findAnchorInSchema(schema: std.json.Value, anchor_name: []const u8) ?std.json.Value {
    const obj = switch (schema) {
        .object => |o| o,
        else => return null,
    };

    // Check $anchor
    if (obj.get("$anchor")) |a| {
        const a_str = switch (a) {
            .string => |s| s,
            else => "",
        };
        if (std.mem.eql(u8, a_str, anchor_name)) return schema;
    }

    // Check $dynamicAnchor (also acts as a regular anchor)
    if (obj.get("$dynamicAnchor")) |da| {
        const da_str = switch (da) {
            .string => |s| s,
            else => "",
        };
        if (std.mem.eql(u8, da_str, anchor_name)) return schema;
    }

    // Check $id anchor (Draft 7 style)
    if (obj.get("$id")) |id_val| {
        const id_str = switch (id_val) {
            .string => |s| s,
            else => "",
        };
        if (id_str.len > 0 and id_str[0] == '#') {
            if (std.mem.eql(u8, id_str[1..], anchor_name)) return schema;
        }
    }

    var it = obj.iterator();
    while (it.next()) |entry| {
        const k = entry.key_ptr.*;
        const v = entry.value_ptr.*;
        if (std.mem.eql(u8, k, "$ref") or std.mem.eql(u8, k, "$dynamicRef")) continue;
        switch (v) {
            .object => {
                if (findAnchorInSchema(v, anchor_name)) |s| return s;
            },
            .array => |arr| {
                for (arr.items) |item| {
                    if (findAnchorInSchema(item, anchor_name)) |s| return s;
                }
            },
            else => {},
        }
    }

    return null;
}

fn appendErrors(ctx: Context, result: jsonschema.ValidationResult) void {
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
