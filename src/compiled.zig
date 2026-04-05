const std = @import("std");
const Allocator = std.mem.Allocator;
const jsonschema = @import("main.zig");
const Validator = @import("validator.zig");
const SchemaRegistry = jsonschema.SchemaRegistry;
pub const c = @cImport(@cInclude("regex.h"));

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
    /// Pre-resolved local $ref targets (ref_string → resolved schema value).
    /// Eliminates repeated JSON pointer walks at validation time.
    local_ref_cache: std.StringHashMap(std.json.Value),
    /// Pre-resolved $dynamicAnchor / $anchor map (anchor_name → schema value).
    anchor_cache: std.StringHashMap(std.json.Value),
    /// Pre-compiled regex list for cleanup in deinit.
    compiled_regexes: []*CompiledRegex,

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
        var regex_list = std.ArrayList(*CompiledRegex).init(alloc);

        // Pre-scan $id entries into the registry so $ref resolution works during compile
        if (registry) |reg| {
            const root_id = getSchemaId(schema);
            reg.scanIds(root_id, schema);
        }

        // Recursively walk the schema tree and compile every object node.
        // Uses placeholder pattern: each node is registered before recursing
        // into sub-schemas, so child nodes are available for pre-linking.
        compileNode(alloc, schema, schema, &node_map, is_2020, validation_vocab_disabled, &regex_list);

        // Post-process: selectively disable needs_uri_resolution for nodes
        // whose $ref targets are fully inlinable by isValidFast.
        optimizeRefResolution(schema, &node_map);

        // Pre-resolve all local $ref targets to avoid JSON pointer walks at runtime.
        var local_ref_cache = std.StringHashMap(std.json.Value).init(alloc);
        buildLocalRefCache(schema, schema, &local_ref_cache);

        // Pre-resolve all $anchor and $dynamicAnchor for fast lookup at runtime.
        var anchor_cache = std.StringHashMap(std.json.Value).init(alloc);
        buildAnchorCache(schema, &anchor_cache);

        return .{
            .arena = arena,
            .node_map = node_map,
            .schema = schema,
            .is_2020 = is_2020,
            .validation_vocab_disabled = validation_vocab_disabled,
            .local_ref_cache = local_ref_cache,
            .anchor_cache = anchor_cache,
            .compiled_regexes = regex_list.toOwnedSlice() catch &.{},
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

    /// Resolve a local $ref string using the pre-computed cache.
    /// Falls back to JSON pointer walk if not cached.
    pub fn resolveLocalRef(self: *const CompiledSchema, ref_str: []const u8) ?std.json.Value {
        return self.local_ref_cache.get(ref_str) orelse {
            // Fallback: resolve via JSON pointer walk
            if (ref_str.len == 0 or ref_str[0] != '#') return null;
            if (ref_str.len == 1) return self.schema;
            if (ref_str.len >= 2 and ref_str[1] == '/') {
                return @import("schema_registry.zig").resolvePointer(self.schema, ref_str[2..]);
            }
            return null;
        };
    }

    /// Look up a pre-resolved $anchor or $dynamicAnchor.
    pub fn resolveAnchor(self: *const CompiledSchema, anchor_name: []const u8) ?std.json.Value {
        return self.anchor_cache.get(anchor_name);
    }

    pub fn deinit(self: *CompiledSchema) void {
        // Free POSIX regex internal allocations before the arena is torn down
        for (self.compiled_regexes) |cr| {
            if (cr.valid) {
                c.regfree(&cr.regex);
            }
        }
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
    /// Pre-computed type bitmask: which JSON types this schema accepts.
    type_mask: u8 = 0xFF,
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
    enum_check: []const std.json.Value,
    /// Pre-built string hashset for large string-only enums (O(1) lookup)
    enum_string_set: *std.StringHashMap(void),
    const_check: *const std.json.Value,

    // Numeric
    minimum: f64,
    maximum: f64,
    exclusive_minimum: f64,
    exclusive_maximum: f64,
    multiple_of: f64,

    // String
    min_length: u64,
    max_length: u64,

    // Array
    min_items: u64,
    max_items: u64,
    unique_items: void,

    // Object
    required: []const []const u8,
    min_properties: u64,
    max_properties: u64,

    // Pre-linked sub-schema variants (sub-schemas resolved at compile time).
    // No keyword_value stored — validateAll sets current_keyword_value = null
    // so keyword functions fall back to ctx.schema.object.get(keyword_name).
    properties_compiled: []const PropertyEntry,
    all_of_compiled: []const LinkedSchema,
    one_of_compiled: struct {
        schemas: []const LinkedSchema,
        /// Discriminator field name (e.g., "type") if all branches use properties.<field>.enum.
        discriminator_field: ?[]const u8 = null,
        /// Mapping from discriminator enum values to pre-linked branches.
        discriminator_map: ?[]const DiscriminatorEntry = null,
    },
    any_of_compiled: []const LinkedSchema,
    not_compiled: *const LinkedSchema,
    items_compiled: *const ItemsCompiled,

    // Combined object validator: type + required + properties + additionalProperties: false
    // Handles the common pattern in a single pass over instance keys/values,
    // avoiding per-property hashmap lookups. Uses bitmask for required tracking.
    object_fast: struct {
        properties: []const PropertyEntry,
        required_mask: u64,
        additional_false: bool,
        has_type_object: bool,
        /// Pre-built hashmap for O(1) property lookup (populated for schemas with >8 properties)
        property_map: ?*std.StringHashMap(u32) = null,
    },

    // Pre-linked local $ref (fragment-only, no registry needed)
    ref_local: *const LinkedSchema,

    // additionalProperties: false — pre-extracted allowed property names + optional pattern regexes
    additional_properties_false: struct {
        property_names: []const []const u8,
        pattern_regexes: ?[]const *CompiledRegex = null,
    },

    additional_properties_schema: *const AdditionalPropsSchemaCompiled,

    // Pre-linked if/then/else
    // Heap-allocated to keep union small (was 232 bytes inline)
    if_then_else_compiled: *const IfThenElseCompiled,

    // Heap-allocated to keep union small (was 104 bytes inline)
    unevaluated_properties_compiled: *const UnevalPropsCompiled,

    // Compiled dependentRequired: trigger property → required property names
    dependent_required_compiled: []const DependentRequiredEntry,

    // Compiled dependentSchemas: trigger property name → linked schema
    dependent_schemas_compiled: []const DependentSchemaEntry,

    // Compiled propertyNames: linked schema to validate property names against
    property_names_compiled: *const LinkedSchema,

    contains_compiled: *const ContainsCompiled,

    // Compiled prefixItems with pre-linked schemas
    prefix_items_compiled: []const LinkedSchema,

    // Pre-compiled regex pattern (stores pointer to arena-allocated CompiledRegex)
    pattern_compiled: *CompiledRegex,

    // Pre-compiled pattern properties (regex + schema links)
    pattern_properties_compiled: []const PatternPropertyEntry,

    // Complex keywords — keep as generic with function pointer fallback
    // These need full schema context (pattern matching, URI resolution, etc.)
    generic: *const GenericValidator,
};

pub const ItemsCompiled = struct {
    schema: LinkedSchema,
    prefix_count: usize,
};

pub const GenericValidator = struct {
    func: Validator.KeywordValidator,
    keyword_value: std.json.Value,
    keyword_name: []const u8,
};

/// A pre-compiled POSIX regex stored in the arena.
pub const CompiledRegex = struct {
    regex: c.regex_t,
    valid: bool,
    /// Simple prefix string for fast matching (e.g., "^x-" → prefix = "x-")
    simple_prefix: ?[]const u8 = null,
    /// True if this is a ^[_a-zA-Z][a-zA-Z0-9_-]*$ identifier pattern
    is_identifier: bool = false,

    /// Check if a string matches this compiled pattern.
    pub fn matches(self: *const CompiledRegex, str: []const u8, allocator: ?std.mem.Allocator) bool {
        // Fast path: simple prefix match
        if (self.simple_prefix) |prefix| {
            return str.len >= prefix.len and std.mem.eql(u8, str[0..prefix.len], prefix);
        }
        // Fast path: identifier pattern
        if (self.is_identifier) return matchesIdentifierPattern(str);
        // Regex path: need null-terminated string
        if (!self.valid) return false;
        if (allocator) |alloc| {
            const str_z = alloc.dupeZ(u8, str) catch return false;
            return c.regexec(&self.regex, str_z.ptr, 0, null, 0) == 0;
        }
        // No allocator: use stack buffer for short strings
        if (str.len < 512) {
            var buf: [512]u8 = undefined;
            @memcpy(buf[0..str.len], str);
            buf[str.len] = 0;
            return c.regexec(&self.regex, &buf, 0, null, 0) == 0;
        }
        return false;
    }
};

pub const AdditionalPropsSchemaCompiled = struct {
    schema: LinkedSchema,
    property_names: []const []const u8,
};

pub const ContainsCompiled = struct {
    schema: LinkedSchema,
    min_contains: usize,
    max_contains: ?usize,
};

pub const IfThenElseCompiled = struct {
    if_schema: LinkedSchema,
    then_schema: ?LinkedSchema,
    else_schema: ?LinkedSchema,
};

pub const UnevalPropsCompiled = struct {
    schema_value: std.json.Value,
    ceiling_map: ?*std.StringHashMap(void),
    ceiling_arr: ?[]const []const u8,
    pattern_regexes: ?[]*CompiledRegex,
    all_covered: bool,
};

/// Pre-compiled pattern property: regex + pre-linked sub-schema.
pub const PatternPropertyEntry = struct {
    regex: *CompiledRegex,
    schema: LinkedSchema,
    pattern: []const u8,
};

/// Compiled dependentRequired entry: trigger → required names.
pub const DependentRequiredEntry = struct {
    trigger: []const u8,
    required: []const []const u8,
};

/// Compiled dependentSchemas entry: trigger property + linked schema.
pub const DependentSchemaEntry = struct {
    trigger: []const u8,
    schema: LinkedSchema,
};

/// Pre-computed type bitmask for fast oneOf/anyOf branch filtering.
/// Each bit represents a JSON type: null=1, bool=2, int=4, float=8, string=16, array=32, object=64
pub fn typeMaskForValue(instance: std.json.Value) u8 {
    return switch (instance) {
        .null => 1,
        .bool => 2,
        .integer => 4 | 8, // integer matches both integer and number
        .float => 8,
        .number_string => 8,
        .string => 16,
        .array => 32,
        .object => 64,
    };
}

fn typeMaskForSchema(schema: std.json.Value) u8 {
    const obj = switch (schema) {
        .object => |o| o,
        .bool => return 0xFF, // true schema accepts all types
        else => return 0xFF,
    };
    const type_val = obj.get("type") orelse return 0xFF; // no type constraint = accept all
    switch (type_val) {
        .string => |s| return typeMaskForString(s),
        .array => |arr| {
            var mask: u8 = 0;
            for (arr.items) |item| {
                if (item == .string) mask |= typeMaskForString(item.string);
            }
            return if (mask != 0) mask else 0xFF;
        },
        else => return 0xFF,
    }
}

fn typeMaskForString(s: []const u8) u8 {
    if (std.mem.eql(u8, s, "null")) return 1;
    if (std.mem.eql(u8, s, "boolean")) return 2;
    if (std.mem.eql(u8, s, "integer")) return 4 | 8;
    if (std.mem.eql(u8, s, "number")) return 4 | 8;
    if (std.mem.eql(u8, s, "string")) return 16;
    if (std.mem.eql(u8, s, "array")) return 32;
    if (std.mem.eql(u8, s, "object")) return 64;
    return 0xFF;
}

/// Discriminator entry for oneOf optimization: maps a string value to a branch.
pub const DiscriminatorEntry = struct {
    value: []const u8,
    schema: LinkedSchema,
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
    /// True if this schema always validates (e.g., {} or {patternProperties: {"^x-": true}}).
    always_valid: bool = false,
    /// True if this schema has $id or $ref — needs slow path for URI resolution.
    needs_uri_resolution: bool = false,
    /// True if this schema has $id (scope change).
    has_id: bool = false,
    /// True if this schema has unevaluatedProperties keyword.
    has_unevaluated_properties: bool = false,
    /// Pre-computed ceiling of property names that could be evaluated by any
    /// applicator branch. Non-null only when the schema has unevaluatedProperties.
    unevaluated_ceiling: ?[]const []const u8 = null,
    /// Same ceiling as a hashmap for O(1) lookup (used when ceiling is large).
    unevaluated_ceiling_map: ?*std.StringHashMap(void) = null,
    /// True if additionalProperties (not false) exists anywhere in the schema
    /// or allOf branches, meaning ALL properties are always evaluated.
    unevaluated_all_covered: bool = false,
    /// Pre-compiled regex patterns from patternProperties in applicator branches.
    /// Used by unevaluatedProperties ceiling check to match property names.
    unevaluated_pattern_regexes: ?[]*CompiledRegex = null,

    /// Extended boolean validation. Returns null only for .generic validators.
    /// Handles more cases than isValidFast (ref_overrides, pattern without alloc).
    /// Ultra-fast boolean-only validation. No allocations, no error construction.
    pub fn isValidFast(self: *const CompiledNode, instance: std.json.Value, compiled: *const CompiledSchema) ?bool {
        if (self.always_valid) return true;
        if (self.simple_type != .none) {
            return Validator.matchesSimpleType(instance, self.simple_type);
        }
        if (self.ref_overrides) {
            // Follow pre-linked ref_local if available
            if (self.validators.len == 1) {
                return isValidatorValid(self.validators[0], instance, compiled);
            }
            return null;
        }
        // Unrolled loop for small validator counts (avoids loop overhead)
        const validators = self.validators;
        switch (validators.len) {
            0 => return true,
            1 => return isValidatorValid(validators[0], instance, compiled),
            2 => {
                const r0 = isValidatorValid(validators[0], instance, compiled) orelse return null;
                if (!r0) return false;
                return isValidatorValid(validators[1], instance, compiled);
            },
            3 => {
                const r0 = isValidatorValid(validators[0], instance, compiled) orelse return null;
                if (!r0) return false;
                const r1 = isValidatorValid(validators[1], instance, compiled) orelse return null;
                if (!r1) return false;
                return isValidatorValid(validators[2], instance, compiled);
            },
            else => {},
        }
        for (validators) |v| {
            const result = isValidatorValid(v, instance, compiled) orelse return null;
            if (!result) return false;
        }
        return true;
    }
};

/// Check if a single compiled validator is valid for an instance.
/// Returns null if the validator can't be inlined (caller must use full path).
pub fn isValidatorValid(v: CompiledValidator, instance: std.json.Value, compiled: *const CompiledSchema) ?bool {
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
        .enum_check => |enum_items| {
            for (enum_items) |candidate| {
                if (@import("keywords/enum_keyword.zig").jsonEqual(instance, candidate)) return true;
            }
            return false;
        },
        .enum_string_set => |set| {
            const str = switch (instance) {
                .string => |s| s,
                else => return false,
            };
            return set.get(str) != null;
        },
        .const_check => |const_val| {
            return @import("keywords/enum_keyword.zig").jsonEqual(instance, const_val.*);
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
        // pattern variant removed (replaced by pattern_compiled)
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
        .unique_items => {
            const arr = switch (instance) {
                .array => |a| a.items,
                else => return true,
            };
            // O(n²) but needed for correctness
            if (arr.len <= 1) return true;
            for (0..arr.len - 1) |i| {
                for (i + 1..arr.len) |j| {
                    if (@import("keywords/enum_keyword.zig").jsonEqual(arr[i], arr[j])) return false;
                }
            }
            return true;
        },
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
        .one_of_compiled => |oo| {
            // Discriminator fast path
            if (oo.discriminator_field) |field| {
                if (oo.discriminator_map) |dmap| {
                    const inst_obj = switch (instance) {
                        .object => |o| o,
                        else => return null,
                    };
                    const disc_val = inst_obj.get(field) orelse return null;
                    const disc_str = switch (disc_val) {
                        .string => |s| s,
                        else => return null,
                    };
                    for (dmap) |entry| {
                        if (disc_str.len == entry.value.len and std.mem.eql(u8, disc_str, entry.value)) {
                            return validateLinkedSchema(entry.schema, instance, compiled);
                        }
                    }
                    return false;
                }
            }
            // Type-based filtering: skip branches that can't match the instance type
            const inst_type_mask = typeMaskForValue(instance);
            var match_count: usize = 0;
            for (oo.schemas) |s| {
                if (s.type_mask & inst_type_mask == 0) continue; // type mismatch — skip
                const result = validateLinkedSchema(s, instance, compiled) orelse return null;
                if (result) {
                    match_count += 1;
                    if (match_count > 1) return false;
                }
            }
            return match_count == 1;
        },
        .any_of_compiled => |schemas| {
            const inst_mask = typeMaskForValue(instance);
            var any_null = false;
            for (schemas) |s| {
                if (s.type_mask & inst_mask == 0) continue;
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
            const result = validateLinkedSchema(ls.*, instance, compiled) orelse return null;
            return !result;
        },
        .items_compiled => |ic| {
            const arr = switch (instance) {
                .array => |a| a.items,
                else => return true,
            };
            if (arr.len <= ic.prefix_count) return true;
            if (ic.schema.node) |inode| {
                // Ultra-fast path for simple type items (e.g., {type: "number"})
                if (inode.simple_type != .none) {
                    for (arr[ic.prefix_count..]) |item| {
                        if (!Validator.matchesSimpleType(item, inode.simple_type)) return false;
                    }
                    return true;
                }
                // Fast path for array-of-simple-type (e.g., coordinates: [[number]])
                // Directly check nested arrays without going through full isValidFast
                if (!inode.needs_uri_resolution and !inode.ref_overrides) {
                    if (getNestedSimpleType(inode)) |info| {
                        for (arr[ic.prefix_count..]) |item| {
                            if (!validateNestedArray(item, info.inner_type, info.min_items, info.depth)) return false;
                        }
                        return true;
                    }
                }
            }
            for (arr[ic.prefix_count..]) |item| {
                const result = validateLinkedSchema(ic.schema, item, compiled) orelse return null;
                if (!result) return false;
            }
            return true;
        },
        .object_fast => |of| {
            const obj = switch (instance) {
                .object => |o| o,
                else => return if (of.has_type_object) false else true,
            };
            const keys = obj.keys();
            const vals = obj.values();
            var found_mask: u64 = 0;
            var additional_count: usize = 0;
            if (of.property_map) |pmap| {
                for (keys, vals) |key, val| {
                    if (pmap.get(key)) |pi| {
                        found_mask |= (@as(u64, 1) << @as(u6, @intCast(pi)));
                        const ls = of.properties[pi].schema;
                        // Ultra-fast: inline simple_type
                        if (ls.node) |n| {
                            if (n.always_valid) continue;
                            if (n.simple_type != .none) {
                                if (!Validator.matchesSimpleType(val, n.simple_type)) return false;
                                continue;
                            }
                        }
                        const result = validateLinkedSchema(ls, val, compiled) orelse return null;
                        if (!result) return false;
                    } else {
                        additional_count += 1;
                    }
                }
            } else {
                // Linear scan for small schemas
                for (keys, vals) |key, val| {
                    var matched = false;
                    for (of.properties, 0..) |entry, pi| {
                        if (key.len == entry.name.len and std.mem.eql(u8, key, entry.name)) {
                            found_mask |= (@as(u64, 1) << @as(u6, @intCast(pi)));
                            // Ultra-fast: inline simple_type
                            if (entry.schema.node) |n| {
                                if (n.always_valid) { matched = true; break; }
                                if (n.simple_type != .none) {
                                    if (!Validator.matchesSimpleType(val, n.simple_type)) return false;
                                    matched = true;
                                    break;
                                }
                            }
                            const result = validateLinkedSchema(entry.schema, val, compiled) orelse return null;
                            if (!result) return false;
                            matched = true;
                            break;
                        }
                    }
                    if (!matched) additional_count += 1;
                }
            }
            // Check additionalProperties: false
            if (of.additional_false and additional_count > 0) return false;
            // Check required using bitmask
            if (found_mask & of.required_mask != of.required_mask) return false;
            return true;
        },
        .ref_local => |ls| {
            return validateLinkedSchema(ls.*, instance, compiled);
        },
        .additional_properties_false => |ap| {
            const obj = switch (instance) {
                .object => |o| o,
                else => return true,
            };
            var covered: usize = 0;
            for (ap.property_names) |name| {
                if (obj.get(name) != null) covered += 1;
            }
            if (obj.count() <= covered) return true;
            // Some uncovered — check against pattern regexes
            if (ap.pattern_regexes) |patterns| {
                const keys = obj.keys();
                for (keys) |key| {
                    var found = false;
                    for (ap.property_names) |name| {
                        if (key.len == name.len and std.mem.eql(u8, key, name)) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        var pattern_match = false;
                        for (patterns) |cr| {
                            if (cr.simple_prefix) |prefix| {
                                if (key.len >= prefix.len and std.mem.eql(u8, key[0..prefix.len], prefix)) {
                                    pattern_match = true;
                                    break;
                                }
                            } else if (cr.is_identifier) {
                                if (matchesIdentifierPattern(key)) {
                                    pattern_match = true;
                                    break;
                                }
                            } else {
                                return null; // Can't check complex regex without allocator
                            }
                        }
                        if (!pattern_match) return false;
                    }
                }
                return true;
            }
            return false;
        },
        .additional_properties_schema => |ap| {
            const obj = switch (instance) {
                .object => |o| o,
                else => return true,
            };
            // Fast check: if all properties are defined, no additional props to validate
            var covered: usize = 0;
            for (ap.property_names) |name| {
                if (obj.get(name) != null) covered += 1;
            }
            if (obj.count() <= covered) return true;
            // Has additional properties — validate each against schema
            var it = obj.iterator();
            while (it.next()) |entry| {
                const prop_name = entry.key_ptr.*;
                var is_defined = false;
                for (ap.property_names) |name| {
                    if (std.mem.eql(u8, prop_name, name)) {
                        is_defined = true;
                        break;
                    }
                }
                if (!is_defined) {
                    const result = validateLinkedSchema(ap.schema, entry.value_ptr.*, compiled) orelse return null;
                    if (!result) return false;
                }
            }
            return true;
        },
        .if_then_else_compiled => |ite| {
            const if_result = validateLinkedSchema(ite.if_schema, instance, compiled) orelse return null;
            if (if_result) {
                if (ite.then_schema) |ts| {
                    return validateLinkedSchema(ts, instance, compiled);
                }
                return true;
            } else {
                if (ite.else_schema) |es| {
                    return validateLinkedSchema(es, instance, compiled);
                }
                return true;
            }
        },
        .pattern_compiled => |cr| {
            const instance_str = switch (instance) {
                .string => |s| s,
                else => return true,
            };
            if (!cr.valid) return true;
            if (cr.simple_prefix) |prefix| {
                return instance_str.len >= prefix.len and std.mem.eql(u8, instance_str[0..prefix.len], prefix);
            }
            if (cr.is_identifier) return matchesIdentifierPattern(instance_str);
            // Use stack buffer for null-termination (handles strings up to 511 bytes)
            if (instance_str.len < 512) {
                var buf: [512]u8 = undefined;
                @memcpy(buf[0..instance_str.len], instance_str);
                buf[instance_str.len] = 0;
                return c.regexec(&cr.regex, &buf, 0, null, 0) == 0;
            }
            return null; // too long for stack buffer
        },
        .dependent_required_compiled => |deps| {
            const obj = switch (instance) {
                .object => |o| o,
                else => return true,
            };
            for (deps) |dep| {
                if (obj.get(dep.trigger) != null) {
                    for (dep.required) |req| {
                        if (obj.get(req) == null) return false;
                    }
                }
            }
            return true;
        },
        .contains_compiled => |cc| {
            const arr = switch (instance) {
                .array => |a| a.items,
                else => return true,
            };
            var match_count: usize = 0;
            for (arr) |item| {
                if (validateLinkedSchema(cc.schema, item, compiled)) |result| {
                    if (result) match_count += 1;
                } else return null;
            }
            if (match_count < cc.min_contains) return false;
            if (cc.max_contains) |max| {
                if (match_count > max) return false;
            }
            return true;
        },
        .prefix_items_compiled => |schemas| {
            const arr = switch (instance) {
                .array => |a| a.items,
                else => return true,
            };
            const count = @min(arr.len, schemas.len);
            for (0..count) |i| {
                const result = validateLinkedSchema(schemas[i], arr[i], compiled) orelse return null;
                if (!result) return false;
            }
            return true;
        },
        .dependent_schemas_compiled => |deps| {
            const obj = switch (instance) {
                .object => |o| o,
                else => return true,
            };
            for (deps) |dep| {
                if (obj.get(dep.trigger) != null) {
                    const result = validateLinkedSchema(dep.schema, instance, compiled) orelse return null;
                    if (!result) return false;
                }
            }
            return true;
        },
        .property_names_compiled => |ls_ptr| {
            const ls = ls_ptr.*;
            const obj = switch (instance) {
                .object => |o| o,
                else => return true,
            };
            if (ls.node) |pnode| {
                if (!pnode.needs_uri_resolution) {
                    const keys = obj.keys();
                    for (keys) |key| {
                        const name_val = std.json.Value{ .string = key };
                        if (pnode.isValidFast(name_val, compiled)) |result| {
                            if (!result) return false;
                        } else return null;
                    }
                    return true;
                }
            }
            return null;
        },
        .unevaluated_properties_compiled => |up| {
            if (up.all_covered) return true;
            const obj = switch (instance) {
                .object => |o| o,
                else => return true,
            };
            // Inline ceiling check (no allocation needed for hashmap + prefix match)
            const keys = obj.keys();
            for (keys) |key| {
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
                        if (cr.matches(key, null)) {
                            found = true;
                            break;
                        }
                        // If matches returned false and we can't check further patterns
                        if (cr.simple_prefix == null and !cr.is_identifier and !cr.valid) return null;
                    }
                }
                if (!found) return null; // Can't determine — need full validation
            }
            return true; // All properties covered by ceiling
        },
        .pattern_properties_compiled => |pp_entries| {
            const obj = switch (instance) {
                .object => |o| o,
                else => return true,
            };
            // Only handle if all patterns can be matched without allocation
            for (pp_entries) |pp_entry| {
                if (pp_entry.regex.simple_prefix == null and !pp_entry.regex.is_identifier) return null;
            }
            const keys = obj.keys();
            const vals = obj.values();
            for (keys, vals) |key, val| {
                for (pp_entries) |pp_entry| {
                    const matched = if (pp_entry.regex.simple_prefix) |prefix|
                        key.len >= prefix.len and std.mem.eql(u8, key[0..prefix.len], prefix)
                    else if (pp_entry.regex.is_identifier)
                        matchesIdentifierPattern(key)
                    else
                        false;
                    if (matched) {
                        const result = validateLinkedSchema(pp_entry.schema, val, compiled) orelse return null;
                        if (!result) return false;
                    }
                }
            }
            return true;
        },
        .generic => return null, // can't inline generic validators
    }
}

