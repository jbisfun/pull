//! Command-line interface (zig-clap). Subcommands of compiled-out features don't
//! exist. Help and usage errors are laid out like the Rust pull's (clap derive).
const std = @import("std");
const clap = @import("clap");
const opts = @import("build_options");
const core = @import("core");
const sys = core.sys;
const Allocator = std.mem.Allocator;

pub const ArgIter = std.process.Args.Iterator;

pub const Cmd = union(enum) {
    init: struct { org: ?[]const u8 },
    repo_add: struct { upstream: []const u8, name: ?[]const u8, branch: []const u8 },
    repo_rm: []const u8,
    repo_list,
    sync,
    update,
    status: struct { json: bool },
    unstage: []const []const u8,
    add: []const []const u8,
    commit: struct { message: []const u8, all: bool, no_verify: bool, paths: []const []const u8 },
    push,
    lint: []const u8,
    whoami,
    env: struct { envrc: bool },
    shell: []const []const u8,
    mcp: struct { root: ?[]const u8 },
    mcp_servers,
    launchd,
    launchctl_load: []const []const u8,
    launchctl_unload: []const u8,
    launchctl_list: struct { json: bool, all: bool },
    launchctl_print: struct { label: []const u8, json: bool },
    launchctl_start: []const u8,
    launchctl_stop: []const u8,
    launchctl_kickstart: struct { label: []const u8, k: bool },
    launchctl_shutdown,
    session_new: struct { name: []const u8, detached: bool, cwd: ?[]const u8, keep_alive: bool, cmd: []const []const u8 },
    session_ls: struct { json: bool },
    session_attach: []const u8,
    session_send: struct { name: []const u8, text: []const []const u8, enter: bool },
    session_capture: struct { name: []const u8, escapes: bool },
    session_run: struct { name: []const u8, idle: u64, timeout: u64, command: []const []const u8 },
    session_kill: []const u8,
    worktree_add: struct { name: []const u8, branch: ?[]const u8 },
    worktree_list,
    worktree_rm: struct { name: []const u8, force: bool },
    tool_sync,
    tool_add: []const []const u8,
    tool_rm: []const []const u8,
    tool_import: []const u8,
    tool_list,
    tool_gc,
    each: []const []const u8,
    haxy_sync: []const []const u8,
    haxy_issues: struct { repo: ?[]const u8, all: bool, json: bool },
    haxy_show: struct { repo: []const u8, issue: []const u8 },
    haxy_new: struct { repo: []const u8, title: []const u8, body: []const u8, labels: []const u8 },
    haxy_comment: struct { repo: []const u8, issue: []const u8, text: []const u8 },
    haxy_status: struct { repo: []const u8, issue: []const u8, close: bool },
    haxy_open: []const u8,
};

// ---------------------------------------------------------------- help data

const Line = struct { []const u8, []const u8 };

const Help = struct {
    about: []const u8,
    usage: []const u8,
    args: []const Line = &.{},
    options: []const Line = &.{},
    commands: []const Line = &.{},
};

const help_flag: Line = .{ "-h, --help", "Print help" };

const Sub = struct { name: []const u8, about: []const u8, enabled: bool = true, hidden: bool = false };

const top_commands = [_]Sub{
    .{ .name = "init", .about = "Create pullfile.plist and local.toml in the current directory" },
    .{ .name = "repo", .about = "Manage the repo list" },
    .{ .name = "sync", .about = "Clone missing repos, fetch, and fast-forward to pinned commits. Runs `pull` hooks" },
    .{ .name = "update", .about = "Fetch and fast-forward every repo to its upstream branch, then re-pin. Runs `pull` hooks" },
    .{ .name = "status", .about = "Show branch, pin and changes for every repo" },
    .{ .name = "unstage", .about = "Unstage paths (back to HEAD); each path is routed to its repo" },
    .{ .name = "add", .about = "Stage paths; each path is routed to the repo it lives in" },
    .{ .name = "commit", .about = "One commit across every repo with staged changes; pins the new commits" },
    .{ .name = "push", .about = "Push every repo whose branch is ahead of origin" },
    .{ .name = "lint", .about = "Check a message against the pullfile lint rules", .enabled = opts.lint },
    .{ .name = "whoami", .about = "Print the identity commits will be written with" },
    .{ .name = "env", .about = "Print the workspace env (pullfile `env` + local.toml `[env]`) as shell exports. `eval \"$(pull env)\"`, or `--envrc` to write a direnv .envrc that does it", .enabled = opts.env },
    .{ .name = "shell", .about = "Start $SHELL (or the given command) with the workspace env applied", .enabled = opts.env },
    .{ .name = "mcp", .about = "MCP server on stdio for agents: multi-repo context, programs, stateful terminals", .enabled = opts.mcp },
    .{ .name = "mcp-servers", .about = "MCP servers for this workspace as JSON (built-in `pull`, plus the pullfile `mcp_servers` section), command resolved via `command -v` and `PULL_ROOT` set: for an editor/agent to register directly", .enabled = opts.mcp },
    .{ .name = "launchd", .about = "Run the workspace job daemon in the foreground (started automatically when needed)", .enabled = opts.launchd, .hidden = true },
    .{ .name = "launchctl", .about = "launchd-style job control: jobs from the pullfile `jobs` or launchd .plist files", .enabled = opts.launchd },
    .{ .name = "session", .about = "tmux-style terminal sessions (headless jobs a human can attach to and an agent can drive), started with the workspace env", .enabled = opts.launchd },
    .{ .name = "worktree", .about = "Workspace worktrees under .worktrees/NAME (every repo as a git worktree)", .enabled = opts.worktree },
    .{ .name = "tool", .about = "Workspace packages: pullfile `tool` (Brewfile-style), poured from Linuxbrew bottles and linked into .pull/tool (on PATH in `pull env`)", .enabled = opts.tool },
    .{ .name = "haxy", .about = "Issues on haxy's `haxy/events` branch: list, file, comment, close, sync, open the haxy TUI", .enabled = opts.haxy },
    .{ .name = "each", .about = "Run a command in every cloned repo (e.g. `pull each git log -1`)" },
};

const haxy_commands = [_]Sub{
    .{ .name = "sync", .about = "Fetch, merge (empty-tree merge commit) and push haxy/events of every repo that has it" },
    .{ .name = "issues", .about = "List open issues (--all: closed too) of every repo with haxy/events, or one repo" },
    .{ .name = "show", .about = "One issue with its description and comments" },
    .{ .name = "new", .about = "Open an issue" },
    .{ .name = "comment", .about = "Comment on an issue" },
    .{ .name = "close", .about = "Close an issue" },
    .{ .name = "reopen", .about = "Reopen an issue" },
    .{ .name = "open", .about = "Run `haxy` (its TUI, and web UI on a local port) in a repo" },
};

