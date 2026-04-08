const std = @import("std");
const parser = @import("parser.zig");

const Node = parser.Node;
const CharClass = parser.CharClass;
const PredefinedClass = parser.PredefinedClass;
const UnicodeProp = parser.UnicodeProp;
const Group = parser.Group;
const Quantified = parser.Quantified;
const Alternation = parser.Alternation;
const Sequence = parser.Sequence;
const Parser = parser.Parser;

// ===================================================================
// Public types
// ===================================================================

/// A captured sub-match for a single capture group.
pub const Capture = struct {
    start: usize,
    end: usize,
};

/// Result of a successful regex match.
pub const Match = struct {
    /// Byte offset in the input where the match starts.
    start: usize,
    /// Byte offset in the input where the match ends (exclusive).
    end: usize,
    /// Capture groups indexed by group number (1-based stored at index 0, etc.).
    /// A null entry means the group did not participate in the match.
    captures: []?Capture,

    pub fn slice(self: *const Match, input: []const u8) []const u8 {
        return input[self.start..self.end];
    }

    pub fn captureSlice(self: *const Match, group: usize, input: []const u8) ?[]const u8 {
        if (group == 0) return input[self.start..self.end];
        if (group - 1 >= self.captures.len) return null;
        const cap = self.captures[group - 1] orelse return null;
        return input[cap.start..cap.end];
    }
};

// ===================================================================
// Regex — public API
// ===================================================================

/// Compiled regular expression that can be executed against input strings.
pub const Regex = struct {
    root: *Node,
    group_count: u32,
    group_indices: GroupIndexMap,
    _parser: Parser,

    /// Compile a regex pattern string into an executable Regex.
    pub fn compile(allocator: std.mem.Allocator, pattern: []const u8) !Regex {
        var p = Parser.init(allocator);
        const root = p.parse(pattern) catch |e| {
            p.deinit();
            return e;
        };
        return .{
            .root = root,
            .group_count = p.group_count,
            .group_indices = GroupIndexMap.build(root),
            ._parser = p,
        };
    }

    /// Execute the regex against input and return the first match, or null.
    pub fn exec(self: *const Regex, input: []const u8) ?Match {
        return self.execFrom(input, 0);
    }

    /// Execute the regex against input starting from byte offset `from`.
    pub fn execFrom(self: *const Regex, input: []const u8, from: usize) ?Match {
        var ctx = Context.init(input, self.group_count, &self.group_indices);
        // Try match at every codepoint-aligned position (leftmost-first).
        var pos = from;
        while (pos <= input.len) {
            ctx.reset();
            if (ctx.matchNode(self.root, pos)) |end_pos| {
                return .{
                    .start = pos,
                    .end = end_pos,
                    .captures = &ctx.captures,
                };
            }
            if (pos == input.len) break;
            // Advance by one UTF-8 codepoint.
            pos += utf8ByteLen(input[pos]);
        }
        return null;
    }

    /// Test whether the regex matches anywhere in the input.
    pub fn matches(self: *const Regex, input: []const u8) bool {
        return self.exec(input) != null;
    }

    /// Release resources.
    pub fn deinit(self: *Regex) void {
        self._parser.deinit();
    }
};

// ===================================================================
// Group index map — maps Group pointer to 0-based capture index
// ===================================================================

