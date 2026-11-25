//! pull-ignore: pullfile `ignore` patterns kept in every repo's .git/info/exclude.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const mod = b.addModule("ignore", .{
        .root_source_file = b.path("src/ignore.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("core", b.dependency("core", .{ .target = target, .optimize = optimize }).module("core"));

    const t = b.addTest(.{ .root_module = mod });
    b.step("test", "Run pull-ignore tests").dependOn(&b.addRunArtifact(t).step);
}
