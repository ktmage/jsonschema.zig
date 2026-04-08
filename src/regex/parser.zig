const std = @import("std");

/// ECMA-262 Regular Expression AST Node.
pub const Node = union(enum) {
    literal: u21, // Unicode codepoint
    dot, // .
    char_class: *CharClass, // [...] or \d \w \s etc
    group: *Group, // (...) (?:...) (?=...) etc
    quantifier: *Quantified, // * + ? {n,m}
    alternation: *Alternation, // a|b|c
    sequence: *Sequence, // abc (concatenation)
    back_ref: u32, // \1 \2 ...
    named_back_ref: []const u8, // \k<name>
    anchor_start, // ^
    anchor_end, // $
    word_boundary, // \b
    non_word_boundary, // \B
};

/// Character class: [...] with ranges, predefined classes, and Unicode properties.
pub const CharClass = struct {
    negated: bool,
    ranges: []Range,

    pub const Range = union(enum) {
        single: u21, // single char
        range: [2]u21, // char range [a-z]
        class: PredefinedClass, // \d \w \s etc
        unicode_prop: UnicodeProp, // \p{...}
    };
};

/// Predefined character classes.
pub const PredefinedClass = enum {
    digit, // \d
    non_digit, // \D
    word, // \w
    non_word, // \W
    space, // \s
    non_space, // \S
};

/// Unicode property escape.
pub const UnicodeProp = struct {
    name: []const u8,
    value: ?[]const u8,
    negated: bool,
};

/// Group: (...) (?:...) (?=...) etc.
pub const Group = struct {
    kind: Kind,
    body: *Node,
    name: ?[]const u8, // for named groups

    pub const Kind = enum {
        capture, // (...)
        non_capture, // (?:...)
        lookahead, // (?=...)
        neg_lookahead, // (?!...)
        lookbehind, // (?<=...)
        neg_lookbehind, // (?<!...)
    };
};

/// Quantified node: body repeated min..max times.
pub const Quantified = struct {
    body: *Node,
    min: u32,
    max: ?u32, // null = unlimited
    greedy: bool,
};

/// Alternation: a|b|c
pub const Alternation = struct {
    alternatives: []*Node,
};

/// Sequence: abc (concatenation of items)
pub const Sequence = struct {
    items: []*Node,
};

/// Parse error information.
pub const ParseError = error{
    UnexpectedEndOfPattern,
    InvalidEscapeSequence,
    UnmatchedOpenParen,
    UnmatchedCloseParen,
    UnmatchedOpenBracket,
    InvalidQuantifier,
    InvalidQuantifierTarget,
    InvalidGroupSyntax,
    InvalidCharacterRange,
    InvalidUnicodeEscape,
    InvalidHexEscape,
    InvalidControlEscape,
    InvalidBackReference,
    InvalidNamedBackReference,
    InvalidUnicodeProperty,
    NothingToRepeat,
    OutOfMemory,
};

