//! haxy tools: issues on the workspace repos' `haxy/events` branches (pkgs/haxy),
//! read and written like `pull haxy`.
const std = @import("std");
const core = @import("core");
const git = @import("git");
const haxy = @import("haxy");
const mcp = @import("mcp.zig");
const tools = @import("tools.zig");
const Args = @import("args.zig").Args;

const Allocator = std.mem.Allocator;
const Ctx = mcp.Ctx;
const Result = mcp.Result;

const issue_schema =
    \\{"$schema":"https://json-schema.org/draft/2020-12/schema","properties":{"issue":{"description":"Issue id (a unique prefix will do).","type":"string"},"repo":{"description":"Repo name from the pullfile.","type":"string"}},"required":["repo","issue"],"type":"object"}
;

pub const defs = &[_]mcp.Def{
    .{
        .name = "haxy_issues",
        .description = "Issues filed with haxy (the git-native forge: issues live on each repo's `haxy/events` branch), per repo: id, status, title, labels, comment count. Open ones unless `all`.",
        .schema =
        \\{"$schema":"https://json-schema.org/draft/2020-12/schema","properties":{"all":{"default":false,"description":"Closed issues too.","type":"boolean"},"repo":{"description":"Repo name; omit for every repo with haxy/events.","type":["string","null"]}},"type":"object"}
        ,
        .fields = &.{ .{ "repo", .opt_string }, .{ "all", .boolean } },
        .run = issues,
    },
    .{
        .name = "haxy_issue",
        .description = "One haxy issue: title, status, author, labels, description and comments.",
        .schema = issue_schema,
        .fields = &.{ .{ "repo", .string }, .{ "issue", .string } },
        .run = issue,
    },
    .{
        .name = "haxy_new_issue",
        .description = "File a haxy issue in a repo (an event commit on its local `haxy/events`; haxy_sync pushes it). Returns the new issue's id.",
        .schema =
        \\{"$schema":"https://json-schema.org/draft/2020-12/schema","properties":{"body":{"description":"Description (markdown).","type":["string","null"]},"labels":{"description":"Space- or comma-separated labels.","type":["string","null"]},"repo":{"description":"Repo name from the pullfile.","type":"string"},"title":{"type":"string"}},"required":["repo","title"],"type":"object"}
        ,
        .fields = &.{ .{ "repo", .string }, .{ "title", .string }, .{ "body", .opt_string }, .{ "labels", .opt_string } },
        .run = newIssue,
    },
    .{
        .name = "haxy_comment",
        .description = "Comment on a haxy issue.",
        .schema =
        \\{"$schema":"https://json-schema.org/draft/2020-12/schema","properties":{"body":{"description":"Comment text (markdown).","type":"string"},"issue":{"description":"Issue id (a unique prefix will do).","type":"string"},"repo":{"description":"Repo name from the pullfile.","type":"string"}},"required":["repo","issue","body"],"type":"object"}
        ,
        .fields = &.{ .{ "repo", .string }, .{ "issue", .string }, .{ "body", .string } },
        .run = comment,
    },
    .{
        .name = "haxy_close",
        .description = "Close a haxy issue.",
        .schema = issue_schema,
        .fields = &.{ .{ "repo", .string }, .{ "issue", .string } },
        .run = close,
    },
    .{
        .name = "haxy_reopen",
        .description = "Reopen a closed haxy issue.",
        .schema = issue_schema,
        .fields = &.{ .{ "repo", .string }, .{ "issue", .string } },
        .run = reopen,
    },
    .{
        .name = "haxy_sync",
        .description = "Sync `haxy/events` with origin like haxy's sync button: fetch, fast-forward or merge (empty-tree merge commit), push. Every repo that has the branch, or one.",
        .schema =
        \\{"$schema":"https://json-schema.org/draft/2020-12/schema","properties":{"repo":{"description":"Repo name; omit for every repo with haxy/events.","type":["string","null"]}},"type":"object"}
        ,
        .fields = &.{.{ "repo", .opt_string }},
        .run = sync,
    },
};

/// Whether the root repo holds the workspace's stacks (so sync includes it).
fn rootHoldsStacks(a: Allocator, root: []const u8, pf: core.Pullfile) bool {
    const ev = (haxy.stack.eventsRepo(a, root, pf) catch return false) orelse return false;
    return std.mem.eql(u8, ev.name, haxy.stack.ROOT);
}

fn names(a: Allocator, pf: core.Pullfile, only: ?[]const u8) ![]const []const u8 {
    return haxy.select(a, pf, if (only) |r| &.{r} else &.{});
}

