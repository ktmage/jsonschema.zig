const std = @import("std");
const jsonschema = @import("jsonschema");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Define a schema for validating many instances
    const schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "id": { "type": "integer", "minimum": 1 },
        \\    "status": { "type": "string", "enum": ["active", "inactive", "pending"] }
        \\  },
        \\  "required": ["id", "status"],
        \\  "additionalProperties": false
        \\}
    ;

    const schema = try std.json.parseFromSlice(std.json.Value, allocator, schema_json, .{});
    defer schema.deinit();

    // Compile the schema once for repeated validation
    var compiled = jsonschema.CompiledSchema.compile(allocator, schema.value, null);
    defer compiled.deinit();

    // Validate multiple instances using the compiled schema
    const instances = [_][]const u8{
        \\{ "id": 1, "status": "active" }
        ,
        \\{ "id": 2, "status": "unknown" }
        ,
        \\{ "id": -1, "status": "active" }
        ,
        \\{ "id": 3, "status": "pending", "extra": true }
        ,
    };

    // Use an arena allocator for efficient per-validation memory
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    for (instances, 0..) |instance_json, i| {
        const instance = try std.json.parseFromSlice(std.json.Value, arena.allocator(), instance_json, .{});

        // Fast boolean-only check (zero allocation for valid instances)
        const is_valid = jsonschema.isValidCompiled(arena.allocator(), &compiled, instance.value);
        std.debug.print("Instance {d}: {}\n", .{ i + 1, is_valid });

        if (!is_valid) {
            // Get detailed errors only when needed
            const result = jsonschema.validateCompiled(arena.allocator(), &compiled, instance.value);
            for (result.errors) |err| {
                std.debug.print("  [{s}] {s}\n", .{ err.keyword, err.message });
            }
        }

        _ = arena.reset(.retain_capacity);
    }
}
