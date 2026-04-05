const std = @import("std");
const Allocator = std.mem.Allocator;
const jsonschema = @import("main.zig");
const ValidationError = jsonschema.ValidationError;
const JsonPointer = jsonschema.JsonPointer;
const compiled_mod = @import("compiled.zig");
const CompiledSchema = compiled_mod.CompiledSchema;
const SimpleType = compiled_mod.SimpleType;

/// Fast inline type check without going through the full validator dispatch.
pub fn matchesSimpleType(instance: std.json.Value, simple_type: SimpleType) bool {
    return switch (simple_type) {
        .none => true,
        .null => instance == .null,
        .boolean => instance == .bool,
        .integer => switch (instance) {
            .integer => true,
            .float => |f| @floor(f) == f and !std.math.isNan(f) and !std.math.isInf(f),
            else => false,
        },
        .number => instance == .integer or instance == .float,
        .string => instance == .string,
        .array => instance == .array,
        .object => instance == .object,
    };
}

/// Dynamic scope entry: tracks which schema resource is being evaluated
pub const DynamicScopeEntry = struct {
    base_uri: []const u8,
    schema: std.json.Value,
};

/// Context passed to every keyword validator.
pub const Context = struct {
    allocator: Allocator,
    root_schema: std.json.Value,
    schema: std.json.Value,
    instance: std.json.Value,
    instance_path: []const u8,
    schema_path: []const u8,
    errors: *std.ArrayList(ValidationError),
    registry: ?*jsonschema.SchemaRegistry = null,
    base_uri: []const u8 = "",
    /// Base URI before this schema's own $id is applied.
    /// Used by $ref to avoid sibling $id changing its resolution scope.
    ref_base_uri: []const u8 = "",
    /// Dynamic scope stack for $dynamicRef resolution
    dynamic_scope: ?*std.ArrayList(DynamicScopeEntry) = null,
    /// Pre-compiled schema for fast dispatch (null = use legacy path).
    compiled: ?*const CompiledSchema = null,
    /// Pre-looked-up compiled node for the current schema.
    /// When set, validateAll skips the hashmap lookup entirely.
    compiled_node: ?*const compiled_mod.CompiledNode = null,
    /// Tracked evaluated property names for unevaluatedProperties optimization.
    /// Non-null only within nodes that have unevaluatedProperties.
    evaluated_props: ?*std.StringHashMap(void) = null,
    /// Current keyword value, set by compiled dispatch to avoid re-lookup.
    current_keyword_value: ?std.json.Value = null,

    /// Recursively validate instance against a sub-schema.
    pub fn validateSubschema(
        self: Context,
        sub_schema: std.json.Value,
        instance: std.json.Value,
        instance_path: []const u8,
        schema_path: []const u8,
    ) jsonschema.ValidationResult {
        // Fast path: when compiled schema is available, skip validateFull overhead
        // (no isDraft2020 check, no $id resolution, no registry lookup, no dynamic_scope push/pop)
        if (self.compiled) |compiled| {
            switch (sub_schema) {
                .bool => |b| {
                    if (b) {
                        return .{ .errors = &.{}, .allocator = self.allocator };
                    } else {
                        // false schema rejects everything
                        const err = jsonschema.ValidationError{
                            .instance_path = self.allocator.dupe(u8, instance_path) catch "",
                            .schema_path = self.allocator.dupe(u8, schema_path) catch "",
                            .keyword = "false schema",
                            .message = self.allocator.dupe(u8, "Schema is false — all values are rejected") catch "",
                        };
                        const errors = self.allocator.alloc(jsonschema.ValidationError, 1) catch return .{ .errors = &.{}, .allocator = self.allocator };
                        errors[0] = err;
                        return .{ .errors = errors, .allocator = self.allocator };
                    }
                },
                .object => {
                    const looked_up_node = compiled.getNode(sub_schema);
                    if (looked_up_node) |node| {
                        // Allow fast path when URI resolution isn't truly needed:
                        // - No $id on this node (scope doesn't change)
                        // - OR no registry (all refs are local/pre-linked)
                        const can_skip_uri = !node.needs_uri_resolution or
                            (!node.has_id and self.registry == null);
                        if (can_skip_uri) {
                            if (node.simple_type != .none) {
                                if (matchesSimpleType(instance, node.simple_type)) {
                                    return .{ .errors = &.{}, .allocator = self.allocator };
                                } else {
                                    const err = jsonschema.ValidationError{
                                        .instance_path = self.allocator.dupe(u8, instance_path) catch "",
                                        .schema_path = self.allocator.dupe(u8, schema_path) catch "",
                                        .keyword = "type",
                                        .message = self.allocator.dupe(u8, "Instance does not match the expected type") catch "",
                                    };
                                    const errs = self.allocator.alloc(jsonschema.ValidationError, 1) catch return .{ .errors = &.{}, .allocator = self.allocator };
                                    errs[0] = err;
                                    return .{ .errors = errs, .allocator = self.allocator };
                                }
                            }
                            // Non-simple, non-URI: use compiled dispatch
                            var errors = std.ArrayList(jsonschema.ValidationError).init(self.allocator);
                            const child = Context{
                                .allocator = self.allocator,
                                .root_schema = self.root_schema,
                                .schema = sub_schema,
                                .instance = instance,
                                .instance_path = instance_path,
                                .schema_path = schema_path,
                                .errors = &errors,
                                .registry = self.registry,
                                .base_uri = self.base_uri,
                                .ref_base_uri = self.base_uri,
                                .dynamic_scope = self.dynamic_scope,
                                .compiled = self.compiled,
                                .compiled_node = node,
                            };
                            validateAll(child);
                            if (errors.items.len == 0) {
                                return .{ .errors = &.{}, .allocator = self.allocator };
                            }
                            return .{
                                .errors = errors.toOwnedSlice() catch &.{},
                                .allocator = self.allocator,
                            };
                        }
                        // needs_uri_resolution — fall through to slow path
                    }
                },
                else => {
                    return .{ .errors = &.{}, .allocator = self.allocator };
                },
            }
        }

        // Slow path: full validation with $id resolution, draft detection, etc.
        return jsonschema.validateFull(
            self.allocator,
            self.root_schema,
            sub_schema,
            instance,
            instance_path,
            schema_path,
            self.registry,
            self.base_uri,
            self.dynamic_scope,
            self.compiled,
        );
    }

    /// Check if a sub-schema validates without collecting errors.
    /// Much faster than validateSubschema when you only need a boolean result.
    pub fn isSubschemaValid(
        self: Context,
        sub_schema: std.json.Value,
        instance: std.json.Value,
    ) bool {
        // Fast path: compiled schemas
        if (self.compiled) |compiled| {
            switch (sub_schema) {
                .bool => |b| return b,
                .object => {
                    if (compiled.getNode(sub_schema)) |node| {
                        const can_skip = !node.needs_uri_resolution or
                            (!node.has_id and self.registry == null);
                        if (can_skip) {
                            if (node.isValidFast(instance, compiled)) |result| return result;
                        }
                    }
                },
                else => return true,
            }
        }

        // Slow path: full validation with proper URI resolution
        const result = jsonschema.validateFull(
            self.allocator,
            self.root_schema,
            sub_schema,
            instance,
            "",
            "",
            self.registry,
            self.base_uri,
            self.dynamic_scope,
            self.compiled,
        );
        defer result.deinit();
        return result.isValid();
    }

    pub fn isSubschemaValidWithNode(
        self: Context,
        sub_schema: std.json.Value,
        instance: std.json.Value,
        pre_node: ?*const compiled_mod.CompiledNode,
    ) bool {
        if (self.compiled) |compiled| {
            switch (sub_schema) {
                .bool => |b| return b,
                .object => {
                    const node = pre_node orelse compiled.getNode(sub_schema);
                    if (node) |n| {
                        const can_skip = !n.needs_uri_resolution or
                            (!n.has_id and self.registry == null);
                        if (can_skip) {
                            if (n.isValidFast(instance, compiled)) |result| return result;
                        }
                    }
                },
                else => return true,
            }
        }
        const result = jsonschema.validateFull(
            self.allocator,
            self.root_schema,
            sub_schema,
            instance,
            "",
            "",
            self.registry,
            self.base_uri,
            self.dynamic_scope,
            self.compiled,
        );
        defer result.deinit();
        return result.isValid();
    }

    /// Add a validation error to the error list.
    pub fn addError(self: Context, keyword: []const u8, message: []const u8) void {
        const schema_p = JsonPointer.appendProperty(self.allocator, self.schema_path, keyword);
        self.errors.append(.{
            .instance_path = self.allocator.dupe(u8, self.instance_path) catch return,
            .schema_path = schema_p,
            .keyword = keyword,
            .message = self.allocator.dupe(u8, message) catch return,
        }) catch return;
    }
};

