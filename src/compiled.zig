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

/// A pre-compiled schema node.  Stores only the keyword validators that are
/// actually present in the original schema object, avoiding the need to probe
/// the hashmap for all 30+ keywords at validation time.
pub const CompiledNode = struct {
    /// Pre-filtered list of validators for keywords present in this node.
    validators: []const Validator.KeywordValidator,
    /// True if this node has $ref AND the schema is Draft 7 (not 2020-12),
    /// meaning $ref overrides all sibling keywords.
    ref_overrides: bool,
};

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

            // Determine which validators are present
            var validators = std.ArrayList(Validator.KeywordValidator).init(alloc);

            const has_ref = obj.get("$ref") != null;
            const ref_overrides = has_ref and !is_2020;

            if (!ref_overrides) {
                // Normal path: collect all present keyword validators
                inline for (Validator.keyword_table) |entry| {
                    const keyword_name = entry[0];
                    const validator_fn = entry[1];
                    if (obj.get(keyword_name) != null) {
                        if (comptime Validator.isValidationKeyword(keyword_name)) {
                            if (!validation_vocab_disabled) {
                                validators.append(validator_fn) catch {};
                            }
                        } else {
                            validators.append(validator_fn) catch {};
                        }
                    }
                }
            }
            // If ref_overrides, we leave validators empty — validateAll will
            // call ref.validate directly anyway.  But we still record the node
            // so the lookup succeeds (and ref_overrides flag is set).

            const node = alloc.create(CompiledNode) catch return;
            node.* = .{
                .validators = validators.toOwnedSlice() catch &.{},
                .ref_overrides = ref_overrides,
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
