//! git across a pull workspace: clone/sync, status, staging, the one-message commit
//! across repos, push. Hooks, lint and env are not known here: the caller wraps these
//! steps with whatever features it was built with.

pub mod git;

pub use git::Change;

use anyhow::{Context, Result, bail};
use git2::Repository;
use pull_core::{Identity, PULLFILE, Pullfile};
use std::collections::BTreeMap;
use std::path::Path;

pub fn open(root: &Path, name: &str) -> Result<Repository> {
    Repository::open(root.join(name))
        .with_context(|| format!("{name}: not cloned (run `pull sync`)"))
}

/// The pullfile root itself, if it is the top of a git repo.
pub fn root_repo(root: &Path) -> Option<Repository> {
    let r = Repository::open(root).ok()?;
    (r.workdir()?.canonicalize().ok()? == root).then_some(r)
}

/// Keep a repo dir out of the root repo's `git status`, if the root is a git repo.
/// Uses `.git/info/exclude`, not `.gitignore`: editors (Zed/ycode) honour `.gitignore`
/// outside of git too and would stop scanning the repo, hiding it from the git panel.
pub fn exclude_from_root_repo(root: &Path, name: &str) -> Result<()> {
    let Some(repo) = root_repo(root) else {
        return Ok(());
    };
    let info = repo.path().join("info");
    std::fs::create_dir_all(&info)?;
    let p = info.join("exclude");
    let line = format!("/{name}/");
    let cur = std::fs::read_to_string(&p).unwrap_or_default();
    if cur.lines().any(|l| l.trim() == line) {
        return Ok(());
    }
    let sep = if cur.is_empty() || cur.ends_with('\n') {
        ""
    } else {
        "\n"
    };
    std::fs::write(&p, format!("{cur}{sep}{line}\n"))?;
    Ok(())
}

/// Clone missing repos, fetch, and fast-forward to the pins (or, `to_upstream`, to the
/// upstream branches and re-pin). Saves the pullfile if pins changed.
pub fn sync(root: &Path, pf: &mut Pullfile, to_upstream: bool) -> Result<()> {
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
            if fresh
                && !to_upstream
                && let Some(pin) = r.commit.as_deref()
            {
                git::reset_hard(&repo, git2::Oid::from_str(pin)?)?;
            }
            let target = if to_upstream {
                git::remote_oid(&repo, &r.branch)
            } else {
                r.commit.as_deref().map(git2::Oid::from_str).transpose()?
            };
            if let Some(t) = target
                && git::fast_forward(&repo, t)?
            {
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
    Ok(())
}

fn branch_name(repo: &Repository) -> Option<String> {
    repo.head()
        .ok()
        .and_then(|h| h.shorthand().ok().map(String::from))
}

/// Human-readable status of every repo.
pub fn print_status(root: &Path, pf: &Pullfile) -> Result<()> {
    for r in &pf.repos {
        let Ok(repo) = Repository::open(root.join(&r.name)) else {
            println!("{}: not cloned", r.name);
            continue;
        };
        let branch = branch_name(&repo).unwrap_or("(unborn)".into());
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
            && h != o
        {
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

#[derive(serde::Serialize)]
pub struct RepoStatus {
    pub name: String,
    pub path: String,
    pub cloned: bool,
    pub branch: Option<String>,
    pub head: Option<String>,
    pub pinned: Option<String>,
    pub ahead: usize,
    pub behind: usize,
    pub changes: Vec<Change>,
}

/// Machine-readable status of every repo (`pull status --json`).
pub fn repo_statuses(root: &Path, pf: &Pullfile) -> Result<Vec<RepoStatus>> {
    let mut out = Vec::new();
    for r in &pf.repos {
        let mut st = RepoStatus {
            name: r.name.clone(),
            path: root.join(&r.name).display().to_string(),
            cloned: false,
            branch: None,
            head: None,
            pinned: r.commit.clone(),
            ahead: 0,
            behind: 0,
            changes: Vec::new(),
        };
        if let Ok(repo) = Repository::open(root.join(&r.name)) {
            st.cloned = true;
            st.branch = branch_name(&repo);
            let head = git::head_oid(&repo);
            st.head = head.map(|h| h.to_string());
            if let (Some(h), Some(o)) = (head, git::remote_oid(&repo, &r.branch))
                && h != o
            {
                (st.ahead, st.behind) = repo.graph_ahead_behind(h, o)?;
            }
            st.changes = git::changes(&repo)?;
        }
        out.push(st);
    }
    Ok(out)
}

/// Stage routed pathspecs (and, `all`, every tracked modification) in each repo.
pub fn stage(
    root: &Path,
    pf: &Pullfile,
    routed: &BTreeMap<String, Vec<String>>,
    all: bool,
) -> Result<()> {
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
    }
    Ok(())
}

/// Repos with something staged.
pub fn staged_repos(root: &Path, pf: &Pullfile) -> Result<Vec<String>> {
    let mut out = Vec::new();
    for r in &pf.repos {
        if let Ok(repo) = Repository::open(root.join(&r.name))
            && git::has_staged(&repo)?
        {
            out.push(r.name.clone());
        }
    }
    Ok(out)
}

/// Commit `targets` with one message and identity, pin the new commits, and (if the root
/// is a git repo) commit the updated pullfile there too.
pub fn commit(
    root: &Path,
    pf: &mut Pullfile,
    targets: &[String],
    id: &Identity,
    msg: &str,
) -> Result<()> {
    for name in targets {
        let repo = open(root, name)?;
        let oid = git::commit(&repo, id, msg).with_context(|| name.clone())?;
        println!("{name}: {}", git::short(oid));
        if let Some(r) = pf.repo_mut(name) {
            r.commit = Some(oid.to_string());
        }
    }
    pf.save(root)?;
    if let Some(repo) = root_repo(root) {
        git::stage(&repo, &[PULLFILE.into(), ".gitignore".into()])?;
        if git::has_staged(&repo)? {
            let oid = git::commit(&repo, id, msg).context("(root)")?;
            println!("(root): {}", git::short(oid));
        }
    }
    Ok(())
}

/// Push every repo whose branch is ahead of origin, then the root repo (if any).
pub fn push(root: &Path, pf: &Pullfile) -> Result<()> {
    for r in &pf.repos {
        let repo = open(root, &r.name)?;
        let head = git::head_oid(&repo);
        if head.is_none() || head == git::remote_oid(&repo, &r.branch) {
            continue;
        }
        println!("{}: pushing {}", r.name, r.branch);
        git::push(&repo, &r.branch).with_context(|| r.name.clone())?;
    }
    // The root repo (if any) carries the pullfile itself.
    if let Some(repo) = root_repo(root)
        && repo.find_remote("origin").is_ok()
        && let Some(b) = branch_name(&repo)
    {
        println!("(root): pushing {b}");
        git::push(&repo, &b).context("(root)")?;
    }
    Ok(())
}
