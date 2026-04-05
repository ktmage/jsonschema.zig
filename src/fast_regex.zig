const std = @import("std");

/// Fast pattern matcher for common JSON Schema regex patterns.
/// Compiles anchored patterns (^...$) into a sequence of match operations
/// that execute in O(n) without NFA state tracking.
///
/// Handles: literal chars, [class], [^class], \d, \w, \s, ., {n}, {n,m}, +, *, ?
/// Does NOT handle: alternation (|), backreferences, lookahead/lookbehind
pub const FastRegex = struct {
    ops: []const Op,
    fixed_width: u16 = 0,
    min_width: u16 = 0,
    max_width: u16 = 0,

    const Op = struct {
        /// 128-bit bitmap: all matching characters have their bit set.
        low: u64,
        high: u64,
        min: u16 = 1,
        max: u16 = 1, // 0 = unlimited
        /// If this op matches exactly one character, store it for optimization
        literal_char: u8 = 0,
        is_literal: bool = false,

        fn matchChar(self: Op, ch: u8) bool {
            if (ch >= 128) return false;
            if (ch < 64) return (self.low >> @as(u6, @intCast(ch))) & 1 != 0;
            return (self.high >> @as(u6, @intCast(ch - 64))) & 1 != 0;
        }
    };

    // Legacy type aliases for backwards compatibility in parsing
    const Kind = union(enum) { literal: u8, char_class: CharClass, dot };

    const CharClass = struct {
        low: u64 = 0,
        high: u64 = 0,
        negated: bool = false,

        fn contains(self: CharClass, ch: u8) bool {
            if (ch >= 128) return self.negated;
            const bit = if (ch < 64)
                (self.low >> @as(u6, @intCast(ch))) & 1 != 0
            else
                (self.high >> @as(u6, @intCast(ch - 64))) & 1 != 0;
            return if (self.negated) !bit else bit;
        }
    };

    /// Compile a regex pattern into fast match operations.
    /// Returns null if the pattern uses features not supported (alternation, etc.)
    pub fn compile(pattern: []const u8, alloc: std.mem.Allocator) ?FastRegex {
        // Must be anchored: ^...$
        if (pattern.len < 2) return null;
        const has_start = pattern[0] == '^';
        const has_end = pattern[pattern.len - 1] == '$';
        if (!has_start or !has_end) return null;

        const inner = pattern[1 .. pattern.len - 1];
        var ops = std.ArrayList(Op).init(alloc);
        var i: usize = 0;

        while (i < inner.len) {
            const ch = inner[i];

            // Parse the match condition
            var kind: Kind = undefined;
            if (ch == '\\' and i + 1 < inner.len) {
                const esc = inner[i + 1];
                kind = switch (esc) {
                    'd' => .{ .char_class = digitClass() },
                    'w' => .{ .char_class = wordClass() },
                    's' => .{ .char_class = spaceClass() },
                    '.' => .{ .literal = '.' },
                    '\\' => .{ .literal = '\\' },
                    '$' => .{ .literal = '$' },
                    '{' => .{ .literal = '{' },
                    '}' => .{ .literal = '}' },
                    '(' => .{ .literal = '(' },
                    ')' => .{ .literal = ')' },
                    '[' => .{ .literal = '[' },
                    ']' => .{ .literal = ']' },
                    '+' => .{ .literal = '+' },
                    '*' => .{ .literal = '*' },
                    '?' => .{ .literal = '?' },
                    '|' => .{ .literal = '|' },
                    '^' => .{ .literal = '^' },
                    else => return null, // unsupported escape
                };
                i += 2;
            } else if (ch == '[') {
                // Character class
                const cc = parseCharClass(inner, &i) orelse return null;
                kind = .{ .char_class = cc };
            } else if (ch == '.') {
                kind = .dot;
                i += 1;
            } else if (ch == '(') {
                // Find matching ')' — only support non-alternation groups
                var depth: usize = 1;
                var j = i + 1;
                while (j < inner.len and depth > 0) : (j += 1) {
                    if (inner[j] == '(') depth += 1
                    else if (inner[j] == ')') depth -= 1;
                }
                if (depth != 0) return null;
                const group_content = inner[i + 1 .. j - 1];
                // Check for alternation — not supported
                for (group_content) |gc| { if (gc == '|') return null; }
                // Recursively compile group content
                const sub_regex = FastRegex.compile(
                    std.fmt.allocPrint(alloc, "^{s}$", .{group_content}) catch return null,
                    alloc,
                ) orelse return null;
                // Add all sub-ops
                for (sub_regex.ops) |sub_op| ops.append(sub_op) catch return null;
                i = j; // past ')'
                // Parse quantifier on the group
                if (i < inner.len) {
                    switch (inner[i]) {
                        '?' => {
                            // Make all sub-ops optional (min=0)
                            // Simple case: set first op min=0 (only works for single-op groups)
                            if (sub_regex.ops.len > 0) {
                                const last_idx = ops.items.len - sub_regex.ops.len;
                                for (ops.items[last_idx..]) |*sop| sop.min = 0;
                            }
                            i += 1;
                        },
                        else => {},
                    }
                }
                continue; // skip the kind/quantifier parsing below
            } else if (ch == '|') {
                return null; // alternation not supported
            } else if (ch == ')') {
                return null;
            } else {
                kind = .{ .literal = ch };
                i += 1;
            }

            // Parse quantifier
            var min: u16 = 1;
            var max: u16 = 1;
            if (i < inner.len) {
                switch (inner[i]) {
                    '*' => { min = 0; max = 0; i += 1; },
                    '+' => { min = 1; max = 0; i += 1; },
                    '?' => { min = 0; max = 1; i += 1; },
                    '{' => {
                        const q = parseQuantifier(inner, &i) orelse return null;
                        min = q.min;
                        max = q.max;
                    },
                    else => {},
                }
            }

            // Convert Kind to unified bitmap Op
            var op_low: u64 = 0;
            var op_high: u64 = 0;
            switch (kind) {
                .literal => |lit| {
                    if (lit < 64) op_low = @as(u64, 1) << @as(u6, @intCast(lit))
                    else if (lit < 128) op_high = @as(u64, 1) << @as(u6, @intCast(lit - 64));
                },
                .char_class => |cc| {
                    if (cc.negated) {
                        // Set all ASCII bits, then clear the specified ones
                        op_low = ~cc.low;
                        op_high = ~cc.high;
                        // Clear newline (0x0a) for compatibility
                        op_low &= ~(@as(u64, 1) << 10);
                    } else {
                        op_low = cc.low;
                        op_high = cc.high;
                    }
                },
                .dot => {
                    // Match any char except newline
                    op_low = ~(@as(u64, 1) << 10); // all bits except \n
                    op_high = ~@as(u64, 0);
                },
            }
            const is_lit = (kind == .literal);
            const lit_ch: u8 = if (kind == .literal) kind.literal else 0;
            ops.append(.{ .low = op_low, .high = op_high, .min = min, .max = max, .literal_char = lit_ch, .is_literal = is_lit }) catch return null;
        }

        const final_ops = ops.toOwnedSlice() catch return null;
        var fw: u16 = 0;
        var min_w: u16 = 0;
        var max_w: u16 = 0;
        var is_fixed = true;
        var has_unlimited = false;
        for (final_ops) |op| {
            min_w += op.min;
            if (op.max == 0) { has_unlimited = true; } else { max_w += op.max; }
            if (op.min != op.max or op.max == 0) { is_fixed = false; } else { fw += op.min; }
        }
        return FastRegex{
            .ops = final_ops,
            .fixed_width = if (is_fixed) fw else 0,
            .min_width = min_w,
            .max_width = if (has_unlimited) 0 else max_w,
        };
    }

    /// Match the pattern against the full input string.
    pub fn matches(self: *const FastRegex, input: []const u8) bool {
        // Quick length check
        if (input.len < self.min_width) return false;
        if (self.max_width > 0 and input.len > self.max_width) return false;
        // Ultra-fast path: fixed-width patterns
        if (self.fixed_width > 0) {
            if (input.len != self.fixed_width) return false;
            var pos: usize = 0;
            for (self.ops) |op| {
                var count: u16 = 0;
                while (count < op.min) : (count += 1) {
                    if (!op.matchChar(input[pos])) return false;
                    pos += 1;
                }
            }
            return true;
        }
        return matchOps(self.ops, input, 0) != null;
    }

    /// Try to match ops against input.
    /// Uses optimized forward scan: for greedy+literal pairs, remember the last
    /// position where the literal could match to avoid backtracking entirely.
    fn matchOps(ops: []const Op, input: []const u8, start: usize) ?usize {
        // Try optimized single-pass first (no backtracking needed for most patterns)
        if (matchOpsOptimized(ops, input, start)) |end| return end;
        return matchOpsBacktrack(ops, input, start);
    }

    /// Optimized single-pass matcher. For each greedy op followed by a literal,
    /// track the last valid split position during the forward scan.
    fn matchOpsOptimized(ops: []const Op, input: []const u8, start: usize) ?usize {
        var pos = start;
        var oi: usize = 0;
        while (oi < ops.len) {
            const op = ops[oi];
            // Match minimum
            var count: u16 = 0;
            while (count < op.min) {
                if (pos >= input.len or !op.matchChar(input[pos])) return null;
                pos += 1;
                count += 1;
            }
            // Optimization: if next op is a literal, check if literal is IN the char class
            if (oi + 1 < ops.len and ops[oi + 1].is_literal and (op.max == 0 or op.max > op.min)) {
                const next_lit = ops[oi + 1].literal_char;
                const lit_in_class = op.matchChar(next_lit);
                if (!lit_in_class) {
                    // Literal NOT in class: greedy naturally stops at literal (no backtrack needed)
                    if (op.max == 0) {
                        while (pos < input.len and op.matchChar(input[pos])) pos += 1;
                    } else {
                        while (count < op.max and pos < input.len and op.matchChar(input[pos])) { pos += 1; count += 1; }
                    }
                } else {
                    // Literal IN class: greedy scan then reverse search for literal
                    const greedy_start = pos;
                    if (op.max == 0) {
                        while (pos < input.len and op.matchChar(input[pos])) pos += 1;
                    } else {
                        while (count < op.max and pos < input.len and op.matchChar(input[pos])) { pos += 1; count += 1; }
                    }
                    // Check if literal is right after greedy range
                    if (pos < input.len and input[pos] == next_lit) {
                        // Greedy stopped before literal — use it directly
                    } else {
                        // Reverse scan from end of greedy range to find last literal
                        var found = false;
                        while (pos > greedy_start) {
                            pos -= 1;
                            if (input[pos] == next_lit) { found = true; break; }
                        }
                        if (!found) return null;
                    }
                }
                oi += 1;
                continue;
            }
            // Standard greedy (no literal follows)
            if (op.max == 0) {
                while (pos < input.len and op.matchChar(input[pos])) pos += 1;
            } else {
                while (count < op.max and pos < input.len and op.matchChar(input[pos])) { pos += 1; count += 1; }
            }
            oi += 1;
        }
        return if (pos == input.len) pos else null;
    }

    /// Fallback with full backtracking for patterns not handled by optimized path.
    fn matchOpsBacktrack(ops: []const Op, input: []const u8, start: usize) ?usize {
        const BacktrackEntry = struct { op_idx: u16, pos: u16, greedy_start: u16 };
        var stack: [64]BacktrackEntry = undefined;
        var stack_len: usize = 0;
        var pos: usize = start;
        var oi: usize = 0;

        while (true) {
            // Forward phase: match ops greedily
            while (oi < ops.len) {
                const op = ops[oi];
                // Match minimum
                var ok = true;
                var count: u16 = 0;
                while (count < op.min) {
                    if (pos >= input.len or !op.matchChar(input[pos])) { ok = false; break; }
                    pos += 1;
                    count += 1;
                }
                if (!ok) break; // backtrack

                // Greedy: match maximum
                const greedy_start = pos;
                if (op.max == 0) {
                    while (pos < input.len and op.matchChar(input[pos])) pos += 1;
                } else {
                    while (count < op.max and pos < input.len and op.matchChar(input[pos])) { pos += 1; count += 1; }
                }

                // Push backtrack point if greedy consumed extra chars
                if (pos > greedy_start and oi + 1 < ops.len and stack_len < 64) {
                    stack[stack_len] = .{
                        .op_idx = @intCast(oi),
                        .pos = @intCast(pos - 1),
                        .greedy_start = @intCast(greedy_start),
                    };
                    stack_len += 1;
                }
                oi += 1;
            }

            // Check success
            if (oi >= ops.len and pos == input.len) return pos;

            // Backtrack
            if (stack_len == 0) return null;
            stack_len -= 1;
            const bt = stack[stack_len];
            pos = bt.pos;
            oi = bt.op_idx + 1;

            // Smart backtrack: if the next op is a literal, scan backward for it
            // This turns O(n) backtrack steps into O(1) for literal-after-greedy patterns
            if (oi < ops.len and ops[oi].is_literal and ops[oi].min >= 1) {
                const lit = ops[oi].literal_char;
                if (input[pos] != lit) {
                    // Current pos doesn't match literal — scan backward
                    var scan_pos = pos;
                    while (scan_pos > bt.greedy_start) {
                        scan_pos -= 1;
                        if (input[scan_pos] == lit) break;
                    } else {
                        // Literal not found in range — this backtrack point is exhausted
                        continue; // try next backtrack entry
                    }
                    // Found literal at scan_pos — update pos and push further backtrack
                    pos = scan_pos;
                    if (pos > bt.greedy_start and stack_len < 64) {
                        stack[stack_len] = .{
                            .op_idx = bt.op_idx,
                            .pos = @intCast(pos - 1),
                            .greedy_start = bt.greedy_start,
                        };
                        stack_len += 1;
                    }
                    continue; // retry with new pos
                }
            }

            // Standard backtrack: push one-less entry
            if (pos > bt.greedy_start and stack_len < 64) {
                stack[stack_len] = .{
                    .op_idx = bt.op_idx,
                    .pos = @intCast(pos - 1),
                    .greedy_start = bt.greedy_start,
                };
                stack_len += 1;
            }
        }
    }

    fn matchOne(kind: Kind, ch: u8) bool {
        return switch (kind) {
            .literal => |lit| ch == lit,
            .char_class => |cc| cc.contains(ch),
            .dot => ch != '\n',
        };
    }

    fn digitClass() CharClass {
        var cc = CharClass{};
        for ('0'..'9' + 1) |ch| {
            if (ch < 64) cc.low |= @as(u64, 1) << @as(u6, @intCast(ch))
            else cc.high |= @as(u64, 1) << @as(u6, @intCast(ch - 64));
        }
        return cc;
    }

    fn wordClass() CharClass {
        var cc = CharClass{};
        for ('a'..'z' + 1) |ch| { if (ch < 64) cc.low |= @as(u64, 1) << @as(u6, @intCast(ch)) else cc.high |= @as(u64, 1) << @as(u6, @intCast(ch - 64)); }
        for ('A'..'Z' + 1) |ch| { if (ch < 64) cc.low |= @as(u64, 1) << @as(u6, @intCast(ch)) else cc.high |= @as(u64, 1) << @as(u6, @intCast(ch - 64)); }
        for ('0'..'9' + 1) |ch| { if (ch < 64) cc.low |= @as(u64, 1) << @as(u6, @intCast(ch)) else cc.high |= @as(u64, 1) << @as(u6, @intCast(ch - 64)); }
        cc.high |= @as(u64, 1) << @as(u6, @intCast('_' - 64));
        return cc;
    }

    fn spaceClass() CharClass {
        var cc = CharClass{};
        cc.low |= @as(u64, 1) << ' ';
        cc.low |= @as(u64, 1) << '\t';
        cc.low |= @as(u64, 1) << '\n';
        cc.low |= @as(u64, 1) << '\r';
        return cc;
    }

    fn parseCharClass(pattern: []const u8, pos: *usize) ?CharClass {
        var i = pos.* + 1; // skip '['
        var cc = CharClass{};
        if (i < pattern.len and pattern[i] == '^') {
            cc.negated = true;
            i += 1;
        }
        // Allow ] as first char in class
        if (i < pattern.len and pattern[i] == ']') {
            setBit(&cc, ']');
            i += 1;
        }
        while (i < pattern.len and pattern[i] != ']') {
            if (pattern[i] == '\\' and i + 1 < pattern.len) {
                switch (pattern[i + 1]) {
                    'd' => { const d = digitClass(); cc.low |= d.low; cc.high |= d.high; i += 2; },
                    'w' => { const w = wordClass(); cc.low |= w.low; cc.high |= w.high; i += 2; },
                    's' => { const s = spaceClass(); cc.low |= s.low; cc.high |= s.high; i += 2; },
                    else => |esc| { setBit(&cc, esc); i += 2; },
                }
            } else if (i + 2 < pattern.len and pattern[i + 1] == '-' and pattern[i + 2] != ']') {
                const start = pattern[i];
                const end = pattern[i + 2];
                if (start <= end) {
                    var c_val: u8 = start;
                    while (c_val <= end) : (c_val += 1) setBit(&cc, c_val);
                }
                i += 3;
            } else {
                setBit(&cc, pattern[i]);
                i += 1;
            }
        }
        if (i >= pattern.len) return null; // unclosed [
        pos.* = i + 1; // skip ']'
        return cc;
    }

    fn setBit(cc: *CharClass, ch: u8) void {
        if (ch >= 128) return;
        if (ch < 64) cc.low |= @as(u64, 1) << @as(u6, @intCast(ch))
        else cc.high |= @as(u64, 1) << @as(u6, @intCast(ch - 64));
    }

    fn parseQuantifier(pattern: []const u8, pos: *usize) ?struct { min: u16, max: u16 } {
        var i = pos.* + 1; // skip '{'
        var min_val: u16 = 0;
        while (i < pattern.len and pattern[i] >= '0' and pattern[i] <= '9') {
            min_val = min_val * 10 + @as(u16, pattern[i] - '0');
            i += 1;
        }
        if (i >= pattern.len) return null;
        if (pattern[i] == '}') {
            pos.* = i + 1;
            return .{ .min = min_val, .max = min_val };
        }
        if (pattern[i] != ',') return null;
        i += 1;
        if (i < pattern.len and pattern[i] == '}') {
            pos.* = i + 1;
            return .{ .min = min_val, .max = 0 }; // unbounded
        }
        var max_val: u16 = 0;
        while (i < pattern.len and pattern[i] >= '0' and pattern[i] <= '9') {
            max_val = max_val * 10 + @as(u16, pattern[i] - '0');
            i += 1;
        }
        if (i >= pattern.len or pattern[i] != '}') return null;
        pos.* = i + 1;
        return .{ .min = min_val, .max = max_val };
    }

    pub fn deinit(self: *FastRegex, alloc: std.mem.Allocator) void {
        alloc.free(self.ops);
    }
};

