const std = @import("std");
const jsonschema = @import("jsonschema");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Define an address schema that will be referenced by $ref
    const address_schema_json =
        \\{
        \\  "$id": "https://example.com/address.json",
        \\  "type": "object",
        \\  "properties": {
        \\    "street": { "type": "string" },
        \\    "city": { "type": "string" },
        \\    "zip": { "type": "string", "pattern": "^[0-9]{5}$" }
        \\  },
        \\  "required": ["street", "city"]
        \\}
    ;

    // Define a person schema that references the address schema
    const person_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "name": { "type": "string" },
        \\    "address": { "$ref": "https://example.com/address.json" }
        \\  },
        \\  "required": ["name"]
        \\}
    ;

    const address_schema = try std.json.parseFromSlice(std.json.Value, allocator, address_schema_json, .{});
    defer address_schema.deinit();

    const person_schema = try std.json.parseFromSlice(std.json.Value, allocator, person_schema_json, .{});
    defer person_schema.deinit();

    // Create a registry and register the address schema
    var registry = jsonschema.SchemaRegistry.init(allocator);
    defer registry.deinit();
    try registry.put("https://example.com/address.json", address_schema.value);

    // Validate a person with a valid address
    const valid_json =
        \\{
        \\  "name": "Bob",
        \\  "address": { "street": "123 Main St", "city": "Springfield", "zip": "12345" }
        \\}
    ;
    const valid = try std.json.parseFromSlice(std.json.Value, allocator, valid_json, .{});
    defer valid.deinit();

    const result1 = jsonschema.validateWithRegistry(allocator, person_schema.value, valid.value, &registry);
    defer result1.deinit();
    std.debug.print("Valid person: {}\n", .{result1.isValid()}); // true

    // Validate a person with an invalid address (missing city)
    const invalid_json =
        \\{
        \\  "name": "Charlie",
        \\  "address": { "street": "456 Oak Ave" }
        \\}
    ;
    const invalid = try std.json.parseFromSlice(std.json.Value, allocator, invalid_json, .{});
    defer invalid.deinit();

    const result2 = jsonschema.validateWithRegistry(allocator, person_schema.value, invalid.value, &registry);
    defer result2.deinit();
    std.debug.print("Invalid person: {}\n", .{result2.isValid()}); // false
    for (result2.errors) |err| {
        std.debug.print("  {s}: {s}\n", .{ err.instance_path, err.message });
    }
}
