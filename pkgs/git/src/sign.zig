//! Commit objects as libgit2 writes them (`commit_create_buffer` + `commit_signed`),
//! GPG-signed the way git does for gpg.program: a detached, armored signature over
//! the unsigned buffer, stored in a `gpgsig` header.
const std = @import("std");
const core = @import("core");
const sys = core.sys;
const Allocator = std.mem.Allocator;

pub fn fmtTz(offset_min: i32) [5]u8 {
    var out: [5]u8 = undefined;
    const sign: u8 = if (offset_min < 0) '-' else '+';
    const m: u32 = @abs(offset_min);
    _ = std.fmt.bufPrint(&out, "{c}{d:0>2}{d:0>2}", .{ sign, m / 60, m % 60 }) catch unreachable;
    return out;
}

/// libgit2 `extract_trimmed`: strip leading/trailing "crud" from signature parts.
fn trimCrud(s: []const u8) []const u8 {
    const crud = " \t\n\x0b\x0c\r.,:;<>\"\\'";
    return std.mem.trim(u8, s, crud);
}

/// The commit object content, signed with gpg when `id.sign`.
pub fn commitBuffer(
    a: Allocator,
    id: core.Identity,
    tree: [40]u8,
    parent: ?[40]u8,
    msg: []const u8,
    secs: i64,
    offset_min: i32,
) ![]const u8 {
    const tz = fmtTz(offset_min);
    const who = try std.fmt.allocPrint(a, "{s} <{s}> {d} {s}", .{ trimCrud(id.name), trimCrud(id.email), secs, &tz });
    var header: std.ArrayList(u8) = .empty;
    try header.print(a, "tree {s}\n", .{&tree});
    if (parent) |p| try header.print(a, "parent {s}\n", .{&p});
    try header.print(a, "author {s}\ncommitter {s}\n", .{ who, who });
    const unsigned = try std.fmt.allocPrint(a, "{s}\n{s}", .{ header.items, msg });
    if (!id.sign) return unsigned;

    const signature = try gpgSign(a, id, unsigned);
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, header.items);
    try out.appendSlice(a, "gpgsig ");
    // Continuation lines of a header field start with a space.
    const sig = std.mem.trimEnd(u8, signature, "\n");
    for (sig, 0..) |c, i| {
        try out.append(a, c);
        if (c == '\n' and i + 1 <= sig.len) try out.append(a, ' ');
    }
    try out.append(a, '\n');
    try out.append(a, '\n');
    try out.appendSlice(a, msg);
    return out.items;
}

/// Same protocol git uses for gpg.program: `--status-fd=2 -bsa [-u KEY]`.
fn gpgSign(a: Allocator, id: core.Identity, content: []const u8) ![]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ id.gpg_program, "--status-fd=2", "-bsa" });
    if (id.signing_key) |k| try argv.appendSlice(a, &.{ "-u", k });
    const o = sys.run(a, argv.items, .{ .stdin = content }) catch |e|
        return sys.context(e, "running {s}", .{id.gpg_program});
    if (!o.ok() or std.mem.indexOf(u8, o.stderr, "[GNUPG:] SIG_CREATED ") == null)
        return sys.fail("gpg failed to sign:\n{s}", .{o.stderr});
    return o.stdout;
}

test "unsigned buffer layout" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const id: core.Identity = .{ .name = "jp", .email = "", .sign = false, .signing_key = null, .gpg_program = "gpg" };
    const tree: [40]u8 = @splat('a');
    const buf = try commitBuffer(arena.allocator(), id, tree, null, "msg\n", 100, -300);
    const want = try std.fmt.allocPrint(arena.allocator(), "tree {s}\nauthor jp <> 100 -0500\ncommitter jp <> 100 -0500\n\nmsg\n", .{&tree});
    try std.testing.expectEqualStrings(want, buf);
}
