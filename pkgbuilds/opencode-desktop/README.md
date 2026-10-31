# OpenCode Desktop

Repackages the official MIT-licensed Linux desktop release for x86_64 and aarch64. The Electron runtime, native PTY module, and desktop backend are upstream's; this does not build OpenCode from source.

Run `opencode-desktop`, or open OpenCode from the app launcher. On a Wayland session the launcher selects native Wayland. Optional flags go in `${XDG_CONFIG_HOME:-~/.config}/opencode-desktop-flags.conf`, separated by whitespace; blank lines and `#` comments are ignored. Command-line arguments are forwarded unchanged and an explicit Ozone platform overrides the default.

The namespace sandbox stays enabled. The launcher never supplies `--no-sandbox`. Kernels that disable unprivileged user namespaces need a sandbox policy of their own.

Updates come through pacman and the declared upstream release watch. The package disables the desktop's Debian update check, with a guarded patch that fails the build if upstream changes that call. Native PTY modules remain outside ASAR, as upstream requires.

This package does not install or replace the terminal `opencode` command. Removing it keeps OpenCode data and credentials, including data shared with the CLI, and the launcher flags file.