const GroupIndexMap = struct {
    entries: [MAX_CAPTURES]Entry = undefined,
    len: usize = 0,

    const Entry = struct {
        group_ptr: usize,
        index: usize,
    };

    fn lookup(self: *const GroupIndexMap, g: *const Group) ?usize {
        const addr = @intFromPtr(g);
        for (self.entries[0..self.len]) |entry| {
            if (entry.group_ptr == addr) return entry.index;
        }
        return null;
    }

    fn build(root: *const Node) GroupIndexMap {
        var map = GroupIndexMap{};
        buildWalk(root, &map);
        return map;
    }

    fn buildWalk(node: *const Node, map: *GroupIndexMap) void {
        switch (node.*) {
            .literal, .dot, .anchor_start, .anchor_end, .word_boundary, .non_word_boundary, .back_ref, .named_back_ref => {},
            .char_class => {},
            .sequence => |seq| {
                for (seq.items) |item| buildWalk(item, map);
            },
            .alternation => |alt| {
                for (alt.alternatives) |branch| buildWalk(branch, map);
            },
            .quantifier => |q| buildWalk(q.body, map),
            .group => |g| {
                if (g.kind == .capture and map.len < MAX_CAPTURES) {
                    map.entries[map.len] = .{
                        .group_ptr = @intFromPtr(g),
                        .index = map.len,
                    };
                    map.len += 1;
                }
                buildWalk(g.body, map);
            },
        }
    }
};

// ===================================================================
// Internal matching context
// ===================================================================

const MAX_CAPTURES = 64;
const MAX_RECURSION: usize = 1000;
const MAX_STEPS: usize = 1_000_000;

