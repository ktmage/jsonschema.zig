# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Custom FastRegex bytecode engine replacing POSIX `regexec` for most patterns
- Bloom filter for O(n) `uniqueItems` validation (replacing O(n²) pairwise comparison)
- `isValidCompiled` API for zero-allocation boolean-only validation
- `CompiledSchema` function pointer dispatch (replacing tagged union switch)
- `object_fast` combined validator for single-pass object validation with bitmask required tracking
- Discriminator map optimization for `oneOf` with type/enum-based branch filtering
- Literal set expansion for regex patterns (O(1) string set lookup)
- Case-insensitive literal detection for regex patterns
- Nested array fast path for coordinate-style validation
- `bool_only` propagation for zero-allocation sub-schema validation
- Benchmark results in README (vs Rust, Go, JS, Python implementations)

### Fixed
- 17 correctness bugs found during code audit:
  - ECMA-262 `\d`, `\w`, `\s` shortcuts now converted to POSIX ERE equivalents
  - `(?:...)` non-capturing groups converted to `(...)` for POSIX ERE compatibility
  - FastRegex: `(group)?` false positives, `[^x]` excluding `\n`, non-ASCII byte handling
  - `expandRegexToLiterals` case-folding preserved original case
  - `>64` property `@intCast` panic fixed with bounds guard
  - `jsonValueHashFast` int/float collision (integer 1 vs float 1.0)
  - `schema_registry` dangling pointers in `percentDecode`/`unescapeToken`
  - `bool_only` UB in `dependent_schemas` and `pattern_properties` validateAll paths
  - `contains.zig` invalid `minContains` skipping contains check
  - `anyOf` null propagation in compiled path

### Changed
- `CompiledValidator` reduced from 240 bytes to 40 bytes
- String hash now samples first+last 16 bytes for better bloom filter distribution
- `isValid_type_multi` uses pre-computed bitmask instead of linear SimpleType iteration
- `isValidationKeyword` uses `StaticStringMap` for O(1) lookup

### Performance
- Warm mode: 2-15x faster than v0.1.0 across all benchmark datasets
- Cold mode: 10-800x faster compilation + validation vs other libraries
- Zero-allocation fast paths for common schema patterns

## [0.1.0] - 2026-03-25

### Added
- Initial release
- Full JSON Schema Draft 7 support (920/920 tests)
- Full JSON Schema Draft 2020-12 support (1142/1142 tests)
- Schema compilation for repeated validation
- Schema Registry for external `$ref` resolution
- Detailed error reporting with JSON Pointer paths
- All standard keywords for Draft 7 and Draft 2020-12

[Unreleased]: https://github.com/ktmage/jsonschema.zig/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/ktmage/jsonschema.zig/releases/tag/v0.1.0
