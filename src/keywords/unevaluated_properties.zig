const std = @import("std");
const validator = @import("../validator.zig");
const Context = validator.Context;
const JsonPointer = @import("../json_pointer.zig");
const jsonschema = @import("../main.zig");
const schema_registry = @import("../schema_registry.zig");
const pattern_properties = @import("pattern_properties.zig");
const compiled_mod = @import("../compiled.zig");
const c_regex = compiled_mod.c;

pub fn validate(ctx: Context) void {
    const schema_obj = ctx.schema.object;
    const unevaluated_schema = schema_obj.get("unevaluatedProperties") orelse return;

    // Only applies to objects
    const instance_obj = switch (ctx.instance) {
        .object => |o| o,
        else => return,
    };

    // Fast path 1: ceiling check (compile-time pre-computed)
    if (ctx.compiled) |compiled| {
        if (compiled.getNode(ctx.schema)) |node| {
            if (node.unevaluated_all_covered) return;
            if (node.unevaluated_ceiling != null) {
                const ceiling_map = node.unevaluated_ceiling_map;
                const ceiling_arr = node.unevaluated_ceiling;
                const pattern_regs = node.unevaluated_pattern_regexes;
                var all_covered = true;
                var inst_it = instance_obj.iterator();
                while (inst_it.next()) |entry| {
                    const prop_name = entry.key_ptr.*;
                    var found = false;
                    // Use hashmap for O(1) lookup if available
                    if (ceiling_map) |cm| {
                        found = cm.get(prop_name) != null;
                    } else if (ceiling_arr) |ca| {
                        for (ca) |name| {
                            if (std.mem.eql(u8, prop_name, name)) {
                                found = true;
                                break;
                            }
                        }
                    }
                    if (!found and pattern_regs != null) {
                        const prop_z = ctx.allocator.dupeZ(u8, prop_name) catch {
                            all_covered = false;
                            break;
                        };
                        for (pattern_regs.?) |cr| {
                            if (cr.valid and compiled_mod.c.regexec(&cr.regex, prop_z.ptr, 0, null, 0) == 0) {
                                found = true;
                                break;
                            }
                        }
                    }
                    if (!found) {
                        all_covered = false;
                        break;
                    }
                }
                if (all_covered) return;
            }
        }
    }

    // Fast path 2: combine runtime tracked set (from properties/additionalProperties/
    // patternProperties during this validation) with compile-time ceiling (from all
    // applicator branches). If together they cover all instance properties, skip the
    // expensive collectEvaluatedProperties tree walk.
    if (ctx.evaluated_props) |ep| {
        const comp_node = if (ctx.compiled) |comp| comp.getNode(ctx.schema) else null;
        const ceiling_map = if (comp_node) |cn| cn.unevaluated_ceiling_map else null;
        const ceiling_arr = if (comp_node) |cn| cn.unevaluated_ceiling else null;
        const pattern_regs = if (comp_node) |cn| cn.unevaluated_pattern_regexes else null;
        var all_covered = true;
        var inst_it = instance_obj.iterator();
        while (inst_it.next()) |entry| {
            const name = entry.key_ptr.*;
            if (ep.get(name) != null) continue;
            if (ceiling_map) |cm| {
                if (cm.get(name) != null) continue;
            } else if (ceiling_arr) |ca| {
                var in_ceil = false;
                for (ca) |cn| {
                    if (std.mem.eql(u8, name, cn)) {
                        in_ceil = true;
                        break;
                    }
                }
                if (in_ceil) continue;
            }
            if (pattern_regs) |pregs| {
                const prop_z = ctx.allocator.dupeZ(u8, name) catch {
                    all_covered = false;
                    break;
                };
                var matched = false;
                for (pregs) |cr| {
                    if (cr.valid and compiled_mod.c.regexec(&cr.regex, prop_z.ptr, 0, null, 0) == 0) {
                        matched = true;
                        break;
                    }
                }
                if (matched) continue;
            }
            all_covered = false;
            break;
        }
        if (all_covered) return;
    }

    // Slow path: collect all evaluated property names
    var evaluated = std.StringHashMap(void).init(ctx.allocator);
    defer evaluated.deinit();

    var validation_cache = std.AutoHashMap(usize, bool).init(ctx.allocator);
    defer validation_cache.deinit();
    collectEvaluatedProperties(ctx, ctx.schema, ctx.instance, &evaluated, true, &validation_cache);

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
    validation_cache: *std.AutoHashMap(usize, bool),
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
    if (obj.get("patternProperties") != null) {
        // Try to use pre-compiled regex from compiled schema
        const compiled_pp = getCompiledPatternProperties(ctx, schema);
        if (compiled_pp) |pp_entries| {
            var inst_it = instance_obj.iterator();
            while (inst_it.next()) |entry| {
                if (matchesAnyCompiledPattern(ctx.allocator, entry.key_ptr.*, pp_entries)) {
                    evaluated.put(entry.key_ptr.*, {}) catch {};
                }
            }
        } else if (obj.get("patternProperties")) |pp_val| {
            if (pp_val == .object) {
                var inst_it = instance_obj.iterator();
                while (inst_it.next()) |entry| {
                    if (pattern_properties.matchesAnyPattern(ctx.allocator, entry.key_ptr.*, pp_val.object)) {
                        evaluated.put(entry.key_ptr.*, {}) catch {};
                    }
                }
            }
        }
    }

    // "additionalProperties" evaluates all remaining properties (not in properties/patternProperties)
    if (obj.get("additionalProperties") != null) {
        var inst_it = instance_obj.iterator();
        while (inst_it.next()) |entry| {
            const prop_name = entry.key_ptr.*;
            var covered = false;
            if (obj.get("properties")) |props_val| {
                if (props_val == .object and props_val.object.get(prop_name) != null) covered = true;
            }
            if (!covered) {
                const compiled_pp = getCompiledPatternProperties(ctx, schema);
                if (compiled_pp) |pp_entries| {
                    if (matchesAnyCompiledPattern(ctx.allocator, prop_name, pp_entries)) covered = true;
                } else if (obj.get("patternProperties")) |pp_val| {
                    if (pp_val == .object and pattern_properties.matchesAnyPattern(ctx.allocator, prop_name, pp_val.object)) covered = true;
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
                collectEvaluatedProperties(ctx, sub_schema, instance, evaluated, false, validation_cache);
            }
        }
    }

    // anyOf: collect from those that match
    if (obj.get("anyOf")) |any_of_val| {
        if (any_of_val == .array) {
            for (any_of_val.array.items) |sub_schema| {
                if (subschemaValidCached(ctx, sub_schema, instance, validation_cache)) {
                    collectEvaluatedProperties(ctx, sub_schema, instance, evaluated, false, validation_cache);
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
                if (subschemaValidCached(ctx, sub_schema, instance, validation_cache)) {
                    match_count += 1;
                    matching_schema = sub_schema;
                }
            }
            if (match_count == 1) {
                if (matching_schema) |ms| {
                    collectEvaluatedProperties(ctx, ms, instance, evaluated, false, validation_cache);
                }
            }
        }
    }

    // if/then/else
    if (obj.get("if")) |if_schema| {
        const if_valid = subschemaValidCached(ctx, if_schema, instance, validation_cache);
        if (if_valid) {
            collectEvaluatedProperties(ctx, if_schema, instance, evaluated, false, validation_cache);
            if (obj.get("then")) |then_schema| {
                collectEvaluatedProperties(ctx, then_schema, instance, evaluated, false, validation_cache);
            }
        } else {
            if (obj.get("else")) |else_schema| {
                collectEvaluatedProperties(ctx, else_schema, instance, evaluated, false, validation_cache);
            }
        }
    }

    // $ref: collect from referenced schema
    if (obj.get("$ref")) |ref_val| {
        if (ref_val == .string) {
            if (resolveRef(ctx, ref_val.string)) |resolved| {
                collectEvaluatedProperties(ctx, resolved, instance, evaluated, false, validation_cache);
            }
        }
    }

    // $dynamicRef: collect from referenced schema
    if (obj.get("$dynamicRef")) |ref_val| {
        if (ref_val == .string) {
            if (resolveDynamicRef(ctx, ref_val.string)) |resolved| {
                collectEvaluatedProperties(ctx, resolved, instance, evaluated, false, validation_cache);
            }
        }
    }

    // dependentSchemas: if the trigger property exists, collect from the dep schema
    if (obj.get("dependentSchemas")) |deps_val| {
        if (deps_val == .object) {
            var dep_it = deps_val.object.iterator();
            while (dep_it.next()) |entry| {
                if (instance_obj.get(entry.key_ptr.*) != null) {
                    if (subschemaValidCached(ctx, entry.value_ptr.*, instance, validation_cache)) {
                        collectEvaluatedProperties(ctx, entry.value_ptr.*, instance, evaluated, false, validation_cache);
                    }
                }
            }
        }
    }

    // unevaluatedProperties itself: if it exists in a sub-schema (nested), treat it as evaluating too
    if (!is_root) {
        if (obj.get("unevaluatedProperties") != null) {
            if (subschemaValidCached(ctx, schema, instance, validation_cache)) {
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

fn subschemaValidCached(ctx: Context, sub_schema: std.json.Value, instance: std.json.Value, cache: *std.AutoHashMap(usize, bool)) bool {
    const key: usize = switch (sub_schema) {
        .object => |o| @intFromPtr(o.keys().ptr),
        else => return ctx.isSubschemaValid(sub_schema, instance),
    };
    if (cache.get(key)) |result| return result;
    const result = ctx.isSubschemaValid(sub_schema, instance);
    cache.put(key, result) catch {};
    return result;
}

fn resolveRef(ctx: Context, ref_str: []const u8) ?std.json.Value {
    // Use compiled schema's pre-resolved local ref cache first
    if (ctx.compiled) |comp| {
        if (comp.resolveLocalRef(ref_str)) |resolved| return resolved;
    }

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

/// Look up pre-compiled patternProperties regex from the CompiledSchema for a given schema node.
fn getCompiledPatternProperties(ctx: Context, schema: std.json.Value) ?[]const compiled_mod.PatternPropertyEntry {
    const comp = ctx.compiled orelse return null;
    const node = comp.getNode(schema) orelse return null;
    for (node.validators) |v| {
        switch (v) {
            .pattern_properties_compiled => |pp| return pp,
            else => {},
        }
    }
    return null;
}

/// Check if a property name matches any pre-compiled pattern regex.
fn matchesAnyCompiledPattern(allocator: std.mem.Allocator, prop_name: []const u8, entries: []const compiled_mod.PatternPropertyEntry) bool {
    const prop_name_z = allocator.dupeZ(u8, prop_name) catch return false;
    for (entries) |entry| {
        if (!entry.regex.valid) continue;
        if (c_regex.regexec(&entry.regex.regex, prop_name_z.ptr, 0, null, 0) == 0) {
            return true;
        }
    }
    return false;
}
