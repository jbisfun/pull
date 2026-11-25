//! Paths in a workspace: routing user paths to repos, root-level ignore files.
const std = @import("std");
const sys = @import("sys.zig");
const pullfile = @import("pullfile.zig");
const Allocator = std.mem.Allocator;

/// Repo name -> repo-relative pathspecs, sorted by repo name (Rust BTreeMap).
pub const Routed = struct {
    names: std.ArrayList([]const u8) = .empty,
    specs: std.ArrayList(std.ArrayList([]const u8)) = .empty,

    pub fn get(r: Routed, name: []const u8) ?[]const []const u8 {
        for (r.names.items, r.specs.items) |n, s| if (std.mem.eql(u8, n, name)) return s.items;
        return null;
    }

    fn push(r: *Routed, a: Allocator, name: []const u8, spec: []const u8) !void {
        for (r.names.items, r.specs.items) |n, *s| if (std.mem.eql(u8, n, name)) return s.append(a, spec);
        var i: usize = 0;
        while (i < r.names.items.len and std.mem.lessThan(u8, r.names.items[i], name)) i += 1;
        var list: std.ArrayList([]const u8) = .empty;
        try list.append(a, spec);
        try r.names.insert(a, i, name);
        try r.specs.insert(a, i, list);
    }
};

/// `rel` with the leading components `prefix` removed (component-wise, like
/// Rust's Path::strip_prefix), or null if `prefix` isn't a prefix.
pub fn stripPrefix(rel: []const u8, prefix: []const u8) ?[]const u8 {
    var ri = std.mem.tokenizeScalar(u8, rel, '/');
    var pi = std.mem.tokenizeScalar(u8, prefix, '/');
    while (pi.next()) |pc| {
        if (std.mem.eql(u8, pc, ".")) continue;
        var rc = ri.next() orelse return null;
        while (std.mem.eql(u8, rc, ".")) rc = ri.next() orelse return null;
        if (!std.mem.eql(u8, rc, pc)) return null;
    }
    return std.mem.trim(u8, ri.rest(), "/");
}

fn componentCount(p: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.tokenizeScalar(u8, p, '/');
    while (it.next()) |c| {
        if (!std.mem.eql(u8, c, ".")) n += 1;
    }
    return n;
}

/// Map user paths onto (repo name -> repo-relative pathspecs), CODEOWNERS-style:
/// the repo whose directory (its name, possibly nested like `group/repo`) is the
/// longest prefix of the path picks the repo. The root itself means everything.
pub fn route(a: Allocator, root: []const u8, pf: pullfile.Pullfile, cwd: []const u8, paths: []const []const u8) !Routed {
    var out: Routed = .{};
    for (paths) |p| {
        const joined = try std.fs.path.resolve(a, &.{ cwd, p });
        const abs = try absolutize(a, joined);
        const rel = stripPrefix(abs, root) orelse
            return sys.fail("{s} is outside the pullfile root", .{p});
        if (rel.len == 0) {
            for (pf.repos.items) |r| try out.push(a, r.name, "*");
            continue;
        }
        var best: ?struct { name: []const u8, inner: []const u8, n: usize } = null;
        for (pf.repos.items) |r| {
            const inner = stripPrefix(rel, r.name) orelse continue;
            const n = componentCount(r.name);
            if (best == null or n >= best.?.n) best = .{ .name = r.name, .inner = inner, .n = n };
        }
        const b = best orelse return sys.fail("{s} is not inside any repo in {s}", .{ p, pullfile.PULLFILE });
        try out.push(a, b.name, if (b.inner.len == 0) "*" else b.inner);
    }
    return out;
}

/// Canonicalize, tolerating a missing final component (deleted files).
pub fn absolutize(a: Allocator, p: []const u8) ![]const u8 {
    if (sys.realpath(a, p)) |c| return c else |_| {}
    const parent = std.fs.path.dirname(p) orelse return sys.fail("bad path", .{});
    const base = std.fs.path.basename(p);
    if (base.len == 0) return sys.fail("bad path", .{});
    const cparent = sys.realpath(a, parent) catch |e| return sys.fail("{s}", .{sys.describe(e)});
    return std.fs.path.join(a, &.{ cparent, base });
}

/// Append `line` to the root's .gitignore unless it is already there.
pub fn ensureIgnored(a: Allocator, root: []const u8, line: []const u8) !void {
    const p = try std.fs.path.join(a, &.{ root, ".gitignore" });
    const cur = sys.readFileOrEmpty(a, p);
    var it = std.mem.splitScalar(u8, cur, '\n');
    while (it.next()) |l| if (std.mem.eql(u8, std.mem.trim(u8, l, " \t\r"), line)) return;
    var s: std.ArrayList(u8) = .empty;
    try s.appendSlice(a, cur);
    if (cur.len > 0 and cur[cur.len - 1] != '\n') try s.append(a, '\n');
    try s.appendSlice(a, line);
    try s.append(a, '\n');
    try sys.writeFile(p, s.items);
}

/// Directory name for a clone URL (`.../foo.git` -> `foo`).
pub fn repoNameFromUrl(url: []const u8) ![]const u8 {
    const trimmed = std.mem.trimEnd(u8, url, "/");
    const start = if (std.mem.lastIndexOfAny(u8, trimmed, "/:")) |i| i + 1 else 0;
    var last = trimmed[start..];
    while (std.mem.endsWith(u8, last, ".git")) last = last[0 .. last.len - 4];
    if (last.len == 0) return sys.fail("can't derive a name from `{s}`; pass --name", .{url});
    return last;
}

test "routing picks the longest repo prefix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("x/y", stripPrefix("group/name/x/y", "group/name").?);
    try std.testing.expectEqualStrings("", stripPrefix("radar", "radar").?);
    try std.testing.expect(stripPrefix("radarx/a", "radar") == null);
    try std.testing.expectEqualStrings("foo", try repoNameFromUrl("https://github.com/a/foo.git"));
    try std.testing.expectEqualStrings("foo", try repoNameFromUrl("git@github.com:a/foo/"));

    // A real directory tree: /tmp-like root with group, group/name.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "group/name/src");
    try tmp.dir.createDirPath(std.testing.io, "radar");
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    var pf: pullfile.Pullfile = .{ .a = a };
    try pf.repos.append(a, .{ .name = "group", .upstream = "u" });
    try pf.repos.append(a, .{ .name = "group/name", .upstream = "u" });
    try pf.repos.append(a, .{ .name = "radar", .upstream = "u" });
    const r = try route(a, root, pf, root, &.{ "group/name/src/gone.txt", "group/other", "radar", "." });
    try std.testing.expectEqualStrings("group", r.names.items[0]);
    try std.testing.expectEqualStrings("other", r.get("group").?[0]);
    try std.testing.expectEqualStrings("*", r.get("group").?[1]);
    try std.testing.expectEqualStrings("src/gone.txt", r.get("group/name").?[0]);
    try std.testing.expectEqualStrings("*", r.get("radar").?[0]);
    try std.testing.expectEqual(@as(usize, 3), r.names.items.len);
}
