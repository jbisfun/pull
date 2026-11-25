//! XML property lists: a `Value` tree parsed with the `xml` package and written
//! byte-for-byte like the Rust `plist` crate (tab indentation, quick-xml escaping,
//! `<array/>`/`<dict/>` for empty collections, no trailing newline), so pull can
//! rewrite a pullfile another build wrote without any diff.
//!
//! `decode` maps a Value onto a Zig type the way serde would (struct fields by key,
//! missing fields take their defaults, unknown keys are ignored).
const std = @import("std");
const xml = @import("xml");
const Allocator = std.mem.Allocator;

pub const Value = union(enum) {
    string: []const u8,
    integer: i128,
    real: f64,
    boolean: bool,
    /// RFC 3339 text, kept verbatim.
    date: []const u8,
    /// Decoded bytes.
    data: []const u8,
    array: std.ArrayList(Value),
    dict: Dict,

    pub fn eql(a: Value, b: Value) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .string => |s| std.mem.eql(u8, s, b.string),
            .integer => |i| i == b.integer,
            .real => |r| r == b.real,
            .boolean => |x| x == b.boolean,
            .date => |s| std.mem.eql(u8, s, b.date),
            .data => |s| std.mem.eql(u8, s, b.data),
            .array => |arr| blk: {
                if (arr.items.len != b.array.items.len) break :blk false;
                for (arr.items, b.array.items) |x, y| if (!x.eql(y)) break :blk false;
                break :blk true;
            },
            .dict => |d| blk: {
                if (d.entries.items.len != b.dict.entries.items.len) break :blk false;
                for (d.entries.items, b.dict.entries.items) |x, y| {
                    if (!std.mem.eql(u8, x.key, y.key) or !x.value.eql(y.value)) break :blk false;
                }
                break :blk true;
            },
        };
    }
};

/// An insertion-ordered dictionary (plist dictionaries keep file order).
pub const Dict = struct {
    entries: std.ArrayList(Entry) = .empty,

    pub const Entry = struct { key: []const u8, value: Value };

    pub fn get(d: Dict, key: []const u8) ?Value {
        for (d.entries.items) |e| if (std.mem.eql(u8, e.key, key)) return e.value;
        return null;
    }

    pub fn getPtr(d: *Dict, key: []const u8) ?*Value {
        for (d.entries.items) |*e| if (std.mem.eql(u8, e.key, key)) return &e.value;
        return null;
    }

    pub fn contains(d: Dict, key: []const u8) bool {
        return d.get(key) != null;
    }

    /// Replace the value of `key` in place, or append it.
    pub fn put(d: *Dict, a: Allocator, key: []const u8, value: Value) !void {
        if (d.getPtr(key)) |p| {
            p.* = value;
            return;
        }
        try d.entries.append(a, .{ .key = key, .value = value });
    }

    pub fn remove(d: *Dict, key: []const u8) bool {
        for (d.entries.items, 0..) |e, i| if (std.mem.eql(u8, e.key, key)) {
            _ = d.entries.orderedRemove(i);
            return true;
        };
        return false;
    }
};

// ---------------------------------------------------------------- parsing

pub const ParseError = error{ MalformedXml, InvalidPlist } || Allocator.Error;

/// Parse an XML plist document; everything is allocated in `a` (use an arena).
pub fn parse(a: Allocator, data: []const u8) ParseError!Value {
    var static_reader: xml.Reader.Static = .init(a, data, .{ .namespace_aware = false });
    defer static_reader.deinit();
    const r = &static_reader.interface;
    // Find <plist> (or a bare root value).
    while (true) {
        const node = r.read() catch return error.MalformedXml;
        switch (node) {
            .eof => return error.InvalidPlist,
            .element_start => {
                if (std.mem.eql(u8, r.elementName(), "plist")) {
                    const v = (try nextValue(a, r)) orelse return error.InvalidPlist;
                    return v;
                }
                return parseElement(a, r);
            },
            else => {},
        }
    }
}

/// The next child value of the current container, or null at its end tag.
fn nextValue(a: Allocator, r: *xml.Reader) ParseError!?Value {
    while (true) {
        const node = r.read() catch return error.MalformedXml;
        switch (node) {
            .element_start => return try parseElement(a, r),
            .element_end, .eof => return null,
            .text => if (std.mem.trim(u8, r.textRaw(), " \t\r\n").len != 0) return error.InvalidPlist,
            else => {},
        }
    }
}

