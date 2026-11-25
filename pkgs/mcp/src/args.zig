//! Tool arguments, checked the way serde checked the Rust server's argument structs,
//! with the same messages ("missing field `path`", "invalid type: integer `5`,
//! expected a string"): object keys in sorted order (serde_json's map), then the
//! required fields that are missing. Unknown keys are ignored.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const Kind = enum {
    string,
    opt_string,
    /// `Option<usize>`.
    opt_usize,
    /// `Option<u64>`.
    opt_u64,
    /// `bool` with `#[serde(default)]`.
    boolean,
    /// `Vec<String>` with `#[serde(default)]`.
    string_list,
    /// `BTreeMap<String, String>` with `#[serde(default)]`.
    string_map,
};

pub const Field = struct { []const u8, Kind };

/// Arguments of one call, already checked against their fields.
pub const Args = struct {
    obj: std.json.ObjectMap,

    fn get(args: Args, key: []const u8) ?Value {
        const v = args.obj.get(key) orelse return null;
        return if (v == .null) null else v;
    }

    pub fn str(args: Args, key: []const u8) ?[]const u8 {
        return if (args.get(key)) |v| v.string else null;
    }

    pub fn int(args: Args, key: []const u8) ?u64 {
        const v = args.get(key) orelse return null;
        return switch (v) {
            .integer => |i| @intCast(i),
            .number_string => |s| std.fmt.parseInt(u64, s, 10) catch std.math.maxInt(u64),
            else => unreachable,
        };
    }

    pub fn flag(args: Args, key: []const u8) bool {
        return if (args.get(key)) |v| v.bool else false;
    }

    pub fn list(args: Args, a: Allocator, key: []const u8) ![]const []const u8 {
        const v = args.get(key) orelse return &.{};
        const out = try a.alloc([]const u8, v.array.items.len);
        for (out, v.array.items) |*o, x| o.* = x.string;
        return out;
    }

    pub fn map(args: Args, key: []const u8) ?std.json.ObjectMap {
        return if (args.get(key)) |v| v.object else null;
    }
};

/// Parse and check `raw` (the call's `arguments`, absent = `{}`): the args, or
/// the message the Rust server answered ("failed to deserialize parameters: ...").
pub fn parse(a: Allocator, raw: ?[]const u8, fields: []const Field) !union(enum) { ok: Args, err: []const u8 } {
    var obj: std.json.ObjectMap = .empty;
    if (raw) |bytes| {
        const v = std.json.parseFromSliceLeaky(Value, a, bytes, .{}) catch return .{ .err = "failed to deserialize parameters: invalid JSON" };
        if (v == .object) obj = v.object;
    }
    const keys = try a.dupe([]const u8, obj.keys());
    std.mem.sort([]const u8, keys, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    for (keys) |k| for (fields) |f| {
        if (!std.mem.eql(u8, f[0], k)) continue;
        if (try check(a, obj.get(k).?, f[1])) |msg| return .{ .err = try std.fmt.allocPrint(a, "failed to deserialize parameters: {s}", .{msg}) };
    };
    for (fields) |f| if (f[1] == .string and !obj.contains(f[0]))
        return .{ .err = try std.fmt.allocPrint(a, "failed to deserialize parameters: missing field `{s}`", .{f[0]}) };
    return .{ .ok = .{ .obj = obj } };
}

fn check(a: Allocator, v: Value, kind: Kind) !?[]const u8 {
    switch (kind) {
        .opt_string, .opt_usize, .opt_u64 => if (v == .null) return null,
        else => {},
    }
    return switch (kind) {
        .string, .opt_string => if (v == .string) null else try invalid(a, v, "a string"),
        .boolean => if (v == .bool) null else try invalid(a, v, "a boolean"),
        .opt_usize, .opt_u64 => {
            const name = if (kind == .opt_usize) "usize" else "u64";
            return switch (v) {
                .integer => |i| if (i < 0) try std.fmt.allocPrint(a, "invalid value: integer `{d}`, expected {s}", .{ i, name }) else null,
                .number_string => |s| if (s.len > 0 and s[0] == '-') try std.fmt.allocPrint(a, "invalid value: integer `{s}`, expected {s}", .{ s, name }) else null,
                else => try invalid(a, v, name),
            };
        },
        .string_list => switch (v) {
            .array => |arr| {
                for (arr.items) |x| if (x != .string) return try invalid(a, x, "a string");
                return null;
            },
            else => try invalid(a, v, "a sequence"),
        },
        .string_map => switch (v) {
            .object => |m| {
                for (m.values()) |x| if (x != .string) return try invalid(a, x, "a string");
                return null;
            },
            else => try invalid(a, v, "a map"),
        },
    };
}

/// serde's `invalid type: {unexpected}, expected {what}`.
fn invalid(a: Allocator, v: Value, what: []const u8) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(a);
    const o = &w.writer;
    try o.writeAll("invalid type: ");
    switch (v) {
        .null => try o.writeAll("null"),
        .bool => |b| try o.print("boolean `{}`", .{b}),
        .integer => |i| try o.print("integer `{d}`", .{i}),
        .number_string => |s| try o.print("integer `{s}`", .{s}),
        .float => |f| {
            var buf: [64]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{f}) catch "?";
            const dotted = std.mem.indexOfAny(u8, s, ".eEn") != null;
            try o.print("floating point `{s}{s}`", .{ s, if (dotted) "" else ".0" });
        },
        .string => |s| {
            try o.writeAll("string ");
            try debugStr(o, s);
        },
        .array => try o.writeAll("sequence"),
        .object => try o.writeAll("map"),
    }
    try o.print(", expected {s}", .{what});
    return w.written();
}

