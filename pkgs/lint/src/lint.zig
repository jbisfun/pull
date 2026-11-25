//! Commit message rules: the pullfile `lint` section.
const std = @import("std");
const conventional = @import("conventional.zig");
const Allocator = std.mem.Allocator;

/// Pullfile section key.
pub const SECTION = "lint";

pub const Lint = struct {
    /// Subject line only; no body.
    no_description: bool = false,
    max_subject_length: ?u64 = null,
    /// Must parse as a Conventional Commit.
    conventional: bool = false,
    no_trailing_period: bool = false,
};

/// Returns a list of violations (empty = ok). `msg` should already be prettified.
pub fn check(a: Allocator, rules: Lint, msg: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, msg, '\n');
    const subject = std.mem.trimEnd(u8, lines.first(), " \t\r\n");
    if (std.mem.trim(u8, subject, " \t\r\n").len == 0) {
        try out.append(a, "empty commit message");
        return out.items;
    }
    if (rules.no_description) {
        while (lines.next()) |l| {
            if (std.mem.trim(u8, l, " \t\r\n").len > 0) {
                try out.append(a, "no_description: message must be a single subject line");
                break;
            }
        }
    }
    if (rules.max_subject_length) |max| {
        const n: u64 = std.unicode.utf8CountCodepoints(subject) catch subject.len;
        if (n > max) try out.append(a, try std.fmt.allocPrint(a, "max_subject_length: subject is {d} chars (max {d})", .{ n, max }));
    }
    if (rules.no_trailing_period and std.mem.endsWith(u8, subject, "."))
        try out.append(a, "no_trailing_period: subject ends with '.'");
    if (rules.conventional) {
        if (conventional.parse(msg)) |kind| try out.append(a, try std.fmt.allocPrint(a, "conventional: {s}", .{kind.message()}));
    }
    return out.items;
}

test "rules" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r: Lint = .{ .no_description = true, .max_subject_length = 20, .conventional = true, .no_trailing_period = true };
    try std.testing.expectEqual(@as(usize, 0), (try check(a, r, "feat: add thing\n")).len);
    try std.testing.expectEqual(@as(usize, 1), (try check(a, r, "feat: add thing\n\nbody\n")).len);
    try std.testing.expectEqual(@as(usize, 2), (try check(a, r, "add thing.\n")).len);
    try std.testing.expectEqual(@as(usize, 1), (try check(a, r, "feat: a very long subject line here\n")).len);
    const v = try check(a, .{ .max_subject_length = 4 }, "abcde\n");
    try std.testing.expectEqualStrings("max_subject_length: subject is 5 chars (max 4)", v[0]);
    try std.testing.expectEqualStrings("empty commit message", (try check(a, .{}, ""))[0]);
}

test {
    _ = conventional;
}
