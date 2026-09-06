//! The redistributable allowlist for rule 8.

use std::collections::BTreeSet;
use std::path::Path;

/// SPDX identifiers under which OPR may host binaries itself.
pub struct Allowlist {
    ids: BTreeSet<String>,
}

/// Shipped in the binary for the same reason as the schema: a PR gate should
/// not depend on a relative path resolving.
pub const EMBEDDED_ALLOWLIST: &str = include_str!("../data/redistributable.txt");

impl Allowlist {
    pub fn embedded() -> Self {
        Self::parse(EMBEDDED_ALLOWLIST)
    }

    pub fn load(path: &Path) -> Result<Self, String> {
        let text = std::fs::read_to_string(path)
            .map_err(|e| format!("cannot read allowlist {}: {e}", path.display()))?;
        Ok(Self::parse(&text))
    }

    pub fn parse(text: &str) -> Self {
        let ids = text
            .lines()
            .map(str::trim)
            .filter(|l| !l.is_empty() && !l.starts_with('#'))
            .map(String::from)
            .collect();
        Self { ids }
    }

    pub fn contains(&self, id: &str) -> bool {
        self.ids.contains(id)
    }

    pub fn len(&self) -> usize {
        self.ids.len()
    }

    pub fn is_empty(&self) -> bool {
        self.ids.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn embedded_list_parses_and_is_not_empty() {
        let a = Allowlist::embedded();
        assert!(a.len() > 20, "allowlist looks truncated: {}", a.len());
        assert!(a.contains("MIT"));
        assert!(a.contains("GPL-3.0-or-later"));
    }

    #[test]
    fn comments_and_blanks_are_skipped() {
        let a = Allowlist::parse("# header\n\nMIT\n  Apache-2.0  \n");
        assert_eq!(a.len(), 2);
        assert!(a.contains("Apache-2.0"));
        assert!(!a.contains("# header"));
    }

    #[test]
    fn proprietary_identifiers_are_absent() {
        let a = Allowlist::embedded();
        assert!(!a.contains("LicenseRef-Google-Chrome-ToS"));
        assert!(!a.contains("CC-BY-NC-4.0"));
    }
}
