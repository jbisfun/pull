mod config;
mod git;
mod hooks;
mod lint;

use anyhow::{Context, Result, bail};
use clap::{Parser, Subcommand};
use config::{LOCAL, Local, PULLFILE, Pullfile, Repo};
use git2::Repository;
use std::collections::BTreeMap;
use std::path::{Component, Path, PathBuf};

/// Multi-repo git wrapper driven by pullfile.plist.
#[derive(Parser)]
#[command(name = "pull", version)]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
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
    Status,
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
    /// Check a message against the pullfile lint rules.
    Lint { message: String },
    /// Print the identity commits will be written with.
    Whoami,
    /// Run a command in every cloned repo (e.g. `pull each git log -1`).
    Each {
        #[arg(required = true, trailing_var_arg = true, allow_hyphen_values = true)]
        cmd: Vec<String>,
    },
}

#[derive(Subcommand)]
enum RepoCmd {
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
    let root = config::find_root(&cwd)?;
    let mut pf = Pullfile::load(&root)?;

    match cli.cmd {
        Cmd::Init { .. } => unreachable!(),
        Cmd::Repo(RepoCmd::Add {
            upstream,
            name,
            branch,
        }) => {
            let name = match name {
                Some(n) => n,
                None => repo_name_from_url(&upstream)?,
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
            ensure_ignored(&root, &format!("/{name}/"))?;
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
        Cmd::Status => status(&root, &pf)?,
        Cmd::Add { paths } => {
            for (name, rel) in route(&root, &pf, &cwd, &paths)? {
                git::stage(&open(&root, &name)?, &rel)?;
            }
        }
        Cmd::Commit {
            message,
            all,
            no_verify,
            paths,
        } => commit(&root, &mut pf, &cwd, &message, all, no_verify, &paths)?,
        Cmd::Push => {
            for r in &pf.repos {
                let repo = open(&root, &r.name)?;
                let head = git::head_oid(&repo);
                if head.is_none() || head == git::remote_oid(&repo, &r.branch) {
                    continue;
                }
                println!("{}: pushing {}", r.name, r.branch);
                git::push(&repo, &r.branch).with_context(|| r.name.clone())?;
            }
            // The root repo (if any) carries the pullfile itself.
            if let Some(repo) = root_repo(&root)
                && repo.find_remote("origin").is_ok()
                    && let Some(b) = repo
                        .head()
                        .ok()
                        .and_then(|h| h.shorthand().ok().map(String::from))
                    {
                        println!("(root): pushing {b}");
                        git::push(&repo, &b).context("(root)")?;
                    }
        }
        Cmd::Lint { message } => {
            let msg = git2::message_prettify(&message, None)?;
            let v = lint::check(&pf.lint, &msg);
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
            let id = config::resolve_identity(&pf, &Local::load(&root)?)?;
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
        Cmd::Each { cmd } => {
            for r in &pf.repos {
                let dir = root.join(&r.name);
                if !dir.exists() {
                    continue;
                }
                println!("== {}", r.name);
                let st = std::process::Command::new(&cmd[0])
                    .args(&cmd[1..])
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
    ensure_ignored(cwd, &format!("/{LOCAL}"))
}

fn repo_name_from_url(url: &str) -> Result<String> {
    let last = url
        .trim_end_matches('/')
        .rsplit(['/', ':'])
        .next()
        .unwrap_or("")
        .trim_end_matches(".git");
    if last.is_empty() {
        bail!("can't derive a name from `{url}`; pass --name");
    }
    Ok(last.to_string())
}

fn ensure_ignored(root: &Path, line: &str) -> Result<()> {
    let p = root.join(".gitignore");
    let cur = std::fs::read_to_string(&p).unwrap_or_default();
    if cur.lines().any(|l| l.trim() == line) {
        return Ok(());
    }
    let mut s = cur;
    if !s.is_empty() && !s.ends_with('\n') {
        s.push('\n');
    }
    s.push_str(line);
    s.push('\n');
    std::fs::write(p, s)?;
    Ok(())
}

fn open(root: &Path, name: &str) -> Result<Repository> {
    Repository::open(root.join(name))
        .with_context(|| format!("{name}: not cloned (run `pull sync`)"))
}

/// The pullfile root itself, if it is the top of a git repo.
fn root_repo(root: &Path) -> Option<Repository> {
    let r = Repository::open(root).ok()?;
    (r.workdir()?.canonicalize().ok()? == root).then_some(r)
}

fn sync(root: &Path, pf: &mut Pullfile, to_upstream: bool) -> Result<()> {
    let mut failed = Vec::new();
    let mut changed = false;
    for r in pf.repos.iter_mut() {
        let dir = root.join(&r.name);
        let res: Result<()> = (|| {
            let fresh = !dir.join(".git").exists();
            let repo = if fresh {
                println!("{}: cloning {}", r.name, r.upstream);
                git::clone(&r.upstream, &dir, &r.branch)?
            } else {
                let repo = Repository::open(&dir)?;
                git::fetch(&repo)?;
                repo
            };
            // A fresh clone lands on upstream HEAD; put it on the pin instead.
            if fresh && !to_upstream
                && let Some(pin) = r.commit.as_deref() {
                    git::reset_hard(&repo, git2::Oid::from_str(pin)?)?;
                }
            let target = if to_upstream {
                git::remote_oid(&repo, &r.branch)
            } else {
                r.commit.as_deref().map(git2::Oid::from_str).transpose()?
            };
            if let Some(t) = target
                && git::fast_forward(&repo, t)? {
                    println!("{}: -> {}", r.name, git::short(t));
                }
            if to_upstream {
                let head = git::head_oid(&repo).map(|o| o.to_string());
                if head.is_some() && head != r.commit {
                    r.commit = head;
                    changed = true;
                }
            }
            Ok(())
        })();
        if let Err(e) = res {
            eprintln!("{}: {e:#}", r.name);
            failed.push(r.name.clone());
        }
    }
    if changed {
        pf.save(root)?;
    }
    if !failed.is_empty() {
        bail!("failed: {}", failed.join(", "));
    }
    let names: Vec<_> = pf.repos.iter().map(|r| r.name.clone()).collect();
    hooks::run("pull", &pf.hooks.pull, root, &names, &[])
}

fn status(root: &Path, pf: &Pullfile) -> Result<()> {
    for r in &pf.repos {
        let Ok(repo) = Repository::open(root.join(&r.name)) else {
            println!("{}: not cloned", r.name);
            continue;
        };
        let branch = repo
            .head()
            .ok()
            .and_then(|h| h.shorthand().ok().map(String::from))
            .unwrap_or("(unborn)".into());
        let head = git::head_oid(&repo);
        let mut flags = Vec::new();
        match (head, r.commit.as_deref()) {
            (Some(h), Some(p)) if h.to_string() != p => {
                flags.push(format!("pin {}", &p[..8.min(p.len())]))
            }
            (Some(_), None) => flags.push("unpinned".into()),
            _ => {}
        }
        if let (Some(h), Some(o)) = (head, git::remote_oid(&repo, &r.branch))
            && h != o {
                let (a, b) = repo.graph_ahead_behind(h, o)?;
                flags.push(format!("+{a}/-{b} origin"));
            }
        let h = head.map(git::short).unwrap_or("-".into());
        println!("{} [{branch} {h}] {}", r.name, flags.join(", "));
        for l in git::status_lines(&repo)? {
            println!("  {l}");
        }
    }
    Ok(())
}

/// Map user paths onto (repo name -> repo-relative pathspecs), CODEOWNERS-style:
/// the first path component under the root picks the repo.
fn route(
    root: &Path,
    pf: &Pullfile,
    cwd: &Path,
    paths: &[PathBuf],
) -> Result<BTreeMap<String, Vec<String>>> {
    let mut out: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for p in paths {
        let abs = absolutize(&cwd.join(p))?;
        let rel = abs
            .strip_prefix(root)
            .map_err(|_| anyhow::anyhow!("{} is outside the pullfile root", p.display()))?;
        let mut comps = rel.components();
        let Some(Component::Normal(first)) = comps.next() else {
            // The root itself: everything in every repo.
            for r in &pf.repos {
                out.entry(r.name.clone()).or_default().push("*".into());
            }
            continue;
        };
        let name = first.to_string_lossy().to_string();
        if !pf.repos.iter().any(|r| r.name == name) {
            bail!("{} is not inside any repo in {PULLFILE}", p.display());
        }
        let inner = comps.as_path().to_string_lossy().to_string();
        out.entry(name)
            .or_default()
            .push(if inner.is_empty() { "*".into() } else { inner });
    }
    Ok(out)
}

/// Canonicalize, tolerating a missing final component (deleted files).
fn absolutize(p: &Path) -> Result<PathBuf> {
    if let Ok(c) = p.canonicalize() {
        return Ok(c);
    }
    let parent = p.parent().context("bad path")?.canonicalize()?;
    Ok(parent.join(p.file_name().context("bad path")?))
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
    let violations = lint::check(&pf.lint, &msg);
    if !violations.is_empty() {
        for v in &violations {
            eprintln!("lint: {v}");
        }
        bail!("commit message rejected");
    }
    let id = config::resolve_identity(pf, &Local::load(root)?)?;
    if pf.identity.require_signing && !id.sign {
        bail!("pullfile requires signed commits");
    }

    // Stage, then collect repos with something to commit.
    let routed = route(root, pf, cwd, paths)?;
    let mut targets = Vec::new();
    for r in &pf.repos {
        let Ok(repo) = Repository::open(root.join(&r.name)) else {
            continue;
        };
        if all {
            git::stage_tracked(&repo)?;
        }
        if let Some(specs) = routed.get(&r.name) {
            git::stage(&repo, specs)?;
        }
        if git::has_staged(&repo)? {
            targets.push(r.name.clone());
        }
    }
    if targets.is_empty() {
        bail!("nothing staged in any repo");
    }

    if !no_verify {
        hooks::run(
            "precommit",
            &pf.hooks.precommit,
            root,
            &targets,
            &[("PULL_MESSAGE", &msg)],
        )?;
    }

    for name in &targets {
        let repo = open(root, name)?;
        let oid = git::commit(&repo, &id, &msg).with_context(|| name.clone())?;
        println!("{name}: {}", git::short(oid));
        pf.repo_mut(name).unwrap().commit = Some(oid.to_string());
    }
    pf.save(root)?;

    // If the root is a git repo, record the new pins with the same message.
    if let Some(repo) = root_repo(root) {
        git::stage(&repo, &[PULLFILE.into(), ".gitignore".into()])?;
        if git::has_staged(&repo)? {
            let oid = git::commit(&repo, &id, &msg).context("(root)")?;
            println!("(root): {}", git::short(oid));
        }
    }

    if !no_verify {
        hooks::run(
            "postcommit",
            &pf.hooks.postcommit,
            root,
            &targets,
            &[("PULL_MESSAGE", &msg)],
        )?;
    }
    Ok(())
}
