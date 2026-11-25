//! The workspace environment: pullfile `env`, then local.toml `[env]` on top.
const std = @import("std");
const core = @import("core");
const sys = core.sys;
const plist = core.plist;
const Allocator = std.mem.Allocator;
const EnvVar = core.EnvVar;

/// Section key, in the pullfile and in local.toml.
pub const SECTION = "env";

/// Environment for the workspace. Values expand `~`, `$VAR` and `${VAR}` (including
/// `$PULL_ROOT`); relative PATH entries are relative to the pullfile root.
pub const Env = struct {
    /// Prepended to PATH, first entry wins.
    path: []const []const u8 = &.{},
    /// Exported variables (toolchain selection, etc.).
    vars: plist.Map([]const u8) = .{},
};

/// Sorted string map (Rust BTreeMap<String, String>).
const Vars = struct {
    keys: std.ArrayList([]const u8) = .empty,
    values: std.ArrayList([]const u8) = .empty,

    fn get(v: Vars, k: []const u8) ?[]const u8 {
        for (v.keys.items, v.values.items) |key, val| if (std.mem.eql(u8, key, k)) return val;
        return null;
    }

    fn put(v: *Vars, a: Allocator, k: []const u8, val: []const u8) !void {
        for (v.keys.items, 0..) |key, i| if (std.mem.eql(u8, key, k)) {
            v.values.items[i] = val;
            return;
        };
        var i: usize = 0;
        while (i < v.keys.items.len and std.mem.lessThan(u8, v.keys.items[i], k)) i += 1;
        try v.keys.insert(a, i, k);
        try v.values.insert(a, i, val);
    }
};

/// Resolved variables to export, in order. `layers` go from shared to most specific
/// (pullfile, then local.toml). `PATH` is complete (new entries + current PATH).
pub fn resolve(a: Allocator, root: []const u8, layers: []const Env) ![]EnvVar {
    var vars: Vars = .{};
    try vars.put(a, "PULL_ROOT", root);
    for (layers) |env| {
        // BTreeMap order within a layer.
        const idx = try a.alloc(usize, env.vars.keys.len);
        for (idx, 0..) |*x, i| x.* = i;
        std.mem.sort(usize, idx, env.vars.keys, struct {
            fn lt(keys: []const []const u8, x: usize, y: usize) bool {
                return std.mem.lessThan(u8, keys[x], keys[y]);
            }
        }.lt);
        for (idx) |i| try vars.put(a, env.vars.keys[i], try expand(a, env.vars.values[i], vars));
    }

    // Local entries first so a machine can shadow the shared toolchain.
    var entries: std.ArrayList([]const u8) = .empty;
    var li = layers.len;
    while (li > 0) {
        li -= 1;
        for (layers[li].path) |p| {
            const e = try expand(a, p, vars);
            const full = if (std.fs.path.isAbsolute(e)) e else try std.fs.path.join(a, &.{ root, e });
            if (!contains(entries.items, full)) try entries.append(a, full);
        }
    }
    var out: std.ArrayList(EnvVar) = .empty;
    for (vars.keys.items, vars.values.items) |k, v| try out.append(a, .{ .key = k, .value = v });
    if (entries.items.len > 0) {
        var all: std.ArrayList([]const u8) = .empty;
        try all.appendSlice(a, entries.items);
        if (sys.getenv("PATH")) |cur| {
            var it = std.mem.splitScalar(u8, cur, ':');
            while (it.next()) |p| if (!contains(entries.items, p)) try all.append(a, p);
        }
        for (entries.items) |e| if (std.mem.indexOfScalar(u8, e, ':') != null)
            return sys.fail("PATH entry contains a separator", .{});
        try out.append(a, .{ .key = "PATH", .value = try std.mem.join(a, ":", all.items) });
    }
    return out.items;
}

fn contains(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

fn isVarChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// shellexpand::full_with_context_no_errors: `$VAR`, `${VAR}`, `${VAR:-default}`
/// (from `vars`, then the process env; unknown ones stay as written), `$$` -> `$`,
/// then a leading `~` / `~/`.
fn expand(a: Allocator, s: []const u8, vars: Vars) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        const d = std.mem.indexOfScalarPos(u8, s, i, '$') orelse {
            try out.appendSlice(a, s[i..]);
            break;
        };
        try out.appendSlice(a, s[i..d]);
        const rest = s[d..];
        if (rest.len > 1 and rest[1] == '{') {
            const close = std.mem.indexOfScalar(u8, rest, '}') orelse {
                try out.appendSlice(a, rest[0..2]);
                i = d + 2;
                continue;
            };
            var name_end = close;
            var default: ?[]const u8 = null;
            if (std.mem.indexOf(u8, rest[0..close], ":-")) |ds| if (ds != 2) {
                default = rest[ds + 2 .. close];
                name_end = ds;
            };
            const name = rest[2..name_end];
            if (lookup(vars, name)) |v| {
                try out.appendSlice(a, v);
            } else if (default) |df| {
                try out.appendSlice(a, df);
            } else try out.appendSlice(a, rest[0 .. close + 1]);
            i = d + close + 1;
        } else if (rest.len > 1 and isVarChar(rest[1])) {
            var end: usize = 1;
            while (end < rest.len and isVarChar(rest[end])) end += 1;
            const name = rest[1..end];
            if (lookup(vars, name)) |v| try out.appendSlice(a, v) else try out.appendSlice(a, rest[0..end]);
            i = d + end;
        } else {
            try out.append(a, '$');
            i = if (rest.len > 1 and rest[1] == '$') d + 2 else d + 1;
        }
    }
    const e = out.items;
    if (e.len > 0 and e[0] == '~' and (e.len == 1 or e[1] == '/')) {
        if (sys.home()) |h| return std.mem.concat(a, u8, &.{ h, e[1..] });
    }
    return e;
}

