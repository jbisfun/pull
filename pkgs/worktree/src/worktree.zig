//! Workspace worktrees: `pull worktree add NAME` makes `{root}/.worktrees/NAME/`, a
//! full pull workspace whose repos are git worktrees of the main ones on branch NAME.
//! Run any pull command inside it (it has its own pullfile.plist with the new branch).
//!
//! git CLI fallback throughout: xit has no linked-worktree support (it refuses to
//! open them), so worktrees are made, inspected and removed with the `git` binary.
const std = @import("std");
const core = @import("core");
const sys = core.sys;
const Allocator = std.mem.Allocator;

pub const DIR = ".worktrees";

pub fn path(a: Allocator, root: []const u8, name: []const u8) ![]const u8 {
    return std.fs.path.join(a, &.{ root, DIR, name });
}

fn checkName(name: []const u8) !void {
    if (name.len == 0 or std.mem.indexOfAny(u8, name, "/\\") != null or name[0] == '.')
        return sys.fail("invalid worktree name `{s}`", .{name});
}

fn git(a: Allocator, dir: []const u8, args: []const []const u8) !sys.Output {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ "git", "-C", dir });
    try argv.appendSlice(a, args);
    return sys.run(a, argv.items, .{}) catch |e| sys.context(e, "running git", .{});
}

fn gitOk(a: Allocator, dir: []const u8, args: []const []const u8) !void {
    const o = try git(a, dir, args);
    if (!o.ok()) return sys.fail("{s}", .{std.mem.trim(u8, o.stderr, " \r\n")});
}

fn isRepo(a: Allocator, dir: []const u8) bool {
    const g = std.fs.path.join(a, &.{ dir, ".git" }) catch return false;
    return sys.exists(g);
}

pub fn add(a: Allocator, root: []const u8, pf: core.Pullfile, name: []const u8, branch_opt: ?[]const u8) ![]const u8 {
    try checkName(name);
    const branch = branch_opt orelse name;
    const dest = try path(a, root, name);
    if (sys.exists(dest)) return sys.fail("{s} already exists", .{dest});
    try sys.makePath(dest);

    var wpf = pf;
    wpf.repos = .empty;
    try wpf.repos.appendSlice(a, pf.repos.items);
    for (wpf.repos.items) |*r| {
        const repo_dir = try std.fs.path.join(a, &.{ root, r.name });
        if (!isRepo(a, repo_dir)) return sys.fail("{s}: not cloned (run `pull sync`)", .{r.name});
        const wt = try std.fs.path.join(a, &.{ dest, r.name });
        const ref = try std.fmt.allocPrint(a, "refs/heads/{s}", .{branch});
        // Branch from the main checkout's HEAD unless it already exists.
        const exists = (try git(a, repo_dir, &.{ "rev-parse", "-q", "--verify", ref })).ok();
        if (!exists and !(try git(a, repo_dir, &.{ "rev-parse", "-q", "--verify", "HEAD^{commit}" })).ok())
            return sys.fail("{s}: no commits to branch from", .{r.name});
        const args: []const []const u8 = if (exists)
            &.{ "worktree", "add", "--quiet", wt, branch }
        else
            &.{ "worktree", "add", "--quiet", "-b", branch, wt, "HEAD" };
        gitOk(a, repo_dir, args) catch |e| return sys.context(e, "{s}: adding worktree", .{r.name});
        sys.out("{s}: {s} on {s}\n", .{ r.name, wt, branch });
        r.branch = branch;
    }
    try wpf.save(dest);
    for ([_][]const u8{ core.LOCAL, ".gitignore", ".envrc" }) |f| {
        const src = try std.fs.path.join(a, &.{ root, f });
        if (sys.exists(src)) try sys.copyFile(src, try std.fs.path.join(a, &.{ dest, f }));
    }
    return dest;
}

pub const Entry = struct { name: []const u8, path: []const u8 };

pub fn list(a: Allocator, root: []const u8) ![]Entry {
    const dir_path = try std.fs.path.join(a, &.{ root, DIR });
    var out: std.ArrayList(Entry) = .empty;
    var dir = sys.cwd().openDir(sys.io, dir_path, .{ .iterate = true }) catch return out.items;
    defer dir.close(sys.io);
    var it = dir.iterate();
    while (it.next(sys.io) catch null) |e| {
        const p = try std.fs.path.join(a, &.{ dir_path, e.name });
        if (sys.isFile(try std.fs.path.join(a, &.{ p, core.PULLFILE }))) {
            try out.append(a, .{ .name = try a.dupe(u8, e.name), .path = p });
        }
    }
    std.mem.sort(Entry, out.items, {}, struct {
        fn lt(_: void, x: Entry, y: Entry) bool {
            return std.mem.lessThan(u8, x.name, y.name);
        }
    }.lt);
    return out.items;
}

pub fn remove(a: Allocator, root: []const u8, pf: core.Pullfile, name: []const u8, force: bool) !void {
    try checkName(name);
    const dest = try path(a, root, name);
    // Refuse before touching anything if any worktree has uncommitted work.
    if (!force) {
        for (pf.repos.items) |r| {
            const wt = try std.fs.path.join(a, &.{ dest, r.name });
            if (!isRepo(a, wt)) continue;
            const o = try git(a, wt, &.{ "status", "--porcelain", "--untracked-files=no" });
            if (o.ok() and std.mem.trim(u8, o.stdout, " \r\n").len > 0)
                return sys.fail("{s}: uncommitted changes in worktree (use --force)", .{r.name});
        }
    }
    for (pf.repos.items) |r| {
        const repo_dir = try std.fs.path.join(a, &.{ root, r.name });
        if (!isRepo(a, repo_dir)) continue;
        const wt = try std.fs.path.join(a, &.{ dest, r.name });
        const listed = try git(a, repo_dir, &.{ "worktree", "list", "--porcelain" });
        const needle = try std.fmt.allocPrint(a, "worktree {s}\n", .{wt});
        if (!listed.ok() or std.mem.indexOf(u8, listed.stdout, needle) == null) continue;
        const args: []const []const u8 = if (force)
            &.{ "worktree", "remove", "--force", "--force", wt }
        else
            &.{ "worktree", "remove", "--force", wt };
        gitOk(a, repo_dir, args) catch |e| return sys.context(e, "{s}: pruning worktree", .{r.name});
        sys.out("{s}: removed worktree {s} (branch kept)\n", .{ r.name, name });
    }
    if (sys.exists(dest)) try sys.deleteTree(dest);
}
