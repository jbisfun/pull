//! cpull tools: issues on the workspace repos' `cpull/events` branches (pkgs/cpull),
//! read and written like `pull cpull`, and stacks (one change across repos, as a
//! cpull patch per repo, landed together). Stacks are read here; creating and
//! merging them runs `pull cpull patch|merge`, since that drives cpull and records
//! the pins with pull's signed pullfile commit.
const std = @import("std");
const core = @import("core");
const git = @import("git");
const cpull = @import("cpull");
const mcp = @import("mcp.zig");
const tools = @import("tools.zig");
const ci = @import("ci.zig");
const Args = @import("args.zig").Args;

const Allocator = std.mem.Allocator;
const Ctx = mcp.Ctx;
const Result = mcp.Result;

const stack_schema =
    \\{"$schema":"https://json-schema.org/draft/2020-12/schema","properties":{"stack":{"description":"Stack id (a unique prefix will do).","type":"string"}},"required":["stack"],"type":"object"}
;

const issue_schema =
    \\{"$schema":"https://json-schema.org/draft/2020-12/schema","properties":{"issue":{"description":"Issue id (a unique prefix will do).","type":"string"},"repo":{"description":"Repo name from the pullfile.","type":"string"}},"required":["repo","issue"],"type":"object"}
;

pub const defs = &[_]mcp.Def{
    .{
        .name = "cpull_issues",
        .description = "Issues filed with cpull (the git-native forge: issues live on each repo's `cpull/events` branch), per repo: id, status, title, labels, comment count. Open ones unless `all`.",
        .schema =
        \\{"$schema":"https://json-schema.org/draft/2020-12/schema","properties":{"all":{"default":false,"description":"Closed issues too.","type":"boolean"},"repo":{"description":"Repo name; omit for every repo with cpull/events.","type":["string","null"]}},"type":"object"}
        ,
        .fields = &.{ .{ "repo", .opt_string }, .{ "all", .boolean } },
        .run = issues,
    },
    .{
        .name = "cpull_issue",
        .description = "One cpull issue: title, status, author, labels, description and comments.",
        .schema = issue_schema,
        .fields = &.{ .{ "repo", .string }, .{ "issue", .string } },
        .run = issue,
    },
    .{
        .name = "cpull_new_issue",
        .description = "File a cpull issue in a repo (an event commit on its local `cpull/events`; cpull_sync pushes it). Returns the new issue's id.",
        .schema =
        \\{"$schema":"https://json-schema.org/draft/2020-12/schema","properties":{"body":{"description":"Description (markdown).","type":["string","null"]},"labels":{"description":"Space- or comma-separated labels.","type":["string","null"]},"repo":{"description":"Repo name from the pullfile.","type":"string"},"title":{"type":"string"}},"required":["repo","title"],"type":"object"}
        ,
        .fields = &.{ .{ "repo", .string }, .{ "title", .string }, .{ "body", .opt_string }, .{ "labels", .opt_string } },
        .run = newIssue,
    },
    .{
        .name = "cpull_comment",
        .description = "Comment on a cpull issue.",
        .schema =
        \\{"$schema":"https://json-schema.org/draft/2020-12/schema","properties":{"body":{"description":"Comment text (markdown).","type":"string"},"issue":{"description":"Issue id (a unique prefix will do).","type":"string"},"repo":{"description":"Repo name from the pullfile.","type":"string"}},"required":["repo","issue","body"],"type":"object"}
        ,
        .fields = &.{ .{ "repo", .string }, .{ "issue", .string }, .{ "body", .string } },
        .run = comment,
    },
    .{
        .name = "cpull_close",
        .description = "Close a cpull issue.",
        .schema = issue_schema,
        .fields = &.{ .{ "repo", .string }, .{ "issue", .string } },
        .run = close,
    },
    .{
        .name = "cpull_reopen",
        .description = "Reopen a closed cpull issue.",
        .schema = issue_schema,
        .fields = &.{ .{ "repo", .string }, .{ "issue", .string } },
        .run = reopen,
    },
    .{
        .name = "cpull_sync",
        .description = "Sync `cpull/events` with origin like cpull's sync button: fetch, fast-forward or merge (empty-tree merge commit), push. Every repo that has the branch, or one.",
        .schema =
        \\{"$schema":"https://json-schema.org/draft/2020-12/schema","properties":{"repo":{"description":"Repo name; omit for every repo with cpull/events.","type":["string","null"]}},"type":"object"}
        ,
        .fields = &.{.{ "repo", .opt_string }},
        .run = sync,
    },
    .{
        .name = "cpull_stacks",
        .description = "cpull stacks: changes across the workspace's repos (one cpull patch per repo) landed together. Newest first: id, status (open/closed/merged), title, member repos.",
        .schema =
        \\{"$schema":"https://json-schema.org/draft/2020-12/schema","properties":{},"type":"object"}
        ,
        .run = stacks,
    },
    .{
        .name = "cpull_stack",
        .description = "One cpull stack: title, status, author, description, and each member repo's patch (source -> target branch, status) and pinned commit once merged.",
        .schema = stack_schema,
        .fields = &.{.{ "stack", .string }},
        .run = stack,
    },
    .{
        .name = "cpull_patch",
        .description = "Turn the work on branches across repos into one cpull patch per repo and a stack (`pull cpull patch`). Members: repos checked out on a branch other than their pullfile one whose tip isn't merged yet, or the repos having `branch`. Returns the stack id and its patches.",
        .schema =
        \\{"$schema":"https://json-schema.org/draft/2020-12/schema","properties":{"body":{"description":"Description (markdown).","type":["string","null"]},"branch":{"description":"Repos with this branch (default: repos checked out on a branch other than their pullfile one).","type":["string","null"]},"labels":{"description":"Space-separated labels.","type":["string","null"]},"title":{"description":"Default: the branch name.","type":["string","null"]}},"type":"object"}
        ,
        .fields = &.{ .{ "title", .opt_string }, .{ "body", .opt_string }, .{ "labels", .opt_string }, .{ "branch", .opt_string } },
        .run = patch,
    },
    .{
        .name = "cpull_merge",
        .description = "Merge a cpull stack (`pull cpull merge`): every member patch into its target branch, all or nothing, then pin the merged commits in the pullfile with one signed commit (message: the stack title, or `message`). Refuses when repos have staged changes, and (with the pullfile's `cpull.require_ci`) until the stack's CI is green, unless `force`.",
        .schema =
        \\{"$schema":"https://json-schema.org/draft/2020-12/schema","properties":{"force":{"default":false,"description":"Merge even when the CI gate (cpull.require_ci) finds the CI not green.","type":"boolean"},"message":{"description":"The pin commit's message (default: the stack title).","type":["string","null"]},"stack":{"description":"Stack id (a unique prefix will do).","type":"string"}},"required":["stack"],"type":"object"}
        ,
        .fields = &.{ .{ "stack", .string }, .{ "message", .opt_string }, .{ "force", .boolean } },
        .run = merge,
    },
    // ------------------------------------------------ reports (what radar was)
    .{
        .name = "cpull_report",
        .description = "File a report: a cpull issue anchored to a line of code, in the repo it points at (`pull cpull report`). The line's text is read from the file and the note becomes the issue description. Returns the report id (a cpull issue id) and its location.",
        .schema =
        \\{"$schema":"https://json-schema.org/draft/2020-12/schema","properties":{"file":{"description":"Path relative to the repo.","type":"string"},"line":{"description":"1-based line number.","minimum":1,"type":"integer"},"note":{"description":"What's wrong here, why, and the fix (markdown).","type":["string","null"]},"quote":{"description":"The selected text, if narrower than the line.","type":["string","null"]},"repo":{"description":"Repo name from the pullfile, or . for the workspace's events repo.","type":"string"},"source":{"description":"Where the report came from (default \"mcp\").","type":["string","null"]},"title":{"description":"Default: the note's first line.","type":["string","null"]}},"required":["repo","file","line"],"type":"object"}
        ,
        .fields = &.{ .{ "repo", .string }, .{ "file", .string }, .{ "line", .opt_u64 }, .{ "note", .opt_string }, .{ "quote", .opt_string }, .{ "source", .opt_string }, .{ "title", .opt_string } },
        .run = report,
    },
    .{
        .name = "cpull_reports",
        .description = "Reports (line-anchored cpull issues) across every repo, oldest first: id, repo/file:line, filing time, the line's text and the note. Open ones unless `all`.",
        .schema =
        \\{"$schema":"https://json-schema.org/draft/2020-12/schema","properties":{"all":{"default":false,"description":"Closed reports too.","type":"boolean"}},"type":"object"}
        ,
        .fields = &.{.{ "all", .boolean }},
        .run = reports,
    },
    .{
        .name = "cpull_report_show",
        .description = "One report: where it points, its note and its web UI path.",
        .schema = report_schema,
        .fields = &.{.{ "id", .string }},
        .run = reportShow,
    },
    .{
        .name = "cpull_report_close",
        .description = "Close a report (its cpull issue).",
        .schema = report_schema,
        .fields = &.{.{ "id", .string }},
        .run = reportClose,
    },
    .{
        .name = "cpull_report_reopen",
        .description = "Reopen a closed report.",
        .schema = report_schema,
        .fields = &.{.{ "id", .string }},
        .run = reportReopen,
    },
};

