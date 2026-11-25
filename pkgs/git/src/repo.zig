//! One repository: xit for ordinary `.git` repos, and the `git` binary for linked
//! worktrees (`.git` is a file pointing into the main repo's `worktrees/`), which
//! xit refuses to open (`UnsupportedRepoLayout`). Every git CLI call below is
//! marked `git CLI fallback`.
const std = @import("std");
const core = @import("core");
const xit = @import("xit");
const sweep = @import("sweep");
const sign = @import("sign.zig");
const credential = @import("credential.zig");
const sys = core.sys;
const Allocator = std.mem.Allocator;

const rp = xit.repo;
const rf = xit.ref;
const obj = xit.object;
pub const xopts: rp.RepoOpts(.git) = .{};
pub const X = rp.Repo(.git, xopts);
const RO = X.State(.read_only);
const RW = X.State(.read_write);
const Index = xit.index.Index(.git, xopts);
const Tree = xit.tree.Tree(.git, xopts);

pub const Oid = [40]u8;

/// xit's own allocations (packs, trees, statuses) are freed as it goes.
const gpa = std.heap.smp_allocator;

pub fn short(oid: Oid) []const u8 {
    const S = struct {
        threadlocal var bufs: [8][8]u8 = undefined;
        threadlocal var i: usize = 0;
    };
    S.i = (S.i + 1) % S.bufs.len;
    @memcpy(&S.bufs[S.i], oid[0..8]);
    return &S.bufs[S.i];
}

pub fn parseOid(s: []const u8) !Oid {
    if (s.len != 40) return sys.fail("invalid oid `{s}`", .{s});
    for (s) |c| if (!std.ascii.isHex(c)) return sys.fail("invalid oid `{s}`", .{s});
    var o: Oid = undefined;
    for (s, 0..) |c, i| o[i] = std.ascii.toLower(c);
    return o;
}

/// One changed path: index (staged) and worktree status letters, as in
/// `git status -s` (`A M D R` / `?` for untracked / space for unchanged).
pub const Change = struct {
    path: []const u8,
    staged: u8,
    unstaged: u8,
};

