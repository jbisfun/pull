//! Stacks: a change across the workspace's repos, landed together. cpull keeps one
//! as a `stack` event in the workspace's events repo (the root repo when the root
//! is a git repo, else the pullfile `cpull` section's `events` repo) naming one
//! ordinary cpull patch per member repo:
//!
//!   {"id":..,"kind":"stack","data":{"title":..,"description":..,"labels":..,
//!    "members":"<repo> <patch id>\n..","status":{"open":{}}}}
//!
//! and, once merged, `"status":{"merged":{"pins":"<repo> <oid>\n.."}}`. Stacks are
//! read here by replaying events, like issues, with cpull's merged values
//! (`cpull.Merged`); creating and merging them is
//! cpull's (`cpull stack new|merge|show`), which pull runs, since a patch carries
//! revision snapshots only cpull computes. Recording the pins is pull's: it owns
//! the pullfile and its signed commits.
const std = @import("std");
const core = @import("core");
const git = @import("git");
const cpull = @import("cpull.zig");
const sys = core.sys;
const Allocator = std.mem.Allocator;

pub const Member = struct { patch_id: []const u8, repo: []const u8 };
pub const Pin = struct { commit: []const u8, repo: []const u8 };

/// Fields in key order, like the rest of pull's JSON.
pub const Stack = struct {
    author: []const u8,
    created: i64,
    description: []const u8,
    id: []const u8,
    labels: []const []const u8,
    members: []const Member,
    /// The commits a merge pinned (merged stacks only).
    pins: []const Pin = &.{},
    /// open, closed or merged.
    status: []const u8,
    title: []const u8,
    updated: i64,
};

/// The repo holding the workspace's issues and stacks: `name` as the pullfile
/// names it, `(root)` for the root repo.
pub const EventsRepo = struct { name: []const u8, path: []const u8 };

pub const ROOT = "(root)";

pub fn eventsRepo(a: Allocator, root: []const u8, pf: core.Pullfile) !?EventsRepo {
    if (cpull.section(pf)) |v| if (v == .dict) if (v.dict.get("events")) |e| if (e == .string) {
        for (pf.repos.items) |r| {
            if (std.mem.eql(u8, r.name, e.string)) break;
        } else return sys.fail("pullfile cpull.events: no repo `{s}`", .{e.string});
        return .{ .name = e.string, .path = try std.fs.path.join(a, &.{ root, e.string }) };
    };
    if (git.rootRepo(a, root)) |r| {
        r.close();
        return .{ .name = ROOT, .path = root };
    }
    return null;
}

pub fn openEvents(a: Allocator, root: []const u8, pf: core.Pullfile) !struct { EventsRepo, *git.Repo } {
    const ev = (try eventsRepo(a, root, pf)) orelse
        return sys.fail("no events repo: make the workspace root a git repo, or name one in the pullfile `cpull` section's `events`", .{});
    const repo = git.Repo.open(a, ev.path) catch return sys.fail("{s}: not cloned (run `pull sync`)", .{ev.name});
    _ = try cpull.adopt(repo);
    return .{ ev, repo };
}

/// Every stack (removed ones dropped), newest first, with cpull's merged values.
pub fn stacks(a: Allocator, repo: *git.Repo) ![]Stack {
    return stacksWith(a, repo, try cpull.mergedOne(a, repo.path));
}

fn setStackData(a: Allocator, s: *Stack, d: std.json.ObjectMap) !void {
    const status = d.get("status");
    const status_name = statusName(status);
    s.title = cpull.str(d.get("title")) orelse "";
    s.description = cpull.str(d.get("description")) orelse "";
    s.labels = try cpull.splitLabels(a, cpull.str(d.get("labels")) orelse "");
    s.members = try parseMembers(a, cpull.str(d.get("members")) orelse "");
    s.status = status_name;
    s.pins = if (std.mem.eql(u8, status_name, "merged")) try parsePins(a, cpull.str(status.?.object.get("merged").?.object.get("pins")) orelse "") else &.{};
}

