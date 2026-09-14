//! Violations, the rules that produce them, and how they reach a human.

use crate::redact;
use std::fmt;

/// Which stage a rule belongs to.
///
/// The distinction is a hard contract, not a hint: the PR check runs with no
/// network, no secrets and no code execution, so `Offline` must be complete on
/// its own. See `rules::Registry` for how the type system enforces it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Stage {
    Offline,
    Resolve,
}

/// A rule from the Validation section of `docs/request-schema.md`.
///
/// `Structure` is not in the document's numbered list. It covers the mirror
/// image of rule 2 — a *missing* required key, or a key of the wrong type —
/// which the schema rejects but the prose does not number. Inventing a
/// "rule 12" would misrepresent the spec, so these report under their own
/// label and always run offline.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Rule {
    Structure,
    /// `schema` is a known version.
    R1,
    /// No unknown keys at any level.
    R2,
    /// `name` matches the pattern and length limit.
    R3,
    /// `name` does not collide with an existing package.
    R4,
    /// `name` is at least edit-distance 2 from any catalogue entry.
    R5,
    /// `upstream` resolves, is a repository root, does not redirect off-host.
    R6,
    /// `license` is a valid SPDX expression.
    R7,
    /// `surface = "binary"` implies a redistributable license.
    R8,
    /// `architectures` is a non-empty subset of the supported set.
    R9,
    /// `source.kind = "vendor"` implies `surface = "recipe"`.
    R10,
    /// `description` and `notes` are within limits and free of control characters.
    R11,
}

impl Rule {
    pub fn label(self) -> &'static str {
        match self {
            Rule::Structure => "structure",
            Rule::R1 => "rule 1",
            Rule::R2 => "rule 2",
            Rule::R3 => "rule 3",
            Rule::R4 => "rule 4",
            Rule::R5 => "rule 5",
            Rule::R6 => "rule 6",
            Rule::R7 => "rule 7",
            Rule::R8 => "rule 8",
            Rule::R9 => "rule 9",
            Rule::R10 => "rule 10",
            Rule::R11 => "rule 11",
        }
    }

    /// Rule 6 is the only rule that needs the network. Everything else is
    /// decidable from the file plus the catalogue.
    pub fn stage(self) -> Stage {
        match self {
            Rule::R6 => Stage::Resolve,
            _ => Stage::Offline,
        }
    }
}

impl fmt::Display for Rule {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.label())
    }
}

/// One failed rule against one field.
///
/// `message` says what is wrong; `remedy` says what to do about it. Both are
/// mandatory. These are read by people filing a first request, for whom
/// "invalid upstream" is a dead end.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Violation {
    pub rule: Rule,
    /// Dotted TOML path, e.g. `package.name`. Submitters read TOML, not JSON,
    /// so pointers are converted before they are ever displayed.
    pub field: String,
    pub message: String,
    pub remedy: String,
}

impl Violation {
    pub fn new(
        rule: Rule,
        field: impl Into<String>,
        message: impl Into<String>,
        remedy: impl Into<String>,
    ) -> Self {
        Self {
            rule,
            field: field.into(),
            message: message.into(),
            remedy: remedy.into(),
        }
    }

    /// One line, always. CI greps this output; a violation that wraps across
    /// lines is a violation that gets missed.
    pub fn render_human(&self, path: &str) -> String {
        format!(
            "{}: {}: {}: {} — {}",
            path,
            self.rule.label(),
            self.field,
            self.message,
            self.remedy
        )
    }

    pub fn render_json(&self, path: &str) -> serde_json::Value {
        serde_json::json!({
            "file": path,
            "rule": self.rule.label(),
            "field": self.field,
            "message": self.message,
            "remedy": self.remedy,
        })
    }
}

/// Convert a JSON Pointer into the dotted path a TOML author would recognise.
///
/// `/package/name` becomes `package.name`; `/package/architectures/0` becomes
/// `package.architectures[0]`. The empty pointer refers to the document root.
///
/// Pointer segments originate in the schema, but an `additionalProperties`
/// error carries the *submitter's* key name, so segments are escaped on the
/// way out like any other untrusted value.
pub fn pointer_to_field(pointer: &str) -> String {
    if pointer.is_empty() {
        return "<document root>".to_string();
    }

    let mut out = String::new();
    for segment in pointer.trim_start_matches('/').split('/') {
        // RFC 6901 unescaping, innermost first.
        let seg = segment.replace("~1", "/").replace("~0", "~");
        if seg.chars().all(|c| c.is_ascii_digit()) && !seg.is_empty() {
            out.push('[');
            out.push_str(&seg);
            out.push(']');
        } else {
            if !out.is_empty() {
                out.push('.');
            }
            out.push_str(&sanitize_segment(&seg));
        }
    }
    out
}

/// A path segment can carry an attacker-chosen key name. Strip anything that
/// could forge structure in the output line.
fn sanitize_segment(segment: &str) -> String {
    let cleaned: String = segment
        .chars()
        .map(|c| {
            if redact::must_escape(c) {
                '\u{fffd}'
            } else {
                c
            }
        })
        .take(64)
        .collect();
    cleaned
}

/// Stable ordering so CI output is diffable between runs.
///
/// Sorted by rule, then field, then message. Two runs over the same file
/// produce byte-identical output; a changed line means a changed outcome.
pub fn sort(violations: &mut [Violation]) {
    violations.sort_by(|a, b| {
        a.rule
            .cmp(&b.rule)
            .then_with(|| a.field.cmp(&b.field))
            .then_with(|| a.message.cmp(&b.message))
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_rule_six_needs_network() {
        for rule in [
            Rule::Structure,
            Rule::R1,
            Rule::R2,
            Rule::R3,
            Rule::R4,
            Rule::R5,
            Rule::R7,
            Rule::R8,
            Rule::R9,
            Rule::R10,
            Rule::R11,
        ] {
            assert_eq!(rule.stage(), Stage::Offline, "{rule} must be offline");
        }
        assert_eq!(Rule::R6.stage(), Stage::Resolve);
    }

    #[test]
    fn pointer_becomes_dotted_toml_path() {
        assert_eq!(pointer_to_field("/package/name"), "package.name");
        assert_eq!(pointer_to_field(""), "<document root>");
        assert_eq!(
            pointer_to_field("/package/architectures/0"),
            "package.architectures[0]"
        );
    }

    #[test]
    fn pointer_segments_cannot_forge_output_structure() {
        let field = pointer_to_field("/package/ev\nil");
        assert!(!field.contains('\n'));
    }

    #[test]
    fn rendered_violation_is_a_single_line() {
        let v = Violation::new(Rule::R3, "package.name", "msg", "fix it");
        let line = v.render_human("requests/x.toml");
        assert_eq!(line.lines().count(), 1);
        assert!(line.starts_with("requests/x.toml: rule 3: package.name:"));
    }

    #[test]
    fn sort_is_stable_by_rule_then_field() {
        let mut vs = vec![
            Violation::new(Rule::R7, "package.license", "b", ""),
            Violation::new(Rule::R2, "package.zzz", "a", ""),
            Violation::new(Rule::R2, "package.aaa", "a", ""),
        ];
        sort(&mut vs);
        assert_eq!(vs[0].field, "package.aaa");
        assert_eq!(vs[1].field, "package.zzz");
        assert_eq!(vs[2].rule, Rule::R7);
    }
}
