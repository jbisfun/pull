//! Commit message rules: the pullfile `lint` section.

use serde::{Deserialize, Serialize};

/// Pullfile section key.
pub const SECTION: &str = "lint";

#[derive(Serialize, Deserialize, Debug, Default, Clone)]
#[serde(default)]
pub struct Lint {
    /// Subject line only; no body.
    pub no_description: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max_subject_length: Option<u64>,
    /// Must parse as a Conventional Commit (needs the `conventional` feature).
    pub conventional: bool,
    pub no_trailing_period: bool,
}

/// Returns a list of violations (empty = ok). `msg` should already be prettified.
pub fn check(rules: &Lint, msg: &str) -> Vec<String> {
    let mut out = Vec::new();
    let subject = msg.lines().next().unwrap_or("").trim_end();

    if subject.trim().is_empty() {
        out.push("empty commit message".into());
        return out;
    }
    if rules.no_description && msg.lines().skip(1).any(|l| !l.trim().is_empty()) {
        out.push("no_description: message must be a single subject line".into());
    }
    if let Some(max) = rules.max_subject_length {
        let n = subject.chars().count() as u64;
        if n > max {
            out.push(format!(
                "max_subject_length: subject is {n} chars (max {max})"
            ));
        }
    }
    if rules.no_trailing_period && subject.ends_with('.') {
        out.push("no_trailing_period: subject ends with '.'".into());
    }
    if rules.conventional {
        #[cfg(feature = "conventional")]
        if let Err(e) = git_conventional::Commit::parse(msg) {
            out.push(format!("conventional: {e}"));
        }
        #[cfg(not(feature = "conventional"))]
        out.push("conventional: pull was built without the `conventional` feature".into());
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(feature = "conventional")]
    #[test]
    fn rules() {
        let r = Lint {
            no_description: true,
            max_subject_length: Some(20),
            conventional: true,
            no_trailing_period: true,
        };
        assert!(check(&r, "feat: add thing\n").is_empty());
        assert_eq!(check(&r, "feat: add thing\n\nbody\n").len(), 1);
        assert_eq!(check(&r, "add thing.\n").len(), 2);
        assert_eq!(check(&r, "feat: a very long subject line here\n").len(), 1);
    }
}