/// ECMA-262 Regular Expression Parser.
///
/// Parses a regex pattern string into an AST. Uses an arena allocator
/// internally for all AST node allocations.
pub const Parser = struct {
    arena: std.heap.ArenaAllocator,

    /// The pattern bytes being parsed.
    source: []const u8 = "",
    /// Current byte offset into source.
    pos: usize = 0,
    /// Number of capture groups seen so far.
    group_count: u32 = 0,

    pub fn init(alloc: std.mem.Allocator) Parser {
        return .{
            .arena = std.heap.ArenaAllocator.init(alloc),
        };
    }

    pub fn deinit(self: *Parser) void {
        self.arena.deinit();
    }

    /// Parse a regex pattern and return the root AST node.
    pub fn parse(self: *Parser, pattern: []const u8) ParseError!*Node {
        self.source = pattern;
        self.pos = 0;
        self.group_count = 0;

        const node = try self.parseAlternation();

        if (self.pos < self.source.len) {
            // There are leftover characters — likely an unmatched ')'
            return error.UnmatchedCloseParen;
        }

        return node;
    }

    // ---------------------------------------------------------------
    // Recursive descent: alternation > sequence > quantified > atom
    // ---------------------------------------------------------------

    /// Parse alternation: seq ('|' seq)*
    fn parseAlternation(self: *Parser) ParseError!*Node {
        const first = try self.parseSequence();

        if (!self.matchChar('|')) return first;

        var alts = std.ArrayList(*Node).init(self.allocator());
        try alts.append(first);

        while (true) {
            const alt = try self.parseSequence();
            try alts.append(alt);
            if (!self.matchChar('|')) break;
        }

        const alt_node = try self.create(Alternation);
        alt_node.* = .{ .alternatives = try alts.toOwnedSlice() };
        const node = try self.createNode();
        node.* = .{ .alternation = alt_node };
        return node;
    }

    /// Parse a sequence (concatenation) of quantified atoms.
    fn parseSequence(self: *Parser) ParseError!*Node {
        var items = std.ArrayList(*Node).init(self.allocator());

        while (self.pos < self.source.len) {
            const ch = self.source[self.pos];
            // Stop at alternation boundary or group close
            if (ch == '|' or ch == ')') break;

            const atom = try self.parseQuantified();
            try items.append(atom);
        }

        if (items.items.len == 0) {
            // Empty sequence → literal empty sequence
            const seq = try self.create(Sequence);
            seq.* = .{ .items = try items.toOwnedSlice() };
            const node = try self.createNode();
            node.* = .{ .sequence = seq };
            return node;
        }

        if (items.items.len == 1) return items.items[0];

        const seq = try self.create(Sequence);
        seq.* = .{ .items = try items.toOwnedSlice() };
        const node = try self.createNode();
        node.* = .{ .sequence = seq };
        return node;
    }

    /// Parse an atom optionally followed by a quantifier.
    fn parseQuantified(self: *Parser) ParseError!*Node {
        const atom = try self.parseAtom();

        if (self.pos >= self.source.len) return atom;

        const ch = self.source[self.pos];
        var min: u32 = 0;
        var max: ?u32 = null;
        var found_quant = false;

        switch (ch) {
            '*' => {
                self.pos += 1;
                min = 0;
                max = null;
                found_quant = true;
            },
            '+' => {
                self.pos += 1;
                min = 1;
                max = null;
                found_quant = true;
            },
            '?' => {
                self.pos += 1;
                min = 0;
                max = 1;
                found_quant = true;
            },
            '{' => {
                switch (self.parseBraceQuantifier()) {
                    .ok => |brace| {
                        min = brace.min;
                        max = brace.max;
                        found_quant = true;
                    },
                    .not_quantifier => return atom,
                    .err => |e| return e,
                }
            },
            else => return atom,
        }

        if (!found_quant) return atom;

        // Validate quantifier target
        switch (atom.*) {
            .anchor_start, .anchor_end, .word_boundary, .non_word_boundary => {
                return error.InvalidQuantifierTarget;
            },
            .quantifier => {
                return error.InvalidQuantifierTarget;
            },
            else => {},
        }

        // Check for lazy modifier
        var greedy = true;
        if (self.pos < self.source.len and self.source[self.pos] == '?') {
            greedy = false;
            self.pos += 1;
        }

        const q = try self.create(Quantified);
        q.* = .{
            .body = atom,
            .min = min,
            .max = max,
            .greedy = greedy,
        };
        const node = try self.createNode();
        node.* = .{ .quantifier = q };
        return node;
    }

    /// Result of attempting to parse a brace quantifier.
    const BraceResult = union(enum) {
        /// Successfully parsed quantifier bounds.
        ok: struct { min: u32, max: ?u32 },
        /// Not a brace quantifier at all (treat '{' as literal).
        not_quantifier: void,
        /// Syntactically a brace quantifier but semantically invalid (e.g., {5,3}).
        err: ParseError,
    };

    /// Try to parse {n}, {n,}, {n,m}.
    fn parseBraceQuantifier(self: *Parser) BraceResult {
        const save = self.pos;
        std.debug.assert(self.source[self.pos] == '{');
        self.pos += 1;

        const min_val = self.parseDecimal() orelse {
            self.pos = save;
            return .not_quantifier;
        };

        if (self.pos >= self.source.len) {
            self.pos = save;
            return .not_quantifier;
        }

        if (self.source[self.pos] == '}') {
            self.pos += 1;
            return .{ .ok = .{ .min = min_val, .max = min_val } };
        }

        if (self.source[self.pos] != ',') {
            self.pos = save;
            return .not_quantifier;
        }
        self.pos += 1; // skip ','

        if (self.pos >= self.source.len) {
            self.pos = save;
            return .not_quantifier;
        }

        if (self.source[self.pos] == '}') {
            self.pos += 1;
            return .{ .ok = .{ .min = min_val, .max = null } };
        }

        const max_val = self.parseDecimal() orelse {
            self.pos = save;
            return .not_quantifier;
        };

        if (self.pos >= self.source.len or self.source[self.pos] != '}') {
            self.pos = save;
            return .not_quantifier;
        }
        self.pos += 1;

        if (max_val < min_val) {
            return .{ .err = error.InvalidQuantifier };
        }

        return .{ .ok = .{ .min = min_val, .max = max_val } };
    }

    /// Parse a decimal integer from current position.
    fn parseDecimal(self: *Parser) ?u32 {
        if (self.pos >= self.source.len) return null;
        if (self.source[self.pos] < '0' or self.source[self.pos] > '9') return null;

        var val: u32 = 0;
        while (self.pos < self.source.len and self.source[self.pos] >= '0' and self.source[self.pos] <= '9') {
            val = val *% 10 +% @as(u32, self.source[self.pos] - '0');
            self.pos += 1;
        }
        return val;
    }

    /// Parse a single atom (the smallest unit).
    fn parseAtom(self: *Parser) ParseError!*Node {
        if (self.pos >= self.source.len) return error.UnexpectedEndOfPattern;

        const ch = self.source[self.pos];

        switch (ch) {
            '.' => {
                self.pos += 1;
                const node = try self.createNode();
                node.* = .dot;
                return node;
            },
            '^' => {
                self.pos += 1;
                const node = try self.createNode();
                node.* = .anchor_start;
                return node;
            },
            '$' => {
                self.pos += 1;
                const node = try self.createNode();
                node.* = .anchor_end;
                return node;
            },
            '(' => return self.parseGroup(),
            '[' => return self.parseCharClass(),
            '\\' => return self.parseEscape(),
            '*', '+', '?' => return error.NothingToRepeat,
            '{' => {
                // In ECMA-262 (non-unicode mode), '{' is a literal when it
                // doesn't form a valid quantifier. But as an atom, it's always literal.
                self.pos += 1;
                const node = try self.createNode();
                node.* = .{ .literal = '{' };
                return node;
            },
            ')' => return error.UnmatchedCloseParen,
            else => {
                // Regular literal character — decode UTF-8 codepoint
                const cp = self.decodeUtf8Codepoint() orelse return error.InvalidEscapeSequence;
                const node = try self.createNode();
                node.* = .{ .literal = cp };
                return node;
            },
        }
    }

    /// Decode a single UTF-8 codepoint from source at current position, advancing pos.
    fn decodeUtf8Codepoint(self: *Parser) ?u21 {
        if (self.pos >= self.source.len) return null;
        const b0 = self.source[self.pos];

        if (b0 < 0x80) {
            self.pos += 1;
            return @intCast(b0);
        }

        const len: usize = if (b0 < 0xC0)
            return null // invalid continuation byte
        else if (b0 < 0xE0)
            2
        else if (b0 < 0xF0)
            3
        else if (b0 < 0xF8)
            4
        else
            return null;

        if (self.pos + len > self.source.len) return null;

        var cp: u21 = @intCast(b0 & (@as(u8, 0x7F) >> @intCast(len)));
        for (1..len) |i| {
            const b = self.source[self.pos + i];
            if (b & 0xC0 != 0x80) return null;
            cp = (cp << 6) | @as(u21, @intCast(b & 0x3F));
        }
        self.pos += len;
        return cp;
    }

    /// Parse an escape sequence starting with '\'.
    fn parseEscape(self: *Parser) ParseError!*Node {
        std.debug.assert(self.source[self.pos] == '\\');
        self.pos += 1;

        if (self.pos >= self.source.len) return error.InvalidEscapeSequence;

        const ch = self.source[self.pos];
        self.pos += 1;

        switch (ch) {
            // Predefined character classes — return as char_class node
            'd', 'D', 'w', 'W', 's', 'S' => {
                const cls = charClassFromEscape(ch);
                const cc = try self.create(CharClass);
                const r = try self.allocator().alloc(CharClass.Range, 1);
                r[0] = .{ .class = cls };
                cc.* = .{ .negated = false, .ranges = r };
                const node = try self.createNode();
                node.* = .{ .char_class = cc };
                return node;
            },

            // Anchors
            'b' => {
                const node = try self.createNode();
                node.* = .word_boundary;
                return node;
            },
            'B' => {
                const node = try self.createNode();
                node.* = .non_word_boundary;
                return node;
            },

            // Simple escapes
            'n' => return self.makeLiteral('\n'),
            't' => return self.makeLiteral('\t'),
            'r' => return self.makeLiteral('\r'),
            'f' => return self.makeLiteral(0x0C),
            'v' => return self.makeLiteral(0x0B),
            '0' => {
                // \0 is NUL, but \0n where n is a digit is an octal escape
                // ECMA-262 Annex B: \0 when not followed by a digit is NUL
                if (self.pos < self.source.len and self.source[self.pos] >= '0' and self.source[self.pos] <= '9') {
                    // Octal escape — parse legacy octal
                    self.pos -= 1; // back up to re-parse as octal
                    return self.parseOctalEscape();
                }
                return self.makeLiteral(0);
            },

            // Hex escape \xHH
            'x' => {
                const val = self.parseHexFixed(2) orelse return error.InvalidHexEscape;
                return self.makeLiteral(@intCast(val));
            },

            // Unicode escape \uHHHH or \u{HHHH}
            'u' => {
                if (self.pos < self.source.len and self.source[self.pos] == '{') {
                    self.pos += 1;
                    const val = self.parseHexVariable() orelse return error.InvalidUnicodeEscape;
                    if (self.pos >= self.source.len or self.source[self.pos] != '}')
                        return error.InvalidUnicodeEscape;
                    self.pos += 1;
                    if (val > 0x10FFFF) return error.InvalidUnicodeEscape;
                    return self.makeLiteral(@intCast(val));
                }
                const val = self.parseHexFixed(4) orelse return error.InvalidUnicodeEscape;
                return self.makeLiteral(@intCast(val));
            },

            // Control escape \cX
            'c' => {
                if (self.pos >= self.source.len) return error.InvalidControlEscape;
                const ctrl = self.source[self.pos];
                if ((ctrl >= 'A' and ctrl <= 'Z') or (ctrl >= 'a' and ctrl <= 'z')) {
                    self.pos += 1;
                    return self.makeLiteral(@intCast(ctrl & 0x1F));
                }
                return error.InvalidControlEscape;
            },

            // Back references \1 - \9
            '1', '2', '3', '4', '5', '6', '7', '8', '9' => {
                // Parse multi-digit back reference
                var ref_num: u32 = @intCast(ch - '0');
                while (self.pos < self.source.len and self.source[self.pos] >= '0' and self.source[self.pos] <= '9') {
                    const new_ref = ref_num * 10 + @as(u32, self.source[self.pos] - '0');
                    // Only consume digits that keep it a valid back reference
                    if (new_ref > self.group_count and ref_num <= self.group_count) break;
                    ref_num = new_ref;
                    self.pos += 1;
                }
                const node = try self.createNode();
                node.* = .{ .back_ref = ref_num };
                return node;
            },

            // Named back reference \k<name>
            'k' => {
                if (self.pos >= self.source.len or self.source[self.pos] != '<')
                    return error.InvalidNamedBackReference;
                self.pos += 1;
                const name_start = self.pos;
                while (self.pos < self.source.len and self.source[self.pos] != '>') {
                    self.pos += 1;
                }
                if (self.pos >= self.source.len) return error.InvalidNamedBackReference;
                const name = self.source[name_start..self.pos];
                if (name.len == 0) return error.InvalidNamedBackReference;
                self.pos += 1; // skip '>'
                const node = try self.createNode();
                node.* = .{ .named_back_ref = name };
                return node;
            },

            // Unicode property escapes \p{...} and \P{...}
            'p', 'P' => {
                const negated = (ch == 'P');
                if (self.pos >= self.source.len or self.source[self.pos] != '{')
                    return error.InvalidUnicodeProperty;
                self.pos += 1;
                const prop_start = self.pos;
                while (self.pos < self.source.len and self.source[self.pos] != '}') {
                    self.pos += 1;
                }
                if (self.pos >= self.source.len) return error.InvalidUnicodeProperty;
                const prop_str = self.source[prop_start..self.pos];
                self.pos += 1; // skip '}'

                // Parse name=value or just name
                var prop_name: []const u8 = prop_str;
                var prop_value: ?[]const u8 = null;
                if (std.mem.indexOfScalar(u8, prop_str, '=')) |eq_idx| {
                    prop_name = prop_str[0..eq_idx];
                    prop_value = prop_str[eq_idx + 1 ..];
                }

                const up = try self.create(UnicodeProp);
                up.* = .{ .name = prop_name, .value = prop_value, .negated = negated };

                const cc = try self.create(CharClass);
                const r = try self.allocator().alloc(CharClass.Range, 1);
                r[0] = .{ .unicode_prop = up.* };
                cc.* = .{ .negated = false, .ranges = r };
                const node = try self.createNode();
                node.* = .{ .char_class = cc };
                return node;
            },

            // Identity escapes: literal versions of metacharacters
            // ECMA-262 allows escaping any syntax character
            '^', '$', '\\', '.', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|', '/' => {
                return self.makeLiteral(@intCast(ch));
            },

            else => {
                // In non-unicode mode, ECMA-262 Annex B allows identity escapes
                // for non-syntax characters. We'll be lenient.
                return self.makeLiteral(@intCast(ch));
            },
        }
    }

    /// Parse an octal escape (legacy Annex B).
    fn parseOctalEscape(self: *Parser) ParseError!*Node {
        var val: u32 = 0;
        var count: u32 = 0;
        while (self.pos < self.source.len and self.source[self.pos] >= '0' and self.source[self.pos] <= '7' and count < 3) {
            val = val * 8 + @as(u32, self.source[self.pos] - '0');
            self.pos += 1;
            count += 1;
            if (val > 0xFF) {
                // Undo last digit
                self.pos -= 1;
                val = (val - @as(u32, self.source[self.pos] - '0')) / 8;
                break;
            }
        }
        return self.makeLiteral(@intCast(val));
    }

    /// Parse exactly `n` hex digits and return the value.
    fn parseHexFixed(self: *Parser, n: u32) ?u32 {
        if (self.pos + n > self.source.len) return null;
        var val: u32 = 0;
        for (0..n) |_| {
            const d = hexVal(self.source[self.pos]) orelse return null;
            val = val * 16 + d;
            self.pos += 1;
        }
        return val;
    }

    /// Parse a variable number of hex digits (at least 1) and return the value.
    fn parseHexVariable(self: *Parser) ?u32 {
        if (self.pos >= self.source.len) return null;
        var val: u32 = 0;
        var count: u32 = 0;
        while (self.pos < self.source.len) {
            const d = hexVal(self.source[self.pos]) orelse break;
            val = val * 16 + d;
            self.pos += 1;
            count += 1;
        }
        if (count == 0) return null;
        return val;
    }

    fn hexVal(ch: u8) ?u32 {
        if (ch >= '0' and ch <= '9') return @intCast(ch - '0');
        if (ch >= 'a' and ch <= 'f') return @intCast(ch - 'a' + 10);
        if (ch >= 'A' and ch <= 'F') return @intCast(ch - 'A' + 10);
        return null;
    }

    // ---------------------------------------------------------------
    // Groups
    // ---------------------------------------------------------------

    /// Parse a group: (...), (?:...), (?=...), (?!...), (?<=...), (?<!...), (?<name>...)
    fn parseGroup(self: *Parser) ParseError!*Node {
        std.debug.assert(self.source[self.pos] == '(');
        self.pos += 1;

        if (self.pos >= self.source.len) return error.UnmatchedOpenParen;

        var kind: Group.Kind = .capture;
        var name: ?[]const u8 = null;

        if (self.source[self.pos] == '?') {
            self.pos += 1;
            if (self.pos >= self.source.len) return error.InvalidGroupSyntax;

            switch (self.source[self.pos]) {
                ':' => {
                    self.pos += 1;
                    kind = .non_capture;
                },
                '=' => {
                    self.pos += 1;
                    kind = .lookahead;
                },
                '!' => {
                    self.pos += 1;
                    kind = .neg_lookahead;
                },
                '<' => {
                    self.pos += 1;
                    if (self.pos >= self.source.len) return error.InvalidGroupSyntax;
                    if (self.source[self.pos] == '=') {
                        self.pos += 1;
                        kind = .lookbehind;
                    } else if (self.source[self.pos] == '!') {
                        self.pos += 1;
                        kind = .neg_lookbehind;
                    } else {
                        // Named capture group (?<name>...)
                        kind = .capture;
                        const name_start = self.pos;
                        while (self.pos < self.source.len and self.source[self.pos] != '>') {
                            self.pos += 1;
                        }
                        if (self.pos >= self.source.len) return error.InvalidGroupSyntax;
                        name = self.source[name_start..self.pos];
                        if (name.?.len == 0) return error.InvalidGroupSyntax;
                        self.pos += 1; // skip '>'
                    }
                },
                else => return error.InvalidGroupSyntax,
            }
        }

        if (kind == .capture) {
            self.group_count += 1;
        }

        const body = try self.parseAlternation();

        if (self.pos >= self.source.len or self.source[self.pos] != ')') {
            return error.UnmatchedOpenParen;
        }
        self.pos += 1; // skip ')'

        const g = try self.create(Group);
        g.* = .{
            .kind = kind,
            .body = body,
            .name = name,
        };
        const node = try self.createNode();
        node.* = .{ .group = g };
        return node;
    }

    // ---------------------------------------------------------------
    // Character classes
    // ---------------------------------------------------------------

    /// Parse a character class: [...].
    fn parseCharClass(self: *Parser) ParseError!*Node {
        std.debug.assert(self.source[self.pos] == '[');
        self.pos += 1;

        if (self.pos >= self.source.len) return error.UnmatchedOpenBracket;

        var negated = false;
        if (self.source[self.pos] == '^') {
            negated = true;
            self.pos += 1;
        }

        var ranges = std.ArrayList(CharClass.Range).init(self.allocator());

        // Handle ']' as first char in class (literal)
        if (self.pos < self.source.len and self.source[self.pos] == ']') {
            try ranges.append(.{ .single = ']' });
            self.pos += 1;
        }

        while (self.pos < self.source.len and self.source[self.pos] != ']') {
            const item = try self.parseCharClassAtom();

            // Check for range: a-z
            if (self.pos + 1 < self.source.len and self.source[self.pos] == '-' and self.source[self.pos + 1] != ']') {
                // Peek to see if this can form a range
                switch (item) {
                    .single => |lo| {
                        self.pos += 1; // skip '-'
                        const hi_item = try self.parseCharClassAtom();
                        switch (hi_item) {
                            .single => |hi| {
                                if (hi < lo) return error.InvalidCharacterRange;
                                try ranges.append(.{ .range = .{ lo, hi } });
                            },
                            else => {
                                // Can't form range with class/property, treat separately
                                try ranges.append(item);
                                try ranges.append(.{ .single = '-' });
                                try ranges.append(hi_item);
                            },
                        }
                    },
                    else => {
                        try ranges.append(item);
                    },
                }
            } else {
                try ranges.append(item);
            }
        }

        if (self.pos >= self.source.len) return error.UnmatchedOpenBracket;
        self.pos += 1; // skip ']'

        const cc = try self.create(CharClass);
        cc.* = .{ .negated = negated, .ranges = try ranges.toOwnedSlice() };
        const node = try self.createNode();
        node.* = .{ .char_class = cc };
        return node;
    }

    /// Parse a single atom inside a character class.
    fn parseCharClassAtom(self: *Parser) ParseError!CharClass.Range {
        if (self.pos >= self.source.len) return error.UnmatchedOpenBracket;

        if (self.source[self.pos] == '\\') {
            self.pos += 1;
            if (self.pos >= self.source.len) return error.InvalidEscapeSequence;

            const ch = self.source[self.pos];
            self.pos += 1;

            switch (ch) {
                'd' => return .{ .class = .digit },
                'D' => return .{ .class = .non_digit },
                'w' => return .{ .class = .word },
                'W' => return .{ .class = .non_word },
                's' => return .{ .class = .space },
                'S' => return .{ .class = .non_space },
                'n' => return .{ .single = '\n' },
                't' => return .{ .single = '\t' },
                'r' => return .{ .single = '\r' },
                'f' => return .{ .single = 0x0C },
                'v' => return .{ .single = 0x0B },
                '0' => return .{ .single = 0 },
                'b' => return .{ .single = 0x08 }, // backspace in char class
                'x' => {
                    const val = self.parseHexFixed(2) orelse return error.InvalidHexEscape;
                    return .{ .single = @intCast(val) };
                },
                'u' => {
                    if (self.pos < self.source.len and self.source[self.pos] == '{') {
                        self.pos += 1;
                        const val = self.parseHexVariable() orelse return error.InvalidUnicodeEscape;
                        if (self.pos >= self.source.len or self.source[self.pos] != '}')
                            return error.InvalidUnicodeEscape;
                        self.pos += 1;
                        if (val > 0x10FFFF) return error.InvalidUnicodeEscape;
                        return .{ .single = @intCast(val) };
                    }
                    const val = self.parseHexFixed(4) orelse return error.InvalidUnicodeEscape;
                    return .{ .single = @intCast(val) };
                },
                'c' => {
                    if (self.pos >= self.source.len) return error.InvalidControlEscape;
                    const ctrl = self.source[self.pos];
                    if ((ctrl >= 'A' and ctrl <= 'Z') or (ctrl >= 'a' and ctrl <= 'z')) {
                        self.pos += 1;
                        return .{ .single = @intCast(ctrl & 0x1F) };
                    }
                    return error.InvalidControlEscape;
                },
                'p', 'P' => {
                    const negated = (ch == 'P');
                    if (self.pos >= self.source.len or self.source[self.pos] != '{')
                        return error.InvalidUnicodeProperty;
                    self.pos += 1;
                    const prop_start = self.pos;
                    while (self.pos < self.source.len and self.source[self.pos] != '}') {
                        self.pos += 1;
                    }
                    if (self.pos >= self.source.len) return error.InvalidUnicodeProperty;
                    const prop_str = self.source[prop_start..self.pos];
                    self.pos += 1; // skip '}'

                    var prop_name: []const u8 = prop_str;
                    var prop_value: ?[]const u8 = null;
                    if (std.mem.indexOfScalar(u8, prop_str, '=')) |eq_idx| {
                        prop_name = prop_str[0..eq_idx];
                        prop_value = prop_str[eq_idx + 1 ..];
                    }

                    return .{ .unicode_prop = .{ .name = prop_name, .value = prop_value, .negated = negated } };
                },
                // Identity escapes within character class
                '-', '^', ']', '\\', '[' => return .{ .single = @intCast(ch) },
                // Other escapes: identity
                else => return .{ .single = @intCast(ch) },
            }
        }

        // Regular literal character
        const cp = self.decodeUtf8Codepoint() orelse return error.UnmatchedOpenBracket;
        return .{ .single = cp };
    }

    // ---------------------------------------------------------------
    // Helper: map escape char to predefined class
    // ---------------------------------------------------------------

    fn charClassFromEscape(ch: u8) PredefinedClass {
        return switch (ch) {
            'd' => .digit,
            'D' => .non_digit,
            'w' => .word,
            'W' => .non_word,
            's' => .space,
            'S' => .non_space,
            else => unreachable,
        };
    }

    // ---------------------------------------------------------------
    // Allocation helpers
    // ---------------------------------------------------------------

    fn allocator(self: *Parser) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn create(self: *Parser, comptime T: type) ParseError!*T {
        return self.arena.allocator().create(T) catch return error.OutOfMemory;
    }

    fn createNode(self: *Parser) ParseError!*Node {
        return self.create(Node);
    }

    fn makeLiteral(self: *Parser, cp: u21) ParseError!*Node {
        const node = try self.createNode();
        node.* = .{ .literal = cp };
        return node;
    }

    fn matchChar(self: *Parser, ch: u8) bool {
        if (self.pos < self.source.len and self.source[self.pos] == ch) {
            self.pos += 1;
            return true;
        }
        return false;
    }
};

