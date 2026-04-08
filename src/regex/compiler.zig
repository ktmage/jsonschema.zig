const std = @import("std");
const parser = @import("parser.zig");

/// Nondeterministic Finite Automaton produced by compiling a regex AST.
pub const NFA = struct {
    states: []State,
    start: u32,
    num_captures: u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *NFA) void {
        for (self.states) |*state| {
            if (state.sub_nfa) |sub| {
                sub.deinit();
                self.allocator.destroy(sub);
            }
            self.allocator.free(state.transitions);
        }
        self.allocator.free(self.states);
    }
};

/// A single NFA state.
pub const State = struct {
    transitions: []Transition = &.{},
    kind: Kind = .normal,
    capture_id: u32 = 0,
    sub_nfa: ?*NFA = null,

    pub const Kind = enum {
        normal,
        match,
        capture_start,
        capture_end,
        assert_lookahead,
        assert_neg_lookahead,
        assert_lookbehind,
        assert_neg_lookbehind,
    };
};

/// A transition from one NFA state to another.
pub const Transition = struct {
    target: u32,
    condition: Condition,
};

/// The condition on an NFA transition.
pub const Condition = union(enum) {
    epsilon,
    char: u21,
    char_range: [2]u21,
    char_class: *const parser.CharClass,
    dot,
    word_boundary,
    non_word_boundary,
    back_ref: u32,
    named_back_ref: []const u8,
};

/// An NFA fragment: a sub-graph with a single start state and single end state.
/// Used internally during Thompson's construction.
const Fragment = struct {
    start: u32,
    end: u32,
};

/// Compile a parsed regex AST into an NFA using Thompson's construction.
pub fn compile(allocator: std.mem.Allocator, ast: *const parser.Node) !NFA {
    var builder = Builder.init(allocator);
    errdefer builder.deinit();

    const frag = try builder.compileNode(ast);

    // If the end state already has a special kind (e.g., capture_end), add a
    // new match state and connect to it via epsilon so we don't clobber it.
    var end_id = frag.end;
    if (builder.states.items[end_id].kind != .normal) {
        const match_state = try builder.addState();
        try builder.addEpsilon(end_id, match_state);
        end_id = match_state;
    }
    builder.states.items[end_id].kind = .match;

    return .{
        .states = try builder.states.toOwnedSlice(),
        .start = frag.start,
        .num_captures = builder.capture_count,
        .allocator = allocator,
    };
}

const CompileError = error{OutOfMemory};

