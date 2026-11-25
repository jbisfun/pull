//! The workspace tools: workspace, status, diff, log, grep, list_files, read_file,
//! exec. Output is the Rust server's, byte for byte.
const std = @import("std");
const core = @import("core");
const git = @import("git");
const Regex = @import("regex");
const mcp = @import("mcp.zig");
const walk = @import("walk.zig");
const Args = @import("args.zig").Args;
const opts = @import("mcp_options");
const launchd = if (opts.sessions) @import("launchd") else struct {};

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Ctx = mcp.Ctx;
const Result = mcp.Result;
const sys = core.sys;

pub const MAX_OUTPUT: usize = 60_000;

const repo_schema =
    \\{"$schema":"https://json-schema.org/draft/2020-12/schema","properties":{"repo":{"description":"Repo name from the pullfile; omit for every repo.","type":["string","null"]}},"type":"object"}
;

pub const defs = [_]mcp.Def{
    .{
        .name = "workspace",
        .description = "Overview of the pull workspace: root, every repo (upstream, branch, HEAD, pinned commit, ahead/behind origin, changed files), lint rules, env and jobs. Start here.",
        .schema = "{\"properties\":{},\"type\":\"object\"}",
        .run = workspace,
    },
    .{
        .name = "status",
        .description = "Changed files per repo (git status, XY format like `git status -s`).",
        .schema = repo_schema,
        .fields = &.{.{ "repo", .opt_string }},
        .run = status,
    },
    .{
        .name = "diff",
        .description = "Unified diff of uncommitted changes, per repo (unstaged by default, or staged).",
        .schema =
        \\{"$schema":"https://json-schema.org/draft/2020-12/schema","properties":{"path":{"description":"Only this path (relative to the repo).","type":["string","null"]},"repo":{"description":"Repo name; omit for every repo.","type":["string","null"]},"staged":{"default":false,"description":"Staged changes (index vs HEAD) instead of unstaged (worktree vs index).","type":"boolean"}},"type":"object"}
        ,
        .fields = &.{ .{ "repo", .opt_string }, .{ "path", .opt_string }, .{ "staged", .boolean } },
        .run = diff,
    },
    .{
        .name = "log",
        .description = "Recent commits per repo: short id, date, author, subject.",
        .schema =
        \\{"$schema":"https://json-schema.org/draft/2020-12/schema","properties":{"limit":{"description":"Commits per repo (default 10).","format":"uint","minimum":0,"type":["integer","null"]},"repo":{"description":"Repo name; omit for every repo.","type":["string","null"]}},"type":"object"}
        ,
        .fields = &.{ .{ "repo", .opt_string }, .{ "limit", .opt_usize } },
        .run = log,
    },
    .{
        .name = "grep",
        .description = "Search file contents across the workspace's repos with a regex (ripgrep's engine; respects .gitignore). Returns repo/path:line: text.",
        .schema =
        \\{"$schema":"https://json-schema.org/draft/2020-12/schema","properties":{"glob":{"description":"Glob of files to include, e.g. \"*.rs\" or \"src/**\".","type":["string","null"]},"max_results":{"description":"Maximum matching lines (default 200).","format":"uint","minimum":0,"type":["integer","null"]},"pattern":{"description":"Regular expression (Rust/ripgrep syntax; smart case).","type":"string"},"repo":{"description":"Repo name; omit to search every repo.","type":["string","null"]}},"required":["pattern"],"type":"object"}
        ,
        .fields = &.{ .{ "pattern", .string }, .{ "repo", .opt_string }, .{ "glob", .opt_string }, .{ "max_results", .opt_usize } },
        .run = grep,
    },
    .{
        .name = "list_files",
        .description = "List files under a workspace directory (respects .gitignore).",
        .schema =
        \\{"$schema":"https://json-schema.org/draft/2020-12/schema","properties":{"glob":{"description":"Glob of files to include.","type":["string","null"]},"max_results":{"description":"Maximum entries (default 500).","format":"uint","minimum":0,"type":["integer","null"]},"path":{"description":"Directory relative to the workspace root (default: the root).","type":["string","null"]}},"type":"object"}
        ,
        .fields = &.{ .{ "path", .opt_string }, .{ "glob", .opt_string }, .{ "max_results", .opt_usize } },
        .run = listFiles,
    },
    .{
        .name = "read_file",
        .description = "Read a file (path relative to the workspace root), with line numbers.",
        .schema =
        \\{"$schema":"https://json-schema.org/draft/2020-12/schema","properties":{"end_line":{"description":"Last line, inclusive (default: start + 400).","format":"uint","minimum":0,"type":["integer","null"]},"path":{"description":"File path relative to the workspace root (e.g. \"pull/src/main.rs\").","type":"string"},"start_line":{"description":"First line, 1-based (default 1).","format":"uint","minimum":0,"type":["integer","null"]}},"required":["path"],"type":"object"}
        ,
        .fields = &.{ .{ "path", .string }, .{ "start_line", .opt_usize }, .{ "end_line", .opt_usize } },
        .run = readFile,
    },
    .{
        .name = "exec",
        .description = "Run a shell command to completion with the workspace env (PATH, toolchains) and return its exit code and output. For long-running or interactive programs use session_new instead.",
        .schema =
        \\{"$schema":"https://json-schema.org/draft/2020-12/schema","properties":{"command":{"description":"Shell command (sh -c), run with the workspace env.","type":"string"},"cwd":{"description":"Working directory relative to the workspace root (default: the root).","type":["string","null"]},"timeout_ms":{"description":"Kill it after this many ms (default 120000).","format":"uint64","minimum":0,"type":["integer","null"]}},"required":["command"],"type":"object"}
        ,
        .fields = &.{ .{ "command", .string }, .{ "cwd", .opt_string }, .{ "timeout_ms", .opt_u64 } },
        .run = exec,
    },
};

