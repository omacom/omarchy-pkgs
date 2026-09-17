# eDP DSC policy regression tests

This test extracts `intel_dp_compute_link_for_joined_pipes()` from a
prepared kernel source tree and compiles it against the C fixture in
`fixtures/edp-dsc.c`. The policy under test comes from the actual source;
it is not a second implementation of the policy.

## Run

Requirements: Linux, Python 3, and GCC (or a GNU C-compatible compiler
selected with `CC`). No root access is needed to run the test.

Prepare the kernel source using the recipe under review. On Arch Linux,
with the recipe's build dependencies and source-verification public keys
available, run from the repository root:

```sh
(cd pkgbuilds/linux-omarchy && makepkg --nobuild)
python3 tests/edp-dsc.py pkgbuilds/linux-omarchy/src/linux-7.2.5
```

`makepkg --nobuild` downloads, verifies and prepares sources without building
or installing the kernel. If `BUILDDIR` is configured, pass the corresponding
prepared source directory instead. The BORE recipe can be tested the same way:

```sh
(cd pkgbuilds/linux-omarchy-bore && makepkg --nobuild)
python3 tests/edp-dsc.py pkgbuilds/linux-omarchy-bore/src/linux-7.2.5
```

An existing prepared tree with this patch applied is also sufficient. The
test reads the tree without modifying it and builds its executables in a
temporary directory that is removed on exit. Missing patch restoration,
compilation errors and assertion failures produce a nonzero exit status.

## Coverage

The ten named cases cover DSC preference, preservation of the requested
depth, external DP exclusion, already-sufficient depth, missing capability,
the permitted depth limit, three optional-DSC failure stages, and two
required-DSC error paths. Each successful case prints a `PASS` line.

A negative control replaces complete DSC/FEC restoration with the original
reset-only fallback and runs the late-dotclock case. It must terminate at
the assertion checking `compression_enabled_on_link`; an arbitrary failure
does not count as detecting this regression. Core dumps are disabled.

These are control-flow tests with simplified state and stubbed helpers.
The FEC stub deliberately changes its flag to exercise restoration; it does
not model actual eDP FEC policy. The tests do not validate DSC parameter
calculation, hardware programming, full kernel builds or display behavior.
They complement the real-machine xe-module validation reported in the PR.
