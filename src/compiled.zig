const std = @import("std");
const Allocator = std.mem.Allocator;
const jsonschema = @import("main.zig");
const Validator = @import("validator.zig");
const SchemaRegistry = jsonschema.SchemaRegistry;

/// A pre-compiled schema that accelerates repeated validation.
///
/// Instead of scanning 30+ keyword hashmap lookups per schema node on every
/// validation, `CompiledSchema` walks the schema tree once and records which
/// keyword validators are actually present at each node.  The validate path
/// then iterates only the pre-built list.
pub const CompiledSchema = struct {
    arena: std.heap.ArenaAllocator,
    /// Map from schema object identity (keys ptr) to compiled node.
    node_map: NodeMap,
    /// The original schema value — callers must keep the parsed JSON alive.
    schema: std.json.Value,
    /// Whether the root schema is Draft 2020-12.
    is_2020: bool,
    /// Whether the validation vocabulary is disabled (custom metaschema).
    validation_vocab_disabled: bool,

    const NodeMap = std.HashMap(
        usize,
        *CompiledNode,
        std.hash_map.AutoContext(usize),
        std.hash_map.default_max_load_percentage,
    );

    /// Compile a schema into a CompiledSchema.
    /// The caller must ensure the `schema` JSON value outlives this CompiledSchema.
    /// An optional `registry` is used only during compile to pre-scan $id entries;
    /// it is NOT stored — callers pass their own registry at validation time.
    pub fn compile(
        child_allocator: Allocator,
        schema: std.json.Value,
        registry: ?*SchemaRegistry,
    ) CompiledSchema {
        var arena = std.heap.ArenaAllocator.init(child_allocator);
        const alloc = arena.allocator();

        // Detect draft version and vocabulary settings early
        const is_2020 = jsonschema.isDraft2020(schema);
        const validation_vocab_disabled = checkValidationVocabDisabled(schema, registry);

        var node_map = NodeMap.init(alloc);

        // Pre-scan $id entries into the registry so $ref resolution works during compile
        if (registry) |reg| {
            const root_id = getSchemaId(schema);
            reg.scanIds(root_id, schema);
        }

        // Recursively walk the schema tree and compile every object node.
        // Uses placeholder pattern: each node is registered before recursing
        // into sub-schemas, so child nodes are available for pre-linking.
        compileNode(alloc, schema, &node_map, is_2020, validation_vocab_disabled);

        return .{
            .arena = arena,
            .node_map = node_map,
            .schema = schema,
            .is_2020 = is_2020,
            .validation_vocab_disabled = validation_vocab_disabled,
        };
    }

    /// Look up the compiled node for a given schema object.
    /// Returns null if the schema is not an object or was not seen during compilation.
    pub fn getNode(self: *const CompiledSchema, schema: std.json.Value) ?*const CompiledNode {
        const obj = switch (schema) {
            .object => |o| o,
            else => return null,
        };
        const key = @intFromPtr(obj.keys().ptr);
        return self.node_map.get(key);
    }

    pub fn deinit(self: *CompiledSchema) void {
        self.arena.deinit();
    }
};

/// Compact type tag for fast type-only validation.
pub const SimpleType = enum(u8) {
    none = 0, // not a simple type-only schema
    null,
    boolean,
    integer,
    number,
    string,
    array,
    object,
};

/// A pre-linked reference to a sub-schema, storing both the compiled node
/// pointer (for fast validation) and the original JSON value (for slow path).
pub const LinkedSchema = struct {
    node: ?*const CompiledNode,
    value: std.json.Value,
};

/// A compiled property entry: property name + pre-linked sub-schema.
pub const PropertyEntry = struct {
    name: []const u8,
    schema: LinkedSchema,
};

/// Tagged union replacing function pointer + json value pairs.
/// Each variant carries pre-extracted native data, eliminating runtime
/// hash lookups and JSON-to-native conversions during validation.
pub const CompiledValidator = union(enum) {
    // Type checking
    type_single: SimpleType,
    type_multi: []const SimpleType,
    enum_check: std.json.Value,
    const_check: std.json.Value,

    // Numeric
    minimum: f64,
    maximum: f64,
    exclusive_minimum: f64,
    exclusive_maximum: f64,
    multiple_of: f64,

    // String
    min_length: u64,
    max_length: u64,
    pattern: std.json.Value,

    // Array
    min_items: u64,
    max_items: u64,
    unique_items: void,
    contains: std.json.Value,

    // Object
    required: []const []const u8,
    min_properties: u64,
    max_properties: u64,

    // Pre-linked sub-schema variants (sub-schemas resolved at compile time).
    // No keyword_value stored — validateAll sets current_keyword_value = null
    // so keyword functions fall back to ctx.schema.object.get(keyword_name).
    properties_compiled: []const PropertyEntry,
    all_of_compiled: []const LinkedSchema,
    one_of_compiled: []const LinkedSchema,
    any_of_compiled: []const LinkedSchema,
    not_compiled: LinkedSchema,
    items_compiled: struct {
        schema: LinkedSchema,
        prefix_count: usize,
    },

    // Complex keywords — keep as generic with function pointer fallback
    // These need full schema context (pattern matching, URI resolution, etc.)
    generic: struct {
        func: Validator.KeywordValidator,
        keyword_value: std.json.Value,
        keyword_name: []const u8,
    },
};

