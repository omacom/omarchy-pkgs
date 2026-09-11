//! Rules 4 and 5 — the name is the thing a user types when they mean
//! something else.

use super::{OfflineCx, OfflineRule, Request};
use crate::diagnostic::{Rule, Violation};
use crate::redact;

/// Rule 4: `name` does not collide with an existing OPR package or with Arch
/// `core`/`extra`.
pub struct Collision;

impl OfflineRule for Collision {
    fn check(&self, req: &Request, cx: &OfflineCx) -> Vec<Violation> {
        let (Some(name), Some(catalogue)) = (req.name(), cx.catalogue.as_ref()) else {
            return Vec::new();
        };

        if !catalogue.contains(name) {
            return Vec::new();
        }

        vec![Violation::new(
            Rule::R4,
            "package.name",
            format!(
                "{} is already the name of an existing package",
                redact::show(name)
            ),
            "if you want that package, it exists already — nothing to request. \
             If this is a different project, it needs a distinct name, because \
             two packages cannot share one",
        )]
    }
}

/// Rule 5: `name` is at least edit-distance 2 from any catalogue entry.
///
/// Name-similarity is a real AUR attack: a package one keystroke from a
/// popular one collects the installs of everyone who mistypes. Catching it
/// here costs a string comparison; catching it after a signed build costs an
/// incident.
pub struct Typosquat;

impl OfflineRule for Typosquat {
    fn check(&self, req: &Request, cx: &OfflineCx) -> Vec<Violation> {
        let (Some(name), Some(catalogue)) = (req.name(), cx.catalogue.as_ref()) else {
            return Vec::new();
        };

        // Distance 0 is rule 4's finding. One mistake, one diagnostic.
        if catalogue.contains(name) {
            return Vec::new();
        }

        let Some(neighbour) = catalogue.nearest_at_distance_one(name) else {
            return Vec::new();
        };

        vec![Violation::new(
            Rule::R5,
            "package.name",
            format!(
                "{} is one edit away from the existing package {}, so it is held for \
                 typosquat review",
                redact::show(name),
                redact::show(neighbour)
            ),
            format!(
                "if you meant {}, it already exists and needs no request. If this is a \
                 genuinely different project, say so in requester.notes and a maintainer \
                 will clear it — names this close are the mechanism behind real \
                 supply-chain attacks, so a human decides",
                redact::show(neighbour)
            ),
        )]
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::catalogue::Catalogue;
    use crate::license::Allowlist;

    fn cx(catalogue: &str) -> OfflineCx {
        OfflineCx {
            catalogue: Some(Catalogue::parse(catalogue)),
            allowlist: Allowlist::embedded(),
        }
    }

    fn request(name: &str) -> serde_json::Value {
        serde_json::json!({ "package": { "name": name } })
    }

    #[test]
    fn an_unrelated_name_passes_both_rules() {
        let v = request("ghostty");
        let req = Request::new(&v);
        let cx = cx("firefox\nchromium\n");
        assert!(Collision.check(&req, &cx).is_empty());
        assert!(Typosquat.check(&req, &cx).is_empty());
    }

    #[test]
    fn an_exact_collision_is_rule_four() {
        let v = request("firefox");
        let out = Collision.check(&Request::new(&v), &cx("firefox\n"));
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].rule, Rule::R4);
    }

    #[test]
    fn an_exact_collision_does_not_also_report_rule_five() {
        let v = request("firefox");
        assert!(Typosquat
            .check(&Request::new(&v), &cx("firefox\n"))
            .is_empty());
    }

    #[test]
    fn distance_one_is_rule_five_and_names_the_neighbour() {
        let v = request("ghosttty");
        let out = Typosquat.check(&Request::new(&v), &cx("ghostty\n"));
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].rule, Rule::R5);
        assert!(out[0].message.contains("'ghostty'"), "{}", out[0].message);
        assert!(out[0].remedy.contains("requester.notes"));
    }

    #[test]
    fn distance_two_passes() {
        let v = request("ghosttty");
        assert!(Typosquat
            .check(&Request::new(&v), &cx("ghosty\n"))
            .is_empty());
    }

    #[test]
    fn without_a_catalogue_the_rules_decline_rather_than_pass() {
        // The caller is responsible for refusing to run in this state; see
        // `--no-catalogue` in cli.rs. The rule itself must not invent a verdict.
        let v = request("firefox");
        let cx = OfflineCx {
            catalogue: None,
            allowlist: Allowlist::embedded(),
        };
        assert!(Collision.check(&Request::new(&v), &cx).is_empty());
        assert!(Typosquat.check(&Request::new(&v), &cx).is_empty());
    }

    #[test]
    fn a_hostile_name_is_escaped_in_the_message() {
        let v = request("fire\u{202e}fox");
        let out = Collision.check(&Request::new(&v), &cx("fire\u{202e}fox\n"));
        assert!(out[0].message.contains("\\u{202e}"));
        assert!(!out[0].message.contains('\u{202e}'));
    }
}
