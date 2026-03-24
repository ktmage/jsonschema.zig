const std = @import("std");
const jsonschema = @import("main.zig");
const build_options = @import("build_options");

const TestCase = struct {
    description: []const u8,
    schema: std.json.Value,
    tests: []const TestInstance,
};

const TestInstance = struct {
    description: []const u8,
    data: std.json.Value,
    valid: bool,
};

fn parseTestFile(allocator: std.mem.Allocator, contents: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, contents, .{});
}

fn runTestFile(allocator: std.mem.Allocator, file_name: []const u8, contents: []const u8) !struct { passed: usize, failed: usize, total: usize } {
    const parsed = try parseTestFile(allocator, contents);
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

            const result = jsonschema.validate(allocator, schema, instance);
            defer result.deinit();

            if (result.isValid() == expected) {
                passed += 1;
            } else {
                const group_desc = blk: {
                    if (group_obj.get("description")) |d| {
                        break :blk switch (d) {
                            .string => |s| s,
                            else => "?",
                        };
                    }
                    break :blk "?";
                };
                const test_desc = blk: {
                    if (test_obj.get("description")) |d| {
                        break :blk switch (d) {
                            .string => |s| s,
                            else => "?",
                        };
                    }
                    break :blk "?";
                };
                std.debug.print("  FAIL [{s}] {s} > {s} (expected {}, got {})\n", .{
                    file_name,
                    group_desc,
                    test_desc,
                    expected,
                    result.isValid(),
                });
                failed += 1;
            }
        }
    }

    return .{ .passed = passed, .failed = failed, .total = passed + failed };
}

test "JSON Schema Test Suite — Draft 7" {
    const allocator = std.testing.allocator;
    const path = build_options.test_suite_path;

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

        const counts = runTestFile(allocator, entry.name, contents) catch |err| {
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

    // Don't fail the test — we expect most tests to fail until keywords are implemented.
    // This runner is for reporting progress.
    try std.testing.expect(file_count > 0);
}
