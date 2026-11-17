//! `pull launchd`: the per-workspace job supervisor. Runs every job in a PTY.

use super::{Job, JobStatus, Request, Response, procinfo, socket_path, state_dir};
use anyhow::{Context, Result};
use portable_pty::{ChildKiller, CommandBuilder, MasterPty, PtySize, native_pty_system};
use std::collections::BTreeMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use std::num::NonZeroU16;

const ROWS: NonZeroU16 = NonZeroU16::new(40).unwrap();
const COLS: NonZeroU16 = NonZeroU16::new(120).unwrap();
const SCROLLBACK: usize = 2000;

/// Attach stream framing, client -> daemon: [kind, len_hi, len_lo, payload...].
pub const FRAME_DATA: u8 = 0;
/// Payload: rows (u16 BE), cols (u16 BE).
pub const FRAME_RESIZE: u8 = 1;

struct Proc {
    pid: u32,
    master: Box<dyn MasterPty + Send>,
    writer: Box<dyn Write + Send>,
    killer: Box<dyn ChildKiller + Send + Sync>,
}

struct Entry {
    job: Job,
    proc: Option<Proc>,
    run_id: u64,
    runs: u32,
    last_exit: Option<i32>,
    last_start: Option<Instant>,
    next_start: Option<Instant>,
    /// Stopped by the user: KeepAlive/StartInterval don't restart it.
    stopped: bool,
    /// kickstart -k: start again as soon as the current run exits.
    restart_on_exit: bool,
    parser: Arc<Mutex<vt100::Parser>>,
    clients: Arc<Mutex<Vec<(u64, UnixStream)>>>,
    last_output: Arc<Mutex<Instant>>,
}

impl Entry {
    fn new(job: Job) -> Self {
        Self {
            job,
            proc: None,
            run_id: 0,
            runs: 0,
            last_exit: None,
            last_start: None,
            next_start: None,
            stopped: false,
            restart_on_exit: false,
            parser: Arc::new(Mutex::new(vt100::Parser::new(ROWS, COLS, SCROLLBACK))),
            clients: Arc::default(),
            last_output: Arc::new(Mutex::new(Instant::now())),
        }
    }

    fn status(&self, root: &Path) -> JobStatus {
        let (foreground, foreground_cwd) = match &self.proc {
            Some(p) => procinfo::foreground(p.pid),
            None => (None, None),
        };
        let state = if self.proc.is_some() {
            "running"
        } else if self.stopped {
            "stopped"
        } else if self.next_start.is_some() {
            "waiting"
        } else if self.runs > 0 {
            "exited"
        } else {
            "loaded"
        };
        JobStatus {
            label: self.job.label.clone(),
            pid: self.proc.as_ref().map(|p| p.pid),
            last_exit: self.last_exit,
            runs: self.runs,
            state: state.into(),
            argv: self.job.argv(),
            cwd: job_cwd(root, &self.job).display().to_string(),
            foreground,
            foreground_cwd,
            attached: self.clients.lock().unwrap().len(),
            job: self.job.clone(),
            pullfile: false,
        }
    }
}

pub struct Daemon {
    root: PathBuf,
    jobs: Mutex<BTreeMap<String, Entry>>,
    ids: AtomicU64,
}

fn expand(root: &Path, s: &str) -> PathBuf {
    let p = PathBuf::from(shellexpand::tilde(s).into_owned());
    if p.is_relative() { root.join(p) } else { p }
}

fn job_cwd(root: &Path, job: &Job) -> PathBuf {
    job.working_directory
        .as_deref()
        .map(|d| expand(root, d))
        .unwrap_or_else(|| root.to_path_buf())
}

/// The workspace env (pullfile `env` + local.toml), resolved at each start.
fn workspace_env(root: &Path) -> Vec<(String, String)> {
    let Ok(pf) = crate::config::Pullfile::load(root) else {
        return Vec::new();
    };
    let local = crate::config::Local::load(root).ok();
    crate::env::resolve(root, &pf, local.as_ref()).unwrap_or_default()
}

