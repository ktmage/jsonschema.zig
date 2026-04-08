const std = @import("std");
const c = @cImport({
    @cInclude("libregexp.h");
});

/// Minimal EcmaRegex wrapper — mirrors src/ecma_regex.zig for benchmark use.
const EcmaRegex = struct {
    bytecode: [*]u8,

    fn compile(pattern: []const u8, allocator: std.mem.Allocator) ?EcmaRegex {
        const pat_z = allocator.dupeZ(u8, pattern) catch return null;
        defer allocator.free(pat_z);

        var error_msg: [64]u8 = undefined;
        var plen: c_int = undefined;

        const bc = c.lre_compile(
            &plen,
            @ptrCast(&error_msg),
            error_msg.len,
            pat_z.ptr,
            @intCast(pattern.len),
            0,
            null,
        );

        if (bc == null) return null;
        return .{ .bytecode = bc.? };
    }

    fn matches(self: *const EcmaRegex, str: []const u8) bool {
        const capture_count = c.lre_get_capture_count(self.bytecode);
        const capture_size: usize = @intCast(capture_count * 2);

        var capture_buf: [64][*c]u8 = undefined;
        const capture: [*c][*c]u8 = if (capture_size <= 64) &capture_buf else return false;

        if (!hasNonAscii(str)) {
            const result = c.lre_exec(
                capture,
                self.bytecode,
                @ptrCast(str.ptr),
                0,
                @intCast(str.len),
                0,
                null,
            );
            return result == 1;
        }

        var utf16_buf: [2048]u16 = undefined;
        const utf16_len = utf8ToUtf16(&utf16_buf, str) orelse return false;

        const result = c.lre_exec(
            capture,
            self.bytecode,
            @ptrCast(&utf16_buf),
            0,
            @intCast(utf16_len),
            1,
            null,
        );
        return result == 1;
    }

    fn deinit(self: *EcmaRegex) void {
        std.c.free(self.bytecode);
    }

    fn hasNonAscii(s: []const u8) bool {
        for (s) |b_| {
            if (b_ >= 0x80) return true;
        }
        return false;
    }

    fn utf8ToUtf16(buf: []u16, utf8: []const u8) ?usize {
        var i: usize = 0;
        var out: usize = 0;
        while (i < utf8.len) {
            if (out >= buf.len) return null;
            const b_ = utf8[i];
            if (b_ < 0x80) {
                buf[out] = @intCast(b_);
                out += 1;
                i += 1;
            } else if (b_ < 0xC0) {
                return null;
            } else if (b_ < 0xE0) {
                if (i + 1 >= utf8.len) return null;
                const cp_: u32 = (@as(u32, b_ & 0x1F) << 6) | @as(u32, utf8[i + 1] & 0x3F);
                buf[out] = @intCast(cp_);
                out += 1;
                i += 2;
            } else if (b_ < 0xF0) {
                if (i + 2 >= utf8.len) return null;
                const cp_: u32 = (@as(u32, b_ & 0x0F) << 12) | (@as(u32, utf8[i + 1] & 0x3F) << 6) | @as(u32, utf8[i + 2] & 0x3F);
                buf[out] = @intCast(cp_);
                out += 1;
                i += 3;
            } else {
                if (i + 3 >= utf8.len) return null;
                if (out + 1 >= buf.len) return null;
                const cp_: u32 = (@as(u32, b_ & 0x07) << 18) | (@as(u32, utf8[i + 1] & 0x3F) << 12) | (@as(u32, utf8[i + 2] & 0x3F) << 6) | @as(u32, utf8[i + 3] & 0x3F);
                const adjusted = cp_ - 0x10000;
                buf[out] = @intCast(0xD800 + (adjusted >> 10));
                buf[out + 1] = @intCast(0xDC00 + (adjusted & 0x3FF));
                out += 2;
                i += 4;
            }
        }
        return out;
    }
};

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

const WARMUP_ITERS: usize = 100;
const BENCH_ITERS: usize = 10_000;

// ---------------------------------------------------------------------------
// Pattern definitions
// ---------------------------------------------------------------------------

const Category = enum {
    // Synthetic categories
    simple_literal,
    char_class,
    quantifier,
    alternation,
    anchor,
    group,
    backref,
    lookahead,
    lookbehind,
    unicode,

    // Real-world schema categories
    cspell,
    github_workflow,
    openapi,
    package_json,
    tsconfig,
};

