# widevine

Google's Widevine CDM for Chromium and Firefox on Apple Silicon, installed by default and working on first boot, as asahi-alarm's `widevine` does on Omarchy 4.5. Omarchy's Netflix and Spotify web apps and Brave (`omarchy-install-browser`) need it for DRM playback.

The recipe follows asahi-alarm's: it downloads the ChromeOS Lacros arm64 image pinned by `_lacros_version` and `_lacros_sha256` from Google's `chromeos-localmirror`, extracts `libwidevinecdm.so`, and patches it with David Buchanan's MIT `widevine_fixup.py` for 16K pages and the glibc symbols ChromeOS provides. It keeps the same name and `pkgver`, a higher `pkgrel`, and `provides`/`conflicts` on `chromium-widevine`. The Chromium manifest, the `/usr/lib/chromium/WidevineCdm` link, the Firefox GMP directory, prefs and `profile.d` script are asahi-alarm's.

One difference: the package ships the library at `/usr/lib/widevine/libwidevinecdm.so`, and the install scriptlet copies it to `/opt/WidevineCdm/chromium/_platform_specific/linux_arm64/`, adds the empty `linux_x64` placeholder Chromium needs, and links Firefox's GMP directory to it. 4.10.2891.0-2 and -3 fetched the library to those paths on the Mac, unowned, and pacman refuses to upgrade over an unowned file. Removing the package deletes them. Upgrading from -2 or -3 also stops their fetch timer and deletes their acceptance record and download cache.

The licence installed with the package is the one the Lacros image carries (`WidevineCdm/LICENSE`), plus the fixup's MIT licence. That Google licence restricts using, modifying and distributing the CDM without a separate licence from Google; the owner chose to ship it as 4.5 does.

`pkgver` and the manifest say 4.10.2891.0, as asahi-alarm's do. The library in Lacros 120.0.6098.0 is really 4.10.2662.3. Lacros was discontinued, so no newer arm64 image exists.
