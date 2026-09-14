//! Getting bytes off disk and into a validated JSON value.
//!
//! Everything here runs before any rule does, on input nobody has checked.
//! The ordering is deliberate: bound the size, then prove it is UTF-8, then
//! parse. Each step assumes the previous one succeeded and nothing assumes
//! the file is well-formed.

use crate::diagnostic::{Rule, Violation};
use std::path::Path;

/// A request is a handful of scalar fields. Anything larger is not a request,
/// and refusing it early keeps a hostile file from driving allocation in the
/// TOML parser.
pub const MAX_FILE_BYTES: u64 = 64 * 1024;

#[derive(Debug)]
pub enum LoadError {
    /// The operator's problem: unreadable path, permissions, missing file.
    Unreadable(String),
    /// The submitter's problem: the file is not a valid request document.
    Invalid(Violation),
}

/// Read and parse a request file into a JSON value the schema can validate.
pub fn load(path: &Path) -> Result<serde_json::Value, LoadError> {
    let meta = std::fs::metadata(path)
        .map_err(|e| LoadError::Unreadable(format!("cannot stat {}: {e}", path.display())))?;

    if !meta.is_file() {
        return Err(LoadError::Unreadable(format!(
            "{} is not a regular file",
            path.display()
        )));
    }

    // Checked before reading, so an oversized file is never held in memory.
    if meta.len() > MAX_FILE_BYTES {
        return Err(LoadError::Invalid(Violation::new(
            Rule::Structure,
            "<file>",
            format!(
                "file is {} bytes, over the {} byte limit for a request",
                meta.len(),
                MAX_FILE_BYTES
            ),
            "a request holds only the fields in docs/request-schema.md — \
             build steps, patches and checksums belong to the factory, not the request",
        )));
    }

    let bytes = std::fs::read(path)
        .map_err(|e| LoadError::Unreadable(format!("cannot read {}: {e}", path.display())))?;

    parse_bytes(&bytes)
}

/// Split out from `load` so tests can drive it without touching the filesystem.
pub fn parse_bytes(bytes: &[u8]) -> Result<serde_json::Value, LoadError> {
    if bytes.starts_with(&[0xEF, 0xBB, 0xBF]) {
        return Err(LoadError::Invalid(Violation::new(
            Rule::Structure,
            "<file>",
            "file begins with a UTF-8 byte order mark",
            "save the file as UTF-8 without a BOM; the leading bytes make the \
             first key unparseable",
        )));
    }

    let text = std::str::from_utf8(bytes).map_err(|e| {
        LoadError::Invalid(Violation::new(
            Rule::Structure,
            "<file>",
            format!("file is not valid UTF-8 (byte offset {})", e.valid_up_to()),
            "save the file as UTF-8; request files are text and must decode cleanly",
        ))
    })?;

    // `toml::from_str`, not `text.parse()`. In toml 1.x the `FromStr` impl for
    // `Value` parses a single bare value rather than a document, so `.parse()`
    // rejects every well-formed request with "unexpected content".
    let value: toml::Value = toml::from_str(text).map_err(|e: toml::de::Error| {
        // The parser's own message can quote file content, so it goes through
        // the same escaping as any other untrusted value.
        LoadError::Invalid(Violation::new(
            Rule::Structure,
            "<file>",
            format!(
                "file is not valid TOML: {}",
                crate::redact::show(e.message())
            ),
            "check for an unclosed string, a duplicate key, or a missing '=' — \
             see requests/ghostty.toml for a minimal valid request",
        ))
    })?;

    Ok(toml_to_json(value))
}

/// Convert TOML into JSON so one schema describes the document.
///
/// TOML has two types JSON does not: datetimes and integers distinct from
/// floats. Datetimes become strings rather than an error, and that choice
/// matters. `[verification]` is written by the pipeline and contains a
/// `verified_at` datetime; a submitter who copies that block into their request
/// must be told "unknown key `verification`" by rule 2, not "cannot represent
/// a datetime" by the parser. The useful diagnostic is the one about the rule
/// they actually broke.
fn toml_to_json(value: toml::Value) -> serde_json::Value {
    use serde_json::Value as J;
    match value {
        toml::Value::String(s) => J::String(s),
        toml::Value::Integer(i) => J::Number(i.into()),
        toml::Value::Float(f) => serde_json::Number::from_f64(f)
            .map(J::Number)
            // NaN and infinity have no JSON representation. They cannot satisfy
            // any field in this schema, so a null lands on a type error.
            .unwrap_or(J::Null),
        toml::Value::Boolean(b) => J::Bool(b),
        toml::Value::Datetime(dt) => J::String(dt.to_string()),
        toml::Value::Array(a) => J::Array(a.into_iter().map(toml_to_json).collect()),
        toml::Value::Table(t) => {
            J::Object(t.into_iter().map(|(k, v)| (k, toml_to_json(v))).collect())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn invalid(bytes: &[u8]) -> Violation {
        match parse_bytes(bytes) {
            Err(LoadError::Invalid(v)) => v,
            other => panic!("expected an Invalid result, got {other:?}"),
        }
    }

    #[test]
    fn parses_a_minimal_document() {
        let v = parse_bytes(b"schema = 1\n[package]\nname = \"x\"\n").unwrap();
        assert_eq!(v["schema"], serde_json::json!(1));
        assert_eq!(v["package"]["name"], serde_json::json!("x"));
    }

    #[test]
    fn rejects_non_utf8() {
        let v = invalid(&[0x73, 0x3d, 0xff, 0xfe]);
        assert!(v.message.contains("not valid UTF-8"), "{}", v.message);
    }

    #[test]
    fn rejects_a_byte_order_mark_with_an_actionable_message() {
        let mut bytes = vec![0xEF, 0xBB, 0xBF];
        bytes.extend_from_slice(b"schema = 1\n");
        let v = invalid(&bytes);
        assert!(v.message.contains("byte order mark"));
        assert!(v.remedy.contains("without a BOM"));
    }

    #[test]
    fn rejects_duplicate_keys() {
        let v = invalid(b"schema = 1\nschema = 2\n");
        assert!(v.message.contains("not valid TOML"), "{}", v.message);
    }

    #[test]
    fn parse_error_text_cannot_forge_an_output_line() {
        // A parse error can quote the offending content back at us.
        let v = invalid(b"key = \"unterminated\nrule 1: forged\n");
        assert!(!v.message.contains('\n'), "parse error leaked a newline");
    }

    #[test]
    fn a_datetime_survives_parsing_so_rule_two_can_report_it() {
        // The point: a copied [verification] block must reach the schema and
        // be reported as an unknown key, not die in the parser.
        let v = parse_bytes(b"schema = 1\n[verification]\nverified_at = 2026-09-04T10:14:00Z\n")
            .unwrap();
        assert!(v["verification"]["verified_at"].is_string());
    }

    #[test]
    fn nested_tables_and_arrays_convert() {
        let v = parse_bytes(b"[package]\narchitectures = [\"x86_64\"]\n").unwrap();
        assert_eq!(
            v["package"]["architectures"][0],
            serde_json::json!("x86_64")
        );
    }
}