/// A pre-compiled schema node.  Stores only the keyword validators that are
/// actually present in the original schema object, avoiding the need to probe
/// the hashmap for all 30+ keywords at validation time.
pub const CompiledNode = struct {
    /// Pre-filtered list of validators as tagged unions with pre-extracted data.
    validators: []const CompiledValidator,
    /// True if this node has $ref AND the schema is Draft 7 (not 2020-12),
    /// meaning $ref overrides all sibling keywords.
    ref_overrides: bool,
    /// If this schema is simply {"type": "xxx"}, store the type tag for
    /// ultra-fast validation without going through the full validator dispatch.
    simple_type: SimpleType = .none,
    /// True if this schema has $id or $ref — needs slow path for URI resolution.
    needs_uri_resolution: bool = false,

    /// Ultra-fast boolean-only validation. No allocations, no error construction.
    /// Returns false on first failure. Only works for common keyword patterns;
    /// falls back to full validation for complex keywords.
    /// Returns null if this node has keywords that can't be inlined (caller must use FBA fallback).
    pub fn isValidFast(self: *const CompiledNode, instance: std.json.Value, compiled: *const CompiledSchema) ?bool {
        if (self.simple_type != .none) {
            return Validator.matchesSimpleType(instance, self.simple_type);
        }
        if (self.ref_overrides) return null; // can't inline $ref
        for (self.validators) |v| {
            const result = isValidatorValid(v, instance, compiled) orelse return null;
            if (!result) return false;
        }
        return true;
    }
};

/// Check if a single compiled validator is valid for an instance.
/// Returns null if the validator can't be inlined (caller must use full path).
fn isValidatorValid(v: CompiledValidator, instance: std.json.Value, compiled: *const CompiledSchema) ?bool {
    switch (v) {
        .type_single => |st| {
            return Validator.matchesSimpleType(instance, st);
        },
        .type_multi => |types| {
            for (types) |st| {
                if (Validator.matchesSimpleType(instance, st)) return true;
            }
            return false;
        },
        .enum_check => |enum_val| {
            const enum_array = switch (enum_val) {
                .array => |a| a.items,
                else => return true,
            };
            for (enum_array) |candidate| {
                if (@import("keywords/enum_keyword.zig").jsonEqual(instance, candidate)) return true;
            }
            return false;
        },
        .const_check => |const_val| {
            return @import("keywords/enum_keyword.zig").jsonEqual(instance, const_val);
        },
        .minimum => |limit| {
            return numCmp(instance, limit, .gte);
        },
        .maximum => |limit| {
            return numCmp(instance, limit, .lte);
        },
        .exclusive_minimum => |limit| {
            return numCmp(instance, limit, .gt);
        },
        .exclusive_maximum => |limit| {
            return numCmp(instance, limit, .lt);
        },
        .multiple_of => |divisor| {
            const n = getNumber(instance) orelse return true;
            if (divisor == 0) return true;
            const remainder = @rem(n, divisor);
            const tolerance: f64 = 1e-9;
            return @abs(remainder) <= tolerance or @abs(remainder) - @abs(divisor) >= -tolerance;
        },
        .min_length => |limit| {
            const s = switch (instance) {
                .string => |str| str,
                else => return true,
            };
            const len = std.unicode.utf8CountCodepoints(s) catch return true;
            return len >= limit;
        },
        .max_length => |limit| {
            const s = switch (instance) {
                .string => |str| str,
                else => return true,
            };
            const len = std.unicode.utf8CountCodepoints(s) catch return true;
            return len <= limit;
        },
        .pattern => return null, // needs regex, can't inline
        .min_items => |limit| {
            const arr = switch (instance) {
                .array => |a| a.items,
                else => return true,
            };
            return arr.len >= limit;
        },
        .max_items => |limit| {
            const arr = switch (instance) {
                .array => |a| a.items,
                else => return true,
            };
            return arr.len <= limit;
        },
        .unique_items => return null, // expensive, use generic path
        .contains => return null, // needs sub-schema validation
        .required => |names| {
            const obj = switch (instance) {
                .object => |o| o,
                else => return true,
            };
            for (names) |name| {
                if (obj.get(name) == null) return false;
            }
            return true;
        },
        .min_properties => |limit| {
            const obj = switch (instance) {
                .object => |o| o,
                else => return true,
            };
            return obj.count() >= limit;
        },
        .max_properties => |limit| {
            const obj = switch (instance) {
                .object => |o| o,
                else => return true,
            };
            return obj.count() <= limit;
        },
        .properties_compiled => |entries| {
            const inst_obj = switch (instance) {
                .object => |o| o,
                else => return true,
            };
            for (entries) |entry| {
                const inst_val = inst_obj.get(entry.name) orelse continue;
                const result = validateLinkedSchema(entry.schema, inst_val, compiled) orelse return null;
                if (!result) return false;
            }
            return true;
        },
        .all_of_compiled => |schemas| {
            for (schemas) |s| {
                const result = validateLinkedSchema(s, instance, compiled) orelse return null;
                if (!result) return false;
            }
            return true;
        },
        .one_of_compiled => |schemas| {
            var match_count: usize = 0;
            for (schemas) |s| {
                if (!@import("keywords/one_of.zig").couldMatch(s.value, instance)) continue;
                const result = validateLinkedSchema(s, instance, compiled) orelse return null;
                if (result) {
                    match_count += 1;
                    if (match_count > 1) return false;
                }
            }
            return match_count == 1;
        },
        .any_of_compiled => |schemas| {
            var any_null = false;
            for (schemas) |s| {
                if (validateLinkedSchema(s, instance, compiled)) |result| {
                    if (result) return true;
                } else {
                    any_null = true;
                }
            }
            if (any_null) return null;
            return false;
        },
        .not_compiled => |ls| {
            const result = validateLinkedSchema(ls, instance, compiled) orelse return null;
            return !result;
        },
        .items_compiled => |ic| {
            const arr = switch (instance) {
                .array => |a| a.items,
                else => return true,
            };
            if (arr.len <= ic.prefix_count) return true;
            for (arr[ic.prefix_count..]) |item| {
                const result = validateLinkedSchema(ic.schema, item, compiled) orelse return null;
                if (!result) return false;
            }
            return true;
        },
        .generic => return null, // can't inline generic validators
    }
}

