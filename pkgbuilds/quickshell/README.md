# Quickshell

Omarchy builds the stable Quickshell release under its original package name. The Omarchy repository precedes Arch repositories so users receive these builds through normal package updates.

`qt-6.12.patch` backports the source changes from upstream commit [5d5d49873fe8cf1f99ddfd5006ceb2057c5c9b13](https://github.com/quickshell-mirror/quickshell/commit/5d5d49873fe8cf1f99ddfd5006ceb2057c5c9b13), which fixes linking and Qt 6.12 compatibility by replacing opaque QObject pointer declarations with MOC includes. Automatic source updates are held (`sync: false`) until a stable release includes the fix and the patch can be removed.

Quickshell uses private Qt APIs. `rebuild_on` queues a package release bump when Qt base, declarative, or Wayland changes. Build on edge and promote with its matching Arch snapshot through RC and stable; do not use the fast ring, whose older channel builds can become incompatible when a snapshot advances. Keep symbols in the binary because OPR does not publish Arch's matching debug package.