const PatternDef = struct {
    name: []const u8,
    pattern: []const u8,
    match_input: []const u8,
    nomatch_input: []const u8,
    category: Category,
};

const patterns = [_]PatternDef{
    // =================================================================
    // Synthetic: Simple literals
    // =================================================================
    .{
        .name = "literal:abc",
        .pattern = "abc",
        .match_input = "xxxabcxxx",
        .nomatch_input = "xxxdefxxx",
        .category = .simple_literal,
    },
    .{
        .name = "literal:hello world",
        .pattern = "hello world",
        .match_input = "say hello world now",
        .nomatch_input = "say goodbye world now",
        .category = .simple_literal,
    },

    // =================================================================
    // Synthetic: Character classes
    // =================================================================
    .{
        .name = "charclass:[a-z0-9]",
        .pattern = "[a-z0-9]",
        .match_input = "x",
        .nomatch_input = "!",
        .category = .char_class,
    },
    .{
        .name = "charclass:[^a-zA-Z]",
        .pattern = "[^a-zA-Z]",
        .match_input = "7",
        .nomatch_input = "m",
        .category = .char_class,
    },
    .{
        .name = "charclass:\\d+",
        .pattern = "\\d+",
        .match_input = "abc123def",
        .nomatch_input = "abcdef",
        .category = .char_class,
    },
    .{
        .name = "charclass:\\w+",
        .pattern = "\\w+",
        .match_input = "hello_world",
        .nomatch_input = "   ",
        .category = .char_class,
    },

    // =================================================================
    // Synthetic: Quantifiers
    // =================================================================
    .{
        .name = "quant:a{3,5}",
        .pattern = "a{3,5}",
        .match_input = "baaab",
        .nomatch_input = "baab",
        .category = .quantifier,
    },
    .{
        .name = "quant:[a-z]{8,}",
        .pattern = "[a-z]{8,}",
        .match_input = "abcdefghij",
        .nomatch_input = "abcdefg",
        .category = .quantifier,
    },
    .{
        .name = "quant:.*foo.*",
        .pattern = ".*foo.*",
        .match_input = "xxxfooxxx",
        .nomatch_input = "xxxbarxxx",
        .category = .quantifier,
    },

    // =================================================================
    // Synthetic: Alternation
    // =================================================================
    .{
        .name = "alt:(foo|bar|baz)",
        .pattern = "(foo|bar|baz)",
        .match_input = "xxbarxx",
        .nomatch_input = "xxquxxx",
        .category = .alternation,
    },
    .{
        .name = "alt:(cat|dog|bird|fish)",
        .pattern = "(cat|dog|bird|fish)",
        .match_input = "I have a bird",
        .nomatch_input = "I have a rock",
        .category = .alternation,
    },

    // =================================================================
    // Synthetic: Anchors
    // =================================================================
    .{
        .name = "anchor:^[a-z]+$",
        .pattern = "^[a-z]+$",
        .match_input = "hello",
        .nomatch_input = "Hello",
        .category = .anchor,
    },
    .{
        .name = "anchor:^\\d{3}-\\d{4}$",
        .pattern = "^\\d{3}-\\d{4}$",
        .match_input = "123-4567",
        .nomatch_input = "12-4567",
        .category = .anchor,
    },

    // =================================================================
    // Synthetic: Groups
    // =================================================================
    .{
        .name = "group:(\\w+)@(\\w+)",
        .pattern = "(\\w+)@(\\w+)",
        .match_input = "user@host",
        .nomatch_input = "user host",
        .category = .group,
    },

    // =================================================================
    // Synthetic: Lookahead
    // =================================================================
    .{
        .name = "lookahead:(?=.*\\d)",
        .pattern = "(?=.*\\d)",
        .match_input = "abc123",
        .nomatch_input = "abcdef",
        .category = .lookahead,
    },
    .{
        .name = "lookahead:(?=.*[A-Z])(?=.*\\d)",
        .pattern = "(?=.*[A-Z])(?=.*\\d)",
        .match_input = "passWord1",
        .nomatch_input = "password",
        .category = .lookahead,
    },
    .{
        .name = "lookahead:foo(?!bar)",
        .pattern = "foo(?!bar)",
        .match_input = "foobaz",
        .nomatch_input = "foobar",
        .category = .lookahead,
    },

    // =================================================================
    // Synthetic: Lookbehind
    // =================================================================
    .{
        .name = "lookbehind:(?<=@)\\w+",
        .pattern = "(?<=@)\\w+",
        .match_input = "user@domain",
        .nomatch_input = "userdomain",
        .category = .lookbehind,
    },
    .{
        .name = "lookbehind:(?<!\\d)\\d{3}(?!\\d)",
        .pattern = "(?<!\\d)\\d{3}(?!\\d)",
        .match_input = "abc123def",
        .nomatch_input = "abc1234def",
        .category = .lookbehind,
    },

    // =================================================================
    // Synthetic: Unicode (note: QuickJS libregexp may not support \p{})
    // =================================================================
    .{
        .name = "unicode:[\\u00C0-\\u024F]",
        .pattern = "[\\u00C0-\\u024F]",
        .match_input = "\xC3\xA9",
        .nomatch_input = "a",
        .category = .unicode,
    },

    // =================================================================
    // Real-world: cspell patterns
    // =================================================================
    .{
        .name = "cspell:glob",
        .pattern = "^(!?[-\\w_\\s]+)|(\\*)$",
        .match_input = "!some-word",
        .nomatch_input = "{invalid}",
        .category = .cspell,
    },
    .{
        .name = "cspell:multi-glob",
        .pattern = "^(![-\\w_\\s]+)(,![-\\w_\\s]+)*$",
        .match_input = "!foo,!bar,!baz",
        .nomatch_input = "foo,bar",
        .category = .cspell,
    },
    .{
        .name = "cspell:word-assert",
        .pattern = "^(?=!+[^!*,;{}[\\]~\\n]+$)(?=(.*\\w)).+$",
        .match_input = "!something",
        .nomatch_input = "!***",
        .category = .cspell,
    },
    .{
        .name = "cspell:word-nonneg",
        .pattern = "^(?=[^!*,;{}[\\]~\\n]+$)(?=(.*\\w)).+$",
        .match_input = "some_word",
        .nomatch_input = "some*word",
        .category = .cspell,
    },
    .{
        .name = "cspell:csv-words",
        .pattern = "^([-\\w_\\s]+)(,[-\\w_\\s]+)*$",
        .match_input = "foo,bar,baz",
        .nomatch_input = "foo;bar",
        .category = .cspell,
    },
    .{
        .name = "cspell:dict-file",
        .pattern = "^.*\\.(?:txt|trie)(?:\\.gz)?$",
        .match_input = "words.txt.gz",
        .nomatch_input = "words.json",
        .category = .cspell,
    },

    // =================================================================
    // Real-world: github-workflow patterns
    // =================================================================
    .{
        .name = "ghwf:yaml-ref",
        .pattern = "^(.+\\/)+(.+)\\.(ya?ml)(@.+)?$",
        .match_input = "org/repo/.github/workflows/ci.yml@main",
        .nomatch_input = "ci.txt",
        .category = .github_workflow,
    },
    .{
        .name = "ghwf:in-exclude",
        .pattern = "^(in|ex)clude$",
        .match_input = "include",
        .nomatch_input = "other",
        .category = .github_workflow,
    },
    .{
        .name = "ghwf:expression",
        .pattern = "^\\$\\{\\{(.|[\r\n])*\\}\\}$",
        .match_input = "${{ github.event_name }}",
        .nomatch_input = "github.event_name",
        .category = .github_workflow,
    },
    .{
        .name = "ghwf:identifier",
        .pattern = "^[_a-zA-Z][a-zA-Z0-9_-]*$",
        .match_input = "my_job-1",
        .nomatch_input = "1-invalid",
        .category = .github_workflow,
    },
    .{
        .name = "ghwf:version",
        .pattern = "^\\d+(\\.\\d+|\\*)?$",
        .match_input = "3.10",
        .nomatch_input = "v3.10",
        .category = .github_workflow,
    },
    .{
        .name = "ghwf:branches",
        .pattern = "^branches(-ignore)?$",
        .match_input = "branches-ignore",
        .nomatch_input = "tags",
        .category = .github_workflow,
    },

    // =================================================================
    // Real-world: openapi patterns
    // =================================================================
    .{
        .name = "oapi:components",
        .pattern = "^(schemas|responses|parameters|examples|requestBodies|headers|securitySchemes|links|callbacks|pathItems)$",
        .match_input = "schemas",
        .nomatch_input = "custom",
        .category = .openapi,
    },
    .{
        .name = "oapi:path-start",
        .pattern = "^/",
        .match_input = "/api/v1/users",
        .nomatch_input = "api/v1/users",
        .category = .openapi,
    },
    .{
        .name = "oapi:version",
        .pattern = "^3\\.1\\.\\d+(-.+)?$",
        .match_input = "3.1.0",
        .nomatch_input = "2.0.0",
        .category = .openapi,
    },
    .{
        .name = "oapi:status-code",
        .pattern = "^[1-5](?:[0-9]{2}|XX)$",
        .match_input = "200",
        .nomatch_input = "999",
        .category = .openapi,
    },
    .{
        .name = "oapi:bearer",
        .pattern = "^[Bb][Ee][Aa][Rr][Ee][Rr]$",
        .match_input = "Bearer",
        .nomatch_input = "Basic",
        .category = .openapi,
    },
    .{
        .name = "oapi:name-chars",
        .pattern = "^[a-zA-Z0-9._-]+$",
        .match_input = "my-schema.v2",
        .nomatch_input = "my schema!",
        .category = .openapi,
    },
    .{
        .name = "oapi:extension",
        .pattern = "^x-",
        .match_input = "x-custom-header",
        .nomatch_input = "content-type",
        .category = .openapi,
    },

    // =================================================================
    // Real-world: package-json patterns
    // =================================================================
    .{
        .name = "pkg:pm-name",
        .pattern = "(node|npm|pnpm|yarn)",
        .match_input = "use npm please",
        .nomatch_input = "use cargo please",
        .category = .package_json,
    },
    .{
        .name = "pkg:pm-version",
        .pattern = "(npm|pnpm|yarn|bun)@\\d+\\.\\d+\\.\\d+(-.+)?",
        .match_input = "pnpm@8.15.4",
        .nomatch_input = "cargo@1.0.0",
        .category = .package_json,
    },
    .{
        .name = "pkg:comment",
        .pattern = "^#.+$",
        .match_input = "#this is a comment",
        .nomatch_input = "not a comment",
        .category = .package_json,
    },
    .{
        .name = "pkg:scoped-name",
        .pattern = "^(?:(?:@(?:[a-z0-9-*~][a-z0-9-*._~]*)?/[a-z0-9-._~])|[a-z0-9-~])[a-z0-9-._~]*$",
        .match_input = "@scope/package-name",
        .nomatch_input = "INVALID_PKG",
        .category = .package_json,
    },
    .{
        .name = "pkg:nonempty",
        .pattern = "^.+$",
        .match_input = "anything",
        .nomatch_input = "",
        .category = .package_json,
    },
    .{
        .name = "pkg:cve",
        .pattern = "^CVE-\\d{4}-\\d{4,7}$",
        .match_input = "CVE-2024-12345",
        .nomatch_input = "GHSA-1234-5678-abcd",
        .category = .package_json,
    },
    .{
        .name = "pkg:ghsa",
        .pattern = "^GHSA(-[23456789cfghjmpqrvwx]{4}){3}$",
        .match_input = "GHSA-2345-6789-cfgh",
        .nomatch_input = "CVE-2024-12345",
        .category = .package_json,
    },
    .{
        .name = "pkg:single-glob",
        .pattern = "^[^*]*(?:\\*[^*]*)?$",
        .match_input = "src/*.js",
        .nomatch_input = "src/**/*.js",
        .category = .package_json,
    },
    .{
        .name = "pkg:no-star",
        .pattern = "^[^*]+$",
        .match_input = "src/index.js",
        .nomatch_input = "src/*",
        .category = .package_json,
    },
    .{
        .name = "pkg:relative",
        .pattern = "^\\./",
        .match_input = "./lib/index.js",
        .nomatch_input = "lib/index.js",
        .category = .package_json,
    },
    .{
        .name = "pkg:underscore",
        .pattern = "^_",
        .match_input = "_internal",
        .nomatch_input = "public",
        .category = .package_json,
    },

    // =================================================================
    // Real-world: tsconfig patterns (representative subset)
    // =================================================================
    .{
        .name = "tsconfig:module",
        .pattern = "^([Cc][Oo][Mm][Mm][Oo][Nn][Jj][Ss]|[AaUu][Mm][Dd]|[Ss][Yy][Ss][Tt][Ee][Mm]|[Ee][Ss]([356]|20(1[567]|2[02])|[Nn][Ee][Xx][Tt])|[Nn][Oo][dD][Ee](1[68]|20)|[Nn][Oo][Dd][Ee][Nn][Ee][Xx][Tt]|[Nn][Oo][Nn][Ee]|[Pp][Rr][Ee][Ss][Ee][Rr][Vv][Ee])$",
        .match_input = "CommonJS",
        .nomatch_input = "invalid",
        .category = .tsconfig,
    },
    .{
        .name = "tsconfig:target",
        .pattern = "^([Ee][Ss]([356]|(20(1[56789]|2[012345]))|[Nn][Ee][Xx][Tt]))$",
        .match_input = "ES2020",
        .nomatch_input = "ES4",
        .category = .tsconfig,
    },
    .{
        .name = "tsconfig:newline",
        .pattern = "^(CRLF|LF|crlf|lf)$",
        .match_input = "LF",
        .nomatch_input = "CR",
        .category = .tsconfig,
    },
    .{
        .name = "tsconfig:decorators",
        .pattern = "^[Dd][Ee][Cc][Oo][Rr][Aa][Tt][Oo][Rr][Ss](\\.([Ll][Ee][Gg][Aa][Cc][Yy]))?$",
        .match_input = "Decorators.Legacy",
        .nomatch_input = "something",
        .category = .tsconfig,
    },
    .{
        .name = "tsconfig:dom",
        .pattern = "^[Dd][Oo][Mm](\\.([Aa][Ss][Yy][Nn][Cc])?[Ii][Tt][Ee][Rr][Aa][Bb][Ll][Ee])?$",
        .match_input = "DOM",
        .nomatch_input = "Window",
        .category = .tsconfig,
    },
    .{
        .name = "tsconfig:es2015-libs",
        .pattern = "^[Ee][Ss]2015(\\.([Cc][Oo][Ll][Ll][Ee][Cc][Tt][Ii][Oo][Nn]|[Cc][Oo][Rr][Ee]|[Gg][Ee][Nn][Ee][Rr][Aa][Tt][Oo][Rr]|[Ii][Tt][Ee][Rr][Aa][Bb][Ll][Ee]|[Pp][Rr][Oo][Mm][Ii][Ss][Ee]|[Pp][Rr][Oo][Xx][Yy]|[Rr][Ee][Ff][Ll][Ee][Cc][Tt]|[Ss][Yy][Mm][Bb][Oo][Ll]\\.[Ww][Ee][Ll][Ll][Kk][Nn][Oo][Ww][Nn]|[Ss][Yy][Mm][Bb][Oo][Ll]))?$",
        .match_input = "ES2015.Collection",
        .nomatch_input = "ES2016.Collection",
        .category = .tsconfig,
    },
    .{
        .name = "tsconfig:es2020-libs",
        .pattern = "^[Ee][Ss]2020(\\.([Bb][Ii][Gg][Ii][Nn][Tt]|[Pp][Rr][Oo][Mm][Ii][Ss][Ee]|[Ss][Tt][Rr][Ii][Nn][Gg]|[Ss][Yy][Mm][Bb][Oo][Ll]\\.[Ww][Ee][Ll][Ll][Kk][Nn][Oo][Ww][Nn]|[Ss][Hh][Aa][Rr][Ee][Dd][Mm][Ee][Mm][Oo][Rr][Yy]|[Ii][Nn][Tt][Ll]|[Dd][Aa][Tt][Ee]|[Nn][Uu][Mm][Bb][Ee][Rr]))?$",
        .match_input = "es2020.bigint",
        .nomatch_input = "es2019.bigint",
        .category = .tsconfig,
    },
    .{
        .name = "tsconfig:esnext-libs",
        .pattern = "^[Ee][Ss][Nn][Ee][Xx][Tt](\\.([Aa][Rr][Rr][Aa][Yy]|[Aa][Ss][Yy][Nn][Cc][Ii][Tt][Ee][Rr][Aa][Bb][Ll][Ee]|[Bb][Ii][Gg][Ii][Nn][Tt]|[Ii][Nn][Tt][Ll]|[Pp][Rr][Oo][Mm][Ii][Ss][Ee]|[Ss][Tt][Rr][Ii][Nn][Gg]|[Ss][Yy][Mm][Bb][Oo][Ll]|[Ww][Ee][Aa][Kk][Rr][Ee][Ff]|[Dd][Ee][Cc][Oo][Rr][Aa][Tt][Oo][Rr][Ss]|[Dd][Ii][Ss][Pp][Oo][Ss][Aa][Bb][Ll][Ee]))?$",
        .match_input = "ESNext.Array",
        .nomatch_input = "ES2020.Array",
        .category = .tsconfig,
    },
    .{
        .name = "tsconfig:webworker",
        .pattern = "^[Ww][Ee][Bb][Ww][Oo][Rr][Kk][Ee][Rr](\\.([Ii][Mm][Pp][Oo][Rr][Tt][Ss][Cc][Rr][Ii][Pp][Tt][Ss]|([Aa][Ss][Yy][Nn][Cc])?[Ii][Tt][Ee][Rr][Aa][Bb][Ll][Ee]))?$",
        .match_input = "WebWorker.ImportScripts",
        .nomatch_input = "Worker",
        .category = .tsconfig,
    },
    .{
        .name = "tsconfig:es5-7",
        .pattern = "^[Ee][Ss]5|[Ee][Ss]6|[Ee][Ss]7$",
        .match_input = "ES5",
        .nomatch_input = "ES8",
        .category = .tsconfig,
    },
};