/// Builder accumulates NFA states during compilation.
const Builder = struct {
    states: std.ArrayList(State),
    allocator: std.mem.Allocator,
    capture_count: u32 = 0,

    fn init(allocator: std.mem.Allocator) Builder {
        return .{
            .states = std.ArrayList(State).init(allocator),
            .allocator = allocator,
        };
    }

    fn deinit(self: *Builder) void {
        for (self.states.items) |*state| {
            if (state.sub_nfa) |sub| {
                sub.deinit();
                self.allocator.destroy(sub);
            }
            self.allocator.free(state.transitions);
        }
        self.states.deinit();
    }

    /// Allocate a new state and return its index.
    fn addState(self: *Builder) !u32 {
        const id: u32 = @intCast(self.states.items.len);
        try self.states.append(.{});
        return id;
    }

    /// Allocate a new state with the given kind and return its index.
    fn addStateKind(self: *Builder, kind: State.Kind) !u32 {
        const id: u32 = @intCast(self.states.items.len);
        try self.states.append(.{ .kind = kind });
        return id;
    }

    /// Add a transition from `from` to `to` with the given condition.
    fn addTransition(self: *Builder, from: u32, target: u32, condition: Condition) !void {
        const state = &self.states.items[from];
        const old_len = state.transitions.len;
        const new_trans = try self.allocator.alloc(Transition, old_len + 1);
        if (old_len > 0) {
            @memcpy(new_trans[0..old_len], state.transitions);
            self.allocator.free(state.transitions);
        }
        new_trans[old_len] = .{ .target = target, .condition = condition };
        state.transitions = new_trans;
    }

    /// Add an epsilon transition from `from` to `to`.
    fn addEpsilon(self: *Builder, from: u32, to: u32) !void {
        try self.addTransition(from, to, .epsilon);
    }

    // ---------------------------------------------------------------
    // Thompson's construction: compile AST node → NFA fragment
    // ---------------------------------------------------------------

    fn compileNode(self: *Builder, node: *const parser.Node) CompileError!Fragment {
        return switch (node.*) {
            .literal => |cp| try self.compileLiteral(cp),
            .dot => try self.compileDot(),
            .char_class => |cc| try self.compileCharClass(cc),
            .sequence => |seq| try self.compileSequence(seq),
            .alternation => |alt| try self.compileAlternation(alt),
            .quantifier => |q| try self.compileQuantifier(q),
            .group => |g| try self.compileGroup(g),
            .back_ref => |ref_id| try self.compileBackRef(ref_id),
            .named_back_ref => |name| try self.compileNamedBackRef(name),
            .anchor_start, .anchor_end => try self.compileAnchor(node),
            .word_boundary => try self.compileWordBoundary(),
            .non_word_boundary => try self.compileNonWordBoundary(),
        };
    }

    // -- Literal --

    fn compileLiteral(self: *Builder, cp: u21) CompileError!Fragment {
        const start = try self.addState();
        const end = try self.addState();
        try self.addTransition(start, end, .{ .char = cp });
        return .{ .start = start, .end = end };
    }

    // -- Dot --

    fn compileDot(self: *Builder) CompileError!Fragment {
        const start = try self.addState();
        const end = try self.addState();
        try self.addTransition(start, end, .dot);
        return .{ .start = start, .end = end };
    }

    // -- Character class --

    fn compileCharClass(self: *Builder, cc: *const parser.CharClass) CompileError!Fragment {
        const start = try self.addState();
        const end = try self.addState();
        try self.addTransition(start, end, .{ .char_class = cc });
        return .{ .start = start, .end = end };
    }

    // -- Sequence (concatenation) --

    fn compileSequence(self: *Builder, seq: *const parser.Sequence) CompileError!Fragment {
        if (seq.items.len == 0) {
            // Empty sequence: just two states with epsilon.
            const start = try self.addState();
            const end = try self.addState();
            try self.addEpsilon(start, end);
            return .{ .start = start, .end = end };
        }

        var result = try self.compileNode(seq.items[0]);
        for (seq.items[1..]) |item| {
            const next = try self.compileNode(item);
            // Chain: connect result.end -> next.start via epsilon.
            try self.addEpsilon(result.end, next.start);
            result.end = next.end;
        }
        return result;
    }

    // -- Alternation --

    fn compileAlternation(self: *Builder, alt: *const parser.Alternation) CompileError!Fragment {
        const start = try self.addState();
        const end = try self.addState();

        for (alt.alternatives) |alternative| {
            const frag = try self.compileNode(alternative);
            try self.addEpsilon(start, frag.start);
            try self.addEpsilon(frag.end, end);
        }

        return .{ .start = start, .end = end };
    }

    // -- Quantifier --

    fn compileQuantifier(self: *Builder, q: *const parser.Quantified) CompileError!Fragment {
        const min = q.min;
        const max = q.max;

        // Special cases for common quantifiers to produce cleaner NFAs.

        if (min == 0 and max == null) {
            // * (star): zero or more
            return self.compileStar(q.body, q.greedy);
        }
        if (min == 1 and max == null) {
            // + (plus): one or more
            return self.compilePlus(q.body, q.greedy);
        }
        if (min == 0 and max != null and max.? == 1) {
            // ? (optional): zero or one
            return self.compileOptional(q.body, q.greedy);
        }

        // General {n,m} quantifier: unroll.
        return self.compileGeneral(q.body, min, max, q.greedy);
    }

    /// Compile `body*` (zero or more, greedy or lazy).
    fn compileStar(self: *Builder, body: *const parser.Node, greedy: bool) CompileError!Fragment {
        const start = try self.addState();
        const end = try self.addState();
        const body_frag = try self.compileNode(body);

        if (greedy) {
            // Greedy: prefer body, then skip.
            try self.addEpsilon(start, body_frag.start);
            try self.addEpsilon(start, end);
        } else {
            // Lazy: prefer skip, then body.
            try self.addEpsilon(start, end);
            try self.addEpsilon(start, body_frag.start);
        }

        // Loop back from body end to start.
        try self.addEpsilon(body_frag.end, start);

        return .{ .start = start, .end = end };
    }

    /// Compile `body+` (one or more, greedy or lazy).
    fn compilePlus(self: *Builder, body: *const parser.Node, greedy: bool) CompileError!Fragment {
        const start = try self.addState();
        const end = try self.addState();
        const body_frag = try self.compileNode(body);

        // Must match body at least once.
        try self.addEpsilon(start, body_frag.start);

        if (greedy) {
            // Greedy: prefer looping, then accept.
            try self.addEpsilon(body_frag.end, body_frag.start);
            try self.addEpsilon(body_frag.end, end);
        } else {
            // Lazy: prefer accepting, then loop.
            try self.addEpsilon(body_frag.end, end);
            try self.addEpsilon(body_frag.end, body_frag.start);
        }

        return .{ .start = start, .end = end };
    }

    /// Compile `body?` (zero or one, greedy or lazy).
    fn compileOptional(self: *Builder, body: *const parser.Node, greedy: bool) CompileError!Fragment {
        const start = try self.addState();
        const end = try self.addState();
        const body_frag = try self.compileNode(body);

        if (greedy) {
            // Greedy: prefer body, then skip.
            try self.addEpsilon(start, body_frag.start);
            try self.addEpsilon(start, end);
        } else {
            // Lazy: prefer skip, then body.
            try self.addEpsilon(start, end);
            try self.addEpsilon(start, body_frag.start);
        }

        try self.addEpsilon(body_frag.end, end);

        return .{ .start = start, .end = end };
    }

    /// Compile `body{min,max}` via unrolling.
    fn compileGeneral(
        self: *Builder,
        body: *const parser.Node,
        min: u32,
        max: ?u32,
        greedy: bool,
    ) CompileError!Fragment {
        // Strategy: chain `min` required copies, then either:
        //   - unlimited (max == null): attach a star at the end
        //   - limited: attach (max - min) optional copies

        if (min == 0 and max != null and max.? == 0) {
            // {0,0}: match nothing, just epsilon.
            const start = try self.addState();
            const end = try self.addState();
            try self.addEpsilon(start, end);
            return .{ .start = start, .end = end };
        }

        // Compile the required copies.
        var result: ?Fragment = null;
        for (0..min) |_| {
            const copy = try self.compileNode(body);
            if (result) |*r| {
                try self.addEpsilon(r.end, copy.start);
                r.end = copy.end;
            } else {
                result = copy;
            }
        }

        if (max == null) {
            // {n,}: n required copies then a star.
            const star = try self.compileStar(body, greedy);
            if (result) |*r| {
                try self.addEpsilon(r.end, star.start);
                r.end = star.end;
            } else {
                result = star;
            }
        } else {
            // {n,m}: n required, (m-n) optional copies.
            const optional_count = max.? - min;
            for (0..optional_count) |_| {
                const opt = try self.compileOptional(body, greedy);
                if (result) |*r| {
                    try self.addEpsilon(r.end, opt.start);
                    r.end = opt.end;
                } else {
                    result = opt;
                }
            }
        }

        // If both min=0 and max=0, we handled it above.
        // If we still have no result (shouldn't happen), produce epsilon.
        if (result) |r| {
            return r;
        }

        const start = try self.addState();
        const end = try self.addState();
        try self.addEpsilon(start, end);
        return .{ .start = start, .end = end };
    }

    // -- Group --

    fn compileGroup(self: *Builder, g: *const parser.Group) CompileError!Fragment {
        switch (g.kind) {
            .capture => {
                self.capture_count += 1;
                const cap_id = self.capture_count;

                const cap_start = try self.addState();
                self.states.items[cap_start].kind = .capture_start;
                self.states.items[cap_start].capture_id = cap_id;

                const body_frag = try self.compileNode(g.body);

                const cap_end = try self.addState();
                self.states.items[cap_end].kind = .capture_end;
                self.states.items[cap_end].capture_id = cap_id;

                try self.addEpsilon(cap_start, body_frag.start);
                try self.addEpsilon(body_frag.end, cap_end);

                return .{ .start = cap_start, .end = cap_end };
            },
            .non_capture => {
                return self.compileNode(g.body);
            },
            .lookahead => {
                return self.compileAssertion(g, .assert_lookahead);
            },
            .neg_lookahead => {
                return self.compileAssertion(g, .assert_neg_lookahead);
            },
            .lookbehind => {
                return self.compileAssertion(g, .assert_lookbehind);
            },
            .neg_lookbehind => {
                return self.compileAssertion(g, .assert_neg_lookbehind);
            },
        }
    }

    /// Compile a lookahead/lookbehind assertion into a state with a sub-NFA.
    fn compileAssertion(self: *Builder, g: *const parser.Group, kind: State.Kind) CompileError!Fragment {
        // Compile the assertion body into a separate NFA.
        var sub_builder = Builder.init(self.allocator);
        errdefer sub_builder.deinit();

        const sub_frag = try sub_builder.compileNode(g.body);
        sub_builder.states.items[sub_frag.end].kind = .match;

        const sub_nfa = try self.allocator.create(NFA);
        sub_nfa.* = .{
            .states = try sub_builder.states.toOwnedSlice(),
            .start = sub_frag.start,
            .num_captures = sub_builder.capture_count,
            .allocator = self.allocator,
        };

        // Create the assertion state in the main NFA.
        const assert_state = try self.addState();
        self.states.items[assert_state].kind = kind;
        self.states.items[assert_state].sub_nfa = sub_nfa;

        const end = try self.addState();
        try self.addEpsilon(assert_state, end);

        return .{ .start = assert_state, .end = end };
    }

    // -- Back references --

    fn compileBackRef(self: *Builder, ref_id: u32) CompileError!Fragment {
        const start = try self.addState();
        const end = try self.addState();
        try self.addTransition(start, end, .{ .back_ref = ref_id });
        return .{ .start = start, .end = end };
    }

    fn compileNamedBackRef(self: *Builder, name: []const u8) CompileError!Fragment {
        const start = try self.addState();
        const end = try self.addState();
        try self.addTransition(start, end, .{ .named_back_ref = name });
        return .{ .start = start, .end = end };
    }

    // -- Anchors --
    // Anchors are zero-width assertions. We represent them as epsilon
    // transitions; the matcher will interpret anchor states specially.
    // For the NFA, they just pass through.

    fn compileAnchor(self: *Builder, node: *const parser.Node) CompileError!Fragment {
        _ = node;
        const start = try self.addState();
        const end = try self.addState();
        try self.addEpsilon(start, end);
        return .{ .start = start, .end = end };
    }

    // -- Word boundary --

    fn compileWordBoundary(self: *Builder) CompileError!Fragment {
        const start = try self.addState();
        const end = try self.addState();
        try self.addTransition(start, end, .word_boundary);
        return .{ .start = start, .end = end };
    }

    fn compileNonWordBoundary(self: *Builder) CompileError!Fragment {
        const start = try self.addState();
        const end = try self.addState();
        try self.addTransition(start, end, .non_word_boundary);
        return .{ .start = start, .end = end };
    }
};

