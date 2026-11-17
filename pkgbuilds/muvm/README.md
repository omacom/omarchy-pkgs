# Omarchy downstream muvm

This recipe builds the upstream `muvm-0.7.0` release with an Omarchy-maintained
session D-Bus patch. Version `0.7.0-2` upgrades `asahi-alarm`'s `0.7.0-1` using
the same package name and installed paths. It preserves both muvm binaries,
the MIT license, and the WirePlumber integration.

`muvm --session-bus -- COMMAND` enables the host user's session bus when starting
a new VM. This lets applications such as Steam register their tray icons with
the host bar. The bridge rejects Unix file descriptor negotiation, which vsock
cannot carry. It accepts a single `unix:path` session-bus address and falls back
to `$XDG_RUNTIME_DIR/bus` when the address is unset. The system bus is not
forwarded. The feature is optional and grants guest applications access to host
session services; restart an existing VM to change whether it is enabled.

The accompanying `omarchy-steam-fex` package enables the bridge when the host
session bus is available and this muvm build advertises support.

The patch was developed with substantial LLM assistance. Its original
[upstream PR #251](https://github.com/AsahiLinux/muvm/pull/251) was closed after
the contributor disclosed that assistance under
[Asahi Linux's LLM policy](https://asahilinux.org/llm-policy/). This is a
downstream proposal, with no upstream acceptance implied.

Automatic source updates are disabled because new muvm releases need a manual
rebase and review of this downstream patch. The package stays in the normal
release ring and declares a rebuild trigger for its native libkrun dependency.

The recipe checks source and patch checksums, builds with Cargo's lockfile and
frozen dependency resolution, and runs the workspace tests in `check()`. No VM
or hardware access is required during the package build. Runtime verification
should check Steam's host tray registration, tray menu, and guest scaling
environment on the target machine.
