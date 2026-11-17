//! Glue between the core and the optional features: each helper does the feature's work
//! when it is compiled in and a neutral fallback otherwise, so commands never need to
//! know which features exist.

use anyhow::Result;
use pull_core::Pullfile;
use std::path::Path;

/// Enabled cargo features (see build.rs).
pub fn features() -> Vec<&'static str> {
    env!("PULL_FEATURES").split_whitespace().collect()
}

/// Pullfile sections and the feature that acts on them.
const SECTIONS: &[(&str, &str)] = &[
    ("env", "env"),
    ("hooks", "hooks"),
    ("lint", "lint"),
    ("ignore", "ignore"),
    ("jobs", "launchd"),
    ("tool", "tool"),
];

/// Say so when the pullfile configures something this build can't do (the section is
/// still kept when the pullfile is rewritten).
pub fn warn_unsupported(pf: &Pullfile) {
    let have = features();
    for (key, feature) in SECTIONS {
        if pf.has_section(key) && !have.contains(feature) {
            eprintln!("pull: ignoring pullfile `{key}` (built without the `{feature}` feature)");
        }
    }
}

/// The workspace environment: pullfile `env` + local.toml `[env]` with the `env` feature,
/// otherwise just PULL_ROOT. With `tool`, the workspace profile's bin dirs are on PATH
/// (after the `env` paths, so those can shadow packages).
pub fn env(root: &Path, pf: &Pullfile) -> Result<Vec<(String, String)>> {
    let tool_paths = tool_paths(root, pf);
    #[cfg(feature = "env")]
    {
        // Lowest-priority layer: resolve puts later layers' paths first.
        let tool = pull_env::Env {
            path: tool_paths.iter().map(|p| p.display().to_string()).collect(),
            ..Default::default()
        };
        let shared: pull_env::Env = pf.section(pull_env::SECTION)?;
        let local: Option<pull_env::Env> = pull_core::Local::load(root)
            .ok()
            .map(|l| l.section(pull_env::SECTION))
            .transpose()?;
        let layers: Vec<&pull_env::Env> = [&tool, &shared].into_iter().chain(local.as_ref()).collect();
        pull_env::resolve(root, &layers)
    }
    #[cfg(not(feature = "env"))]
    {
        let mut out = vec![("PULL_ROOT".to_string(), root.display().to_string())];
        if !tool_paths.is_empty() {
            let current = std::env::var_os("PATH").unwrap_or_default();
            let joined = std::env::join_paths(
                tool_paths.into_iter().chain(std::env::split_paths(&current)),
            )?;
            out.push(("PATH".into(), joined.to_string_lossy().into_owned()));
        }
        Ok(out)
    }
}

/// PATH entries of the workspace package profile (none without the `tool` feature).
fn tool_paths(root: &Path, pf: &Pullfile) -> Vec<std::path::PathBuf> {
    #[cfg(feature = "tool")]
    {
        pull_tool::path_entries(root, pf)
    }
    #[cfg(not(feature = "tool"))]
    {
        let _ = (root, pf);
        Vec::new()
    }
}

/// [`env`] re-read from disk on every call, for long-running servers (daemon, MCP).
#[allow(dead_code)]
pub fn env_provider(root: &Path) -> impl Fn() -> Vec<(String, String)> + Send + Sync + 'static {
    let root = root.to_path_buf();
    move || {
        Pullfile::load(&root)
            .and_then(|pf| env(&root, &pf))
            .unwrap_or_default()
    }
}

/// Which hook list to run.
#[derive(Clone, Copy)]
pub enum Hook {
    Precommit,
    Postcommit,
    Pull,
}

/// Run a pullfile hook (no-op without the `hooks` feature).
pub fn run_hook(
    hook: Hook,
    root: &Path,
    pf: &Pullfile,
    repos: &[String],
    extra: &[(&str, &str)],
) -> Result<()> {
    #[cfg(feature = "hooks")]
    {
        let hooks: pull_hooks::Hooks = pf.section(pull_hooks::SECTION)?;
        let (kind, cmds) = match hook {
            Hook::Precommit => ("precommit", &hooks.precommit),
            Hook::Postcommit => ("postcommit", &hooks.postcommit),
            Hook::Pull => ("pull", &hooks.pull),
        };
        if cmds.is_empty() {
            return Ok(());
        }
        pull_hooks::run(kind, cmds, root, repos, &env(root, pf)?, extra)
    }
    #[cfg(not(feature = "hooks"))]
    {
        let _ = (hook, root, pf, repos, extra);
        Ok(())
    }
}

/// Lint violations for a commit message (none without the `lint` feature).
pub fn lint(pf: &Pullfile, msg: &str) -> Result<Vec<String>> {
    #[cfg(feature = "lint")]
    {
        let rules: pull_lint::Lint = pf.section(pull_lint::SECTION)?;
        Ok(pull_lint::check(&rules, msg))
    }
    #[cfg(not(feature = "lint"))]
    {
        let _ = (pf, msg);
        Ok(Vec::new())
    }
}

/// Keep the pullfile `ignore` patterns in every repo's exclude file.
pub fn apply_ignores(root: &Path, pf: &Pullfile) {
    #[cfg(feature = "ignore")]
    match pf.section::<Vec<String>>(pull_ignore::SECTION) {
        Ok(patterns) => pull_ignore::apply(root, &pf.repo_names(), &patterns),
        Err(e) => eprintln!("pull: {e:#}"),
    }
    #[cfg(not(feature = "ignore"))]
    let _ = (root, pf);
}
