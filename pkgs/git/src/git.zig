//! git across a pull workspace: clone/sync, status, staging, the one-message commit
//! across repos, push. Hooks, lint and env are not known here: the caller wraps
//! these steps with whatever features it was built with.
const std = @import("std");
const core = @import("core");
const repo_mod = @import("repo.zig");
const sys = core.sys;
const Allocator = std.mem.Allocator;

pub const Repo = repo_mod.Repo;
pub const Change = repo_mod.Change;
pub const Oid = repo_mod.Oid;
pub const short = repo_mod.short;
pub const clone = repo_mod.clone;
pub const runGit = repo_mod.runGit;

pub fn open(a: Allocator, root: []const u8, name: []const u8) !*Repo {
    const p = try std.fs.path.join(a, &.{ root, name });
    return Repo.open(a, p) catch sys.fail("{s}: not cloned (run `pull sync`)", .{name});
}

fn tryOpen(a: Allocator, root: []const u8, name: []const u8) ?*Repo {
    const p = std.fs.path.join(a, &.{ root, name }) catch return null;
    return Repo.open(a, p) catch null;
}

/// The pullfile root itself, if it is the top of a git repo.
pub fn rootRepo(a: Allocator, root: []const u8) ?*Repo {
    return Repo.open(a, root) catch null;
}

/// Keep a repo dir out of the root repo's `git status`, if the root is a git repo.
/// Uses `.git/info/exclude`, not `.gitignore`: editors (Zed/ycode) honour
/// `.gitignore` outside of git too and would stop scanning the repo.
pub fn excludeFromRootRepo(a: Allocator, root: []const u8, name: []const u8) !void {
    const r = rootRepo(a, root) orelse return;
    defer r.close();
    const info = try std.fs.path.join(a, &.{ r.git_dir, "info" });
    try sys.makePath(info);
    const p = try std.fs.path.join(a, &.{ info, "exclude" });
    const line = try std.fmt.allocPrint(a, "/{s}/", .{name});
    const cur = sys.readFileOrEmpty(a, p);
    var it = std.mem.splitScalar(u8, cur, '\n');
    while (it.next()) |l| if (std.mem.eql(u8, std.mem.trim(u8, l, " \t\r"), line)) return;
    const sep = if (cur.len == 0 or cur[cur.len - 1] == '\n') "" else "\n";
    try sys.writeFile(p, try std.fmt.allocPrint(a, "{s}{s}{s}\n", .{ cur, sep, line }));
}

/// Clone missing repos, fetch, and fast-forward to the pins (or, `to_upstream`, to
/// the upstream branches and re-pin). Saves the pullfile if pins changed. `extra`:
/// refspecs fetched from origin as well (skipped where origin lacks the ref).
pub fn sync(a: Allocator, root: []const u8, pf: *core.Pullfile, to_upstream: bool, extra: []const []const u8) !void {
    var failed: std.ArrayList([]const u8) = .empty;
    var changed = false;
    for (pf.repos.items) |*r| {
        syncOne(a, root, r, to_upstream, extra, &changed) catch |e| {
            sys.err("{s}: {s}\n", .{ r.name, sys.describe(e) });
            try failed.append(a, r.name);
        };
    }
    if (changed) try pf.save(root);
    if (failed.items.len > 0) {
        return sys.fail("failed: {s}", .{try std.mem.join(a, ", ", failed.items)});
    }
}

fn syncOne(a: Allocator, root: []const u8, r: *core.Repo, to_upstream: bool, extra: []const []const u8, changed: *bool) !void {
    const dir = try std.fs.path.join(a, &.{ root, r.name });
    const fresh = !sys.exists(try std.fs.path.join(a, &.{ dir, ".git" }));
    const repo = if (fresh) blk: {
        sys.out("{s}: cloning {s}\n", .{ r.name, r.upstream });
        break :blk try clone(a, r.upstream, dir, r.branch);
    } else blk: {
        const repo = Repo.open(a, dir) catch |e| return sys.context(e, "opening {s}", .{dir});
        try repo.fetch();
        break :blk repo;
    };
    defer repo.close();
    if (extra.len > 0) try repo.fetchSpecs(extra);
    // A fresh clone lands on upstream HEAD; put it on the pin instead.
    if (fresh and !to_upstream) if (r.commit) |pin| try repo.resetHard(try repo_mod.parseOid(pin));
    const target: ?Oid = if (to_upstream)
        repo.remoteOid(r.branch)
    else if (r.commit) |c| try repo_mod.parseOid(c) else null;
    if (target) |t| if (try repo.fastForward(t)) sys.out("{s}: -> {s}\n", .{ r.name, short(t) });
    if (to_upstream) if (repo.headOid()) |h| {
        if (try repin(a, r, &h)) changed.* = true;
    };
}

