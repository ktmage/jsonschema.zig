const std = @import("std");
const validator = @import("../validator.zig");
const Context = validator.Context;
const JsonPointer = @import("../json_pointer.zig");

/// Quick check: can this instance possibly match the sub-schema based on
/// type/enum constraints? Returns false if definitely not, true if maybe.
pub fn couldMatch(sub_schema: std.json.Value, instance: std.json.Value) bool {
    const obj = switch (sub_schema) {
        .object => |o| o,
        else => return true,
    };

    // Check "type" keyword
    if (obj.get("type")) |type_val| {
        switch (type_val) {
            .string => |t| {
                if (!instanceMatchesType(t, instance)) return false;
            },
            .array => |arr| {
                var any = false;
                for (arr.items) |item| {
                    switch (item) {
                        .string => |t| {
                            if (instanceMatchesType(t, instance)) {
                                any = true;
                                break;
                            }
                        },
                        else => {
                            any = true;
                            break;
                        },
                    }
                }
                if (!any) return false;
            },
            else => {},
        }
    }

    // Check "properties.type.enum" pattern (common in oneOf like geojson)
    if (obj.get("properties")) |props_val| {
        switch (props_val) {
            .object => |props| {
                if (props.get("type")) |type_prop| {
                    switch (type_prop) {
                        .object => |tp| {
                            if (tp.get("enum")) |enum_val| {
                                // Instance must be an object with a "type" field
                                switch (instance) {
                                    .object => |inst_obj| {
                                        if (inst_obj.get("type")) |inst_type| {
                                            switch (enum_val) {
                                                .array => |enum_arr| {
                                                    var found = false;
                                                    for (enum_arr.items) |e| {
                                                        if (jsonValueEql(e, inst_type)) {
                                                            found = true;
                                                            break;
                                                        }
                                                    }
                                                    if (!found) return false;
                                                },
                                                else => {},
                                            }
                                        }
                                    },
                                    else => {},
                                }
                            }
                        },
                        else => {},
                    }
                }
            },
            else => {},
        }
    }

    return true;
}

fn instanceMatchesType(type_name: []const u8, instance: std.json.Value) bool {
    return switch (instance) {
        .null => std.mem.eql(u8, type_name, "null"),
        .bool => std.mem.eql(u8, type_name, "boolean"),
        .integer => std.mem.eql(u8, type_name, "integer") or std.mem.eql(u8, type_name, "number"),
        .float => |f| blk: {
            if (std.mem.eql(u8, type_name, "number")) break :blk true;
            if (std.mem.eql(u8, type_name, "integer")) break :blk f == @trunc(f);
            break :blk false;
        },
        .string => std.mem.eql(u8, type_name, "string"),
        .array => std.mem.eql(u8, type_name, "array"),
        .object => std.mem.eql(u8, type_name, "object"),
        .number_string => false,
    };
}

fn jsonValueEql(a: std.json.Value, b: std.json.Value) bool {
    const tag_a = @intFromEnum(std.meta.activeTag(a));
    const tag_b = @intFromEnum(std.meta.activeTag(b));
    if (tag_a != tag_b) return false;
    return switch (a) {
        .string => |s| std.mem.eql(u8, s, b.string),
        .integer => |n| n == b.integer,
        .float => |f| f == b.float,
        .bool => |v| v == b.bool,
        .null => true,
        else => false,
    };
}

pub fn validate(ctx: Context) void {
    const value = ctx.current_keyword_value orelse ctx.schema.object.get("oneOf") orelse return;
    const sub_schemas = switch (value) {
        .array => |a| a.items,
        else => return,
    };

    var match_count: usize = 0;

    for (sub_schemas) |sub_schema| {
        // Quick pre-check: skip sub-schemas that can't possibly match
        if (!couldMatch(sub_schema, ctx.instance)) continue;

        if (ctx.isSubschemaValid(sub_schema, ctx.instance)) {
            match_count += 1;
            if (match_count > 1) break;
        }
    }

    if (match_count != 1) {
        if (match_count == 0) {
            ctx.addError("oneOf", "Instance does not match any schema in oneOf");
        } else {
            ctx.addError("oneOf", "Instance matches more than one schema in oneOf");
        }
    }
}