fn getNumber(val: std.json.Value) ?f64 {
    return switch (val) {
        .integer => |n| @floatFromInt(n),
        .float => |f| f,
        else => null,
    };
}

const CmpOp = enum { gte, lte, gt, lt };

fn numCmp(instance: std.json.Value, limit: f64, op: CmpOp) bool {
    const n = getNumber(instance) orelse return true;
    return switch (op) {
        .gte => n >= limit,
        .lte => n <= limit,
        .gt => n > limit,
        .lt => n < limit,
    };
}

fn getUint(val: std.json.Value) ?u64 {
    return switch (val) {
        .integer => |n| if (n >= 0) @intCast(n) else null,
        .float => |f| if (f >= 0 and f == @trunc(f)) @intFromFloat(f) else null,
        else => null,
    };
}

/// Check if a linked schema's isValidFast is guaranteed to not return null
/// at the immediate level (no .generic, .pattern, .unique_items, .contains).
/// This is a 1-level check — deeper pre-linked variants may still return null.
fn validateLinkedSchema(ls: LinkedSchema, instance: std.json.Value, compiled: *const CompiledSchema) ?bool {
    if (ls.node) |node| {
        if (node.needs_uri_resolution) return null;
        return node.isValidFast(instance, compiled);
    }
    return switch (ls.value) {
        .bool => |b| b,
        else => null,
    };
}

fn linkSchema(node_map: *const CompiledSchema.NodeMap, value: std.json.Value) LinkedSchema {
    const node: ?*const CompiledNode = switch (value) {
        .object => |o| node_map.get(@intFromPtr(o.keys().ptr)),
        else => null,
    };
    return .{ .node = node, .value = value };
}

fn linkSchemaArray(alloc: Allocator, node_map: *const CompiledSchema.NodeMap, items: []const std.json.Value) []const LinkedSchema {
    var result = std.ArrayList(LinkedSchema).init(alloc);
    for (items) |item| {
        result.append(linkSchema(node_map, item)) catch {};
    }
    return result.toOwnedSlice() catch &.{};
}

// ---------------------------------------------------------------------------
// Compilation helpers
// ---------------------------------------------------------------------------

fn compileNode(
    alloc: Allocator,
    schema: std.json.Value,
    node_map: *CompiledSchema.NodeMap,
    is_2020: bool,
    validation_vocab_disabled: bool,
) void {
    switch (schema) {
        .object => |obj| {
            const key = @intFromPtr(obj.keys().ptr);
            if (node_map.get(key) != null) return;

            // 1. Register placeholder node (prevents infinite recursion on
            //    circular $ref and makes this node addressable by children).
            const node = alloc.create(CompiledNode) catch return;
            node.* = .{ .validators = &.{}, .ref_overrides = false };
            node_map.put(key, node) catch return;

            // 2. Recurse into sub-schemas so child nodes are available
            //    for pre-linking when we compile this node's keywords.
            recurseIntoSubSchemas(alloc, obj, node_map, is_2020, validation_vocab_disabled);

            // 3. Compile keywords with pre-linking via node_map.
            const has_ref = obj.get("$ref") != null;
            const ref_overrides = has_ref and !is_2020;
            var validators = std.ArrayList(CompiledValidator).init(alloc);
            if (!ref_overrides) {
                compileKeywords(alloc, obj, &validators, validation_vocab_disabled, node_map);
            }

            // 4. Fill in placeholder with actual data.
            node.* = .{
                .validators = validators.toOwnedSlice() catch &.{},
                .ref_overrides = ref_overrides,
                .simple_type = detectSimpleType(obj),
                .needs_uri_resolution = has_ref or obj.get("$id") != null,
            };
        },
        .array => |arr| {
            for (arr.items) |item| {
                compileNode(alloc, item, node_map, is_2020, validation_vocab_disabled);
            }
        },
        else => {},
    }
}