// ---------------------------------------------------------------- helpers

/// An error as Rust's io::Error displays it ("No such file or directory (os error 2)").
pub fn describe(a: Allocator, e: anyerror) []const u8 {
    const os: ?struct { []const u8, u8 } = switch (e) {
        error.FileNotFound => .{ "No such file or directory", 2 },
        error.AccessDenied, error.PermissionDenied => .{ "Permission denied", 13 },
        error.NotDir => .{ "Not a directory", 20 },
        error.IsDir => .{ "Is a directory", 21 },
        error.NameTooLong => .{ "File name too long", 36 },
        error.SymLinkLoop => .{ "Too many levels of symbolic links", 40 },
        else => null,
    };
    if (os) |o| return std.fmt.allocPrint(a, "{s} (os error {d})", .{ o[0], o[1] }) catch o[0];
    if (e == error.InvalidUtf8) return "stream did not contain valid UTF-8";
    return sys.describe(e);
}

/// Keep tool output within what an agent can take in one go.
pub fn truncate(a: Allocator, s: []const u8, max: usize) ![]const u8 {
    if (s.len <= max) return s;
    var cut = max;
    while (cut > 0 and (s[cut] & 0xc0) == 0x80) cut -= 1;
    return std.fmt.allocPrint(a, "{s}\n… truncated ({d} bytes total)", .{ s[0..cut], s.len });
}

fn fail(a: Allocator, comptime fmt: []const u8, args: anytype) !Result {
    return .{ .err = try std.fmt.allocPrint(a, fmt, args) };
}

pub fn pullfile(ctx: *const Ctx, a: Allocator) union(enum) { ok: core.Pullfile, err: []const u8 } {
    const pf = core.Pullfile.load(a, ctx.root) catch |e| return .{ .err = describe(a, e) };
    return .{ .ok = pf };
}

const Named = struct { name: []const u8, repo: *git.Repo };

