# CUA Driver accessibility patches

This experimental x86_64 recipe builds the CLI and SDK from the checksummed
`cua-driver-rs-v0.28.2` source archive and retains the matching vendor bundle's
companion assets. The first three patches apply in the order below; the fourth adds the editable-text contract described separately. The Hyprland
plugin and Atreyu are unchanged.

## Problems and repairs

1. **Chromium window identity and missing children**
   (`chromium-accessibility.patch`). Hyprland can expose a page title while
   AT-SPI appends a browser profile or audio decoration. Exact equality rejects
   the association, returning `accessibility_window_identity_unproven` and no
   usable element tokens. Chromium can also report a child that initially reads
   as null. Requesting BrowserRootView attributes enables fuller publication.
   Decorated-title matching requires a verified Chromium executable,
   BrowserRootView, matching dimensions and uniqueness among compositor windows
   and accessible frames. Ambiguous titles still refuse.

2. **Unrelated windows exhaust the requested window's budget**
   (`exact-window-snapshots.patch`). The previous walker traversed every window
   in the process under one budget before filtering to the requested window.
   A large earlier sibling could starve a small later target. Four retries of
   the same exhausted walk then produced the misleading
   `x11_property_fallback_partial: AT-SPI was unavailable` result.
   The walker now proves the exact frame first and budgets only that subtree.
   Capture reports node, depth, deadline and partial-read reasons with traversal
   counts; deterministic exhaustion does not trigger four full retries.
   Bounded readiness retries share one overall deadline. Screenshot-only
   capture skips AT-SPI.

   This also repairs **snapshot-to-action identity**: scoped indexes cannot
   safely be interpreted by an application-wide re-walk. Snapshots retain
   native targets, and both element tokens and legacy index-plus-snapshot
   arguments resolve through that mapping. Indexed click, editing, focus,
   bounds, scrolling, hit-testing, browser helpers and recording share it.
   Dispatch rechecks process, connection, exact window, ancestry and defunct
   state. Missing targets never become same-label replacements.
   `type_text_chars` rejects previously ignored element arguments; callers
   should use snapshot-targeted `type_text`.

3. **One malformed Hyprland window hides all other windows**
   (`hyprland-unusable-geometry.patch`). A mapped client with negative width
   caused unsigned conversion to abort the entire window list. Keep that
   client's identity with zero bounds and nonvisible status, while refusing its
   unusable geometry. Valid windows remain discoverable. Invalid-geometry
   title competitors and exported-handle collisions still participate in
   ambiguity checks.

4. **Editable text is missing and replacement can append**
   (`editable-text-contract.patch`). Native Text was used only as fallback
   display text, and empty structured values were discarded. Rows now expose
   actual text, editability, completeness and native provenance separately.
   `set_value` no longer falls back to insertion at the caret; native replacement
   requires fresh complete readback before confirmation. Chromium Text-only
   fields explicitly refuse unsupported replacement. See [EDITABLE-TEXT.md](EDITABLE-TEXT.md)
   for the exact JSON fields, examples and verification boundaries.

## Packaging and updates

Build with `bin/build --package cua-driver-bin`. Both CLI and SDK are rebuilt
with the locked dependencies. `check()` covers native traversal/text, observation rows, replacement outcomes, browser helper guards, Hyprland and core verification/snapshot invariants. LTO is disabled
because makepkg's GCC LTO objects from ring/zstd cannot be linked by Rust's lld.
The pacman updater stub and companion assets are preserved.

This keeps the local experimental `0.28.2-1.3` candidate version and x86_64-only architecture
for review. ARM is unbuilt. Automatic updates are held with `sync: false`:
the existing release hook updates vendor checksums but cannot rebase these
patches or refresh the source archive checksum. Remove the hold only after
qualifying a replacement recipe or an upstream release containing the fixes.

## Prior three-patch verification

- 146 focused checks passed: 73 Linux AT-SPI/cache/retry, 20 Hyprland, one
  character-typing regression, 13 snapshot/dispatch/session, 23 token/runtime
  identity, 12 KWin helper contract, three protocol schema and one sanitized
  AT-SPI startup check. The startup check requires `NO_AT_BRIDGE` and
  `AT_SPI_BUS_ADDRESS` to be unset; the inherited disabled-bridge environment
  initially failed it for both baseline and candidate.
- Applying all three patches to pristine upstream files reproduced the eight
  reviewed source files byte for byte. The built CLI and SDK had no missing
  libraries; the updater rewrite and unchanged helper assets were checked.
- The packaged CLI ran through persistent `mcp --direct` in Atreyu's sanitized
  environment, using disposable Chromium windows and a loopback fixture with
  an independent DOM action journal. A small later target remained capturable
  at 2,500/default limits while an earlier sibling grew from 6,000 to 10,000
  controls. The same retained Search token clicked the target after growth,
  before recapture, with zero sibling actions. DOM reordering, sibling insertion
  and legacy index-plus-snapshot dispatch also passed.
- Stale tokens, wrong windows, destroyed targets and duplicate titles refused;
  same-label replacements received no clicks. Native slider value 37 was
  verified independently through the DOM journal and fresh accessibility state.
  Node/depth limits reported explicit reasons; screenshot-only returned no
  snapshot. Raw browser captures are private and are not included here.
- The local package was installed, all 21 package files passed integrity
  checking, and the restarted service executable matched the tested artifact.

Capture samples at 2,500/default limits were 62/63 ms before sibling growth and
159/50 ms afterward; node/depth limits took 5/4 ms and screenshot-only 20 ms.
These are individual diagnostic samples, not benchmark percentiles.

## Editable-text candidate verification

The final 0.28.2-1.3 package passed 155 build checks, plus 20 token tests, three
protocol-token tests against its extracted CLI, and one source-build AT-SPI
startup integration test (179 focused checks total). The exact packaged CLI
passed the owned Chromium and GTK persistent-MCP fixtures in EDITABLE-TEXT.md.
The previous multi-window persistent-MCP regression suite also passed against
that CLI. Its first cold capture took 7.986 seconds; subsequent samples were
93–237 ms (diagnostics, not percentiles).
Its SHA256 is `804f088a644083313e219d186c7fc2dcc5ca28b10eea9922c5bbce038ee2fda8`.

## Remaining qualification

This is a draft local experiment, not full release qualification. ARM, other
GUI toolkits and non-Hyprland compositors have not been live qualified. KWin
checks are contract tests only. Partial bounds remain explicit, and the driver
does not claim complete application accessibility. Chromium's fixture text
field exposes neither EditableText nor Value, so `set_value` refuses there;
the slider validates native Value dispatch. GTK verifies native text replacement; the fourth patch makes this distinction explicit. Background double/right-click
requests refuse at their backend gate and do not prove that native route live.
No broad personal-desktop recording suite was run. Atreyu/Jev candidate limits,
fallback improvements and full end-to-end product acceptance remain separate.