/// `pull update`'s re-pin: move an existing pin to `head`. A repo without a
/// `commit` key is deliberately unpinned (it follows its branch) and stays so.
fn repin(a: Allocator, r: *core.Repo, head: []const u8) !bool {
    const pin = r.commit orelse return false;
    if (std.mem.eql(u8, pin, head)) return false;
    r.commit = try a.dupe(u8, head);
    return true;
}

test "update refreshes pins and leaves unpinned repos unpinned" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const old = "1111111111111111111111111111111111111111";
    const new = "2222222222222222222222222222222222222222";
    var pinned: core.Repo = .{ .name = "p", .upstream = "u", .branch = "main", .commit = old };
    var unpinned: core.Repo = .{ .name = "f", .upstream = "u", .branch = "main" };
    try std.testing.expect(try repin(a, &pinned, new));
    try std.testing.expectEqualStrings(new, pinned.commit.?);
    try std.testing.expect(!try repin(a, &pinned, new));
    try std.testing.expect(!try repin(a, &unpinned, new));
    try std.testing.expect(unpinned.commit == null);
}

/// Human-readable status of every repo.
pub fn printStatus(a: Allocator, root: []const u8, pf: core.Pullfile) !void {
    for (pf.repos.items) |r| {
        const repo = tryOpen(a, root, r.name) orelse {
            sys.out("{s}: not cloned\n", .{r.name});
            continue;
        };
        defer repo.close();
        const branch = repo.branchName() orelse "(unborn)";
        const head = repo.headOid();
        var flags: std.ArrayList([]const u8) = .empty;
        if (head) |h| {
            if (r.commit) |p| {
                if (!std.mem.eql(u8, &h, p)) try flags.append(a, try std.fmt.allocPrint(a, "pin {s}", .{p[0..@min(8, p.len)]}));
            } else try flags.append(a, "unpinned");
        }
        if (head) |h| if (repo.remoteOid(r.branch)) |o| if (!std.mem.eql(u8, &h, &o)) {
            const ab = try repo.aheadBehind(h, o);
            try flags.append(a, try std.fmt.allocPrint(a, "+{d}/-{d} origin", .{ ab[0], ab[1] }));
        };
        const hs = if (head) |h| short(h) else "-";
        sys.out("{s} [{s} {s}] {s}\n", .{ r.name, branch, hs, try std.mem.join(a, ", ", flags.items) });
        for (try repo.changes(false)) |c| sys.out("  {c}{c} {s}\n", .{ c.staged, c.unstaged, c.path });
    }
}

pub const RepoStatus = struct {
    // Fields in key order: serde_json's json! map sorts keys.
    ahead: usize = 0,
    behind: usize = 0,
    branch: ?[]const u8 = null,
    changes: []const ChangeJson = &.{},
    cloned: bool = false,
    head: ?[]const u8 = null,
    name: []const u8,
    path: []const u8,
    pinned: ?[]const u8,
};

pub const ChangeJson = struct {
    path: []const u8,
    staged: []const u8,
    unstaged: []const u8,
};

/// Machine-readable status of every repo (`pull status --json`).
pub fn repoStatuses(a: Allocator, root: []const u8, pf: core.Pullfile) ![]RepoStatus {
    var out: std.ArrayList(RepoStatus) = .empty;
    for (pf.repos.items) |r| {
        var st: RepoStatus = .{
            .name = r.name,
            .path = try std.fs.path.join(a, &.{ root, r.name }),
            .pinned = r.commit,
        };
        if (tryOpen(a, root, r.name)) |repo| {
            defer repo.close();
            st.cloned = true;
            st.branch = repo.branchName();
            const head = repo.headOid();
            if (head) |h| st.head = try a.dupe(u8, &h);
            if (head) |h| if (repo.remoteOid(r.branch)) |o| if (!std.mem.eql(u8, &h, &o)) {
                st.ahead, st.behind = try repo.aheadBehind(h, o);
            };
            const cs = try repo.changes(true);
            const js = try a.alloc(ChangeJson, cs.len);
            for (cs, js) |c, *j| j.* = .{
                .path = c.path,
                .staged = try a.dupe(u8, &.{c.staged}),
                .unstaged = try a.dupe(u8, &.{c.unstaged}),
            };
            st.changes = js;
        }
        try out.append(a, st);
    }
    return out.items;
}

