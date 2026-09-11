//! Rule 6: `upstream` is HTTPS, resolves, is a repository root, and does not
//! redirect off-host.

use super::{Http, HttpError};
use crate::diagnostic::{Rule, Violation};
use crate::redact;
use crate::rules::{Request, ResolveRule};
use url::Url;

/// Long enough for the canonicalising redirects a forge actually performs
/// (case correction, trailing slash, a rename), short enough that a loop ends.
const MAX_HOPS: usize = 5;

/// Forges whose URL layout we know well enough to say what a repository root
/// looks like. On any other host the shape is unknowable, so the check is
/// limited to what is actually decidable.
const KNOWN_FORGES: &[(&str, ForgeShape)] = &[
    ("github.com", ForgeShape::OwnerRepo),
    ("bitbucket.org", ForgeShape::OwnerRepo),
    ("codeberg.org", ForgeShape::OwnerRepo),
    ("git.sr.ht", ForgeShape::OwnerRepo),
    // GitLab permits arbitrarily nested subgroups, so depth cannot be pinned.
    ("gitlab.com", ForgeShape::NestedGroups),
];

#[derive(Debug, Clone, Copy, PartialEq)]
enum ForgeShape {
    /// Exactly `/owner/repo`.
    OwnerRepo,
    /// `/group[/subgroup...]/repo`, but not a reserved path.
    NestedGroups,
}

/// Path segments that are part of a forge's own UI rather than a repository.
/// A URL containing one of these is a page *about* a repository, not its root.
const FORGE_UI_SEGMENTS: &[&str] = &[
    "releases", "tree", "blob", "issues", "pulls", "pull", "wiki", "tags", "commits", "commit",
    "actions", "archive", "raw", "compare", "-", "settings",
];

pub struct UpstreamResolves;

impl ResolveRule for UpstreamResolves {
    fn check(&self, req: &Request, net: &dyn Http) -> Vec<Violation> {
        let Some(raw) = req.upstream() else {
            return Vec::new();
        };

        let Ok(start) = Url::parse(raw) else {
            return vec![Violation::new(
                Rule::R6,
                "package.upstream",
                format!("{} is not a URL", redact::show(raw)),
                "use the https:// URL of the repository of record, for example \
                 https://github.com/ghostty-org/ghostty",
            )];
        };

        if start.scheme() != "https" {
            return vec![Violation::new(
                Rule::R6,
                "package.upstream",
                format!("{} is not https", redact::show(raw)),
                "use https:// — an http or git+ssh URL cannot be verified",
            )];
        }

        // Walk the chain before judging the destination: where a URL ends up
        // is what the factory will actually track.
        let final_url = match walk(&start, net) {
            Ok(url) => url,
            Err(violation) => return vec![violation],
        };

        // A vendor download has no repository root by definition. The spec's
        // own Surface B example (requests/google-chrome.toml) points at
        // dl.google.com, so applying the repository-root assertion to it would
        // reject a request the document presents as valid. See README:
        // "Where the implementation reads the spec".
        if req.source_kind() == Some("vendor") {
            return Vec::new();
        }

        repository_root_violation(&final_url, raw)
            .map(|v| vec![v])
            .unwrap_or_default()
    }
}

/// Follow the redirect chain by hand, refusing any hop that leaves the host.
fn walk(start: &Url, net: &dyn Http) -> Result<Url, Violation> {
    let mut current = start.clone();

    for _ in 0..MAX_HOPS {
        let response = net.head(current.as_str()).map_err(|e| match e {
            HttpError::Unreachable(m) => Violation::new(
                Rule::R6,
                "package.upstream",
                format!(
                    "{} could not be reached: {}",
                    redact::show(current.as_str()),
                    redact::show(&m)
                ),
                "check the URL opens in a browser. If the repository is private or has \
                 been deleted, we cannot package it — we build from sources anyone can \
                 verify",
            ),
            HttpError::Refused(m) => Violation::new(
                Rule::R6,
                "package.upstream",
                format!("request refused: {}", redact::show(&m)),
                "use a public https:// repository URL",
            ),
        })?;

        if !(300..400).contains(&response.status) {
            return finish(current, response.status, start);
        }

        let Some(location) = response.location else {
            return Err(Violation::new(
                Rule::R6,
                "package.upstream",
                format!(
                    "{} returned a {} redirect with no destination",
                    redact::show(current.as_str()),
                    response.status
                ),
                "this usually means the URL is not the canonical one — open it in a \
                 browser and use the address you land on",
            ));
        };

        // Relative Locations are legal, so resolve against the current URL.
        let next = current.join(&location).map_err(|_| {
            Violation::new(
                Rule::R6,
                "package.upstream",
                format!(
                    "redirected to an unusable address: {}",
                    redact::show(&location)
                ),
                "open the URL in a browser and use the address you land on",
            )
        })?;

        if next.scheme() != "https" {
            return Err(Violation::new(
                Rule::R6,
                "package.upstream",
                format!(
                    "{} redirects to {}, which is not https",
                    redact::show(start.as_str()),
                    redact::show(next.as_str())
                ),
                "a chain that drops to http cannot be verified — use the https address \
                 the project actually serves",
            ));
        }

        if let Some(violation) = off_host(start, &next) {
            return Err(violation);
        }

        current = next;
    }

    Err(Violation::new(
        Rule::R6,
        "package.upstream",
        format!(
            "{} redirects more than {MAX_HOPS} times",
            redact::show(start.as_str())
        ),
        "use the address the chain settles on, or the repository's canonical URL",
    ))
}

