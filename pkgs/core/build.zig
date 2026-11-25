//! pull-core: pullfile.plist / local.toml model, commit identity, path routing,
//! and the process-wide Io/env helpers every other package uses.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const mod = b.addModule("core", .{
        .root_source_file = b.path("src/core.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("xml", b.dependency("xml", .{ .target = target, .optimize = optimize }).module("xml"));
    mod.addImport("toml", b.dependency("toml", .{ .target = target, .optimize = optimize }).module("toml"));

    const t = b.addTest(.{ .root_module = mod });
    b.step("test", "Run pull-core tests").dependOn(&b.addRunArtifact(t).step);
}
