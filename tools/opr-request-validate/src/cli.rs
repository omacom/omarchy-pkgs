//! Command-line surface.

use clap::{ArgAction, Parser, ValueEnum};
use std::path::PathBuf;

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum Format {
    /// One line per violation.
    Human,
    /// One JSON object per file, for a bot that comments on the PR.
    Json,
}

#[derive(Debug, Parser)]
#[command(
    name = "opr-request-validate",
    version,
    about = "Validate an OPR packaging request. Offline by default.",
    long_about = "Validates requests/<name>.toml against docs/request-schema.md.\n\n\
                  --offline (the default) runs rules 1-5 and 7-11 and opens no \
                  network connection, which is what the PR stage requires.\n\
                  --resolve additionally runs rule 6, which asks the network what is \
                  actually at the upstream URL.",
    after_help = "EXIT CODES:\n  \
                  0  no violations\n  \
                  1  one or more violations (including a file that will not parse)\n  \
                  2  the validator could not run: bad arguments, unreadable path, \
                  missing catalogue"
)]
pub struct Args {
    /// Request files to validate.
    #[arg(value_name = "PATH", required = true)]
    pub paths: Vec<PathBuf>,

    /// Additionally run rule 6, which resolves the upstream URL over the network.
    #[arg(long, action = ArgAction::SetTrue)]
    pub resolve: bool,

    /// Run only the rules that need no network. This is the default.
    #[arg(long, action = ArgAction::SetTrue, conflicts_with = "resolve")]
    pub offline: bool,

    /// Newline-delimited existing package names, for rules 4 and 5.
    #[arg(long, value_name = "FILE")]
    pub catalogue: Option<PathBuf>,

    /// Skip rules 4 and 5 because no catalogue is available.
    ///
    /// For local runs. CI must always pass --catalogue: without one, a name
    /// that collides with an existing package, or sits one keystroke from a
    /// popular one, would pass unexamined.
    #[arg(long, action = ArgAction::SetTrue, conflicts_with = "catalogue")]
    pub no_catalogue: bool,

    /// Override the redistributable license allowlist used by rule 8.
    #[arg(long, value_name = "FILE")]
    pub redistributable: Option<PathBuf>,

    /// Override the embedded request schema. For testing.
    #[arg(long, value_name = "FILE")]
    pub schema: Option<PathBuf>,

    #[arg(long, value_enum, default_value_t = Format::Human)]
    pub format: Format,

    /// Print nothing; signal the result through the exit code alone.
    #[arg(long, short, action = ArgAction::SetTrue)]
    pub quiet: bool,
}

impl Args {
    pub fn wants_network(&self) -> bool {
        self.resolve
    }

    /// The catalogue is mandatory unless its absence is stated explicitly.
    ///
    /// Fail-closed: a mistyped `--catalogue` path must stop the run, not
    /// quietly turn rules 4 and 5 off and report success. A gate that passes
    /// because it was misconfigured is worse than one that fails.
    pub fn catalogue_choice(&self) -> Result<Option<&PathBuf>, String> {
        match (&self.catalogue, self.no_catalogue) {
            (Some(path), _) => Ok(Some(path)),
            (None, true) => Ok(None),
            (None, false) => Err(
                "no catalogue given, so rules 4 (name collision) and 5 (typosquat \
                 distance) cannot run.\n\
                 Pass --catalogue <FILE> with one existing package name per line, or \
                 --no-catalogue to skip those two rules deliberately.\n\
                 CI should always pass --catalogue."
                    .to_string(),
            ),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::CommandFactory;

    fn parse(args: &[&str]) -> Result<Args, clap::Error> {
        Args::try_parse_from(std::iter::once("opr-request-validate").chain(args.iter().copied()))
    }

    #[test]
    fn cli_definition_is_well_formed() {
        Args::command().debug_assert();
    }

    #[test]
    fn offline_is_the_default() {
        let a = parse(&["--no-catalogue", "x.toml"]).unwrap();
        assert!(!a.wants_network());
    }

    #[test]
    fn resolve_opts_into_the_network() {
        let a = parse(&["--resolve", "--no-catalogue", "x.toml"]).unwrap();
        assert!(a.wants_network());
    }

    #[test]
    fn offline_and_resolve_are_mutually_exclusive() {
        assert!(parse(&["--offline", "--resolve", "x.toml"]).is_err());
    }

    #[test]
    fn a_missing_catalogue_is_an_error_not_a_silent_skip() {
        let a = parse(&["x.toml"]).unwrap();
        let err = a.catalogue_choice().unwrap_err();
        assert!(err.contains("--catalogue"));
        assert!(err.contains("--no-catalogue"));
    }

    #[test]
    fn skipping_the_catalogue_must_be_explicit() {
        let a = parse(&["--no-catalogue", "x.toml"]).unwrap();
        assert!(a.catalogue_choice().unwrap().is_none());
    }

    #[test]
    fn catalogue_and_no_catalogue_conflict() {
        assert!(parse(&["--catalogue", "c.txt", "--no-catalogue", "x.toml"]).is_err());
    }

    #[test]
    fn at_least_one_path_is_required() {
        assert!(parse(&["--no-catalogue"]).is_err());
    }

    #[test]
    fn several_files_can_be_checked_in_one_run() {
        let a = parse(&["--no-catalogue", "a.toml", "b.toml"]).unwrap();
        assert_eq!(a.paths.len(), 2);
    }
}
