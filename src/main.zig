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
    return validateFull(allocator, schema, schema, instance, "", "", null, "");
}

pub fn validateWithRegistry(
    allocator: Allocator,
    schema: std.json.Value,
    instance: std.json.Value,
    registry: *SchemaRegistry,
) ValidationResult {
    return validateFull(allocator, schema, schema, instance, "", "", registry, "");
}

pub fn validateWithPath(
    allocator: Allocator,
    root_schema: std.json.Value,
    schema: std.json.Value,
    instance: std.json.Value,
    instance_path: []const u8,
    schema_path: []const u8,
) ValidationResult {
    return validateFull(allocator, root_schema, schema, instance, instance_path, schema_path, null, "");
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
    return validateFull(allocator, root_schema, schema, instance, instance_path, schema_path, registry, "");
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
    const has_ref = schema.object.get("$ref") != null;
    const base_uri = blk: {
        if (schema.object.get("$id")) |id_val| {
            if (asString(id_val)) |id_str| {
                if (id_str.len > 0 and id_str[0] != '#') {
                    break :blk schema_registry_mod.resolveUri(allocator, parent_base_uri, id_str);
                }
            }
        }
        break :blk parent_base_uri;
    };

    // For $ref resolution: if $ref is present, use parent_base_uri (ignore sibling $id)
    const ref_base_uri = if (has_ref) parent_base_uri else base_uri;

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
