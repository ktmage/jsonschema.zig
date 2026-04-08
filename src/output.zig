const std = @import("std");
const Allocator = std.mem.Allocator;
const jsonschema = @import("main.zig");

/// JSON Schema output formats per specification (2020-12 Section 12).
pub const OutputFormat = enum {
    /// Boolean result only.
    flag,
    /// Flat list of output units.
    basic,
    /// Hierarchical tree condensed to only relevant branches.
    detailed,
    /// Full hierarchical tree with all nodes.
    verbose,
};

/// A single output unit in the structured output.
pub const OutputUnit = struct {
    /// Whether this node's validation passed.
    valid: bool,
    /// JSON Pointer to the instance location.
    instance_location: []const u8,
    /// JSON Pointer to the keyword in the schema.
    keyword_location: []const u8,
    /// Error message (only for failed assertions).
    @"error": ?[]const u8 = null,
    /// Annotation value (only for passed keywords with annotations).
    annotation: ?std.json.Value = null,
    /// Child output units (for detailed/verbose formats).
    children: []const OutputUnit = &.{},

    /// Serialize this OutputUnit to a std.json.Value.
    /// The caller owns the returned value (allocated with the given allocator).
    pub fn toJson(self: OutputUnit, allocator: Allocator) ?std.json.Value {
        var obj = std.json.ObjectMap.init(allocator);
        obj.put(allocator.dupe(u8, "valid") catch return null, .{ .bool = self.valid }) catch return null;
        obj.put(
            allocator.dupe(u8, "instanceLocation") catch return null,
            .{ .string = allocator.dupe(u8, self.instance_location) catch return null },
        ) catch return null;
        obj.put(
            allocator.dupe(u8, "keywordLocation") catch return null,
            .{ .string = allocator.dupe(u8, self.keyword_location) catch return null },
        ) catch return null;

        if (self.@"error") |err_msg| {
            obj.put(
                allocator.dupe(u8, "error") catch return null,
                .{ .string = allocator.dupe(u8, err_msg) catch return null },
            ) catch return null;
        }

        if (self.annotation) |ann| {
            obj.put(
                allocator.dupe(u8, "annotation") catch return null,
                ann,
            ) catch return null;
        }

        if (self.children.len > 0) {
            var arr = std.json.Array.initCapacity(allocator, self.children.len) catch return null;
            for (self.children) |child| {
                arr.append(child.toJson(allocator) orelse return null) catch return null;
            }
            obj.put(
                allocator.dupe(u8, "errors") catch return null,
                .{ .array = arr },
            ) catch return null;
        }

        return .{ .object = obj };
    }
};

/// Flag output: just valid/invalid.
pub const FlagOutput = struct {
    valid: bool,
};

/// Basic output: flat list of all output units.
pub const BasicOutput = struct {
    valid: bool,
    errors: []const OutputUnit,
    annotations: []const OutputUnit,
};

/// Detailed/Verbose output: hierarchical tree.
pub const HierarchicalOutput = struct {
    valid: bool,
    root: OutputUnit,
};

/// Convert a ValidationResult to flag output.
pub fn toFlag(result: jsonschema.ValidationResult) FlagOutput {
    return .{ .valid = result.isValid() };
}

/// Convert a ValidationResult to basic output.
pub fn toBasic(allocator: Allocator, result: jsonschema.ValidationResult) BasicOutput {
    var error_units = std.ArrayList(OutputUnit).init(allocator);
    for (result.errors) |err| {
        error_units.append(.{
            .valid = false,
            .instance_location = err.instance_path,
            .keyword_location = err.schema_path,
            .@"error" = err.message,
        }) catch {};
    }

    var annotation_units = std.ArrayList(OutputUnit).init(allocator);
    for (result.annotations) |ann| {
        annotation_units.append(.{
            .valid = true,
            .instance_location = ann.instance_path,
            .keyword_location = ann.schema_path,
            .annotation = ann.value,
        }) catch {};
    }

    return .{
        .valid = result.isValid(),
        .errors = error_units.toOwnedSlice() catch &.{},
        .annotations = annotation_units.toOwnedSlice() catch &.{},
    };
}

