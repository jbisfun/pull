//! pull-env: pullfile `env` + local.toml `[env]`; `pull env` / `pull shell`.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const mod = b.addModule("env", .{
        .root_source_file = b.path("src/env.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("core", b.dependency("core", .{ .target = target, .optimize = optimize }).module("core"));

    const t = b.addTest(.{ .root_module = mod });
    b.step("test", "Run pull-env tests").dependOn(&b.addRunArtifact(t).step);
}