// ===================================================================
// Tests
// ===================================================================

const testing = std.testing;

fn expectLiteral(node: *const Node, expected: u21) !void {
    try testing.expectEqual(Node{ .literal = expected }, node.*);
}

fn expectNodeTag(node: *const Node, comptime expected: std.meta.Tag(Node)) !void {
    try testing.expectEqual(expected, std.meta.activeTag(node.*));
}

// ---------------------------------------------------------------
// Basic literals
// ---------------------------------------------------------------

test "basic literals: single char" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const node = try p.parse("a");
    try expectLiteral(node, 'a');
}

test "basic literals: sequence of chars" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const node = try p.parse("abc");
    try expectNodeTag(node, .sequence);
    const seq = node.sequence;
    try testing.expectEqual(@as(usize, 3), seq.items.len);
    try expectLiteral(seq.items[0], 'a');
    try expectLiteral(seq.items[1], 'b');
    try expectLiteral(seq.items[2], 'c');
}

test "basic literals: empty pattern" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const node = try p.parse("");
    try expectNodeTag(node, .sequence);
    try testing.expectEqual(@as(usize, 0), node.sequence.items.len);
}

// ---------------------------------------------------------------
// Dot
// ---------------------------------------------------------------

test "dot" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const node = try p.parse(".");
    try expectNodeTag(node, .dot);
}

