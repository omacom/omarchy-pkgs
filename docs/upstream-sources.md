# Direct upstream watches

Omarchy owns the recipes in `pkgbuilds/`. `bin/sync-upstream` discovers new
releases directly from project/vendor feeds and updates versions, declared
release variables, and the source checksums already used by the recipe. It never
imports upstream PKGBUILDs or runs downloaded build scripts. Architecture support,
root install hooks, dependencies, and build functions remain ours to maintain.

`upstream.watch` complements the existing declarative providers and custom hooks:

```json
{
  "source": "local",
  "upstream": {
    "watch": {
      "github": "abenz1267/walker",
      "pattern": "v(?P<version>[0-9]+(?:\\.[0-9]+)*)"
    }
  }
}
```

## Watch fields

Choose exactly one provider: `github` (owner/repository), `git_tags` (repository
HTTPS URL), `git_branch` (repository URL plus explicit `branch`), `npm` or `pypi`
(package name), `debian` (Packages index plus exact `package`), `json` (URL plus
version `path`), `regex` (text URL), `redirect` (final HTTPS download URL), or
`archive` (inspect archive metadata without extracting/executing code).

Tag, text, redirect and archive watches use an explicit `pattern` with a named
`version` capture; `debian` and `npm` watches also accept an optional `pattern`
to normalize vendor versions (such as npm prereleases). Tag and `npm` patterns
match the entire string. `npm` watches default to `dist_tag: "latest"`. `version`
optionally formats those captures into an Arch pkgver; e.g. Sublime uses
`4.{version}`. JSON feeds can expose additional capture values through `fields`,
a name-to-JSON-path map.

`variables` maps recipe scalars such as `_commit` or `_build` to capture templates.
Only explicitly declared underscore-prefixed variables can change. GitHub
`{commit}` resolves the selected tag, not a moving target_commitish branch.
`submodules` can map a recipe variable to a gitlink in the selected GitHub tag.
Downloaded repository code is never evaluated.

For upstreams that rebuild a release, declare a numeric `revision` template and
its `revision_variable`. With unchanged pkgver, only an increasing revision can
advance that variable, and the downstream pkgrel increments instead of resetting.
Cursor CLI uses `sequence` to preserve its date/counter/hash version convention
when the vendor publishes a second hash on the same day. A new pkgver resets
pkgrel to 1, but the complete epoch:pkgver-pkgrel must still increase.

GitHub releases always exclude drafts, exclude prereleases unless
`allow_prerelease` is true, and paginate up to five pages of 100 entries only
when page 1 yields no eligible
match (keeping normal repositories at one API call while protecting monorepos).
Existing `min_release_age` policies apply: a feed without a verifiable publication
time cannot bypass a configured hold.

## Branch watches

A `git_branch` watch treats every commit on a branch as a release and writes an
immutable pin (`"_commit": "{commit}"`) so the recipe never carries a moving
`#branch=` source; `tests/pinned-sources.sh` enforces that. The clone is bare,
blobless and single-branch, read only with git, and shared by every package
that watches the same branch in one run, so two recipes pinned from it always
see the same commit. Values available to `version`:

- `{date}` (default), `{count}` (commits on the branch), `{commit}`
  (`{commit:.7}` for the short form)
- with `tag_pattern` (a regular expression with a named `version` group,
  matched against whole tags): `{tag}`, `{version}` from that tag, and
  `{distance}`, the number of commits past it. Only tags in the pinned
  commit's own history count, so a release cut on another branch is ignored.

`{version}.r{distance}.g{commit:.7}` gives `1.21.0.r15.gabc1234`, which pacman
orders above the `1.21.0` release it follows and below `1.21.1`; `omasnap-git`
uses it. The Omarchy dev pair uses `{version}.r{count}.g{commit:.7}` instead
because its published history counted every commit and the number must never
go down.

`min_release_age` holds a branch tip until its commit timestamp is old enough.
A fresh tip falls back to the newest commit on the branch's first-parent
history that has cleared the window, so a busy branch still advances; it never
selects a commit from a merged side branch. This uses Git's committer date, not
the time a commit was pushed, measured from when the run cloned the branch so
packages pinned from it agree. `BYPASS_MIN_RELEASE_AGE=1` bypasses the hold.

`sync-upstream.yml` runs three cadence lanes:

- `five-minute`: packages marked `"auto_merge": true` and `"sync_cadence": "five-minute"`
  (`omarchy-dev` and `omarchy-settings-dev`), using `auto/track-branches-<package>`.
- `hourly`: other packages marked `"auto_merge": true`, using
  `auto/track-branches-<package>`.
- `six-hourly`: all other tracked packages, using `auto/sync-upstream-<package>`.