impl Daemon {
    fn with_job<R>(&self, label: &str, f: impl FnOnce(&mut Entry) -> Result<R>) -> Result<R> {
        let mut jobs = self.jobs.lock().unwrap();
        let entry = jobs
            .get_mut(label)
            .with_context(|| format!("no job with label {label}"))?;
        f(entry)
    }

    /// Start `label` now. Caller holds no lock.
    fn start(self: &Arc<Self>, label: &str) -> Result<()> {
        let mut jobs = self.jobs.lock().unwrap();
        let entry = jobs
            .get_mut(label)
            .with_context(|| format!("no job with label {label}"))?;
        if entry.proc.is_some() {
            return Ok(());
        }
        if entry.job.launch_only_once && entry.runs > 0 {
            anyhow::bail!("{label} is LaunchOnlyOnce and already ran");
        }
        let job = entry.job.clone();
        let argv = job.argv();
        let size = {
            let p = entry.parser.lock().unwrap();
            let (rows, cols) = p.screen().size();
            PtySize {
                rows: rows.into(),
                cols: cols.into(),
                pixel_width: 0,
                pixel_height: 0,
            }
        };
        let pair = native_pty_system().openpty(size)?;
        let mut cmd = CommandBuilder::new(&argv[0]);
        cmd.args(&argv[1..]);
        cmd.cwd(job_cwd(&self.root, &job));
        cmd.env("TERM", "xterm-256color");
        for (k, v) in workspace_env(&self.root) {
            cmd.env(k, v);
        }
        for (k, v) in &job.environment_variables {
            cmd.env(
                k,
                shellexpand::full(v)
                    .map(|s| s.into_owned())
                    .unwrap_or_else(|_| v.clone()),
            );
        }
        cmd.env("PULL_JOB", &job.label);
        let mut child = pair
            .slave
            .spawn_command(cmd)
            .with_context(|| format!("starting {label}: {}", argv.join(" ")))?;
        drop(pair.slave);
        let pid = child.process_id().unwrap_or(0);
        let mut reader = pair.master.try_clone_reader()?;
        let writer = pair.master.take_writer()?;
        let killer = child.clone_killer();
        entry.run_id = self.ids.fetch_add(1, Ordering::Relaxed);
        entry.runs += 1;
        entry.last_start = Some(Instant::now());
        entry.next_start = None;
        entry.stopped = false;
        entry.proc = Some(Proc {
            pid,
            master: pair.master,
            writer,
            killer,
        });
        let run_id = entry.run_id;
        let parser = entry.parser.clone();
        let clients = entry.clients.clone();
        let last_output = entry.last_output.clone();
        let mut log = job.standard_out_path.as_deref().and_then(|p| {
            std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(expand(&self.root, p))
                .ok()
        });
        drop(jobs);

        let this = self.clone();
        let label = label.to_string();
        std::thread::Builder::new()
            .name(format!("job {label}"))
            .spawn(move || {
                let mut buf = [0u8; 8192];
                loop {
                    let n = match reader.read(&mut buf) {
                        Ok(0) | Err(_) => break,
                        Ok(n) => n,
                    };
                    let bytes = &buf[..n];
                    parser.lock().unwrap().process(bytes);
                    *last_output.lock().unwrap() = Instant::now();
                    if let Some(f) = log.as_mut() {
                        f.write_all(bytes).ok();
                    }
                    clients
                        .lock()
                        .unwrap()
                        .retain_mut(|(_, s)| s.write_all(bytes).is_ok());
                }
                let code = child.wait().ok().map(|s| s.exit_code() as i32);
                this.exited(&label, run_id, code);
            })?;
        Ok(())
    }

