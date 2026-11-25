//! `pull`: the CLI. The core (repos, sync, status, commit, push) lives in pkgs/core
//! and pkgs/git; every other feature is an optional package behind a build feature,
//! wired in through `workspace.zig` (hooks, lint, env, ignore) or its own subcommands.
const std = @import("std");
const opts = @import("build_options");
const core = @import("core");
const git = @import("git");
const cli = @import("cli.zig");
const ws = @import("workspace.zig");
const sys = core.sys;
const Allocator = std.mem.Allocator;

const worktree = if (opts.worktree) @import("worktree") else struct {};
const tool = if (opts.tool) @import("tool") else struct {};
const env_pkg = if (opts.env) @import("env") else struct {};

const launchd = if (opts.launchd) @import("launchd.zig") else struct {};
const mcp = if (opts.mcp) @import("mcp.zig") else struct {};

/// Thread-safe allocator for the long-running servers (launchd daemon, MCP).
var gpa: Allocator = undefined;

pub const env_provider: core.EnvProvider = ws.workspaceEnv;

pub fn main(init: std.process.Init) !u8 {
    sys.init(init.io, init.environ_map);
    gpa = init.gpa;
    const a = init.arena.allocator();
    var iter = try init.minimal.args.iterateAllocator(a);
    _ = iter.next();
    const cmd = cli.parse(a, &iter) catch |e| switch (e) {
        error.Usage => return 2,
        error.HelpShown => return 0,
        else => return e,
    };
    run(a, cmd) catch |e| {
        sys.err("pull: {s}\n", .{sys.describe(e)});
        return 1;
    };
    return 0;
}