/// `stacks`, with the record values taken from `m` (cpull's merge) when given.
pub fn stacksWith(a: Allocator, repo: *git.Repo, m: ?cpull.Merged) ![]Stack {
    var by_id: std.StringArrayHashMapUnmanaged(Stack) = .empty;
    for (try cpull.events(a, repo)) |e| {
        if (!std.mem.eql(u8, e.kind, "stack")) continue;
        const d = e.data orelse {
            _ = by_id.orderedRemove(e.id);
            continue;
        };
        const g = try by_id.getOrPut(a, e.id);
        const first = !g.found_existing;
        g.value_ptr.* = .{
            .author = if (first) e.commit.author else g.value_ptr.author,
            .created = if (first) e.commit.time else g.value_ptr.created,
            .updated = e.commit.time,
            .id = e.id,
            .title = "",
            .description = "",
            .labels = &.{},
            .members = &.{},
            .status = "open",
        };
        try setStackData(a, g.value_ptr, d);
    }
    if (m) |x| {
        var i: usize = 0;
        while (i < by_id.count()) {
            const d = x.stacks.get(by_id.keys()[i]) orelse {
                by_id.orderedRemoveAt(i);
                continue;
            };
            try setStackData(a, &by_id.values()[i], d);
            i += 1;
        }
    }
    const out = try a.dupe(Stack, by_id.values());
    std.mem.reverse(Stack, out);
    return out;
}

/// `{"open":{}}` -> "open".
fn statusName(v: ?std.json.Value) []const u8 {
    const x = v orelse return "open";
    if (x != .object or x.object.count() != 1) return "open";
    const k = x.object.keys()[0];
    inline for (.{ "open", "closed", "merged" }) |s| if (std.mem.eql(u8, k, s)) {
        if (std.mem.eql(u8, s, "merged") and x.object.values()[0] != .object) return "open";
        return s;
    };
    return "open";
}

fn parseMembers(a: Allocator, text: []const u8) ![]const Member {
    var out: std.ArrayList(Member) = .empty;
    var it = std.mem.tokenizeScalar(u8, text, '\n');
    while (it.next()) |line| {
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        try out.append(a, .{ .repo = line[0..sp], .patch_id = line[sp + 1 ..] });
    }
    return out.items;
}

fn parsePins(a: Allocator, text: []const u8) ![]const Pin {
    var out: std.ArrayList(Pin) = .empty;
    var it = std.mem.tokenizeScalar(u8, text, '\n');
    while (it.next()) |line| {
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        try out.append(a, .{ .repo = line[0..sp], .commit = line[sp + 1 ..] });
    }
    return out.items;
}

/// The stack `id` names (a unique prefix will do).
pub fn find(list: []const Stack, id: []const u8) !Stack {
    var found: ?Stack = null;
    for (list) |s| {
        if (std.mem.eql(u8, s.id, id)) return s;
        if (id.len == 0 or !std.mem.startsWith(u8, s.id, id)) continue;
        if (found != null) return sys.fail("stack id `{s}` is ambiguous", .{id});
        found = s;
    }
    return found orelse sys.fail("no stack `{s}`", .{id});
}

/// A member patch's branches, read from its repo's events (null when absent).
pub const PatchInfo = struct { source_branch: ?[]const u8, status: []const u8, target_branch: []const u8, title: []const u8 };

pub fn patchInfo(a: Allocator, repo: *git.Repo, patch_id: []const u8) !?PatchInfo {
    var info: ?PatchInfo = null;
    for (try cpull.events(a, repo)) |e| {
        if (!std.mem.eql(u8, e.kind, "patch") or !std.mem.eql(u8, e.id, patch_id)) continue;
        const d = e.data orelse {
            info = null;
            continue;
        };
        info = .{
            .title = cpull.str(d.get("title")) orelse "",
            .source_branch = cpull.str(d.get("source_branch")),
            .target_branch = cpull.str(d.get("target_branch")) orelse "",
            .status = statusName(d.get("status")),
        };
    }
    return info;
}

/// A stack (`id`, a unique prefix will do) and its member patches as their repos'
/// events have them.
pub fn withPatches(a: Allocator, root: []const u8, pf: core.Pullfile, id: []const u8) !struct { Stack, []const ?PatchInfo } {
    _, const repo = try openEvents(a, root, pf);
    defer repo.close();
    const s = try find(try stacks(a, repo), id);
    const infos = try a.alloc(?PatchInfo, s.members.len);
    for (s.members, infos) |m, *info| {
        info.* = null;
        const p = try std.fs.path.join(a, &.{ root, m.repo });
        const r = git.Repo.open(a, p) catch continue;
        defer r.close();
        info.* = try patchInfo(a, r, m.patch_id);
    }
    return .{ s, infos };
}