/// Convert a ValidationResult to detailed output.
/// Groups errors by instance location into a hierarchical tree structure.
/// Errors sharing a common instance_location prefix are grouped under
/// intermediate nodes representing those path prefixes.
pub fn toDetailed(allocator: Allocator, result: jsonschema.ValidationResult) HierarchicalOutput {
    if (result.isValid()) {
        return .{
            .valid = true,
            .root = .{
                .valid = true,
                .instance_location = "",
                .keyword_location = "",
            },
        };
    }

    // Build leaf OutputUnits from errors
    var leaves = std.ArrayList(OutputUnit).init(allocator);
    defer leaves.deinit();
    for (result.errors) |err| {
        leaves.append(.{
            .valid = false,
            .instance_location = err.instance_path,
            .keyword_location = err.schema_path,
            .@"error" = err.message,
        }) catch {};
    }

    const root_children = buildTree(allocator, leaves.items, "");

    return .{
        .valid = false,
        .root = .{
            .valid = false,
            .instance_location = "",
            .keyword_location = "",
            .children = root_children,
        },
    };
}

/// Convert a ValidationResult to verbose output.
/// Same tree structure as detailed but includes ALL evaluated nodes,
/// both failing (errors) and passing (annotations).
pub fn toVerbose(allocator: Allocator, result: jsonschema.ValidationResult) HierarchicalOutput {
    // Build leaf OutputUnits from both errors and annotations
    var leaves = std.ArrayList(OutputUnit).init(allocator);
    defer leaves.deinit();

    for (result.errors) |err| {
        leaves.append(.{
            .valid = false,
            .instance_location = err.instance_path,
            .keyword_location = err.schema_path,
            .@"error" = err.message,
        }) catch {};
    }

    for (result.annotations) |ann| {
        leaves.append(.{
            .valid = true,
            .instance_location = ann.instance_path,
            .keyword_location = ann.schema_path,
            .annotation = ann.value,
        }) catch {};
    }

    const valid = result.isValid();
    const root_children = buildTree(allocator, leaves.items, "");

    return .{
        .valid = valid,
        .root = .{
            .valid = valid,
            .instance_location = "",
            .keyword_location = "",
            .children = root_children,
        },
    };
}

// ── Tree-building internals ──────────────────────────────────────────

/// Split a JSON Pointer into its individual segments.
/// e.g. "/properties/name/type" -> ["properties", "name", "type"]
/// The root "" returns an empty slice.
fn splitPointer(allocator: Allocator, path: []const u8) []const []const u8 {
    if (path.len == 0) return allocator.alloc([]const u8, 0) catch return &.{};

    // Skip the leading '/'
    const trimmed = if (path.len > 0 and path[0] == '/') path[1..] else path;
    if (trimmed.len == 0) return allocator.alloc([]const u8, 0) catch return &.{};

    // Count segments
    var count: usize = 1;
    for (trimmed) |c| {
        if (c == '/') count += 1;
    }

    var segments = allocator.alloc([]const u8, count) catch return &.{};
    var idx: usize = 0;
    var start: usize = 0;
    for (trimmed, 0..) |c, i| {
        if (c == '/') {
            segments[idx] = trimmed[start..i];
            idx += 1;
            start = i + 1;
        }
    }
    segments[idx] = trimmed[start..];
    return segments;
}

/// Join segments back into a JSON Pointer string.
/// e.g. ["properties", "name"] -> "/properties/name"
fn joinPointer(allocator: Allocator, segments: []const []const u8) []const u8 {
    if (segments.len == 0) return "";
    var total_len: usize = 0;
    for (segments) |seg| {
        total_len += 1 + seg.len; // '/' + segment
    }
    var buf = allocator.alloc(u8, total_len) catch return "";
    var pos: usize = 0;
    for (segments) |seg| {
        buf[pos] = '/';
        pos += 1;
        @memcpy(buf[pos .. pos + seg.len], seg);
        pos += seg.len;
    }
    return buf;
}

