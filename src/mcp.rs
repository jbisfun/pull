//! `pull mcp`: an MCP server (stdio) over the workspace, for agents.
//!
//! Multi-repo context (workspace overview, status, diffs, logs, search, files), programs
//! (one-shot commands with the workspace env) and stateful terminals (the launchd
//! sessions: they persist between calls and across agents, and a human can attach to the
//! same terminal with `pull session attach`).

use crate::config::{Local, Pullfile};
use crate::git;
use crate::launchd::{self, KeepAlive, Request, Response, client};
use git2::{DiffFormat, DiffOptions, Repository, Sort};
use rmcp::{
    ServerHandler, ServiceExt,
    handler::server::{router::tool::ToolRouter, wrapper::Parameters},
    model::{ServerCapabilities, ServerConfig},
    schemars, tool, tool_handler, tool_router,
};
use serde::Deserialize;
use std::collections::BTreeMap;
use std::fmt::Write as _;
use std::path::{Path, PathBuf};
use std::time::Duration;

const MAX_OUTPUT: usize = 60_000;

type ToolResult = Result<String, String>;

fn err(e: impl std::fmt::Display) -> String {
    format!("{e:#}")
}

/// Keep tool output within what an agent can take in one go.
fn truncate(mut s: String, max: usize) -> String {
    if s.len() > max {
        let mut cut = max;
        while !s.is_char_boundary(cut) {
            cut -= 1;
        }
        let total = s.len();
        s.truncate(cut);
        let _ = write!(s, "\n… truncated ({total} bytes total)");
    }
    s
}

#[derive(Clone)]
pub struct PullMcp {
    root: PathBuf,
    tool_router: ToolRouter<Self>,
}

#[derive(Deserialize, schemars::JsonSchema)]
pub struct RepoArg {
    /// Repo name from the pullfile; omit for every repo.
    pub repo: Option<String>,
}

#[derive(Deserialize, schemars::JsonSchema)]
pub struct DiffArgs {
    /// Repo name; omit for every repo.
    pub repo: Option<String>,
    /// Only this path (relative to the repo).
    pub path: Option<String>,
    /// Staged changes (index vs HEAD) instead of unstaged (worktree vs index).
    #[serde(default)]
    pub staged: bool,
}

#[derive(Deserialize, schemars::JsonSchema)]
pub struct LogArgs {
    /// Repo name; omit for every repo.
    pub repo: Option<String>,
    /// Commits per repo (default 10).
    pub limit: Option<usize>,
}

#[derive(Deserialize, schemars::JsonSchema)]
pub struct GrepArgs {
    /// Regular expression (Rust/ripgrep syntax; smart case).
    pub pattern: String,
    /// Repo name; omit to search every repo.
    pub repo: Option<String>,
    /// Glob of files to include, e.g. "*.rs" or "src/**".
    pub glob: Option<String>,
    /// Maximum matching lines (default 200).
    pub max_results: Option<usize>,
}

#[derive(Deserialize, schemars::JsonSchema)]
pub struct FilesArgs {
    /// Directory relative to the workspace root (default: the root).
    pub path: Option<String>,
    /// Glob of files to include.
    pub glob: Option<String>,
    /// Maximum entries (default 500).
    pub max_results: Option<usize>,
}

#[derive(Deserialize, schemars::JsonSchema)]
pub struct ReadArgs {
    /// File path relative to the workspace root (e.g. "pull/src/main.rs").
    pub path: String,
    /// First line, 1-based (default 1).
    pub start_line: Option<usize>,
    /// Last line, inclusive (default: start + 400).
    pub end_line: Option<usize>,
}

#[derive(Deserialize, schemars::JsonSchema)]
pub struct ExecArgs {
    /// Shell command (sh -c), run with the workspace env.
    pub command: String,
    /// Working directory relative to the workspace root (default: the root).
    pub cwd: Option<String>,
    /// Kill it after this many ms (default 120000).
    pub timeout_ms: Option<u64>,
}

