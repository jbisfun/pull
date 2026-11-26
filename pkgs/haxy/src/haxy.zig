//! haxy issues in a pull workspace. haxy (a local-first git forge) keeps a project's
//! issues, comments, patches and discussions as events on the `haxy/events` branch:
//! one commit per event with an empty tree, the event as JSON in the message
//! (`{"id":..,"kind":"issue","data":{..}}`; `data: null` removes the record), the
//! author line naming who made it. Merges of two event histories are commits with
//! two parents and no event. See haxy's docs/event.md and docs/local.md.
//!
//! Issues are read by replaying the events (latest event per id wins, in causal
//! order: a commit's generation, then commit time) from the local branch, else
//! origin's. New events are written exactly as haxy's local mode writes them, so
//! `haxy` itself consumes them. Sync is haxy's own: fetch origin's branch,
//! fast-forward or make an empty-tree merge commit, push.
const std = @import("std");
const core = @import("core");
const git = @import("git");
const sys = core.sys;
const Allocator = std.mem.Allocator;
const Oid = git.Oid;

pub const stack = @import("stack.zig");

pub const BRANCH = "haxy/events";
pub const LOCAL = "refs/heads/" ++ BRANCH;
pub const REMOTE = "refs/remotes/origin/" ++ BRANCH;
pub const FETCH_SPEC = "+" ++ LOCAL ++ ":" ++ REMOTE;
const PUSH_SPEC = LOCAL ++ ":" ++ LOCAL;
/// haxy's `evt.max_event_size`.
const MAX_EVENT = 100 * 1024;
/// haxy's `Issue.label_max_len`.
const LABEL_MAX = 64;

pub const Status = enum { open, closed };

pub const Comment = struct {
    author: []const u8,
    body: []const u8,
    created: i64,
    id: []const u8,
    /// The issue itself for a top-level comment, else the comment replied to.
    parent_id: []const u8,
};

/// Fields in key order (`--json` output is sorted like the rest of pull's JSON).
pub const Issue = struct {
    /// Who opened it (`Name <email>`).
    author: []const u8,
    comments: []const Comment = &.{},
    created: i64,
    description: []const u8,
    id: []const u8,
    labels: []const []const u8,
    status: Status,
    title: []const u8,
    updated: i64,
};

// ---------------------------------------------------------------- reading

/// The events tip pull reads: the local branch, else origin's.
pub fn tip(repo: *git.Repo) ?Oid {
    return repo.refOid(LOCAL) orelse repo.refOid(REMOTE);
}

/// One event: `data` null removes the record `id` names.
pub const Event = struct { id: []const u8, kind: []const u8, data: ?std.json.ObjectMap, commit: git.Repo.Commit };

/// Every event on the events branch, in replay order.
pub fn events(a: Allocator, repo: *git.Repo) ![]Event {
    const head = tip(repo) orelse return &.{};
    var out: std.ArrayList(Event) = .empty;
    for (try replayOrder(a, repo, head)) |c| {
        if (c.parents.len > 1) continue; // a merge, not an event
        const ev = std.json.parseFromSliceLeaky(std.json.Value, a, c.message, .{}) catch continue;
        if (ev != .object) continue;
        try out.append(a, .{
            .id = str(ev.object.get("id")) orelse continue,
            .kind = str(ev.object.get("kind")) orelse continue,
            .data = if (ev.object.get("data")) |d| (if (d == .object) d.object else null) else null,
            .commit = c,
        });
    }
    return out.items;
}

