//! Conventional Commits validation: a port of the grammar the Rust pull used
//! (git-conventional 1.1 `Commit::parse`, winnow), reporting the same error kinds.
//! No maintained Zig Conventional Commits parser exists, so this is a small port.
const std = @import("std");

pub const ErrorKind = enum {
    missing_type,
    invalid_scope,
    missing_description,
    invalid_body,
    invalid_footer,
    invalid_format,

    pub fn message(k: ErrorKind) []const u8 {
        return switch (k) {
            .missing_type => "Missing type in the commit summary, expected `type: description`",
            .invalid_scope => "Incorrect scope syntax in commit summary, expected `type(scope): description`",
            .missing_description => "Missing description in commit summary, expected `type: description`",
            .invalid_body => "Incorrect body syntax",
            .invalid_footer => "Incorrect footer syntax",
            .invalid_format => "Incorrect conventional commit format",
        };
    }
};

/// Rust `char::is_whitespace`.
fn isWs(cp: u21) bool {
    return switch (cp) {
        0x09...0x0d, 0x20, 0x85, 0xa0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000 => true,
        else => false,
    };
}

fn decode(s: []const u8, i: usize) struct { cp: u21, len: usize } {
    const n = std.unicode.utf8ByteSequenceLength(s[i]) catch return .{ .cp = s[i], .len = 1 };
    if (i + n > s.len) return .{ .cp = s[i], .len = 1 };
    const cp = std.unicode.utf8Decode(s[i .. i + n]) catch return .{ .cp = s[i], .len = 1 };
    return .{ .cp = cp, .len = n };
}

/// `type`: one or more chars except newline, parens, ':', '!' and whitespace.
fn typeLen(s: []const u8) usize {
    var i: usize = 0;
    while (i < s.len) {
        const d = decode(s, i);
        switch (d.cp) {
            '\n', '\r', '(', ')', ':', '!' => break,
            else => if (isWs(d.cp)) break,
        }
        i += d.len;
    }
    return i;
}

fn wsLen(s: []const u8) usize {
    var i: usize = 0;
    while (i < s.len) {
        const d = decode(s, i);
        if (!isWs(d.cp)) break;
        i += d.len;
    }
    return i;
}

fn lineEnding(s: []const u8) usize {
    if (std.mem.startsWith(u8, s, "\n")) return 1;
    if (std.mem.startsWith(u8, s, "\r\n")) return 2;
    return 0;
}

/// `(token, separator)` at the start of `s` (token = "BREAKING CHANGE" | type).
fn tokenSepLen(s: []const u8) ?usize {
    var t: usize = 0;
    if (std.mem.startsWith(u8, s, "BREAKING CHANGE")) {
        t = "BREAKING CHANGE".len;
    } else {
        t = typeLen(s);
        if (t == 0) return null;
    }
    if (std.mem.startsWith(u8, s[t..], ":")) return t + 1;
    if (std.mem.startsWith(u8, s[t..], " #")) return t + 2;
    return null;
}

/// Lines with their terminators.
fn nextLine(s: []const u8, i: usize) []const u8 {
    const nl = std.mem.indexOfScalarPos(u8, s, i, '\n');
    return s[i .. if (nl) |n| n + 1 else s.len];
}

/// Null when `msg` is a valid Conventional Commit, else why not.
pub fn parse(msg: []const u8) ?ErrorKind {
    var s = msg;
    // <summary> ::= <type> ["(" <scope> ")"] ["!"] ":" <whitespace>* <text>
    const t = typeLen(s);
    if (t == 0) return .missing_type;
    s = s[t..];
    if (std.mem.startsWith(u8, s, "(")) {
        var j: usize = 1;
        while (j < s.len and s[j] != '\n' and s[j] != '\r' and s[j] != '(' and s[j] != ')') j += 1;
        if (j == 1) return .missing_type; // cut inside the summary context
        if (j < s.len and s[j] == ')') s = s[j + 1 ..];
    }
    if (std.mem.startsWith(u8, s, "!")) s = s[1..];
    if (!std.mem.startsWith(u8, s, ":")) return .missing_type;
    s = s[1..];
    s = s[wsLen(s)..];
    var text: usize = 0;
    while (text < s.len and s[text] != '\n' and s[text] != '\r') text += 1;
    if (text == 0) return .missing_type;
    s = s[text..];
    // terminated by a line ending or eof
    if (s.len > 0) {
        const n = lineEnding(s);
        if (n == 0) return .invalid_format;
        s = s[n..];
    }
    // The body MUST begin one blank line after the description.
    if (s.len > 0) {
        const n = lineEnding(s);
        if (n == 0) return .invalid_body;
        s = s[n..];
    }
    while (lineEnding(s) > 0) s = s[lineEnding(s)..];

    // optional body: up to the first footer-looking line after a blank line
    if (s.len > 0) {
        var off: usize = 0;
        var prior_empty = true;
        while (off < s.len) {
            const line = nextLine(s, off);
            if (prior_empty and tokenSepLen(std.mem.trimEnd(u8, line, " \t\r\n")) != null) break;
            prior_empty = std.mem.trim(u8, line, " \t\r\n").len == 0;
            off += line.len;
        }
        s = s[off..];
    }

    // footers: <token> <separator> <whitespace>* <value>
    while (s.len > 0) {
        const ts = tokenSepLen(s) orelse break;
        var rest = s[ts..];
        rest = rest[wsLen(rest)..];
        if (rest.len == 0) return .invalid_format; // value cut
        var off: usize = 0;
        var i: usize = 0;
        while (off < rest.len) : (i += 1) {
            const line = nextLine(rest, off);
            if (i > 0 and tokenSepLen(std.mem.trimEnd(u8, line, " \t\r\n")) != null) break;
            off += line.len;
        }
        s = rest[off..];
    }
    while (lineEnding(s) > 0) s = s[lineEnding(s)..];
    if (s.len > 0) return .invalid_format;
    return null;
}

test parse {
    try std.testing.expectEqual(@as(?ErrorKind, null), parse("feat: add thing\n"));
    try std.testing.expectEqual(@as(?ErrorKind, null), parse("feat(api)!: add thing\n\nbody text\n\nRefs: #1\n"));
    try std.testing.expectEqual(@as(?ErrorKind, .missing_type), parse("Hello World"));
    try std.testing.expectEqual(@as(?ErrorKind, .missing_type), parse("fix Improved error messages\n"));
    try std.testing.expectEqual(@as(?ErrorKind, .missing_type), parse("feat: \n"));
    try std.testing.expectEqual(@as(?ErrorKind, .invalid_body), parse("feat: x\nbody right away\n"));
    try std.testing.expectEqual(@as(?ErrorKind, null), parse("feat: x\n\nbody\nmore body\n"));
}
