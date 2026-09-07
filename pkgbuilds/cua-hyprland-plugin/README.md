# Optional Cua Hyprland plugin

This package builds the optional Cua input plugin separately from Cua Driver.
It does not add the plugin to the Omarchy installation or change the Driver
package. The recipe is copied unchanged from the published Cua Driver 0.24.0
build kit, including its source checks, mandatory tests, and ABI checks.

The package is in the fast release ring with `skip_build: true`. This keeps it
out of unscoped builds while maintainers qualify the pinned environment.
An explicit package build remains available. Fast-ring membership does not
establish compatibility: edge, rc, and stable use separate build environments,
and each must satisfy the exact contract before publication there.

## Source and ABI contract

The authoritative release is
[cua-driver-rs-v0.24.0](https://github.com/trycua/cua/releases/tag/cua-driver-rs-v0.24.0),
at source revision `4b3396d9fe4bd3cf723b0eb8db83c18a8764b520`.
Both archives use the stem
`cua-hyprland-plugin-0.24.0-4b3396d9fe4bd3cf723b0eb8db83c18a8764b520`.
The release's `checksums.txt` records these SHA-256 values:

| Artifact | SHA-256 |
| --- | --- |
| Source (`.tar.gz`) | `73b65823b3281c027a31cd8f7d9ca9586fe7386ed1eec74174f2e72cea0af643` |
| Build kit (`-build-kit.tar.gz`) | `f91a7b61a39f0efdcee9558eb6725fe864340e8eacf940346499222afe7f7869` |

The supported environment is Linux x86_64, `hyprland=0.56.2-1`, headers
`0.56.2`, GCC `16.1.1 20260728`, and shared `libstdc++.so.6.0.36`.
The compiler probe and compositor must carry the exact GCC ELF comment; the
compiler, compositor, and module must resolve identical runtime bytes. The
recipe rejects mismatches. `gcc-libs` alone is not proof of runtime compatibility.
There is no qualified ARM build.

Production input is enabled at build time. Experimental signed input and
tracing are disabled. Source and build provenance are installed with the module.
The build requires CMake 3.30 or later and Python 3.11 or later. The default
compiler is `/usr/bin/g++`; an absolute `CUA_RELEASE_CXX` path can select an
already provisioned matching compiler without bypassing runtime checks.
The package does not provision a compiler or change runtime search paths.

## Review and qualify

Download both archives and `checksums.txt` from the exact release. Verify the
archive hashes before extracting the kit, then verify its `SHA256SUMS` with the
source archive alongside it. Compare this package's `PKGBUILD` byte for byte
with the kit's recipe. Follow the kit's operator README and
[release packaging instructions](https://github.com/trycua/cua/blob/4b3396d9fe4bd3cf723b0eb8db83c18a8764b520/libs/cua-driver/hyprland-plugin/packaging/release/README.md).

Before enabling scheduled builds or publishing a package, maintainers need:

1. A native build in each intended channel's pinned x86_64 environment, with
   all bundled tests passing and the packaged ELF dependencies and provenance
   inspected. An unsigned, explicitly scoped repository build is
   `bin/repo build --package cua-hyprland-plugin --arch x86_64 --mirror edge`.
   Repeat with the intended channel only when its environment matches.
2. The kit's `lifecycle.py` gate in a disposable pinned Arch environment,
   including installation, removal, reinstallation, and refusal with a different
   Hyprland package. That gate uses isolated ALPM roots and metadata dependency
   fixtures; it does not prove live activation.
3. Fresh-session activation and representative supported input, then upgrade,
   rollback, and removal across compositor restarts. Retain evidence for the
   exact package, source revision, compositor, compiler, and runtime.

Static review and download verification do not establish these native results.
The source manifest's `native_certified: false` describes the generator's
scope; separate native evidence must establish runtime qualification.

## Update policy

Updates are explicit maintainer changes. There is no upstream polling hook,
AUR synchronization, or automatic `rebuild_on` bump. Do not use Omarchy's
`pinned` metadata flag here: it controls the Omarchy release pair's rc branch
workflow, not native ABI compatibility.

For an update, select an exact Cua Driver component tag, download its matching
source and build kit, verify published checksums, and review the recipe and
manifest together. Replace the recipe and update this record only after reviewing
the new ABI contract. A Driver release alone does not qualify its plugin for
a changed compositor. Keep `skip_build` enabled until the required channel
evidence is available; removing it is a separate publication decision.

Do not widen the Hyprland dependency or remove compiler/runtime checks to
accommodate channel drift. If a channel cannot provide the pins, keep the
plugin unavailable there and use Driver without this plugin. An installed
plugin's exact dependency can block a compositor upgrade; remove the plugin
using the restart procedure before moving to an incompatible environment.

## Activation and removal

The package installs only the module, license, and provenance. It has no install
hooks, autoloading, configuration edits, or hot replacement. Follow the
[pinned operator guide](https://github.com/trycua/cua/blob/4b3396d9fe4bd3cf723b0eb8db83c18a8764b520/libs/cua-driver/hyprland-plugin/packaging/release/USAGE.md)
for deliberate loading, input enablement, status checks, and supported apps.
Loading the module alone does not enable its input transport.

Before installing or upgrading, save your work and exit Hyprland. Install from
a text console, start a fresh session, and deliberately activate and verify the
module. Keep the prior package and its matching environment for rollback.
Before removal, remove any operator-added load and enable settings, exit
Hyprland, and remove the package from a text console. Start a fresh session
afterward. Upgrade, rollback, and removal require compositor restart; do not
hot-unload/reload the module or force installation past its dependency pin.