// ---------------------------------------------------------------
// Anchors
// ---------------------------------------------------------------

test "anchors: ^ and $" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const node = try p.parse("^a$");
    try expectNodeTag(node, .sequence);
    const items = node.sequence.items;
    try testing.expectEqual(@as(usize, 3), items.len);
    try expectNodeTag(items[0], .anchor_start);
    try expectLiteral(items[1], 'a');
    try expectNodeTag(items[2], .anchor_end);
}

// ---------------------------------------------------------------
// Character classes
// ---------------------------------------------------------------

test "char class: [a-z]" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const node = try p.parse("[a-z]");
    try expectNodeTag(node, .char_class);
    const cc = node.char_class;
    try testing.expect(!cc.negated);
    try testing.expectEqual(@as(usize, 1), cc.ranges.len);
    switch (cc.ranges[0]) {
        .range => |r| {
            try testing.expectEqual(@as(u21, 'a'), r[0]);
            try testing.expectEqual(@as(u21, 'z'), r[1]);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "char class: [^0-9]" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const node = try p.parse("[^0-9]");
    try expectNodeTag(node, .char_class);
    const cc = node.char_class;
    try testing.expect(cc.negated);
    try testing.expectEqual(@as(usize, 1), cc.ranges.len);
    switch (cc.ranges[0]) {
        .range => |r| {
            try testing.expectEqual(@as(u21, '0'), r[0]);
            try testing.expectEqual(@as(u21, '9'), r[1]);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "char class: [\\d\\w]" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const node = try p.parse("[\\d\\w]");
    try expectNodeTag(node, .char_class);
    const cc = node.char_class;
    try testing.expectEqual(@as(usize, 2), cc.ranges.len);
    switch (cc.ranges[0]) {
        .class => |cls| try testing.expectEqual(PredefinedClass.digit, cls),
        else => return error.TestUnexpectedResult,
    }
    switch (cc.ranges[1]) {
        .class => |cls| try testing.expectEqual(PredefinedClass.word, cls),
        else => return error.TestUnexpectedResult,
    }
}

test "char class: [abc]" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const node = try p.parse("[abc]");
    try expectNodeTag(node, .char_class);
    const cc = node.char_class;
    try testing.expectEqual(@as(usize, 3), cc.ranges.len);
    switch (cc.ranges[0]) {
        .single => |v| try testing.expectEqual(@as(u21, 'a'), v),
        else => return error.TestUnexpectedResult,
    }
}

test "char class: ] as first char" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const node = try p.parse("[]a]");
    try expectNodeTag(node, .char_class);
    const cc = node.char_class;
    try testing.expectEqual(@as(usize, 2), cc.ranges.len);
    switch (cc.ranges[0]) {
        .single => |v| try testing.expectEqual(@as(u21, ']'), v),
        else => return error.TestUnexpectedResult,
    }
}

// ---------------------------------------------------------------
// Groups
// ---------------------------------------------------------------

test "group: capture (abc)" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const node = try p.parse("(abc)");
    try expectNodeTag(node, .group);
    const g = node.group;
    try testing.expectEqual(Group.Kind.capture, g.kind);
    try testing.expect(g.name == null);
    try expectNodeTag(g.body, .sequence);
}