/// Whether a hop leaves the originating host.
///
/// This is the rule's security-relevant half. A URL that passes review pointing
/// at one host and later serves from another is exactly the substitution the
/// verification stage exists to catch, so the comparison is on the host itself
/// and not on the registrable domain — `github.com` to `pages.github.com` is a
/// different origin and reported as such.
///
/// The single exemption is a `www.` prefix appearing or disappearing, which is
/// a canonicalisation every large site performs and which moves nothing.
fn off_host(start: &Url, next: &Url) -> Option<Violation> {
    let from = normalise_host(start);
    let to = normalise_host(next);

    if from == to {
        return None;
    }

    Some(Violation::new(
        Rule::R6,
        "package.upstream",
        format!(
            "{} redirects off-host to {}",
            redact::show(start.as_str()),
            redact::show(next.as_str())
        ),
        format!(
            "point upstream at {} directly. A URL on one host that serves from another \
             gives us nothing stable to verify against, and it is how a source gets \
             substituted between review and build",
            redact::show(&to)
        ),
    ))
}

fn normalise_host(url: &Url) -> String {
    let host = url.host_str().unwrap_or_default().to_ascii_lowercase();
    host.strip_prefix("www.").unwrap_or(&host).to_string()
}

/// Judge the endpoint the chain settled on.
fn finish(current: Url, status: u16, start: &Url) -> Result<Url, Violation> {
    if (200..300).contains(&status) {
        return Ok(current);
    }

    let (what, fix) = match status {
        404 | 410 => (
            "does not exist",
            "check the spelling, and check the project has not moved or been deleted. \
             We package from sources anyone can fetch",
        ),
        401 | 403 => (
            "is not publicly readable",
            "a private repository cannot be packaged — every source we build from has \
             to be verifiable by anyone",
        ),
        429 => (
            "rate-limited the check",
            "this is our problem, not yours — re-run the check, and tell a maintainer \
             if it keeps happening",
        ),
        500..=599 => (
            "returned a server error",
            "the host is having trouble; re-run the check later",
        ),
        _ => (
            "did not resolve",
            "open the URL in a browser and use the address you land on",
        ),
    };

    Err(Violation::new(
        Rule::R6,
        "package.upstream",
        format!("{} {what} (HTTP {status})", redact::show(start.as_str())),
        fix,
    ))
}

