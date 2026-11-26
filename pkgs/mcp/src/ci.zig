//! ci_* tools: cpull's CI (idlci's port, src/ci in cpull) for the idl projects
//! of the workspace, through the workspace server's JSON API under /ci/api.
//! The same tools idlci's `idlci mcp` served (projects, queue, jobs, job, log,
//! wait, cancel, retry), with the same schemas and output.
const std = @import("std");
const mcp = @import("mcp.zig");
const Args = @import("args.zig").Args;

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Ctx = mcp.Ctx;
const Result = mcp.Result;

const default_addr = "127.0.0.1:8080";

const id_schema =
    \\{"$schema":"https://json-schema.org/draft/2020-12/schema","properties":{"id":{"format":"int64","type":"integer"}},"required":["id"],"type":"object"}
;

pub const defs = &[_]mcp.Def{
    .{
        .name = "ci_projects",
        .description = "cpull CI: list idl projects in the workspace with git state, targets and the latest job per command.",
        .schema = "{\"properties\":{},\"type\":\"object\"}",
        .run = projects,
    },
    .{
        .name = "ci_queue",
        .description = "cpull CI: queue an idl job (build|test|lint|fmt-check|check|clean) for a project; returns the job id. Use `ci_wait` to block until it finishes. Jobs run one at a time on a shared queue (the laptop overheats), so prefer targeted jobs and don't queue duplicates.",
        .schema =
        \\{"$defs":{"Command":{"enum":["build","test","lint","fmt-check","check","clean"],"type":"string"},"Configuration":{"enum":["debug","release","none"],"type":"string"}},"$schema":"https://json-schema.org/draft/2020-12/schema","properties":{"command":{"$ref":"#/$defs/Command"},"configuration":{"anyOf":[{"$ref":"#/$defs/Configuration"},{"type":"null"}],"description":"debug | release (default: idl's default)."},"project":{"description":"Project path relative to the workspace root (e.g. `fossify-ios/calculator-ios`), pull repo name, or last path segment.","type":"string"},"strict":{"description":"--strict (build/check only).","type":["boolean","null"]},"targets":{"description":"Targets (default: all).","items":{"type":"string"},"type":["array","null"]}},"required":["project","command"],"type":"object"}
        ,
        .fields = &.{ .{ "project", .string }, .{ "command", .string }, .{ "configuration", .opt_string } },
        .run = queue,
    },
    .{
        .name = "ci_jobs",
        .description = "cpull CI: list jobs, newest first (filters: status, project, limit).",
        .schema =
        \\{"$defs":{"Status":{"enum":["queued","running","passed","failed","cancelled"],"type":"string"}},"$schema":"https://json-schema.org/draft/2020-12/schema","properties":{"limit":{"description":"Default 20.","format":"uint","minimum":0,"type":["integer","null"]},"project":{"type":["string","null"]},"status":{"anyOf":[{"$ref":"#/$defs/Status"},{"type":"null"}]}},"type":"object"}
        ,
        .fields = &.{ .{ "status", .opt_string }, .{ "project", .opt_string }, .{ "limit", .opt_usize } },
        .run = jobs,
    },
    .{
        .name = "ci_job",
        .description = "cpull CI: job metadata plus the last log lines.",
        .schema =
        \\{"$schema":"https://json-schema.org/draft/2020-12/schema","properties":{"id":{"format":"int64","type":"integer"},"lines":{"description":"Log lines to include from the end (default 40).","format":"uint","minimum":0,"type":["integer","null"]}},"required":["id"],"type":"object"}
        ,
        .fields = &.{ .{ "id", .int }, .{ "lines", .opt_usize } },
        .run = job,
    },
    .{
        .name = "ci_log",
        .description = "cpull CI: read a job's log: from a byte offset (up to 1 MiB, returns next_offset) or the last `tail` lines.",
        .schema =
        \\{"$schema":"https://json-schema.org/draft/2020-12/schema","properties":{"id":{"format":"int64","type":"integer"},"offset":{"description":"Byte offset to read from (use the returned next_offset to continue).","format":"uint64","minimum":0,"type":["integer","null"]},"tail":{"description":"Only the last N lines (overrides offset).","format":"uint","minimum":0,"type":["integer","null"]}},"required":["id"],"type":"object"}
        ,
        .fields = &.{ .{ "id", .int }, .{ "offset", .opt_u64 }, .{ "tail", .opt_usize } },
        .run = log,
    },
    .{
        .name = "ci_wait",
        .description = "cpull CI: block until a job finishes (or timeout_s, default 300, max 600); returns its status and log tail.",
        .schema =
        \\{"$schema":"https://json-schema.org/draft/2020-12/schema","properties":{"id":{"format":"int64","type":"integer"},"lines":{"description":"Log lines to include from the end (default 40).","format":"uint","minimum":0,"type":["integer","null"]},"timeout_s":{"description":"Seconds to wait (default 300, max 600).","format":"uint64","minimum":0,"type":["integer","null"]}},"required":["id"],"type":"object"}
        ,
        .fields = &.{ .{ "id", .int }, .{ "lines", .opt_usize }, .{ "timeout_s", .opt_u64 } },
        .run = wait,
    },
    .{
        .name = "ci_cancel",
        .description = "cpull CI: cancel a queued job or abort a running one (kills its whole process group).",
        .schema = id_schema,
        .fields = &.{.{ "id", .int }},
        .run = cancel,
    },
    .{
        .name = "ci_retry",
        .description = "cpull CI: queue the same job again; returns the new job id.",
        .schema = id_schema,
        .fields = &.{.{ "id", .int }},
        .run = retry,
    },
};

