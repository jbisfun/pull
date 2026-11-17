//! Clients of the workspace launchd: requests, auto-start, and terminal attach.

use super::daemon::{FRAME_DATA, FRAME_RESIZE};
use super::{Request, Response, socket_path, state_dir};
use anyhow::{Context, Result, bail};
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

/// Connect to the workspace daemon, starting it (detached, in its own session) if needed.
pub fn connect(root: &Path) -> Result<UnixStream> {
    let sock = socket_path(root);
    if let Ok(s) = UnixStream::connect(&sock) {
        return Ok(s);
    }
    std::fs::create_dir_all(state_dir(root))?;
    let log = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(state_dir(root).join("launchd.log"))?;
    let mut cmd = Command::new(std::env::current_exe()?);
    cmd.arg("launchd")
        .current_dir(root)
        .stdin(Stdio::null())
        .stdout(log.try_clone()?)
        .stderr(log);
    // SAFETY: setsid is async-signal-safe; detaches the daemon from our terminal.
    unsafe {
        cmd.pre_exec(|| {
            nix::unistd::setsid().map_err(std::io::Error::from)?;
            Ok(())
        });
    }
    cmd.spawn().context("starting pull launchd")?;
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        if let Ok(s) = UnixStream::connect(&sock) {
            return Ok(s);
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    bail!(
        "launchd did not start; see {}",
        state_dir(root).join("launchd.log").display()
    )
}

pub fn request(root: &Path, req: &Request) -> Result<Response> {
    let mut s = connect(root)?;
    writeln!(s, "{}", serde_json::to_string(req)?)?;
    let mut line = String::new();
    BufReader::new(s).read_line(&mut line)?;
    let resp: Response = serde_json::from_str(&line).context("bad reply from launchd")?;
    if let Response::Error(e) = resp {
        bail!("{e}");
    }
    Ok(resp)
}

/// Is a daemon running for this workspace (without starting one)?
pub fn running(root: &Path) -> bool {
    UnixStream::connect(socket_path(root)).is_ok()
}

fn frame(kind: u8, payload: &[u8]) -> Vec<u8> {
    let mut v = Vec::with_capacity(3 + payload.len());
    v.push(kind);
    v.extend_from_slice(&(payload.len() as u16).to_be_bytes());
    v.extend_from_slice(payload);
    v
}

/// Attach the current terminal to a job. Detach with ctrl-\.
pub fn attach(root: &Path, label: &str) -> Result<()> {
    use crossterm::terminal;
    let (cols, rows) = terminal::size().unwrap_or((120, 40));
    let mut s = connect(root)?;
    writeln!(
        s,
        "{}",
        serde_json::to_string(&Request::Attach {
            label: label.into(),
            rows,
            cols
        })?
    )?;
    // Read exactly one reply line (unbuffered: raw output follows it).
    let mut line = Vec::new();
    let mut byte = [0u8; 1];
    while s.read(&mut byte)? == 1 && byte[0] != b'\n' {
        line.push(byte[0]);
    }
    if let Response::Error(e) = serde_json::from_slice(&line)? {
        bail!("{e}");
    }

    terminal::enable_raw_mode()?;
    eprint!("\x1b]0;pull: {label}\x07");
    let mut from_daemon = s.try_clone()?;
    let output = std::thread::spawn(move || {
        let mut stdout = std::io::stdout();
        let mut buf = [0u8; 8192];
        while let Ok(n) = from_daemon.read(&mut buf) {
            if n == 0 || stdout.write_all(&buf[..n]).is_err() {
                break;
            }
            stdout.flush().ok();
        }
    });
    let mut to_daemon = s.try_clone()?;
    std::thread::spawn(move || {
        let mut last = (cols, rows);
        loop {
            std::thread::sleep(Duration::from_millis(250));
            let Ok(size) = terminal::size() else { break };
            if size != last {
                last = size;
                let mut p = size.1.to_be_bytes().to_vec();
                p.extend_from_slice(&size.0.to_be_bytes());
                if to_daemon.write_all(&frame(FRAME_RESIZE, &p)).is_err() {
                    break;
                }
            }
        }
    });
    let mut stdin = std::io::stdin();
    let mut buf = [0u8; 4096];
    loop {
        let n = match stdin.read(&mut buf) {
            Ok(0) | Err(_) => break,
            Ok(n) => n,
        };
        // ctrl-\ detaches.
        if let Some(i) = buf[..n].iter().position(|b| *b == 0x1c) {
            if i > 0 {
                s.write_all(&frame(FRAME_DATA, &buf[..i])).ok();
            }
            break;
        }
        if s.write_all(&frame(FRAME_DATA, &buf[..n])).is_err() || output.is_finished() {
            break;
        }
    }
    s.shutdown(std::net::Shutdown::Both).ok();
    terminal::disable_raw_mode()?;
    eprintln!("\r\n[detached from {label}]");
    Ok(())
}
