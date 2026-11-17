//! A port of launchd's job model to pull (Linux and macOS, per workspace).
//!
//! Jobs use launchd's plist keys (see Apple's `liblaunch/launch.h`) and live in the
//! pullfile's `jobs` array or in standalone `.plist` files loaded with
//! `pull launchctl load FILE`. Unlike launchd, every job runs in a pseudo-terminal managed
//! by the workspace daemon (`pull launchd`), so any job is also a tmux-style session: a
//! human can attach to it, and an agent can send input and read its screen.
//!
//! Supported job keys: Label, Program, ProgramArguments, EnvironmentVariables,
//! WorkingDirectory, RunAtLoad, KeepAlive (bool or {SuccessfulExit}), StartInterval,
//! ThrottleInterval, StandardOutPath, Disabled, LaunchOnlyOnce. A PTY merges stdout and
//! stderr, so StandardErrorPath is accepted but the combined output goes to StandardOutPath.

pub mod client;
pub mod daemon;
pub mod procinfo;

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

#[derive(Serialize, Deserialize, Debug, Clone, Default, PartialEq)]
#[serde(rename_all = "PascalCase")]
pub struct Job {
    pub label: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub program: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub program_arguments: Vec<String>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub environment_variables: BTreeMap<String, String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub working_directory: Option<String>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub run_at_load: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub keep_alive: Option<KeepAlive>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub start_interval: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub throttle_interval: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub standard_out_path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub standard_error_path: Option<String>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub disabled: bool,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub launch_only_once: bool,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(untagged)]
pub enum KeepAlive {
    Always(bool),
    Conditions {
        /// true: restart after a zero exit; false: restart after a non-zero exit.
        #[serde(rename = "SuccessfulExit", default)]
        successful_exit: Option<bool>,
    },
}

impl Job {
    /// launchd's default ThrottleInterval.
    pub fn throttle(&self) -> u64 {
        self.throttle_interval.unwrap_or(10)
    }

    /// Should the job be started again after exiting with `code`?
    pub fn restart_after(&self, code: Option<i32>) -> bool {
        match &self.keep_alive {
            Some(KeepAlive::Always(b)) => *b,
            Some(KeepAlive::Conditions {
                successful_exit: Some(want_success),
            }) => (code == Some(0)) == *want_success,
            _ => false,
        }
    }

    /// argv: ProgramArguments (with Program as the executable if both are set),
    /// Program alone, or the user's shell for an ad-hoc session.
    pub fn argv(&self) -> Vec<String> {
        let mut argv = self.program_arguments.clone();
        match (&self.program, argv.is_empty()) {
            (Some(p), true) => argv.push(p.clone()),
            (Some(p), false) => argv[0] = p.clone(),
            (None, true) => argv.push(std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".into())),
            (None, false) => {}
        }
        argv
    }

    pub fn load_plist(path: &Path) -> anyhow::Result<Self> {
        Ok(plist::from_file(path)?)
    }
}

/// Per-workspace state directory (socket, daemon log).
pub fn state_dir(root: &Path) -> PathBuf {
    root.join(".pull")
}

pub fn socket_path(root: &Path) -> PathBuf {
    state_dir(root).join("launchd.sock")
}

#[derive(Serialize, Deserialize, Debug)]
pub enum Request {
    /// Load jobs (replacing jobs with the same label) and start RunAtLoad ones.
    Load {
        jobs: Vec<Job>,
        start: bool,
    },
    Unload {
        label: String,
    },
    List,
    Print {
        label: String,
    },
    Start {
        label: String,
    },
    Stop {
        label: String,
    },
    /// launchctl kickstart: start, or with `kill` restart a running job.
    Kickstart {
        label: String,
        kill: bool,
    },
    /// Write bytes to the job's terminal.
    Send {
        label: String,
        data: String,
    },
    /// The job's current screen (plain text, or with escapes).
    Capture {
        label: String,
        escapes: bool,
    },
    /// Wait until the job produced no output for `idle_ms` (or exited), max `timeout_ms`.
    WaitIdle {
        label: String,
        idle_ms: u64,
        timeout_ms: u64,
    },
    /// Switch this connection to a raw terminal stream for the job.
    Attach {
        label: String,
        rows: u16,
        cols: u16,
    },
    Shutdown,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct JobStatus {
    pub label: String,
    pub pid: Option<u32>,
    pub last_exit: Option<i32>,
    pub runs: u32,
    pub state: String,
    pub argv: Vec<String>,
    pub cwd: String,
    /// Foreground program in the job's terminal (what tmux shows as pane_current_command).
    pub foreground: Option<String>,
    /// Working directory of the foreground program (pane_current_path).
    pub foreground_cwd: Option<String>,
    pub attached: usize,
    pub job: Job,
    /// Defined in the pullfile's `jobs` (as opposed to an ad-hoc session).
    #[serde(default)]
    pub pullfile: bool,
}

#[derive(Serialize, Deserialize, Debug)]
pub enum Response {
    Ok,
    Error(String),
    Jobs(Vec<JobStatus>),
    Job(Box<JobStatus>),
    Text(String),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn launchd_plist_round_trip() {
        let xml = r#"<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>Label</key><string>dev.server</string>
  <key>ProgramArguments</key><array><string>python3</string><string>-m</string><string>http.server</string></array>
  <key>EnvironmentVariables</key><dict><key>PORT</key><string>8000</string></dict>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>RunAtLoad</key><true/>
</dict></plist>"#;
        let job: Job = plist::from_bytes(xml.as_bytes()).unwrap();
        assert_eq!(job.label, "dev.server");
        assert_eq!(job.argv(), vec!["python3", "-m", "http.server"]);
        assert!(job.run_at_load);
        assert!(job.restart_after(Some(1)));
        assert!(!job.restart_after(Some(0)));
        let always: Job = plist::from_bytes(
            br#"<plist version="1.0"><dict><key>Label</key><string>a</string><key>KeepAlive</key><true/></dict></plist>"#,
        )
        .unwrap();
        assert!(always.restart_after(Some(0)));
    }
}