/// Compile keywords from a schema object into CompiledValidator entries.
/// Keywords are processed in the same order as the keyword_table to maintain
/// validation order consistency.
fn compileKeywords(
    alloc: Allocator,
    obj: std.json.ObjectMap,
    validators: *std.ArrayList(CompiledValidator),
    validation_vocab_disabled: bool,
    node_map: *const CompiledSchema.NodeMap,
) void {
    // Type checking
    if (obj.get("type")) |kv| {
        if (!validation_vocab_disabled) {
            if (compileType(alloc, kv)) |cv| {
                validators.append(cv) catch {};
            }
        }
    }
    if (obj.get("enum")) |kv| {
        if (!validation_vocab_disabled) {
            validators.append(.{ .enum_check = kv }) catch {};
        }
    }
    if (obj.get("const")) |kv| {
        if (!validation_vocab_disabled) {
            validators.append(.{ .const_check = kv }) catch {};
        }
    }

    // Numeric
    if (obj.get("minimum")) |kv| {
        if (!validation_vocab_disabled) {
            if (getNumber(kv)) |limit| {
                validators.append(.{ .minimum = limit }) catch {};
            }
        }
    }
    if (obj.get("maximum")) |kv| {
        if (!validation_vocab_disabled) {
            if (getNumber(kv)) |limit| {
                validators.append(.{ .maximum = limit }) catch {};
            }
        }
    }
    if (obj.get("exclusiveMinimum")) |kv| {
        if (!validation_vocab_disabled) {
            if (getNumber(kv)) |limit| {
                validators.append(.{ .exclusive_minimum = limit }) catch {};
            }
        }
    }
    if (obj.get("exclusiveMaximum")) |kv| {
        if (!validation_vocab_disabled) {
            if (getNumber(kv)) |limit| {
                validators.append(.{ .exclusive_maximum = limit }) catch {};
            }
        }
    }
    if (obj.get("multipleOf")) |kv| {
        if (!validation_vocab_disabled) {
            if (getNumber(kv)) |divisor| {
                validators.append(.{ .multiple_of = divisor }) catch {};
            }
        }
    }

    // String
    if (obj.get("minLength")) |kv| {
        if (!validation_vocab_disabled) {
            if (getUint(kv)) |limit| {
                validators.append(.{ .min_length = limit }) catch {};
            }
        }
    }
    if (obj.get("maxLength")) |kv| {
        if (!validation_vocab_disabled) {
            if (getUint(kv)) |limit| {
                validators.append(.{ .max_length = limit }) catch {};
            }
        }
    }
    if (obj.get("pattern")) |kv| {
        validators.append(.{ .generic = .{
            .func = @import("keywords/pattern.zig").validate,
            .keyword_value = kv,
            .keyword_name = "pattern",
        } }) catch {};
    }

    // Array
    if (obj.get("prefixItems")) |kv| {
        validators.append(.{ .generic = .{
            .func = @import("keywords/prefix_items.zig").validate,
            .keyword_value = kv,
            .keyword_name = "prefixItems",
        } }) catch {};
    }
    if (obj.get("items")) |kv| {
        switch (kv) {
            .object, .bool => {
                validators.append(.{ .items_compiled = .{
                    .schema = linkSchema(node_map, kv),
                    .prefix_count = if (obj.get("prefixItems")) |pi| switch (pi) {
                        .array => |a| a.items.len,
                        else => 0,
                    } else 0,
                } }) catch {};
            },
            else => {
                validators.append(.{ .generic = .{
                    .func = @import("keywords/items.zig").validate,
                    .keyword_value = kv,
                    .keyword_name = "items",
                } }) catch {};
            },
        }
    }
    if (obj.get("additionalItems")) |kv| {
        validators.append(.{ .generic = .{
            .func = @import("keywords/additional_items.zig").validate,
            .keyword_value = kv,
            .keyword_name = "additionalItems",
        } }) catch {};
    }
    if (obj.get("minItems")) |kv| {
        if (!validation_vocab_disabled) {
            if (getUint(kv)) |limit| {
                validators.append(.{ .min_items = limit }) catch {};
            }
        }
    }
    if (obj.get("maxItems")) |kv| {
        if (!validation_vocab_disabled) {
            if (getUint(kv)) |limit| {
                validators.append(.{ .max_items = limit }) catch {};
            }
        }
    }
    if (obj.get("uniqueItems")) |kv| {
        if (!validation_vocab_disabled) {
            // Only add if uniqueItems is true
            switch (kv) {
                .bool => |b| {
                    if (b) {
                        validators.append(.{ .generic = .{
                            .func = @import("keywords/unique_items.zig").validate,
                            .keyword_value = kv,
                            .keyword_name = "uniqueItems",
                        } }) catch {};
                    }
                },
                else => {},
            }
        }
    }
    if (obj.get("contains")) |kv| {
        validators.append(.{ .generic = .{
            .func = @import("keywords/contains.zig").validate,
            .keyword_value = kv,
            .keyword_name = "contains",
        } }) catch {};
    }

    // Object
    if (obj.get("properties")) |kv| {
        switch (kv) {
            .object => |props_obj| {
                var entries = std.ArrayList(PropertyEntry).init(alloc);
                var it = props_obj.iterator();
                while (it.next()) |entry| {
                    entries.append(.{
                        .name = entry.key_ptr.*,
                        .schema = linkSchema(node_map, entry.value_ptr.*),
                    }) catch {};
                }
                validators.append(.{ .properties_compiled = entries.toOwnedSlice() catch &.{} }) catch {};
            },
            else => {},
        }
    }
    if (obj.get("required")) |kv| {
        if (!validation_vocab_disabled) {
            if (compileRequired(alloc, kv)) |names| {
                validators.append(.{ .required = names }) catch {};
            }
        }
    }
    if (obj.get("additionalProperties")) |kv| {
        validators.append(.{ .generic = .{
            .func = @import("keywords/additional_properties.zig").validate,
            .keyword_value = kv,
            .keyword_name = "additionalProperties",
        } }) catch {};
    }
    if (obj.get("patternProperties")) |kv| {
        validators.append(.{ .generic = .{
            .func = @import("keywords/pattern_properties.zig").validate,
            .keyword_value = kv,
            .keyword_name = "patternProperties",
        } }) catch {};
    }
    if (obj.get("minProperties")) |kv| {
        if (!validation_vocab_disabled) {
            if (getUint(kv)) |limit| {
                validators.append(.{ .min_properties = limit }) catch {};
            }
        }
    }
    if (obj.get("maxProperties")) |kv| {
        if (!validation_vocab_disabled) {
            if (getUint(kv)) |limit| {
                validators.append(.{ .max_properties = limit }) catch {};
            }
        }
    }
    if (obj.get("propertyNames")) |kv| {
        validators.append(.{ .generic = .{
            .func = @import("keywords/property_names.zig").validate,
            .keyword_value = kv,
            .keyword_name = "propertyNames",
        } }) catch {};
    }
    if (obj.get("dependencies")) |kv| {
        validators.append(.{ .generic = .{
            .func = @import("keywords/dependencies.zig").validate,
            .keyword_value = kv,
            .keyword_name = "dependencies",
        } }) catch {};
    }
    if (obj.get("dependentRequired")) |kv| {
        if (!validation_vocab_disabled) {
            validators.append(.{ .generic = .{
                .func = @import("keywords/dependent_required.zig").validate,
                .keyword_value = kv,
                .keyword_name = "dependentRequired",
            } }) catch {};
        }
    }
    if (obj.get("dependentSchemas")) |kv| {
        validators.append(.{ .generic = .{
            .func = @import("keywords/dependent_schemas.zig").validate,
            .keyword_value = kv,
            .keyword_name = "dependentSchemas",
        } }) catch {};
    }

    // Logical composition
    if (obj.get("allOf")) |kv| {
        switch (kv) {
            .array => |arr| {
                validators.append(.{ .all_of_compiled = linkSchemaArray(alloc, node_map, arr.items) }) catch {};
            },
            else => {},
        }
    }
    if (obj.get("anyOf")) |kv| {
        switch (kv) {
            .array => |arr| {
                validators.append(.{ .any_of_compiled = linkSchemaArray(alloc, node_map, arr.items) }) catch {};
            },
            else => {},
        }
    }
    if (obj.get("oneOf")) |kv| {
        switch (kv) {
            .array => |arr| {
                validators.append(.{ .one_of_compiled = linkSchemaArray(alloc, node_map, arr.items) }) catch {};
            },
            else => {},
        }
    }
    if (obj.get("not")) |kv| {
        validators.append(.{ .not_compiled = linkSchema(node_map, kv) }) catch {};
    }

    // Reference
    if (obj.get("$ref")) |kv| {
        validators.append(.{ .generic = .{
            .func = @import("keywords/ref.zig").validate,
            .keyword_value = kv,
            .keyword_name = "$ref",
        } }) catch {};
    }
    if (obj.get("$dynamicRef")) |kv| {
        validators.append(.{ .generic = .{
            .func = @import("keywords/dynamic_ref.zig").validate,
            .keyword_value = kv,
            .keyword_name = "$dynamicRef",
        } }) catch {};
    }

    // Conditional
    if (obj.get("if")) |kv| {
        validators.append(.{ .generic = .{
            .func = @import("keywords/if_then_else.zig").validate,
            .keyword_value = kv,
            .keyword_name = "if",
        } }) catch {};
    }

    // Unevaluated (must be last — depends on other keywords' evaluations)
    if (obj.get("unevaluatedProperties")) |kv| {
        validators.append(.{ .generic = .{
            .func = @import("keywords/unevaluated_properties.zig").validate,
            .keyword_value = kv,
            .keyword_name = "unevaluatedProperties",
        } }) catch {};
    }
    if (obj.get("unevaluatedItems")) |kv| {
        validators.append(.{ .generic = .{
            .func = @import("keywords/unevaluated_items.zig").validate,
            .keyword_value = kv,
            .keyword_name = "unevaluatedItems",
        } }) catch {};
    }
}

