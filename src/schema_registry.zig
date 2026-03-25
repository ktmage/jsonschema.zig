const std = @import("std");
const Allocator = std.mem.Allocator;

/// Minimal Draft-07 metaschema (covers type, minLength, maxLength, minimum, maximum, etc.)
const draft07_metaschema_json =
    \\{
    \\  "definitions": {
    \\    "nonNegativeInteger": { "type": "integer", "minimum": 0 },
    \\    "nonNegativeIntegerDefault0": { "type": "integer", "minimum": 0 },
    \\    "simpleTypes": { "enum": ["array","boolean","integer","null","number","object","string"] },
    \\    "stringArray": { "type": "array", "items": { "type": "string" }, "uniqueItems": true },
    \\    "schemaArray": { "type": "array", "items": { "$ref": "#" }, "minItems": 1 }
    \\  },
    \\  "type": ["object", "boolean"],
    \\  "properties": {
    \\    "$id": { "type": "string" },
    \\    "$schema": { "type": "string" },
    \\    "$ref": { "type": "string" },
    \\    "$comment": { "type": "string" },
    \\    "title": { "type": "string" },
    \\    "description": { "type": "string" },
    \\    "default": true,
    \\    "readOnly": { "type": "boolean" },
    \\    "examples": { "type": "array" },
    \\    "multipleOf": { "type": "number", "exclusiveMinimum": 0 },
    \\    "maximum": { "type": "number" },
    \\    "exclusiveMaximum": { "type": "number" },
    \\    "minimum": { "type": "number" },
    \\    "exclusiveMinimum": { "type": "number" },
    \\    "maxLength": { "$ref": "#/definitions/nonNegativeInteger" },
    \\    "minLength": { "$ref": "#/definitions/nonNegativeIntegerDefault0" },
    \\    "pattern": { "type": "string" },
    \\    "additionalItems": { "$ref": "#" },
    \\    "items": { "anyOf": [{ "$ref": "#" }, { "$ref": "#/definitions/schemaArray" }] },
    \\    "maxItems": { "$ref": "#/definitions/nonNegativeInteger" },
    \\    "minItems": { "$ref": "#/definitions/nonNegativeIntegerDefault0" },
    \\    "uniqueItems": { "type": "boolean" },
    \\    "contains": { "$ref": "#" },
    \\    "maxProperties": { "$ref": "#/definitions/nonNegativeInteger" },
    \\    "minProperties": { "$ref": "#/definitions/nonNegativeIntegerDefault0" },
    \\    "required": { "$ref": "#/definitions/stringArray" },
    \\    "additionalProperties": { "$ref": "#" },
    \\    "definitions": { "type": "object", "additionalProperties": { "$ref": "#" } },
    \\    "properties": { "type": "object", "additionalProperties": { "$ref": "#" } },
    \\    "patternProperties": { "type": "object", "additionalProperties": { "$ref": "#" } },
    \\    "dependencies": { "type": "object", "additionalProperties": { "anyOf": [{ "$ref": "#" }, { "$ref": "#/definitions/stringArray" }] } },
    \\    "propertyNames": { "$ref": "#" },
    \\    "const": true,
    \\    "enum": { "type": "array", "minItems": 1, "uniqueItems": true },
    \\    "type": { "anyOf": [{ "$ref": "#/definitions/simpleTypes" }, { "type": "array", "items": { "$ref": "#/definitions/simpleTypes" }, "minItems": 1, "uniqueItems": true }] },
    \\    "format": { "type": "string" },
    \\    "contentMediaType": { "type": "string" },
    \\    "contentEncoding": { "type": "string" },
    \\    "if": { "$ref": "#" },
    \\    "then": { "$ref": "#" },
    \\    "else": { "$ref": "#" },
    \\    "allOf": { "$ref": "#/definitions/schemaArray" },
    \\    "anyOf": { "$ref": "#/definitions/schemaArray" },
    \\    "oneOf": { "$ref": "#/definitions/schemaArray" },
    \\    "not": { "$ref": "#" }
    \\  },
    \\  "additionalProperties": true
    \\}
;