/// Every issue on the events branch (removed ones dropped), newest first.
pub fn issues(a: Allocator, repo: *git.Repo) ![]Issue {
    var by_id: std.StringArrayHashMapUnmanaged(Issue) = .empty;
    const C = struct { thread: []const u8, comment: Comment };
    var comment_ids: std.StringArrayHashMapUnmanaged(?C) = .empty;

    for (try events(a, repo)) |e| {
        const c = e.commit;
        const id = e.id;
        const kind = e.kind;
        const data = e.data;
        if (std.mem.eql(u8, kind, "issue")) {
            const d = data orelse {
                _ = by_id.orderedRemove(id);
                continue;
            };
            const g = try by_id.getOrPut(a, id);
            const first = !g.found_existing;
            g.value_ptr.* = .{
                .author = if (first) c.author else g.value_ptr.author,
                .created = if (first) c.time else g.value_ptr.created,
                .updated = c.time,
                .id = id,
                .title = str(d.get("title")) orelse "",
                .description = str(d.get("description")) orelse "",
                .labels = try splitLabels(a, str(d.get("labels")) orelse ""),
                .status = if (std.mem.eql(u8, str(d.get("status")) orelse "open", "closed")) .closed else .open,
            };
        } else if (std.mem.eql(u8, kind, "comment")) {
            const g = try comment_ids.getOrPut(a, id);
            const d = data orelse {
                g.value_ptr.* = null;
                continue;
            };
            const prev: ?C = if (g.found_existing) g.value_ptr.* else null;
            g.value_ptr.* = .{ .thread = str(d.get("thread_id")) orelse "", .comment = .{
                .id = id,
                .author = if (prev) |p| p.comment.author else c.author,
                .created = if (prev) |p| p.comment.created else c.time,
                .parent_id = str(d.get("parent_id")) orelse "",
                .body = str(d.get("body")) orelse "",
            } };
        }
    }

    var lists: std.StringHashMapUnmanaged(std.ArrayList(Comment)) = .empty;
    for (comment_ids.values()) |m| {
        const cm = m orelse continue;
        const g = try lists.getOrPut(a, cm.thread);
        if (!g.found_existing) g.value_ptr.* = .empty;
        try g.value_ptr.append(a, cm.comment);
    }
    const out = try a.dupe(Issue, by_id.values());
    for (out) |*i| if (lists.get(i.id)) |l| {
        i.comments = l.items;
    };
    std.mem.reverse(Issue, out);
    return out;
}

/// The issue `id` names (a unique prefix will do).
pub fn find(list: []const Issue, id: []const u8) !Issue {
    var found: ?Issue = null;
    for (list) |i| {
        if (std.mem.eql(u8, i.id, id)) return i;
        if (id.len == 0 or !std.mem.startsWith(u8, i.id, id)) continue;
        if (found != null) return sys.fail("issue id `{s}` is ambiguous", .{id});
        found = i;
    }
    return found orelse sys.fail("no issue `{s}`", .{id});
}

pub fn str(v: ?std.json.Value) ?[]const u8 {
    const x = v orelse return null;
    return if (x == .string) x.string else null;
}

pub fn splitLabels(a: Allocator, labels: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, labels, " ,");
    while (it.next()) |l| try out.append(a, l);
    return out.items;
}

const Node = struct { oid: Oid, gen: u64, commit: git.Repo.Commit };

/// Every commit reachable from `head`, parents before children: by generation
/// (haxy's event order: one more than the highest parent's), then commit time.
fn replayOrder(a: Allocator, repo: *git.Repo, head: Oid) ![]git.Repo.Commit {
    var commits: std.AutoArrayHashMapUnmanaged(Oid, Node) = .empty;
    var todo: std.ArrayList(Oid) = .empty;
    try todo.append(a, head);
    while (todo.pop()) |oid| {
        const g = try commits.getOrPut(a, oid);
        if (g.found_existing) continue;
        const c = try repo.readCommit(oid);
        g.value_ptr.* = .{ .oid = oid, .gen = 0, .commit = c };
        try todo.appendSlice(a, c.parents);
    }
    // Generations without recursion: a commit is done once all its parents are.
    try todo.append(a, head);
    while (todo.items.len > 0) {
        const e = commits.getPtr(todo.items[todo.items.len - 1]).?;
        if (e.gen != 0) {
            _ = todo.pop();
            continue;
        }
        var gen: u64 = 1;
        var ready = true;
        for (e.commit.parents) |p| {
            const pe = commits.get(p) orelse continue;
            if (pe.gen == 0) {
                ready = false;
                try todo.append(a, p);
            } else gen = @max(gen, pe.gen + 1);
        }
        if (ready) {
            e.gen = gen;
            _ = todo.pop();
        }
    }
    const nodes = try a.dupe(Node, commits.values());
    std.mem.sort(Node, nodes, {}, struct {
        fn lt(_: void, x: Node, y: Node) bool {
            if (x.gen != y.gen) return x.gen < y.gen;
            if (x.commit.time != y.commit.time) return x.commit.time < y.commit.time;
            return std.mem.lessThan(u8, &x.oid, &y.oid);
        }
    }.lt);
    const out = try a.alloc(git.Repo.Commit, nodes.len);
    for (out, nodes) |*o, e| o.* = e.commit;
    return out;
}

