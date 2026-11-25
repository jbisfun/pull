//! `pull mcp` (the `mcp` feature): pkgs/mcp served with this workspace's env, the
//! pull executable for the launchd auto-start, and the pullfile `jobs`.
const std = @import("std");
const opts = @import("build_options");
const core = @import("core");
const mcp = @import("mcp");
const ws = @import("workspace.zig");
const launchd = if (opts.launchd) @import("launchd.zig") else struct {};
const sys = core.sys;
const Allocator = std.mem.Allocator;

fn jobs(a: Allocator, root: []const u8) anyerror![]const @import("launchd").Job {
    return launchd.pullfileJobs(a, try core.Pullfile.load(a, root));
}

pub fn serve(gpa: Allocator, a: Allocator, root: []const u8) !void {
    try mcp.serve(gpa, sys.io, .{
        .root = root,
        .env = ws.workspaceEnv,
        .exe = try std.process.executablePathAlloc(sys.io, a),
        .jobs = if (opts.launchd) jobs else null,
    });
}
