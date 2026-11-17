//! pullfile.plist (shared, committed) and local.toml (per-machine, ignored).

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

pub const PULLFILE: &str = "pullfile.plist";
pub const LOCAL: &str = "local.toml";

#[derive(Serialize, Deserialize, Debug, Default, Clone)]
#[serde(default)]
pub struct Pullfile {
    pub identity: IdentityPolicy,
    /// Shared environment, like an .envrc for the whole workspace.
    #[serde(skip_serializing_if = "Env::is_empty")]
    pub env: Env,
    pub lint: Lint,
    pub hooks: Hooks,
    pub repos: Vec<Repo>,
    /// launchd jobs for this workspace (launchd plist keys), run by `pull launchd`.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub jobs: Vec<crate::launchd::Job>,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct Repo {
    /// Directory name under the pullfile root.
    pub name: String,
    pub upstream: String,
    #[serde(default = "default_branch")]
    pub branch: String,
    /// Pinned commit. Updated by `pull commit` / `pull update`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub commit: Option<String>,
}

fn default_branch() -> String {
    "main".into()
}

#[derive(Serialize, Deserialize, Debug, Default, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum EmailPolicy {
    /// Commits carry an empty email (`Name <>`). Default.
    #[default]
    None,
    /// Use the email from local.toml if one is set.
    Local,
}

#[derive(Serialize, Deserialize, Debug, Default, Clone)]
#[serde(default)]
pub struct IdentityPolicy {
    /// Selects `[orgs.<org>]` from local.toml.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub org: Option<String>,
    pub email: EmailPolicy,
    pub require_signing: bool,
}

#[derive(Serialize, Deserialize, Debug, Default, Clone)]
#[serde(default)]
pub struct Lint {
    /// Subject line only; no body.
    pub no_description: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max_subject_length: Option<u64>,
    /// Must parse as a Conventional Commit.
    pub conventional: bool,
    pub no_trailing_period: bool,
}

/// Environment for the workspace. Values expand `~`, `$VAR` and `${VAR}` (including
/// `$PULL_ROOT`); relative PATH entries are relative to the pullfile root.
#[derive(Serialize, Deserialize, Debug, Default, Clone)]
#[serde(default)]
pub struct Env {
    /// Prepended to PATH, first entry wins.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub path: Vec<String>,
    /// Exported variables (toolchain selection, etc.).
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    pub vars: BTreeMap<String, String>,
}

impl Env {
    pub fn is_empty(&self) -> bool {
        self.path.is_empty() && self.vars.is_empty()
    }
}

#[derive(Serialize, Deserialize, Debug, Default, Clone)]
#[serde(default)]
pub struct Hooks {
    pub precommit: Vec<String>,
    pub postcommit: Vec<String>,
    pub pull: Vec<String>,
}

impl Pullfile {
    pub fn load(root: &Path) -> Result<Self> {
        let p = root.join(PULLFILE);
        plist::from_file(&p).with_context(|| format!("reading {}", p.display()))
    }

    pub fn save(&self, root: &Path) -> Result<()> {
        let p = root.join(PULLFILE);
        plist::to_file_xml(&p, self).with_context(|| format!("writing {}", p.display()))
    }

    pub fn repo_mut(&mut self, name: &str) -> Option<&mut Repo> {
        self.repos.iter_mut().find(|r| r.name == name)
    }
}

#[derive(Serialize, Deserialize, Debug, Default, Clone)]
pub struct Local {
    /// Handle shown as author/committer name.
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub email: Option<String>,
    /// GPG key id/fingerprint. If unset and signing is on, gpg's default key is used.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub signing_key: Option<String>,
    #[serde(default)]
    pub sign: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub gpg_program: Option<String>,
    #[serde(default)]
    pub orgs: BTreeMap<String, OrgIdentity>,
    /// Machine-specific env layered over the pullfile's (`[env]` with `path`/`vars`).
    #[serde(default, skip_serializing_if = "Env::is_empty")]
    pub env: Env,
}

#[derive(Serialize, Deserialize, Debug, Default, Clone)]
pub struct OrgIdentity {
    pub name: Option<String>,
    pub email: Option<String>,
    pub signing_key: Option<String>,
    pub sign: Option<bool>,
}

impl Local {
    /// `{root}/local.toml`, falling back to `$XDG_CONFIG_HOME/pull/local.toml`.
    pub fn path(root: &Path) -> Option<PathBuf> {
        let here = root.join(LOCAL);
        if here.exists() {
            return Some(here);
        }
        let global = dirs::config_dir()?.join("pull").join(LOCAL);
        global.exists().then_some(global)
    }

    pub fn load(root: &Path) -> Result<Self> {
        let Some(p) = Self::path(root) else {
            bail!(
                "no {LOCAL} found in {} or ~/.config/pull (run `pull init`)",
                root.display()
            );
        };
        let s = std::fs::read_to_string(&p).with_context(|| format!("reading {}", p.display()))?;
        toml::from_str(&s).with_context(|| format!("parsing {}", p.display()))
    }
}

/// The identity actually written into commits.
#[derive(Debug, Clone)]
pub struct Identity {
    pub name: String,
    pub email: String,
    pub sign: bool,
    pub signing_key: Option<String>,
    pub gpg_program: String,
}

pub fn resolve_identity(pf: &Pullfile, local: &Local) -> Result<Identity> {
    let org = match &pf.identity.org {
        Some(o) => Some(local.orgs.get(o).with_context(|| {
            format!("pullfile wants org `{o}` but local.toml has no [orgs.{o}]")
        })?),
        None => None,
    };
    let name = org
        .and_then(|o| o.name.clone())
        .unwrap_or_else(|| local.name.clone());
    if name.trim().is_empty() {
        bail!("local.toml: `name` is empty");
    }
    let email = match pf.identity.email {
        EmailPolicy::None => String::new(),
        EmailPolicy::Local => org
            .and_then(|o| o.email.clone())
            .or_else(|| local.email.clone())
            .unwrap_or_default(),
    };
    let sign = org.and_then(|o| o.sign).unwrap_or(local.sign) || pf.identity.require_signing;
    let signing_key = org
        .and_then(|o| o.signing_key.clone())
        .or_else(|| local.signing_key.clone());
    Ok(Identity {
        name,
        email,
        sign,
        signing_key,
        gpg_program: local.gpg_program.clone().unwrap_or_else(|| "gpg".into()),
    })
}

/// Walk up from `start` to the directory containing pullfile.plist.
pub fn find_root(start: &Path) -> Result<PathBuf> {
    let mut d = start.canonicalize()?;
    loop {
        if d.join(PULLFILE).is_file() {
            return Ok(d);
        }
        if !d.pop() {
            bail!(
                "no {PULLFILE} found in {} or any parent (run `pull init`)",
                start.display()
            );
        }
    }
}
