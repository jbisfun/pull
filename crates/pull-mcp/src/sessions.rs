//! Session and job tools: stateful terminals run by the workspace launchd daemon.

use crate::{PullMcp, ToolResult, err};
use pull_launchd::{self as launchd, KeepAlive, Request, Response, client};
use rmcp::{handler::server::wrapper::Parameters, schemars, tool, tool_router};
use serde::Deserialize;
use std::collections::BTreeMap;
use std::fmt::Write as _;
use std::time::Duration;

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

/// Run blocking work off the async runtime.
async fn blocking<T: Send + 'static>(f: impl FnOnce() -> T + Send + 'static) -> T {
    tokio::task::spawn_blocking(f).await.expect("tool panicked")
}

impl PullMcp {
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

#[tool_router(router = session_router, vis = "pub(crate)")]
impl PullMcp {
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
            let jobs: Vec<launchd::Job> = pf.section(launchd::SECTION).map_err(err)?;
            this.launchd(Request::Load { jobs, start: false })?;
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