// ---------------------------------------------------------------- new stacks

pub const Candidate = struct { repo: []const u8, branch: []const u8 };

/// The repos with work for a stack: on a branch other than the pullfile one (or,
/// with `branch`, having that branch), whose tip isn't already in the pullfile
/// branch.
pub fn candidates(a: Allocator, root: []const u8, pf: core.Pullfile, branch: ?[]const u8) ![]Candidate {
    var out: std.ArrayList(Candidate) = .empty;
    for (pf.repos.items) |r| {
        const p = try std.fs.path.join(a, &.{ root, r.name });
        const repo = git.Repo.open(a, p) catch continue;
        defer repo.close();
        const source = branch orelse (repo.head() catch continue).branch orelse continue;
        if (std.mem.eql(u8, source, r.branch)) continue;
        const tip = repo.localBranchOid(source) orelse continue;
        const target = repo.localBranchOid(r.branch) orelse continue;
        if (std.mem.eql(u8, &tip, &target) or try repo.descendantOf(target, tip)) continue;
        try out.append(a, .{ .repo = r.name, .branch = source });
    }
    return out.items;
}

/// The cpull commands' arguments for `cpull stack new`.
pub fn newArgs(a: Allocator, root: []const u8, title: []const u8, body: []const u8, labels: []const u8, members: []const Candidate) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ "cpull", "stack", "new", "--workspace", root, "--title", title });
    if (body.len > 0) try argv.appendSlice(a, &.{ "--description", body });
    if (labels.len > 0) try argv.appendSlice(a, &.{ "--labels", labels });
    for (members) |m| try argv.append(a, try std.fmt.allocPrint(a, "{s}:{s}", .{ m.repo, m.branch }));
    return argv.items;
}

// ---------------------------------------------------------------- output

pub fn writeList(w: *std.Io.Writer, list: []const Stack) !void {
    if (list.len == 0) try w.writeAll("no stacks\n");
    for (list) |s| {
        try w.print("{s}  {s: <6}  {s}  ({d} repo{s}:", .{ s.id[0..@min(8, s.id.len)], s.status, s.title, s.members.len, if (s.members.len == 1) "" else "s" });
        for (s.members) |m| try w.print(" {s}", .{m.repo});
        try w.writeAll(")\n");
    }
}

pub fn writeStack(w: *std.Io.Writer, s: Stack, infos: []const ?PatchInfo) !void {
    try w.print("{s} [{s}] {s}\nby {s}\n", .{ s.id, s.status, s.title, s.author });
    if (s.description.len > 0) try w.print("\n{s}\n", .{std.mem.trimEnd(u8, s.description, "\n")});
    try w.writeAll("\n");
    for (s.members, infos) |m, info| {
        try w.print("  {s}  patch {s}", .{ m.repo, m.patch_id[0..@min(8, m.patch_id.len)] });
        if (info) |i| try w.print("  {s} -> {s}  {s}", .{ i.source_branch orelse "(fork)", i.target_branch, i.status }) else try w.writeAll("  (patch not found)");
        for (s.pins) |p| if (std.mem.eql(u8, p.repo, m.repo)) try w.print("  pinned {s}", .{p.commit[0..@min(8, p.commit.len)]});
        try w.writeAll("\n");
    }
}

test "stack events" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const members = try parseMembers(a, "core 00ff\ngroup/app 11ee");
    try std.testing.expectEqual(@as(usize, 2), members.len);
    try std.testing.expectEqualStrings("group/app", members[1].repo);
    try std.testing.expectEqualStrings("11ee", members[1].patch_id);
    const merged = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"merged\":{\"pins\":\"core abc\"}}", .{});
    try std.testing.expectEqualStrings("merged", statusName(merged));
    try std.testing.expectEqualStrings("closed", statusName(try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"closed\":{}}", .{})));
    try std.testing.expectEqualStrings("abc", (try parsePins(a, "core abc"))[0].commit);
    const argv = try newArgs(a, "/w", "t", "", "", &.{.{ .repo = "group/app", .branch = "feat" }});
    try std.testing.expectEqualStrings("group/app:feat", argv[argv.len - 1]);
}
