const std = @import("std");
const jsonschema = @import("main.zig");
const SchemaRegistry = jsonschema.SchemaRegistry;
const CompiledSchema = jsonschema.CompiledSchema;
const build_options = @import("build_options");

fn runTestFile(
    backing_allocator: std.mem.Allocator,
    file_name: []const u8,
    contents: []const u8,
    remotes_registry: *SchemaRegistry,
) !struct { passed: usize, failed: usize, total: usize } {
    const parsed = try std.json.parseFromSlice(std.json.Value, backing_allocator, contents, .{});
    defer parsed.deinit();

    const test_groups = parsed.value.array.items;
    var passed: usize = 0;
    var failed: usize = 0;

    for (test_groups) |group| {
        const group_obj = group.object;
        const schema = group_obj.get("schema") orelse continue;
        const tests_val = group_obj.get("tests") orelse continue;

        for (tests_val.array.items) |t| {
            const test_obj = t.object;
            const instance = test_obj.get("data") orelse continue;
            const expected = (test_obj.get("valid") orelse continue).bool;

            var arena = std.heap.ArenaAllocator.init(backing_allocator);
            defer arena.deinit();
            const allocator = arena.allocator();

            // Build a per-test registry: start with remotes, then scan schema $ids
            var registry = SchemaRegistry.init(allocator);

            // Copy remotes
            var remote_it = remotes_registry.schemas.iterator();
            while (remote_it.next()) |entry| {
                registry.addSchema(entry.key_ptr.*, entry.value_ptr.*);
            }

            // Scan schema for $id declarations
            const base_uri = getSchemaId(schema) orelse "";
            if (base_uri.len > 0) {
                registry.addSchema(base_uri, schema);
            }
            registry.scanIds(base_uri, schema);

            const result = jsonschema.validateWithRegistry(allocator, schema, instance, &registry);

            if (result.isValid() == expected) {
                passed += 1;
            } else {
                const group_desc = getDesc(group_obj);
                const test_desc = getDesc(test_obj);
                std.debug.print("  FAIL [{s}] {s} > {s} (expected {}, got {})\n", .{
                    file_name, group_desc, test_desc, expected, result.isValid(),
                });
                failed += 1;
            }
        }
    }

    return .{ .passed = passed, .failed = failed, .total = passed + failed };
}

fn getDesc(obj: std.json.ObjectMap) []const u8 {
    if (obj.get("description")) |d| {
        return switch (d) {
            .string => |s| s,
            else => "?",
        };
    }
    return "?";
}

fn getSchemaId(schema: std.json.Value) ?[]const u8 {
    const obj = switch (schema) {
        .object => |o| o,
        else => return null,
    };
    const id_val = obj.get("$id") orelse return null;
    return switch (id_val) {
        .string => |s| s,
        else => null,
    };
}

fn getSchemaDialectUri(schema: std.json.Value) ?[]const u8 {
    const obj = switch (schema) {
        .object => |o| o,
        else => return null,
    };
    const val = obj.get("$schema") orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

/// Load remote schemas from the test suite's remotes/ directory.
fn loadRemotes(
    allocator: std.mem.Allocator,
    registry: *SchemaRegistry,
    dir: std.fs.Dir,
    base_path: []const u8,
    parsed_list: *std.ArrayList(std.json.Parsed(std.json.Value)),
) void {
    var iter = dir.iterate();
    while (iter.next() catch return) |entry| {
        const sub_path = std.fmt.allocPrint(allocator, "{s}{s}", .{ base_path, entry.name }) catch continue;

        if (entry.kind == .directory) {
            const dir_path = std.fmt.allocPrint(allocator, "{s}{s}/", .{ base_path, entry.name }) catch continue;
            var sub_dir = dir.openDir(entry.name, .{ .iterate = true }) catch continue;
            defer sub_dir.close();
            loadRemotes(allocator, registry, sub_dir, dir_path, parsed_list);
        } else if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".json")) {
            const contents = dir.readFileAlloc(allocator, entry.name, 10 * 1024 * 1024) catch continue;
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, contents, .{}) catch continue;
            // Keep parsed alive by storing it
            parsed_list.append(parsed) catch continue;
            const uri = std.fmt.allocPrint(allocator, "http://localhost:1234/{s}", .{sub_path}) catch continue;
            registry.addSchema(uri, parsed.value);
            // Also scan for $id within remote schemas
            registry.scanIds(uri, parsed.value);
        }
    }
}

