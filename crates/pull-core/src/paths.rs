//! Paths in a workspace: routing user paths to repos, root-level ignore files.

use crate::{PULLFILE, Pullfile};
use anyhow::{Context, Result, bail};
use std::collections::BTreeMap;
use std::path::{Component, Path, PathBuf};

/// Map user paths onto (repo name -> repo-relative pathspecs), CODEOWNERS-style:
/// the first path component under the root picks the repo.
pub fn route(
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
pub fn absolutize(p: &Path) -> Result<PathBuf> {
    if let Ok(c) = p.canonicalize() {
        return Ok(c);
    }
    let parent = p.parent().context("bad path")?.canonicalize()?;
    Ok(parent.join(p.file_name().context("bad path")?))
}

/// Append `line` to the root's .gitignore unless it is already there.
pub fn ensure_ignored(root: &Path, line: &str) -> Result<()> {
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

/// Directory name for a clone URL (`.../foo.git` -> `foo`).
pub fn repo_name_from_url(url: &str) -> Result<String> {
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