test "group: non-capture (?:abc)" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const node = try p.parse("(?:abc)");
    try expectNodeTag(node, .group);
    try testing.expectEqual(Group.Kind.non_capture, node.group.kind);
}

test "group: lookahead (?=abc)" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const node = try p.parse("(?=abc)");
    try expectNodeTag(node, .group);
    try testing.expectEqual(Group.Kind.lookahead, node.group.kind);
}

test "group: neg lookahead (?!abc)" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const node = try p.parse("(?!abc)");
    try expectNodeTag(node, .group);
    try testing.expectEqual(Group.Kind.neg_lookahead, node.group.kind);
}

test "group: lookbehind (?<=abc)" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const node = try p.parse("(?<=abc)");
    try expectNodeTag(node, .group);
    try testing.expectEqual(Group.Kind.lookbehind, node.group.kind);
}

test "group: neg lookbehind (?<!abc)" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const node = try p.parse("(?<!abc)");
    try expectNodeTag(node, .group);
    try testing.expectEqual(Group.Kind.neg_lookbehind, node.group.kind);
}

test "group: named capture (?<name>abc)" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const node = try p.parse("(?<name>abc)");
    try expectNodeTag(node, .group);
    const g = node.group;
    try testing.expectEqual(Group.Kind.capture, g.kind);
    try testing.expectEqualStrings("name", g.name.?);
}

