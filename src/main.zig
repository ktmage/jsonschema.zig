const std = @import("std");
const Allocator = std.mem.Allocator;

pub const JsonPointer = @import("json_pointer.zig");
const Validator = @import("validator.zig");
pub const CustomKeyword = Validator.CustomKeyword;
pub const KeywordValidator = Validator.KeywordValidator;
pub const SchemaRegistry = @import("schema_registry.zig").SchemaRegistry;
const schema_registry_mod = @import("schema_registry.zig");
const compiled_mod = @import("compiled.zig");
pub const CompiledSchema = compiled_mod.CompiledSchema;
pub const output = @import("output.zig");

/// A single validation error.
///
/// All string fields (`instance_path`, `schema_path`, `message`) are owned by the
/// enclosing `ValidationResult` and freed when `ValidationResult.deinit()` is called.
/// Do not store references to these strings beyond the lifetime of the result.
pub const ValidationError = struct {
    instance_path: []const u8,
    schema_path: []const u8,
    keyword: []const u8,
    message: []const u8,
};

/// The result of a schema validation.
///
/// Use `isValid()` to check whether the instance passed validation.
/// When done inspecting errors, call `deinit()` to release all memory
/// associated with the error messages. Every `ValidationResult` returned
/// by the library **must** be `deinit()`-ed to avoid memory leaks (even
/// when `isValid()` is true).
pub const ValidationResult = struct {
    errors: []const ValidationError,
    annotations: []const Annotation = &.{},
    allocator: Allocator,

    /// Returns `true` when the instance is valid against the schema.
    pub fn isValid(self: ValidationResult) bool {
        return self.errors.len == 0;
    }

    /// Frees all memory owned by this result, including error message strings.
    pub fn deinit(self: ValidationResult) void {
        for (self.errors) |err| {
            self.allocator.free(err.instance_path);
            self.allocator.free(err.schema_path);
            self.allocator.free(err.message);
        }
        self.allocator.free(self.errors);
        for (self.annotations) |ann| {
            self.allocator.free(ann.instance_path);
            self.allocator.free(ann.schema_path);
        }
        if (self.annotations.len > 0) self.allocator.free(self.annotations);
    }
};

/// A collected annotation from a schema keyword.
pub const Annotation = struct {
    /// The keyword that produced this annotation (e.g., "title", "description", "default").
    keyword: []const u8,
    /// JSON Pointer to the instance location.
    instance_path: []const u8,
    /// JSON Pointer to the schema keyword location.
    schema_path: []const u8,
    /// The annotation value as a JSON value.
    value: std.json.Value,
};

/// JSON Schema draft version.
pub const Draft = enum {
    /// Auto-detect from $schema keyword (default).
    auto,
    /// JSON Schema Draft 7.
    draft7,
    /// JSON Schema Draft 2020-12.
    draft2020_12,
};

/// A custom format validator entry.
pub const CustomFormat = struct {
    /// Format name (e.g., "employee-id").
    name: []const u8,
    /// Validation function. Returns true if the string is valid.
    validate: *const fn ([]const u8) bool,
};

/// Options for validation behavior.
pub const ValidateOptions = struct {
    /// JSON Schema draft version (default: auto-detect from $schema).
    draft: Draft = .auto,
    /// Enable format keyword assertion evaluation (default: disabled per spec).
    validate_formats: bool = false,
    /// Custom keyword validators.
    custom_keywords: ?[]const CustomKeyword = null,
    /// Custom format validators (used when validate_formats is true).
    custom_formats: ?[]const CustomFormat = null,
    /// Enable annotation collection (default: disabled for performance).
    collect_annotations: bool = false,
};

pub fn validate(
    allocator: Allocator,
    schema: std.json.Value,
    instance: std.json.Value,
) ValidationResult {
    return validateWithOptions(allocator, schema, instance, .{});
}

/// Validate with options (format control, custom keywords, etc.)
pub fn validateWithOptions(
    allocator: Allocator,
    schema: std.json.Value,
    instance: std.json.Value,
    options: ValidateOptions,
) ValidationResult {
    return validateFull(allocator, schema, schema, instance, "", "", null, "", null, null, options);
}

