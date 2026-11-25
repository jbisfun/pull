//! libc calls std doesn't export (or exports with awkward types). Linux and macOS.
const std = @import("std");

pub const fd_t = c_int;
pub const pid_t = c_int;
pub const winsize = std.posix.winsize;
pub const termios = std.c.termios;

pub extern "c" fn openpty(amaster: *fd_t, aslave: *fd_t, name: ?[*]u8, termp: ?*const termios, winp: ?*const winsize) c_int;
pub extern "c" fn cfmakeraw(t: *termios) void;
pub extern "c" fn tcgetattr(fd: fd_t, t: *termios) c_int;
pub extern "c" fn tcsetattr(fd: fd_t, action: c_int, t: *const termios) c_int;
pub extern "c" fn fork() pid_t;
pub extern "c" fn setsid() pid_t;
pub extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
pub extern "c" fn execve(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
pub extern "c" fn _exit(code: c_int) noreturn;
pub extern "c" fn ioctl(fd: fd_t, req: c_ulong, ...) c_int;
pub extern "c" fn dup2(old: fd_t, new: fd_t) c_int;
pub extern "c" fn close(fd: fd_t) c_int;
pub extern "c" fn chdir(path: [*:0]const u8) c_int;
pub extern "c" fn read(fd: fd_t, buf: [*]u8, n: usize) isize;
pub extern "c" fn write(fd: fd_t, buf: [*]const u8, n: usize) isize;
pub extern "c" fn send(fd: fd_t, buf: [*]const u8, n: usize, flags: c_int) isize;
pub extern "c" fn shutdown(fd: fd_t, how: c_int) c_int;
pub extern "c" fn kill(pid: pid_t, sig: c_int) c_int;
pub extern "c" fn waitpid(pid: pid_t, status: *c_int, options: c_int) pid_t;
pub extern "c" fn pipe(fds: *[2]fd_t) c_int;
pub extern "c" fn fcntl(fd: fd_t, cmd: c_int, ...) c_int;
pub extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) fd_t;
pub extern "c" fn signal(sig: c_int, handler: usize) usize;
pub extern "c" fn sigprocmask(how: c_int, set: ?*const anyopaque, old: ?*anyopaque) c_int;
pub extern "c" fn poll(fds: [*]pollfd, n: c_ulong, timeout: c_int) c_int;
pub extern "c" fn strerror(e: c_int) [*:0]const u8;
pub extern "c" var environ: [*:null]?[*:0]u8;

pub const pollfd = extern struct { fd: fd_t, events: c_short, revents: c_short = 0 };
pub const POLLIN: c_short = 0x001;
pub const POLLHUP: c_short = 0x010;

pub const SIGHUP = 1;
pub const SIGKILL = 9;
pub const SIGPIPE = 13;
pub const SIGTERM = 15;
pub const SIG_DFL: usize = 0;
pub const SIG_IGN: usize = 1;
pub const SIG_SETMASK = if (@import("builtin").os.tag == .linux) 2 else 3;

pub const SHUT_RDWR = 2;
pub const MSG_NOSIGNAL: c_int = if (@import("builtin").os.tag == .linux) 0x4000 else 0;
pub const F_SETFD = 2;
pub const FD_CLOEXEC = 1;
pub const TCSANOW = 0;
pub const TIOCSCTTY: c_ulong = @intCast(std.c.T.IOCSCTTY);
pub const TIOCGWINSZ: c_ulong = @intCast(std.c.T.IOCGWINSZ);
pub const TIOCSWINSZ: c_ulong = @intCast(std.c.T.IOCSWINSZ);

pub fn errno() c_int {
    return std.c._errno().*;
}

pub fn errText(e: c_int) []const u8 {
    return std.mem.span(strerror(e));
}

pub const EINTR = 4;
pub const EAGAIN = if (@import("builtin").os.tag == .linux) 11 else 35;

/// Write everything; sockets use MSG_NOSIGNAL so a gone peer is an error, not SIGPIPE.
pub fn writeAll(fd: fd_t, bytes: []const u8, socket: bool) !void {
    var rest = bytes;
    while (rest.len > 0) {
        const n = if (socket) send(fd, rest.ptr, rest.len, MSG_NOSIGNAL) else write(fd, rest.ptr, rest.len);
        if (n < 0) {
            if (errno() == EINTR) continue;
            return error.WriteFailed;
        }
        rest = rest[@intCast(n)..];
    }
}

pub fn setCloexec(fd: fd_t) void {
    _ = fcntl(fd, F_SETFD, @as(c_int, FD_CLOEXEC));
}

/// Exit code like portable-pty's: the status for a normal exit, 1 for a signal.
pub fn exitCode(status: c_int) i32 {
    const s: u32 = @bitCast(status);
    if (s & 0x7f == 0) return @intCast((s >> 8) & 0xff);
    return 1;
}
