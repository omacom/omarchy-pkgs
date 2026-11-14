# speakerguardd-v2

speakerguardd 1.0 (`1.0.0-alpha`), the in-graph speaker protection from the
`v2` branch of aurora-silicon/speakerguardd. It is a new program, not an
upgrade of the 0.1 daemon, so it is packaged under its own name and installs
beside the older daemons, speakerguardd 0.1 and speakersafetyd.

## Opt-in (release candidate 8)

Nothing in the default install pulls this package: aurora-audio requires only
speakersafetyd and speakerguardd 0.1, and replaces/conflicts only with the
retired preview builds (up to 1.0.0alpha.1-25). Installing it changes nothing
by itself. At every boot the fleet gate (`speakerguardd-gate`, the
`ExecCondition=` of every unit of both stacks) starts exactly one stack:

- on a kernel with only the legacy interface ("Speaker Volume Unlock"), the
  older daemons;
- on the dual-interface kernel (linux 98cb6a86 and later: "Speaker Protection
  Interface"), the older daemons unless `aurora-speaker-upgrade` has switched
  this Mac (`/var/lib/aurora-speaker-upgrade/interface` says `v2`) and the
  Mac's own tuning passed compilation, the macOS parity attestation and the
  wiring self-check; then v2;
- on a v2-only kernel (lab fleet kernels), v2 when qualified, else the
  kernel's floor.

There is no board list: qualification is derived from the Mac's own tuning,
device tree and self-check. `speakerguardd-gate explain` prints the decision.
aurora-speaker-upgrade ships disabled; `aurora-speaker-upgrade --check` is a
dry run that writes nothing.

## No manual steps

On a gated board, `speakerguardd-v2-provision.service` runs before the
self-check and the supervisor, which both require it:

- it compiles the installer's tuning bundle (`/lib/firmware/vendor/apple/audio-tuning`,
  or the ESP's vendorfw archive) into `/var/lib/speakerguardd/params.bin`;
- it binds the blob to the board, kernel, bundle, macOS build and compiler,
  and recompiles when one changes;
- it resolves the seat user by name, never by a fixed uid;
- it writes `/etc/speakerguardd/speakerguardd.conf`.

After the self-check passes, the machine's PipeWire and WirePlumber files are
generated into `/run/speakerguardd-graph`. The user unit
`speakerguardd-v2-graph.service` links them for the seat user only.
`speakerguardd-v2-seat.path` provisions again when another user takes
seat0. Any failure fails closed: the supervisor does not start, the kernel's
floor holds, and the journal says why.

Overrides, all optional, go in `/etc/speakerguardd/provision.conf`:
`SGV2_SEAT_USER=<name>` and `SGV2_BUNDLE=<path>`.

## What it installs

| Path | What |
|---|---|
| `speakerguardd-v2/` under `/usr/libexec` (Fedora), `/usr/lib` (Arch) or `libexec` (Nix) | The supervisor, `speakerguardd-provision`, `speakerguardd-gate`, `speakerguardd-selfcheck`, `speakerguardd-session` |
| `speakerguardd-v2{,-provision,-selfcheck,-seat}.service`, `speakerguardd-v2-seat.path` | The upstream units, renamed and enabled, each one gated |
| `speakerguardd-v2-session.service`, `speakerguardd-v2-graph.service` (user units) | The session helper, and the seat user's graph links |
| `60-speakerguardd-v2-gate.conf` in `speakersafetyd.service.d` and `speakerguardd.service.d` | The gate on the older daemons' units |
| `sgv2.lv2` in the distribution's LV2 directory | The protection unit for the PipeWire filter-chain |
| `aurora-speaker-tuning` | Reader, validator and compiler for the Mac's own tuning bundle |
| `/usr/share/speakerguardd/` | `gate.json` and the reference graphs |
| SELinux module `speakerguardd` (Fedora) | Upstream's policy: `speakerguardd_t`, with the program, `/run/speakerguardd` and `/var/lib/speakerguardd` labelled |

## Rollback

| | Back to the older daemons |
|---|---|
| Any distribution, dual kernel | `aurora-speaker-upgrade --revert`: the setting goes, the kernel returns to "Speaker Volume Unlock" and the older daemons take the speakers |
| Any distribution | `pacman -R speakerguardd-v2`: its gate drop-ins go with it and the older daemons run as before |

The older daemons stay installed throughout, so the rollback needs no
download.

## Source

The pin is a commit on the `v2` branch. Bump it as the lanes merge there.
`aurora-speaker-tuning` is based on aurora-audio-dsp by saku (MIT); its
notice is installed with the licence.