/// Keyword validator function signature.
pub const KeywordValidator = *const fn (ctx: Context) void;


/// Registry of keyword validators.
/// Each keyword maps to a validation function.
/// To add a new keyword, add an entry to this table and create the
/// corresponding file in src/keywords/.
pub const keyword_table = .{
    // Type checking
    .{ "type", @import("keywords/type_keyword.zig").validate },
    .{ "enum", @import("keywords/enum_keyword.zig").validate },
    .{ "const", @import("keywords/const_keyword.zig").validate },
    // Numeric
    .{ "minimum", @import("keywords/minimum.zig").validate },
    .{ "maximum", @import("keywords/maximum.zig").validate },
    .{ "exclusiveMinimum", @import("keywords/exclusive_minimum.zig").validate },
    .{ "exclusiveMaximum", @import("keywords/exclusive_maximum.zig").validate },
    .{ "multipleOf", @import("keywords/multiple_of.zig").validate },
    // String
    .{ "minLength", @import("keywords/min_length.zig").validate },
    .{ "maxLength", @import("keywords/max_length.zig").validate },
    .{ "pattern", @import("keywords/pattern.zig").validate },
    // Array
    .{ "prefixItems", @import("keywords/prefix_items.zig").validate },
    .{ "items", @import("keywords/items.zig").validate },
    .{ "additionalItems", @import("keywords/additional_items.zig").validate },
    .{ "minItems", @import("keywords/min_items.zig").validate },
    .{ "maxItems", @import("keywords/max_items.zig").validate },
    .{ "uniqueItems", @import("keywords/unique_items.zig").validate },
    .{ "contains", @import("keywords/contains.zig").validate },
    // Object
    .{ "properties", @import("keywords/properties.zig").validate },
    .{ "required", @import("keywords/required.zig").validate },
    .{ "additionalProperties", @import("keywords/additional_properties.zig").validate },
    .{ "patternProperties", @import("keywords/pattern_properties.zig").validate },
    .{ "minProperties", @import("keywords/min_properties.zig").validate },
    .{ "maxProperties", @import("keywords/max_properties.zig").validate },
    .{ "propertyNames", @import("keywords/property_names.zig").validate },
    .{ "dependencies", @import("keywords/dependencies.zig").validate },
    .{ "dependentRequired", @import("keywords/dependent_required.zig").validate },
    .{ "dependentSchemas", @import("keywords/dependent_schemas.zig").validate },
    // Logical composition
    .{ "allOf", @import("keywords/all_of.zig").validate },
    .{ "anyOf", @import("keywords/any_of.zig").validate },
    .{ "oneOf", @import("keywords/one_of.zig").validate },
    .{ "not", @import("keywords/not_keyword.zig").validate },
    // Reference
    .{ "$ref", @import("keywords/ref.zig").validate },
    .{ "$dynamicRef", @import("keywords/dynamic_ref.zig").validate },
    // Conditional
    .{ "if", @import("keywords/if_then_else.zig").validate },
    // Unevaluated (must be last — depends on other keywords' evaluations)
    .{ "unevaluatedProperties", @import("keywords/unevaluated_properties.zig").validate },
    .{ "unevaluatedItems", @import("keywords/unevaluated_items.zig").validate },
};

