//! `pull launchctl ...` and `pull session ...`: thin command functions over `Client`,
//! printing to `out` exactly like the Rust CLI. Errors from the daemon are
//! `error.Remote` with the text in `c.errorMessage()`.
const std = @import("std");
const protocol = @import("protocol.zig");
const jobmod = @import("job.zig");
const Client = @import("client.zig").Client;

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Job = jobmod.Job;
const JobStatus = protocol.JobStatus;

fn dash(w: *Writer, v: anytype) !void {
    if (v) |x| try w.print("{d}", .{x}) else try w.writeAll("-");
}

fn isPullfileJob(pf: []const Job, label: []const u8) bool {
    for (pf) |j| if (std.mem.eql(u8, j.label, label)) return true;
    return false;
}

pub const launchctl = struct {
    /// `load [FILE.plist...]`: `jobs` are the parsed plists, or the pullfile's jobs.
    pub fn load(c: *Client, out: *Writer, jobs: []const Job) !void {
        try c.load(jobs, true);
        try out.print("loaded {d} job(s)\n", .{jobs.len});
    }

    pub fn unload(c: *Client, label: []const u8) !void {
        try c.unload(label);
    }

    pub const ListOptions = struct {
        json: bool = false,
        /// Also pullfile jobs that aren't loaded (state "unloaded"), and don't start
        /// the daemon just to list.
        all: bool = false,
    };

    pub fn list(c: *Client, arena: Allocator, out: *Writer, pullfile_jobs: []const Job, opts: ListOptions) !void {
        var jobs: std.ArrayList(JobStatus) = .empty;
        if (!opts.all or c.running()) try jobs.appendSlice(arena, try c.list(arena));
        for (jobs.items) |*j| j.pullfile = isPullfileJob(pullfile_jobs, j.label);
        if (opts.all) {
            outer: for (pullfile_jobs) |job| {
                if (job.disabled) continue;
                for (jobs.items) |j| if (std.mem.eql(u8, j.label, job.label)) continue :outer;
                try jobs.append(arena, .{
                    .label = job.label,
                    .state = "unloaded",
                    .argv = try job.argv(arena),
                    .cwd = job.working_directory orelse c.root,
                    .job = job,
                    .pullfile = true,
                });
            }
        }
        if (opts.json) return protocol.writePretty(out, jobs.items);
        try out.writeAll("PID\tStatus\tLabel\n");
        for (jobs.items) |j| {
            try dash(out, j.pid);
            try out.writeByte('\t');
            try dash(out, j.last_exit);
            try out.print("\t{s}\n", .{j.label});
        }
    }

    pub fn print(c: *Client, arena: Allocator, out: *Writer, label: []const u8, json: bool) !void {
        const j = try c.print(arena, label);
        if (json) return protocol.writePretty(out, j);
        try out.print("{s} = {{\n", .{j.label});
        try out.print("\tstate = {s}\n", .{j.state});
        try out.writeAll("\tpid = ");
        try dash(out, j.pid);
        try out.print("\n\truns = {d}\n", .{j.runs});
        try out.writeAll("\tlast exit code = ");
        try dash(out, j.last_exit);
        try out.writeAll("\n\tprogram = ");
        for (j.argv, 0..) |a, i| try out.print("{s}{s}", .{ if (i > 0) " " else "", a });
        try out.print("\n\tworking directory = {s}\n", .{j.cwd});
        if (j.foreground) |fg| try out.print("\tforeground = {s} in {s}\n", .{ fg, j.foreground_cwd orelse "?" });
        try out.print("\tattached = {d}\n", .{j.attached});
        for (j.job.environment_variables) |e| try out.print("\tenv {s} = {s}\n", .{ e.name, e.value });
        try out.writeAll("}\n");
    }

    pub fn start(c: *Client, label: []const u8) !void {
        try c.start(label);
    }

    pub fn stop(c: *Client, label: []const u8) !void {
        try c.stop(label);
    }

    /// Start a job; with `k`, kill and restart it if it is running.
    pub fn kickstart(c: *Client, label: []const u8, k: bool) !void {
        try c.kickstart(label, k);
    }

    /// Stop every job and the daemon (no-op when it isn't running).
    pub fn shutdown(c: *Client) !void {
        if (c.running()) try c.shutdown();
    }
};

