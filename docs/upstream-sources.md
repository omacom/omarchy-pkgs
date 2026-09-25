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
`version` capture. Tag patterns match the entire tag. `version` optionally formats
those captures into an Arch pkgver; e.g. Sublime uses `4.{version}`. JSON feeds can
expose additional capture values through `fields`, a name-to-JSON-path map.

`variables` maps recipe scalars such as `_commit` or `_build` to capture templates.
Only explicitly declared underscore-prefixed variables can change. GitHub
`{commit}` resolves the selected tag, not a moving target_commitish branch.
`submodules` can map a recipe variable to a gitlink in the selected GitHub tag;
RustDesk uses this for hbb_common. Downloaded repository code is never evaluated.

For upstreams that rebuild a release, declare a numeric `revision` template and
its `revision_variable`. With unchanged pkgver, only an increasing revision can
advance that variable, and the downstream pkgrel increments instead of resetting.
Cursor CLI uses `sequence` to preserve its date/counter/hash version convention
when the vendor publishes a second hash on the same day. A new pkgver resets
pkgrel to 1, but the complete epoch:pkgver-pkgrel must still increase.

GitHub releases exclude drafts and prereleases unless `allow_prerelease` is true.
Existing `min_release_age` policies apply: a feed without a verifiable publication
time cannot bypass a configured hold. Git branch watches derive a commit count
and date from the actual branch history and write an immutable source pin.

Checksums retain their algorithms (SHA256, SHA512, BLAKE2, etc.) and source order.
Changed git sources are hashed with makepkg's git-archive convention. Unchanged
sources retain their hashes; `mutable_sources` explicitly names entries such as
`source:0` that must be fetched again for a new version despite a stable URL.
Existing `SKIP` entries remain unchanged (including signed metadata verified by
the recipe); new skips are never introduced. Changed URLs are still fetched.
A matching GitHub release asset SHA256 digest avoids downloading large assets.
Missing architecture artifacts or malformed metadata fail the package atomically.
Every declared architecture must read back the same release and checksum values.

Archive watches use `member` to select a text member, or `filenames: true` to read
versions from archive member names. Debian archives are read through their control
metadata. `unescape_json` handles JSON strings embedded in a vendor's HTML page.

## Maintenance and validation

Running watches locally requires Python 3.11+, Bash, curl, git, jq, Arch's
`vercmp`, and `bsdtar`. CI installs these in its Arch container.

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

## Migrated package watches

68 active AUR packages now use direct watches. The nine previously disabled
packages retain manual maintenance holds. Historical AUR provenance is recorded
in `origin` and has no effect on release selection.

