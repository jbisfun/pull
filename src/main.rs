//! `pull`: the CLI. The core (repos, sync, status, commit, push) lives in pull-core and
//! pull-git; every other feature is an optional crate behind a cargo feature, wired in
//! through `workspace` (hooks, lint, env, ignore) or its own subcommands.

mod cli;
#[cfg(feature = "launchd")]
mod launchd;
mod workspace;

use anyhow::{Result, bail};
use clap::Parser;
use cli::{Cli, Cmd, RepoCmd};
use pull_core::{LOCAL, Local, PULLFILE, Pullfile, Repo, paths};
use pull_git::git;
use std::path::{Path, PathBuf};
use workspace::Hook;

fn main() {
    if let Err(e) = run(Cli::parse()) {
        eprintln!("pull: {e:#}");
        std::process::exit(1);
    }
}

fn run(cli: Cli) -> Result<()> {
    let cwd = std::env::current_dir()?;
    if let Cmd::Init { org } = &cli.cmd {
        return init(&cwd, org.clone());
    }
    #[cfg(feature = "mcp")]
    if let Cmd::Mcp { root: Some(r) } = &cli.cmd {
        return mcp(pull_core::find_root(r)?);
    }
    let root = pull_core::find_root(&cwd)?;
    let mut pf = Pullfile::load(&root)?;
    workspace::warn_unsupported(&pf);
    workspace::apply_ignores(&root, &pf);

    match cli.cmd {
        Cmd::Init { .. } => unreachable!(),
        Cmd::Repo(RepoCmd::Add {
            upstream,
            name,
            branch,
        }) => {
            let name = match name {
                Some(n) => n,
                None => paths::repo_name_from_url(&upstream)?,
            };
            if pf.repos.iter().any(|r| r.name == name) {
                bail!("repo `{name}` already in {PULLFILE}");
            }
            pf.repos.push(Repo {
                name: name.clone(),
                upstream,
                branch,
                commit: None,
            });
            pf.save(&root)?;
            pull_git::exclude_from_root_repo(&root, &name)?;
            println!("added {name}; run `pull sync` to clone");
        }
        Cmd::Repo(RepoCmd::Rm { name }) => {
            let n = pf.repos.len();
            pf.repos.retain(|r| r.name != name);
            if pf.repos.len() == n {
                bail!("no repo `{name}`");
            }
            pf.save(&root)?;
        }
        Cmd::Repo(RepoCmd::List) => {
            for r in &pf.repos {
                let pin = r
                    .commit
                    .as_deref()
                    .map(|c| &c[..8.min(c.len())])
                    .unwrap_or("-");
                println!("{:<20} {:<10} {pin}  {}", r.name, r.branch, r.upstream);
            }
        }
        Cmd::Sync => sync(&root, &mut pf, false)?,
        Cmd::Update => sync(&root, &mut pf, true)?,
        Cmd::Status { json: false } => pull_git::print_status(&root, &pf)?,
        Cmd::Status { json: true } => status_json(&root, &pf)?,
        Cmd::Unstage { paths } => {
            for (name, rel) in paths::route(&root, &pf, &cwd, &paths)? {
                git::unstage(&pull_git::open(&root, &name)?, &rel)?;
            }
        }
        Cmd::Add { paths } => {
            for (name, rel) in paths::route(&root, &pf, &cwd, &paths)? {
                git::stage(&pull_git::open(&root, &name)?, &rel)?;
            }
        }
        Cmd::Commit {
            message,
            all,
            no_verify,
            paths,
        } => commit(&root, &mut pf, &cwd, &message, all, no_verify, &paths)?,
        Cmd::Push => pull_git::push(&root, &pf)?,
        #[cfg(feature = "lint")]
        Cmd::Lint { message } => {
            let msg = git2::message_prettify(&message, None)?;
            let v = workspace::lint(&pf, &msg)?;
            if v.is_empty() {
                println!("ok");
            } else {
                for e in &v {
                    eprintln!("lint: {e}");
                }
                bail!("{} lint violation(s)", v.len());
            }
        }
        Cmd::Whoami => {
            let id = pull_core::resolve_identity(&pf, &Local::load(&root)?)?;
            println!("{} <{}>", id.name, id.email);
            match (id.sign, &id.signing_key) {
                (true, Some(k)) => println!("signing: gpg key {k}"),
                (true, None) => println!("signing: gpg default key"),
                (false, _) => println!("signing: off"),
            }
            if let Some(o) = &pf.identity.org {
                println!("org: {o}");
            }
        }
        #[cfg(feature = "mcp")]
        Cmd::Mcp { .. } => mcp(root)?,
        #[cfg(feature = "mcp")]
        Cmd::McpServers => mcp_servers_json(&root)?,
        #[cfg(feature = "launchd")]
        Cmd::Launchd => launchd::daemon(&root, &pf)?,
        #[cfg(feature = "launchd")]
        Cmd::Launchctl(cmd) => launchd::launchctl(&root, &pf, cmd)?,
        #[cfg(feature = "launchd")]
        Cmd::Session(cmd) => launchd::session(&root, cmd)?,
        #[cfg(feature = "worktree")]
        Cmd::Worktree(cmd) => worktree(&root, &pf, cmd)?,
        #[cfg(feature = "tool")]
        Cmd::Tool(cmd) => tool(&root, &mut pf, &cwd, cmd)?,
        #[cfg(feature = "env")]
        Cmd::Env { envrc } => {
            if envrc {
                let p = root.join(".envrc");
                std::fs::write(&p, pull_env::ENVRC)?;
                println!("wrote {} (run `direnv allow` there)", p.display());
            } else {
                print!("{}", pull_env::exports(&workspace::env(&root, &pf)?)?);
            }
        }
        #[cfg(feature = "env")]
        Cmd::Shell { cmd } => {
            use anyhow::Context as _;
            let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".into());
            let (prog, args) = match cmd.split_first() {
                Some((p, a)) => (p.clone(), a.to_vec()),
                None => (shell, Vec::new()),
            };
            let st = std::process::Command::new(&prog)
                .args(&args)
                .envs(workspace::env(&root, &pf)?)
                .status()
                .with_context(|| format!("running {prog}"))?;
            std::process::exit(st.code().unwrap_or(1));
        }
        Cmd::Each { cmd } => {
            let vars = workspace::env(&root, &pf)?;
            for r in &pf.repos {
                let dir = root.join(&r.name);
                if !dir.exists() {
                    continue;
                }
                println!("== {}", r.name);
                let st = std::process::Command::new(&cmd[0])
                    .args(&cmd[1..])
                    .envs(vars.iter().map(|(k, v)| (k, v)))
                    .current_dir(&dir)
                    .status()?;
                if !st.success() {
                    bail!("{}: {st}", r.name);
                }
            }
        }
    }
    Ok(())
}

