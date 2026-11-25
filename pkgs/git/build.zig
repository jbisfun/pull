//! pull-git: clone/sync, status, staging, the one-message commit across repos,
//! push. Built on xit (a Zig git implementation, vendored with two small patches,
//! see vendor/xit) and sweep (git's ignore rules).
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const mod = b.addModule("git", .{
        .root_source_file = b.path("src/git.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("core", b.dependency("core", .{ .target = target, .optimize = optimize }).module("core"));
    mod.addImport("xit", b.dependency("xit", .{}).module("xit"));
    mod.addImport("sweep", b.dependency("sweep", .{ .target = target, .optimize = optimize }).module("sweep"));

    const t = b.addTest(.{ .root_module = mod });
    b.step("test", "Run pull-git tests").dependOn(&b.addRunArtifact(t).step);
}