fn readText(a: Allocator, r: *xml.Reader) ParseError![]u8 {
    return r.readElementTextAlloc(a) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.MalformedXml,
    };
}

fn parseElement(a: Allocator, r: *xml.Reader) ParseError!Value {
    const name = r.elementName();
    if (std.mem.eql(u8, name, "dict")) {
        var d: Dict = .{};
        while (true) {
            const node = r.read() catch return error.MalformedXml;
            switch (node) {
                .element_start => {
                    if (!std.mem.eql(u8, r.elementName(), "key")) return error.InvalidPlist;
                    const key = try readText(a, r);
                    const v = (try nextValue(a, r)) orelse return error.InvalidPlist;
                    try d.entries.append(a, .{ .key = key, .value = v });
                },
                .element_end => return .{ .dict = d },
                .eof => return error.InvalidPlist,
                else => {},
            }
        }
    }
    if (std.mem.eql(u8, name, "array")) {
        var arr: std.ArrayList(Value) = .empty;
        while (try nextValue(a, r)) |v| try arr.append(a, v);
        return .{ .array = arr };
    }
    if (std.mem.eql(u8, name, "true") or std.mem.eql(u8, name, "false")) {
        const b = name[0] == 't';
        _ = try readText(a, r);
        return .{ .boolean = b };
    }
    // Copy the name: reading text invalidates it.
    var name_buf: [16]u8 = undefined;
    if (name.len > name_buf.len) return error.InvalidPlist;
    @memcpy(name_buf[0..name.len], name);
    const tag = name_buf[0..name.len];
    const text = try readText(a, r);
    if (std.mem.eql(u8, tag, "string")) return .{ .string = text };
    if (std.mem.eql(u8, tag, "integer")) {
        const t = std.mem.trim(u8, text, " \t\r\n");
        const neg = t.len > 0 and t[0] == '-';
        const digits = if (neg) t[1..] else t;
        const n: i128 = if (std.ascii.startsWithIgnoreCase(digits, "0x"))
            std.fmt.parseInt(i128, digits[2..], 16) catch return error.InvalidPlist
        else
            std.fmt.parseInt(i128, digits, 10) catch return error.InvalidPlist;
        return .{ .integer = if (neg) -n else n };
    }
    if (std.mem.eql(u8, tag, "real")) {
        return .{ .real = std.fmt.parseFloat(f64, std.mem.trim(u8, text, " \t\r\n")) catch return error.InvalidPlist };
    }
    if (std.mem.eql(u8, tag, "date")) return .{ .date = std.mem.trim(u8, text, " \t\r\n") };
    if (std.mem.eql(u8, tag, "data")) {
        var clean: std.ArrayList(u8) = .empty;
        for (text) |c| if (!std.ascii.isWhitespace(c)) try clean.append(a, c);
        const dec = std.base64.standard.Decoder;
        const n = dec.calcSizeForSlice(clean.items) catch return error.InvalidPlist;
        const out = try a.alloc(u8, n);
        dec.decode(out, clean.items) catch return error.InvalidPlist;
        return .{ .data = out };
    }
    return error.InvalidPlist;
}

// ---------------------------------------------------------------- writing

const prologue =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    \\<plist version="1.0">
    \\
;

/// Serialize like `plist::to_file_xml` (plist crate 1.10, quick-xml 0.42).
pub fn write(a: Allocator, v: Value) Allocator.Error![]u8 {
    var w: std.Io.Writer.Allocating = .init(a);
    writeTo(&w.writer, v) catch return error.OutOfMemory;
    return w.toOwnedSlice();
}

pub fn writeTo(w: *std.Io.Writer, v: Value) std.Io.Writer.Error!void {
    try w.writeAll(prologue);
    try writeValue(w, v, 0, true);
    try w.writeAll("\n</plist>");
}

fn newline(w: *std.Io.Writer, depth: usize, first: bool) !void {
    if (!first) try w.writeByte('\n');
    try w.splatByteAll('\t', depth);
}

