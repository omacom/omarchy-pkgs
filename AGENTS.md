# Instructions for agents

Read README.md first: how a package reaches users, the publish rules and
the layout. For writing and shell style, follow the `AGENTS.md` of
omacom/omarchy.

## Signing keys

- Builds never fetch PGP keys. No `gpg --recv-keys`, `--receive-keys`,
  `--locate-keys` or key download in `build/`, `bin/build`, `helpers/`,
  the workflows that build, or a PKGBUILD. On 11 November 2026
  keyserver.ubuntu.com went down and such a lookup, with no timeout, held
  every builder for two hours.
- Every fingerprint in a recipe's `validpgpkeys` ships as
  `pkgbuilds/<package>/keys/pgp/<FINGERPRINT>.asc`, with that fingerprint
  inside. `tests/pgp-keys-vendored.sh` fails otherwise.
- Take a new key from its owner (their site or WKD) and check the
  fingerprint against what upstream publishes. Never trust a key because a
  keyserver returned it.
- `bin/refresh-pgp-keys` is the one place that reads keyservers and WKD,
  outside any build. `refresh-pgp-keys.yml` runs it daily. Commit what it
  changes in a PR of its own; a revoked key stays revoked in the file, so
  makepkg refuses its signatures.
- The builder image takes Omarchy's own repository key from Omarchy's WKD
  and exports only the pinned fingerprint (`build/Dockerfile`).

## Tooling and packages

- PR CI runs build tooling from `master` and takes only `pkgbuilds/` from
  the PR. A change to `build/`, `bin/` or `helpers/` is proven by running it
  locally (`bin/build --package <name>`), not by the PR's own builds.
- A recipe change does not rebuild without a `pkgver` or `pkgrel` bump.
- A non-draft PR that only touches `pkgbuilds/` merges and publishes itself
  once green. Open it as a draft to keep control.