/// Build a hierarchical tree from a flat list of OutputUnit leaves.
///
/// The algorithm groups leaves by the first instance_location segment below
/// `prefix`, creating intermediate nodes for shared path prefixes. Leaves
/// whose instance_location exactly equals `prefix` stay at this level.
///
/// For example, given prefix="" and leaves at:
///   /properties/name/type
///   /properties/name/minLength
///   /properties/age/minimum
///   /type
///
/// The result is:
///   children[0]: node at /properties  (intermediate, grouping)
///     children[0]: node at /properties/name  (intermediate, grouping)
///       children[0]: leaf at /properties/name/type
///       children[1]: leaf at /properties/name/minLength
///     children[1]: node at /properties/age  (intermediate, grouping)
///       children[0]: leaf at /properties/age/minimum
///   children[1]: leaf at /type
fn buildTree(allocator: Allocator, leaves: []const OutputUnit, prefix: []const u8) []const OutputUnit {
    if (leaves.len == 0) return &.{};

    const prefix_segments = splitPointer(allocator, prefix);
    defer if (prefix_segments.len > 0) allocator.free(prefix_segments);
    const prefix_depth = prefix_segments.len;

    // Partition leaves: those at exactly this prefix depth (direct) vs deeper
    var direct = std.ArrayList(OutputUnit).init(allocator);
    defer direct.deinit();

    // Group deeper leaves by their next segment
    var groups = std.StringHashMap(std.ArrayList(OutputUnit)).init(allocator);
    defer {
        var it = groups.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        groups.deinit();
    }

    // Track insertion order for deterministic output
    var group_order = std.ArrayList([]const u8).init(allocator);
    defer group_order.deinit();

    for (leaves) |leaf| {
        const leaf_segments = splitPointer(allocator, leaf.instance_location);
        defer if (leaf_segments.len > 0) allocator.free(leaf_segments);

        // Check if the leaf is under this prefix
        if (leaf_segments.len < prefix_depth) {
            // Shouldn't happen in a well-formed call, but keep it as direct
            direct.append(leaf) catch {};
            continue;
        }

        // Verify prefix matches
        var prefix_matches = true;
        for (0..prefix_depth) |i| {
            if (!std.mem.eql(u8, leaf_segments[i], prefix_segments[i])) {
                prefix_matches = false;
                break;
            }
        }
        if (!prefix_matches) {
            direct.append(leaf) catch {};
            continue;
        }

        if (leaf_segments.len == prefix_depth) {
            // Leaf is at exactly this prefix level
            direct.append(leaf) catch {};
        } else {
            // Leaf is deeper — group by the next segment
            const next_seg = leaf_segments[prefix_depth];
            const gop = groups.getOrPut(next_seg) catch continue;
            if (!gop.found_existing) {
                gop.value_ptr.* = std.ArrayList(OutputUnit).init(allocator);
                group_order.append(next_seg) catch {};
            }
            gop.value_ptr.append(leaf) catch {};
        }
    }

    // Now build the result: direct leaves + group intermediate nodes
    var result = std.ArrayList(OutputUnit).init(allocator);

    // Add direct leaves (at this exact level)
    for (direct.items) |leaf| {
        result.append(leaf) catch {};
    }

    // Add intermediate group nodes
    for (group_order.items) |seg| {
        if (groups.get(seg)) |group_leaves| {
            // Build the child prefix
            const child_prefix = blk: {
                if (prefix.len == 0) {
                    break :blk std.fmt.allocPrint(allocator, "/{s}", .{seg}) catch "";
                } else {
                    break :blk std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, seg }) catch "";
                }
            };

            const sub_leaves = group_leaves.items;

            // If there's exactly one leaf and it's at exactly this child_prefix,
            // don't create an intermediate node — just use the leaf directly.
            if (sub_leaves.len == 1) {
                if (std.mem.eql(u8, sub_leaves[0].instance_location, child_prefix)) {
                    result.append(sub_leaves[0]) catch {};
                    continue;
                }
            }

            // Recursively build subtree
            const sub_children = buildTree(allocator, sub_leaves, child_prefix);

            // If the recursion produced exactly one node, and that node's
            // instance_location matches child_prefix with its own children,
            // we can collapse it. But for correctness, keep the intermediate.

            // Determine validity: intermediate node is valid only if all
            // descendants are valid.
            var all_valid = true;
            for (sub_leaves) |sl| {
                if (!sl.valid) {
                    all_valid = false;
                    break;
                }
            }

            // Find the common keyword_location prefix for this group
            const kw_loc = commonKeywordPrefix(allocator, sub_leaves);

            result.append(.{
                .valid = all_valid,
                .instance_location = child_prefix,
                .keyword_location = kw_loc,
                .children = sub_children,
            }) catch {};
        }
    }

    return result.toOwnedSlice() catch &.{};
}