// ===================================================================
// Tests
// ===================================================================

const testing = std.testing;

/// Helper: parse a pattern and compile it, returning the NFA.
fn testCompile(pattern: []const u8) !struct { nfa: NFA, p: parser.Parser } {
    var p = parser.Parser.init(testing.allocator);
    const ast = p.parse(pattern) catch |e| {
        p.deinit();
        return e;
    };
    var nfa = compile(testing.allocator, ast) catch |e| {
        p.deinit();
        return e;
    };
    _ = &nfa;
    return .{ .nfa = nfa, .p = p };
}

fn countTransitionsWithCondition(nfa: *const NFA, comptime tag: std.meta.Tag(Condition)) u32 {
    var count: u32 = 0;
    for (nfa.states) |state| {
        for (state.transitions) |t| {
            if (std.meta.activeTag(t.condition) == tag) {
                count += 1;
            }
        }
    }
    return count;
}

fn countEpsilons(nfa: *const NFA) u32 {
    return countTransitionsWithCondition(nfa, .epsilon);
}

fn countStatesByKind(nfa: *const NFA, kind: State.Kind) u32 {
    var count: u32 = 0;
    for (nfa.states) |state| {
        if (state.kind == kind) {
            count += 1;
        }
    }
    return count;
}

// ---------------------------------------------------------------
// Test: Simple literal "abc"
// ---------------------------------------------------------------