const Context = struct {
    input: []const u8,
    captures: [MAX_CAPTURES]?Capture,
    group_count: u32,
    steps: usize,
    recursion: usize,
    group_indices: *const GroupIndexMap,

    fn init(input: []const u8, group_count: u32, group_indices: *const GroupIndexMap) Context {
        return .{
            .input = input,
            .captures = [_]?Capture{null} ** MAX_CAPTURES,
            .group_count = group_count,
            .steps = 0,
            .recursion = 0,
            .group_indices = group_indices,
        };
    }

    fn reset(self: *Context) void {
        self.steps = 0;
        self.recursion = 0;
        self.captures = [_]?Capture{null} ** MAX_CAPTURES;
    }

    // ---------------------------------------------------------------
    // Core recursive matcher — returns end position on success, null on failure
    // ---------------------------------------------------------------

    fn matchNode(self: *Context, node: *const Node, pos: usize) ?usize {
        self.steps += 1;
        if (self.steps > MAX_STEPS or self.recursion > MAX_RECURSION) return null;

        return switch (node.*) {
            .literal => |cp| self.matchLiteral(cp, pos),
            .dot => self.matchDot(pos),
            .char_class => |cc| self.matchCharClass(cc, pos),
            .sequence => |seq| self.matchSequence(seq.items, pos),
            .alternation => |alt| self.matchAlternation(alt, pos),
            .quantifier => |q| self.matchQuantifier(q, pos),
            .group => |g| self.matchGroup(g, pos),
            .back_ref => |ref_num| self.matchBackRef(ref_num, pos),
            .named_back_ref => pos, // unresolved named back ref matches empty
            .anchor_start => if (pos == 0) pos else null,
            .anchor_end => if (pos == self.input.len) pos else null,
            .word_boundary => self.matchWordBoundary(pos, false),
            .non_word_boundary => self.matchWordBoundary(pos, true),
        };
    }

    // ---------------------------------------------------------------
    // Literal
    // ---------------------------------------------------------------

    fn matchLiteral(self: *const Context, expected: u21, pos: usize) ?usize {
        const decoded = decodeUtf8(self.input, pos) orelse return null;
        return if (decoded.cp == expected) decoded.next else null;
    }

    // ---------------------------------------------------------------
    // Dot — matches any codepoint except line terminators (ECMA-262)
    // ---------------------------------------------------------------

    fn matchDot(self: *const Context, pos: usize) ?usize {
        const decoded = decodeUtf8(self.input, pos) orelse return null;
        return switch (decoded.cp) {
            '\n', '\r', 0x2028, 0x2029 => null,
            else => decoded.next,
        };
    }

    // ---------------------------------------------------------------
    // Character class
    // ---------------------------------------------------------------

    fn matchCharClass(self: *const Context, cc: *const CharClass, pos: usize) ?usize {
        const decoded = decodeUtf8(self.input, pos) orelse return null;
        const in_class = charInClass(cc, decoded.cp);
        const matched = if (cc.negated) !in_class else in_class;
        return if (matched) decoded.next else null;
    }

    // ---------------------------------------------------------------
    // Sequence (concatenation) — with backtracking into quantifiers
    // ---------------------------------------------------------------

    fn matchSequence(self: *Context, items: []*Node, pos: usize) ?usize {
        return self.matchSequenceFrom(items, 0, pos);
    }

    fn matchSequenceFrom(self: *Context, items: []*Node, idx: usize, pos: usize) ?usize {
        if (idx >= items.len) return pos;

        const item = items[idx];
        const rest = items;
        const rest_idx = idx + 1;

        // For quantifiers, use continuation-aware matching.
        if (item.* == .quantifier) {
            return self.matchQuantifierWithCont(item.quantifier, pos, rest, rest_idx);
        }

        // For non-quantifier nodes, match normally and continue.
        const saved_caps = self.captures;
        if (self.matchNode(item, pos)) |next| {
            if (self.matchSequenceFrom(rest, rest_idx, next)) |end| return end;
        }
        self.captures = saved_caps;
        return null;
    }

    // ---------------------------------------------------------------
    // Alternation
    // ---------------------------------------------------------------

    fn matchAlternation(self: *Context, alt: *const Alternation, pos: usize) ?usize {
        for (alt.alternatives) |branch| {
            const saved_caps = self.captures;
            if (self.matchNode(branch, pos)) |end| return end;
            self.captures = saved_caps;
        }
        return null;
    }

    // ---------------------------------------------------------------
    // Quantifier (greedy / lazy) — standalone (no continuation)
    // ---------------------------------------------------------------

    fn matchQuantifier(self: *Context, q: *const Quantified, pos: usize) ?usize {
        return self.matchQuantifierWithCont(q, pos, &.{}, 0);
    }

    /// Quantifier matching with continuation (remaining sequence items).
    fn matchQuantifierWithCont(self: *Context, q: *const Quantified, pos: usize, cont: []*Node, cont_idx: usize) ?usize {
        self.recursion += 1;
        defer self.recursion -= 1;

        return if (q.greedy)
            self.quantifierGreedyRec(q, pos, 0, cont, cont_idx)
        else
            self.quantifierLazyRec(q, pos, 0, cont, cont_idx);
    }

    /// Greedy: try to match one more, recurse, on failure try continuation at current count.
    fn quantifierGreedyRec(self: *Context, q: *const Quantified, pos: usize, count: u32, cont: []*Node, cont_idx: usize) ?usize {
        if (self.steps > MAX_STEPS or self.recursion > MAX_RECURSION) return null;

        const max: u32 = q.max orelse std.math.maxInt(u32);

        // Try matching one more repetition first (greedy).
        if (count < max) {
            const saved = self.captures;
            if (self.matchNode(q.body, pos)) |next| {
                if (next != pos) { // non-empty match — recurse
                    if (self.quantifierGreedyRec(q, next, count + 1, cont, cont_idx)) |end| return end;
                }
                self.captures = saved;
            } else {
                self.captures = saved;
            }
        }

        // Cannot match more (or backtracked). Try continuation if min is satisfied.
        if (count >= q.min) {
            return self.matchSequenceFrom(cont, cont_idx, pos);
        }
        return null;
    }

    /// Lazy: try continuation first, on failure try one more repetition.
    fn quantifierLazyRec(self: *Context, q: *const Quantified, pos: usize, count: u32, cont: []*Node, cont_idx: usize) ?usize {
        if (self.steps > MAX_STEPS or self.recursion > MAX_RECURSION) return null;

        const max: u32 = q.max orelse std.math.maxInt(u32);

        // If minimum is met, try continuation first (lazy).
        if (count >= q.min) {
            const saved = self.captures;
            if (self.matchSequenceFrom(cont, cont_idx, pos)) |end| return end;
            self.captures = saved;
        }

        // Try one more repetition.
        if (count < max) {
            const saved = self.captures;
            if (self.matchNode(q.body, pos)) |next| {
                if (next != pos) { // non-empty match
                    if (self.quantifierLazyRec(q, next, count + 1, cont, cont_idx)) |end| return end;
                }
                self.captures = saved;
            } else {
                self.captures = saved;
            }
        }
        return null;
    }

    // ---------------------------------------------------------------
    // Group
    // ---------------------------------------------------------------

    fn matchGroup(self: *Context, g: *const Group, pos: usize) ?usize {
        self.recursion += 1;
        defer self.recursion -= 1;

        return switch (g.kind) {
            .capture => self.matchCaptureGroup(g, pos),
            .non_capture => self.matchNode(g.body, pos),
            .lookahead => self.matchLookahead(g, pos, false),
            .neg_lookahead => self.matchLookahead(g, pos, true),
            .lookbehind => self.matchLookbehind(g, pos, false),
            .neg_lookbehind => self.matchLookbehind(g, pos, true),
        };
    }

    fn matchCaptureGroup(self: *Context, g: *const Group, pos: usize) ?usize {
        const idx = self.group_indices.lookup(g) orelse return self.matchNode(g.body, pos);
        const saved_cap = self.captures[idx];
        if (self.matchNode(g.body, pos)) |end| {
            self.captures[idx] = Capture{ .start = pos, .end = end };
            return end;
        }
        self.captures[idx] = saved_cap;
        return null;
    }

    fn matchLookahead(self: *Context, g: *const Group, pos: usize, negative: bool) ?usize {
        const saved_caps = self.captures;
        const result = self.matchNode(g.body, pos);
        if (negative) {
            self.captures = saved_caps;
            return if (result == null) pos else null;
        } else {
            if (result != null) return pos;
            self.captures = saved_caps;
            return null;
        }
    }

    fn matchLookbehind(self: *Context, g: *const Group, pos: usize, negative: bool) ?usize {
        const saved_caps = self.captures;
        var start = pos;
        while (true) {
            self.captures = saved_caps;
            if (self.matchNode(g.body, start)) |end| {
                if (end == pos) {
                    if (negative) {
                        self.captures = saved_caps;
                        return null;
                    }
                    return pos;
                }
            }
            if (start == 0) break;
            start = prevCodepointPos(self.input, start);
        }
        self.captures = saved_caps;
        return if (negative) pos else null;
    }

    // ---------------------------------------------------------------
    // Back reference
    // ---------------------------------------------------------------

    fn matchBackRef(self: *Context, ref_num: u32, pos: usize) ?usize {
        if (ref_num == 0 or ref_num > MAX_CAPTURES) return null;
        const cap = self.captures[ref_num - 1] orelse return pos; // ECMA-262: non-participating group matches empty
        const text = self.input[cap.start..cap.end];
        if (pos + text.len > self.input.len) return null;
        return if (std.mem.eql(u8, self.input[pos .. pos + text.len], text)) pos + text.len else null;
    }

    // ---------------------------------------------------------------
    // Word boundary
    // ---------------------------------------------------------------

    fn matchWordBoundary(self: *const Context, pos: usize, negated: bool) ?usize {
        const before = if (pos > 0) isWordChar(prevCodepoint(self.input, pos)) else false;
        const after = if (pos < self.input.len) isWordCharAt(self.input, pos) else false;
        const is_boundary = before != after;
        return if (negated == is_boundary) null else pos;
    }
};