fn run(a: Allocator, cmd: cli.Cmd) !void {
    const cwd = try sys.realpath(a, ".");
    if (cmd == .init) return initCmd(a, cwd, cmd.init.org);
    if (opts.mcp and cmd == .mcp) if (cmd.mcp.root) |r| {
        return mcp.serve(gpa, a, try core.findRoot(a, try sys.realpath(a, r)));
    };
    const root = try core.findRoot(a, cwd);
    var pf = try core.Pullfile.load(a, root);
    ws.warnUnsupported(pf);
    ws.applyIgnores(a, root, pf);

    switch (cmd) {
        .init => unreachable,
        .repo_add => |r| {
            const name = r.name orelse try core.paths.repoNameFromUrl(r.upstream);
            if (pf.repo(name) != null) return sys.fail("repo `{s}` already in {s}", .{ name, core.PULLFILE });
            try pf.repos.append(a, .{ .name = name, .upstream = r.upstream, .branch = r.branch });
            try pf.save(root);
            try git.excludeFromRootRepo(a, root, name);
            sys.out("added {s}; run `pull sync` to clone\n", .{name});
        },
        .repo_rm => |name| {
            const n = pf.repos.items.len;
            var i: usize = 0;
            while (i < pf.repos.items.len) {
                if (std.mem.eql(u8, pf.repos.items[i].name, name)) _ = pf.repos.orderedRemove(i) else i += 1;
            }
            if (pf.repos.items.len == n) return sys.fail("no repo `{s}`", .{name});
            try pf.save(root);
        },
        .repo_list => for (pf.repos.items) |r| {
            const pin = if (r.commit) |c| c[0..@min(8, c.len)] else "-";
            sys.out("{s} {s} {s}  {s}\n", .{ pad(a, r.name, 20), pad(a, r.branch, 10), pin, r.upstream });
        },
        .sync => try sync(a, root, &pf, false),
        .update => try sync(a, root, &pf, true),
        .status => |s| if (s.json) try statusJson(a, root, pf) else try git.printStatus(a, root, pf),
        .unstage => |paths| {
            const routed = try core.paths.route(a, root, pf, cwd, paths);
            for (routed.names.items, routed.specs.items) |name, specs| {
                const repo = try git.open(a, root, name);
                defer repo.close();
                try repo.unstage(specs.items);
            }
        },
        .add => |paths| {
            const routed = try core.paths.route(a, root, pf, cwd, paths);
            for (routed.names.items, routed.specs.items) |name, specs| {
                const repo = try git.open(a, root, name);
                defer repo.close();
                try repo.stage(specs.items);
            }
        },
        .commit => |c| try commit(a, root, &pf, cwd, c.message, c.all, c.no_verify, c.paths),
        .push => try git.push(a, root, pf),
        .lint => |message| {
            const msg = try core.message.prettify(a, message);
            const v = try ws.lint(a, pf, msg);
            if (v.len == 0) {
                sys.out("ok\n", .{});
            } else {
                for (v) |e| sys.err("lint: {s}\n", .{e});
                return sys.fail("{d} lint violation(s)", .{v.len});
            }
        },
        .whoami => {
            const id = try core.resolveIdentity(pf, try core.Local.load(a, root));
            sys.out("{s} <{s}>\n", .{ id.name, id.email });
            if (!id.sign) {
                sys.out("signing: off\n", .{});
            } else if (id.signing_key) |k| {
                sys.out("signing: gpg key {s}\n", .{k});
            } else sys.out("signing: gpg default key\n", .{});
            if (pf.identity.org) |o| sys.out("org: {s}\n", .{o});
        },
        .mcp => if (opts.mcp) try mcp.serve(gpa, a, root),
        .mcp_servers => try mcpServersJson(a, root),
        .launchd => if (opts.launchd) try launchd.daemon(gpa, a, root, pf),
        .launchctl_load, .launchctl_unload, .launchctl_list, .launchctl_print, .launchctl_start, .launchctl_stop, .launchctl_kickstart, .launchctl_shutdown, .session_new, .session_ls, .session_attach, .session_send, .session_capture, .session_run, .session_kill => if (opts.launchd) try launchd.run(gpa, a, root, pf, cmd),
        .worktree_add => |w| if (opts.worktree) {
            try core.paths.ensureIgnored(a, root, "/" ++ worktree.DIR ++ "/");
            const dest = try worktree.add(a, root, pf, w.name, w.branch);
            sys.out("workspace: {s}\n", .{dest});
        },
        .worktree_list => if (opts.worktree) {
            for (try worktree.list(a, root)) |e| {
                const wpf = try core.Pullfile.load(a, e.path);
                var branches: std.ArrayList([]const u8) = .empty;
                for (wpf.repos.items) |r| {
                    if (branches.items.len > 0 and std.mem.eql(u8, branches.items[branches.items.len - 1], r.branch)) continue;
                    try branches.append(a, r.branch);
                }
                sys.out("{s} {s} {s}\n", .{ pad(a, e.name, 20), pad(a, try std.mem.join(a, ",", branches.items), 12), e.path });
            }
        },
        .worktree_rm => |w| if (opts.worktree) try worktree.remove(a, root, pf, w.name, w.force),
        .tool_sync => if (opts.tool) try tool.sync(a, root, pf),
        .tool_add => |names| if (opts.tool) {
            var p = try tool.packages(a, pf);
            const changed = try p.add(a, names);
            _ = try tool.edit(a, root, &pf, p, changed);
            try tool.sync(a, root, pf);
        },
        .tool_rm => |names| if (opts.tool) {
            var p = try tool.packages(a, pf);
            const changed = p.remove(names);
            _ = try tool.edit(a, root, &pf, p, changed);
            try tool.sync(a, root, pf);
        },
        .tool_import => |file| if (opts.tool) {
            _ = try tool.importBrewfile(try std.fs.path.resolve(a, &.{ cwd, file }));
        },
        .tool_list => if (opts.tool) try tool.list(a, root),
        .tool_gc => if (opts.tool) try tool.gc(a),
        .env => |e| if (opts.env) {
            if (e.envrc) {
                const p = try std.fs.path.join(a, &.{ root, ".envrc" });
                try sys.writeFile(p, env_pkg.ENVRC);
                sys.out("wrote {s} (run `direnv allow` there)\n", .{p});
            } else {
                sys.outBytes(try env_pkg.exports(a, try ws.env(a, root, pf)));
            }
        },
        .shell => |argv| if (opts.env) {
            const shell = sys.getenv("SHELL") orelse "/bin/sh";
            const full: []const []const u8 = if (argv.len > 0) argv else &.{shell};
            var map = try sys.envMap(a);
            for (try ws.env(a, root, pf)) |v| try map.put(v.key, v.value);
            const term = sys.runInherit(full, .{ .env = &map }) catch |e|
                return sys.fail("running {s}: {s}", .{ full[0], sys.describe(e) });
            std.process.exit(switch (term) {
                .exited => |c| c,
                else => 1,
            });
        },
        .each => |argv| {
            var map = try sys.envMap(a);
            for (try ws.env(a, root, pf)) |v| try map.put(v.key, v.value);
            for (pf.repos.items) |r| {
                const dir = try std.fs.path.join(a, &.{ root, r.name });
                if (!sys.exists(dir)) continue;
                sys.out("== {s}\n", .{r.name});
                const term = sys.runInherit(argv, .{ .cwd = dir, .env = &map }) catch |e| return sys.fail("{s}", .{sys.describe(e)});
                if (!sys.succeeded(term)) {
                    var buf: [64]u8 = undefined;
                    return sys.fail("{s}: {s}", .{ r.name, sys.fmtTerm(&buf, term) });
                }
            }
        },
    }
}