const repo_commands = [_]Sub{
    .{ .name = "add", .about = "Add a repo; it will be cloned to <root>/<name>" },
    .{ .name = "rm", .about = "Remove a repo from the pullfile (does not delete the directory)" },
    .{ .name = "list", .about = "List repos" },
};

const launchctl_commands = [_]Sub{
    .{ .name = "load", .about = "Load jobs from launchd .plist files, or (no files) the pullfile's `jobs`" },
    .{ .name = "unload", .about = "Stop a job and forget it" },
    .{ .name = "list", .about = "PID, last exit status and label of every job, like launchctl list" },
    .{ .name = "print", .about = "Everything about one job: state, program, environment, foreground program" },
    .{ .name = "start", .about = "" },
    .{ .name = "stop", .about = "" },
    .{ .name = "kickstart", .about = "Start a job; with -k, kill and restart it if it is running" },
    .{ .name = "shutdown", .about = "Stop every job and the daemon" },
};

const session_commands = [_]Sub{
    .{ .name = "new", .about = "Start a session running CMD (default: your shell) and attach, unless -d" },
    .{ .name = "ls", .about = "Sessions with their running program and directory (tmux ls)" },
    .{ .name = "attach", .about = "Attach this terminal to a session; detach with ctrl-\\" },
    .{ .name = "send", .about = "Type TEXT into a session (tmux send-keys)" },
    .{ .name = "capture", .about = "Print a session's screen (tmux capture-pane)" },
    .{ .name = "run", .about = "For agents: type COMMAND + enter, wait until output settles, print the screen" },
    .{ .name = "kill", .about = "Stop and remove a session" },
};

const worktree_commands = [_]Sub{
    .{ .name = "add", .about = "Create .worktrees/NAME: each repo checked out on BRANCH (default NAME)" },
    .{ .name = "list", .about = "List workspace worktrees" },
    .{ .name = "rm", .about = "Remove a workspace worktree (branches are kept)" },
};

const tool_commands = [_]Sub{
    .{ .name = "sync", .about = "Install the pullfile's packages and swap .pull/tool to exactly that set" },
    .{ .name = "add", .about = "Add formulae to the pullfile and sync" },
    .{ .name = "rm", .about = "Remove formulae from the pullfile and sync" },
    .{ .name = "import", .about = "Merge a Brewfile's taps and formulae into the pullfile and sync" },
    .{ .name = "list", .about = "List installed packages (`*` = linked into the profile)" },
    .{ .name = "gc", .about = "Delete store kegs that no workspace profile uses" },
};

fn aboutOf(subs: []const Sub, name: []const u8) []const u8 {
    for (subs) |s| if (std.mem.eql(u8, s.name, name)) return s.about;
    return "";
}

fn renderLines(w: *std.Io.Writer, title: []const u8, lines: []const Line) !void {
    if (lines.len == 0) return;
    var width: usize = 0;
    for (lines) |l| width = @max(width, l[0].len);
    try w.print("\n{s}:\n", .{title});
    for (lines) |l| {
        try w.print("  {s}", .{l[0]});
        try w.splatByteAll(' ', width - l[0].len + 2);
        try w.print("{s}\n", .{l[1]});
    }
}

fn render(a: Allocator, h: Help) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(a);
    if (h.about.len > 0) try w.writer.print("{s}\n\n", .{h.about});
    try w.writer.print("Usage: {s}\n", .{h.usage});
    try renderLines(&w.writer, "Commands", h.commands);
    try renderLines(&w.writer, "Arguments", h.args);
    try renderLines(&w.writer, "Options", h.options);
    return w.written();
}

fn commandLines(a: Allocator, subs: []const Sub) ![]const Line {
    var out: std.ArrayList(Line) = .empty;
    for (subs) |s| if (s.enabled and !s.hidden) try out.append(a, .{ s.name, s.about });
    try out.append(a, .{ "help", "Print this message or the help of the given subcommand(s)" });
    return out.items;
}

fn groupHelp(a: Allocator, path: []const u8, about: []const u8, subs: []const Sub) ![]const u8 {
    return render(a, .{
        .about = about,
        .usage = try std.fmt.allocPrint(a, "pull {s} <COMMAND>", .{path}),
        .commands = try commandLines(a, subs),
        .options = &.{help_flag},
    });
}

pub fn mainHelp(a: Allocator) ![]const u8 {
    return render(a, .{
        .about = "Multi-repo git wrapper driven by pullfile.plist",
        .usage = "pull <COMMAND>",
        .commands = try commandLines(a, &top_commands),
        .options = &.{ help_flag, .{ "-V, --version", "Print version" } },
    });
}

