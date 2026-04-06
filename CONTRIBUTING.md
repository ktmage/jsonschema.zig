# Contributing to jsonschema.zig

Thank you for your interest in contributing! This document explains how to get started.

## Prerequisites

- **Zig 0.14.0+** — install via [ziglang.org/download](https://ziglang.org/download/) or your package manager
- **Git** — for version control
- **`gh` CLI** (optional) — for GitHub interactions

## Development Setup

```bash
git clone https://github.com/ktmage/jsonschema.zig.git
cd jsonschema.zig
zig build test    # Run the full test suite (auto-fetches JSON Schema Test Suite)
```

The test suite validates against the official [JSON Schema Test Suite](https://github.com/json-schema-org/JSON-Schema-Test-Suite) and must pass 100%:
- Draft 7: 920/920
- Draft 2020-12: 1142/1142

## Code Style

- Run `zig fmt` before committing — CI enforces this
- Follow Zig standard library conventions
- Keep functions focused and small
- Add doc comments for public API functions
- Avoid unnecessary allocations in hot paths

## Running Tests

```bash
zig build test                    # Full test suite
zig build test -- --test-filter "Draft 7"   # Filter specific tests
```

## Running Benchmarks

Benchmarks live in a separate repository: [jsonschema-bench](https://github.com/ktmage/jsonschema-bench)

## Making Changes

1. **Check existing issues** — look for related issues before starting work
2. **Create a branch** — `git checkout -b your-feature`
3. **Make your changes** — keep commits focused and well-described
4. **Run tests** — `zig build test` must pass with 0 failures
5. **Format code** — `zig fmt src/`
6. **Submit a PR** — describe what you changed and why

## Commit Messages

Use conventional commit prefixes:
- `fix:` — bug fixes
- `feat:` — new features
- `perf:` — performance improvements
- `docs:` — documentation changes
- `chore:` — maintenance tasks
- `test:` — test additions/changes

## Pull Request Guidelines

- Keep PRs focused — one logical change per PR
- Include test coverage for new features
- Don't break existing tests (920/920 + 1142/1142 must pass)
- Update CHANGELOG.md for user-facing changes
- Performance changes should include before/after measurements

## Reporting Bugs

Use the [bug report template](https://github.com/ktmage/jsonschema.zig/issues/new?template=bug.yml) and include:
- Zig version and platform
- Schema and instance that trigger the bug
- Expected vs actual behavior

## Security Vulnerabilities

See [SECURITY.md](SECURITY.md) for reporting security issues.

## Code of Conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md). Be respectful and constructive.

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