test "compile literal 'abc'" {
    // "abc" is a sequence of 3 literals.
    // Each literal produces 2 states (start + end) with a char transition.
    // The sequence chains them with epsilons.
    // Total: 6 states from 3 literals, end state is match.
    var result = try testCompile("abc");
    defer result.nfa.deinit();
    defer result.p.deinit();

    const nfa = &result.nfa;

    // Should have 3 char transitions for 'a', 'b', 'c'.
    try testing.expectEqual(@as(u32, 3), countTransitionsWithCondition(nfa, .char));

    // Exactly 1 match state.
    try testing.expectEqual(@as(u32, 1), countStatesByKind(nfa, .match));

    // Verify the char transitions are a, b, c in order.
    // Walk from the start state.
    var current = nfa.start;
    const expected_chars = [_]u21{ 'a', 'b', 'c' };
    for (expected_chars) |expected_ch| {
        // Current state should have a char transition.
        var found = false;
        for (nfa.states[current].transitions) |t| {
            if (t.condition == .char and t.condition.char == expected_ch) {
                current = t.target;
                found = true;
                break;
            }
        }
        if (!found) {
            // May need to follow epsilons first (sequence chaining).
            for (nfa.states[current].transitions) |t| {
                if (t.condition == .epsilon) {
                    // Follow epsilon, then look for char.
                    for (nfa.states[t.target].transitions) |t2| {
                        if (t2.condition == .char and t2.condition.char == expected_ch) {
                            current = t2.target;
                            found = true;
                            break;
                        }
                    }
                    if (found) break;
                }
            }
        }
        try testing.expect(found);
    }

    // current should now be the match state.
    // It might be the match directly, or reachable via epsilon.
    var is_match = nfa.states[current].kind == .match;
    if (!is_match) {
        // Follow epsilons to find match.
        for (nfa.states[current].transitions) |t| {
            if (t.condition == .epsilon and nfa.states[t.target].kind == .match) {
                is_match = true;
                break;
            }
        }
    }
    try testing.expect(is_match);
}