/// Info about a nested array pattern (e.g., [[number]] or [[[number]]]).
const NestedArrayInfo = struct {
    inner_type: SimpleType,
    min_items: ?u64,
    depth: u8, // 0 = items are simple type, 1 = items are arrays of simple type, etc.
};

/// Detect if a node is an array-of-...-of-simple-type pattern.
/// Returns info about the nesting if found, null otherwise.
fn getNestedSimpleType(node: *const CompiledNode) ?NestedArrayInfo {
    // Node must be an array type with items_compiled
    var has_type_array = false;
    var min_items: ?u64 = null;
    var items_node: ?*const CompiledNode = null;

    for (node.validators) |nv| {
        switch (nv) {
            .type_single => |st| {
                if (st == .array) has_type_array = true else return null;
            },
            .min_items => |m| min_items = m,
            .items_compiled => |ic| {
                items_node = if (ic.schema.node) |n| n else return null;
            },
            .object_fast, .required, .properties_compiled, .generic,
            .pattern_compiled, .pattern_properties_compiled,
            => return null,
            else => {},
        }
    }

    if (!has_type_array) return null;
    const inode = items_node orelse return null;

    // Check if items is a simple type
    if (inode.simple_type != .none) {
        return .{ .inner_type = inode.simple_type, .min_items = min_items, .depth = 0 };
    }

    // Check if items is another array (recursive)
    if (!inode.needs_uri_resolution and !inode.ref_overrides) {
        if (getNestedSimpleType(inode)) |inner| {
            if (inner.depth < 4) { // limit recursion
                return .{ .inner_type = inner.inner_type, .min_items = min_items, .depth = inner.depth + 1 };
            }
        }
    }

    return null;
}