/// Minimal Draft 2020-12 metaschema.
/// This is a simplified version that validates the basic structure.
const draft2020_metaschema_json =
    \\{
    \\  "$schema": "https://json-schema.org/draft/2020-12/schema",
    \\  "$id": "https://json-schema.org/draft/2020-12/schema",
    \\  "$defs": {
    \\    "nonNegativeInteger": { "type": "integer", "minimum": 0 },
    \\    "nonNegativeIntegerDefault0": { "type": "integer", "minimum": 0 },
    \\    "simpleTypes": { "enum": ["array","boolean","integer","null","number","object","string"] },
    \\    "stringArray": { "type": "array", "items": { "type": "string" }, "uniqueItems": true }
    \\  },
    \\  "type": ["object", "boolean"],
    \\  "properties": {
    \\    "$id": { "type": "string" },
    \\    "$schema": { "type": "string" },
    \\    "$ref": { "type": "string" },
    \\    "$anchor": { "type": "string" },
    \\    "$dynamicRef": { "type": "string" },
    \\    "$dynamicAnchor": { "type": "string" },
    \\    "$defs": { "type": "object", "additionalProperties": { "$ref": "#" } },
    \\    "$comment": { "type": "string" },
    \\    "title": { "type": "string" },
    \\    "description": { "type": "string" },
    \\    "default": true,
    \\    "deprecated": { "type": "boolean" },
    \\    "readOnly": { "type": "boolean" },
    \\    "writeOnly": { "type": "boolean" },
    \\    "examples": { "type": "array" },
    \\    "multipleOf": { "type": "number", "exclusiveMinimum": 0 },
    \\    "maximum": { "type": "number" },
    \\    "exclusiveMaximum": { "type": "number" },
    \\    "minimum": { "type": "number" },
    \\    "exclusiveMinimum": { "type": "number" },
    \\    "maxLength": { "$ref": "#/$defs/nonNegativeInteger" },
    \\    "minLength": { "$ref": "#/$defs/nonNegativeIntegerDefault0" },
    \\    "pattern": { "type": "string" },
    \\    "prefixItems": { "type": "array", "items": { "$ref": "#" }, "minItems": 1 },
    \\    "items": { "$ref": "#" },
    \\    "contains": { "$ref": "#" },
    \\    "maxItems": { "$ref": "#/$defs/nonNegativeInteger" },
    \\    "minItems": { "$ref": "#/$defs/nonNegativeIntegerDefault0" },
    \\    "uniqueItems": { "type": "boolean" },
    \\    "maxContains": { "$ref": "#/$defs/nonNegativeInteger" },
    \\    "minContains": { "$ref": "#/$defs/nonNegativeInteger" },
    \\    "maxProperties": { "$ref": "#/$defs/nonNegativeInteger" },
    \\    "minProperties": { "$ref": "#/$defs/nonNegativeIntegerDefault0" },
    \\    "required": { "$ref": "#/$defs/stringArray" },
    \\    "additionalProperties": { "$ref": "#" },
    \\    "properties": { "type": "object", "additionalProperties": { "$ref": "#" } },
    \\    "patternProperties": { "type": "object", "additionalProperties": { "$ref": "#" } },
    \\    "dependentRequired": { "type": "object", "additionalProperties": { "$ref": "#/$defs/stringArray" } },
    \\    "dependentSchemas": { "type": "object", "additionalProperties": { "$ref": "#" } },
    \\    "propertyNames": { "$ref": "#" },
    \\    "const": true,
    \\    "enum": { "type": "array", "minItems": 1, "uniqueItems": true },
    \\    "type": { "anyOf": [{ "$ref": "#/$defs/simpleTypes" }, { "type": "array", "items": { "$ref": "#/$defs/simpleTypes" }, "minItems": 1, "uniqueItems": true }] },
    \\    "if": { "$ref": "#" },
    \\    "then": { "$ref": "#" },
    \\    "else": { "$ref": "#" },
    \\    "allOf": { "type": "array", "items": { "$ref": "#" }, "minItems": 1 },
    \\    "anyOf": { "type": "array", "items": { "$ref": "#" }, "minItems": 1 },
    \\    "oneOf": { "type": "array", "items": { "$ref": "#" }, "minItems": 1 },
    \\    "not": { "$ref": "#" },
    \\    "unevaluatedItems": { "$ref": "#" },
    \\    "unevaluatedProperties": { "$ref": "#" },
    \\    "format": { "type": "string" },
    \\    "contentMediaType": { "type": "string" },
    \\    "contentEncoding": { "type": "string" },
    \\    "contentSchema": { "$ref": "#" }
    \\  },
    \\  "additionalProperties": true
    \\}