const Client = struct {
    a: Allocator,
    http: std.http.Client,
    base: []const u8,

    const Response = union(enum) { ok: std.json.Value, err: []const u8 };

    fn send(c: *Client, method: std.http.Method, path: []const u8, payload: ?[]const u8) !Response {
        var out: std.Io.Writer.Allocating = .init(c.a);
        const res = c.http.fetch(.{
            .location = .{ .url = try std.fmt.allocPrint(c.a, "{s}{s}", .{ c.base, path }) },
            .method = method,
            .payload = payload,
            .response_writer = &out.writer,
            .headers = .{ .content_type = if (payload != null) .{ .override = "application/json" } else .default },
        }) catch |e| return .{ .err = try std.fmt.allocPrint(c.a, "{s}{s}: {t}", .{ c.base, path, e }) };
        const v = std.json.parseFromSliceLeaky(std.json.Value, c.a, out.written(), .{}) catch
            return .{ .err = try std.fmt.allocPrint(c.a, "decoding response: {s}", .{out.written()}) };
        if (res.status.class() != .success) {
            if (v == .object) if (v.object.get("error")) |e| if (e == .string) return .{ .err = e.string };
            return .{ .err = @tagName(res.status) };
        }
        return .{ .ok = v };
    }
};

/// The workspace server for this root: `.pull/cpull/serve.addr` (written by
/// `cpull --workspace ROOT --web-listen ADDR`), else 127.0.0.1:8080.
fn connect(ctx: *const Ctx, a: Allocator) !union(enum) { ok: Client, err: []const u8 } {
    const io = ctx.io;
    const addr = blk: {
        const path = try std.fs.path.join(a, &.{ ctx.root, ".pull", "cpull", "serve.addr" });
        const text = Io.Dir.cwd().readFileAlloc(io, path, a, .limited(256)) catch break :blk default_addr;
        const t = std.mem.trim(u8, text, " \t\r\n");
        break :blk if (t.len == 0) default_addr else t;
    };
    var c: Client = .{ .a = a, .http = .{ .allocator = a, .io = io }, .base = try std.fmt.allocPrint(a, "http://{s}", .{addr}) };
    const root = Io.Dir.cwd().realPathFileAlloc(io, ctx.root, a) catch ctx.root;
    const health = switch (try c.send(.GET, "/ci/api/health", null)) {
        .ok => |v| v,
        .err => return .{ .err = try std.fmt.allocPrint(a, "the cpull workspace server isn't running for {s} at {s}: start its pullfile job (job tool), or `pull cpull open --web-listen {s}`", .{ root, addr, addr }) },
    };
    const served = if (health == .object) health.object.get("root") else null;
    if (served == null or served.? != .string) return .{ .err = try std.fmt.allocPrint(a, "{s} answers but isn't a cpull server with CI", .{addr}) };
    if (!std.mem.eql(u8, served.?.string, root)) return .{ .err = try std.fmt.allocPrint(a, "{s} is a cpull server for {s}, not {s}", .{ addr, served.?.string, root }) };
    return .{ .ok = c };
}

