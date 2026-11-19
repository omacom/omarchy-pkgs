# widevine

Google's Widevine CDM for Chromium and Firefox on Apple Silicon, installed on the Mac itself by the user who accepts Google's licence. This package holds none of Google's code.

Google's terms forbid copying, modifying or distributing its software, and the CDM has to be patched to run on Asahi kernels (16K pages, missing glibc symbols). So we never host the library, never put it in an image, and never fetch it during a package or image build, on a schedule, or without asking. The package ships only our own files and the MIT-licensed fixup script.

`sudo widevine-fetch`, run by the user in a terminal:

1. downloads the ChromeOS Lacros arm64 image pinned in the recipe (`_lacros_version`, `_lacros_sha256`) from Google's `chromeos-localmirror` and checks its sha256;
2. shows the licence the image carries (`WidevineCdm/LICENSE`, or a pointer to Google's Chrome terms for an image without one) and asks the user to type `accept`;
3. only then extracts `libwidevinecdm.so`, patches it with David Buchanan's `widevine_fixup.py`, and installs it in `/opt/WidevineCdm/chromium/_platform_specific/linux_arm64/`. The licence text as accepted, and who accepted it when, are kept in `/var/lib/widevine/LICENSE` and `/var/lib/widevine/accepted`.

Declining, or a run with no terminal (a script, a timer, pacman), installs nothing. A rerun after acceptance only checks the installed library's hash. `--force` downloads and asks again. Off a booted system (a chroot, or a container with no systemd) the command does nothing, so an image build can't trigger it. The install scriptlet only prints what to run.

The Chromium manifest, the `/usr/lib/chromium/WidevineCdm` link, the Firefox GMP directory, prefs and `profile.d` script come from asahi-alarm's recipe. The fetch adds the links to the library, so no path in the package is named `libwidevinecdm.so`. Removing the package deletes the fetched library, the acceptance record and the cache.

The recipe follows asahi-alarm's: same name and `pkgver`, a higher `pkgrel`, and `provides`/`conflicts` on `chromium-widevine`. Upgrading from asahi-alarm's build removes its packaged library until the user runs `sudo widevine-fetch`. 4.10.2891.0-2 fetched on a timer without asking. Upgrading from it stops the timer and removes any library installed with no acceptance record. `pkgver` and the manifest say 4.10.2891.0, as asahi-alarm's do. The library in Lacros 120.0.6098.0 is really 4.10.2662.3. Lacros was discontinued, so no newer arm64 image exists.

The pinned image's licence says you "may not use, modify, sell, or otherwise distribute the Software" without a separate Google licence. Whether a user may patch the library on their own Mac under it is an open legal question for the owner.
