const std = @import("std");
const validator = @import("../validator.zig");
const Context = validator.Context;
const EcmaRegex = @import("../ecma_regex.zig").EcmaRegex;

pub fn validate(ctx: Context) void {
    const value = ctx.current_keyword_value orelse ctx.schema.object.get("pattern") orelse return;
    const instance_str = switch (ctx.instance) {
        .string => |s| s,
        else => return,
    };
    const pattern_str = switch (value) {
        .string => |s| s,
        else => return,
    };

    var ecma = EcmaRegex.compile(pattern_str, ctx.allocator) orelse {
        ctx.addError("pattern", "Failed to compile regex pattern");
        return;
    };
    defer ecma.deinit();

    if (!ecma.matches(instance_str)) {
        const msg = std.fmt.allocPrint(
            ctx.allocator,
            "String does not match pattern: {s}",
            .{pattern_str},
        ) catch return;
        defer ctx.allocator.free(msg);
        ctx.addError("pattern", msg);
    }
}
