//! `pull launchd`: the per-workspace job supervisor. Runs every job in a PTY with a VT
//! screen (ghostty-vt), so every job is also a session.
const std = @import("std");
const vt = @import("ghostty-vt");
const sys = @import("sys.zig");
const procinfo = @import("procinfo.zig");
const protocol = @import("protocol.zig");
const jobmod = @import("job.zig");
const root_mod = @import("root.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const net = std.Io.net;
const Job = jobmod.Job;
const EnvVar = jobmod.EnvVar;
const Request = protocol.Request;
const Response = protocol.Response;
const JobStatus = protocol.JobStatus;
const log = std.log.scoped(.launchd);

const ROWS = 40;
const COLS = 120;
const SCROLLBACK_LINES = 2000;

/// Supplies the workspace environment at each job start (so edits to the pullfile `env`
/// apply to the next run). Allocate the result in `arena`.
pub const EnvProvider = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque, arena: Allocator) anyerror![]const EnvVar,
};

pub const Options = struct {
    /// Absolute workspace root.
    root: []const u8,
    /// The pullfile's jobs, loaded (and RunAtLoad ones started) at startup.
    jobs: []const Job = &.{},
    env: ?EnvProvider = null,
};

const Attached = struct { id: u64, fd: sys.fd_t };

const Proc = struct { pid: sys.pid_t, master: sys.fd_t };

const Entry = struct {
    refs: std.atomic.Value(u32) = .init(1),
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    job: Job,
    proc: ?Proc = null,
    removed: bool = false,
    run_id: u64 = 0,
    runs: u32 = 0,
    last_exit: ?i32 = null,
    last_start: ?i64 = null,
    next_start: ?i64 = null,
    /// Stopped by the user: KeepAlive/StartInterval don't restart it.
    stopped: bool = false,
    /// kickstart -k: start again as soon as the current run exits.
    restart_on_exit: bool = false,

    term_lock: Io.Mutex = .init,
    term: vt.Terminal,
    stream: vt.TerminalStream = undefined,
    clients_lock: Io.Mutex = .init,
    clients: std.ArrayList(Attached) = .empty,
    last_output: std.atomic.Value(i64),

    fn create(gpa: Allocator, io: Io, job: Job, now: i64) !*Entry {
        const e = try gpa.create(Entry);
        errdefer gpa.destroy(e);
        e.* = .{
            .gpa = gpa,
            .arena = .init(gpa),
            .job = undefined,
            .term = try .init(io, gpa, .{ .cols = COLS, .rows = ROWS, .max_scrollback_lines = SCROLLBACK_LINES }),
            .last_output = .init(now),
        };
        e.job = try job.clone(e.arena.allocator());
        e.stream = e.term.vtStream();
        return e;
    }

    fn ref(e: *Entry) *Entry {
        _ = e.refs.fetchAdd(1, .monotonic);
        return e;
    }

    fn unref(e: *Entry) void {
        if (e.refs.fetchSub(1, .acq_rel) != 1) return;
        e.stream.deinit();
        e.term.deinit(e.gpa);
        e.clients.deinit(e.gpa);
        e.arena.deinit();
        e.gpa.destroy(e);
    }

    fn state(e: *const Entry) []const u8 {
        if (e.proc != null) return "running";
        if (e.stopped) return "stopped";
        if (e.next_start != null) return "waiting";
        if (e.runs > 0) return "exited";
        return "loaded";
    }
};

const Fail = error{Failed};