/// Help of a leaf command (`path` like "repo add").
fn leafHelp(a: Allocator, path: []const u8) !?[]const u8 {
    const H = struct { []const u8, Help };
    const leaves = [_]H{
        .{ "init", .{ .about = aboutOf(&top_commands, "init"), .usage = "pull init [OPTIONS]", .options = &.{ .{ "    --org <ORG>", "Org identity to use (selects [orgs.<org>] in local.toml)" }, help_flag } } },
        .{ "repo add", .{ .about = aboutOf(&repo_commands, "add"), .usage = "pull repo add [OPTIONS] <UPSTREAM>", .args = &.{.{ "<UPSTREAM>", "" }}, .options = &.{ .{ "    --name <NAME>", "" }, .{ "    --branch <BRANCH>", "[default: main]" }, help_flag } } },
        .{ "repo rm", .{ .about = aboutOf(&repo_commands, "rm"), .usage = "pull repo rm <NAME>", .args = &.{.{ "<NAME>", "" }}, .options = &.{help_flag} } },
        .{ "repo list", .{ .about = aboutOf(&repo_commands, "list"), .usage = "pull repo list", .options = &.{help_flag} } },
        .{ "sync", .{ .about = aboutOf(&top_commands, "sync"), .usage = "pull sync", .options = &.{help_flag} } },
        .{ "update", .{ .about = aboutOf(&top_commands, "update"), .usage = "pull update", .options = &.{help_flag} } },
        .{ "status", .{ .about = aboutOf(&top_commands, "status"), .usage = "pull status [OPTIONS]", .options = &.{ .{ "    --json", "Machine-readable: per repo branch, head, pin, ahead/behind and changed files" }, help_flag } } },
        .{ "unstage", .{ .about = aboutOf(&top_commands, "unstage"), .usage = "pull unstage <PATHS>...", .args = &.{.{ "<PATHS>...", "" }}, .options = &.{help_flag} } },
        .{ "add", .{ .about = aboutOf(&top_commands, "add"), .usage = "pull add <PATHS>...", .args = &.{.{ "<PATHS>...", "" }}, .options = &.{help_flag} } },
        .{ "commit", .{ .about = aboutOf(&top_commands, "commit"), .usage = "pull commit [OPTIONS] --message <MESSAGE> [PATHS]...", .args = &.{.{ "[PATHS]...", "Only stage+commit these paths (routed to their repos)" }}, .options = &.{ .{ "-m, --message <MESSAGE>", "" }, .{ "-a, --all", "Stage all tracked modifications first (like `git commit -a`)" }, .{ "    --no-verify", "Skip precommit/postcommit hooks" }, help_flag } } },
        .{ "push", .{ .about = aboutOf(&top_commands, "push"), .usage = "pull push", .options = &.{help_flag} } },
        .{ "lint", .{ .about = aboutOf(&top_commands, "lint"), .usage = "pull lint <MESSAGE>", .args = &.{.{ "<MESSAGE>", "" }}, .options = &.{help_flag} } },
        .{ "whoami", .{ .about = aboutOf(&top_commands, "whoami"), .usage = "pull whoami", .options = &.{help_flag} } },
        .{ "env", .{ .about = aboutOf(&top_commands, "env"), .usage = "pull env [OPTIONS]", .options = &.{ .{ "    --envrc", "" }, help_flag } } },
        .{ "shell", .{ .about = aboutOf(&top_commands, "shell"), .usage = "pull shell [CMD]...", .args = &.{.{ "[CMD]...", "" }}, .options = &.{help_flag} } },
        .{ "mcp", .{ .about = aboutOf(&top_commands, "mcp"), .usage = "pull mcp [OPTIONS]", .options = &.{ .{ "    --root <ROOT>", "Workspace root (default: found from the current directory)" }, help_flag } } },
        .{ "mcp-servers", .{ .about = aboutOf(&top_commands, "mcp-servers"), .usage = "pull mcp-servers", .options = &.{help_flag} } },
        .{ "launchd", .{ .about = aboutOf(&top_commands, "launchd"), .usage = "pull launchd", .options = &.{help_flag} } },
        .{ "launchctl load", .{ .about = aboutOf(&launchctl_commands, "load"), .usage = "pull launchctl load [PATHS]...", .args = &.{.{ "[PATHS]...", "" }}, .options = &.{help_flag} } },
        .{ "launchctl unload", .{ .about = aboutOf(&launchctl_commands, "unload"), .usage = "pull launchctl unload <LABEL>", .args = &.{.{ "<LABEL>", "" }}, .options = &.{help_flag} } },
        .{ "launchctl list", .{ .about = aboutOf(&launchctl_commands, "list"), .usage = "pull launchctl list [OPTIONS]", .options = &.{ .{ "    --json", "" }, .{ "    --all", "Also pullfile jobs that aren't loaded (state \"unloaded\"), and don't start the daemon just to list" }, help_flag } } },
        .{ "launchctl print", .{ .about = aboutOf(&launchctl_commands, "print"), .usage = "pull launchctl print [OPTIONS] <LABEL>", .args = &.{.{ "<LABEL>", "" }}, .options = &.{ .{ "    --json", "" }, help_flag } } },
        .{ "launchctl start", .{ .about = "", .usage = "pull launchctl start <LABEL>", .args = &.{.{ "<LABEL>", "" }}, .options = &.{help_flag} } },
        .{ "launchctl stop", .{ .about = "", .usage = "pull launchctl stop <LABEL>", .args = &.{.{ "<LABEL>", "" }}, .options = &.{help_flag} } },
        .{ "launchctl kickstart", .{ .about = aboutOf(&launchctl_commands, "kickstart"), .usage = "pull launchctl kickstart [OPTIONS] <LABEL>", .args = &.{.{ "<LABEL>", "" }}, .options = &.{ .{ "-k", "" }, help_flag } } },
        .{ "launchctl shutdown", .{ .about = aboutOf(&launchctl_commands, "shutdown"), .usage = "pull launchctl shutdown", .options = &.{help_flag} } },
        .{ "session new", .{ .about = aboutOf(&session_commands, "new"), .usage = "pull session new [OPTIONS] <NAME> [CMD]...", .args = &.{ .{ "<NAME>", "" }, .{ "[CMD]...", "" } }, .options = &.{ .{ "-d, --detached", "Don't attach (like tmux new -d)" }, .{ "-c, --cwd <CWD>", "Working directory (default: the workspace root)" }, .{ "    --keep-alive", "Restart the command whenever it exits (launchd KeepAlive)" }, help_flag } } },
        .{ "session ls", .{ .about = aboutOf(&session_commands, "ls"), .usage = "pull session ls [OPTIONS]", .options = &.{ .{ "    --json", "" }, help_flag } } },
        .{ "session attach", .{ .about = aboutOf(&session_commands, "attach"), .usage = "pull session attach <NAME>", .args = &.{.{ "<NAME>", "" }}, .options = &.{help_flag} } },
        .{ "session send", .{ .about = aboutOf(&session_commands, "send"), .usage = "pull session send [OPTIONS] <NAME> [TEXT]...", .args = &.{ .{ "<NAME>", "" }, .{ "[TEXT]...", "" } }, .options = &.{ .{ "-e, --enter", "Press enter after the text" }, help_flag } } },
        .{ "session capture", .{ .about = aboutOf(&session_commands, "capture"), .usage = "pull session capture [OPTIONS] <NAME>", .args = &.{.{ "<NAME>", "" }}, .options = &.{ .{ "-e, --escapes", "Keep colours and attributes (ANSI escapes)" }, help_flag } } },
        .{ "session run", .{ .about = aboutOf(&session_commands, "run"), .usage = "pull session run [OPTIONS] <NAME> <COMMAND>...", .args = &.{ .{ "<NAME>", "" }, .{ "<COMMAND>...", "" } }, .options = &.{ .{ "    --idle <IDLE>", "Settle time with no new output, in ms [default: 800]" }, .{ "    --timeout <TIMEOUT>", "Give up waiting after this many ms [default: 60000]" }, help_flag } } },
        .{ "session kill", .{ .about = aboutOf(&session_commands, "kill"), .usage = "pull session kill <NAME>", .args = &.{.{ "<NAME>", "" }}, .options = &.{help_flag} } },
        .{ "worktree add", .{ .about = aboutOf(&worktree_commands, "add"), .usage = "pull worktree add [OPTIONS] <NAME>", .args = &.{.{ "<NAME>", "" }}, .options = &.{ .{ "-b, --branch <BRANCH>", "" }, help_flag } } },
        .{ "worktree list", .{ .about = aboutOf(&worktree_commands, "list"), .usage = "pull worktree list", .options = &.{help_flag} } },
        .{ "worktree rm", .{ .about = aboutOf(&worktree_commands, "rm"), .usage = "pull worktree rm [OPTIONS] <NAME>", .args = &.{.{ "<NAME>", "" }}, .options = &.{ .{ "    --force", "" }, help_flag } } },
        .{ "tool sync", .{ .about = aboutOf(&tool_commands, "sync"), .usage = "pull tool sync", .options = &.{help_flag} } },
        .{ "tool add", .{ .about = aboutOf(&tool_commands, "add"), .usage = "pull tool add <NAMES>...", .args = &.{.{ "<NAMES>...", "" }}, .options = &.{help_flag} } },
        .{ "tool rm", .{ .about = aboutOf(&tool_commands, "rm"), .usage = "pull tool rm <NAMES>...", .args = &.{.{ "<NAMES>...", "" }}, .options = &.{help_flag} } },
        .{ "tool import", .{ .about = aboutOf(&tool_commands, "import"), .usage = "pull tool import [FILE]", .args = &.{.{ "[FILE]", "[default: Brewfile]" }}, .options = &.{help_flag} } },
        .{ "tool list", .{ .about = aboutOf(&tool_commands, "list"), .usage = "pull tool list", .options = &.{help_flag} } },
        .{ "tool gc", .{ .about = aboutOf(&tool_commands, "gc"), .usage = "pull tool gc", .options = &.{help_flag} } },
        .{ "each", .{ .about = aboutOf(&top_commands, "each"), .usage = "pull each <CMD>...", .args = &.{.{ "<CMD>...", "" }}, .options = &.{help_flag} } },
        .{ "haxy sync", .{ .about = aboutOf(&haxy_commands, "sync"), .usage = "pull haxy sync [REPOS]...", .args = &.{.{ "[REPOS]...", "Only these repos" }}, .options = &.{help_flag} } },
        .{ "haxy issues", .{ .about = aboutOf(&haxy_commands, "issues"), .usage = "pull haxy issues [OPTIONS] [REPO]", .args = &.{.{ "[REPO]", "" }}, .options = &.{ .{ "    --all", "Closed issues too" }, .{ "    --json", "Machine-readable: {repos: [{issues, name, path}], root}" }, help_flag } } },
        .{ "haxy show", .{ .about = aboutOf(&haxy_commands, "show"), .usage = "pull haxy show <REPO> <ISSUE>", .args = &.{ .{ "<REPO>", "" }, .{ "<ISSUE>", "Issue id (a unique prefix will do)" } }, .options = &.{help_flag} } },
        .{ "haxy new", .{ .about = aboutOf(&haxy_commands, "new"), .usage = "pull haxy new [OPTIONS] --title <TITLE> <REPO>", .args = &.{.{ "<REPO>", "" }}, .options = &.{ .{ "-t, --title <TITLE>", "" }, .{ "-b, --body <BODY>", "Description (markdown)" }, .{ "-l, --labels <LABELS>", "Space- or comma-separated" }, help_flag } } },
        .{ "haxy comment", .{ .about = aboutOf(&haxy_commands, "comment"), .usage = "pull haxy comment <REPO> <ISSUE> <TEXT>", .args = &.{ .{ "<REPO>", "" }, .{ "<ISSUE>", "Issue id (a unique prefix will do)" }, .{ "<TEXT>", "" } }, .options = &.{help_flag} } },
        .{ "haxy close", .{ .about = aboutOf(&haxy_commands, "close"), .usage = "pull haxy close <REPO> <ISSUE>", .args = &.{ .{ "<REPO>", "" }, .{ "<ISSUE>", "Issue id (a unique prefix will do)" } }, .options = &.{help_flag} } },
        .{ "haxy reopen", .{ .about = aboutOf(&haxy_commands, "reopen"), .usage = "pull haxy reopen <REPO> <ISSUE>", .args = &.{ .{ "<REPO>", "" }, .{ "<ISSUE>", "Issue id (a unique prefix will do)" } }, .options = &.{help_flag} } },
        .{ "haxy open", .{ .about = aboutOf(&haxy_commands, "open"), .usage = "pull haxy open <REPO>", .args = &.{.{ "<REPO>", "" }}, .options = &.{help_flag} } },
    };
    for (leaves) |l| if (std.mem.eql(u8, l[0], path)) return try render(a, l[1]);
    if (std.mem.eql(u8, path, "repo")) return try groupHelp(a, "repo", aboutOf(&top_commands, "repo"), &repo_commands);
    if (std.mem.eql(u8, path, "worktree")) return try groupHelp(a, "worktree", aboutOf(&top_commands, "worktree"), &worktree_commands);
    if (std.mem.eql(u8, path, "tool")) return try groupHelp(a, "tool", aboutOf(&top_commands, "tool"), &tool_commands);
    if (std.mem.eql(u8, path, "launchctl")) return try groupHelp(a, "launchctl", aboutOf(&top_commands, "launchctl"), &launchctl_commands);
    if (std.mem.eql(u8, path, "session")) return try groupHelp(a, "session", aboutOf(&top_commands, "session"), &session_commands);
    if (std.mem.eql(u8, path, "haxy")) return try groupHelp(a, "haxy", aboutOf(&top_commands, "haxy"), &haxy_commands);
    return null;
}

