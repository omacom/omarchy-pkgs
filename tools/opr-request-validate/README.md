# opr-request-validate

Validates an OPR packaging request against `docs/request-schema.md`.

A request is the only artifact in this system written by someone outside the
project. This is the first and cheapest place a bad one stops.

```bash
opr-request-validate --catalogue catalogue.txt requests/ghostty.toml
```

Exit `0` if valid, `1` for violations, `2` if the validator could not run.
One line per violation, each naming the field and the rule:

```
requests/ghosttty.toml: rule 5: package.name: 'ghosttty' is one edit away from
the existing package 'ghostty', so it is held for typosquat review — if you
meant 'ghostty', it already exists and needs no request. [...]
```

## Two stages

| | rules | network |
|---|---|---|
| `--offline` (default) | 1-5, 7-11 | none |
| `--resolve` | the above, plus 6 | resolves `upstream` |

`--offline` is complete on its own, because the PR check runs with no network,
no secrets and no code execution. That is enforced by the type system rather
than by convention: an offline rule's `check` signature receives no HTTP
handle, so it cannot perform I/O and the compiler rejects any attempt to add
one. See `src/rules/mod.rs`.

Two further consequences of the same requirement:

- `jsonschema` is built with `default-features = false`. Its defaults enable
  `reqwest`, `resolve-http` and `resolve-file`, which would link a remote
  `$ref` resolver into the offline binary.
- The schema and the license allowlist are embedded with `include_str!`, so a
  locked-down runner has no relative path that can be wrong.

## Where each rule lives

Rules 1, 2, 3, 9, 10 and the length half of 11 are decided by
`schema/request.schema.json` — the structural checks are not reimplemented in
Rust, because two definitions of the format would drift. What *is* written by
hand is the translation from a schema error into a sentence a first-time
submitter can act on.

| Rule | Decided by |
|---|---|
| 1 `schema` version | schema (`const`) |
| 2 no unknown keys | schema (`additionalProperties: false`) |
| 3 name pattern and length | schema |
| 4 name collision | `rules/naming.rs` + `--catalogue` |
| 5 typosquat distance | `rules/naming.rs` + `--catalogue` |
| 6 upstream resolution | `net/resolve.rs`, `--resolve` only |
| 7 SPDX validity | `rules/license.rs` (`spdx` crate) |
| 8 redistributable | `rules/license.rs` + `data/redistributable.txt` |
| 9 architectures | schema |
| 10 vendor implies recipe | schema (`allOf` / `if` / `then`) |
| 11 length + control characters | schema (length) + `rules/text.rs` (characters) |

The binary refuses to start if the schema it loads has stopped saying
`"additionalProperties": false` on any object. Fail-closed-on-unknown-keys is
the invariant that stops the format growing by smuggling, it lives in one
keyword per object, and a future edit could otherwise drop one silently.

## Untrusted input

Every request value is hostile until proven otherwise. Nothing in this crate
builds a shell command, so there is no interpolation site to audit; what
remains is display safety, in `src/redact.rs`. Values reaching a message are
escaped (`\u{...}`), length-capped and delimited, so a value cannot forge an
output line, hide itself with terminal escapes, or reorder the text around it.
`tests/cli.rs` asserts that no raw control, bidi or zero-width character
reaches stdout even when the request is built to produce one.

## Where the implementation reads the spec

These are judgment calls, not decisions the document makes. Each is worth a
maintainer's eye before this merges.

1. **A vendor source is exempt from rule 6's repository-root requirement.**
   As written, rule 6 requires `upstream` to be a repository root — but the
   spec's own Surface B example, `requests/google-chrome.toml`, points at
   `https://dl.google.com/linux/chrome/deb`, which is not one and cannot be.
   Applying the rule literally rejects a request the document presents as
   valid. The exemption is keyed on `source.kind = "vendor"`; HTTPS,
   resolution and the off-host check still apply. **The alternative reading is
   that the example is wrong** and Surface B requests need some other identity
   anchor. That is a real design question, not an oversight to paper over.

