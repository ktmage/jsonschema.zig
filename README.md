# jsonschema.zig

> **Note**: This is an experimental project where [Claude Code](https://claude.ai/claude-code) autonomously wrote all of the code — architecture, spec compliance, keyword logic, performance optimizations, tests, and this README. No human-written code; human involvement was limited to deciding project direction.

A [JSON Schema](https://json-schema.org/) validator for Zig — **100% spec-compliant**, zero external dependencies, and built for performance.

- **Full specification coverage**: Draft 7 (920/920 tests) and Draft 2020-12 (1142/1142 tests) with 100% pass rate against the official [JSON Schema Test Suite](https://github.com/json-schema-org/JSON-Schema-Test-Suite)
- **Zero dependencies**: Pure Zig, only `std` — no C libraries, no allocator hacks
- **Compiled schema mode**: Pre-compile schemas once, validate many times with pre-linked sub-schema dispatch and zero-allocation fast paths
- **Detailed error reporting**: JSON Pointer paths to both the failing instance location and the schema keyword that rejected it

## Quick Start

```zig
const std = @import("std");
const jsonschema = @import("jsonschema");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "name": { "type": "string" },
        \\    "age": { "type": "integer", "minimum": 0 }
        \\  },
        \\  "required": ["name"]
        \\}
    ;
    const instance_json =
        \\{ "name": "Alice", "age": 30 }
    ;

    const schema = try std.json.parseFromSlice(std.json.Value, allocator, schema_json, .{});
    defer schema.deinit();
    const instance = try std.json.parseFromSlice(std.json.Value, allocator, instance_json, .{});
    defer instance.deinit();

    const result = jsonschema.validate(allocator, schema.value, instance.value);
    defer result.deinit();

    if (result.isValid()) {
        std.debug.print("Valid!\n", .{});
    } else {
        for (result.errors) |err| {
            std.debug.print("{s}: {s}\n", .{ err.instance_path, err.message });
        }
    }
}
```

## Compiled Schema (Recommended for Repeated Validation)

When validating many instances against the same schema, compile it once for significantly better throughput:

```zig
// Compile once
var compiled = jsonschema.CompiledSchema.compile(allocator, schema.value, null);
defer compiled.deinit();

// Validate many times
for (instances) |instance| {
    const result = jsonschema.validateCompiled(allocator, &compiled, instance);
    defer result.deinit();
    // ...
}
```

The compiled path pre-links sub-schema references, eliminates hash-map lookups, and enables a zero-allocation `isValidFast` path for common schema patterns.

## Installation

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .jsonschema = .{
        .url = "https://github.com/ktmage/jsonschema.zig/archive/refs/tags/v0.1.0.tar.gz",
        .hash = "HASH", // run: zig fetch <url>
    },
},
```

Then in your `build.zig`:

```zig
const jsonschema_dep = b.dependency("jsonschema", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("jsonschema", jsonschema_dep.module("jsonschema"));
```

## Spec Compliance

Tested against the official [JSON Schema Test Suite](https://github.com/json-schema-org/JSON-Schema-Test-Suite):

- **Draft 7**: 920/920 (100%)
- **Draft 2020-12**: 1142/1142 (100%)

### Supported Keywords

**Draft 7**: `type`, `enum`, `const`, `minimum`, `maximum`, `exclusiveMinimum`, `exclusiveMaximum`, `multipleOf`, `minLength`, `maxLength`, `pattern`, `items`, `additionalItems`, `minItems`, `maxItems`, `uniqueItems`, `contains`, `properties`, `required`, `additionalProperties`, `patternProperties`, `minProperties`, `maxProperties`, `propertyNames`, `dependencies`, `allOf`, `anyOf`, `oneOf`, `not`, `if`/`then`/`else`, `$ref`, `definitions`

**Draft 2020-12 (additional)**: `prefixItems`, `$defs`, `$anchor`, `dependentRequired`, `dependentSchemas`, `minContains`, `maxContains`, `unevaluatedProperties`, `unevaluatedItems`, `$dynamicRef`, `$dynamicAnchor`

## Schema Registry

For schemas that reference external resources (via `$ref` with absolute URIs), you can register them:

```zig
var registry = jsonschema.SchemaRegistry.init(allocator);
defer registry.deinit();

// Register external schemas by URI
try registry.put("https://example.com/address.json", address_schema.value);

// Validate with registry
const result = jsonschema.validateWithRegistry(
    allocator,
    schema.value,
    instance.value,
    &registry,
);
```

## Error Details

Validation errors include JSON Pointer paths for precise error location:

```zig
for (result.errors) |err| {
    // err.instance_path — where in the instance the error occurred (e.g. "/address/zip")
    // err.schema_path   — which schema keyword rejected it (e.g. "/properties/address/properties/zip/pattern")
    // err.keyword       — the keyword name (e.g. "pattern")
    // err.message       — human-readable description
}
```

## Building & Testing

```bash
zig build          # Build the library
zig build test     # Run the full test suite (auto-fetches JSON Schema Test Suite)
```

**Requirements**: Zig 0.14.0+

## License

MIT
