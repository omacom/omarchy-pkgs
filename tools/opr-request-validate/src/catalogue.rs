//! The list of package names that already exist.
//!
//! Supplied as a file rather than fetched. The PR stage has no network, and a
//! validator that reaches out to build its own ground truth is a validator
//! whose result depends on whoever answers.

use std::collections::HashSet;
use std::path::Path;

/// Arch `core` + `extra` plus OPR is on the order of 15k names. The cap exists
/// to bound work, not to express a real limit.
pub const MAX_ENTRIES: usize = 200_000;

pub struct Catalogue {
    names: HashSet<String>,
    /// Iteration order is fixed so a name equidistant from two entries always
    /// reports the same neighbour.
    sorted: Vec<String>,
}

impl Catalogue {
    pub fn load(path: &Path) -> Result<Self, String> {
        let text = std::fs::read_to_string(path)
            .map_err(|e| format!("cannot read catalogue {}: {e}", path.display()))?;
        Ok(Self::parse(&text))
    }

    /// Blank lines and `#` comments are skipped so the file can be generated
    /// with a provenance header.
    pub fn parse(text: &str) -> Self {
        let mut names = HashSet::new();
        for line in text.lines().take(MAX_ENTRIES) {
            let entry = line.trim();
            if entry.is_empty() || entry.starts_with('#') {
                continue;
            }
            names.insert(entry.to_string());
        }
        let mut sorted: Vec<String> = names.iter().cloned().collect();
        sorted.sort();
        Self { names, sorted }
    }

    pub fn is_empty(&self) -> bool {
        self.names.is_empty()
    }

    pub fn len(&self) -> usize {
        self.names.len()
    }

    /// Rule 4: exact collision.
    pub fn contains(&self, name: &str) -> bool {
        self.names.contains(name)
    }

    /// Rule 5: the first catalogue entry exactly one edit away.
    ///
    /// Distance 0 is rule 4's finding, so an exact match is not reported here
    /// — one mistake should produce one diagnostic.
    pub fn nearest_at_distance_one(&self, name: &str) -> Option<&str> {
        self.sorted
            .iter()
            .find(|entry| entry.as_str() != name && distance_is_one(name, entry))
            .map(String::as_str)
    }
}

/// Whether two strings are exactly one edit (insert, delete, or substitute)
/// apart.
///
/// Specialised rather than a general Levenshtein matrix because the only
/// question rule 5 asks is "is the distance below 2", and this answers it in
/// one pass per entry instead of building a DP table against every one of
/// ~15k catalogue names.
///
/// Note this is Levenshtein, as the spec specifies, not Damerau-Levenshtein:
/// a transposition counts as two edits and therefore passes. See the notes in
/// the README about that gap.
pub fn distance_is_one(a: &str, b: &str) -> bool {
    if a == b {
        return false;
    }

    let a: Vec<char> = a.chars().collect();
    let b: Vec<char> = b.chars().collect();

    // Cheap rejection before any scanning.
    let (long, short) = if a.len() >= b.len() {
        (&a, &b)
    } else {
        (&b, &a)
    };
    if long.len() - short.len() > 1 {
        return false;
    }

    if long.len() == short.len() {
        // Substitution: exactly one position may differ.
        return long
            .iter()
            .zip(short.iter())
            .filter(|(x, y)| x != y)
            .count()
            == 1;
    }

    // Insertion or deletion: the shorter string must be the longer one with
    // exactly one character removed.
    let mut i = 0usize;
    let mut j = 0usize;
    let mut skipped = false;
    while i < long.len() && j < short.len() {
        if long[i] == short[j] {
            i += 1;
            j += 1;
        } else if skipped {
            return false;
        } else {
            skipped = true;
            i += 1;
        }
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identical_strings_are_not_distance_one() {
        assert!(!distance_is_one("ghostty", "ghostty"));
    }

    #[test]
    fn single_insertion_is_distance_one() {
        assert!(distance_is_one("ghosttty", "ghostty"));
        assert!(distance_is_one("ghostty", "ghosttty"));
    }

    #[test]
    fn single_substitution_is_distance_one() {
        assert!(distance_is_one("ghostty", "ghustty"));
    }

    #[test]
    fn single_deletion_is_distance_one() {
        assert!(distance_is_one("ghosty", "ghostty"));
    }

    #[test]
    fn two_edits_is_not_distance_one() {
        assert!(!distance_is_one("ghosttty", "ghosty"));
        assert!(!distance_is_one("firefox", "chromium"));
    }

    #[test]
    fn a_transposition_is_two_edits_under_levenshtein() {
        // Documented gap, asserted so a future change to Damerau is deliberate.
        assert!(!distance_is_one("ghostty", "ghotsty"));
    }

    #[test]
    fn parse_skips_comments_and_blanks() {
        let c = Catalogue::parse("# generated\n\nghostty\n  firefox  \n\n");
        assert_eq!(c.len(), 2);
        assert!(c.contains("ghostty"));
        assert!(c.contains("firefox"));
    }

    #[test]
    fn nearest_ignores_the_exact_match() {
        let c = Catalogue::parse("ghostty\n");
        assert_eq!(c.nearest_at_distance_one("ghostty"), None);
        assert_eq!(c.nearest_at_distance_one("ghosttty"), Some("ghostty"));
    }

    #[test]
    fn nearest_is_deterministic_across_equidistant_entries() {
        let c = Catalogue::parse("zzz-tool\naaa-tool\n");
        // Both are one substitution from "bbb-tool"? No — pick a real case:
        let c2 = Catalogue::parse("btop\natop\n");
        assert_eq!(c2.nearest_at_distance_one("ctop"), Some("atop"));
        assert!(c.len() == 2);
    }
}
