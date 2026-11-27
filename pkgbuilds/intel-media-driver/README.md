# intel-media-driver

Arch's `extra/intel-media-driver`, rebuilt with one patch. `[omarchy]` comes before `[extra]` in Omarchy's `pacman.conf`, so every x86_64 machine that has the driver installed takes this build instead of Arch's.

## The patch

`decode-destroy-context-status-check-race.patch` is [intel/media-driver#2057](https://github.com/intel/media-driver/pull/2057), unchanged. Without it, `vaSyncSurface` on one thread can read a decode context that `vaDestroyContext` is freeing on another, and the process dies with a segmentation fault. ffmpeg does exactly that at the end of a stream when it downloads hardware-decoded frames (`-hwaccel vaapi -hwaccel_output_format vaapi` with `hwdownload`), because it syncs surfaces on its filter thread while the decoder thread tears down.

It changes only the decode path the driver selects from Meteor Lake on. Older generations use the driver's legacy path: they get this package too, and it behaves there as Arch's does. That includes the crash: the legacy path has the same unguarded pair of calls, [intel/media-driver#2091](https://github.com/intel/media-driver/issues/2091) reports it on an Arc A380, and this patch does not touch it.

What the patch does not do:

- It covers the two calls running at once. It does not clear the pointer on a surface the decoder has already dropped from its table, so a sync of such a surface after its context is gone still reads the freed context, as it did before. A context drops one when its table of 127 is full and a new surface takes the slot of one no longer in use, which takes far more surfaces in one context than the five-frame samples in the runs below use.
- It holds the display's surface mutex while a context is torn down, which includes waiting for that stream's outstanding GPU work. Another stream on the same display that looks up, creates or destroys a surface in that moment waits for it. On `xe` the teardown also waits for any wait on GPU work another stream on the display is in the middle of, such as its own `vaSyncSurface`, so one slow stream can hold up the others through a stream that is closing.

## Evidence

On a Dell XPS 14 (Panther Lake, `xe`) the Omarchy Certified Hardware video decode test, which decodes ten kinds of sample six times each, lost 26 of 300 decodes to that crash with Arch's 26.3.5-1 and 25 of 300 with the same source rebuilt unpatched. With the patch, as a library built beside the system's, it lost none of 300. With this recipe's package installed on that machine, a full run of the kit passed the test with no core dump.

Separately, by hand with the same ffmpeg commands on Arch's 26.3.5-1: a Dell XPS 13 (Wildcat Lake, `xe`) crashed the same way in 25 of 75 decodes of the three kinds it was tried on, and an Arrow Lake machine on `i915` in none of 75.

## Updates

Updates are reviewed (`"review": true`): a new upstream release opens a draft PR. Before marking one ready:

- Check whether the release has the fix. The patch is applied with `--fuzz=0`, so a release that changed these lines fails to build, but one that only moved them still applies. If #2057 has merged, or the two functions already take the mutex, retire the carry instead.
- `bin/check-shadowed` goes red when Arch's version passes this one; treat that as the prompt to bring the carry up to Arch's or retire it.
- Compare Arch's [PKGBUILD](https://gitlab.archlinux.org/archlinux/packaging/packages/intel-media-driver) for new options, dependencies or patches. While this package is published, machines never see Arch's own rebuilds of the driver, so anything Arch changes has to be brought over here by hand.
- Set `pkgrel` to `1.1`, or to Arch's current `pkgrel` with `.1` after it. That keeps this build above the Arch build it replaces and below Arch's next one.

## Retiring the carry

Drop this recipe once a release Arch ships has the fix. Deleting the directory is not enough: the published package keeps shadowing Arch's until a maintainer unpublishes it from each channel (see *Retire a package* in the repository README). A machine then moves to Arch's build on its next update only if Arch's version is newer than the one it has, which the `pkgrel` rule above ensures for any later Arch build.
