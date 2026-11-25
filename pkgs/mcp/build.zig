//! pull-mcp: the MCP server (`pull mcp`) over a pull workspace, on parley.
//! `-Dsessions=false` leaves out the session/job tools (and pkgs/launchd),
//! `-Dhaxy=false` the haxy_* tools (and pkgs/haxy).
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sessions = b.option(bool, "sessions", "Session and job tools (needs pkgs/launchd)") orelse true;
    const haxy = b.option(bool, "haxy", "haxy issue tools (needs pkgs/haxy)") orelse true;
    const args = .{ .target = target, .optimize = optimize };

    const options = b.addOptions();
    options.addOption(bool, "sessions", sessions);
    options.addOption(bool, "haxy", haxy);
    const mod = b.addModule("mcp", .{
        .root_source_file = b.path("src/mcp.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addOptions("mcp_options", options);
    mod.addImport("core", b.dependency("core", args).module("core"));
    mod.addImport("git", b.dependency("git", args).module("git"));
    mod.addImport("parley", b.dependency("parley", args).module("parley"));
    mod.addImport("regex", b.dependency("regex", args).module("regex"));
    mod.addImport("sweep", b.dependency("sweep", args).module("sweep"));
    if (sessions) if (b.lazyDependency("launchd", args)) |d| mod.addImport("launchd", d.module("launchd"));
    if (haxy) if (b.lazyDependency("haxy", args)) |d| mod.addImport("haxy", d.module("haxy"));

    const t = b.addTest(.{ .root_module = mod });
    b.step("test", "Run pull-mcp tests").dependOn(&b.addRunArtifact(t).step);
}
