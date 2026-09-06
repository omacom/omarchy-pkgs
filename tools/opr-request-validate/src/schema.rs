//! Structural validation against `schema/request.schema.json`.
//!
//! The structural checks are not hand-rolled. The schema is the single
//! statement of what a request may contain, and duplicating it in Rust would
//! create two definitions that drift. What *is* hand-rolled is the translation
//! from a schema error into something a first-time submitter can act on:
//! `"additionalProperties" is not allowed` names no rule and suggests no fix.

use crate::diagnostic::{pointer_to_field, Rule, Violation};
use crate::redact;

/// The schema travels inside the binary.
///
/// A PR gate runs in a locked-down environment where a relative path is one
/// more thing that can be wrong. `--schema` overrides this for testing only.
pub const EMBEDDED_SCHEMA: &str = include_str!("../../../schema/request.schema.json");

pub struct Schema {
    validator: jsonschema::Validator,
}

#[derive(Debug)]
pub enum SchemaError {
    Parse(String),
    Compile(String),
    /// The schema itself failed its fail-closed self-check.
    Unsound(String),
}

impl std::fmt::Display for SchemaError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SchemaError::Parse(m) => write!(f, "schema is not valid JSON: {m}"),
            SchemaError::Compile(m) => write!(f, "schema does not compile: {m}"),
            SchemaError::Unsound(m) => write!(f, "schema is unsound: {m}"),
        }
    }
}

impl Schema {
    pub fn embedded() -> Result<Self, SchemaError> {
        Self::from_json(EMBEDDED_SCHEMA)
    }

    pub fn from_json(text: &str) -> Result<Self, SchemaError> {
        let doc: serde_json::Value =
            serde_json::from_str(text).map_err(|e| SchemaError::Parse(e.to_string()))?;

        assert_fails_closed(&doc)?;

        let validator =
            jsonschema::validator_for(&doc).map_err(|e| SchemaError::Compile(e.to_string()))?;

        Ok(Self { validator })
    }

    /// Every structural violation in the document, translated.
    pub fn check(&self, instance: &serde_json::Value) -> Vec<Violation> {
        self.validator
            .iter_errors(instance)
            .map(|e| translate(&e))
            .collect()
    }
}

/// Refuse to run against a schema that does not fail closed.
///
/// "Unknown keys are rejected, not ignored" is the invariant that stops the
/// request format growing by smuggling. It lives in one JSON keyword per
/// object, and a future edit could drop one without any test noticing —
/// the request would simply start accepting a field nobody designed.
///
/// So the binary refuses to start rather than validate against a schema that
/// has quietly stopped enforcing it.
fn assert_fails_closed(schema: &serde_json::Value) -> Result<(), SchemaError> {
    fn walk(node: &serde_json::Value, path: &str, out: &mut Vec<String>) {
        let Some(obj) = node.as_object() else { return };

        // Only object schemas that declare properties need the guard.
        if obj.contains_key("properties") {
            let closed = matches!(
                obj.get("additionalProperties"),
                Some(serde_json::Value::Bool(false))
            );
            // Subschemas under if/then/else constrain an already-closed object;
            // requiring the keyword there would reject a correct schema.
            let conditional =
                path.contains("/if") || path.contains("/then") || path.contains("/else");
            if !closed && !conditional {
                out.push(if path.is_empty() {
                    "<root>".into()
                } else {
                    path.into()
                });
            }
        }

        for (key, child) in obj {
            match child {
                serde_json::Value::Object(_) => walk(child, &format!("{path}/{key}"), out),
                serde_json::Value::Array(items) => {
                    for (i, item) in items.iter().enumerate() {
                        walk(item, &format!("{path}/{key}/{i}"), out);
                    }
                }
                _ => {}
            }
        }
    }

    let mut open = Vec::new();
    walk(schema, "", &mut open);

    if open.is_empty() {
        Ok(())
    } else {
        Err(SchemaError::Unsound(format!(
            "these object schemas accept unknown keys (missing \
             \"additionalProperties\": false): {}. Validation must fail closed \
             on unknown keys — see docs/request-schema.md.",
            open.join(", ")
        )))
    }
}

