//! `pull mcp`: an MCP server (stdio, on parley) over the workspace, for agents.
//!
//! Multi-repo context (workspace overview, status, diffs, logs, search, files),
//! programs (one-shot commands with the workspace env) and stateful terminals (the
//! launchd sessions: they persist between calls and across agents, and a human can
//! attach to the same terminal with `pull session attach`).
//!
//! The session/job tools need the `sessions` build option (pkgs/launchd), the
//! cpull_* issue and stack tools the `cpull` one (pkgs/cpull). The
//! workspace env and the pullfile jobs are injected by the bin.
const std = @import("std");
const parley = @import("parley");
const core = @import("core");
const opts = @import("mcp_options");
const args_mod = @import("args.zig");
const tools = @import("tools.zig");
pub const sessions = if (opts.sessions) @import("sessions.zig") else struct {};
const launchd = if (opts.sessions) @import("launchd") else struct {};
const cpull = if (opts.cpull) @import("cpull.zig") else struct {};
const ci = @import("ci.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// The pullfile's `jobs` (the bin parses them).
pub const JobsFn = if (opts.sessions) *const fn (Allocator, []const u8) anyerror![]const launchd.Job else void;

pub const Options = struct {
    /// Absolute workspace root.
    root: []const u8,
    /// The workspace env (`pull env`), for `exec`.
    env: core.EnvProvider,
    /// The pull executable, started as `EXE launchd` when no daemon runs.
    exe: ?[]const u8 = null,
    jobs: ?JobsFn = null,
};

pub const Ctx = struct {
    gpa: Allocator,
    io: Io,
    root: []const u8,
    env: core.EnvProvider,
    exe: ?[]const u8,
    jobs: ?JobsFn,
};

/// A tool's answer: text, or an execution error the model reads.
pub const Result = union(enum) {
    ok: []const u8,
    err: []const u8,
};

pub const instructions = "pull workspace: several git repos under one root, managed by `pull`. Use `workspace` " ++
    "for an overview, then status/diff/log/grep/list_files/read_file across repos. " ++
    "`exec` runs a command to completion with the workspace env; sessions are stateful " ++
    "terminals (PTYs) that persist between calls and can be attached to by a human. " ++
    "Commit with `pull commit -m MSG PATHS` via exec (subject lint applies). " ++
    "The idl projects' CI (cpull's /ci: build/test/lint jobs on a shared queue) has ci_* tools." ++
    (if (opts.cpull) " Repos with a `cpull/events` branch carry cpull issues; changes across repos landed together are cpull stacks: cpull_* tools." else "");

/// A tool as registered: its spec (schema byte for byte as the Rust server's
/// schemars output), the fields its arguments are checked against, and its body.
pub const Def = struct {
    name: []const u8,
    description: []const u8,
    schema: []const u8,
    fields: []const args_mod.Field = &.{},
    run: *const fn (ctx: *const Ctx, a: Allocator, args: args_mod.Args) anyerror!Result,
};

const Tool = struct {
    h: parley.ToolHandler = .{ .callFn = call },
    ctx: *const Ctx,
    def: Def,

    fn call(h: *parley.ToolHandler, c: *parley.Call, raw: ?[]const u8) parley.Call.Error!parley.ToolResult {
        const t: *Tool = @fieldParentPtr("h", h);
        const a = c.arena;
        const parsed = args_mod.parse(a, raw, t.def.fields) catch return error.OutOfMemory;
        const args = switch (parsed) {
            .ok => |x| x,
            .err => |m| return .failure(m),
        };
        const r = t.def.run(t.ctx, a, args) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .failure(tools.describe(a, e)),
        };
        return switch (r) {
            .ok => |s| .ofText(s),
            .err => |s| .failure(s),
        };
    }
};

/// Every tool this build serves, sorted by name (rmcp lists them so).
pub fn defs() []const Def {
    const all = comptime blk: {
        @setEvalBranchQuota(100_000);
        const base = if (opts.sessions) tools.defs ++ sessions.defs.* else tools.defs;
        var arr = (if (opts.cpull) base ++ cpull.defs.* else base) ++ ci.defs.*;
        std.mem.sortUnstable(Def, &arr, {}, struct {
            fn lt(_: void, x: Def, y: Def) bool {
                return std.mem.lessThan(u8, x.name, y.name);
            }
        }.lt);
        const final = arr;
        break :blk &final;
    };
    return all;
}

/// Serve MCP on stdin/stdout until the client closes stdin.
pub fn serve(gpa: Allocator, io: Io, o: Options) !void {
    const ctx: Ctx = .{ .gpa = gpa, .io = io, .root = o.root, .env = o.env, .exe = o.exe, .jobs = o.jobs };
    var server = try parley.Server.init(gpa, io, .{
        .info = .{ .name = "pull", .version = "0.1.0" },
        .instructions = instructions,
        .logging = false,
        .validator = null,
    });
    defer server.deinit(io);
    const list = defs();
    const handlers = try gpa.alloc(Tool, list.len);
    defer gpa.free(handlers);
    for (handlers, list) |*t, d| {
        t.* = .{ .ctx = &ctx, .def = d };
        try server.addDynamicTool(io, .{ .name = d.name, .description = d.description, .input_schema = d.schema }, &t.h);
    }
    var in_buffer: [64 * 1024]u8 = undefined;
    var out_buffer: [64 * 1024]u8 = undefined;
    var stdin = Io.File.stdin().readerStreaming(io, &in_buffer);
    var stdout = Io.File.stdout().writerStreaming(io, &out_buffer);
    try parley.stdio.serve(io, gpa, &server, .fromFile(&stdin), .fromFile(&stdout), .{});
}

test {
    _ = args_mod;
    _ = tools;
    if (opts.sessions) _ = sessions;
    if (opts.cpull) _ = cpull;
    _ = ci;
    try std.testing.expect(defs().len == @as(usize, if (opts.sessions) 15 else 8) + (if (opts.cpull) 16 else 0) + ci.defs.len);
}
