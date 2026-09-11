//! Rules 7 and 8 — what the license says we may do.

use super::{OfflineCx, OfflineRule, Request};
use crate::diagnostic::{Rule, Violation};
use crate::redact;

/// Rule 7: `license` is a valid SPDX identifier or expression.
///
/// Validity only. Whether the declared license matches what is actually in the
/// repository is the factory's job, and the mismatch between claim and
/// detection is itself a signal worth keeping.
pub struct SpdxValid;

impl OfflineRule for SpdxValid {
    fn check(&self, req: &Request, _cx: &OfflineCx) -> Vec<Violation> {
        let Some(text) = req.license() else {
            return Vec::new();
        };

        match spdx::Expression::parse(text) {
            Ok(_) => Vec::new(),
            Err(e) => vec![Violation::new(
                Rule::R7,
                "package.license",
                format!(
                    "{} is not a valid SPDX expression: {}",
                    redact::show(text),
                    redact::show(&e.reason.to_string())
                ),
                "use the SPDX identifier, not the project's prose name — \"MIT\" not \
                 \"MIT License\", \"GPL-3.0-or-later\" not \"GPLv3+\". Combine with OR \
                 and AND (\"MIT OR Apache-2.0\"). For a license with no SPDX identifier, \
                 use a LicenseRef- name such as \"LicenseRef-Vendor-ToS\". \
                 Full list: https://spdx.org/licenses/",
            )],
        }
    }
}

/// Rule 8: if `surface = "binary"`, `license` is on the redistributable
/// allowlist.
///
/// Rejected with the reason rather than silently downgraded to `recipe`. The
/// requester declared which surface they wanted and should learn that they are
/// not getting it, rather than discovering later that the package installs
/// differently than they expected.
pub struct Redistributable;

impl OfflineRule for Redistributable {
    fn check(&self, req: &Request, cx: &OfflineCx) -> Vec<Violation> {
        let (Some(text), Some(surface)) = (req.license(), req.surface()) else {
            return Vec::new();
        };

        if surface != "binary" {
            return Vec::new();
        }

        // An unparseable expression is rule 7's finding; this rule declines
        // rather than adding a second diagnostic for one mistake.
        let Ok(expr) = spdx::Expression::parse(text) else {
            return Vec::new();
        };

        // `evaluate` walks the expression's boolean structure, so
        // "MIT OR LicenseRef-Foo" is satisfiable through the MIT branch while
        // "MIT AND LicenseRef-Foo" is not. Getting this wrong in either
        // direction is a legal problem, not a UX one.
        let satisfiable = expr.evaluate(|req| match &req.license {
            spdx::LicenseItem::Spdx { id, .. } => cx.allowlist.contains(id.name),
            // A LicenseRef- names terms we have not read. Unknown terms are
            // never grounds to host and sign binaries ourselves.
            spdx::LicenseItem::Other { .. } => false,
        });

        if satisfiable {
            return Vec::new();
        }

        vec![Violation::new(
            Rule::R8,
            "package.license",
            format!(
                "surface = \"binary\" needs a license that lets us redistribute builds, \
                 and {} is not on the redistributable allowlist",
                redact::show(text)
            ),
            "set `surface = \"recipe\"` — we cannot legally host the bits, so the recipe \
             fetches from the vendor with a pinned checksum and builds on the user's \
             machine. If you believe this license does permit redistribution, say so in \
             requester.notes; the allowlist is reviewed and can be extended",
        )]
    }
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

    fn request(license: &str, surface: &str) -> serde_json::Value {
        serde_json::json!({ "package": { "license": license, "surface": surface } })
    }

    #[test]
    fn a_plain_identifier_is_valid() {
        let v = request("MIT", "binary");
        assert!(SpdxValid.check(&Request::new(&v), &cx()).is_empty());
    }

    #[test]
    fn an_expression_is_valid() {
        let v = request("MIT OR Apache-2.0", "binary");
        assert!(SpdxValid.check(&Request::new(&v), &cx()).is_empty());
    }

    #[test]
    fn a_prose_license_name_is_rejected_with_the_spdx_form() {
        let v = request("GPLv3+", "recipe");
        let out = SpdxValid.check(&Request::new(&v), &cx());
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].rule, Rule::R7);
        assert!(out[0].remedy.contains("GPL-3.0-or-later"));
    }

    #[test]
    fn a_license_ref_is_a_valid_expression() {
        let v = request("LicenseRef-Google-Chrome-ToS", "recipe");
        assert!(SpdxValid.check(&Request::new(&v), &cx()).is_empty());
    }

    #[test]
    fn binary_surface_with_a_redistributable_license_passes() {
        let v = request("MIT", "binary");
        assert!(Redistributable.check(&Request::new(&v), &cx()).is_empty());
    }

    #[test]
    fn binary_surface_with_a_license_ref_is_rejected_not_downgraded() {
        let v = request("LicenseRef-Google-Chrome-ToS", "binary");
        let out = Redistributable.check(&Request::new(&v), &cx());
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].rule, Rule::R8);
        assert!(out[0].remedy.contains("surface = \"recipe\""));
    }

    #[test]
    fn recipe_surface_accepts_a_non_redistributable_license() {
        let v = request("LicenseRef-Google-Chrome-ToS", "recipe");
        assert!(Redistributable.check(&Request::new(&v), &cx()).is_empty());
    }

    #[test]
    fn an_or_expression_is_satisfiable_through_its_permitted_branch() {
        let v = request("MIT OR LicenseRef-Proprietary", "binary");
        assert!(Redistributable.check(&Request::new(&v), &cx()).is_empty());
    }

    #[test]
    fn an_and_expression_requires_every_branch() {
        let v = request("MIT AND LicenseRef-Proprietary", "binary");
        let out = Redistributable.check(&Request::new(&v), &cx());
        assert_eq!(out.len(), 1, "AND with an unreviewed term must not pass");
        assert_eq!(out[0].rule, Rule::R8);
    }

    #[test]
    fn an_unparseable_license_reports_only_rule_seven() {
        let v = request("GPLv3+", "binary");
        assert_eq!(SpdxValid.check(&Request::new(&v), &cx()).len(), 1);
        assert!(Redistributable.check(&Request::new(&v), &cx()).is_empty());
    }
}
