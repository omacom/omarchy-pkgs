# ath12k-board-fallback

Wi-Fi for Qualcomm cards that linux-firmware does not list yet.

ath12k needs board data for the exact card: radio calibration and power limits. It looks the
card up in `board-2.bin` by the card's PCI vendor, device and subsystem IDs and the board ID the
card reports. When no entry matches, it loads `board.bin`, and when there is none, the card has
no Wi-Fi. linux-firmware's QCC2072 file lists 2 of the 8 cards Qualcomm's Windows driver knows,
and its WCN7850 file lacks 6 of 32, so a laptop with one of those cards comes up without Wi-Fi.

ath11k finds its board data the same way, and the tool covers two of its cards too: the WCN6855
in the HP OmniBook X 14 (`105b:e108`) and in the HP OmniBook 3 14 (`103c:8d9a`), which
linux-firmware doesn't list. Their Windows drivers give them the same board file as `105b:e105`,
and that card's record gave the OmniBook X 14 a working link.

## Why a card's family is enough

The cards are M.2 modules, such as Foxconn's NCM825A, that several makers fit in their laptops
under their own subsystem IDs. Qualcomm's Windows driver gives every card of one module family
the same board file, and linux-firmware does the same: every card it lists in a family has the
same record. `cards` maps each card to its family and each family to the linux-firmware records
that hold its data.

## What the tool does

`ath12k-board-fallback` runs from a pacman hook whenever linux-firmware's `ath12k` or `ath11k`
files or the card list change, and when this package is installed. For each Qualcomm Wi-Fi chip
in the machine:

- If linux-firmware lists the machine's card, it does nothing, and removes a copy it installed
  earlier.
- If a package installs its own `board.bin` for the chip, it does nothing, and removes a copy it
  installed earlier.
- Otherwise, when `cards` knows the card's family, it copies the family's record from the
  installed linux-firmware to `/usr/lib/firmware/updates/<driver>/<chip>/<hw>/board.bin`. The
  driver reads `board.bin` only when `board-2.bin` has no entry for the card, so the copy stops
  being used once linux-firmware lists the card, and the next run removes it.

It never removes a file it did not install or that changed since, and it records what it
installed in `/var/lib/ath12k-board-fallback/installed`. The driver reads the board data when
it probes the card, so a new copy takes effect after a reboot. `ath12k-board-fallback --check`
prints what it would do. The package ships no firmware: the copy comes from the machine's own
linux-firmware.

## Upstream

The fix that makes this package unnecessary is an entry for each card in linux-firmware's
`board-2.bin`, pointing at the record its family already uses there.
