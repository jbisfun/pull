//! What is running in a job's terminal, from /proc (Linux).
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Foreground = struct { program: ?[]const u8 = null, cwd: ?[]const u8 = null };

/// (foreground program, its working directory) for the terminal session led by `pid`:
/// the terminal's foreground process group (`tpgid` in /proc/PID/stat), like tmux's
/// pane_current_command / pane_current_path.
pub fn foreground(arena: Allocator, io: Io, pid: i32) Foreground {
    const fg = blk: {
        const t = tpgid(arena, io, pid) orelse break :blk pid;
        break :blk if (t > 0) t else pid;
    };
    var out: Foreground = .{};
    const comm_path = std.fmt.allocPrint(arena, "/proc/{d}/comm", .{fg}) catch return out;
    var buf: [256]u8 = undefined;
    if (Io.Dir.cwd().readFile(io, comm_path, &buf)) |s| {
        out.program = arena.dupe(u8, std.mem.trim(u8, s, " \t\r\n")) catch null;
    } else |_| {}
    const cwd_path = std.fmt.allocPrint(arena, "/proc/{d}/cwd", .{fg}) catch return out;
    var lbuf: [std.fs.max_path_bytes]u8 = undefined;
    if (Io.Dir.cwd().readLink(io, cwd_path, &lbuf)) |n| {
        out.cwd = arena.dupe(u8, lbuf[0..n]) catch null;
    } else |_| {}
    return out;
}

fn tpgid(arena: Allocator, io: Io, pid: i32) ?i64 {
    const path = std.fmt.allocPrint(arena, "/proc/{d}/stat", .{pid}) catch return null;
    var buf: [1024]u8 = undefined;
    const stat = Io.Dir.cwd().readFile(io, path, &buf) catch return null;
    return parseTpgid(stat);
}

fn parseTpgid(stat: []const u8) ?i64 {
    // Fields after the parenthesised comm: state ppid pgrp session tty_nr tpgid ...
    const close = std.mem.lastIndexOfScalar(u8, stat, ')') orelse return null;
    if (close + 2 > stat.len) return null;
    var it = std.mem.tokenizeScalar(u8, stat[close + 2 ..], ' ');
    var i: usize = 0;
    while (it.next()) |f| : (i += 1) {
        if (i == 5) return std.fmt.parseInt(i64, f, 10) catch null;
    }
    return null;
}

test parseTpgid {
    try std.testing.expectEqual(@as(?i64, 4242), parseTpgid("123 (a) b) S 1 123 123 34816 4242 0 0"));
    try std.testing.expectEqual(@as(?i64, null), parseTpgid("garbage"));
}
