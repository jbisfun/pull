//! pullfile.plist (shared, committed) and local.toml (per machine).
//!
//! Only `identity` and `repos` belong to the core. Every other top-level key is a
//! *section* owned by an optional feature package (`env`, `lint`, `hooks`, `ignore`,
//! `jobs`, `tool`, `mcp_servers`, ...): it stays raw plist (in file order, written
//! between `identity` and `repos`) and its owner decodes it with `section`, so a
//! build without that feature still round-trips it.
const std = @import("std");
const toml = @import("toml");
const sys = @import("sys.zig");
const plist = @import("plist.zig");
const Allocator = std.mem.Allocator;

pub const PULLFILE = "pullfile.plist";
pub const LOCAL = "local.toml";

pub const EmailPolicy = enum {
    /// Commits carry an empty email (`Name <>`). Default.
    none,
    /// Use the email from local.toml if one is set.
    local,
};

pub const IdentityPolicy = struct {
    /// Selects `[orgs.<org>]` from local.toml.
    org: ?[]const u8 = null,
    email: EmailPolicy = .none,
    require_signing: bool = false,
};

pub const Repo = struct {
    /// Directory name under the pullfile root (may be nested: `group/name`).
    name: []const u8,
    upstream: []const u8,
    branch: []const u8 = "main",
    /// Pinned commit. Updated by `pull commit` / `pull update`.
    commit: ?[]const u8 = null,
};

pub const Pullfile = struct {
    /// Everything (sections, saved bytes) lives in this allocator: use an arena.
    a: Allocator,
    identity: IdentityPolicy = .{},
    /// Feature sections, in file order.
    sections: plist.Dict = .{},
    repos: std.ArrayList(Repo) = .empty,

    pub fn path(a: Allocator, root: []const u8) ![]u8 {
        return std.fs.path.join(a, &.{ root, PULLFILE });
    }

    pub fn load(a: Allocator, root: []const u8) !Pullfile {
        const p = try path(a, root);
        const data = sys.readFile(a, p) catch |e| return sys.context(e, "reading {s}", .{p});
        return parse(a, data) catch |e| sys.context(e, "reading {s}", .{p});
    }

    pub fn parse(a: Allocator, data: []const u8) !Pullfile {
        const root = plist.parse(a, data) catch |e| return sys.fail("{s}", .{@errorName(e)});
        const d = switch (root) {
            .dict => |d| d,
            else => return sys.fail("invalid type: expected a dictionary", .{}),
        };
        var pf: Pullfile = .{ .a = a };
        for (d.entries.items) |e| {
            if (std.mem.eql(u8, e.key, "identity")) {
                pf.identity = plist.decodeOr(IdentityPolicy, a, e.value) catch |err| return decodeFail(err, "identity");
            } else if (std.mem.eql(u8, e.key, "repos")) {
                plist.decode_path = "";
                const repos = plist.decode([]Repo, a, e.value) catch |err| return decodeFail(err, "repos");
                try pf.repos.appendSlice(a, repos);
            } else {
                try pf.sections.entries.append(a, e);
            }
        }
        return pf;
    }

    pub fn toValue(pf: Pullfile) !plist.Value {
        const a = pf.a;
        var d: plist.Dict = .{};
        var id: plist.Dict = .{};
        if (pf.identity.org) |o| try id.put(a, "org", .{ .string = o });
        try id.put(a, "email", .{ .string = @tagName(pf.identity.email) });
        try id.put(a, "require_signing", .{ .boolean = pf.identity.require_signing });
        try d.put(a, "identity", .{ .dict = id });
        for (pf.sections.entries.items) |e| try d.entries.append(a, e);
        var repos: std.ArrayList(plist.Value) = .empty;
        for (pf.repos.items) |r| {
            var rd: plist.Dict = .{};
            try rd.put(a, "name", .{ .string = r.name });
            try rd.put(a, "upstream", .{ .string = r.upstream });
            try rd.put(a, "branch", .{ .string = r.branch });
            if (r.commit) |c| try rd.put(a, "commit", .{ .string = c });
            try repos.append(a, .{ .dict = rd });
        }
        try d.put(a, "repos", .{ .array = repos });
        return .{ .dict = d };
    }

    pub fn serialize(pf: Pullfile) ![]u8 {
        return plist.write(pf.a, try pf.toValue());
    }

    pub fn save(pf: Pullfile, root: []const u8) !void {
        const p = try path(pf.a, root);
        const bytes = try pf.serialize();
        sys.writeFile(p, bytes) catch |e| return sys.context(e, "writing {s}", .{p});
    }

    pub fn repo(pf: *Pullfile, name: []const u8) ?*Repo {
        for (pf.repos.items) |*r| if (std.mem.eql(u8, r.name, name)) return r;
        return null;
    }

    pub fn repoNames(pf: Pullfile) ![]const []const u8 {
        const out = try pf.a.alloc([]const u8, pf.repos.items.len);
        for (pf.repos.items, out) |r, *o| o.* = r.name;
        return out;
    }

    pub fn hasSection(pf: Pullfile, key: []const u8) bool {
        return pf.sections.contains(key);
    }

    /// The raw section `key`.
    pub fn sectionValue(pf: Pullfile, key: []const u8) ?plist.Value {
        return pf.sections.get(key);
    }

    /// Decode the section `key` (its defaults when absent).
    pub fn section(pf: Pullfile, comptime T: type, key: []const u8) !T {
        return plist.decodeOr(T, pf.a, pf.sections.get(key)) catch |e| decodeFail(e, key);
    }

    /// Replace (or add) the section `key`, keeping its position.
    pub fn setSection(pf: *Pullfile, key: []const u8, v: plist.Value) !void {
        try pf.sections.put(pf.a, key, v);
    }
};