// ---------------------------------------------------------------------------
// Statistics
// ---------------------------------------------------------------------------

fn compare_u64(_: void, a: u64, b: u64) bool {
    return a < b;
}

const Stats = struct {
    median_ns: u64,
    mean_ns: u64,
    stddev_ns: u64,
    p95_ns: u64,
    p99_ns: u64,
    min_ns: u64,
    max_ns: u64,
};

fn computeStats(samples: []u64) Stats {
    const n = samples.len;
    std.debug.assert(n > 0);

    std.mem.sort(u64, samples, {}, compare_u64);

    // Sum for mean
    var sum: u128 = 0;
    for (samples) |s| {
        sum += s;
    }
    const mean: u64 = @intCast(sum / n);

    // Variance for stddev
    var var_sum: u128 = 0;
    for (samples) |s| {
        const diff: i128 = @as(i128, @intCast(s)) - @as(i128, @intCast(mean));
        var_sum += @intCast(@as(u128, @bitCast(diff * diff)));
    }
    const variance: u64 = @intCast(var_sum / n);
    const stddev: u64 = std.math.sqrt(variance);

    return .{
        .median_ns = samples[n / 2],
        .mean_ns = mean,
        .stddev_ns = stddev,
        .p95_ns = samples[(n * 95) / 100],
        .p99_ns = samples[(n * 99) / 100],
        .min_ns = samples[0],
        .max_ns = samples[n - 1],
    };
}