pub const session = struct {
    pub const NewOptions = struct {
        name: []const u8,
        /// Don't attach (like tmux new -d).
        detached: bool = false,
        /// Working directory, relative to the current directory (default: current dir).
        cwd: ?[]const u8 = null,
        /// Restart the command whenever it exits (KeepAlive, ThrottleInterval 1).
        keep_alive: bool = false,
        /// Program and arguments; empty: $SHELL.
        cmd: []const []const u8 = &.{},
        env: []const jobmod.EnvVar = &.{},
    };

    /// The Job `session new` loads (also what the MCP session_new tool loads).
    pub fn job(opts: NewOptions, cwd: ?[]const u8) Job {
        return .{
            .label = opts.name,
            .program_arguments = opts.cmd,
            .working_directory = cwd,
            .environment_variables = opts.env,
            .run_at_load = true,
            .keep_alive = if (opts.keep_alive) .{ .always = true } else null,
            .throttle_interval = if (opts.keep_alive) 1 else null,
        };
    }

    pub fn new(c: *Client, arena: Allocator, out: *Writer, opts: NewOptions) !void {
        const cwd: ?[]const u8 = std.Io.Dir.cwd().realPathFileAlloc(c.io, opts.cwd orelse ".", arena) catch |e| blk: {
            if (opts.cwd) |p| {
                c.err_buf.clearRetainingCapacity();
                try c.err_buf.print(c.gpa, "{s}: {s}", .{ p, @errorName(e) });
                return error.Remote;
            }
            break :blk null;
        };
        try c.load(&.{job(opts, cwd)}, true);
        if (opts.detached) {
            try out.print("{s}\n", .{opts.name});
        } else {
            try out.flush();
            try c.attach(opts.name);
        }
    }

    pub fn ls(c: *Client, arena: Allocator, out: *Writer, json: bool) !void {
        const jobs = try c.list(arena);
        if (json) return protocol.writePretty(out, jobs);
        for (jobs) |j| {
            try out.print("{s}: ", .{j.label});
            if (j.foreground != null and j.foreground_cwd != null)
                try out.print("{s} in {s}", .{ j.foreground.?, j.foreground_cwd.? })
            else
                try out.writeAll(j.state);
            try out.print("{s}\n", .{if (j.attached > 0) " (attached)" else ""});
        }
    }

    pub fn attach(c: *Client, name: []const u8) !void {
        try c.attach(name);
    }

    /// Type TEXT (words joined by spaces) into a session; `enter` presses enter.
    pub fn send(c: *Client, arena: Allocator, name: []const u8, text: []const []const u8, enter: bool) !void {
        var data: std.ArrayList(u8) = .empty;
        for (text, 0..) |t, i| {
            if (i > 0) try data.append(arena, ' ');
            try data.appendSlice(arena, t);
        }
        if (enter) try data.append(arena, '\r');
        try c.send(name, data.items);
    }

    pub fn capture(c: *Client, arena: Allocator, out: *Writer, name: []const u8, escapes: bool) !void {
        try out.print("{s}\n", .{try c.capture(arena, name, escapes)});
    }

    pub const RunOptions = struct {
        name: []const u8,
        /// Settle time with no new output, in ms.
        idle_ms: u64 = 800,
        /// Give up waiting after this many ms.
        timeout_ms: u64 = 60_000,
        command: []const []const u8,
    };

    /// For agents: type COMMAND + enter, wait until output settles, print the screen.
    pub fn run(c: *Client, arena: Allocator, out: *Writer, opts: RunOptions) !void {
        const cmd = try std.mem.join(arena, " ", opts.command);
        try out.print("{s}\n", .{try c.run(arena, opts.name, cmd, opts.idle_ms, opts.timeout_ms)});
    }

    pub fn kill(c: *Client, name: []const u8) !void {
        try c.unload(name);
    }
};