/// (name, repo) for `only`, or every cloned repo.
fn repos(ctx: *const Ctx, a: Allocator, only: ?[]const u8) !union(enum) { ok: []Named, err: []const u8 } {
    const pf = switch (pullfile(ctx, a)) {
        .ok => |p| p,
        .err => |m| return .{ .err = m },
    };
    if (only) |n| {
        for (pf.repos.items) |r| {
            if (std.mem.eql(u8, r.name, n)) break;
        } else return .{ .err = try std.fmt.allocPrint(a, "no repo named {s} in the pullfile", .{n}) };
    }
    var out: std.ArrayList(Named) = .empty;
    for (pf.repos.items) |r| {
        if (only) |n| if (!std.mem.eql(u8, n, r.name)) continue;
        const p = try std.fs.path.join(a, &.{ ctx.root, r.name });
        const repo = git.Repo.open(a, p) catch continue;
        try out.append(a, .{ .name = r.name, .repo = repo });
    }
    return .{ .ok = out.items };
}

fn closeAll(list: []Named) void {
    for (list) |n| n.repo.close();
}

/// A path inside the workspace (no escaping it with `..`), canonical.
pub fn inside(ctx: *const Ctx, a: Allocator, rel_path: ?[]const u8) !union(enum) { ok: []const u8, err: []const u8 } {
    const p = if (rel_path) |r| (if (r.len > 0) (if (std.fs.path.isAbsolute(r)) r else try std.fs.path.join(a, &.{ ctx.root, r })) else ctx.root) else ctx.root;
    const canon = sys.realpath(a, p) catch |e| return .{ .err = try std.fmt.allocPrint(a, "{s}: {s}", .{ p, describe(a, e) }) };
    const root = sys.realpath(a, ctx.root) catch |e| return .{ .err = describe(a, e) };
    if (!startsWithPath(canon, root)) return .{ .err = try std.fmt.allocPrint(a, "{s} is outside the workspace", .{p}) };
    return .{ .ok = canon };
}

fn startsWithPath(p: []const u8, base: []const u8) bool {
    if (!std.mem.startsWith(u8, p, base)) return false;
    return p.len == base.len or p[base.len] == '/' or std.mem.eql(u8, base, "/");
}

/// `p` relative to the workspace root (or `p` itself if it isn't under it).
fn rel(ctx: *const Ctx, p: []const u8) []const u8 {
    if (!startsWithPath(p, ctx.root)) return p;
    if (p.len == ctx.root.len) return "";
    return p[ctx.root.len + 1 ..];
}

fn statusLines(a: Allocator, repo: *git.Repo) ![]const []const u8 {
    const changes = try repo.changes(false);
    const out = try a.alloc([]const u8, changes.len);
    for (out, changes) |*o, c| o.* = try std.fmt.allocPrint(a, "{c}{c} {s}", .{ c.staged, c.unstaged, c.path });
    return out;
}

/// A plist scalar as text (for showing pullfile sections).
fn scalar(a: Allocator, v: core.plist.Value) ![]const u8 {
    return switch (v) {
        .boolean => |b| if (b) "true" else "false",
        .integer => |i| std.fmt.allocPrint(a, "{d}", .{i}),
        .real => |r| std.fmt.allocPrint(a, "{d}", .{r}),
        .string => |s| s,
        .date => |s| std.fmt.allocPrint(a, "Date({s})", .{s}),
        .data => "Data(..)",
        .array => "Array(..)",
        .dict => "Dictionary(..)",
    };
}

// ---------------------------------------------------------------- tools

