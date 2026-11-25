//! The pullfile `ignore` section: gitignore patterns for every repo, kept in each
//! repo's `.git/info/exclude` between markers (nothing gets committed for it).
const std = @import("std");
const core = @import("core");
const sys = core.sys;
const Allocator = std.mem.Allocator;

/// Pullfile section key (an array of patterns).
pub const SECTION = "ignore";

const BEGIN = "# >>> pull ignore (pullfile.plist)";
const END = "# <<< pull ignore";

/// Write `patterns` into every cloned repo's exclude file, leaving the rest alone.
pub fn apply(a: Allocator, root: []const u8, repos: []const []const u8, patterns: []const []const u8) void {
    for (repos) |name| {
        const dir = std.fs.path.join(a, &.{ root, name }) catch continue;
        const common = commonDir(a, dir) orelse continue;
        const p = std.fs.path.join(a, &.{ common, "info", "exclude" }) catch continue;
        writeExclude(a, p, patterns) catch |e| sys.err("{s}: ignore: {s}\n", .{ name, sys.describe(e) });
    }
}

/// The shared git dir of the repo at `dir` (`.git`, or the main repo's for a
/// linked worktree), or null if it isn't one.
fn commonDir(a: Allocator, dir: []const u8) ?[]const u8 {
    const dot_git = std.fs.path.join(a, &.{ dir, ".git" }) catch return null;
    switch (sys.kind(dot_git) orelse return null) {
        .directory => return dot_git,
        .file => {
            const text = sys.readFile(a, dot_git) catch return null;
            const line = std.mem.trim(u8, text, " \t\r\n");
            if (!std.mem.startsWith(u8, line, "gitdir:")) return null;
            const gd = std.fs.path.resolve(a, &.{ dir, std.mem.trim(u8, line["gitdir:".len..], " \t") }) catch return null;
            const cd = sys.readFile(a, std.fs.path.join(a, &.{ gd, "commondir" }) catch return null) catch return gd;
            return std.fs.path.resolve(a, &.{ gd, std.mem.trim(u8, cd, " \t\r\n") }) catch null;
        },
        else => return null,
    }
}

pub fn writeExclude(a: Allocator, path: []const u8, patterns: []const []const u8) !void {
    const cur = sys.readFileOrEmpty(a, path);
    var out: std.ArrayList(u8) = .empty;
    var inside = false;
    var it = std.mem.splitScalar(u8, cur, '\n');
    while (it.next()) |raw| {
        // Rust `str::lines`: no phantom line after a final "\n"; "\r\n" endings.
        if (it.index == null and raw.len == 0) break;
        const line = if (raw.len > 0 and raw[raw.len - 1] == '\r') raw[0 .. raw.len - 1] else raw;
        if (std.mem.eql(u8, line, BEGIN)) {
            inside = true;
        } else if (std.mem.eql(u8, line, END)) {
            inside = false;
        } else if (!inside) {
            try out.appendSlice(a, line);
            try out.append(a, '\n');
        }
    }
    if (patterns.len > 0) {
        try out.print(a, "{s}\n", .{BEGIN});
        for (patterns) |p| try out.print(a, "{s}\n", .{p});
        try out.print(a, "{s}\n", .{END});
    }
    if (!std.mem.eql(u8, out.items, cur)) {
        try sys.makePath(std.fs.path.dirname(path) orelse ".");
        try sys.writeFile(path, out.items);
    }
}

test "replaces only its block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    const p = try std.fs.path.join(a, &.{ dir, "info", "exclude" });
    try sys.makePath(std.fs.path.dirname(p).?);
    try sys.writeFile(p, "mine\n");
    try writeExclude(a, p, &.{ "a", "b" });
    try writeExclude(a, p, &.{"c"});
    try std.testing.expectEqualStrings("mine\n" ++ BEGIN ++ "\nc\n" ++ END ++ "\n", try sys.readFile(a, p));
    try writeExclude(a, p, &.{});
    try std.testing.expectEqualStrings("mine\n", try sys.readFile(a, p));
}