// ===================================================================
// UTF-8 helpers
// ===================================================================

const Decoded = struct {
    cp: u21,
    next: usize,
};

fn decodeUtf8(input: []const u8, pos: usize) ?Decoded {
    if (pos >= input.len) return null;
    const b0 = input[pos];

    if (b0 < 0x80) return .{ .cp = @intCast(b0), .next = pos + 1 };

    const len: usize = if (b0 < 0xC0)
        return null
    else if (b0 < 0xE0)
        2
    else if (b0 < 0xF0)
        3
    else if (b0 < 0xF8)
        4
    else
        return null;

    if (pos + len > input.len) return null;

    var cp: u21 = @intCast(b0 & (@as(u8, 0x7F) >> @intCast(len)));
    for (1..len) |i| {
        const b = input[pos + i];
        if (b & 0xC0 != 0x80) return null;
        cp = (cp << 6) | @as(u21, @intCast(b & 0x3F));
    }
    return .{ .cp = cp, .next = pos + len };
}

fn utf8ByteLen(b: u8) usize {
    if (b < 0x80) return 1;
    if (b < 0xC0) return 1; // invalid lead, advance 1 to avoid stuck
    if (b < 0xE0) return 2;
    if (b < 0xF0) return 3;
    if (b < 0xF8) return 4;
    return 1;
}

