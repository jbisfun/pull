//! The pullfile `hooks` section: shell commands run around commits and syncs.
const std = @import("std");
const core = @import("core");
const sys = core.sys;
const Allocator = std.mem.Allocator;

/// Pullfile section key.
pub const SECTION = "hooks";

pub const Hooks = struct {
    precommit: []const []const u8 = &.{},
    postcommit: []const []const u8 = &.{},
    pull: []const []const u8 = &.{},
};

/// Run each hook command through `sh -c` in the pullfile root.
/// Env: the workspace env (`pull env`), PULL_ROOT, PULL_HOOK, PULL_REPOS
/// (space-separated), plus `extra`.
pub fn run(
    a: Allocator,
    kind: []const u8,
    cmds: []const []const u8,
    root: []const u8,
    repos: []const []const u8,
    env: []const core.EnvVar,
    extra: []const core.EnvVar,
) !void {
    var map = try sys.envMap(a);
    for (env) |v| try map.put(v.key, v.value);
    try map.put("PULL_ROOT", root);
    try map.put("PULL_HOOK", kind);
    try map.put("PULL_REPOS", try std.mem.join(a, " ", repos));
    for (extra) |v| try map.put(v.key, v.value);
    for (cmds) |cmd| {
        sys.err("[{s}] {s}\n", .{ kind, cmd });
        const term = sys.runInherit(&.{ "sh", "-c", cmd }, .{ .cwd = root, .env = &map }) catch |e|
            return sys.fail("{s}", .{sys.describe(e)});
        if (!sys.succeeded(term)) {
            var buf: [64]u8 = undefined;
            return sys.fail("{s} hook failed ({s}): {s}", .{ kind, sys.fmtTerm(&buf, term), cmd });
        }
    }
}

test "hook env" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try run(a, "pull", &.{"test \"$PULL_HOOK $PULL_REPOS $X\" = \"pull a b/c 1\""}, "/", &.{ "a", "b/c" }, &.{}, &.{.{ .key = "X", .value = "1" }});
    try std.testing.expectError(error.Fail, run(a, "pull", &.{"exit 3"}, "/", &.{}, &.{}, &.{}));
    try std.testing.expectEqualStrings("pull hook failed (exit status: 3): exit 3", sys.msg);
}
