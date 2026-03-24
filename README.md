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

## Bowtie

This implementation includes a [Bowtie](https://bowtie.report/) harness for standardized testing:

```bash
# Build the harness
zig build

# Test locally
echo '{"cmd":"start","version":1}' | ./zig-out/bin/bowtie-zig-jsonschema

# Docker
docker build -t zig-jsonschema .
```

## License

MIT