fn prevCodepointPos(input: []const u8, pos: usize) usize {
    if (pos == 0) return 0;
    var p = pos - 1;
    while (p > 0 and (input[p] & 0xC0) == 0x80) p -= 1;
    return p;
}

fn prevCodepoint(input: []const u8, pos: usize) u21 {
    const p = prevCodepointPos(input, pos);
    return if (decodeUtf8(input, p)) |d| d.cp else 0xFFFD;
}

// ===================================================================
// Character classification
// ===================================================================

fn charInClass(cc: *const CharClass, cp: u21) bool {
    for (cc.ranges) |range| {
        const hit = switch (range) {
            .single => |s| cp == s,
            .range => |r| cp >= r[0] and cp <= r[1],
            .class => |cls| matchPredefinedClass(cls, cp),
            .unicode_prop => |up| matchUnicodeProp(up, cp),
        };
        if (hit) return true;
    }
    return false;
}

fn isWordChar(cp: u21) bool {
    return (cp >= 'A' and cp <= 'Z') or (cp >= 'a' and cp <= 'z') or (cp >= '0' and cp <= '9') or cp == '_';
}

fn isWordCharAt(input: []const u8, pos: usize) bool {
    return if (decodeUtf8(input, pos)) |d| isWordChar(d.cp) else false;
}

fn isDigit(cp: u21) bool {
    return cp >= '0' and cp <= '9';
}

fn isSpace(cp: u21) bool {
    return switch (cp) {
        ' ', '\t', '\n', '\r', 0x0B, 0x0C, 0xA0, 0xFEFF => true,
        0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 => true,
        else => false,
    };
}

fn matchPredefinedClass(cls: PredefinedClass, cp: u21) bool {
    return switch (cls) {
        .digit => isDigit(cp),
        .non_digit => !isDigit(cp),
        .word => isWordChar(cp),
        .non_word => !isWordChar(cp),
        .space => isSpace(cp),
        .non_space => !isSpace(cp),
    };
}

fn matchUnicodeProp(up: UnicodeProp, cp: u21) bool {
    const matched = matchUnicodePropPositive(up.name, up.value, cp);
    return if (up.negated) !matched else matched;
}

fn matchUnicodePropPositive(name: []const u8, value: ?[]const u8, cp: u21) bool {
    if (value) |val| {
        if (strEqlIgnoreCase(name, "General_Category") or strEqlIgnoreCase(name, "gc"))
            return matchGeneralCategory(val, cp);
        return false;
    }
    return matchGeneralCategory(name, cp);
}

fn matchGeneralCategory(cat: []const u8, cp: u21) bool {
    if (strEqlIgnoreCase(cat, "Letter") or strEqlIgnoreCase(cat, "L")) return isLetter(cp);
    if (strEqlIgnoreCase(cat, "Number") or strEqlIgnoreCase(cat, "N") or strEqlIgnoreCase(cat, "Nd")) return isDigit(cp);
    if (strEqlIgnoreCase(cat, "Lowercase_Letter") or strEqlIgnoreCase(cat, "Ll")) return cp >= 'a' and cp <= 'z';
    if (strEqlIgnoreCase(cat, "Uppercase_Letter") or strEqlIgnoreCase(cat, "Lu")) return cp >= 'A' and cp <= 'Z';
    if (strEqlIgnoreCase(cat, "ASCII")) return cp <= 0x7F;
    return false;
}

