const std = @import("std");
const Allocator = std.mem.Allocator;
const jsonschema = @import("main.zig");
const ValidationError = jsonschema.ValidationError;
const JsonPointer = jsonschema.JsonPointer;

/// Context passed to every keyword validator.
pub const Context = struct {
    allocator: Allocator,
    root_schema: std.json.Value,
    schema: std.json.Value,
    instance: std.json.Value,
    instance_path: []const u8,
    schema_path: []const u8,
    errors: *std.ArrayList(ValidationError),

    /// Recursively validate instance against a sub-schema.
    /// Used by composition keywords (allOf, anyOf, etc.) and $ref.
    pub fn validateSubschema(
        self: Context,
        sub_schema: std.json.Value,
        instance: std.json.Value,
        instance_path: []const u8,
        schema_path: []const u8,
    ) jsonschema.ValidationResult {
        return jsonschema.validateWithPath(
            self.allocator,
            self.root_schema,
            sub_schema,
            instance,
            instance_path,
            schema_path,
        );
    }

    /// Add a validation error to the error list.
    pub fn addError(self: Context, keyword: []const u8, message: []const u8) void {
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
    // Phase 2 keywords will be registered here.
    // Example:
    // .{ "type", @import("keywords/type_keyword.zig").validate },
};

/// Run all applicable keyword validators against the schema/instance pair.
pub fn validateAll(ctx: Context) void {
    const schema_obj = ctx.schema.object;

    inline for (keyword_table) |entry| {
        const keyword_name = entry[0];
        const validator_fn = entry[1];
        if (schema_obj.get(keyword_name) != null) {
            validator_fn(ctx);
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
