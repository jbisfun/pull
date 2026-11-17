//! Command-line interface. Subcommands of compiled-out features don't exist.

use clap::{Parser, Subcommand};
use std::path::PathBuf;

/// Multi-repo git wrapper driven by pullfile.plist.
#[derive(Parser)]
#[command(name = "pull", version, long_version = LONG_VERSION)]
pub struct Cli {
    #[command(subcommand)]
    pub cmd: Cmd,
}

const LONG_VERSION: &str = concat!(
    env!("CARGO_PKG_VERSION"),
    "\nfeatures: ",
    env!("PULL_FEATURES")
);

#[derive(Subcommand)]
pub enum Cmd {
    /// Create pullfile.plist and local.toml in the current directory.
    Init {
        /// Org identity to use (selects [orgs.<org>] in local.toml).
        #[arg(long)]
        org: Option<String>,
    },
    /// Manage the repo list.
    #[command(subcommand)]
    Repo(RepoCmd),
    /// Clone missing repos, fetch, and fast-forward to pinned commits. Runs `pull` hooks.
    Sync,
    /// Fetch and fast-forward every repo to its upstream branch, then re-pin. Runs `pull` hooks.
    Update,
    /// Show branch, pin and changes for every repo.
    Status {
        /// Machine-readable: per repo branch, head, pin, ahead/behind and changed files.
        #[arg(long)]
        json: bool,
    },
    /// Unstage paths (back to HEAD); each path is routed to its repo.
    Unstage {
        #[arg(required = true)]
        paths: Vec<PathBuf>,
    },
    /// Stage paths; each path is routed to the repo it lives in.
    Add {
        #[arg(required = true)]
        paths: Vec<PathBuf>,
    },
    /// One commit across every repo with staged changes; pins the new commits.
    Commit {
        #[arg(short, long)]
        message: String,
        /// Stage all tracked modifications first (like `git commit -a`).
        #[arg(short, long)]
        all: bool,
        /// Skip precommit/postcommit hooks.
        #[arg(long)]
        no_verify: bool,
        /// Only stage+commit these paths (routed to their repos).
        paths: Vec<PathBuf>,
    },
    /// Push every repo whose branch is ahead of origin.
    Push,
    #[cfg(feature = "lint")]
    /// Check a message against the pullfile lint rules.
    Lint { message: String },
    /// Print the identity commits will be written with.
    Whoami,
    #[cfg(feature = "env")]
    /// Print the workspace env (pullfile `env` + local.toml `[env]`) as shell exports.
    /// `eval "$(pull env)"`, or `--envrc` to write a direnv .envrc that does it.
    Env {
        #[arg(long)]
        envrc: bool,
    },
    #[cfg(feature = "env")]
    /// Start $SHELL (or the given command) with the workspace env applied.
    Shell {
        #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
        cmd: Vec<String>,
    },
    #[cfg(feature = "mcp")]
    /// MCP server on stdio for agents: multi-repo context, programs, stateful terminals.
    Mcp {
        /// Workspace root (default: found from the current directory).
        #[arg(long)]
        root: Option<PathBuf>,
    },
    #[cfg(feature = "launchd")]
    /// Run the workspace job daemon in the foreground (started automatically when needed).
    #[command(hide = true)]
    Launchd,
    #[cfg(feature = "launchd")]
    /// launchd-style job control: jobs from the pullfile `jobs` or launchd .plist files.
    #[command(subcommand)]
    Launchctl(LaunchctlCmd),
    #[cfg(feature = "launchd")]
    /// tmux-style terminal sessions (headless jobs a human can attach to and an agent can
    /// drive), started with the workspace env.
    #[command(subcommand)]
    Session(SessionCmd),
    #[cfg(feature = "worktree")]
    /// Workspace worktrees under .worktrees/NAME (every repo as a git worktree).
    #[command(subcommand)]
    Worktree(WorktreeCmd),
    #[cfg(feature = "tool")]
    /// Workspace packages: pullfile `tool` (Brewfile-style), poured from Linuxbrew bottles
    /// and linked into .pull/tool (on PATH in `pull env`).
    #[command(subcommand)]
    Tool(ToolCmd),
    /// Run a command in every cloned repo (e.g. `pull each git log -1`).
    Each {
        #[arg(required = true, trailing_var_arg = true, allow_hyphen_values = true)]
        cmd: Vec<String>,
    },
}