fn identity(ctx: *const Ctx, a: Allocator, pf: core.Pullfile) !core.Identity {
    const id = try core.resolveIdentity(pf, try core.Local.load(a, ctx.root));
    if (pf.identity.require_signing and !id.sign) return core.sys.fail("pullfile requires signed commits", .{});
    return id;
}

fn issues(ctx: *const Ctx, a: Allocator, args: Args) !Result {
    const pf = switch (tools.pullfile(ctx, a)) {
        .ok => |p| p,
        .err => |m| return .{ .err = m },
    };
    const repos = try haxy.collect(a, ctx.root, try names(a, pf, args.str("repo")), args.flag("all"));
    var w: std.Io.Writer.Allocating = .init(a);
    try haxy.writeList(&w.writer, repos);
    if (repos.len == 0) return .{ .ok = "no repo has a haxy/events branch" };
    return .{ .ok = try tools.truncate(a, w.written(), tools.MAX_OUTPUT) };
}

/// The repo `args.repo` names, opened.
fn repo(ctx: *const Ctx, a: Allocator, pf: core.Pullfile, args: Args) !*git.Repo {
    const name = args.str("repo").?;
    _ = try haxy.select(a, pf, &.{name});
    return git.open(a, ctx.root, name);
}

fn issue(ctx: *const Ctx, a: Allocator, args: Args) !Result {
    const pf = switch (tools.pullfile(ctx, a)) {
        .ok => |p| p,
        .err => |m| return .{ .err = m },
    };
    const r = try repo(ctx, a, pf, args);
    defer r.close();
    var w: std.Io.Writer.Allocating = .init(a);
    try haxy.writeIssue(&w.writer, try haxy.find(try haxy.issues(a, r), args.str("issue").?));
    return .{ .ok = try tools.truncate(a, w.written(), tools.MAX_OUTPUT) };
}

fn newIssue(ctx: *const Ctx, a: Allocator, args: Args) !Result {
    const pf = switch (tools.pullfile(ctx, a)) {
        .ok => |p| p,
        .err => |m| return .{ .err = m },
    };
    const r = try repo(ctx, a, pf, args);
    defer r.close();
    const id = try haxy.create(a, r, try identity(ctx, a, pf), args.str("title").?, args.str("body") orelse "", args.str("labels") orelse "");
    return .{ .ok = try std.fmt.allocPrint(a, "{s}: opened {s}", .{ args.str("repo").?, id }) };
}

fn comment(ctx: *const Ctx, a: Allocator, args: Args) !Result {
    const pf = switch (tools.pullfile(ctx, a)) {
        .ok => |p| p,
        .err => |m| return .{ .err = m },
    };
    const r = try repo(ctx, a, pf, args);
    defer r.close();
    const i, const id = try haxy.comment(a, r, try identity(ctx, a, pf), args.str("issue").?, args.str("body").?);
    return .{ .ok = try std.fmt.allocPrint(a, "{s}: commented on {s} ({s})", .{ args.str("repo").?, i.id, id }) };
}

fn setStatus(ctx: *const Ctx, a: Allocator, args: Args, status: haxy.Status) !Result {
    const pf = switch (tools.pullfile(ctx, a)) {
        .ok => |p| p,
        .err => |m| return .{ .err = m },
    };
    const r = try repo(ctx, a, pf, args);
    defer r.close();
    const name = args.str("repo").?;
    const i = try haxy.setStatus(a, r, try identity(ctx, a, pf), args.str("issue").?, status) orelse
        return .{ .ok = try std.fmt.allocPrint(a, "{s}: {s} is already {s}", .{ name, args.str("issue").?, @tagName(status) }) };
    return .{ .ok = try std.fmt.allocPrint(a, "{s}: {s} {s}", .{ name, if (status == .closed) "closed" else "reopened", i.id }) };
}

fn close(ctx: *const Ctx, a: Allocator, args: Args) !Result {
    return setStatus(ctx, a, args, .closed);
}

fn reopen(ctx: *const Ctx, a: Allocator, args: Args) !Result {
    return setStatus(ctx, a, args, .open);
}

fn sync(ctx: *const Ctx, a: Allocator, args: Args) !Result {
    const pf = switch (tools.pullfile(ctx, a)) {
        .ok => |p| p,
        .err => |m| return .{ .err = m },
    };
    var w: std.Io.Writer.Allocating = .init(a);
    haxy.syncAll(a, ctx.root, try names(a, pf, args.str("repo")), args.str("repo") == null and rootHoldsStacks(a, ctx.root, pf), try identity(ctx, a, pf), &w.writer) catch |e|
        return .{ .err = try std.fmt.allocPrint(a, "{s}{s}", .{ w.written(), tools.describe(a, e) }) };
    return .{ .ok = if (w.written().len == 0) "no repo has a haxy/events branch" else w.written() };
}
