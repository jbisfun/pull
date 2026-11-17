//! What is running in a job's terminal, from /proc (Linux).

use std::path::Path;

/// (foreground program, its working directory) for the terminal session led by `pid`:
/// the terminal's foreground process group (`tpgid` in /proc/PID/stat), like tmux's
/// pane_current_command / pane_current_path.
pub fn foreground(pid: u32) -> (Option<String>, Option<String>) {
    let fg = tpgid(pid).filter(|p| *p > 0).unwrap_or(pid as i64);
    let base = format!("/proc/{fg}");
    let comm = std::fs::read_to_string(format!("{base}/comm"))
        .ok()
        .map(|s| s.trim().to_string());
    let cwd = std::fs::read_link(format!("{base}/cwd"))
        .ok()
        .map(|p| p.display().to_string());
    (comm, cwd)
}

fn tpgid(pid: u32) -> Option<i64> {
    let stat =
        std::fs::read_to_string(Path::new("/proc").join(pid.to_string()).join("stat")).ok()?;
    // Fields after the parenthesised comm: state ppid pgrp session tty_nr tpgid ...
    let rest = &stat[stat.rfind(')')? + 2..];
    rest.split_whitespace().nth(5)?.parse().ok()
}