/// Rust's `{:?}` of a str.
fn debugStr(o: *std.Io.Writer, s: []const u8) !void {
    try o.writeByte('"');
    const view = std.unicode.Utf8View.init(s) catch {
        try o.writeAll(s);
        return o.writeByte('"');
    };
    var it = view.iterator();
    while (it.nextCodepoint()) |c| switch (c) {
        '"' => try o.writeAll("\\\""),
        '\\' => try o.writeAll("\\\\"),
        '\n' => try o.writeAll("\\n"),
        '\r' => try o.writeAll("\\r"),
        '\t' => try o.writeAll("\\t"),
        0 => try o.writeAll("\\0"),
        else => if (c < 0x20 or c == 0x7f) try o.print("\\u{{{x}}}", .{c}) else try o.print("{u}", .{c}),
    };
    try o.writeByte('"');
}

test parse {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fields = [_]Field{ .{ "path", .string }, .{ "start_line", .opt_usize } };
    try std.testing.expectEqualStrings("failed to deserialize parameters: missing field `path`", (try parse(a, "{}", &fields)).err);
    try std.testing.expectEqualStrings("failed to deserialize parameters: invalid type: integer `5`, expected a string", (try parse(a, "{\"path\":5}", &fields)).err);
    try std.testing.expectEqualStrings("failed to deserialize parameters: invalid type: string \"3\", expected usize", (try parse(a, "{\"path\":\"x\",\"start_line\":\"3\"}", &fields)).err);
    try std.testing.expectEqualStrings("failed to deserialize parameters: invalid value: integer `-1`, expected usize", (try parse(a, "{\"path\":\"x\",\"start_line\":-1}", &fields)).err);
    try std.testing.expectEqualStrings("failed to deserialize parameters: invalid type: floating point `1.5`, expected usize", (try parse(a, "{\"path\":\"x\",\"start_line\":1.5}", &fields)).err);
    const ok = (try parse(a, "{\"path\":\"x\",\"start_line\":null}", &fields)).ok;
    try std.testing.expectEqualStrings("x", ok.str("path").?);
    try std.testing.expectEqual(@as(?u64, null), ok.int("start_line"));
}
