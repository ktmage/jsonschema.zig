const std = @import("std");
const validator = @import("../validator.zig");
const Context = validator.Context;
const JsonPointer = @import("../json_pointer.zig");

pub fn validate(ctx: Context) void {
    const schema_obj = ctx.schema.object;
    const value = schema_obj.get("oneOf") orelse return;
    const sub_schemas = switch (value) {
        .array => |a| a.items,
        else => return,
    };

    var match_count: usize = 0;

    for (sub_schemas) |sub_schema| {
        if (ctx.isSubschemaValid(sub_schema, ctx.instance)) {
            match_count += 1;
            if (match_count > 1) break; // short-circuit: already invalid
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
