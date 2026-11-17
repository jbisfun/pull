//! Repository operations on top of git2 (libgit2) + auth-git2.

use crate::config::Identity;
use anyhow::{Context, Result, bail};
use auth_git2::GitAuthenticator;
use git2::{
    BranchType, IndexAddOption, ObjectType, Oid, Repository, ResetType, Signature, StatusOptions,
};
use std::io::Write;
use std::path::Path;
use std::process::{Command, Stdio};

fn auth() -> GitAuthenticator {
    GitAuthenticator::default()
}

pub fn clone(url: &str, dest: &Path, branch: &str) -> Result<Repository> {
    let repo = auth()
        .clone_repo(url, dest)
        .with_context(|| format!("cloning {url}"))?;
    checkout_branch(&repo, branch)?;
    Ok(repo)
}

/// Make `branch` the checked-out branch, creating it from origin/<branch> if needed.
pub fn checkout_branch(repo: &Repository, branch: &str) -> Result<()> {
    if repo
        .head()
        .ok()
        .and_then(|h| h.shorthand().ok().map(String::from))
        .as_deref()
        == Some(branch)
    {
        return Ok(());
    }
    if repo.find_branch(branch, BranchType::Local).is_err() {
        let Ok(remote) = repo.find_branch(&format!("origin/{branch}"), BranchType::Remote) else {
            // Empty / new upstream: point HEAD at the unborn branch.
            repo.set_head(&format!("refs/heads/{branch}"))?;
            return Ok(());
        };
        let c = remote.get().peel_to_commit()?;
        let mut b = repo.branch(branch, &c, false)?;
        b.set_upstream(Some(&format!("origin/{branch}")))?;
    }
    let refname = format!("refs/heads/{branch}");
    let obj = repo.revparse_single(&refname)?;
    repo.checkout_tree(&obj, None)?;
    repo.set_head(&refname)?;
    Ok(())
}

pub fn fetch(repo: &Repository) -> Result<()> {
    let mut remote = repo.find_remote("origin")?;
    auth()
        .fetch(
            repo,
            &mut remote,
            &["+refs/heads/*:refs/remotes/origin/*"],
            None,
        )
        .context("fetch origin")?;
    Ok(())
}

pub fn push(repo: &Repository, branch: &str) -> Result<()> {
    let mut remote = repo.find_remote("origin")?;
    let spec = format!("refs/heads/{branch}:refs/heads/{branch}");
    auth()
        .push(repo, &mut remote, &[&spec])
        .context("push origin")?;
    // Mirror what `git push` does to the remote-tracking ref.
    if let Some(oid) = head_oid(repo) {
        repo.reference(&format!("refs/remotes/origin/{branch}"), oid, true, "push")?;
    }
    Ok(())
}

pub fn head_oid(repo: &Repository) -> Option<Oid> {
    repo.head().ok()?.target()
}

pub fn remote_oid(repo: &Repository, branch: &str) -> Option<Oid> {
    repo.refname_to_id(&format!("refs/remotes/origin/{branch}"))
        .ok()
}

/// Tracked changes in index or worktree (untracked files ignored).
pub fn is_dirty(repo: &Repository) -> Result<bool> {
    let mut o = StatusOptions::new();
    o.include_untracked(false).include_ignored(false);
    Ok(!repo.statuses(Some(&mut o))?.is_empty())
}

pub fn status_lines(repo: &Repository) -> Result<Vec<String>> {
    let mut o = StatusOptions::new();
    o.include_untracked(true).recurse_untracked_dirs(false);
    let mut out = Vec::new();
    for e in repo.statuses(Some(&mut o))?.iter() {
        let s = e.status();
        let idx = if s.is_index_new() {
            'A'
        } else if s.is_index_modified() {
            'M'
        } else if s.is_index_deleted() {
            'D'
        } else if s.is_index_renamed() {
            'R'
        } else {
            ' '
        };
        let wt = if s.is_wt_new() {
            '?'
        } else if s.is_wt_modified() {
            'M'
        } else if s.is_wt_deleted() {
            'D'
        } else {
            ' '
        };
        let idx = if wt == '?' { '?' } else { idx };
        out.push(format!("{idx}{wt} {}", e.path().unwrap_or("?")));
    }
    Ok(out)
}

/// Move the current branch to `target` if that is a fast-forward and the tree is clean.
/// Returns true if HEAD moved.
pub fn fast_forward(repo: &Repository, target: Oid) -> Result<bool> {
    let Some(head) = head_oid(repo) else {
        let obj = repo.find_object(target, Some(ObjectType::Commit))?;
        repo.reset(&obj, ResetType::Hard, None)?;
        return Ok(true);
    };
    if head == target || repo.graph_descendant_of(head, target)? {
        return Ok(false);
    }
    if !repo.graph_descendant_of(target, head)? {
        bail!(
            "diverged from {} (HEAD {}); resolve manually",
            short(target),
            short(head)
        );
    }
    if is_dirty(repo)? {
        bail!(
            "has uncommitted changes; not fast-forwarding to {}",
            short(target)
        );
    }
    let obj = repo.find_object(target, Some(ObjectType::Commit))?;
    repo.reset(&obj, ResetType::Hard, None)?;
    Ok(true)
}

