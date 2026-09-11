//! Rule 11 — free-text fields carry only text.
//!
//! Length limits for these fields live in the schema. What the schema cannot
//! express is the rest of rule 11: `description`'s pattern excludes newlines
//! and `notes` has no pattern at all, so neither field is protected against
//! the other control characters, bidirectional overrides, or zero-width
//! characters.
//!
//! These fields end up in the package catalog, in PR comments and in a
//! maintainer's terminal. A value that renders as one thing and reads as
//! another defeats the human review the whole design depends on.

use super::{OfflineCx, OfflineRule, Request};
use crate::diagnostic::{Rule, Violation};
use crate::redact;

pub struct ControlCharacters;

impl OfflineRule for ControlCharacters {
    fn check(&self, req: &Request, _cx: &OfflineCx) -> Vec<Violation> {
        [
            ("package.description", req.description()),
            ("requester.notes", req.notes()),
        ]
        .into_iter()
        .filter_map(|(field, value)| value.map(|v| (field, v)))
        .filter_map(|(field, value)| {
            let (offset, codepoint) = redact::first_disallowed(value)?;
            Some(Violation::new(
                Rule::R11,
                field,
                format!(
                    "contains the disallowed character {codepoint} at position {offset}, \
                     shown here as {}",
                    redact::show(value)
                ),
                describe(&codepoint),
            ))
        })
        .collect()
    }
}

/// Say what the character is, since it is by definition one the submitter
/// cannot see in their editor.
fn describe(codepoint: &str) -> String {
    let kind = match codepoint {
        "U+0000" => "a null byte",
        "U+0009" => "a tab",
        "U+000A" => "a line feed",
        "U+000D" => "a carriage return",
        "U+001B" => "an escape character, which terminals interpret as a control sequence",
        "U+200B" | "U+200C" | "U+200D" | "U+2060" | "U+FEFF" => "an invisible zero-width character",
        "U+00AD" => "a soft hyphen, which is invisible in most editors",
        "U+200E" | "U+200F" | "U+202A" | "U+202B" | "U+202C" | "U+202D" | "U+202E" | "U+2066"
        | "U+2067" | "U+2068" | "U+2069" => {
            "a bidirectional override, which makes text display in a different order \
             than it is stored"
        }
        _ => "a control character",
    };
    format!(
        "remove it. This is {kind}. These fields are plain text shown to maintainers \
         and in the package catalog, so they must read exactly as they are stored. \
         If it arrived by pasting from a document, retype the line by hand"
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::license::Allowlist;

    fn cx() -> OfflineCx {
        OfflineCx {
            catalogue: None,
            allowlist: Allowlist::embedded(),
        }
    }

    fn request(description: &str, notes: &str) -> serde_json::Value {
        serde_json::json!({
            "package": { "description": description },
            "requester": { "notes": notes }
        })
    }

    #[test]
    fn ordinary_text_passes() {
        let v = request("GPU-accelerated terminal emulator", "Widely used.");
        assert!(ControlCharacters.check(&Request::new(&v), &cx()).is_empty());
    }

    #[test]
    fn non_ascii_text_is_not_a_control_character() {
        let v = request("Éditeur de texte — with em dash", "naïve café 日本語");
        assert!(ControlCharacters.check(&Request::new(&v), &cx()).is_empty());
    }

    #[test]
    fn an_escape_sequence_in_description_is_caught_and_explained() {
        let v = request("terminal\u{1b}[31m emulator", "");
        let out = ControlCharacters.check(&Request::new(&v), &cx());
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].rule, Rule::R11);
        assert_eq!(out[0].field, "package.description");
        assert!(out[0].message.contains("U+001B"));
        assert!(out[0].remedy.contains("control sequence"));
        assert!(
            !out[0].message.contains('\u{1b}'),
            "raw escape reached output"
        );
    }

    #[test]
    fn a_null_byte_is_caught() {
        let v = request("term\u{0}inal", "");
        let out = ControlCharacters.check(&Request::new(&v), &cx());
        assert!(out[0].message.contains("U+0000"));
        assert!(out[0].remedy.contains("null byte"));
    }

    #[test]
    fn notes_are_checked_too_since_the_schema_has_no_pattern_for_them() {
        let v = request("fine", "looks fine\u{202e}but is not");
        let out = ControlCharacters.check(&Request::new(&v), &cx());
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].field, "requester.notes");
        assert!(out[0].remedy.contains("bidirectional override"));
    }

    #[test]
    fn a_zero_width_space_is_caught() {
        let v = request("gho\u{200b}stty", "");
        let out = ControlCharacters.check(&Request::new(&v), &cx());
        assert!(out[0].remedy.contains("zero-width"));
    }

    #[test]
    fn both_fields_report_independently() {
        let v = request("a\u{0}b", "c\u{7}d");
        let out = ControlCharacters.check(&Request::new(&v), &cx());
        assert_eq!(out.len(), 2);
    }

    #[test]
    fn the_reported_offset_is_in_characters_not_bytes() {
        // "é" is two bytes; the offset must still read as position 1.
        let v = request("é\u{0}x", "");
        let out = ControlCharacters.check(&Request::new(&v), &cx());
        assert!(out[0].message.contains("position 1"), "{}", out[0].message);
    }
}
