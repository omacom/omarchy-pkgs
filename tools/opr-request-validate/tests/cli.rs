//! End-to-end tests against the compiled binary.
//!
//! The unit tests cover each rule's logic. These cover the contract the PR
//! stage actually depends on: exit codes, one line per violation, and output
//! that is safe to paste into a log.

use std::path::{Path, PathBuf};
use std::process::{Command, Output};

fn manifest_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

fn fixture(rel: &str) -> PathBuf {
    manifest_dir().join("tests/fixtures").join(rel)
}

/// Existing packages, excluding every name the valid fixtures request.
fn catalogue() -> PathBuf {
    fixture("catalogue.txt")
}

/// Contains `ghostty`, so the typosquat fixture (`ghosttty`) sits one edit
/// away. Kept separate because a catalogue that lists a name is exactly what
/// makes a request for that name a rule 4 collision.
fn neighbours() -> PathBuf {
    fixture("catalogue-neighbours.txt")
}

/// Run the binary with a catalogue, in the default (offline) mode.
fn run(args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_opr-request-validate"))
        .args(args)
        .output()
        .expect("binary runs")
}

fn check(path: &Path) -> Output {
    check_against(path, &catalogue())
}

fn check_against(path: &Path, catalogue: &Path) -> Output {
    run(&[
        "--catalogue",
        catalogue.to_str().unwrap(),
        path.to_str().unwrap(),
    ])
}

fn stdout(out: &Output) -> String {
    String::from_utf8_lossy(&out.stdout).to_string()
}

fn code(out: &Output) -> i32 {
    out.status.code().expect("process exited normally")
}

// ---------------------------------------------------------------- happy path

#[test]
fn the_spec_example_requests_are_valid() {
    for name in ["ghostty.toml", "google-chrome.toml", "recipe-tag.toml"] {
        let out = check(&fixture("valid").join(name));
        assert_eq!(
            code(&out),
            0,
            "{name} should be valid but produced:\n{}\n{}",
            stdout(&out),
            String::from_utf8_lossy(&out.stderr)
        );
    }
}

#[test]
fn the_committed_requests_directory_is_valid() {
    // The real files, not copies. If someone edits requests/ into an invalid
    // state, this fails.
    let repo = manifest_dir().join("../..").canonicalize().unwrap();
    for name in ["ghostty.toml", "google-chrome.toml"] {
        let out = check(&repo.join("requests").join(name));
        assert_eq!(
            code(&out),
            0,
            "requests/{name} is not valid:\n{}",
            stdout(&out)
        );
    }
}

#[test]
fn several_files_are_checked_in_one_run() {
    let out = run(&[
        "--catalogue",
        catalogue().to_str().unwrap(),
        fixture("valid/ghostty.toml").to_str().unwrap(),
        fixture("valid/google-chrome.toml").to_str().unwrap(),
    ]);
    assert_eq!(code(&out), 0);
    assert!(stdout(&out).contains("2 requests valid."));
}

// ------------------------------------------------------------ the exit codes

#[test]
fn a_violation_exits_one() {
    assert_eq!(code(&check(&fixture("invalid/unknown-key.toml"))), 1);
}

#[test]
fn a_missing_catalogue_exits_two_rather_than_silently_skipping_rules() {
    // The gate must not report success because it was misconfigured.
    let out = run(&[fixture("valid/ghostty.toml").to_str().unwrap()]);
    assert_eq!(code(&out), 2);
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(err.contains("--catalogue"), "{err}");
    assert!(err.contains("--no-catalogue"), "{err}");
}

#[test]
fn a_mistyped_catalogue_path_exits_two() {
    let out = run(&[
        "--catalogue",
        "/nonexistent/catalogue.txt",
        fixture("valid/ghostty.toml").to_str().unwrap(),
    ]);
    assert_eq!(code(&out), 2, "a bad catalogue path must stop the run");
}

#[test]
fn an_unreadable_request_path_does_not_report_success() {
    let out = run(&[
        "--catalogue",
        catalogue().to_str().unwrap(),
        "/nonexistent/request.toml",
    ]);
    assert_ne!(code(&out), 0);
}

#[test]
fn skipping_the_catalogue_is_possible_but_must_be_explicit() {
    let out = run(&[
        "--no-catalogue",
        fixture("valid/ghostty.toml").to_str().unwrap(),
    ]);
    assert_eq!(code(&out), 0);
}

