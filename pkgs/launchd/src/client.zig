//! Client of the workspace launchd: requests, auto-start, and terminal attach.
const std = @import("std");
const sys = @import("sys.zig");
const protocol = @import("protocol.zig");
const root_mod = @import("root.zig");
const Job = @import("job.zig").Job;

const Allocator = std.mem.Allocator;
const Io = std.Io;
const net = std.Io.net;
const Request = protocol.Request;
const Response = protocol.Response;
const JobStatus = protocol.JobStatus;

pub const Error = error{
    /// The daemon (or auto-start) failed; the text is in `Client.errorMessage()`.
    Remote,
    OutOfMemory,
    Disconnected,
    BadMessage,
};

pub const Client = struct {
    gpa: Allocator,
    io: Io,
    /// Absolute workspace root.
    root: []const u8,
    /// Executable started as `EXE launchd` (cwd = root, own session) when no daemon
    /// is running; null: never auto-start.
    exe: ?[]const u8,
    err_buf: std.ArrayList(u8) = .empty,

    pub fn init(gpa: Allocator, io: Io, root: []const u8, exe: ?[]const u8) Client {
        return .{ .gpa = gpa, .io = io, .root = root, .exe = exe };
    }

    pub fn deinit(c: *Client) void {
        c.err_buf.deinit(c.gpa);
    }

    /// Text of the last `error.Remote`.
    pub fn errorMessage(c: *const Client) []const u8 {
        return c.err_buf.items;
    }

    fn fail(c: *Client, comptime fmt: []const u8, args: anytype) Error {
        c.err_buf.clearRetainingCapacity();
        c.err_buf.print(c.gpa, fmt, args) catch {};
        return error.Remote;
    }

    fn tryConnect(c: *Client) ?net.Stream {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&buf);
        const sock = root_mod.socketPath(fba.allocator(), c.root) catch return null;
        const addr = net.UnixAddress.init(sock) catch return null;
        return addr.connect(c.io) catch null;
    }

    /// Is a daemon running for this workspace (without starting one)?
    pub fn running(c: *Client) bool {
        const s = c.tryConnect() orelse return false;
        s.close(c.io);
        return true;
    }

    /// Connect to the workspace daemon, starting it (detached, in its own session) if needed.
    pub fn connect(c: *Client) Error!net.Stream {
        if (c.tryConnect()) |s| return s;
        var arena_state: std.heap.ArenaAllocator = .init(c.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const state = try root_mod.stateDir(arena, c.root);
        const log_path = try std.fs.path.join(arena, &.{ state, "launchd.log" });
        const exe = c.exe orelse return c.fail("launchd is not running for {s}", .{c.root});
        Io.Dir.cwd().createDirPath(c.io, state) catch |e| return c.fail("creating {s}: {s}", .{ state, @errorName(e) });
        spawnDaemon(arena, exe, c.root, log_path) catch |e| return c.fail("starting pull launchd: {s}", .{@errorName(e)});
        var waited: u32 = 0;
        while (waited < 5000) : (waited += 50) {
            if (c.tryConnect()) |s| return s;
            c.io.sleep(.fromMilliseconds(50), .awake) catch {};
        }
        return c.fail("launchd did not start; see {s}", .{log_path});
    }

    /// One request/response. Daemon errors become `error.Remote` (see `errorMessage`).
    /// Response memory is in `arena`.
    pub fn request(c: *Client, arena: Allocator, req: Request) Error!Response {
        const s = try c.connect();
        defer s.close(c.io);
        const line = try protocol.encodeLine(arena, req);
        sys.writeAll(s.socket.handle, line, true) catch return error.Disconnected;
        var buf: [4096]u8 = undefined;
        var reader = s.reader(c.io, &buf);
        var reply: Io.Writer.Allocating = .init(arena);
        _ = reader.interface.streamDelimiter(&reply.writer, '\n') catch return error.Disconnected;
        const owned = reply.written();
        const resp = protocol.parseResponse(arena, owned) catch return c.fail("bad reply from launchd", .{});
        if (resp == .@"error") return c.fail("{s}", .{resp.@"error"});
        return resp;
    }

    fn ok(c: *Client, req: Request) Error!void {
        var arena: std.heap.ArenaAllocator = .init(c.gpa);
        defer arena.deinit();
        _ = try c.request(arena.allocator(), req);
    }

    // ---- typed requests (the MCP session tools use these) ---------------------

    pub fn load(c: *Client, jobs: []const Job, start_jobs: bool) Error!void {
        return c.ok(.{ .load = .{ .jobs = jobs, .start = start_jobs } });
    }
    pub fn unload(c: *Client, label: []const u8) Error!void {
        return c.ok(.{ .unload = .{ .label = label } });
    }
    pub fn start(c: *Client, label: []const u8) Error!void {
        return c.ok(.{ .start = .{ .label = label } });
    }
    pub fn stop(c: *Client, label: []const u8) Error!void {
        return c.ok(.{ .stop = .{ .label = label } });
    }
    pub fn kickstart(c: *Client, label: []const u8, kill: bool) Error!void {
        return c.ok(.{ .kickstart = .{ .label = label, .kill = kill } });
    }
    pub fn send(c: *Client, label: []const u8, data: []const u8) Error!void {
        return c.ok(.{ .send = .{ .label = label, .data = data } });
    }
    pub fn waitIdle(c: *Client, label: []const u8, idle_ms: u64, timeout_ms: u64) Error!void {
        return c.ok(.{ .wait_idle = .{ .label = label, .idle_ms = idle_ms, .timeout_ms = timeout_ms } });
    }
    pub fn shutdown(c: *Client) Error!void {
        return c.ok(.shutdown);
    }
    pub fn list(c: *Client, arena: Allocator) Error![]const JobStatus {
        return switch (try c.request(arena, .list)) {
            .jobs => |j| j,
            else => c.fail("unexpected reply", .{}),
        };
    }
    pub fn print(c: *Client, arena: Allocator, label: []const u8) Error!JobStatus {
        return switch (try c.request(arena, .{ .print = .{ .label = label } })) {
            .job => |j| j,
            else => c.fail("unexpected reply", .{}),
        };
    }
    pub fn capture(c: *Client, arena: Allocator, label: []const u8, escapes: bool) Error![]const u8 {
        return switch (try c.request(arena, .{ .capture = .{ .label = label, .escapes = escapes } })) {
            .text => |t| t,
            else => c.fail("unexpected reply", .{}),
        };
    }

    /// Type `command` + enter, wait until output settles, return the screen
    /// (`pull session run` / the MCP session_run tool).
    pub fn run(c: *Client, arena: Allocator, label: []const u8, command: []const u8, idle_ms: u64, timeout_ms: u64) Error![]const u8 {
        try c.send(label, try std.mem.concat(arena, u8, &.{ command, "\r" }));
        // Let the command start producing output before waiting for it to settle.
        c.io.sleep(.fromMilliseconds(100), .awake) catch {};
        try c.waitIdle(label, idle_ms, timeout_ms);
        return c.capture(arena, label, false);
    }

    /// Attach the current terminal (stdin/stdout) to a job; detach with ctrl-\.
    /// Messages ("[detached from X]") go to stderr.
    pub fn attach(c: *Client, label: []const u8) Error!void {
        var ws: sys.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
        const have_size = sys.ioctl(1, sys.TIOCGWINSZ, &ws) == 0 and ws.row > 0 and ws.col > 0;
        const rows: u16 = if (have_size) ws.row else 40;
        const cols: u16 = if (have_size) ws.col else 120;

        const s = try c.connect();
        defer s.close(c.io);
        const fd = s.socket.handle;
        {
            var arena: std.heap.ArenaAllocator = .init(c.gpa);
            defer arena.deinit();
            const line = try protocol.encodeLine(arena.allocator(), Request{ .attach = .{ .label = label, .rows = rows, .cols = cols } });
            sys.writeAll(fd, line, true) catch return error.Disconnected;
            // Read exactly one reply line (unbuffered: raw output follows it).
            var reply: std.ArrayList(u8) = .empty;
            while (true) {
                var b: [1]u8 = undefined;
                const n = sys.read(fd, &b, 1);
                if (n < 0 and sys.errno() == sys.EINTR) continue;
                if (n <= 0 or b[0] == '\n') break;
                try reply.append(arena.allocator(), b[0]);
            }
            const resp = protocol.parseResponse(arena.allocator(), reply.items) catch return c.fail("bad reply from launchd", .{});
            if (resp == .@"error") return c.fail("{s}", .{resp.@"error"});
        }

        var saved: sys.termios = undefined;
        const raw_mode = sys.tcgetattr(0, &saved) == 0;
        if (raw_mode) {
            var raw = saved;
            sys.cfmakeraw(&raw);
            _ = sys.tcsetattr(0, sys.TCSANOW, &raw);
        }
        defer if (raw_mode) {
            _ = sys.tcsetattr(0, sys.TCSANOW, &saved);
        };
        stderrPrint("\x1b]0;pull: {s}\x07", .{label});

        var last = ws;
        var fds = [_]sys.pollfd{ .{ .fd = 0, .events = sys.POLLIN }, .{ .fd = fd, .events = sys.POLLIN } };
        var buf: [8192]u8 = undefined;
        const ended = while (true) {
            fds[0].revents = 0;
            fds[1].revents = 0;
            const r = sys.poll(&fds, fds.len, 250);
            if (r < 0) {
                if (sys.errno() == sys.EINTR) continue;
                break false;
            }
            if (have_size) {
                var now: sys.winsize = last;
                if (sys.ioctl(1, sys.TIOCGWINSZ, &now) == 0 and (now.row != last.row or now.col != last.col)) {
                    last = now;
                    var p: [4]u8 = undefined;
                    std.mem.writeInt(u16, p[0..2], now.row, .big);
                    std.mem.writeInt(u16, p[2..4], now.col, .big);
                    sendFrame(fd, protocol.FRAME_RESIZE, &p) catch break true;
                }
            }
            if (fds[1].revents != 0) {
                const n = sys.read(fd, &buf, buf.len);
                if (n <= 0) break true;
                sys.writeAll(1, buf[0..@intCast(n)], false) catch break true;
            }
            if (fds[0].revents != 0) {
                const n = sys.read(0, &buf, buf.len);
                if (n <= 0) break false;
                const in = buf[0..@intCast(n)];
                // ctrl-\ detaches.
                if (std.mem.indexOfScalar(u8, in, 0x1c)) |i| {
                    if (i > 0) sendFrame(fd, protocol.FRAME_DATA, in[0..i]) catch {};
                    break false;
                }
                sendFrame(fd, protocol.FRAME_DATA, in) catch break true;
            }
        };
        _ = sys.shutdown(fd, sys.SHUT_RDWR);
        if (raw_mode) _ = sys.tcsetattr(0, sys.TCSANOW, &saved);
        if (ended) stderrPrint("\r\n[session {s} ended]\n", .{label}) else stderrPrint("\r\n[detached from {s}]\n", .{label});
    }
};

