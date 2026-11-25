//! A gitignore-aware directory walk, like the `ignore` crate's `WalkBuilder` with
//! `hidden(true)`, `git_ignore`, `git_exclude`, `git_global` and an override glob
//! (what the Rust server used), on sweep's ignore stacks:
//!
//! - entries come depth first in directory order; symlinks are not followed or
//!   listed;
//! - `.gitignore`/`.ignore` files, `.git/info/exclude` and the global excludes file
//!   apply only inside a git repository, and only up to its top: a nested repo
//!   starts a fresh stack (the walk root's ancestors up to their repo count too);
//! - hidden entries are skipped;
//! - the override glob decides first, relative to the walk root: a match includes
//!   the entry (ignored or hidden), a `!glob` match excludes it, and a file no
//!   whitelist glob matches is skipped.
const std = @import("std");
const sweep = @import("sweep");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Visit = enum { more, stop };

/// One `--glob`-style override (`OverrideBuilder::add`).
const Override = struct {
    set: sweep.Set,
    cache: sweep.Set.Cache,
    negated: bool,

    /// .include / .exclude / null (undecided).
    fn decide(o: *Override, rel: []const u8, kind: sweep.Kind) ?bool {
        if (o.set.last(&o.cache, rel, kind) != null) return !o.negated;
        if (!o.negated and kind == .file) return false;
        return null;
    }
};