2. **Rule 8's allowlist does not exist in the spec.** The rule names "the
   redistributable allowlist"; nothing defines its contents. `data/redistributable.txt`
   is a conservative proposal, reviewable as its own diff and overridable with
   `--redistributable`. Absence from it means *unreviewed*, not refused: the
   request is rejected with that reason and a maintainer can add the
   identifier. It is never silently downgraded to the recipe surface, per the
   spec's own instruction.

3. **Rule 4 needs the catalogue too**, not just rule 5 — it checks collision
   against "an existing OPR package or Arch `core`/`extra`". One `--catalogue`
   file serves both: distance 0 is rule 4, distance 1 is rule 5, so one
   mistake produces one diagnostic. If the intent was two lists — everything
   that exists for rule 4, a top-N popularity subset for rule 5 — that needs a
   second flag.

4. **A missing catalogue is a hard error**, not a silent skip. `--no-catalogue`
   exists for local runs and must be passed deliberately. A gate that reports
   success because it was misconfigured is worse than one that fails.

5. **Rule 5 fails the check** rather than only annotating it. The spec says the
   request "is flagged for typosquat review", which in a PR gate means the
   check stops and a human looks. If the intent was a passing check with a
   label, this should change.

6. **Structural errors the spec does not number** — a missing required key, a
   value of the wrong type — report as `structure` rather than under an
   invented rule 12.

7. **`upstream` failing the `^https://` pattern reports as `structure`, not
   rule 6.** Rule 6 lists HTTPS among its conditions, but reporting it as rule
   6 would mean rule 6 firing in offline mode and breaking the stated mode
   split. Rule 6 owns only the network-dependent assertions.

8. **Rule 5 is Levenshtein, as specified — so transpositions pass.**
   `ghotsty` is distance 2 from `ghostty` and clears the rule, though it is an
   obvious typosquat. Damerau-Levenshtein would catch it. Asserted as-is in
   `catalogue.rs` so a change is deliberate.

9. **"Off-host" is compared on the host**, not the registrable domain, so
   `github.com` → `pages.github.com` is reported. The one exemption is a
   `www.` prefix appearing or disappearing.

Also worth knowing: rule 6 accepts any path on a host it does not recognise.
Repository layout is only decidable for known forges (GitHub, GitLab,
Codeberg, SourceHut, Bitbucket) and for the bare-domain case, which is the
most common good-faith mistake. Self-hosted cgit or Gitea is passed through to
the factory rather than guessed at.

## Building

```bash
cargo build --release
```

For the PR runner, a static binary:

```bash
cargo build --release --target x86_64-unknown-linux-musl
```

`ureq` is configured with rustls rather than native-tls so the musl target
links without OpenSSL. (Not yet exercised in CI — see below.)

## In CI

```yaml
- run: |
    opr-request-validate \
      --catalogue catalogue.txt \
      $(git diff --name-only origin/master... -- 'requests/*.toml')
```

CI must always pass `--catalogue`. Generating that file — Arch `core`/`extra`
plus the current OPR catalogue — is not part of this crate.

## Tests

```bash
cargo test              # 112 tests, no network
cargo test -- --ignored # adds one test that resolves a real URL
```

Rule 6's redirect and host logic is tested against scripted responses through
the `Http` trait, not against the live internet: a suite that depends on what
a third party serves today is a suite that fails for reasons unrelated to the
code.

The offline guarantee can be checked directly rather than taken on trust
(macOS):

```bash
printf '(version 1)\n(allow default)\n(deny network*)\n' > /tmp/nonet.sb
sandbox-exec -f /tmp/nonet.sb opr-request-validate \
  --catalogue catalogue.txt requests/ghostty.toml     # passes
sandbox-exec -f /tmp/nonet.sb opr-request-validate \
  --resolve --catalogue catalogue.txt requests/ghostty.toml   # fails
```

The first must succeed and the second must fail. The pair is the actual
evidence: one shows offline needs no network, the other shows `--resolve`
genuinely uses it. Worth reproducing under `unshare -rn` on the Linux runner.