fn isLetter(cp: u21) bool {
    if (cp >= 'A' and cp <= 'Z') return true;
    if (cp >= 'a' and cp <= 'z') return true;
    if (cp >= 0xC0 and cp <= 0x024F) return true;
    if (cp >= 0x0370 and cp <= 0x03FF) return true;
    if (cp >= 0x0400 and cp <= 0x04FF) return true;
    if (cp >= 0x0590 and cp <= 0x05FF) return true;
    if (cp >= 0x0600 and cp <= 0x06FF) return true;
    if (cp >= 0x0900 and cp <= 0x097F) return true;
    if (cp >= 0x3040 and cp <= 0x309F) return true;
    if (cp >= 0x30A0 and cp <= 0x30FF) return true;
    if (cp >= 0x4E00 and cp <= 0x9FFF) return true;
    if (cp >= 0xAC00 and cp <= 0xD7AF) return true;
    return false;
}

fn strEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        const la: u8 = if (ca >= 'A' and ca <= 'Z') ca + 32 else ca;
        const lb: u8 = if (cb >= 'A' and cb <= 'Z') cb + 32 else cb;
        if (la != lb) return false;
    }
    return true;
}

// ===================================================================
// Tests
// ===================================================================

const testing = std.testing;

fn expectMatch(pattern: []const u8, input: []const u8, expected_start: usize, expected_end: usize) !void {
    var re = try Regex.compile(testing.allocator, pattern);
    defer re.deinit();
    const m = re.exec(input) orelse {
        std.debug.print("Pattern /{s}/ did not match input \"{s}\"\n", .{ pattern, input });
        return error.TestUnexpectedResult;
    };
    if (m.start != expected_start or m.end != expected_end) {
        std.debug.print("Pattern /{s}/ on \"{s}\": expected [{d},{d}), got [{d},{d})\n", .{
            pattern, input, expected_start, expected_end, m.start, m.end,
        });
        return error.TestUnexpectedResult;
    }
}

fn expectNoMatch(pattern: []const u8, input: []const u8) !void {
    var re = try Regex.compile(testing.allocator, pattern);
    defer re.deinit();
    if (re.exec(input)) |m| {
        std.debug.print("Pattern /{s}/ unexpectedly matched input \"{s}\" at [{d},{d})\n", .{
            pattern, input, m.start, m.end,
        });
        return error.TestUnexpectedResult;
    }
}

fn expectCapture(pattern: []const u8, input: []const u8, group: usize, expected: []const u8) !void {
    var re = try Regex.compile(testing.allocator, pattern);
    defer re.deinit();
    const m = re.exec(input) orelse {
        std.debug.print("Pattern /{s}/ did not match input \"{s}\"\n", .{ pattern, input });
        return error.TestUnexpectedResult;
    };
    const got = m.captureSlice(group, input) orelse {
        std.debug.print("Pattern /{s}/ on \"{s}\": group {d} did not capture\n", .{ pattern, input, group });
        return error.TestUnexpectedResult;
    };
    if (!std.mem.eql(u8, got, expected)) {
        std.debug.print("Pattern /{s}/ on \"{s}\": group {d} captured \"{s}\", expected \"{s}\"\n", .{
            pattern, input, group, got, expected,
        });
        return error.TestUnexpectedResult;
    }
}

// ---------------------------------------------------------------
// Basic matching
// ---------------------------------------------------------------

test "basic: literal match" {
    try expectMatch("abc", "xabcy", 1, 4);
}

test "basic: literal at start" {
    try expectMatch("abc", "abcdef", 0, 3);
}

test "basic: no match" {
    try expectNoMatch("xyz", "abcdef");
}

test "basic: single char" {
    try expectMatch("a", "bac", 1, 2);
}

test "basic: dot matches any char" {
    try expectMatch("a.c", "axc", 0, 3);
}

