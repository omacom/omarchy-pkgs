# widevine

Google's Widevine CDM for Chromium and Firefox on Apple Silicon, installed on the Mac itself. This package holds none of Google's code.

Google's terms forbid copying, modifying or distributing its software, and the CDM has to be patched to run on Asahi kernels (16K pages, missing glibc symbols). So we never host the library, never put it in an image, and never fetch it during a package or image build. The package ships only our own files and the MIT-licensed fixup script:

- `widevine-fetch` downloads the ChromeOS Lacros arm64 image pinned in the recipe (`_lacros_version`, `_lacros_sha256`) from Google's `chromeos-localmirror`, checks its sha256, extracts `libwidevinecdm.so`, patches it with David Buchanan's `widevine_fixup.py` and installs it in `/opt/WidevineCdm/chromium/_platform_specific/linux_arm64/`.
- `widevine-fetch.timer` is enabled by the package itself (image presets only cover omarchy-mac's units). It runs the fetch two minutes after boot and hourly after that. Once the library is installed, a run only checks its hash. Offline runs exit cleanly and the next run tries again.
- The fetch exits without doing anything off a booted system (a chroot, or a container with no systemd), so an image build can't trigger it. The install scriptlet only starts the timer, and only on a booted system.
- The Chromium manifest, the `/usr/lib/chromium/WidevineCdm` link, the Firefox GMP directory, prefs and `profile.d` script come from asahi-alarm's recipe. The fetch adds the links to the library, so no path in the package is named `libwidevinecdm.so`.

`sudo widevine-fetch` fetches it right away, and `--force` fetches it again. Restart the browser afterwards. Removing the package deletes the fetched library and its cache.

The recipe follows asahi-alarm's: same name and `pkgver`, a higher `pkgrel`, and `provides`/`conflicts` on `chromium-widevine`. Upgrading from asahi-alarm's build removes its packaged library, and the timer installs ours a few minutes later. `pkgver` and the manifest say 4.10.2891.0, as asahi-alarm's do. The library in Lacros 120.0.6098.0 is really 4.10.2662.3. Lacros was discontinued, so no newer arm64 image exists.
