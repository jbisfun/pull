//! `pull launchd` / `pull launchctl` / `pull session` (the `launchd` feature).

use crate::cli::{LaunchctlCmd, SessionCmd};
use anyhow::{Context, Result, bail};
use pull_core::{Pullfile, paths};
use pull_launchd::{self as launchd, KeepAlive, Request, Response, client};
use std::path::Path;

/// The pullfile's `jobs`.
pub fn pullfile_jobs(pf: &Pullfile) -> Result<Vec<launchd::Job>> {
    pf.section(launchd::SECTION)
}

/// Run the daemon in the foreground with the pullfile jobs and the workspace env.
pub fn daemon(root: &Path, pf: &Pullfile) -> Result<()> {
    paths::ensure_ignored(root, "/.pull/")?;
    launchd::daemon::run(
        root,
        pullfile_jobs(pf)?,
        Box::new(crate::workspace::env_provider(root)),
    )
}

pub fn launchctl(root: &Path, pf: &Pullfile, cmd: LaunchctlCmd) -> Result<()> {
    match cmd {
        LaunchctlCmd::Load { paths } => {
            let jobs = if paths.is_empty() {
                pullfile_jobs(pf)?
            } else {
                paths
                    .iter()
                    .map(|p| launchd::Job::load_plist(p).with_context(|| p.display().to_string()))
                    .collect::<Result<Vec<_>>>()?
            };
            let n = jobs.len();
            client::request(root, &Request::Load { jobs, start: true })?;
            println!("loaded {n} job(s)");
        }
        LaunchctlCmd::Unload { label } => {
            client::request(root, &Request::Unload { label })?;
        }
        LaunchctlCmd::List { json, all } => {
            let mut jobs = if !all || client::running(root) {
                let Response::Jobs(jobs) = client::request(root, &Request::List)? else {
                    bail!("unexpected reply");
                };
                jobs
            } else {
                Vec::new()
            };
            let pf_jobs = pullfile_jobs(pf)?;
            for j in &mut jobs {
                j.pullfile = pf_jobs.iter().any(|p| p.label == j.label);
            }
            if all {
                for job in &pf_jobs {
                    if job.disabled || jobs.iter().any(|j| j.label == job.label) {
                        continue;
                    }
                    jobs.push(launchd::JobStatus {
                        label: job.label.clone(),
                        pid: None,
                        last_exit: None,
                        runs: 0,
                        state: "unloaded".into(),
                        argv: job.argv(),
                        cwd: job
                            .working_directory
                            .clone()
                            .unwrap_or_else(|| root.display().to_string()),
                        foreground: None,
                        foreground_cwd: None,
                        attached: 0,
                        job: job.clone(),
                        pullfile: true,
                    });
                }
            }
            if json {
                println!("{}", serde_json::to_string_pretty(&jobs)?);
            } else {
                println!("PID\tStatus\tLabel");
                for j in jobs {
                    let pid = j.pid.map(|p| p.to_string()).unwrap_or("-".into());
                    let status = j.last_exit.map(|c| c.to_string()).unwrap_or("-".into());
                    println!("{pid}\t{status}\t{}", j.label);
                }
            }
        }
        LaunchctlCmd::Print { label, json } => {
            let Response::Job(j) = client::request(root, &Request::Print { label })? else {
                bail!("unexpected reply");
            };
            if json {
                println!("{}", serde_json::to_string_pretty(&j)?);
            } else {
                println!("{} = {{", j.label);
                println!("\tstate = {}", j.state);
                println!(
                    "\tpid = {}",
                    j.pid.map(|p| p.to_string()).unwrap_or("-".into())
                );
                println!("\truns = {}", j.runs);
                println!(
                    "\tlast exit code = {}",
                    j.last_exit.map(|c| c.to_string()).unwrap_or("-".into())
                );
                println!("\tprogram = {}", j.argv.join(" "));
                println!("\tworking directory = {}", j.cwd);
                if let Some(fg) = &j.foreground {
                    println!(
                        "\tforeground = {fg} in {}",
                        j.foreground_cwd.as_deref().unwrap_or("?")
                    );
                }
                println!("\tattached = {}", j.attached);
                for (k, v) in &j.job.environment_variables {
                    println!("\tenv {k} = {v}");
                }
                println!("}}");
            }
        }
        LaunchctlCmd::Start { label } => {
            client::request(root, &Request::Start { label })?;
        }
        LaunchctlCmd::Stop { label } => {
            client::request(root, &Request::Stop { label })?;
        }
        LaunchctlCmd::Kickstart { label, k } => {
            client::request(root, &Request::Kickstart { label, kill: k })?;
        }
        LaunchctlCmd::Shutdown => {
            if client::running(root) {
                client::request(root, &Request::Shutdown)?;
            }
        }
    }
    Ok(())
}

pub fn session(root: &Path, cmd: SessionCmd) -> Result<()> {
    match cmd {
        SessionCmd::New {
            name,
            detached,
            cwd,
            keep_alive,
            cmd,
        } => {
            let cwd = match cwd {
                Some(c) => Some(paths::absolutize(&std::env::current_dir()?.join(c))?),
                None => std::env::current_dir().ok(),
            };
            let job = launchd::Job {
                label: name.clone(),
                program_arguments: cmd,
                working_directory: cwd.map(|c| c.display().to_string()),
                run_at_load: true,
                keep_alive: keep_alive.then_some(KeepAlive::Always(true)),
                throttle_interval: keep_alive.then_some(1),
                ..Default::default()
            };
            client::request(
                root,
                &Request::Load {
                    jobs: vec![job],
                    start: true,
                },
            )?;
            if detached {
                println!("{name}");
            } else {
                client::attach(root, &name)?;
            }
        }
        SessionCmd::Ls { json } => {
            let Response::Jobs(jobs) = client::request(root, &Request::List)? else {
                bail!("unexpected reply");
            };
            if json {
                println!("{}", serde_json::to_string_pretty(&jobs)?);
            } else {
                for j in jobs {
                    let what = match (&j.foreground, &j.foreground_cwd) {
                        (Some(fg), Some(cwd)) => format!("{fg} in {cwd}"),
                        _ => j.state.clone(),
                    };
                    let attached = if j.attached > 0 { " (attached)" } else { "" };
                    println!("{}: {what}{attached}", j.label);
                }
            }
        }
        SessionCmd::Attach { name } => client::attach(root, &name)?,
        SessionCmd::Send { name, text, enter } => {
            let mut data = text.join(" ");
            if enter {
                data.push('\r');
            }
            client::request(root, &Request::Send { label: name, data })?;
        }
        SessionCmd::Capture { name, escapes } => {
            if let Response::Text(t) = client::request(
                root,
                &Request::Capture {
                    label: name,
                    escapes,
                },
            )? {
                println!("{t}");
            }
        }
        SessionCmd::Run {
            name,
            idle,
            timeout,
            command,
        } => {
            let data = format!("{}\r", command.join(" "));
            client::request(
                root,
                &Request::Send {
                    label: name.clone(),
                    data,
                },
            )?;
            // Let the command start producing output before waiting for it to settle.
            std::thread::sleep(std::time::Duration::from_millis(100));
            client::request(
                root,
                &Request::WaitIdle {
                    label: name.clone(),
                    idle_ms: idle,
                    timeout_ms: timeout,
                },
            )?;
            if let Response::Text(t) = client::request(
                root,
                &Request::Capture {
                    label: name,
                    escapes: false,
                },
            )? {
                println!("{t}");
            }
        }
        SessionCmd::Kill { name } => {
            client::request(root, &Request::Unload { label: name })?;
        }
    }
    Ok(())
}