// ---------------------------------------------------------------
// Test: Alternation "a|b"
// ---------------------------------------------------------------

test "compile alternation 'a|b'" {
    var result = try testCompile("a|b");
    defer result.nfa.deinit();
    defer result.p.deinit();

    const nfa = &result.nfa;

    // Alternation: new start with epsilon to each branch, each branch end epsilon to new end.
    // 'a': 2 states, 'b': 2 states, alt start + alt end = 2. Total = 6 states.
    try testing.expectEqual(@as(usize, 6), nfa.states.len);

    // 2 char transitions (one for 'a', one for 'b').
    try testing.expectEqual(@as(u32, 2), countTransitionsWithCondition(nfa, .char));

    // The start state should have 2 epsilon transitions (to 'a' branch and 'b' branch).
    try testing.expectEqual(@as(usize, 2), nfa.states[nfa.start].transitions.len);
    for (nfa.states[nfa.start].transitions) |t| {
        try testing.expectEqual(Condition.epsilon, t.condition);
    }

    // 1 match state.
    try testing.expectEqual(@as(u32, 1), countStatesByKind(nfa, .match));
}

// ---------------------------------------------------------------
// Test: Star "a*"
// ---------------------------------------------------------------

test "compile star 'a*'" {
    var result = try testCompile("a*");
    defer result.nfa.deinit();
    defer result.p.deinit();

    const nfa = &result.nfa;

    // a*: star_start, star_end, body_start, body_end = 4 states.
    try testing.expectEqual(@as(usize, 4), nfa.states.len);

    // 1 char transition for 'a'.
    try testing.expectEqual(@as(u32, 1), countTransitionsWithCondition(nfa, .char));

    // The start state should have 2 epsilon transitions:
    // greedy: [to body_start, to end].
    try testing.expectEqual(@as(usize, 2), nfa.states[nfa.start].transitions.len);

    // 1 match state.
    try testing.expectEqual(@as(u32, 1), countStatesByKind(nfa, .match));

    // There should be a loop back: body_end has epsilon to start.
    var has_loop = false;
    for (nfa.states) |state| {
        for (state.transitions) |t| {
            if (t.condition == .epsilon and t.target == nfa.start) {
                has_loop = true;
            }
        }
    }
    try testing.expect(has_loop);
}

