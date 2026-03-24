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

pub const SchemaRegistry = struct {
    allocator: Allocator,
    /// URI (without fragment) -> schema
    schemas: std.StringHashMap(std.json.Value),
    /// Anchor URI (base + "#" + anchor) -> schema
    anchors: std.StringHashMap(std.json.Value),
    /// Parsed metaschema (kept alive for the lifetime of the registry)
    metaschema_parsed: ?std.json.Parsed(std.json.Value) = null,

    pub fn init(allocator: Allocator) SchemaRegistry {
        return .{
            .allocator = allocator,
            .schemas = std.StringHashMap(std.json.Value).init(allocator),
            .anchors = std.StringHashMap(std.json.Value).init(allocator),
        };
    }

    pub fn deinit(self: *SchemaRegistry) void {
        if (self.metaschema_parsed) |p| p.deinit();
        self.schemas.deinit();
        self.anchors.deinit();
    }

    /// Ensure the draft-07 metaschema is registered.
    fn ensureMetaschema(self: *SchemaRegistry) void {
        const uri = "http://json-schema.org/draft-07/schema";
        if (self.schemas.get(uri) != null) return;
        if (self.metaschema_parsed != null) return;

        self.metaschema_parsed = std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            draft07_metaschema_json,
            .{},
        ) catch return;

        if (self.metaschema_parsed) |parsed| {
            self.schemas.put(
                self.allocator.dupe(u8, uri) catch return,
                parsed.value,
            ) catch return;
            // Also scan for $ids inside the metaschema
            self.scanIds(uri, parsed.value);
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
    if (std.mem.lastIndexOfScalar(u8, base_no_frag, '/')) |last_slash| {
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ base_no_frag[0..last_slash], ref }) catch ref;
    }
    return allocator.dupe(u8, ref) catch ref;
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
                // Track $id changes on intermediate schemas
                if (obj.get("$id")) |id_val| {
                    if (asString(id_val)) |id_str| {
                        if (id_str.len > 0 and id_str[0] != '#') {
                            const resolved_id = resolveUri(allocator, current_base, id_str);
                            current_base = stripFragment(resolved_id);
                        }
                    }
                }
                current = obj.get(token) orelse return .{ .schema = null, .base_uri = current_base };
            },
            .array => |arr| {
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