/// Check if the root schema indicates Draft 2020-12.
fn isDraft2020x(root_schema: std.json.Value) bool {
    const obj = switch (root_schema) {
        .object => |o| o,
        else => return false,
    };
    const schema_val = obj.get("$schema") orelse return false;
    const schema_str = switch (schema_val) {
        .string => |s| s,
        else => return false,
    };
    return std.mem.indexOf(u8, schema_str, "2020-12") != null;
}

/// Keywords that belong to the validation vocabulary.
const validation_keywords = [_][]const u8{
    "type",           "enum",         "const",
    "multipleOf",     "maximum",      "exclusiveMaximum",
    "minimum",        "exclusiveMinimum",
    "maxLength",      "minLength",    "pattern",
    "maxItems",       "minItems",     "uniqueItems",
    "maxContains",    "minContains",
    "maxProperties",  "minProperties", "required",
    "dependentRequired",
};

pub fn isValidationKeyword(name: []const u8) bool {
    @setEvalBranchQuota(10000);
    for (validation_keywords) |vk| {
        if (std.mem.eql(u8, name, vk)) return true;
    }
    return false;
}

/// Check if the validation vocabulary is disabled by a custom metaschema.
fn isValidationVocabDisabled(ctx: Context) bool {
    const root_obj = switch (ctx.root_schema) {
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
    const reg = ctx.registry orelse return false;
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

    // If $vocabulary exists but doesn't include the validation vocabulary, it's disabled
    return vocab_obj.get("https://json-schema.org/draft/2020-12/vocab/validation") == null;
}

/// Run all applicable keyword validators against the schema/instance pair.
pub fn validateAll(ctx: Context) void {
    // Fast path: use pre-compiled node if available
    if (ctx.compiled) |compiled| {
        // Use pre-looked-up node if available, otherwise do the hashmap lookup
        const node = ctx.compiled_node orelse compiled.getNode(ctx.schema);
        if (node) |n| {
            if (n.ref_overrides) {
                @import("keywords/ref.zig").validate(ctx);
                return;
            }
            // Ultra-fast path: simple type-only schemas like {"type": "number"}
            if (n.simple_type != .none) {
                if (!matchesSimpleType(ctx.instance, n.simple_type)) {
                    ctx.addError("type", "Instance does not match the expected type");
                }
                return;
            }
            for (n.validators) |v| {
                switch (v) {
                    .type_single => |st| {
                        if (!matchesSimpleType(ctx.instance, st)) {
                            ctx.addError("type", "Instance does not match the expected type");
                        }
                    },
                    .type_multi => |types| {
                        var matched = false;
                        for (types) |st| {
                            if (matchesSimpleType(ctx.instance, st)) {
                                matched = true;
                                break;
                            }
                        }
                        if (!matched) {
                            ctx.addError("type", "Instance does not match any of the expected types");
                        }
                    },
                    .enum_check => |enum_val| {
                        const enum_array = switch (enum_val) {
                            .array => |a| a.items,
                            else => continue,
                        };
                        var found = false;
                        for (enum_array) |candidate| {
                            if (@import("keywords/enum_keyword.zig").jsonEqual(ctx.instance, candidate)) {
                                found = true;
                                break;
                            }
                        }
                        if (!found) {
                            ctx.addError("enum", "Instance does not match any enum value");
                        }
                    },
                    .const_check => |const_val| {
                        if (!@import("keywords/enum_keyword.zig").jsonEqual(ctx.instance, const_val)) {
                            ctx.addError("const", "Instance does not match the const value");
                        }
                    },
                    .minimum => |limit| {
                        const instance_num: f64 = switch (ctx.instance) {
                            .integer => |n2| @floatFromInt(n2),
                            .float => |f| f,
                            else => continue,
                        };
                        if (instance_num < limit) {
                            ctx.addError("minimum", "Value must be greater than or equal to minimum");
                        }
                    },
                    .maximum => |limit| {
                        const instance_num: f64 = switch (ctx.instance) {
                            .integer => |n2| @floatFromInt(n2),
                            .float => |f| f,
                            else => continue,
                        };
                        if (instance_num > limit) {
                            ctx.addError("maximum", "Value must be less than or equal to maximum");
                        }
                    },
                    .exclusive_minimum => |limit| {
                        const instance_num: f64 = switch (ctx.instance) {
                            .integer => |n2| @floatFromInt(n2),
                            .float => |f| f,
                            else => continue,
                        };
                        if (instance_num <= limit) {
                            ctx.addError("exclusiveMinimum", "Value must be strictly greater than exclusiveMinimum");
                        }
                    },
                    .exclusive_maximum => |limit| {
                        const instance_num: f64 = switch (ctx.instance) {
                            .integer => |n2| @floatFromInt(n2),
                            .float => |f| f,
                            else => continue,
                        };
                        if (instance_num >= limit) {
                            ctx.addError("exclusiveMaximum", "Value must be strictly less than exclusiveMaximum");
                        }
                    },
                    .multiple_of => |divisor| {
                        const instance_num: f64 = switch (ctx.instance) {
                            .integer => |n2| @floatFromInt(n2),
                            .float => |f| f,
                            else => continue,
                        };
                        if (divisor != 0) {
                            const remainder = @rem(instance_num, divisor);
                            const tolerance: f64 = 1e-9;
                            if (@abs(remainder) > tolerance and @abs(remainder) - @abs(divisor) < -tolerance) {
                                ctx.addError("multipleOf", "Value must be a multiple of multipleOf");
                            }
                        }
                    },
                    .min_length => |limit| {
                        const instance_str = switch (ctx.instance) {
                            .string => |s| s,
                            else => continue,
                        };
                        const codepoint_count = std.unicode.utf8CountCodepoints(instance_str) catch continue;
                        if (codepoint_count < limit) {
                            const msg = std.fmt.allocPrint(
                                ctx.allocator,
                                "String is too short: {d} codepoints, minimum {d}",
                                .{ codepoint_count, limit },
                            ) catch continue;
                            defer ctx.allocator.free(msg);
                            ctx.addError("minLength", msg);
                        }
                    },
                    .max_length => |limit| {
                        const instance_str = switch (ctx.instance) {
                            .string => |s| s,
                            else => continue,
                        };
                        const codepoint_count = std.unicode.utf8CountCodepoints(instance_str) catch continue;
                        if (codepoint_count > limit) {
                            const msg = std.fmt.allocPrint(
                                ctx.allocator,
                                "String is too long: {d} codepoints, maximum {d}",
                                .{ codepoint_count, limit },
                            ) catch continue;
                            defer ctx.allocator.free(msg);
                            ctx.addError("maxLength", msg);
                        }
                    },
                    .pattern => {
                        // Should not happen (compiled as generic), but handle gracefully
                        continue;
                    },
                    .min_items => |limit| {
                        const arr = switch (ctx.instance) {
                            .array => |a| a,
                            else => continue,
                        };
                        if (arr.items.len < limit) {
                            ctx.addError("minItems", "Array has fewer items than minItems");
                        }
                    },
                    .max_items => |limit| {
                        const arr = switch (ctx.instance) {
                            .array => |a| a,
                            else => continue,
                        };
                        if (arr.items.len > limit) {
                            ctx.addError("maxItems", "Array has more items than maxItems");
                        }
                    },
                    .unique_items => {
                        // Handled by isValidFast; validateAll only reached for errors
                        @import("keywords/unique_items.zig").validate(ctx);
                    },
                    .required => |names| {
                        const obj = switch (ctx.instance) {
                            .object => |o| o,
                            else => continue,
                        };
                        for (names) |name| {
                            if (obj.get(name) == null) {
                                const msg = std.fmt.allocPrint(
                                    ctx.allocator,
                                    "Required property '{s}' is missing",
                                    .{name},
                                ) catch continue;
                                ctx.addError("required", msg);
                            }
                        }
                    },
                    .min_properties => |limit| {
                        const obj = switch (ctx.instance) {
                            .object => |o| o,
                            else => continue,
                        };
                        if (obj.count() < limit) {
                            ctx.addError("minProperties", "Object has too few properties");
                        }
                    },
                    .max_properties => |limit| {
                        const obj = switch (ctx.instance) {
                            .object => |o| o,
                            else => continue,
                        };
                        if (obj.count() > limit) {
                            ctx.addError("maxProperties", "Object has too many properties");
                        }
                    },
                    .properties_compiled => |entries| {
                        // Inline fast path: use pre-linked nodes directly
                        const inst_obj = switch (ctx.instance) {
                            .object => |o| o,
                            else => continue,
                        };
                        if (ctx.evaluated_props == null) {
                            // No unevaluatedProperties tracking needed — pure fast path
                            var need_slow = false;
                            for (entries) |entry| {
                                const inst_val = inst_obj.get(entry.name) orelse continue;
                                if (entry.schema.node) |enode| {
                                    if (!enode.needs_uri_resolution) {
                                        if (enode.isValidFast(inst_val, compiled)) |result| {
                                            if (result) continue;
                                        }
                                    }
                                }
                                need_slow = true;
                                break;
                            }
                            if (need_slow) {
                                var child = ctx;
                                child.current_keyword_value = null;
                                child.compiled_node = null;
                                @import("keywords/properties.zig").validate(child);
                            }
                        } else {
                            var child = ctx;
                            child.current_keyword_value = null;
                            child.compiled_node = null;
                            @import("keywords/properties.zig").validate(child);
                        }
                    },
                    .all_of_compiled => |schemas| {
                        // Per-branch fast path: try isValidFast, fallback per branch
                        var any_failed = false;
                        for (schemas) |s| {
                            if (s.node) |snode| {
                                const can_skip = !snode.needs_uri_resolution or
                                    (!snode.has_id and ctx.registry == null);
                                if (can_skip) {
                                    if (snode.isValidFast(ctx.instance, compiled)) |result| {
                                        if (result) continue;
                                        any_failed = true;
                                        break;
                                    }
                                }
                            }
                            // This branch can't be inlined — use boolean check
                            if (!ctx.isSubschemaValidWithNode(s.value, ctx.instance, s.node)) {
                                any_failed = true;
                                break;
                            }
                        }
                        if (any_failed) {
                            // Re-validate for error collection
                            var child = ctx;
                            child.current_keyword_value = null;
                            child.compiled_node = null;
                            @import("keywords/all_of.zig").validate(child);
                        }
                    },
                    .one_of_compiled => |oo| {
                        // Discriminator fast path: direct branch lookup
                        if (oo.discriminator_field) |field| {
                            if (oo.discriminator_map) |dmap| {
                                const disc_val = blk: {
                                    const inst_obj = switch (ctx.instance) {
                                        .object => |o| o,
                                        else => break :blk @as(?[]const u8, null),
                                    };
                                    const fv = inst_obj.get(field) orelse break :blk @as(?[]const u8, null);
                                    break :blk switch (fv) {
                                        .string => |s| @as(?[]const u8, s),
                                        else => @as(?[]const u8, null),
                                    };
                                };
                                if (disc_val) |dv| {
                                    var matched = false;
                                    for (dmap) |entry| {
                                        if (std.mem.eql(u8, dv, entry.value)) {
                                            if (entry.schema.node) |snode| {
                                                if (!snode.needs_uri_resolution) {
                                                    if (snode.isValidFast(ctx.instance, compiled)) |result| {
                                                        if (result) {
                                                            matched = true;
                                                            break;
                                                        }
                                                    }
                                                }
                                            }
                                            // Not fast — fall through to slow path
                                            if (!matched) {
                                                if (ctx.isSubschemaValidWithNode(entry.schema.value, ctx.instance, entry.schema.node)) {
                                                    matched = true;
                                                    break;
                                                }
                                            }
                                            break;
                                        }
                                    }
                                    if (!matched) {
                                        ctx.addError("oneOf", "Instance does not match any schema in oneOf");
                                    }
                                    continue;
                                }
                            }
                        }
                        // Non-discriminator: inline fast path with type mask
                        const inst_mask = compiled_mod.typeMaskForValue(ctx.instance);
                        var fast_ok = true;
                        var match_count: usize = 0;
                        for (oo.schemas) |s| {
                            if (s.type_mask & inst_mask == 0) continue;
                            if (s.node) |snode| {
                                const can_skip_o = !snode.needs_uri_resolution or
                                    (!snode.has_id and ctx.registry == null);
                                if (can_skip_o) {
                                    if (snode.isValidFast(ctx.instance, compiled)) |result| {
                                        if (result) {
                                            match_count += 1;
                                            if (match_count > 1) break;
                                        }
                                        continue;
                                    }
                                }
                            }
                            fast_ok = false;
                            break;
                        }
                        if (fast_ok) {
                            if (match_count != 1) {
                                if (match_count == 0) {
                                    ctx.addError("oneOf", "Instance does not match any schema in oneOf");
                                } else {
                                    ctx.addError("oneOf", "Instance matches more than one schema in oneOf");
                                }
                            }
                        } else {
                            var child = ctx;
                            child.current_keyword_value = null;
                            child.compiled_node = null;
                            @import("keywords/one_of.zig").validate(child);
                        }
                    },
                    .any_of_compiled => |schemas| {
                        // Per-branch fast path
                        const inst_mask = compiled_mod.typeMaskForValue(ctx.instance);
                        var found = false;
                        for (schemas) |s| {
                            if (s.type_mask & inst_mask == 0) continue;
                            if (s.node) |snode| {
                                const can_skip = !snode.needs_uri_resolution or
                                    (!snode.has_id and ctx.registry == null);
                                if (can_skip) {
                                    if (snode.isValidFast(ctx.instance, compiled)) |result| {
                                        if (result) { found = true; break; }
                                        continue;
                                    }
                                }
                            }
                            // Can't inline — use boolean check
                            if (ctx.isSubschemaValidWithNode(s.value, ctx.instance, s.node)) {
                                found = true;
                                break;
                            }
                        }
                        if (!found) {
                            ctx.addError("anyOf", "Instance does not match any schema in anyOf");
                        }
                    },
                    .not_compiled => |ls| {
                        if (ls.node) |snode| {
                            if (!snode.needs_uri_resolution) {
                                if (snode.isValidFast(ctx.instance, compiled)) |result| {
                                    if (result) {
                                        ctx.addError("not", "Instance must not validate against the schema");
                                    }
                                    continue;
                                }
                            }
                        }
                        var child = ctx;
                        child.current_keyword_value = null;
                        child.compiled_node = null;
                        @import("keywords/not_keyword.zig").validate(child);
                    },
                    .items_compiled => |ic| {
                        // Inline fast path: use pre-linked items schema node
                        const arr = switch (ctx.instance) {
                            .array => |a| a,
                            else => continue,
                        };
                        if (arr.items.len <= ic.prefix_count) continue;
                        if (ic.schema.node) |inode| {
                            if (!inode.needs_uri_resolution) {
                                // Ultra-fast path for simple type items (e.g., {type: "number"})
                                if (inode.simple_type != .none) {
                                    var all_valid = true;
                                    for (arr.items[ic.prefix_count..]) |item| {
                                        if (!matchesSimpleType(item, inode.simple_type)) {
                                            all_valid = false;
                                            break;
                                        }
                                    }
                                    if (all_valid) continue;
                                } else {
                                    var all_fast = true;
                                    for (arr.items[ic.prefix_count..]) |item| {
                                        if (inode.isValidFast(item, compiled)) |result| {
                                            if (result) continue;
                                        }
                                        all_fast = false;
                                        break;
                                    }
                                    if (all_fast) continue;
                                }
                            }
                        }
                        @import("keywords/items.zig").validate(ctx);
                    },
                    .object_fast => |of| {
                        // Combined type + required + properties + additionalProperties in one pass
                        const inst_obj = switch (ctx.instance) {
                            .object => |o| o,
                            else => {
                                if (of.has_type_object) {
                                    ctx.addError("type", "Instance does not match the expected type");
                                }
                                continue;
                            },
                        };
                        if (ctx.evaluated_props == null) {
                            const keys = inst_obj.keys();
                            const vals = inst_obj.values();
                            var found_mask: u64 = 0;
                            var additional_count: usize = 0;
                            var need_slow = false;
                            for (keys, vals) |key, val| {
                                // Find matching schema property
                                const pi_opt: ?usize = if (of.property_map) |pmap|
                                    if (pmap.get(key)) |pi| @as(usize, pi) else null
                                else blk: {
                                    for (of.properties, 0..) |entry, pi| {
                                        if (key.len == entry.name.len and std.mem.eql(u8, key, entry.name))
                                            break :blk @as(?usize, pi);
                                    }
                                    break :blk null;
                                };
                                if (pi_opt) |pi| {
                                    found_mask |= (@as(u64, 1) << @as(u6, @intCast(pi)));
                                    const entry = of.properties[pi];
                                    if (entry.schema.node) |enode| {
                                        const can_skip_of = !enode.needs_uri_resolution or
                                            (!enode.has_id and ctx.registry == null);
                                        if (can_skip_of) {
                                            if (enode.isValidFast(val, compiled)) |result| {
                                                if (result) continue;
                                            }
                                        }
                                    }
                                    need_slow = true;
                                    break;
                                } else {
                                    additional_count += 1;
                                }
                                if (need_slow) break;
                            }
                            if (!need_slow) {
                                // Check required via bitmask
                                if (found_mask & of.required_mask == of.required_mask) {
                                    // Check additional properties
                                    if (!of.additional_false or additional_count == 0) {
                                        continue; // All good — zero allocation fast path!
                                    }
                                }
                            }
                        }
                        // Slow path: use keys/values iteration for error reporting
                        {
                            const keys = inst_obj.keys();
                            const vals = inst_obj.values();
                            for (keys, vals) |key, val| {
                                var matched = false;
                                for (of.properties) |entry| {
                                    if (std.mem.eql(u8, key, entry.name)) {
                                        matched = true;
                                        if (ctx.evaluated_props) |ep| ep.put(key, {}) catch {};
                                        if (ctx.isSubschemaValidWithNode(entry.schema.value, val, entry.schema.node)) break;
                                        const base_sp = @import("json_pointer.zig").appendProperty(ctx.allocator, ctx.schema_path, "properties");
                                        const prop_sp = @import("json_pointer.zig").appendProperty(ctx.allocator, base_sp, entry.name);
                                        const prop_ip = @import("json_pointer.zig").appendProperty(ctx.allocator, ctx.instance_path, key);
                                        const result = ctx.validateSubschema(entry.schema.value, val, prop_ip, prop_sp);
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
                                        break;
                                    }
                                }
                                if (!matched and of.additional_false) {
                                    const msg = std.fmt.allocPrint(ctx.allocator, "Additional property '{s}' is not allowed", .{key}) catch continue;
                                    ctx.addError("additionalProperties", msg);
                                }
                            }
                            // Check required
                            for (of.properties, 0..) |entry, pi| {
                                if (pi >= 64) break;
                                if (of.required_mask & (@as(u64, 1) << @as(u6, @intCast(pi))) != 0) {
                                    if (inst_obj.get(entry.name) == null) {
                                        const msg = std.fmt.allocPrint(ctx.allocator, "Required property '{s}' is missing", .{entry.name}) catch continue;
                                        ctx.addError("required", msg);
                                    }
                                }
                            }
                        }
                    },
                    .ref_local => |ls| {
                        // Inline local $ref: directly validate against pre-linked target
                        const rnode_opt = ls.node orelse if (ctx.compiled) |cc| cc.getNode(ls.value) else null;
                        if (rnode_opt) |rnode| {
                            const can_skip = !rnode.needs_uri_resolution or
                                (!rnode.has_id and ctx.registry == null);
                            if (can_skip) {
                                if (rnode.always_valid) continue;
                                if (rnode.isValidFast(ctx.instance, compiled)) |result| {
                                    if (result) continue;
                                }
                                // Can't fully inline — call validateAll directly on target
                                const result = ctx.validateSubschema(ls.value, ctx.instance, ctx.instance_path, ctx.schema_path);
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
                                continue;
                            }
                        }
                        // Fall back to full ref validation
                        var child = ctx;
                        child.current_keyword_value = null;
                        child.compiled_node = null;
                        @import("keywords/ref.zig").validate(child);
                    },
                    .additional_properties_false => |ap| {
                        const inst_obj = switch (ctx.instance) {
                            .object => |o| o,
                            else => continue,
                        };
                        // Fast check: count covered properties
                        var name_covered: usize = 0;
                        for (ap.property_names) |name| {
                            if (inst_obj.get(name) != null) name_covered += 1;
                        }
                        if (inst_obj.count() <= name_covered) continue;
                        // Check uncovered properties against pattern regexes
                        var has_violation = false;
                        const keys = inst_obj.keys();
                        for (keys) |prop_name| {
                            var found = false;
                            for (ap.property_names) |name| {
                                if (prop_name.len == name.len and std.mem.eql(u8, prop_name, name)) {
                                    found = true;
                                    break;
                                }
                            }
                            if (!found and ap.pattern_regexes != null) {
                                for (ap.pattern_regexes.?) |cr| {
                                    if (cr.matches(prop_name, ctx.allocator)) {
                                        found = true;
                                        break;
                                    }
                                }
                            }
                            if (!found) {
                                has_violation = true;
                                const msg = std.fmt.allocPrint(
                                    ctx.allocator,
                                    "Additional property '{s}' is not allowed",
                                    .{prop_name},
                                ) catch continue;
                                ctx.addError("additionalProperties", msg);
                            }
                        }
                    },
                    .additional_properties_schema => |ap| {
                        const inst_obj = switch (ctx.instance) {
                            .object => |o| o,
                            else => continue,
                        };
                        var it = inst_obj.iterator();
                        while (it.next()) |entry| {
                            const prop_name = entry.key_ptr.*;
                            const prop_value = entry.value_ptr.*;
                            var covered = false;
                            for (ap.property_names) |name| {
                                if (std.mem.eql(u8, prop_name, name)) {
                                    covered = true;
                                    break;
                                }
                            }
                            if (!covered) {
                                // Fast path: try isValidFast on the additional property
                                if (ap.schema.node) |anode| {
                                    if (!anode.needs_uri_resolution) {
                                        if (anode.isValidFast(prop_value, compiled)) |result| {
                                            if (result) continue;
                                        }
                                    }
                                }
                                // Slow path
                                var child = ctx;
                                child.current_keyword_value = null;
                                child.compiled_node = null;
                                @import("keywords/additional_properties.zig").validate(child);
                                break;
                            }
                        }
                    },
                    .if_then_else_compiled => |ite| {
                        // Inline fast path: use pre-linked schemas
                        const if_valid = blk: {
                            if (ite.if_schema.node) |inode| {
                                if (!inode.needs_uri_resolution) {
                                    if (inode.isValidFast(ctx.instance, compiled)) |result| {
                                        break :blk result;
                                    }
                                }
                            }
                            break :blk ctx.isSubschemaValid(ite.if_schema.value, ctx.instance);
                        };
                        if (if_valid) {
                            if (ite.then_schema) |ts| {
                                // Fast path for then
                                if (ts.node) |tnode| {
                                    if (!tnode.needs_uri_resolution) {
                                        if (tnode.isValidFast(ctx.instance, compiled)) |result| {
                                            if (result) continue;
                                        }
                                    }
                                }
                                // Slow path
                                var child = ctx;
                                child.current_keyword_value = null;
                                child.compiled_node = null;
                                @import("keywords/if_then_else.zig").validate(child);
                            }
                        } else {
                            if (ite.else_schema) |es| {
                                // Fast path for else
                                if (es.node) |enode| {
                                    if (!enode.needs_uri_resolution) {
                                        if (enode.isValidFast(ctx.instance, compiled)) |result| {
                                            if (result) continue;
                                        }
                                    }
                                }
                                // Slow path
                                var child = ctx;
                                child.current_keyword_value = null;
                                child.compiled_node = null;
                                @import("keywords/if_then_else.zig").validate(child);
                            }
                        }
                    },
                    .pattern_compiled => |cr| {
                        const instance_str = switch (ctx.instance) {
                            .string => |s| s,
                            else => continue,
                        };
                        if (!cr.valid) continue;
                        const instance_z = ctx.allocator.dupeZ(u8, instance_str) catch continue;
                        defer ctx.allocator.free(instance_z);
                        if (compiled_mod.c.regexec(&cr.regex, instance_z.ptr, 0, null, 0) != 0) {
                            ctx.addError("pattern", "String does not match pattern");
                        }
                    },
                    .contains_compiled => |cc| {
                        const c_arr = switch (ctx.instance) {
                            .array => |a| a,
                            else => continue,
                        };
                        var match_count: usize = 0;
                        for (c_arr.items) |item| {
                            if (cc.schema.node) |cnode| {
                                const can_skip_c = !cnode.needs_uri_resolution or
                                    (!cnode.has_id and ctx.registry == null);
                                if (can_skip_c) {
                                    if (cnode.isValidFast(item, compiled)) |result| {
                                        if (result) { match_count += 1; continue; }
                                        continue;
                                    }
                                }
                            }
                            if (ctx.isSubschemaValidWithNode(cc.schema.value, item, cc.schema.node)) {
                                match_count += 1;
                            }
                        }
                        if (match_count < cc.min_contains) {
                            ctx.addError(if (cc.min_contains > 1) "minContains" else "contains", "Not enough items match the contains schema");
                        }
                        if (cc.max_contains) |max| {
                            if (match_count > max) {
                                ctx.addError("maxContains", "Too many items match the contains schema");
                            }
                        }
                    },
                    .prefix_items_compiled => |schemas| {
                        const pi_arr = switch (ctx.instance) {
                            .array => |a| a,
                            else => continue,
                        };
                        const count = @min(pi_arr.items.len, schemas.len);
                        var all_valid = true;
                        for (0..count) |i| {
                            if (schemas[i].node) |pnode| {
                                const can_skip_p = !pnode.needs_uri_resolution or
                                    (!pnode.has_id and ctx.registry == null);
                                if (can_skip_p) {
                                    if (pnode.isValidFast(pi_arr.items[i], compiled)) |result| {
                                        if (result) continue;
                                    }
                                }
                            }
                            if (ctx.isSubschemaValidWithNode(schemas[i].value, pi_arr.items[i], schemas[i].node)) continue;
                            all_valid = false;
                            break;
                        }
                        if (!all_valid) {
                            // Slow path for error details
                            var child = ctx;
                            child.current_keyword_value = null;
                            child.compiled_node = null;
                            @import("keywords/prefix_items.zig").validate(child);
                        }
                    },
                    .dependent_schemas_compiled => |deps| {
                        const ds_obj = switch (ctx.instance) {
                            .object => |o| o,
                            else => continue,
                        };
                        for (deps) |dep| {
                            if (ds_obj.get(dep.trigger) == null) continue;
                            // Fast path
                            if (dep.schema.node) |snode| {
                                const can_skip = !snode.needs_uri_resolution or
                                    (!snode.has_id and ctx.registry == null);
                                if (can_skip) {
                                    if (snode.isValidFast(ctx.instance, compiled)) |result| {
                                        if (result) continue;
                                    }
                                }
                            }
                            if (ctx.isSubschemaValidWithNode(dep.schema.value, ctx.instance, dep.schema.node)) continue;
                            // Invalid — collect errors
                            const base_path = @import("json_pointer.zig").appendProperty(ctx.allocator, ctx.schema_path, "dependentSchemas");
                            const dep_path = @import("json_pointer.zig").appendProperty(ctx.allocator, base_path, dep.trigger);
                            const result = ctx.validateSubschema(dep.schema.value, ctx.instance, ctx.instance_path, dep_path);
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
                    },
                    .property_names_compiled => |ls| {
                        const pn_obj = switch (ctx.instance) {
                            .object => |o| o,
                            else => continue,
                        };
                        // Fast path: try isValidFast on all property names
                        if (ls.node) |pnode| {
                            const can_skip = !pnode.needs_uri_resolution or
                                (!pnode.has_id and ctx.registry == null);
                            if (can_skip) {
                                var all_ok = true;
                                const pn_keys = pn_obj.keys();
                                for (pn_keys) |key| {
                                    const name_val = std.json.Value{ .string = key };
                                    if (pnode.isValidFast(name_val, compiled)) |result| {
                                        if (result) continue;
                                    }
                                    all_ok = false;
                                    break;
                                }
                                if (all_ok) continue;
                            }
                        }
                        // Slow path
                        var child = ctx;
                        child.current_keyword_value = null;
                        child.compiled_node = null;
                        @import("keywords/property_names.zig").validate(child);
                    },
                    .unevaluated_properties_compiled => |up| {
                        // Fast path: ceiling check inline
                        if (up.all_covered) continue;
                        const up_obj = switch (ctx.instance) {
                            .object => |o| o,
                            else => continue,
                        };
                        if (up.ceiling_map != null or up.ceiling_arr != null) {
                            var all_ok = true;
                            const up_keys = up_obj.keys();
                            for (up_keys) |key| {
                                var found = false;
                                if (up.ceiling_map) |cm| {
                                    found = cm.get(key) != null;
                                } else if (up.ceiling_arr) |ca| {
                                    for (ca) |name| {
                                        if (key.len == name.len and std.mem.eql(u8, key, name)) {
                                            found = true;
                                            break;
                                        }
                                    }
                                }
                                if (!found and up.pattern_regexes != null) {
                                    for (up.pattern_regexes.?) |cr| {
                                        if (cr.matches(key, ctx.allocator)) {
                                            found = true;
                                            break;
                                        }
                                    }
                                }
                                if (!found) {
                                    all_ok = false;
                                    break;
                                }
                            }
                            if (all_ok) continue;
                        }
                        // Fall back to full unevaluatedProperties validation
                        var child = ctx;
                        child.current_keyword_value = up.schema_value;
                        child.compiled_node = null;
                        @import("keywords/unevaluated_properties.zig").validate(child);
                    },
                    .pattern_properties_compiled => |pp_entries| {
                        const inst_obj = switch (ctx.instance) {
                            .object => |o| o,
                            else => continue,
                        };
                        for (pp_entries) |pp_entry| {
                            var inst_it = inst_obj.iterator();
                            while (inst_it.next()) |entry| {
                                const prop_name = entry.key_ptr.*;
                                const prop_value = entry.value_ptr.*;
                                if (pp_entry.regex.matches(prop_name, ctx.allocator)) {
                                    if (ctx.evaluated_props) |ep| {
                                        ep.put(prop_name, {}) catch {};
                                    }
                                    // Fast path
                                    if (pp_entry.schema.node) |pnode| {
                                        if (!pnode.needs_uri_resolution) {
                                            if (pnode.isValidFast(prop_value, compiled)) |result| {
                                                if (result) continue;
                                            }
                                        }
                                    }
                                    if (ctx.isSubschemaValidWithNode(pp_entry.schema.value, prop_value, pp_entry.schema.node)) continue;
                                    // Invalid — build error
                                    const base_path = @import("json_pointer.zig").appendProperty(ctx.allocator, ctx.schema_path, "patternProperties");
                                    const pp_path = @import("json_pointer.zig").appendProperty(ctx.allocator, base_path, pp_entry.pattern);
                                    const prop_path = @import("json_pointer.zig").appendProperty(ctx.allocator, ctx.instance_path, prop_name);
                                    const result = ctx.validateSubschema(pp_entry.schema.value, prop_value, prop_path, pp_path);
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
                    },
                    .generic => |g| {
                        var child = ctx;
                        child.current_keyword_value = g.keyword_value;
                        // Clear compiled_node so nested validateAll calls don't
                        // reuse a stale node pointer from the parent.
                        child.compiled_node = null;
                        g.func(child);
                    },
                }
            }
            return;
        }
        // Fall through to legacy path if node not found (e.g. dynamically resolved schema)
    }

    const schema_obj = ctx.schema.object;

    // Draft 7: $ref overrides all sibling keywords
    // In 2020-12: $ref is just another keyword, siblings still apply
    if (schema_obj.get("$ref") != null) {
        const is_2020 = isDraft2020x(ctx.root_schema);
        if (!is_2020) {
            @import("keywords/ref.zig").validate(ctx);
            return;
        }
    }

    const skip_validation = isValidationVocabDisabled(ctx);

    inline for (keyword_table) |entry| {
        const keyword_name = entry[0];
        const validator_fn = entry[1];
        if (schema_obj.get(keyword_name) != null) {
            // Skip validation keywords if vocabulary says so
            if (comptime isValidationKeyword(keyword_name)) {
                if (!skip_validation) {
                    validator_fn(ctx);
                }
            } else {
                validator_fn(ctx);
            }
        }
    }
}

test "empty schema validates everything" {
    const allocator = std.testing.allocator;

    const schema_str = "{}";
    const parsed_schema = try std.json.parseFromSlice(std.json.Value, allocator, schema_str, .{});
    defer parsed_schema.deinit();

    const instance_str = "42";
    const parsed_instance = try std.json.parseFromSlice(std.json.Value, allocator, instance_str, .{});
    defer parsed_instance.deinit();

    const result = jsonschema.validate(allocator, parsed_schema.value, parsed_instance.value);
    defer result.deinit();

    try std.testing.expect(result.isValid());
}

test "false schema rejects everything" {
    const allocator = std.testing.allocator;

    const schema_str = "false";
    const parsed_schema = try std.json.parseFromSlice(std.json.Value, allocator, schema_str, .{});
    defer parsed_schema.deinit();

    const instance_str = "42";
    const parsed_instance = try std.json.parseFromSlice(std.json.Value, allocator, instance_str, .{});
    defer parsed_instance.deinit();

    const result = jsonschema.validate(allocator, parsed_schema.value, parsed_instance.value);
    defer result.deinit();

    try std.testing.expect(!result.isValid());
}