pub const Daemon = struct {
    gpa: Allocator,
    io: Io,
    root: []const u8,
    env: ?EnvProvider,
    lock: Io.Mutex = .init,
    jobs: std.StringArrayHashMapUnmanaged(*Entry) = .empty,
    ids: std.atomic.Value(u64) = .init(1),

    fn now(d: *Daemon) i64 {
        return Io.Clock.awake.now(d.io).toMilliseconds();
    }

    fn sleep(d: *Daemon, ms: i64) void {
        d.io.sleep(.fromMilliseconds(ms), .awake) catch {};
    }

    fn lockJobs(d: *Daemon) void {
        d.lock.lockUncancelable(d.io);
    }

    fn unlockJobs(d: *Daemon) void {
        d.lock.unlock(d.io);
    }

    /// Error text for the current request, in the request arena.
    const Diag = struct {
        arena: Allocator,
        msg: []const u8 = "",
        fn fail(self: *Diag, comptime fmt: []const u8, args: anytype) Fail {
            self.msg = std.fmt.allocPrint(self.arena, fmt, args) catch "out of memory";
            return error.Failed;
        }
    };

    fn get(d: *Daemon, diag: *Diag, label: []const u8) Fail!*Entry {
        return d.jobs.get(label) orelse diag.fail("no job with label {s}", .{label});
    }

    fn jobCwd(d: *Daemon, arena: Allocator, job: Job) ![]const u8 {
        const wd = job.working_directory orelse return d.root;
        return jobmod.expandPath(arena, d.root, wd);
    }

    // ---- starting jobs ------------------------------------------------------

    /// Start `label` now. Caller holds no lock.
    fn start(d: *Daemon, diag: *Diag, label: []const u8) Fail!void {
        d.lockJobs();
        defer d.unlockJobs();
        const e = try d.get(diag, label);
        return d.startLocked(diag, e);
    }

    fn startLocked(d: *Daemon, diag: *Diag, e: *Entry) Fail!void {
        if (e.proc != null) return;
        if (e.job.launch_only_once and e.runs > 0)
            return diag.fail("{s} is LaunchOnlyOnce and already ran", .{e.job.label});
        var arena_state: std.heap.ArenaAllocator = .init(d.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const job = e.job;
        const argv = job.argv(arena) catch return diag.fail("out of memory", .{});
        const cwd = d.jobCwd(arena, job) catch return diag.fail("out of memory", .{});
        const envp = d.buildEnv(arena, job) catch |err| return diag.fail("{s}: environment: {s}", .{ job.label, @errorName(err) });

        e.term_lock.lockUncancelable(d.io);
        const ws: sys.winsize = .{ .row = e.term.rows, .col = e.term.cols, .xpixel = 0, .ypixel = 0 };
        e.term_lock.unlock(d.io);

        const proc = spawnPty(arena, argv, cwd, envp, ws) catch |err| {
            const joined = std.mem.join(arena, " ", argv) catch "";
            return diag.fail("starting {s}: {s}: {s}", .{ job.label, joined, spawn_error_text(err) });
        };

        e.run_id = d.ids.fetchAdd(1, .monotonic);
        e.runs += 1;
        e.last_start = d.now();
        e.next_start = null;
        e.stopped = false;
        e.proc = proc;
        e.last_output.store(d.now(), .monotonic);

        var log_fd: sys.fd_t = -1;
        if (job.standard_out_path) |p| {
            if (jobmod.expandPath(arena, d.root, p)) |path| {
                const z = arena.dupeSentinel(u8, path, 0) catch "";
                if (z.len > 0) log_fd = openAppend(z);
            } else |_| {}
        }
        const t = std.Thread.spawn(.{}, readerThread, .{ d, e.ref(), e.run_id, proc, log_fd }) catch {
            e.unref();
            _ = sys.kill(-proc.pid, sys.SIGKILL);
            return diag.fail("starting {s}: cannot spawn reader thread", .{job.label});
        };
        t.detach();
    }

    /// Daemon env + TERM + workspace env + job EnvironmentVariables (expanded) + PULL_JOB.
    fn buildEnv(d: *Daemon, arena: Allocator, job: Job) ![:null]?[*:0]u8 {
        var map: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
        var i: usize = 0;
        while (sys.environ[i]) |kv| : (i += 1) {
            const s = std.mem.span(kv);
            const eq = std.mem.indexOfScalar(u8, s, '=') orelse continue;
            try map.put(arena, s[0..eq], s[eq + 1 ..]);
        }
        try map.put(arena, "TERM", "xterm-256color");
        if (d.env) |p| for (try p.func(p.ctx, arena)) |kv| try map.put(arena, kv.name, kv.value);
        const Lookup = struct {
            fn f(m: *std.StringArrayHashMapUnmanaged([]const u8), name: []const u8) ?[]const u8 {
                return m.get(name);
            }
        };
        for (job.environment_variables) |kv| {
            const v = try jobmod.expandValue(arena, kv.value, &map, Lookup.f);
            try map.put(arena, kv.name, v);
        }
        try map.put(arena, "PULL_JOB", job.label);
        const out = try arena.allocSentinel(?[*:0]u8, map.count(), null);
        var it = map.iterator();
        i = 0;
        while (it.next()) |kv| : (i += 1) {
            out[i] = (try std.fmt.allocPrintSentinel(arena, "{s}={s}", .{ kv.key_ptr.*, kv.value_ptr.* }, 0)).ptr;
        }
        return out;
    }

    fn readerThread(d: *Daemon, e: *Entry, run_id: u64, proc: Proc, log_fd: sys.fd_t) void {
        defer e.unref();
        var buf: [8192]u8 = undefined;
        while (true) {
            const n = sys.read(proc.master, &buf, buf.len);
            if (n < 0 and sys.errno() == sys.EINTR) continue;
            if (n <= 0) break;
            const bytes = buf[0..@intCast(n)];
            {
                e.term_lock.lockUncancelable(d.io);
                defer e.term_lock.unlock(d.io);
                e.stream.nextSlice(bytes);
            }
            e.last_output.store(d.now(), .monotonic);
            if (log_fd >= 0) sys.writeAll(log_fd, bytes, false) catch {};
            e.clients_lock.lockUncancelable(d.io);
            defer e.clients_lock.unlock(d.io);
            var i: usize = 0;
            while (i < e.clients.items.len) {
                const c = e.clients.items[i];
                if (sys.writeAll(c.fd, bytes, true)) |_| {
                    i += 1;
                } else |_| {
                    _ = sys.shutdown(c.fd, sys.SHUT_RDWR);
                    _ = e.clients.swapRemove(i);
                }
            }
        }
        if (log_fd >= 0) _ = sys.close(log_fd);
        var wstatus: c_int = 0;
        const code: ?i32 = while (true) {
            const r = sys.waitpid(proc.pid, &wstatus, 0);
            if (r == proc.pid) break sys.exitCode(wstatus);
            if (r < 0 and sys.errno() == sys.EINTR) continue;
            break null;
        };
        d.exited(e, run_id, code);
        _ = sys.close(proc.master);
    }

    fn exited(d: *Daemon, e: *Entry, run_id: u64, code: ?i32) void {
        d.lockJobs();
        defer d.unlockJobs();
        if (e.removed or e.run_id != run_id) return;
        e.proc = null;
        e.last_exit = code;
        var buf: [256]u8 = undefined;
        const msg = if (code) |c|
            std.fmt.bufPrint(&buf, "\r\n[pull: {s} exited with {d}]\r\n", .{ e.job.label, c }) catch ""
        else
            std.fmt.bufPrint(&buf, "\r\n[pull: {s} exited]\r\n", .{e.job.label}) catch "";
        d.dropClients(e, msg);
        const t = d.now();
        const throttle_until = if (e.last_start) |s| s + @as(i64, @intCast(e.job.throttle())) * 1000 else t;
        if (e.restart_on_exit) {
            e.restart_on_exit = false;
            e.next_start = t;
        } else if (!e.stopped and e.job.restartAfter(code)) {
            e.next_start = @max(throttle_until, t);
        } else if (!e.stopped and e.job.start_interval != null) {
            if (e.last_start) |s| e.next_start = s + @as(i64, @intCast(e.job.start_interval.?)) * 1000;
        }
    }

    /// Tell attached terminals `msg` and disconnect them (their connection threads see
    /// EOF and close the sockets).
    fn dropClients(d: *Daemon, e: *Entry, msg: []const u8) void {
        e.clients_lock.lockUncancelable(d.io);
        defer e.clients_lock.unlock(d.io);
        for (e.clients.items) |c| {
            sys.writeAll(c.fd, msg, true) catch {};
            _ = sys.shutdown(c.fd, sys.SHUT_RDWR);
        }
        e.clients.clearRetainingCapacity();
    }

    // ---- stopping -----------------------------------------------------------

    fn stopLocked(d: *Daemon, e: *Entry, restart: bool) void {
        e.stopped = !restart;
        e.restart_on_exit = restart;
        e.next_start = null;
        const p = e.proc orelse return;
        // The job leads its own session/process group in the PTY.
        if (sys.kill(-p.pid, sys.SIGTERM) != 0) _ = sys.kill(p.pid, sys.SIGTERM);
        // ExitTimeOut: still running this run after 5 s -> SIGKILL.
        const t = std.Thread.spawn(.{}, killLater, .{ d, e.ref(), e.run_id, p.pid }) catch {
            e.unref();
            return;
        };
        t.detach();
    }

    fn killLater(d: *Daemon, e: *Entry, run_id: u64, pid: sys.pid_t) void {
        defer e.unref();
        d.sleep(5000);
        d.lockJobs();
        defer d.unlockJobs();
        if (e.proc != null and e.run_id == run_id) {
            _ = sys.kill(-pid, sys.SIGHUP);
            _ = sys.kill(-pid, sys.SIGKILL);
            _ = sys.kill(pid, sys.SIGKILL);
        }
    }

    // ---- requests -----------------------------------------------------------

    fn load(d: *Daemon, diag: *Diag, jobs: []const Job, start_jobs: bool) Fail!void {
        var to_start: std.ArrayList([]const u8) = .empty;
        {
            d.lockJobs();
            defer d.unlockJobs();
            for (jobs) |job| {
                if (job.disabled or job.label.len == 0) continue;
                if (d.jobs.get(job.label)) |existing| {
                    if (existing.job.eql(job)) continue;
                    existing.job = job.clone(existing.arena.allocator()) catch return diag.fail("out of memory", .{});
                } else {
                    const e = Entry.create(d.gpa, d.io, job, d.now()) catch return diag.fail("out of memory", .{});
                    if (job.start_interval) |secs| {
                        if (!job.run_at_load) e.next_start = d.now() + @as(i64, @intCast(secs)) * 1000;
                    }
                    d.jobs.put(d.gpa, e.job.label, e) catch {
                        e.unref();
                        return diag.fail("out of memory", .{});
                    };
                }
                if (start_jobs and job.run_at_load)
                    to_start.append(diag.arena, job.label) catch return diag.fail("out of memory", .{});
            }
        }
        for (to_start.items) |label| try d.start(diag, label);
    }

    fn status(d: *Daemon, arena: Allocator, e: *Entry) !JobStatus {
        var fg: procinfo.Foreground = .{};
        if (e.proc) |p| fg = procinfo.foreground(arena, d.io, p.pid);
        e.clients_lock.lockUncancelable(d.io);
        const attached = e.clients.items.len;
        e.clients_lock.unlock(d.io);
        return .{
            .label = try arena.dupe(u8, e.job.label),
            .pid = if (e.proc) |p| @intCast(p.pid) else null,
            .last_exit = e.last_exit,
            .runs = e.runs,
            .state = e.state(),
            .argv = try e.job.argv(arena),
            .cwd = try d.jobCwd(arena, e.job),
            .foreground = fg.program,
            .foreground_cwd = fg.cwd,
            .attached = attached,
            .job = try e.job.clone(arena),
        };
    }

    fn handle(d: *Daemon, diag: *Diag, req: Request) Fail!Response {
        const arena = diag.arena;
        switch (req) {
            .load => |r| try d.load(diag, r.jobs, r.start),
            .unload => |r| {
                d.lockJobs();
                defer d.unlockJobs();
                const e = try d.get(diag, r.label);
                d.stopLocked(e, false);
                // Hang up the terminal as closing its master would (interactive shells
                // ignore SIGTERM).
                if (e.proc) |p| _ = sys.kill(-p.pid, sys.SIGHUP);
                e.removed = true;
                _ = d.jobs.orderedRemove(r.label);
                const msg = std.fmt.allocPrint(arena, "\r\n[pull: {s} removed]\r\n", .{r.label}) catch "";
                d.dropClients(e, msg);
                e.unref();
            },
            .list => {
                d.lockJobs();
                defer d.unlockJobs();
                const keys = arena.dupe([]const u8, d.jobs.keys()) catch return diag.fail("out of memory", .{});
                std.mem.sort([]const u8, keys, {}, struct {
                    fn lt(_: void, a: []const u8, b: []const u8) bool {
                        return std.mem.lessThan(u8, a, b);
                    }
                }.lt);
                const out = arena.alloc(JobStatus, keys.len) catch return diag.fail("out of memory", .{});
                for (out, keys) |*s, k| s.* = d.status(arena, d.jobs.get(k).?) catch return diag.fail("out of memory", .{});
                return .{ .jobs = out };
            },
            .print => |r| {
                d.lockJobs();
                defer d.unlockJobs();
                const e = try d.get(diag, r.label);
                return .{ .job = d.status(arena, e) catch return diag.fail("out of memory", .{}) };
            },
            .start => |r| try d.start(diag, r.label),
            .stop => |r| {
                d.lockJobs();
                defer d.unlockJobs();
                d.stopLocked(try d.get(diag, r.label), false);
            },
            .kickstart => |r| {
                d.lockJobs();
                defer d.unlockJobs();
                const e = try d.get(diag, r.label);
                if (e.proc != null and r.kill) d.stopLocked(e, true) else try d.startLocked(diag, e);
            },
            .send => |r| {
                d.lockJobs();
                defer d.unlockJobs();
                const e = try d.get(diag, r.label);
                const p = e.proc orelse return diag.fail("job is not running", .{});
                sys.writeAll(p.master, r.data, false) catch return diag.fail("writing to {s}: {s}", .{ r.label, sys.errText(sys.errno()) });
            },
            .capture => |r| {
                d.lockJobs();
                const e = (d.get(diag, r.label) catch |err| {
                    d.unlockJobs();
                    return err;
                }).ref();
                d.unlockJobs();
                defer e.unref();
                return .{ .text = d.capture(arena, e, if (r.escapes) .escapes else .plain) catch return diag.fail("out of memory", .{}) };
            },
            .wait_idle => |r| {
                const started = d.now();
                while (true) {
                    const running, const last = blk: {
                        d.lockJobs();
                        defer d.unlockJobs();
                        const e = try d.get(diag, r.label);
                        break :blk .{ e.proc != null, e.last_output.load(.monotonic) };
                    };
                    const t = d.now();
                    if (!running or t - last >= @as(i64, @intCast(r.idle_ms))) break;
                    if (t - started >= @as(i64, @intCast(r.timeout_ms))) break;
                    d.sleep(25);
                }
            },
            .attach => unreachable, // handled by the connection
            .shutdown => {
                {
                    d.lockJobs();
                    defer d.unlockJobs();
                    for (d.jobs.values()) |e| d.stopLocked(e, false);
                }
                const sock = root_mod.socketPath(arena, d.root) catch "";
                Io.Dir.cwd().deleteFile(d.io, sock) catch {};
                const t = std.Thread.spawn(.{}, exitSoon, .{d}) catch std.process.exit(0);
                t.detach();
            },
        }
        return .ok;
    }

    fn exitSoon(d: *Daemon) void {
        d.sleep(300);
        std.process.exit(0);
    }

    const CaptureMode = enum { plain, escapes, redraw };

    /// The visible screen: plain text (trailing newlines trimmed), with SGR escapes, or a
    /// full redraw for a newly attached terminal (styles, modes, cursor).
    fn capture(d: *Daemon, arena: Allocator, e: *Entry, mode: CaptureMode) ![]const u8 {
        e.term_lock.lockUncancelable(d.io);
        defer e.term_lock.unlock(d.io);
        return screenText(arena, &e.term, mode);
    }

    // ---- connections --------------------------------------------------------

    fn serve(d: *Daemon, stream: net.Stream) void {
        defer stream.close(d.io);
        const fd = stream.socket.handle;
        var read_buf: [64 * 1024]u8 = undefined;
        var reader = stream.reader(d.io, &read_buf);
        const r = &reader.interface;
        while (true) {
            var arena_state: std.heap.ArenaAllocator = .init(d.gpa);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            var diag: Diag = .{ .arena = arena };
            var line: Io.Writer.Allocating = .init(arena);
            _ = r.streamDelimiter(&line.writer, '\n') catch return;
            r.toss(1);
            const owned = line.written();
            if (owned.len == 0) continue;
            const req = protocol.parseRequest(arena, owned) catch |err| {
                const out = protocol.encodeLine(arena, Response{ .@"error" = @errorName(err) }) catch return;
                sys.writeAll(fd, out, true) catch return;
                continue;
            };
            if (req == .attach) {
                const a = req.attach;
                d.attach(&diag, fd, r, a.label, a.rows, a.cols) catch {
                    const out = protocol.encodeLine(arena, Response{ .@"error" = diag.msg }) catch return;
                    sys.writeAll(fd, out, true) catch {};
                };
                return;
            }
            const resp: Response = d.handle(&diag, req) catch .{ .@"error" = diag.msg };
            const out = protocol.encodeLine(arena, resp) catch return;
            sys.writeAll(fd, out, true) catch return;
        }
    }

    fn attach(d: *Daemon, diag: *Diag, fd: sys.fd_t, r: *Io.Reader, label: []const u8, rows: u16, cols: u16) Fail!void {
        const e = blk: {
            d.lockJobs();
            defer d.unlockJobs();
            const e = try d.get(diag, label);
            if (e.proc == null) return diag.fail("{s} is not running", .{label});
            break :blk e.ref();
        };
        defer e.unref();
        d.resize(e, rows, cols);
        const id = d.ids.fetchAdd(1, .monotonic);
        {
            // Redraw the current screen for the new client, then stream live output.
            // Holding the screen lock keeps the reader from interleaving output.
            e.term_lock.lockUncancelable(d.io);
            defer e.term_lock.unlock(d.io);
            const screen = screenText(diag.arena, &e.term, .redraw) catch "";
            e.clients_lock.lockUncancelable(d.io);
            defer e.clients_lock.unlock(d.io);
            sys.writeAll(fd, "\"Ok\"\n\x1b[H\x1b[2J", true) catch return;
            sys.writeAll(fd, screen, true) catch return;
            e.clients.append(d.gpa, .{ .id = id, .fd = fd }) catch return;
        }
        defer {
            e.clients_lock.lockUncancelable(d.io);
            for (e.clients.items, 0..) |c, i| if (c.id == id) {
                _ = e.clients.swapRemove(i);
                break;
            };
            e.clients_lock.unlock(d.io);
        }
        while (true) {
            const header = r.takeArray(3) catch return;
            const len = std.mem.readInt(u16, header[1..3], .big);
            const payload = r.take(len) catch return;
            switch (header[0]) {
                protocol.FRAME_DATA => {
                    d.lockJobs();
                    defer d.unlockJobs();
                    if (e.removed) return;
                    if (e.proc) |p| sys.writeAll(p.master, payload, false) catch return;
                },
                protocol.FRAME_RESIZE => if (len == 4) {
                    d.resize(e, std.mem.readInt(u16, payload[0..2], .big), std.mem.readInt(u16, payload[2..4], .big));
                },
                else => {},
            }
        }
    }

    fn resize(d: *Daemon, e: *Entry, rows: u16, cols: u16) void {
        if (rows == 0 or cols == 0) return;
        d.lockJobs();
        defer d.unlockJobs();
        {
            e.term_lock.lockUncancelable(d.io);
            defer e.term_lock.unlock(d.io);
            e.term.resize(d.gpa, .{ .cols = cols, .rows = rows }) catch return;
        }
        if (e.proc) |p| {
            const ws: sys.winsize = .{ .row = rows, .col = cols, .xpixel = 0, .ypixel = 0 };
            _ = sys.ioctl(p.master, sys.TIOCSWINSZ, &ws);
        }
    }

    /// KeepAlive / StartInterval / kickstart restarts.
    fn supervise(d: *Daemon) void {
        while (true) {
            d.sleep(250);
            var arena_state: std.heap.ArenaAllocator = .init(d.gpa);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            var due: std.ArrayList([]const u8) = .empty;
            {
                d.lockJobs();
                defer d.unlockJobs();
                const t = d.now();
                for (d.jobs.values()) |e| {
                    if (e.proc == null and e.next_start != null and e.next_start.? <= t)
                        due.append(arena, arena.dupe(u8, e.job.label) catch continue) catch continue;
                }
            }
            for (due.items) |label| {
                var diag: Diag = .{ .arena = arena };
                d.start(&diag, label) catch {
                    log.err("{s}: {s}", .{ label, diag.msg });
                    d.lockJobs();
                    defer d.unlockJobs();
                    if (d.jobs.get(label)) |e| e.next_start = null;
                };
            }
        }
    }
};

pub fn screenText(arena: Allocator, t: *vt.Terminal, mode: Daemon.CaptureMode) ![]const u8 {
    if (mode == .plain) {
        const s = try t.plainString(arena);
        return std.mem.trimEnd(u8, s, "\n");
    }
    var f: vt.formatter.TerminalFormatter = .init(t, .vt);
    const pages = &t.screens.active.pages;
    f.content = .{ .selection = .init(
        pages.pin(.{ .active = .{ .x = 0, .y = 0 } }).?,
        pages.pin(.{ .active = .{ .x = t.cols - 1, .y = t.rows - 1 } }).?,
        false,
    ) };
    f.extra = if (mode == .redraw) .{
        .palette = false,
        .modes = true,
        .scrolling_region = true,
        .tabstops = false,
        .pwd = false,
        .keyboard = true,
        .screen = .{ .cursor = true, .style = true, .hyperlink = true, .protection = false, .kitty_keyboard = true, .charsets = true },
    } else .{
        .palette = false,
        .modes = false,
        .scrolling_region = false,
        .tabstops = false,
        .pwd = false,
        .keyboard = false,
        .screen = .styles,
    };
    var w: Io.Writer.Allocating = .init(arena);
    f.format(&w.writer) catch return error.OutOfMemory;
    return w.written();
}

fn openAppend(path: [*:0]const u8) sys.fd_t {
    const flags: std.c.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true };
    const raw: u32 = @bitCast(flags);
    return sys.open(path, @bitCast(raw), @as(c_uint, 0o644));
}