/// Boolean-only validation: returns true/false without collecting errors.
/// Uses isValidFast first (zero-allocation), falls back to full validation.
pub fn isValidCompiled(
    allocator: Allocator,
    compiled: *const CompiledSchema,
    instance: std.json.Value,
) bool {
    const schema = compiled.schema;
    switch (schema) {
        .bool => |b| return b,
        .object => {},
        else => return true,
    }

    const node = compiled.getNode(schema);
    if (node) |n| {
        if (n.always_valid) return true;
        // No registry in isValidCompiled, so $id doesn't affect resolution.
        // Safe to use isValidFast even with has_id.
        if (n.isValidFast(instance, compiled, allocator)) |result| return result;
    }

    // Fallback: bool_only validateCompiled — zero-allocation path
    // Stack-based errors (sentinel trick sets items.len = 1 without writing data)
    var error_buf: [1]ValidationError = undefined;
    var errors = std.ArrayList(ValidationError){
        .items = error_buf[0..0], // len=0, but ptr is valid stack memory
        .capacity = 1,
        .allocator = allocator,
    };

    const ctx = Validator.Context{
        .allocator = allocator,
        .root_schema = schema,
        .schema = schema,
        .instance = instance,
        .instance_path = "",
        .schema_path = "",
        .errors = &errors,
        .registry = null,
        .base_uri = "",
        .ref_base_uri = "",
        .dynamic_scope = null,
        .compiled = compiled,
        .compiled_node = compiled.getNode(schema),
        .bool_only = true,
    };

    Validator.validateAll(ctx);
    return errors.items.len == 0;
}

/// Validate an instance against a pre-compiled schema.
/// This is the fast path for repeated validation against the same schema.
pub fn validateCompiled(
    allocator: Allocator,
    compiled: *const CompiledSchema,
    instance: std.json.Value,
) ValidationResult {
    const schema = compiled.schema;

    // Handle boolean schemas directly
    switch (schema) {
        .bool => |b| {
            if (b) {
                return .{ .errors = &.{}, .allocator = allocator };
            } else {
                return makeSingleError(allocator, "", "", "false schema", "Schema is false — all values are rejected");
            }
        },
        .object => {},
        else => {
            return .{ .errors = &.{}, .allocator = allocator };
        },
    }

    // Fast path: skip isDraft2020, $id resolution, registry checks, dynamic scope
    var errors = std.ArrayList(ValidationError).init(allocator);

    const ctx = Validator.Context{
        .allocator = allocator,
        .root_schema = schema,
        .schema = schema,
        .instance = instance,
        .instance_path = "",
        .schema_path = "",
        .errors = &errors,
        .registry = null,
        .base_uri = "",
        .ref_base_uri = "",
        .dynamic_scope = null,
        .compiled = compiled,
        .compiled_node = compiled.getNode(schema),
    };

    Validator.validateAll(ctx);

    // Fast path: no errors means no allocation needed for the result
    if (errors.items.len == 0) {
        return .{ .errors = &.{}, .allocator = allocator };
    }

    return .{
        .errors = errors.toOwnedSlice() catch &.{},
        .allocator = allocator,
    };
}

/// Validate an instance against a pre-compiled schema with a registry.
pub fn validateCompiledWithRegistry(
    allocator: Allocator,
    compiled: *const CompiledSchema,
    instance: std.json.Value,
    registry: *SchemaRegistry,
) ValidationResult {
    var dynamic_scope = std.ArrayList(Validator.DynamicScopeEntry).init(allocator);
    defer dynamic_scope.deinit();
    const root_base = blk: {
        const obj = switch (compiled.schema) {
            .object => |o| o,
            else => break :blk @as([]const u8, ""),
        };
        const id_val = obj.get("$id") orelse break :blk @as([]const u8, "");
        break :blk switch (id_val) {
            .string => |s| s,
            else => @as([]const u8, ""),
        };
    };
    dynamic_scope.append(.{ .base_uri = root_base, .schema = compiled.schema }) catch {};
    return validateFull(allocator, compiled.schema, compiled.schema, instance, "", "", registry, "", &dynamic_scope, compiled, .{});
}

