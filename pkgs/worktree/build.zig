//! pull-worktree: `pull worktree`, workspace-wide git worktrees.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const mod = b.addModule("worktree", .{
        .root_source_file = b.path("src/worktree.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("core", b.dependency("core", .{ .target = target, .optimize = optimize }).module("core"));

    const t = b.addTest(.{ .root_module = mod });
    b.step("test", "Run pull-worktree tests").dependOn(&b.addRunArtifact(t).step);
}
