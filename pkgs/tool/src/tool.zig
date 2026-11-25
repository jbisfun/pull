//! Workspace packages: the pullfile `tool` section is a Brewfile-shaped package list
//! (`tap`, `brew`) that jbisfun/tool pours from Linuxbrew bottles into its shared
//! store and links into the workspace profile `.pull/tool/`. The env adds the
//! profile's `bin`/`sbin` to PATH.
//!
//! The Rust pull linked the `tool` library; here pull runs the `tool` CLI
//! (`tool --file BREWFILE --profile DIR sync|list|gc`), handing it the pullfile's
//! package list as a generated Brewfile.
const std = @import("std");
const core = @import("core");
const sys = core.sys;
const plist = core.plist;
const Allocator = std.mem.Allocator;

/// Pullfile section key.
pub const SECTION = "tool";

/// The workspace profile, relative to the root.
pub const PROFILE = ".pull/tool";

/// `tool`'s manifest file inside a profile.
const MANIFEST = ".tool.json";

pub fn profile(a: Allocator, root: []const u8) ![]const u8 {
    return std.fs.path.join(a, &.{ root, PROFILE });
}

pub const Brew = struct {
    name: []const u8,
    /// null: plain `brew "name"` (a string in the pullfile).
    link: ?bool = null,
    entry: bool = false,
};

pub const Packages = struct {
    tap: std.ArrayList([]const u8) = .empty,
    brew: std.ArrayList(Brew) = .empty,

    pub fn fromValue(a: Allocator, v: ?plist.Value) !Packages {
        var p: Packages = .{};
        const d = switch (v orelse return p) {
            .dict => |d| d,
            else => return sys.fail("{s}: `{s}`: invalid type, expected a dictionary", .{ core.PULLFILE, SECTION }),
        };
        if (d.get("tap")) |t| try p.tap.appendSlice(a, plist.decode([]const []const u8, a, t) catch
            return sys.fail("{s}: `{s}`: tap: {s}", .{ core.PULLFILE, SECTION, plist.decode_path }));
        if (d.get("brew")) |b| switch (b) {
            .array => |arr| for (arr.items) |item| switch (item) {
                .string => |s| try p.brew.append(a, .{ .name = s }),
                .dict => |e| {
                    const name = switch (e.get("name") orelse return sys.fail("{s}: `{s}`: missing field `name`", .{ core.PULLFILE, SECTION })) {
                        .string => |s| s,
                        else => return sys.fail("{s}: `{s}`: invalid brew name", .{ core.PULLFILE, SECTION }),
                    };
                    const link: ?bool = if (e.get("link")) |l| switch (l) {
                        .boolean => |x| x,
                        else => return sys.fail("{s}: `{s}`: invalid link", .{ core.PULLFILE, SECTION }),
                    } else null;
                    try p.brew.append(a, .{ .name = name, .link = link, .entry = true });
                },
                else => return sys.fail("{s}: `{s}`: invalid brew entry", .{ core.PULLFILE, SECTION }),
            },
            else => return sys.fail("{s}: `{s}`: brew: expected an array", .{ core.PULLFILE, SECTION }),
        };
        return p;
    }

    /// As the Rust `Packages` serialized: empty lists left out.
    pub fn toValue(p: Packages, a: Allocator) !plist.Value {
        var d: plist.Dict = .{};
        if (p.tap.items.len > 0) try d.put(a, "tap", try plist.stringArray(a, p.tap.items));
        if (p.brew.items.len > 0) {
            var arr: std.ArrayList(plist.Value) = .empty;
            for (p.brew.items) |b| {
                if (!b.entry) {
                    try arr.append(a, .{ .string = b.name });
                } else {
                    var e: plist.Dict = .{};
                    try e.put(a, "name", .{ .string = b.name });
                    if (b.link) |l| try e.put(a, "link", .{ .boolean = l });
                    try arr.append(a, .{ .dict = e });
                }
            }
            try d.put(a, "brew", .{ .array = arr });
        }
        return .{ .dict = d };
    }

    fn has(p: Packages, name: []const u8) bool {
        for (p.brew.items) |b| if (std.mem.eql(u8, b.name, name)) return true;
        return false;
    }

    pub fn add(p: *Packages, a: Allocator, names: []const []const u8) !bool {
        var changed = false;
        for (names) |n| if (!p.has(n)) {
            try p.brew.append(a, .{ .name = n });
            changed = true;
        };
        return changed;
    }

    pub fn remove(p: *Packages, names: []const []const u8) bool {
        const before = p.brew.items.len;
        var i: usize = 0;
        while (i < p.brew.items.len) {
            var drop = false;
            for (names) |n| if (std.mem.eql(u8, n, p.brew.items[i].name)) {
                drop = true;
            };
            if (drop) _ = p.brew.orderedRemove(i) else i += 1;
        }
        return p.brew.items.len != before;
    }

    /// The same list as a Brewfile, for the `tool` CLI.
    fn brewfile(p: Packages, a: Allocator) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (p.tap.items) |t| try out.print(a, "tap {f}\n", .{std.json.fmt(t, .{})});
        for (p.brew.items) |b| {
            try out.print(a, "brew {f}", .{std.json.fmt(b.name, .{})});
            if (b.link) |l| try out.print(a, ", link: {s}", .{if (l) "true" else "false"});
            try out.append(a, '\n');
        }
        return out.items;
    }
};

