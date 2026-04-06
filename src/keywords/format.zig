const std = @import("std");
const validator = @import("../validator.zig");
const Context = validator.Context;

pub fn validate(ctx: Context) void {
    // Format validation is opt-in per JSON Schema spec.
    // Only validate if validate_formats is enabled in context.
    if (!ctx.validate_formats) return;

    const schema_obj = ctx.schema.object;
    const format_val = schema_obj.get("format") orelse return;
    const format_str = switch (format_val) {
        .string => |s| s,
        else => return,
    };

    const instance_str = switch (ctx.instance) {
        .string => |s| s,
        else => return, // format only applies to strings
    };

    const valid = validateFormat(format_str, instance_str);
    if (!valid) {
        const msg = std.fmt.allocPrint(
            ctx.allocator,
            "String does not match format '{s}'",
            .{format_str},
        ) catch return;
        defer ctx.allocator.free(msg);
        ctx.addError("format", msg);
    }
}

fn validateFormat(format: []const u8, value: []const u8) bool {
    if (std.mem.eql(u8, format, "date-time")) return isDateTime(value);
    if (std.mem.eql(u8, format, "date")) return isDate(value);
    if (std.mem.eql(u8, format, "time")) return isTime(value);
    if (std.mem.eql(u8, format, "email")) return isEmail(value);
    if (std.mem.eql(u8, format, "idn-email")) return isEmail(value);
    if (std.mem.eql(u8, format, "hostname")) return isHostname(value);
    if (std.mem.eql(u8, format, "idn-hostname")) return isHostname(value);
    if (std.mem.eql(u8, format, "ipv4")) return isIpv4(value);
    if (std.mem.eql(u8, format, "ipv6")) return isIpv6(value);
    if (std.mem.eql(u8, format, "uri")) return isUri(value);
    if (std.mem.eql(u8, format, "uri-reference")) return isUriReference(value);
    if (std.mem.eql(u8, format, "iri")) return isUri(value);
    if (std.mem.eql(u8, format, "iri-reference")) return isUriReference(value);
    if (std.mem.eql(u8, format, "uri-template")) return isUriTemplate(value);
    if (std.mem.eql(u8, format, "json-pointer")) return isJsonPointer(value);
    if (std.mem.eql(u8, format, "relative-json-pointer")) return isRelativeJsonPointer(value);
    if (std.mem.eql(u8, format, "regex")) return isRegex(value);
    if (std.mem.eql(u8, format, "uuid")) return isUuid(value);
    if (std.mem.eql(u8, format, "duration")) return isDuration(value);
    // Unknown formats pass validation (per spec)
    return true;
}

// --- Format validators ---

fn isDateTime(s: []const u8) bool {
    // RFC 3339: YYYY-MM-DDThh:mm:ss[.frac]Z or +/-hh:mm
    if (s.len < 20) return false; // minimum: 2000-01-01T00:00:00Z
    const t_pos = std.mem.indexOfScalar(u8, s, 'T') orelse
        std.mem.indexOfScalar(u8, s, 't') orelse return false;
    return isDate(s[0..t_pos]) and isTime(s[t_pos + 1 ..]);
}

fn isDate(s: []const u8) bool {
    // YYYY-MM-DD
    if (s.len != 10) return false;
    if (s[4] != '-' or s[7] != '-') return false;
    const year = std.fmt.parseInt(u16, s[0..4], 10) catch return false;
    const month = std.fmt.parseInt(u8, s[5..7], 10) catch return false;
    const day = std.fmt.parseInt(u8, s[8..10], 10) catch return false;
    if (month < 1 or month > 12) return false;
    if (day < 1) return false;
    const days_in_month = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var max_day = days_in_month[month - 1];
    if (month == 2 and isLeapYear(year)) max_day = 29;
    return day <= max_day;
}

