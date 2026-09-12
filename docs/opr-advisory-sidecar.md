# OPR advisory sidecar (omacom/omarchy-pkgs#378)

Arch covers distro packages (`arch-audit` / Arch Security Tracker).
OPR-built packages are silent there. The sidecar answers, for each
**published OPR version**, which known CVEs apply and how fresh that
answer is — without rebuilding the package.

This is OPR-published metadata, not a maintainer score in the PKGBUILD.

## What it is

A sidecar beside the pacman database, per channel/arch:

- `pkgs.omarchy.org/<channel>/<arch>/omarchy.advisories.json`
- `pkgs.omarchy.org/<channel>/<arch>/omarchy.advisories.json.sig`

Entries are keyed by package name and pin the scanned version:

```json
{
  "schema": 1, "channel": "edge", "arch": "x86_64",
  "generated_at": "2026-09-11T00:00:00Z",
  "advisories": {
    "mise-bin": {
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
  }
}
```

### Field contract (v1)

- `cve_ids`: array of CVE IDs applying to this published version.
- `cve_max_severity` + `severity_scale`: worst severity and the scale it
  is measured on (`CVSSv3`, or a named distro mapping). A severity
  without a scale is a feed bug (`scan_status=error`).
- `advisory_as_of`: when the CVE data was current at the source.
- `scanned_at`: when OPR ingest wrote this entry.
- `scan_source`: feed the report came from (`osv.dev` preferred;
  NVD/vendor feeds map onto the same fields).
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
- The sidecar is **independently signed** with the same OPR repo key
  that signs packages (detached `.sig`, like the database). `sync-repo`
  already publishes it: the package upload passes everything except
  `omarchy.db*`/`omarchy.files*`, and the database upload covers
  `omarchy.*`, which includes the sidecar and its signature.
- "Trusted partner" writers are explicitly later: named org + key +
  audit log + revocation, or nothing.

## Refresh without rebuild

```bash
# Refresh one channel/arch from an OPR-operated feed dir:
bin/sync-advisories --mirror edge --arch x86_64 --feed ./advisories-feed

# First milestone demo (mise-bin):
bin/sync-advisories --mirror edge --arch x86_64 --package mise-bin --feed ./feed --no-sign
# ... new CVE lands in ./feed/mise-bin.json ...
bin/sync-advisories --mirror edge --arch x86_64 --package mise-bin --feed ./feed --no-sign
# The sidecar changed; every .pkg.tar.zst kept its bytes.
```

Feed input is one JSON file per package (`<feed>/<pkgname>.json`)
with `cve_ids`, `cve_max_severity`, `severity_scale`,
`advisory_as_of`, `scan_source`, and optional `note`. A missing file
is `missing`, not an error. `bin/sync-advisories --dry-run` previews
without writing.

`bin/repo advisories` forwards to the repository host like the other
published-tree commands (`--local` forces local execution).

## Missing / stale policy

Missing and stale are first-class, not edge cases:

- `missing`: never scanned. Visible, fail-open (warn, do not block).
- `stale`: `advisory_as_of` older than `--stale-after` (default 72h).
  Visible, fail-open.
- `error`: feed unparseable, unreadable timestamp, or severity
  without a scale. Visible, fail-open, needs OPR triage.
- `ok`: fresh scan, even when `cve_ids` is non-empty. A known CVE is
  information, not a build failure.

Default for v1 is **visible + warn; unknown does not block**. Policy
files on the client may opt into fail-closed; that policy lives with
the client (see `HxHippy/omarchy-resolve#1`), never here. Pacman
remains the authority on what is installed.

## Channel movement

`bin/repo advance` carries advisory entries forward with the packages
they describe (edge → rc → stable, `--arch` per architecture):
entries for moved packages are merged into the destination sidecar,
and the destination database remains the authority on which versions
exist. A version that advance did not move keeps its old entry until
the next ingest refresh marks it missing/stale.