/// Stage routed pathspecs (and, `all`, every tracked modification) in each repo.
pub fn stage(a: Allocator, root: []const u8, pf: core.Pullfile, routed: core.paths.Routed, all: bool) !void {
    for (pf.repos.items) |r| {
        const repo = tryOpen(a, root, r.name) orelse continue;
        defer repo.close();
        if (all) try repo.stageTracked();
        if (routed.get(r.name)) |specs| try repo.stage(specs);
    }
}

/// Repos with something staged.
pub fn stagedRepos(a: Allocator, root: []const u8, pf: core.Pullfile) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (pf.repos.items) |r| {
        const repo = tryOpen(a, root, r.name) orelse continue;
        defer repo.close();
        if (try repo.hasStaged()) try out.append(a, r.name);
    }
    return out.items;
}

/// Commit `targets` with one message and identity, pin the new commits, and (if the
/// root is a git repo) commit the updated pullfile there too.
pub fn commit(a: Allocator, root: []const u8, pf: *core.Pullfile, targets: []const []const u8, id: core.Identity, msg: []const u8) !void {
    for (targets) |name| {
        const repo = try open(a, root, name);
        defer repo.close();
        const oid = repo.commit(id, msg) catch |e| return sys.context(e, "{s}", .{name});
        sys.out("{s}: {s}\n", .{ name, short(oid) });
        if (pf.repo(name)) |r| r.commit = try a.dupe(u8, &oid);
    }
    try pf.save(root);
    if (rootRepo(a, root)) |repo| {
        defer repo.close();
        try repo.stage(&.{ core.PULLFILE, ".gitignore" });
        if (try repo.hasStaged()) {
            const oid = repo.commit(id, msg) catch |e| return sys.context(e, "(root)", .{});
            sys.out("(root): {s}\n", .{short(oid)});
        }
    }
}

/// Push every repo whose branch is ahead of origin, then the root repo (if any).
/// `extra`: other local branches pushed where they exist and origin's copy is
/// missing or behind (a diverged one is left for its own sync).
pub fn push(a: Allocator, root: []const u8, pf: core.Pullfile, extra: []const []const u8) !void {
    for (pf.repos.items) |r| {
        const repo = try open(a, root, r.name);
        defer repo.close();
        try pushExtra(a, repo, r.name, extra);
        const head = repo.headOid() orelse continue;
        if (repo.remoteOid(r.branch)) |o| if (std.mem.eql(u8, &head, &o)) continue;
        sys.out("{s}: pushing {s}\n", .{ r.name, r.branch });
        repo.push(r.branch) catch |e| return sys.context(e, "{s}", .{r.name});
    }
    // The root repo (if any) carries the pullfile itself.
    if (rootRepo(a, root)) |repo| {
        defer repo.close();
        if (repo.hasRemote("origin")) if (repo.branchName()) |b| {
            sys.out("(root): pushing {s}\n", .{b});
            repo.push(b) catch |e| return sys.context(e, "(root)", .{});
        };
        if (repo.hasRemote("origin")) try pushExtra(a, repo, "(root)", extra);
    }
}

fn pushExtra(a: Allocator, repo: *Repo, name: []const u8, extra: []const []const u8) !void {
    if (extra.len == 0 or !repo.hasRemote("origin")) return;
    for (extra) |b| {
        const local = repo.refOid(try std.fmt.allocPrint(a, "refs/heads/{s}", .{b})) orelse continue;
        const remote_ref = try std.fmt.allocPrint(a, "refs/remotes/origin/{s}", .{b});
        if (repo.refOid(remote_ref)) |o| {
            if (std.mem.eql(u8, &local, &o)) continue;
            if (!try repo.descendantOf(local, o)) continue;
        }
        sys.out("{s}: pushing {s}\n", .{ name, b });
        repo.push(b) catch |e| return sys.context(e, "{s}", .{name});
        try repo.writeRef(remote_ref, local);
    }
}

test {
    _ = repo_mod;
    _ = @import("sign.zig");
    _ = @import("credential.zig");
}