fn usageOf(a: Allocator, path: []const u8) []const u8 {
    const h = leafHelp(a, path) catch return "pull";
    const text = h orelse return "pull <COMMAND>";
    const start = (std.mem.indexOf(u8, text, "Usage: ") orelse return "pull") + "Usage: ".len;
    const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
    return text[start..end];
}

// ---------------------------------------------------------------- errors

/// clap-style usage error on stderr; the caller exits 2.
fn usageError(a: Allocator, path: []const u8, comptime fmt: []const u8, args: anytype) error{Usage} {
    sys.err("error: " ++ fmt ++ "\n\nUsage: {s}\n\nFor more information, try '--help'.\n", args ++ .{usageOf(a, path)});
    return error.Usage;
}

fn missing(a: Allocator, path: []const u8, what: []const u8, usage: []const u8) error{Usage} {
    sys.err("error: the following required arguments were not provided:\n  {s}\n\nUsage: {s}\n\nFor more information, try '--help'.\n", .{ what, usage });
    _ = a;
    _ = path;
    return error.Usage;
}

fn enabled(subs: []const Sub, name: []const u8) bool {
    for (subs) |s| if (std.mem.eql(u8, s.name, name)) return s.enabled;
    return false;
}

// ---------------------------------------------------------------- parsing

const parsers = .{ .str = clap.parsers.string };