pub const Repo = struct {
    a: Allocator,
    /// Absolute working directory.
    path: []const u8,
    /// The repo's git dir (`.git`, or `.git/worktrees/NAME` for a linked worktree).
    git_dir: []const u8,
    /// Shared git dir (where `info/exclude` and objects live).
    common_dir: []const u8,
    backend: union(enum) { xit: X, cli },

    // ------------------------------------------------------------ open

    /// Open the repo whose working directory is exactly `path` (no discovery).
    pub fn open(a: Allocator, path: []const u8) !*Repo {
        const dot_git = try std.fs.path.join(a, &.{ path, ".git" });
        const r = try a.create(Repo);
        switch (sys.kind(dot_git) orelse return error.RepoNotFound) {
            .directory => {
                const x = X.open(sys.io, gpa, .{ .path = path, .require_repo_root = true }) catch |e| return e;
                r.* = .{ .a = a, .path = path, .git_dir = dot_git, .common_dir = dot_git, .backend = .{ .xit = x } };
            },
            .file => {
                // Linked worktree: "gitdir: <main>/.git/worktrees/NAME".
                const text = sys.readFile(a, dot_git) catch return error.RepoNotFound;
                const line = std.mem.trim(u8, text, " \t\r\n");
                if (!std.mem.startsWith(u8, line, "gitdir:")) return error.RepoNotFound;
                const gd_raw = std.mem.trim(u8, line["gitdir:".len..], " \t");
                const gd = try std.fs.path.resolve(a, &.{ path, gd_raw });
                const cd_file = try std.fs.path.join(a, &.{ gd, "commondir" });
                const cd = if (sys.readFile(a, cd_file)) |t|
                    try std.fs.path.resolve(a, &.{ gd, std.mem.trim(u8, t, " \t\r\n") })
                else |_|
                    gd;
                r.* = .{ .a = a, .path = path, .git_dir = gd, .common_dir = cd, .backend = .cli };
            },
            else => return error.RepoNotFound,
        }
        return r;
    }

    pub fn close(r: *Repo) void {
        switch (r.backend) {
            .xit => |*x| x.deinit(sys.io, gpa),
            .cli => {},
        }
    }

    fn ro(r: *Repo) RO {
        return .{ .core = &r.backend.xit.core, .extra = .{} };
    }

    fn rw(r: *Repo) RW {
        return .{ .core = &r.backend.xit.core, .extra = .{} };
    }

    /// git CLI fallback: run `git -C <path> args...`, failing with its stderr.
    fn git(r: *Repo, args: []const []const u8) ![]const u8 {
        return runGit(r.a, r.path, args, null);
    }

    fn gitOk(r: *Repo, args: []const []const u8) bool {
        const o = gitOutput(r.a, r.path, args, null) catch return false;
        return o.ok();
    }

    // ------------------------------------------------------------ refs

    pub const Head = struct {
        /// Branch HEAD points at (null when detached).
        branch: ?[]const u8,
        oid: ?Oid,
    };

    pub fn head(r: *Repo) !Head {
        switch (r.backend) {
            .xit => |*x| {
                var buf: [rf.MAX_REF_CONTENT_SIZE]u8 = undefined;
                const h = x.head(sys.io, &buf) catch |e| switch (e) {
                    error.HeadNotFound => return .{ .branch = null, .oid = null },
                    else => return e,
                };
                return switch (h) {
                    .ref => |ref| .{
                        .branch = if (ref.kind == .head) try r.a.dupe(u8, ref.name) else null,
                        .oid = try rf.readRecur(.git, xopts, r.ro(), sys.io, .{ .ref = ref }),
                    },
                    .oid => |o| .{ .branch = null, .oid = o.* },
                };
            },
            .cli => {
                const b = gitOutput(r.a, r.path, &.{ "symbolic-ref", "-q", "--short", "HEAD" }, null) catch null;
                const o = gitOutput(r.a, r.path, &.{ "rev-parse", "-q", "--verify", "HEAD" }, null) catch null;
                return .{
                    .branch = if (b != null and b.?.ok()) std.mem.trim(u8, b.?.stdout, " \r\n") else null,
                    .oid = if (o != null and o.?.ok()) try parseOid(std.mem.trim(u8, o.?.stdout, " \r\n")) else null,
                };
            },
        }
    }

    pub fn headOid(r: *Repo) ?Oid {
        return (r.head() catch return null).oid;
    }

    /// `git2 Reference::shorthand` of HEAD: branch name, "HEAD" when detached,
    /// null when unborn.
    pub fn branchName(r: *Repo) ?[]const u8 {
        const h = r.head() catch return null;
        if (h.oid == null) return null;
        return h.branch orelse "HEAD";
    }

    pub fn refOid(r: *Repo, ref_path: []const u8) ?Oid {
        switch (r.backend) {
            .xit => {
                const ref = rf.Ref.initFromPath(ref_path, null) orelse return null;
                return rf.readRecur(.git, xopts, r.ro(), sys.io, .{ .ref = ref }) catch null;
            },
            .cli => {
                const o = gitOutput(r.a, r.path, &.{ "rev-parse", "-q", "--verify", ref_path }, null) catch return null;
                if (!o.ok()) return null;
                return parseOid(std.mem.trim(u8, o.stdout, " \r\n")) catch null;
            },
        }
    }

    pub fn remoteOid(r: *Repo, branch: []const u8) ?Oid {
        const p = std.fmt.allocPrint(r.a, "refs/remotes/origin/{s}", .{branch}) catch return null;
        return r.refOid(p);
    }

    pub fn localBranchOid(r: *Repo, branch: []const u8) ?Oid {
        const p = std.fmt.allocPrint(r.a, "refs/heads/{s}", .{branch}) catch return null;
        return r.refOid(p);
    }

    pub fn writeRef(r: *Repo, ref_path: []const u8, oid: Oid) !void {
        switch (r.backend) {
            .xit => try rf.write(.git, xopts, r.rw(), sys.io, ref_path, .{ .oid = &oid }),
            .cli => _ = try r.git(&.{ "update-ref", ref_path, &oid }), // git CLI fallback
        }
    }

    pub fn hasRemote(r: *Repo, name: []const u8) bool {
        switch (r.backend) {
            .xit => |*x| {
                var remotes = x.listRemotes(sys.io, gpa) catch return false;
                defer remotes.deinit();
                return remotes.sections.contains(name);
            },
            .cli => return r.gitOk(&.{ "remote", "get-url", name }),
        }
    }

    pub fn setConfig(r: *Repo, name: []const u8, value: []const u8) !void {
        switch (r.backend) {
            .xit => |*x| try x.addConfig(sys.io, gpa, .{ .name = name, .value = value }),
            .cli => _ = try r.git(&.{ "config", name, value }),
        }
    }

    // ------------------------------------------------------------ graph

    /// (ahead, behind) of `h` relative to `o`: commits only reachable from one side.
    pub fn aheadBehind(r: *Repo, h: Oid, o: Oid) !struct { usize, usize } {
        switch (r.backend) {
            .xit => {
                const Ancestry = xit.merge.Ancestry(.git, xopts);
                var anc = try Ancestry.init(r.ro(), sys.io, gpa, &h, &o);
                defer anc.deinit();
                try anc.finish(null);
                // libgit2's ahead_behind: from both tips, count commits reached
                // by one side only, not walking past commits both reach.
                var ahead: usize = 0;
                var behind: usize = 0;
                var seen: std.AutoHashMapUnmanaged(Oid, void) = .empty;
                defer seen.deinit(gpa);
                var todo: std.ArrayList(Oid) = .empty;
                defer todo.deinit(gpa);
                try todo.appendSlice(gpa, &.{ h, o });
                while (todo.pop()) |c| {
                    if ((try seen.getOrPut(gpa, c)).found_existing) continue;
                    const node = anc.nodes.get(c) orelse continue;
                    switch (node.flags & Ancestry.both) {
                        Ancestry.one => ahead += 1,
                        Ancestry.two => behind += 1,
                        else => continue,
                    }
                    try todo.appendSlice(gpa, node.parents);
                }
                return .{ ahead, behind };
            },
            .cli => {
                const range = try std.fmt.allocPrint(r.a, "{s}...{s}", .{ &h, &o });
                const out = try r.git(&.{ "rev-list", "--left-right", "--count", range });
                var it = std.mem.tokenizeAny(u8, out, " \t\r\n");
                const a_ = try std.fmt.parseInt(usize, it.next() orelse "0", 10);
                const b_ = try std.fmt.parseInt(usize, it.next() orelse "0", 10);
                return .{ a_, b_ };
            },
        }
    }

    /// `git2 graph_descendant_of`: `a` is a strict descendant of `b`.
    pub fn descendantOf(r: *Repo, a_: Oid, b: Oid) !bool {
        if (std.mem.eql(u8, &a_, &b)) return false;
        switch (r.backend) {
            .xit => {
                const d = xit.merge.getDescendent(.git, xopts, r.ro(), sys.io, gpa, &a_, &b) catch |e| switch (e) {
                    error.DescendentNotFound => return false,
                    else => return e,
                };
                return std.mem.eql(u8, &d, &a_);
            },
            .cli => {
                const o = try gitOutput(r.a, r.path, &.{ "merge-base", "--is-ancestor", &b, &a_ }, null);
                return o.ok();
            },
        }
    }

    // ------------------------------------------------------------ status

    pub const Status = struct {
        /// Sorted by path.
        changes: []Change,
        /// Untracked directories (no recursion), with a trailing slash.
        untracked_dirs: []const []const u8,
    };

    /// Changed paths, like git2 statuses with untracked files (ignored ones
    /// excluded). `recurse`: list untracked directories' files instead of `dir/`.
    pub fn changes(r: *Repo, recurse: bool) ![]Change {
        switch (r.backend) {
            .xit => return r.xitChanges(recurse),
            .cli => return r.cliChanges(recurse),
        }
    }

    fn xitChanges(r: *Repo, recurse: bool) ![]Change {
        const a = r.a;
        var st = try r.backend.xit.status(sys.io, gpa);
        defer st.deinit(gpa);
        var map: std.StringArrayHashMapUnmanaged(Change) = .empty;
        const S = struct {
            fn put(m: *std.StringArrayHashMapUnmanaged(Change), al: Allocator, p: []const u8, staged: ?u8, unstaged: ?u8) !void {
                const g = try m.getOrPut(al, p);
                if (!g.found_existing) g.value_ptr.* = .{ .path = try al.dupe(u8, p), .staged = ' ', .unstaged = ' ' };
                if (staged) |c| g.value_ptr.staged = c;
                if (unstaged) |c| g.value_ptr.unstaged = c;
            }
        };
        for (st.index_added.keys()) |p| try S.put(&map, a, p, 'A', null);
        for (st.index_modified.keys()) |p| try S.put(&map, a, p, 'M', null);
        for (st.index_deleted.keys()) |p| try S.put(&map, a, p, 'D', null);
        for (st.work_dir_modified.keys()) |p| try S.put(&map, a, p, null, 'M');
        for (st.work_dir_deleted.keys()) |p| try S.put(&map, a, p, null, 'D');
        for (st.unresolved_conflicts.keys()) |p| try S.put(&map, a, p, null, null);

        var ign = try Ignore.init(r);
        defer ign.deinit();
        for (st.untracked.values()) |e| {
            if (e.meta.kind == .directory) {
                if (try ign.ignored(e.path, .dir)) continue;
                var files: std.ArrayList([]const u8) = .empty;
                try ign.untrackedFiles(a, e.path, &files, if (recurse) null else 1);
                if (files.items.len == 0) continue;
                if (recurse) {
                    for (files.items) |f| try S.put(&map, a, f, '?', '?');
                } else {
                    try S.put(&map, a, try std.fmt.allocPrint(a, "{s}/", .{e.path}), '?', '?');
                }
            } else {
                if (try ign.ignored(e.path, .file)) continue;
                try S.put(&map, a, e.path, '?', '?');
            }
        }
        const out = try a.dupe(Change, map.values());
        std.mem.sort(Change, out, {}, struct {
            fn lt(_: void, x: Change, y: Change) bool {
                return std.mem.lessThan(u8, x.path, y.path);
            }
        }.lt);
        return out;
    }

    /// git CLI fallback (linked worktrees): `git status --porcelain`.
    fn cliChanges(r: *Repo, recurse: bool) ![]Change {
        const out = try r.git(&.{ "status", "--porcelain=v1", "-z", if (recurse) "--untracked-files=all" else "--untracked-files=normal", "--no-renames" });
        var list: std.ArrayList(Change) = .empty;
        var it = std.mem.splitScalar(u8, out, 0);
        while (it.next()) |rec| {
            if (rec.len < 4) continue;
            var x = rec[0];
            const y = rec[1];
            if (x == 'T') x = 'M';
            try list.append(r.a, .{ .path = rec[3..], .staged = if (y == '?') '?' else x, .unstaged = if (y == 'T') 'M' else y });
        }
        std.mem.sort(Change, list.items, {}, struct {
            fn lt(_: void, p: Change, q: Change) bool {
                return std.mem.lessThan(u8, p.path, q.path);
            }
        }.lt);
        return list.items;
    }

    /// Tracked changes in index or worktree (untracked files ignored).
    pub fn isDirty(r: *Repo) !bool {
        switch (r.backend) {
            .xit => |*x| {
                var st = try x.status(sys.io, gpa);
                defer st.deinit(gpa);
                return st.index_added.count() + st.index_modified.count() + st.index_deleted.count() +
                    st.work_dir_modified.count() + st.work_dir_deleted.count() + st.unresolved_conflicts.count() > 0;
            },
            .cli => {
                const out = try r.git(&.{ "status", "--porcelain", "--untracked-files=no" });
                return std.mem.trim(u8, out, " \r\n").len > 0;
            },
        }
    }

    /// Something differs between HEAD's tree and the index.
    pub fn hasStaged(r: *Repo) !bool {
        switch (r.backend) {
            .xit => {
                const paths = try r.stagedPaths();
                return paths.len > 0;
            },
            .cli => {
                const o = try gitOutput(r.a, r.path, &.{ "diff", "--cached", "--quiet" }, null);
                return switch (o.term) {
                    .exited => |c| if (c == 1) true else if (c == 0) false else sys.fail("git diff --cached: {s}", .{o.stderr}),
                    else => sys.fail("git diff --cached failed", .{}),
                };
            },
        }
    }

    /// Paths whose index entry differs from HEAD (xit).
    fn stagedPaths(r: *Repo) ![]const []const u8 {
        var index = try Index.init(r.ro(), sys.io, gpa);
        defer index.deinit();
        var tree = try Tree.init(r.ro(), sys.io, gpa, null);
        defer tree.deinit();
        var out: std.ArrayList([]const u8) = .empty;
        for (index.entries.keys(), index.entries.values()) |p, entries| {
            const e = entries[0] orelse {
                try out.append(r.a, try r.a.dupe(u8, p)); // conflict
                continue;
            };
            if (tree.entries.get(p)) |te| {
                if (!te.eql(.{ .oid = e.oid, .mode = e.mode })) try out.append(r.a, try r.a.dupe(u8, p));
            } else try out.append(r.a, try r.a.dupe(u8, p));
        }
        for (tree.entries.keys()) |p| {
            if (!index.entries.contains(p)) try out.append(r.a, try r.a.dupe(u8, p));
        }
        return out.items;
    }

    // ------------------------------------------------------------ index

    /// Stage pathspecs (`*` = everything) like `git add`, deletions included,
    /// ignored untracked files skipped.
    pub fn stage(r: *Repo, specs: []const []const u8) !void {
        switch (r.backend) {
            .xit => {
                const all = try r.changes(true);
                var paths: std.ArrayList([]const u8) = .empty;
                for (all) |c| {
                    if (c.unstaged == ' ') continue;
                    if (matchesAny(c.path, specs)) try paths.append(r.a, c.path);
                }
                if (paths.items.len > 0) try r.backend.xit.add(sys.io, gpa, paths.items);
            },
            .cli => {
                var args: std.ArrayList([]const u8) = .empty;
                try args.appendSlice(r.a, &.{ "add", "-A", "--" });
                for (specs) |s| try args.append(r.a, if (std.mem.eql(u8, s, "*")) "." else s);
                _ = try r.git(args.items);
            },
        }
    }

    /// `git commit -a` staging: modifications and deletions of tracked files.
    pub fn stageTracked(r: *Repo) !void {
        switch (r.backend) {
            .xit => {
                const all = try r.changes(false);
                var paths: std.ArrayList([]const u8) = .empty;
                for (all) |c| if (c.unstaged == 'M' or c.unstaged == 'D') try paths.append(r.a, c.path);
                if (paths.items.len > 0) try r.backend.xit.add(sys.io, gpa, paths.items);
            },
            .cli => _ = try r.git(&.{ "add", "-u" }),
        }
    }

    /// Put pathspecs back to HEAD in the index (`git reset -- paths`); with no
    /// commits yet, drop them from the index.
    pub fn unstage(r: *Repo, specs: []const []const u8) !void {
        switch (r.backend) {
            .xit => {
                const staged = try r.stagedPaths();
                var paths: std.ArrayList([]const u8) = .empty;
                for (staged) |p| if (matchesAny(p, specs)) try paths.append(r.a, p);
                if (paths.items.len == 0) return;
                const has_head = r.headOid() != null;
                var lock = try xit.fs.LockFile.init(sys.io, r.backend.xit.core.repo_dir, "index");
                defer lock.deinit(sys.io);
                const state: RW = .{ .core = &r.backend.xit.core, .extra = .{ .lock_file_maybe = lock.lock_file } };
                var index = try Index.init(state.readOnly(), sys.io, gpa);
                defer index.deinit();
                for (paths.items) |p| {
                    try index.removePath(p, null);
                    if (!has_head) continue;
                    var parts: std.ArrayList([]const u8) = .empty;
                    var it = std.mem.splitScalar(u8, p, '/');
                    while (it.next()) |part| try parts.append(r.a, part);
                    if (try xit.tree.headTreeEntry(.git, xopts, state.readOnly(), sys.io, gpa, parts.items)) |*te| {
                        try index.addTreeEntry(state.readOnly(), sys.io, gpa, te, parts.items);
                    }
                }
                try index.write(gpa, state, sys.io);
                lock.success = true;
            },
            .cli => {
                var args: std.ArrayList([]const u8) = .empty;
                const has_head = r.headOid() != null;
                if (has_head) {
                    try args.appendSlice(r.a, &.{ "reset", "-q", "--" });
                } else try args.appendSlice(r.a, &.{ "rm", "--cached", "-r", "-q", "--ignore-unmatch", "--" });
                for (specs) |s| try args.append(r.a, if (std.mem.eql(u8, s, "*")) "." else s);
                _ = try r.git(args.items);
            },
        }
    }

    // ------------------------------------------------------------ commit

    /// Commit the index as `id`, optionally GPG-signed; moves HEAD's branch.
    pub fn commit(r: *Repo, id: core.Identity, msg: []const u8) !Oid {
        const parent = r.headOid();
        const tree_oid: Oid = switch (r.backend) {
            .xit => blk: {
                var index = try Index.init(r.ro(), sys.io, gpa);
                defer index.deinit();
                var tree = try obj.Tree.initFromIndex(.git, xopts, r.rw(), sys.io, gpa, &index);
                defer tree.deinit();
                var bytes: [20]u8 = undefined;
                try obj.writeTree(.git, xopts, r.rw(), sys.io, gpa, &tree, &bytes);
                break :blk std.fmt.bytesToHex(bytes, .lower);
            },
            // git CLI fallback
            .cli => try parseOid(std.mem.trim(u8, try r.git(&.{"write-tree"}), " \r\n")),
        };
        const t = sys.now();
        const oid = try r.commitObject(id, tree_oid, if (parent) |p| &.{p} else &.{}, msg, t);
        const subject = std.mem.sliceTo(msg, '\n');
        const reflog = try std.fmt.allocPrint(r.a, "commit: {s}", .{subject});
        switch (r.backend) {
            .xit => {
                try rf.updateHead(.git, xopts, r.rw(), sys.io, &oid);
                r.appendReflog(id, parent, oid, t.secs, t.offset_min, reflog) catch {};
            },
            .cli => _ = try r.git(&.{ "update-ref", "-m", reflog, "HEAD", &oid }),
        }
        return oid;
    }

    /// Reflog lines for HEAD and its branch, as libgit2 writes them on commit.
    fn appendReflog(r: *Repo, id: core.Identity, old: ?Oid, new: Oid, secs: i64, off: i32, text: []const u8) !void {
        const zero: Oid = @splat('0');
        const tz = sign.fmtTz(off);
        const line = try std.fmt.allocPrint(r.a, "{s} {s} {s} <{s}> {d} {s}\t{s}\n", .{ &(old orelse zero), &new, id.name, id.email, secs, &tz, text });
        var logs: std.ArrayList([]const u8) = .empty;
        try logs.append(r.a, "logs/HEAD");
        if ((try r.head()).branch) |b| try logs.append(r.a, try std.fmt.allocPrint(r.a, "logs/refs/heads/{s}", .{b}));
        for (logs.items) |rel| {
            const p = try std.fs.path.join(r.a, &.{ r.git_dir, rel });
            try sys.makePath(std.fs.path.dirname(p).?);
            const f = sys.cwd().openFile(sys.io, p, .{ .mode = .write_only }) catch |e| switch (e) {
                error.FileNotFound => try sys.cwd().createFile(sys.io, p, .{}),
                else => return e,
            };
            defer f.close(sys.io);
            const len = try f.length(sys.io);
            try f.writePositionalAll(sys.io, line, len);
        }
    }

    // ------------------------------------------------------------ objects

    pub const Time = @TypeOf(sys.now());

    /// Write a commit object (GPG-signed when `id.sign`) without moving any ref.
    pub fn commitObject(r: *Repo, id: core.Identity, tree: Oid, parents: []const Oid, msg: []const u8, t: Time) !Oid {
        const content = try sign.commitBuffer(r.a, id, tree, parents, msg, t.secs, t.offset_min);
        switch (r.backend) {
            .xit => {
                var bytes: [20]u8 = undefined;
                var reader = std.Io.Reader.fixed(content);
                try obj.writeObject(.git, xopts, r.rw(), sys.io, gpa, &reader, .{ .kind = .commit, .size = content.len }, &bytes);
                return std.fmt.bytesToHex(bytes, .lower);
            },
            // git CLI fallback
            .cli => {
                const out = try runGit(r.a, r.path, &.{ "hash-object", "-t", "commit", "-w", "--stdin" }, content);
                return parseOid(std.mem.trim(u8, out, " \r\n"));
            },
        }
    }

    /// The empty tree, written to the object store.
    pub fn emptyTree(r: *Repo) !Oid {
        switch (r.backend) {
            .xit => {
                var tree = try obj.Tree.init(gpa);
                defer tree.deinit();
                var bytes: [20]u8 = undefined;
                try obj.writeTree(.git, xopts, r.rw(), sys.io, gpa, &tree, &bytes);
                return std.fmt.bytesToHex(bytes, .lower);
            },
            // git CLI fallback
            .cli => return parseOid(std.mem.trim(u8, try runGit(r.a, r.path, &.{ "hash-object", "-t", "tree", "-w", "--stdin" }, ""), " \r\n")),
        }
    }

    pub const Commit = struct {
        parents: []const Oid,
        /// `Name <email>` of the author line.
        author: []const u8,
        /// Committer time (seconds since the epoch).
        time: i64,
        message: []const u8,
    };

    /// A commit's parents, author, time and message.
    pub fn readCommit(r: *Repo, oid: Oid) !Commit {
        const raw = switch (r.backend) {
            .xit => blk: {
                var rd = try obj.ObjectReader(.git, xopts).init(r.ro(), sys.io, gpa, &oid);
                defer rd.deinit();
                if (rd.header().kind != .commit) return sys.fail("{s} is not a commit", .{short(oid)});
                break :blk try rd.interface.allocRemaining(r.a, .unlimited);
            },
            .cli => try r.git(&.{ "cat-file", "commit", &oid }), // git CLI fallback
        };
        return parseCommit(r.a, raw);
    }

    // ------------------------------------------------------------ worktree moves

    /// Hard reset the current branch (and index/worktree) to `target`.
    pub fn resetHard(r: *Repo, target: Oid) !void {
        switch (r.backend) {
            .xit => |*x| {
                var sw = try x.resetDir(sys.io, gpa, .{ .target = .{ .oid = &target }, .force = true });
                defer sw.deinit();
                if (sw.result == .conflict) return sys.fail("reset to {s}: conflict", .{short(target)});
            },
            .cli => _ = try r.git(&.{ "reset", "-q", "--hard", &target }),
        }
    }

    /// Move the current branch to `target` if that is a fast-forward and the tree
    /// is clean. Returns true if HEAD moved.
    pub fn fastForward(r: *Repo, target: Oid) !bool {
        const h = r.headOid() orelse {
            try r.resetHard(target);
            return true;
        };
        if (std.mem.eql(u8, &h, &target) or try r.descendantOf(h, target)) return false;
        if (!try r.descendantOf(target, h))
            return sys.fail("diverged from {s} (HEAD {s}); resolve manually", .{ short(target), short(h) });
        if (try r.isDirty())
            return sys.fail("has uncommitted changes; not fast-forwarding to {s}", .{short(target)});
        try r.resetHard(target);
        return true;
    }

    /// Make `branch` the checked-out branch, creating it from origin/<branch> if needed.
    pub fn checkoutBranch(r: *Repo, branch: []const u8) !void {
        if (r.branchName()) |b| if (std.mem.eql(u8, b, branch)) return;
        const x = &r.backend.xit;
        if (r.localBranchOid(branch) == null) {
            const remote = r.remoteOid(branch) orelse {
                // Empty / new upstream: point HEAD at the unborn branch.
                try rf.replaceHead(.git, xopts, r.rw(), sys.io, .{ .ref = .{ .kind = .head, .name = branch } });
                return;
            };
            try r.writeRef(try std.fmt.allocPrint(r.a, "refs/heads/{s}", .{branch}), remote);
            try r.setUpstream(branch);
        }
        var sw = try x.switchDir(sys.io, gpa, .{ .target = .{ .ref = .{ .kind = .head, .name = branch } } });
        defer sw.deinit();
        if (sw.result == .conflict) return sys.fail("checkout {s}: local changes would be overwritten", .{branch});
    }

    fn setUpstream(r: *Repo, branch: []const u8) !void {
        try r.setConfig(try std.fmt.allocPrint(r.a, "branch.{s}.remote", .{branch}), "origin");
        try r.setConfig(try std.fmt.allocPrint(r.a, "branch.{s}.merge", .{branch}), try std.fmt.allocPrint(r.a, "refs/heads/{s}", .{branch}));
    }

    // ------------------------------------------------------------ network

    /// Fetch `+refs/heads/*:refs/remotes/origin/*` from origin.
    pub fn fetch(r: *Repo) !void {
        return r.fetchSpecs(&.{"+refs/heads/*:refs/remotes/origin/*"});
    }

    /// Fetch `refspecs` from origin (refs origin doesn't have are skipped).
    pub fn fetchSpecs(r: *Repo, refspecs: []const []const u8) !void {
        switch (r.backend) {
            .xit => {
                var url = try r.remoteUrl();
                var cred: ?credential.Credential = null;
                while (true) {
                    var remote = try xit.net.Remote(.git, xopts).open(r.ro(), sys.io, gpa, "origin");
                    defer remote.deinit(sys.io, gpa);
                    if (cred) |c| try overrideUrl(&remote, try c.url(r.a, url));
                    xit.net.fetch(.git, xopts, r.rw(), sys.io, gpa, &remote, .{ .refspecs = refspecs }) catch |e| {
                        if (e == error.HttpUnauthorized and cred == null) {
                            cred = try credential.fill(r.a, url);
                            continue;
                        }
                        if (cred) |c| c.reject(r.a);
                        return sys.context(e, "fetch origin", .{});
                    };
                    if (cred) |c| c.approve(r.a);
                    url = url;
                    return;
                }
            },
            // git CLI fallback (which, unlike xit, fails on a ref origin doesn't have)
            .cli => {
                var argv: std.ArrayList([]const u8) = .empty;
                try argv.appendSlice(r.a, &.{ "fetch", "-q", "origin" });
                try argv.appendSlice(r.a, refspecs);
                const o = gitOutput(r.a, r.path, argv.items, null) catch |e| return sys.context(e, "fetch origin", .{});
                if (!o.ok() and std.mem.indexOf(u8, o.stderr, "couldn't find remote ref") == null)
                    return sys.fail("fetch origin: {s}", .{std.mem.trim(u8, o.stderr, " \r\n")});
            },
        }
    }

    /// Push `refs/heads/<branch>` to origin, then move refs/remotes/origin/<branch>
    /// like `git push` does.
    pub fn push(r: *Repo, branch: []const u8) !void {
        const spec = try std.fmt.allocPrint(r.a, "refs/heads/{s}:refs/heads/{s}", .{ branch, branch });
        try r.pushSpec(spec);
        if (r.localBranchOid(branch) orelse r.headOid()) |h| try r.writeRef(try std.fmt.allocPrint(r.a, "refs/remotes/origin/{s}", .{branch}), h);
    }

    /// Push one refspec (`src:dst`) to origin.
    pub fn pushSpec(r: *Repo, spec: []const u8) !void {
        switch (r.backend) {
            .xit => {
                const url = try r.remoteUrl();
                var cred: ?credential.Credential = null;
                while (true) {
                    var remote = try xit.net.Remote(.git, xopts).open(r.ro(), sys.io, gpa, "origin");
                    defer remote.deinit(sys.io, gpa);
                    if (cred) |c| try overrideUrl(&remote, try c.url(r.a, url));
                    xit.net.push(.git, xopts, r.ro(), sys.io, gpa, &remote, .{ .refspecs = &.{spec} }) catch |e| {
                        if (e == error.HttpUnauthorized and cred == null) {
                            cred = try credential.fill(r.a, url);
                            continue;
                        }
                        if (cred) |c| c.reject(r.a);
                        return sys.context(e, "push origin", .{});
                    };
                    if (cred) |c| c.approve(r.a);
                    break;
                }
            },
            .cli => _ = r.git(&.{ "push", "-q", "origin", spec }) catch |e| return sys.context(e, "push origin", .{}),
        }
    }

    fn remoteUrl(r: *Repo) ![]const u8 {
        var remote = try xit.net.Remote(.git, xopts).open(r.ro(), sys.io, gpa, "origin");
        defer remote.deinit(sys.io, gpa);
        return r.a.dupe(u8, remote.push_url orelse remote.url orelse return sys.fail("remote `origin` has no url", .{}));
    }
};

