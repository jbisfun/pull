//! pull-launchd: the per-workspace PTY job daemon, its client, and the
//! `pull launchctl` / `pull session` commands. Exposes the `launchd` module.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ghostty = b.dependency("ghostty", .{ .target = target, .optimize = optimize });
    const mod = b.addModule("launchd", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addImport("ghostty-vt", ghostty.module("ghostty-vt"));

    const tests = b.addTest(.{ .root_module = mod });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);

    // Test harness: a stand-in for the `pull` binary (fake env, cwd = workspace root).
    const harness = b.addExecutable(.{
        .name = "launchd-harness",
        .root_module = b.createModule(.{
            .root_source_file = b.path("harness/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "launchd", .module = mod }},
        }),
    });
    const install = b.addInstallArtifact(harness, .{});
    b.step("harness", "Build the test harness (zig-out/bin/launchd-harness)").dependOn(&install.step);
}