fn lookup(vars: Vars, name: []const u8) ?[]const u8 {
    return vars.get(name) orelse sys.getenv(name);
}

/// POSIX shell `export` lines (bash/zsh/sh; what direnv's `eval` expects).
pub fn exports(a: Allocator, vars: []const EnvVar) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (vars) |v| {
        const q = quote(a, v.value) catch return sys.fail("can't quote value of {s}", .{v.key});
        try out.print(a, "export {s}={s}\n", .{ v.key, q });
    }
    return out.items;
}

/// direnv `.envrc` that loads the pullfile env and reloads when it changes.
pub const ENVRC = "# generated by `pull env --envrc`: the environment lives in pullfile.plist\n" ++
    "watch_file pullfile.plist local.toml\n" ++
    "eval \"$(pull env)\"\n";

// ---------------------------------------------------------------- shlex::try_quote

fn unquotedOk(c: u8) bool {
    return switch (c) {
        '+', '-', '.', '/', ':', '@', ']', '_', '0'...'9', 'A'...'Z', 'a'...'z' => true,
        else => false,
    };
}

fn singleQuotedOk(c: u8) bool {
    return c != '\'' and c != '^' and c != '\\';
}

fn doubleQuotedOk(c: u8) bool {
    return c != '`' and c != '$' and c != '!' and c != '^';
}

const Strategy = enum { unquoted, single, double };

/// A port of the shlex crate's quoting (1.3): minimal chunks, unquoted when
/// possible, else single quotes, else double quotes with backslashes.
pub fn quote(a: Allocator, s: []const u8) ![]const u8 {
    if (s.len == 0) return "''";
    if (std.mem.indexOfScalar(u8, s, 0) != null) return error.Nul;
    var out: std.ArrayList(u8) = .empty;
    var rest = s;
    while (rest.len > 0) {
        const U: u8 = 1;
        const S: u8 = 2;
        const D: u8 = 4;
        var prev: u8 = U | S | D;
        var i: usize = 0;
        if (rest[0] == '^') {
            prev = S;
            i = 1;
        }
        while (i < rest.len) : (i += 1) {
            const c = rest[i];
            var cur = prev;
            if (c >= 0x80) {
                cur &= ~U;
            } else {
                if (!unquotedOk(c)) cur &= ~U;
                if (!singleQuotedOk(c)) cur &= ~S;
                if (!doubleQuotedOk(c)) cur &= ~D;
            }
            if (cur == 0) break;
            prev = cur;
        }
        const strat: Strategy = if (prev & U != 0) .unquoted else if (prev & S != 0) .single else .double;
        if (i == rest.len and strat == .unquoted and out.items.len == 0) return s;
        const chunk = rest[0..i];
        rest = rest[i..];
        switch (strat) {
            .unquoted => try out.appendSlice(a, chunk),
            .single => {
                try out.append(a, '\'');
                try out.appendSlice(a, chunk);
                try out.append(a, '\'');
            },
            .double => {
                try out.append(a, '"');
                for (chunk) |c| {
                    if (c == '$' or c == '`' or c == '"' or c == '\\') try out.append(a, '\\');
                    try out.append(a, c);
                }
                try out.append(a, '"');
            },
        }
    }
    return out.items;
}

test "layers expand and path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const shared: Env = .{
        .path = &.{ "bin", "$TOOLS", "~/x" },
        .vars = .{ .keys = &.{ "TOOLS", "GOTOOLCHAIN" }, .values = &.{ "$PULL_ROOT/tools", "local" } },
    };
    const local: Env = .{
        .path = &.{"/opt/mine"},
        .vars = .{ .keys = &.{"GOTOOLCHAIN"}, .values = &.{"go1.27.4"} },
    };
    const v = try resolve(a, "/w", &.{ shared, local });
    try std.testing.expectEqualStrings("GOTOOLCHAIN", v[0].key);
    try std.testing.expectEqualStrings("go1.27.4", v[0].value);
    try std.testing.expectEqualStrings("PULL_ROOT", v[1].key);
    try std.testing.expectEqualStrings("/w/tools", v[2].value);
    const home = sys.home().?;
    const want = try std.fmt.allocPrint(a, "/opt/mine:/w/bin:/w/tools:{s}/x", .{home});
    try std.testing.expect(std.mem.startsWith(u8, v[3].value, want));
    try std.testing.expectEqualStrings("\"it's\"", try quote(a, "it's"));
    try std.testing.expectEqualStrings("'$HOME'", try quote(a, "$HOME"));
    try std.testing.expectEqualStrings("/a/b:c", try quote(a, "/a/b:c"));
    try std.testing.expectEqualStrings("''", try quote(a, ""));
    try std.testing.expectEqualStrings("'a b'", try quote(a, "a b"));
}
