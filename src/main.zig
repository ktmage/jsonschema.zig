const std = @import("std");
const Allocator = std.mem.Allocator;

pub const JsonPointer = @import("json_pointer.zig");
pub const Validator = @import("validator.zig");
pub const SchemaRegistry = @import("schema_registry.zig").SchemaRegistry;
const schema_registry_mod = @import("schema_registry.zig");

pub const ValidationError = struct {
    instance_path: []const u8,
    schema_path: []const u8,
    keyword: []const u8,
    message: []const u8,
};

pub const ValidationResult = struct {
    errors: []const ValidationError,
    allocator: Allocator,

    pub fn isValid(self: ValidationResult) bool {
        return self.errors.len == 0;
    }

    pub fn deinit(self: ValidationResult) void {
        for (self.errors) |err| {
            self.allocator.free(err.instance_path);
            self.allocator.free(err.schema_path);
            self.allocator.free(err.message);
        }
        self.allocator.free(self.errors);
    }
};

pub fn validate(
    allocator: Allocator,
    schema: std.json.Value,
    instance: std.json.Value,
) ValidationResult {
    return validateFull(allocator, schema, schema, instance, "", "", null, "", null);
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
    return validateFull(allocator, schema, schema, instance, "", "", registry, "", &dynamic_scope);
}

pub fn validateWithPath(
    allocator: Allocator,
    root_schema: std.json.Value,
    schema: std.json.Value,
    instance: std.json.Value,
    instance_path: []const u8,
    schema_path: []const u8,
) ValidationResult {
    return validateFull(allocator, root_schema, schema, instance, instance_path, schema_path, null, "", null);
}

pub fn validateWithContext(
    allocator: Allocator,
    root_schema: std.json.Value,
    schema: std.json.Value,
    instance: std.json.Value,
    instance_path: []const u8,
    schema_path: []const u8,
    registry: ?*SchemaRegistry,
) ValidationResult {
    return validateFull(allocator, root_schema, schema, instance, instance_path, schema_path, registry, "", null);
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
    const is_2020 = isDraft2020(root_schema);
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
    };

    Validator.validateAll(ctx);

    return .{
        .errors = errors.toOwnedSlice() catch &.{},
        .allocator = allocator,
    };
}

fn asString(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |s| s,
        else => null,
    };
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
    const err = ValidationError{
        .instance_path = allocator.dupe(u8, instance_path) catch "",
        .schema_path = allocator.dupe(u8, schema_path) catch "",
        .keyword = keyword,
        .message = allocator.dupe(u8, message) catch "",
    };
    const errors = allocator.alloc(ValidationError, 1) catch return .{ .errors = &.{}, .allocator = allocator };
    errors[0] = err;
    return .{ .errors = errors, .allocator = allocator };
}

test {
    _ = @import("test_runner.zig");
    _ = Validator;
}