/// Validate a nested array structure directly without recursive isValidFast calls.
fn validateNestedArray(instance: std.json.Value, inner_type: SimpleType, min_items: ?u64, depth: u8) bool {
    const arr = switch (instance) {
        .array => |a| a.items,
        else => return false,
    };
    if (min_items) |m| {
        if (arr.len < m) return false;
    }
    if (depth == 0) {
        // Innermost level: check each element against simple type
        for (arr) |item| {
            if (!Validator.matchesSimpleType(item, inner_type)) return false;
        }
        return true;
    }
    // Recurse one level deeper
    for (arr) |item| {
        if (!validateNestedArray(item, inner_type, null, depth - 1)) return false;
    }
    return true;
}

/// Check if all $ref in the validators are pre-linked (ref_local).
fn allRefsPreLinked(validators: []const CompiledValidator) bool {
    for (validators) |v| {
        switch (v) {
            .generic => |g| {
                if (std.mem.eql(u8, g.keyword_name, "$ref")) return false;
            },
            .ref_local => {},
            else => {},
        }
    }
    return true;
}

/// Check if validators always pass (no-op schema).
fn isAlwaysValid(validators: []const CompiledValidator) bool {
    for (validators) |v| {
        switch (v) {
            .pattern_properties_compiled => |pp_entries| {
                for (pp_entries) |entry| {
                    if (entry.schema.value != .bool or !entry.schema.value.bool) return false;
                }
            },
            else => return false,
        }
    }
    return true;
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
/// Post-process pass: for nodes with $ref (needs_uri_resolution=true),
/// check if the $ref target is fully inlinable. If so, set needs_uri_resolution=false
/// so isValidFast can be called on this node (delegating to the target via pre-linked validators).
fn optimizeRefResolution(root_schema: std.json.Value, node_map: *const CompiledSchema.NodeMap) void {
    const schema_reg = @import("schema_registry.zig");
    // Multi-pass: keep iterating until no more changes
    var changed = true;
    while (changed) {
        changed = false;
        var it = node_map.iterator();
        while (it.next()) |entry| {
            const node = entry.value_ptr.*;
            if (!node.needs_uri_resolution) continue;
            // Skip nodes with $id — they always need URI resolution for scope change
            if (node.has_id) continue;
            // Check if ALL refs in this node are fully inlinable
            var can_clear = true;
            for (node.validators) |v| {
                switch (v) {
                    .generic => |g| {
                        if (std.mem.eql(u8, g.keyword_name, "$ref")) {
                            const ref_str = switch (g.keyword_value) {
                                .string => |s| s,
                                else => {
                                    can_clear = false;
                                    break;
                                },
                            };
                            if (ref_str.len >= 2 and ref_str[0] == '#' and ref_str[1] == '/') {
                                if (schema_reg.resolvePointer(root_schema, ref_str[2..])) |resolved| {
                                    if (resolved == .object) {
                                        if (node_map.get(@intFromPtr(resolved.object.keys().ptr))) |target| {
                                            if (!isNodeFullyInlinable(target) and !target.always_valid) {
                                                can_clear = false;
                                            }
                                        } else can_clear = false;
                                    } else can_clear = false;
                                } else can_clear = false;
                            } else can_clear = false;
                        }
                    },
                    .ref_local => |ls| {
                        if (ls.node) |target| {
                            if (target.needs_uri_resolution and !target.always_valid) {
                                can_clear = false;
                            }
                        } else can_clear = false;
                    },
                    else => {},
                }
                if (!can_clear) break;
            }
            if (can_clear) {
                node.needs_uri_resolution = false;
                changed = true;
            }
        }
    }
}

/// Check if a node's isValidFast is guaranteed to never return null.
/// Only checks the immediate level (1-deep) — pre-linked variants
/// that recurse into sub-schemas may still return null at deeper levels.
fn isNodeFullyInlinable(node: *const CompiledNode) bool {
    if (node.needs_uri_resolution) return false;
    if (node.ref_overrides) return false;
    if (node.simple_type != .none) return true;
    for (node.validators) |v| {
        switch (v) {
            .generic => return false,
            .pattern_properties_compiled => |pp| {
                for (pp) |entry| {
                    if (entry.regex.simple_prefix == null and !entry.regex.is_identifier) return false;
                }
            },
            else => {},
        }
    }
    // unevaluated_properties_compiled is handled by isValidatorValid
    // (only for ceiling-based checks without regex allocation)
    return true;
}

fn validateLinkedSchema(ls: LinkedSchema, instance: std.json.Value, compiled: *const CompiledSchema) ?bool {
    if (ls.node) |node| {
        if (node.always_valid) return true;
        if (node.simple_type != .none) return Validator.matchesSimpleType(instance, node.simple_type);
        if (node.has_id) return null;
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
    var mask = typeMaskForSchema(value);
    // Infer tighter type mask from compiled node (helps $ref branches)
    if (mask == 0xFF) {
        if (node) |n| {
            if (n.simple_type != .none) {
                mask = typeMaskForString(switch (n.simple_type) {
                    .null => "null",
                    .boolean => "boolean",
                    .integer => "integer",
                    .number => "number",
                    .string => "string",
                    .array => "array",
                    .object => "object",
                    .none => "",
                });
            } else {
                // Check validators for type constraints
                for (n.validators) |v| {
                    switch (v) {
                        .type_single => |st| {
                            mask = typeMaskForString(switch (st) {
                                .null => "null",
                                .boolean => "boolean",
                                .integer => "integer",
                                .number => "number",
                                .string => "string",
                                .array => "array",
                                .object => "object",
                                .none => "",
                            });
                            break;
                        },
                        .type_multi => |types| {
                            mask = 0;
                            for (types) |st| {
                                mask |= typeMaskForString(switch (st) {
                                    .null => "null",
                                    .boolean => "boolean",
                                    .integer => "integer",
                                    .number => "number",
                                    .string => "string",
                                    .array => "array",
                                    .object => "object",
                                    .none => "",
                                });
                            }
                            break;
                        },
                        .object_fast => { mask = 64; break; },
                        else => {},
                    }
                }
            }
        }
    }
    return .{ .node = node, .value = value, .type_mask = mask };
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
    root_schema: std.json.Value,
    schema: std.json.Value,
    node_map: *CompiledSchema.NodeMap,
    is_2020: bool,
    validation_vocab_disabled: bool,
    regex_list: *std.ArrayList(*CompiledRegex),
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
            recurseIntoSubSchemas(alloc, obj, root_schema, node_map, is_2020, validation_vocab_disabled, regex_list);

            // 3. Compile keywords with pre-linking via node_map.
            const has_ref = obj.get("$ref") != null;
            const ref_overrides = has_ref and !is_2020;
            var validators = std.ArrayList(CompiledValidator).init(alloc);
            if (!ref_overrides) {
                compileKeywords(alloc, obj, root_schema, &validators, validation_vocab_disabled, node_map, is_2020, regex_list);
            } else {
                // ref_overrides: only compile $ref as ref_local for direct target access
                if (obj.get("$ref")) |kv| {
                    const ref_str = switch (kv) { .string => |s| s, else => null };
                    if (ref_str) |rs| {
                        if (rs.len > 0 and rs[0] == '#') {
                            var resolved: ?std.json.Value = null;
                            if (rs.len == 1) resolved = root_schema
                            else if (rs.len >= 2 and rs[1] == '/') resolved = @import("schema_registry.zig").resolvePointer(root_schema, rs[2..]);
                            if (resolved) |r| {
                                if (alloc.create(LinkedSchema)) |ls| {
                                    ls.* = linkSchema(node_map, r);
                                    validators.append(.{ .ref_local = ls }) catch {};
                                } else |_| {}
                            }
                        }
                    }
                }
            }
            if (!ref_overrides) {
                // Post-process: merge type_single(.object) + required + properties_compiled + additional_properties_false
                // into a single object_fast validator to reduce hashmap lookups
                tryMergeObjectFast(alloc, &validators);
            }

            // 4. Pre-compute unevaluatedProperties ceiling if present.
            var unevaluated_ceiling: ?[]const []const u8 = null;
            var unevaluated_all_covered: bool = false;
            var unevaluated_pattern_regexes: ?[]*CompiledRegex = null;
            if (obj.get("unevaluatedProperties") != null) {
                var ceiling_set = std.StringHashMap(void).init(alloc);
                var seen = std.AutoHashMap(usize, void).init(alloc);
                var pattern_regex_list = std.ArrayList(*CompiledRegex).init(alloc);
                unevaluated_all_covered = collectStaticCeiling(obj, &ceiling_set, root_schema, &seen, alloc, regex_list, &pattern_regex_list);
                var names = std.ArrayList([]const u8).init(alloc);
                var ceil_it = ceiling_set.iterator();
                while (ceil_it.next()) |entry| {
                    names.append(entry.key_ptr.*) catch {};
                }
                unevaluated_ceiling = names.toOwnedSlice() catch &.{};
                if (pattern_regex_list.items.len > 0) {
                    unevaluated_pattern_regexes = pattern_regex_list.toOwnedSlice() catch null;
                }
                // Build hashmap for O(1) ceiling lookup when ceiling is large
            }

            // Build ceiling hashmap for O(1) lookup
            var ceiling_map: ?*std.StringHashMap(void) = null;
            if (unevaluated_ceiling) |ceil| {
                if (ceil.len >= 4) {
                    if (alloc.create(std.StringHashMap(void))) |hm| {
                        hm.* = std.StringHashMap(void).init(alloc);
                        for (ceil) |name| {
                            hm.put(name, {}) catch {};
                        }
                        ceiling_map = hm;
                    } else |_| {}
                }
            }

            // 4b. Replace generic unevaluatedProperties with compiled variant
            if (unevaluated_ceiling != null or unevaluated_all_covered) {
                for (validators.items, 0..) |v, vi| {
                    switch (v) {
                        .generic => |g| {
                            if (std.mem.eql(u8, g.keyword_name, "unevaluatedProperties")) {
                                if (alloc.create(UnevalPropsCompiled)) |up| {
                                    up.* = .{
                                        .schema_value = g.keyword_value,
                                        .ceiling_map = ceiling_map,
                                        .ceiling_arr = unevaluated_ceiling,
                                        .pattern_regexes = unevaluated_pattern_regexes,
                                        .all_covered = unevaluated_all_covered,
                                    };
                                    validators.items[vi] = .{ .unevaluated_properties_compiled = up };
                                } else |_| {}
                                break;
                            }
                        },
                        else => {},
                    }
                }
            }

            // 5. Fill in placeholder with actual data.
            const final_validators = validators.toOwnedSlice() catch &.{};
            // Propagate simple_type through ref_overrides → ref_local chains
            var effective_simple_type = detectSimpleType(obj);
            var effective_always_valid = !ref_overrides and (final_validators.len == 0 or isAlwaysValid(final_validators));
            if (ref_overrides and final_validators.len == 1) {
                switch (final_validators[0]) {
                    .ref_local => |ls| {
                        if (ls.node) |target| {
                            if (target.simple_type != .none) {
                                effective_simple_type = target.simple_type;
                            } else {
                                // Check if target has object_fast (implies .object type)
                                for (target.validators) |tv| {
                                    switch (tv) {
                                        .object_fast => |of| {
                                            if (of.has_type_object) effective_simple_type = .object;
                                            break;
                                        },
                                        .type_single => |st| {
                                            effective_simple_type = st;
                                            break;
                                        },
                                        else => {},
                                    }
                                }
                            }
                            if (target.always_valid) effective_always_valid = true;
                        }
                    },
                    else => {},
                }
            }
            node.* = .{
                .validators = final_validators,
                .ref_overrides = ref_overrides,
                .simple_type = effective_simple_type,
                .always_valid = effective_always_valid,
                .needs_uri_resolution = has_ref or obj.get("$id") != null,
                .has_id = obj.get("$id") != null,
                .has_unevaluated_properties = obj.get("unevaluatedProperties") != null,
                .unevaluated_ceiling = unevaluated_ceiling,
                .unevaluated_ceiling_map = ceiling_map,
                .unevaluated_all_covered = unevaluated_all_covered,
                .unevaluated_pattern_regexes = unevaluated_pattern_regexes,
            };
        },
        .array => |arr| {
            for (arr.items) |item| {
                compileNode(alloc, root_schema, item, node_map, is_2020, validation_vocab_disabled, regex_list);
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
    root_schema: std.json.Value,
    validators: *std.ArrayList(CompiledValidator),
    validation_vocab_disabled: bool,
    node_map: *const CompiledSchema.NodeMap,
    _: bool, // is_2020 — no longer needed in keyword compilation
    regex_list: *std.ArrayList(*CompiledRegex),
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
            // For large string-only enums, use hashset for O(1) lookup
            const use_hashset = blk: {
                const arr = switch (kv) { .array => |a| a, else => break :blk false };
                if (arr.items.len < 4) break :blk false;
                for (arr.items) |item| {
                    if (item != .string) break :blk false;
                }
                break :blk true;
            };
            if (use_hashset) {
                if (alloc.create(std.StringHashMap(void))) |hm| {
                    hm.* = std.StringHashMap(void).init(alloc);
                    for (kv.array.items) |item| {
                        hm.put(item.string, {}) catch {};
                    }
                    validators.append(.{ .enum_string_set = hm }) catch {};
                } else |_| {
                    switch (kv) { .array => |a| validators.append(.{ .enum_check = a.items }) catch {}, else => {} }
                }
            } else {
                switch (kv) { .array => |a| validators.append(.{ .enum_check = a.items }) catch {}, else => {} }
            }
        }
    }
    if (obj.get("const")) |kv| {
        if (!validation_vocab_disabled) {
            if (alloc.create(std.json.Value)) |vp| { vp.* = kv; validators.append(.{ .const_check = vp }) catch {}; } else |_| {}
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
        if (compileRegex(alloc, kv, regex_list)) |cr| {
            validators.append(.{ .pattern_compiled = cr }) catch {};
        } else {
            validators.append(makeGeneric(alloc, @import("keywords/pattern.zig").validate, kv, "pattern")) catch {};
        }
    }

    // Array
    if (obj.get("prefixItems")) |kv| {
        switch (kv) {
            .array => |arr| {
                validators.append(.{ .prefix_items_compiled = linkSchemaArray(alloc, node_map, arr.items) }) catch {};
            },
            else => {},
        }
    }
    if (obj.get("items")) |kv| {
        switch (kv) {
            .object, .bool => {
                if (alloc.create(ItemsCompiled)) |ic_val| {
                    ic_val.* = .{
                        .schema = linkSchema(node_map, kv),
                        .prefix_count = if (obj.get("prefixItems")) |pi| switch (pi) {
                            .array => |a| a.items.len,
                            else => 0,
                        } else 0,
                    };
                    validators.append(.{ .items_compiled = ic_val }) catch {};
                } else |_| {}
            },
            else => {
                validators.append(makeGeneric(alloc, @import("keywords/items.zig").validate, kv, "items")) catch {};
            },
        }
    }
    if (obj.get("additionalItems")) |kv| {
        validators.append(makeGeneric(alloc, @import("keywords/additional_items.zig").validate, kv, "additionalItems")) catch {};
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
                        validators.append(makeGeneric(alloc, @import("keywords/unique_items.zig").validate, kv, "uniqueItems")) catch {};
                    }
                },
                else => {},
            }
        }
    }
    if (obj.get("contains")) |kv| {
        const min_c: usize = if (obj.get("minContains")) |mc| switch (mc) {
            .integer => |n| if (n >= 0) @intCast(n) else 1,
            else => 1,
        } else 1;
        const max_c: ?usize = if (obj.get("maxContains")) |mc| switch (mc) {
            .integer => |n| if (n >= 0) @as(?usize, @intCast(n)) else null,
            else => null,
        } else null;
        if (alloc.create(ContainsCompiled)) |cc_val| {
            cc_val.* = .{
                .schema = linkSchema(node_map, kv),
                .min_contains = min_c,
                .max_contains = max_c,
            };
            validators.append(.{ .contains_compiled = cc_val }) catch {};
        } else |_| {}
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
        const prop_names = extractPropertyNames(alloc, obj);
        // Collect pattern regexes from patternProperties (if any) for additionalProperties check
        const ap_patterns: ?[]const *CompiledRegex = blk: {
            if (obj.get("patternProperties")) |pp_val| {
                if (pp_val == .object) {
                    var pp_regs = std.ArrayList(*CompiledRegex).init(alloc);
                    var pp_it = pp_val.object.iterator();
                    while (pp_it.next()) |pp_entry| {
                        if (compileRegex(alloc, .{ .string = pp_entry.key_ptr.* }, regex_list)) |cr| {
                            pp_regs.append(cr) catch {};
                        }
                    }
                    if (pp_regs.items.len > 0) break :blk pp_regs.toOwnedSlice() catch null;
                }
            }
            break :blk null;
        };

        switch (kv) {
            .bool => |b| {
                if (!b) {
                    validators.append(.{ .additional_properties_false = .{
                        .property_names = prop_names,
                        .pattern_regexes = ap_patterns,
                    } }) catch {};
                }
                // true means allow everything — no validator needed
            },
            .object => {
                if (alloc.create(AdditionalPropsSchemaCompiled)) |aps| {
                    aps.* = .{ .schema = linkSchema(node_map, kv), .property_names = prop_names };
                    validators.append(.{ .additional_properties_schema = aps }) catch {};
                } else |_| {}
            },
            else => {},
        }
    }
    if (obj.get("patternProperties")) |kv| {
        // Try to pre-compile regex patterns
        if (compilePatternProperties(alloc, kv, node_map, regex_list)) |compiled_pp| {
            validators.append(.{ .pattern_properties_compiled = compiled_pp }) catch {};
        } else {
            validators.append(makeGeneric(alloc, @import("keywords/pattern_properties.zig").validate, kv, "patternProperties")) catch {};
        }
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
        if (alloc.create(LinkedSchema)) |ls| { ls.* = linkSchema(node_map, kv); validators.append(.{ .property_names_compiled = ls }) catch {}; } else |_| {}
    }
    if (obj.get("dependencies")) |kv| {
        validators.append(makeGeneric(alloc, @import("keywords/dependencies.zig").validate, kv, "dependencies")) catch {};
        // Also compile array-form dependencies as dependent_required_compiled
        // and schema-form as dependent_schemas_compiled
        if (kv == .object) {
            var dr_entries = std.ArrayList(DependentRequiredEntry).init(alloc);
            var ds_entries = std.ArrayList(DependentSchemaEntry).init(alloc);
            var deps_it = kv.object.iterator();
            while (deps_it.next()) |dep_entry| {
                switch (dep_entry.value_ptr.*) {
                    .array => |arr| {
                        var req_names = std.ArrayList([]const u8).init(alloc);
                        for (arr.items) |item| {
                            if (item == .string) req_names.append(item.string) catch {};
                        }
                        if (req_names.items.len > 0) {
                            dr_entries.append(.{
                                .trigger = dep_entry.key_ptr.*,
                                .required = req_names.toOwnedSlice() catch &.{},
                            }) catch {};
                        }
                    },
                    .object, .bool => {
                        ds_entries.append(.{
                            .trigger = dep_entry.key_ptr.*,
                            .schema = linkSchema(node_map, dep_entry.value_ptr.*),
                        }) catch {};
                    },
                    else => {},
                }
            }
            // Remove the generic and replace with compiled variants
            if (dr_entries.items.len > 0 or ds_entries.items.len > 0) {
                _ = validators.pop(); // remove the generic we just added
                if (dr_entries.items.len > 0) {
                    validators.append(.{ .dependent_required_compiled = dr_entries.toOwnedSlice() catch &.{} }) catch {};
                }
                if (ds_entries.items.len > 0) {
                    validators.append(.{ .dependent_schemas_compiled = ds_entries.toOwnedSlice() catch &.{} }) catch {};
                }
            }
        }
    }
    if (obj.get("dependentRequired")) |kv| {
        if (!validation_vocab_disabled) {
            if (kv == .object) {
                const DREntry = DependentRequiredEntry;
                var dr_entries = std.ArrayList(DREntry).init(alloc);
                var dr_it = kv.object.iterator();
                while (dr_it.next()) |dr_entry| {
                    if (dr_entry.value_ptr.* == .array) {
                        var req_names = std.ArrayList([]const u8).init(alloc);
                        for (dr_entry.value_ptr.*.array.items) |item| {
                            if (item == .string) req_names.append(item.string) catch {};
                        }
                        dr_entries.append(.{
                            .trigger = dr_entry.key_ptr.*,
                            .required = req_names.toOwnedSlice() catch &.{},
                        }) catch {};
                    }
                }
                if (dr_entries.items.len > 0) {
                    validators.append(.{ .dependent_required_compiled = dr_entries.toOwnedSlice() catch &.{} }) catch {};
                }
            }
        }
    }
    if (obj.get("dependentSchemas")) |kv| {
        switch (kv) {
            .object => |deps_obj| {
                var dep_entries = std.ArrayList(DependentSchemaEntry).init(alloc);
                var deps_it = deps_obj.iterator();
                while (deps_it.next()) |dep_entry| {
                    dep_entries.append(.{
                        .trigger = dep_entry.key_ptr.*,
                        .schema = linkSchema(node_map, dep_entry.value_ptr.*),
                    }) catch {};
                }
                validators.append(.{ .dependent_schemas_compiled = dep_entries.toOwnedSlice() catch &.{} }) catch {};
            },
            else => {},
        }
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
                const linked = linkSchemaArray(alloc, node_map, arr.items);
                // Try to detect discriminator pattern
                const disc = detectDiscriminator(alloc, arr.items, linked);
                validators.append(.{ .one_of_compiled = .{
                    .schemas = linked,
                    .discriminator_field = disc.field,
                    .discriminator_map = disc.map,
                } }) catch {};
            },
            else => {},
        }
    }
    if (obj.get("not")) |kv| {
        if (alloc.create(LinkedSchema)) |ls| { ls.* = linkSchema(node_map, kv); validators.append(.{ .not_compiled = ls }) catch {}; } else |_| {}
    }

    // Reference
    if (obj.get("$ref")) |kv| {
        const ref_str = switch (kv) {
            .string => |s| s,
            else => null,
        };
        // For local fragment-only refs, pre-link the target at compile time
        // Pre-link local fragment $refs for both Draft 7 and 2020-12
        // In Draft 7: $ref overrides siblings (handled by ref_overrides flag)
        // In 2020-12: $ref is just another keyword, sibling validators still process
        const can_pre_link = ref_str != null and ref_str.?.len > 0 and ref_str.?[0] == '#';
        if (can_pre_link) {
            const rs = ref_str.?;
            var resolved: ?std.json.Value = null;
            if (rs.len == 1) {
                resolved = root_schema;
            } else if (rs.len >= 2 and rs[1] == '/') {
                resolved = @import("schema_registry.zig").resolvePointer(root_schema, rs[2..]);
            }
            if (resolved) |r| {
                if (alloc.create(LinkedSchema)) |ls| {
                    ls.* = linkSchema(node_map, r);
                    validators.append(.{ .ref_local = ls }) catch {};
                } else |_| {}
            } else {
                validators.append(makeGeneric(alloc, @import("keywords/ref.zig").validate, kv, "$ref")) catch {};
            }
        } else {
            validators.append(makeGeneric(alloc, @import("keywords/ref.zig").validate, kv, "$ref")) catch {};
        }
    }
    if (obj.get("$dynamicRef")) |kv| {
        validators.append(makeGeneric(alloc, @import("keywords/dynamic_ref.zig").validate, kv, "$dynamicRef")) catch {};
    }

    // Conditional
    if (obj.get("if")) |kv| {
        const then_val = obj.get("then");
        const else_val = obj.get("else");
        if (alloc.create(IfThenElseCompiled)) |ite| {
            ite.* = .{
                .if_schema = linkSchema(node_map, kv),
                .then_schema = if (then_val) |tv| linkSchema(node_map, tv) else null,
                .else_schema = if (else_val) |ev| linkSchema(node_map, ev) else null,
            };
            validators.append(.{ .if_then_else_compiled = ite }) catch {};
        } else |_| {}
    }

    // Unevaluated (must be last — depends on other keywords' evaluations)
    if (obj.get("unevaluatedProperties")) |kv| {
        validators.append(makeGeneric(alloc, @import("keywords/unevaluated_properties.zig").validate, kv, "unevaluatedProperties")) catch {};
    }
    if (obj.get("unevaluatedItems")) |kv| {
        // If items (single schema, not array) exists, it evaluates ALL items.
        // unevaluatedItems: false is therefore redundant.
        const has_items_single = if (obj.get("items")) |iv| switch (iv) {
            .object, .bool => true,
            else => false,
        } else false;
        const is_false = kv == .bool and !kv.bool;
        if (has_items_single and is_false) {
            // Skip — items covers all elements, unevaluatedItems: false is no-op
        } else {
            validators.append(makeGeneric(alloc, @import("keywords/unevaluated_items.zig").validate, kv, "unevaluatedItems")) catch {};
        }
    }
}