test "basic: dot does not match newline" {
    try expectNoMatch("a.b", "a\nb");
}

// ---------------------------------------------------------------
// Greedy quantifiers
// ---------------------------------------------------------------

test "greedy: a* matches empty" {
    try expectMatch("a*", "", 0, 0);
}

test "greedy: a* matches aaa" {
    try expectMatch("a*", "aaa", 0, 3);
}

test "greedy: a+ matches aaa" {
    try expectMatch("a+", "aaa", 0, 3);
}

test "greedy: a+ requires at least one" {
    try expectNoMatch("a+", "bbb");
}

test "greedy: a? matches one" {
    try expectMatch("a?", "abc", 0, 1);
}

test "greedy: a? matches empty" {
    try expectMatch("a?", "xyz", 0, 0);
}

test "greedy: a{2,4}" {
    try expectMatch("a{2,4}", "aaaaa", 0, 4);
}

test "greedy: a{3}" {
    try expectMatch("a{3}", "aaaa", 0, 3);
}

// ---------------------------------------------------------------
// Lazy quantifiers
// ---------------------------------------------------------------

test "lazy: a*? matches empty" {
    try expectMatch("a*?", "aaa", 0, 0);
}

test "lazy: a+? matches one" {
    try expectMatch("a+?", "aaa", 0, 1);
}

// ---------------------------------------------------------------
// Capture groups
// ---------------------------------------------------------------

test "capture: (a)(b) captures" {
    try expectCapture("(a)(b)", "ab", 1, "a");
    try expectCapture("(a)(b)", "ab", 2, "b");
}

test "capture: (a+) greedy capture" {
    try expectCapture("(a+)", "aaa", 1, "aaa");
}

test "capture: nested ((a)(b))" {
    try expectCapture("((a)(b))", "ab", 1, "ab");
    try expectCapture("((a)(b))", "ab", 2, "a");
    try expectCapture("((a)(b))", "ab", 3, "b");
}

// ---------------------------------------------------------------
// Back references
// ---------------------------------------------------------------

test "backref: (a)\\1 matches aa" {
    try expectMatch("(a)\\1", "aa", 0, 2);
}

test "backref: (a)\\1 does not match ab" {
    try expectNoMatch("(a)\\1", "ab");
}

test "backref: ([ab])\\1 matches aa" {
    try expectMatch("([ab])\\1", "aabb", 0, 2);
}

test "backref: ([ab])\\1 matches bb" {
    try expectMatch("([ab])\\1", "bb", 0, 2);
}

// ---------------------------------------------------------------
// Lookahead
// ---------------------------------------------------------------

test "lookahead: (?=a)a matches" {
    try expectMatch("(?=a)a", "a", 0, 1);
}

test "lookahead: (?=a)b does not match" {
    try expectNoMatch("(?=a)b", "a");
}

test "neg lookahead: (?!b)a matches" {
    try expectMatch("(?!b)a", "a", 0, 1);
}

test "neg lookahead: (?!a)a does not match" {
    try expectNoMatch("(?!a).", "a");
}

// ---------------------------------------------------------------
// Lookbehind
// ---------------------------------------------------------------

test "lookbehind: (?<=a)b matches b in ab" {
    try expectMatch("(?<=a)b", "ab", 1, 2);
}

test "lookbehind: (?<=a)b does not match in cb" {
    try expectNoMatch("(?<=a)b", "cb");
}

test "neg lookbehind: (?<!a)b matches b in cb" {
    try expectMatch("(?<!a)b", "cb", 1, 2);
}

test "neg lookbehind: (?<!a)b does not match in ab" {
    try expectNoMatch("(?<!a)b", "ab");
}

// ---------------------------------------------------------------
// Anchors
// ---------------------------------------------------------------

test "anchor: ^abc$ matches abc" {
    try expectMatch("^abc$", "abc", 0, 3);
}

test "anchor: ^abc$ does not match xabc" {
    try expectNoMatch("^abc$", "xabc");
}

