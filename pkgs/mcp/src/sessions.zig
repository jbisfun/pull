//! Session and job tools: stateful terminals run by the workspace launchd daemon.
const std = @import("std");
const launchd = @import("launchd");
const mcp = @import("mcp.zig");
const tools = @import("tools.zig");
const Args = @import("args.zig").Args;

const Allocator = std.mem.Allocator;
const Ctx = mcp.Ctx;
const Result = mcp.Result;

const name_schema =
    \\{"$schema":"https://json-schema.org/draft/2020-12/schema","properties":{"name":{"description":"Session (job) name.","type":"string"}},"required":["name"],"type":"object"}
;

pub const defs = &[_]mcp.Def{
    .{
        .name = "session_new",
        .description = "Start a stateful terminal session (a PTY with the workspace env) running a shell or a program. It persists between calls; a human can watch it with `pull session attach NAME`.",
        .schema =
        \\{"$schema":"https://json-schema.org/draft/2020-12/schema","properties":{"command":{"default":[],"description":"Program and arguments; omit for an interactive shell.","items":{"type":"string"},"type":"array"},"cwd":{"description":"Working directory relative to the workspace root (default: the root).","type":["string","null"]},"env":{"additionalProperties":{"type":"string"},"default":{},"description":"Extra environment variables.","type":"object"},"keep_alive":{"default":false,"description":"Restart the program whenever it exits (servers, watchers).","type":"boolean"},"name":{"description":"Session name (unique in the workspace).","type":"string"}},"required":["name"],"type":"object"}
        ,
        .fields = &.{ .{ "name", .string }, .{ "command", .string_list }, .{ "cwd", .opt_string }, .{ "env", .string_map }, .{ "keep_alive", .boolean } },
        .run = sessionNew,
    },
    .{
        .name = "session_list",
        .description = "Sessions and jobs: state, pid, last exit code, and the program currently running in each terminal with its working directory.",
        .schema = "{\"properties\":{},\"type\":\"object\"}",
        .run = sessionList,
    },
    .{
        .name = "session_run",
        .description = "Type a command into a session's shell, wait until its output settles, and return the screen. The session keeps its state (cwd, env, history) between calls.",
        .schema =
        \\{"$schema":"https://json-schema.org/draft/2020-12/schema","properties":{"command":{"description":"Command line to type into the session's shell.","type":"string"},"idle_ms":{"description":"Output must be quiet this long to count as finished (default 800 ms).","format":"uint64","minimum":0,"type":["integer","null"]},"name":{"type":"string"},"timeout_ms":{"description":"Give up waiting after this long (default 60000 ms); the command keeps running.","format":"uint64","minimum":0,"type":["integer","null"]}},"required":["name","command"],"type":"object"}
        ,
        .fields = &.{ .{ "name", .string }, .{ "command", .string }, .{ "idle_ms", .opt_u64 }, .{ "timeout_ms", .opt_u64 } },
        .run = sessionRun,
    },
    .{
        .name = "session_send",
        .description = "Type text or keys into a session without waiting (e.g. answer a prompt, \"\\u0003\" for ctrl-c).",
        .schema =
        \\{"$schema":"https://json-schema.org/draft/2020-12/schema","properties":{"enter":{"default":false,"description":"Press enter after the text.","type":"boolean"},"name":{"type":"string"},"text":{"description":"Text to type. Escapes such as \"\\u0003\" (ctrl-c) or \"\\u001b\" (esc) are sent as is.","type":"string"}},"required":["name","text"],"type":"object"}
        ,
        .fields = &.{ .{ "name", .string }, .{ "text", .string }, .{ "enter", .boolean } },
        .run = sessionSend,
    },
    .{
        .name = "session_capture",
        .description = "The current screen of a session (what a human attached to it would see).",
        .schema = name_schema,
        .fields = &.{.{ "name", .string }},
        .run = sessionCapture,
    },
    .{
        .name = "session_kill",
        .description = "Stop a session (SIGTERM, then SIGKILL) and remove it.",
        .schema = name_schema,
        .fields = &.{.{ "name", .string }},
        .run = sessionKill,
    },
    .{
        .name = "job",
        .description = "Control a job from the pullfile `jobs` (or any session): start, stop, restart, unload. Loads the pullfile jobs first.",
        .schema =
        \\{"$schema":"https://json-schema.org/draft/2020-12/schema","properties":{"action":{"description":"One of: start, stop, restart, unload.","type":"string"},"label":{"description":"Job label.","type":"string"}},"required":["label","action"],"type":"object"}
        ,
        .fields = &.{ .{ "label", .string }, .{ "action", .string } },
        .run = job,
    },
};

/// A client per call: tool calls run concurrently and a client keeps its last error.
const Session = struct {
    c: launchd.Client,
    a: Allocator,

    fn init(ctx: *const Ctx, a: Allocator) Session {
        return .{ .c = .init(ctx.gpa, ctx.io, ctx.root, ctx.exe), .a = a };
    }

    fn deinit(s: *Session) void {
        s.c.deinit();
    }

    /// The daemon's error text (or the error's name) as a tool error.
    fn failed(s: *Session, e: anyerror) !Result {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        return .{ .err = if (e == error.Remote) try s.a.dupe(u8, s.c.errorMessage()) else @errorName(e) };
    }
};