fn stderrPrint(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    sys.writeAll(2, s, false) catch {};
}

fn sendFrame(fd: sys.fd_t, kind: u8, payload: []const u8) !void {
    var rest = payload;
    while (true) {
        const chunk = rest[0..@min(rest.len, std.math.maxInt(u16))];
        var h: [3]u8 = .{ kind, 0, 0 };
        std.mem.writeInt(u16, h[1..3], @intCast(chunk.len), .big);
        try sys.writeAll(fd, &h, true);
        try sys.writeAll(fd, chunk, true);
        rest = rest[chunk.len..];
        if (rest.len == 0) return;
    }
}

/// `EXE launchd` in `root`, in its own session (double fork: init reaps it), stdin
/// /dev/null, stdout/stderr appended to `log_path`.
fn spawnDaemon(arena: Allocator, exe: []const u8, root: []const u8, log_path: []const u8) !void {
    const exez = try arena.dupeSentinel(u8, exe, 0);
    const rootz = try arena.dupeSentinel(u8, root, 0);
    const logz = try arena.dupeSentinel(u8, log_path, 0);
    const argv = [_:null]?[*:0]const u8{ exez.ptr, "launchd", null };
    const pid = sys.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        _ = sys.setsid();
        if (sys.fork() != 0) sys._exit(0);
        const flags: u32 = @bitCast(std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true });
        const log_fd = sys.open(logz.ptr, @bitCast(flags), @as(c_uint, 0o644));
        const null_flags: u32 = @bitCast(std.c.O{ .ACCMODE = .RDONLY });
        const devnull = sys.open("/dev/null", @bitCast(null_flags));
        if (devnull >= 0) _ = sys.dup2(devnull, 0);
        if (log_fd >= 0) {
            _ = sys.dup2(log_fd, 1);
            _ = sys.dup2(log_fd, 2);
        }
        _ = sys.chdir(rootz.ptr);
        _ = sys.execve(exez.ptr, &argv, @ptrCast(sys.environ));
        sys._exit(127);
    }
    var st: c_int = 0;
    _ = sys.waitpid(pid, &st, 0);
}