/// Detect a discriminator pattern in oneOf branches.
/// If all branches have `properties.<field>.enum` with exactly 1 unique value,
/// we can use that field as a discriminator for O(1) branch selection.
fn detectDiscriminator(
    alloc: Allocator,
    branches: []const std.json.Value,
    linked: []const LinkedSchema,
) struct { field: ?[]const u8, map: ?[]const DiscriminatorEntry } {
    if (branches.len < 2) return .{ .field = null, .map = null };

    // Try common discriminator field names
    const candidates = [_][]const u8{ "type", "kind", "discriminator" };
    for (candidates) |field| {
        if (tryBuildDiscriminatorMap(alloc, field, branches, linked)) |dmap| {
            return .{ .field = field, .map = dmap };
        }
    }

    // Try any field that has enum in the first branch
    const first = switch (branches[0]) {
        .object => |o| o,
        else => return .{ .field = null, .map = null },
    };
    const props = switch (first.get("properties") orelse return .{ .field = null, .map = null }) {
        .object => |o| o,
        else => return .{ .field = null, .map = null },
    };
    var pit = props.iterator();
    while (pit.next()) |entry| {
        const prop_name = entry.key_ptr.*;
        const prop_schema = switch (entry.value_ptr.*) {
            .object => |o| o,
            else => continue,
        };
        if (prop_schema.get("enum") != null) {
            if (tryBuildDiscriminatorMap(alloc, prop_name, branches, linked)) |dmap| {
                return .{ .field = prop_name, .map = dmap };
            }
        }
    }

    return .{ .field = null, .map = null };
}

