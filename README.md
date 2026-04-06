# jsonschema.zig

[![CI](https://github.com/ktmage/jsonschema.zig/actions/workflows/ci.yml/badge.svg)](https://github.com/ktmage/jsonschema.zig/actions/workflows/ci.yml)

> [!WARNING]
> This entire project — code, tests, optimizations, benchmarks, and this README — was autonomously written by [Claude Code](https://claude.ai/claude-code). No human reviewed the benchmark methodology or verified these numbers are fair. The AI may have unknowingly introduced shortcuts that inflate performance, or configured benchmarks in ways that favor this implementation. We found and fixed 17 correctness bugs during audits, but more may exist. **Treat these benchmarks as rough, unverified estimates — not rigorous measurements.** If you find anything wrong, please [open an issue](https://github.com/ktmage/jsonschema.zig/issues) — it will be fixed immediately.

A [JSON Schema](https://json-schema.org/) validator for Zig — **100% spec-compliant**, zero external dependencies, and built for performance.

**Warm mode** — schema pre-compiled, 550 instances × 100 iterations ([methodology](#benchmark-details)):

| Dataset | jsonschema.zig | [jsonschema](https://crates.io/crates/jsonschema) (Rust) | [jsonschema](https://github.com/santhosh-tekuri/jsonschema) (Go) | [Ajv](https://ajv.js.org/) (JS) | [jsonschema](https://pypi.org/project/jsonschema/) (Python) |
|---------|----:|-----:|---:|----:|-------:|
| helm-chart-lock | **9 ms** | 13 ms | 293 ms | 53 ms | 2,348 ms |
| dependabot | **17 ms** | 27 ms | 262 ms | 26 ms | 2,500 ms |
| geojson | **42 ms** | 53 ms | 2,035 ms | 1,262 ms | 28,490 ms |
| openapi | 1,213 ms | 7,454 ms | 4,219 ms | **262 ms** | 345,985 ms |
| tsconfig | **43 ms** | 89 ms | 367 ms | — | 4,475 ms |
| github-workflow | 66 ms | **56 ms** | 1,259 ms | 300 ms | 21,693 ms |
| package-json | **41 ms** | — | — | — | 3,163 ms |
| cspell | **76 ms** | — | — | 244 ms | 5,468 ms |

**Cold mode** — schema compilation + single validation pass:

| Dataset | jsonschema.zig | jsonschema (Rust) | jsonschema (Go) | Ajv (JS) | jsonschema (Python) |
|---------|----:|-----:|---:|----:|-------:|
| helm-chart-lock | **0.1 ms** | 14 ms | 95 ms | 222 ms | 25 ms |
| dependabot | **0.2 ms** | 54 ms | 263 ms | 582 ms | 28 ms |
| geojson | **0.9 ms** | 326 ms | 1,599 ms | 7,726 ms | 294 ms |
| openapi | **15 ms** | 12,262 ms | 1,886 ms | 4,176 ms | 3,381 ms |
| tsconfig | **1.5 ms** | 2,196 ms | 2,014 ms | — | 50 ms |
| github-workflow | **2.1 ms** | 568 ms | 1,834 ms | 7,604 ms | 225 ms |
| package-json | **1.5 ms** | 201 ms | 1,130 ms | — | 36 ms |
| cspell | **2.1 ms** | 257 ms | 1,590 ms | 4,720 ms | 61 ms |

<details>
<summary id="benchmark-details">Benchmark details</summary>

- **Machine**: Apple M4 Pro (12 cores, 48GB RAM), macOS 15.5
- **Isolation**: Docker containers per language
- **Method**: Median of 5 runs, 100 warm iterations, boolean-only validation (`is_valid`), format validation disabled
- **Schemas**: Real-world schemas from [SchemaStore](https://www.schemastore.org/), [OpenAPI Initiative](https://www.openapis.org/), [GeoJSON](https://geojson.org/)
- **Instances**: Synthetically generated (500 valid + 50 invalid per dataset, deterministic seed)
- **"—"** = the library failed to compile or validate the schema
- **Reproduction**: [github.com/ktmage/jsonschema-bench](https://github.com/ktmage/jsonschema-bench)

</details>

- **Full specification coverage**: Draft 7 (920/920 tests) and Draft 2020-12 (1142/1142 tests) with 100% pass rate against the official [JSON Schema Test Suite](https://github.com/json-schema-org/JSON-Schema-Test-Suite)
- **Minimal dependencies**: Pure Zig with `std` only — links libc for POSIX regex fallback (used for patterns the built-in FastRegex engine doesn't cover)
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

> **Memory model**: `CompiledSchema` holds internal references to the original parsed `schema` JSON value. The parsed schema **must outlive** the `CompiledSchema` — do not call `schema.deinit()` before `compiled.deinit()`. The `CompiledSchema` owns an internal arena allocator that is freed on `deinit()`.
>
> **Thread safety**: A `CompiledSchema` is read-only after compilation and can be shared across threads for concurrent validation. Each validation call must use its own allocator and `ValidationResult`. The original schema JSON must not be modified or freed while any thread is validating.

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

> **Remote schemas**: The library does not automatically fetch remote `$ref` URIs. Fetch schemas yourself (e.g., via `std.http.Client`) and register them with `registry.put()` before validation.

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

## Versioning

This project follows [Semantic Versioning](https://semver.org/):

- **Major** (1.0.0 → 2.0.0): Breaking API changes
- **Minor** (0.1.0 → 0.2.0): New features, backward compatible
- **Patch** (0.1.0 → 0.1.1): Bug fixes only

The library is currently pre-1.0. The public API (`validate`, `validateCompiled`, `validateWithRegistry`, `validateCompiledWithRegistry`, `isValidCompiled`, `CompiledSchema`, `SchemaRegistry`, `ValidationResult`, `CustomKeyword`) may change between minor versions. A 1.0.0 release will signal API stability.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, code style, and PR guidelines.

## License

MIT
