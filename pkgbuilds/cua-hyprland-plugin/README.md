# Optional Cua Hyprland plugin

This package targets **Omarchy stable x86_64**, with Inkscape `1.4.4-6` and
two independent background-input lanes. Cua's native qualification is recorded
in [the kit's qualification record](https://github.com/trycua/cua/releases/download/cua-hyprland-kit-v1.1.0-omarchy-stable-20260910/QUALIFICATION.md)
and [Cua #3698](https://github.com/trycua/cua/pull/3698). Omabot replay and
Omarchy's explicit merge, signing, and publication decisions remain required.
Keep `skip_build: true` until those gates pass.

The plugin is optional. Cua Driver works independently, and installation does
not load the plugin or enable input. Metadata restricts the initial destination
to `channels: ["stable"]`; `release_ring: fast` permits a native package build.
Edge, RC, and ARM publication are outside this initial scope.

## Source and build profile

The package uses the [Driver 0.26.1 plugin source](https://github.com/trycua/cua/releases/tag/cua-driver-rs-v0.26.1),
including the [desktop-fault cleanup repair](https://github.com/trycua/cua/pull/3702).
It is not a repackaging of the unmodified 0.24.0 plugin. The Driver client
pairing qualified for this package remains `cua-driver-bin 0.24.0-1`, with
input protocol v3. Discovery protocol v2 is separate.

Profile `omarchy-stable-20260910`, kit `1.1.0`, and package release `2` pin:

- Hyprland `0.56.2-2`, headers `0.56.2`, and measured executable/header hashes.
- GCC `16.2.1 20260810`, including compiler bytes and emitted ELF identity.
- Shared runtime `libstdc++.so.6.0.36`, its bytes, and exact ABI package versions.

The generated `PKGBUILD` identifies the immutable kit download, outer checksum,
and member checksums. The kit records the full source and tooling revisions,
profile digest, and source archive/manifest digests. Do not infer compatibility
from a matching version label or substitute an unreviewed profile.

The download wrapper verifies its complete inventory before executing downloaded
tooling. It preserves the source archive and its historical embedded verifier,
but explicitly uses the new kit's `profile_verify.py`. Source integrity,
package-owned headers, pkg-config selection, compiler probes, runtime equality,
and production flags remain mandatory. Packaging runs all bundled CTests even
with `--nocheck` or `--repackage`; `--skipinteg` does not bypass recipe checks.
Production input is built in; experimental signed input and tracing are off.

## What is qualified

The initial app scope is native Wayland Inkscape `1.4.4-6` with the canonical
US keymap. Two lanes require independent Driver processes and distinct native
application clients, not merely two windows. This is concurrency inside one
desktop account, not multi-user or mutually untrusted-agent isolation.

Cua's retained evidence covers background application effects, two-lane overlap,
third-owner refusal, primary-input preservation, conflicts, stale targets and
geometry, cancellation, desktop faults, recovery, and cold package transitions.
Production-package app checks and independent primary observers are separate
from trace-enabled diagnostics. Cua's retained canonical run
`433ce968ee164d5e8e3226e800db93a6` recorded all 128 required cells: 87
deliveries and 41 expected refusals, with no failures or skips; its completion
report has SHA-256
`1eda4cc008ea6b27d96c21d58f8041834398a43409642376bafe84ad38f0e112`.
That run used source-built released Driver 0.24.0; the real-app checks
separately used the actual Omarchy `cua-driver-bin 0.24.0-1` executable. A
separate later Omabot replay reported 124 passes and four failures, plus seven
incomplete native cases, so Omarchy replay remains an explicit merge gate. See
the linked qualification record for exact artifacts and observation limits.

Duplicate motion notifications are retained and counted. They are acceptable
only when pointer identity, coordinates, focus, held input, and foreground
interaction remain unchanged. Actual motion—including moving away and back—
fails isolation. After cancellation, an inert agent pointer may remain parked
if held input is released and authority is revoked.

Current LibreOffice Calc `26.8`, Chromium/Electron raw background input,
XWayland, Unicode/IME, non-US layouts, and modified pointer gestures are outside
this profile. The plugin does not widen Driver's application admission.
Foreground input, capture, and accessibility have separate contracts; a
background refusal never authorizes a hidden foreground fallback or unlock.

## Omabot replay before merge

Use the unsigned, explicitly scoped build command:

```sh
bin/repo build --package cua-hyprland-plugin --arch x86_64 --mirror stable
```

In a fresh worker matching the reviewed profile:

1. Verify the downloaded kit and source identities against the reviewed recipe.
   Record the actual channel snapshot, Driver, compiler, compositor, runtime,
   applications, keymap, and resulting package/module hashes.
2. Require all bundled tests and native compatibility checks. Do not weaken
   exact dependencies or replace the compositor to make the build pass.
3. Install through pacman and activate in a fresh session. Replay the declared
   app, two-lane, refusal, primary-input, cancellation, and fault/recovery checks
   against the actual packaged Driver and module. A Cua Fleet result is not an
   Omabot result; matching source alone does not certify different binaries.
4. Verify restart-based upgrade, rollback, removal, and reinstallation. Retain
   evidence that binds each result to the package and mapped module bytes.

Portable tests, screenshots, health reports, and a successful build do not
replace native qualification. Recheck the published Driver package before
rollout and qualify any changed pairing explicitly.

## Activation, updates, and removal

The package installs the module at
`/usr/lib/cua/hyprland/cua-hyprland-plugin.so` and provenance plus the consumer
verifier under `/usr/share/cua-hyprland-plugin/`. There are no hooks, autoloading,
configuration edits, or hot replacement.

Save your work and exit Hyprland before installing, replacing, or removing the
package. Install the exact reviewed package from a text console, then start a
fresh session. Before loading, run the consumer check with the independently
reviewed kit-provenance digest from the qualification record:

```sh
python3 /usr/share/cua-hyprland-plugin/profile_verify.py \
  --kit /usr/share/cua-hyprland-plugin \
  --kit-sha256 7beb736adfd334eed52e84070177634269e3a09f8bb25971b38606933ff4c997 \
  --consumer /usr/lib/cua/hyprland/cua-hyprland-plugin.so
```

This check requires Python 3.11+, binutils `readelf`, and system `ldd`/`pacman`,
not a compiler or headers. If it fails, leave the plugin unloaded. It verifies
installed compatibility, not runtime mapping or input effects.

After that check passes in the fresh session, load the module explicitly:

```sh
hyprctl plugin load /usr/lib/cua/hyprland/cua-hyprland-plugin.so
hyprctl -j cua:status
```

Loading alone does not enable input. Before opting in, save open work and save
the exact current personal input configuration. The backup command refuses a
symlinked input file and refuses to replace an earlier backup:

```sh
test -f "$HOME/.config/hypr/input.lua" && \
  test ! -L "$HOME/.config/hypr/input.lua" && \
  test ! -e "$HOME/.config/hypr/input.lua.cua-before" && \
  cp --archive -- "$HOME/.config/hypr/input.lua" \
    "$HOME/.config/hypr/input.lua.cua-before"
```

If `input.lua` is a symlink, stop here: back up and later restore its resolved
target explicitly instead of using the commands below.

The background-input admission guard requires the exact XKB keymap
`rules=evdev`, `model=pc105`, `layout=us`, empty variant and options, and no
custom keymap file. Stock Omarchy 4.0.3 English (US) is not that literal
configuration: it leaves rules and model empty and sets
`compose:caps,shift:both_capslock_cancel`. Those options make Caps Lock the
Compose key and both Shift keys the Caps Lock/cancel chord. The required empty
options restore ordinary Caps Lock behavior and remove both stock shortcuts
while Cua input is enabled. Any other effective value is intentionally refused
as `unsupported_layout`; do not weaken or bypass that admission guard.

Append this override to `~/.config/hypr/input.lua` so it follows any existing
input settings. It both selects the exact admitted keymap and enables the
trusted local transport:

```lua
hl.config({
  input = {
    kb_rules = "evdev",
    kb_model = "pc105",
    kb_layout = "us",
    kb_variant = "",
    kb_options = "",
    kb_file = "",
  },
  plugin = { cua = { enabled = true } },
})
```

Reload, then read back every keymap value rather than relying on the source
file alone:

```sh
hyprctl reload
for name in kb_rules kb_model kb_layout kb_variant kb_options kb_file; do
  value=$(hyprctl -j getoption "input:$name" | jq -r '.str')
  printf '%s=%s\n' "$name" "$value"
done
hyprctl -j cua:status
```

The keymap readback must be exactly:

```text
kb_rules=evdev
kb_model=pc105
kb_layout=us
kb_variant=
kb_options=
kb_file=
```

A runtime keyword or Lua evaluation without `hyprctl reload` does not reconcile
the input sockets. Continue only when status also reports input protocol v3,
input capability, socket paths, and the expected compositor identity. Do not
disable NumLock; that was required only by a strict qualification observer, not
by the demonstrated background-input contract.

Start Driver with `CUA_DRIVER_RS_ENABLE_WAYLAND=1`. For the activation check,
use background input in a new disposable Inkscape document to create a text
object containing `CUA activation check`. Save it under a new temporary
filename, then verify the text in both a fresh Driver snapshot and the reopened
saved SVG. Never test against an existing document, and do not automatically
replay an action with a partial or unknown outcome.

After the check, restore the exact saved configuration and reload it:

```sh
command mv --force -- "$HOME/.config/hypr/input.lua.cua-before" \
  "$HOME/.config/hypr/input.lua"
hyprctl reload
hyprctl -j cua:status
```

Confirm that the prior keymap values are back and status reports input disabled.
Retained inert agent pointers can remain until the compositor exits; disabling
input does not unload the mapped module. If you intentionally keep activation,
retain the backup until you are ready to perform this exact restoration.

Before an incompatible desktop update, remove operator-added plugin activation
settings, save work, and exit the graphical session. From a text console, run
`sudo pacman -R cua-hyprland-plugin`, then apply the normal desktop update and
verify a fresh session without the plugin. Declining removal preserves the
dependency refusal. Disabling input alone leaves exact dependencies installed;
do not force an upgrade past them.

Retain the previous package with its matching compositor, runtime, Driver, and
provenance as a rollback set. Restore a consistent set outside the graphical
session, then repeat the fresh-session consumer and app checks. Do not hot
unload/reload or replace a mapped module.

## Ownership and publication

The [agreed ownership split](https://github.com/omacom/omarchy-pkgs/pull/346#issuecomment-5612834061)
assigns profiles, build kits, plugin fixes, and native input evidence to Cua.
Francesco (@f-trycua) is the Cua contact through this PR. Omarchy owns package
integration, dependency-change detection, Omabot validation, and signing and
publication decisions. Omarchy must name its package/release owner before
rollout. Maintenance is best effort, with no turnaround commitment.

Edge detects upcoming incompatibilities; RC validates the intended stable
environment. Mirror/channel changes and changes to ABI dependencies, Driver,
or admitted apps request a new candidate and affected qualification. They do
not establish compatibility or authorize additional publication channels.

`skip_build` controls selection, not publication authority. This package has no
upstream polling, AUR synchronization, or automatic rebuild bump. After replay
and explicit merge approval, the named Omarchy owner must deliberately sign
and publish the validated bytes. `bin/repo release` rebuilds before publication;
`push` and `upload-prebuilt` also publish. None supplies native qualification.
Do not silently substitute newly rebuilt bytes during signing/publication.

Finally, install the signed published package on a fresh consumer, verify its
signature and package/module digests, and perform a short activation,
background-action, and cleanup smoke. Broader channels or unattended publishing
require an enforced artifact-to-evidence gate, including prebuilt uploads.