test "JSON Schema Test Suite — Draft 7" {
    const allocator = std.testing.allocator;
    const path = build_options.test_suite_path;
    const remotes_path = build_options.remotes_path;

    // Load remote schemas
    var remotes_arena = std.heap.ArenaAllocator.init(allocator);
    defer remotes_arena.deinit();
    const remotes_alloc = remotes_arena.allocator();

    var remotes_registry = SchemaRegistry.init(remotes_alloc);
    var parsed_remotes = std.ArrayList(std.json.Parsed(std.json.Value)).init(remotes_alloc);

    var remotes_dir = try std.fs.openDirAbsolute(remotes_path, .{ .iterate = true });
    defer remotes_dir.close();
    loadRemotes(remotes_alloc, &remotes_registry, remotes_dir, "", &parsed_remotes);

    // Run test files
    var dir = try std.fs.openDirAbsolute(path, .{ .iterate = true });
    defer dir.close();

    var total_passed: usize = 0;
    var total_failed: usize = 0;
    var total_tests: usize = 0;
    var file_count: usize = 0;

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;

        const contents = dir.readFileAlloc(allocator, entry.name, 10 * 1024 * 1024) catch |err| {
            std.debug.print("Failed to read {s}: {}\n", .{ entry.name, err });
            continue;
        };
        defer allocator.free(contents);

        const counts = runTestFile(allocator, entry.name, contents, &remotes_registry) catch |err| {
            std.debug.print("Failed to parse {s}: {}\n", .{ entry.name, err });
            continue;
        };

        total_passed += counts.passed;
        total_failed += counts.failed;
        total_tests += counts.total;
        file_count += 1;
    }

    std.debug.print(
        "\n=== Draft 7 Test Suite Results ===\n" ++
            "Files:  {d}\n" ++
            "Tests:  {d}\n" ++
            "Passed: {d}\n" ++
            "Failed: {d}\n" ++
            "Rate:   {d:.1}%\n\n",
        .{
            file_count,
            total_tests,
            total_passed,
            total_failed,
            if (total_tests > 0) @as(f64, @floatFromInt(total_passed)) / @as(f64, @floatFromInt(total_tests)) * 100.0 else 0.0,
        },
    );

    try std.testing.expect(file_count > 0);
}

test "JSON Schema Test Suite — Draft 2020-12" {
    const allocator = std.testing.allocator;
    const path = build_options.test_suite_path_2020;
    const remotes_path = build_options.remotes_path;

    // Load remote schemas
    var remotes_arena = std.heap.ArenaAllocator.init(allocator);
    defer remotes_arena.deinit();
    const remotes_alloc = remotes_arena.allocator();

    var remotes_registry = SchemaRegistry.init(remotes_alloc);
    var parsed_remotes = std.ArrayList(std.json.Parsed(std.json.Value)).init(remotes_alloc);

    var remotes_dir = try std.fs.openDirAbsolute(remotes_path, .{ .iterate = true });
    defer remotes_dir.close();
    loadRemotes(remotes_alloc, &remotes_registry, remotes_dir, "", &parsed_remotes);

    // Run test files
    var dir = try std.fs.openDirAbsolute(path, .{ .iterate = true });
    defer dir.close();

    var total_passed: usize = 0;
    var total_failed: usize = 0;
    var total_tests: usize = 0;
    var file_count: usize = 0;

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;

        // Skip format.json — we don't validate format by default
        if (std.mem.eql(u8, entry.name, "format.json")) continue;

        const contents = dir.readFileAlloc(allocator, entry.name, 10 * 1024 * 1024) catch |err| {
            std.debug.print("Failed to read {s}: {}\n", .{ entry.name, err });
            continue;
        };
        defer allocator.free(contents);

        const counts = runTestFile(allocator, entry.name, contents, &remotes_registry) catch |err| {
            std.debug.print("Failed to parse {s}: {}\n", .{ entry.name, err });
            continue;
        };

        total_passed += counts.passed;
        total_failed += counts.failed;
        total_tests += counts.total;
        file_count += 1;
    }

    std.debug.print(
        "\n=== Draft 2020-12 Test Suite Results ===\n" ++
            "Files:  {d}\n" ++
            "Tests:  {d}\n" ++
            "Passed: {d}\n" ++
            "Failed: {d}\n" ++
            "Rate:   {d:.1}%\n\n",
        .{
            file_count,
            total_tests,
            total_passed,
            total_failed,
            if (total_tests > 0) @as(f64, @floatFromInt(total_passed)) / @as(f64, @floatFromInt(total_tests)) * 100.0 else 0.0,
        },
    );

    try std.testing.expect(file_count > 0);
}