/// Left-align in `width` columns (Rust `{:<width}`).
fn pad(a: Allocator, s: []const u8, width: usize) []const u8 {
    const n = std.unicode.utf8CountCodepoints(s) catch s.len;
    if (n >= width) return s;
    const out = a.alloc(u8, s.len + width - n) catch return s;
    @memcpy(out[0..s.len], s);
    @memset(out[s.len..], ' ');
    return out;
}

fn initCmd(a: Allocator, cwd: []const u8, org: ?[]const u8) !void {
    const pfp = try std.fs.path.join(a, &.{ cwd, core.PULLFILE });
    if (sys.exists(pfp)) {
        sys.out("{s} already exists\n", .{core.PULLFILE});
    } else {
        var pf: core.Pullfile = .{ .a = a };
        pf.identity.org = org;
        try pf.save(cwd);
        sys.out("wrote {s}\n", .{pfp});
    }
    const lp = try std.fs.path.join(a, &.{ cwd, core.LOCAL });
    if (!sys.exists(lp) and (try core.Local.path(a, cwd)) == null) {
        const name = sys.getenv("USER") orelse "anon";
        try sys.writeFile(lp, try core.Local.initText(a, name, org));
        sys.out("wrote {s}\n", .{lp});
    }
    try core.paths.ensureIgnored(a, cwd, "/" ++ core.LOCAL);
}

fn sync(a: Allocator, root: []const u8, pf: *core.Pullfile, to_upstream: bool) !void {
    try git.sync(a, root, pf, to_upstream);
    try ws.runHook(a, .pull, root, pf.*, try pf.repoNames(), &.{});
}

fn commit(a: Allocator, root: []const u8, pf: *core.Pullfile, cwd: []const u8, message: []const u8, all: bool, no_verify: bool, paths: []const []const u8) !void {
    const msg = try core.message.prettify(a, message);
    const violations = try ws.lint(a, pf.*, msg);
    if (violations.len > 0) {
        for (violations) |v| sys.err("lint: {s}\n", .{v});
        return sys.fail("commit message rejected", .{});
    }
    const id = try core.resolveIdentity(pf.*, try core.Local.load(a, root));
    if (pf.identity.require_signing and !id.sign) return sys.fail("pullfile requires signed commits", .{});

    const routed = try core.paths.route(a, root, pf.*, cwd, paths);
    try git.stage(a, root, pf.*, routed, all);
    var targets = try git.stagedRepos(a, root, pf.*);
    const extra = [_]core.EnvVar{.{ .key = "PULL_MESSAGE", .value = msg }};
    if (!no_verify) {
        try ws.runHook(a, .precommit, root, pf.*, targets, &extra);
        // Like git, whatever the hook staged is part of the commit.
        targets = try git.stagedRepos(a, root, pf.*);
    }
    if (targets.len == 0) return sys.fail("nothing staged in any repo", .{});
    try git.commit(a, root, pf, targets, id, msg);
    if (!no_verify) try ws.runHook(a, .postcommit, root, pf.*, targets, &extra);
}