/// Find the longest common prefix of keyword_location across a set of leaves.
/// This is used to assign a keyword_location to intermediate grouping nodes.
fn commonKeywordPrefix(allocator: Allocator, leaves: []const OutputUnit) []const u8 {
    if (leaves.len == 0) return "";
    if (leaves.len == 1) return leaves[0].keyword_location;

    // Find common prefix of all keyword_locations
    var prefix = leaves[0].keyword_location;
    for (leaves[1..]) |leaf| {
        prefix = commonPrefix(prefix, leaf.keyword_location);
    }

    // Trim to the last '/' boundary so we don't cut in the middle of a segment
    if (prefix.len > 0 and !std.mem.eql(u8, prefix, leaves[0].keyword_location)) {
        if (std.mem.lastIndexOf(u8, prefix, "/")) |last_slash| {
            // Allocate a copy so the pointer is stable
            return allocator.dupe(u8, prefix[0..last_slash]) catch prefix[0..last_slash];
        }
    }

    return prefix;
}

/// Return the common prefix of two strings.
fn commonPrefix(a: []const u8, b: []const u8) []const u8 {
    const min_len = @min(a.len, b.len);
    var i: usize = 0;
    while (i < min_len and a[i] == b[i]) : (i += 1) {}
    return a[0..i];
}

// ── Tests ────────────────────────────────────────────────────────────

test "toFlag returns valid for empty errors" {
    const result = jsonschema.ValidationResult{
        .errors = &.{},
        .allocator = std.testing.allocator,
    };
    const flag = toFlag(result);
    try std.testing.expect(flag.valid);
}

test "toFlag returns invalid for errors present" {
    // We need a ValidationError with allocated strings for deinit.
    const allocator = std.testing.allocator;
    const ip = try allocator.dupe(u8, "/foo");
    const sp = try allocator.dupe(u8, "/type");
    const msg = try allocator.dupe(u8, "bad");
    const errs = try allocator.alloc(jsonschema.ValidationError, 1);
    errs[0] = .{
        .instance_path = ip,
        .schema_path = sp,
        .keyword = "type",
        .message = msg,
    };
    const result = jsonschema.ValidationResult{
        .errors = errs,
        .allocator = allocator,
    };
    defer result.deinit();

    const flag = toFlag(result);
    try std.testing.expect(!flag.valid);
}

test "toBasic returns flat list of errors" {
    const allocator = std.testing.allocator;
    const ip1 = try allocator.dupe(u8, "/name");
    const sp1 = try allocator.dupe(u8, "/properties/name/type");
    const msg1 = try allocator.dupe(u8, "expected string");
    const ip2 = try allocator.dupe(u8, "/age");
    const sp2 = try allocator.dupe(u8, "/properties/age/minimum");
    const msg2 = try allocator.dupe(u8, "must be >= 0");

    const errs = try allocator.alloc(jsonschema.ValidationError, 2);
    errs[0] = .{ .instance_path = ip1, .schema_path = sp1, .keyword = "type", .message = msg1 };
    errs[1] = .{ .instance_path = ip2, .schema_path = sp2, .keyword = "minimum", .message = msg2 };

    const result = jsonschema.ValidationResult{
        .errors = errs,
        .allocator = allocator,
    };
    defer result.deinit();

    const basic = toBasic(std.testing.allocator, result);
    defer std.testing.allocator.free(basic.errors);

    try std.testing.expect(!basic.valid);
    try std.testing.expectEqual(@as(usize, 2), basic.errors.len);
    try std.testing.expectEqualStrings("/name", basic.errors[0].instance_location);
    try std.testing.expectEqualStrings("/age", basic.errors[1].instance_location);
}