// ---------------------------------------------------------------- writing

/// A new event id: 16 random bytes in lowercase hex (haxy's `event_id_size`).
fn newId() [32]u8 {
    var bytes: [16]u8 = undefined;
    sys.io.random(&bytes);
    return std.fmt.bytesToHex(bytes, .lower);
}

/// Commit one event onto the local branch (continuing from origin's when there is
/// no local one yet, as haxy does), with a fresh empty tree.
fn commitEvent(a: Allocator, repo: *git.Repo, id: core.Identity, event: anytype) !Oid {
    const json = try std.json.Stringify.valueAlloc(a, event, .{});
    if (json.len > MAX_EVENT) return sys.fail("event too large ({d} bytes, haxy allows {d})", .{ json.len, MAX_EVENT });
    const parent = tip(repo);
    const oid = try repo.commitObject(id, try repo.emptyTree(), if (parent) |p| &.{p} else &.{}, json, sys.now());
    try repo.writeRef(LOCAL, oid);
    return oid;
}

/// haxy's Issue event fields, in its order.
const IssueData = struct { title: []const u8, description: []const u8, labels: []const u8, status: Status };
const CommentData = struct { thread_id: []const u8, parent_id: []const u8, body: []const u8 };

fn issueEvent(issue_id: []const u8, d: IssueData) struct { id: []const u8, kind: []const u8 = "issue", data: IssueData } {
    return .{ .id = issue_id, .data = d };
}

/// Open an issue; returns its id. `labels`: space- or comma-separated.
pub fn create(a: Allocator, repo: *git.Repo, id: core.Identity, title: []const u8, description: []const u8, labels: []const u8) ![]const u8 {
    if (std.mem.trim(u8, title, " \t\r\n").len == 0) return sys.fail("the title is empty", .{});
    const list = try splitLabels(a, labels);
    for (list) |l| if (l.len > LABEL_MAX) return sys.fail("label `{s}` is longer than {d} bytes", .{ l, LABEL_MAX });
    const issue_id = try a.dupe(u8, &newId());
    _ = try commitEvent(a, repo, id, issueEvent(issue_id, .{
        .title = title,
        .description = description,
        .labels = try std.mem.join(a, " ", list),
        .status = .open,
    }));
    return issue_id;
}

/// Close or reopen an issue (the whole issue re-emitted, as haxy does). Returns
/// the issue, or null if it already had that status.
pub fn setStatus(a: Allocator, repo: *git.Repo, id: core.Identity, issue_ref: []const u8, status: Status) !?Issue {
    const issue = try find(try issues(a, repo), issue_ref);
    if (issue.status == status) return null;
    _ = try commitEvent(a, repo, id, issueEvent(issue.id, .{
        .title = issue.title,
        .description = issue.description,
        .labels = try std.mem.join(a, " ", issue.labels),
        .status = status,
    }));
    return issue;
}

/// Comment on an issue (top level); returns the comment's id.
pub fn comment(a: Allocator, repo: *git.Repo, id: core.Identity, issue_ref: []const u8, body: []const u8) !struct { Issue, []const u8 } {
    if (body.len == 0) return sys.fail("the comment is empty", .{});
    const issue = try find(try issues(a, repo), issue_ref);
    const comment_id = try a.dupe(u8, &newId());
    _ = try commitEvent(a, repo, id, .{ .id = comment_id, .kind = "comment", .data = CommentData{
        .thread_id = issue.id,
        .parent_id = issue.id,
        .body = body,
    } });
    return .{ issue, comment_id };
}

// ---------------------------------------------------------------- sync