;

pub const SchemaRegistry = struct {
    allocator: Allocator,
    /// URI (without fragment) -> schema
    schemas: std.StringHashMap(std.json.Value),
    /// Anchor URI (base + "#" + anchor) -> schema
    anchors: std.StringHashMap(std.json.Value),
    /// Parsed metaschema (kept alive for the lifetime of the registry)
    metaschema_parsed: ?std.json.Parsed(std.json.Value) = null,
    metaschema_2020_parsed: ?std.json.Parsed(std.json.Value) = null,

    pub fn init(allocator: Allocator) SchemaRegistry {
        return .{
            .allocator = allocator,
            .schemas = std.StringHashMap(std.json.Value).init(allocator),
            .anchors = std.StringHashMap(std.json.Value).init(allocator),
        };
    }

    pub fn deinit(self: *SchemaRegistry) void {
        if (self.metaschema_parsed) |p| p.deinit();
        if (self.metaschema_2020_parsed) |p| p.deinit();
        self.schemas.deinit();
        self.anchors.deinit();
    }

    /// Ensure the draft-07 metaschema is registered.
    fn ensureMetaschema(self: *SchemaRegistry) void {
        const uri07 = "http://json-schema.org/draft-07/schema";
        if (self.schemas.get(uri07) == null and self.metaschema_parsed == null) {
            self.metaschema_parsed = std.json.parseFromSlice(
                std.json.Value,
                self.allocator,
                draft07_metaschema_json,
                .{},
            ) catch return;

            if (self.metaschema_parsed) |parsed| {
                self.schemas.put(
                    self.allocator.dupe(u8, uri07) catch return,
                    parsed.value,
                ) catch return;
                self.scanIds(uri07, parsed.value);
            }
        }

        // Also register 2020-12 metaschema (permissive — accepts everything)
        const uri2020 = "https://json-schema.org/draft/2020-12/schema";
        if (self.schemas.get(uri2020) == null and self.metaschema_2020_parsed == null) {
            self.metaschema_2020_parsed = std.json.parseFromSlice(
                std.json.Value,
                self.allocator,
                draft2020_metaschema_json,
                .{},
            ) catch return;

            if (self.metaschema_2020_parsed) |parsed| {
                self.schemas.put(
                    self.allocator.dupe(u8, uri2020) catch return,
                    parsed.value,
                ) catch return;
                self.scanIds(uri2020, parsed.value);
            }
        }
    }

    /// Register an external schema by URI.
    pub fn addSchema(self: *SchemaRegistry, uri: []const u8, schema: std.json.Value) void {
        const key = self.allocator.dupe(u8, uri) catch return;
        self.schemas.put(key, schema) catch return;
    }

    /// Scan a schema tree for $id declarations and register them.
    pub fn scanIds(self: *SchemaRegistry, base_uri: []const u8, schema: std.json.Value) void {
        self.scanIdsRecursive(base_uri, schema);
    }

    fn scanIdsRecursive(self: *SchemaRegistry, base_uri: []const u8, schema: std.json.Value) void {
        const obj = switch (schema) {
            .object => |o| o,
            else => return,
        };

        // Determine this schema's base URI
        var current_base = base_uri;
        if (obj.get("$id")) |id_val| {
            if (asString(id_val)) |id_str| {
                if (isAnchor(id_str)) {
                    // Anchor: $id = "#foo"
                    const anchor_uri = resolveUri(self.allocator, base_uri, id_str);
                    const key = self.allocator.dupe(u8, anchor_uri) catch return;
                    self.anchors.put(key, schema) catch return;
                } else {
                    // URI: $id = "http://..." or relative
                    const resolved = resolveUri(self.allocator, base_uri, id_str);
                    const no_fragment = stripFragment(resolved);
                    const key = self.allocator.dupe(u8, no_fragment) catch return;
                    self.schemas.put(key, schema) catch return;
                    current_base = no_fragment;
                }
            }
        }

        // Support $anchor keyword (Draft 2020-12)
        if (obj.get("$anchor")) |anchor_val| {
            if (asString(anchor_val)) |anchor_str| {
                // Register as base_uri#anchor_name
                const anchor_uri = std.fmt.allocPrint(self.allocator, "{s}#{s}", .{ current_base, anchor_str }) catch return;
                self.anchors.put(anchor_uri, schema) catch return;
            }
        }

        // Support $dynamicAnchor keyword (Draft 2020-12) — also acts as a regular anchor
        if (obj.get("$dynamicAnchor")) |anchor_val| {
            if (asString(anchor_val)) |anchor_str| {
                const anchor_uri = std.fmt.allocPrint(self.allocator, "{s}#{s}", .{ current_base, anchor_str }) catch return;
                self.anchors.put(anchor_uri, schema) catch return;
            }
        }

        // Recurse into all object values and array items
        var it = obj.iterator();
        while (it.next()) |entry| {
            const k = entry.key_ptr.*;
            const v = entry.value_ptr.*;
            // Skip $ref — don't scan inside $ref targets
            if (std.mem.eql(u8, k, "$ref")) continue;
            switch (v) {
                .object => self.scanIdsRecursive(current_base, v),
                .array => |arr| {
                    for (arr.items) |item| {
                        self.scanIdsRecursive(current_base, item);
                    }
                },
                else => {},
            }
        }
    }

    /// Result of resolving a $ref — includes the resolved schema and its root.
    pub const ResolveResult = struct {
        schema: std.json.Value,
        root: std.json.Value,
        base_uri: []const u8,
    };

    /// Resolve a $ref string against this registry.
    /// Returns the resolved schema along with its root schema (for nested $ref resolution).
    pub fn resolveWithRoot(self: *SchemaRegistry, root_schema: std.json.Value, base_uri: []const u8, ref: []const u8) ?ResolveResult {
        // Ensure built-in schemas are registered
        self.ensureMetaschema();
        // 1. Local fragment-only reference: #/definitions/foo or #foo
        if (ref.len > 0 and ref[0] == '#') {
            // Try to resolve against the schema identified by base_uri first
            if (base_uri.len > 0) {
                const base_no_frag = stripFragment(base_uri);
                if (self.schemas.get(base_no_frag)) |base_schema| {
                    if (ref.len == 1) return .{ .schema = base_schema, .root = base_schema, .base_uri = base_no_frag };
                    if (ref.len >= 2 and ref[1] == '/') {
                        // Resolve JSON pointer, tracking $id changes for base URI
                        const ptr_result = resolvePointerWithBaseUri(self.allocator, base_schema, ref[2..], base_no_frag);
                        if (ptr_result.schema) |s| return .{ .schema = s, .root = base_schema, .base_uri = ptr_result.base_uri };
                    }
                    // Anchor: #foo — try with base_uri, then scan schema tree
                    const full = resolveUri(self.allocator, base_no_frag, ref);
                    if (self.anchors.get(full)) |s| return .{ .schema = s, .root = base_schema, .base_uri = base_no_frag };
                    // Lazy anchor scan: search within the target schema tree
                    if (ref.len > 1) {
                        if (findAnchorInSchema(base_schema, ref[1..], base_no_frag, self.allocator)) |s| return .{ .schema = s, .root = base_schema, .base_uri = base_no_frag };
                    }
                }
            }

            // Fall back to root_schema
            if (ref.len == 1) return .{ .schema = root_schema, .root = root_schema, .base_uri = base_uri };
            if (ref.len >= 2 and ref[1] == '/') {
                // Resolve JSON pointer, tracking $id changes for base URI
                const root_base = if (base_uri.len > 0) stripFragment(base_uri) else "";
                const ptr_result = resolvePointerWithBaseUri(self.allocator, root_schema, ref[2..], root_base);
                if (ptr_result.schema) |s| return .{ .schema = s, .root = root_schema, .base_uri = ptr_result.base_uri };
            }
            // Anchor: #foo — try plain and with base_uri
            if (self.anchors.get(ref)) |s| return .{ .schema = s, .root = root_schema, .base_uri = base_uri };
            const full = resolveUri(self.allocator, base_uri, ref);
            if (self.anchors.get(full)) |s| return .{ .schema = s, .root = root_schema, .base_uri = base_uri };
            // Lazy anchor scan in root schema
            if (ref.len > 1) {
                const root_base = if (base_uri.len > 0) stripFragment(base_uri) else "";
                if (findAnchorInSchema(root_schema, ref[1..], root_base, self.allocator)) |s| return .{ .schema = s, .root = root_schema, .base_uri = base_uri };
            }
            return null;
        }

        // 2. Resolve relative/absolute URI
        const resolved = resolveUri(self.allocator, base_uri, ref);

        // Split into URI and fragment
        const fragment_pos = std.mem.indexOfScalar(u8, resolved, '#');
        const uri_part = if (fragment_pos) |p| resolved[0..p] else resolved;
        const fragment = if (fragment_pos) |p| resolved[p..] else null;

        // Look up in schemas registry
        if (self.schemas.get(uri_part)) |target_schema| {
            if (fragment) |frag| {
                if (frag.len == 1) return .{ .schema = target_schema, .root = target_schema, .base_uri = uri_part };
                if (frag.len >= 2 and frag[1] == '/') {
                    const ptr_result = resolvePointerWithBaseUri(self.allocator, target_schema, frag[2..], uri_part);
                    if (ptr_result.schema) |s| return .{ .schema = s, .root = target_schema, .base_uri = ptr_result.base_uri };
                    return null;
                }
                // Anchor fragment
                if (self.anchors.get(resolved)) |s| return .{ .schema = s, .root = target_schema, .base_uri = uri_part };
                // Lazy anchor scan
                if (frag.len > 1) {
                    if (findAnchorInSchema(target_schema, frag[1..], uri_part, self.allocator)) |s| return .{ .schema = s, .root = target_schema, .base_uri = uri_part };
                }
            }
            return .{ .schema = target_schema, .root = target_schema, .base_uri = uri_part };
        }

        return null;
    }

    /// Legacy resolve — returns just the schema (for backward compat).
    pub fn resolve(self: *SchemaRegistry, root_schema: std.json.Value, base_uri: []const u8, ref: []const u8) ?std.json.Value {
        if (self.resolveWithRoot(root_schema, base_uri, ref)) |result| return result.schema;
        return null;
    }
};

