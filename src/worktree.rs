//! Workspace worktrees: `pull worktree add NAME` makes `{root}/.worktrees/NAME/`, a full
//! pull workspace whose repos are git worktrees of the main ones on branch NAME.
//! Run any pull command inside it (it has its own pullfile.plist with the new branch).

use crate::config::{LOCAL, PULLFILE, Pullfile};
use crate::git;
use anyhow::{Context, Result, bail};
use git2::{BranchType, Repository, WorktreeAddOptions, WorktreePruneOptions};
use std::path::{Path, PathBuf};

pub const DIR: &str = ".worktrees";

pub fn path(root: &Path, name: &str) -> PathBuf {
    root.join(DIR).join(name)
}

fn check_name(name: &str) -> Result<()> {
    if name.is_empty() || name.contains(['/', '\\']) || name.starts_with('.') {
        bail!("invalid worktree name `{name}`");
    }
    Ok(())
}

pub fn add(root: &Path, pf: &Pullfile, name: &str, branch: Option<&str>) -> Result<PathBuf> {
    check_name(name)?;
    let branch = branch.unwrap_or(name);
    let dest = path(root, name);
    if dest.exists() {
        bail!("{} already exists", dest.display());
    }
    std::fs::create_dir_all(&dest)?;

    let mut wpf = pf.clone();
    for r in wpf.repos.iter_mut() {
        let repo = Repository::open(root.join(&r.name))
            .with_context(|| format!("{}: not cloned (run `pull sync`)", r.name))?;
        // Branch from the main checkout's HEAD unless it already exists.
        let reference = match repo.find_branch(branch, BranchType::Local) {
            Ok(b) => b.into_reference(),
            Err(_) => {
                let head = repo
                    .head()
                    .and_then(|h| h.peel_to_commit())
                    .with_context(|| format!("{}: no commits to branch from", r.name))?;
                repo.branch(branch, &head, false)?.into_reference()
            }
        };
        let mut opts = WorktreeAddOptions::new();
        opts.reference(Some(&reference));
        repo.worktree(name, &dest.join(&r.name), Some(&opts))
            .with_context(|| format!("{}: adding worktree", r.name))?;
        println!("{}: {} on {branch}", r.name, dest.join(&r.name).display());
        r.branch = branch.to_string();
    }
    wpf.save(&dest)?;
    for f in [LOCAL, ".gitignore", ".envrc"] {
        if root.join(f).exists() {
            std::fs::copy(root.join(f), dest.join(f))?;
        }
    }
    Ok(dest)
}

pub fn list(root: &Path) -> Result<Vec<(String, PathBuf)>> {
    let dir = root.join(DIR);
    let mut out = Vec::new();
    for e in std::fs::read_dir(&dir).into_iter().flatten().flatten() {
        if e.path().join(PULLFILE).is_file() {
            out.push((e.file_name().to_string_lossy().into_owned(), e.path()));
        }
    }
    out.sort();
    Ok(out)
}

pub fn remove(root: &Path, pf: &Pullfile, name: &str, force: bool) -> Result<()> {
    check_name(name)?;
    let dest = path(root, name);
    // Refuse before touching anything if any worktree has uncommitted work.
    if !force {
        for r in &pf.repos {
            if let Ok(wt) = Repository::open(dest.join(&r.name))
                && git::is_dirty(&wt)?
            {
                bail!("{}: uncommitted changes in worktree (use --force)", r.name);
            }
        }
    }
    for r in &pf.repos {
        let Ok(repo) = Repository::open(root.join(&r.name)) else {
            continue;
        };
        let Ok(wt) = repo.find_worktree(name) else {
            continue;
        };
        let wt_path = wt.path().to_path_buf();
        if wt_path.exists() {
            std::fs::remove_dir_all(&wt_path)?;
        }
        wt.prune(Some(
            WorktreePruneOptions::new()
                .valid(true)
                .locked(force)
                .working_tree(true),
        ))
        .with_context(|| format!("{}: pruning worktree", r.name))?;
        println!("{}: removed worktree {name} (branch kept)", r.name);
    }
    if dest.exists() {
        std::fs::remove_dir_all(&dest)?;
    }
    Ok(())
}
