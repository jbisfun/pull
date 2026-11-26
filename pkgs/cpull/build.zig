//! pull-cpull: `pull cpull`, issues on cpull's `cpull/events` branch.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const args = .{ .target = target, .optimize = optimize };
    const mod = b.addModule("cpull", .{
        .root_source_file = b.path("src/cpull.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("core", b.dependency("core", args).module("core"));
    mod.addImport("git", b.dependency("git", args).module("git"));

    const t = b.addTest(.{ .root_module = mod });
    b.step("test", "Run pull-cpull tests").dependOn(&b.addRunArtifact(t).step);
}