fn tryBuildDiscriminatorMap(
    alloc: Allocator,
    field: []const u8,
    branches: []const std.json.Value,
    linked: []const LinkedSchema,
) ?[]const DiscriminatorEntry {
    var entries = std.ArrayList(DiscriminatorEntry).init(alloc);
    for (branches, 0..) |branch, i| {
        const obj = switch (branch) {
            .object => |o| o,
            else => return null,
        };
        const props = switch (obj.get("properties") orelse return null) {
            .object => |o| o,
            else => return null,
        };
        const field_schema = switch (props.get(field) orelse return null) {
            .object => |o| o,
            else => return null,
        };
        const enum_val = switch (field_schema.get("enum") orelse return null) {
            .array => |a| a,
            else => return null,
        };
        if (enum_val.items.len != 1) return null;
        const disc_str = switch (enum_val.items[0]) {
            .string => |s| s,
            else => return null,
        };
        // Check for duplicates
        for (entries.items) |existing| {
            if (std.mem.eql(u8, existing.value, disc_str)) return null;
        }
        entries.append(.{ .value = disc_str, .schema = linked[i] }) catch return null;
    }
    if (entries.items.len == branches.len) {
        return entries.toOwnedSlice() catch null;
    }
    return null;
}

/// Try to merge separate type(.object) + required + properties_compiled + additional_properties_false
/// validators into a single object_fast validator for reduced per-validation overhead.
fn tryMergeObjectFast(alloc: Allocator, validators: *std.ArrayList(CompiledValidator)) void {
    // Check if we have the right pattern: type_single(.object), required, properties_compiled, additional_properties_false
    // with no other validators that could conflict (no generic, no unevaluated, etc.)
    var has_type_object = false;
    var type_idx: ?usize = null;
    var required_data: ?[]const []const u8 = null;
    var required_idx: ?usize = null;
    var properties_data: ?[]const PropertyEntry = null;
    var properties_idx: ?usize = null;
    var additional_false = false;
    var additional_idx: ?usize = null;
    var has_incompatible = false;

    for (validators.items, 0..) |v, i| {
        switch (v) {
            .type_single => |st| {
                if (st == .object) {
                    has_type_object = true;
                    type_idx = i;
                }
            },
            .required => |r| {
                required_data = r;
                required_idx = i;
            },
            .properties_compiled => |p| {
                properties_data = p;
                properties_idx = i;
            },
            .additional_properties_false => |apf| {
                // Only merge if no pattern regexes (object_fast can't handle patterns)
                if (apf.pattern_regexes == null) {
                    additional_false = true;
                    additional_idx = i;
                }
            },
            // These overlap with object_fast logic — can't merge
            .additional_properties_schema, .object_fast => {
                has_incompatible = true;
            },
            // Everything else is compatible (operates on different aspects)
            else => {},
        }
    }

    // Try to merge allOf properties-only branches into the main properties list
    // This eliminates separate allOf branch evaluations for common patterns like
    // tsconfig where each allOf branch adds one property definition
    for (validators.items, 0..) |v, vi| {
        switch (v) {
            .all_of_compiled => |schemas| {
                var merged_props = std.ArrayList(PropertyEntry).init(alloc);
                // Start with existing properties
                if (properties_data) |pd| {
                    for (pd) |p| merged_props.append(p) catch {};
                }
                var all_merged = true;
                for (schemas, 0..) |s, si| {
                    _ = si;
                    // Check if this branch is a ref_local → properties-only target
                    if (s.node) |snode| {
                        if (snode.ref_overrides and snode.validators.len == 1) {
                            switch (snode.validators[0]) {
                                .ref_local => |ls| {
                                    if (ls.node) |target| {
                                        // Target must be properties-only (object_fast with no required, no additional)
                                        for (target.validators) |tv| {
                                            switch (tv) {
                                                .object_fast => |of| {
                                                    if (of.required_mask == 0 and !of.additional_false) {
                                                        for (of.properties) |p| merged_props.append(p) catch {};
                                                        continue;
                                                    }
                                                },
                                                .properties_compiled => |pc| {
                                                    for (pc) |p| merged_props.append(p) catch {};
                                                    continue;
                                                },
                                                else => {},
                                            }
                                        }
                                    }
                                },
                                else => {},
                            }
                        }
                    }
                    all_merged = false;
                    break;
                }
                if (all_merged and merged_props.items.len > (properties_data orelse &.{}).len) {
                    // All allOf branches were properties-only — merge into main properties
                    properties_data = merged_props.toOwnedSlice() catch properties_data;
                    if (properties_idx == null) {
                        // Insert properties at allOf's position
                        properties_idx = vi;
                        validators.items[vi] = .{ .properties_compiled = properties_data.? };
                    } else {
                        // Update existing properties and remove allOf
                        validators.items[properties_idx.?] = .{ .properties_compiled = properties_data.? };
                        _ = validators.orderedRemove(vi);
                    }
                }
            },
            else => {},
        }
    }

    // Only merge if we have properties and no incompatible validators
    if (properties_data == null or has_incompatible) return;
    // Need properties with > 64 entries? Can't use bitmask
    if (properties_data.?.len > 64) return;

    // Build required bitmask: bit i is set if properties[i] is in the required array
    var required_mask: u64 = 0;
    if (required_data) |req_names| {
        for (req_names) |req_name| {
            for (properties_data.?, 0..) |entry, pi| {
                if (pi >= 64) break;
                if (std.mem.eql(u8, req_name, entry.name)) {
                    required_mask |= (@as(u64, 1) << @as(u6, @intCast(pi)));
                    break;
                }
            }
        }
    }

    // Don't merge if there are required properties NOT in the properties list
    // (they wouldn't be caught by the bitmask check)
    if (required_data) |req_names| {
        for (req_names) |req_name| {
            var in_props = false;
            for (properties_data.?) |entry| {
                if (std.mem.eql(u8, req_name, entry.name)) {
                    in_props = true;
                    break;
                }
            }
            if (!in_props) return; // Can't merge — required name not in properties
        }
    }

    // Build property hashmap for large schemas
    var property_map: ?*std.StringHashMap(u32) = null;
    const props = properties_data.?;
    if (props.len > 8) {
        if (alloc.create(std.StringHashMap(u32))) |hm| {
            hm.* = std.StringHashMap(u32).init(alloc);
            for (props, 0..) |entry, pi| {
                hm.put(entry.name, @intCast(pi)) catch {};
            }
            property_map = hm;
        } else |_| {}
    }

    // Build the merged validator
    const merged = CompiledValidator{ .object_fast = .{
        .properties = props,
        .required_mask = required_mask,
        .additional_false = additional_false,
        .has_type_object = has_type_object,
        .property_map = property_map,
    } };

    // Remove the merged validators (in reverse order to preserve indices)
    var indices_to_remove = std.ArrayList(usize).init(alloc);
    if (type_idx) |idx| indices_to_remove.append(idx) catch {};
    if (required_idx) |idx| indices_to_remove.append(idx) catch {};
    if (properties_idx) |idx| indices_to_remove.append(idx) catch {};
    if (additional_idx) |idx| indices_to_remove.append(idx) catch {};

    // Sort in reverse to remove from back to front
    std.mem.sort(usize, indices_to_remove.items, {}, struct {
        fn f(_: void, a: usize, b: usize) bool {
            return a > b;
        }
    }.f);
    for (indices_to_remove.items) |idx| {
        _ = validators.orderedRemove(idx);
    }

    // Insert the merged validator at the front
    validators.insert(0, merged) catch {};
}

