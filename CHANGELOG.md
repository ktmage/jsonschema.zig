# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Custom FastRegex bytecode engine replacing POSIX `regexec` for most patterns
- QuickJS libregexp integration for ECMA-262 regex support (lookahead, Unicode)
- Bloom filter for O(n) `uniqueItems` validation (replacing O(n²) pairwise comparison)
- `isValidCompiled` API for zero-allocation boolean-only validation
- `CompiledSchema` function pointer dispatch (replacing tagged union switch)
- `object_fast` combined validator for single-pass object validation with bitmask required tracking
- Discriminator map optimization for `oneOf` with type/enum-based branch filtering
- Literal set expansion for regex patterns (O(1) string set lookup)
- Case-insensitive literal detection for regex patterns
- Nested array fast path for coordinate-style validation
- `bool_only` propagation for zero-allocation sub-schema validation
- External `$ref` schemas compiled into CompiledSchema for full fast-path coverage
- Custom keyword extension API (`CustomKeyword`)
- Optional format validation (opt-in via `validate_formats` flag)
- `memoryUsage()` API on CompiledSchema
- Benchmark results in README (vs Rust, Go, JS, Python implementations)
- GitHub Actions CI (Ubuntu + macOS, zig fmt check)
- CHANGELOG, CONTRIBUTING, SECURITY, CODE_OF_CONDUCT documentation

### Fixed
- External `$ref` schemas not compiled — caused 26% of validations to fall back to slow path for openapi
- Circular/late-bound local `$ref` not re-linked after compilation — caused slow path fallback for tsconfig, github-workflow, cspell
- Character class dash positioning for POSIX ERE compatibility (`[a-z0-9-~]` → `[a-z0-9~-]`)
- `regex_t` opaque type on Linux/glibc — heap-allocate via C malloc instead of struct embedding
- `object_fast` required_mask overflow for schemas with >64 properties
- Memory leak in `makeSingleError` and `addError` on partial allocation failure
- `CustomKeyword` dependency loop in ReleaseFast builds
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

### Removed
- FastRegex custom bytecode engine and all pattern-specific fast paths (prefix, identifier, bitmap, literal set) — replaced by single-tier EcmaRegex (QuickJS libregexp)
- POSIX regex dependency (`regex.h`, `regcomp`, `regexec`, `regfree`) — fully replaced by EcmaRegex
- `convertEcmaToPostfix` ECMA→POSIX conversion (no longer needed)

### Changed
- Single-tier regex architecture: EcmaRegex (QuickJS libregexp, ECMA-262 compliant)
- `CompiledValidator` reduced from 240 bytes to 40 bytes
- String hash now samples first+last 16 bytes for better bloom filter distribution
- `isValid_type_multi` uses pre-computed bitmask instead of linear SimpleType iteration
- `isValidationKeyword` uses `StaticStringMap` for O(1) lookup
- Fast-path functions now accept Allocator parameter (enables future optimizations)
- All validators re-linked after compilation (multi-pass convergence)

### Performance
- openapi warm: 1,330ms → 211ms (-84%) — external $ref compilation + full fast-path coverage
- tsconfig warm: 38ms → 27ms (-29%) — local $ref re-linking
- github-workflow warm: 62ms → 50ms (-19%) — local $ref re-linking
- cspell warm: 72ms → 23ms (-68%) — ECMA-262 regex (lookahead) via QuickJS libregexp
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
