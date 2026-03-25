const std = @import("std");
const validator = @import("../validator.zig");
const Context = validator.Context;

pub fn validate(ctx: Context) void {
    // Use pre-extracted value if available
    const value = ctx.current_keyword_value orelse ctx.schema.object.get("uniqueItems") orelse return;

    const unique_required = switch (value) {
        .bool => |b| b,
        else => return,
    };

    if (!unique_required) return;

    const arr = switch (ctx.instance) {
        .array => |a| a,
        else => return, // non-arrays pass
    };

    const items = arr.items;
    for (0..items.len) |i| {
        for (i + 1..items.len) |j| {
            if (jsonEqual(items[i], items[j])) {
                ctx.addError("uniqueItems", "Array items are not unique");
                return;
            }
        }
    }
}

/// Deep equality comparison for std.json.Value.
fn jsonEqual(a: std.json.Value, b: std.json.Value) bool {
    const TagType = std.meta.Tag(std.json.Value);
    const tag_a: TagType = a;
    const tag_b: TagType = b;

    // Special case: integer and float can be equal across types
    if (isNumeric(tag_a) and isNumeric(tag_b)) {
        return numericEqual(a, b);
    }

    if (tag_a != tag_b) return false;

    switch (a) {
        .null => return true,
        .bool => |val_a| return val_a == b.bool,
        .integer => |val_a| return val_a == b.integer,
        .float => |val_a| return val_a == b.float,
        .string => |val_a| return std.mem.eql(u8, val_a, b.string),
        .array => |arr_a| {
            const arr_b = b.array;
            if (arr_a.items.len != arr_b.items.len) return false;
            for (arr_a.items, arr_b.items) |item_a, item_b| {
                if (!jsonEqual(item_a, item_b)) return false;
            }
            return true;
        },
        .object => |obj_a| {
            const obj_b = b.object;
            if (obj_a.count() != obj_b.count()) return false;
            var it = obj_a.iterator();
            while (it.next()) |entry| {
                const val_b = obj_b.get(entry.key_ptr.*) orelse return false;
                if (!jsonEqual(entry.value_ptr.*, val_b)) return false;
            }
            return true;
        },
        .number_string => |val_a| {
            return switch (b) {
                .number_string => |val_b| std.mem.eql(u8, val_a, val_b),
                else => false,
            };
        },
    }
}

fn isNumeric(tag: std.meta.Tag(std.json.Value)) bool {
    return tag == .integer or tag == .float;
}

fn numericEqual(a: std.json.Value, b: std.json.Value) bool {
    const fa: f64 = switch (a) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => unreachable,
    };
    const fb: f64 = switch (b) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => unreachable,
    };
    return fa == fb;
}