// ---------------------------------------------------------------------------
// Benchmark runner
// ---------------------------------------------------------------------------

fn benchCompile(pattern: []const u8, allocator: std.mem.Allocator) ?Stats {
    var timer = std.time.Timer.start() catch return null;

    // Warmup
    for (0..WARMUP_ITERS) |_| {
        var re = EcmaRegex.compile(pattern, allocator) orelse return null;
        re.deinit();
    }

    // Measure
    var samples: [BENCH_ITERS]u64 = undefined;
    for (&samples) |*sample| {
        timer.reset();
        var re = EcmaRegex.compile(pattern, allocator) orelse return null;
        sample.* = timer.read();
        re.deinit();
    }

    return computeStats(&samples);
}

fn benchMatch(regex: *const EcmaRegex, input: []const u8) ?Stats {
    var timer = std.time.Timer.start() catch return null;

    // Warmup
    for (0..WARMUP_ITERS) |_| {
        _ = regex.matches(input);
    }

    // Measure
    var samples: [BENCH_ITERS]u64 = undefined;
    for (&samples) |*sample| {
        timer.reset();
        const result = regex.matches(input);
        sample.* = timer.read();
        // Prevent dead-code elimination
        std.mem.doNotOptimizeAway(result);
    }

    return computeStats(&samples);
}