fn workspace(ctx: *const Ctx, a: Allocator, _: Args) !Result {
    const pf = switch (pullfile(ctx, a)) {
        .ok => |p| p,
        .err => |m| return .{ .err = m },
    };
    var w: std.Io.Writer.Allocating = .init(a);
    const o = &w.writer;
    try o.print("root: {s}\n", .{ctx.root});
    if (pf.sectionValue("lint")) |lint| if (lint == .dict) {
        try o.writeAll("lint:");
        for (lint.dict.entries.items) |e| try o.print(" {s}={s}", .{ e.key, try scalar(a, e.value) });
        try o.writeAll("\n");
    };
    try o.writeAll("repos:\n");
    for (pf.repos.items) |r| {
        try o.print("  {s} ({s}, branch {s})", .{ r.name, r.upstream, r.branch });
        const p = try std.fs.path.join(a, &.{ ctx.root, r.name });
        const repo = git.Repo.open(a, p) catch {
            try o.writeAll(" not cloned\n");
            continue;
        };
        defer repo.close();
        const head = repo.head() catch git.Repo.Head{ .branch = null, .oid = null };
        const branch = if (head.oid == null) "(unborn)" else head.branch orelse "HEAD";
        try o.print(": on {s} at {s}", .{ branch, if (head.oid) |h| git.short(h) else "-" });
        if (r.commit) |pin| {
            if (head.oid) |h| if (!std.mem.eql(u8, pin, &h)) try o.print(", pinned {s}", .{pin[0..@min(8, pin.len)]});
        } else try o.writeAll(", unpinned");
        if (head.oid) |h| if (repo.remoteOid(r.branch)) |org| if (!std.mem.eql(u8, &h, &org)) {
            if (repo.aheadBehind(h, org)) |ab| try o.print(", +{d}/-{d} origin", .{ ab[0], ab[1] }) else |_| {}
        };
        const changed = if (statusLines(a, repo)) |l| l.len else |_| 0;
        try o.print(", {d} changed\n", .{changed});
    }
    const env = ctx.env(a, ctx.root);
    if (env.len > 0) {
        try o.writeAll("env:\n");
        for (env) |v| if (!std.mem.eql(u8, v.key, "PATH")) try o.print("  {s}={s}\n", .{ v.key, v.value });
    }
    if (opts.sessions) if (ctx.jobs) |jobs_fn| {
        const jobs = jobs_fn(a, ctx.root) catch |e| return .{ .err = describe(a, e) };
        if (jobs.len > 0) {
            try o.writeAll("jobs:\n");
            for (jobs) |j| try o.print("  {s}: {s}\n", .{ j.label, try std.mem.join(a, " ", try j.argv(a)) });
        }
    };
    return .{ .ok = w.written() };
}

fn status(ctx: *const Ctx, a: Allocator, args: Args) !Result {
    const list = switch (try repos(ctx, a, args.str("repo"))) {
        .ok => |l| l,
        .err => |m| return .{ .err = m },
    };
    defer closeAll(list);
    var w: std.Io.Writer.Allocating = .init(a);
    for (list) |n| {
        const lines = statusLines(a, n.repo) catch |e| return .{ .err = describe(a, e) };
        try w.writer.print("{s}: {s}\n", .{ n.name, if (lines.len == 0) "clean" else "" });
        for (lines) |l| try w.writer.print("  {s}\n", .{l});
    }
    return .{ .ok = w.written() };
}

/// git CLI: the patch libgit2 printed (`git diff` is its reference format).
fn diff(ctx: *const Ctx, a: Allocator, args: Args) !Result {
    const list = switch (try repos(ctx, a, args.str("repo"))) {
        .ok => |l| l,
        .err => |m| return .{ .err = m },
    };
    defer closeAll(list);
    var w: std.Io.Writer.Allocating = .init(a);
    for (list) |n| {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(a, &.{ "-c", "core.quotePath=false", "-c", "diff.noprefix=false", "-c", "diff.mnemonicPrefix=false", "-c", "diff.relative=false", "diff", "--no-color", "--no-ext-diff", "--no-textconv", "--no-renames", "--src-prefix=a/", "--dst-prefix=b/" });
        if (args.flag("staged")) try argv.append(a, "--cached");
        try argv.append(a, "--");
        if (args.str("path")) |p| try argv.append(a, p);
        const out = git.runGit(a, n.repo.path, argv.items, null) catch |e| return .{ .err = describe(a, e) };
        if (out.len == 0) continue;
        try w.writer.print("### {s}\n", .{n.name});
        try w.writer.writeAll(out);
        if (w.written().len >= MAX_OUTPUT * 2) break;
    }
    if (w.written().len == 0) return .{ .ok = "no changes" };
    return .{ .ok = try truncate(a, w.written(), MAX_OUTPUT) };
}