/// The package list from the pullfile.
pub fn packages(a: Allocator, pf: core.Pullfile) !Packages {
    return Packages.fromValue(a, pf.sectionValue(SECTION));
}

/// PATH entries for the workspace env (none unless the pullfile has a `tool` section).
pub fn pathEntries(a: Allocator, root: []const u8, pf: core.Pullfile) ![]const []const u8 {
    if (!pf.hasSection(SECTION)) return &.{};
    const p = try profile(a, root);
    const out = try a.alloc([]const u8, 2);
    out[0] = try std.fs.path.join(a, &.{ p, "bin" });
    out[1] = try std.fs.path.join(a, &.{ p, "sbin" });
    return out;
}

fn runTool(a: Allocator, args: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(a, "tool");
    try argv.appendSlice(a, args);
    const term = sys.runInherit(argv.items, .{}) catch |e| switch (e) {
        error.FileNotFound => return sys.fail("the `tool` CLI (jbisfun/tool) is not on PATH", .{}),
        else => return sys.context(e, "running tool", .{}),
    };
    if (!sys.succeeded(term)) return sys.fail("tool {s} failed", .{args[args.len - 1]});
}

/// Install the pullfile's packages and swap the workspace profile to exactly that
/// set (`tool sync` prints the resulting packages, `*` = linked).
pub fn sync(a: Allocator, root: []const u8, pf: core.Pullfile) !void {
    const pkgs = try packages(a, pf);
    const tmp = sys.getenv("TMPDIR") orelse "/tmp";
    const bf = try std.fmt.allocPrint(a, "{s}/pull-tool-{d}.Brewfile", .{ tmp, std.os.linux.getpid() });
    try sys.writeFile(bf, try pkgs.brewfile(a));
    defer sys.cwd().deleteFile(sys.io, bf) catch {};
    try runTool(a, &.{ "--file", bf, "--profile", try profile(a, root), "sync" });
}

/// Edit the package list in the pullfile (saved only if it changed). Returns whether it did.
pub fn edit(a: Allocator, root: []const u8, pf: *core.Pullfile, pkgs: Packages, changed: bool) !bool {
    if (!changed and pf.hasSection(SECTION)) return false;
    try pf.setSection(SECTION, try pkgs.toValue(a));
    try pf.save(root);
    return true;
}

/// Print the profile's packages, or say it hasn't been synced.
pub fn list(a: Allocator, root: []const u8) !void {
    const p = try profile(a, root);
    if (!sys.exists(try std.fs.path.join(a, &.{ p, MANIFEST }))) {
        sys.out("not synced yet (run `pull tool sync`)\n", .{});
        return;
    }
    try runTool(a, &.{ "--profile", p, "list" });
}

/// Delete store kegs no live profile (in any workspace) uses (`tool gc` prints them).
pub fn gc(a: Allocator) !void {
    try runTool(a, &.{"gc"});
}

/// `pull tool import`: the tool CLI has no way to read a Brewfile into a package
/// list (only `sync` from one), so there is nothing to merge from.
pub fn importBrewfile(path: []const u8) !Packages {
    return sys.fail("{s}: importing a Brewfile needs a `tool` CLI command that prints a Brewfile's packages (jbisfun/tool has none yet)", .{path});
}

test "packages round trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var p: Packages = .{};
    _ = try p.add(a, &.{ "jq", "git" });
    try p.brew.append(a, .{ .name = "gh", .link = false, .entry = true });
    try std.testing.expect(!try p.add(a, &.{"jq"}));
    try std.testing.expect(p.remove(&.{"git"}));
    const v = try p.toValue(a);
    const back = try Packages.fromValue(a, v);
    try std.testing.expectEqual(@as(usize, 2), back.brew.items.len);
    try std.testing.expectEqualStrings("brew \"jq\"\nbrew \"gh\", link: false\n", try back.brewfile(a));
}