const SpawnError = error{ OutOfMemory, OpenPty, Fork, Pipe, Exec };
threadlocal var last_spawn_errno: c_int = 0;

fn spawn_error_text(err: SpawnError) []const u8 {
    return switch (err) {
        error.Exec => sys.errText(last_spawn_errno),
        else => @errorName(err),
    };
}

/// Fork `argv` on a new PTY (session leader, controlling terminal = the PTY slave) with
/// `envp`; PATH lookup uses the job's PATH. Exec failures are reported synchronously
/// through a close-on-exec pipe.
fn spawnPty(arena: Allocator, argv: []const []const u8, cwd: []const u8, envp: [:null]?[*:0]u8, ws: sys.winsize) SpawnError!Proc {
    const argz = try arena.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argz, argv) |*d, a| d.* = (try arena.dupeSentinel(u8, a, 0)).ptr;
    const cwdz = try arena.dupeSentinel(u8, cwd, 0);

    var master: sys.fd_t = -1;
    var slave: sys.fd_t = -1;
    if (sys.openpty(&master, &slave, null, null, &ws) != 0) return error.OpenPty;
    sys.setCloexec(master);
    sys.setCloexec(slave);
    var pipe: [2]sys.fd_t = undefined;
    if (sys.pipe(&pipe) != 0) {
        _ = sys.close(master);
        _ = sys.close(slave);
        return error.Pipe;
    }
    sys.setCloexec(pipe[0]);
    sys.setCloexec(pipe[1]);

    const pid = sys.fork();
    if (pid < 0) {
        inline for (.{ master, slave, pipe[0], pipe[1] }) |fd| _ = sys.close(fd);
        return error.Fork;
    }
    if (pid == 0) {
        // Child of a multi-threaded process: async-signal-safe calls only until exec.
        var empty = std.mem.zeroes([128]u8);
        _ = sys.sigprocmask(sys.SIG_SETMASK, &empty, null);
        _ = sys.signal(sys.SIGPIPE, sys.SIG_DFL);
        _ = sys.setsid();
        _ = sys.ioctl(slave, sys.TIOCSCTTY, @as(c_int, 0));
        _ = sys.dup2(slave, 0);
        _ = sys.dup2(slave, 1);
        _ = sys.dup2(slave, 2);
        // A missing WorkingDirectory leaves the job in the daemon's cwd (the root).
        _ = sys.chdir(cwdz.ptr);
        sys.environ = envp.ptr;
        _ = sys.execvp(argz[0].?, argz.ptr);
        const e: c_int = sys.errno();
        _ = sys.write(pipe[1], std.mem.asBytes(&e), @sizeOf(c_int));
        sys._exit(127);
    }
    _ = sys.close(slave);
    _ = sys.close(pipe[1]);
    var child_errno: c_int = 0;
    const n = while (true) {
        const r = sys.read(pipe[0], std.mem.asBytes(&child_errno), @sizeOf(c_int));
        if (r < 0 and sys.errno() == sys.EINTR) continue;
        break r;
    };
    _ = sys.close(pipe[0]);
    if (n > 0) {
        var st: c_int = 0;
        _ = sys.waitpid(pid, &st, 0);
        _ = sys.close(master);
        last_spawn_errno = child_errno;
        return error.Exec;
    }
    return .{ .pid = pid, .master = master };
}