pub fn validateWithRegistry(
    allocator: Allocator,
    schema: std.json.Value,
    instance: std.json.Value,
    registry: *SchemaRegistry,
) ValidationResult {
    // Create dynamic scope for 2020-12 support
    var dynamic_scope = std.ArrayList(Validator.DynamicScopeEntry).init(allocator);
    defer dynamic_scope.deinit();
    // Push the root schema as the initial scope entry
    const root_base = blk: {
        const obj = switch (schema) {
            .object => |o| o,
            else => break :blk @as([]const u8, ""),
        };
        const id_val = obj.get("$id") orelse break :blk @as([]const u8, "");
        break :blk switch (id_val) {
            .string => |s| s,
            else => @as([]const u8, ""),
        };
    };
    dynamic_scope.append(.{ .base_uri = root_base, .schema = schema }) catch {};
    return validateFull(allocator, schema, schema, instance, "", "", registry, "", &dynamic_scope, null, .{});
}

fn validateWithPath(
    allocator: Allocator,
    root_schema: std.json.Value,
    schema: std.json.Value,
    instance: std.json.Value,
    instance_path: []const u8,
    schema_path: []const u8,
) ValidationResult {
    return validateFull(allocator, root_schema, schema, instance, instance_path, schema_path, null, "", null, null, .{});
}

fn validateWithContext(
    allocator: Allocator,
    root_schema: std.json.Value,
    schema: std.json.Value,
    instance: std.json.Value,
    instance_path: []const u8,
    schema_path: []const u8,
    registry: ?*SchemaRegistry,
) ValidationResult {
    return validateFull(allocator, root_schema, schema, instance, instance_path, schema_path, registry, "", null, null, .{});
}

pub fn validateFull(
    allocator: Allocator,
    root_schema: std.json.Value,
    schema: std.json.Value,
    instance: std.json.Value,
    instance_path: []const u8,
    schema_path: []const u8,
    registry: ?*SchemaRegistry,
    parent_base_uri: []const u8,
    dynamic_scope: ?*std.ArrayList(Validator.DynamicScopeEntry),
    compiled: ?*const CompiledSchema,
    options: ValidateOptions,
) ValidationResult {
    switch (schema) {
        .bool => |b| {
            if (b) {
                return .{ .errors = &.{}, .allocator = allocator };
            } else {
                return makeSingleError(allocator, instance_path, schema_path, "false schema", "Schema is false — all values are rejected");
            }
        },
        .object => {},
        else => {
            return .{ .errors = &.{}, .allocator = allocator };
        },
    }

    // Determine base URI: if this schema has $id, resolve it against parent
    // In Draft 7, $ref overrides sibling keywords, so $id sibling of $ref
    // should NOT affect $ref resolution. We track parent_base_uri separately.
    // In Draft 2020-12, $ref is a regular keyword and $id always applies.
    const has_ref = schema.object.get("$ref") != null;
    const is_2020 = switch (options.draft) {
        .auto => isDraft2020(root_schema),
        .draft7 => false,
        .draft2020_12 => true,
    };
    const base_uri = blk: {
        if (schema.object.get("$id")) |id_val| {
            if (asString(id_val)) |id_str| {
                if (id_str.len > 0 and id_str[0] != '#') {
                    // Check if this schema is already registered in the registry
                    // under parent_base_uri. If so, $id was already processed
                    // during registration — don't re-resolve.
                    if (registry) |reg| {
                        const pbu_stripped = schema_registry_mod.stripFragment(parent_base_uri);
                        if (reg.schemas.get(pbu_stripped)) |registered| {
                            // Compare by pointer identity: if the registered schema
                            // is the same JSON object, skip $id resolution.
                            if (registered.object.keys().ptr == schema.object.keys().ptr) {
                                break :blk parent_base_uri;
                            }
                        }
                    }
                    break :blk schema_registry_mod.resolveUri(allocator, parent_base_uri, id_str);
                }
            }
        }
        break :blk parent_base_uri;
    };

    // For $ref resolution: in Draft 7, if $ref is present, use parent_base_uri (ignore sibling $id)
    // In 2020-12: $id always applies to $ref
    const ref_base_uri = if (has_ref and !is_2020) parent_base_uri else base_uri;

    // Track dynamic scope: push this schema's base URI if it defines a new scope
    const has_new_scope = schema.object.get("$id") != null;
    if (dynamic_scope) |ds| {
        if (has_new_scope) {
            ds.append(.{ .base_uri = base_uri, .schema = schema }) catch {};
        }
    }
    defer {
        if (dynamic_scope) |ds| {
            if (has_new_scope and ds.items.len > 0) {
                _ = ds.pop();
            }
        }
    }

    var errors = std.ArrayList(ValidationError).init(allocator);
    var annotations_list = if (options.collect_annotations) std.ArrayList(Annotation).init(allocator) else std.ArrayList(Annotation){ .items = &.{}, .capacity = 0, .allocator = allocator };

    const ctx = Validator.Context{
        .allocator = allocator,
        .root_schema = root_schema,
        .schema = schema,
        .instance = instance,
        .instance_path = instance_path,
        .schema_path = schema_path,
        .errors = &errors,
        .registry = registry,
        .base_uri = base_uri,
        .ref_base_uri = ref_base_uri,
        .dynamic_scope = dynamic_scope,
        .compiled = compiled,
        .validate_formats = options.validate_formats,
        .custom_keywords = options.custom_keywords,
        .custom_formats = options.custom_formats,
        .collect_annotations = options.collect_annotations,
        .annotations = if (options.collect_annotations) &annotations_list else null,
    };

    Validator.validateAll(ctx);

    return .{
        .errors = errors.toOwnedSlice() catch &.{},
        .annotations = if (options.collect_annotations) annotations_list.toOwnedSlice() catch &.{} else &.{},
        .allocator = allocator,
    };
}