All three lanes open their PRs through `package-prs.yml` and auto-merge them as
soon as the build checks pass (unless marked `"review": true`). Packages that
pin the same branch, or declare the same `"lockstep"` group name (such as
`"lockstep": "nvidia"`), share a PR so a package whose build fails holds back
only itself and its lockstep companions. The hourly lane works with every
provider, not only branch watches, so it also carries release feeds worth
checking frequently: the browsers, large vendors' apps, Omacom's own projects,
and vendor binaries that hold fresh releases with `min_release_age`.
`bin/sync-upstream --lane reviewed|auto-merge|five-minute|all` selects a lane;
the shared workflow passes the lane for the dispatched `cadence`. These
historical names select cadence, not whether the PR auto-merges. Packages that
pin the same branch move in lockstep: if one of them fails to update, the run
restores the others and reports the group as failed. A targeted sync includes
the other packages watching that branch, so requesting only `omarchy-dev` also
updates `omarchy-settings-dev`.

### Reviewed updates

`"review": true` keeps a package's update PRs for a maintainer. The PR opens as
a draft, `package-prs.yml` does not arm auto-merge, and `auto-merge-pr.yml`
skips drafts, so nothing lands on its own. CI still builds it. Read the bump,
fix the recipe on the PR branch if its build fails, and mark it **Ready for
review**: `auto-merge-pr.yml` then arms auto-merge and the PR lands once
`result`, `self-tests` and `build-isolation` pass. A later run that finds a
newer release turns a ready PR back into a draft and takes auto-merge off
before it pushes the update (`hold-reviewed-pr.sh`), so the new release gets
its own review.
`review` cannot be combined with `auto_merge`, and needs an upstream watch,
provider or hook. Outside the Asahi-derived table below, `facetimehd-dkms`,
`intel-media-driver`, and `libva-nvidia-driver` also set `"review": true`.

### Enable unattended branch updates

The builder controller box dispatches all three cadence groups on systemd timers
(`ci/dispatch.sh`, including `omarchy-dispatch-sync-five-minute.timer`), because
GitHub's own schedule ran them hours late.
The omarchy-pkgs-sync GitHub App pushes the branches and opens the PRs, so
they build without an approval hold. The omarchy-pkgs-merge GitHub App arms
auto-merge, so the merges start publishing. The built-in Actions `GITHUB_TOKEN`
can do neither.

1. The omarchy-pkgs-sync App is owned by the omacom organization, has no
   webhook, and has repository **Contents: Read and write** and **Pull
   requests: Read and write** permissions, with Workflows left at no access.
   It is installed on **omacom/omarchy-pkgs** only. Its client ID is the
   repository variable `PKGS_SYNC_APP_CLIENT_ID`. Its private key is the
   secret `PKGS_SYNC_APP_KEY` in the `bot-sync` environment, whose
   deployment branches are limited to `master`. To rotate the key, generate
   a new one in the App's settings, replace the secret, then delete the old
   key there.
2. The omarchy-pkgs-merge App arms auto-merge, so the merge, and the publish
   it starts, run as it. It is set up the same way, with the same
   permissions, installed on **omacom/omarchy-pkgs** only. Its client ID is
   the variable `PKGS_MERGE_APP_CLIENT_ID`, and its private key the secret
   `PKGS_MERGE_APP_KEY` in the `bot-merge` environment, limited to `master`.
3. Keep **Allow auto-merge** enabled and require `result`, `self-tests`, and
   `build-isolation` on `master`; the updater does not request a protection bypass.
4. Run **Sync Upstream** once from Actions with `cadence: hourly`
   to verify that its PR builds, auto-merges, and starts **Publish merged packages**.
   Subsequent runs happen hourly.

Checksums retain their algorithms (SHA256, SHA512, BLAKE2, etc.) and source order.
Changed git sources are hashed with makepkg's git-archive convention. Unchanged
sources retain their hashes; `mutable_sources` explicitly names entries such as
`source:0` that must be fetched again for a new version despite a stable URL.
Existing `SKIP` entries remain unchanged (including signed metadata verified by
the recipe); new skips are never introduced. Changed URLs are still fetched.
A matching GitHub release asset SHA256 digest avoids downloading large assets.
Missing architecture artifacts or malformed metadata fail the package atomically.
Every declared architecture must read back the same release and checksum values.

Archive watches use `member` to select a text member in ZIP or tar archives, or
`filenames: true` (ZIP only) to read versions from archive member names. Debian `.deb` archives ignore `member` and read their `control` metadata; when
the feed URL ends in `.deb`, discovery probes the first 64 KiB via HTTP Range
(`206 Partial Content`) and falls back to a full download if unsupported or
incomplete, while an actual update still downloads the full archive and
re-verifies its version before writing checksums. `unescape_json` handles JSON strings embedded
in a vendor's HTML page.

`source_variables` sets a recipe variable from a file inside one of the new
release's own sources, for facts a vendor publishes only in the artifact:

```json
"source_variables": {
  "_electronver": {
    "source": "source:0",
    "member": "usr/lib/slack/version",
    "pattern": "(?P<value>[0-9]+\\.[0-9]+\\.[0-9]+)"
  }
}
```

After the new pkgver is written, the watch fetches that source (`source:0`
names the first `source` entry, `source_aarch64:1` the second AArch64 one),
reads `member` from a zip, a tar or a `.deb`'s data archive without
extracting anything else, and requires the whole trimmed file (64 KiB at most)
to match `pattern`. The `value` capture replaces the variable, and sources that
use it are hashed again. Slack's AArch64 build uses it to follow the Electron
release each Slack `.deb` ships.

