//! Commit message cleanup: a port of libgit2's `git_message_prettify` (what the Rust
//! pull ran on every message via `git2::message_prettify(msg, None)`): trailing
//! whitespace removed from each line, runs of blank lines collapsed to one, leading
//! and trailing blank lines dropped, and a final newline added.
const std = @import("std");

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == 0x0b or c == 0x0c or c == '\r';
}

pub fn prettify(a: std.mem.Allocator, message: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var empty_lines: usize = 0;
    var i: usize = 0;
    while (i < message.len) {
        const nl = std.mem.indexOfScalarPos(u8, message, i, '\n');
        const line_len = if (nl) |n| n - i + 1 else message.len - i;
        var trimmed = line_len;
        while (trimmed > 0 and isSpace(message[i + trimmed - 1])) trimmed -= 1;
        if (trimmed == 0) {
            empty_lines += 1;
        } else {
            if (empty_lines > 0 and out.items.len > 0) try out.append(a, '\n');
            empty_lines = 0;
            try out.appendSlice(a, message[i .. i + trimmed]);
            try out.append(a, '\n');
        }
        i += line_len;
    }
    return out.items;
}

test prettify {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("subject\n", try prettify(a, "subject"));
    try std.testing.expectEqualStrings("subject\n\nbody\n", try prettify(a, "\n\nsubject  \n\n\n\nbody\t\n\n"));
    try std.testing.expectEqualStrings("", try prettify(a, "  \n \n"));
}