// ---------------------------------------------------------------
// Test: Capture group "(a)"
// ---------------------------------------------------------------

test "compile capture group '(a)'" {
    var result = try testCompile("(a)");
    defer result.nfa.deinit();
    defer result.p.deinit();

    const nfa = &result.nfa;

    // (a): capture_start + body(2 states) + capture_end + match = 5 states.
    try testing.expectEqual(@as(usize, 5), nfa.states.len);

    // 1 capture group.
    try testing.expectEqual(@as(u32, 1), nfa.num_captures);

    // 1 capture_start state and 1 capture_end state.
    try testing.expectEqual(@as(u32, 1), countStatesByKind(nfa, .capture_start));
    try testing.expectEqual(@as(u32, 1), countStatesByKind(nfa, .capture_end));

    // The capture_start state should be the start.
    try testing.expectEqual(State.Kind.capture_start, nfa.states[nfa.start].kind);
    try testing.expectEqual(@as(u32, 1), nfa.states[nfa.start].capture_id);

    // 1 char transition for 'a'.
    try testing.expectEqual(@as(u32, 1), countTransitionsWithCondition(nfa, .char));
}

// ---------------------------------------------------------------
// Test: Lookahead "(?=a)b" (sequence of lookahead + literal)
// ---------------------------------------------------------------

test "compile lookahead '(?=a)b'" {
    var result = try testCompile("(?=a)b");
    defer result.nfa.deinit();
    defer result.p.deinit();

    const nfa = &result.nfa;

    // Should have at least one assert_lookahead state.
    try testing.expectEqual(@as(u32, 1), countStatesByKind(nfa, .assert_lookahead));

    // The assert_lookahead state should have a sub-NFA.
    var found_assertion = false;
    for (nfa.states) |state| {
        if (state.kind == .assert_lookahead) {
            try testing.expect(state.sub_nfa != null);
            const sub = state.sub_nfa.?;
            // Sub-NFA should have at least a char transition for 'a'.
            var sub_has_char = false;
            for (sub.states) |sub_state| {
                for (sub_state.transitions) |t| {
                    if (t.condition == .char and t.condition.char == 'a') {
                        sub_has_char = true;
                    }
                }
            }
            try testing.expect(sub_has_char);
            found_assertion = true;
        }
    }
    try testing.expect(found_assertion);

    // Main NFA should have a char transition for 'b'.
    var has_b = false;
    for (nfa.states) |state| {
        for (state.transitions) |t| {
            if (t.condition == .char and t.condition.char == 'b') {
                has_b = true;
            }
        }
    }
    try testing.expect(has_b);

    // 1 match state.
    try testing.expectEqual(@as(u32, 1), countStatesByKind(nfa, .match));
}