// ---------------------------------------------------------------------------
// Output formatting
// ---------------------------------------------------------------------------

fn fmtNs(ns: u64) [12]u8 {
    var buf: [12]u8 = .{' '} ** 12;
    _ = std.fmt.bufPrint(&buf, "{d:>12}", .{ns}) catch {};
    return buf;
}

fn printHeader(writer: anytype) !void {
    try writer.print("\n{s:<40} | {s:>12} {s:>12} {s:>12} | {s:>12} {s:>12} {s:>12} | {s:>12} {s:>12} {s:>12}\n", .{
        "Pattern",
        "Compile med",  "Compile avg",  "Compile p99",
        "Match med",    "Match avg",    "Match p99",
        "NoMatch med",  "NoMatch avg",  "NoMatch p99",
    });
    try writer.print("{s:-<40}-+-{s:->12}-{s:->12}-{s:->12}-+-{s:->12}-{s:->12}-{s:->12}-+-{s:->12}-{s:->12}-{s:->12}\n", .{
        "", "", "", "", "", "", "", "", "", "",
    });
}

fn printRow(writer: anytype, name: []const u8, compile_stats: ?Stats, match_stats: ?Stats, nomatch_stats: ?Stats) !void {
    // Name (truncated to 40 chars)
    var name_buf: [40]u8 = .{' '} ** 40;
    const len = @min(name.len, 40);
    @memcpy(name_buf[0..len], name[0..len]);

    try writer.print("{s:<40} | ", .{name_buf});

    if (compile_stats) |cs| {
        try writer.print("{d:>12} {d:>12} {d:>12} | ", .{ cs.median_ns, cs.mean_ns, cs.p99_ns });
    } else {
        try writer.print("{s:>12} {s:>12} {s:>12} | ", .{ "FAIL", "FAIL", "FAIL" });
    }

    if (match_stats) |ms| {
        try writer.print("{d:>12} {d:>12} {d:>12} | ", .{ ms.median_ns, ms.mean_ns, ms.p99_ns });
    } else {
        try writer.print("{s:>12} {s:>12} {s:>12} | ", .{ "FAIL", "FAIL", "FAIL" });
    }

    if (nomatch_stats) |ns| {
        try writer.print("{d:>12} {d:>12} {d:>12}", .{ ns.median_ns, ns.mean_ns, ns.p99_ns });
    } else {
        try writer.print("{s:>12} {s:>12} {s:>12}", .{ "FAIL", "FAIL", "FAIL" });
    }

    try writer.print("\n", .{});
}