fn overrideUrl(remote: anytype, url: []const u8) !void {
    if (remote.url) |u| gpa.free(u);
    remote.url = try gpa.dupe(u8, url);
    if (remote.push_url) |u| {
        gpa.free(u);
        remote.push_url = null;
    }
}

/// Clone `url` into `dest` and check out `branch` (created from origin/<branch>).
pub fn clone(a: Allocator, url: []const u8, dest: []const u8, branch: []const u8) !*Repo {
    const parent = std.fs.path.dirname(dest) orelse dest;
    try sys.makePath(parent);
    var cred: ?credential.Credential = null;
    while (true) {
        const clone_url = if (cred) |c| try c.url(a, url) else url;
        var x = X.clone(sys.io, gpa, clone_url, dest, dest, null, .{}) catch |e| {
            sys.deleteTree(dest) catch {};
            if (e == error.HttpUnauthorized and cred == null) {
                cred = try credential.fill(a, url);
                continue;
            }
            if (cred) |c| c.reject(a);
            return sys.context(e, "cloning {s}", .{url});
        };
        if (cred) |c| {
            c.approve(a);
            // Don't keep the token in .git/config.
            try x.addConfig(sys.io, gpa, .{ .name = "remote.origin.url", .value = url });
        }
        x.deinit(sys.io, gpa);
        break;
    }
    const r = try Repo.open(a, dest);
    // What libgit2/git clone also write: format config, the remote HEAD symref,
    // and the default branch's upstream (set in checkoutBranch for others).
    try r.setConfig("core.repositoryformatversion", "0");
    try r.setConfig("core.filemode", "true");
    try r.setConfig("core.logallrefupdates", "true");
    if (r.head() catch null) |h| if (h.branch) |b| if (h.oid != null) {
        try rf.write(.git, xopts, r.rw(), sys.io, "refs/remotes/origin/HEAD", .{ .ref = .{ .kind = .{ .remote = "origin" }, .name = b } });
        try r.setUpstream(b);
    };
    try r.checkoutBranch(branch);
    return r;
}