// ---------------------------------------------------------------
// Test: Plus "a+"
// ---------------------------------------------------------------

test "compile plus 'a+'" {
    var result = try testCompile("a+");
    defer result.nfa.deinit();
    defer result.p.deinit();

    const nfa = &result.nfa;

    // a+: plus_start, plus_end, body_start, body_end = 4 states.
    try testing.expectEqual(@as(usize, 4), nfa.states.len);

    // 1 char transition for 'a'.
    try testing.expectEqual(@as(u32, 1), countTransitionsWithCondition(nfa, .char));

    // start has epsilon to body_start.
    try testing.expectEqual(@as(usize, 1), nfa.states[nfa.start].transitions.len);
    try testing.expectEqual(Condition.epsilon, nfa.states[nfa.start].transitions[0].condition);
}

// ---------------------------------------------------------------
// Test: Optional "a?"
// ---------------------------------------------------------------

test "compile optional 'a?'" {
    var result = try testCompile("a?");
    defer result.nfa.deinit();
    defer result.p.deinit();

    const nfa = &result.nfa;

    // a?: opt_start, opt_end, body_start, body_end = 4 states.
    try testing.expectEqual(@as(usize, 4), nfa.states.len);

    // Start state has 2 epsilon transitions (greedy: to body, to end).
    try testing.expectEqual(@as(usize, 2), nfa.states[nfa.start].transitions.len);

    // 1 char transition for 'a'.
    try testing.expectEqual(@as(u32, 1), countTransitionsWithCondition(nfa, .char));
}

// ---------------------------------------------------------------
// Test: Lazy star "a*?"
// ---------------------------------------------------------------

test "compile lazy star 'a*?'" {
    var result = try testCompile("a*?");
    defer result.nfa.deinit();
    defer result.p.deinit();

    const nfa = &result.nfa;

    // Same structure as greedy star, but epsilon priority reversed.
    // Start state's first epsilon should go to end (skip), second to body.
    try testing.expectEqual(@as(usize, 2), nfa.states[nfa.start].transitions.len);

    // For lazy: first transition targets the end (match) state.
    const first_target = nfa.states[nfa.start].transitions[0].target;
    // The end state of star is the match state.
    try testing.expectEqual(State.Kind.match, nfa.states[first_target].kind);
}

// ---------------------------------------------------------------
// Test: Bounded quantifier "a{2,4}"
// ---------------------------------------------------------------

test "compile bounded quantifier 'a{2,4}'" {
    var result = try testCompile("a{2,4}");
    defer result.nfa.deinit();
    defer result.p.deinit();

    const nfa = &result.nfa;

    // 2 required copies of 'a' (each 2 states) + 2 optional copies (each 4 states: opt_start, opt_end, body_start, body_end).
    // = 4 + 8 = 12 states.
    // Plus epsilons for chaining.

    // Should have 4 char transitions total (2 required + 2 optional).
    try testing.expectEqual(@as(u32, 4), countTransitionsWithCondition(nfa, .char));

    // 1 match state.
    try testing.expectEqual(@as(u32, 1), countStatesByKind(nfa, .match));
}

// ---------------------------------------------------------------
// Test: Non-capture group "(?:a)"
// ---------------------------------------------------------------

test "compile non-capture group '(?:a)'" {
    var result = try testCompile("(?:a)");
    defer result.nfa.deinit();
    defer result.p.deinit();

    const nfa = &result.nfa;

    // Non-capture group is transparent: same as just 'a'.
    try testing.expectEqual(@as(usize, 2), nfa.states.len);
    try testing.expectEqual(@as(u32, 0), nfa.num_captures);
    try testing.expectEqual(@as(u32, 0), countStatesByKind(nfa, .capture_start));
}

// ---------------------------------------------------------------
// Test: Back reference "(a)\\1"
// ---------------------------------------------------------------