fn sleep(ctx: *const Ctx, ms: i64) void {
    ctx.io.sleep(.fromMilliseconds(ms), .awake) catch {};
}

fn sessionNew(ctx: *const Ctx, a: Allocator, args: Args) !Result {
    const cwd = switch (try tools.inside(ctx, a, args.str("cwd"))) {
        .ok => |p| p,
        .err => |m| return .{ .err = m },
    };
    var env: []launchd.EnvVar = &.{};
    if (args.map("env")) |m| {
        env = try a.alloc(launchd.EnvVar, m.count());
        for (env, m.keys(), m.values()) |*e, k, v| e.* = .{ .name = k, .value = v.string };
        launchd.Job.sortEnv(env);
    }
    const name = args.str("name").?;
    const j = launchd.session.job(.{
        .name = name,
        .cmd = try args.list(a, "command"),
        .keep_alive = args.flag("keep_alive"),
        .env = env,
    }, cwd);
    var s: Session = .init(ctx, a);
    defer s.deinit();
    s.c.load(&.{j}, true) catch |e| return s.failed(e);
    sleep(ctx, 300);
    const screen = s.c.capture(a, name, false) catch |e| return s.failed(e);
    return .{ .ok = try std.fmt.allocPrint(a, "started {s}\n{s}", .{ name, screen }) };
}

fn sessionList(ctx: *const Ctx, a: Allocator, _: Args) !Result {
    var s: Session = .init(ctx, a);
    defer s.deinit();
    const jobs = s.c.list(a) catch |e| return s.failed(e);
    var w: std.Io.Writer.Allocating = .init(a);
    const o = &w.writer;
    for (jobs) |j| {
        try o.print("{s}: {s}", .{ j.label, j.state });
        if (j.pid) |pid| try o.print(", pid {d}", .{pid});
        if (j.last_exit) |c| try o.print(", last exit {d}", .{c});
        if (j.foreground) |fg| if (j.foreground_cwd) |cwd| try o.print(", running {s} in {s}", .{ fg, cwd });
        if (j.attached > 0) try o.print(", {d} attached", .{j.attached});
        try o.print(" ({s})\n", .{try std.mem.join(a, " ", j.argv)});
    }
    if (w.written().len == 0) return .{ .ok = "no sessions" };
    return .{ .ok = w.written() };
}

fn sessionRun(ctx: *const Ctx, a: Allocator, args: Args) !Result {
    const name = args.str("name").?;
    var s: Session = .init(ctx, a);
    defer s.deinit();
    s.c.send(name, try std.fmt.allocPrint(a, "{s}\r", .{args.str("command").?})) catch |e| return s.failed(e);
    sleep(ctx, 100);
    s.c.waitIdle(name, args.int("idle_ms") orelse 800, args.int("timeout_ms") orelse 60_000) catch |e| return s.failed(e);
    return .{ .ok = s.c.capture(a, name, false) catch |e| return s.failed(e) };
}

fn sessionSend(ctx: *const Ctx, a: Allocator, args: Args) !Result {
    const name = args.str("name").?;
    const text = args.str("text").?;
    var s: Session = .init(ctx, a);
    defer s.deinit();
    const data = if (args.flag("enter")) try std.fmt.allocPrint(a, "{s}\r", .{text}) else text;
    s.c.send(name, data) catch |e| return s.failed(e);
    return .{ .ok = try std.fmt.allocPrint(a, "sent to {s}", .{name}) };
}

fn sessionCapture(ctx: *const Ctx, a: Allocator, args: Args) !Result {
    var s: Session = .init(ctx, a);
    defer s.deinit();
    return .{ .ok = s.c.capture(a, args.str("name").?, false) catch |e| return s.failed(e) };
}

fn sessionKill(ctx: *const Ctx, a: Allocator, args: Args) !Result {
    const name = args.str("name").?;
    var s: Session = .init(ctx, a);
    defer s.deinit();
    s.c.unload(name) catch |e| return s.failed(e);
    return .{ .ok = try std.fmt.allocPrint(a, "killed {s}", .{name}) };
}

fn job(ctx: *const Ctx, a: Allocator, args: Args) !Result {
    const label = args.str("label").?;
    const action = args.str("action").?;
    switch (tools.pullfile(ctx, a)) {
        .ok => {},
        .err => |m| return .{ .err = m },
    }
    const jobs = if (ctx.jobs) |f| f(a, ctx.root) catch |e| return .{ .err = tools.describe(a, e) } else &.{};
    var s: Session = .init(ctx, a);
    defer s.deinit();
    s.c.load(jobs, false) catch |e| return s.failed(e);
    const eq = std.mem.eql;
    const r = if (eq(u8, action, "start"))
        s.c.start(label)
    else if (eq(u8, action, "stop"))
        s.c.stop(label)
    else if (eq(u8, action, "restart"))
        s.c.kickstart(label, true)
    else if (eq(u8, action, "unload"))
        s.c.unload(label)
    else
        return .{ .err = try std.fmt.allocPrint(a, "unknown action {s}", .{action}) };
    r catch |e| return s.failed(e);
    return .{ .ok = try std.fmt.allocPrint(a, "{s} {s}", .{ action, label }) };
}
