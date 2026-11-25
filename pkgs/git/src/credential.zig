//! https credentials through git's credential helpers (`git credential fill`),
//! which xit's http transport doesn't consult. git CLI fallback by design: the
//! helpers (gh, libsecret, store) are configured for git.
const std = @import("std");
const core = @import("core");
const sys = core.sys;
const Allocator = std.mem.Allocator;

pub const Credential = struct {
    protocol: []const u8,
    host: []const u8,
    username: []const u8,
    password: []const u8,

    /// `url` with `user:password@` in its authority (percent-encoded).
    pub fn url(c: Credential, a: Allocator, plain: []const u8) ![]const u8 {
        const sep = std.mem.indexOf(u8, plain, "://") orelse return plain;
        const rest = plain[sep + 3 ..];
        const host_start = if (std.mem.indexOfScalar(u8, rest, '@')) |at| blk: {
            const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
            break :blk if (at < slash) at + 1 else 0;
        } else 0;
        var w: std.Io.Writer.Allocating = .init(a);
        try w.writer.writeAll(plain[0 .. sep + 3]);
        try std.Uri.Component.percentEncode(&w.writer, c.username, isUnreserved);
        try w.writer.writeByte(':');
        try std.Uri.Component.percentEncode(&w.writer, c.password, isUnreserved);
        try w.writer.writeByte('@');
        try w.writer.writeAll(rest[host_start..]);
        return w.toOwnedSlice();
    }

    fn describe(c: Credential, a: Allocator) ![]const u8 {
        return std.fmt.allocPrint(a, "protocol={s}\nhost={s}\nusername={s}\npassword={s}\n\n", .{ c.protocol, c.host, c.username, c.password });
    }

    /// Tell the helpers the credential worked (`git credential approve`).
    pub fn approve(c: Credential, a: Allocator) void {
        const input = c.describe(a) catch return;
        _ = sys.run(a, &.{ "git", "credential", "approve" }, .{ .stdin = input }) catch {};
    }

    /// ... or that it didn't (`git credential reject`).
    pub fn reject(c: Credential, a: Allocator) void {
        const input = c.describe(a) catch return;
        _ = sys.run(a, &.{ "git", "credential", "reject" }, .{ .stdin = input }) catch {};
    }
};

fn isUnreserved(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~';
}

/// Ask git's credential helpers for `url`'s protocol and host.
pub fn fill(a: Allocator, url: []const u8) !Credential {
    const sep = std.mem.indexOf(u8, url, "://") orelse return sys.fail("authentication required for {s}", .{url});
    const protocol = url[0..sep];
    var rest = url[sep + 3 ..];
    if (std.mem.indexOfScalar(u8, rest, '/')) |s| rest = rest[0..s];
    var username: ?[]const u8 = null;
    if (std.mem.lastIndexOfScalar(u8, rest, '@')) |at| {
        username = rest[0..at];
        rest = rest[at + 1 ..];
    }
    var input: std.ArrayList(u8) = .empty;
    try input.print(a, "protocol={s}\nhost={s}\n", .{ protocol, rest });
    if (username) |u| try input.print(a, "username={s}\n", .{u});
    try input.appendSlice(a, "\n");
    const o = sys.run(a, &.{ "git", "credential", "fill" }, .{ .stdin = input.items }) catch |e|
        return sys.context(e, "git credential fill", .{});
    if (!o.ok()) return sys.fail("git credential fill: {s}", .{std.mem.trim(u8, o.stderr, " \r\n")});
    var c: Credential = .{ .protocol = protocol, .host = rest, .username = username orelse "", .password = "" };
    var it = std.mem.splitScalar(u8, o.stdout, '\n');
    while (it.next()) |line| {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const k = line[0..eq];
        const v = line[eq + 1 ..];
        if (std.mem.eql(u8, k, "username")) c.username = v;
        if (std.mem.eql(u8, k, "password")) c.password = v;
        if (std.mem.eql(u8, k, "host")) c.host = v;
        if (std.mem.eql(u8, k, "protocol")) c.protocol = v;
    }
    if (c.password.len == 0) return sys.fail("no credentials for {s}://{s}", .{ protocol, rest });
    return c;
}

test "credential url" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const c: Credential = .{ .protocol = "https", .host = "github.com", .username = "x-access-token", .password = "t/k" };
    try std.testing.expectEqualStrings("https://x-access-token:t%2Fk@github.com/a/b", try c.url(arena.allocator(), "https://github.com/a/b"));
}