pub const Synced = union(enum) {
    up_to_date,
    /// Local moved to origin's tip.
    fast_forward: Oid,
    /// Local was ahead and was pushed.
    pushed: Oid,
    /// Diverged: merged with an empty-tree merge commit, which was pushed.
    merged: Oid,
};

/// haxy's sync for one repo, or null when neither side has the events branch.
pub fn sync(repo: *git.Repo, id: core.Identity) !?Synced {
    if (repo.hasRemote("origin")) try repo.fetchSpecs(&.{FETCH_SPEC});
    const remote = repo.refOid(REMOTE);
    const local = repo.refOid(LOCAL) orelse {
        const r = remote orelse return null;
        try repo.writeRef(LOCAL, r);
        return .{ .fast_forward = r };
    };
    if (!repo.hasRemote("origin")) return .up_to_date;
    const r = remote orelse return try push(repo, .{ .pushed = local });
    if (std.mem.eql(u8, &local, &r)) return .up_to_date;
    if (try repo.descendantOf(r, local)) {
        try repo.writeRef(LOCAL, r);
        return .{ .fast_forward = r };
    }
    if (try repo.descendantOf(local, r)) return try push(repo, .{ .pushed = local });
    const merge = try repo.commitObject(id, try repo.emptyTree(), &.{ local, r }, "merge events", sys.now());
    try repo.writeRef(LOCAL, merge);
    return try push(repo, .{ .merged = merge });
}

fn push(repo: *git.Repo, s: Synced) !Synced {
    try repo.pushSpec(PUSH_SPEC);
    try repo.writeRef(REMOTE, repo.refOid(LOCAL).?);
    return s;
}

// ---------------------------------------------------------------- workspace

/// The pullfile repos `only` names (all of them when empty).
pub fn select(a: Allocator, pf: core.Pullfile, only: []const []const u8) ![]const []const u8 {
    if (only.len == 0) return pf.repoNames();
    outer: for (only) |n| {
        for (pf.repos.items) |r| if (std.mem.eql(u8, r.name, n)) continue :outer;
        return sys.fail("no repo `{s}`", .{n});
    }
    return a.dupe([]const u8, only);
}

pub fn open(a: Allocator, root: []const u8, name: []const u8) !*git.Repo {
    return git.open(a, root, name);
}

/// Sync every selected repo that has events on either side, and with
/// `with_root` the root repo (where a workspace's stacks live when the root is a
/// git repo); one line per repo synced, others skipped silently.
pub fn syncAll(a: Allocator, root: []const u8, names: []const []const u8, with_root: bool, id: core.Identity, w: *std.Io.Writer) !void {
    var failed: std.ArrayList([]const u8) = .empty;
    const all = if (with_root) try std.mem.concat(a, []const u8, &.{ &.{stack.ROOT}, names }) else names;
    for (all) |name| {
        const p = if (std.mem.eql(u8, name, stack.ROOT)) root else try std.fs.path.join(a, &.{ root, name });
        const repo = git.Repo.open(a, p) catch continue;
        defer repo.close();
        const s = sync(repo, id) catch |e| {
            try w.print("{s}: {s}\n", .{ name, sys.describe(e) });
            try failed.append(a, name);
            continue;
        } orelse continue;
        switch (s) {
            .up_to_date => try w.print("{s}: {s} up to date\n", .{ name, BRANCH }),
            .fast_forward => |o| try w.print("{s}: {s} -> {s}\n", .{ name, BRANCH, git.short(o) }),
            .pushed => |o| try w.print("{s}: {s} pushed {s}\n", .{ name, BRANCH, git.short(o) }),
            .merged => |o| try w.print("{s}: {s} merged {s}, pushed\n", .{ name, BRANCH, git.short(o) }),
        }
    }
    if (failed.items.len > 0) return sys.fail("failed: {s}", .{try std.mem.join(a, ", ", failed.items)});
}

pub const RepoIssues = struct { issues: []const Issue, name: []const u8, path: []const u8 };

