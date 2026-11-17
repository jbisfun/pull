//! Workspace packages: the pullfile `tool` section is a Brewfile-shaped package list
//! (`tap`, `brew`) that jbisfun/tool pours from Linuxbrew bottles into its shared store and
//! links into the workspace profile `.pull/tool/`. The env adds the profile's `bin`/`sbin`
//! to PATH.

use anyhow::Result;
use pull_core::Pullfile;
use std::path::{Path, PathBuf};
pub use tool::{Manifest, Packages, Store};

/// Pullfile section key.
pub const SECTION: &str = "tool";

/// The workspace profile, relative to the root.
pub const PROFILE: &str = ".pull/tool";

pub fn profile(root: &Path) -> PathBuf {
    root.join(PROFILE)
}

/// The package list from the pullfile.
pub fn packages(pf: &Pullfile) -> Result<Packages> {
    pf.section(SECTION)
}

/// PATH entries for the workspace env (none unless the pullfile has a `tool` section).
pub fn path_entries(root: &Path, pf: &Pullfile) -> Vec<PathBuf> {
    if pf.has_section(SECTION) {
        tool::path_entries(&profile(root))
    } else {
        Vec::new()
    }
}

/// Install the pullfile's packages and swap the workspace profile to exactly that set.
pub fn sync(root: &Path, pf: &Pullfile) -> Result<Manifest> {
    tool::sync(&Store::open()?, &packages(pf)?, &profile(root))
}

/// Edit the package list in the pullfile (saved only if it changed). Returns whether it did.
pub fn edit(root: &Path, pf: &mut Pullfile, f: impl FnOnce(&mut Packages) -> bool) -> Result<bool> {
    let mut pkgs = packages(pf)?;
    if !f(&mut pkgs) && pf.has_section(SECTION) {
        return Ok(false);
    }
    pf.set_section(SECTION, &pkgs)?;
    pf.save(root)?;
    Ok(true)
}

/// The workspace profile's manifest, if it has been synced.
pub fn manifest(root: &Path) -> Result<Option<Manifest>> {
    Manifest::load(&profile(root))
}

/// Delete store kegs no live profile (in any workspace) uses.
pub fn gc() -> Result<Vec<String>> {
    tool::gc(&Store::open()?)
}

/// Read a Brewfile into a package list.
pub fn read_brewfile(path: &Path) -> Result<Packages> {
    Packages::from_brewfile(path)
}
