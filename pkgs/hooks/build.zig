//! pull-hooks: pullfile `hooks` (precommit, postcommit, pull).
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const mod = b.addModule("hooks", .{
        .root_source_file = b.path("src/hooks.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("core", b.dependency("core", .{ .target = target, .optimize = optimize }).module("core"));

    const t = b.addTest(.{ .root_module = mod });
    b.step("test", "Run pull-hooks tests").dependOn(&b.addRunArtifact(t).step);
}