fn init(cwd: &Path, org: Option<String>) -> Result<()> {
    let pfp = cwd.join(PULLFILE);
    if pfp.exists() {
        println!("{PULLFILE} already exists");
    } else {
        let mut pf = Pullfile::default();
        pf.identity.org = org.clone();
        pf.save(cwd)?;
        println!("wrote {}", pfp.display());
    }
    let lp = cwd.join(LOCAL);
    if !lp.exists() && Local::path(cwd).is_none() {
        let mut local = Local {
            name: std::env::var("USER").unwrap_or_else(|_| "anon".into()),
            ..Default::default()
        };
        if let Some(o) = org {
            local.orgs.insert(o, Default::default());
        }
        std::fs::write(&lp, toml::to_string_pretty(&local)?)?;
        println!("wrote {}", lp.display());
    }
    paths::ensure_ignored(cwd, &format!("/{LOCAL}"))
}

fn sync(root: &Path, pf: &mut Pullfile, to_upstream: bool) -> Result<()> {
    pull_git::sync(root, pf, to_upstream)?;
    workspace::run_hook(Hook::Pull, root, pf, &pf.repo_names(), &[])
}

fn commit(
    root: &Path,
    pf: &mut Pullfile,
    cwd: &Path,
    message: &str,
    all: bool,
    no_verify: bool,
    paths: &[PathBuf],
) -> Result<()> {
    let msg = git2::message_prettify(message, None)?;
    let violations = workspace::lint(pf, &msg)?;
    if !violations.is_empty() {
        for v in &violations {
            eprintln!("lint: {v}");
        }
        bail!("commit message rejected");
    }
    let id = pull_core::resolve_identity(pf, &Local::load(root)?)?;
    if pf.identity.require_signing && !id.sign {
        bail!("pullfile requires signed commits");
    }

    let routed = paths::route(root, pf, cwd, paths)?;
    pull_git::stage(root, pf, &routed, all)?;
    let mut targets = pull_git::staged_repos(root, pf)?;
    let extra = [("PULL_MESSAGE", msg.as_str())];
    if !no_verify {
        workspace::run_hook(Hook::Precommit, root, pf, &targets, &extra)?;
        // Like git, whatever the hook staged is part of the commit.
        targets = pull_git::staged_repos(root, pf)?;
    }
    if targets.is_empty() {
        bail!("nothing staged in any repo");
    }
    pull_git::commit(root, pf, &targets, &id, &msg)?;
    if !no_verify {
        workspace::run_hook(Hook::Postcommit, root, pf, &targets, &extra)?;
    }
    Ok(())
}

fn status_json(root: &Path, pf: &Pullfile) -> Result<()> {
    #[allow(unused_mut)]
    let mut doc = serde_json::json!({
        "root": root.display().to_string(),
        "features": workspace::features(),
        "repos": pull_git::repo_statuses(root, pf)?,
    });
    #[cfg(feature = "lint")]
    {
        let lint: pull_lint::Lint = pf.section(pull_lint::SECTION)?;
        doc["lint"] = serde_json::json!({
            "max_subject_length": lint.max_subject_length,
            "no_description": lint.no_description,
        });
    }
    println!("{}", serde_json::to_string_pretty(&doc)?);
    Ok(())
}