/// git CLI: commits from HEAD, newest commit time first (libgit2's Sort::TIME).
fn log(ctx: *const Ctx, a: Allocator, args: Args) !Result {
    const limit = args.int("limit") orelse 10;
    const list = switch (try repos(ctx, a, args.str("repo"))) {
        .ok => |l| l,
        .err => |m| return .{ .err = m },
    };
    defer closeAll(list);
    var w: std.Io.Writer.Allocating = .init(a);
    for (list) |n| {
        try w.writer.print("{s}:\n", .{n.name});
        if (limit == 0) continue;
        const max = try std.fmt.allocPrint(a, "--max-count={d}", .{@min(limit, std.math.maxInt(i32))});
        const out = git.runGit(a, n.repo.path, &.{ "log", "--no-color", "--date-order", max, "--format=%H%x1f%ct%x1f%an%x1f%s", "HEAD", "--" }, null) catch continue;
        var lines = std.mem.splitScalar(u8, out, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            var f = std.mem.splitScalar(u8, line, 0x1f);
            const oid = f.next() orelse continue;
            const when = std.fmt.parseInt(i64, f.next() orelse "0", 10) catch 0;
            const author = f.next() orelse "?";
            const subject = f.rest();
            try w.writer.print("  {s} {s} {s} {s}\n", .{ oid[0..@min(8, oid.len)], try formatDate(a, when), author, subject });
        }
    }
    return .{ .ok = w.written() };
}

/// UTC `%Y-%m-%d`.
fn formatDate(a: Allocator, secs: i64) ![]const u8 {
    if (secs < 0) return "";
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(secs) };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    return std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2}", .{ yd.year, md.month.numeric(), md.day_index + 1 });
}

// ---------------------------------------------------------------- grep

/// grep-regex's smart case: insensitive when the pattern has a literal and no
/// uppercase one (escapes like `\W` or `\x4A` aren't literals).
fn caseInsensitive(pattern: []const u8) bool {
    var any_literal = false;
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        const c = pattern[i];
        if (c == '\\') {
            i += 1;
            if (i >= pattern.len) break;
            const e = pattern[i];
            if ((e == 'p' or e == 'P' or e == 'x' or e == 'u' or e == 'U') and i + 1 < pattern.len and pattern[i + 1] == '{') {
                i = std.mem.indexOfScalarPos(u8, pattern, i, '}') orelse pattern.len;
            } else if (e == 'x') {
                i += 2;
            } else if (!std.ascii.isAlphanumeric(e)) {
                any_literal = true;
            }
            continue;
        }
        if (std.mem.indexOfScalar(u8, "()|*+?{}[]^$.-", c) != null) continue;
        any_literal = true;
        if (std.ascii.isUpper(c)) return false;
    }
    return any_literal;
}