fn isLeapYear(year: u16) bool {
    return (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
}

fn isTime(s: []const u8) bool {
    // RFC 3339 time: hh:mm:ss[.frac](Z|+hh:mm|-hh:mm)
    // Minimum valid: "00:00:00Z" = 9 chars (timezone offset is required)
    if (s.len < 9) return false;
    if (s[2] != ':' or s[5] != ':') return false;
    const hour = std.fmt.parseInt(u8, s[0..2], 10) catch return false;
    const minute = std.fmt.parseInt(u8, s[3..5], 10) catch return false;
    const second = std.fmt.parseInt(u8, s[6..8], 10) catch return false;
    if (hour > 23 or minute > 59 or second > 60) return false; // 60 for leap second
    var pos: usize = 8;
    // Optional fractional seconds
    if (pos < s.len and s[pos] == '.') {
        pos += 1;
        if (pos >= s.len or !std.ascii.isDigit(s[pos])) return false;
        while (pos < s.len and std.ascii.isDigit(s[pos])) : (pos += 1) {}
    }
    // Timezone offset required
    if (pos >= s.len) return false;
    if (s[pos] == 'Z' or s[pos] == 'z') return pos + 1 == s.len;
    if (s[pos] == '+' or s[pos] == '-') {
        if (s.len - pos != 6) return false; // +hh:mm
        if (s[pos + 3] != ':') return false;
        const oh = std.fmt.parseInt(u8, s[pos + 1 .. pos + 3], 10) catch return false;
        const om = std.fmt.parseInt(u8, s[pos + 4 .. pos + 6], 10) catch return false;
        return oh <= 23 and om <= 59;
    }
    return false;
}

fn isEmail(s: []const u8) bool {
    // Simplified RFC 5321: local@domain
    const at = std.mem.indexOfScalar(u8, s, '@') orelse return false;
    if (at == 0 or at >= s.len - 1) return false;
    const local = s[0..at];
    const domain = s[at + 1 ..];
    if (local.len > 64 or domain.len > 255) return false;
    return isHostname(domain) or (domain.len > 2 and domain[0] == '[' and domain[domain.len - 1] == ']');
}

fn isHostname(s: []const u8) bool {
    if (s.len == 0 or s.len > 253) return false;
    var label_start: usize = 0;
    for (s, 0..) |c, i| {
        if (c == '.') {
            if (i == label_start) return false; // empty label
            if (i - label_start > 63) return false;
            if (s[label_start] == '-' or s[i - 1] == '-') return false;
            label_start = i + 1;
        } else if (!std.ascii.isAlphanumeric(c) and c != '-') {
            // Allow non-ASCII for IDN hostnames
            if (c < 128) return false;
        }
    }
    // Check last label
    if (s.len == label_start) return false;
    if (s.len - label_start > 63) return false;
    if (s[label_start] == '-' or s[s.len - 1] == '-') return false;
    return true;
}

fn isIpv4(s: []const u8) bool {
    var parts: u8 = 0;
    var num_start: usize = 0;
    for (s, 0..) |c, i| {
        if (c == '.') {
            if (i == num_start) return false;
            const num = std.fmt.parseInt(u16, s[num_start..i], 10) catch return false;
            if (num > 255) return false;
            // No leading zeros
            if (i - num_start > 1 and s[num_start] == '0') return false;
            parts += 1;
            num_start = i + 1;
        } else if (!std.ascii.isDigit(c)) return false;
    }
    if (s.len == num_start) return false;
    const num = std.fmt.parseInt(u16, s[num_start..], 10) catch return false;
    if (num > 255) return false;
    if (s.len - num_start > 1 and s[num_start] == '0') return false;
    parts += 1;
    return parts == 4;
}

fn isIpv6(s: []const u8) bool {
    if (s.len < 2) return false;
    var groups: u8 = 0;
    var has_double_colon = false;
    var i: usize = 0;

    // Handle leading ::
    if (s.len >= 2 and s[0] == ':' and s[1] == ':') {
        has_double_colon = true;
        i = 2;
        if (i >= s.len) return true; // :: alone is valid
    }

    while (i < s.len) {
        // Parse hex group
        var hex_len: usize = 0;
        while (i + hex_len < s.len and std.ascii.isHex(s[i + hex_len])) : (hex_len += 1) {}
        if (hex_len > 4) return false;
        if (hex_len > 0) {
            groups += 1;
            i += hex_len;
        }

        if (i >= s.len) break;

        if (s[i] == ':') {
            if (i + 1 < s.len and s[i + 1] == ':') {
                if (has_double_colon) return false; // only one :: allowed
                has_double_colon = true;
                i += 2;
            } else {
                i += 1;
                if (i >= s.len) return false; // trailing single colon
            }
        } else if (s[i] == '.' and groups > 0) {
            // IPv4-mapped suffix: check remaining as IPv4
            // Back up to start of last group (it's the first IPv4 octet)
            var j = i;
            while (j > 0 and s[j - 1] != ':') : (j -= 1) {}
            groups -= 1; // last group is actually part of IPv4
            return isIpv4(s[j..]) and (groups + 2 == 8 or (has_double_colon and groups + 2 <= 8));
        } else {
            return false;
        }
    }

    if (has_double_colon) return groups <= 8;
    return groups == 8;
}

fn isUri(s: []const u8) bool {
    // RFC 3986: scheme ":" hier-part
    if (s.len == 0) return false;
    // Must have a scheme
    const colon = std.mem.indexOfScalar(u8, s, ':') orelse return false;
    if (colon == 0) return false;
    // Scheme: ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )
    if (!std.ascii.isAlphabetic(s[0])) return false;
    for (s[1..colon]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') return false;
    }
    return true;
}

fn isUriReference(s: []const u8) bool {
    // URI-reference = URI / relative-ref (RFC 3986 Section 4.1)
    if (s.len == 0) return true; // empty string is valid relative-ref
    if (isUri(s)) return true;
    // Relative-ref: must not contain invalid characters
    // Reject characters not allowed in URI-references per RFC 3986
    for (s) |ch| {
        if (ch < 0x21 or ch == 0x7F) return false; // control chars and space
        // Allow: unreserved / pct-encoded / sub-delims / : / @ / / / ?/ # / [ / ]
        // Reject: < > { } | \ ^ ` (delimiters not in RFC 3986 URI-reference)
        if (ch == '<' or ch == '>' or ch == '{' or ch == '}' or
            ch == '|' or ch == '\\' or ch == '^' or ch == '`') return false;
    }
    return true;
}

fn isUriTemplate(s: []const u8) bool {
    // RFC 6570: simplified check for balanced braces
    var depth: i32 = 0;
    for (s) |c| {
        if (c == '{') depth += 1;
        if (c == '}') depth -= 1;
        if (depth < 0) return false;
    }
    return depth == 0;
}

fn isJsonPointer(s: []const u8) bool {
    // RFC 6901: "" or ("/" reference-token)*
    if (s.len == 0) return true;
    if (s[0] != '/') return false;
    var i: usize = 1;
    while (i < s.len) {
        if (s[i] == '~') {
            if (i + 1 >= s.len) return false;
            if (s[i + 1] != '0' and s[i + 1] != '1') return false;
            i += 2;
        } else {
            i += 1;
        }
    }
    return true;
}

fn isRelativeJsonPointer(s: []const u8) bool {
    // non-negative-integer [json-pointer | "#"]
    if (s.len == 0) return false;
    var i: usize = 0;
    if (!std.ascii.isDigit(s[0])) return false;
    while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {}
    // Leading zeros not allowed (except "0" itself)
    if (i > 1 and s[0] == '0') return false;
    if (i == s.len) return true; // just a number
    if (s[i] == '#') return i + 1 == s.len;
    return isJsonPointer(s[i..]);
}

fn isRegex(s: []const u8) bool {
    // Check if s is a valid ECMA-262 regex by attempting POSIX ERE compilation.
    // Convert ECMA shortcuts first, then try to compile.
    const c = @import("../compiled.zig").c;
    const compiled_mod = @import("../compiled.zig");
    // Use a stack allocator for the conversion
    var buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const posix_pat = compiled_mod.convertEcmaToPostfix(fba.allocator(), s) catch s;
    const pat_z = fba.allocator().dupeZ(u8, posix_pat) catch return true; // can't check, assume valid
    const regex: *c.regex_t = @ptrCast(@alignCast(std.c.malloc(256) orelse return true));
    defer std.c.free(@ptrCast(regex));
    const result = c.regcomp(regex, pat_z.ptr, c.REG_EXTENDED | c.REG_NOSUB);
    if (result == 0) {
        c.regfree(regex);
        return true;
    }
    return false;
}

fn isUuid(s: []const u8) bool {
    // RFC 4122: 8-4-4-4-12 hex digits
    if (s.len != 36) return false;
    const pattern = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx";
    for (s, pattern) |c, p| {
        if (p == '-') {
            if (c != '-') return false;
        } else {
            if (!std.ascii.isHex(c)) return false;
        }
    }
    return true;
}

fn isDuration(s: []const u8) bool {
    // ISO 8601 / RFC 3339 Appendix A: PnYnMnDTnHnMnS
    if (s.len < 2 or s[0] != 'P') return false;
    var i: usize = 1;
    var has_t = false;
    var has_any = false;
    while (i < s.len) {
        if (s[i] == 'T') {
            has_t = true;
            i += 1;
            continue;
        }
        // Parse number
        const num_start = i;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {}
        if (i == num_start) return false; // expected a number
        if (i >= s.len) return false; // expected a designator
        const designator = s[i];
        if (has_t) {
            if (designator != 'H' and designator != 'M' and designator != 'S') return false;
        } else {
            if (designator == 'W') {
                // Week designator
                has_any = true;
                i += 1;
                return i == s.len;
            }
            if (designator != 'Y' and designator != 'M' and designator != 'D') return false;
        }
        has_any = true;
        i += 1;
    }
    return has_any;
}
