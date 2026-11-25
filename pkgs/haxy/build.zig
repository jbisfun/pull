//! pull-haxy: `pull haxy`, issues on haxy's `haxy/events` branch.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const args = .{ .target = target, .optimize = optimize };
    const mod = b.addModule("haxy", .{
        .root_source_file = b.path("src/haxy.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("core", b.dependency("core", args).module("core"));
    mod.addImport("git", b.dependency("git", args).module("git"));

    const t = b.addTest(.{ .root_module = mod });
    b.step("test", "Run pull-haxy tests").dependOn(&b.addRunArtifact(t).step);
}
