//! idlci (github.com/jbisfun/idlci), the workspace's CI, as `cpull_stack`
//! shows it: the stack's latest CI run from idlci's `/api/status/subject`
//! (theme docs/workspace-tools.md §5), when idlci is running for this root.
//! The CI tools themselves (ci_*) are idlci's own MCP server (`idlci mcp`).
const std = @import("std");
const core = @import("core");
const cpull = @import("cpull");
const mcp = @import("mcp.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Ctx = mcp.Ctx;

const Client = struct {
    a: Allocator,
    /// On the heap: pooled connections point back at their std.http.Client,
    /// so it must not move when `connect` returns the Client.
    http: *std.http.Client,
    base: []const u8,

    fn get(c: *Client, path: []const u8) !std.json.Value {
        var out: std.Io.Writer.Allocating = .init(c.a);
        const res = try c.http.fetch(.{
            .location = .{ .url = try std.fmt.allocPrint(c.a, "{s}{s}", .{ c.base, path }) },
            .method = .GET,
            .response_writer = &out.writer,
        });
        if (res.status.class() != .success) return error.IdlciError;
        return std.json.parseFromSliceLeaky(std.json.Value, c.a, out.written(), .{});
    }
};

/// idlci for this root: $IDLCI_ADDR, else `.pull/idlci/serve.addr` while its
/// server holds `.pull/idlci/serve.lock`, else nothing; it must answer
/// /api/health with this root.
fn connect(ctx: *const Ctx, a: Allocator) ?Client {
    const io = ctx.io;
    const addr = blk: {
        const env = core.sys.envMap(a) catch null;
        if (env) |e| if (e.get("IDLCI_ADDR")) |x| if (x.len > 0) break :blk x;
        const dir = std.fs.path.join(a, &.{ ctx.root, ".pull", "idlci" }) catch return null;
        const text = Io.Dir.cwd().readFileAlloc(io, std.fs.path.join(a, &.{ dir, "serve.addr" }) catch return null, a, .limited(256)) catch return null;
        const t = std.mem.trim(u8, text, " \t\r\n");
        if (t.len == 0) return null;
        // a crashed server leaves serve.addr behind, but the kernel drops its lock
        if (Io.Dir.cwd().openFile(io, std.fs.path.join(a, &.{ dir, "serve.lock" }) catch return null, .{})) |f| {
            defer f.close(io);
            const free = f.tryLock(io, .shared) catch false;
            if (free) {
                f.unlock(io);
                return null;
            }
        } else |_| {}
        break :blk t;
    };
    const http = a.create(std.http.Client) catch return null;
    http.* = .{ .allocator = a, .io = io };
    var c: Client = .{ .a = a, .http = http, .base = std.fmt.allocPrint(a, "http://{s}", .{addr}) catch return null };
    const health = c.get("/api/health") catch {
        http.deinit();
        return null;
    };
    const served = if (health == .object) health.object.get("root") else null;
    const ours = blk: {
        if (served == null or served.? != .string) break :blk false;
        const root = Io.Dir.cwd().realPathFileAlloc(io, ctx.root, a) catch ctx.root;
        const theirs = Io.Dir.cwd().realPathFileAlloc(io, served.?.string, a) catch served.?.string;
        break :blk std.mem.eql(u8, theirs, root);
    };
    if (!ours) {
        http.deinit();
        return null;
    }
    return c;
}

fn s(o: std.json.ObjectMap, k: []const u8) ?[]const u8 {
    const v = o.get(k) orelse return null;
    return if (v == .string) v.string else null;
}

fn n(o: std.json.ObjectMap, k: []const u8) ?i64 {
    const v = o.get(k) orelse return null;
    return if (v == .integer) v.integer else null;
}

fn escape(a: Allocator, text: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    try std.Uri.Component.percentEncode(&out.writer, text, struct {
        fn ok(ch: u8) bool {
            return std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '.' or ch == '_' or ch == '~';
        }
    }.ok);
    return out.written();
}

/// The `ci:` lines of `cpull_stack`, or null when idlci isn't running.
pub fn stackStatus(ctx: *const Ctx, a: Allocator, pf: core.Pullfile, stack: cpull.stack.Stack, infos: []const ?cpull.stack.PatchInfo) !?[]const u8 {
    var c = connect(ctx, a) orelse return null;
    defer c.http.deinit();
    // the members' source tips: what a current run checked out
    var tips: std.ArrayList(u8) = .empty;
    for (stack.members, infos) |m, info| {
        const branch = (info orelse continue).source_branch orelse continue;
        const repo = std.fs.path.join(a, &.{ ctx.root, m.repo }) catch continue;
        const res = core.sys.run(a, &.{ "git", "-C", repo, "rev-parse", "--verify", "-q", try std.fmt.allocPrint(a, "refs/heads/{s}", .{branch}) }, .{}) catch continue;
        if (!res.ok()) continue;
        if (tips.items.len > 0) try tips.append(a, '\n');
        try tips.print(a, "{s} {s}", .{ m.repo, std.mem.trim(u8, res.stdout, " \r\n") });
    }
    const path = try std.fmt.allocPrint(a, "/api/status/subject?subject={s}&tips={s}", .{ try escape(a, try std.fmt.allocPrint(a, "stack:{s}", .{stack.id})), try escape(a, tips.items) });
    const v = c.get(path) catch return null;
    var out: std.Io.Writer.Allocating = .init(a);
    if (v == .object) {
        try out.writer.print("ci: {s}\n", .{s(v.object, "label") orelse ""});
        if (v.object.get("jobs")) |list| if (list == .array) for (list.array.items) |j| if (j == .object) {
            try out.writer.print("  #{d} {s} {s}\n", .{ n(j.object, "id") orelse 0, s(j.object, "status") orelse "", s(j.object, "label") orelse "" });
        };
    } else try out.writer.writeAll("ci: not run yet (idlci's ci_stack queues it)\n");
    if (requireCi(pf)) try out.writer.writeAll("merge gate (cpull.require_ci): on; cpull_merge refuses until the CI is green, unless force\n");
    return out.written();
}

fn requireCi(pf: core.Pullfile) bool {
    const sec = cpull.section(pf) orelse return false;
    if (sec != .dict) return false;
    const v = sec.dict.get("require_ci") orelse return false;
    return v == .boolean and v.boolean;
}