    fn exited(&self, label: &str, run_id: u64, code: Option<i32>) {
        let mut jobs = self.jobs.lock().unwrap();
        let Some(entry) = jobs.get_mut(label) else {
            return;
        };
        if entry.run_id != run_id {
            return;
        }
        entry.proc = None;
        entry.last_exit = code;
        let msg = format!(
            "\r\n[pull: {label} exited{}]\r\n",
            code.map(|c| format!(" with {c}")).unwrap_or_default()
        );
        for (_, s) in entry.clients.lock().unwrap().drain(..) {
            let mut s = s;
            s.write_all(msg.as_bytes()).ok();
            s.shutdown(std::net::Shutdown::Both).ok();
        }
        let now = Instant::now();
        let throttle_until = entry
            .last_start
            .map(|t| t + Duration::from_secs(entry.job.throttle()))
            .unwrap_or(now);
        if entry.restart_on_exit {
            entry.restart_on_exit = false;
            entry.next_start = Some(now);
        } else if !entry.stopped && entry.job.restart_after(code) {
            entry.next_start = Some(throttle_until.max(now));
        } else if !entry.stopped
            && let Some(secs) = entry.job.start_interval
        {
            entry.next_start = entry.last_start.map(|t| t + Duration::from_secs(secs));
        }
    }

    fn stop(&self, label: &str, restart: bool) -> Result<()> {
        self.with_job(label, |e| {
            e.stopped = !restart;
            e.restart_on_exit = restart;
            e.next_start = None;
            if let Some(p) = &mut e.proc {
                let pid = p.pid as i32;
                // The job leads its own session/process group in the PTY.
                if nix::sys::signal::killpg(
                    nix::unistd::Pid::from_raw(pid),
                    nix::sys::signal::Signal::SIGTERM,
                )
                .is_err()
                {
                    p.killer.kill().ok();
                }
                let mut killer = p.killer.clone_killer();
                let run_id = e.run_id;
                let _ = run_id;
                std::thread::spawn(move || {
                    std::thread::sleep(Duration::from_secs(5));
                    // ExitTimeOut: still alive after SIGTERM -> SIGKILL.
                    if nix::sys::signal::kill(nix::unistd::Pid::from_raw(pid), None).is_ok() {
                        killer.kill().ok();
                    }
                });
            }
            Ok(())
        })
    }

    fn load(self: &Arc<Self>, jobs: Vec<Job>, start: bool) -> Result<()> {
        let mut to_start = Vec::new();
        {
            let mut map = self.jobs.lock().unwrap();
            for job in jobs {
                if job.disabled || job.label.is_empty() {
                    continue;
                }
                if let Some(existing) = map.get_mut(&job.label) {
                    if existing.job == job {
                        continue;
                    }
                    existing.job = job.clone();
                } else {
                    let mut entry = Entry::new(job.clone());
                    if let Some(secs) = job.start_interval
                        && !job.run_at_load
                    {
                        entry.next_start = Some(Instant::now() + Duration::from_secs(secs));
                    }
                    map.insert(job.label.clone(), entry);
                }
                if start && job.run_at_load {
                    to_start.push(job.label.clone());
                }
            }
        }
        for label in to_start {
            self.start(&label)?;
        }
        Ok(())
    }

    fn status(&self, label: &str) -> Result<JobStatus> {
        self.with_job(label, |e| Ok(e.status(&self.root)))
    }