fn makeGeneric(alloc: Allocator, func: Validator.KeywordValidator, kv: std.json.Value, name: []const u8) CompiledValidator {
    if (alloc.create(GenericValidator)) |g| {
        g.* = .{ .func = func, .keyword_value = kv, .keyword_name = name };
        return .{ .generic = g };
    } else |_| {
        return .{ .generic = undefined };
    }
}

/// Extract property names from a schema's "properties" keyword.
fn extractPropertyNames(alloc: Allocator, obj: std.json.ObjectMap) []const []const u8 {
    const props_val = obj.get("properties") orelse return &.{};
    const props_obj = switch (props_val) {
        .object => |o| o,
        else => return &.{},
    };
    var names = std.ArrayList([]const u8).init(alloc);
    var it = props_obj.iterator();
    while (it.next()) |entry| {
        names.append(entry.key_ptr.*) catch {};
    }
    return names.toOwnedSlice() catch &.{};
}

/// Compile a POSIX regex pattern string. Returns null if not a string or compilation fails.
fn compileRegex(alloc: Allocator, pattern_val: std.json.Value, regex_list: *std.ArrayList(*CompiledRegex)) ?*CompiledRegex {
    const pattern_str = switch (pattern_val) {
        .string => |s| s,
        else => return null,
    };
    const cr = alloc.create(CompiledRegex) catch return null;
    cr.simple_prefix = detectSimplePrefix(pattern_str);
    cr.is_identifier = isIdentifierPattern(pattern_str);
    const pattern_z = alloc.dupeZ(u8, pattern_str) catch return null;
    const comp_result = c.regcomp(&cr.regex, pattern_z.ptr, c.REG_EXTENDED | c.REG_NOSUB);
    cr.valid = comp_result == 0;
    regex_list.append(cr) catch {};
    return cr;
}