## Maintenance and validation

Running watches locally requires Python 3.14+ (its `tarfile` reads zstd), Bash,
curl, git, jq, Arch's `vercmp`, and `bsdtar`. CI installs these in its Arch
container.

- Edit packaging and architecture changes directly in PKGBUILD. The old AUR
  overlays have been folded into these recipes and removed.
- Keep source-code patches and install hooks checked in as ordinary package files.
- Bump pkgrel when changing a recipe at the same version. Removing a dotted AUR
  suffix must never lower the complete version.
- Add a watch with each new package. `bin/add-package --source aur` is a one-time
  import; it records historical `origin` metadata and leaves an owned recipe.
- `python helpers/upstream-watch.py check pkgbuilds/NAME` checks release discovery
  without rewriting the recipe. `bin/sync-upstream NAME` performs the update.
- `python tests/upstream-watch.py` tests update atomicity, architecture coverage,
  version ordering, source hashes and hostile metadata using offline fixtures.

The scheduled workflow continues reviewing completed updates if another package
fails. The failing recipe stays unchanged and the run still reports failure.

## Tracked upstream watches

Across `pkgbuilds/`, **206** active packages track upstream directly (**160** via
`upstream.watch`, **35** via legacy top-level `upstream`, and **11** via
`.omarchy/upstream.sh`). Each package's `.omarchy/package.json` is the source of
truth for the full inventory; the tables below record the **50** active `upstream.watch`
recipes carrying historical `origin.aur` provenance (a 51st `origin.aur`
recipe, `grok-bot`, uses an `.omarchy/upstream.sh` hook), the **9**
Asahi-derived reviewed
watches, and all intentional `"sync": false` holds. Historical AUR provenance in
`origin` has no effect on release selection.