const report_schema =
    \\{"$schema":"https://json-schema.org/draft/2020-12/schema","properties":{"id":{"description":"Report id (a unique prefix will do).","type":"string"}},"required":["id"],"type":"object"}
;

fn report(ctx: *const Ctx, a: Allocator, args: Args) !Result {
    const line = args.int("line") orelse return .{ .err = "line is required" };
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ "cpull", "report", args.str("repo").?, args.str("file").?, try std.fmt.allocPrint(a, "{d}", .{line}), "--source", args.str("source") orelse "mcp" });
    inline for (.{ .{ "note", "--note" }, .{ "quote", "--quote" }, .{ "title", "--title" } }) |f|
        if (args.str(f[0])) |v| try argv.appendSlice(a, &.{ f[1], v });
    return runPull(ctx, a, argv.items);
}

fn reports(ctx: *const Ctx, a: Allocator, args: Args) !Result {
    return runPull(ctx, a, if (args.flag("all")) &.{ "cpull", "report", "list", "--all" } else &.{ "cpull", "report", "list" });
}

fn reportShow(ctx: *const Ctx, a: Allocator, args: Args) !Result {
    return runPull(ctx, a, &.{ "cpull", "report", "show", args.str("id").? });
}

fn reportClose(ctx: *const Ctx, a: Allocator, args: Args) !Result {
    return runPull(ctx, a, &.{ "cpull", "report", "close", args.str("id").? });
}