fn writeJson(a: Allocator, value: anytype) !void {
    var w: std.Io.Writer.Allocating = .init(a);
    try std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, &w.writer);
    try w.writer.writeByte('\n');
    sys.outBytes(w.written());
}

fn statusJson(a: Allocator, root: []const u8, pf: core.Pullfile) !void {
    // Keys in serde_json's (sorted) order.
    const repos = try git.repoStatuses(a, root, pf);
    if (opts.lint) {
        try writeJson(a, .{ .features = ws.features, .lint = (try ws.lintJson(pf)).?, .repos = repos, .root = root });
    } else {
        try writeJson(a, .{ .features = ws.features, .repos = repos, .root = root });
    }
}

/// A pullfile `mcp_servers` entry: `{command, args}`, kept raw (env/root are filled
/// in per workspace by `mcpServersJson`).
const McpServerConfig = struct {
    /// Defaults to the section key.
    command: ?[]const u8 = null,
    args: []const []const u8 = &.{},
};

/// `pull` itself, plus every pullfile `mcp_servers` entry, as `{name: {command, args,
/// env}}` ready for an editor/agent's MCP settings: `command` resolved on PATH
/// (`command -v`, falling back to the bare name) and `PULL_ROOT` always set.
fn mcpServersJson(a: Allocator, root: []const u8) !void {
    const pf = try core.Pullfile.load(a, root);
    const J = std.json.Value;
    var servers: std.StringArrayHashMapUnmanaged(J) = .empty;
    {
        var o: std.json.ObjectMap = .empty;
        try o.put(a, "args", try strArray(a, &.{ "mcp", "--root", root }));
        try o.put(a, "command", .{ .string = resolveCommand(a, "pull") });
        try servers.put(a, "pull", .{ .object = o });
    }
    const configured = try pf.section(core.plist.Map(McpServerConfig), "mcp_servers");
    for (configured.keys, configured.values) |name, cfg| {
        var o: std.json.ObjectMap = .empty;
        try o.put(a, "args", try strArray(a, cfg.args));
        try o.put(a, "command", .{ .string = resolveCommand(a, cfg.command orelse name) });
        var env: std.json.ObjectMap = .empty;
        try env.put(a, "PULL_ROOT", .{ .string = root });
        try o.put(a, "env", .{ .object = env });
        try servers.put(a, name, .{ .object = o });
    }
    // serde_json's Map is sorted by key.
    const Ctx = struct {
        keys: []const []const u8,
        pub fn lessThan(c: @This(), x: usize, y: usize) bool {
            return std.mem.lessThan(u8, c.keys[x], c.keys[y]);
        }
    };
    servers.sort(Ctx{ .keys = servers.keys() });
    try writeJson(a, J{ .object = .{ .entries = servers.entries } });
}

fn strArray(a: Allocator, items: []const []const u8) !std.json.Value {
    var arr: std.json.Array = .init(a);
    for (items) |s| try arr.append(.{ .string = s });
    return .{ .array = arr };
}

/// `name`'s absolute path on `$PATH` (`command -v`), or `name` itself if that fails.
fn resolveCommand(a: Allocator, name: []const u8) []const u8 {
    const quoted = shellQuote(a, name) catch return name;
    const script = std.fmt.allocPrint(a, "command -v -- {s}", .{quoted}) catch return name;
    const o = sys.run(a, &.{ "sh", "-c", script }, .{}) catch return name;
    if (!o.ok()) return name;
    const s = std.mem.trim(u8, o.stdout, " \t\r\n");
    return if (s.len == 0) name else s;
}

fn shellQuote(a: Allocator, s: []const u8) ![]const u8 {
    const inner = try std.mem.replaceOwned(u8, a, s, "'", "'\\''");
    return std.fmt.allocPrint(a, "'{s}'", .{inner});
}

test {
    _ = cli;
    if (opts.launchd) _ = launchd;
}
