## About

Garia is a fast, easy, and free download manager for macOS and Linux. It is built on [aria2](https://aria2.github.io/) and wrapped in a [Tauri](https://tauri.app/) native app.

Garia manages aria2 automatically — it ships its own copy inside the app and starts it with the app. Closing the window leaves downloads running; Quit is what stops them. You never have to touch the command line to download a file.

![Garia downloading files](docs/images/downloading.png)

It comes as:

 * A native GUI application (macOS `.dmg`, Linux AppImage and `.deb`)
 * A browser capture extension for Chrome, Firefox, Edge, Brave, Arc, and Safari
 * Bundled aria2, ffmpeg, and yt-dlp sidecars

This is an **alpha**. Pre-built installers are on the [Releases](https://github.com/fabimc/garia/releases) page.

### macOS

Install with Homebrew from the [personal tap](https://github.com/fabimc/homebrew-garia) after a GitHub Release is published:

```sh
brew tap fabimc/garia
brew trust fabimc/garia
brew install --cask garia
```

### Linux

Grab the `.AppImage` (run anywhere) or the `.deb` (Debian/Ubuntu — preferred if you want `garia://`, magnet, and `.torrent` associations) from [Releases](https://github.com/fabimc/garia/releases).

Visit https://fabimc.github.io/garia/ for the download, a feature tour, and the FAQ, or https://github.com/fabimc/garia for source, issues, and releases.

## Documentation

[Garia's documentation](docs/README.md) is the place for features, building, the bundled tools, and the browser extension.

Intent for agents and contributors lives in [`src/md/`](src/md/README.md) ([srcmd.org](https://srcmd.org/) layout). Change that Markdown first, then derive code and tests from it. Formal docs stay in `docs/`.

## Building

Garia builds from the command line with Tauri.

For a more detailed description, dependencies, sidecar notes, signing, and the release workflow, visit [Building Garia](docs/Building.md) in docs.

### Requirements (macOS)

| Tool | Version | Install |
|------|---------|---------|
| macOS | 11.0+ | — |
| [Xcode Command Line Tools](https://developer.apple.com/xcode/) | — | `xcode-select --install` |
| [Rust](https://www.rust-lang.org/) | 1.70+ | `brew install rust` |
| [Node.js](https://nodejs.org/) | 18+ | `brew install node` |

### Requirements (Linux)

| Tool | Version | Install (Debian/Ubuntu) |
|------|---------|-------------------------|
| Rust | 1.70+ | [rustup](https://rustup.rs/) |
| Node.js | 18+ | distro package or nvm |
| WebKitGTK / build deps | — | `libwebkit2gtk-4.1-dev libssl-dev libayatana-appindicator3-dev librsvg2-dev patchelf pkg-config build-essential` |

aria2 and ffmpeg are not on those lists. Garia builds both and bundles them — see [Sidecars](docs/Sidecars.md). Video pages also need [yt-dlp](https://github.com/yt-dlp/yt-dlp); a copy is fetched into the bundle, and a `yt-dlp` on `PATH` is preferred if you have one. Linux needs a `python3` 3.10+ for the bundled zipapp.

### Building Garia from Git (first time)

```sh
git clone https://github.com/fabimc/garia.git
cd garia
npm install
npm run tauri dev
```

The first run takes a few minutes while Cargo compiles the Tauri runtime and the sidecar scripts build aria2 and ffmpeg. Subsequent runs are fast — the scripts are no-ops once the binaries exist.

### Building a Garia release from the command line

```sh
npm run tauri build
```

On macOS that produces an `.app` and a `.dmg`. On Linux it produces an AppImage and a `.deb`. Artifacts land under `src-tauri/target/release/bundle/`.

A universal Mac binary (Apple Silicon and Intel) is a second target:

```sh
rustup target add x86_64-apple-darwin
npm run tauri build -- --target universal-apple-darwin
```

The result lands under `src-tauri/target/universal-apple-darwin/release/bundle/` and runs natively on both chips. A release tag builds Mac and Linux on CI.

## Contributing

Bug reports and pull requests are welcome.

 * Check [existing issues](https://github.com/fabimc/garia/issues) before opening a new one.
 * Intent for modules and features lives in `src/md/` ([srcmd.org](https://srcmd.org/)). Curate that first when changing behavior.
 * User-facing documentation lives in `docs/`. Fixes and new pages there are as useful as code.
 * The [browser extension store checklist](docs/Publishing-the-Extension.md) is the path to Chrome Web Store and addons.mozilla.org.
 * The website lives in `site/` — plain HTML and CSS, no build step. A push to `master` that touches it deploys it to GitHub Pages through `.github/workflows/pages.yml`.

Garia is [MIT](LICENSE). The copy of aria2 inside the app is GPL-2.0-or-later, ffmpeg is LGPL-2.1, and yt-dlp is Unlicense.