/// Detect if a regex pattern is a simple "^literal" prefix match.
/// Returns the prefix string if so, null otherwise.
fn detectSimplePrefix(pattern: []const u8) ?[]const u8 {
    if (pattern.len < 2 or pattern[0] != '^') return null;
    // Check that the rest is a literal string (no regex metacharacters)
    const rest = pattern[1..];
    for (rest) |ch| {
        switch (ch) {
            '.', '*', '+', '?', '[', ']', '(', ')', '{', '}', '|', '\\', '$' => return null,
            else => {},
        }
    }
    return rest;
}

/// Check if a string matches the identifier pattern ^[_a-zA-Z][a-zA-Z0-9_-]*$
/// Very common in JSON Schema (property name patterns).
fn isIdentifierPattern(pattern: []const u8) bool {
    return std.mem.eql(u8, pattern, "^[_a-zA-Z][a-zA-Z0-9_-]*$") or
        std.mem.eql(u8, pattern, "^[a-zA-Z_][a-zA-Z0-9_-]*$") or
        std.mem.eql(u8, pattern, "^[a-zA-Z][a-zA-Z0-9_-]*$");
}

fn matchesIdentifierPattern(s: []const u8) bool {
    if (s.len == 0) return false;
    // First char: [_a-zA-Z]
    const first = s[0];
    if (!((first >= 'a' and first <= 'z') or (first >= 'A' and first <= 'Z') or first == '_')) return false;
    // Rest: [a-zA-Z0-9_-]*
    for (s[1..]) |ch| {
        if (!((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '_' or ch == '-')) return false;
    }
    return true;
}

/// Compile patternProperties into pre-compiled regex + linked schemas.
fn compilePatternProperties(
    alloc: Allocator,
    pp_val: std.json.Value,
    node_map: *const CompiledSchema.NodeMap,
    regex_list: *std.ArrayList(*CompiledRegex),
) ?[]const PatternPropertyEntry {
    const pp_obj = switch (pp_val) {
        .object => |o| o,
        else => return null,
    };
    var entries = std.ArrayList(PatternPropertyEntry).init(alloc);
    var it = pp_obj.iterator();
    while (it.next()) |entry| {
        const pattern = entry.key_ptr.*;
        const sub_schema = entry.value_ptr.*;
        const pattern_z = alloc.dupeZ(u8, pattern) catch continue;
        const cr = alloc.create(CompiledRegex) catch continue;
        cr.simple_prefix = detectSimplePrefix(pattern);
        const comp_result = c.regcomp(&cr.regex, pattern_z.ptr, c.REG_EXTENDED | c.REG_NOSUB);
        cr.valid = comp_result == 0;
        regex_list.append(cr) catch {};
        entries.append(.{
            .regex = cr,
            .schema = linkSchema(node_map, sub_schema),
            .pattern = pattern,
        }) catch {};
    }
    if (entries.items.len > 0) {
        return entries.toOwnedSlice() catch null;
    }
    return null;
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
    root_schema: std.json.Value,
    node_map: *CompiledSchema.NodeMap,
    is_2020: bool,
    validation_vocab_disabled: bool,
    regex_list: *std.ArrayList(*CompiledRegex),
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
            compileNode(alloc, root_schema, val, node_map, is_2020, validation_vocab_disabled, regex_list);
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
                        compileNode(alloc, root_schema, item, node_map, is_2020, validation_vocab_disabled, regex_list);
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
                        compileNode(alloc, root_schema, entry.value_ptr.*, node_map, is_2020, validation_vocab_disabled, regex_list);
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
                    compileNode(alloc, root_schema, item, node_map, is_2020, validation_vocab_disabled, regex_list);
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

/// Recursively collect property names that could be evaluated by this schema
/// and all its applicator sub-schemas. Returns true if ALL properties are
/// covered (additionalProperties exists and is not false).
fn collectStaticCeiling(
    obj: std.json.ObjectMap,
    ceiling: *std.StringHashMap(void),
    root_schema: std.json.Value,
    seen: *std.AutoHashMap(usize, void),
    alloc: Allocator,
    regex_list: *std.ArrayList(*CompiledRegex),
    pattern_regexes: *std.ArrayList(*CompiledRegex),
) bool {
    // additionalProperties (not false) means all extra properties are evaluated
    if (obj.get("additionalProperties")) |ap| {
        switch (ap) {
            .bool => |b| {
                if (b) return true;
            },
            .object => return true, // schema-valued additionalProperties evaluates all additional props
            else => {},
        }
    }

    // Collect from properties
    if (obj.get("properties")) |props| {
        if (props == .object) {
            var it = props.object.iterator();
            while (it.next()) |entry| {
                ceiling.put(entry.key_ptr.*, {}) catch {};
            }
        }
    }

    // Collect from patternProperties — compile patterns for ceiling check
    if (obj.get("patternProperties")) |pp| {
        if (pp == .object) {
            var pp_it = pp.object.iterator();
            while (pp_it.next()) |entry| {
                const pattern = entry.key_ptr.*;
                const pattern_z = alloc.dupeZ(u8, pattern) catch continue;
                const cr = alloc.create(CompiledRegex) catch continue;
                cr.simple_prefix = detectSimplePrefix(pattern);
                const comp_result = c.regcomp(&cr.regex, pattern_z.ptr, c.REG_EXTENDED | c.REG_NOSUB);
                cr.valid = comp_result == 0;
                regex_list.append(cr) catch {};
                if (cr.valid or cr.simple_prefix != null) {
                    pattern_regexes.append(cr) catch {};
                }
            }
        }
    }

    const single_applicators = [_][]const u8{ "then", "else", "if" };
    for (single_applicators) |keyword| {
        if (obj.get(keyword)) |sub| {
            if (collectStaticCeilingFromSchema(sub, ceiling, root_schema, seen, alloc, regex_list, pattern_regexes)) return true;
        }
    }

    const array_applicators = [_][]const u8{ "allOf", "anyOf", "oneOf" };
    for (array_applicators) |keyword| {
        if (obj.get(keyword)) |val| {
            if (val == .array) {
                for (val.array.items) |sub| {
                    if (collectStaticCeilingFromSchema(sub, ceiling, root_schema, seen, alloc, regex_list, pattern_regexes)) return true;
                }
            }
        }
    }

    // $ref
    if (obj.get("$ref")) |ref_val| {
        if (ref_val == .string) {
            const ref_str = ref_val.string;
            if (ref_str.len > 0 and ref_str[0] == '#') {
                var resolved: ?std.json.Value = null;
                if (ref_str.len == 1) {
                    resolved = root_schema;
                } else if (ref_str.len >= 2 and ref_str[1] == '/') {
                    resolved = @import("schema_registry.zig").resolvePointer(root_schema, ref_str[2..]);
                }
                if (resolved) |r| {
                    if (collectStaticCeilingFromSchema(r, ceiling, root_schema, seen, alloc, regex_list, pattern_regexes)) return true;
                }
            }
        }
    }

    // dependentSchemas
    if (obj.get("dependentSchemas")) |deps| {
        if (deps == .object) {
            var it = deps.object.iterator();
            while (it.next()) |entry| {
                if (collectStaticCeilingFromSchema(entry.value_ptr.*, ceiling, root_schema, seen, alloc, regex_list, pattern_regexes)) return true;
            }
        }
    }

    return false;
}

fn collectStaticCeilingFromSchema(
    schema_val: std.json.Value,
    ceiling: *std.StringHashMap(void),
    root_schema: std.json.Value,
    seen: *std.AutoHashMap(usize, void),
    alloc: Allocator,
    regex_list: *std.ArrayList(*CompiledRegex),
    pattern_regexes: *std.ArrayList(*CompiledRegex),
) bool {
    switch (schema_val) {
        .object => |obj| {
            const key = @intFromPtr(obj.keys().ptr);
            if (seen.get(key) != null) return false;
            seen.put(key, {}) catch return false;
            return collectStaticCeiling(obj, ceiling, root_schema, seen, alloc, regex_list, pattern_regexes);
        },
        else => return false,
    }
}

/// Scan the schema tree for all $ref values and pre-resolve local fragment references.
fn buildLocalRefCache(
    root: std.json.Value,
    schema: std.json.Value,
    cache: *std.StringHashMap(std.json.Value),
) void {
    switch (schema) {
        .object => |obj| {
            if (obj.get("$ref")) |ref_val| {
                if (ref_val == .string) {
                    const ref_str = ref_val.string;
                    if (cache.get(ref_str) == null and ref_str.len > 0 and ref_str[0] == '#') {
                        if (ref_str.len == 1) {
                            cache.put(ref_str, root) catch {};
                        } else if (ref_str.len >= 2 and ref_str[1] == '/') {
                            if (@import("schema_registry.zig").resolvePointer(root, ref_str[2..])) |resolved| {
                                cache.put(ref_str, resolved) catch {};
                            }
                        }
                    }
                }
            }
            var it = obj.iterator();
            while (it.next()) |entry| {
                buildLocalRefCache(root, entry.value_ptr.*, cache);
            }
        },
        .array => |arr| {
            for (arr.items) |item| {
                buildLocalRefCache(root, item, cache);
            }
        },
        else => {},
    }
}

/// Pre-resolve all $anchor and $dynamicAnchor in the schema tree.
fn buildAnchorCache(schema: std.json.Value, cache: *std.StringHashMap(std.json.Value)) void {
    switch (schema) {
        .object => |obj| {
            // Check $anchor
            if (obj.get("$anchor")) |a| {
                if (a == .string) {
                    cache.put(a.string, schema) catch {};
                }
            }
            // Check $dynamicAnchor
            if (obj.get("$dynamicAnchor")) |da| {
                if (da == .string) {
                    cache.put(da.string, schema) catch {};
                }
            }
            var it = obj.iterator();
            while (it.next()) |entry| {
                buildAnchorCache(entry.value_ptr.*, cache);
            }
        },
        .array => |arr| {
            for (arr.items) |item| {
                buildAnchorCache(item, cache);
            }
        },
        else => {},
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
    // type_single(.object) + properties_compiled merged into object_fast = 1 validator
    try std.testing.expect(root_node.?.validators.len >= 1);

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