#[cfg(feature = "launchd")]
#[derive(Subcommand)]
pub enum LaunchctlCmd {
    /// Load jobs from launchd .plist files, or (no files) the pullfile's `jobs`.
    Load {
        paths: Vec<PathBuf>,
    },
    /// Stop a job and forget it.
    Unload {
        label: String,
    },
    /// PID, last exit status and label of every job, like launchctl list.
    List {
        #[arg(long)]
        json: bool,
        /// Also pullfile jobs that aren't loaded (state "unloaded"), and don't start the
        /// daemon just to list.
        #[arg(long)]
        all: bool,
    },
    /// Everything about one job: state, program, environment, foreground program.
    Print {
        label: String,
        #[arg(long)]
        json: bool,
    },
    Start {
        label: String,
    },
    Stop {
        label: String,
    },
    /// Start a job; with -k, kill and restart it if it is running.
    Kickstart {
        label: String,
        #[arg(short)]
        k: bool,
    },
    /// Stop every job and the daemon.
    Shutdown,
}

#[cfg(feature = "launchd")]
#[derive(Subcommand)]
pub enum SessionCmd {
    /// Start a session running CMD (default: your shell) and attach, unless -d.
    New {
        name: String,
        /// Don't attach (like tmux new -d).
        #[arg(short, long)]
        detached: bool,
        /// Working directory (default: the workspace root).
        #[arg(short = 'c', long)]
        cwd: Option<PathBuf>,
        /// Restart the command whenever it exits (launchd KeepAlive).
        #[arg(long)]
        keep_alive: bool,
        #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
        cmd: Vec<String>,
    },
    /// Sessions with their running program and directory (tmux ls).
    Ls {
        #[arg(long)]
        json: bool,
    },
    /// Attach this terminal to a session; detach with ctrl-\.
    Attach { name: String },
    /// Type TEXT into a session (tmux send-keys).
    Send {
        name: String,
        text: Vec<String>,
        /// Press enter after the text.
        #[arg(short, long)]
        enter: bool,
    },
    /// Print a session's screen (tmux capture-pane).
    Capture {
        name: String,
        /// Keep colours and attributes (ANSI escapes).
        #[arg(short, long)]
        escapes: bool,
    },
    /// For agents: type COMMAND + enter, wait until output settles, print the screen.
    Run {
        name: String,
        /// Settle time with no new output, in ms.
        #[arg(long, default_value_t = 800)]
        idle: u64,
        /// Give up waiting after this many ms.
        #[arg(long, default_value_t = 60000)]
        timeout: u64,
        #[arg(required = true, trailing_var_arg = true, allow_hyphen_values = true)]
        command: Vec<String>,
    },
    /// Stop and remove a session.
    Kill { name: String },
}

#[cfg(feature = "tool")]
#[derive(Subcommand)]
pub enum ToolCmd {
    /// Install the pullfile's packages and swap .pull/tool to exactly that set.
    Sync,
    /// Add formulae to the pullfile and sync.
    Add {
        #[arg(required = true)]
        names: Vec<String>,
    },
    /// Remove formulae from the pullfile and sync.
    Rm {
        #[arg(required = true)]
        names: Vec<String>,
    },
    /// Merge a Brewfile's taps and formulae into the pullfile and sync.
    Import {
        #[arg(default_value = "Brewfile")]
        file: PathBuf,
    },
    /// List installed packages (`*` = linked into the profile).
    List,
    /// Delete store kegs that no workspace profile uses.
    Gc,
}

#[cfg(feature = "worktree")]
#[derive(Subcommand)]
pub enum WorktreeCmd {
    /// Create .worktrees/NAME: each repo checked out on BRANCH (default NAME).
    Add {
        name: String,
        #[arg(short, long)]
        branch: Option<String>,
    },
    /// List workspace worktrees.
    List,
    /// Remove a workspace worktree (branches are kept).
    Rm {
        name: String,
        #[arg(long)]
        force: bool,
    },
}

#[derive(Subcommand)]
pub enum RepoCmd {
    /// Add a repo; it will be cloned to <root>/<name>.
    Add {
        upstream: String,
        #[arg(long)]
        name: Option<String>,
        #[arg(long, default_value = "main")]
        branch: String,
    },
    /// Remove a repo from the pullfile (does not delete the directory).
    Rm { name: String },
    /// List repos.
    List,
}
