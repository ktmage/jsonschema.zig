const std = @import("std");
const validator = @import("../validator.zig");
const Context = validator.Context;

pub fn validate(ctx: Context) void {
    const schema_obj = ctx.schema.object;
    const enum_value = schema_obj.get("enum") orelse return;

    const enum_array = switch (enum_value) {
        .array => |a| a,
        else => return,
    };

    for (enum_array.items) |candidate| {
        if (jsonEqual(ctx.instance, candidate)) {
            return; // instance matches one of the enum values
        }
    }
    ctx.addError("enum", "Instance does not match any enum value");
}

/// Deep equality comparison for std.json.Value.
/// Compares two JSON values recursively, handling all value types.
pub fn jsonEqual(a: std.json.Value, b: std.json.Value) bool {
    const TagType = std.meta.Tag(std.json.Value);
    const tag_a: TagType = a;
    const tag_b: TagType = b;

    // Special case: integer and float can be equal across types
    // e.g. integer 1 == float 1.0
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
