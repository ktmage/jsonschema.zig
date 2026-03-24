const std = @import("std");
const jsonschema = @import("jsonschema");

const stdout = std.io.getStdOut().writer();
const stdin = std.io.getStdIn().reader();

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    while (true) {
        buf.clearRetainingCapacity();
        stdin.streamUntilDelimiter(buf.writer(), '\n', null) catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };
        const line = buf.items;
        if (line.len == 0) continue;

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();

        const obj = switch (parsed.value) {
            .object => |o| o,
            else => continue,
        };

        const cmd_val = obj.get("cmd") orelse continue;
        const cmd = switch (cmd_val) {
            .string => |s| s,
            else => continue,
        };

        if (std.mem.eql(u8, cmd, "start")) {
            try handleStart(obj);
        } else if (std.mem.eql(u8, cmd, "dialect")) {
            try handleDialect(obj);
        } else if (std.mem.eql(u8, cmd, "run")) {
            handleRun(allocator, obj) catch |err| {
                // If we can't handle run at all, try to write an error response
                const seq = obj.get("seq");
                writeErrorResponse(allocator, seq, @errorName(err)) catch {};
            };
        } else if (std.mem.eql(u8, cmd, "stop")) {
            return;
        }
    }
}

fn handleStart(obj: std.json.ObjectMap) !void {
    const version = blk: {
        const v = obj.get("version") orelse break :blk @as(i64, 0);
        break :blk switch (v) {
            .integer => |n| n,
            else => 0,
        };
    };

    if (version != 1) {
        // Unsupported protocol version
        return;
    }

    const response =
        \\{"version":1,"implementation":{"language":"zig","name":"jsonschema.zig","version":"0.2.0","homepage":"https://github.com/ktmage/jsonschema.zig","issues":"https://github.com/ktmage/jsonschema.zig/issues","source":"https://github.com/ktmage/jsonschema.zig","dialects":["https://json-schema.org/draft/2020-12/schema","http://json-schema.org/draft-07/schema#"]}}
    ;
    try stdout.print("{s}\n", .{response});
}

fn handleDialect(obj: std.json.ObjectMap) !void {
    const dialect = blk: {
        const v = obj.get("dialect") orelse break :blk "";
        break :blk switch (v) {
            .string => |s| s,
            else => "",
        };
    };

    if (std.mem.eql(u8, dialect, "http://json-schema.org/draft-07/schema#") or
        std.mem.eql(u8, dialect, "https://json-schema.org/draft/2020-12/schema"))
    {
        try stdout.print("{{\"ok\":true}}\n", .{});
    } else {
        try stdout.print("{{\"ok\":false}}\n", .{});
    }
}

fn handleRun(backing_allocator: std.mem.Allocator, obj: std.json.ObjectMap) !void {
    const seq = obj.get("seq") orelse return;
    const case_val = obj.get("case") orelse return;
    const case_obj = switch (case_val) {
        .object => |o| o,
        else => return,
    };

    const schema = case_obj.get("schema") orelse return;
    const tests = blk: {
        const v = case_obj.get("tests") orelse return;
        break :blk switch (v) {
            .array => |a| a.items,
            else => return,
        };
    };

    // Build results array
    var results = std.ArrayList(u8).init(backing_allocator);
    defer results.deinit();

    try results.appendSlice("[");
    for (tests, 0..) |t, i| {
        if (i > 0) try results.appendSlice(",");

        const test_obj = switch (t) {
            .object => |o| o,
            else => {
                try results.appendSlice("{\"errored\":true,\"context\":{\"message\":\"invalid test\"}}");
                continue;
            },
        };

        const instance = test_obj.get("instance") orelse {
            try results.appendSlice("{\"errored\":true,\"context\":{\"message\":\"missing instance\"}}");
            continue;
        };

        // Use arena for each test validation
        var arena = std.heap.ArenaAllocator.init(backing_allocator);
        defer arena.deinit();

        const result = jsonschema.validate(arena.allocator(), schema, instance);
        if (result.isValid()) {
            try results.appendSlice("{\"valid\":true}");
        } else {
            try results.appendSlice("{\"valid\":false}");
        }
    }
    try results.appendSlice("]");

    // Write response with seq preserved as-is
    var response = std.ArrayList(u8).init(backing_allocator);
    defer response.deinit();

    try response.appendSlice("{\"seq\":");
    try writeJsonValue(&response, seq);
    try response.appendSlice(",\"results\":");
    try response.appendSlice(results.items);
    try response.appendSlice("}\n");

    try stdout.writeAll(response.items);
}

fn writeErrorResponse(allocator: std.mem.Allocator, seq: ?std.json.Value, message: []const u8) !void {
    var response = std.ArrayList(u8).init(allocator);
    defer response.deinit();

    try response.appendSlice("{\"seq\":");
    if (seq) |s| {
        try writeJsonValue(&response, s);
    } else {
        try response.appendSlice("null");
    }
    try response.appendSlice(",\"errored\":true,\"context\":{\"message\":\"");
    try response.appendSlice(message);
    try response.appendSlice("\"}}\n");

    try stdout.writeAll(response.items);
}

fn writeJsonValue(buf: *std.ArrayList(u8), value: std.json.Value) !void {
    switch (value) {
        .null => try buf.appendSlice("null"),
        .bool => |b| try buf.appendSlice(if (b) "true" else "false"),
        .integer => |n| {
            var num_buf: [32]u8 = undefined;
            const len = std.fmt.formatIntBuf(&num_buf, n, 10, .lower, .{});
            try buf.appendSlice(num_buf[0..len]);
        },
        .float => |f| {
            var num_buf: [64]u8 = undefined;
            const slice = std.fmt.bufPrint(&num_buf, "{d}", .{f}) catch return;
            try buf.appendSlice(slice);
        },
        .string => |s| {
            try buf.append('"');
            for (s) |c| {
                switch (c) {
                    '"' => try buf.appendSlice("\\\""),
                    '\\' => try buf.appendSlice("\\\\"),
                    '\n' => try buf.appendSlice("\\n"),
                    '\r' => try buf.appendSlice("\\r"),
                    '\t' => try buf.appendSlice("\\t"),
                    else => try buf.append(c),
                }
            }
            try buf.append('"');
        },
        .array => |arr| {
            try buf.append('[');
            for (arr.items, 0..) |item, i| {
                if (i > 0) try buf.append(',');
                try writeJsonValue(buf, item);
            }
            try buf.append(']');
        },
        .object => |obj| {
            try buf.append('{');
            var first = true;
            var it = obj.iterator();
            while (it.next()) |entry| {
                if (!first) try buf.append(',');
                first = false;
                try buf.append('"');
                try buf.appendSlice(entry.key_ptr.*);
                try buf.append('"');
                try buf.append(':');
                try writeJsonValue(buf, entry.value_ptr.*);
            }
            try buf.append('}');
        },
        .number_string => |s| try buf.appendSlice(s),
    }
}
