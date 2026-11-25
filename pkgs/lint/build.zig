//! pull-lint: pullfile `lint`, commit message rules; `pull lint`.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const mod = b.addModule("lint", .{
        .root_source_file = b.path("src/lint.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("core", b.dependency("core", .{ .target = target, .optimize = optimize }).module("core"));

    const t = b.addTest(.{ .root_module = mod });
    b.step("test", "Run pull-lint tests").dependOn(&b.addRunArtifact(t).step);
}