/// Whether the settled URL looks like the root of a repository.
///
/// Only two things are actually decidable. On a known forge the path layout
/// says so outright. On any host, a bare domain with no path is a homepage
/// rather than a repository — which is the single most common good-faith
/// mistake this field attracts. Everything else (self-hosted cgit, Gitea,
/// Forgejo) is accepted here and left to the factory, because guessing would
/// reject correct requests.
fn repository_root_violation(url: &Url, raw: &str) -> Option<Violation> {
    let host = normalise_host(url);
    let segments: Vec<&str> = url
        .path_segments()
        .map(|s| s.filter(|seg| !seg.is_empty()).collect())
        .unwrap_or_default();

    let homepage_remedy = "upstream must be a repository root, not a project homepage — \
                           use the GitHub/GitLab repo URL, for example \
                           https://github.com/ghostty-org/ghostty";

    if segments.is_empty() {
        return Some(Violation::new(
            Rule::R6,
            "package.upstream",
            format!(
                "{} is a bare domain, so it is a homepage rather than a repository root",
                redact::show(raw)
            ),
            homepage_remedy,
        ));
    }

    let shape = KNOWN_FORGES
        .iter()
        .find(|(h, _)| *h == host)
        .map(|(_, shape)| *shape)?;

    if let Some(ui) = segments
        .iter()
        .find(|s| FORGE_UI_SEGMENTS.contains(&s.to_ascii_lowercase().as_str()))
    {
        return Some(Violation::new(
            Rule::R6,
            "package.upstream",
            format!(
                "{} points at a {} page inside the repository, not the repository root",
                redact::show(raw),
                redact::show(ui)
            ),
            "trim the URL back to the repository itself — everything after \
             owner/repo is a view of it, and the factory needs the root to diff \
             future versions against",
        ));
    }

    let wrong_depth = match shape {
        ForgeShape::OwnerRepo => segments.len() != 2,
        ForgeShape::NestedGroups => segments.len() < 2,
    };

    if wrong_depth {
        let detail = if segments.len() < 2 {
            "names an account or organisation, not one repository"
        } else {
            "is deeper than a repository root"
        };
        return Some(Violation::new(
            Rule::R6,
            "package.upstream",
            format!("{} {detail}", redact::show(raw)),
            "use the repository's own URL, in the form https://<forge>/<owner>/<repo>",
        ));
    }

    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;
    use std::collections::HashMap;

    /// A scripted client. Rule 6's logic is the redirect chain and the host
    /// comparison, and both are testable without a socket.
    struct Fake {
        routes: HashMap<String, super::super::Response>,
        asked: RefCell<Vec<String>>,
    }

    impl Fake {
        fn new() -> Self {
            Self {
                routes: HashMap::new(),
                asked: RefCell::new(Vec::new()),
            }
        }
        fn ok(mut self, url: &str) -> Self {
            self.routes.insert(
                url.into(),
                super::super::Response {
                    status: 200,
                    location: None,
                },
            );
            self
        }
        fn status(mut self, url: &str, status: u16) -> Self {
            self.routes.insert(
                url.into(),
                super::super::Response {
                    status,
                    location: None,
                },
            );
            self
        }
        fn redirect(mut self, from: &str, to: &str) -> Self {
            self.routes.insert(
                from.into(),
                super::super::Response {
                    status: 301,
                    location: Some(to.into()),
                },
            );
            self
        }
    }

    impl Http for Fake {
        fn head(&self, url: &str) -> Result<super::super::Response, HttpError> {
            self.asked.borrow_mut().push(url.to_string());
            self.routes
                .get(url)
                .cloned()
                .ok_or_else(|| HttpError::Unreachable("no such host".into()))
        }
    }

    fn request(upstream: &str) -> serde_json::Value {
        serde_json::json!({ "package": { "upstream": upstream }, "source": { "kind": "release" } })
    }

    fn vendor_request(upstream: &str) -> serde_json::Value {
        serde_json::json!({ "package": { "upstream": upstream }, "source": { "kind": "vendor" } })
    }

    fn run(value: &serde_json::Value, net: &dyn Http) -> Vec<Violation> {
        UpstreamResolves.check(&Request::new(value), net)
    }

    #[test]
    fn a_repository_root_that_resolves_passes() {
        let v = request("https://github.com/ghostty-org/ghostty");
        let net = Fake::new().ok("https://github.com/ghostty-org/ghostty");
        assert!(run(&v, &net).is_empty());
    }

    #[test]
    fn an_on_host_redirect_is_followed() {
        // A rename inside the same forge is normal and must not fail.
        let v = request("https://github.com/old-org/ghostty");
        let net = Fake::new()
            .redirect(
                "https://github.com/old-org/ghostty",
                "https://github.com/ghostty-org/ghostty",
            )
            .ok("https://github.com/ghostty-org/ghostty");
        assert!(run(&v, &net).is_empty());
    }

    #[test]
    fn a_redirect_off_host_is_reported() {
        let v = request("https://github.com/ghostty-org/ghostty");
        let net = Fake::new()
            .redirect(
                "https://github.com/ghostty-org/ghostty",
                "https://evil.example/ghostty",
            )
            .ok("https://evil.example/ghostty");
        let out = run(&v, &net);
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].rule, Rule::R6);
        assert!(out[0].message.contains("off-host"), "{}", out[0].message);
        assert!(out[0].message.contains("evil.example"));
    }

    #[test]
    fn an_off_host_redirect_is_not_followed_further() {
        let v = request("https://github.com/a/b");
        let net = Fake::new()
            .redirect("https://github.com/a/b", "https://evil.example/x")
            .ok("https://evil.example/x");
        let _ = run(&v, &net);
        let asked = net.asked.borrow();
        assert!(
            !asked.iter().any(|u| u.contains("evil.example")),
            "validator followed the off-host hop: {asked:?}"
        );
    }

    #[test]
    fn a_www_prefix_change_is_not_off_host() {
        let v = request("https://codeberg.org/owner/repo");
        let net = Fake::new()
            .redirect(
                "https://codeberg.org/owner/repo",
                "https://www.codeberg.org/owner/repo",
            )
            .ok("https://www.codeberg.org/owner/repo");
        assert!(run(&v, &net).is_empty());
    }

    #[test]
    fn a_subdomain_is_off_host() {
        let v = request("https://github.com/a/b");
        let net = Fake::new()
            .redirect("https://github.com/a/b", "https://pages.github.com/a/b")
            .ok("https://pages.github.com/a/b");
        assert!(!run(&v, &net).is_empty());
    }

    #[test]
    fn a_downgrade_to_http_is_reported() {
        let v = request("https://github.com/a/b");
        let net = Fake::new().redirect("https://github.com/a/b", "http://github.com/a/b");
        let out = run(&v, &net);
        assert!(out[0].message.contains("not https"), "{}", out[0].message);
    }

    #[test]
    fn a_redirect_loop_terminates() {
        let v = request("https://github.com/a/b");
        let net = Fake::new()
            .redirect("https://github.com/a/b", "https://github.com/b/c")
            .redirect("https://github.com/b/c", "https://github.com/a/b");
        let out = run(&v, &net);
        assert_eq!(out.len(), 1);
        assert!(out[0].message.contains("redirects more than"));
    }

    #[test]
    fn a_project_homepage_is_rejected_with_the_repo_hint() {
        let v = request("https://ghostty.org/");
        let net = Fake::new().ok("https://ghostty.org/");
        let out = run(&v, &net);
        assert_eq!(out.len(), 1);
        assert!(out[0].remedy.contains("not a project homepage"));
    }

    #[test]
    fn a_releases_page_is_not_a_repository_root() {
        let v = request("https://github.com/ghostty-org/ghostty/releases");
        let net = Fake::new().ok("https://github.com/ghostty-org/ghostty/releases");
        let out = run(&v, &net);
        assert_eq!(out.len(), 1);
        assert!(out[0].message.contains("not the repository root"));
    }

    #[test]
    fn an_org_page_is_not_a_repository_root() {
        let v = request("https://github.com/ghostty-org");
        let net = Fake::new().ok("https://github.com/ghostty-org");
        let out = run(&v, &net);
        assert!(out[0].message.contains("account or organisation"));
    }

    #[test]
    fn gitlab_subgroups_are_allowed() {
        let v = request("https://gitlab.com/group/subgroup/repo");
        let net = Fake::new().ok("https://gitlab.com/group/subgroup/repo");
        assert!(run(&v, &net).is_empty());
    }

    #[test]
    fn an_unknown_forge_with_a_path_is_left_to_the_factory() {
        let v = request("https://git.example.org/cgit/thing");
        let net = Fake::new().ok("https://git.example.org/cgit/thing");
        assert!(run(&v, &net).is_empty());
    }

    #[test]
    fn a_vendor_source_is_exempt_from_the_repository_root_check() {
        // requests/google-chrome.toml, which the spec presents as valid.
        let v = vendor_request("https://dl.google.com/linux/chrome/deb");
        let net = Fake::new().ok("https://dl.google.com/linux/chrome/deb");
        assert!(run(&v, &net).is_empty());
    }

    #[test]
    fn a_vendor_source_still_may_not_redirect_off_host() {
        let v = vendor_request("https://dl.google.com/linux/chrome/deb");
        let net = Fake::new()
            .redirect(
                "https://dl.google.com/linux/chrome/deb",
                "https://evil.example/x",
            )
            .ok("https://evil.example/x");
        assert!(!run(&v, &net).is_empty());
    }

    #[test]
    fn a_404_explains_that_sources_must_be_public() {
        let v = request("https://github.com/a/b");
        let net = Fake::new().status("https://github.com/a/b", 404);
        let out = run(&v, &net);
        assert!(out[0].message.contains("does not exist"));
    }

    #[test]
    fn a_private_repository_is_explained_as_such() {
        let v = request("https://github.com/a/b");
        let net = Fake::new().status("https://github.com/a/b", 403);
        let out = run(&v, &net);
        assert!(out[0].remedy.contains("private repository"));
    }

    #[test]
    fn an_unreachable_host_is_reported_not_silently_passed() {
        let v = request("https://github.com/a/b");
        let out = run(&v, &Fake::new());
        assert_eq!(out.len(), 1);
        assert!(out[0].message.contains("could not be reached"));
    }
}