fn s(o: std.json.ObjectMap, k: []const u8) ?[]const u8 {
    const v = o.get(k) orelse return null;
    return if (v == .string) v.string else null;
}

fn n(o: std.json.ObjectMap, k: []const u8) ?i64 {
    const v = o.get(k) orelse return null;
    return if (v == .integer) v.integer else null;
}

fn b(o: std.json.ObjectMap, k: []const u8) bool {
    const v = o.get(k) orelse return false;
    return v == .bool and v.bool;
}

/// idlci's Job::summary of a job's JSON.
fn summary(a: Allocator, v: std.json.Value) ![]const u8 {
    const o = v.object;
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    try w.print("#{d} {s} {s} {s}", .{ n(o, "id") orelse 0, s(o, "status") orelse "", s(o, "command") orelse "", s(o, "project") orelse "" });
    if (o.get("targets")) |t| if (t == .array and t.array.items.len > 0) {
        try w.writeAll(" [");
        for (t.array.items, 0..) |x, i| try w.print("{s}{s}", .{ if (i > 0) " " else "", if (x == .string) x.string else "" });
        try w.writeByte(']');
    };
    const cfg = s(o, "configuration") orelse "none";
    if (!std.mem.eql(u8, cfg, "none")) try w.print(" -c {s}", .{cfg});
    if (b(o, "strict")) try w.writeAll(" --strict");
    if (n(o, "exit_code")) |code| try w.print(" exit={d}", .{code});
    if (n(o, "started")) |st| if (n(o, "finished")) |f| try w.print(" {d}s", .{f - st});
    if (s(o, "head")) |head| {
        try w.writeAll(" @");
        if (s(o, "branch")) |br| try w.print("{s}:", .{br});
        try w.print("{s}{s}", .{ head, if (b(o, "dirty")) "+dirty" else "" });
    }
    try w.print(" by {s}", .{s(o, "requested_by") orelse ""});
    return out.written();
}

fn isFinal(status: []const u8) bool {
    return !std.mem.eql(u8, status, "queued") and !std.mem.eql(u8, status, "running");
}

fn withTail(c: *Client, a: Allocator, j: std.json.Value, lines: ?u64) !Result {
    const count = lines orelse 40;
    const id = n(j.object, "id") orelse 0;
    const l = switch (try c.send(.GET, try std.fmt.allocPrint(a, "/ci/api/jobs/{d}/log?tail={d}", .{ id, count }), null)) {
        .ok => |v| v,
        .err => |m| return .{ .err = m },
    };
    return .{ .ok = try std.fmt.allocPrint(a, "{s}\nlog: {s}\n--- last {d} log lines ---\n{s}", .{ try summary(a, j), s(j.object, "log") orelse "", count, s(l.object, "text") orelse "" }) };
}

const command_names = [_][]const u8{ "build", "test", "lint", "fmt-check", "check", "clean" };
const status_names = [_][]const u8{ "queued", "running", "passed", "failed", "cancelled" };
const configuration_names = [_][]const u8{ "debug", "release", "none" };

/// serde's message for an unknown enum variant.
fn variant(a: Allocator, value: []const u8, names: []const []const u8) !?[]const u8 {
    for (names) |x| if (std.mem.eql(u8, x, value)) return null;
    var w: std.Io.Writer.Allocating = .init(a);
    try w.writer.print("failed to deserialize parameters: unknown variant `{s}`, expected one of ", .{value});
    for (names, 0..) |x, i| try w.writer.print("{s}`{s}`", .{ if (i > 0) ", " else "", x });
    return w.written();
}