/// Parse a raw commit object (headers, blank line, message).
pub fn parseCommit(a: Allocator, raw: []const u8) !Repo.Commit {
    const split = std.mem.indexOf(u8, raw, "\n\n") orelse raw.len;
    var parents: std.ArrayList(Oid) = .empty;
    var c: Repo.Commit = .{ .parents = &.{}, .author = "", .time = 0, .message = if (split < raw.len) raw[split + 2 ..] else "" };
    var it = std.mem.splitScalar(u8, raw[0..split], '\n');
    while (it.next()) |line| {
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        const key = line[0..sp];
        const val = line[sp + 1 ..];
        if (std.mem.eql(u8, key, "parent")) {
            try parents.append(a, try parseOid(val));
        } else if (std.mem.eql(u8, key, "author")) {
            const gt = std.mem.lastIndexOfScalar(u8, val, '>') orelse val.len - 1;
            c.author = val[0 .. gt + 1];
        } else if (std.mem.eql(u8, key, "committer")) {
            var parts = std.mem.splitBackwardsScalar(u8, val, ' ');
            _ = parts.next();
            c.time = std.fmt.parseInt(i64, parts.next() orelse "0", 10) catch 0;
        }
    }
    c.parents = parents.items;
    return c;
}

/// A pathspec as pull routes them: `*` (everything) or a repo-relative path,
/// matching the path itself or anything below it.
pub fn matchesSpec(path: []const u8, spec: []const u8) bool {
    if (std.mem.eql(u8, spec, "*") or std.mem.eql(u8, spec, ".")) return true;
    const s = std.mem.trimEnd(u8, spec, "/");
    const p = std.mem.trimEnd(u8, path, "/");
    if (std.mem.eql(u8, p, s)) return true;
    return p.len > s.len and std.mem.startsWith(u8, p, s) and p[s.len] == '/';
}