fn writeValue(w: *std.Io.Writer, v: Value, depth: usize, first: bool) std.Io.Writer.Error!void {
    try newline(w, depth, first);
    switch (v) {
        .string => |s| try element(w, "string", s),
        .integer => |n| try w.print("<integer>{d}</integer>", .{n}),
        .real => |f| {
            try w.writeAll("<real>");
            try writeReal(w, f);
            try w.writeAll("</real>");
        },
        .boolean => |b| try w.writeAll(if (b) "<true/>" else "<false/>"),
        .date => |s| try element(w, "date", s),
        .data => |bytes| {
            try w.writeAll("<data>");
            const enc = std.base64.standard.Encoder;
            var line_buf: [68]u8 = undefined;
            var i: usize = 0;
            while (i < bytes.len) : (i += 51) {
                const chunk = bytes[i..@min(i + 51, bytes.len)];
                try w.writeByte('\n');
                try w.splatByteAll('\t', depth);
                try w.writeAll(enc.encode(&line_buf, chunk));
            }
            try newline(w, depth, false);
            try w.writeAll("</data>");
        },
        .array => |arr| {
            if (arr.items.len == 0) return w.writeAll("<array/>");
            try w.writeAll("<array>");
            for (arr.items) |item| try writeValue(w, item, depth + 1, false);
            try newline(w, depth, false);
            try w.writeAll("</array>");
        },
        .dict => |d| {
            if (d.entries.items.len == 0) return w.writeAll("<dict/>");
            try w.writeAll("<dict>");
            for (d.entries.items) |e| {
                try newline(w, depth + 1, false);
                try element(w, "key", e.key);
                try writeValue(w, e.value, depth + 1, false);
            }
            try newline(w, depth, false);
            try w.writeAll("</dict>");
        },
    }
}

fn element(w: *std.Io.Writer, tag: []const u8, text: []const u8) !void {
    try w.print("<{s}>", .{tag});
    try escape(w, text);
    try w.print("</{s}>", .{tag});
}

/// quick-xml `escape`: < > & ' " and \r.
pub fn escape(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| switch (c) {
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '&' => try w.writeAll("&amp;"),
        '\'' => try w.writeAll("&apos;"),
        '"' => try w.writeAll("&quot;"),
        '\r' => try w.writeAll("&#13;"),
        else => try w.writeByte(c),
    };
}

/// Rust's f64 Display: integral values without a fraction ("1"), else shortest repr.
fn writeReal(w: *std.Io.Writer, f: f64) !void {
    if (f == @trunc(f) and @abs(f) < 1e16) return w.print("{d}", .{@as(i64, @intFromFloat(f))});
    try w.print("{d}", .{f});
}

// ---------------------------------------------------------------- decoding

pub const DecodeError = error{InvalidType} || Allocator.Error;

/// Where decoding failed (field path), for error messages.
pub var decode_path_buf: [256]u8 = undefined;
pub var decode_path: []const u8 = "";

/// An insertion-ordered string map decoded from a dict.
pub fn Map(comptime V: type) type {
    return struct {
        keys: []const []const u8 = &.{},
        values: []const V = &.{},
        pub const is_plist_map = true;

        pub fn get(m: @This(), key: []const u8) ?V {
            for (m.keys, m.values) |k, v| if (std.mem.eql(u8, k, key)) return v;
            return null;
        }
    };
}

fn setPath(comptime fmt: []const u8, args: anytype) void {
    decode_path = std.fmt.bufPrint(&decode_path_buf, fmt, args) catch "";
}

