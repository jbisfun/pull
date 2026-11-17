//! The pullfile `hooks` section: shell commands run around commits and syncs.

use anyhow::{Result, bail};
use serde::{Deserialize, Serialize};
use std::path::Path;
use std::process::Command;

/// Pullfile section key.
pub const SECTION: &str = "hooks";

#[derive(Serialize, Deserialize, Debug, Default, Clone)]
#[serde(default)]
pub struct Hooks {
    pub precommit: Vec<String>,
    pub postcommit: Vec<String>,
    pub pull: Vec<String>,
}

/// Run each hook command through `sh -c` in the pullfile root.
/// Env: the workspace env (`pull env`), PULL_ROOT, PULL_HOOK, PULL_REPOS
/// (space-separated), plus `extra`.
pub fn run(
    kind: &str,
    cmds: &[String],
    root: &Path,
    repos: &[String],
    env: &[(String, String)],
    extra: &[(&str, &str)],
) -> Result<()> {
    for cmd in cmds {
        eprintln!("[{kind}] {cmd}");
        let mut c = Command::new("sh");
        c.arg("-c")
            .arg(cmd)
            .current_dir(root)
            .envs(env.iter().map(|(k, v)| (k, v)))
            .env("PULL_ROOT", root)
            .env("PULL_HOOK", kind)
            .env("PULL_REPOS", repos.join(" "));
        for (k, v) in extra {
            c.env(k, v);
        }
        let st = c.status()?;
        if !st.success() {
            bail!("{kind} hook failed ({st}): {cmd}");
        }
    }
    Ok(())
}
