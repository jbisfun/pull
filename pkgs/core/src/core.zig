//! pull-core: the workspace model shared by every pull package.
pub const sys = @import("sys.zig");
pub const plist = @import("plist.zig");
pub const paths = @import("paths.zig");
pub const message = @import("message.zig");
const pullfile = @import("pullfile.zig");

pub const PULLFILE = pullfile.PULLFILE;
pub const LOCAL = pullfile.LOCAL;
pub const Pullfile = pullfile.Pullfile;
pub const Repo = pullfile.Repo;
pub const IdentityPolicy = pullfile.IdentityPolicy;
pub const EmailPolicy = pullfile.EmailPolicy;
pub const Local = pullfile.Local;
pub const OrgIdentity = pullfile.OrgIdentity;
pub const Identity = pullfile.Identity;
pub const resolveIdentity = pullfile.resolveIdentity;
pub const findRoot = pullfile.findRoot;
pub const configDir = pullfile.configDir;

/// Environment variables as an ordered list of (key, value), like Rust's
/// `Vec<(String, String)>` the env provider returns.
pub const EnvVar = struct { key: []const u8, value: []const u8 };

/// The workspace env (`pull env`) for `root`, re-read on every call: what the bin
/// injects into long-running servers (launchd daemon, MCP), so those packages need
/// neither the env nor the tool feature.
pub const EnvProvider = *const fn (std.mem.Allocator, []const u8) []const EnvVar;
const std = @import("std");

test {
    _ = plist;
    _ = paths;
    _ = message;
    _ = pullfile;
}