fn decodeFail(e: anyerror, key: []const u8) error{Fail} {
    if (e == error.InvalidType) return sys.fail("{s}: `{s}`: {s}", .{ PULLFILE, key, plist.decode_path });
    return sys.fail("{s}: `{s}`: {s}", .{ PULLFILE, key, @errorName(e) });
}

// ---------------------------------------------------------------- local.toml

pub const OrgIdentity = struct {
    name: ?[]const u8 = null,
    email: ?[]const u8 = null,
    signing_key: ?[]const u8 = null,
    sign: ?bool = null,
};

pub const Local = struct {
    /// Handle shown as author/committer name.
    name: []const u8 = "",
    email: ?[]const u8 = null,
    /// GPG key id/fingerprint. If unset and signing is on, gpg's default key is used.
    signing_key: ?[]const u8 = null,
    sign: bool = false,
    gpg_program: ?[]const u8 = null,
    orgs: plist.Map(OrgIdentity) = .{},
    /// Every table/key besides the above (e.g. `[env]`), converted to plist values
    /// so features decode them like pullfile sections.
    sections: plist.Dict = .{},
    a: Allocator,

    /// `{root}/local.toml`, falling back to `$XDG_CONFIG_HOME/pull/local.toml`
    /// (`~/.config/pull/local.toml`).
    pub fn path(a: Allocator, root: []const u8) !?[]const u8 {
        const here = try std.fs.path.join(a, &.{ root, LOCAL });
        if (sys.exists(here)) return here;
        const global = try std.fs.path.join(a, &.{ (try configDir(a)) orelse return null, "pull", LOCAL });
        return if (sys.exists(global)) global else null;
    }

    pub fn load(a: Allocator, root: []const u8) !Local {
        const p = (try path(a, root)) orelse
            return sys.fail("no {s} found in {s} or ~/.config/pull (run `pull init`)", .{ LOCAL, root });
        const data = sys.readFile(a, p) catch |e| return sys.context(e, "reading {s}", .{p});
        return parse(a, data) catch |e| sys.context(e, "parsing {s}", .{p});
    }

    pub fn parse(a: Allocator, data: []const u8) !Local {
        var parser = toml.Parser(toml.Table).init(a);
        const parsed = parser.parseString(data) catch |e| {
            if (parser.error_info) |info| if (info == .parse) {
                return sys.fail("TOML parse error at line {d}, column {d}", .{ info.parse.line, info.parse.pos });
            };
            return sys.fail("{s}", .{@errorName(e)});
        };
        const v = try tomlToPlist(a, .{ .table = @constCast(&parsed.value) });
        var l: Local = .{ .a = a };
        plist.decode_path = "";
        for (v.dict.entries.items) |e| {
            const k = e.key;
            if (std.mem.eql(u8, k, "name")) {
                l.name = plist.decode([]const u8, a, e.value) catch return localFail("name");
            } else if (std.mem.eql(u8, k, "email")) {
                l.email = plist.decode([]const u8, a, e.value) catch return localFail("email");
            } else if (std.mem.eql(u8, k, "signing_key")) {
                l.signing_key = plist.decode([]const u8, a, e.value) catch return localFail("signing_key");
            } else if (std.mem.eql(u8, k, "sign")) {
                l.sign = plist.decode(bool, a, e.value) catch return localFail("sign");
            } else if (std.mem.eql(u8, k, "gpg_program")) {
                l.gpg_program = plist.decode([]const u8, a, e.value) catch return localFail("gpg_program");
            } else if (std.mem.eql(u8, k, "orgs")) {
                l.orgs = plist.decode(plist.Map(OrgIdentity), a, e.value) catch return localFail("orgs");
            } else {
                try l.sections.entries.append(a, e);
            }
        }
        if (!v.dict.contains("name")) return sys.fail("missing field `name`", .{});
        return l;
    }

    /// Decode the table `key` (its defaults when absent).
    pub fn section(l: Local, comptime T: type, key: []const u8) !T {
        return plist.decodeOr(T, l.a, l.sections.get(key)) catch
            sys.fail("{s}: `[{s}]`: {s}", .{ LOCAL, key, plist.decode_path });
    }

    /// What `pull init` writes (toml crate's `to_string_pretty` of a fresh Local).
    pub fn initText(a: Allocator, name: []const u8, org: ?[]const u8) ![]u8 {
        var w: std.Io.Writer.Allocating = .init(a);
        try w.writer.writeAll("name = ");
        try tomlString(&w.writer, name);
        try w.writer.writeAll("\nsign = false\n\n");
        if (org) |o| {
            try w.writer.writeAll("[orgs.");
            if (isBareKey(o)) try w.writer.writeAll(o) else try tomlString(&w.writer, o);
            try w.writer.writeAll("]\n");
        } else try w.writer.writeAll("[orgs]\n");
        return w.toOwnedSlice();
    }
};