fn reportReopen(ctx: *const Ctx, a: Allocator, args: Args) !Result {
    return runPull(ctx, a, &.{ "cpull", "report", "reopen", args.str("id").? });
}

/// Whether the root repo holds the workspace's stacks (so sync includes it).
fn rootHoldsStacks(a: Allocator, root: []const u8, pf: core.Pullfile) bool {
    const ev = (cpull.stack.eventsRepo(a, root, pf) catch return false) orelse return false;
    return std.mem.eql(u8, ev.name, cpull.stack.ROOT);
}

fn names(a: Allocator, pf: core.Pullfile, only: ?[]const u8) ![]const []const u8 {
    return cpull.select(a, pf, if (only) |r| &.{r} else &.{});
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
    const repos = try cpull.collect(a, ctx.root, try names(a, pf, args.str("repo")), args.flag("all"));
    var w: std.Io.Writer.Allocating = .init(a);
    try cpull.writeList(&w.writer, repos);
    if (repos.len == 0) return .{ .ok = "no repo has a cpull/events branch" };
    return .{ .ok = try tools.truncate(a, w.written(), tools.MAX_OUTPUT) };
}

/// The repo `args.repo` names, opened.
fn repo(ctx: *const Ctx, a: Allocator, pf: core.Pullfile, args: Args) !*git.Repo {
    const name = args.str("repo").?;
    _ = try cpull.select(a, pf, &.{name});
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
    try cpull.writeIssue(&w.writer, try cpull.find(try cpull.issues(a, r), args.str("issue").?));
    return .{ .ok = try tools.truncate(a, w.written(), tools.MAX_OUTPUT) };
}

fn newIssue(ctx: *const Ctx, a: Allocator, args: Args) !Result {
    const pf = switch (tools.pullfile(ctx, a)) {
        .ok => |p| p,
        .err => |m| return .{ .err = m },
    };
    const r = try repo(ctx, a, pf, args);
    defer r.close();
    const id = try cpull.create(a, r, try identity(ctx, a, pf), args.str("title").?, args.str("body") orelse "", args.str("labels") orelse "");
    return .{ .ok = try std.fmt.allocPrint(a, "{s}: opened {s}", .{ args.str("repo").?, id }) };
}

