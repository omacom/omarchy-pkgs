# Optional Cua Hyprland plugin

This package targets **Omarchy x86_64**, with Inkscape `1.4.4-6` and two independent background-input lanes. Release `6` is an edge candidate for Aquamarine `0.15.1-1`; it retains the keyboard-remap patch introduced in release `5`, which includes the Omarchy patch for independent agent keymaps, operation-specific foreground checks, and compatible Num Lock state; the upstream native qualification below covers the unpatched source, not this change. Cua's native qualification is recorded in [the kit's qualification record](https://github.com/trycua/cua/releases/download/cua-hyprland-kit-v1.1.0-omarchy-stable-20260910/QUALIFICATION.md) and [Cua #3698](https://github.com/trycua/cua/pull/3698). Omabot replay and Omarchy's merge decision are recorded in [omarchy-pkgs #346](https://github.com/omacom/omarchy-pkgs/pull/346). Scheduling the recipe does not expand the qualified stable target.

The plugin is optional. Cua Driver works independently, and installation does not load the plugin or enable input. The package follows the normal edge-to-RC-to-stable promotion path instead of the fast release ring. Its PKGBUILD limits builds to x86_64. The upstream qualification covers the original stable profile; the updated Aquamarine profile needs its own Omabot validation before promotion.

## Source and build profile

The package uses the [Driver 0.26.1 plugin source](https://github.com/trycua/cua/releases/tag/cua-driver-rs-v0.26.1),
including the [desktop-fault cleanup repair](https://github.com/trycua/cua/pull/3702).
It is not a repackaging of the unmodified 0.24.0 plugin.

The qualified upstream Driver pairing is `cua-driver-bin 0.27.0-1`, with input protocol v3. Driver 0.27.0 contains the bounded stale-geometry retry validated with the upstream module; its production plugin source is the base for the downstream patch used here. Discovery protocol v2 is separate. A newer Driver release is a changed pairing and requires affected replay before promotion.

Profile `omarchy-hypr0562r3-aq0151-remaps`, kit tooling `1.1.0`, and package release `6` pin:

- Hyprland `0.56.2-3`, headers `0.56.2`, and measured executable/header hashes.
- GCC `16.2.1 20260810`, including compiler bytes and emitted ELF identity.
- Shared runtime `libstdc++.so.6.0.36`, its bytes, and exact ABI package versions, including Aquamarine `0.15.1-1`.

This profile derives from Cua's `omarchy-stable-20260910` profile. Arch's
Hyprland `-3` package splits out `hyprpm` and changes package dependencies;
its compositor executable and all 498 header/pkg-config files are byte-identical
to `-2`. Both executables have SHA-256
`da8fcacf347bcbed83edc40108c6e2298da095e22246bd764e9bb382786cebb2`.
The checked-in `PROFILE.json` changes only the profile name, package release, and exact Hyprland and Aquamarine package versions. Compiler, libstdc++ runtime, upstream source, compositor executable, and header identities remain unchanged; the separately recorded patch changes the build source. The download wrapper verifies the
original kit before deriving the updated profile, recipe, and provenance,
then verifies every derived member against its recorded digest.

The native qualification below was recorded with package release `2` and
Hyprland `-2`. The downstream keymap change and Aquamarine update need their own application and Driver replay before promotion. Hyprland `0.56.2-3` and Aquamarine `0.15.1-1` must both reach a destination channel before this artifact can be installed there; publication still follows edge → RC → stable.

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

The pristine upstream archive, manifest, and verifier remain unchanged. `independent-keymaps.patch` is applied to a separate source tree, and `DOWNSTREAM-PROVENANCE.json` pins the patch and every resulting source file. Build, check, and package revalidate both trees, including when makepkg integrity checks are skipped. `BUILD-PROVENANCE.json` records the upstream base under `source`, the applied change under `downstream`, and the final module digest; the downstream manifest and patch are installed beside it. This preserves the existing compiler, headers, runtime, and consumer checks without representing the modified module as an unmodified upstream build.

## Aquamarine dependency refresh

Release `5` required Aquamarine `0.15.0-2`. When the edge mirror moved to `0.15.1-1`, pacman could no longer resolve that dependency, even after a full database refresh. Release `6` derives a new profile from the same verified upstream kit and pins `0.15.1-1` in both the package dependencies and the installed compatibility verifier. Source, patch, compiler, compositor, headers, and libstdc++ hashes remain pinned; the original upstream qualification does not establish compatibility with the changed Aquamarine package.

A package release bump alone cannot repair future dependency drift: the checked-in profile and derived kit checksums must agree with the new environment, and affected native checks must pass before publication. Do not remove exact dependencies or selectively downgrade a library to bypass a mismatch.

## Keyboard behavior

Each background lane owns a canonical US keymap and independent modifier state. The physical keyboard keeps its layout, Compose key, and remaps. No installation or activation step edits `input:kb_*`. Existing Driver keycodes are interpreted by the agent keyboard, so this does not add Unicode, IME, or new Driver text routes.

Plain click, scroll, drag, and foreground activation do not require a canonical keyboard layout. Foreground keys still use the primary seat: the plugin checks the requested key and modifier sequence against its actual XKB map before activation or input. Unrelated remaps are accepted; a sequence whose symbols or modifier/lock transitions differ from the canonical meaning is refused with `unsupported_layout`. Arbitrary foreground layout translation remains outside protocol v3.

Foreground typing preserves Num Lock and admits a requested key sequence only when its symbols and shortcut semantics still match the canonical meaning. Num Lock does not block unaffected letters, top-row digits, Enter, or compatible shortcuts; a keypad sequence whose meaning changes is refused. Caps Lock, other unsupported lock states, held or latched modifiers, and nonzero layout groups remain guarded.

Both routes retain target/conflict checks and cancellation on desktop/keymap changes. `hyprctl -j cua:status` exposes `keyboard_layout_independent: true` and `foreground_numlock_compatible: true` for installers to distinguish this implementation from an older mapped module. The marker does not identify every future package revision; plugin updates still require a fresh desktop session.

## Historical upstream qualification

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
That historical run used source-built released Driver 0.24.0; earlier real-app
checks separately used the then-published Omarchy `cua-driver-bin 0.24.0-1`
executable. A separate later Omabot replay reported 124 passes and four
failures, plus seven incomplete native cases. Cua subsequently passed those
four cells with the repair candidate shipped in Driver 0.27.0 and passed all
seven lifecycle cases. A final exact-release Fleet replay then passed all four
cells with Driver and harness source `082de4344b731ae4738ddc6a6f13f21bb3c49a85`,
released Driver binary SHA-256
`bb1b65394e912246220f9f758c9efbbf6260cec16e3562e62a361fa95329377f`,
and evidence SHA-256
`b6c47278a3db398ecbb4d7aed2bce44a467e2af37e6d4ccfc236d1e07aa70af7`.
See the linked qualification record and PR description for exact artifacts and observation limits. Omarchy replay of the 0.27.0 package pairing is recorded in #346; it does not qualify later Driver releases.

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

## Omabot replay before promotion

Build the unsigned candidate in edge:

```sh
./bin/build --package cua-hyprland-plugin --arch x86_64 --mirror edge
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

After the exact package and Driver pairing passes, advance the signed artifact with `bin/repo advance --from edge --to rc --package cua-hyprland-plugin`, validate RC, and then use `bin/repo advance --from rc --to stable --package cua-hyprland-plugin`. Do not rebuild independently in RC or stable.

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
fresh session. Before loading, run the consumer check with this package's derived
kit-provenance digest:

```sh
python3 /usr/share/cua-hyprland-plugin/profile_verify.py \
  --kit /usr/share/cua-hyprland-plugin \
  --kit-sha256 819779b93655d603d9ebb0d33ea052326c3374674a1d473886106af25e0fffdd \
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

Loading alone does not enable input. Use Omarchy's explicit Cua Input toggle when available; it verifies the installed profile and loaded capability and removes the legacy copied toggle's keyboard override. If it reports an older mapped plugin, disable Cua Input and log out and back in before enabling it again. Never hot-unload and reload the module.

For manual activation, add only this plugin setting to a sourced Hyprland Lua configuration file, preserving all existing input settings:

```lua
hl.config({
  plugin = { cua = { enabled = true } },
})
```

Then reload and inspect status:

```sh
hyprctl reload
hyprctl -j cua:status
```

Continue only when status reports `keyboard_layout_independent: true`, `foreground_numlock_compatible: true`, input protocol v3, input capability, socket paths, and the expected compositor identity. Do not change `kb_layout`, `kb_options`, or NumLock for background input. If you previously followed the stock-US override instructions, remove only that Cua-specific override and reload to restore your underlying personal settings.

Start Driver with `CUA_DRIVER_RS_ENABLE_WAYLAND=1`. In a new disposable Inkscape document, test an admitted background key operation and pointer operation, then verify the result in both a fresh snapshot and a saved/reopened SVG. Driver text-route restrictions still apply. Never test against an existing document or automatically replay an action with a partial or unknown outcome.

To disable input, turn the Cua Input toggle off, or remove the manual `plugin.cua.enabled` setting and reload. Confirm that status reports input disabled. Retained inert agent pointers can remain until the compositor exits; disabling input does not unload the mapped module.

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
publication decisions. Spencer (@spencerbull) and Emir (@emirb) jointly own
that Omarchy package and release path. Maintenance is best effort, with no
turnaround commitment.

Edge detects upcoming incompatibilities; RC validates the intended stable
environment. Mirror/channel changes and changes to ABI dependencies, Driver,
or admitted apps request a new candidate and affected qualification. They do
not establish compatibility or authorize additional publication channels.

This package participates in scheduled builds, but has no upstream polling, AUR synchronization, or automatic rebuild bump. A checked-in version change or missing artifact can queue it for the normal release pipeline. Build selection, promotion, `push`, and `upload-prebuilt` do not supply native qualification or authorize a broader support claim. Do not silently substitute newly rebuilt bytes during signing or publication.

Before calling a release complete, install the signed published package on a fresh consumer, verify its signature and package/module digests, and perform a short activation, background-action, and cleanup smoke. Edge and RC artifacts are compatibility checkpoints, not qualified support for those environments.