fn projects(ctx: *const Ctx, a: Allocator, _: Args) !Result {
    var c = switch (try connect(ctx, a)) {
        .ok => |x| x,
        .err => |m| return .{ .err = m },
    };
    const list = switch (try c.send(.GET, "/ci/api/projects", null)) {
        .ok => |v| v,
        .err => |m| return .{ .err = m },
    };
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    for (list.array.items) |p| {
        const o = p.object;
        try w.print("{s}  (repo {s}, {s}@{s}{s})  ", .{ s(o, "path") orelse "", s(o, "repo") orelse "-", s(o, "branch") orelse "-", s(o, "head") orelse "-", if (b(o, "dirty")) " dirty" else "" });
        if (o.get("last")) |last| if (last == .object) {
            var it = last.object.iterator();
            var first = true;
            while (it.next()) |e| {
                try w.print("{s}{s}:{s}#{d}", .{ if (first) "" else " ", e.key_ptr.*, s(e.value_ptr.object, "status") orelse "", n(e.value_ptr.object, "id") orelse 0 });
                first = false;
            }
        };
        try w.writeAll("\n    targets: ");
        if (o.get("targets")) |t| if (t == .array) for (t.array.items, 0..) |x, i| {
            try w.print("{s}{s}({s})", .{ if (i == 0) "" else " ", s(x.object, "name") orelse "", s(x.object, "kind") orelse "" });
        };
        try w.writeByte('\n');
    }
    return .{ .ok = out.written() };
}

fn queue(ctx: *const Ctx, a: Allocator, args: Args) !Result {
    const command = args.str("command").?;
    if (try variant(a, command, &command_names)) |m| return .{ .err = m };
    const cfg = args.str("configuration") orelse "none";
    if (try variant(a, cfg, &configuration_names)) |m| return .{ .err = m };
    const strict = if (args.obj.get("strict")) |v| switch (v) {
        .bool => |x| x,
        .null => false,
        else => return .{ .err = "failed to deserialize parameters: invalid type, expected a boolean" },
    } else false;
    var targets: std.ArrayList([]const u8) = .empty;
    if (args.obj.get("targets")) |v| switch (v) {
        .array => |arr| for (arr.items) |x| {
            if (x != .string) return .{ .err = "failed to deserialize parameters: invalid type, expected a string" };
            try targets.append(a, x.string);
        },
        .null => {},
        else => return .{ .err = "failed to deserialize parameters: invalid type, expected a sequence" },
    };
    var c = switch (try connect(ctx, a)) {
        .ok => |x| x,
        .err => |m| return .{ .err = m },
    };
    const body = try std.json.Stringify.valueAlloc(a, .{
        .project = args.str("project").?,
        .command = command,
        .targets = targets.items,
        .configuration = cfg,
        .strict = strict,
        .requested_by = "mcp",
        .retry_of = null,
    }, .{});
    const e = switch (try c.send(.POST, "/ci/api/jobs", body)) {
        .ok => |v| v,
        .err => |m| return .{ .err = m },
    };
    const note = if (b(e.object, "deduplicated")) " (an identical job was already queued)" else "";
    return .{ .ok = try std.fmt.allocPrint(a, "queued job {d}{s}\n{s}", .{ n(e.object, "id") orelse 0, note, try summary(a, e) }) };
}

fn jobs(ctx: *const Ctx, a: Allocator, args: Args) !Result {
    var path: std.Io.Writer.Allocating = .init(a);
    try path.writer.print("/ci/api/jobs?limit={d}", .{args.int("limit") orelse 20});
    if (args.str("status")) |st| {
        if (try variant(a, st, &status_names)) |m| return .{ .err = m };
        try path.writer.print("&status={s}", .{st});
    }
    if (args.str("project")) |p| {
        try path.writer.writeAll("&project=");
        try std.Uri.Component.percentEncode(&path.writer, p, struct {
            fn ok(ch: u8) bool {
                return std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '/';
            }
        }.ok);
    }
    var c = switch (try connect(ctx, a)) {
        .ok => |x| x,
        .err => |m| return .{ .err = m },
    };
    const list = switch (try c.send(.GET, path.written(), null)) {
        .ok => |v| v,
        .err => |m| return .{ .err = m },
    };
    if (list.array.items.len == 0) return .{ .ok = "no jobs" };
    var lines: std.ArrayList([]const u8) = .empty;
    for (list.array.items) |j| try lines.append(a, try summary(a, j));
    return .{ .ok = try std.mem.join(a, "\n", lines.items) };
}

fn getJob(c: *Client, a: Allocator, id: i64) !Client.Response {
    return c.send(.GET, try std.fmt.allocPrint(a, "/ci/api/jobs/{d}", .{id}), null);
}

fn job(ctx: *const Ctx, a: Allocator, args: Args) !Result {
    var c = switch (try connect(ctx, a)) {
        .ok => |x| x,
        .err => |m| return .{ .err = m },
    };
    const j = switch (try getJob(&c, a, args.obj.get("id").?.integer)) {
        .ok => |v| v,
        .err => |m| return .{ .err = m },
    };
    return withTail(&c, a, j, args.int("lines"));
}

