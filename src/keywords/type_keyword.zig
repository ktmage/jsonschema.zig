const std = @import("std");
const validator = @import("../validator.zig");
const Context = validator.Context;

pub fn validate(ctx: Context) void {
    const schema_obj = ctx.schema.object;
    const type_value = schema_obj.get("type") orelse return;

    switch (type_value) {
        .string => |expected_type| {
            if (!matchesType(ctx.instance, expected_type)) {
                ctx.addError("type", "Instance does not match the expected type");
            }
        },
        .array => |type_array| {
            for (type_array.items) |item| {
                switch (item) {
                    .string => |t| {
                        if (matchesType(ctx.instance, t)) {
                            return; // matches at least one type
                        }
                    },
                    else => {},
                }
            }
            ctx.addError("type", "Instance does not match any of the expected types");
        },
        else => {},
    }
}

fn matchesType(instance: std.json.Value, expected: []const u8) bool {
    if (std.mem.eql(u8, expected, "null")) {
        return instance == .null;
    } else if (std.mem.eql(u8, expected, "boolean")) {
        return instance == .bool;
    } else if (std.mem.eql(u8, expected, "object")) {
        return instance == .object;
    } else if (std.mem.eql(u8, expected, "array")) {
        return instance == .array;
    } else if (std.mem.eql(u8, expected, "string")) {
        return instance == .string;
    } else if (std.mem.eql(u8, expected, "integer")) {
        return isInteger(instance);
    } else if (std.mem.eql(u8, expected, "number")) {
        return instance == .integer or instance == .float;
    }
    return false;
}

fn isInteger(instance: std.json.Value) bool {
    switch (instance) {
        .integer => return true,
        .float => |f| {
            // A number with zero fractional part is a valid integer (e.g. 1.0)
            return @floor(f) == f and !std.math.isNan(f) and !std.math.isInf(f);
        },
        else => return false,
    }
}
