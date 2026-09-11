//! Rule 6 — the only rule that needs the network, and the only one `--offline`
//! does not run.
//!
//! `upstream` is the identity anchor for the whole package: it is what the
//! factory diffs future versions against, and the field most likely to be
//! wrong in good faith. Checking it means asking the network what is actually
//! there, which is why it is a separate stage from the PR gate.
//!
//! HTTP goes behind a trait so the redirect and host logic — the part with the
//! security consequences — is tested against scripted responses rather than
//! against whatever the internet returns today.

pub mod resolve;

pub use resolve::UpstreamResolves;

/// The minimum an HTTP client must do for rule 6.
///
/// Deliberately narrow. Redirects are *not* followed by the implementation:
/// the rule walks the chain itself, because "does not redirect off-host" is
/// a question about the chain, and a client that follows transparently has
/// already thrown away the answer.
pub trait Http {
    fn head(&self, url: &str) -> Result<Response, HttpError>;
}

#[derive(Debug, Clone)]
pub struct Response {
    pub status: u16,
    /// The `Location` header, verbatim and unresolved.
    pub location: Option<String>,
}

#[derive(Debug, Clone)]
pub enum HttpError {
    /// DNS failure, connection refused, TLS failure, timeout.
    Unreachable(String),
    /// The client refused to make the request at all.
    Refused(String),
}

impl std::fmt::Display for HttpError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            HttpError::Unreachable(m) => write!(f, "{m}"),
            HttpError::Refused(m) => write!(f, "{m}"),
        }
    }
}

/// A real client, constructed only when `--resolve` is passed.
pub struct UreqClient {
    agent: ureq::Agent,
}

impl Default for UreqClient {
    fn default() -> Self {
        Self::new()
    }
}

impl UreqClient {
    pub fn new() -> Self {
        let config = ureq::Agent::config_builder()
            // The rule walks the chain itself; see the `Http` docs.
            .max_redirects(0)
            .timeout_global(Some(std::time::Duration::from_secs(15)))
            // A validator identifies itself. An operator reading their logs
            // should be able to tell what this traffic is.
            .user_agent(concat!("opr-request-validate/", env!("CARGO_PKG_VERSION")))
            .build();
        Self {
            agent: ureq::Agent::new_with_config(config),
        }
    }
}

impl Http for UreqClient {
    fn head(&self, url: &str) -> Result<Response, HttpError> {
        // Belt and braces: `resolve` already refuses non-https, but this is
        // the last point before a socket opens.
        if !url.starts_with("https://") {
            return Err(HttpError::Refused(
                "refusing to request a non-https URL".to_string(),
            ));
        }

        let response = self.agent.head(url).call().or_else(|e| match e {
            // With max_redirects(0) a 3xx surfaces as an error in some
            // ureq versions and as a response in others. Both are the
            // chain step we want to inspect, not a failure.
            ureq::Error::StatusCode(code) if (300..400).contains(&code) => Err(
                HttpError::Unreachable(format!("redirect status {code} without a location")),
            ),
            ureq::Error::StatusCode(code) => Ok(ureq::http::Response::builder()
                .status(code)
                .body(ureq::Body::builder().data(&[][..]))
                .expect("status-only response is well-formed")),
            other => Err(HttpError::Unreachable(other.to_string())),
        })?;

        let status = response.status().as_u16();
        let location = response
            .headers()
            .get("location")
            .and_then(|v| v.to_str().ok())
            .map(str::to_string);

        Ok(Response { status, location })
    }
}