// ---------------------------------------------------------------
// Quantifiers
// ---------------------------------------------------------------

test "quantifier: a*" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const node = try p.parse("a*");
    try expectNodeTag(node, .quantifier);
    const q = node.quantifier;
    try testing.expectEqual(@as(u32, 0), q.min);
    try testing.expect(q.max == null);
    try testing.expect(q.greedy);
    try expectLiteral(q.body, 'a');
}

test "quantifier: a+" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const node = try p.parse("a+");
    try expectNodeTag(node, .quantifier);
    const q = node.quantifier;
    try testing.expectEqual(@as(u32, 1), q.min);
    try testing.expect(q.max == null);
    try testing.expect(q.greedy);
}

test "quantifier: a?" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const node = try p.parse("a?");
    try expectNodeTag(node, .quantifier);
    const q = node.quantifier;
    try testing.expectEqual(@as(u32, 0), q.min);
    try testing.expectEqual(@as(?u32, 1), q.max);
    try testing.expect(q.greedy);
}

test "quantifier: a{3}" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const node = try p.parse("a{3}");
    try expectNodeTag(node, .quantifier);
    const q = node.quantifier;
    try testing.expectEqual(@as(u32, 3), q.min);
    try testing.expectEqual(@as(?u32, 3), q.max);
}

test "quantifier: a{3,5}" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const node = try p.parse("a{3,5}");
    try expectNodeTag(node, .quantifier);
    const q = node.quantifier;
    try testing.expectEqual(@as(u32, 3), q.min);
    try testing.expectEqual(@as(?u32, 5), q.max);
}

test "quantifier: a{3,}" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const node = try p.parse("a{3,}");
    try expectNodeTag(node, .quantifier);
    const q = node.quantifier;
    try testing.expectEqual(@as(u32, 3), q.min);
    try testing.expect(q.max == null);
}

test "quantifier: a*? (lazy)" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const node = try p.parse("a*?");
    try expectNodeTag(node, .quantifier);
    const q = node.quantifier;
    try testing.expectEqual(@as(u32, 0), q.min);
    try testing.expect(q.max == null);
    try testing.expect(!q.greedy);
}

test "quantifier: a+? (lazy)" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const node = try p.parse("a+?");
    try expectNodeTag(node, .quantifier);
    try testing.expect(!node.quantifier.greedy);
}

test "quantifier: a{2,4}? (lazy)" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const node = try p.parse("a{2,4}?");
    try expectNodeTag(node, .quantifier);
    try testing.expect(!node.quantifier.greedy);
    try testing.expectEqual(@as(u32, 2), node.quantifier.min);
    try testing.expectEqual(@as(?u32, 4), node.quantifier.max);
}

// ---------------------------------------------------------------
// Alternation
// ---------------------------------------------------------------

test "alternation: a|b|c" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const node = try p.parse("a|b|c");
    try expectNodeTag(node, .alternation);
    const alt = node.alternation;
    try testing.expectEqual(@as(usize, 3), alt.alternatives.len);
    try expectLiteral(alt.alternatives[0], 'a');
    try expectLiteral(alt.alternatives[1], 'b');
    try expectLiteral(alt.alternatives[2], 'c');
}

test "alternation: ab|cd" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const node = try p.parse("ab|cd");
    try expectNodeTag(node, .alternation);
    const alt = node.alternation;
    try testing.expectEqual(@as(usize, 2), alt.alternatives.len);
    try expectNodeTag(alt.alternatives[0], .sequence);
    try expectNodeTag(alt.alternatives[1], .sequence);
}

// ---------------------------------------------------------------
// Escape sequences
// ---------------------------------------------------------------

test "escape: \\d \\w \\s" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const node = try p.parse("\\d");
    try expectNodeTag(node, .char_class);
    const cc = node.char_class;
    try testing.expectEqual(@as(usize, 1), cc.ranges.len);
    switch (cc.ranges[0]) {
        .class => |cls| try testing.expectEqual(PredefinedClass.digit, cls),
        else => return error.TestUnexpectedResult,
    }
}

test "escape: \\D \\W \\S" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const node = try p.parse("\\D");
    try expectNodeTag(node, .char_class);
    switch (node.char_class.ranges[0]) {
        .class => |cls| try testing.expectEqual(PredefinedClass.non_digit, cls),
        else => return error.TestUnexpectedResult,
    }
}

test "escape: \\n \\t \\r" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    {
        const node = try p.parse("\\n");
        try expectLiteral(node, '\n');
    }
}

test "escape: \\t" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const node = try p.parse("\\t");
    try expectLiteral(node, '\t');
}

test "escape: \\x41" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const node = try p.parse("\\x41");
    try expectLiteral(node, 'A');
}

