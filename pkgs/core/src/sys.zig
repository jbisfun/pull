//! Process-wide `std.Io`, environment and small fs/process helpers. `main` calls
//! `init` once; tests use `std.testing`'s Io. pull is a short-lived CLI, so the
//! Io and an arena allocator are globals instead of being threaded everywhere.
const std = @import("std");
const builtin = @import("builtin");

pub var io: std.Io = if (builtin.is_test) std.testing.io else undefined;
var environ_map: ?*const std.process.Environ.Map = null;

pub fn init(i: std.Io, env: *const std.process.Environ.Map) void {
    io = i;
    environ_map = env;
}

pub fn getenv(name: []const u8) ?[]const u8 {
    if (environ_map) |m| return m.get(name);
    if (builtin.is_test) return std.testing.environ.getPosix(name);
    return null;
}

/// A mutable copy of the process environment.
pub fn envMap(a: std.mem.Allocator) !std.process.Environ.Map {
    if (environ_map) |m| return m.clone(a);
    if (builtin.is_test) return std.testing.environ.createMap(a);
    unreachable;
}

pub fn home() ?[]const u8 {
    const h = getenv("HOME") orelse return null;
    return if (h.len == 0) null else h;
}

// ------------------------------------------------------------------ errors

/// The message of the last `fail`; main prints it as `pull: {msg}`.
pub var msg_buf: [8192]u8 = undefined;
pub var msg: []const u8 = "";

/// Record an error message (anyhow-style) and return error.Fail.
pub fn fail(comptime fmt: []const u8, args: anytype) error{Fail} {
    msg = std.fmt.bufPrint(&msg_buf, fmt, args) catch blk: {
        const tail = "...";
        @memcpy(msg_buf[msg_buf.len - tail.len ..], tail);
        break :blk msg_buf[0..];
    };
    return error.Fail;
}

/// Prefix the current message with `ctx: ` (anyhow `.context()` printed with `{:#}`).
/// Non-Fail errors become a Fail carrying `ctx: ErrorName`.
pub fn context(e: anyerror, comptime fmt: []const u8, args: anytype) error{Fail} {
    var ctx_buf: [1024]u8 = undefined;
    const ctx = std.fmt.bufPrint(&ctx_buf, fmt, args) catch "";
    if (e == error.Fail) {
        var tmp: [8192]u8 = undefined;
        const inner = tmp[0..msg.len];
        @memcpy(inner, msg);
        return fail("{s}: {s}", .{ ctx, inner });
    }
    return fail("{s}: {s}", .{ ctx, describe(e) });
}

/// Human text for an error: the recorded message for Fail, else a readable name.
pub fn describe(e: anyerror) []const u8 {
    if (e == error.Fail) return msg;
    return switch (e) {
        error.FileNotFound => "No such file or directory (os error 2)",
        error.AccessDenied => "Permission denied (os error 13)",
        error.NotDir => "Not a directory (os error 20)",
        error.IsDir => "Is a directory (os error 21)",
        else => @errorName(e),
    };
}

// ------------------------------------------------------------------ output

/// Unbuffered writes: children share the descriptors, nothing may sit in a buffer.
pub fn print(file: std.Io.File, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    var w = file.writerStreaming(io, &buf);
    w.interface.print(fmt, args) catch {};
    w.interface.flush() catch {};
}

pub fn out(comptime fmt: []const u8, args: anytype) void {
    print(std.Io.File.stdout(), fmt, args);
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    print(std.Io.File.stderr(), fmt, args);
}

pub fn outBytes(bytes: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(io, bytes) catch {};
}

// ------------------------------------------------------------------ fs

pub fn cwd() std.Io.Dir {
    return std.Io.Dir.cwd();
}

/// Absolute, symlink-resolved path (fails if it doesn't exist).
pub fn realpath(a: std.mem.Allocator, path: []const u8) ![]u8 {
    return cwd().realPathFileAlloc(io, path, a);
}

pub fn readFile(a: std.mem.Allocator, path: []const u8) ![]u8 {
    return cwd().readFileAlloc(io, path, a, .limited(64 * 1024 * 1024));
}

/// File contents, or "" if it can't be read (Rust's `read_to_string(..).unwrap_or_default()`).
pub fn readFileOrEmpty(a: std.mem.Allocator, path: []const u8) []const u8 {
    return readFile(a, path) catch "";
}