fn localFail(key: []const u8) error{Fail} {
    return sys.fail("{s}: `{s}`: {s}", .{ LOCAL, key, plist.decode_path });
}

/// `dirs::config_dir()`: $XDG_CONFIG_HOME if absolute, else ~/.config.
pub fn configDir(a: Allocator) !?[]const u8 {
    if (sys.getenv("XDG_CONFIG_HOME")) |x| if (std.fs.path.isAbsolute(x)) return x;
    const h = sys.home() orelse return null;
    return try std.fs.path.join(a, &.{ h, ".config" });
}

fn isBareKey(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) return false;
    return true;
}

fn tomlString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\t' => try w.writeAll("\\t"),
        '\r' => try w.writeAll("\\r"),
        0...8, 11, 12, 14...31, 127 => try w.print("\\u{X:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

/// TOML values as plist values (tables -> dicts with keys sorted, like toml::Table).
fn tomlToPlist(a: Allocator, v: toml.Value) !plist.Value {
    return switch (v) {
        .string => |s| .{ .string = s },
        .integer => |n| .{ .integer = n },
        .float => |f| .{ .real = f },
        .boolean => |b| .{ .boolean = b },
        .date, .time, .datetime => .{ .string = "" },
        .array => |arr| blk: {
            var out: std.ArrayList(plist.Value) = .empty;
            for (arr.items) |item| try out.append(a, try tomlToPlist(a, item));
            break :blk .{ .array = out };
        },
        .table => |t| blk: {
            var keys: std.ArrayList([]const u8) = .empty;
            var it = t.iterator();
            while (it.next()) |e| try keys.append(a, e.key_ptr.*);
            std.mem.sort([]const u8, keys.items, {}, struct {
                fn lt(_: void, x: []const u8, y: []const u8) bool {
                    return std.mem.lessThan(u8, x, y);
                }
            }.lt);
            var d: plist.Dict = .{};
            for (keys.items) |k| try d.entries.append(a, .{ .key = k, .value = try tomlToPlist(a, t.get(k).?) });
            break :blk .{ .dict = d };
        },
    };
}

// ---------------------------------------------------------------- identity

/// The identity actually written into commits.
pub const Identity = struct {
    name: []const u8,
    email: []const u8,
    sign: bool,
    signing_key: ?[]const u8,
    gpg_program: []const u8,
};

pub fn resolveIdentity(pf: Pullfile, local: Local) !Identity {
    const org: ?OrgIdentity = if (pf.identity.org) |o|
        local.orgs.get(o) orelse return sys.fail("pullfile wants org `{s}` but local.toml has no [orgs.{s}]", .{ o, o })
    else
        null;
    const name = if (org) |o| o.name orelse local.name else local.name;
    if (std.mem.trim(u8, name, " \t\r\n").len == 0) return sys.fail("local.toml: `name` is empty", .{});
    const email: []const u8 = switch (pf.identity.email) {
        .none => "",
        .local => (if (org) |o| o.email else null) orelse local.email orelse "",
    };
    const sign = ((if (org) |o| o.sign else null) orelse local.sign) or pf.identity.require_signing;
    const signing_key = (if (org) |o| o.signing_key else null) orelse local.signing_key;
    return .{
        .name = name,
        .email = email,
        .sign = sign,
        .signing_key = signing_key,
        .gpg_program = local.gpg_program orelse "gpg",
    };
}

/// Walk up from `start` to the directory containing pullfile.plist.
pub fn findRoot(a: Allocator, start: []const u8) ![]const u8 {
    var d: []const u8 = sys.realpath(a, start) catch |e| return sys.fail("{s}", .{sys.describe(e)});
    while (true) {
        const p = try std.fs.path.join(a, &.{ d, PULLFILE });
        if (sys.isFile(p)) return d;
        d = std.fs.path.dirname(d) orelse
            return sys.fail("no {s} found in {s} or any parent (run `pull init`)", .{ PULLFILE, start });
    }
}

test "unknown sections round trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<plist version="1.0"><dict>
        \\  <key>identity</key><dict><key>email</key><string>none</string></dict>
        \\  <key>lint</key><dict><key>max_subject_length</key><integer>40</integer></dict>
        \\  <key>repos</key><array><dict><key>name</key><string>a</string><key>upstream</key><string>u</string></dict></array>
        \\  <key>jobs</key><array><dict><key>Label</key><string>x</string><key>RunAtLoad</key><true/></dict></array>
        \\</dict></plist>
    ;
    var pf = try Pullfile.parse(a, src);
    try std.testing.expectEqualStrings("main", pf.repos.items[0].branch);
    try std.testing.expectEqual(@as(usize, 2), pf.sections.entries.items.len);
    try std.testing.expectEqualStrings("lint", pf.sections.entries.items[0].key);
    try std.testing.expectEqualStrings("jobs", pf.sections.entries.items[1].key);
    const Lint = struct { max_subject_length: ?u64 = null };
    try std.testing.expectEqual(@as(?u64, 40), (try pf.section(Lint, "lint")).max_subject_length);
    try std.testing.expectEqual(@as(?u64, null), (try pf.section(Lint, "nope")).max_subject_length);
    const out = try pf.serialize();
    const back = try Pullfile.parse(a, out);
    try std.testing.expect((plist.Value{ .dict = back.sections }).eql(.{ .dict = pf.sections }));
}

test "local sections" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const l = try Local.parse(a, "name = \"jp\"\n[env]\npath = [\"/x\"]\n[orgs.acme]\nname = \"jp@acme\"\n");
    const Env = struct { path: []const []const u8 = &.{} };
    try std.testing.expectEqualStrings("/x", (try l.section(Env, "env")).path[0]);
    try std.testing.expectEqualStrings("jp@acme", l.orgs.get("acme").?.name.?);
    try std.testing.expectEqualStrings("name = \"jp\"\nsign = false\n\n[orgs]\n", try Local.initText(a, "jp", null));
    try std.testing.expectEqualStrings("name = \"jp\"\nsign = false\n\n[orgs.acme]\n", try Local.initText(a, "jp", "acme"));
}

test "golden pullfile round trip" {
    // The real workspace pullfile, as the Rust plist crate wrote it.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = @embedFile("testdata/pullfile.plist");
    const pf = try Pullfile.parse(a, src);
    try std.testing.expectEqualStrings(src, try pf.serialize());
}