pub fn matchesAny(path: []const u8, specs: []const []const u8) bool {
    for (specs) |s| if (matchesSpec(path, s)) return true;
    return false;
}

// ------------------------------------------------------------ ignore rules

/// git's ignore stack for a repo: core.excludesFile default
/// (~/.config/git/ignore), info/exclude, then every directory's .gitignore.
const Ignore = struct {
    checker: sweep.ignore.Checker,
    dir: std.Io.Dir,
    r: *Repo,

    fn init(r: *Repo) !Ignore {
        var stack = sweep.ignore.Stack.init(gpa, .{ .unreadable = .skip });
        errdefer stack.deinit();
        const cwd = sys.cwd();
        if (try globalExcludes(r.a)) |p| try stack.addFile(sys.io, cwd, p, .{ .group = .file, .source = p }, .follow);
        const ex = try std.fs.path.join(r.a, &.{ r.common_dir, "info", "exclude" });
        try stack.addFile(sys.io, cwd, ex, .{ .group = .file, .source = "info/exclude" }, .follow);
        const dir = try cwd.openDir(sys.io, r.path, .{ .iterate = true });
        return .{ .checker = .init(stack, dir), .dir = dir, .r = r };
    }

    fn deinit(ig: *Ignore) void {
        ig.checker.deinit();
        ig.dir.close(sys.io);
    }

    fn ignored(ig: *Ignore, path: []const u8, k: sweep.Kind) !bool {
        return (try ig.checker.match(sys.io, path, k)).excluded;
    }

    /// Non-ignored files under the untracked directory `rel` (up to `limit`).
    /// Nested repositories count as one entry (`dir/`), as git shows them.
    fn untrackedFiles(ig: *Ignore, a: Allocator, rel: []const u8, out: *std.ArrayList([]const u8), limit: ?usize) !void {
        var d = ig.dir.openDir(sys.io, rel, .{ .iterate = true }) catch return;
        defer d.close(sys.io);
        if (d.access(sys.io, ".git", .{})) |_| {
            try out.append(a, try std.fmt.allocPrint(a, "{s}/", .{rel}));
            return;
        } else |_| {}
        var names: std.ArrayList(struct { []const u8, std.Io.File.Kind }) = .empty;
        var it = d.iterate();
        while (try it.next(sys.io)) |e| try names.append(a, .{ try a.dupe(u8, e.name), e.kind });
        for (names.items) |n| {
            if (limit) |l| if (out.items.len >= l) return;
            const sub = try std.fmt.allocPrint(a, "{s}/{s}", .{ rel, n[0] });
            if (n[1] == .directory) {
                if (try ig.ignored(sub, .dir)) continue;
                try ig.untrackedFiles(a, sub, out, limit);
            } else {
                if (try ig.ignored(sub, .file)) continue;
                try out.append(a, sub);
            }
        }
    }
};