/// Resolve a URI reference against a base URI.
pub fn resolveUri(allocator: Allocator, base: []const u8, ref: []const u8) []const u8 {
    // Absolute URI (has scheme)
    if (hasScheme(ref)) return allocator.dupe(u8, ref) catch ref;

    // Fragment-only
    if (ref.len > 0 and ref[0] == '#') {
        const base_no_frag = stripFragment(base);
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ base_no_frag, ref }) catch ref;
    }

    // Absolute path
    if (ref.len > 0 and ref[0] == '/') {
        const scheme_end = schemeEnd(base);
        if (scheme_end) |end| {
            // Find authority end (after //)
            if (base.len > end + 2 and base[end] == '/' and base[end + 1] == '/') {
                const auth_end = std.mem.indexOfScalarPos(u8, base, end + 2, '/') orelse base.len;
                return std.fmt.allocPrint(allocator, "{s}{s}", .{ base[0..auth_end], ref }) catch ref;
            }
            return std.fmt.allocPrint(allocator, "{s}{s}", .{ base[0..end], ref }) catch ref;
        }
        return allocator.dupe(u8, ref) catch ref;
    }

    // Relative path — resolve against base directory
    const base_no_frag = stripFragment(base);
    // Strip leading "./" from ref
    const clean_ref = if (ref.len >= 2 and ref[0] == '.' and ref[1] == '/') ref[2..] else ref;
    if (std.mem.lastIndexOfScalar(u8, base_no_frag, '/')) |last_slash| {
        const resolved_raw = std.fmt.allocPrint(allocator, "{s}/{s}", .{ base_no_frag[0..last_slash], clean_ref }) catch ref;
        return normalizeUri(allocator, resolved_raw);
    }
    return allocator.dupe(u8, clean_ref) catch clean_ref;
}

