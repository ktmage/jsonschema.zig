const std = @import("std");
const validator = @import("../validator.zig");
const Context = validator.Context;
const JsonPointer = @import("../json_pointer.zig");

pub fn validate(ctx: Context) void {
    const schema_obj = ctx.schema.object;
    const if_schema = schema_obj.get("if") orelse return;

    // Validate instance against the "if" schema silently (only need bool result)
    if (ctx.isSubschemaValid(if_schema, ctx.instance)) {
        // "if" passed — validate against "then" if it exists
        const then_schema = schema_obj.get("then") orelse return;
        // Fast path: skip path allocation if then-schema passes
        if (ctx.compiled != null and ctx.isSubschemaValid(then_schema, ctx.instance)) return;
        const then_path = JsonPointer.appendProperty(ctx.allocator, ctx.schema_path, "then");
        const then_result = ctx.validateSubschema(then_schema, ctx.instance, ctx.instance_path, then_path);
        defer then_result.deinit();
        if (!then_result.isValid()) {
            for (then_result.errors) |err| {
                ctx.errors.append(.{
                    .instance_path = ctx.allocator.dupe(u8, err.instance_path) catch return,
                    .schema_path = ctx.allocator.dupe(u8, err.schema_path) catch return,
                    .keyword = err.keyword,
                    .message = ctx.allocator.dupe(u8, err.message) catch return,
                }) catch return;
            }
        }
    } else {
        // "if" failed — validate against "else" if it exists
        const else_schema = schema_obj.get("else") orelse return;
        // Fast path: skip path allocation if else-schema passes
        if (ctx.compiled != null and ctx.isSubschemaValid(else_schema, ctx.instance)) return;
        const else_path = JsonPointer.appendProperty(ctx.allocator, ctx.schema_path, "else");
        const else_result = ctx.validateSubschema(else_schema, ctx.instance, ctx.instance_path, else_path);
        defer else_result.deinit();
        if (!else_result.isValid()) {
            for (else_result.errors) |err| {
                ctx.errors.append(.{
                    .instance_path = ctx.allocator.dupe(u8, err.instance_path) catch return,
                    .schema_path = ctx.allocator.dupe(u8, err.schema_path) catch return,
                    .keyword = err.keyword,
                    .message = ctx.allocator.dupe(u8, err.message) catch return,
                }) catch return;
            }
        }
    }
}