pub const Walk = struct {
    a: Allocator,
    io: Io,
    override: ?Override = null,

    /// Error text for a glob that doesn't compile is in `msg`.
    pub fn init(a: Allocator, io: Io, glob: ?[]const u8, msg: *[]const u8) !Walk {
        var w: Walk = .{ .a = a, .io = io };
        const g = glob orelse return w;
        const line = sweep.gitignore.parseLine(g) orelse return w;
        var b: sweep.Set.Builder = .init(a);
        _ = b.add(line.pattern, line.entry) catch |e| {
            msg.* = try std.fmt.allocPrint(a, "error parsing glob '{s}': {s}", .{ g, switch (e) {
                error.PatternTooLong => "pattern too long",
                error.OutOfMemory => return error.OutOfMemory,
                else => if (unclosedBracket(line.pattern)) "unclosed character class; missing ']'" else "invalid pattern",
            } });
            return error.InvalidGlob;
        };
        const set = try b.build();
        w.override = .{ .set = set, .cache = undefined, .negated = line.negated };
        return w;
    }

    /// Visit every file under `root` (absolute), or `root` itself if it is a file.
    /// `visit(ctx, abs_path)`.
    pub fn run(w: *Walk, root: []const u8, ctx: anytype, comptime visit: fn (@TypeOf(ctx), []const u8) anyerror!Visit) !void {
        if (w.override) |*o| o.cache = try .init(w.a, &o.set, .{});
        const st = Io.Dir.cwd().statFile(w.io, root, .{}) catch return;
        if (st.kind != .directory) {
            if (st.kind == .file) _ = try visit(ctx, root);
            return;
        }
        var seg = try Segment.forRoot(w, root);
        defer if (seg) |*s| s.deinit();
        _ = try w.dir(root, "", if (seg) |*s| s else null, if (seg) |s| s.root_base else "", ctx, visit);
    }

    const Segment = struct {
        stack: sweep.ignore.Stack,
        root_base: []const u8 = "",

        fn init(w: *Walk, repo: []const u8) !Segment {
            var s: Segment = .{ .stack = .init(w.a, .{ .unreadable = .skip, .file_names = &.{ ".gitignore", ".ignore" } }) };
            const cwd = Io.Dir.cwd();
            if (try globalExcludes(w.a)) |p| try s.stack.addFile(w.io, cwd, p, .{ .group = .file, .source = p }, .follow);
            const ex = try std.fs.path.join(w.a, &.{ repo, ".git", "info", "exclude" });
            try s.stack.addFile(w.io, cwd, ex, .{ .group = .file, .source = "info/exclude" }, .follow);
            return s;
        }

        /// The segment of the repo `root` is in (its ignore files from the repo top
        /// down to `root`), or null outside any repo.
        fn forRoot(w: *Walk, root: []const u8) !?Segment {
            var top: []const u8 = root;
            while (true) {
                if (hasGit(w, top)) break;
                top = std.fs.path.dirname(top) orelse return null;
            }
            var s = try Segment.init(w, top);
            errdefer s.deinit();
            const below = std.mem.trimStart(u8, root[top.len..], "/");
            var base: []const u8 = "";
            var parts = std.mem.tokenizeScalar(u8, below, '/');
            while (true) {
                const at = if (base.len == 0) top else try std.fmt.allocPrint(w.a, "{s}/{s}", .{ top, base });
                var d = Io.Dir.cwd().openDir(w.io, at, .{}) catch break;
                defer d.close(w.io);
                try s.stack.addDirectory(w.io, d, base);
                const c = parts.next() orelse break;
                base = if (base.len == 0) c else try std.fmt.allocPrint(w.a, "{s}/{s}", .{ base, c });
            }
            s.root_base = below;
            return s;
        }

        fn deinit(s: *Segment) void {
            s.stack.deinit();
        }
    };

    fn hasGit(w: *Walk, dir_path: []const u8) bool {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const p = std.fmt.bufPrint(&buf, "{s}/.git", .{dir_path}) catch return false;
        Io.Dir.cwd().access(w.io, p, .{}) catch return false;
        return true;
    }

    /// Walk directory `abs` (relative path `rel` from the walk root; `base` its
    /// path in `seg`'s repo).
    fn dir(w: *Walk, abs: []const u8, rel: []const u8, seg: ?*Segment, base: []const u8, ctx: anytype, comptime visit: anytype) !Visit {
        var d = Io.Dir.cwd().openDir(w.io, abs, .{ .iterate = true }) catch return .more;
        defer d.close(w.io);
        var it = d.iterate();
        while (it.next(w.io) catch null) |e| {
            var kind = e.kind;
            if (kind == .unknown) {
                const st = d.statFile(w.io, e.name, .{ .follow_symlinks = false }) catch continue;
                kind = st.kind;
            }
            if (kind != .file and kind != .directory) continue;
            const k: sweep.Kind = if (kind == .directory) .dir else .file;
            const child_rel = if (rel.len == 0) e.name else try std.fmt.allocPrint(w.a, "{s}/{s}", .{ rel, e.name });
            const child_base = if (base.len == 0) e.name else try std.fmt.allocPrint(w.a, "{s}/{s}", .{ base, e.name });
            const decided: ?bool = if (w.override) |*o| o.decide(child_rel, k) else null;
            if (decided) |include| {
                if (!include) continue;
            } else {
                if (seg) |s| if (s.stack.match(child_base, k).excluded) continue;
                if (e.name[0] == '.') continue;
            }
            const child_abs = try std.fmt.allocPrint(w.a, "{s}/{s}", .{ abs, e.name });
            if (k == .file) {
                if (try visit(ctx, child_abs) == .stop) return .stop;
                continue;
            }
            if (hasGit(w, child_abs)) {
                var sub = try Segment.init(w, child_abs);
                defer sub.deinit();
                var cd = d.openDir(w.io, e.name, .{}) catch continue;
                sub.stack.addDirectory(w.io, cd, "") catch {};
                cd.close(w.io);
                if (try w.dir(child_abs, child_rel, &sub, "", ctx, visit) == .stop) return .stop;
            } else if (seg) |s| {
                const mark = s.stack.mark();
                defer s.stack.popTo(mark);
                var cd = d.openDir(w.io, e.name, .{}) catch continue;
                s.stack.addDirectory(w.io, cd, child_base) catch {};
                cd.close(w.io);
                if (try w.dir(child_abs, child_rel, s, child_base, ctx, visit) == .stop) return .stop;
            } else {
                if (try w.dir(child_abs, child_rel, null, "", ctx, visit) == .stop) return .stop;
            }
        }
        return .more;
    }
};

fn unclosedBracket(p: []const u8) bool {
    const open = std.mem.lastIndexOfScalar(u8, p, '[') orelse return false;
    return std.mem.indexOfScalarPos(u8, p, open, ']') == null;
}

/// git's default `core.excludesFile` ($XDG_CONFIG_HOME/git/ignore or
/// ~/.config/git/ignore), if it exists.
fn globalExcludes(a: Allocator) !?[]const u8 {
    const core = @import("core");
    const base = if (core.sys.getenv("XDG_CONFIG_HOME")) |x| (if (x.len > 0) x else null) else null;
    const p = if (base) |b| try std.fs.path.join(a, &.{ b, "git", "ignore" }) else blk: {
        const h = core.sys.home() orelse return null;
        break :blk try std.fs.path.join(a, &.{ h, ".config", "git", "ignore" });
    };
    return if (core.sys.isFile(p)) p else null;
}