/// Compile a "type" keyword value into a CompiledValidator.
fn compileType(alloc: Allocator, type_val: std.json.Value) ?CompiledValidator {
    switch (type_val) {
        .string => |s| {
            const st = detectSimpleTypeFromString(s);
            if (st != .none) return .{ .type_single = st };
            return null;
        },
        .array => |arr| {
            var types = std.ArrayList(SimpleType).init(alloc);
            for (arr.items) |item| {
                switch (item) {
                    .string => |s| {
                        const st = detectSimpleTypeFromString(s);
                        if (st != .none) {
                            types.append(st) catch {};
                        }
                    },
                    else => {},
                }
            }
            if (types.items.len > 0) {
                return .{ .type_multi = types.toOwnedSlice() catch &.{} };
            }
            return null;
        },
        else => return null,
    }
}

/// Compile a "required" keyword value into a pre-extracted string slice.
fn compileRequired(alloc: Allocator, req_val: std.json.Value) ?[]const []const u8 {
    const arr = switch (req_val) {
        .array => |a| a.items,
        else => return null,
    };
    var names = std.ArrayList([]const u8).init(alloc);
    for (arr) |item| {
        switch (item) {
            .string => |s| {
                names.append(s) catch {};
            },
            else => {},
        }
    }
    if (names.items.len > 0) {
        return names.toOwnedSlice() catch null;
    }
    return null;
}