test "toDetailed builds hierarchical tree from errors" {
    const allocator = std.testing.allocator;

    // Create errors at /properties/name/type and /properties/name/minLength
    const ip1 = try allocator.dupe(u8, "/name");
    const sp1 = try allocator.dupe(u8, "/properties/name/type");
    const msg1 = try allocator.dupe(u8, "expected string");
    const ip2 = try allocator.dupe(u8, "/name");
    const sp2 = try allocator.dupe(u8, "/properties/name/minLength");
    const msg2 = try allocator.dupe(u8, "too short");
    const ip3 = try allocator.dupe(u8, "/age");
    const sp3 = try allocator.dupe(u8, "/properties/age/minimum");
    const msg3 = try allocator.dupe(u8, "must be >= 0");

    const errs = try allocator.alloc(jsonschema.ValidationError, 3);
    errs[0] = .{ .instance_path = ip1, .schema_path = sp1, .keyword = "type", .message = msg1 };
    errs[1] = .{ .instance_path = ip2, .schema_path = sp2, .keyword = "minLength", .message = msg2 };
    errs[2] = .{ .instance_path = ip3, .schema_path = sp3, .keyword = "minimum", .message = msg3 };

    const result = jsonschema.ValidationResult{
        .errors = errs,
        .allocator = allocator,
    };
    defer result.deinit();

    // Use an arena so the tree allocations are freed together
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const detailed = toDetailed(arena.allocator(), result);
    try std.testing.expect(!detailed.valid);
    try std.testing.expectEqualStrings("", detailed.root.instance_location);

    // Root should have children grouped by instance_location
    // /name has 2 errors (grouped), /age has 1 error
    try std.testing.expect(detailed.root.children.len >= 2);
}

test "toDetailed valid result returns valid root" {
    const result = jsonschema.ValidationResult{
        .errors = &.{},
        .allocator = std.testing.allocator,
    };
    const detailed = toDetailed(std.testing.allocator, result);
    try std.testing.expect(detailed.valid);
    try std.testing.expect(detailed.root.valid);
    try std.testing.expectEqual(@as(usize, 0), detailed.root.children.len);
}

test "toVerbose includes both errors and annotations" {
    const allocator = std.testing.allocator;

    const ip1 = try allocator.dupe(u8, "/name");
    const sp1 = try allocator.dupe(u8, "/properties/name/type");
    const msg1 = try allocator.dupe(u8, "expected string");

    const errs = try allocator.alloc(jsonschema.ValidationError, 1);
    errs[0] = .{ .instance_path = ip1, .schema_path = sp1, .keyword = "type", .message = msg1 };

    const ann_ip = try allocator.dupe(u8, "/age");
    const ann_sp = try allocator.dupe(u8, "/properties/age/title");

    const anns = try allocator.alloc(jsonschema.Annotation, 1);
    anns[0] = .{
        .keyword = "title",
        .instance_path = ann_ip,
        .schema_path = ann_sp,
        .value = .{ .string = "Age" },
    };

    const result = jsonschema.ValidationResult{
        .errors = errs,
        .annotations = anns,
        .allocator = allocator,
    };
    defer result.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const verbose = toVerbose(arena.allocator(), result);
    try std.testing.expect(!verbose.valid);

    // Should have children from both errors and annotations
    try std.testing.expect(verbose.root.children.len >= 2);
}