// -------------------------------------------------- the cases the spec names

/// Every invalid fixture must fail, and fail for the stated rule.
#[test]
fn each_malformed_request_reports_its_rule() {
    let cases: &[(&str, &str, bool)] = &[
        ("invalid/unknown-key.toml", "rule 2", false),
        ("invalid/verification-block.toml", "rule 2", false),
        ("invalid/shell-metacharacters.toml", "rule 3", false),
        ("invalid/typosquat.toml", "rule 5", true),
        ("invalid/binary-nonredistributable.toml", "rule 8", false),
        ("invalid/vendor-binary.toml", "rule 10", false),
        ("invalid/control-characters.toml", "rule 11", false),
        ("invalid/missing-required.toml", "structure", false),
    ];

    for (path, expected, needs_neighbours) in cases {
        let cat = if *needs_neighbours {
            neighbours()
        } else {
            catalogue()
        };
        let out = check_against(&fixture(path), &cat);
        let text = stdout(&out);
        assert_eq!(code(&out), 1, "{path} should be invalid");
        assert!(
            text.contains(expected),
            "{path} should report {expected}, got:\n{text}"
        );
    }
}

#[test]
fn an_unknown_key_names_the_key_and_says_the_factory_derives_it() {
    let out = check(&fixture("invalid/unknown-key.toml"));
    let text = stdout(&out);
    assert!(text.contains("'depends'"), "{text}");
    assert!(text.contains("factory derives"), "{text}");
}

#[test]
fn a_copied_verification_block_is_rejected_with_its_own_reason() {
    // The block is pipeline-written; a requester who copies it should be told
    // that, not given a generic unknown-key message.
    let out = check(&fixture("invalid/verification-block.toml"));
    let text = stdout(&out);
    assert!(text.contains("'verification'"), "{text}");
    assert!(text.contains("written by the pipeline"), "{text}");
}

#[test]
fn a_typosquat_names_the_package_it_resembles() {
    let out = check_against(&fixture("invalid/typosquat.toml"), &neighbours());
    let text = stdout(&out);
    assert!(
        text.contains("'ghosttty'") && text.contains("'ghostty'"),
        "{text}"
    );
}