fn detectSimpleTypeFromString(t: []const u8) SimpleType {
    if (std.mem.eql(u8, t, "null")) return .null;
    if (std.mem.eql(u8, t, "boolean")) return .boolean;
    if (std.mem.eql(u8, t, "integer")) return .integer;
    if (std.mem.eql(u8, t, "number")) return .number;
    if (std.mem.eql(u8, t, "string")) return .string;
    if (std.mem.eql(u8, t, "array")) return .array;
    if (std.mem.eql(u8, t, "object")) return .object;
    return .none;
}

/// Recurse into known sub-schema positions within a schema object.
fn recurseIntoSubSchemas(
    alloc: Allocator,
    obj: std.json.ObjectMap,
    node_map: *CompiledSchema.NodeMap,
    is_2020: bool,
    validation_vocab_disabled: bool,
) void {
    // Sub-schema keywords (single schema)
    const single_schema_keywords = [_][]const u8{
        "additionalProperties", "additionalItems", "contains",
        "if",                   "then",            "else",
        "not",                  "items",           "propertyNames",
        "unevaluatedItems",     "unevaluatedProperties",
    };

    inline for (single_schema_keywords) |kw| {
        if (obj.get(kw)) |val| {
            compileNode(alloc, val, node_map, is_2020, validation_vocab_disabled);
        }
    }

    // Sub-schema keywords (array of schemas)
    const array_schema_keywords = [_][]const u8{
        "allOf", "anyOf", "oneOf", "prefixItems",
    };

    inline for (array_schema_keywords) |kw| {
        if (obj.get(kw)) |val| {
            switch (val) {
                .array => |arr| {
                    for (arr.items) |item| {
                        compileNode(alloc, item, node_map, is_2020, validation_vocab_disabled);
                    }
                },
                else => {},
            }
        }
    }

    // Sub-schema keywords (object mapping string -> schema)
    const object_schema_keywords = [_][]const u8{
        "properties",      "patternProperties", "definitions",
        "$defs",           "dependencies",      "dependentSchemas",
        "dependentRequired",
    };

    inline for (object_schema_keywords) |kw| {
        if (obj.get(kw)) |val| {
            switch (val) {
                .object => |inner_obj| {
                    var it = inner_obj.iterator();
                    while (it.next()) |entry| {
                        compileNode(alloc, entry.value_ptr.*, node_map, is_2020, validation_vocab_disabled);
                    }
                },
                else => {},
            }
        }
    }

    // items can be an array of schemas (Draft 7 tuple validation)
    if (obj.get("items")) |items_val| {
        switch (items_val) {
            .array => |arr| {
                for (arr.items) |item| {
                    compileNode(alloc, item, node_map, is_2020, validation_vocab_disabled);
                }
            },
            else => {}, // already handled as single schema above
        }
    }
}

/// Check if a schema object is simply {"type": "xxx"} with no other keywords.
fn detectSimpleType(obj: std.json.ObjectMap) SimpleType {
    const type_val = obj.get("type") orelse return .none;
    const type_str = switch (type_val) {
        .string => |s| s,
        else => return .none,
    };

    // Check that all other keys are annotations (no validation keywords besides "type")
    var it = obj.iterator();
    while (it.next()) |entry| {
        const k = entry.key_ptr.*;
        if (std.mem.eql(u8, k, "type")) continue;
        if (isAnnotationOnly(k)) continue;
        return .none; // has a validation keyword other than type
    }

    if (std.mem.eql(u8, type_str, "null")) return .null;
    if (std.mem.eql(u8, type_str, "boolean")) return .boolean;
    if (std.mem.eql(u8, type_str, "integer")) return .integer;
    if (std.mem.eql(u8, type_str, "number")) return .number;
    if (std.mem.eql(u8, type_str, "string")) return .string;
    if (std.mem.eql(u8, type_str, "array")) return .array;
    if (std.mem.eql(u8, type_str, "object")) return .object;
    return .none;
}

fn isAnnotationOnly(key: []const u8) bool {
    const annotations = [_][]const u8{
        "description", "title",    "$comment", "default",
        "examples",    "format",   "$id",      "$schema",
        "readOnly",    "writeOnly", "$anchor", "$defs",
        "definitions", "deprecated",
    };
    for (annotations) |a| {
        if (std.mem.eql(u8, key, a)) return true;
    }
    return false;
}