fn regexError(a: Allocator, wrapped: []const u8, diag: Regex.Diagnostics) ![]const u8 {
    const P = Regex.Diagnostics.ParseError;
    switch (diag) {
        .parse => |p| {
            const msg = switch (p.err) {
                P.class_ascii_invalid => "invalid ASCII character class",
                P.class_not_closed => "unclosed character class",
                P.class_range_invalid => "invalid character class range, the start must be <= the end",
                P.escape_at_eof => "incomplete escape sequence, reached end of pattern prematurely",
                P.escape_hex_brace_not_closed => "unclosed hexadecimal literal",
                P.escape_hex_digit_invalid => "invalid hexadecimal digit",
                P.escape_hex_value_invalid => "hexadecimal literal is not a Unicode scalar value",
                P.escape_invalid => "unrecognized escape sequence",
                P.flag_disable_op_dangling => "dangling flag negation operator",
                P.flag_disable_op_duplicated => "flag negation operator repeated",
                P.flag_duplicated => "duplicate flag",
                P.flag_unsupported => "unrecognized flag",
                P.group_close_unexpected => "unopened group",
                P.group_name_duplicated => "duplicate capture group name",
                P.group_name_invalid => "invalid capture group character",
                P.group_name_not_closed => "unclosed capture group name",
                P.group_not_closed => "unclosed group",
                P.utf8_codepoint_invalid => "pattern can only contain valid UTF-8",
                P.repeat_argument_missing => "repetition operator missing expression",
                P.repeat_count_empty => "repetition quantifier expects a valid decimal",
                P.repeat_count_format_invalid => "repetition quantifier expects a valid decimal",
                P.repeat_count_not_closed => "unclosed counted repetition",
                P.repeat_size_invalid => "invalid repetition count range, the start must be <= the end",
                P.unsupported_feature => "unsupported regex feature",
            };
            const start = @min(p.span.start, wrapped.len);
            const end = @max(start + 1, @min(p.span.end, wrapped.len));
            var w: std.Io.Writer.Allocating = .init(a);
            try w.writer.print("regex parse error:\n    {s}\n    ", .{wrapped});
            try w.writer.splatByteAll(' ', start);
            try w.writer.splatByteAll('^', end - start);
            try w.writer.print("\nerror: {s}", .{msg});
            return w.written();
        },
        .compile => return "Compiled regex exceeds size limit",
    }
}

/// Rust's `str::trim_end` (Unicode White_Space).
fn trimEnd(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 0) {
        var start = end - 1;
        while (start > 0 and (s[start] & 0xc0) == 0x80) start -= 1;
        const cp = std.unicode.utf8Decode(s[start..end]) catch break;
        const ws = switch (cp) {
            0x09...0x0d, 0x20, 0x85, 0xa0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000 => true,
            else => false,
        };
        if (!ws) break;
        end = start;
    }
    return s[0..end];
}

const GrepState = struct {
    ctx: *const Ctx,
    a: Allocator,
    re: *Regex,
    out: *std.Io.Writer,
    n: usize = 0,
    max: usize,
    done: bool = false,

    fn file(g: *GrepState, abs: []const u8) anyerror!walk.Visit {
        const data = Io.Dir.cwd().readFileAlloc(g.ctx.io, abs, g.a, .unlimited) catch return .more;
        // grep-searcher's BinaryDetection::quit: stop at the 64 KiB buffer holding a NUL.
        const limit = if (std.mem.indexOfScalar(u8, data, 0)) |z| z - z % (64 * 1024) else data.len;
        const r = rel(g.ctx, abs);
        var line_no: usize = 0;
        var at: usize = 0;
        while (at < data.len) {
            const nl = std.mem.indexOfScalarPos(u8, data, at, '\n');
            const end = nl orelse data.len;
            const next = if (nl) |x| x + 1 else data.len;
            if (next > limit) break;
            line_no += 1;
            const line = data[at..end];
            at = next;
            if (!g.re.match(line)) continue;
            // The UTF-8 sink fails (and ends the file) on a line that isn't UTF-8.
            if (!std.unicode.utf8ValidateSlice(line)) break;
            var text = trimEnd(line);
            if (text.len > 300) text = try truncate(g.a, text, 300);
            try g.out.print("{s}:{d}: {s}\n", .{ r, line_no, text });
            g.n += 1;
            if (g.n >= g.max) {
                g.done = true;
                return .stop;
            }
        }
        return .more;
    }
};