fn asString(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

/// Validate a schema against its meta-schema.
/// Returns true if the schema is structurally valid JSON Schema.
/// Boolean schemas (true/false) are always valid.
pub fn isValidSchema(allocator: Allocator, schema: std.json.Value) bool {
    switch (schema) {
        .bool => return true,
        .object => |obj| {
            // Get the meta-schema URI from $schema, or use draft-07 default
            const meta_uri = blk: {
                const sv = obj.get("$schema") orelse break :blk "http://json-schema.org/draft-07/schema";
                break :blk switch (sv) {
                    .string => |s| s,
                    else => "http://json-schema.org/draft-07/schema",
                };
            };
            // Create registry which auto-registers built-in metaschemas
            var registry = SchemaRegistry.init(allocator);
            defer registry.deinit();
            // Look up the metaschema
            const metaschema = registry.schemas.get(meta_uri) orelse {
                // Trigger metaschema loading by resolving
                _ = registry.resolve(schema, "", meta_uri);
                return registry.schemas.get(meta_uri) != null;
            };
            // Validate schema-as-instance against metaschema
            const result = validateWithRegistry(allocator, metaschema, schema, &registry);
            defer result.deinit();
            return result.isValid();
        },
        else => return false,
    }
}

/// Bundle a schema by resolving all external $ref targets and embedding them
/// in a self-contained document with $defs. The caller owns the returned JSON
/// (all strings and containers are heap-allocated via `allocator`).
/// Returns null if bundling fails (allocation error).
pub fn bundle(allocator: Allocator, schema: std.json.Value, registry: *SchemaRegistry) ?std.json.Value {
    // Step 1: Collect all external $ref URIs recursively
    var external_refs = std.StringHashMap(std.json.Value).init(allocator);
    defer external_refs.deinit();
    collectExternalRefs(schema, registry, &external_refs);
    if (external_refs.count() == 0) return deepClone(allocator, schema);

    // Step 2: Deep clone the schema
    var cloned = deepClone(allocator, schema) orelse return null;

    // Step 3: Add $defs with all resolved external schemas
    var cloned_obj = switch (cloned) {
        .object => |*o| o,
        else => return cloned,
    };
    // Get or create $defs — must use getPtr to get a pointer into the map
    if (cloned_obj.getPtr("$defs") == null or cloned_obj.getPtr("$defs").?.* != .object) {
        const defs_key = allocator.dupe(u8, "$defs") catch return null;
        cloned_obj.put(defs_key, .{ .object = std.json.ObjectMap.init(allocator) }) catch return null;
    }
    const defs = &cloned_obj.getPtr("$defs").?.object;

    // Add each external schema to $defs
    var ref_it = external_refs.iterator();
    while (ref_it.next()) |entry| {
        const uri = entry.key_ptr.*;
        const ext_schema = entry.value_ptr.*;
        // Use URI as key, replacing / and : with _ for safety
        const safe_key = makeSafeKey(allocator, uri) orelse continue;
        const cloned_ext = deepClone(allocator, ext_schema) orelse continue;
        defs.put(safe_key, cloned_ext) catch {};
    }

    // Step 4: Rewrite external $ref URIs to point to #/$defs/...
    rewriteExternalRefs(&cloned, &external_refs, allocator);

    return cloned;
}

/// Create a safe key from a URI by replacing / and : with _
fn makeSafeKey(allocator: Allocator, uri: []const u8) ?[]u8 {
    const safe_key = allocator.dupe(u8, uri) catch return null;
    for (safe_key) |*ch| {
        if (ch.* == '/' or ch.* == ':') ch.* = '_';
    }
    return safe_key;
}

fn collectExternalRefs(schema: std.json.Value, registry: *SchemaRegistry, refs: *std.StringHashMap(std.json.Value)) void {
    switch (schema) {
        .object => |obj| {
            if (obj.get("$ref")) |ref_val| {
                if (ref_val == .string) {
                    const ref_str = ref_val.string;
                    if (ref_str.len > 0 and ref_str[0] != '#') {
                        // Skip if already collected (prevents infinite recursion on circular refs)
                        if (refs.get(ref_str) == null) {
                            if (registry.schemas.get(ref_str)) |resolved| {
                                refs.put(ref_str, resolved) catch {};
                                // Recurse into resolved schema to find transitive refs
                                collectExternalRefs(resolved, registry, refs);
                            }
                        }
                    }
                }
            }
            var it = obj.iterator();
            while (it.next()) |entry| {
                collectExternalRefs(entry.value_ptr.*, registry, refs);
            }
        },
        .array => |arr| {
            for (arr.items) |item| {
                collectExternalRefs(item, registry, refs);
            }
        },
        else => {},
    }
}

fn rewriteExternalRefs(val: *std.json.Value, refs: *const std.StringHashMap(std.json.Value), allocator: Allocator) void {
    switch (val.*) {
        .object => |*obj| {
            if (obj.getPtr("$ref")) |ref_ptr| {
                if (ref_ptr.* == .string) {
                    const ref_str = ref_ptr.string;
                    if (ref_str.len > 0 and ref_str[0] != '#') {
                        if (refs.get(ref_str) != null) {
                            // Rewrite to #/$defs/safe_key
                            const safe_key = makeSafeKey(allocator, ref_str) orelse return;
                            defer allocator.free(safe_key);
                            const new_ref = std.fmt.allocPrint(allocator, "#/$defs/{s}", .{safe_key}) catch return;
                            ref_ptr.* = .{ .string = new_ref };
                        }
                    }
                }
            }
            var it = obj.iterator();
            while (it.next()) |entry| {
                rewriteExternalRefs(entry.value_ptr, refs, allocator);
            }
        },
        .array => |arr| {
            for (arr.items) |*item| {
                rewriteExternalRefs(item, refs, allocator);
            }
        },
        else => {},
    }
}

/// Deep clone a JSON value, allocating all strings and containers with the given allocator.
fn deepClone(allocator: Allocator, val: std.json.Value) ?std.json.Value {
    return switch (val) {
        .null => .null,
        .bool => |b| .{ .bool = b },
        .integer => |n| .{ .integer = n },
        .float => |f| .{ .float = f },
        .string => |s| .{ .string = allocator.dupe(u8, s) catch return null },
        .array => |arr| blk: {
            var new_arr = std.json.Array.initCapacity(allocator, arr.items.len) catch return null;
            for (arr.items) |item| {
                new_arr.append(deepClone(allocator, item) orelse return null) catch return null;
            }
            break :blk .{ .array = new_arr };
        },
        .object => |obj| blk: {
            var new_obj = std.json.ObjectMap.init(allocator);
            new_obj.ensureTotalCapacity(@intCast(obj.count())) catch return null;
            var it = obj.iterator();
            while (it.next()) |entry| {
                const key = allocator.dupe(u8, entry.key_ptr.*) catch return null;
                const value = deepClone(allocator, entry.value_ptr.*) orelse return null;
                new_obj.put(key, value) catch return null;
            }
            break :blk .{ .object = new_obj };
        },
        .number_string => |s| .{ .number_string = allocator.dupe(u8, s) catch return null },
    };
}

/// Recursively free a deep-cloned JSON value (all strings/containers heap-allocated).
fn freeJsonValue(allocator: Allocator, val: std.json.Value) void {
    switch (val) {
        .string => |s| allocator.free(s),
        .number_string => |s| allocator.free(s),
        .array => |arr| {
            for (arr.items) |item| freeJsonValue(allocator, item);
            var mut_arr = arr;
            mut_arr.deinit();
        },
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                freeJsonValue(allocator, entry.value_ptr.*);
            }
            var mut_obj = obj;
            mut_obj.deinit();
        },
        else => {},
    }
}

