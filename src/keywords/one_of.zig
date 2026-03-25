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

    const base_path = JsonPointer.appendProperty(ctx.allocator, ctx.schema_path, "oneOf");
    var match_count: usize = 0;

    for (sub_schemas, 0..) |sub_schema, i| {
        const path = JsonPointer.appendIndex(ctx.allocator, base_path, i);
        const result = ctx.validateSubschema(sub_schema, ctx.instance, ctx.instance_path, path);
        defer result.deinit();
        if (result.isValid()) {
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
