//! The pullfile `ignore` section: gitignore patterns for every repo, kept in each
//! repo's `.git/info/exclude` between markers (nothing gets committed for it).

use anyhow::{Context, Result};
use git2::Repository;
use std::path::Path;

/// Pullfile section key (an array of patterns).
pub const SECTION: &str = "ignore";

const BEGIN: &str = "# >>> pull ignore (pullfile.plist)";
const END: &str = "# <<< pull ignore";

/// Write `patterns` into every cloned repo's exclude file, leaving the rest alone.
pub fn apply(root: &Path, repos: &[String], patterns: &[String]) {
    for name in repos {
        let Ok(repo) = Repository::open(root.join(name)) else {
            continue;
        };
        if let Err(e) = write_exclude(&repo.commondir().join("info/exclude"), patterns) {
            eprintln!("{name}: ignore: {e:#}");
        }
    }
}

pub fn write_exclude(path: &Path, patterns: &[String]) -> Result<()> {
    let cur = std::fs::read_to_string(path).unwrap_or_default();
    let mut out = String::new();
    let mut inside = false;
    for line in cur.lines() {
        match line {
            BEGIN => inside = true,
            END => inside = false,
            _ if !inside => {
                out.push_str(line);
                out.push('\n');
            }
            _ => {}
        }
    }
    if !patterns.is_empty() {
        out.push_str(BEGIN);
        out.push('\n');
        for p in patterns {
            out.push_str(p);
            out.push('\n');
        }
        out.push_str(END);
        out.push('\n');
    }
    if out != cur {
        std::fs::create_dir_all(path.parent().context("exclude path")?)?;
        std::fs::write(path, out)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn replaces_only_its_block() {
        let dir = std::env::temp_dir().join(format!("pull-ignore-{}", std::process::id()));
        let p = dir.join("exclude");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(&p, "mine\n").unwrap();
        write_exclude(&p, &["a".into(), "b".into()]).unwrap();
        write_exclude(&p, &["c".into()]).unwrap();
        assert_eq!(
            std::fs::read_to_string(&p).unwrap(),
            format!("mine\n{BEGIN}\nc\n{END}\n")
        );
        write_exclude(&p, &[]).unwrap();
        assert_eq!(std::fs::read_to_string(&p).unwrap(), "mine\n");
        std::fs::remove_dir_all(dir).ok();
    }
}
