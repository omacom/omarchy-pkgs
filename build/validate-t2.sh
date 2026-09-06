#!/bin/bash
set -euo pipefail

# Start from the builder's Arch-only configuration; reject a contaminated image.
mapfile -t repos < <(pacman-conf --repo-list)
[[ "${repos[*]}" == 'core extra' ]]
if pacman -Qq | grep -qxE 'linux-t2|linux-t2-headers|apple-t2-audio-config|apple-bcm-firmware|t2fanrd'; then
  echo 'T2 packages were already installed in the validation image' >&2
  exit 1
fi
sudo pacman -Syu --noconfirm

sudo sed -i '/^\[core\]$/i [omarchy-build]\nSigLevel = Never\nServer = file:///packages\n' /etc/pacman.conf
sudo pacman -Sy --noconfirm
pacman-conf
# Prove the remaining blocker explicitly; never substitute an empty provider.
if pacman -Sp linux-t2 linux-t2-headers apple-t2-audio-config apple-bcm-firmware t2fanrd > /tmp/t2-full-transaction 2>&1; then
  echo 'Unexpected apple-bcm-firmware provider in the isolated repositories' >&2
  exit 1
fi
grep -F 'target not found: apple-bcm-firmware' /tmp/t2-full-transaction
pacman -Sp --print-format '%r %n %v %l' mkinitcpio linux-t2 linux-t2-headers apple-t2-audio-config t2fanrd
sudo pacman -S --noconfirm mkinitcpio linux-t2 linux-t2-headers apple-t2-audio-config t2fanrd
pacman -Q linux-t2 linux-t2-headers apple-t2-audio-config t2fanrd
[[ $(pacman -Q linux-t2 | cut -d' ' -f2) == "$(pacman -Q linux-t2-headers | cut -d' ' -f2)" ]]
pacman -Dk
pacman -Qkk linux-t2 linux-t2-headers apple-t2-audio-config t2fanrd

mapfile -t releases < <(find /usr/lib/modules -name pkgbase -exec grep -lFx linux-t2 {} +)
[[ ${#releases[@]} == 1 ]]
kver=${releases[0]%/pkgbase}
kver=${kver##*/}
test -s "/usr/lib/modules/$kver/vmlinuz"
test "$(cat "/usr/lib/modules/$kver/build/version")" = "$kver"
for module in t2bce_core t2bce_dma t2bce_vhci t2bce_audio hci_bcm4377 brcmfmac applesmc hid_apple usbhid; do
  [[ $(modinfo -k "$kver" -F name "$module") == "$module" ]]
  if [[ $(modinfo -k "$kver" -F filename "$module") != '(builtin)' ]]; then
    [[ $(modinfo -k "$kver" -F vermagic "$module") == "$kver "* ]]
  fi
  modinfo -k "$kver" -F depends "$module"
done
if modinfo -k "$kver" apple-bce >/dev/null 2>&1; then
  echo 'Unexpected legacy apple-bce module' >&2
  exit 1
fi
modprobe --show-depends --set-version "$kver" t2bce_vhci

cat > /tmp/t2-mkinitcpio.conf <<'EOF'
MODULES=(t2bce_vhci usbhid hid_apple hid_generic xhci_pci xhci_hcd)
BINARIES=()
FILES=()
HOOKS=(base systemd keyboard)
COMPRESSION=zstd
EOF
sudo mkinitcpio -k "$kver" -c /tmp/t2-mkinitcpio.conf -g /tmp/t2-initramfs.img
sudo lsinitcpio /tmp/t2-initramfs.img > /tmp/t2-initramfs.list
for module in t2bce_vhci t2bce_core t2bce_dma hid_apple; do
  module_file=$(modinfo -k "$kver" -F filename "$module")
  grep -F "/${module_file##*/}" /tmp/t2-initramfs.list
done

# Compile an external module against the installed headers, without loading it.
mkdir /tmp/t2-header-test
cat > /tmp/t2-header-test/probe.c <<'EOF'
#include <linux/module.h>
static int __init probe_init(void) { return 0; }
static void __exit probe_exit(void) {}
module_init(probe_init);
module_exit(probe_exit);
MODULE_LICENSE("GPL");
EOF
echo 'obj-m := probe.o' > /tmp/t2-header-test/Makefile
make -C "/usr/lib/modules/$kver/build" M=/tmp/t2-header-test modules
[[ $(modinfo -F vermagic /tmp/t2-header-test/probe.ko) == "$kver "* ]]

systemd-analyze verify /usr/lib/systemd/system/t2fanrd.service
[[ $(systemctl is-enabled t2fanrd.service || true) == disabled ]]
for speakers in 2 4 6; do
  test -s "/usr/share/alsa/ucm2/AppleT2/HiFi-x$speakers.conf"
  test -s "/usr/share/alsa/ucm2/conf.d/AppleT2x$speakers/AppleT2x$speakers.conf"
done
ldd /usr/bin/t2fanrd
if ldd /usr/bin/t2fanrd | grep -q 'not found'; then exit 1; fi
grep -qx '\[Fan2\]' /etc/t2fand.conf
echo "PASS: local pacman transaction, dependencies, modules, initramfs, headers, UCM files and fan service ($kver)"
echo 'Not tested: booting or operating actual T2 hardware; Apple firmware is absent.'
