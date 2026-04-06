const std = @import("std");
const jsonschema = @import("jsonschema");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Define a schema
    const schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "name": { "type": "string", "minLength": 1 },
        \\    "age": { "type": "integer", "minimum": 0 },
        \\    "email": { "type": "string" }
        \\  },
        \\  "required": ["name", "age"]
        \\}
    ;

    // Parse schema
    const schema = try std.json.parseFromSlice(std.json.Value, allocator, schema_json, .{});
    defer schema.deinit();

    // Valid instance
    const valid_json =
        \\{ "name": "Alice", "age": 30, "email": "alice@example.com" }
    ;
    const valid = try std.json.parseFromSlice(std.json.Value, allocator, valid_json, .{});
    defer valid.deinit();

    const result1 = jsonschema.validate(allocator, schema.value, valid.value);
    defer result1.deinit();
    std.debug.print("Valid instance: {}\n", .{result1.isValid()}); // true

    // Invalid instance (missing required "age", name too short)
    const invalid_json =
        \\{ "name": "" }
    ;
    const invalid = try std.json.parseFromSlice(std.json.Value, allocator, invalid_json, .{});
    defer invalid.deinit();

    const result2 = jsonschema.validate(allocator, schema.value, invalid.value);
    defer result2.deinit();
    std.debug.print("Invalid instance: {}\n", .{result2.isValid()}); // false

    // Print each error
    for (result2.errors) |err| {
        std.debug.print("  [{s}] {s}: {s}\n", .{ err.keyword, err.instance_path, err.message });
    }
}