/// Run the daemon for the workspace at `opts.root` (foreground, never returns on
/// success), loading `opts.jobs` at start.
pub fn run(gpa: Allocator, io: Io, opts: Options) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const state = try root_mod.stateDir(arena, opts.root);
    try Io.Dir.cwd().createDirPath(io, state);
    const sock = try root_mod.socketPath(arena, opts.root);
    const addr = try net.UnixAddress.init(sock);
    if (addr.connect(io)) |s| {
        s.close(io);
        log.err("launchd is already running for {s}", .{opts.root});
        return error.AlreadyRunning;
    } else |_| {}
    Io.Dir.cwd().deleteFile(io, sock) catch {};
    var listener = addr.listen(io, .{}) catch |err| {
        log.err("binding {s}: {s}", .{ sock, @errorName(err) });
        return err;
    };
    _ = sys.signal(sys.SIGPIPE, sys.SIG_IGN);

    const d = try gpa.create(Daemon);
    d.* = .{ .gpa = gpa, .io = io, .root = try gpa.dupe(u8, opts.root), .env = opts.env };
    var diag: Daemon.Diag = .{ .arena = arena };
    d.load(&diag, opts.jobs, true) catch log.err("loading pullfile jobs: {s}", .{diag.msg});
    log.info("{s} ({d} jobs)", .{ sock, opts.jobs.len });
    (try std.Thread.spawn(.{}, Daemon.supervise, .{d})).detach();
    while (true) {
        const stream = listener.accept(io) catch |err| {
            log.warn("accept: {s}", .{@errorName(err)});
            d.sleep(100);
            continue;
        };
        const t = std.Thread.spawn(.{}, Daemon.serve, .{ d, stream }) catch {
            stream.close(io);
            continue;
        };
        t.detach();
    }
}

test "screen text" {
    const a = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    var t: vt.Terminal = try .init(std.testing.io, a, .{ .cols = 20, .rows = 5 });
    defer t.deinit(a);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("$ echo hi\r\nhi\r\n\x1b[31mred\x1b[0m\r\n");
    try std.testing.expectEqualStrings("$ echo hi\nhi\nred", try screenText(arena.allocator(), &t, .plain));
    const esc = try screenText(arena.allocator(), &t, .escapes);
    try std.testing.expect(std.mem.indexOf(u8, esc, "red") != null);
    try std.testing.expect(std.mem.indexOf(u8, esc, "\x1b[") != null);
}
