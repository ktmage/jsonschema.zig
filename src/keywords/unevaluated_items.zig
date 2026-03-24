const std = @import("std");
const validator = @import("../validator.zig");
const Context = validator.Context;
const JsonPointer = @import("../json_pointer.zig");
const jsonschema = @import("../main.zig");
const schema_registry = @import("../schema_registry.zig");

pub fn validate(ctx: Context) void {
    const schema_obj = ctx.schema.object;
    const unevaluated_schema = schema_obj.get("unevaluatedItems") orelse return;

    // Only applies to arrays
    const arr = switch (ctx.instance) {
        .array => |a| a,
        else => return,
    };

    if (arr.items.len == 0) return;

    // Determine the maximum evaluated index
    var max_evaluated: usize = 0;
    var has_items_keyword = false;
    var evaluated_indices = std.AutoHashMap(usize, void).init(ctx.allocator);
    defer evaluated_indices.deinit();

    collectEvaluatedItems(ctx, ctx.schema, ctx.instance, &max_evaluated, &has_items_keyword, &evaluated_indices, true);

    // If items keyword covers everything, all items are evaluated
    if (has_items_keyword) return;

    // Check unevaluated items
    const unevaluated_path = JsonPointer.appendProperty(ctx.allocator, ctx.schema_path, "unevaluatedItems");

    for (0..arr.items.len) |i| {
        // Item is evaluated if it's under max_evaluated or in the evaluated set
        if (i < max_evaluated) continue;
        if (evaluated_indices.get(i) != null) continue;

        // This item is unevaluated
        switch (unevaluated_schema) {
            .bool => |b| {
                if (!b) {
                    const msg = std.fmt.allocPrint(
                        ctx.allocator,
                        "Unevaluated item at index {d} is not allowed",
                        .{i},
                    ) catch return;
                    ctx.addError("unevaluatedItems", msg);
                }
            },
            .object => {
                const item_path = JsonPointer.appendIndex(ctx.allocator, ctx.instance_path, i);
                const result = ctx.validateSubschema(unevaluated_schema, arr.items[i], item_path, unevaluated_path);
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

/// Collect the maximum evaluated item index from a schema.
fn collectEvaluatedItems(
    ctx: Context,
    schema: std.json.Value,
    instance: std.json.Value,
    max_evaluated: *usize,
    has_items_keyword: *bool,
    evaluated_indices: *std.AutoHashMap(usize, void),
    is_root: bool,
) void {
    const obj = switch (schema) {
        .object => |o| o,
        else => {
            // Boolean schemas don't evaluate individual items
            return;
        },
    };

    const arr = switch (instance) {
        .array => |a| a,
        else => return,
    };

    // prefixItems evaluates indices 0..N-1
    if (obj.get("prefixItems")) |pi_val| {
        if (pi_val == .array) {
            const count = @min(pi_val.array.items.len, arr.items.len);
            if (count > max_evaluated.*) max_evaluated.* = count;
        }
    }

    // items (2020-12 mode: single schema after prefixItems) evaluates all remaining
    if (obj.get("items")) |items_val| {
        switch (items_val) {
            .object, .bool => {
                // In 2020-12 mode (with prefixItems), items applies to everything after prefixItems
                // In draft 7 mode (without prefixItems), items as single schema applies to all
                has_items_keyword.* = true;
            },
            .array => |items_arr| {
                // Draft 7 tuple validation
                const count = @min(items_arr.items.len, arr.items.len);
                if (count > max_evaluated.*) max_evaluated.* = count;
            },
            else => {},
        }
    }

    // additionalItems (Draft 7) evaluates items beyond items tuple
    if (obj.get("additionalItems") != null) {
        if (obj.get("items")) |items_val| {
            if (items_val == .array) {
                has_items_keyword.* = true;
            }
        }
    }

    // contains evaluates matching indices
    if (obj.get("contains")) |contains_schema| {
        for (arr.items, 0..) |item, i| {
            const result = ctx.validateSubschema(contains_schema, item, ctx.instance_path, ctx.schema_path);
            defer result.deinit();
            if (result.isValid()) {
                evaluated_indices.put(i, {}) catch {};
            }
        }
    }

    // allOf: collect from all
    if (obj.get("allOf")) |all_of_val| {
        if (all_of_val == .array) {
            for (all_of_val.array.items) |sub_schema| {
                collectEvaluatedItems(ctx, sub_schema, instance, max_evaluated, has_items_keyword, evaluated_indices, false);
            }
        }
    }

    // anyOf: collect from matching
    if (obj.get("anyOf")) |any_of_val| {
        if (any_of_val == .array) {
            for (any_of_val.array.items) |sub_schema| {
                if (subschemaValid(ctx, sub_schema, instance)) {
                    collectEvaluatedItems(ctx, sub_schema, instance, max_evaluated, has_items_keyword, evaluated_indices, false);
                }
            }
        }
    }

    // oneOf: collect from the matching one
    if (obj.get("oneOf")) |one_of_val| {
        if (one_of_val == .array) {
            var match_count: usize = 0;
            var matching_schema: ?std.json.Value = null;
            for (one_of_val.array.items) |sub_schema| {
                if (subschemaValid(ctx, sub_schema, instance)) {
                    match_count += 1;
                    matching_schema = sub_schema;
                }
            }
            if (match_count == 1) {
                if (matching_schema) |ms| {
                    collectEvaluatedItems(ctx, ms, instance, max_evaluated, has_items_keyword, evaluated_indices, false);
                }
            }
        }
    }

    // if/then/else
    if (obj.get("if")) |if_schema| {
        const if_valid = subschemaValid(ctx, if_schema, instance);
        if (if_valid) {
            collectEvaluatedItems(ctx, if_schema, instance, max_evaluated, has_items_keyword, evaluated_indices, false);
            if (obj.get("then")) |then_schema| {
                collectEvaluatedItems(ctx, then_schema, instance, max_evaluated, has_items_keyword, evaluated_indices, false);
            }
        } else {
            if (obj.get("else")) |else_schema| {
                collectEvaluatedItems(ctx, else_schema, instance, max_evaluated, has_items_keyword, evaluated_indices, false);
            }
        }
    }

    // $ref
    if (obj.get("$ref")) |ref_val| {
        if (ref_val == .string) {
            if (resolveRef(ctx, ref_val.string)) |resolved| {
                collectEvaluatedItems(ctx, resolved, instance, max_evaluated, has_items_keyword, evaluated_indices, false);
            }
        }
    }

    // $dynamicRef
    if (obj.get("$dynamicRef")) |ref_val| {
        if (ref_val == .string) {
            if (resolveDynamicRef(ctx, ref_val.string)) |resolved| {
                collectEvaluatedItems(ctx, resolved, instance, max_evaluated, has_items_keyword, evaluated_indices, false);
            }
        }
    }

    // Nested unevaluatedItems: if the sub-schema is valid, all items are evaluated
    if (!is_root) {
        if (obj.get("unevaluatedItems") != null) {
            if (subschemaValid(ctx, schema, instance)) {
                has_items_keyword.* = true;
            }
        }
    }
}

fn subschemaValid(ctx: Context, sub_schema: std.json.Value, instance: std.json.Value) bool {
    const result = ctx.validateSubschema(sub_schema, instance, ctx.instance_path, ctx.schema_path);
    defer result.deinit();
    return result.isValid();
}

fn resolveRef(ctx: Context, ref_str: []const u8) ?std.json.Value {
    if (ctx.registry) |reg| {
        if (reg.resolveWithRoot(ctx.root_schema, ctx.base_uri, ref_str)) |res| {
            return res.schema;
        }
    }

    if (ref_str.len > 0 and ref_str[0] == '#') {
        if (ref_str.len == 1) return ctx.root_schema;
        if (ref_str.len >= 2 and ref_str[1] == '/') {
            return schema_registry.resolvePointer(ctx.root_schema, ref_str[2..]);
        }
    }
    return null;
}

fn resolveDynamicRef(ctx: Context, ref_str: []const u8) ?std.json.Value {
    const dynamic_ref = @import("dynamic_ref.zig");

    const initial = resolveRef(ctx, ref_str) orelse return null;

    const fragment = getAnchorFragment(ref_str) orelse return initial;
    if (!hasDynamicAnchor(initial, fragment)) return initial;

    if (ctx.dynamic_scope) |ds| {
        for (ds.items) |scope_entry| {
            if (dynamic_ref.findDynamicAnchorInResource(scope_entry.schema, fragment)) |anchor_schema| {
                return anchor_schema;
            }
        }
    }

    return initial;
}

fn getAnchorFragment(ref: []const u8) ?[]const u8 {
    const hash_pos = std.mem.indexOfScalar(u8, ref, '#') orelse return null;
    const frag = ref[hash_pos + 1 ..];
    if (frag.len == 0 or frag[0] == '/') return null;
    return frag;
}

fn hasDynamicAnchor(schema_val: std.json.Value, anchor_name: []const u8) bool {
    const obj_val = switch (schema_val) {
        .object => |o| o,
        else => return false,
    };
    const da = obj_val.get("$dynamicAnchor") orelse return false;
    const da_str = switch (da) {
        .string => |s| s,
        else => return false,
    };
    return std.mem.eql(u8, da_str, anchor_name);
}
