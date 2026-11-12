# Optional Cua Hyprland plugin

This package targets **Omarchy x86_64**, with Inkscape `1.4.4-6` and two independent background-input lanes. Release `0.47.8-2` is an edge release built from Cua's published [Hyprland kit 1.4.0](https://github.com/trycua/cua/releases/tag/cua-hyprland-kit-v1.4.0-omarchy-edge-20261111) for Omarchy edge (Hyprland `0.57.2`), with its ABI package versions measured on edge with the kit's own tooling (see *Dependency refresh*), used with `cua-driver-bin` `0.47.x`. It carries no Omarchy patch: the IME popup guard and the text-chord keyboard check that `0.33.2-4` applied as `downstream.patch` are in Cua's plugin source ([Cua #7320](https://github.com/trycua/cua/pull/7320)), and agent-seat hover for background apps is too ([Cua #7319](https://github.com/trycua/cua/pull/7319)). The same Cua source and kit tooling build against Hyprland `0.56.2` for RC and stable, which keep their current `0.33.2` package until promotion. Cua's CI evidence for this kit is linked from [Cua #7390](https://github.com/trycua/cua/pull/7390). Omabot replay and Omarchy's merge decisions are recorded in the pull requests that change this package, starting with [omarchy-pkgs #346](https://github.com/omacom/omarchy-pkgs/pull/346). Scheduling the recipe does not expand the qualified target.

The plugin is optional. Cua Driver works independently, and installation does not load the plugin or enable input. The package follows the normal edge-to-RC-to-stable promotion path instead of the fast release ring. Its PKGBUILD limits builds to x86_64. Cua measured and qualified the kit's profile on Omarchy edge; RC and stable need their own Omabot validation before promotion.

## Source and build profile

The package builds the plugin source published with [Driver 0.47.8](https://github.com/trycua/cua/releases/tag/cua-driver-rs-v0.47.8), exactly as kit 1.4.0 carries it, with the kit's own packaging tooling and recipe. The source detects the installed Hyprland's input internals instead of pinning a version, so the same source serves `0.56.2` and `0.57.x` ([Cua #6495](https://github.com/trycua/cua/pull/6495)); only the reviewed profile differs per channel.

The kit's qualified Driver pairing is `0.47.8`, with input protocol v3. Cua's CI loads the packaged module into a headless Hyprland on both `0.57.2-1` and `0.56.2-4`, types and clicks into a window that does not hold focus, and drives it with the released Driver (`list_windows`, screenshot, click, `type_text`). That is CI evidence, not Omabot replay: the `cua-driver-bin` version on edge, the profile scope and the package versions below need Omabot replay before promotion.

Profile `omarchy-edge-20261111-abi`, kit tooling `1.4.0`, and package release `2` pin:

- Hyprland `0.57.2-1`, headers `0.57.2`, and measured executable/header hashes.
- GCC `16.2.1 20260810`, including compiler bytes and emitted ELF identity.
- Shared runtime `libstdc++.so.6.0.36`, its bytes, and the exact versions of the ABI packages below.

- Hyprland `0.56.2-4`, headers `0.56.2`, and measured executable/header hashes.
- GCC `16.2.1 20260810`, including compiler bytes and emitted ELF identity.
- Shared runtime `libstdc++.so.6.0.36`, its bytes, and the exact versions of the ABI packages below.

### ABI-scoped profile

Kit 1.4.0's own profile, `omarchy-edge-20261111`, pins the exact version of all packages Hyprland links against, Mesa, GLib and OpenSSL among them. Published as is, any routine update to one of them would make `omarchy update` refuse with `breaks dependency … required by cua-hyprland-plugin` until a new kit landed, and several of them move within days of any measurement. The checked-in `PROFILE.json` is that profile with its runtime list reduced to the ABI packages Cua's [daily compatibility CI](https://raw.githubusercontent.com/trycua/cua/hyprland-plugin-compat/compatibility.json) requalifies the plugin against: Aquamarine, glibc, hyprcursor, hyprgraphics, hyprlang, hyprutils, libgcc, libstdc++, libxkbcommon and Wayland, with Hyprland and GCC pinned in their own fields. Cua's profile contract asks for exactly that, exact ABI-relevant package dependencies. The package versions are the ones last measured on edge (see *Dependency refresh*), its ID `omarchy-edge-20261111-abi` is named for that measurement, and its package release is `2`. Every other field is Cua's: the source identity and the compositor, header, compiler and runtime hashes.

`kit.py` derives the kit from the published archive the way Cua's `profile_bundle.py` builds one. It verifies the archive's checksum and every member against the kit's `SHA256SUMS`, refuses a profile that changes anything beyond its ID, its release, that runtime scope and the versions of the packages in it, rewrites `KIT-PROVENANCE.json` for the new profile digest, renders `PKGBUILD` from the kit's `PROFILE-PKGBUILD.in` with the kit's own `profile_verify.py`, and runs that verifier's completeness check. Cua's `profile_bundle.py`, run at the kit's tooling commit (the 40-character SHA in the kit's file name) on the same profile and source archive, produces the same eleven members byte for byte. `kit_test.py` runs in `check()` against the downloaded kit, admits a moved ABI package version, and refuses widened or narrowed profiles, a rebuilt compositor, changed compositor, header, compiler or libstdc++ hashes, a changed source, a tampered or extended archive, an unreviewed kit-provenance digest, and a changed extracted kit.

The build, check and package steps are Cua's rendered recipe, with the kit moved under `$srcdir/cua-profile-kit` the way Cua's `profile_download_recipe.py` adapts it for a downloaded kit. Source integrity, package-owned headers, pkg-config selection, compiler probes, runtime equality, and production flags remain mandatory. Packaging runs all bundled CTests even with `--nocheck` or `--repackage`, and every downloaded and local input is checked again explicitly, so `--skipinteg` does not bypass recipe checks. Production input is built in; experimental signed input and tracing are off.

The pristine upstream archive, manifest and verifier remain unchanged and no Omarchy patch is applied, so `BUILD-PROVENANCE.json` describes an unmodified upstream build.

## Dependency refresh

Every ABI package is pinned exactly, so an Arch update to any of them makes the published plugin uninstallable until a new build lands: pacman refuses it with `unable to satisfy dependency`, even after a full database refresh, and `omarchy update` refuses the whole update. Releases `0.26.1-5` and `0.26.1-6` stopped resolving that way when Aquamarine and glibc moved. Cua's daily compatibility CI checks Arch and Omarchy edge, RC and stable for any change to Hyprland or these packages, down to same-version rebuilds, builds the plugin against each, and reports `omarchy_plugin.installable: false` for a channel whose update would break this package's pins.

When only the ABI package versions move, the refresh is a new release here measured with the kit's own tooling, not a new kit. On an up-to-date edge host with the build tools installed, run Cua's `profile_measure.py measure` from the kit's tooling commit with the kit's own ID, version and release, and require `profile_measure.py reuse --reviewed` against the kit's `PROFILE.json` to report `runtime` as the only difference, with the same libstdc++ basename and hash. Then reduce the measured runtime to the ten ABI packages, give the profile a new ID and package release, and replay the package before promotion. Matching sonames and unchanged Hyprland bytes do not prove the moved library compatible: neither verifier hashes the ABI packages' own headers, some of them carry data between Hyprland and the plugin in layouts defined there (hyprutils' `CSignalT` hands its arguments over as a tuple behind a `void*`), and a library can change behaviour both rely on without a new soname. So read the moved packages' upstream diffs, headers and implementation alike: a change to an existing type, template or inline function, or to behaviour the plugin relies on through the library (when a signal's listeners run, for one), needs a new kit from Cua. Compare the rebuilt module with the previous release's too. Identical bytes mean the plugin's emitted code is unchanged; different bytes need their cause found in the build inputs, a header or the toolchain, before the refresh goes ahead. `kit.py` enforces the profile side of this: the ABI package versions may follow the measurement, and the source and the compositor, header, compiler and libstdc++ identities must still be the kit's. Anything else, including an Arch rebuild of the same Hyprland release, a new GCC or a libstdc++ whose bytes changed, needs a new kit from Cua. A package release bump alone cannot repair dependency drift. Do not remove exact dependencies or selectively downgrade a library to bypass a mismatch.

## Keyboard behavior

Driver 0.31.0 and later implement this upstream. Each background lane owns a canonical US keymap and independent modifier state. The physical keyboard keeps its layout, Compose key, and remaps. No installation or activation step edits `input:kb_*`. Existing Driver keycodes are interpreted by the agent keyboard, so this does not add Unicode, IME, or new Driver text routes.

Plain click, scroll, drag, and foreground activation do not require a canonical keyboard layout. Foreground keys still use the primary seat, so foreground typing needs a physical keymap under which every chord Driver types text with (the US main-block digits, letters and punctuation with and without Shift, plus Space, Tab and Return) means what it means on the canonical US map, with Num Lock off and on. A different layout, or a remap of one of those keys or of Shift, is refused with `unsupported_layout` before a string starts. Upstream also requires every other key the KEY command can press to match, which refuses all foreground typing under remaps like `ctrl:swapcaps`, `compose:ralt`, `altwin:swap_alt_win`, or `compose:102`; Cua's plugin limits the up-front check ([Cua #7320](https://github.com/trycua/cua/pull/7320)) to the text chords and leaves other keys to the per-chord check, which simulates each requested key and modifier sequence against the actual XKB map before activation or input. Under `ctrl:swapcaps`, plain text types and Ctrl+A is refused. Arbitrary foreground layout translation remains outside protocol v3.

Foreground typing preserves Num Lock and admits a requested key sequence only when its symbols and shortcut semantics still match the canonical meaning. Num Lock does not block unaffected letters, top-row digits, Enter, or compatible shortcuts; a keypad sequence whose meaning changes is refused with `foreground_keyboard_numlock_keypad`. Caps Lock is refused with `foreground_keyboard_caps_lock`; other unsupported lock states, held or latched modifiers, and nonzero layout groups remain guarded.

Both routes retain target/conflict checks and cancellation on desktop/keymap changes. `hyprctl -j cua:status` exposes `keyboard_layout_independent: true` and `foreground_numlock_compatible: true` for installers to distinguish this implementation from an older mapped module. The marker does not identify every future package revision; plugin updates still require a fresh desktop session.

## Input-method popups

With input enabled, the agent seats are ordinary `wl_seat` globals, and fcitx5 requests an input method for every seat it sees: one is accepted and the others are refused. When fcitx5 then exits, which Omarchy's `omarchy-restart-xcompose` does, Hyprland 0.56.2 can be left with an input-method popup that is still mapped although its `wl_surface` is already gone, and it updates every popup as the input method goes away. `CInputPopup::updateBox` dereferences the missing surface and Hyprland crashes into safe mode. Hyprland never marks such a popup unmapped, and its renderer reaches the same missing surface through `CInputPopup::shouldBeRendered`. The plugin hooks `CInputPopup::updateBox` and `CInputPopup::shouldBeRendered` through Hyprland's function-hook API so that a popup whose `getSurface()` is empty is neither placed nor rendered. The hooks are installed when the module loads and removed when it unloads, and `hyprctl -j cua:status` reports `ime_popup_guard: true` when both are active. If either exact symbol is not found, the plugin loads without the guard and reports `false`. The guard is in the module only; the bundled tests compile `plugin.cpp` against mocks without it.

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
See the linked qualification record and PR description for exact artifacts and observation limits. Omarchy replay of the 0.27.0 package pairing is recorded in #346; it does not qualify later Driver releases, including 0.28.2.

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

After the exact package and Driver pairing passes, promote the signed artifact with **Promote channel** limited to this package (`gh workflow run promote.yml -R omacom/omarchy-pkgs -f direction="edge -> rc" -f packages=cua-hyprland-plugin`), validate RC, and then run it with `-f direction="rc -> stable"`. Promotion copies the published file; nothing is rebuilt for RC or stable.

Portable tests, screenshots, health reports, and a successful build do not
replace native qualification. Recheck the published Driver package before
rollout and qualify any changed pairing explicitly.

## Activation, updates, and removal

The package installs the module at
`/usr/lib/cua/hyprland/cua-hyprland-plugin.so` and provenance plus the consumer
verifier under `/usr/share/cua-hyprland-plugin/`. There are no package-manager hooks, autoloading,
configuration edits, or hot replacement.

Save your work and exit Hyprland before installing, replacing, or removing the
package. Install the exact reviewed package from a text console, then start a
fresh session. Before loading, run the consumer check with this package's derived
kit-provenance digest:

```sh
python3 /usr/share/cua-hyprland-plugin/profile_verify.py \
  --kit /usr/share/cua-hyprland-plugin \
  --kit-sha256 963f350781e1474c84edb43838dac136f2af48ed4121d333dfbe5bcfe87bbf9c \
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

Continue only when status reports `keyboard_layout_independent: true`, `foreground_numlock_compatible: true`, `ime_popup_guard: true`, input protocol v3, input capability, socket paths, and the expected compositor identity. Do not change `kb_layout`, `kb_options`, or NumLock for background input. If you previously followed the stock-US override instructions, remove only that Cua-specific override and reload to restore your underlying personal settings.

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
assigns profiles, build kits, plugin fixes, and native input evidence to Cua. Refreshing only the ABI package versions with the kit's own tooling, as *Dependency refresh* describes, is Omarchy's; a profile that changes anything else still comes from Cua.
Francesco (@f-trycua) is the Cua contact through this PR. Omarchy owns package
integration, dependency-change detection, Omabot validation, and signing and
publication decisions. Spencer (@spencerbull) and Emir (@emirb) jointly own
that Omarchy package and release path. Maintenance is best effort, with no
turnaround commitment.

Edge detects upcoming incompatibilities; RC validates the intended stable
environment. Mirror/channel changes and changes to ABI dependencies, Driver,
or admitted apps request a new candidate and affected qualification. They do
not establish compatibility or authorize additional publication channels.

This package has no upstream polling or automatic rebuild bump. A checked-in version change builds it on its pull request and publishes it to edge on merge, like any package. Building, publishing and promotion do not supply native qualification or authorize a broader support claim. Do not silently substitute newly rebuilt bytes during signing or publication.

Before calling a release complete, install the signed published package on a fresh consumer, verify its signature and package/module digests, and perform a short activation, background-action, and cleanup smoke. Edge and RC artifacts are compatibility checkpoints, not qualified support for those environments.