test "date pattern" {
    const r = FastRegex.compile("^\\d{4}-\\d{2}-\\d{2}$", std.testing.allocator).?;
    defer @constCast(&r).deinit(std.testing.allocator);
    try std.testing.expect(r.matches("2024-06-15"));
    try std.testing.expect(!r.matches("24-6-15"));
    try std.testing.expect(!r.matches("2024-06-155"));
}

test "email pattern" {
    const r = FastRegex.compile("^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$", std.testing.allocator).?;
    defer @constCast(&r).deinit(std.testing.allocator);
    try std.testing.expect(r.matches("user@example.com"));
    try std.testing.expect(!r.matches("invalid"));
}

test "uuid pattern" {
    const r = FastRegex.compile("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", std.testing.allocator).?;
    defer @constCast(&r).deinit(std.testing.allocator);
    try std.testing.expect(r.matches("deadbeef-1234-5678-abcd-0123456789ab"));
    try std.testing.expect(!r.matches("not-a-uuid"));
}

test "prefix pattern" {
    const r = FastRegex.compile("^str_[a-z]+$", std.testing.allocator).?;
    defer @constCast(&r).deinit(std.testing.allocator);
    try std.testing.expect(r.matches("str_hello"));
    try std.testing.expect(!r.matches("str_"));
    try std.testing.expect(!r.matches("STR_hello"));
}

test "uppercase pattern" {
    const r = FastRegex.compile("^[A-Z][A-Z_]+$", std.testing.allocator).?;
    defer @constCast(&r).deinit(std.testing.allocator);
    try std.testing.expect(r.matches("MAX_RETRY"));
    try std.testing.expect(!r.matches("max_retry"));
}

test "returns null for alternation" {
    try std.testing.expect(FastRegex.compile("^(a|b)$", std.testing.allocator) == null);
}

test "ip pattern" {
    const r = FastRegex.compile("^\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}$", std.testing.allocator).?;
    defer @constCast(&r).deinit(std.testing.allocator);
    try std.testing.expect(r.matches("192.168.1.1"));
    try std.testing.expect(r.matches("0.0.0.0"));
    try std.testing.expect(!r.matches("1234.0.0.0"));
}