| Package | Provider | Upstream |
|---|---|---|
| `1password-beta` | debian | [https://downloads.1password.com/linux/debian/amd64/dists/beta/main/binary-amd64/Packages](https://downloads.1password.com/linux/debian/amd64/dists/beta/main/binary-amd64/Packages) |
| `1password-cli` | json (auto-merge) | [https://app-updates.agilebits.com/check/1/0/CLI2/en/0](https://app-updates.agilebits.com/check/1/0/CLI2/en/0) |
| `aether` | github (auto-merge) | [omacom/aether](https://github.com/omacom/aether) |
| `amp-desktop-bin` | debian (auto-merge) | [https://static.ampcode.com/linux/dists/stable/main/binary-amd64/Packages](https://static.ampcode.com/linux/dists/stable/main/binary-amd64/Packages) |
| `bambustudio-bin` | regex | [bambulab/BambuStudio](https://api.github.com/repos/bambulab/BambuStudio/releases/latest) |
| `brave-bin` | debian (auto-merge) | [https://brave-browser-apt-release.s3.brave.com/dists/stable/main/binary-amd64/Packages](https://brave-browser-apt-release.s3.brave.com/dists/stable/main/binary-amd64/Packages) |
| `brave-origin-bin` | debian (auto-merge) | [https://brave-browser-apt-release.s3.brave.com/dists/stable/main/binary-amd64/Packages](https://brave-browser-apt-release.s3.brave.com/dists/stable/main/binary-amd64/Packages) |
| `cliamp` | github (auto-merge) | [bjarneo/cliamp](https://github.com/bjarneo/cliamp) |
| `cursor-bin` | json (auto-merge) | [https://www.cursor.com/api/download?platform=linux-x64&releaseTrack=stable](https://www.cursor.com/api/download?platform=linux-x64&releaseTrack=stable) |
| `dbxcli-bin` | github | [dropbox/dbxcli](https://github.com/dropbox/dbxcli) |
| `dotnet-core-bin` | json | [https://builds.dotnet.microsoft.com/dotnet/release-metadata/10.0/releases.json](https://builds.dotnet.microsoft.com/dotnet/release-metadata/10.0/releases.json) |
| `dropbox` | redirect (auto-merge) | [https://www.dropbox.com/download?plat=lnx.x86_64](https://www.dropbox.com/download?plat=lnx.x86_64) |
| `dropbox-cli` | regex | [https://linux.dropbox.com/packages/](https://linux.dropbox.com/packages/) |
| `facetimehd-dkms` | git_branch (review) | [https://github.com/patjak/facetimehd.git](https://github.com/patjak/facetimehd.git) `master` |
| `google-chrome` | debian (auto-merge) | [https://dl.google.com/linux/chrome/deb/dists/stable/main/binary-amd64/Packages](https://dl.google.com/linux/chrome/deb/dists/stable/main/binary-amd64/Packages) |
| `helium-browser-bin` | github (auto-merge) | [imputnet/helium-linux](https://github.com/imputnet/helium-linux) |
| `heroic-games-launcher-bin` | github | [Heroic-Games-Launcher/HeroicGamesLauncher](https://github.com/Heroic-Games-Launcher/HeroicGamesLauncher) |
| `hex-bin` | json (auto-merge) | [https://anoma.ly/release/hex/desktop/stable.json](https://anoma.ly/release/hex/desktop/stable.json) |
| `lib32-nvidia-580xx-utils` | regex | NVIDIA GeForce Linux x64 lookup ([GeForce 10 Series](https://gfwsl.geforce.com/services_toolkit/services/com/nvidia/services/AjaxDriverService.php?func=DriverManualLookup&psid=101&pfid=816&osID=12&languageCode=1033&isWHQL=0&dch=0&sort1=0&numberOfResults=10)) |
| `limine-mkinitcpio-hook` | git_tags | [https://gitlab.com/Zesko/limine-entry-tool.git](https://gitlab.com/Zesko/limine-entry-tool.git) |
| `limine-snapper-sync` | git_tags | [https://gitlab.com/Zesko/limine-snapper-sync.git](https://gitlab.com/Zesko/limine-snapper-sync.git) |
| `lmstudio-bin` | regex (auto-merge) | [https://lmstudio.ai/download](https://lmstudio.ai/download) |
| `localsend` | github | [localsend/localsend](https://github.com/localsend/localsend) |
| `macbook12-spi-driver-dkms` | git_branch | [https://github.com/marc-git/macbook12-spi-driver.git](https://github.com/marc-git/macbook12-spi-driver.git) `touchbar-driver-hid-driver` |
| `microsoft-edge-stable-bin` | debian (auto-merge) | [https://packages.microsoft.com/repos/edge/dists/stable/main/binary-amd64/Packages](https://packages.microsoft.com/repos/edge/dists/stable/main/binary-amd64/Packages) |
| `minecraft-launcher` | archive | [https://launcher.mojang.com/download/Minecraft.deb](https://launcher.mojang.com/download/Minecraft.deb) |
| `nautilus-dropbox` | github | [dropbox/nautilus-dropbox](https://github.com/dropbox/nautilus-dropbox) |
| `nordvpn-bin` | debian | [https://repo.nordvpn.com/deb/nordvpn/debian/dists/stable/main/binary-amd64/Packages](https://repo.nordvpn.com/deb/nordvpn/debian/dists/stable/main/binary-amd64/Packages) |
| `nvidia-580xx-utils` | regex | NVIDIA GeForce Linux x64 lookup ([GeForce 10 Series](https://gfwsl.geforce.com/services_toolkit/services/com/nvidia/services/AjaxDriverService.php?func=DriverManualLookup&psid=101&pfid=816&osID=12&languageCode=1033&isWHQL=0&dch=0&sort1=0&numberOfResults=10)) |
| `omarchy-emacs` | git_tags | [https://github.com/scottjones/omarchy-emacs.git](https://github.com/scottjones/omarchy-emacs.git) |
| `omazed` | git_tags | [https://github.com/aps6/omazed.git](https://github.com/aps6/omazed.git) |
| `once-bin` | github | [basecamp/once](https://github.com/basecamp/once) |
| `owe` | github (auto-merge) | [omacom/owe](https://github.com/omacom/owe) |
| `python-mediapipe` | github | [google-ai-edge/mediapipe](https://github.com/google-ai-edge/mediapipe) |
| `python-sounddevice` | pypi | [sounddevice](https://pypi.org/project/sounddevice/) |
| `python-terminaltexteffects` | pypi | [terminaltexteffects](https://pypi.org/project/terminaltexteffects/) |
| `spotify` | debian (auto-merge) | [https://repository.spotify.com/dists/testing/non-free/binary-amd64/Packages](https://repository.spotify.com/dists/testing/non-free/binary-amd64/Packages) |
| `sublime-text-4` | json (auto-merge) | [https://www.sublimetext.com/updates/4/stable_update_check](https://www.sublimetext.com/updates/4/stable_update_check) |
| `sunshine` | github | [SunshineStream/Sunshine](https://github.com/SunshineStream/Sunshine) |
| `ttf-ia-writer` | git_branch | [https://github.com/iaolo/iA-Fonts.git](https://github.com/iaolo/iA-Fonts.git) `master` |
| `tuxedo-drivers-nocompatcheck-dkms` | git_tags | [https://gitlab.com/kronerm/tuxedo-drivers-nocompatcheck.git](https://gitlab.com/kronerm/tuxedo-drivers-nocompatcheck.git) |
| `typora` | debian (auto-merge) | [https://downloads.typora.io/linux/Packages](https://downloads.typora.io/linux/Packages) |
| `ufw-docker` | git_tags | [https://github.com/chaifeng/ufw-docker.git](https://github.com/chaifeng/ufw-docker.git) |
| `vi` | regex | [https://sources.archlinux.org/other/vi/](https://sources.archlinux.org/other/vi/) |
| `visual-studio-code-bin` | json (auto-merge) | [https://update.code.visualstudio.com/api/update/linux-deb-x64/stable/latest](https://update.code.visualstudio.com/api/update/linux-deb-x64/stable/latest) |
| `walker` | github | [abenz1267/walker](https://github.com/abenz1267/walker) |
| `xpadneo-dkms` | github | [atar-axis/xpadneo](https://github.com/atar-axis/xpadneo) |
| `yaru-icon-theme` | git_tags | [https://github.com/ubuntu/yaru.git](https://github.com/ubuntu/yaru.git) |
| `yay` | github | [Jguer/yay](https://github.com/Jguer/yay) |
| `zen-browser-bin` | github (auto-merge) | [zen-browser/desktop](https://github.com/zen-browser/desktop) |

Notable non-AUR branch watches: `omarchy-dev` and `omarchy-settings-dev` watch
[omacom/omarchy](https://github.com/omacom/omarchy) `quattro` on the
`five-minute` lane (auto-merge), and `omasnap-git` watches
[omacom/omasnap](https://github.com/omacom/omasnap) `main` on the `hourly` lane
(auto-merge).

### Asahi-derived packages

Apple Silicon userland and audio packages originally taken from Asahi Linux's Arch packages watch their own upstreams. Every one carries `"review": true`, so every bump opens as a draft PR for the owner (see [Reviewed updates](#reviewed-updates)). The reference recipe stays asahi-alarm's [PKGBUILDs](https://github.com/asahi-alarm/PKGBUILDs). Before marking a bump ready, compare its directory there for new patches, dependencies or install steps. A watch moves only `pkgver`, `pkgrel`, declared variables and source checksums.

| Package | Provider | Upstream | asahi-alarm recipe |
|---|---|---|---|
| `aurora-scripts` | git_tags (review) | [asahi-alarm/asahi-scripts](https://github.com/asahi-alarm/asahi-scripts) | [asahi-scripts](https://github.com/asahi-alarm/PKGBUILDs/tree/main/asahi-scripts) |
| `aurora-fwextract` | git_tags (review) | [asahi-alarm/asahi-alarm-installer](https://github.com/asahi-alarm/asahi-alarm-installer) `v` tags | [asahi-fwextract](https://github.com/asahi-alarm/PKGBUILDs/tree/main/asahi-fwextract) |
| `lzfse` | git_tags (review) | [lzfse/lzfse](https://github.com/lzfse/lzfse) `lzfse-` tags | [lzfse](https://github.com/asahi-alarm/PKGBUILDs/tree/main/lzfse) |
| `speakersafetyd` | git_tags (review) | [AsahiLinux/speakersafetyd](https://github.com/AsahiLinux/speakersafetyd) | [speakersafetyd](https://github.com/asahi-alarm/PKGBUILDs/tree/main/speakersafetyd) |
| `bankstown` | git_tags (review) | [chadmed/bankstown](https://github.com/chadmed/bankstown) | [bankstown](https://github.com/asahi-alarm/PKGBUILDs/tree/main/bankstown) |
| `triforce-lv2` | git_tags (review) | [chadmed/triforce](https://github.com/chadmed/triforce) | [triforce-lv2](https://github.com/asahi-alarm/PKGBUILDs/tree/main/triforce-lv2) |
| `muvm` | git_tags (review) | [AsahiLinux/muvm](https://github.com/AsahiLinux/muvm) `muvm-` tags | [muvm](https://github.com/asahi-alarm/PKGBUILDs/tree/main/muvm) |
| `fex-emu` | git_tags (review) | [FEX-Emu/FEX](https://github.com/FEX-Emu/FEX) `FEX-` tags | [FEX-Emu](https://github.com/asahi-alarm/PKGBUILDs/tree/main/FEX-Emu) |
| `widevine` | regex (review) | asahi-alarm's [widevine/PKGBUILD](https://raw.githubusercontent.com/asahi-alarm/PKGBUILDs/main/widevine/PKGBUILD) | the same file |

- `widevine` has no upstream of its own that we can follow: Google's CDM comes from a Lacros image that asahi-alarm picks. The watch reads asahi-alarm's `pkgver`, `_lacros_version` and first `sha256sums_aarch64` entry into our `pkgver`, `_lacros_version` and `_lacros_sha256`. `_lacros_revision` is the Lacros version as one number (`120.0.6098.0` is `1200060980000`), declared as the watch's revision. So when asahi-alarm moves to a newer Lacros without a new `pkgver`, the PR bumps `pkgrel`. If they change only the sha256, or go back to an older Lacros, the watch fails, so the change is never skipped quietly. A change to their `widevine_fixup.py` isn't picked up: compare it when reviewing.
- `speakersafetyd` carries asahi-alarm's J504 patch. A release that already includes it fails to patch: drop the patch on the PR branch.
- The Aurora recipes (`linux-aurora`, `m1n1-aurora`, `uboot-aurora` and the rest) stay pinned by hand.

## Manual holds (`"sync": false`)

**Previously excluded AUR packages (8):** `libfprint-git`, `libretro-cap32-git`,
`libretro-database-git`, `libretro-fbneo-git`, `libretro-uae-git`,
`libretro-vice-git`, `quickshell-git`, `supergfxctl`. These were already
excluded from automatic AUR updates and retain manual maintenance holds.

**Held packages carrying a declared upstream watch, provider, or hook (7):**
- `cua-driver-bin`: Omarchy bumps it by hand after verifying Hyprland
  compatibility; keeps its `.omarchy/upstream.sh` hook and `min_release_age`,
  so lifting the hold means removing `"sync": false`. `cua-hyprland-plugin`
  declares no upstream source and is rebuilt by `sync-rebuilds` when Hyprland
  or its ABI packages move.
- `omarchy-mlx`: its wheel filename carries a per-build stamp
  (`mlx_omarchy-0.32.4.dev202610050725+5c15fba-…`) that a tag watch cannot
  derive, so the maintainer repins `_wheel`, the vendor tar, and checksums
  together. Keeps its watch until wheel names follow the release version.
- `hyprland` and `wlroots0.20`: compositor/ABI pins bumped manually with their
  ecosystem and rebuild set.
- `linuxqq`, `spark-hwmon-dkms`, and `yt6801-dkms`: retain their watch
  declarations while held for manual verification.

**Hardware, boot, firmware, and pinned local holds without upstream watches (22):**
- Apple Silicon / Aurora boot, kernel, audio, and graphics: `alsa-ucm-conf-aurora`,
  `aurora-audio`, `aurora-bless`, `linux-aurora`, `m1n1-aurora`, `mesa-aurora`,
  `omarchy-aurora-firmware`, `uboot-asahi`, `uboot-aurora`. (`m1n1-aurora` and
  `uboot-asahi` are Apple Silicon boot code qualified by cold boot on
  qualification Macs in `edge` before promotion to `rc` or `stable`; see
  `pkgbuilds/m1n1-aurora/README.md`.)
- Apple T2 Mac support: `apple-bcm-firmware-fetcher`, `apple-t2-audio-config`,
  `linux-t2`, `t2fanrd`.
- Platform audio, firmware, and hardware daemons: `alsa-ucm-conf`,
  `linux-firmware-cirrus-dx13260`,
  `raspberry-pi-4-bluetooth-firmware`, `speakerguardd`.
- Benchmarks, toolkits, and local apps: `aura`, `geekbench`, `geekbench6`,
  `omarchy-amiga-screensaver`, `openvino-genai`.

## Package-specific boundaries

- `nvidia-580xx-utils` (building `nvidia-580xx-utils`, `nvidia-580xx-dkms`, and `opencl-nvidia-580xx`) and `lib32-nvidia-580xx-utils` serve Maxwell, Pascal, and Volta GPUs on NVIDIA's closed-source R580 branch. Turing and newer GPUs use the mainline branch (`nvidia-utils`, `lib32-nvidia-utils`, `nvidia-open-dkms`, and `linux-omarchy-nvidia-open`). Pacman `provides` and `conflicts` keep the two branches mutually exclusive on one system. GPU family detection lives in `omarchy` (`omarchy-hw-nvidia-gsp` and `omarchy-hw-nvidia-without-gsp`), not in package headers. Both 580xx recipes watch NVIDIA's GeForce Linux x64 lookup feed (GeForce 10 Series, GTX 1080) and filter it to `580.*` `XFree86` runfiles. The `download.nvidia.com/XFree86/Linux-x86_64/` index stopped regenerating on 18 November 2026. Tesla's `releases.json` includes Data Center hotfixes absent from `XFree86` and omits display-only kernel fixes. NVIDIA maintains R580 as a Long Term Support Branch with kernel compatibility and security fixes through June 2028 for Data Center. GeForce and Quadro GPUs receive critical security updates through October 2028 (NVIDIA KB 3142, KB 5676, and KB 5706). Today `nvidia-580xx-dkms` builds modules locally with DKMS. Omarchy carries `nvidia-580xx` itself so planned Secure Boot work can ship prebuilt, signed `580xx` modules with the kernel. After NVIDIA ends R580 support in 2028, forward-porting to newer kernels becomes best-effort. When R580 stops building against the current kernel, Omarchy freezes the last working 580xx package without holding back the kernel. Maxwell, Pascal, and Volta users then fall back to `nouveau` (with its Maxwell+ signed-firmware and re-clocking limits) or upgrade to a Turing+ GPU.
- The current driver follows Arch's `nvidia-utils`. Its `.omarchy/upstream.sh` runs `bin/bump-nvidia` when Arch moves, which sets the release in `nvidia-utils`, `nvidia-open-dkms`, `lib32-nvidia-utils` and every `linux-omarchy` kernel's `_nvidiaver`, bumps the kernels' `pkgrel` so their `-nvidia-open` modules are rebuilt, and swaps the checksums of NVIDIA's three files. Their `"lockstep": "nvidia"` puts all of it in one PR, which `tests/nvidia-open-lockstep.sh` holds together and which builds every kernel before it merges. An ARM patch that no longer applies leaves the PR red for a maintainer. A maintainer can run `bin/bump-nvidia <version>` the same way.
- Hardware-specific packages keep their declared architectures; this migration does not invent ARM binaries for x86-only upstreams.
- iA Duospace was deleted upstream. Its four legacy font files retain their original immutable pin while the other families track the current repository.
- Spotify uses HTTPS and retains its signed Release/Packages verification.
- Source and build compatibility still need review when upstream code changes. Direct watches remove AUR recipe churn, not the need to maintain packaging.

## How the sync PRs build

`sync-upstream.yml` (all three cadence groups) and `sync-rebuilds.yml` each run their
sync once, split the changed recipes into one PR per package with
`.github/scripts/package-pr-groups.sh`, and hand them to `package-prs.yml`. That
pushes each PR as the omarchy-pkgs-sync App, so its builds start without an
approval hold. Its `arm` job then arms auto-merge as the omarchy-pkgs-merge
App, in a job of its own, since a job has one environment. It finds each
group's PR from this repository into `master` and judges it by the same rule
as `auto-merge-pr.yml`, then arms the head it judged. A push to an `auto/sync-*` or
`auto/track-branches-*` branch does not cancel the PR's build in flight: the new
build waits, then reuses every artifact the finished one uploaded.

Each PR's description comes from `helpers/sync-pr-body.py`, which compares the
group's recipes and `.omarchy/package.json` with `master`. It works the same for
every source type, hooks and rebuilds included, and shows:

- each package's old and new version, with the kind of jump for dotted versions;
- the source: the GitHub repository, tag or branch, the npm or PyPI package, or
  the feed URL;
- the pinned variables the sync rewrote, and each source whose URL or checksum
  changed, per architecture;
- for a rebuild, the dependencies in `rebuilt_against` that moved;
- the architectures, and the channels the package ships to on merge;
- how the new bytes were checked: against GitHub's asset digests, by the
  recorded checksums, and by `validpgpkeys`.

When a source is a tag on GitHub, the description links the release and the
compare view, and shows the release notes. The notes sit in a 4-space indented
code block, capped at 40 lines or 4,000 characters, so they render as plain
text. A hidden comment at the end repeats
the facts as JSON. If the script fails, the PR still opens with the plain body.

A red PR stays open for a maintainer and holds back only its own package (or
branch/lockstep PR group). A later run updates it if upstream moves again, and
`close-superseded` closes any unrefreshed PR once it conflicts with `master` or
its edits have already landed on `master`. A
run started by hand with `packages` updates the same
per-package PRs a scheduled run would.

## Declarative providers and hooks

The older provider form, still in use beside `upstream.watch`. Give a new
package an `upstream.watch`; `helpers/upstream-watch.py check` validates that
form only.

```bash
bin/sync-upstream                       # Update every package with an upstream watch, provider, or hook
bin/sync-upstream openai-codex-desktop  # Update specific packages
```

A package declares where its releases come from either as data or, for an
unusual feed, a small hook.

A vendor shipping tagged GitHub releases is pure data, declared as `upstream`
in `.omarchy/package.json` with no code at all:

```json
"upstream": {
  "github": "jdx/mise",
  "checksums": "SHASUMS256.txt",
  "assets": {
    "x86_64": "mise-{tag}-linux-x64.tar.xz",
    "aarch64": "mise-{tag}-linux-arm64.tar.xz"
  }
}
```

`checksums` names the manifest asset the vendor publishes. A vendor publishing
none sets `"digests": true` instead, and the checksums come from the SHA-256
digest GitHub's release API reports for every asset — see
`pkgbuilds/schist-bin/.omarchy/package.json`. Either way the artifacts
themselves are never downloaded.

An architecture may map to an ordered array when its PKGBUILD downloads more
than one release asset. Small versioned files outside the release assets can be
listed under `sources` and are downloaded and hashed when a new version appears:

```json
"upstream": {
  "github": "owner/project",
  "digests": true,
  "assets": {
    "x86_64": ["tool-{pkgver}-x86_64", "tool-{pkgver}-x86_64.asc"],
    "aarch64": ["tool-{pkgver}-aarch64", "tool-{pkgver}-aarch64.asc"]
  },
  "sources": {
    "any": ["https://raw.githubusercontent.com/owner/project/{tag}/LICENSE"]
  }
}
```

Asset and source keys must be disjoint because each key maps to one PKGBUILD
checksum array (`any` means the unsuffixed `sha256sums`).

Repositories whose historical releases use incompatible tag schemes may set
`"latest_only": true`. The provider then considers only the newest stable
GitHub release, while retaining all validation for that release. A quarantine
will wait for that release to age instead of falling back to an older one.

`{tag}` and `{pkgver}` interpolate into asset names; a leading `v` on the tag is
stripped for `pkgver`; drafts and prereleases are ignored. Only the 100 most
recent releases are considered. The provider fails closed on anything it cannot
read — an unusable tag, timestamp, or checksum stops the sync rather than being
skipped.

Projects that publish version tags but no checksum manifest can declare the
tag repository, the exact tag shape, and every source that should be hashed:

```json
"upstream": {
  "git_tags": "https://github.com/owner/project.git",
  "tag_pattern": "v{pkgver}",
  "sources": {
    "any": ["https://github.com/owner/project/archive/refs/tags/{tag}.tar.gz"]
  }
}
```

The newest matching tag is selected with pacman's `vercmp`; unrelated tags are
ignored. `tag_pattern` must contain exactly one `{pkgver}`. Source templates may
use `{tag}` and `{pkgver}`. Each expanded URL must be HTTPS and is downloaded
only when the discovered version is newer. A checked-in patch or other local
source can be included as `file:patch-name.patch`; it is hashed from the package
directory. Keys such as `any`, `x86_64`, and `aarch64` select the corresponding
`sha256sums` array.

npm packages use the same source mapping, with `{npm_tarball}` available for
the tarball named by the selected dist-tag:

```json
"upstream": {
  "npm": "@scope/package",
  "dist_tag": "latest",
  "sources": {
    "any": ["{npm_tarball}", "https://example.com/v{pkgver}/CHANGELOG.md"]
  }
}
```

`dist_tag` defaults to `latest`. The registry's publication timestamp is
carried into the provider result, so `min_release_age` works for npm packages.

A vendor with a plain-text Debian `Packages` index can use it to discover the
newest exact package version, then hash immutable source URLs:

```json
"upstream": {
  "debian": "https://example.com/debian/dists/stable/main/binary-amd64/Packages",
  "package": "example-app",
  "sources": {
    "x86_64": ["https://example.com/tool-{pkgver}-x64.tar.gz"],
    "aarch64": ["https://example.com/tool-{pkgver}-arm64.tar.gz"]
  }
}
```

This legacy provider deliberately accepts only Debian versions that are already
valid Arch `pkgver` values. Feeds needing revision or filename translation
should use `upstream.watch` (`debian` with `pattern`, `revision`, and
`revision_variable`, as `google-chrome` and `microsoft-edge-stable-bin` do) or
a hook. Exactly one of `watch`, `github`, `git_tags`, `npm`, or `debian` may
appear in a declaration.

A timestamped provider may also declare `"min_release_age": "24h"`
(`s`/`m`/`h`/`d` suffix or bare seconds) to quarantine fresh releases until
maintainers have had time to pull a bad or compromised one. GitHub Releases and
npm provide publication times; raw git tags and Debian Packages indexes do not,
so combining either with this policy fails closed. The newest release that has
cleared the window ships, so a fast release cadence cannot starve updates. The
window is enforced
centrally: whatever reports the release must prove its age via `published_at`,
or the sync fails. A maintainer deliberately shipping inside the window runs
`BYPASS_MIN_RELEASE_AGE=1 bin/sync-upstream <package>` locally and merges the
result through a normal PR; scheduled automation never sets the bypass.

A vendor whose feed fits no convention (such as an OSTree repository or a
multi-feed manifest) instead provides `.omarchy/upstream.sh`, a hook that reports the
newest upstream release as JSON on stdout — declaring both an `upstream` block
and a hook is an error:

```json
{
  "pkgver": "1.2.3",
  "sha256sums": { "x86_64": ["<sha256>"], "aarch64": ["<sha256>"] }
}
```

Architecture keys become `sha256sums_<arch>` in the PKGBUILD; the key `any` means
the unsuffixed `sha256sums` array, and only the arrays a hook names are touched.
An empty object (`{}`) reports no update, which is how a hook waits out a release
that has landed for one architecture but not yet the other.

When the reported version is newer than the checked-in one, `bin/sync-upstream`
rewrites `pkgver` and those checksum arrays and resets `pkgrel` to 1. A hook may
also report an explicit `"pkgrel"` for a same-`pkgver` rebuild (such as
`notion-desktop` advancing off a pruned OSTree commit) when `vercmp` confirms
`pkgver-pkgrel` increases. An equal or older release leaves the package alone,
so a vendor rolling a release back cannot walk the repository backwards.

Hooks should read checksums from whatever manifest the vendor publishes rather
than downloading the artifacts — see `pkgbuilds/openai-codex-desktop/.omarchy/upstream.sh`,
which reads OpenAI's Debian package index and never fetches the 750 MB of debs
it describes. Hooks honoring `min_release_age` receive the window as
`MIN_RELEASE_AGE_SECONDS` and report `published_at` alongside `pkgver`.

`grok-bot` cannot follow that pattern. Cursor's apt index lags the Linux update
feed the app itself follows, and the feed's digest is for an AppImage.
`pkgbuilds/grok-bot/.omarchy/upstream.sh` reads the x64 and arm64 feeds, waits
until both name the same version and commit, and downloads the two `.deb`s at
that commit only when the version is newer than the recipe. The hook writes
`_commit` itself: `bin/sync-upstream` rewrites `pkgver` and the checksum arrays,
not other recipe variables, and the source URL is
`downloads.cursor.com/grokbot/stable/<commit>/`. An hourly run that is already
current does not download the debs.

`bin/sync-upstream self-test` runs offline fixture tests over the release
selection, quarantine backstop, duration parsing, and manifest validation.