fn parseSub(a: Allocator, comptime path: []const u8, comptime params: []const clap.Param(clap.Help), iter: *ArgIter) !clap.ResultEx(clap.Help, params, parsers) {
    var d: clap.Diagnostic = .{};
    const res = clap.parseEx(clap.Help, params, parsers, iter, .{ .diagnostic = &d, .allocator = a }) catch |e| {
        var buf: [512]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        d.report(&w, e) catch {};
        const text = std.mem.trim(u8, w.buffered(), " \r\n");
        const clean = if (std.mem.startsWith(u8, text, "error: ")) text["error: ".len..] else text;
        // clap(-rs) wording for unknown flags/extra args.
        const prefix = "Invalid argument ";
        if (std.mem.startsWith(u8, clean, prefix)) {
            const arg = clean[prefix.len..];
            const positional = comptime for (params) |p| {
                if (p.names.long == null and p.names.short == null) break true;
            } else false;
            // clap's tip when a hyphenated word could have been a positional value.
            if (positional and arg.len > 2 and arg[1] == '-') {
                const bare = arg[1 .. arg.len - 1];
                return usageError(a, path, "unexpected argument {s} found\n\n  tip: to pass '{s}' as a value, use '-- {s}'", .{ arg, bare, bare });
            }
            return usageError(a, path, "unexpected argument {s} found", .{arg});
        }
        return usageError(a, path, "{s}", .{clean});
    };
    if (res.args.help != 0) {
        sys.outBytes((try leafHelp(a, path)).?);
        return error.HelpShown;
    }
    if (iter.next()) |extra| return usageError(a, path, "unexpected argument '{s}' found", .{extra});
    return res;
}

/// The remaining raw arguments (trailing var args: hyphens allowed); `--help`
/// right after the subcommand shows its help.
fn rest(a: Allocator, comptime path: []const u8, iter: *ArgIter) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    while (iter.next()) |arg| try out.append(a, arg);
    if (out.items.len > 0 and (std.mem.eql(u8, out.items[0], "-h") or std.mem.eql(u8, out.items[0], "--help"))) {
        sys.outBytes((try leafHelp(a, path)).?);
        return error.HelpShown;
    }
    if (out.items.len > 0 and std.mem.eql(u8, out.items[0], "--")) return out.items[1..];
    return out.items;
}

/// Parse the whole command line. error.Usage (exit 2) / error.HelpShown (exit 0).
pub fn parse(a: Allocator, iter: *ArgIter) !Cmd {
    const first = iter.next() orelse {
        sys.err("{s}", .{try mainHelp(a)});
        return error.Usage;
    };
    if (std.mem.eql(u8, first, "-h") or std.mem.eql(u8, first, "--help")) {
        sys.outBytes(try mainHelp(a));
        return error.HelpShown;
    }
    if (std.mem.eql(u8, first, "-V")) {
        sys.out("pull {s}\n", .{opts.version});
        return error.HelpShown;
    }
    if (std.mem.eql(u8, first, "--version")) {
        sys.out("pull {s}\nfeatures: {s}\n", .{ opts.version, try std.mem.join(a, " ", opts.features) });
        return error.HelpShown;
    }
    if (std.mem.eql(u8, first, "help")) {
        var words: std.ArrayList([]const u8) = .empty;
        while (iter.next()) |w| try words.append(a, w);
        const path = try std.mem.join(a, " ", words.items);
        if (path.len == 0) {
            sys.outBytes(try mainHelp(a));
        } else if (try leafHelp(a, path)) |h| {
            sys.outBytes(h);
        } else {
            sys.err("error: unrecognized subcommand '{s}'\n\nUsage: pull <COMMAND>\n\nFor more information, try '--help'.\n", .{words.items[0]});
            return error.Usage;
        }
        return error.HelpShown;
    }
    if (first.len > 0 and first[0] == '-') {
        sys.err("error: unexpected argument '{s}' found\n\nUsage: pull <COMMAND>\n\nFor more information, try '--help'.\n", .{first});
        return error.Usage;
    }
    if (!enabled(&top_commands, first)) {
        sys.err("error: unrecognized subcommand '{s}'\n\nUsage: pull <COMMAND>\n\nFor more information, try '--help'.\n", .{first});
        return error.Usage;
    }
    const eq = std.mem.eql;
    if (eq(u8, first, "init")) {
        const res = try parseSub(a, "init", &comptime clap.parseParamsComptime(
            \\-h, --help
            \\--org <str>
            \\
        ), iter);
        return .{ .init = .{ .org = res.args.org } };
    }
    if (eq(u8, first, "repo")) return parseGroup(a, "repo", iter);
    if (eq(u8, first, "worktree")) return parseGroup(a, "worktree", iter);
    if (eq(u8, first, "tool")) return parseGroup(a, "tool", iter);
    if (eq(u8, first, "launchctl")) return parseGroup(a, "launchctl", iter);
    if (eq(u8, first, "session")) return parseGroup(a, "session", iter);
    if (eq(u8, first, "haxy")) return parseGroup(a, "haxy", iter);
    if (eq(u8, first, "launchd")) return noArgs(a, "launchd", iter, .launchd);
    if (eq(u8, first, "mcp")) {
        const res = try parseSub(a, "mcp", &comptime clap.parseParamsComptime(
            \\-h, --help
            \\--root <str>
            \\
        ), iter);
        return .{ .mcp = .{ .root = res.args.root } };
    }
    if (eq(u8, first, "sync")) return noArgs(a, "sync", iter, .sync);
    if (eq(u8, first, "update")) return noArgs(a, "update", iter, .update);
    if (eq(u8, first, "push")) return noArgs(a, "push", iter, .push);
    if (eq(u8, first, "whoami")) return noArgs(a, "whoami", iter, .whoami);
    if (eq(u8, first, "mcp-servers")) return noArgs(a, "mcp-servers", iter, .mcp_servers);
    if (eq(u8, first, "status")) {
        const res = try parseSub(a, "status", &comptime clap.parseParamsComptime(
            \\-h, --help
            \\--json
            \\
        ), iter);
        return .{ .status = .{ .json = res.args.json != 0 } };
    }
    if (eq(u8, first, "env")) {
        const res = try parseSub(a, "env", &comptime clap.parseParamsComptime(
            \\-h, --help
            \\--envrc
            \\
        ), iter);
        return .{ .env = .{ .envrc = res.args.envrc != 0 } };
    }
    if (eq(u8, first, "add") or eq(u8, first, "unstage")) {
        const params = comptime clap.parseParamsComptime(
            \\-h, --help
            \\<str>...
            \\
        );
        const res = if (eq(u8, first, "add")) try parseSub(a, "add", &params, iter) else try parseSub(a, "unstage", &params, iter);
        if (res.positionals[0].len == 0)
            return missing(a, first, "<PATHS>...", try std.fmt.allocPrint(a, "pull {s} <PATHS>...", .{first}));
        return if (eq(u8, first, "add")) .{ .add = res.positionals[0] } else .{ .unstage = res.positionals[0] };
    }
    if (eq(u8, first, "commit")) {
        const res = try parseSub(a, "commit", &comptime clap.parseParamsComptime(
            \\-h, --help
            \\-m, --message <str>
            \\-a, --all
            \\--no-verify
            \\<str>...
            \\
        ), iter);
        const m = res.args.message orelse
            return missing(a, "commit", "--message <MESSAGE>", "pull commit --message <MESSAGE> [PATHS]...");
        return .{ .commit = .{ .message = m, .all = res.args.all != 0, .no_verify = res.args.@"no-verify" != 0, .paths = res.positionals[0] } };
    }
    if (eq(u8, first, "lint")) {
        const res = try parseSub(a, "lint", &comptime clap.parseParamsComptime(
            \\-h, --help
            \\<str>...
            \\
        ), iter);
        return .{ .lint = (try one(a, "lint", res.positionals[0])) orelse return missing(a, "lint", "<MESSAGE>", "pull lint <MESSAGE>") };
    }
    if (eq(u8, first, "shell")) return .{ .shell = try rest(a, "shell", iter) };
    if (eq(u8, first, "each")) {
        const cmd = try rest(a, "each", iter);
        if (cmd.len == 0) return missing(a, "each", "<CMD>...", "pull each <CMD>...");
        return .{ .each = cmd };
    }
    unreachable;
}