/// Normalize a URI by resolving ".." and "." segments.
fn normalizeUri(allocator: Allocator, uri: []const u8) []const u8 {
    // Only normalize if there are "./" or "../" patterns
    if (std.mem.indexOf(u8, uri, "./") == null and std.mem.indexOf(u8, uri, "..") == null) return uri;

    // Find where the path starts (after scheme://authority)
    const scheme_end = std.mem.indexOf(u8, uri, "://") orelse return uri;
    const path_start = std.mem.indexOfScalarPos(u8, uri, scheme_end + 3, '/') orelse return uri;

    const prefix = uri[0..path_start];
    const path = uri[path_start..];
    const has_trailing_slash = path.len > 0 and path[path.len - 1] == '/';

    // Split path into segments and resolve . and ..
    var segments = std.ArrayList([]const u8).init(allocator);
    defer segments.deinit();

    var remaining = path;
    while (remaining.len > 0) {
        if (remaining[0] == '/') remaining = remaining[1..];
        if (remaining.len == 0) break;
        const sep = std.mem.indexOfScalar(u8, remaining, '/');
        const seg = if (sep) |s| remaining[0..s] else remaining;
        remaining = if (sep) |s| remaining[s..] else "";

        if (std.mem.eql(u8, seg, ".")) {
            continue;
        } else if (std.mem.eql(u8, seg, "..")) {
            if (segments.items.len > 0) _ = segments.pop();
        } else {
            segments.append(seg) catch return uri;
        }
    }

    // Reconstruct
    var result = std.ArrayList(u8).init(allocator);
    result.appendSlice(prefix) catch return uri;
    for (segments.items) |seg| {
        result.append('/') catch return uri;
        result.appendSlice(seg) catch return uri;
    }
    if (result.items.len == prefix.len) {
        result.append('/') catch return uri;
    }
    // Preserve trailing slash
    if (has_trailing_slash) {
        if (result.items.len > 0 and result.items[result.items.len - 1] != '/') {
            result.append('/') catch return uri;
        }
    }
    return result.toOwnedSlice() catch uri;
}

