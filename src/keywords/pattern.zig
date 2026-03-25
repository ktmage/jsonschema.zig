const std = @import("std");
const validator = @import("../validator.zig");
const Context = validator.Context;
const c = @cImport(@cInclude("regex.h"));

pub fn validate(ctx: Context) void {
    const schema_obj = ctx.schema.object;
    const value = schema_obj.get("pattern") orelse return;
    const instance_str = switch (ctx.instance) {
        .string => |s| s,
        else => return,
    };
    const pattern_str = switch (value) {
        .string => |s| s,
        else => return,
    };

    // Null-terminate instance string for C interop.
    const instance_z = ctx.allocator.dupeZ(u8, instance_str) catch return;
    defer ctx.allocator.free(instance_z);

    // Use regex cache if available
    if (ctx.regex_cache) |cache| {
        const match_result = cache.matches(pattern_str, instance_z.ptr) orelse {
            ctx.addError("pattern", "Failed to compile regex pattern");
            return;
        };
        if (!match_result) {
            const msg = std.fmt.allocPrint(
                ctx.allocator,
                "String does not match pattern: {s}",
                .{pattern_str},
            ) catch return;
            defer ctx.allocator.free(msg);
            ctx.addError("pattern", msg);
        }
        return;
    }

    // Fallback: compile regex without cache
    const pattern_z = ctx.allocator.dupeZ(u8, pattern_str) catch return;
    defer ctx.allocator.free(pattern_z);

    var regex: c.regex_t = undefined;
    const comp_result = c.regcomp(&regex, pattern_z.ptr, c.REG_EXTENDED | c.REG_NOSUB);
    if (comp_result != 0) {
        ctx.addError("pattern", "Failed to compile regex pattern");
        return;
    }
    defer c.regfree(&regex);

    const exec_result = c.regexec(&regex, instance_z.ptr, 0, null, 0);
    if (exec_result != 0) {
        const msg = std.fmt.allocPrint(
            ctx.allocator,
            "String does not match pattern: {s}",
            .{pattern_str},
        ) catch return;
        defer ctx.allocator.free(msg);
        ctx.addError("pattern", msg);
    }
}
