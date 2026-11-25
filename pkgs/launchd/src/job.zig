//! A launchd job (Apple's `liblaunch/launch.h` plist keys). JSON uses the plist key
//! names (PascalCase) and omits defaults, like the Rust `pull_launchd::Job`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const EnvVar = struct { name: []const u8, value: []const u8 };

pub const KeepAlive = union(enum) {
    /// `KeepAlive = true/false`.
    always: bool,
    /// `KeepAlive = {SuccessfulExit = b}`: true restarts after a zero exit, false after a
    /// non-zero exit; null never restarts.
    successful_exit: ?bool,

    pub fn jsonStringify(self: KeepAlive, jw: anytype) !void {
        switch (self) {
            .always => |b| try jw.write(b),
            .successful_exit => |s| {
                try jw.beginObject();
                try jw.objectField("SuccessfulExit");
                try jw.write(s);
                try jw.endObject();
            },
        }
    }
};

pub const Job = struct {
    label: []const u8,
    program: ?[]const u8 = null,
    program_arguments: []const []const u8 = &.{},
    /// Sorted by name (see `sortEnv`).
    environment_variables: []const EnvVar = &.{},
    working_directory: ?[]const u8 = null,
    run_at_load: bool = false,
    keep_alive: ?KeepAlive = null,
    start_interval: ?u64 = null,
    throttle_interval: ?u64 = null,
    standard_out_path: ?[]const u8 = null,
    /// Accepted; a PTY merges stderr into StandardOutPath.
    standard_error_path: ?[]const u8 = null,
    disabled: bool = false,
    launch_only_once: bool = false,

    /// launchd's default ThrottleInterval.
    pub fn throttle(self: Job) u64 {
        return self.throttle_interval orelse 10;
    }

    /// Should the job be started again after exiting with `code`?
    pub fn restartAfter(self: Job, code: ?i32) bool {
        const ka = self.keep_alive orelse return false;
        return switch (ka) {
            .always => |b| b,
            .successful_exit => |want| if (want) |w| (code != null and code.? == 0) == w else false,
        };
    }

    /// argv: ProgramArguments (with Program as the executable if both are set), Program
    /// alone, or $SHELL (default /bin/sh) for an ad-hoc session.
    pub fn argv(self: Job, arena: Allocator) ![]const []const u8 {
        var out = try arena.dupe([]const u8, self.program_arguments);
        if (self.program) |p| {
            if (out.len == 0) return arena.dupe([]const u8, &.{p});
            out[0] = p;
            return out;
        }
        if (out.len == 0) {
            const sh: []const u8 = if (std.c.getenv("SHELL")) |s| std.mem.span(s) else "/bin/sh";
            return arena.dupe([]const u8, &.{sh});
        }
        return out;
    }

    pub fn sortEnv(env: []EnvVar) void {
        std.mem.sort(EnvVar, env, {}, struct {
            fn lt(_: void, a: EnvVar, b: EnvVar) bool {
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.lt);
    }

    pub fn eql(a: Job, b: Job) bool {
        const s = std.mem.eql;
        const optS = struct {
            fn f(x: ?[]const u8, y: ?[]const u8) bool {
                if (x == null or y == null) return x == null and y == null;
                return std.mem.eql(u8, x.?, y.?);
            }
        }.f;
        if (!s(u8, a.label, b.label) or !optS(a.program, b.program) or
            !optS(a.working_directory, b.working_directory) or
            !optS(a.standard_out_path, b.standard_out_path) or
            !optS(a.standard_error_path, b.standard_error_path)) return false;
        if (a.run_at_load != b.run_at_load or a.disabled != b.disabled or
            a.launch_only_once != b.launch_only_once or
            a.start_interval != b.start_interval or a.throttle_interval != b.throttle_interval)
            return false;
        if (a.program_arguments.len != b.program_arguments.len) return false;
        for (a.program_arguments, b.program_arguments) |x, y| if (!s(u8, x, y)) return false;
        if (a.environment_variables.len != b.environment_variables.len) return false;
        for (a.environment_variables, b.environment_variables) |x, y|
            if (!s(u8, x.name, y.name) or !s(u8, x.value, y.value)) return false;
        if ((a.keep_alive == null) != (b.keep_alive == null)) return false;
        if (a.keep_alive) |ka| {
            const kb = b.keep_alive.?;
            if (std.meta.activeTag(ka) != std.meta.activeTag(kb)) return false;
            switch (ka) {
                .always => |x| if (x != kb.always) return false,
                .successful_exit => |x| if (x != kb.successful_exit) return false,
            }
        }
        return true;
    }

    /// Deep copy into `arena`.
    pub fn clone(self: Job, arena: Allocator) !Job {
        var j = self;
        j.label = try arena.dupe(u8, self.label);
        inline for (.{ "program", "working_directory", "standard_out_path", "standard_error_path" }) |f| {
            if (@field(self, f)) |v| @field(j, f) = try arena.dupe(u8, v);
        }
        const args = try arena.alloc([]const u8, self.program_arguments.len);
        for (args, self.program_arguments) |*d, a| d.* = try arena.dupe(u8, a);
        j.program_arguments = args;
        const env = try arena.alloc(EnvVar, self.environment_variables.len);
        for (env, self.environment_variables) |*d, e| d.* = .{ .name = try arena.dupe(u8, e.name), .value = try arena.dupe(u8, e.value) };
        sortEnv(env);
        j.environment_variables = env;
        return j;
    }

    pub fn jsonStringify(self: Job, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("Label");
        try jw.write(self.label);
        if (self.program) |v| {
            try jw.objectField("Program");
            try jw.write(v);
        }
        if (self.program_arguments.len > 0) {
            try jw.objectField("ProgramArguments");
            try jw.write(self.program_arguments);
        }
        if (self.environment_variables.len > 0) {
            try jw.objectField("EnvironmentVariables");
            try jw.beginObject();
            for (self.environment_variables) |e| {
                try jw.objectField(e.name);
                try jw.write(e.value);
            }
            try jw.endObject();
        }
        if (self.working_directory) |v| {
            try jw.objectField("WorkingDirectory");
            try jw.write(v);
        }
        if (self.run_at_load) {
            try jw.objectField("RunAtLoad");
            try jw.write(true);
        }
        if (self.keep_alive) |v| {
            try jw.objectField("KeepAlive");
            try jw.write(v);
        }
        if (self.start_interval) |v| {
            try jw.objectField("StartInterval");
            try jw.write(v);
        }
        if (self.throttle_interval) |v| {
            try jw.objectField("ThrottleInterval");
            try jw.write(v);
        }
        if (self.standard_out_path) |v| {
            try jw.objectField("StandardOutPath");
            try jw.write(v);
        }
        if (self.standard_error_path) |v| {
            try jw.objectField("StandardErrorPath");
            try jw.write(v);
        }
        if (self.disabled) {
            try jw.objectField("Disabled");
            try jw.write(true);
        }
        if (self.launch_only_once) {
            try jw.objectField("LaunchOnlyOnce");
            try jw.write(true);
        }
        try jw.endObject();
    }

    pub const FromValueError = error{ OutOfMemory, InvalidJob };

    /// From a JSON object with plist keys (unknown keys are ignored, like serde).
    /// Strings are borrowed from `v`.
    pub fn fromValue(arena: Allocator, v: Value) FromValueError!Job {
        if (v != .object) return error.InvalidJob;
        const o = v.object;
        var j: Job = .{ .label = try str(o.get("Label") orelse return error.InvalidJob) };
        if (o.get("Program")) |x| j.program = try optStr(x);
        if (o.get("ProgramArguments")) |x| switch (x) {
            .null => {},
            .array => |a| {
                const out = try arena.alloc([]const u8, a.items.len);
                for (out, a.items) |*d, s| d.* = try str(s);
                j.program_arguments = out;
            },
            else => return error.InvalidJob,
        };
        if (o.get("EnvironmentVariables")) |x| switch (x) {
            .null => {},
            .object => |m| {
                const out = try arena.alloc(EnvVar, m.count());
                var it = m.iterator();
                var i: usize = 0;
                while (it.next()) |e| : (i += 1) out[i] = .{ .name = e.key_ptr.*, .value = try str(e.value_ptr.*) };
                sortEnv(out);
                j.environment_variables = out;
            },
            else => return error.InvalidJob,
        };
        if (o.get("WorkingDirectory")) |x| j.working_directory = try optStr(x);
        if (o.get("RunAtLoad")) |x| j.run_at_load = try boolean(x);
        if (o.get("KeepAlive")) |x| j.keep_alive = switch (x) {
            .null => null,
            .bool => |b| .{ .always = b },
            .object => |m| .{ .successful_exit = if (m.get("SuccessfulExit")) |s| switch (s) {
                .null => null,
                .bool => |b| b,
                else => return error.InvalidJob,
            } else null },
            else => return error.InvalidJob,
        };
        if (o.get("StartInterval")) |x| j.start_interval = try optInt(x);
        if (o.get("ThrottleInterval")) |x| j.throttle_interval = try optInt(x);
        if (o.get("StandardOutPath")) |x| j.standard_out_path = try optStr(x);
        if (o.get("StandardErrorPath")) |x| j.standard_error_path = try optStr(x);
        if (o.get("Disabled")) |x| j.disabled = try boolean(x);
        if (o.get("LaunchOnlyOnce")) |x| j.launch_only_once = try boolean(x);
        return j;
    }

    pub fn jsonParseFromValue(arena: Allocator, v: Value, _: std.json.ParseOptions) !Job {
        return fromValue(arena, v) catch |e| switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidJob => error.UnexpectedToken,
        };
    }

    pub fn jsonParse(arena: Allocator, source: anytype, options: std.json.ParseOptions) !Job {
        const v = try std.json.innerParse(Value, arena, source, options);
        return jsonParseFromValue(arena, v, options);
    }

    fn str(v: Value) ![]const u8 {
        return if (v == .string) v.string else error.InvalidJob;
    }
    fn optStr(v: Value) !?[]const u8 {
        return if (v == .null) null else try str(v);
    }
    fn boolean(v: Value) !bool {
        return switch (v) {
            .bool => |b| b,
            .null => false,
            else => error.InvalidJob,
        };
    }
    fn optInt(v: Value) !?u64 {
        return switch (v) {
            .null => null,
            .integer => |i| std.math.cast(u64, i) orelse error.InvalidJob,
            else => error.InvalidJob,
        };
    }
};

/// `~` / `~/x` -> $HOME; relative paths are joined to `root`.
pub fn expandPath(arena: Allocator, root: []const u8, p: []const u8) ![]const u8 {
    var s = p;
    if (std.mem.eql(u8, p, "~") or std.mem.startsWith(u8, p, "~/")) {
        if (std.c.getenv("HOME")) |h| s = try std.mem.concat(arena, u8, &.{ std.mem.span(h), p[1..] });
    }
    if (std.fs.path.isAbsolute(s)) return s;
    return std.fs.path.join(arena, &.{ root, s });
}

/// shellexpand::full: `~`, `$VAR` and `${VAR}` from `lookup`. Unknown variables are
/// an error in shellexpand, where the Rust daemon kept the value verbatim; same here.
pub fn expandValue(arena: Allocator, s: []const u8, ctx: anytype, comptime lookup: fn (@TypeOf(ctx), []const u8) ?[]const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    if (std.mem.eql(u8, s, "~") or std.mem.startsWith(u8, s, "~/")) {
        const home = lookup(ctx, "HOME") orelse return s;
        try out.appendSlice(arena, home);
        i = 1;
    }
    while (i < s.len) {
        const c = s[i];
        if (c != '$' or i + 1 >= s.len) {
            try out.append(arena, c);
            i += 1;
            continue;
        }
        var name: []const u8 = undefined;
        var next: usize = undefined;
        if (s[i + 1] == '{') {
            const end = std.mem.indexOfScalarPos(u8, s, i + 2, '}') orelse return s;
            name = s[i + 2 .. end];
            next = end + 1;
        } else {
            var e = i + 1;
            while (e < s.len and (std.ascii.isAlphanumeric(s[e]) or s[e] == '_')) e += 1;
            if (e == i + 1) {
                try out.append(arena, c);
                i += 1;
                continue;
            }
            name = s[i + 1 .. e];
            next = e;
        }
        try out.appendSlice(arena, lookup(ctx, name) orelse return s);
        i = next;
    }
    return out.items;
}

test "job json round trip and keep-alive" {
    const a = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const ar = arena.allocator();
    const src =
        \\{"Label":"dev.server","ProgramArguments":["python3","-m","http.server"],
        \\ "EnvironmentVariables":{"PORT":"8000","A":"1"},"KeepAlive":{"SuccessfulExit":false},
        \\ "RunAtLoad":true,"Unknown":1}
    ;
    const j = try std.json.parseFromSliceLeaky(Job, ar, src, .{});
    try std.testing.expectEqualStrings("dev.server", j.label);
    try std.testing.expectEqual(@as(usize, 3), (try j.argv(ar)).len);
    try std.testing.expect(j.run_at_load);
    try std.testing.expect(j.restartAfter(1));
    try std.testing.expect(!j.restartAfter(0));
    try std.testing.expectEqualStrings("A", j.environment_variables[0].name);
    const out = try std.json.Stringify.valueAlloc(ar, j, .{});
    try std.testing.expectEqualStrings(
        \\{"Label":"dev.server","ProgramArguments":["python3","-m","http.server"],"EnvironmentVariables":{"A":"1","PORT":"8000"},"RunAtLoad":true,"KeepAlive":{"SuccessfulExit":false}}
    , out);
    const back = try std.json.parseFromSliceLeaky(Job, ar, out, .{});
    try std.testing.expect(j.eql(back));
    const always = try std.json.parseFromSliceLeaky(Job, ar, "{\"Label\":\"a\",\"KeepAlive\":true}", .{});
    try std.testing.expect(always.restartAfter(0));
    try std.testing.expect(!j.eql(always));
}

test "expand" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const L = struct {
        fn f(_: void, n: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, n, "HOME")) return "/h";
            if (std.mem.eql(u8, n, "X")) return "x";
            return null;
        }
    };
    try std.testing.expectEqualStrings("/h/a-x-x$", try expandValue(ar, "~/a-$X-${X}$", {}, L.f));
    try std.testing.expectEqualStrings("$NOPE", try expandValue(ar, "$NOPE", {}, L.f));
    try std.testing.expectEqualStrings("/r/log", try expandPath(ar, "/r", "log"));
}
