//! Test harness standing in for the `pull` binary: the workspace root is the current
//! directory, the "pullfile" jobs are `jobs.json` (a JSON array of plist-keyed jobs),
//! and the workspace env is fake (HARNESS_ENV=1, PULL_ROOT=<root>).
//!
//!   launchd-harness launchd
//!   launchd-harness launchctl load [JOB.json...] | unload L | list [--json] [--all]
//!                   | print L [--json] | start L | stop L | kickstart [-k] L | shutdown
//!   launchd-harness session new NAME [-d] [-c DIR] [--keep-alive] [CMD...] | ls [--json]
//!                   | attach N | send N [-e] TEXT... | capture N [-e]
//!                   | run N [--idle MS] [--timeout MS] CMD... | kill N
const std = @import("std");
const launchd = @import("launchd");

const Io = std.Io;
const Allocator = std.mem.Allocator;

var root_dir: []const u8 = "";

fn fakeEnv(_: ?*anyopaque, arena: Allocator) anyerror![]const launchd.EnvVar {
    return arena.dupe(launchd.EnvVar, &.{
        .{ .name = "HARNESS_ENV", .value = "1" },
        .{ .name = "PULL_ROOT", .value = root_dir },
    });
}

fn readJobs(arena: Allocator, io: Io, path: []const u8) ![]const launchd.Job {
    const data = Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch |e| switch (e) {
        error.FileNotFound => return &.{},
        else => return e,
    };
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, data, .{});
    return switch (v) {
        .array => |a| blk: {
            const out = try arena.alloc(launchd.Job, a.items.len);
            for (out, a.items) |*j, x| j.* = try launchd.Job.fromValue(arena, x);
            break :blk out;
        },
        else => try arena.dupe(launchd.Job, &.{try launchd.Job.fromValue(arena, v)}),
    };
}

fn has(args: []const []const u8, flag: []const u8) bool {
    for (args) |a| if (std.mem.eql(u8, a, flag)) return true;
    return false;
}

/// First argument that isn't a flag.
fn positional(args: []const []const u8) []const u8 {
    for (args) |a| if (a.len == 0 or a[0] != '-') return a;
    return "";
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);
    root_dir = try Io.Dir.cwd().realPathFileAlloc(io, ".", arena);
    const exe = try std.process.executablePathAlloc(io, arena);
    const args: []const []const u8 = argv[1..];
    if (args.len == 0) return error.Usage;

    const env: launchd.EnvProvider = .{ .func = fakeEnv };
    if (std.mem.eql(u8, args[0], "launchd")) {
        return launchd.daemon.run(gpa, io, .{ .root = root_dir, .jobs = try readJobs(arena, io, "jobs.json"), .env = env });
    }

    var c = launchd.Client.init(gpa, io, root_dir, exe);
    defer c.deinit();
    var out_buf: [4096]u8 = undefined;
    var out_w = Io.File.stdout().writer(io, &out_buf);
    const out = &out_w.interface;
    defer out.flush() catch {};

    dispatch(&c, arena, io, out, args) catch |e| {
        out.flush() catch {};
        if (e == error.Remote) std.debug.print("error: {s}\n", .{c.errorMessage()}) else std.debug.print("error: {s}\n", .{@errorName(e)});
        std.process.exit(1);
    };
}

fn dispatch(c: *launchd.Client, arena: Allocator, io: Io, out: *Io.Writer, args: []const []const u8) !void {
    if (args.len < 2) return error.Usage;
    const sub = args[1];
    const rest = args[2..];
    const eq = std.mem.eql;
    if (eq(u8, args[0], "launchctl")) {
        const lc = launchd.launchctl;
        if (eq(u8, sub, "load")) {
            var jobs: std.ArrayList(launchd.Job) = .empty;
            if (rest.len == 0) try jobs.appendSlice(arena, try readJobs(arena, io, "jobs.json"));
            for (rest) |p| try jobs.appendSlice(arena, try readJobs(arena, io, p));
            return lc.load(c, out, jobs.items);
        }
        if (eq(u8, sub, "unload")) return lc.unload(c, positional(rest));
        if (eq(u8, sub, "list")) return lc.list(c, arena, out, try readJobs(arena, io, "jobs.json"), .{ .json = has(rest, "--json"), .all = has(rest, "--all") });
        if (eq(u8, sub, "print")) return lc.print(c, arena, out, positional(rest), has(rest, "--json"));
        if (eq(u8, sub, "start")) return lc.start(c, positional(rest));
        if (eq(u8, sub, "stop")) return lc.stop(c, positional(rest));
        if (eq(u8, sub, "kickstart")) return lc.kickstart(c, positional(rest), has(rest, "-k"));
        if (eq(u8, sub, "shutdown")) return lc.shutdown(c);
        return error.Usage;
    }
    if (eq(u8, args[0], "session")) {
        const s = launchd.session;
        if (eq(u8, sub, "new")) {
            var opts: s.NewOptions = .{ .name = "" };
            var i: usize = 0;
            while (i < rest.len) : (i += 1) {
                const a = rest[i];
                if (eq(u8, a, "-d")) {
                    opts.detached = true;
                } else if (eq(u8, a, "--keep-alive")) {
                    opts.keep_alive = true;
                } else if (eq(u8, a, "-c")) {
                    i += 1;
                    opts.cwd = rest[i];
                } else if (opts.name.len == 0) {
                    opts.name = a;
                } else {
                    opts.cmd = rest[i..];
                    break;
                }
            }
            return s.new(c, arena, out, opts);
        }
        if (eq(u8, sub, "ls")) return s.ls(c, arena, out, has(rest, "--json"));
        if (eq(u8, sub, "attach")) return s.attach(c, positional(rest));
        if (eq(u8, sub, "send")) {
            var text: std.ArrayList([]const u8) = .empty;
            for (rest[1..]) |a| if (!eq(u8, a, "-e")) try text.append(arena, a);
            return s.send(c, arena, rest[0], text.items, has(rest, "-e"));
        }
        if (eq(u8, sub, "capture")) return s.capture(c, arena, out, positional(rest), has(rest, "-e"));
        if (eq(u8, sub, "run")) {
            var opts: s.RunOptions = .{ .name = rest[0], .command = &.{} };
            var i: usize = 1;
            while (i < rest.len) : (i += 1) {
                if (eq(u8, rest[i], "--idle")) {
                    i += 1;
                    opts.idle_ms = try std.fmt.parseInt(u64, rest[i], 10);
                } else if (eq(u8, rest[i], "--timeout")) {
                    i += 1;
                    opts.timeout_ms = try std.fmt.parseInt(u64, rest[i], 10);
                } else {
                    opts.command = rest[i..];
                    break;
                }
            }
            return s.run(c, arena, out, opts);
        }
        if (eq(u8, sub, "kill")) return s.kill(c, positional(rest));
    }
    return error.Usage;
}
