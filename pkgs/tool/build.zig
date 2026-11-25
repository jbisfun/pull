//! pull-tool: pullfile `tool` packages, managed by the jbisfun/tool CLI.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const mod = b.addModule("tool", .{
        .root_source_file = b.path("src/tool.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("core", b.dependency("core", .{ .target = target, .optimize = optimize }).module("core"));

    const t = b.addTest(.{ .root_module = mod });
    b.step("test", "Run pull-tool tests").dependOn(&b.addRunArtifact(t).step);
}