/// The single value of an `<X>` positional (parsed as `<X>...`, since zig-clap
/// lets a repeated positional overwrite the first): extras are a usage error.
fn one(a: Allocator, path: []const u8, vals: []const []const u8) !?[]const u8 {
    if (vals.len > 1) return usageError(a, path, "unexpected argument '{s}' found", .{vals[1]});
    return if (vals.len == 1) vals[0] else null;
}

fn noArgs(a: Allocator, comptime path: []const u8, iter: *ArgIter, cmd: Cmd) !Cmd {
    const res = try parseSub(a, path, &comptime clap.parseParamsComptime(
        \\-h, --help
        \\
    ), iter);
    _ = res;
    return cmd;
}

fn parseGroup(a: Allocator, comptime group: []const u8, iter: *ArgIter) !Cmd {
    const subs: []const Sub = if (comptime std.mem.eql(u8, group, "repo")) &repo_commands else if (comptime std.mem.eql(u8, group, "worktree")) &worktree_commands else if (comptime std.mem.eql(u8, group, "launchctl")) &launchctl_commands else if (comptime std.mem.eql(u8, group, "session")) &session_commands else if (comptime std.mem.eql(u8, group, "haxy")) &haxy_commands else &tool_commands;
    const about = aboutOf(&top_commands, group);
    const sub = iter.next() orelse {
        sys.err("{s}", .{try groupHelp(a, group, about, subs)});
        return error.Usage;
    };
    const eq = std.mem.eql;
    if (eq(u8, sub, "-h") or eq(u8, sub, "--help")) {
        sys.outBytes(try groupHelp(a, group, about, subs));
        return error.HelpShown;
    }
    if (eq(u8, sub, "help")) {
        if (iter.next()) |w| {
            const p = try std.fmt.allocPrint(a, "{s} {s}", .{ group, w });
            if (try leafHelp(a, p)) |h| {
                sys.outBytes(h);
                return error.HelpShown;
            }
            return usageError(a, group, "unrecognized subcommand '{s}'", .{w});
        }
        sys.outBytes(try groupHelp(a, group, about, subs));
        return error.HelpShown;
    }
    if (!enabled(subs, sub)) return usageError(a, group, "unrecognized subcommand '{s}'", .{sub});

    if (comptime std.mem.eql(u8, group, "repo")) {
        if (eq(u8, sub, "add")) {
            const res = try parseSub(a, "repo add", &comptime clap.parseParamsComptime(
                \\-h, --help
                \\--name <str>
                \\--branch <str>
                \\<str>...
                \\
            ), iter);
            const up = (try one(a, "repo add", res.positionals[0])) orelse return missing(a, "repo add", "<UPSTREAM>", "pull repo add <UPSTREAM>");
            return .{ .repo_add = .{ .upstream = up, .name = res.args.name, .branch = res.args.branch orelse "main" } };
        }
        if (eq(u8, sub, "rm")) {
            const res = try parseSub(a, "repo rm", &comptime clap.parseParamsComptime(
                \\-h, --help
                \\<str>...
                \\
            ), iter);
            return .{ .repo_rm = (try one(a, "repo rm", res.positionals[0])) orelse return missing(a, "repo rm", "<NAME>", "pull repo rm <NAME>") };
        }
        return noArgs(a, "repo list", iter, .repo_list);
    }
    if (comptime std.mem.eql(u8, group, "worktree")) {
        if (eq(u8, sub, "add")) {
            const res = try parseSub(a, "worktree add", &comptime clap.parseParamsComptime(
                \\-h, --help
                \\-b, --branch <str>
                \\<str>...
                \\
            ), iter);
            const n = (try one(a, "worktree add", res.positionals[0])) orelse return missing(a, "worktree add", "<NAME>", "pull worktree add <NAME>");
            return .{ .worktree_add = .{ .name = n, .branch = res.args.branch } };
        }
        if (eq(u8, sub, "rm")) {
            const res = try parseSub(a, "worktree rm", &comptime clap.parseParamsComptime(
                \\-h, --help
                \\--force
                \\<str>...
                \\
            ), iter);
            const n = (try one(a, "worktree rm", res.positionals[0])) orelse return missing(a, "worktree rm", "<NAME>", "pull worktree rm <NAME>");
            return .{ .worktree_rm = .{ .name = n, .force = res.args.force != 0 } };
        }
        return noArgs(a, "worktree list", iter, .worktree_list);
    }
    if (comptime std.mem.eql(u8, group, "launchctl")) return parseLaunchctl(a, sub, iter);
    if (comptime std.mem.eql(u8, group, "session")) return parseSession(a, sub, iter);
    if (comptime std.mem.eql(u8, group, "haxy")) return parseHaxy(a, sub, iter);
    // tool
    if (eq(u8, sub, "add") or eq(u8, sub, "rm")) {
        const params = comptime clap.parseParamsComptime(
            \\-h, --help
            \\<str>...
            \\
        );
        const res = if (eq(u8, sub, "add")) try parseSub(a, "tool add", &params, iter) else try parseSub(a, "tool rm", &params, iter);
        if (res.positionals[0].len == 0)
            return missing(a, "tool", "<NAMES>...", try std.fmt.allocPrint(a, "pull tool {s} <NAMES>...", .{sub}));
        return if (eq(u8, sub, "add")) .{ .tool_add = res.positionals[0] } else .{ .tool_rm = res.positionals[0] };
    }
    if (eq(u8, sub, "import")) {
        const res = try parseSub(a, "tool import", &comptime clap.parseParamsComptime(
            \\-h, --help
            \\<str>...
            \\
        ), iter);
        return .{ .tool_import = (try one(a, "tool import", res.positionals[0])) orelse "Brewfile" };
    }
    if (eq(u8, sub, "sync")) return noArgs(a, "tool sync", iter, .tool_sync);
    if (eq(u8, sub, "list")) return noArgs(a, "tool list", iter, .tool_list);
    return noArgs(a, "tool gc", iter, .tool_gc);
}