    fn handle(self: &Arc<Self>, req: Request) -> Response {
        let result: Result<Response> = (|| {
            Ok(match req {
                Request::Load { jobs, start } => {
                    self.load(jobs, start)?;
                    Response::Ok
                }
                Request::Unload { label } => {
                    self.stop(&label, false)?;
                    if let Some(entry) = self.jobs.lock().unwrap().remove(&label) {
                        // exited() won't find the entry anymore; disconnect attached
                        // terminals now (shutdown also ends the daemon's reader on them).
                        for (_, mut s) in entry.clients.lock().unwrap().drain(..) {
                            s.write_all(format!("\r\n[pull: {label} removed]\r\n").as_bytes())
                                .ok();
                            s.shutdown(std::net::Shutdown::Both).ok();
                        }
                    }
                    Response::Ok
                }
                Request::List => Response::Jobs(
                    self.jobs
                        .lock()
                        .unwrap()
                        .values()
                        .map(|e| e.status(&self.root))
                        .collect(),
                ),
                Request::Print { label } => Response::Job(Box::new(self.status(&label)?)),
                Request::Start { label } => {
                    self.start(&label)?;
                    Response::Ok
                }
                Request::Stop { label } => {
                    self.stop(&label, false)?;
                    Response::Ok
                }
                Request::Kickstart { label, kill } => {
                    let running = self.with_job(&label, |e| Ok(e.proc.is_some()))?;
                    if running && kill {
                        self.stop(&label, true)?;
                    } else {
                        self.start(&label)?;
                    }
                    Response::Ok
                }
                Request::Send { label, data } => {
                    self.with_job(&label, |e| {
                        let p = e.proc.as_mut().context("job is not running")?;
                        p.writer.write_all(data.as_bytes())?;
                        p.writer.flush()?;
                        Ok(())
                    })?;
                    Response::Ok
                }
                Request::Capture { label, escapes } => {
                    let parser = self.with_job(&label, |e| Ok(e.parser.clone()))?;
                    let parser = parser.lock().unwrap();
                    let screen = parser.screen();
                    let text = if escapes {
                        screen.contents_formatted()
                    } else {
                        let mut s = screen.contents();
                        while s.ends_with('\n') {
                            s.pop();
                        }
                        s
                    };
                    Response::Text(text)
                }
                Request::WaitIdle {
                    label,
                    idle_ms,
                    timeout_ms,
                } => {
                    let started = Instant::now();
                    loop {
                        let (running, last) = self.with_job(&label, |e| {
                            Ok((e.proc.is_some(), *e.last_output.lock().unwrap()))
                        })?;
                        if !running || last.elapsed() >= Duration::from_millis(idle_ms) {
                            break;
                        }
                        if started.elapsed() >= Duration::from_millis(timeout_ms) {
                            break;
                        }
                        std::thread::sleep(Duration::from_millis(25));
                    }
                    Response::Ok
                }
                Request::Attach { .. } => unreachable!("handled by the connection"),
                Request::Shutdown => {
                    let labels: Vec<String> = self.jobs.lock().unwrap().keys().cloned().collect();
                    for l in labels {
                        self.stop(&l, false).ok();
                    }
                    std::fs::remove_file(socket_path(&self.root)).ok();
                    std::thread::spawn(|| {
                        std::thread::sleep(Duration::from_millis(300));
                        std::process::exit(0);
                    });
                    Response::Ok
                }
            })
        })();
        result.unwrap_or_else(|e| Response::Error(format!("{e:#}")))
    }

    fn attach(
        self: &Arc<Self>,
        stream: UnixStream,
        label: &str,
        rows: u16,
        cols: u16,
    ) -> Result<()> {
        let (parser, clients) = self.with_job(label, |e| {
            if e.proc.is_none() {
                anyhow::bail!("{label} is not running");
            }
            Ok((e.parser.clone(), e.clients.clone()))
        })?;
        self.resize(label, rows, cols);
        let mut out = stream.try_clone()?;
        writeln!(out, "{}", serde_json::to_string(&Response::Ok)?)?;
        // Redraw the current screen for the new client, then stream live output.
        let screen = parser.lock().unwrap().screen().contents_formatted();
        out.write_all(b"\x1b[H\x1b[2J")?;
        out.write_all(screen.as_bytes())?;
        let id = self.ids.fetch_add(1, Ordering::Relaxed);
        clients.lock().unwrap().push((id, out));

        let mut input = BufReader::new(stream);
        let mut header = [0u8; 3];
        loop {
            if input.read_exact(&mut header).is_err() {
                break;
            }
            let len = u16::from_be_bytes([header[1], header[2]]) as usize;
            let mut payload = vec![0u8; len];
            if input.read_exact(&mut payload).is_err() {
                break;
            }
            match header[0] {
                FRAME_DATA => {
                    let ok = self.with_job(label, |e| {
                        if let Some(p) = e.proc.as_mut() {
                            p.writer.write_all(&payload)?;
                            p.writer.flush()?;
                        }
                        Ok(())
                    });
                    if ok.is_err() {
                        break;
                    }
                }
                FRAME_RESIZE if len == 4 => {
                    let rows = u16::from_be_bytes([payload[0], payload[1]]);
                    let cols = u16::from_be_bytes([payload[2], payload[3]]);
                    self.resize(label, rows, cols);
                }
                _ => {}
            }
        }
        clients.lock().unwrap().retain(|(cid, _)| *cid != id);
        Ok(())
    }