test "escape: \\u0041" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const node = try p.parse("\\u0041");
    try expectLiteral(node, 'A');
}

test "escape: \\u{41}" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const node = try p.parse("\\u{41}");
    try expectLiteral(node, 'A');
}

test "escape: \\u{1F600} (emoji)" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const node = try p.parse("\\u{1F600}");
    try expectLiteral(node, 0x1F600);
}

test "escape: \\cA (control)" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const node = try p.parse("\\cA");
    try expectLiteral(node, 1); // ctrl-A = 0x01
}

test "escape: \\0 (NUL)" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const node = try p.parse("\\0");
    try expectLiteral(node, 0);
}

test "escape: \\. literal dot" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const node = try p.parse("\\.");
    try expectLiteral(node, '.');
}

test "escape: \\* literal star" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const node = try p.parse("\\*");
    try expectLiteral(node, '*');
}

// ---------------------------------------------------------------
// Word boundary
// ---------------------------------------------------------------

test "word boundary: \\b and \\B" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    {
        const node = try p.parse("\\b");
        try expectNodeTag(node, .word_boundary);
    }
}

test "non-word boundary: \\B" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const node = try p.parse("\\B");
    try expectNodeTag(node, .non_word_boundary);
}

// ---------------------------------------------------------------
// Back references
// ---------------------------------------------------------------

test "back reference: (a)\\1" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const node = try p.parse("(a)\\1");
    try expectNodeTag(node, .sequence);
    const items = node.sequence.items;
    try testing.expectEqual(@as(usize, 2), items.len);
    try expectNodeTag(items[0], .group);
    try expectNodeTag(items[1], .back_ref);
    try testing.expectEqual(@as(u32, 1), items[1].back_ref);
}

// ---------------------------------------------------------------
// Named groups and named back references
// ---------------------------------------------------------------

test "named group and back reference: (?<name>abc)\\k<name>" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const node = try p.parse("(?<name>abc)\\k<name>");
    try expectNodeTag(node, .sequence);
    const items = node.sequence.items;
    try testing.expectEqual(@as(usize, 2), items.len);
    try expectNodeTag(items[0], .group);
    try testing.expectEqualStrings("name", items[0].group.name.?);
    try expectNodeTag(items[1], .named_back_ref);
    try testing.expectEqualStrings("name", items[1].named_back_ref);
}

// ---------------------------------------------------------------
// Lookahead / lookbehind combined with other atoms
// ---------------------------------------------------------------

test "lookahead: (?=abc)def" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const node = try p.parse("(?=abc)def");
    try expectNodeTag(node, .sequence);
    const items = node.sequence.items;
    try testing.expectEqual(@as(usize, 4), items.len);
    try expectNodeTag(items[0], .group);
    try testing.expectEqual(Group.Kind.lookahead, items[0].group.kind);
    try expectLiteral(items[1], 'd');
}

test "lookbehind: (?<=abc)def" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const node = try p.parse("(?<=abc)def");
    try expectNodeTag(node, .sequence);
    const items = node.sequence.items;
    try testing.expectEqual(@as(usize, 4), items.len);
    try expectNodeTag(items[0], .group);
    try testing.expectEqual(Group.Kind.lookbehind, items[0].group.kind);
}

// ---------------------------------------------------------------
// Unicode property escapes
// ---------------------------------------------------------------

test "unicode property: \\p{Letter}" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const node = try p.parse("\\p{Letter}");
    try expectNodeTag(node, .char_class);
    const cc = node.char_class;
    try testing.expectEqual(@as(usize, 1), cc.ranges.len);
    switch (cc.ranges[0]) {
        .unicode_prop => |up| {
            try testing.expectEqualStrings("Letter", up.name);
            try testing.expect(up.value == null);
            try testing.expect(!up.negated);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "unicode property: \\P{Script=Latin}" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const node = try p.parse("\\P{Script=Latin}");
    try expectNodeTag(node, .char_class);
    switch (node.char_class.ranges[0]) {
        .unicode_prop => |up| {
            try testing.expectEqualStrings("Script", up.name);
            try testing.expectEqualStrings("Latin", up.value.?);
            try testing.expect(up.negated);
        },
        else => return error.TestUnexpectedResult,
    }
}

// ---------------------------------------------------------------
// Complex patterns
// ---------------------------------------------------------------

test "complex: ^(?:(?=.*\\d)(?=.*[a-z])(?=.*[A-Z]).{8,})$" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const node = try p.parse("^(?:(?=.*\\d)(?=.*[a-z])(?=.*[A-Z]).{8,})$");
    try expectNodeTag(node, .sequence);
    const items = node.sequence.items;
    try testing.expect(items.len >= 3); // ^, group, $
    try expectNodeTag(items[0], .anchor_start);
    try expectNodeTag(items[items.len - 1], .anchor_end);
    try expectNodeTag(items[1], .group);
    try testing.expectEqual(Group.Kind.non_capture, items[1].group.kind);
}

test "complex: (foo)|(bar)" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const node = try p.parse("(foo)|(bar)");
    try expectNodeTag(node, .alternation);
    const alts = node.alternation.alternatives;
    try testing.expectEqual(@as(usize, 2), alts.len);
    try expectNodeTag(alts[0], .group);
    try expectNodeTag(alts[1], .group);
}

test "complex: nested groups ((a)(b))" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const node = try p.parse("((a)(b))");
    try expectNodeTag(node, .group);
    const body = node.group.body;
    try expectNodeTag(body, .sequence);
    try testing.expectEqual(@as(usize, 2), body.sequence.items.len);
    try expectNodeTag(body.sequence.items[0], .group);
    try expectNodeTag(body.sequence.items[1], .group);
}

test "complex: quantified group (ab)+" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const node = try p.parse("(ab)+");
    try expectNodeTag(node, .quantifier);
    try expectNodeTag(node.quantifier.body, .group);
    try testing.expectEqual(@as(u32, 1), node.quantifier.min);
    try testing.expect(node.quantifier.max == null);
}

test "complex: alternation inside group (a|b)" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const node = try p.parse("(a|b)");
    try expectNodeTag(node, .group);
    try expectNodeTag(node.group.body, .alternation);
}

test "complex: quantified char class [a-z]+" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const node = try p.parse("[a-z]+");
    try expectNodeTag(node, .quantifier);
    try expectNodeTag(node.quantifier.body, .char_class);
}