test "compiled path matches uncompiled path — Draft 7" {
    const allocator = std.testing.allocator;
    const path = build_options.test_suite_path;
    const remotes_path = build_options.remotes_path;

    // Load remote schemas
    var remotes_arena = std.heap.ArenaAllocator.init(allocator);
    defer remotes_arena.deinit();
    const remotes_alloc = remotes_arena.allocator();

    var remotes_registry = SchemaRegistry.init(remotes_alloc);
    var parsed_remotes = std.ArrayList(std.json.Parsed(std.json.Value)).init(remotes_alloc);

    var remotes_dir = try std.fs.openDirAbsolute(remotes_path, .{ .iterate = true });
    defer remotes_dir.close();
    loadRemotes(remotes_alloc, &remotes_registry, remotes_dir, "", &parsed_remotes);

    // Run test files
    var dir = try std.fs.openDirAbsolute(path, .{ .iterate = true });
    defer dir.close();

    var total_tests: usize = 0;
    var mismatches: usize = 0;
    var file_count: usize = 0;

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;

        const contents = dir.readFileAlloc(allocator, entry.name, 10 * 1024 * 1024) catch |err| {
            std.debug.print("Failed to read {s}: {}\n", .{ entry.name, err });
            continue;
        };
        defer allocator.free(contents);

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, contents, .{}) catch |err| {
            std.debug.print("Failed to parse {s}: {}\n", .{ entry.name, err });
            continue;
        };
        defer parsed.deinit();

        const test_groups = parsed.value.array.items;

        for (test_groups) |group| {
            const group_obj = group.object;
            const schema = group_obj.get("schema") orelse continue;
            const tests_val = group_obj.get("tests") orelse continue;

            for (tests_val.array.items) |t| {
                const test_obj = t.object;
                const instance = test_obj.get("data") orelse continue;
                _ = (test_obj.get("valid") orelse continue).bool;

                var arena = std.heap.ArenaAllocator.init(allocator);
                defer arena.deinit();
                const alloc = arena.allocator();

                // Build a per-test registry with remotes
                var registry = SchemaRegistry.init(alloc);
                var remote_it = remotes_registry.schemas.iterator();
                while (remote_it.next()) |re| {
                    registry.addSchema(re.key_ptr.*, re.value_ptr.*);
                }
                const base_uri = getSchemaId(schema) orelse "";
                if (base_uri.len > 0) {
                    registry.addSchema(base_uri, schema);
                }
                registry.scanIds(base_uri, schema);

                // Uncompiled path
                const uncompiled_result = jsonschema.validateWithRegistry(alloc, schema, instance, &registry);
                const uncompiled_valid = uncompiled_result.isValid();

                // Compiled path
                var compiled = CompiledSchema.compile(alloc, schema, &registry);
                defer compiled.deinit();
                const compiled_result = jsonschema.validateCompiledWithRegistry(alloc, &compiled, instance, &registry);
                const compiled_valid = compiled_result.isValid();

                if (uncompiled_valid != compiled_valid) {
                    const group_desc = getDesc(group_obj);
                    const test_desc = getDesc(test_obj);
                    std.debug.print("  compiled path mismatch [{s}] {s} > {s} (uncompiled={}, compiled={})\n", .{
                        entry.name, group_desc, test_desc, uncompiled_valid, compiled_valid,
                    });
                    mismatches += 1;
                }
                total_tests += 1;
            }
        }
        file_count += 1;
    }

    std.debug.print(
        "\n=== compiled path vs uncompiled path (Draft 7) ===\n" ++
            "Files:      {d}\n" ++
            "Tests:      {d}\n" ++
            "Mismatches: {d}\n\n",
        .{ file_count, total_tests, mismatches },
    );

    try std.testing.expect(file_count > 0);
    try std.testing.expectEqual(@as(usize, 0), mismatches);
}
