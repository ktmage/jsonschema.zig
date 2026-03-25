const std = @import("std");
const Allocator = std.mem.Allocator;
const jsonschema = @import("main.zig");
const ValidationError = jsonschema.ValidationError;
const JsonPointer = jsonschema.JsonPointer;
pub const RegexCache = @import("regex_cache.zig").RegexCache;
const schema_registry_mod = @import("schema_registry.zig");

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
    /// When true, skip error detail construction for fast boolean-only validation.
    valid_only: bool = false,
    /// Cached result of isDraft2020() on root_schema.
    is_draft_2020: bool = false,
    /// Optional regex cache for avoiding repeated regcomp() calls.
    regex_cache: ?*RegexCache = null,

    /// Recursively validate instance against a sub-schema.
    pub fn validateSubschema(
        self: Context,
        sub_schema: std.json.Value,
        instance: std.json.Value,
        instance_path: []const u8,
        schema_path: []const u8,
    ) jsonschema.ValidationResult {
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
        );
    }

    /// Fast boolean-only sub-schema validation (no error details, no path building).
    /// Reuses parent context state to avoid redundant $id resolution, isDraft2020 checks,
    /// and ArrayList allocations.
    pub fn isSubschemaValid(
        self: Context,
        sub_schema: std.json.Value,
        instance: std.json.Value,
    ) bool {
        // Short-circuit for boolean schemas
        switch (sub_schema) {
            .bool => |b| return b,
            .object => {},
            else => return true,
        }

        // Compute base_uri for sub-schema (handle $id inline)
        const has_ref = sub_schema.object.get("$ref") != null;
        const sub_base = blk: {
            if (sub_schema.object.get("$id")) |id_val| {
                switch (id_val) {
                    .string => |id_str| {
                        if (id_str.len > 0 and id_str[0] != '#') {
                            // Check if already registered (same logic as validateFull)
                            if (self.registry) |reg| {
                                const pbu_stripped = schema_registry_mod.stripFragment(self.base_uri);
                                if (reg.schemas.get(pbu_stripped)) |registered| {
                                    if (registered.object.keys().ptr == sub_schema.object.keys().ptr) {
                                        break :blk self.base_uri;
                                    }
                                }
                            }
                            break :blk schema_registry_mod.resolveUri(self.allocator, self.base_uri, id_str);
                        }
                    },
                    else => {},
                }
            }
            break :blk self.base_uri;
        };

        const ref_base_uri = if (has_ref and !self.is_draft_2020) self.base_uri else sub_base;

        // Track dynamic scope
        const has_new_scope = sub_schema.object.get("$id") != null;
        if (self.dynamic_scope) |ds| {
            if (has_new_scope) {
                ds.append(.{ .base_uri = sub_base, .schema = sub_schema }) catch {};
            }
        }
        defer {
            if (self.dynamic_scope) |ds| {
                if (has_new_scope and ds.items.len > 0) {
                    _ = ds.pop();
                }
            }
        }

        var errors = std.ArrayList(ValidationError).init(self.allocator);
        defer errors.deinit();

        const child_ctx = Context{
            .allocator = self.allocator,
            .root_schema = self.root_schema,
            .schema = sub_schema,
            .instance = instance,
            .instance_path = "",
            .schema_path = "",
            .errors = &errors,
            .registry = self.registry,
            .base_uri = sub_base,
            .ref_base_uri = ref_base_uri,
            .dynamic_scope = self.dynamic_scope,
            .valid_only = true,
            .is_draft_2020 = self.is_draft_2020,
            .regex_cache = self.regex_cache,
        };

        validateAll(child_ctx);
        return errors.items.len == 0;
    }

    /// Add a validation error to the error list.
    pub fn addError(self: Context, keyword: []const u8, message: []const u8) void {
        if (self.valid_only) {
            // In valid_only mode, add a sentinel error with no allocations
            self.errors.append(.{
                .instance_path = "",
                .schema_path = "",
                .keyword = keyword,
                .message = "",
            }) catch return;
            return;
        }
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
const keyword_table = .{
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

fn isValidationKeyword(name: []const u8) bool {
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
    const schema_obj = ctx.schema.object;

    // Draft 7: $ref overrides all sibling keywords
    // In 2020-12: $ref is just another keyword, siblings still apply
    if (schema_obj.get("$ref") != null) {
        if (!ctx.is_draft_2020) {
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
            // Early exit in valid_only mode: stop on first error
            if (ctx.valid_only and ctx.errors.items.len > 0) return;
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