test "anchor: ^abc$ does not match abcx" {
    try expectNoMatch("^abc$", "abcx");
}

test "anchor: ^$ matches empty" {
    try expectMatch("^$", "", 0, 0);
}

// ---------------------------------------------------------------
// Word boundary
// ---------------------------------------------------------------

test "word boundary: \\bword\\b" {
    try expectMatch("\\bword\\b", "a word here", 2, 6);
}

test "word boundary: \\bword\\b does not match wording" {
    try expectNoMatch("\\bword\\b", "wording");
}

// ---------------------------------------------------------------
// Character classes
// ---------------------------------------------------------------

test "char class: [a-z]" {
    try expectMatch("[a-z]", "5a", 1, 2);
}

test "char class: [^a-z]" {
    try expectMatch("[^a-z]", "a5", 1, 2);
}

test "char class: \\d" {
    try expectMatch("\\d+", "abc123", 3, 6);
}

test "char class: \\w+" {
    try expectMatch("\\w+", "hello world", 0, 5);
}

test "char class: \\s" {
    try expectMatch("\\s", "hello world", 5, 6);
}

// ---------------------------------------------------------------
// Alternation
// ---------------------------------------------------------------

test "alternation: a|b matches a" {
    try expectMatch("a|b", "a", 0, 1);
}

test "alternation: a|b matches b" {
    try expectMatch("a|b", "b", 0, 1);
}

test "alternation: cat|dog" {
    try expectMatch("cat|dog", "I have a dog", 9, 12);
}

// ---------------------------------------------------------------
// UTF-8 support
// ---------------------------------------------------------------

test "utf8: match multi-byte chars" {
    try expectMatch("caf", "caf\xc3\xa9", 0, 3);
}

test "utf8: dot matches multi-byte" {
    try expectMatch("caf.", "caf\xc3\xa9", 0, 5);
}

// ---------------------------------------------------------------
// Complex patterns
// ---------------------------------------------------------------

test "complex: email-like pattern" {
    try expectMatch("\\w+@\\w+\\.\\w+", "send to user@example.com please", 8, 24);
}

test "complex: nested quantifier (ab)+" {
    try expectMatch("(ab)+", "xababx", 1, 5);
}

test "complex: alternation in group (foo|bar)" {
    try expectMatch("(foo|bar)", "xbarx", 1, 4);
    try expectCapture("(foo|bar)", "xbarx", 1, "bar");
}

test "complex: greedy vs context a+a" {
    try expectMatch("a+a", "aaa", 0, 3);
}

// ---------------------------------------------------------------
// Greedy vs lazy in context
// ---------------------------------------------------------------

test "greedy vs lazy: <.*> greedy matches longest" {
    try expectMatch("<.*>", "<a>b<c>", 0, 7);
}

test "greedy vs lazy: <.*?> lazy matches shortest" {
    try expectMatch("<.*?>", "<a>b<c>", 0, 3);
}

// ---------------------------------------------------------------
// Edge cases
// ---------------------------------------------------------------

test "edge: empty pattern matches empty string" {
    try expectMatch("", "", 0, 0);
}

test "edge: empty pattern matches any string at pos 0" {
    try expectMatch("", "hello", 0, 0);
}

test "edge: a{0} matches empty" {
    try expectMatch("a{0}", "b", 0, 0);
}

test "edge: match at end of string" {
    try expectMatch("c$", "abc", 2, 3);
}

test "edge: non-participating group" {
    var re = try Regex.compile(testing.allocator, "(a)|(b)");
    defer re.deinit();
    const m = re.exec("b") orelse return error.TestUnexpectedResult;
    try testing.expect(m.captureSlice(1, "b") == null);
    const g2 = m.captureSlice(2, "b") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("b", g2);
}

test "public API: matches returns bool" {
    var re = try Regex.compile(testing.allocator, "hello");
    defer re.deinit();
    try testing.expect(re.matches("say hello"));
    try testing.expect(!re.matches("say goodbye"));
}