fn printDetailedStats(writer: anytype, label: []const u8, stats: Stats) !void {
    try writer.print("  {s:<14}  median={d:>8}ns  mean={d:>8}ns  stddev={d:>8}ns  p95={d:>8}ns  p99={d:>8}ns  min={d:>8}ns  max={d:>8}ns\n", .{
        label,
        stats.median_ns,
        stats.mean_ns,
        stats.stddev_ns,
        stats.p95_ns,
        stats.p99_ns,
        stats.min_ns,
        stats.max_ns,
    });
}

fn categoryName(cat: Category) []const u8 {
    return switch (cat) {
        .simple_literal => "Simple Literal",
        .char_class => "Character Class",
        .quantifier => "Quantifier",
        .alternation => "Alternation",
        .anchor => "Anchor",
        .group => "Group",
        .backref => "Backref",
        .lookahead => "Lookahead",
        .lookbehind => "Lookbehind",
        .unicode => "Unicode",
        .cspell => "cspell (real)",
        .github_workflow => "GitHub Workflow (real)",
        .openapi => "OpenAPI (real)",
        .package_json => "package.json (real)",
        .tsconfig => "tsconfig (real)",
    };
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    const stdout = std.io.getStdOut().writer();

    try stdout.print("╔══════════════════════════════════════════════════════════════╗\n", .{});
    try stdout.print("║  QuickJS libregexp Benchmark — JSON Schema Pattern Baseline ║\n", .{});
    try stdout.print("╚══════════════════════════════════════════════════════════════╝\n", .{});
    try stdout.print("\nConfiguration: warmup={d}, iterations={d}\n", .{ WARMUP_ITERS, BENCH_ITERS });
    try stdout.print("All times in nanoseconds (ns).\n", .{});

    // ── Summary table ────────────────────────────────────────────────
    try printHeader(stdout);

    var total_compile: u128 = 0;
    var total_match: u128 = 0;
    var total_nomatch: u128 = 0;
    var count: usize = 0;

    var current_category: ?Category = null;

    for (&patterns) |*pd| {
        // Category separator
        if (current_category == null or current_category.? != pd.category) {
            current_category = pd.category;
            try stdout.print("{s:-<40}-+-{s:->12}-{s:->12}-{s:->12}-+-{s:->12}-{s:->12}-{s:->12}-+-{s:->12}-{s:->12}-{s:->12}\n", .{
                "", "", "", "", "", "", "", "", "", "",
            });
            // Print category label as a section header
            try stdout.print("  [{s}]\n", .{categoryName(pd.category)});
        }

        // Compile benchmark
        const compile_stats = benchCompile(pd.pattern, allocator);

        // Compile once for match benchmarks
        var regex = EcmaRegex.compile(pd.pattern, allocator);

        const match_stats = if (regex != null) benchMatch(&regex.?, pd.match_input) else null;
        const nomatch_stats = if (regex != null) benchMatch(&regex.?, pd.nomatch_input) else null;

        // Verify correctness before reporting
        if (regex) |*re| {
            const should_match = re.matches(pd.match_input);
            const should_not_match = re.matches(pd.nomatch_input);
            if (!should_match) {
                try stdout.print("  WARNING: '{s}' did not match expected input '{s}'\n", .{ pd.pattern, pd.match_input });
            }
            // nomatch_input with empty string is a valid edge case (empty always doesn't match ^.+$)
            if (should_not_match and pd.nomatch_input.len > 0) {
                try stdout.print("  WARNING: '{s}' unexpectedly matched '{s}'\n", .{ pd.pattern, pd.nomatch_input });
            }
            re.deinit();
        }

        try printRow(stdout, pd.name, compile_stats, match_stats, nomatch_stats);

        if (compile_stats) |cs| {
            total_compile += cs.median_ns;
            count += 1;
        }
        if (match_stats) |ms| total_match += ms.median_ns;
        if (nomatch_stats) |ns| total_nomatch += ns.median_ns;
    }

    // ── Summary ──────────────────────────────────────────────────────
    try stdout.print("\n{s:=<120}\n", .{""});
    try stdout.print("SUMMARY ({d} patterns benchmarked)\n", .{count});
    try stdout.print("{s:-<120}\n", .{""});

    if (count > 0) {
        try stdout.print("  Total compile (median sum):   {d:>12} ns\n", .{@as(u64, @intCast(total_compile))});
        try stdout.print("  Total match   (median sum):   {d:>12} ns\n", .{@as(u64, @intCast(total_match))});
        try stdout.print("  Total nomatch (median sum):   {d:>12} ns\n", .{@as(u64, @intCast(total_nomatch))});
        try stdout.print("  Avg compile per pattern:      {d:>12} ns\n", .{@as(u64, @intCast(total_compile / count))});
        try stdout.print("  Avg match per pattern:        {d:>12} ns\n", .{@as(u64, @intCast(total_match / count))});
        try stdout.print("  Avg nomatch per pattern:      {d:>12} ns\n", .{@as(u64, @intCast(total_nomatch / count))});
    }

    // ── Detailed stats ───────────────────────────────────────────────
    try stdout.print("\n{s:=<120}\n", .{""});
    try stdout.print("DETAILED STATISTICS (per pattern)\n", .{});
    try stdout.print("{s:=<120}\n", .{""});

    for (&patterns) |*pd| {
        try stdout.print("\n{s} — pattern: {s}\n", .{ pd.name, pd.pattern });

        const compile_stats = benchCompile(pd.pattern, allocator);
        if (compile_stats) |cs| {
            try printDetailedStats(stdout, "compile", cs);
        } else {
            try stdout.print("  compile:        FAILED (pattern did not compile)\n", .{});
        }

        var regex = EcmaRegex.compile(pd.pattern, allocator);
        if (regex) |*re| {
            if (benchMatch(re, pd.match_input)) |ms| {
                try printDetailedStats(stdout, "match", ms);
            }
            if (benchMatch(re, pd.nomatch_input)) |ns| {
                try printDetailedStats(stdout, "nomatch", ns);
            }
            re.deinit();
        }
    }

    try stdout.print("\n", .{});
}