/// Issues of the selected repos that have an events branch (open ones unless `all`).
pub fn collect(a: Allocator, root: []const u8, names: []const []const u8, all: bool) ![]RepoIssues {
    var out: std.ArrayList(RepoIssues) = .empty;
    for (names) |name| {
        const p = try std.fs.path.join(a, &.{ root, name });
        const repo = git.Repo.open(a, p) catch continue;
        defer repo.close();
        if (tip(repo) == null) continue;
        var list: std.ArrayList(Issue) = .empty;
        for (try issues(a, repo)) |i| if (all or i.status == .open) try list.append(a, i);
        try out.append(a, .{ .issues = list.items, .name = name, .path = p });
    }
    return out.items;
}

/// `pull haxy issues`: per repo, one line per issue.
pub fn writeList(w: *std.Io.Writer, repos: []const RepoIssues) !void {
    for (repos) |r| {
        try w.print("{s}: {d} issue{s}\n", .{ r.name, r.issues.len, if (r.issues.len == 1) "" else "s" });
        for (r.issues) |i| try writeLine(w, i);
    }
}

fn writeLine(w: *std.Io.Writer, i: Issue) !void {
    try w.print("  {s}  {s: <6}  {s}", .{ i.id[0..@min(8, i.id.len)], @tagName(i.status), i.title });
    if (i.labels.len > 0) {
        try w.writeAll("  [");
        for (i.labels, 0..) |l, n| try w.print("{s}{s}", .{ if (n > 0) " " else "", l });
        try w.writeAll("]");
    }
    if (i.comments.len > 0) try w.print("  ({d} comment{s})", .{ i.comments.len, if (i.comments.len == 1) "" else "s" });
    try w.writeAll("\n");
}

/// One issue with its description and comments.
pub fn writeIssue(w: *std.Io.Writer, i: Issue) !void {
    try w.print("{s} [{s}] {s}\n", .{ i.id, @tagName(i.status), i.title });
    try w.print("by {s}, opened {f}, updated {f}", .{ i.author, Date{ .secs = i.created }, Date{ .secs = i.updated } });
    if (i.labels.len > 0) {
        try w.writeAll(", labels:");
        for (i.labels) |l| try w.print(" {s}", .{l});
    }
    try w.writeAll("\n");
    if (i.description.len > 0) try w.print("\n{s}\n", .{std.mem.trimEnd(u8, i.description, "\n")});
    for (i.comments) |c| {
        try w.print("\n--- {s} ({s}, {f}){s}\n{s}\n", .{ c.author, c.id[0..@min(8, c.id.len)], Date{ .secs = c.created }, if (std.mem.eql(u8, c.parent_id, i.id)) "" else " reply", std.mem.trimEnd(u8, c.body, "\n") });
    }
}

/// `YYYY-MM-DD HH:MM` (UTC) of a commit time.
const Date = struct {
    secs: i64,
    pub fn format(d: Date, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(d.secs, 0)) };
        const yd = es.getEpochDay().calculateYearDay();
        const md = yd.calculateMonthDay();
        const ds = es.getDaySeconds();
        try w.print("{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2} UTC", .{ yd.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour() });
    }
};

/// `--json`: `{repos: [{issues, name, path}], root}`.
pub fn writeJson(w: *std.Io.Writer, root: []const u8, repos: []const RepoIssues) !void {
    try std.json.Stringify.value(.{ .repos = repos, .root = root }, .{ .whitespace = .indent_2 }, w);
    try w.writeByte('\n');
}

test "event json is haxy's" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings(
        \\{"id":"00ff","kind":"issue","data":{"title":"t \"q\"","description":"d\nx","labels":"bug ui","status":"open"}}
    , try std.json.Stringify.valueAlloc(a, issueEvent("00ff", .{ .title = "t \"q\"", .description = "d\nx", .labels = "bug ui", .status = .open }), .{}));
    try std.testing.expectEqual(@as(usize, 32), newId().len);
    try std.testing.expectEqual(@as(usize, 2), (try splitLabels(a, "a, b")).len);
    try std.testing.expectEqualStrings("2026-11-25 20:38 UTC", try std.fmt.allocPrint(a, "{f}", .{Date{ .secs = 1795639091 }}));
}

test {
    std.testing.refAllDecls(@This());
    _ = stack;
}
