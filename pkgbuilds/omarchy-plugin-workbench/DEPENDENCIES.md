## Companion changes and merge order

| Change | Dependency |
|---|---|
| [Workbench v0.4.0](https://github.com/tcballard/omarchy-plugin-workbench/releases/tag/v0.4.0) | The QML launcher requires the exact x86_64 helper SHA-256 `4b40638081baddafaff0c33c38917bf841923aa7a92ba0b2b9f11e021bcf402f`. |
| [Helper package #287](https://github.com/omacom/omarchy-pkgs/pull/287) | Installs that release binary byte for byte from source commit `eee779c060d8567687128c205cd8fb357c607217`. Publish before enabling the native panel for package users. |
| [Native Workbench #10027](https://github.com/omacom/omarchy/pull/10027) | Reconcile its first-party integration with the current v0.4.0 QML and helper before shipping. Its older protocol-1/Drawer proposal is not part of v0.4.0. |

The package is x86_64 only, matching the released helper. `check()` verifies the helper version and the source launcher digest. Workbench's Rust and lifecycle tests run in its own repository CI; its tagged reproducible build and release asset share the pinned binary digest. This package still needs an upstream clean Arch build and publication. Marketplace validation and maintainer approval are separate.