#[derive(Deserialize, schemars::JsonSchema)]
pub struct SessionNewArgs {
    /// Session name (unique in the workspace).
    pub name: String,
    /// Program and arguments; omit for an interactive shell.
    #[serde(default)]
    pub command: Vec<String>,
    /// Working directory relative to the workspace root (default: the root).
    pub cwd: Option<String>,
    /// Extra environment variables.
    #[serde(default)]
    pub env: BTreeMap<String, String>,
    /// Restart the program whenever it exits (servers, watchers).
    #[serde(default)]
    pub keep_alive: bool,
}

#[derive(Deserialize, schemars::JsonSchema)]
pub struct NameArg {
    /// Session (job) name.
    pub name: String,
}

#[derive(Deserialize, schemars::JsonSchema)]
pub struct SendArgs {
    pub name: String,
    /// Text to type. Escapes such as "\u0003" (ctrl-c) or "\u001b" (esc) are sent as is.
    pub text: String,
    /// Press enter after the text.
    #[serde(default)]
    pub enter: bool,
}

#[derive(Deserialize, schemars::JsonSchema)]
pub struct RunArgs {
    pub name: String,
    /// Command line to type into the session's shell.
    pub command: String,
    /// Output must be quiet this long to count as finished (default 800 ms).
    pub idle_ms: Option<u64>,
    /// Give up waiting after this long (default 60000 ms); the command keeps running.
    pub timeout_ms: Option<u64>,
}

#[derive(Deserialize, schemars::JsonSchema)]
pub struct JobArgs {
    /// Job label.
    pub label: String,
    /// One of: start, stop, restart, unload.
    pub action: String,
}

impl PullMcp {
    pub fn new(root: PathBuf) -> Self {
        Self {
            root,
            tool_router: Self::tool_router(),
        }
    }

    fn pullfile(&self) -> Result<Pullfile, String> {
        Pullfile::load(&self.root).map_err(err)
    }

    /// (name, repo) for `only`, or every cloned repo.
    fn repos(&self, only: Option<&str>) -> Result<Vec<(String, Repository)>, String> {
        let pf = self.pullfile()?;
        if let Some(name) = only
            && !pf.repos.iter().any(|r| r.name == name)
        {
            return Err(format!("no repo named {name} in the pullfile"));
        }
        Ok(pf
            .repos
            .iter()
            .filter(|r| only.is_none_or(|n| n == r.name))
            .filter_map(|r| {
                Repository::open(self.root.join(&r.name))
                    .ok()
                    .map(|repo| (r.name.clone(), repo))
            })
            .collect())
    }

    /// A path inside the workspace (no escaping it with `..`).
    fn inside(&self, rel: Option<&str>) -> Result<PathBuf, String> {
        let p = match rel {
            Some(r) if !r.is_empty() => self.root.join(r),
            _ => self.root.clone(),
        };
        let canon = p
            .canonicalize()
            .map_err(|e| format!("{}: {e}", p.display()))?;
        let root = self.root.canonicalize().map_err(err)?;
        if !canon.starts_with(&root) {
            return Err(format!("{} is outside the workspace", p.display()));
        }
        Ok(canon)
    }

    fn rel(&self, p: &Path) -> String {
        p.strip_prefix(&self.root)
            .unwrap_or(p)
            .display()
            .to_string()
    }

    fn env(&self) -> Vec<(String, String)> {
        let Ok(pf) = Pullfile::load(&self.root) else {
            return Vec::new();
        };
        let local = Local::load(&self.root).ok();
        crate::env::resolve(&self.root, &pf, local.as_ref()).unwrap_or_default()
    }

    fn launchd(&self, req: Request) -> Result<Response, String> {
        client::request(&self.root, &req).map_err(err)
    }

    fn capture(&self, name: &str) -> ToolResult {
        match self.launchd(Request::Capture {
            label: name.into(),
            escapes: false,
        })? {
            Response::Text(t) => Ok(t),
            _ => Err("unexpected reply".into()),
        }
    }
}

/// Run blocking work off the async runtime.
async fn blocking<T: Send + 'static>(f: impl FnOnce() -> T + Send + 'static) -> T {
    tokio::task::spawn_blocking(f).await.expect("tool panicked")
}