/// `launchctl <sub>` (the subcommand is known to exist).
fn parseLaunchctl(a: Allocator, sub: []const u8, iter: *ArgIter) !Cmd {
    const eq = std.mem.eql;
    const label_params = comptime clap.parseParamsComptime(
        \\-h, --help
        \\<str>...
        \\
    );
    if (eq(u8, sub, "load")) {
        const res = try parseSub(a, "launchctl load", &label_params, iter);
        return .{ .launchctl_load = res.positionals[0] };
    }
    if (eq(u8, sub, "list")) {
        const res = try parseSub(a, "launchctl list", &comptime clap.parseParamsComptime(
            \\-h, --help
            \\--json
            \\--all
            \\
        ), iter);
        return .{ .launchctl_list = .{ .json = res.args.json != 0, .all = res.args.all != 0 } };
    }
    if (eq(u8, sub, "print")) {
        const res = try parseSub(a, "launchctl print", &comptime clap.parseParamsComptime(
            \\-h, --help
            \\--json
            \\<str>...
            \\
        ), iter);
        const l = (try one(a, "launchctl print", res.positionals[0])) orelse return missing(a, "", "<LABEL>", "pull launchctl print <LABEL>");
        return .{ .launchctl_print = .{ .label = l, .json = res.args.json != 0 } };
    }
    if (eq(u8, sub, "kickstart")) {
        const res = try parseSub(a, "launchctl kickstart", &comptime clap.parseParamsComptime(
            \\-h, --help
            \\-k
            \\<str>...
            \\
        ), iter);
        const l = (try one(a, "launchctl kickstart", res.positionals[0])) orelse return missing(a, "", "<LABEL>", "pull launchctl kickstart <LABEL>");
        return .{ .launchctl_kickstart = .{ .label = l, .k = res.args.k != 0 } };
    }
    if (eq(u8, sub, "shutdown")) return noArgs(a, "launchctl shutdown", iter, .launchctl_shutdown);
    // unload / start / stop: one <LABEL>.
    const res = if (eq(u8, sub, "unload"))
        try parseSub(a, "launchctl unload", &label_params, iter)
    else if (eq(u8, sub, "start"))
        try parseSub(a, "launchctl start", &label_params, iter)
    else
        try parseSub(a, "launchctl stop", &label_params, iter);
    const path = try std.fmt.allocPrint(a, "launchctl {s}", .{sub});
    const l = (try one(a, path, res.positionals[0])) orelse
        return missing(a, "", "<LABEL>", try std.fmt.allocPrint(a, "pull {s} <LABEL>", .{path}));
    if (eq(u8, sub, "unload")) return .{ .launchctl_unload = l };
    if (eq(u8, sub, "start")) return .{ .launchctl_start = l };
    return .{ .launchctl_stop = l };
}

/// clap-style value error for a numeric option.
fn parseMs(name: []const u8, v: []const u8) !u64 {
    return std.fmt.parseInt(u64, v, 10) catch {
        const why = if (v.len == 0) "cannot parse integer from empty string" else "invalid digit found in string";
        sys.err("error: invalid value '{s}' for '{s}': {s}\n\nFor more information, try '--help'.\n", .{ v, name, why });
        return error.Usage;
    };
}

/// `session new` / `session run`: options, then NAME, then a trailing command
/// (taken verbatim from its first word on, hyphens included).
fn parseTrailing(a: Allocator, comptime path: []const u8, iter: *ArgIter) !Cmd {
    const eq = std.mem.eql;
    const is_new = comptime std.mem.eql(u8, path, "session new");
    var name: ?[]const u8 = null;
    var cmd: std.ArrayList([]const u8) = .empty;
    var detached = false;
    var keep_alive = false;
    var cwd: ?[]const u8 = null;
    var idle: u64 = 800;
    var timeout: u64 = 60_000;
    while (iter.next()) |arg| {
        if (name != null and cmd.items.len > 0) {
            try cmd.append(a, arg);
            continue;
        }
        if (eq(u8, arg, "--")) {
            while (iter.next()) |x| {
                if (name == null) name = x else try cmd.append(a, x);
            }
            break;
        }
        const flag = arg.len > 1 and arg[0] == '-';
        if (flag and (eq(u8, arg, "-h") or eq(u8, arg, "--help"))) {
            sys.outBytes((try leafHelp(a, path)).?);
            return error.HelpShown;
        }
        if (flag and is_new and (eq(u8, arg, "-d") or eq(u8, arg, "--detached"))) {
            detached = true;
        } else if (flag and is_new and eq(u8, arg, "--keep-alive")) {
            keep_alive = true;
        } else if (flag and is_new and (eq(u8, arg, "-c") or eq(u8, arg, "--cwd") or std.mem.startsWith(u8, arg, "--cwd="))) {
            cwd = if (std.mem.indexOfScalar(u8, arg, '=')) |i| arg[i + 1 ..] else iter.next() orelse {
                sys.err("error: a value is required for '--cwd <CWD>' but none was supplied\n\nFor more information, try '--help'.\n", .{});
                return error.Usage;
            };
        } else if (flag and !is_new and (eq(u8, arg, "--idle") or std.mem.startsWith(u8, arg, "--idle="))) {
            const v = if (std.mem.indexOfScalar(u8, arg, '=')) |i| arg[i + 1 ..] else iter.next() orelse {
                sys.err("error: a value is required for '--idle <IDLE>' but none was supplied\n\nFor more information, try '--help'.\n", .{});
                return error.Usage;
            };
            idle = try parseMs("--idle <IDLE>", v);
        } else if (flag and !is_new and (eq(u8, arg, "--timeout") or std.mem.startsWith(u8, arg, "--timeout="))) {
            const v = if (std.mem.indexOfScalar(u8, arg, '=')) |i| arg[i + 1 ..] else iter.next() orelse {
                sys.err("error: a value is required for '--timeout <TIMEOUT>' but none was supplied\n\nFor more information, try '--help'.\n", .{});
                return error.Usage;
            };
            timeout = try parseMs("--timeout <TIMEOUT>", v);
        } else if (flag and name == null) {
            return usageError(a, path, "unexpected argument '{s}' found\n\n  tip: to pass '{s}' as a value, use '-- {s}'", .{ arg, arg, arg });
        } else if (name == null) {
            name = arg;
        } else {
            try cmd.append(a, arg);
        }
    }
    if (is_new) {
        const n = name orelse return missing(a, "", "<NAME>", "pull session new <NAME> [CMD]...");
        return .{ .session_new = .{ .name = n, .detached = detached, .cwd = cwd, .keep_alive = keep_alive, .cmd = cmd.items } };
    }
    if (name == null) return missing(a, "", "<NAME>\n  <COMMAND>...", "pull session run <NAME> <COMMAND>...");
    if (cmd.items.len == 0) return missing(a, "", "<COMMAND>...", "pull session run <NAME> <COMMAND>...");
    return .{ .session_run = .{ .name = name.?, .idle = idle, .timeout = timeout, .command = cmd.items } };
}