#[cfg(feature = "mcp")]
fn mcp(root: PathBuf) -> Result<()> {
    let env = std::sync::Arc::new(workspace::env_provider(&root));
    pull_mcp::serve(root, env)
}

/// A pullfile `mcp_servers` entry: `{command, args}`, kept raw (no env/root here — that's
/// filled in per workspace by [`mcp_servers_json`]).
#[cfg(feature = "mcp")]
#[derive(serde::Deserialize, Default)]
#[serde(default)]
struct McpServerConfig {
    /// Defaults to the section key.
    command: Option<String>,
    args: Vec<String>,
}

/// `pull` itself, plus every pullfile `mcp_servers` entry, as `{name: {command, args,
/// env}}` ready for an editor/agent's MCP settings: `command` resolved on PATH (`command
/// -v`, falling back to the bare name) and `PULL_ROOT` always set.
#[cfg(feature = "mcp")]
fn mcp_servers_json(root: &Path) -> Result<()> {
    let pf = Pullfile::load(root)?;
    let mut servers = serde_json::Map::new();
    servers.insert(
        "pull".to_string(),
        serde_json::json!({
            "command": resolve_command("pull"),
            "args": ["mcp", "--root", root.display().to_string()],
        }),
    );
    let configured: std::collections::BTreeMap<String, McpServerConfig> =
        pf.section("mcp_servers")?;
    for (name, cfg) in configured {
        let command = resolve_command(cfg.command.as_deref().unwrap_or(&name));
        servers.insert(
            name,
            serde_json::json!({
                "command": command,
                "args": cfg.args,
                "env": { "PULL_ROOT": root.display().to_string() },
            }),
        );
    }
    println!("{}", serde_json::to_string_pretty(&servers)?);
    Ok(())
}

/// `name`'s absolute path on `$PATH` (`command -v`), or `name` itself if that fails.
#[cfg(feature = "mcp")]
fn resolve_command(name: &str) -> String {
    std::process::Command::new("sh")
        .arg("-c")
        .arg(format!("command -v -- {}", shell_quote(name)))
        .output()
        .ok()
        .filter(|o| o.status.success())
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| name.to_string())
}

#[cfg(feature = "mcp")]
fn shell_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}

#[cfg(feature = "worktree")]
fn worktree(root: &Path, pf: &Pullfile, cmd: cli::WorktreeCmd) -> Result<()> {
    use cli::WorktreeCmd;
    match cmd {
        WorktreeCmd::Add { name, branch } => {
            paths::ensure_ignored(root, &format!("/{}/", pull_worktree::DIR))?;
            let dest = pull_worktree::add(root, pf, &name, branch.as_deref())?;
            println!("workspace: {}", dest.display());
        }
        WorktreeCmd::List => {
            for (name, path) in pull_worktree::list(root)? {
                let wpf = Pullfile::load(&path)?;
                let mut branches: Vec<_> = wpf.repos.iter().map(|r| r.branch.as_str()).collect();
                branches.dedup();
                println!("{name:<20} {:<12} {}", branches.join(","), path.display());
            }
        }
        WorktreeCmd::Rm { name, force } => pull_worktree::remove(root, pf, &name, force)?,
    }
    Ok(())
}

#[cfg(feature = "tool")]
fn tool(root: &Path, pf: &mut Pullfile, cwd: &Path, cmd: cli::ToolCmd) -> Result<()> {
    use cli::ToolCmd;
    let print = |m: &pull_tool::Manifest| {
        for (name, version) in &m.closure {
            let mark = if m.linked.contains(name) { "*" } else { " " };
            println!("{mark} {name} {version}");
        }
    };
    match cmd {
        ToolCmd::Sync => {}
        ToolCmd::Add { names } => {
            pull_tool::edit(root, pf, |p| p.add(&names))?;
        }
        ToolCmd::Rm { names } => {
            pull_tool::edit(root, pf, |p| p.remove(&names))?;
        }
        ToolCmd::Import { file } => {
            let other = pull_tool::read_brewfile(&cwd.join(file))?;
            pull_tool::edit(root, pf, |p| {
                let before = p.clone();
                p.merge(other);
                *p != before
            })?;
        }
        ToolCmd::List => {
            match pull_tool::manifest(root)? {
                Some(m) => print(&m),
                None => println!("not synced yet (run `pull tool sync`)"),
            }
            return Ok(());
        }
        ToolCmd::Gc => {
            for k in pull_tool::gc()? {
                println!("removed {k}");
            }
            return Ok(());
        }
    }
    print(&pull_tool::sync(root, pf)?);
    Ok(())
}
