# jsonschema.zig

A JSON Schema (Draft 7) validator written in Zig.

## Requirements

- Zig 0.14.1
- [mise](https://mise.jdx.dev/) (optional, for version management)

## Build

```bash
zig build
```

## Test

Runs the [JSON Schema Test Suite](https://github.com/json-schema-org/JSON-Schema-Test-Suite) (Draft 7):

```bash
zig build test
```

The test suite is fetched automatically as a lazy dependency on first run.
