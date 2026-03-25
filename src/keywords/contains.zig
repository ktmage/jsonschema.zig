const std = @import("std");
const validator = @import("../validator.zig");
const Context = validator.Context;
const json_pointer = @import("../json_pointer.zig");
const compiled_mod = @import("../compiled.zig");

pub fn validate(ctx: Context) void {
    const schema_obj = ctx.schema.object;
    const contains_schema = schema_obj.get("contains") orelse return;

    const arr = switch (ctx.instance) {
        .array => |a| a,
        else => return, // non-arrays pass
    };

    // Pre-lookup compiled node once for the contains schema
    const contains_node: ?*const compiled_mod.CompiledNode = if (ctx.compiled) |c| c.getNode(contains_schema) else null;

    // Count how many items match
    var match_count: usize = 0;
    for (arr.items) |item| {
        if (ctx.isSubschemaValidWithNode(contains_schema, item, contains_node)) {
            match_count += 1;
        }
    }

    // Check for minContains / maxContains
    const has_min_contains = schema_obj.get("minContains") != null;
    const has_max_contains = schema_obj.get("maxContains") != null;

    if (has_min_contains or has_max_contains) {
        // When minContains or maxContains are present, they control the validation
        const min_contains = getIntFromValue(schema_obj.get("minContains")) orelse if (has_min_contains) return else @as(usize, 1);
        const max_contains = getIntFromValue(schema_obj.get("maxContains"));

        if (match_count < min_contains) {
            const msg = std.fmt.allocPrint(
                ctx.allocator,
                "Expected at least {d} items to match contains schema, but found {d}",
                .{ min_contains, match_count },
            ) catch return;
            if (has_min_contains) {
                ctx.addError("minContains", msg);
            } else {
                ctx.addError("contains", msg);
            }
        }

        if (max_contains) |max| {
            if (match_count > max) {
                const msg = std.fmt.allocPrint(
                    ctx.allocator,
                    "Expected at most {d} items to match contains schema, but found {d}",
                    .{ max, match_count },
                ) catch return;
                ctx.addError("maxContains", msg);
            }
        }
    } else {
        // Standard contains: at least one must match
        if (match_count == 0) {
            ctx.addError("contains", "No items match the contains schema");
        }
    }
}

fn getIntFromValue(val: ?std.json.Value) ?usize {
    const v = val orelse return null;
    return switch (v) {
        .integer => |n| if (n >= 0) @as(usize, @intCast(n)) else null,
        .float => |f| blk: {
            // Handle decimal values like 2.0
            const rounded = @round(f);
            if (f == rounded and f >= 0) {
                break :blk @as(usize, @intFromFloat(rounded));
            }
            break :blk null;
        },
        else => null,
    };
}