test "compile back reference '(a)\\1'" {
    var result = try testCompile("(a)\\1");
    defer result.nfa.deinit();
    defer result.p.deinit();

    const nfa = &result.nfa;

    // Should have 1 back_ref transition.
    try testing.expectEqual(@as(u32, 1), countTransitionsWithCondition(nfa, .back_ref));

    // Should have 1 capture group.
    try testing.expectEqual(@as(u32, 1), nfa.num_captures);
}

// ---------------------------------------------------------------
// Test: Dot "."
// ---------------------------------------------------------------

test "compile dot '.'" {
    var result = try testCompile(".");
    defer result.nfa.deinit();
    defer result.p.deinit();

    const nfa = &result.nfa;

    try testing.expectEqual(@as(usize, 2), nfa.states.len);
    try testing.expectEqual(@as(u32, 1), countTransitionsWithCondition(nfa, .dot));
}

// ---------------------------------------------------------------
// Test: Character class "[a-z]"
// ---------------------------------------------------------------

test "compile char class '[a-z]'" {
    var result = try testCompile("[a-z]");
    defer result.nfa.deinit();
    defer result.p.deinit();

    const nfa = &result.nfa;

    try testing.expectEqual(@as(usize, 2), nfa.states.len);
    try testing.expectEqual(@as(u32, 1), countTransitionsWithCondition(nfa, .char_class));
}

// ---------------------------------------------------------------
// Test: Word boundary "\\b"
// ---------------------------------------------------------------

test "compile word boundary '\\b'" {
    var result = try testCompile("\\b");
    defer result.nfa.deinit();
    defer result.p.deinit();

    const nfa = &result.nfa;

    try testing.expectEqual(@as(u32, 1), countTransitionsWithCondition(nfa, .word_boundary));
}

// ---------------------------------------------------------------
// Test: Negative lookahead "(?!a)"
// ---------------------------------------------------------------

test "compile negative lookahead '(?!a)'" {
    var result = try testCompile("(?!a)");
    defer result.nfa.deinit();
    defer result.p.deinit();

    const nfa = &result.nfa;

    try testing.expectEqual(@as(u32, 1), countStatesByKind(nfa, .assert_neg_lookahead));
}

// ---------------------------------------------------------------
// Test: Multiple capture groups "(a)(b)"
// ---------------------------------------------------------------

test "compile multiple capture groups '(a)(b)'" {
    var result = try testCompile("(a)(b)");
    defer result.nfa.deinit();
    defer result.p.deinit();

    const nfa = &result.nfa;

    try testing.expectEqual(@as(u32, 2), nfa.num_captures);
    try testing.expectEqual(@as(u32, 2), countStatesByKind(nfa, .capture_start));
    try testing.expectEqual(@as(u32, 2), countStatesByKind(nfa, .capture_end));

    // Verify capture IDs are 1 and 2.
    var ids = std.ArrayList(u32).init(testing.allocator);
    defer ids.deinit();
    for (nfa.states) |state| {
        if (state.kind == .capture_start) {
            try ids.append(state.capture_id);
        }
    }
    std.mem.sort(u32, ids.items, {}, std.sort.asc(u32));
    try testing.expectEqual(@as(u32, 1), ids.items[0]);
    try testing.expectEqual(@as(u32, 2), ids.items[1]);
}

// ---------------------------------------------------------------
// Test: Single char compiles to 2 states
// ---------------------------------------------------------------

test "compile single char 'a'" {
    var result = try testCompile("a");
    defer result.nfa.deinit();
    defer result.p.deinit();

    const nfa = &result.nfa;

    try testing.expectEqual(@as(usize, 2), nfa.states.len);
    try testing.expectEqual(State.Kind.normal, nfa.states[nfa.start].kind);
    try testing.expectEqual(@as(usize, 1), nfa.states[nfa.start].transitions.len);
    try testing.expectEqual(Condition{ .char = 'a' }, nfa.states[nfa.start].transitions[0].condition);

    const target = nfa.states[nfa.start].transitions[0].target;
    try testing.expectEqual(State.Kind.match, nfa.states[target].kind);
}