pub fn reset_hard(repo: &Repository, target: Oid) -> Result<()> {
    let obj = repo.find_object(target, Some(ObjectType::Commit))?;
    repo.reset(&obj, ResetType::Hard, None)?;
    Ok(())
}

/// Stage paths (relative to the repo) like `git add`, including deletions.
pub fn stage(repo: &Repository, paths: &[String]) -> Result<()> {
    let mut idx = repo.index()?;
    idx.add_all(paths, IndexAddOption::DEFAULT, None)?;
    idx.update_all(paths, None)?;
    idx.write()?;
    Ok(())
}

/// `git commit -a` staging: tracked files only.
pub fn stage_tracked(repo: &Repository) -> Result<()> {
    let mut idx = repo.index()?;
    idx.update_all(["*"], None)?;
    idx.write()?;
    Ok(())
}

pub fn has_staged(repo: &Repository) -> Result<bool> {
    let head_tree = match repo.head() {
        Ok(h) => Some(h.peel_to_tree()?),
        Err(_) => None,
    };
    let idx = repo.index()?;
    let diff = repo.diff_tree_to_index(head_tree.as_ref(), Some(&idx), None)?;
    Ok(diff.deltas().len() > 0)
}

/// Commit the index as `id`, optionally GPG-signed. Updates HEAD's branch.
pub fn commit(repo: &Repository, id: &Identity, msg: &str) -> Result<Oid> {
    let mut idx = repo.index()?;
    let tree = repo.find_tree(idx.write_tree()?)?;
    // libgit2 rejects empty emails, but git (and the object format) allow `Name <>`.
    // Use a placeholder and blank it in the header before hashing/signing.
    const NO_EMAIL: &str = "no-email.pull.invalid";
    let email = if id.email.is_empty() {
        NO_EMAIL
    } else {
        id.email.as_str()
    };
    let sig = Signature::now(&id.name, email)?;
    let parent = match repo.head() {
        Ok(h) => Some(h.peel_to_commit()?),
        Err(_) => None,
    };
    let parents: Vec<_> = parent.iter().collect();
    let buf = repo.commit_create_buffer(&sig, &sig, msg, &tree, &parents)?;
    let raw = buf.as_str().context("commit buffer not utf-8")?;
    let content = if id.email.is_empty() {
        let (header, body) = raw.split_once("\n\n").unwrap_or((raw, ""));
        let header: Vec<String> = header
            .lines()
            .map(|l| {
                if l.starts_with("author ") || l.starts_with("committer ") {
                    l.replace(&format!("<{NO_EMAIL}>"), "<>")
                } else {
                    l.to_string()
                }
            })
            .collect();
        format!("{}\n\n{body}", header.join("\n"))
    } else {
        raw.to_string()
    };
    let content = content.as_str();

    let oid = if id.sign {
        let signature = gpg_sign(id, content)?;
        repo.commit_signed(content, &signature, None)?
    } else {
        repo.odb()?.write(ObjectType::Commit, content.as_bytes())?
    };

    let subject = msg.lines().next().unwrap_or("");
    let reflog = format!("commit: {subject}");
    let head = repo.find_reference("HEAD")?;
    match head.symbolic_target()? {
        Some(branch_ref) => {
            repo.reference(branch_ref, oid, true, &reflog)?;
        }
        None => repo.set_head_detached(oid)?,
    }
    Ok(oid)
}

/// Same protocol git uses for gpg.program: detached, armored signature over the commit buffer.
fn gpg_sign(id: &Identity, content: &str) -> Result<String> {
    let mut c = Command::new(&id.gpg_program);
    c.args(["--status-fd=2", "-bsa"]);
    if let Some(k) = &id.signing_key {
        c.args(["-u", k]);
    }
    let mut child = c
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .with_context(|| format!("running {}", id.gpg_program))?;
    child.stdin.take().unwrap().write_all(content.as_bytes())?;
    let out = child.wait_with_output()?;
    let status = String::from_utf8_lossy(&out.stderr);
    if !out.status.success() || !status.contains("[GNUPG:] SIG_CREATED ") {
        bail!("gpg failed to sign:\n{status}");
    }
    Ok(String::from_utf8(out.stdout)?)
}

pub fn short(oid: Oid) -> String {
    oid.to_string()[..8].to_string()
}