pub fn writeFile(path: []const u8, data: []const u8) !void {
    return cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

pub fn makePath(path: []const u8) !void {
    return cwd().createDirPath(io, path);
}

pub fn deleteTree(path: []const u8) !void {
    return cwd().deleteTree(io, path);
}

pub fn exists(path: []const u8) bool {
    cwd().access(io, path, .{}) catch return false;
    return true;
}

pub fn kind(path: []const u8) ?std.Io.File.Kind {
    const st = cwd().statFile(io, path, .{}) catch return null;
    return st.kind;
}

pub fn isFile(path: []const u8) bool {
    return kind(path) == .file;
}

pub fn isDir(path: []const u8) bool {
    return kind(path) == .directory;
}

pub fn copyFile(src: []const u8, dst: []const u8) !void {
    try std.Io.Dir.copyFile(cwd(), src, cwd(), dst, io, .{});
}

pub fn join(a: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    return std.fs.path.join(a, parts);
}

// ------------------------------------------------------------------ processes

pub const Child = std.process.Child;
pub const Term = std.process.Child.Term;

pub const SpawnOptions = struct {
    cwd: ?[]const u8 = null,
    env: ?*const std.process.Environ.Map = null,
    stdin: std.process.SpawnOptions.StdIo = .inherit,
    stdout: std.process.SpawnOptions.StdIo = .inherit,
    stderr: std.process.SpawnOptions.StdIo = .inherit,
};

/// `argv[0]` without a '/' is looked up on the PATH of `env` (the child's env).
fn exeFor(argv0: []const u8, env: ?*const std.process.Environ.Map, buf: []u8) std.process.ReplaceOptions.Exe {
    const e = env orelse return .detect;
    if (std.mem.indexOfScalar(u8, argv0, '/') != null) return .detect;
    var it = std.mem.tokenizeScalar(u8, e.get("PATH") orelse return .detect, ':');
    while (it.next()) |dir| {
        const candidate = std.fmt.bufPrint(buf, "{s}/{s}", .{ dir, argv0 }) catch continue;
        cwd().access(io, candidate, .{ .execute = true }) catch continue;
        const st = cwd().statFile(io, candidate, .{}) catch continue;
        if (st.kind == .directory) continue;
        return .{ .explicit = .{ .dir = cwd(), .path = candidate } };
    }
    return .detect;
}

pub fn spawn(argv: []const []const u8, opts: SpawnOptions) std.process.SpawnError!Child {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    return std.process.spawn(io, .{
        .exe = exeFor(argv[0], opts.env, &buf),
        .argv = argv,
        .cwd = if (opts.cwd) |d| .{ .path = d } else .inherit,
        .environ_map = opts.env,
        .stdin = opts.stdin,
        .stdout = opts.stdout,
        .stderr = opts.stderr,
    });
}

pub fn succeeded(term: Term) bool {
    return term == .exited and term.exited == 0;
}

/// Exit code as a process would see it (signals -> 128+n, like a shell).
pub fn exitCode(term: Term) u8 {
    return switch (term) {
        .exited => |c| c,
        .signal => |s| 128 +| @as(u8, @truncate(@intFromEnum(s))),
        else => 1,
    };
}

/// Like Rust's `ExitStatus` Display: "exit status: N" / "signal: N".
pub fn fmtTerm(buf: []u8, term: Term) []const u8 {
    return switch (term) {
        .exited => |c| std.fmt.bufPrint(buf, "exit status: {d}", .{c}) catch "exit status",
        .signal => |s| std.fmt.bufPrint(buf, "signal: {d}", .{@intFromEnum(s)}) catch "signal",
        else => "abnormal exit",
    };
}

/// Run with inherited stdio and wait.
pub fn runInherit(argv: []const []const u8, opts: SpawnOptions) !Term {
    var child = try spawn(argv, opts);
    return child.wait(io);
}

pub const Output = struct {
    term: Term,
    stdout: []u8,
    stderr: []u8,

    pub fn ok(o: Output) bool {
        return succeeded(o.term);
    }
};

pub const RunOptions = struct {
    cwd: ?[]const u8 = null,
    env: ?*const std.process.Environ.Map = null,
    stdin: ?[]const u8 = null,
};

/// Run to completion collecting stdout/stderr, optionally feeding `stdin`.
pub fn run(a: std.mem.Allocator, argv: []const []const u8, opts: RunOptions) !Output {
    var child = try spawn(argv, .{
        .cwd = opts.cwd,
        .env = opts.env,
        .stdin = if (opts.stdin != null) .pipe else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    if (opts.stdin) |input| {
        if (child.stdin) |f| {
            f.writeStreamingAll(io, input) catch {};
            f.close(io);
            child.stdin = null;
        }
    }
    defer child.kill(io);
    var mr_buf: std.Io.File.MultiReader.Buffer(2) = undefined;
    var mr: std.Io.File.MultiReader = undefined;
    mr.init(a, io, mr_buf.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer mr.deinit();
    while (mr.fill(64, .none)) |_| {} else |e| switch (e) {
        error.EndOfStream => {},
        else => |x| return x,
    }
    try mr.checkAnyError();
    const term = try child.wait(io);
    return .{ .term = term, .stdout = try mr.toOwnedSlice(0), .stderr = try mr.toOwnedSlice(1) };
}

// ------------------------------------------------------------------ time

/// Seconds since the epoch and the local UTC offset in minutes (from $TZ or
/// /etc/localtime via std.tz), for commit signatures.
pub fn now() struct { secs: i64, offset_min: i32 } {
    const secs = std.Io.Timestamp.now(io, .real).toSeconds();
    return .{ .secs = secs, .offset_min = localOffset(secs) };
}

fn localOffset(secs: i64) i32 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = blk: {
        if (getenv("TZ")) |tz| {
            const name = if (tz.len > 0 and tz[0] == ':') tz[1..] else tz;
            if (name.len > 0 and name[0] == '/') break :blk name;
            if (name.len > 0) break :blk std.fmt.allocPrint(a, "/usr/share/zoneinfo/{s}", .{name}) catch return 0;
        }
        break :blk "/etc/localtime";
    };
    const data = readFile(a, path) catch return 0;
    var r = std.Io.Reader.fixed(data);
    const tz = std.Tz.parse(a, &r) catch return 0;
    var off: ?i32 = null;
    for (tz.transitions) |t| {
        if (t.ts > secs) break;
        off = t.timetype.offset;
    }
    if (off == null) {
        for (tz.timetypes) |tt| if (!tt.isDst()) {
            off = tt.offset;
            break;
        };
    }
    return @divTrunc(off orelse 0, 60);
}
