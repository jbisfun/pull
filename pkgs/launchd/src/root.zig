//! A port of launchd's job model to pull (per workspace).
//!
//! Jobs use launchd's plist keys and live in the pullfile's `jobs` array or in
//! standalone `.plist` files (the bin parses those into `Job`s). Every job runs in a
//! pseudo-terminal managed by the workspace daemon (`pull launchd`), so any job is also
//! a tmux-style session: a human can attach to it, an agent can send input and read
//! its screen.
const std = @import("std");

pub const job = @import("job.zig");
pub const protocol = @import("protocol.zig");
pub const daemon = @import("daemon.zig");
pub const client = @import("client.zig");
pub const commands = @import("commands.zig");
pub const procinfo = @import("procinfo.zig");

pub const Job = job.Job;
pub const KeepAlive = job.KeepAlive;
pub const EnvVar = job.EnvVar;
pub const JobStatus = protocol.JobStatus;
pub const Request = protocol.Request;
pub const Response = protocol.Response;
pub const Client = client.Client;
pub const EnvProvider = daemon.EnvProvider;
pub const launchctl = commands.launchctl;
pub const session = commands.session;

/// Pullfile section key (an array of jobs).
pub const SECTION = "jobs";

/// Per-workspace state directory (socket, daemon log).
pub fn stateDir(arena: std.mem.Allocator, root: []const u8) ![]const u8 {
    return std.fs.path.join(arena, &.{ root, ".pull" });
}

pub fn socketPath(arena: std.mem.Allocator, root: []const u8) ![]const u8 {
    return std.fs.path.join(arena, &.{ root, ".pull", "launchd.sock" });
}

test {
    std.testing.refAllDecls(@This());
    _ = job;
    _ = protocol;
    _ = daemon;
    _ = procinfo;
}
