# HP EliteBook X G2i audio

Speakers and microphone for the HP EliteBook X G2i (Panther Lake): RT712 SDCA
codec plus four TAS2783 smart amps over SoundWire.

**Without this package and the kernel it depends on, the machine has no Speaker
device at all** — not quiet, absent. `pactl list cards` shows the card stuck on
profile `off` with no usable sink.

## Where the fix actually lives

Most of the fix is kernel-side, and every piece is an edit to a file that
already exists in the kernel. They ship as patches in `linux-ptl`, which this
machine installs anyway for its other Panther Lake backports:

| Patch | What it does |
|---|---|
| `0050-ASoC-Intel-soc-acpi-intel-ptl-add-HP-EliteBook-X-G2i` | Adds the match-table entry for the board's RT712 (link 3) + quad TAS2783A (link 2). Without it SOF falls back to a barebones machine driver and never instantiates the amps. The array lists the amps L,R,L,R by physical side, which is load-bearing for stereo. |
| `0051-ASoC-sdw_utils-set-a-component-name-for-the-TAS2783A` | Makes the card report `spk:tas2783` in `card->components`. Every other amp in `codec_info_list` already declares this; the TAS2783A did not, so UCM could not resolve a speaker configuration. Merged upstream as `79bec4638`; drop at the 7.2 rebase. |
| `0061-soundwire-stream-append-ports-when-a-second-DAI-joins` | Stops a second DAI joining a stream from overwriting the first DAI's port config. Not board-specific. |
| `0062-ASoC-Intel-sof_sdw-split-a-four-amp-TAS2783A-link` | Gives the amp dai_link two CPU pins, which selects the `sdca-2amp` topology. |
| `0063-ASoC-tas2783-take-one-stream-channel-per-mono-amplifier` | `.set_tdm_slot` on tas2783, driven from the `tas2783-N` prefix by `asoc_sdw_ti_spk_rtd_init()`. |

The last three are what make the machine stereo. Without them all four
amplifiers receive the same channel and the speakers play mono-left — a state
in which every check short of listening reports a healthy stereo card.

Neither belongs in DKMS. A DKMS module that rebuilds `snd-soc-acpi-intel-match`
has to carry a frozen copy of every Intel platform's match table, which silently
reverts upstream fixes for unrelated machines and stops compiling the first time
ASoC changes a struct — with no speakers and no warning as the failure mode.

## What this package installs

### 1. The Speaker device

`sof-soundwire/HiFi.conf` includes `/sof-soundwire/${SpeakerCodecFile}.conf`
with no whitelist. With the kernel reporting `spk:tas2783`, stock
`alsa-ucm-conf` resolves that to `tas2783` and picks up the file this package
ships. Nothing `alsa-ucm-conf` owns is modified or overwritten.

The device also pins the four per-amp digital trims to −12 dB. They default to
hardware maximum and are not reachable from PipeWire's volume control, which
sits on a separate downstream stage.

### 2. Firmware filename links

`tas2783-sdw.c` requests `8E86-2-{9,A,C,D}.bin`. `linux-firmware` ships the same
per-amp calibration blobs as `8E86-2-0x{9,A,C,D}.bin.zst`. A naming bug, not
missing firmware — so the package symlinks rather than copies, leaving
`linux-firmware` owning the real files. `post_remove` removes only symlinks it
created, never a real file.

### 3. Boot-race protection, two layers

The amps download firmware asynchronously at boot. If WirePlumber enumerates the
card first, the Speaker device is skipped and the whole HiFi profile comes up
unavailable — no sinks, no sources — on a random subset of boots.

`wait-tas2783-controls` runs as WirePlumber's `ExecStartPre` and waits, bounded
at 12 s, for the `tas2783-1 Speaker Volume` kcontrol. It returns at once when
the control is already there and never blocks login.

That narrows the window without closing it, so
`hp-elitebook-x-g2i-audio-recover.service` runs once per session afterwards and
checks two faults. The second one is the reason it exists: the card can sit on a
perfectly healthy `HiFi` profile while the PipeWire graph does not reach the
speakers, so a profile-only check reports success on a silent machine. It logs a
graph snapshot on every run, healthy or not, and only restarts the shell when it
actually repaired something.

## Upstream status

The interim, in the same spirit as `dell-xps-touchpad-haptics`. Each of these
retires a layer when it lands:

| Piece | Real home | Status |
|---|---|---|
| Match-table entry | Linux, `soc-acpi-intel-ptl-match.c` | not submitted |
| TAS2783A component name | Linux, `sound/soc/sdw_utils/soc_sdw_utils.c` | merged, `79bec4638` |
| Second-DAI port overwrite | Linux, `drivers/soundwire/stream.c` | not submitted; a general bug |
| Two-PDI amp split | Linux, `sof_sdw.c` + `soc_sdw_ti_amp.c` | not submitted |
| Firmware naming | `linux-firmware` / `tas2783-sdw.c` | partly merged, `e26bb459d` |
| Speaker device definition | `alsa-ucm-conf` | not submitted |

## Scope

This package carries **enablement only** — it makes the hardware work, and
contains no vendor-derived tuning data. The perceptual voicing (HP's factory
DTS:X Ultra curve) ships separately as an Omarchy audio tuning, matched on the
DMI SKU, and is an independent decision.

## Verifying

```bash
amixer -c 0 info | grep Components            # expect " spk:tas2783"
pactl list cards | grep 'Active Profile'      # expect HiFi
journalctl -k -b | grep -o 'sof-sdca-.amp'    # expect sdca-2amp, NOT sdca-1amp
speaker-test -c 2 -t pink                     # left must come from the left
wpctl status                                  # expect a Speaker sink and a Mic source
journalctl --user -u hp-elitebook-x-g2i-audio-recover -b
```

`sdca-1amp` means the two-PDI split did not take effect and the machine is
playing mono out of all four speakers. That is a kernel-patch problem, not a
tuning problem — do not go looking at levels.

A reboot is required after install: the kernel side of the fix cannot apply to
the running kernel.