/// `session <sub>` (the subcommand is known to exist).
fn parseSession(a: Allocator, sub: []const u8, iter: *ArgIter) !Cmd {
    const eq = std.mem.eql;
    if (eq(u8, sub, "new")) return parseTrailing(a, "session new", iter);
    if (eq(u8, sub, "run")) return parseTrailing(a, "session run", iter);
    if (eq(u8, sub, "ls")) {
        const res = try parseSub(a, "session ls", &comptime clap.parseParamsComptime(
            \\-h, --help
            \\--json
            \\
        ), iter);
        return .{ .session_ls = .{ .json = res.args.json != 0 } };
    }
    if (eq(u8, sub, "send")) {
        const res = try parseSub(a, "session send", &comptime clap.parseParamsComptime(
            \\-h, --help
            \\-e, --enter
            \\<str>...
            \\
        ), iter);
        const ps = res.positionals[0];
        if (ps.len == 0) return missing(a, "", "<NAME>", "pull session send <NAME> [TEXT]...");
        return .{ .session_send = .{ .name = ps[0], .text = ps[1..], .enter = res.args.enter != 0 } };
    }
    if (eq(u8, sub, "capture")) {
        const res = try parseSub(a, "session capture", &comptime clap.parseParamsComptime(
            \\-h, --help
            \\-e, --escapes
            \\<str>...
            \\
        ), iter);
        const n = (try one(a, "session capture", res.positionals[0])) orelse return missing(a, "", "<NAME>", "pull session capture <NAME>");
        return .{ .session_capture = .{ .name = n, .escapes = res.args.escapes != 0 } };
    }
    const params = comptime clap.parseParamsComptime(
        \\-h, --help
        \\<str>...
        \\
    );
    const res = if (eq(u8, sub, "attach")) try parseSub(a, "session attach", &params, iter) else try parseSub(a, "session kill", &params, iter);
    const path = try std.fmt.allocPrint(a, "session {s}", .{sub});
    const n = (try one(a, path, res.positionals[0])) orelse
        return missing(a, "", "<NAME>", try std.fmt.allocPrint(a, "pull {s} <NAME>", .{path}));
    return if (eq(u8, sub, "attach")) .{ .session_attach = n } else .{ .session_kill = n };
}

/// `haxy <sub>` (the subcommand is known to exist).
fn parseHaxy(a: Allocator, sub: []const u8, iter: *ArgIter) !Cmd {
    const eq = std.mem.eql;
    const positional = comptime clap.parseParamsComptime(
        \\-h, --help
        \\<str>...
        \\
    );
    if (eq(u8, sub, "sync")) return .{ .haxy_sync = (try parseSub(a, "haxy sync", &positional, iter)).positionals[0] };
    if (eq(u8, sub, "issues")) {
        const res = try parseSub(a, "haxy issues", &comptime clap.parseParamsComptime(
            \\-h, --help
            \\--all
            \\--json
            \\<str>...
            \\
        ), iter);
        return .{ .haxy_issues = .{ .repo = try one(a, "haxy issues", res.positionals[0]), .all = res.args.all != 0, .json = res.args.json != 0 } };
    }
    if (eq(u8, sub, "new")) {
        const res = try parseSub(a, "haxy new", &comptime clap.parseParamsComptime(
            \\-h, --help
            \\-t, --title <str>
            \\-b, --body <str>
            \\-l, --labels <str>
            \\<str>...
            \\
        ), iter);
        const usage = "pull haxy new --title <TITLE> <REPO>";
        const repo = (try one(a, "haxy new", res.positionals[0])) orelse return missing(a, "", "<REPO>", usage);
        const title = res.args.title orelse return missing(a, "", "--title <TITLE>", usage);
        return .{ .haxy_new = .{ .repo = repo, .title = title, .body = res.args.body orelse "", .labels = res.args.labels orelse "" } };
    }
    if (eq(u8, sub, "open")) {
        const res = try parseSub(a, "haxy open", &positional, iter);
        return .{ .haxy_open = (try one(a, "haxy open", res.positionals[0])) orelse return missing(a, "", "<REPO>", "pull haxy open <REPO>") };
    }
    // show / comment / close / reopen: REPO ISSUE (+ TEXT for comment).
    const path = try std.fmt.allocPrint(a, "haxy {s}", .{sub});
    const res = if (eq(u8, sub, "show"))
        try parseSub(a, "haxy show", &positional, iter)
    else if (eq(u8, sub, "comment"))
        try parseSub(a, "haxy comment", &positional, iter)
    else if (eq(u8, sub, "close"))
        try parseSub(a, "haxy close", &positional, iter)
    else
        try parseSub(a, "haxy reopen", &positional, iter);
    const ps = res.positionals[0];
    const want: usize = if (eq(u8, sub, "comment")) 3 else 2;
    const names = [_][]const u8{ "<REPO>", "<ISSUE>", "<TEXT>" };
    if (ps.len < want) return missing(a, "", try std.mem.join(a, "\n  ", names[ps.len..want]), usageOf(a, path));
    if (ps.len > want) return usageError(a, path, "unexpected argument '{s}' found", .{ps[want]});
    if (eq(u8, sub, "show")) return .{ .haxy_show = .{ .repo = ps[0], .issue = ps[1] } };
    if (eq(u8, sub, "comment")) return .{ .haxy_comment = .{ .repo = ps[0], .issue = ps[1], .text = ps[2] } };
    return .{ .haxy_status = .{ .repo = ps[0], .issue = ps[1], .close = eq(u8, sub, "close") } };
}

test "help layout matches clap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings(
        "Create pullfile.plist and local.toml in the current directory\n\nUsage: pull init [OPTIONS]\n\nOptions:\n      --org <ORG>  Org identity to use (selects [orgs.<org>] in local.toml)\n  -h, --help       Print help\n",
        (try leafHelp(a, "init")).?,
    );
}