#[tool_router]
impl PullMcp {
    #[tool(
        description = "Overview of the pull workspace: root, every repo (upstream, branch, HEAD, pinned commit, ahead/behind origin, changed files), lint rules, env and jobs. Start here."
    )]
    fn workspace(&self) -> ToolResult {
        let pf = self.pullfile()?;
        let mut out = format!("root: {}\n", self.root.display());
        let _ = writeln!(
            out,
            "lint: max_subject_length={:?} no_description={}",
            pf.lint.max_subject_length, pf.lint.no_description
        );
        out.push_str("repos:\n");
        for r in &pf.repos {
            let _ = write!(out, "  {} ({}, branch {})", r.name, r.upstream, r.branch);
            let Ok(repo) = Repository::open(self.root.join(&r.name)) else {
                out.push_str(" not cloned\n");
                continue;
            };
            let head = git::head_oid(&repo);
            let branch = repo
                .head()
                .ok()
                .and_then(|h| h.shorthand().ok().map(String::from))
                .unwrap_or("(unborn)".into());
            let _ = write!(
                out,
                ": on {branch} at {}",
                head.map(git::short).unwrap_or("-".into())
            );
            match (&r.commit, head) {
                (Some(p), Some(h)) if *p != h.to_string() => {
                    let _ = write!(out, ", pinned {}", &p[..8.min(p.len())]);
                }
                (None, _) => out.push_str(", unpinned"),
                _ => {}
            }
            if let (Some(h), Some(o)) = (head, git::remote_oid(&repo, &r.branch))
                && h != o
                && let Ok((a, b)) = repo.graph_ahead_behind(h, o)
            {
                let _ = write!(out, ", +{a}/-{b} origin");
            }
            let changed = git::status_lines(&repo).map(|l| l.len()).unwrap_or(0);
            let _ = writeln!(out, ", {changed} changed");
        }
        let env = self.env();
        if !env.is_empty() {
            out.push_str("env:\n");
            for (k, v) in env.iter().filter(|(k, _)| k != "PATH") {
                let _ = writeln!(out, "  {k}={v}");
            }
        }
        if !pf.jobs.is_empty() {
            out.push_str("jobs:\n");
            for j in &pf.jobs {
                let _ = writeln!(out, "  {}: {}", j.label, j.argv().join(" "));
            }
        }
        Ok(out)
    }

    #[tool(description = "Changed files per repo (git status, XY format like `git status -s`).")]
    fn status(&self, Parameters(a): Parameters<RepoArg>) -> ToolResult {
        let mut out = String::new();
        for (name, repo) in self.repos(a.repo.as_deref())? {
            let lines = git::status_lines(&repo).map_err(err)?;
            let _ = writeln!(
                out,
                "{name}: {}",
                if lines.is_empty() { "clean" } else { "" }
            );
            for l in lines {
                let _ = writeln!(out, "  {l}");
            }
        }
        Ok(out)
    }

    #[tool(
        description = "Unified diff of uncommitted changes, per repo (unstaged by default, or staged)."
    )]
    fn diff(&self, Parameters(a): Parameters<DiffArgs>) -> ToolResult {
        let mut out = String::new();
        for (name, repo) in self.repos(a.repo.as_deref())? {
            let mut opts = DiffOptions::new();
            if let Some(p) = &a.path {
                opts.pathspec(p);
            }
            let diff = if a.staged {
                let head = repo.head().ok().and_then(|h| h.peel_to_tree().ok());
                repo.diff_tree_to_index(head.as_ref(), None, Some(&mut opts))
            } else {
                repo.diff_index_to_workdir(None, Some(&mut opts))
            }
            .map_err(err)?;
            if diff.deltas().len() == 0 {
                continue;
            }
            let _ = writeln!(out, "### {name}");
            diff.print(DiffFormat::Patch, |_, _, line| {
                match line.origin() {
                    '+' | '-' | ' ' => out.push(line.origin()),
                    _ => {}
                }
                out.push_str(&String::from_utf8_lossy(line.content()));
                out.len() < MAX_OUTPUT * 2
            })
            .ok();
        }
        if out.is_empty() {
            out = "no changes".into();
        }
        Ok(truncate(out, MAX_OUTPUT))
    }

    #[tool(description = "Recent commits per repo: short id, date, author, subject.")]
    fn log(&self, Parameters(a): Parameters<LogArgs>) -> ToolResult {
        let limit = a.limit.unwrap_or(10);
        let mut out = String::new();
        for (name, repo) in self.repos(a.repo.as_deref())? {
            let _ = writeln!(out, "{name}:");
            let mut walk = repo.revwalk().map_err(err)?;
            if walk.push_head().is_err() {
                continue;
            }
            walk.set_sorting(Sort::TIME).ok();
            for oid in walk.take(limit).flatten() {
                let Ok(c) = repo.find_commit(oid) else {
                    continue;
                };
                let when = c.time().seconds();
                let _ = writeln!(
                    out,
                    "  {} {} {} {}",
                    git::short(oid),
                    format_time(when),
                    c.author().name().unwrap_or("?"),
                    c.summary().ok().flatten().unwrap_or("")
                );
            }
        }
        Ok(out)
    }

    #[tool(
        description = "Search file contents across the workspace's repos with a regex (ripgrep's engine; respects .gitignore). Returns repo/path:line: text."
    )]
    fn grep(&self, Parameters(a): Parameters<GrepArgs>) -> ToolResult {
        use grep_regex::RegexMatcherBuilder;
        use grep_searcher::{BinaryDetection, SearcherBuilder, sinks::UTF8};
        let max = a.max_results.unwrap_or(200);
        let matcher = RegexMatcherBuilder::new()
            .case_smart(true)
            .build(&a.pattern)
            .map_err(err)?;
        let mut searcher = SearcherBuilder::new()
            .binary_detection(BinaryDetection::quit(0))
            .line_number(true)
            .build();
        let mut out = String::new();
        let mut n = 0;
        'repos: for (name, _) in self.repos(a.repo.as_deref())? {
            let dir = self.root.join(&name);
            for entry in self.walker(&dir, a.glob.as_deref())? {
                let Ok(entry) = entry else { continue };
                if !entry.file_type().is_some_and(|t| t.is_file()) {
                    continue;
                }
                let rel = self.rel(entry.path());
                let mut done = false;
                searcher
                    .search_path(
                        &matcher,
                        entry.path(),
                        UTF8(|line_no, line| {
                            let mut line = line.trim_end().to_string();
                            if line.len() > 300 {
                                line = truncate(line, 300);
                            }
                            let _ = writeln!(out, "{rel}:{line_no}: {line}");
                            n += 1;
                            done = n >= max;
                            Ok(!done)
                        }),
                    )
                    .ok();
                if done {
                    let _ = writeln!(out, "… stopped at {max} results");
                    break 'repos;
                }
            }
        }
        if out.is_empty() {
            out = "no matches".into();
        }
        Ok(truncate(out, MAX_OUTPUT))
    }

    #[tool(description = "List files under a workspace directory (respects .gitignore).")]
    fn list_files(&self, Parameters(a): Parameters<FilesArgs>) -> ToolResult {
        let dir = self.inside(a.path.as_deref())?;
        let max = a.max_results.unwrap_or(500);
        let mut out = String::new();
        let mut n = 0;
        for entry in self.walker(&dir, a.glob.as_deref())?.flatten() {
            if !entry.file_type().is_some_and(|t| t.is_file()) {
                continue;
            }
            let _ = writeln!(out, "{}", self.rel(entry.path()));
            n += 1;
            if n >= max {
                let _ = writeln!(out, "… stopped at {max} entries");
                break;
            }
        }
        Ok(out)
    }

    #[tool(description = "Read a file (path relative to the workspace root), with line numbers.")]
    fn read_file(&self, Parameters(a): Parameters<ReadArgs>) -> ToolResult {
        let path = self.inside(Some(&a.path))?;
        let text = std::fs::read_to_string(&path).map_err(|e| format!("{}: {e}", a.path))?;
        let start = a.start_line.unwrap_or(1).max(1);
        let end = a.end_line.unwrap_or(start + 400);
        let total = text.lines().count();
        let mut out = String::new();
        for (i, line) in text
            .lines()
            .enumerate()
            .skip(start - 1)
            .take(end + 1 - start)
        {
            let _ = writeln!(out, "{:>5}|{line}", i + 1);
        }
        if end < total {
            let _ = writeln!(
                out,
                "… {total} lines total; continue with start_line={}",
                end + 1
            );
        }
        Ok(truncate(out, MAX_OUTPUT))
    }

    #[tool(
        description = "Run a shell command to completion with the workspace env (PATH, toolchains) and return its exit code and output. For long-running or interactive programs use session_new instead."
    )]
    async fn exec(&self, Parameters(a): Parameters<ExecArgs>) -> ToolResult {
        let cwd = self.inside(a.cwd.as_deref())?;
        let env = self.env();
        let timeout = Duration::from_millis(a.timeout_ms.unwrap_or(120_000));
        let mut cmd = tokio::process::Command::new("sh");
        cmd.arg("-c")
            .arg(&a.command)
            .current_dir(cwd)
            .envs(env)
            .stdin(std::process::Stdio::null())
            .kill_on_drop(true);
        match tokio::time::timeout(timeout, cmd.output()).await {
            Err(_) => Err(format!(
                "timed out after {} ms (killed)",
                timeout.as_millis()
            )),
            Ok(Err(e)) => Err(err(e)),
            Ok(Ok(o)) => {
                let mut out = format!("exit {}\n", o.status.code().unwrap_or(-1));
                out.push_str(&String::from_utf8_lossy(&o.stdout));
                if !o.stderr.is_empty() {
                    out.push_str("\n[stderr]\n");
                    out.push_str(&String::from_utf8_lossy(&o.stderr));
                }
                Ok(truncate(out, MAX_OUTPUT))
            }
        }
    }

    #[tool(
        description = "Start a stateful terminal session (a PTY with the workspace env) running a shell or a program. It persists between calls; a human can watch it with `pull session attach NAME`."
    )]
    async fn session_new(&self, Parameters(a): Parameters<SessionNewArgs>) -> ToolResult {
        let cwd = self.inside(a.cwd.as_deref())?;
        let job = launchd::Job {
            label: a.name.clone(),
            program_arguments: a.command,
            working_directory: Some(cwd.display().to_string()),
            environment_variables: a.env,
            run_at_load: true,
            keep_alive: a.keep_alive.then_some(KeepAlive::Always(true)),
            throttle_interval: a.keep_alive.then_some(1),
            ..Default::default()
        };
        let this = self.clone();
        blocking(move || {
            this.launchd(Request::Load {
                jobs: vec![job],
                start: true,
            })?;
            std::thread::sleep(Duration::from_millis(300));
            this.capture(&a.name)
                .map(|screen| format!("started {}\n{screen}", a.name))
        })
        .await
    }

    #[tool(
        description = "Sessions and jobs: state, pid, last exit code, and the program currently running in each terminal with its working directory."
    )]
    async fn session_list(&self) -> ToolResult {
        let this = self.clone();
        blocking(move || match this.launchd(Request::List)? {
            Response::Jobs(jobs) => {
                let mut out = String::new();
                for j in jobs {
                    let _ = write!(out, "{}: {}", j.label, j.state);
                    if let Some(pid) = j.pid {
                        let _ = write!(out, ", pid {pid}");
                    }
                    if let Some(c) = j.last_exit {
                        let _ = write!(out, ", last exit {c}");
                    }
                    if let (Some(fg), Some(cwd)) = (&j.foreground, &j.foreground_cwd) {
                        let _ = write!(out, ", running {fg} in {cwd}");
                    }
                    if j.attached > 0 {
                        let _ = write!(out, ", {} attached", j.attached);
                    }
                    let _ = writeln!(out, " ({})", j.argv.join(" "));
                }
                if out.is_empty() {
                    out = "no sessions".into();
                }
                Ok(out)
            }
            _ => Err("unexpected reply".into()),
        })
        .await
    }

    #[tool(
        description = "Type a command into a session's shell, wait until its output settles, and return the screen. The session keeps its state (cwd, env, history) between calls."
    )]
    async fn session_run(&self, Parameters(a): Parameters<RunArgs>) -> ToolResult {
        let this = self.clone();
        blocking(move || {
            this.launchd(Request::Send {
                label: a.name.clone(),
                data: format!("{}\r", a.command),
            })?;
            std::thread::sleep(Duration::from_millis(100));
            this.launchd(Request::WaitIdle {
                label: a.name.clone(),
                idle_ms: a.idle_ms.unwrap_or(800),
                timeout_ms: a.timeout_ms.unwrap_or(60_000),
            })?;
            this.capture(&a.name)
        })
        .await
    }

    #[tool(
        description = "Type text or keys into a session without waiting (e.g. answer a prompt, \"\\u0003\" for ctrl-c)."
    )]
    async fn session_send(&self, Parameters(a): Parameters<SendArgs>) -> ToolResult {
        let this = self.clone();
        blocking(move || {
            let mut data = a.text;
            if a.enter {
                data.push('\r');
            }
            this.launchd(Request::Send {
                label: a.name.clone(),
                data,
            })?;
            Ok(format!("sent to {}", a.name))
        })
        .await
    }

    #[tool(
        description = "The current screen of a session (what a human attached to it would see)."
    )]
    async fn session_capture(&self, Parameters(a): Parameters<NameArg>) -> ToolResult {
        let this = self.clone();
        blocking(move || this.capture(&a.name)).await
    }

    #[tool(description = "Stop a session (SIGTERM, then SIGKILL) and remove it.")]
    async fn session_kill(&self, Parameters(a): Parameters<NameArg>) -> ToolResult {
        let this = self.clone();
        blocking(move || {
            this.launchd(Request::Unload {
                label: a.name.clone(),
            })?;
            Ok(format!("killed {}", a.name))
        })
        .await
    }

    #[tool(
        description = "Control a job from the pullfile `jobs` (or any session): start, stop, restart, unload. Loads the pullfile jobs first."
    )]
    async fn job(&self, Parameters(a): Parameters<JobArgs>) -> ToolResult {
        let this = self.clone();
        blocking(move || {
            let pf = this.pullfile()?;
            this.launchd(Request::Load {
                jobs: pf.jobs,
                start: false,
            })?;
            let label = a.label.clone();
            let req = match a.action.as_str() {
                "start" => Request::Start { label },
                "stop" => Request::Stop { label },
                "restart" => Request::Kickstart { label, kill: true },
                "unload" => Request::Unload { label },
                other => return Err(format!("unknown action {other}")),
            };
            this.launchd(req)?;
            Ok(format!("{} {}", a.action, a.label))
        })
        .await
    }
}

