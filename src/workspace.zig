//! Glue between the core and the optional features: each helper does the feature's
//! work when it is compiled in and a neutral fallback otherwise, so commands never
//! need to know which features exist. Feature packages are imported only here.
const std = @import("std");
const opts = @import("build_options");
const core = @import("core");
const sys = core.sys;
const Allocator = std.mem.Allocator;
const EnvVar = core.EnvVar;

const env_pkg = if (opts.env) @import("env") else struct {};
const hooks_pkg = if (opts.hooks) @import("hooks") else struct {};
const lint_pkg = if (opts.lint) @import("lint") else struct {};
const ignore_pkg = if (opts.ignore) @import("ignore") else struct {};
const tool_pkg = if (opts.tool) @import("tool") else struct {};

/// Enabled build features (`pull --version`, `status --json`).
pub const features = opts.features;

fn has(f: []const u8) bool {
    for (features) |x| if (std.mem.eql(u8, x, f)) return true;
    return false;
}

/// Pullfile sections and the feature that acts on them.
const SECTIONS = [_]struct { []const u8, []const u8 }{
    .{ "env", "env" },
    .{ "hooks", "hooks" },
    .{ "lint", "lint" },
    .{ "ignore", "ignore" },
    .{ "jobs", "launchd" },
    .{ "tool", "tool" },
};

/// Say so when the pullfile configures something this build can't do (the section
/// is still kept when the pullfile is rewritten).
pub fn warnUnsupported(pf: core.Pullfile) void {
    for (SECTIONS) |s| {
        if (pf.hasSection(s[0]) and !has(s[1]))
            sys.err("pull: ignoring pullfile `{s}` (built without the `{s}` feature)\n", .{ s[0], s[1] });
    }
}

/// The workspace environment: pullfile `env` + local.toml `[env]` with the `env`
/// feature, otherwise just PULL_ROOT. With `tool`, the workspace profile's bin dirs
/// are on PATH (after the `env` paths, so those can shadow packages).
pub fn env(a: Allocator, root: []const u8, pf: core.Pullfile) ![]const EnvVar {
    const tool_paths = try toolPaths(a, root, pf);
    if (opts.env) {
        const E = env_pkg.Env;
        // Lowest-priority layer: resolve puts later layers' paths first.
        var layers: std.ArrayList(E) = .empty;
        try layers.append(a, .{ .path = tool_paths });
        try layers.append(a, try pf.section(E, env_pkg.SECTION));
        if (core.Local.load(a, root)) |l| {
            try layers.append(a, try l.section(E, env_pkg.SECTION));
        } else |_| {}
        return env_pkg.resolve(a, root, layers.items);
    } else {
        var out: std.ArrayList(EnvVar) = .empty;
        try out.append(a, .{ .key = "PULL_ROOT", .value = root });
        if (tool_paths.len > 0) {
            var all: std.ArrayList([]const u8) = .empty;
            try all.appendSlice(a, tool_paths);
            if (sys.getenv("PATH")) |p| try all.append(a, p);
            try out.append(a, .{ .key = "PATH", .value = try std.mem.join(a, ":", all.items) });
        }
        return out.items;
    }
}

/// PATH entries of the workspace package profile (none without the `tool` feature).
fn toolPaths(a: Allocator, root: []const u8, pf: core.Pullfile) ![]const []const u8 {
    if (opts.tool) return tool_pkg.pathEntries(a, root, pf);
    return &.{};
}

/// `env`, re-read from disk on every call: the provider long-running servers
/// (launchd daemon, MCP) get injected. Errors give an empty env.
pub fn workspaceEnv(a: Allocator, root: []const u8) []const EnvVar {
    const pf = core.Pullfile.load(a, root) catch return &.{};
    return env(a, root, pf) catch &.{};
}

pub const Hook = enum { precommit, postcommit, pull };

/// Run a pullfile hook (no-op without the `hooks` feature).
pub fn runHook(a: Allocator, hook: Hook, root: []const u8, pf: core.Pullfile, repos: []const []const u8, extra: []const EnvVar) !void {
    if (!opts.hooks) return;
    const hooks = try pf.section(hooks_pkg.Hooks, hooks_pkg.SECTION);
    const cmds = switch (hook) {
        .precommit => hooks.precommit,
        .postcommit => hooks.postcommit,
        .pull => hooks.pull,
    };
    if (cmds.len == 0) return;
    try hooks_pkg.run(a, @tagName(hook), cmds, root, repos, try env(a, root, pf), extra);
}

/// Lint violations for a commit message (none without the `lint` feature).
pub fn lint(a: Allocator, pf: core.Pullfile, msg: []const u8) ![]const []const u8 {
    if (!opts.lint) return &.{};
    var rules = try pf.section(lint_pkg.Lint, lint_pkg.SECTION);
    const want_conventional = rules.conventional and !opts.conventional;
    if (want_conventional) rules.conventional = false;
    var out: std.ArrayList([]const u8) = .empty;
    try out.appendSlice(a, try lint_pkg.check(a, rules, msg));
    if (want_conventional) try out.append(a, "conventional: pull was built without the `conventional` feature");
    return out.items;
}

/// The lint rules `status --json` reports.
pub const LintJson = struct { max_subject_length: ?u64, no_description: bool };

pub fn lintJson(pf: core.Pullfile) !?LintJson {
    if (!opts.lint) return null;
    const rules = try pf.section(lint_pkg.Lint, lint_pkg.SECTION);
    return .{ .max_subject_length = rules.max_subject_length, .no_description = rules.no_description };
}

/// Keep the pullfile `ignore` patterns in every repo's exclude file.
pub fn applyIgnores(a: Allocator, root: []const u8, pf: core.Pullfile) void {
    if (!opts.ignore) return;
    const patterns = pf.section([]const []const u8, ignore_pkg.SECTION) catch {
        sys.err("pull: {s}\n", .{sys.msg});
        return;
    };
    const names = pf.repoNames() catch return;
    ignore_pkg.apply(a, root, names, patterns);
}
