const std = @import("std");
const validator = @import("../validator.zig");
const Context = validator.Context;
const JsonPointer = @import("../json_pointer.zig");
const jsonschema = @import("../main.zig");
const schema_registry = @import("../schema_registry.zig");
const pattern_properties = @import("pattern_properties.zig");

pub fn validate(ctx: Context) void {
    const schema_obj = ctx.schema.object;
    const unevaluated_schema = schema_obj.get("unevaluatedProperties") orelse return;

    // Only applies to objects
    const instance_obj = switch (ctx.instance) {
        .object => |o| o,
        else => return,
    };

    // Collect all evaluated property names
    var evaluated = std.StringHashMap(void).init(ctx.allocator);
    defer evaluated.deinit();

    collectEvaluatedProperties(ctx, ctx.schema, ctx.instance, &evaluated, true);

    // Check unevaluated properties
    const unevaluated_path = JsonPointer.appendProperty(ctx.allocator, ctx.schema_path, "unevaluatedProperties");

    var it = instance_obj.iterator();
    while (it.next()) |entry| {
        const prop_name = entry.key_ptr.*;
        const prop_value = entry.value_ptr.*;

        if (evaluated.get(prop_name) != null) continue;

        // This property is unevaluated
        switch (unevaluated_schema) {
            .bool => |b| {
                if (!b) {
                    const msg = std.fmt.allocPrint(
                        ctx.allocator,
                        "Unevaluated property '{s}' is not allowed",
                        .{prop_name},
                    ) catch return;
                    ctx.addError("unevaluatedProperties", msg);
                }
            },
            .object => {
                const prop_path = JsonPointer.appendProperty(ctx.allocator, ctx.instance_path, prop_name);
                const result = ctx.validateSubschema(unevaluated_schema, prop_value, prop_path, unevaluated_path);
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

/// Collect property names that are "evaluated" by the given schema.
/// This includes properties evaluated by properties, patternProperties,
/// additionalProperties, and in-place applicators.
fn collectEvaluatedProperties(
    ctx: Context,
    schema: std.json.Value,
    instance: std.json.Value,
    evaluated: *std.StringHashMap(void),
    is_root: bool,
) void {
    const obj = switch (schema) {
        .object => |o| o,
        else => {
            // Boolean schemas don't evaluate individual properties
            // true = accept everything (but doesn't mark properties as evaluated)
            // false = reject everything
            return;
        },
    };

    const instance_obj = switch (instance) {
        .object => |o| o,
        else => return,
    };

    // "properties" evaluates the properties it defines
    if (obj.get("properties")) |props_val| {
        if (props_val == .object) {
            var props_it = props_val.object.iterator();
            while (props_it.next()) |entry| {
                if (instance_obj.get(entry.key_ptr.*) != null) {
                    evaluated.put(entry.key_ptr.*, {}) catch {};
                }
            }
        }
    }

    // "patternProperties" evaluates properties matching its patterns
    if (obj.get("patternProperties")) |pp_val| {
        if (pp_val == .object) {
            var inst_it = instance_obj.iterator();
            while (inst_it.next()) |entry| {
                if (pattern_properties.matchesAnyPattern(ctx.allocator, entry.key_ptr.*, pp_val.object, ctx.regex_cache)) {
                    evaluated.put(entry.key_ptr.*, {}) catch {};
                }
            }
        }
    }

    // "additionalProperties" evaluates all remaining properties (not in properties/patternProperties)
    if (obj.get("additionalProperties") != null) {
        // additionalProperties applies to all properties not covered by properties/patternProperties
        // If it exists (whether true, false, or schema), the properties it applies to are "evaluated"
        var inst_it = instance_obj.iterator();
        while (inst_it.next()) |entry| {
            const prop_name = entry.key_ptr.*;
            var covered = false;
            if (obj.get("properties")) |props_val| {
                if (props_val == .object and props_val.object.get(prop_name) != null) covered = true;
            }
            if (!covered) {
                if (obj.get("patternProperties")) |pp_val| {
                    if (pp_val == .object and pattern_properties.matchesAnyPattern(ctx.allocator, prop_name, pp_val.object, ctx.regex_cache)) covered = true;
                }
            }
            if (!covered) {
                evaluated.put(prop_name, {}) catch {};
            }
        }
    }

    // Process in-place applicators (allOf, anyOf, oneOf, if/then/else, $ref, dependentSchemas)
    // These contribute evaluated properties from sub-schemas

    // allOf: all must match, so collect from all
    if (obj.get("allOf")) |all_of_val| {
        if (all_of_val == .array) {
            for (all_of_val.array.items) |sub_schema| {
                collectEvaluatedProperties(ctx, sub_schema, instance, evaluated, false);
            }
        }
    }

    // anyOf: collect from those that match
    if (obj.get("anyOf")) |any_of_val| {
        if (any_of_val == .array) {
            for (any_of_val.array.items) |sub_schema| {
                if (subschemaValid(ctx, sub_schema, instance)) {
                    collectEvaluatedProperties(ctx, sub_schema, instance, evaluated, false);
                }
            }
        }
    }

    // oneOf: collect from the one that matches
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
                    collectEvaluatedProperties(ctx, ms, instance, evaluated, false);
                }
            }
        }
    }

    // if/then/else
    if (obj.get("if")) |if_schema| {
        const if_valid = subschemaValid(ctx, if_schema, instance);
        if (if_valid) {
            // When if passes, collect annotations from both if and then
            collectEvaluatedProperties(ctx, if_schema, instance, evaluated, false);
            if (obj.get("then")) |then_schema| {
                collectEvaluatedProperties(ctx, then_schema, instance, evaluated, false);
            }
        } else {
            // When if fails, only collect from else (not from if)
            if (obj.get("else")) |else_schema| {
                collectEvaluatedProperties(ctx, else_schema, instance, evaluated, false);
            }
        }
    }

    // $ref: collect from referenced schema
    if (obj.get("$ref")) |ref_val| {
        if (ref_val == .string) {
            if (resolveRef(ctx, ref_val.string)) |resolved| {
                collectEvaluatedProperties(ctx, resolved, instance, evaluated, false);
            }
        }
    }

    // $dynamicRef: collect from referenced schema
    if (obj.get("$dynamicRef")) |ref_val| {
        if (ref_val == .string) {
            if (resolveDynamicRef(ctx, ref_val.string)) |resolved| {
                collectEvaluatedProperties(ctx, resolved, instance, evaluated, false);
            }
        }
    }

    // dependentSchemas: if the trigger property exists, collect from the dep schema
    if (obj.get("dependentSchemas")) |deps_val| {
        if (deps_val == .object) {
            var dep_it = deps_val.object.iterator();
            while (dep_it.next()) |entry| {
                if (instance_obj.get(entry.key_ptr.*) != null) {
                    if (subschemaValid(ctx, entry.value_ptr.*, instance)) {
                        collectEvaluatedProperties(ctx, entry.value_ptr.*, instance, evaluated, false);
                    }
                }
            }
        }
    }

    // unevaluatedProperties itself: if it exists in a sub-schema (nested), treat it as evaluating too
    if (!is_root) {
        if (obj.get("unevaluatedProperties") != null) {
            // Nested unevaluatedProperties: if the sub-schema passes, all properties are evaluated
            if (subschemaValid(ctx, schema, instance)) {
                addAllProperties(instance, evaluated);
            }
        }
    }
}

fn addAllProperties(instance: std.json.Value, evaluated: *std.StringHashMap(void)) void {
    const obj = switch (instance) {
        .object => |o| o,
        else => return,
    };
    var it = obj.iterator();
    while (it.next()) |entry| {
        evaluated.put(entry.key_ptr.*, {}) catch {};
    }
}

fn subschemaValid(ctx: Context, sub_schema: std.json.Value, instance: std.json.Value) bool {
    return ctx.isSubschemaValid(sub_schema, instance);
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

    // First do normal resolution
    const initial = resolveRef(ctx, ref_str) orelse return null;

    // Check if it has a $dynamicAnchor matching the fragment
    const fragment = getAnchorFragment(ref_str) orelse return initial;
    if (!hasDynamicAnchor(initial, fragment)) return initial;

    // Walk dynamic scope for the first matching $dynamicAnchor
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
    const fragment = ref[hash_pos + 1 ..];
    if (fragment.len == 0 or fragment[0] == '/') return null;
    return fragment;
}

fn hasDynamicAnchor(schema_val: std.json.Value, anchor_name: []const u8) bool {
    const obj = switch (schema_val) {
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
