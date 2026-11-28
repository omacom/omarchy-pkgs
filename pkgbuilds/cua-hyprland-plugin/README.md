# Optional Cua Hyprland plugin

This package targets **Omarchy x86_64**, with Inkscape `1.4.4-6` and two independent background-input lanes. Edge and RC now serve Inkscape `1.4.4-8`, which Driver `0.47.5` admits and which Omabot's runs on Omarchy 4.6.0 RC1 used. Release `0.47.8` is built on edge from Cua's published [Hyprland kit 1.4.0](https://github.com/trycua/cua/releases/tag/cua-hyprland-kit-v1.4.0-omarchy-edge-20261111) against the build of Hyprland `0.57.2` that Omarchy publishes (see *Omarchy's Hyprland*) and the ABI packages edge serves when it is built, all of which the build measures and none of which the package pins from `0.47.8-12` on (see *When Hyprland or an ABI package moves*), used with `cua-driver-bin` `0.47.5`, the release every channel serves. It carries no Omarchy patch: the IME popup guard and the text-chord keyboard check that `0.33.2-4` applied as `downstream.patch` are in Cua's plugin source ([Cua #7320](https://github.com/trycua/cua/pull/7320)), and agent-seat hover for background apps is too ([Cua #7319](https://github.com/trycua/cua/pull/7319)). It reaches RC and stable by promotion: RC has served it beside Omarchy's Hyprland `0.57.2` since Omarchy 4.6.0 RC1, and stable keeps `0.33.2-3`, an earlier Cua release built for and pinned to Arch's Hyprland `0.56.2-4`, so the update that replaces that Hyprland has to bring this release with it. Cua's CI evidence for this kit is linked from [Cua #7390](https://github.com/trycua/cua/pull/7390). Omabot replay and Omarchy's merge decisions are recorded in the pull requests that change this package, starting with [omarchy-pkgs #346](https://github.com/omacom/omarchy-pkgs/pull/346). Scheduling the recipe does not expand the qualified target.

The plugin is optional. Cua Driver works independently, and installation does not load the plugin or enable input. The package follows the normal edge-to-RC-to-stable promotion path instead of the fast release ring. Its PKGBUILD limits builds to x86_64. Cua measured and qualified the kit's profile on Arch's build of Hyprland `0.57.2`; Omarchy's build of it, RC and stable need their own Omabot validation before promotion.

## Source and build profile

The package builds the plugin source published with [Driver 0.47.8](https://github.com/trycua/cua/releases/tag/cua-driver-rs-v0.47.8), exactly as kit 1.4.0 carries it, with the kit's own packaging tooling and recipe. The source detects the installed Hyprland's input internals instead of pinning a version, so the same source serves `0.56.2` and `0.57.x` ([Cua #6495](https://github.com/trycua/cua/pull/6495)); only the reviewed profile differs per channel.

The kit's qualified Driver pairing is `0.47.8`, with input protocol v3. Cua's CI loads the packaged module into a headless Hyprland on both `0.57.2-1` and `0.56.2-4`, types and clicks into a window that does not hold focus, and drives it with the released Driver (`list_windows`, screenshot, click, `type_text`). That is CI evidence, not Omabot replay: the `cua-driver-bin` version on edge, the profile scope and the package versions below need Omabot replay before promotion.

Profile `omarchy-edge-20261111-abi` and kit tooling `1.4.0` pin:

- Hyprland headers `0.57.2`, in the build of that release installed where the package is built: its package version and its executable and header hashes are measured there (see *Omarchy's Hyprland*).
- GCC `16.2.1 20260810`, including compiler bytes and emitted ELF identity.
- Shared runtime `libstdc++.so.6.0.36` and its bytes. The versions of the ABI packages below are measured where the package is built.

### Omarchy's Hyprland

Omarchy publishes its own Hyprland, patched and with a package release above Arch's, and Omarchy's pacman configuration and the builder both list `[omarchy]` before `[extra]`. The kit's profile names the build Cua measured, which is Arch's. A package pinned to that build is satisfied only by `[extra]`, so installing it replaces Omarchy's Hyprland with Arch's, and the next update, which wants Omarchy's back, is refused. Which Hyprland a machine runs is Omarchy's decision and this package never changes it, so the build is never read from the kit.

`prepare()` measures the installed `hyprland` package with the kit's own verifier: its version, the bytes of `/usr/bin/Hyprland`, and the header inventory. `kit.py` writes those into the profile the kit is derived for, along with the package's own release, and every later step derives the kit again and requires the extracted one to match, so a Hyprland replaced during the build stops it. The package depends on `hyprland` by name only, so the builder resolves Omarchy's and the package never holds a Hyprland update back (see *When Hyprland or an ABI package moves*).

The module loads beside that one build and no other, and installs beside any. `.omarchy/package.json` names `hyprland` in `rebuild_on`, so `sync-rebuilds` opens the rebuild by bumping the package release once edge serves the new Hyprland. The rebuild cannot ride in the pull request that changes Hyprland: every package in a pull request is built against what edge already serves, so the plugin would compile against the old Hyprland, and a `rebuilt_against` edited by hand to name the new one would keep `sync-rebuilds` from opening the rebuild that is still owed. Each new Hyprland build is therefore on edge before the plugin built for it, by the wait for the next `sync-rebuilds` run, which is dispatched every hour and after each edge mirror sync, and then the time the rebuild's pull request takes to build and merge.

A rebuild is not a requalification. Compiling against the new headers picks up a changed layout, and the bundled tests run against mocks, so neither sees a change in what Hyprland does. A Hyprland of another upstream release is refused by `kit.py` and by the source's own version check, and needs a kit from Cua.

### ABI-scoped profile

Kit 1.4.0's own profile, `omarchy-edge-20261111`, pins the exact version of all packages Hyprland links against, Mesa, GLib and OpenSSL among them. Held to all of them, the consumer check would fail after nearly every update until a rebuild landed, since several of them move within days of any measurement. The checked-in `PROFILE.json` is that profile with its runtime list reduced to the ABI packages Cua's [daily compatibility CI](https://raw.githubusercontent.com/trycua/cua/hyprland-plugin-compat/compatibility.json) requalifies the plugin against: Aquamarine, glibc, hyprcursor, hyprgraphics, hyprlang, hyprutils, libgcc, libstdc++, libxkbcommon and Wayland, with Hyprland and GCC pinned in their own fields. The file carries those ten at the versions Cua measured and nothing of Omarchy's but its ID, `omarchy-edge-20261111-abi`. Every other field is Cua's: the source identity, the compiler and runtime hashes, and the Hyprland fields and package versions as Cua measured them, which the build replaces with what it finds installed.

`kit.py` derives the kit from the published archive the way Cua's `profile_bundle.py` builds one. It verifies the archive's checksum and every member against the kit's `SHA256SUMS`, refuses a checked-in profile that changes anything beyond its ID, its release and that runtime scope, puts the measured Hyprland build, the measured versions of the ten ABI packages and the package release in its place, refuses a Hyprland that is not a build of the release the kit names, rewrites `KIT-PROVENANCE.json` for the new profile digest, renders `PKGBUILD` from the kit's `PROFILE-PKGBUILD.in` with the kit's own `profile_verify.py`, and runs that verifier's completeness check. Cua's `profile_bundle.py`, run at the kit's tooling commit (the 40-character SHA in the kit's file name) on the same profile and source archive, produces the same eleven members byte for byte. `kit_test.py` runs in `check()` against the downloaded kit with a stand-in for the installed Hyprland, so it passes or fails the same on any builder. It derives the kit for a Hyprland build and a glibc version the kit has never seen, and refuses a Hyprland of another release, a Hyprland or an ABI package replaced after extraction, a measurement that is not exactly the ten ABI packages, a fractional package release, a checked-in profile that is widened or narrowed, that carries a version written by hand, or that changes the compositor, header, compiler or libstdc++ fields or the source, a tampered or extended archive, and a changed extracted kit.

The build, check and package steps are Cua's rendered recipe, with the kit moved under `$srcdir/cua-profile-kit` the way Cua's `profile_download_recipe.py` adapts it for a downloaded kit. Source integrity, package-owned headers, pkg-config selection, compiler probes, runtime equality, and production flags remain mandatory. Packaging runs all bundled CTests even with `--nocheck` or `--repackage`, and every downloaded and local input is checked again explicitly, so `--skipinteg` does not bypass recipe checks. Production input is built in; experimental signed input and tracing are off.

The pristine upstream archive, manifest and verifier remain unchanged and no Omarchy patch is applied, so `BUILD-PROVENANCE.json` describes an unmodified upstream build.

## When Hyprland or an ABI package moves

Pacman is told no version of Hyprland or the ten ABI packages. They are dependencies by name only, because an exact pin on any of them makes `omarchy update` refuse the whole update on every machine with the plugin, from the moment that package moves until a plugin build for it is published. Nine of the ten are Arch's packages and move when Arch moves them, with nothing in this repository in between, and Aquamarine, which Omarchy builds itself from `0.16.0-1.2`, moves the way Hyprland does: Aquamarine and glibc under `0.26.1-5` and `0.26.1-6`, hyprutils `0.14.3` under `0.33.2-3`, glibc `2.44+r78` under `0.47.8-3`. Hyprland is Omarchy's, but its rebuild and the plugin's cannot be published together (see *Omarchy's Hyprland*): Hyprland `0.57.2-3` and `0.57.2-4` each stopped updates for about six hours on 2026-11-20, under `0.47.8-6` and `0.47.8-7`. RC and stable move only when someone promotes them, so a promotion made in such a gap would have left every update refused there until the next one. `omarchy-hyprland-titlebars` pins the Hyprland release without the package release, which a rebuild satisfies. That is not enough here: that plugin moves to a new Hyprland release in the pull request that brings it, and this one waits for a kit from Cua with every update refused in between.

The exact match is kept where a mismatch costs Cua Input and nothing else. The installed `PROFILE.json` records the Hyprland build and the version of each ABI package the module was built against, and the kit's consumer check requires Hyprland and all ten at exactly those versions, with Hyprland's and libstdc++'s bytes unchanged. Omarchy has no Cua Input toggle yet, so nothing loads the module by itself. `cua-hyprland-plugin-load`, which this package installs, runs that check and loads the module only when it passes (see *Activation, updates, and removal*). Nothing else sees a Hyprland rebuilt under the same release. The module refuses by itself to start in a Hyprland of another upstream commit, or one built against another minor version of Aquamarine, hyprutils, hyprgraphics, hyprcursor or hyprlang, and a rebuild need not change any of those. Hyprland `0.57.2-3` was `0.57.2-2` rebuilt against patch releases of hyprutils and hyprcursor, which the fingerprint leaves out: the module reports the same fingerprint for both, and the module compiled against each is a different file. A patch Omarchy adds to Hyprland under one release changes none of them either. So when Hyprland or one of the ten moves, the update goes through and the check fails from then on. A session already running is not touched: its compositor and module keep the executable and libraries they mapped when they started, so input that is on stays on until that session ends. In a later session the loader refuses, and the module stays unloaded until the rebuilt package arrives.

The rebuild needs nobody. `.omarchy/package.json` names Hyprland and the ten in `rebuild_on`, so `sync-rebuilds` opens a package release bump at its first run after edge serves the new version, and that pull request merges and publishes once it builds. The bump is the whole refresh, because no version is written in the recipe: `prepare()` reads each ABI package's installed version with the kit's verifier, `kit.py` writes them into the profile the kit is derived for beside the measured Hyprland, and the builder upgrades its system before it builds. The kit's own checks decide whether that build is still Cua's: the source, the compiler's identity and libstdc++'s name and bytes must be the kit's, in the builder, in Hyprland and in the module. A new GCC, a libstdc++ whose bytes changed, or another Hyprland release fails the build, the pull request stays open and red, and input stays off until Cua publishes a kit for it.

A rebuild is not a requalification here either. Matching sonames and unchanged Hyprland bytes do not prove a moved library compatible: no verifier hashes the ABI packages' own headers, some of them carry data between Hyprland and the plugin in layouts defined there (hyprutils' `CSignalT` hands its arguments over as a tuple behind a `void*`), and a library can change behaviour both rely on without a new soname. The rebuilt module is compiled against the moved headers while Hyprland may still be the build compiled against the previous ones, and nothing here reads the upstream diff. Cua's daily compatibility CI builds and exercises the plugin against every such move on Arch and on Omarchy edge, RC and stable, and is where a break of that kind shows. Compare a rebuilt module with the previous release's when one is in doubt: identical bytes mean the plugin's emitted code is unchanged.

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
   the kit's checks or replace the compositor to make the build pass.
3. Install through pacman and activate in a fresh session. Replay the declared
   app, two-lane, refusal, primary-input, cancellation, and fault/recovery checks
   against the actual packaged Driver and module. A Cua Fleet result is not an
   Omabot result; matching source alone does not certify different binaries.
4. Verify restart-based upgrade, rollback, removal, and reinstallation. Retain
   evidence that binds each result to the package and mapped module bytes.

After the exact package and Driver pairing passes, check the destination before promoting. Nothing in pacman keeps the package off a channel it was not built for: it installs anywhere, and loads only where Hyprland and the ten ABI packages are at exactly the versions in its `PROFILE.json`. Promoted to a channel that serves anything else, a newer Hyprland build included, it replaces a plugin that loads there with one that does not. Read the versions out of the package file, here `$package`, and compare them with what the destination will serve once the promotion is done:

```sh
bsdtar -xOf "$package" usr/share/cua-hyprland-plugin/PROFILE.json | jq '.hyprland.package_version, .runtime.packages'
```

Hyprland and Aquamarine are Omarchy's and can go with the plugin. The other nine come from the destination's Arch snapshot, which a promotion does not move. Then promote the signed artifact with **Promote channel** (`gh workflow run promote.yml -R omacom/omarchy-pkgs -f direction="edge -> rc" -f packages="cua-hyprland-plugin"`, with `hyprland` and `aquamarine` in the list when the destination does not yet serve those builds), validate RC, and run it again with `-f direction="rc -> stable"`. Promotion copies the published file; nothing is rebuilt for RC or stable.

A promotion of the whole channel carries Hyprland, Aquamarine and the plugin together, and still carries a mismatched set when it runs between a Hyprland build reaching edge and the plugin's rebuild. An open `auto/sync-rebuilds-cua-hyprland-plugin` pull request is a sign that the rebuild is owed; the comparison above settles it.

Portable tests, screenshots, health reports, and a successful build do not
replace native qualification. Recheck the published Driver package before
rollout and qualify any changed pairing explicitly.

## Activation, updates, and removal

The package installs the module at `/usr/lib/cua/hyprland/cua-hyprland-plugin.so`, the loader `cua-hyprland-plugin-load`, and provenance plus the consumer verifier under `/usr/share/cua-hyprland-plugin/`. There are no package-manager hooks, autoloading, configuration edits, or hot replacement.

Install the package with `omarchy pkg add cua-hyprland-plugin`, and load the module from a terminal in the session. A session that has the module loaded keeps that module until it ends, so log out and back in after the package is replaced or removed. The loader is in `0.47.8-12` and later; a machine on an earlier release, `0.47.8-10` on Omarchy 4.6.0 RC1 among them, gets it with the update that brings a later one.

```sh
cua-hyprland-plugin-load
```

The loader loads the module only when two things hold, and says which did not:

- Cua's consumer check passes: Hyprland and the ten ABI packages are installed at exactly the versions in `PROFILE.json`, with Hyprland's and libstdc++'s bytes unchanged. This is the kit's `profile_verify.py --consumer`, which requires Python 3.11+, binutils `readelf`, and system `ldd`/`pacman`, not a compiler or headers, and which the loader runs with the system's `/usr/bin/python3`, whatever `PATH` and `PYTHONPATH` offer. The kit-provenance digest it is given is different for every Hyprland build the package is rebuilt against, so the loader reads it from the installed file. What vouches for that file is the package it was installed from, whose signature pacman verified then, and `pacman -Qkk cua-hyprland-plugin` shows whether the installed files still match it.
- The session is current: the compositor is the installed `/usr/bin/Hyprland`, and no file it has code mapped from has been replaced since it started. The consumer check reads installed files and cannot see this. A Hyprland started from another path, a source build ahead on `PATH` for example, is refused. After an update that replaces Hyprland or a library it runs, the session goes on running the old one until it ends, so the loader names the replaced file and asks for a new login. It asks the same when any other executable file the compositor has mapped was replaced, which is more than can matter to the module, and errs toward a new session.

It then asks Hyprland to load the module, and passes on Hyprland's answer when the module is turned down. `hyprctl plugin load` on the module skips both checks, and `hyprctl` exits 0 when Hyprland turns a module down; do not load it that way. Run the loader when no update is in progress: one that replaces the module between the checks and the load is not seen. Neither check verifies input effects.

The load lasts for that session. Nothing loads the module at login, so run the loader in each session that wants it. Never hot-unload and reload the module.

Loading does not enable input by itself. To enable it, add only this plugin setting to a Lua file that `~/.config/hypr/hyprland.lua` requires, for example `~/.config/hypr/cua.lua` with `require("hypr.cua")` added to `hyprland.lua`, the way Omarchy requires its own files there, preserving all existing input settings:

```lua
if hl.get_config("plugin.cua.enabled") ~= nil then
  hl.config({ plugin = { cua = { enabled = true } } })
end
```

Keep the guard, and put it around a bare `hl.config` line written from an earlier version of these steps. Hyprland knows the key only while the module is loaded, so without the guard every login shows `unknown config key 'plugin.cua.enabled'` in the config error banner. With it the file does nothing until the module is loaded, and since loading reloads the configuration, in each later session input comes on with the load.

Hyprland reloads its configuration when the file is saved, so input is on from then. Reload by hand if it is not, and inspect status:

```sh
hyprctl reload
hyprctl -j cua:status
```

Continue only when status reports `configured: true`, `transport.ready: true`, `input.protocol: 3`, `input.transport_ready: true`, `abi.match: true`, `keyboard_layout_independent: true`, `foreground_numlock_compatible: true` and `ime_popup_guard: true`. Do not change `kb_layout`, `kb_options`, or NumLock for background input. If you previously followed the stock-US override instructions, remove only that Cua-specific override and reload to restore your underlying personal settings.

Start Driver in a terminal of its own with `CUA_DRIVER_RS_ENABLE_WAYLAND=1 cua-driver serve`. In a new disposable Inkscape document, test an admitted background key operation and pointer operation, then verify the result in both a fresh snapshot and a saved/reopened SVG. Give Inkscape a tile its window fits first: a surface Hyprland scales down to fit its tile takes pointer input at the wrong place, with no error, and a rectangle dragged in an Inkscape squashed from 990 to 781 wide came out 0.79 as wide as asked and displaced. Driver text-route restrictions still apply. Never test against an existing document or automatically replay an action with a partial or unknown outcome.

To disable input, remove the `plugin.cua.enabled` setting and reload. Confirm that status reports `configured: false`. When the file itself is deleted, take its `require` line out of `hyprland.lua` with it, or the next reload reports the missing module. Retained inert agent pointers can remain until the compositor exits; disabling input does not unload the mapped module.

An update that moves Hyprland or an ABI package goes through with the plugin installed, and leaves a running session as it was. In a later session the loader refuses until the rebuilt package arrives with a later update.

That holds from release `0.47.8-12`. Earlier releases pin the exact Hyprland build, `0.47.8-10` on Omarchy 4.6.0 RC1 among them, and those before `0.47.8-4` the ABI packages too, so on a machine or channel that still has one, an update that moves a pinned package without bringing a later plugin release in the same transaction is refused. To update before then, remove operator-added plugin activation settings, save work, and exit the graphical session. From a text console, run `sudo pacman -R cua-hyprland-plugin`, then apply the normal desktop update and verify a fresh session without the plugin. Do not force an upgrade past the dependency.

Retain the previous package with its matching compositor, runtime, Driver, and
provenance as a rollback set. Restore a consistent set outside the graphical
session, then repeat the fresh-session consumer and app checks. Do not hot
unload/reload or replace a mapped module.

## Ownership and publication

The [agreed ownership split](https://github.com/omacom/omarchy-pkgs/pull/346#issuecomment-5612834061)
assigns profiles, build kits, plugin fixes, and native input evidence to Cua. Following the Hyprland build and the ABI packages edge serves, as *When Hyprland or an ABI package moves* describes, is Omarchy's, and that Hyprland build is one Omarchy publishes, as *Omarchy's Hyprland* describes. A profile that changes anything else, another Hyprland release included, still comes from Cua.
Francesco (@f-trycua) is the Cua contact through this PR. Omarchy owns package
integration, dependency-change detection, Omabot validation, and signing and
publication decisions. Spencer (@spencerbull) and Emir (@emirb) jointly own
that Omarchy package and release path. Maintenance is best effort, with no
turnaround commitment.

Edge detects upcoming incompatibilities; RC validates the intended stable
environment. Mirror/channel changes and changes to ABI dependencies, Driver,
or admitted apps request a new candidate and affected qualification. They do
not establish compatibility or authorize additional publication channels.

This package has no upstream polling. `sync-rebuilds` bumps its release when Omarchy's Hyprland or one of the ABI packages moves, and nothing else changes it. A checked-in version change builds it on its pull request and publishes it to edge on merge, like any package. Building, publishing and promotion do not supply native qualification or authorize a broader support claim. Do not silently substitute newly rebuilt bytes during signing or publication.

Before calling a release complete, install the signed published package on a fresh consumer, verify its signature and package/module digests, and perform a short activation, background-action, and cleanup smoke. Edge and RC artifacts are compatibility checkpoints, not qualified support for those environments.