fn getSchemaId(schema: std.json.Value) []const u8 {
    const obj = switch (schema) {
        .object => |o| o,
        else => return "",
    };
    const id_val = obj.get("$id") orelse return "";
    return switch (id_val) {
        .string => |s| s,
        else => "",
    };
}

/// Check if the validation vocabulary is disabled by a custom metaschema.
fn checkValidationVocabDisabled(schema: std.json.Value, registry: ?*SchemaRegistry) bool {
    const root_obj = switch (schema) {
        .object => |o| o,
        else => return false,
    };
    const schema_uri = switch (root_obj.get("$schema") orelse return false) {
        .string => |s| s,
        else => return false,
    };
    // Standard 2020-12 schema has validation enabled
    if (std.mem.indexOf(u8, schema_uri, "json-schema.org/draft/2020-12/schema") != null) return false;

    // Look up the metaschema in the registry
    const reg = registry orelse return false;
    const metaschema = reg.schemas.get(schema_uri) orelse return false;
    const meta_obj = switch (metaschema) {
        .object => |o| o,
        else => return false,
    };
    const vocab = meta_obj.get("$vocabulary") orelse return false;
    const vocab_obj = switch (vocab) {
        .object => |o| o,
        else => return false,
    };

    return vocab_obj.get("https://json-schema.org/draft/2020-12/vocab/validation") == null;
}

test "compile empty schema" {
    const alloc = std.testing.allocator;
    const schema_str = "{}";
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, schema_str, .{});
    defer parsed.deinit();

    var compiled = CompiledSchema.compile(alloc, parsed.value, null);
    defer compiled.deinit();

    // Empty schema should have a node with 0 validators
    const node = compiled.getNode(parsed.value);
    try std.testing.expect(node != null);
    try std.testing.expectEqual(@as(usize, 0), node.?.validators.len);
}

test "compile schema with type keyword" {
    const alloc = std.testing.allocator;
    const schema_str =
        \\{"type": "string"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, schema_str, .{});
    defer parsed.deinit();

    var compiled = CompiledSchema.compile(alloc, parsed.value, null);
    defer compiled.deinit();

    const node = compiled.getNode(parsed.value);
    try std.testing.expect(node != null);
    try std.testing.expectEqual(@as(usize, 1), node.?.validators.len);
}

test "compile schema with properties recurses" {
    const alloc = std.testing.allocator;
    const schema_str =
        \\{"type": "object", "properties": {"name": {"type": "string"}}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, schema_str, .{});
    defer parsed.deinit();

    var compiled = CompiledSchema.compile(alloc, parsed.value, null);
    defer compiled.deinit();

    // Root node: type + properties = 2 validators
    const root_node = compiled.getNode(parsed.value);
    try std.testing.expect(root_node != null);
    try std.testing.expectEqual(@as(usize, 2), root_node.?.validators.len);

    // Sub-schema {"type": "string"} should also be compiled
    const props = parsed.value.object.get("properties").?.object;
    const name_schema_val = props.get("name").?;
    const name_node = compiled.getNode(name_schema_val);
    try std.testing.expect(name_node != null);
    try std.testing.expectEqual(@as(usize, 1), name_node.?.validators.len);
}

test "compiled validation produces correct results" {
    const backing = std.testing.allocator;

    // Schema with multiple keywords
    const schema_str =
        \\{"type": "object", "properties": {"name": {"type": "string"}, "age": {"type": "integer", "minimum": 0}}, "required": ["name"]}
    ;
    const parsed_schema = try std.json.parseFromSlice(std.json.Value, backing, schema_str, .{});
    defer parsed_schema.deinit();

    var compiled = CompiledSchema.compile(backing, parsed_schema.value, null);
    defer compiled.deinit();

    // Valid instance
    {
        var arena = std.heap.ArenaAllocator.init(backing);
        defer arena.deinit();
        const alloc = arena.allocator();
        const instance_str =
            \\{"name": "Alice", "age": 30}
        ;
        const parsed_instance = try std.json.parseFromSlice(std.json.Value, backing, instance_str, .{});
        defer parsed_instance.deinit();

        const result = jsonschema.validateCompiled(alloc, &compiled, parsed_instance.value);
        try std.testing.expect(result.isValid());
    }

    // Invalid: wrong type for name
    {
        var arena = std.heap.ArenaAllocator.init(backing);
        defer arena.deinit();
        const alloc = arena.allocator();
        const instance_str =
            \\{"name": 42}
        ;
        const parsed_instance = try std.json.parseFromSlice(std.json.Value, backing, instance_str, .{});
        defer parsed_instance.deinit();

        const result = jsonschema.validateCompiled(alloc, &compiled, parsed_instance.value);
        try std.testing.expect(!result.isValid());
    }

    // Invalid: missing required property
    {
        var arena = std.heap.ArenaAllocator.init(backing);
        defer arena.deinit();
        const alloc = arena.allocator();
        const instance_str =
            \\{"age": 30}
        ;
        const parsed_instance = try std.json.parseFromSlice(std.json.Value, backing, instance_str, .{});
        defer parsed_instance.deinit();

        const result = jsonschema.validateCompiled(alloc, &compiled, parsed_instance.value);
        try std.testing.expect(!result.isValid());
    }

    // Invalid: negative age (minimum violation)
    {
        var arena = std.heap.ArenaAllocator.init(backing);
        defer arena.deinit();
        const alloc = arena.allocator();
        const instance_str =
            \\{"name": "Bob", "age": -5}
        ;
        const parsed_instance = try std.json.parseFromSlice(std.json.Value, backing, instance_str, .{});
        defer parsed_instance.deinit();

        const result = jsonschema.validateCompiled(alloc, &compiled, parsed_instance.value);
        try std.testing.expect(!result.isValid());
    }
}

