//! Entry point. Argument handling, output, exit codes — no rule logic.

use clap::Parser;
use opr_request_validate::{
    catalogue::Catalogue,
    cli::{Args, Format},
    license::Allowlist,
    net::{Http, UreqClient},
    schema::Schema,
    Report, Validator,
};
use std::process::ExitCode;

/// Distinguishing 1 from 2 is what lets a broken runner fail loudly instead of
/// reporting a clean bill of health for a request nobody actually checked.
const EXIT_VALID: u8 = 0;
const EXIT_VIOLATIONS: u8 = 1;
const EXIT_CANNOT_RUN: u8 = 2;

fn main() -> ExitCode {
    let args = Args::parse();

    match run(&args) {
        Ok(reports) => {
            emit(&args, &reports);
            if reports.iter().all(Report::is_valid) {
                ExitCode::from(EXIT_VALID)
            } else {
                ExitCode::from(EXIT_VIOLATIONS)
            }
        }
        Err(message) => {
            eprintln!("opr-request-validate: {message}");
            ExitCode::from(EXIT_CANNOT_RUN)
        }
    }
}

fn run(args: &Args) -> Result<Vec<Report>, String> {
    let schema = match &args.schema {
        Some(path) => {
            let text = std::fs::read_to_string(path)
                .map_err(|e| format!("cannot read schema {}: {e}", path.display()))?;
            Schema::from_json(&text)
        }
        None => Schema::embedded(),
    }
    .map_err(|e| e.to_string())?;

    let catalogue = match args.catalogue_choice()? {
        Some(path) => Some(Catalogue::load(path)?),
        None => None,
    };

    let allowlist = match &args.redistributable {
        Some(path) => Allowlist::load(path)?,
        None => Allowlist::embedded(),
    };
    if allowlist.is_empty() {
        return Err(
            "the redistributable allowlist is empty, so rule 8 would reject \
                    every binary-surface request"
                .to_string(),
        );
    }

    let validator = Validator::new(schema, catalogue, allowlist);

    // Constructed only on the --resolve path. In offline mode no client
    // exists, so there is nothing that could open a socket.
    let client: Option<Box<dyn Http>> = if args.wants_network() {
        Some(Box::new(UreqClient::new()))
    } else {
        None
    };

    Ok(args
        .paths
        .iter()
        .map(|path| match &client {
            Some(net) => validator.check_all(path, net.as_ref()),
            None => validator.check_offline(path),
        })
        .collect())
}

fn emit(args: &Args, reports: &[Report]) {
    if args.quiet {
        return;
    }

    match args.format {
        Format::Human => {
            for report in reports {
                for violation in &report.violations {
                    println!("{}", violation.render_human(&report.path));
                }
            }
            let failed = reports.iter().filter(|r| !r.is_valid()).count();
            if failed == 0 {
                let n = reports.len();
                let noun = if n == 1 { "request" } else { "requests" };
                println!("{n} {noun} valid.");
            } else {
                let total: usize = reports.iter().map(|r| r.violations.len()).sum();
                let violations = if total == 1 {
                    "violation"
                } else {
                    "violations"
                };
                let files = if reports.len() == 1 { "file" } else { "files" };
                eprintln!(
                    "\n{failed} of {} checked {files} failed with {total} {violations}. \
                     Rules are documented in docs/request-schema.md.",
                    reports.len()
                );
            }
        }
        Format::Json => {
            let payload: Vec<serde_json::Value> = reports
                .iter()
                .map(|r| {
                    serde_json::json!({
                        "file": r.path,
                        "valid": r.is_valid(),
                        "violations": r.violations
                            .iter()
                            .map(|v| v.render_json(&r.path))
                            .collect::<Vec<_>>(),
                    })
                })
                .collect();
            println!(
                "{}",
                serde_json::to_string_pretty(&payload).unwrap_or_else(|_| "[]".into())
            );
        }
    }
}
