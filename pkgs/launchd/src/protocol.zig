//! Wire protocol: one JSON object per line, serde's externally tagged enum shapes
//! (`"List"`, `{"Print":{"label":"x"}}`, `{"Error":"..."}`), so it matches the Rust crate.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Job = @import("job.zig").Job;

pub const Label = struct { label: []const u8 };

pub const Request = union(enum) {
    /// Load jobs (replacing jobs with the same label) and start RunAtLoad ones.
    load: struct { jobs: []const Job, start: bool },
    unload: Label,
    list,
    print: Label,
    start: Label,
    stop: Label,
    /// launchctl kickstart: start, or with `kill` restart a running job.
    kickstart: struct { label: []const u8, kill: bool },
    /// Write bytes to the job's terminal.
    send: struct { label: []const u8, data: []const u8 },
    /// The job's current screen (plain text, or with escapes).
    capture: struct { label: []const u8, escapes: bool },
    /// Wait until the job produced no output for `idle_ms` (or exited), max `timeout_ms`.
    wait_idle: struct { label: []const u8, idle_ms: u64, timeout_ms: u64 },
    /// Switch this connection to a raw terminal stream for the job.
    attach: struct { label: []const u8, rows: u16, cols: u16 },
    shutdown,

    pub fn jsonStringify(self: Request, jw: anytype) !void {
        return writeTagged(self, jw);
    }
};

pub const JobStatus = struct {
    label: []const u8,
    pid: ?u32 = null,
    last_exit: ?i32 = null,
    runs: u32 = 0,
    state: []const u8,
    argv: []const []const u8 = &.{},
    cwd: []const u8,
    /// Foreground program in the job's terminal (tmux pane_current_command).
    foreground: ?[]const u8 = null,
    /// Working directory of the foreground program (pane_current_path).
    foreground_cwd: ?[]const u8 = null,
    attached: usize = 0,
    job: Job,
    /// Defined in the pullfile's `jobs` (as opposed to an ad-hoc session).
    pullfile: bool = false,
};

pub const Response = union(enum) {
    ok,
    @"error": []const u8,
    jobs: []const JobStatus,
    job: JobStatus,
    text: []const u8,

    pub fn jsonStringify(self: Response, jw: anytype) !void {
        return writeTagged(self, jw);
    }
};

/// Attach stream framing, client -> daemon: [kind, len_hi, len_lo, payload...].
pub const FRAME_DATA: u8 = 0;
/// Payload: rows (u16 BE), cols (u16 BE).
pub const FRAME_RESIZE: u8 = 1;

fn pascal(comptime tag: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        var up = true;
        for (tag) |c| {
            if (c == '_') {
                up = true;
                continue;
            }
            out = out ++ [_]u8{if (up) std.ascii.toUpper(c) else c};
            up = false;
        }
        return out;
    }
}

fn writeTagged(self: anytype, jw: anytype) !void {
    switch (self) {
        inline else => |payload, tag| {
            const name = comptime pascal(@tagName(tag));
            if (@TypeOf(payload) == void) return jw.write(name);
            try jw.beginObject();
            try jw.objectField(name);
            try jw.write(payload);
            try jw.endObject();
        },
    }
}

fn parseTagged(comptime T: type, arena: Allocator, v: Value) !T {
    const opts: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
    const name: []const u8, const payload: ?Value = switch (v) {
        .string => |s| .{ s, null },
        .object => |o| blk: {
            if (o.count() != 1) return error.BadMessage;
            var it = o.iterator();
            const e = it.next().?;
            break :blk .{ e.key_ptr.*, e.value_ptr.* };
        },
        else => return error.BadMessage,
    };
    const info = @typeInfo(T).@"union";
    inline for (info.field_names, info.field_types) |fname, ftype| {
        if (std.mem.eql(u8, name, comptime pascal(fname))) {
            if (ftype == void) return @unionInit(T, fname, {});
            const p = payload orelse return error.BadMessage;
            return @unionInit(T, fname, std.json.parseFromValueLeaky(ftype, arena, p, opts) catch return error.BadMessage);
        }
    }
    return error.UnknownVariant;
}

pub fn parseRequest(arena: Allocator, line: []const u8) !Request {
    const v = std.json.parseFromSliceLeaky(Value, arena, line, .{}) catch return error.BadMessage;
    return parseTagged(Request, arena, v);
}

pub fn parseResponse(arena: Allocator, line: []const u8) !Response {
    const v = std.json.parseFromSliceLeaky(Value, arena, line, .{}) catch return error.BadMessage;
    return parseTagged(Response, arena, v);
}

/// One message line (JSON + '\n').
pub fn encodeLine(arena: Allocator, msg: anytype) ![]u8 {
    var w: std.Io.Writer.Allocating = .init(arena);
    std.json.Stringify.value(msg, .{}, &w.writer) catch return error.OutOfMemory;
    w.writer.writeByte('\n') catch return error.OutOfMemory;
    return w.written();
}

/// serde_json::to_string_pretty layout.
pub fn writePretty(w: *std.Io.Writer, v: anytype) !void {
    try std.json.Stringify.value(v, .{ .whitespace = .indent_2 }, w);
    try w.writeByte('\n');
}

test "request/response shapes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("\"List\"\n", try encodeLine(a, @as(Request, .list)));
    try std.testing.expectEqualStrings(
        "{\"WaitIdle\":{\"label\":\"x\",\"idle_ms\":5,\"timeout_ms\":9}}\n",
        try encodeLine(a, Request{ .wait_idle = .{ .label = "x", .idle_ms = 5, .timeout_ms = 9 } }),
    );
    const r = try parseRequest(a, "{\"Load\":{\"jobs\":[{\"Label\":\"j\",\"RunAtLoad\":true}],\"start\":true}}");
    try std.testing.expectEqualStrings("j", r.load.jobs[0].label);
    try std.testing.expect(r.load.jobs[0].run_at_load);
    try std.testing.expect(try parseRequest(a, "\"Shutdown\"") == .shutdown);
    try std.testing.expectEqualStrings("{\"Error\":\"no\"}\n", try encodeLine(a, Response{ .@"error" = "no" }));
    const st: JobStatus = .{ .label = "j", .state = "running", .cwd = "/", .job = .{ .label = "j" } };
    const line = try encodeLine(a, Response{ .jobs = &.{st} });
    try std.testing.expectEqualStrings(
        "{\"Jobs\":[{\"label\":\"j\",\"pid\":null,\"last_exit\":null,\"runs\":0,\"state\":\"running\",\"argv\":[],\"cwd\":\"/\",\"foreground\":null,\"foreground_cwd\":null,\"attached\":0,\"job\":{\"Label\":\"j\"},\"pullfile\":false}]}\n",
        line,
    );
    const back = try parseResponse(a, line);
    try std.testing.expectEqualStrings("running", back.jobs[0].state);
    try std.testing.expect(try parseResponse(a, "\"Ok\"") == .ok);
}
