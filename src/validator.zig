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
                        if (!node.needs_uri_resolution) {
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
                        if (!node.needs_uri_resolution) {
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
                        if (!n.needs_uri_resolution) {
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
                        // Should not happen (compiled as generic), but handle gracefully
                        continue;
                    },
                    .contains => {
                        // Should not happen (compiled as generic), but handle gracefully
                        continue;
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
                    .properties_compiled => |_| {
                        var child = ctx;
                        child.current_keyword_value = null;
                        child.compiled_node = null;
                        @import("keywords/properties.zig").validate(child);
                    },
                    .all_of_compiled => |_| {
                        var child = ctx;
                        child.current_keyword_value = null;
                        child.compiled_node = null;
                        @import("keywords/all_of.zig").validate(child);
                    },
                    .one_of_compiled => |_| {
                        var child = ctx;
                        child.current_keyword_value = null;
                        child.compiled_node = null;
                        @import("keywords/one_of.zig").validate(child);
                    },
                    .any_of_compiled => |_| {
                        var child = ctx;
                        child.current_keyword_value = null;
                        child.compiled_node = null;
                        @import("keywords/any_of.zig").validate(child);
                    },
                    .not_compiled => |_| {
                        var child = ctx;
                        child.current_keyword_value = null;
                        child.compiled_node = null;
                        @import("keywords/not_keyword.zig").validate(child);
                    },
                    .items_compiled => |_| {
                        @import("keywords/items.zig").validate(ctx);
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
