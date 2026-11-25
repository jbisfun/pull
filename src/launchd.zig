//! `pull launchd` / `pull launchctl` / `pull session` (the `launchd` feature): the
//! bin's side of pkgs/launchd — pullfile and .plist jobs, the workspace env, and
//! daemon errors as `pull: ...`.
const std = @import("std");
const core = @import("core");
const launchd = @import("launchd");
const cli = @import("cli.zig");
const ws = @import("workspace.zig");
const sys = core.sys;
const plist = core.plist;
const Allocator = std.mem.Allocator;

/// A plist value as JSON (what `launchd.Job.fromValue` reads).
pub fn jsonValue(a: Allocator, v: plist.Value) !std.json.Value {
    return switch (v) {
        .string, .date, .data => |s| .{ .string = s },
        .integer => |i| .{ .integer = std.math.cast(i64, i) orelse return error.InvalidJob },
        .real => |r| .{ .float = r },
        .boolean => |b| .{ .bool = b },
        .array => |arr| blk: {
            var out: std.json.Array = .init(a);
            for (arr.items) |x| try out.append(try jsonValue(a, x));
            break :blk .{ .array = out };
        },
        .dict => |d| blk: {
            var out: std.json.ObjectMap = .empty;
            for (d.entries.items) |e| try out.put(a, e.key, try jsonValue(a, e.value));
            break :blk .{ .object = out };
        },
    };
}

fn job(a: Allocator, v: plist.Value) !launchd.Job {
    return launchd.Job.fromValue(a, try jsonValue(a, v));
}

/// The pullfile's `jobs`.
pub fn pullfileJobs(a: Allocator, pf: core.Pullfile) ![]const launchd.Job {
    const v = pf.sectionValue(launchd.SECTION) orelse return &.{};
    if (v != .array) return sys.fail("pullfile `{s}`: expected an array", .{launchd.SECTION});
    const out = try a.alloc(launchd.Job, v.array.items.len);
    for (out, v.array.items, 0..) |*j, x, i| j.* = job(a, x) catch |e|
        return sys.fail("pullfile `{s}`[{d}]: {s}", .{ launchd.SECTION, i, sys.describe(e) });
    return out;
}

fn loadPlist(a: Allocator, path: []const u8) !launchd.Job {
    const data = sys.readFile(a, path) catch |e| return sys.fail("{s}: {s}", .{ path, sys.describe(e) });
    const v = plist.parse(a, data) catch |e| return sys.fail("{s}: {s}", .{ path, sys.describe(e) });
    return job(a, v) catch |e| sys.fail("{s}: {s}", .{ path, sys.describe(e) });
}

var env_root: []const u8 = "";

fn envFunc(_: ?*anyopaque, arena: Allocator) anyerror![]const launchd.EnvVar {
    const vars = ws.workspaceEnv(arena, env_root);
    const out = try arena.alloc(launchd.EnvVar, vars.len);
    for (out, vars) |*o, v| o.* = .{ .name = v.key, .value = v.value };
    return out;
}

/// The workspace env as a launchd `EnvProvider` (re-read at every job start).
pub fn envProvider(root: []const u8) launchd.EnvProvider {
    env_root = root;
    return .{ .func = envFunc };
}

/// Run the daemon in the foreground with the pullfile jobs and the workspace env.
pub fn daemon(gpa: Allocator, a: Allocator, root: []const u8, pf: core.Pullfile) !void {
    try core.paths.ensureIgnored(a, root, "/.pull/");
    try launchd.daemon.run(gpa, sys.io, .{ .root = root, .jobs = try pullfileJobs(a, pf), .env = envProvider(root) });
}

/// `pull launchctl ...` / `pull session ...`.
pub fn run(gpa: Allocator, a: Allocator, root: []const u8, pf: core.Pullfile, cmd: cli.Cmd) !void {
    const exe = try std.process.executablePathAlloc(sys.io, a);
    var c = launchd.Client.init(gpa, sys.io, root, exe);
    defer c.deinit();
    var buf: [4096]u8 = undefined;
    var fw = std.Io.File.stdout().writer(sys.io, &buf);
    const out = &fw.interface;
    defer out.flush() catch {};
    dispatch(&c, a, out, root, pf, cmd) catch |e| {
        out.flush() catch {};
        if (e == error.Remote) return sys.fail("{s}", .{c.errorMessage()});
        return e;
    };
}

fn dispatch(c: *launchd.Client, a: Allocator, out: *std.Io.Writer, root: []const u8, pf: core.Pullfile, cmd: cli.Cmd) !void {
    _ = root;
    const lc = launchd.launchctl;
    const s = launchd.session;
    switch (cmd) {
        .launchctl_load => |paths| {
            const jobs = if (paths.len == 0) try pullfileJobs(a, pf) else blk: {
                const js = try a.alloc(launchd.Job, paths.len);
                for (js, paths) |*j, p| j.* = try loadPlist(a, p);
                break :blk js;
            };
            try lc.load(c, out, jobs);
        },
        .launchctl_unload => |l| try lc.unload(c, l),
        .launchctl_list => |l| try lc.list(c, a, out, try pullfileJobs(a, pf), .{ .json = l.json, .all = l.all }),
        .launchctl_print => |p| try lc.print(c, a, out, p.label, p.json),
        .launchctl_start => |l| try lc.start(c, l),
        .launchctl_stop => |l| try lc.stop(c, l),
        .launchctl_kickstart => |k| try lc.kickstart(c, k.label, k.k),
        .launchctl_shutdown => try lc.shutdown(c),
        .session_new => |n| try s.new(c, a, out, .{ .name = n.name, .detached = n.detached, .cwd = n.cwd, .keep_alive = n.keep_alive, .cmd = n.cmd }),
        .session_ls => |l| try s.ls(c, a, out, l.json),
        .session_attach => |n| try s.attach(c, n),
        .session_send => |x| try s.send(c, a, x.name, x.text, x.enter),
        .session_capture => |x| try s.capture(c, a, out, x.name, x.escapes),
        .session_run => |r| try s.run(c, a, out, .{ .name = r.name, .idle_ms = r.idle, .timeout_ms = r.timeout, .command = r.command }),
        .session_kill => |n| try s.kill(c, n),
        else => unreachable,
    }
}

test jsonValue {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try plist.parse(a,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<plist version="1.0"><dict><key>Label</key><string>web</string>
        \\<key>ProgramArguments</key><array><string>sh</string><string>-c</string><string>x</string></array>
        \\<key>KeepAlive</key><true/><key>ThrottleInterval</key><integer>3</integer>
        \\<key>EnvironmentVariables</key><dict><key>B</key><string>2</string><key>A</key><string>1</string></dict>
        \\</dict></plist>
    );
    const j = try job(a, v);
    try std.testing.expectEqualStrings("web", j.label);
    try std.testing.expectEqual(@as(usize, 3), j.program_arguments.len);
    try std.testing.expectEqual(@as(?u64, 3), j.throttle_interval);
    try std.testing.expectEqualStrings("A", j.environment_variables[0].name);
}
