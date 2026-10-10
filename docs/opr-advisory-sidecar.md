# OPR advisory sidecar (omacom/omarchy-pkgs#378)

Arch covers distro packages (`arch-audit` / Arch Security Tracker).
OPR-built packages are silent there. The sidecar answers, for each
**published OPR version**, which known CVEs apply and how fresh that
answer is — without rebuilding the package.

This is OPR-published metadata, not a maintainer score in the PKGBUILD.
OPR does **not** scan package bits. It **ingests CVE records from
existing sources** (OSV first; NVD or a vendor feed can map onto the
same fields). If a version hits OPR before those sources know it, the
row stays `missing` until a later refresh finds a report. That is
expected, not a hole in this pipeline.

Risk facets of the code itself (opens ports, filesystem, privilege)
are out of scope here. If those ever exist they belong in a **separate
application and repository**, not in omarchy-pkgs.

## What it is

One signed file per published artifact, beside that package archive:

- `pkgs.omarchy.org/<channel>/<arch>/<pkgname>-<pkgver>-<pkgrel>-<arch>.advisory.json`
- `pkgs.omarchy.org/<channel>/<arch>/<pkgname>-<pkgver>-<pkgrel>-<arch>.advisory.json.sig`

The filename is the key, so two published versions cannot clobber each
other. A new package adds one file. A refresh replaces that file and
leaves every other advisory file alone. A missing file means
`scan_status=missing`. A feed for another version does not stamp the
live package.

```json
{
  "schema": 1,
  "pkgname": "mise-bin",
  "pkgver": "2026.9.1", "pkgrel": "1", "arch": "x86_64",
  "artifact": "mise-bin-2026.9.1-1-x86_64.pkg.tar.zst",
  "cve_ids": ["CVE-2026-12345"],
  "cve_max_severity": "HIGH", "severity_scale": "CVSSv3",
  "advisory_as_of": "2026-09-10T00:00:00Z",
  "scanned_at": "2026-09-11T00:00:00Z",
  "scan_source": "osv.dev",
  "scan_status": "ok",
  "note": ""
}
```

### Field contract (v1)

- `cve_ids`: array of CVE IDs applying to this published version.
- `cve_max_severity` + `severity_scale`: worst severity and the scale it
  is measured on (`CVSSv3`, or a named distro mapping). A severity
  without a scale is a feed bug (`scan_status=error`).
- `advisory_as_of`: when the CVE data was current at the source.
- `scanned_at`: when the producer queried the source (copied through
  ingest when present; otherwise when ingest wrote the row).
- `scan_source`: which existing CVE source the report came from
  (`osv.dev` preferred). Not an OPR scanner.
- `scan_status`: `ok` | `stale` | `missing` | `error`.

There is deliberately **no** composite `safety_score` and **no**
capability tags (ports / fs / priv) in v1. A UI that needs a color
derives it client-side from `cve_max_severity` + `scan_status` and
labels it "advisories", not "safety".

This does not reuse the resolver's `trust` tier: `trust` answers who
owns a route when it breaks; the sidecar answers which holes are known
in this version and how fresh the scan is. Scanning applies only to
OPR `built-here` artifacts — the resolver must not print an OPR
advisory band for brew/flatpak/apt routes.

## Writer and signing

- Writer is **OPR-operated ingest only** (`bin/sync-advisories`).
  Maintainers are never the writers; CVE data lives outside
  `.omarchy/package.json` and the PKGBUILD precisely so it can refresh
  when the feed moves even if the bits did not.
- Each advisory file is **independently signed** with the same OPR repo
  key that signs packages (detached `.sig`). `bin/publish-artifact` uploads
  that file when it is sitting beside the package. `bin/sync-repo` uploads
  advisory files with checksums, so a refresh replaces the remote copy.
  The package upload does not overwrite them. `bin/promote-build`,
  `bin/advance-channel`, `bin/remove-package`, and `bin/clean-repo` carry
  or delete the advisory with the package. There is no channel-wide
  document.
- "Trusted partner" writers are explicitly later: named org + key +
  audit log + revocation, or nothing.

## Refresh without rebuild

```bash
# Produce a versioned feed from OSV, then ingest it:
bin/fetch-advisories --mirror edge --arch x86_64 --package mise-bin --feed ./advisories-feed
bin/sync-advisories --mirror edge --arch x86_64 --feed ./advisories-feed

# Refresh one channel/arch from an OPR-operated feed dir:
bin/sync-advisories --mirror edge --arch x86_64 --feed ./advisories-feed

# First milestone demo (mise-bin):
bin/sync-advisories --mirror edge --arch x86_64 --package mise-bin --feed ./feed --no-sign
# ... new CVE lands in ./feed/mise-bin/<pkgver>-<pkgrel>/x86_64.json ...
bin/sync-advisories --mirror edge --arch x86_64 --package mise-bin --feed ./feed --no-sign
# The sidecar changed; every .pkg.tar.zst kept its bytes.
```

Feed input is one JSON file per published artifact
(`<feed>/<pkgname>/<pkgver>-<pkgrel>/<arch>.json`) with `pkgname`,
`pkgver`, `pkgrel`, `arch`, `cve_ids`, `cve_max_severity`,
`severity_scale`, `advisory_as_of`, `scan_source`, and optional `note`.
A missing file is `missing`, not an error. A file for another version
is ignored for the live package. `bin/sync-advisories --dry-run`
previews without writing.

`bin/repo advisories` forwards to the repository host like the other
published-tree commands (`--local` forces local execution).

## Missing / stale policy

Missing and stale are first-class, not edge cases:

- `missing`: no existing source has a report for this published
  version yet (common when OPR ships first). Visible, fail-open
  (warn, do not block).
- `stale`: `advisory_as_of` older than `--stale-after` (default 72h).
  Visible, fail-open.
- `error`: feed unparseable, unreadable timestamp, or severity
  without a scale. Visible, fail-open, needs OPR triage.
- `ok`: a fresh report from the source, even when `cve_ids` is
  non-empty. A known CVE is information, not a build failure.

Default for v1 is **visible + warn; unknown does not block**. Policy
files on the client may opt into fail-closed; that policy lives with
the client (see `HxHippy/omarchy-resolve#1`), never here. Pacman
remains the authority on what is installed.

## Channel movement

When an artifact is copied to another channel, its advisory file is
copied with it. There is no merged channel document, and this does not
add new advance behavior beyond that copy. A version that did not move
keeps the advisory file it already has.