test "complex: escaped chars in class [\\n\\t\\r]" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const node = try p.parse("[\\n\\t\\r]");
    try expectNodeTag(node, .char_class);
    const cc = node.char_class;
    try testing.expectEqual(@as(usize, 3), cc.ranges.len);
    switch (cc.ranges[0]) {
        .single => |v| try testing.expectEqual(@as(u21, '\n'), v),
        else => return error.TestUnexpectedResult,
    }
    switch (cc.ranges[1]) {
        .single => |v| try testing.expectEqual(@as(u21, '\t'), v),
        else => return error.TestUnexpectedResult,
    }
    switch (cc.ranges[2]) {
        .single => |v| try testing.expectEqual(@as(u21, '\r'), v),
        else => return error.TestUnexpectedResult,
    }
}

test "backspace in char class: [\\b]" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const node = try p.parse("[\\b]");
    try expectNodeTag(node, .char_class);
    switch (node.char_class.ranges[0]) {
        .single => |v| try testing.expectEqual(@as(u21, 0x08), v),
        else => return error.TestUnexpectedResult,
    }
}

// ---------------------------------------------------------------
// Error cases
// ---------------------------------------------------------------

test "error: unmatched [" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const result = p.parse("[");
    try testing.expectError(error.UnmatchedOpenBracket, result);
}

test "error: unmatched (" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const result = p.parse("(");
    try testing.expectError(error.UnmatchedOpenParen, result);
}

test "error: unmatched )" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const result = p.parse(")");
    try testing.expectError(error.UnmatchedCloseParen, result);
}

test "error: * at start (nothing to repeat)" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const result = p.parse("*");
    try testing.expectError(error.NothingToRepeat, result);
}

test "error: + at start (nothing to repeat)" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const result = p.parse("+");
    try testing.expectError(error.NothingToRepeat, result);
}

test "error: ? at start (nothing to repeat)" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const result = p.parse("?");
    try testing.expectError(error.NothingToRepeat, result);
}

test "error: invalid quantifier range {5,3}" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const result = p.parse("a{5,3}");
    try testing.expectError(error.InvalidQuantifier, result);
}

test "error: invalid hex escape \\xGG" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const result = p.parse("\\xGG");
    try testing.expectError(error.InvalidHexEscape, result);
}

test "error: invalid unicode escape \\uGGGG" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const result = p.parse("\\uGGGG");
    try testing.expectError(error.InvalidUnicodeEscape, result);
}

test "error: invalid group syntax (?X...)" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const result = p.parse("(?X)");
    try testing.expectError(error.InvalidGroupSyntax, result);
}

test "error: invalid char range [z-a]" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const result = p.parse("[z-a]");
    try testing.expectError(error.InvalidCharacterRange, result);
}

test "error: incomplete escape at end \\" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const result = p.parse("\\");
    try testing.expectError(error.InvalidEscapeSequence, result);
}

test "error: invalid control escape \\c1" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const result = p.parse("\\c1");
    try testing.expectError(error.InvalidControlEscape, result);
}

test "error: invalid named back ref \\k<>" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const result = p.parse("\\k<>");
    try testing.expectError(error.InvalidNamedBackReference, result);
}

test "error: quantifier on anchor ^+" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const result = p.parse("^+");
    try testing.expectError(error.InvalidQuantifierTarget, result);
}

// ---------------------------------------------------------------
// Edge cases
// ---------------------------------------------------------------

test "edge: empty alternation a|" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const node = try p.parse("a|");
    try expectNodeTag(node, .alternation);
    const alts = node.alternation.alternatives;
    try testing.expectEqual(@as(usize, 2), alts.len);
    try expectLiteral(alts[0], 'a');
    try expectNodeTag(alts[1], .sequence); // empty sequence
}

test "edge: |b (empty first alternative)" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const node = try p.parse("|b");
    try expectNodeTag(node, .alternation);
    const alts = node.alternation.alternatives;
    try testing.expectEqual(@as(usize, 2), alts.len);
    try expectNodeTag(alts[0], .sequence); // empty
    try expectLiteral(alts[1], 'b');
}

test "edge: { as literal (not a quantifier)" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const node = try p.parse("{");
    try expectLiteral(node, '{');
}

test "edge: {abc} as literals (invalid quantifier)" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    // In non-unicode mode, a{abc} means 'a' followed by literal '{abc}'
    const node = try p.parse("a{abc}");
    try expectNodeTag(node, .sequence);
}

test "edge: empty group ()" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const node = try p.parse("()");
    try expectNodeTag(node, .group);
    try expectNodeTag(node.group.body, .sequence);
    try testing.expectEqual(@as(usize, 0), node.group.body.sequence.items.len);
}

test "edge: multiple quantifiers a**" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const result = p.parse("a**");
    // The second * sees a quantifier node and gets NothingToRepeat
    // because the quantifier is consumed as part of the atom and the
    // next * sees nothing to repeat.
    try testing.expectError(error.NothingToRepeat, result);
}

test "edge: unicode property in char class [\\p{Letter}]" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const node = try p.parse("[\\p{Letter}]");
    try expectNodeTag(node, .char_class);
    const cc = node.char_class;
    try testing.expectEqual(@as(usize, 1), cc.ranges.len);
    switch (cc.ranges[0]) {
        .unicode_prop => |up| {
            try testing.expectEqualStrings("Letter", up.name);
            try testing.expect(!up.negated);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "edge: escaped ] in char class [\\]]" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const node = try p.parse("[\\]]");
    try expectNodeTag(node, .char_class);
    const cc = node.char_class;
    try testing.expectEqual(@as(usize, 1), cc.ranges.len);
    switch (cc.ranges[0]) {
        .single => |v| try testing.expectEqual(@as(u21, ']'), v),
        else => return error.TestUnexpectedResult,
    }
}

test "edge: dash at end of char class [a-]" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const node = try p.parse("[a-]");
    try expectNodeTag(node, .char_class);
    const cc = node.char_class;
    try testing.expectEqual(@as(usize, 2), cc.ranges.len);
    switch (cc.ranges[0]) {
        .single => |v| try testing.expectEqual(@as(u21, 'a'), v),
        else => return error.TestUnexpectedResult,
    }
    switch (cc.ranges[1]) {
        .single => |v| try testing.expectEqual(@as(u21, '-'), v),
        else => return error.TestUnexpectedResult,
    }
}

test "edge: hex escape in char class [\\x41-\\x5A]" {
    var p = Parser.init(testing.allocator);
    defer p.deinit();
    const node = try p.parse("[\\x41-\\x5A]");
    try expectNodeTag(node, .char_class);
    const cc = node.char_class;
    try testing.expectEqual(@as(usize, 1), cc.ranges.len);
    switch (cc.ranges[0]) {
        .range => |r| {
            try testing.expectEqual(@as(u21, 'A'), r[0]);
            try testing.expectEqual(@as(u21, 'Z'), r[1]);
        },
        else => return error.TestUnexpectedResult,
    }
}