fn grep(ctx: *const Ctx, a: Allocator, args: Args) !Result {
    const max = args.int("max_results") orelse 200;
    const pattern = args.str("pattern").?;
    const wrapped = try std.fmt.allocPrint(a, "(?:{s})", .{pattern});
    var diag: Regex.Diagnostics = undefined;
    var re = Regex.compile(a, wrapped, .{
        .syntax = .{ .case_insensitive = caseInsensitive(pattern), .unicode = true },
        .limits = .{ .max_repeat = std.math.maxInt(u16) },
        .diag = &diag,
    }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .err = try regexError(a, wrapped, diag) },
    };
    defer re.deinit();
    const list = switch (try repos(ctx, a, args.str("repo"))) {
        .ok => |l| l,
        .err => |m| return .{ .err = m },
    };
    closeAll(list);
    var w: std.Io.Writer.Allocating = .init(a);
    var g: GrepState = .{ .ctx = ctx, .a = a, .re = &re, .out = &w.writer, .max = max };
    for (list) |n| {
        var msg: []const u8 = "";
        var walker = walk.Walk.init(a, ctx.io, args.str("glob"), &msg) catch |e| switch (e) {
            error.InvalidGlob => return .{ .err = msg },
            else => return e,
        };
        try walker.run(n.repo.path, &g, GrepState.file);
        if (g.done) {
            try w.writer.print("… stopped at {d} results\n", .{max});
            break;
        }
    }
    if (w.written().len == 0) return .{ .ok = "no matches" };
    return .{ .ok = try truncate(a, w.written(), MAX_OUTPUT) };
}

// ---------------------------------------------------------------- files

const ListState = struct {
    ctx: *const Ctx,
    out: *std.Io.Writer,
    n: usize = 0,
    max: usize,

    fn file(l: *ListState, abs: []const u8) anyerror!walk.Visit {
        try l.out.print("{s}\n", .{rel(l.ctx, abs)});
        l.n += 1;
        if (l.n >= l.max) {
            try l.out.print("… stopped at {d} entries\n", .{l.max});
            return .stop;
        }
        return .more;
    }
};

fn listFiles(ctx: *const Ctx, a: Allocator, args: Args) !Result {
    const dir = switch (try inside(ctx, a, args.str("path"))) {
        .ok => |d| d,
        .err => |m| return .{ .err = m },
    };
    var w: std.Io.Writer.Allocating = .init(a);
    var l: ListState = .{ .ctx = ctx, .out = &w.writer, .max = args.int("max_results") orelse 500 };
    var msg: []const u8 = "";
    var walker = walk.Walk.init(a, ctx.io, args.str("glob"), &msg) catch |e| switch (e) {
        error.InvalidGlob => return .{ .err = msg },
        else => return e,
    };
    try walker.run(dir, &l, ListState.file);
    return .{ .ok = w.written() };
}

fn readFile(ctx: *const Ctx, a: Allocator, args: Args) !Result {
    const req = args.str("path").?;
    const path = switch (try inside(ctx, a, req)) {
        .ok => |p| p,
        .err => |m| return .{ .err = m },
    };
    const text = Io.Dir.cwd().readFileAlloc(ctx.io, path, a, .unlimited) catch |e| return fail(a, "{s}: {s}", .{ req, describe(a, e) });
    if (!std.unicode.utf8ValidateSlice(text)) return fail(a, "{s}: {s}", .{ req, describe(a, error.InvalidUtf8) });
    // Rust's str::lines: split on \n, drop a trailing empty line and each line's \r.
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| try lines.append(a, if (l.len > 0 and l[l.len - 1] == '\r') l[0 .. l.len - 1] else l);
    if (text.len == 0 or text[text.len - 1] == '\n') _ = lines.pop();
    const total = lines.items.len;
    const start = @max(args.int("start_line") orelse 1, 1);
    const end = args.int("end_line") orelse start +| 400;
    // `take(end + 1 - start)` wraps in a release build: everything from `start`.
    const count = if (end +| 1 >= start) end +| 1 - start else std.math.maxInt(u64);
    var w: std.Io.Writer.Allocating = .init(a);
    var i: u64 = start - 1;
    var taken: u64 = 0;
    while (i < total and taken < count) : ({
        i += 1;
        taken += 1;
    }) try w.writer.print("{d: >5}|{s}\n", .{ i + 1, lines.items[@intCast(i)] });
    if (end < total) try w.writer.print("… {d} lines total; continue with start_line={d}\n", .{ total, end + 1 });
    return .{ .ok = try truncate(a, w.written(), MAX_OUTPUT) };
}

