//! The rules from the Validation section of `docs/request-schema.md`.
//!
//! Rules 1, 2, 3, 9, 10 and part of 11 are decided by the schema
//! (see `crate::schema`). This module holds the rest: the ones that need a
//! catalogue, a license database, or the network.
//!
//! # The offline guarantee
//!
//! `--offline` must be complete on its own, because the PR stage runs with no
//! network, no secrets and no code execution. That is enforced here by types
//! rather than by convention:
//!
//! ```text
//! trait OfflineRule { fn check(&self, req: &Request, cx: &OfflineCx) -> ...; }
//! trait ResolveRule { fn check(&self, req: &Request, net: &dyn Http) -> ...; }
//! ```
//!
//! An `OfflineRule` is never handed anything capable of I/O, so it cannot
//! perform any — the compiler rejects the attempt rather than a reviewer
//! having to notice it.

pub mod license;
pub mod naming;
pub mod text;

use crate::catalogue::Catalogue;
use crate::diagnostic::Violation;
use crate::license::Allowlist;
use crate::net::Http;

/// A typed read-only view over a parsed request.
///
/// Every accessor is fallible. Native rules run even when the schema found
/// problems, so that one pass reports everything wrong with a file rather than
/// revealing faults one round-trip at a time. A rule whose input is missing or
/// mistyped simply declines to fire; the schema has already reported it.
pub struct Request<'a> {
    root: &'a serde_json::Value,
}

impl<'a> Request<'a> {
    pub fn new(root: &'a serde_json::Value) -> Self {
        Self { root }
    }

    fn str_at(&self, table: &str, key: &str) -> Option<&'a str> {
        self.root.get(table)?.get(key)?.as_str()
    }

    pub fn name(&self) -> Option<&'a str> {
        self.str_at("package", "name")
    }
    pub fn description(&self) -> Option<&'a str> {
        self.str_at("package", "description")
    }
    pub fn upstream(&self) -> Option<&'a str> {
        self.str_at("package", "upstream")
    }
    pub fn license(&self) -> Option<&'a str> {
        self.str_at("package", "license")
    }
    pub fn surface(&self) -> Option<&'a str> {
        self.str_at("package", "surface")
    }
    pub fn source_kind(&self) -> Option<&'a str> {
        self.str_at("source", "kind")
    }
    pub fn notes(&self) -> Option<&'a str> {
        self.str_at("requester", "notes")
    }
}

/// Everything an offline rule is allowed to consult.
///
/// Note what is absent: no HTTP client, no filesystem handle, no clock, no
/// environment. An offline rule is a pure function of the request and this.
pub struct OfflineCx {
    /// `None` only when the operator passed `--no-catalogue`. Rules 4 and 5
    /// decline rather than pass when it is missing.
    pub catalogue: Option<Catalogue>,
    pub allowlist: Allowlist,
}

pub trait OfflineRule {
    fn check(&self, req: &Request, cx: &OfflineCx) -> Vec<Violation>;
}

pub trait ResolveRule {
    fn check(&self, req: &Request, net: &dyn Http) -> Vec<Violation>;
}

/// The offline rule set, in the order the spec lists them.
pub fn offline_rules() -> Vec<Box<dyn OfflineRule>> {
    vec![
        Box::new(naming::Collision),        // rule 4
        Box::new(naming::Typosquat),        // rule 5
        Box::new(license::SpdxValid),       // rule 7
        Box::new(license::Redistributable), // rule 8
        Box::new(text::ControlCharacters),  // rule 11
    ]
}

/// The network rule set. Only ever constructed on the `--resolve` path.
pub fn resolve_rules() -> Vec<Box<dyn ResolveRule>> {
    vec![Box::new(crate::net::UpstreamResolves)] // rule 6
}