test "toDetailed groups nested errors under common prefix" {
    const allocator = std.testing.allocator;

    // Two errors at instance /a/b/c and /a/b/d should group under /a/b
    const ip1 = try allocator.dupe(u8, "/a/b/c");
    const sp1 = try allocator.dupe(u8, "/properties/a/properties/b/properties/c/type");
    const msg1 = try allocator.dupe(u8, "err1");
    const ip2 = try allocator.dupe(u8, "/a/b/d");
    const sp2 = try allocator.dupe(u8, "/properties/a/properties/b/properties/d/type");
    const msg2 = try allocator.dupe(u8, "err2");

    const errs = try allocator.alloc(jsonschema.ValidationError, 2);
    errs[0] = .{ .instance_path = ip1, .schema_path = sp1, .keyword = "type", .message = msg1 };
    errs[1] = .{ .instance_path = ip2, .schema_path = sp2, .keyword = "type", .message = msg2 };

    const result = jsonschema.ValidationResult{
        .errors = errs,
        .allocator = allocator,
    };
    defer result.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const detailed = toDetailed(arena.allocator(), result);

    // Root should have 1 child: an intermediate node at /a
    try std.testing.expectEqual(@as(usize, 1), detailed.root.children.len);
    const a_node = detailed.root.children[0];
    try std.testing.expectEqualStrings("/a", a_node.instance_location);

    // /a should have 1 child: intermediate node at /a/b
    try std.testing.expectEqual(@as(usize, 1), a_node.children.len);
    const b_node = a_node.children[0];
    try std.testing.expectEqualStrings("/a/b", b_node.instance_location);

    // /a/b should have 2 children: leaves at /a/b/c and /a/b/d
    try std.testing.expectEqual(@as(usize, 2), b_node.children.len);
}

test "splitPointer splits correctly" {
    const allocator = std.testing.allocator;

    const empty = splitPointer(allocator, "");
    try std.testing.expectEqual(@as(usize, 0), empty.len);

    const root_slash = splitPointer(allocator, "/");
    try std.testing.expectEqual(@as(usize, 0), root_slash.len);

    const simple = splitPointer(allocator, "/foo");
    defer allocator.free(simple);
    try std.testing.expectEqual(@as(usize, 1), simple.len);
    try std.testing.expectEqualStrings("foo", simple[0]);

    const nested = splitPointer(allocator, "/properties/name/type");
    defer allocator.free(nested);
    try std.testing.expectEqual(@as(usize, 3), nested.len);
    try std.testing.expectEqualStrings("properties", nested[0]);
    try std.testing.expectEqualStrings("name", nested[1]);
    try std.testing.expectEqualStrings("type", nested[2]);
}

test "joinPointer joins correctly" {
    const allocator = std.testing.allocator;

    const empty_segs: []const []const u8 = &.{};
    const empty = joinPointer(allocator, empty_segs);
    try std.testing.expectEqualStrings("", empty);

    const one: []const []const u8 = &.{"foo"};
    const one_result = joinPointer(allocator, one);
    defer allocator.free(one_result);
    try std.testing.expectEqualStrings("/foo", one_result);

    const multi: []const []const u8 = &.{ "properties", "name" };
    const multi_result = joinPointer(allocator, multi);
    defer allocator.free(multi_result);
    try std.testing.expectEqualStrings("/properties/name", multi_result);
}

test "commonPrefix returns correct prefix" {
    try std.testing.expectEqualStrings("/prop", commonPrefix("/properties", "/prop"));
    try std.testing.expectEqualStrings("", commonPrefix("abc", "xyz"));
    try std.testing.expectEqualStrings("abc", commonPrefix("abc", "abc"));
}

test "OutputUnit.toJson serializes correctly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const unit = OutputUnit{
        .valid = false,
        .instance_location = "/name",
        .keyword_location = "/properties/name/type",
        .@"error" = "expected string",
    };

    const json_val = unit.toJson(alloc);
    try std.testing.expect(json_val != null);

    const obj = json_val.?.object;
    try std.testing.expect(!obj.get("valid").?.bool);
    try std.testing.expectEqualStrings("/name", obj.get("instanceLocation").?.string);
    try std.testing.expectEqualStrings("/properties/name/type", obj.get("keywordLocation").?.string);
    try std.testing.expectEqualStrings("expected string", obj.get("error").?.string);
}