// ---------------------------------------------------------------- exec

fn exec(ctx: *const Ctx, a: Allocator, args: Args) !Result {
    const cwd = switch (try inside(ctx, a, args.str("cwd"))) {
        .ok => |p| p,
        .err => |m| return .{ .err = m },
    };
    const timeout_ms = args.int("timeout_ms") orelse 120_000;
    var env = try sys.envMap(a);
    for (ctx.env(a, ctx.root)) |v| try env.put(v.key, v.value);
    var child = sys.spawn(&.{ "sh", "-c", args.str("command").? }, .{
        .cwd = cwd,
        .env = &env,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |e| return .{ .err = describe(a, e) };
    defer child.kill(ctx.io);
    const io = ctx.io;
    const deadline: Io.Timeout = .{ .deadline = .fromNow(io, .{ .raw = .fromMilliseconds(@intCast(@min(timeout_ms, std.math.maxInt(i64)))), .clock = .awake }) };
    var mr_buf: Io.File.MultiReader.Buffer(2) = undefined;
    var mr: Io.File.MultiReader = undefined;
    mr.init(a, io, mr_buf.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer mr.deinit();
    while (mr.fill(64, deadline)) |_| {} else |e| switch (e) {
        error.EndOfStream => {},
        error.Timeout => return fail(a, "timed out after {d} ms (killed)", .{timeout_ms}),
        else => |x| return .{ .err = describe(a, x) },
    }
    const term = child.wait(io) catch |e| return .{ .err = describe(a, e) };
    const code: i64 = switch (term) {
        .exited => |c| c,
        else => -1,
    };
    var w: std.Io.Writer.Allocating = .init(a);
    try w.writer.print("exit {d}\n", .{code});
    try lossy(&w.writer, try mr.toOwnedSlice(0));
    const stderr = try mr.toOwnedSlice(1);
    if (stderr.len > 0) {
        try w.writer.writeAll("\n[stderr]\n");
        try lossy(&w.writer, stderr);
    }
    return .{ .ok = try truncate(a, w.written(), MAX_OUTPUT) };
}

/// `String::from_utf8_lossy`.
fn lossy(w: *std.Io.Writer, bytes: []const u8) !void {
    var i: usize = 0;
    while (i < bytes.len) {
        const n = std.unicode.utf8ByteSequenceLength(bytes[i]) catch {
            try w.writeAll("\u{fffd}");
            i += 1;
            continue;
        };
        if (i + n <= bytes.len and std.unicode.utf8ValidateSlice(bytes[i .. i + n])) {
            try w.writeAll(bytes[i .. i + n]);
            i += n;
        } else {
            try w.writeAll("\u{fffd}");
            i += 1;
        }
    }
}

test caseInsensitive {
    try std.testing.expect(caseInsensitive("todo"));
    try std.testing.expect(!caseInsensitive("TODO"));
    try std.testing.expect(caseInsensitive("\\Wfoo"));
    try std.testing.expect(!caseInsensitive("\\d+"));
    try std.testing.expect(!caseInsensitive("[A-Z]x"));
}

test trimEnd {
    try std.testing.expectEqualStrings("a b", trimEnd("a b \t\r\n"));
    try std.testing.expectEqualStrings("x", trimEnd("x\u{3000}"));
}

test formatDate {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("2026-01-02", try formatDate(arena.allocator(), 1767348000));
}