fn hasScheme(uri: []const u8) bool {
    // Check for "scheme:" pattern
    for (uri, 0..) |c, i| {
        if (c == ':') return i > 0;
        if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') {
            if (i == 0 or !std.ascii.isAlphabetic(uri[0])) return false;
        }
    }
    return false;
}

fn schemeEnd(uri: []const u8) ?usize {
    for (uri, 0..) |c, i| {
        if (c == ':') return i + 1;
        if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') {
            if (i == 0) return null;
        }
    }
    return null;
}

fn isAnchor(id: []const u8) bool {
    return id.len > 0 and id[0] == '#';
}

pub fn stripFragment(uri: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, uri, '#')) |p| uri[0..p] else uri;
}

fn asString(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

/// Walk a JSON Pointer path through a JSON value.
pub fn resolvePointer(value: std.json.Value, pointer: []const u8) ?std.json.Value {
    var current = value;
    var remaining = pointer;
    var has_more = true;

    while (has_more) {
        const sep = std.mem.indexOfScalar(u8, remaining, '/');
        const token_raw = if (sep) |s| remaining[0..s] else remaining;
        if (sep) |s| {
            remaining = remaining[s + 1 ..];
        } else {
            has_more = false;
        }

        const decoded = percentDecode(token_raw);
        const token = unescapeToken(decoded);

        switch (current) {
            .object => |obj| {
                current = obj.get(token) orelse return null;
            },
            .array => |arr| {
                const index = std.fmt.parseInt(usize, token, 10) catch return null;
                if (index >= arr.items.len) return null;
                current = arr.items[index];
            },
            else => return null,
        }
    }

    return current;
}

/// Result of resolving a JSON pointer with base URI tracking.
const PointerBaseResult = struct {
    schema: ?std.json.Value,
    base_uri: []const u8,
};

/// Walk a JSON Pointer path through a JSON value, tracking $id changes for base URI.
pub fn resolvePointerWithBaseUri(allocator: Allocator, value: std.json.Value, pointer: []const u8, initial_base: []const u8) PointerBaseResult {
    var current = value;
    var remaining = pointer;
    var has_more = true;
    var current_base = initial_base;
    var is_first = true;

    while (has_more) {
        const sep = std.mem.indexOfScalar(u8, remaining, '/');
        const token_raw = if (sep) |s| remaining[0..s] else remaining;
        if (sep) |s| {
            remaining = remaining[s + 1 ..];
        } else {
            has_more = false;
        }

        const decoded = percentDecode(token_raw);
        const token = unescapeToken(decoded);

        switch (current) {
            .object => |obj| {
                // Track $id changes on intermediate schemas.
                // Skip the first node if it's the root of a looked-up schema
                // (its $id is already accounted for by the URI lookup).
                if (!is_first) {
                    if (obj.get("$id")) |id_val| {
                        if (asString(id_val)) |id_str| {
                            if (id_str.len > 0 and id_str[0] != '#') {
                                const resolved_id = resolveUri(allocator, current_base, id_str);
                                current_base = stripFragment(resolved_id);
                            }
                        }
                    }
                }
                is_first = false;
                current = obj.get(token) orelse return .{ .schema = null, .base_uri = current_base };
            },
            .array => |arr| {
                is_first = false;
                const index = std.fmt.parseInt(usize, token, 10) catch return .{ .schema = null, .base_uri = current_base };
                if (index >= arr.items.len) return .{ .schema = null, .base_uri = current_base };
                current = arr.items[index];
            },
            else => return .{ .schema = null, .base_uri = current_base },
        }
    }

    // NOTE: Do NOT apply $id from the final resolved schema here.
    // The caller (validateFull) will handle $id on the resolved schema itself.
    // We only tracked $id on intermediate schemas that we traversed through.
    return .{ .schema = current, .base_uri = current_base };
}

/// Search a schema tree for a $id anchor matching the given name.
/// anchor_name should NOT include the '#' prefix.
fn findAnchorInSchema(schema: std.json.Value, anchor_name: []const u8, base_uri: []const u8, allocator: Allocator) ?std.json.Value {
    const obj = switch (schema) {
        .object => |o| o,
        else => return null,
    };

    // Check if this schema has the matching $id anchor
    if (obj.get("$id")) |id_val| {
        if (asString(id_val)) |id_str| {
            if (id_str.len > 0 and id_str[0] == '#') {
                if (std.mem.eql(u8, id_str[1..], anchor_name)) return schema;
            }
        }
    }

    // Check $anchor keyword (Draft 2020-12)
    if (obj.get("$anchor")) |anchor_val| {
        if (asString(anchor_val)) |anchor_str| {
            if (std.mem.eql(u8, anchor_str, anchor_name)) return schema;
        }
    }

    // Check $dynamicAnchor keyword (Draft 2020-12) — also acts as a regular anchor
    if (obj.get("$dynamicAnchor")) |anchor_val| {
        if (asString(anchor_val)) |anchor_str| {
            if (std.mem.eql(u8, anchor_str, anchor_name)) return schema;
        }
    }

    // Determine this schema's base URI for recursion
    var current_base = base_uri;
    if (obj.get("$id")) |id_val| {
        if (asString(id_val)) |id_str| {
            if (id_str.len > 0 and id_str[0] != '#') {
                const resolved = resolveUri(allocator, base_uri, id_str);
                current_base = stripFragment(resolved);
            }
        }
    }

    // Recurse into object values and array items
    var it = obj.iterator();
    while (it.next()) |entry| {
        const k = entry.key_ptr.*;
        const v = entry.value_ptr.*;
        if (std.mem.eql(u8, k, "$ref")) continue;
        switch (v) {
            .object => {
                if (findAnchorInSchema(v, anchor_name, current_base, allocator)) |s| return s;
            },
            .array => |arr| {
                for (arr.items) |item| {
                    if (findAnchorInSchema(item, anchor_name, current_base, allocator)) |s| return s;
                }
            },
            else => {},
        }
    }

    return null;
}

fn percentDecode(input: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, input, '%') == null) return input;
    var buf: [4096]u8 = undefined;
    var len: usize = 0;
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '%' and i + 2 < input.len) {
            const hi = hexVal(input[i + 1]);
            const lo = hexVal(input[i + 2]);
            if (hi != null and lo != null) {
                if (len < buf.len) {
                    buf[len] = (hi.? << 4) | lo.?;
                    len += 1;
                }
                i += 3;
                continue;
            }
        }
        if (len < buf.len) {
            buf[len] = input[i];
            len += 1;
        }
        i += 1;
    }
    return buf[0..len];
}

fn hexVal(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

fn unescapeToken(token: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, token, '~') == null) return token;
    var buf: [4096]u8 = undefined;
    var len: usize = 0;
    var i: usize = 0;
    while (i < token.len) {
        if (token[i] == '~' and i + 1 < token.len) {
            if (token[i + 1] == '1') {
                if (len < buf.len) { buf[len] = '/'; len += 1; }
                i += 2;
                continue;
            } else if (token[i + 1] == '0') {
                if (len < buf.len) { buf[len] = '~'; len += 1; }
                i += 2;
                continue;
            }
        }
        if (len < buf.len) { buf[len] = token[i]; len += 1; }
        i += 1;
    }
    return buf[0..len];
}
