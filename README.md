# jsonschema.zig

A JSON Schema validator written in Zig. Fully compliant with Draft 7 and Draft 2020-12.

## Compliance

Tested against the official [JSON Schema Test Suite](https://github.com/json-schema-org/JSON-Schema-Test-Suite):

| Draft | Tests | Pass Rate |
|-------|-------|-----------|
| Draft 7 | 920/920 | 100% |
| Draft 2020-12 | 1142/1142 | 100% |

## Supported Keywords

### Draft 7
`type`, `enum`, `const`, `minimum`, `maximum`, `exclusiveMinimum`, `exclusiveMaximum`, `multipleOf`, `minLength`, `maxLength`, `pattern`, `items`, `additionalItems`, `minItems`, `maxItems`, `uniqueItems`, `contains`, `properties`, `required`, `additionalProperties`, `patternProperties`, `minProperties`, `maxProperties`, `propertyNames`, `dependencies`, `allOf`, `anyOf`, `oneOf`, `not`, `if`/`then`/`else`, `$ref`, `definitions`

### Draft 2020-12 (additional)
`prefixItems`, `$defs`, `$anchor`, `dependentRequired`, `dependentSchemas`, `minContains`, `maxContains`, `unevaluatedProperties`, `unevaluatedItems`, `$dynamicRef`, `$dynamicAnchor`

## Requirements

- Zig 0.14.1
- [mise](https://mise.jdx.dev/) (optional, for version management)

## Build

```bash
zig build
```

## Test

```bash
zig build test
```

The test suite is fetched automatically as a lazy dependency on first run.

## Installation

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .jsonschema = .{
        .url = "https://github.com/ktmage/jsonschema.zig/archive/refs/tags/v0.1.0.tar.gz",
        .hash = "HASH", // run `zig fetch <url>` to get this
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

## Usage

```zig
const jsonschema = @import("jsonschema");

const schema = try std.json.parseFromSlice(std.json.Value, allocator, schema_json, .{});
const instance = try std.json.parseFromSlice(std.json.Value, allocator, instance_json, .{});

const result = jsonschema.validate(allocator, schema.value, instance.value);
defer result.deinit();

if (result.isValid()) {
    // valid
} else {
    for (result.errors) |err| {
        std.debug.print("{s}: {s}\n", .{ err.instance_path, err.message });
    }
}
```

## License

MIT
