//! pull: multi-repo git wrapper driven by pullfile.plist.
//!
//! The core packages (pkgs/core, pkgs/git) are always built; every other feature is
//! its own package, compiled in only when selected (they never import each other and
//! meet only in src/workspace.zig):
//!
//!   zig build -Dfeatures=env,hooks           # a lean pull
//!   zig build                                # default features
//!
//! `mcp` without `launchd` builds the MCP server without its session/job tools, and
//! without `haxy` without its haxy_* tools.
const std = @import("std");

/// Every feature this build knows, sorted (also the `features` order printed).
const all_features = [_][]const u8{ "conventional", "env", "haxy", "hooks", "https", "ignore", "launchd", "lint", "mcp", "ssh", "tool", "worktree" };
/// Feature packages (pkgs/<name>) compiled in when their feature is on.
const packages = [_][]const u8{ "env", "hooks", "lint", "ignore", "worktree", "tool", "launchd", "haxy", "mcp" };
const default_features = "conventional,env,haxy,hooks,https,ignore,launchd,lint,mcp,ssh,tool,worktree";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const spec = b.option([]const u8, "features", "Comma-separated features (default: " ++ default_features ++ ")") orelse default_features;

    var enabled: std.array_hash_map.String(void) = .empty;
    var it = std.mem.tokenizeAny(u8, spec, ", ");
    while (it.next()) |f| {
        var known = false;
        for (all_features) |k| known = known or std.mem.eql(u8, k, f);
        if (!known) std.debug.panic("unknown feature `{s}` (known: {s})", .{ f, std.mem.join(b.allocator, ",", &all_features) catch "" });
        enabled.put(b.allocator, f, {}) catch @panic("OOM");
    }
    // `conventional` is part of the lint feature.
    if (enabled.contains("conventional")) enabled.put(b.allocator, "lint", {}) catch @panic("OOM");

    const options = b.addOptions();
    var names: std.ArrayList([]const u8) = .empty;
    for (all_features) |f| {
        const on = enabled.contains(f);
        options.addOption(bool, f, on);
        if (on) names.append(b.allocator, f) catch @panic("OOM");
    }
    options.addOption([]const []const u8, "features", names.items);
    options.addOption([]const u8, "version", "0.1.0");

    const dep_args = .{ .target = target, .optimize = optimize };
    const core = b.dependency("core", dep_args).module("core");
    const git = b.dependency("git", dep_args).module("git");

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addOptions("build_options", options);
    mod.addImport("core", core);
    mod.addImport("git", git);
    mod.addImport("clap", b.dependency("clap", dep_args).module("clap"));

    const test_step = b.step("test", "Run unit tests of the bin and every built package");
    for (packages) |p| {
        if (!enabled.contains(p)) continue;
        const dep = (if (std.mem.eql(u8, p, "mcp"))
            b.lazyDependency(p, .{ .target = target, .optimize = optimize, .sessions = enabled.contains("launchd"), .haxy = enabled.contains("haxy") })
        else
            b.lazyDependency(p, dep_args)) orelse
            std.debug.panic("feature `{s}` needs pkgs/{s} in build.zig.zon", .{ p, p });
        const m = dep.module(p);
        mod.addImport(p, m);
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = m })).step);
    }
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = core })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = git })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod })).step);

    const exe = b.addExecutable(.{ .name = "pull", .root_module = mod });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("run", "Run pull (arguments after --)").dependOn(&run.step);
}