pub fn decode(comptime T: type, a: Allocator, v: Value) DecodeError!T {
    if (T == Value) return v;
    switch (@typeInfo(T)) {
        .bool => return switch (v) {
            .boolean => |b| b,
            else => invalid("a boolean", v),
        },
        .int => return switch (v) {
            .integer => |n| std.math.cast(T, n) orelse invalid("an integer in range", v),
            else => invalid("an integer", v),
        },
        .float => return switch (v) {
            .real => |f| @floatCast(f),
            .integer => |n| @floatFromInt(n),
            else => invalid("a real", v),
        },
        .optional => |o| return try decode(o.child, a, v),
        .@"enum" => |e| {
            const s = switch (v) {
                .string => |s| s,
                else => return invalid("a string", v),
            };
            inline for (e.field_names) |n| if (std.mem.eql(u8, n, s)) return @field(T, n);
            setPath("unknown variant `{s}`", .{s});
            return error.InvalidType;
        },
        .pointer => |p| {
            if (p.size != .slice) @compileError("unsupported " ++ @typeName(T));
            if (p.child == u8) return switch (v) {
                .string => |s| s,
                else => invalid("a string", v),
            };
            const arr = switch (v) {
                .array => |arr| arr,
                else => return invalid("an array", v),
            };
            const out = try a.alloc(p.child, arr.items.len);
            for (arr.items, out) |item, *o| o.* = try decode(p.child, a, item);
            return out;
        },
        .@"struct" => |s| {
            if (@hasDecl(T, "decodePlist")) return T.decodePlist(a, v);
            const d = switch (v) {
                .dict => |d| d,
                else => return invalid("a dictionary", v),
            };
            if (@hasDecl(T, "is_plist_map")) {
                const V = @typeInfo(@FieldType(T, "values")).pointer.child;
                const keys = try a.alloc([]const u8, d.entries.items.len);
                const values = try a.alloc(V, d.entries.items.len);
                for (d.entries.items, keys, values) |e, *k, *val| {
                    k.* = e.key;
                    val.* = try decode(V, a, e.value);
                }
                return .{ .keys = keys, .values = values };
            }
            var out: T = undefined;
            inline for (s.field_names, s.field_types, s.field_attrs) |name, FT, attrs| {
                if (d.get(name)) |fv| {
                    @field(out, name) = decode(FT, a, fv) catch |e| {
                        if (e == error.InvalidType and decode_path.len == 0) setPath("field `{s}`", .{name});
                        return e;
                    };
                } else if (comptime attrs.defaultValue(FT)) |dv| {
                    @field(out, name) = dv;
                } else if (@typeInfo(FT) == .optional) {
                    @field(out, name) = null;
                } else {
                    setPath("missing field `{s}`", .{name});
                    return error.InvalidType;
                }
            }
            return out;
        },
        else => @compileError("unsupported " ++ @typeName(T)),
    }
}

fn invalid(comptime want: []const u8, v: Value) error{InvalidType} {
    setPath("invalid type: {s}, expected " ++ want, .{@tagName(v)});
    return error.InvalidType;
}

/// Decode an optional section: absent -> `T{}` defaults.
pub fn decodeOr(comptime T: type, a: Allocator, v: ?Value) DecodeError!T {
    decode_path = "";
    const val = v orelse return if (@typeInfo(T) == .pointer) &.{} else .{};
    return decode(T, a, val);
}

// ---------------------------------------------------------------- building

pub fn string(s: []const u8) Value {
    return .{ .string = s };
}

pub fn stringArray(a: Allocator, items: []const []const u8) !Value {
    var arr: std.ArrayList(Value) = .empty;
    for (items) |s| try arr.append(a, .{ .string = s });
    return .{ .array = arr };
}

test "round trip plist-crate formatting" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" ++
        "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n" ++
        "<plist version=\"1.0\">\n" ++
        "<dict>\n" ++
        "\t<key>a</key>\n" ++
        "\t<string>x &quot;q&quot; &amp;&amp; &lt;y&gt; it&apos;s</string>\n" ++
        "\t<key>e</key>\n" ++
        "\t<array/>\n" ++
        "\t<key>d</key>\n" ++
        "\t<dict/>\n" ++
        "\t<key>n</key>\n" ++
        "\t<integer>40</integer>\n" ++
        "\t<key>b</key>\n" ++
        "\t<true/>\n" ++
        "\t<key>arr</key>\n" ++
        "\t<array>\n" ++
        "\t\t<dict>\n" ++
        "\t\t\t<key>k</key>\n" ++
        "\t\t\t<false/>\n" ++
        "\t\t</dict>\n" ++
        "\t</array>\n" ++
        "</dict>\n" ++
        "</plist>";
    const v = try parse(a, src);
    try std.testing.expectEqualStrings("x \"q\" && <y> it's", v.dict.get("a").?.string);
    try std.testing.expectEqualStrings(src, try write(a, v));
}
