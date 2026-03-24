const std = @import("std");
const Allocator = std.mem.Allocator;

pub const JsonPointer = @import("json_pointer.zig");
pub const Validator = @import("validator.zig");

pub const ValidationError = struct {
    /// JSON Pointer path to the failing instance
    instance_path: []const u8,
    /// JSON Pointer path to the schema keyword that failed
    schema_path: []const u8,
    /// The keyword that produced this error
    keyword: []const u8,
    /// Human-readable error message
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

/// Validate an instance against a JSON schema.
pub fn validate(
    allocator: Allocator,
    schema: std.json.Value,
    instance: std.json.Value,
) ValidationResult {
    return validateWithPath(allocator, schema, schema, instance, "", "");
}

/// Validate with explicit root schema and paths (for recursive validation).
pub fn validateWithPath(
    allocator: Allocator,
    root_schema: std.json.Value,
    schema: std.json.Value,
    instance: std.json.Value,
    instance_path: []const u8,
    schema_path: []const u8,
) ValidationResult {
    // Boolean schema: true validates everything, false rejects everything
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

    var errors = std.ArrayList(ValidationError).init(allocator);

    const ctx = Validator.Context{
        .allocator = allocator,
        .root_schema = root_schema,
        .schema = schema,
        .instance = instance,
        .instance_path = instance_path,
        .schema_path = schema_path,
        .errors = &errors,
    };

    Validator.validateAll(ctx);

    return .{
        .errors = errors.toOwnedSlice() catch &.{},
        .allocator = allocator,
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