pub fn isDraft2020(root_schema: std.json.Value) bool {
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

fn makeSingleError(
    allocator: Allocator,
    instance_path: []const u8,
    schema_path: []const u8,
    keyword: []const u8,
    message: []const u8,
) ValidationResult {
    const errors = allocator.alloc(ValidationError, 1) catch return .{ .errors = &.{}, .allocator = allocator };
    const ip = allocator.dupe(u8, instance_path) catch {
        allocator.free(errors);
        return .{ .errors = &.{}, .allocator = allocator };
    };
    const sp = allocator.dupe(u8, schema_path) catch {
        allocator.free(ip);
        allocator.free(errors);
        return .{ .errors = &.{}, .allocator = allocator };
    };
    const msg = allocator.dupe(u8, message) catch {
        allocator.free(sp);
        allocator.free(ip);
        allocator.free(errors);
        return .{ .errors = &.{}, .allocator = allocator };
    };
    errors[0] = .{ .instance_path = ip, .schema_path = sp, .keyword = keyword, .message = msg };
    return .{ .errors = errors, .allocator = allocator };
}

test "bundle embeds external refs into $defs and rewrites URIs" {
    const allocator = std.testing.allocator;

    // Create a referenced schema: { "type": "string" }
    var ref_schema_obj = std.json.ObjectMap.init(allocator);
    defer ref_schema_obj.deinit();
    try ref_schema_obj.put("type", .{ .string = "string" });
    const ref_schema: std.json.Value = .{ .object = ref_schema_obj };

    // Register it in a schema registry
    var registry = SchemaRegistry.init(allocator);
    defer registry.deinit();
    try registry.addSchema("https://example.com/name.json", ref_schema);

    // Create the root schema:
    // { "properties": { "name": { "$ref": "https://example.com/name.json" } } }
    var name_prop = std.json.ObjectMap.init(allocator);
    defer name_prop.deinit();
    try name_prop.put("$ref", .{ .string = "https://example.com/name.json" });

    var props = std.json.ObjectMap.init(allocator);
    defer props.deinit();
    try props.put("name", .{ .object = name_prop });

    var root_obj = std.json.ObjectMap.init(allocator);
    defer root_obj.deinit();
    try root_obj.put("properties", .{ .object = props });
    const root_schema: std.json.Value = .{ .object = root_obj };

    // Bundle
    const bundled = bundle(allocator, root_schema, &registry) orelse return error.BundleFailed;
    defer freeJsonValue(allocator, bundled);

    // Verify $defs exists and contains the embedded schema
    const bundled_obj = bundled.object;
    const defs_val = bundled_obj.get("$defs") orelse return error.NoDefs;
    const defs_obj = defs_val.object;

    // The safe key for "https://example.com/name.json" is "https___example.com_name.json"
    const safe_key = "https___example.com_name.json";
    const embedded = defs_obj.get(safe_key) orelse return error.NoEmbeddedSchema;
    const embedded_obj = embedded.object;
    try std.testing.expectEqualStrings("string", embedded_obj.get("type").?.string);

    // Verify $ref was rewritten
    const bundled_props = bundled_obj.get("properties").?.object;
    const bundled_name = bundled_props.get("name").?.object;
    const rewritten_ref = bundled_name.get("$ref").?.string;
    try std.testing.expectEqualStrings("#/$defs/https___example.com_name.json", rewritten_ref);
}

test "bundle handles circular references without infinite loop" {
    const allocator = std.testing.allocator;

    // Schema A references B, and B references A
    var schema_a_obj = std.json.ObjectMap.init(allocator);
    defer schema_a_obj.deinit();
    try schema_a_obj.put("$ref", .{ .string = "https://example.com/b.json" });
    const schema_a: std.json.Value = .{ .object = schema_a_obj };

    var schema_b_obj = std.json.ObjectMap.init(allocator);
    defer schema_b_obj.deinit();
    try schema_b_obj.put("$ref", .{ .string = "https://example.com/a.json" });
    const schema_b: std.json.Value = .{ .object = schema_b_obj };

    var registry = SchemaRegistry.init(allocator);
    defer registry.deinit();
    try registry.addSchema("https://example.com/a.json", schema_a);
    try registry.addSchema("https://example.com/b.json", schema_b);

    // Root schema that references A
    var root_obj = std.json.ObjectMap.init(allocator);
    defer root_obj.deinit();
    try root_obj.put("$ref", .{ .string = "https://example.com/a.json" });
    const root_schema: std.json.Value = .{ .object = root_obj };

    // This should not hang — must terminate despite circular refs
    const bundled = bundle(allocator, root_schema, &registry) orelse return error.BundleFailed;
    defer freeJsonValue(allocator, bundled);

    // Verify both external refs are in $defs
    const defs_val = bundled.object.get("$defs") orelse return error.NoDefs;
    try std.testing.expect(defs_val.object.get("https___example.com_a.json") != null);
    try std.testing.expect(defs_val.object.get("https___example.com_b.json") != null);
}

test "bundle with no external refs returns clone" {
    const allocator = std.testing.allocator;

    var root_obj = std.json.ObjectMap.init(allocator);
    defer root_obj.deinit();
    try root_obj.put("type", .{ .string = "string" });
    const root_schema: std.json.Value = .{ .object = root_obj };

    var registry = SchemaRegistry.init(allocator);
    defer registry.deinit();

    const bundled = bundle(allocator, root_schema, &registry) orelse return error.BundleFailed;
    defer freeJsonValue(allocator, bundled);

    // Should be a clone with no $defs added
    try std.testing.expectEqualStrings("string", bundled.object.get("type").?.string);
    try std.testing.expect(bundled.object.get("$defs") == null);
}

test "bundle handles transitive refs" {
    const allocator = std.testing.allocator;

    // B references C (chain: root -> B -> C)
    var schema_c_obj = std.json.ObjectMap.init(allocator);
    defer schema_c_obj.deinit();
    try schema_c_obj.put("type", .{ .string = "integer" });
    const schema_c: std.json.Value = .{ .object = schema_c_obj };

    var schema_b_obj = std.json.ObjectMap.init(allocator);
    defer schema_b_obj.deinit();
    try schema_b_obj.put("$ref", .{ .string = "https://example.com/c.json" });
    const schema_b: std.json.Value = .{ .object = schema_b_obj };

    var registry = SchemaRegistry.init(allocator);
    defer registry.deinit();
    try registry.addSchema("https://example.com/b.json", schema_b);
    try registry.addSchema("https://example.com/c.json", schema_c);

    // Root references B
    var root_obj = std.json.ObjectMap.init(allocator);
    defer root_obj.deinit();
    try root_obj.put("$ref", .{ .string = "https://example.com/b.json" });
    const root_schema: std.json.Value = .{ .object = root_obj };

    const bundled = bundle(allocator, root_schema, &registry) orelse return error.BundleFailed;
    defer freeJsonValue(allocator, bundled);

    // Verify both B and C are in $defs (transitive resolution)
    const defs_val = bundled.object.get("$defs") orelse return error.NoDefs;
    try std.testing.expect(defs_val.object.get("https___example.com_b.json") != null);
    try std.testing.expect(defs_val.object.get("https___example.com_c.json") != null);
}

test {
    _ = @import("test_runner.zig");
    _ = Validator;
    _ = compiled_mod;
    _ = @import("output.zig");
}