impl PullMcp {
    fn walker(&self, dir: &Path, glob: Option<&str>) -> Result<ignore::Walk, String> {
        let mut b = ignore::WalkBuilder::new(dir);
        b.hidden(true).git_ignore(true).git_exclude(true);
        if let Some(g) = glob {
            let mut o = ignore::overrides::OverrideBuilder::new(dir);
            o.add(g).map_err(err)?;
            b.overrides(o.build().map_err(err)?);
        }
        Ok(b.build())
    }
}

fn format_time(secs: i64) -> String {
    jiff::Timestamp::from_second(secs)
        .map(|t| t.strftime("%Y-%m-%d").to_string())
        .unwrap_or_default()
}

#[tool_handler(router = self.tool_router)]
impl ServerHandler for PullMcp {
    fn get_info(&self) -> ServerConfig {
        ServerConfig::new(ServerCapabilities::builder().enable_tools().build()).with_instructions(
            "pull workspace: several git repos under one root, managed by `pull`. Use `workspace` \
             for an overview, then status/diff/log/grep/list_files/read_file across repos. \
             `exec` runs a command to completion with the workspace env; sessions are stateful \
             terminals (PTYs) that persist between calls and can be attached to by a human. \
             Commit with `pull commit -m MSG PATHS` via exec (subject lint applies).",
        )
    }
}

/// Serve MCP on stdin/stdout until the client disconnects.
pub fn serve(root: PathBuf) -> anyhow::Result<()> {
    let rt = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()?;
    rt.block_on(async move {
        let service = PullMcp::new(root).serve(rmcp::transport::stdio()).await?;
        service.waiting().await?;
        Ok(())
    })
}