fn globalExcludes(a: Allocator) !?[]const u8 {
    const base = if (sys.getenv("XDG_CONFIG_HOME")) |x| (if (x.len > 0) x else null) else null;
    const p = if (base) |b| try std.fs.path.join(a, &.{ b, "git", "ignore" }) else blk: {
        const h = sys.home() orelse return null;
        break :blk try std.fs.path.join(a, &.{ h, ".config", "git", "ignore" });
    };
    return if (sys.isFile(p)) p else null;
}

// ------------------------------------------------------------ git CLI fallback

fn gitOutput(a: Allocator, dir: []const u8, args: []const []const u8, stdin: ?[]const u8) !sys.Output {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ "git", "-C", dir });
    try argv.appendSlice(a, args);
    return sys.run(a, argv.items, .{ .stdin = stdin });
}

/// git CLI fallback: run git in `dir`; stdout on success, a Fail with stderr otherwise.
pub fn runGit(a: Allocator, dir: []const u8, args: []const []const u8, stdin: ?[]const u8) ![]const u8 {
    const o = gitOutput(a, dir, args, stdin) catch |e| return sys.context(e, "running git", .{});
    if (!o.ok()) return sys.fail("git {s}: {s}", .{ args[0], std.mem.trim(u8, o.stderr, " \r\n") });
    return o.stdout;
}

test parseCommit {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const p: Oid = @splat('b');
    const raw = "tree " ++ @as([40]u8, @splat('a')) ++ "\nparent " ++ p ++ "\nauthor jp <j@x> 5 +0000\ncommitter jp <j@x> 7 -0500\ngpgsig -----BEGIN\n \n -----END\n\n{\"id\":1}";
    const c = try parseCommit(arena.allocator(), raw);
    try std.testing.expectEqual(@as(usize, 1), c.parents.len);
    try std.testing.expectEqualStrings("jp <j@x>", c.author);
    try std.testing.expectEqual(@as(i64, 7), c.time);
    try std.testing.expectEqualStrings("{\"id\":1}", c.message);
}

test matchesSpec {
    try std.testing.expect(matchesSpec("a/b.txt", "*"));
    try std.testing.expect(matchesSpec("a/b.txt", "a"));
    try std.testing.expect(matchesSpec("a/b.txt", "a/b.txt"));
    try std.testing.expect(!matchesSpec("ab/c", "a"));
}