| Package | Provider | Upstream |
|---|---|---|
| `1password-beta` | debian | [https://downloads.1password.com/linux/debian/amd64/dists/beta/main/binary-amd64/Packages](https://downloads.1password.com/linux/debian/amd64/dists/beta/main/binary-amd64/Packages) |
| `1password-cli` | json | [https://app-updates.agilebits.com/check/1/0/CLI2/en/0](https://app-updates.agilebits.com/check/1/0/CLI2/en/0) |
| `aether` | github | [omacom/aether](https://github.com/omacom/aether) |
| `asusctl` | git_tags | [https://github.com/OpenGamingCollective/asusctl.git](https://github.com/OpenGamingCollective/asusctl.git) |
| `basecamp-cli` | github | [basecamp/basecamp-cli](https://github.com/basecamp/basecamp-cli) |
| `bun-bin` | github | [oven-sh/bun](https://github.com/oven-sh/bun) |
| `claude-code` | regex | [https://downloads.claude.ai/claude-code-releases/latest](https://downloads.claude.ai/claude-code-releases/latest) |
| `cliamp` | github | [bjarneo/cliamp](https://github.com/bjarneo/cliamp) |
| `crush-bin` | github | [charmbracelet/crush](https://github.com/charmbracelet/crush) |
| `cursor-bin` | json | [https://www.cursor.com/api/download?platform=linux-x64&releaseTrack=stable](https://www.cursor.com/api/download?platform=linux-x64&releaseTrack=stable) |
| `cursor-cli` | regex | [https://cursor.com/install](https://cursor.com/install) |
| `dbxcli-bin` | github | [dropbox/dbxcli](https://github.com/dropbox/dbxcli) |
| `dropbox` | redirect | [https://www.dropbox.com/download?plat=lnx.x86_64](https://www.dropbox.com/download?plat=lnx.x86_64) |
| `dropbox-cli` | regex | [https://linux.dropbox.com/packages/](https://linux.dropbox.com/packages/) |
| `elephant` | github | [abenz1267/elephant](https://github.com/abenz1267/elephant) |
| `elephant-all` | github | [abenz1267/elephant](https://github.com/abenz1267/elephant) |
| `elephant-archlinuxpkgs` | github | [abenz1267/elephant](https://github.com/abenz1267/elephant) |
| `elephant-bluetooth` | github | [abenz1267/elephant](https://github.com/abenz1267/elephant) |
| `elephant-calc` | github | [abenz1267/elephant](https://github.com/abenz1267/elephant) |
| `elephant-clipboard` | github | [abenz1267/elephant](https://github.com/abenz1267/elephant) |
| `elephant-desktopapplications` | github | [abenz1267/elephant](https://github.com/abenz1267/elephant) |
| `elephant-files` | github | [abenz1267/elephant](https://github.com/abenz1267/elephant) |
| `elephant-menus` | github | [abenz1267/elephant](https://github.com/abenz1267/elephant) |
| `elephant-providerlist` | github | [abenz1267/elephant](https://github.com/abenz1267/elephant) |
| `elephant-runner` | github | [abenz1267/elephant](https://github.com/abenz1267/elephant) |
| `elephant-symbols` | github | [abenz1267/elephant](https://github.com/abenz1267/elephant) |
| `elephant-todo` | github | [abenz1267/elephant](https://github.com/abenz1267/elephant) |
| `elephant-unicode` | github | [abenz1267/elephant](https://github.com/abenz1267/elephant) |
| `elephant-websearch` | github | [abenz1267/elephant](https://github.com/abenz1267/elephant) |
| `heroic-games-launcher-bin` | github | [Heroic-Games-Launcher/HeroicGamesLauncher](https://github.com/Heroic-Games-Launcher/HeroicGamesLauncher) |
| `hyprshade` | pypi | [hyprshade](https://pypi.org/project/hyprshade/) |
| `lib32-nvidia-580xx-utils` | regex | [https://download.nvidia.com/XFree86/Linux-x86_64/](https://download.nvidia.com/XFree86/Linux-x86_64/) |
| `limine-mkinitcpio-hook` | git_tags | [https://gitlab.com/Zesko/limine-entry-tool.git](https://gitlab.com/Zesko/limine-entry-tool.git) |
| `limine-snapper-sync` | git_tags | [https://gitlab.com/Zesko/limine-snapper-sync.git](https://gitlab.com/Zesko/limine-snapper-sync.git) |
| `lmstudio-bin` | regex | [https://lmstudio.ai/download](https://lmstudio.ai/download) |
| `localsend` | github | [localsend/localsend](https://github.com/localsend/localsend) |
| `localsend-bin` | github | [localsend/localsend](https://github.com/localsend/localsend) |
| `macbook12-spi-driver-dkms` | git_branch | [https://github.com/marc-git/macbook12-spi-driver.git](https://github.com/marc-git/macbook12-spi-driver.git) |
| `makima-bin` | github | [cyber-sushi/makima](https://github.com/cyber-sushi/makima) |
| `minecraft-launcher` | archive | [https://launcher.mojang.com/download/Minecraft.deb](https://launcher.mojang.com/download/Minecraft.deb) |
| `nautilus-dropbox` | github | [dropbox/nautilus-dropbox](https://github.com/dropbox/nautilus-dropbox) |
| `nautilus-open-any-terminal` | git_tags | [https://github.com/Stunkymonkey/nautilus-open-any-terminal.git](https://github.com/Stunkymonkey/nautilus-open-any-terminal.git) |
| `nordvpn-bin` | debian | [https://repo.nordvpn.com/deb/nordvpn/debian/dists/stable/main/binary-amd64/Packages](https://repo.nordvpn.com/deb/nordvpn/debian/dists/stable/main/binary-amd64/Packages) |
| `nvidia-580xx-utils` | regex | [https://download.nvidia.com/XFree86/Linux-x86_64/](https://download.nvidia.com/XFree86/Linux-x86_64/) |
| `omarchy-chromium-bin` | github | [omacom/omarchy-chromium](https://github.com/omacom/omarchy-chromium) |
| `omarchy-emacs` | git_tags | [https://github.com/scottjones/omarchy-emacs.git](https://github.com/scottjones/omarchy-emacs.git) |
| `omazed` | git_tags | [https://github.com/aps6/omazed.git](https://github.com/aps6/omazed.git) |
| `once-bin` | github | [basecamp/once](https://github.com/basecamp/once) |
| `openai-codex-bin` | github | [openai/codex](https://github.com/openai/codex) |
| `python-mediapipe` | github | [google-ai-edge/mediapipe](https://github.com/google-ai-edge/mediapipe) |
| `python-sounddevice` | pypi | [sounddevice](https://pypi.org/project/sounddevice/) |
| `python-terminaltexteffects` | pypi | [terminaltexteffects](https://pypi.org/project/terminaltexteffects/) |
| `rustdesk` | github | [rustdesk/rustdesk](https://github.com/rustdesk/rustdesk) |
| `spotify` | debian | [https://repository.spotify.com/dists/testing/non-free/binary-amd64/Packages](https://repository.spotify.com/dists/testing/non-free/binary-amd64/Packages) |
| `sublime-text-4` | json | [https://www.sublimetext.com/updates/4/stable_update_check](https://www.sublimetext.com/updates/4/stable_update_check) |
| `sunshine` | github | [LizardByte/Sunshine](https://github.com/LizardByte/Sunshine) |
| `ttf-ia-writer` | git_branch | [https://github.com/iaolo/iA-Fonts.git](https://github.com/iaolo/iA-Fonts.git) |
| `tuxedo-drivers-nocompatcheck-dkms` | git_tags | [https://gitlab.com/kronerm/tuxedo-drivers-nocompatcheck.git](https://gitlab.com/kronerm/tuxedo-drivers-nocompatcheck.git) |
| `typora` | debian | [https://downloads.typora.io/linux/Packages](https://downloads.typora.io/linux/Packages) |
| `ufw-docker` | git_tags | [https://github.com/chaifeng/ufw-docker.git](https://github.com/chaifeng/ufw-docker.git) |
| `vi` | regex | [https://sources.archlinux.org/other/vi/](https://sources.archlinux.org/other/vi/) |
| `visual-studio-code-bin` | json | [https://update.code.visualstudio.com/api/update/linux-deb-x64/stable/latest](https://update.code.visualstudio.com/api/update/linux-deb-x64/stable/latest) |
| `walker` | github | [abenz1267/walker](https://github.com/abenz1267/walker) |
| `xdg-terminal-exec` | git_tags | [https://gitlab.freedesktop.org/Vladimir-csp/xdg-terminal-exec.git](https://gitlab.freedesktop.org/Vladimir-csp/xdg-terminal-exec.git) |
| `xpadneo-dkms` | github | [atar-axis/xpadneo](https://github.com/atar-axis/xpadneo) |
| `yaru-icon-theme` | git_tags | [https://github.com/ubuntu/yaru.git](https://github.com/ubuntu/yaru.git) |
| `yay` | github | [Jguer/yay](https://github.com/Jguer/yay) |
| `yt6801-dkms` | archive | [https://www.motor-comm.com/Cn/Skippower/downloadFile.html?id=1817](https://www.motor-comm.com/Cn/Skippower/downloadFile.html?id=1817) |

## Existing manual holds

`grok-bot`, `libfprint-git`, `libretro-cap32-git`, `libretro-database-git`, `libretro-fbneo-git`, `libretro-uae-git`, `libretro-vice-git`, `quickshell-git`, `supergfxctl`.

These packages were already excluded from automatic AUR updates. The migration preserves that policy.

`linux-firmware-cirrus` is a deliberate hold: a self-retiring shim that ships Arch's linux-firmware-cirrus 20260910-2 payload to stable while stable's Arch snapshot is on 20260810-2 (Dell XPS 13 DX13260 / 1028:0e54 speaker firmware). It is versioned 20260810-3 so the genuine Arch package supersedes it as soon as the snapshot advances; bumping it to the Arch version would defeat that. Delete the recipe once stable's snapshot carries linux-firmware >= 20260910.

`m1n1-aurora` and `uboot-asahi` are deliberate holds: Apple Silicon boot code, pinned by hand like `linux-aurora`, and bumped only after a cold boot on the qualification Macs. `m1n1-aurora` pins an aurora-silicon/m1n1 commit plus a local patch. `uboot-asahi` follows asahi-alarm's recipe and patch set (asahi-alarm/PKGBUILDs), which a tag watch on AsahiLinux/u-boot cannot carry.

## Package-specific boundaries

- NVIDIA watches remain on the 580 driver branch.
- Hardware-specific packages keep their declared architectures; this migration does not invent ARM binaries for x86-only upstreams.
- iA Duospace was deleted upstream. Its four legacy font files retain their original immutable pin while the other families track the current repository.
- RustDesk reads hbb_common from the release gitlink; its existing build-time dependency/toolchain checks remain in force.
- Spotify uses HTTPS and retains its signed Release/Packages verification.
- Source and build compatibility still need review when upstream code changes. Direct watches remove AUR recipe churn, not the need to maintain packaging.