#[test]
fn a_binary_surface_with_a_non_redistributable_license_is_told_to_use_recipe() {
    let out = check(&fixture("invalid/binary-nonredistributable.toml"));
    let text = stdout(&out);
    assert!(text.contains("rule 8"), "{text}");
    assert!(text.contains(r#"surface = "recipe""#), "{text}");
}

#[test]
fn a_vendor_source_requested_as_a_binary_is_rejected() {
    let out = check(&fixture("invalid/vendor-binary.toml"));
    let text = stdout(&out);
    assert!(text.contains("rule 10"), "{text}");
    assert!(text.contains("pinned checksum"), "{text}");
}

#[test]
fn a_malformed_request_reports_every_problem_in_one_pass() {
    // Not one round-trip per mistake.
    let out = check(&fixture("invalid/many-violations.toml"));
    let text = stdout(&out);
    let lines = text.lines().filter(|l| l.contains(".toml:")).count();
    assert!(
        lines >= 5,
        "expected several violations at once, got:\n{text}"
    );
    for expected in ["rule 1", "rule 3", "rule 9", "rule 11"] {
        assert!(text.contains(expected), "missing {expected} in:\n{text}");
    }
}

// --------------------------------------------------------- output discipline

#[test]
fn output_is_one_line_per_violation() {
    let out = check(&fixture("invalid/many-violations.toml"));
    let text = stdout(&out);
    for line in text.lines().filter(|l| !l.is_empty()) {
        assert!(
            line.contains(".toml:") || line.contains("valid."),
            "stray line that is not a violation: {line:?}"
        );
    }
}

#[test]
fn a_hostile_value_cannot_put_control_characters_into_the_output() {
    // The whole point of rule 11's fixture: the validator prints a report
    // about ESC and U+202E without ever emitting them.
    let out = check(&fixture("invalid/control-characters.toml"));
    let text = stdout(&out);

    assert!(text.contains("U+001B"), "{text}");
    assert!(text.contains("U+202E"), "{text}");

    for ch in text.chars() {
        let c = ch as u32;
        let is_newline = ch == '\n';
        assert!(
            is_newline || !(c < 0x20 || c == 0x7f),
            "raw control character U+{c:04X} reached stdout"
        );
        assert!(
            !matches!(c, 0x202A..=0x202E | 0x2066..=0x2069 | 0x200B..=0x200F),
            "raw bidi/zero-width character U+{c:04X} reached stdout"
        );
    }
}

#[test]
fn a_shell_metacharacter_name_is_reported_as_data() {
    // Nothing in the validator builds a command line; this asserts the value
    // is quoted and escaped on the way out rather than reproduced bare.
    let out = check(&fixture("invalid/shell-metacharacters.toml"));
    let text = stdout(&out);
    assert_eq!(code(&out), 1);
    assert!(text.contains("rule 3"), "{text}");
}

#[test]
fn json_output_is_parseable_and_carries_the_same_findings() {
    let out = run(&[
        "--catalogue",
        neighbours().to_str().unwrap(),
        "--format",
        "json",
        fixture("invalid/typosquat.toml").to_str().unwrap(),
    ]);
    let parsed: serde_json::Value = serde_json::from_str(&stdout(&out)).expect("valid JSON");
    assert_eq!(parsed[0]["valid"], serde_json::json!(false));
    assert_eq!(
        parsed[0]["violations"][0]["rule"],
        serde_json::json!("rule 5")
    );
    assert_eq!(
        parsed[0]["violations"][0]["field"],
        serde_json::json!("package.name")
    );
}

#[test]
fn quiet_prints_nothing_and_still_signals_through_the_exit_code() {
    let out = run(&[
        "--catalogue",
        neighbours().to_str().unwrap(),
        "--quiet",
        fixture("invalid/typosquat.toml").to_str().unwrap(),
    ]);
    assert_eq!(code(&out), 1);
    assert!(stdout(&out).is_empty());
}

#[test]
fn every_violation_carries_a_remedy() {
    // "invalid upstream" is a dead end for someone filing a first request.
    for name in [
        "unknown-key.toml",
        "binary-nonredistributable.toml",
        "vendor-binary.toml",
        "control-characters.toml",
        "many-violations.toml",
    ] {
        let out = check_against(&fixture("invalid").join(name), &neighbours());
        for line in stdout(&out).lines().filter(|l| l.contains(".toml:")) {
            assert!(
                line.contains(" — "),
                "violation has no remedy clause: {line}"
            );
        }
    }
}

// ------------------------------------------------------------ the mode split

#[test]
fn offline_mode_never_reports_rule_six() {
    // Rule 6 is the only networked rule. In the default mode it must not run,
    // including against a request whose upstream is plainly not a repo root.
    for name in [
        "vendor-binary.toml",
        "many-violations.toml",
        "typosquat.toml",
    ] {
        let out = check_against(&fixture("invalid").join(name), &neighbours());
        let text = stdout(&out);
        assert!(
            !text.contains("rule 6"),
            "{name} reported rule 6 without --resolve:\n{text}"
        );
    }
}

#[test]
fn offline_and_resolve_cannot_both_be_requested() {
    let out = run(&[
        "--offline",
        "--resolve",
        "--no-catalogue",
        fixture("valid/ghostty.toml").to_str().unwrap(),
    ]);
    assert_eq!(code(&out), 2);
}

#[test]
fn explicit_offline_matches_the_default() {
    let with = run(&[
        "--offline",
        "--catalogue",
        catalogue().to_str().unwrap(),
        fixture("invalid/many-violations.toml").to_str().unwrap(),
    ]);
    let without = check(&fixture("invalid/many-violations.toml"));
    assert_eq!(stdout(&with), stdout(&without));
}

#[test]
fn repeated_runs_produce_byte_identical_output() {
    // CI diffs this; unstable ordering would make every run look like a change.
    let first = stdout(&check(&fixture("invalid/many-violations.toml")));
    let second = stdout(&check(&fixture("invalid/many-violations.toml")));
    assert_eq!(first, second);
}

/// Rule 6 against the real internet. Ignored by default: the test suite must
/// not depend on what a third party serves today. The rule's logic is covered
/// by scripted responses in `src/net/resolve.rs`.
#[test]
#[ignore = "hits the network; run with --ignored"]
fn resolve_mode_checks_upstream_over_the_network() {
    let out = run(&[
        "--resolve",
        "--catalogue",
        catalogue().to_str().unwrap(),
        fixture("valid/ghostty.toml").to_str().unwrap(),
    ]);
    assert_eq!(code(&out), 0, "{}", stdout(&out));
}
