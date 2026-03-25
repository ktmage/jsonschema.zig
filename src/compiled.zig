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

        // Recursively walk the schema tree and compile every object node
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

/// A pre-compiled schema node.  Stores only the keyword validators that are
/// actually present in the original schema object, avoiding the need to probe
/// the hashmap for all 30+ keywords at validation time.
pub const CompiledNode = struct {
    /// Pre-filtered list of validators with their pre-extracted keyword values.
    entries: []const ValidatorEntry,
    /// True if this node has $ref AND the schema is Draft 7 (not 2020-12),
    /// meaning $ref overrides all sibling keywords.
    ref_overrides: bool,
    /// If this schema is simply {"type": "xxx"}, store the type tag for
    /// ultra-fast validation without going through the full validator dispatch.
    simple_type: SimpleType = .none,

    pub const ValidatorEntry = struct {
        func: Validator.KeywordValidator,
        keyword_value: std.json.Value,
    };

    /// Ultra-fast boolean-only validation. No allocations, no error construction.
    /// Returns false on first failure. Only works for common keyword patterns;
    /// falls back to full validation for complex keywords.
    pub fn isValid(self: *const CompiledNode, instance: std.json.Value, compiled: *const CompiledSchema) bool {
        if (self.simple_type != .none) {
            return Validator.matchesSimpleType(instance, self.simple_type);
        }
        if (self.ref_overrides) {
            // $ref override — need full validation path, can't inline
            // Return null-like signal... but we return bool.
            // Use FBA fallback in caller instead.
            unreachable; // caller should check ref_overrides before calling isValid
        }
        for (self.entries) |entry| {
            if (!isEntryValid(entry, instance, compiled)) return false;
        }
        return true;
    }
};

/// Check if a single keyword entry is valid for an instance.
/// Inlines common validators to avoid function pointer overhead.
fn isEntryValid(entry: CompiledNode.ValidatorEntry, instance: std.json.Value, compiled: *const CompiledSchema) bool {
    const kv = entry.keyword_value;
    const func = entry.func;

    // Identify keyword by function pointer comparison and inline the check
    if (func == @import("keywords/type_keyword.zig").validate) {
        return isTypeValid(kv, instance);
    }
    if (func == @import("keywords/required.zig").validate) {
        return isRequiredValid(kv, instance);
    }
    if (func == @import("keywords/properties.zig").validate) {
        return isPropertiesValid(kv, instance, compiled);
    }
    if (func == @import("keywords/minimum.zig").validate) {
        return numCmp(instance, kv, .gte);
    }
    if (func == @import("keywords/maximum.zig").validate) {
        return numCmp(instance, kv, .lte);
    }
    if (func == @import("keywords/exclusive_minimum.zig").validate) {
        return numCmp(instance, kv, .gt);
    }
    if (func == @import("keywords/exclusive_maximum.zig").validate) {
        return numCmp(instance, kv, .lt);
    }
    if (func == @import("keywords/min_length.zig").validate) {
        return isLengthValid(instance, kv, .min);
    }
    if (func == @import("keywords/max_length.zig").validate) {
        return isLengthValid(instance, kv, .max);
    }
    if (func == @import("keywords/min_items.zig").validate) {
        return isItemCountValid(instance, kv, .min);
    }
    if (func == @import("keywords/max_items.zig").validate) {
        return isItemCountValid(instance, kv, .max);
    }
    if (func == @import("keywords/min_properties.zig").validate) {
        return isPropCountValid(instance, kv, .min);
    }
    if (func == @import("keywords/max_properties.zig").validate) {
        return isPropCountValid(instance, kv, .max);
    }
    if (func == @import("keywords/items.zig").validate) {
        return isItemsValid(instance, kv, compiled);
    }
    if (func == @import("keywords/additional_properties.zig").validate) {
        // Too complex to inline — conservative true
        return true;
    }

    // Unknown keyword — conservative true (let full validation handle it)
    return true;
}