    fn resize(&self, label: &str, rows: u16, cols: u16) {
        let (Some(r), Some(c)) = (NonZeroU16::new(rows), NonZeroU16::new(cols)) else {
            return;
        };
        self.with_job(label, |e| {
            e.parser.lock().unwrap().screen_mut().set_size(r, c);
            if let Some(p) = &e.proc {
                p.master.resize(PtySize {
                    rows,
                    cols,
                    pixel_width: 0,
                    pixel_height: 0,
                })?;
            }
            Ok(())
        })
        .ok();
    }

    fn serve(self: Arc<Self>, stream: UnixStream) -> Result<()> {
        let mut reader = BufReader::new(stream.try_clone()?);
        let mut out = stream.try_clone()?;
        let mut line = String::new();
        loop {
            line.clear();
            if reader.read_line(&mut line)? == 0 {
                return Ok(());
            }
            let req: Request = match serde_json::from_str(&line) {
                Ok(r) => r,
                Err(e) => {
                    writeln!(
                        out,
                        "{}",
                        serde_json::to_string(&Response::Error(e.to_string()))?
                    )?;
                    continue;
                }
            };
            if let Request::Attach { label, rows, cols } = req {
                drop(reader);
                if let Err(e) = self.attach(stream, &label, rows, cols) {
                    writeln!(
                        out,
                        "{}",
                        serde_json::to_string(&Response::Error(format!("{e:#}")))?
                    )
                    .ok();
                }
                return Ok(());
            }
            let resp = self.handle(req);
            writeln!(out, "{}", serde_json::to_string(&resp)?)?;
        }
    }

    /// KeepAlive / StartInterval / kickstart restarts.
    fn supervise(self: Arc<Self>) {
        loop {
            std::thread::sleep(Duration::from_millis(250));
            let due: Vec<String> = self
                .jobs
                .lock()
                .unwrap()
                .values()
                .filter(|e| e.proc.is_none() && e.next_start.is_some_and(|t| t <= Instant::now()))
                .map(|e| e.job.label.clone())
                .collect();
            for label in due {
                if let Err(e) = self.start(&label) {
                    eprintln!("launchd: {label}: {e:#}");
                    self.with_job(&label, |e| {
                        e.next_start = None;
                        Ok(())
                    })
                    .ok();
                }
            }
        }
    }
}

/// Run the daemon for the workspace at `root` (foreground).
pub fn run(root: &Path) -> Result<()> {
    std::fs::create_dir_all(state_dir(root))?;
    let sock = socket_path(root);
    if UnixStream::connect(&sock).is_ok() {
        anyhow::bail!("launchd is already running for {}", root.display());
    }
    std::fs::remove_file(&sock).ok();
    let listener =
        UnixListener::bind(&sock).with_context(|| format!("binding {}", sock.display()))?;
    let daemon = Arc::new(Daemon {
        root: root.to_path_buf(),
        jobs: Mutex::default(),
        ids: AtomicU64::new(1),
    });
    let pf = crate::config::Pullfile::load(root)?;
    if let Err(e) = daemon.load(pf.jobs.clone(), true) {
        eprintln!("launchd: loading pullfile jobs: {e:#}");
    }
    eprintln!("launchd: {} ({} jobs)", sock.display(), pf.jobs.len());
    std::thread::spawn({
        let d = daemon.clone();
        move || d.supervise()
    });
    for stream in listener.incoming() {
        let Ok(stream) = stream else { continue };
        let d = daemon.clone();
        std::thread::spawn(move || {
            if let Err(e) = d.serve(stream) {
                eprintln!("launchd: connection: {e:#}");
            }
        });
    }
    Ok(())
}