/// Turn one schema error into a numbered rule and an actionable sentence.
fn translate(error: &jsonschema::ValidationError) -> Violation {
    use jsonschema::error::ValidationErrorKind as K;

    let pointer = error.instance_path().to_string();
    let field = pointer_to_field(&pointer);
    let schema_path = error.schema_path().to_string();

    match error.kind() {
        // Rule 2. The one that matters most: the format cannot grow by smuggling.
        K::AdditionalProperties { unexpected } => {
            let names: Vec<String> = unexpected.iter().map(|u| redact::show(u)).collect();
            let (subject, verb) = if names.len() == 1 {
                ("key", "is")
            } else {
                ("keys", "are")
            };
            Violation::new(
                Rule::R2,
                field,
                format!(
                    "unknown {subject} {} {verb} not part of a request",
                    names.join(", ")
                ),
                match unexpected.iter().any(|u| u == "verification") {
                    true => "the [verification] block is written by the pipeline, never by \
                             the requester — remove it"
                        .to_string(),
                    false => "remove it; requests carry no build steps, patches, dependencies, \
                              checksums or flags — the factory derives all of those. \
                              docs/request-schema.md lists every accepted key"
                        .to_string(),
                },
            )
        }

        K::Required { property } => Violation::new(
            Rule::Structure,
            if field == "<document root>" {
                "<document root>".to_string()
            } else {
                field
            },
            format!(
                "required key {} is missing",
                redact::show(&property.to_string())
            ),
            "add it; every required key is listed in docs/request-schema.md",
        ),

        K::Constant { expected_value } if pointer == "/schema" => Violation::new(
            Rule::R1,
            field,
            format!("unknown schema version, expected {expected_value}"),
            "set `schema = 1`; a request with an unrecognised version is rejected \
             rather than parsed on a best-effort basis",
        ),

        // Rule 10, expressed in the schema as an allOf/if/then.
        K::Constant { .. } if schema_path.contains("allOf") => Violation::new(
            Rule::R10,
            field,
            "source.kind = \"vendor\" requires surface = \"recipe\"",
            "set `surface = \"recipe\"`; a vendor-hosted download cannot be rebuilt, \
             signed and republished by us, so it ships as a recipe that fetches on \
             the user's machine with a pinned checksum",
        ),

        K::Pattern { .. } if pointer == "/package/name" => Violation::new(
            Rule::R3,
            field,
            "name contains characters that are not valid in a pacman package name",
            "use lowercase letters, digits, and any of @ . _ + - , starting with a \
             letter or digit",
        ),

        K::MaxLength { limit } if pointer == "/package/name" => Violation::new(
            Rule::R3,
            field,
            format!("name is longer than the {limit} character limit"),
            "shorten it to the upstream project's own name",
        ),

        K::Pattern { .. } if pointer == "/package/description" => Violation::new(
            Rule::R11,
            field,
            "description spans more than one line",
            "keep it to a single line; it appears in the package catalog",
        ),

        K::MaxLength { limit } if pointer == "/package/description" => Violation::new(
            Rule::R11,
            field,
            format!("description is longer than the {limit} character limit"),
            "one line for the catalog — put the longer explanation in requester.notes",
        ),

        K::MinLength { .. } if pointer == "/package/description" => Violation::new(
            Rule::R11,
            field,
            "description is empty",
            "write one line describing what the package is",
        ),

        K::MaxLength { limit } if pointer == "/requester/notes" => Violation::new(
            Rule::R11,
            field,
            format!("notes are longer than the {limit} character limit"),
            "trim to what the reviewing maintainer needs to decide",
        ),

        K::Pattern { .. } if pointer == "/package/upstream" => Violation::new(
            Rule::Structure,
            field,
            "upstream is not an https:// URL",
            "use the https:// URL of the repository of record — http and git+ssh \
             cannot be verified",
        ),

        K::MinItems { .. } | K::UniqueItems if pointer == "/package/architectures" => {
            Violation::new(
                Rule::R9,
                field,
                "architectures must be a non-empty list with no repeats",
                "use [\"x86_64\"], [\"aarch64\"], or both",
            )
        }

        K::Enum { .. } if pointer.starts_with("/package/architectures") => Violation::new(
            Rule::R9,
            field,
            "unsupported architecture",
            "only \"x86_64\" and \"aarch64\" are built",
        ),

        K::Enum { options } => Violation::new(
            Rule::Structure,
            field,
            format!("value is not one of the accepted options: {options}"),
            "see docs/request-schema.md for the accepted values of this field",
        ),

        K::Type { .. } => Violation::new(
            Rule::Structure,
            field,
            "value has the wrong type",
            "check the field's type in docs/request-schema.md — strings need quotes, \
             `schema` is a bare integer, and architectures is a list",
        ),

        // Anything the schema can produce that is not mapped above still
        // reports, with the raw text escaped. Silence would be worse.
        _ => Violation::new(
            Rule::Structure,
            field,
            format!(
                "does not satisfy the schema: {}",
                redact::show(&error.to_string())
            ),
            "see docs/request-schema.md for this field's requirements",
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn check(toml_src: &str) -> Vec<Violation> {
        let value = crate::loader::parse_bytes(toml_src.as_bytes()).unwrap();
        Schema::embedded().unwrap().check(&value)
    }

    #[test]
    fn embedded_schema_compiles_and_fails_closed() {
        Schema::embedded().expect("embedded schema must be sound");
    }

    #[test]
    fn a_schema_that_accepts_unknown_keys_is_refused() {
        // The guard that stops the fail-closed invariant being edited away.
        let open = r#"{
            "type": "object",
            "properties": { "name": { "type": "string" } }
        }"#;
        match Schema::from_json(open) {
            Err(SchemaError::Unsound(m)) => assert!(m.contains("additionalProperties")),
            Err(other) => panic!("expected Unsound, got {other}"),
            Ok(_) => panic!("a schema that accepts unknown keys must be refused"),
        }
    }

    #[test]
    fn valid_example_requests_pass_structurally() {
        for path in [
            "../../requests/ghostty.toml",
            "../../requests/google-chrome.toml",
        ] {
            let text = std::fs::read_to_string(path).unwrap();
            let v = check(&text);
            assert!(v.is_empty(), "{path} produced {v:#?}");
        }
    }
}