fn comment(ctx: *const Ctx, a: Allocator, args: Args) !Result {
    const pf = switch (tools.pullfile(ctx, a)) {
        .ok => |p| p,
        .err => |m| return .{ .err = m },
    };
    const r = try repo(ctx, a, pf, args);
    defer r.close();
    const i, const id = try cpull.comment(a, r, try identity(ctx, a, pf), args.str("issue").?, args.str("body").?);
    return .{ .ok = try std.fmt.allocPrint(a, "{s}: commented on {s} ({s})", .{ args.str("repo").?, i.id, id }) };
}

fn setStatus(ctx: *const Ctx, a: Allocator, args: Args, status: cpull.Status) !Result {
    const pf = switch (tools.pullfile(ctx, a)) {
        .ok => |p| p,
        .err => |m| return .{ .err = m },
    };
    const r = try repo(ctx, a, pf, args);
    defer r.close();
    const name = args.str("repo").?;
    const i = try cpull.setStatus(a, r, try identity(ctx, a, pf), args.str("issue").?, status) orelse
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
    cpull.syncAll(a, ctx.root, try names(a, pf, args.str("repo")), args.str("repo") == null and rootHoldsStacks(a, ctx.root, pf), try identity(ctx, a, pf), &w.writer) catch |e|
        return .{ .err = try std.fmt.allocPrint(a, "{s}{s}", .{ w.written(), tools.describe(a, e) }) };
    return .{ .ok = if (w.written().len == 0) "no repo has a cpull/events branch" else w.written() };
}

// ---------------------------------------------------------------- stacks

fn stacks(ctx: *const Ctx, a: Allocator, _: Args) !Result {
    const pf = switch (tools.pullfile(ctx, a)) {
        .ok => |p| p,
        .err => |m| return .{ .err = m },
    };
    _, const r = try cpull.stack.openEvents(a, ctx.root, pf);
    defer r.close();
    var w: std.Io.Writer.Allocating = .init(a);
    try cpull.stack.writeList(&w.writer, try cpull.stack.stacks(a, r));
    return .{ .ok = try tools.truncate(a, w.written(), tools.MAX_OUTPUT) };
}

fn stack(ctx: *const Ctx, a: Allocator, args: Args) !Result {
    const pf = switch (tools.pullfile(ctx, a)) {
        .ok => |p| p,
        .err => |m| return .{ .err = m },
    };
    const s, const infos = try cpull.stack.withPatches(a, ctx.root, pf, args.str("stack").?);
    var w: std.Io.Writer.Allocating = .init(a);
    try cpull.stack.writeStack(&w.writer, s, infos);
    // its CI and the merge gate, from the workspace server when it runs
    if (try ci.stackStatus(ctx, a, s.id)) |text| try w.writer.writeAll(text);
    return .{ .ok = try tools.truncate(a, w.written(), tools.MAX_OUTPUT) };
}

fn patch(ctx: *const Ctx, a: Allocator, args: Args) !Result {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ "cpull", "patch" });
    inline for (.{ .{ "title", "--title" }, .{ "body", "--body" }, .{ "labels", "--labels" }, .{ "branch", "--branch" } }) |f|
        if (args.str(f[0])) |v| try argv.appendSlice(a, &.{ f[1], v });
    return runPull(ctx, a, argv.items);
}

fn merge(ctx: *const Ctx, a: Allocator, args: Args) !Result {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ "cpull", "merge" });
    if (args.str("message")) |m| try argv.appendSlice(a, &.{ "--message", m });
    if (args.flag("force")) try argv.append(a, "--force");
    try argv.append(a, args.str("stack").?);
    return runPull(ctx, a, argv.items);
}

/// Run `pull ARGS` in the workspace: the bin owns cpull's env and identity, the
/// hooks and the signed pullfile commit.
fn runPull(ctx: *const Ctx, a: Allocator, args: []const []const u8) !Result {
    const argv = try std.mem.concat(a, []const u8, &.{ &.{ctx.exe orelse "pull"}, args });
    var env = try core.sys.envMap(a);
    for (ctx.env(a, ctx.root)) |v| try env.put(v.key, v.value);
    try env.put("PULL_ROOT", ctx.root);
    const res = core.sys.run(a, argv, .{ .cwd = ctx.root, .env = &env }) catch |e| return .{ .err = tools.describe(a, e) };
    const out = try std.mem.concat(a, u8, &.{ res.stdout, res.stderr });
    const text = std.mem.trimEnd(u8, out, "\n");
    if (!res.ok()) return .{ .err = if (text.len == 0) "pull failed" else text };
    return .{ .ok = try tools.truncate(a, text, tools.MAX_OUTPUT) };
}
