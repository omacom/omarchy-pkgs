//! Rendering untrusted request values into human-readable messages.
//!
//! A request file is the only artifact in the system written by someone
//! outside the project. Every value in it is hostile until proven otherwise,
//! and validator output is read by humans, pasted into PR comments, and
//! shipped to CI logs. A raw value reaching any of those is a defect.
//!
//! Nothing in this crate builds a shell command, so there is no interpolation
//! site to audit. What remains is display safety: a value must not be able to
//! forge log lines, hide itself with terminal escapes, reorder the text around
//! it, or blow up a log with a megabyte of padding.

/// Longest run of a request value that will ever appear in a message.
const MAX_SHOWN: usize = 80;

/// Render an untrusted value for display inside a diagnostic.
///
/// The result is always single-line, always delimited, and contains only
/// printable characters. Escaping is `\u{...}` so the reader can see exactly
/// which codepoint was present rather than losing it to the terminal.
pub fn show(value: &str) -> String {
    let mut out = String::with_capacity(value.len() + 2);
    out.push('\'');

    let mut chars = value.chars();

    for ch in chars.by_ref().take(MAX_SHOWN) {
        match ch {
            // The delimiter itself, so a value cannot close its own quoting
            // and append text that reads as validator output.
            '\'' => out.push_str("\\'"),
            '\\' => out.push_str("\\\\"),
            _ if must_escape(ch) => {
                out.push_str(&format!("\\u{{{:04x}}}", ch as u32));
            }
            _ => out.push(ch),
        }
    }

    out.push('\'');
    if chars.next().is_some() {
        out.push_str(" (truncated)");
    }
    out
}

/// Characters that never appear literally in output.
///
/// Deliberately wider than "control characters": bidirectional overrides are
/// printable by Unicode's definition but reorder surrounding text visually,
/// which is the Trojan Source trick. A name that renders as one thing and
/// validates as another is precisely the confusion this validator exists to
/// prevent.
pub fn must_escape(ch: char) -> bool {
    is_control(ch) || is_bidi(ch) || is_invisible(ch)
}

/// C0 controls, DEL, and C1 controls.
pub fn is_control(ch: char) -> bool {
    let c = ch as u32;
    c < 0x20 || c == 0x7f || (0x80..=0x9f).contains(&c)
}

/// Bidirectional overrides and isolates (Trojan Source).
pub fn is_bidi(ch: char) -> bool {
    matches!(ch as u32,
        0x200e | 0x200f | 0x202a..=0x202e | 0x2066..=0x2069)
}

/// Zero-width and other invisible formatting characters that can hide content
/// or make two distinct names render identically.
pub fn is_invisible(ch: char) -> bool {
    matches!(ch as u32, 0x00ad | 0x200b..=0x200d | 0x2060 | 0xfeff)
}

/// Describe the first disallowed character in `value`, if any.
///
/// Returns the zero-based character offset and a bare `U+XXXX` label. Used by
/// rule 11, which needs to name the offender rather than just reject the field.
pub fn first_disallowed(value: &str) -> Option<(usize, String)> {
    value
        .chars()
        .enumerate()
        .find_map(|(i, ch)| must_escape(ch).then(|| (i, format!("U+{:04X}", ch as u32))))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plain_text_is_only_quoted() {
        assert_eq!(show("ghostty"), "'ghostty'");
    }

    #[test]
    fn control_characters_are_escaped_not_emitted() {
        let out = show("evil\u{0}name");
        assert_eq!(out, "'evil\\u{0000}name'");
        assert!(!out.contains('\u{0}'));
    }

    #[test]
    fn newline_cannot_forge_a_second_output_line() {
        let out = show("a\nrule 1: package.name: looks legitimate");
        assert!(!out.contains('\n'), "value forged a line break: {out}");
        assert!(out.contains("\\u{000a}"));
    }

    #[test]
    fn quote_cannot_escape_its_own_delimiter() {
        let out = show("a' and then");
        assert!(out.starts_with('\'') && out.ends_with('\''));
        assert!(out.contains("\\'"));
    }

    #[test]
    fn bidi_override_is_escaped() {
        let out = show("ghost\u{202e}ytt");
        assert!(out.contains("\\u{202e}"));
    }

    #[test]
    fn zero_width_space_is_escaped() {
        assert!(show("ghost\u{200b}ty").contains("\\u{200b}"));
    }

    #[test]
    fn long_values_are_capped() {
        let out = show(&"a".repeat(5000));
        assert!(out.len() < 200, "unbounded value reached output");
        assert!(out.ends_with("(truncated)"));
    }

    #[test]
    fn first_disallowed_reports_offset_and_codepoint() {
        assert_eq!(first_disallowed("ok"), None);
        let (i, label) = first_disallowed("ab\u{7}c").unwrap();
        assert_eq!((i, label.as_str()), (2, "U+0007"));
    }
}