fn isTypeValid(type_val: std.json.Value, instance: std.json.Value) bool {
    switch (type_val) {
        .string => |t| return Validator.matchesSimpleType(instance, detectSimpleTypeFromString(t)),
        .array => |arr| {
            for (arr.items) |item| {
                switch (item) {
                    .string => |t| {
                        if (Validator.matchesSimpleType(instance, detectSimpleTypeFromString(t))) return true;
                    },
                    else => return true,
                }
            }
            return false;
        },
        else => return true,
    }
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

fn isRequiredValid(req_val: std.json.Value, instance: std.json.Value) bool {
    const obj = switch (instance) {
        .object => |o| o,
        else => return true,
    };
    const arr = switch (req_val) {
        .array => |a| a.items,
        else => return true,
    };
    for (arr) |item| {
        switch (item) {
            .string => |name| {
                if (obj.get(name) == null) return false;
            },
            else => {},
        }
    }
    return true;
}

fn isPropertiesValid(props_val: std.json.Value, instance: std.json.Value, compiled: *const CompiledSchema) bool {
    const props = switch (props_val) {
        .object => |o| o,
        else => return true,
    };
    const inst_obj = switch (instance) {
        .object => |o| o,
        else => return true,
    };
    var it = props.iterator();
    while (it.next()) |entry| {
        const inst_val = inst_obj.get(entry.key_ptr.*) orelse continue;
        const prop_schema = entry.value_ptr.*;
        // Try compiled node for sub-schema
        if (compiled.getNode(prop_schema)) |node| {
            if (!node.isValid(inst_val, compiled)) return false;
        }
        // If no compiled node, conservatively return true
    }
    return true;
}

fn isItemsValid(instance: std.json.Value, items_val: std.json.Value, compiled: *const CompiledSchema) bool {
    const arr = switch (instance) {
        .array => |a| a.items,
        else => return true,
    };
    switch (items_val) {
        .object => {
            if (compiled.getNode(items_val)) |node| {
                for (arr) |item| {
                    if (!node.isValid(item, compiled)) return false;
                }
            }
            return true;
        },
        .bool => |b| return b or arr.len == 0,
        else => return true,
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

fn numCmp(instance: std.json.Value, limit_val: std.json.Value, op: CmpOp) bool {
    const n = getNumber(instance) orelse return true;
    const limit = getNumber(limit_val) orelse return true;
    return switch (op) {
        .gte => n >= limit,
        .lte => n <= limit,
        .gt => n > limit,
        .lt => n < limit,
    };
}

const LenOp = enum { min, max };

fn isLengthValid(instance: std.json.Value, limit_val: std.json.Value, op: LenOp) bool {
    const s = switch (instance) {
        .string => |str| str,
        else => return true,
    };
    const limit = getUint(limit_val) orelse return true;
    const len = std.unicode.utf8CountCodepoints(s) catch return true;
    return switch (op) {
        .min => len >= limit,
        .max => len <= limit,
    };
}

fn isItemCountValid(instance: std.json.Value, limit_val: std.json.Value, op: LenOp) bool {
    const arr = switch (instance) {
        .array => |a| a.items,
        else => return true,
    };
    const limit = getUint(limit_val) orelse return true;
    return switch (op) {
        .min => arr.len >= limit,
        .max => arr.len <= limit,
    };
}

fn isPropCountValid(instance: std.json.Value, limit_val: std.json.Value, op: LenOp) bool {
    const obj = switch (instance) {
        .object => |o| o,
        else => return true,
    };
    const limit = getUint(limit_val) orelse return true;
    return switch (op) {
        .min => obj.count() >= limit,
        .max => obj.count() <= limit,
    };
}

fn getUint(val: std.json.Value) ?usize {
    return switch (val) {
        .integer => |n| if (n >= 0) @intCast(n) else null,
        .float => |f| if (f >= 0 and f == @trunc(f)) @intFromFloat(f) else null,
        else => null,
    };
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
            // Already compiled?
            if (node_map.get(key) != null) return;

            // Determine which validators are present and pre-extract their values
            var entries = std.ArrayList(CompiledNode.ValidatorEntry).init(alloc);

            const has_ref = obj.get("$ref") != null;
            const ref_overrides = has_ref and !is_2020;

            if (!ref_overrides) {
                inline for (Validator.keyword_table) |entry| {
                    const keyword_name = entry[0];
                    const validator_fn = entry[1];
                    if (obj.get(keyword_name)) |kw_val| {
                        if (comptime Validator.isValidationKeyword(keyword_name)) {
                            if (!validation_vocab_disabled) {
                                entries.append(.{ .func = validator_fn, .keyword_value = kw_val }) catch {};
                            }
                        } else {
                            entries.append(.{ .func = validator_fn, .keyword_value = kw_val }) catch {};
                        }
                    }
                }
            }
            // If ref_overrides, we leave validators empty — validateAll will
            // call ref.validate directly anyway.  But we still record the node
            // so the lookup succeeds (and ref_overrides flag is set).

            // Detect simple type-only schemas: {"type": "xxx"}
            const simple_type = detectSimpleType(obj);

            const node = alloc.create(CompiledNode) catch return;
            node.* = .{
                .entries = entries.toOwnedSlice() catch &.{},
                .ref_overrides = ref_overrides,
                .simple_type = simple_type,
            };
            node_map.put(key, node) catch return;

            // Recurse into sub-schemas
            recurseIntoSubSchemas(alloc, obj, node_map, is_2020, validation_vocab_disabled);
        },
        .array => |arr| {
            // Schema arrays (allOf, anyOf, oneOf items, etc.)
            for (arr.items) |item| {
                compileNode(alloc, item, node_map, is_2020, validation_vocab_disabled);
            }
        },
        else => {},
    }
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
    try std.testing.expectEqual(@as(usize, 0), node.?.entries.len);
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
    try std.testing.expectEqual(@as(usize, 1), node.?.entries.len);
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
    try std.testing.expectEqual(@as(usize, 2), root_node.?.entries.len);

    // Sub-schema {"type": "string"} should also be compiled
    const props = parsed.value.object.get("properties").?.object;
    const name_schema_val = props.get("name").?;
    const name_node = compiled.getNode(name_schema_val);
    try std.testing.expect(name_node != null);
    try std.testing.expectEqual(@as(usize, 1), name_node.?.entries.len);
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