test "compiled validation with $ref" {
    const backing = std.testing.allocator;

    const schema_str =
        \\{"definitions": {"str": {"type": "string"}}, "properties": {"name": {"$ref": "#/definitions/str"}}}
    ;
    const parsed_schema = try std.json.parseFromSlice(std.json.Value, backing, schema_str, .{});
    defer parsed_schema.deinit();

    var compiled = CompiledSchema.compile(backing, parsed_schema.value, null);
    defer compiled.deinit();

    // Valid
    {
        var arena = std.heap.ArenaAllocator.init(backing);
        defer arena.deinit();
        const alloc = arena.allocator();
        const instance_str =
            \\{"name": "Alice"}
        ;
        const parsed_instance = try std.json.parseFromSlice(std.json.Value, backing, instance_str, .{});
        defer parsed_instance.deinit();

        const result = jsonschema.validateCompiled(alloc, &compiled, parsed_instance.value);
        try std.testing.expect(result.isValid());
    }

    // Invalid
    {
        var arena = std.heap.ArenaAllocator.init(backing);
        defer arena.deinit();
        const alloc = arena.allocator();
        const instance_str =
            \\{"name": 42}
        ;
        const parsed_instance = try std.json.parseFromSlice(std.json.Value, backing, instance_str, .{});
        defer parsed_instance.deinit();

        const result = jsonschema.validateCompiled(alloc, &compiled, parsed_instance.value);
        try std.testing.expect(!result.isValid());
    }
}

test "compiled validation with boolean schema" {
    const backing = std.testing.allocator;

    // false schema rejects everything - boolean schemas bypass compilation
    {
        var arena = std.heap.ArenaAllocator.init(backing);
        defer arena.deinit();
        const alloc = arena.allocator();
        const schema_str = "false";
        const parsed_schema = try std.json.parseFromSlice(std.json.Value, backing, schema_str, .{});
        defer parsed_schema.deinit();

        var compiled = CompiledSchema.compile(backing, parsed_schema.value, null);
        defer compiled.deinit();

        const instance_str = "42";
        const parsed_instance = try std.json.parseFromSlice(std.json.Value, backing, instance_str, .{});
        defer parsed_instance.deinit();

        const result = jsonschema.validateCompiled(alloc, &compiled, parsed_instance.value);
        try std.testing.expect(!result.isValid());
    }

    // true schema accepts everything
    {
        var arena = std.heap.ArenaAllocator.init(backing);
        defer arena.deinit();
        const alloc = arena.allocator();
        const schema_str = "true";
        const parsed_schema = try std.json.parseFromSlice(std.json.Value, backing, schema_str, .{});
        defer parsed_schema.deinit();

        var compiled = CompiledSchema.compile(backing, parsed_schema.value, null);
        defer compiled.deinit();

        const instance_str = "42";
        const parsed_instance = try std.json.parseFromSlice(std.json.Value, backing, instance_str, .{});
        defer parsed_instance.deinit();

        const result = jsonschema.validateCompiled(alloc, &compiled, parsed_instance.value);
        try std.testing.expect(result.isValid());
    }
}

test "compiled validation with allOf/anyOf/oneOf" {
    const backing = std.testing.allocator;

    const schema_str =
        \\{"oneOf": [{"type": "string"}, {"type": "integer"}]}
    ;
    const parsed_schema = try std.json.parseFromSlice(std.json.Value, backing, schema_str, .{});
    defer parsed_schema.deinit();

    var compiled = CompiledSchema.compile(backing, parsed_schema.value, null);
    defer compiled.deinit();

    // Valid: string
    {
        var arena = std.heap.ArenaAllocator.init(backing);
        defer arena.deinit();
        const alloc = arena.allocator();
        const instance_str =
            \\"hello"
        ;
        const parsed_instance = try std.json.parseFromSlice(std.json.Value, backing, instance_str, .{});
        defer parsed_instance.deinit();

        const result = jsonschema.validateCompiled(alloc, &compiled, parsed_instance.value);
        try std.testing.expect(result.isValid());
    }

    // Invalid: array (matches neither)
    {
        var arena = std.heap.ArenaAllocator.init(backing);
        defer arena.deinit();
        const alloc = arena.allocator();
        const instance_str = "[1,2,3]";
        const parsed_instance = try std.json.parseFromSlice(std.json.Value, backing, instance_str, .{});
        defer parsed_instance.deinit();

        const result = jsonschema.validateCompiled(alloc, &compiled, parsed_instance.value);
        try std.testing.expect(!result.isValid());
    }
}