fn log(ctx: *const Ctx, a: Allocator, args: Args) !Result {
    var c = switch (try connect(ctx, a)) {
        .ok => |x| x,
        .err => |m| return .{ .err = m },
    };
    const id = args.obj.get("id").?.integer;
    const q = if (args.int("tail")) |t| try std.fmt.allocPrint(a, "tail={d}", .{t}) else try std.fmt.allocPrint(a, "offset={d}", .{args.int("offset") orelse 0});
    const l = switch (try c.send(.GET, try std.fmt.allocPrint(a, "/ci/api/jobs/{d}/log?{s}", .{ id, q }), null)) {
        .ok => |v| v,
        .err => |m| return .{ .err = m },
    };
    const o = l.object;
    return .{ .ok = try std.fmt.allocPrint(a, "[job #{d} {s} size={d} next_offset={d}]\n{s}", .{ n(o, "id") orelse 0, s(o, "status") orelse "", n(o, "size") orelse 0, n(o, "next_offset") orelse 0, s(o, "text") orelse "" }) };
}

fn wait(ctx: *const Ctx, a: Allocator, args: Args) !Result {
    var c = switch (try connect(ctx, a)) {
        .ok => |x| x,
        .err => |m| return .{ .err = m },
    };
    const id = args.obj.get("id").?.integer;
    const timeout_s: i64 = @intCast(@min(args.int("timeout_s") orelse 300, 600));
    const deadline = Io.Timestamp.now(ctx.io, .awake).toSeconds() + timeout_s;
    while (true) {
        const j = switch (try getJob(&c, a, id)) {
            .ok => |v| v,
            .err => |m| return .{ .err = m },
        };
        const status = s(j.object, "status") orelse "";
        if (isFinal(status)) return withTail(&c, a, j, args.int("lines"));
        if (Io.Timestamp.now(ctx.io, .awake).toSeconds() >= deadline) {
            const out = switch (try withTail(&c, a, j, args.int("lines"))) {
                .ok => |x| x,
                .err => |m| return .{ .err = m },
            };
            return .{ .ok = try std.fmt.allocPrint(a, "still {s} after timeout; call wait again\n{s}", .{ status, out }) };
        }
        ctx.io.sleep(.fromSeconds(2), .awake) catch return .{ .err = "cancelled" };
    }
}

fn cancel(ctx: *const Ctx, a: Allocator, args: Args) !Result {
    var c = switch (try connect(ctx, a)) {
        .ok => |x| x,
        .err => |m| return .{ .err = m },
    };
    const j = switch (try c.send(.POST, try std.fmt.allocPrint(a, "/ci/api/jobs/{d}/cancel", .{args.obj.get("id").?.integer}), "null")) {
        .ok => |v| v,
        .err => |m| return .{ .err = m },
    };
    return .{ .ok = try summary(a, j) };
}

fn retry(ctx: *const Ctx, a: Allocator, args: Args) !Result {
    var c = switch (try connect(ctx, a)) {
        .ok => |x| x,
        .err => |m| return .{ .err = m },
    };
    const e = switch (try c.send(.POST, try std.fmt.allocPrint(a, "/ci/api/jobs/{d}/retry?by=mcp", .{args.obj.get("id").?.integer}), "null")) {
        .ok => |v| v,
        .err => |m| return .{ .err = m },
    };
    return .{ .ok = try std.fmt.allocPrint(a, "queued job {d}\n{s}", .{ n(e.object, "id") orelse 0, try summary(a, e) }) };
}

test summary {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"id":12,"project":"ferry-ios","command":"test","targets":["A","B"],"configuration":"release","strict":true,"status":"failed","exit_code":1,"created":1,"started":10,"finished":11,"repo":"ferry-ios","branch":"master","head":"49c350a","dirty":true,"requested_by":"web","retry_of":null,"log":"/x/12.log"}
    , .{});
    try std.testing.expectEqualStrings("#12 failed test ferry-ios [A B] -c release --strict exit=1 1s @master:49c350a+dirty by web", try summary(a, v));
    try std.testing.expectEqualStrings("failed to deserialize parameters: unknown variant `x`, expected one of `debug`, `release`, `none`", (try variant(a, "x", &configuration_names)).?);
}
