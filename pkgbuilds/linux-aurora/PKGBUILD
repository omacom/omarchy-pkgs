# AArch64 Apple Silicon (Aurora Silicon)
# Based on the asahi-alarm linux-asahi package by Jos Dehaes and Matthias Kurz.
#
# Aurora Silicon maintain a fork of the Asahi kernel carrying DisplayPort
# alt-mode and USB4 support for external monitors, variable refresh rate, and
# the ISP and AOP drivers. Those changes touch device trees, the type-C stack
# and DRM, so they cannot ship as a module: this is a whole alternative kernel
# for Macs on the Omarchy edge channel. It reaches rc and stable only after
# cold-boot qualification on M1 and M2.

_auroraver=7.2.11
_aurorarel=14
pkgrel=1

# Immutable pin on omacom/linux-aurora (branch integration/aurora). Every bump is a
# PR that moves _commit; its cold-boot qualification is recorded in
# the PR's attached qualification evidence before channel publication.
_commit=4fdd0fc5c931ef9f14474942b37c3d451e97fc04

# Any m1n1 1.6.1 loads these device trees. The Neo's own Stage 2 comes from the
# image, so the floor stays where M1 and M2 users' m1n1-aurora already meets it.
_m1n1_version=1.6.1

pkgbase=linux-aurora
_srcname=linux
_kernelname=${pkgbase#linux}
_desc="AArch64 Apple Silicon (Aurora kernel)"
pkgver="${_auroraver}.aurora${_aurorarel}"
arch=('aarch64')
groups=('omarchy-platform-apple-silicon')
url="https://github.com/omacom/linux-aurora"
license=('GPL2')

makedepends=(
  base-devel bc dtc kmod libelf pahole cpio perl rustup clang llvm lld clang18 llvm18 lld18
  tar xz xmlto python git patch
)
options=('!strip')
source=(validate-config.py configure.sh "linux::git+https://github.com/omacom/linux-aurora.git#commit=${_commit}"
        rust-toolchain.toml bindgen-kernel.py config)
sha256sums=('aca7420a18139474da62a81c77fc6e5c3f25001f872b6e11e18605cd892aa4c3'
            'b95c0f0ddf106f3861e0e62a746af6a881fb8e0f356a892961f9e86062877400'
            'SKIP'
            '443a9c4613172ea352f49b114818a1d75ab048ec4bd2d75b388a7ab3a8a1f046'
            '84a03d5fea19cae243c89f50c1736c639622d25d4d1de8d7d53ebd8f603c0f62'
            '98f76a885d81711013aad47e2ee13f000923191e43321738ec8f381690bf5160')

# Kbuild takes ARCH literally and knows arm64, not aarch64.
export ARCH=arm64
export KBUILD_BUILD_HOST=archlinux
export KBUILD_BUILD_USER=$pkgbase
export KBUILD_BUILD_TIMESTAMP="$(date -Ru${SOURCE_DATE_EPOCH:+d @$SOURCE_DATE_EPOCH})"

# Kbuild assigns BINDGEN itself, so an environment-only value is ignored.
# Supply the wrapper and its real tool in every makepkg phase, not just prepare.
_make() {
  AURORA_BINDGEN_REAL="$srcdir/private-bindgen/rust-bindgen-0.73.2/target/release/bindgen" \
    RUSTFMT="$(rustup which --toolchain 1.99.0 rustfmt)" \
    LIBCLANG_PATH="${AURORA_LIBCLANG_PATH:-/usr/lib/llvm18/lib}" \
    RUSTUP_TOOLCHAIN=1.85.0 make LLVM="${AURORA_LLVM:-/usr/lib/llvm18/bin/}" \
    BINDGEN="$srcdir/bindgen-kernel.py" LOCALVERSION= "$@"
}

_check_kernelrelease() {
  [[ $1 == *-ARCH ]] || {
    echo "Kernel release must end in -ARCH for boot-bundle DTB discovery: $1" >&2
    return 1
  }
}

prepare() {
  cd $_srcname

  echo "Setting version..."
  echo "-$_aurorarel-$pkgrel" > localversion.10-pkgrel

  local src
  for src in "${source[@]}"; do
    src="${src%%::*}"
    src="${src##*/}"
    [[ $src = *.patch ]] || continue
    echo "Applying patch $src..."
    patch -Np1 < "../$src"
  done

  echo "Pinning the Rust toolchain..."
  cp ../rust-toolchain.toml .

  # ALARM's clang18, llvm18 and lld18 install their tools under this prefix only.
  export LLVM="${AURORA_LLVM:-/usr/lib/llvm18/bin/}"
  local clang_command="clang${LLVM}"
  [[ $LLVM != */ ]] || clang_command="${LLVM}clang"
  "$clang_command" --version | head -1 | grep -Eq 'clang version 18\.' || {
    echo 'linux-aurora requires the qualified LLVM 18 build environment' >&2; return 1;
  }
  # Bindgen's checked output and the compatibility adapter need formatted Rust.
  rustup toolchain install 1.99.0 --profile minimal --component rustfmt
  RUSTUP_TOOLCHAIN=1.99.0 RUSTFMT="$(rustup which --toolchain 1.99.0 rustfmt)" \
    python3 tools/aurora-bindgen/build.py --output-dir "$srcdir/private-bindgen"
  export AURORA_BINDGEN_REAL="$srcdir/private-bindgen/rust-bindgen-0.73.2/target/release/bindgen"
  export RUSTUP_TOOLCHAIN=1.85.0
  rustup toolchain install 1.85.0 --profile minimal --component rust-src
  # Keep shared kexec support: apple_piodma_lock_transition() in
  # pcie-apple-piodma-diag.c acquires the kernel kexec blocker before Neo radio
  # admission retains DMA/firmware ownership. Both kexec
  # load APIs and execution reject while that blocker is held.
  # Keep config's -ARCH suffix: omarchy-mac-boot and update-m1n1 discover
  # device trees under /lib/modules/*-ARCH.
  source ../configure.sh
  configure_kernel "$PWD/.." "$PWD/build/base" || return
  _make O="$PWD/build/base" prepare
  _make -s O="$PWD/build/base" kernelrelease > build/base/version

  _check_kernelrelease "$(<build/base/version)"
  echo "Prepared $pkgbase version $(<build/base/version)"
}

build() {
  cd $_srcname
  echo "Building base..."
  export LLVM="${AURORA_LLVM:-/usr/lib/llvm18/bin/}" RUSTUP_TOOLCHAIN=1.85.0
  export AURORA_BINDGEN_REAL="$srcdir/private-bindgen/rust-bindgen-0.73.2/target/release/bindgen"
  _make O="$PWD/build/base" -j"${OMARCHY_BUILD_JOBS:-10}" Image modules dtbs
}

check() {
  cd $_srcname
  python -I tools/aurora-sep/tests/test_extract_mesa_calibration.py
}

_package_kernel() {
  pkgdesc="The $pkgdesc kernel and modules"
  depends=(coreutils kmod initramfs $2 "m1n1>=$_m1n1_version")
  optdepends=('crda: to set the correct wireless channels of your country'
              'linux-firmware: firmware images needed for some devices'
              'python: extract-mesa-calibration, for Touch ID')
  # No generic linux provide: on a shared aarch64 repository it would compete
  # with linux-aarch64 for any dependency on linux.
  provides=(WIREGUARD-MODULE linux-asahi=${pkgver})
  conflicts=(linux-asahi)

  local kernver="$(<$O/version)"
  local modulesdir="$pkgdir/usr/lib/modules/$kernver"

  echo "Installing boot image..."
  # systemd expects to find the kernel here to allow hibernation
  # https://github.com/systemd/systemd/commit/edda44605f06a41fb86b7ab8128dcf99161d2344
  install -Dm644 "$O"/arch/arm64/boot/Image "$modulesdir/vmlinuz"

  # Used by mkinitcpio to name the kernel
  echo "$1" | install -Dm644 /dev/stdin "$modulesdir/pkgbase"

  echo "Installing modules..."
  _make O="$O" INSTALL_MOD_PATH="$pkgdir/usr" INSTALL_MOD_STRIP=1 modules_install

  echo "Installing device trees..."
  install -Dt "$modulesdir/dtbs" "$O"/arch/arm64/boot/dts/apple/*.dtb

  # Touch ID needs this Mac's Mesa calibration, which the SEP driver loads as
  # firmware. The extractor ships with the kernel it was written for, at a path
  # of its own, so the platform package can run it without carrying a copy.
  echo "Installing the Mesa calibration extractor..."
  install -Dm755 tools/aurora-sep/extract-mesa-calibration.py \
    "$pkgdir/usr/lib/linux-aurora/extract-mesa-calibration"

  # remove build and source links
  rm -f "$modulesdir"/{source,build}
}

_package() {
  cd $_srcname
  export O="$PWD/build/base"
  _package_kernel "$pkgbase"
}

_package-headers() {
  pkgdesc="Headers and scripts for building modules for the $pkgdesc kernel"
  depends=(pahole)
  provides=(linux-asahi-headers=${pkgver})
  conflicts=(linux-asahi-headers)

  KARCH=arm64

  cd $_srcname
  O=build/base
  local builddir="$pkgdir/usr/lib/modules/$(<${O}/version)/build"

  echo "Installing build files..."
  install -Dt "$builddir" -m644 $O/.config Makefile $O/Module.symvers $O/System.map \
    localversion.* $O/version $O/vmlinux
  install -Dt "$builddir/kernel" -m644 kernel/Makefile
  cp -t "$builddir" -a scripts $O/scripts

  # required when STACK_VALIDATION is enabled
  #install -Dt "$builddir/tools/objtool" tools/objtool/objtool

  # required when DEBUG_INFO_BTF_MODULES is enabled
  if grep -qx 'CONFIG_DEBUG_INFO_BTF=y' "$O/.config"; then
    [[ -x $O/tools/bpf/resolve_btfids/resolve_btfids ]] || {
      echo 'BTF is enabled but resolve_btfids was not built' >&2; return 1;
    }
    install -Dt "$builddir/tools/bpf/resolve_btfids" "$O/tools/bpf/resolve_btfids/resolve_btfids"
  fi

  echo "Installing headers..."
  cp -t "$builddir" -a include $O/include

  install -Dt "${builddir}/arch/${KARCH}" -m644 arch/${KARCH}/Makefile
  install -Dt "${builddir}/arch/${KARCH}/kernel" -m644 $O/arch/${KARCH}/kernel/asm-offsets.s
  cp -t "${builddir}/arch/${KARCH}" -a arch/${KARCH}/include $O/arch/${KARCH}/include

  install -Dt "$builddir/drivers/md" -m644 drivers/md/*.h
  install -Dt "$builddir/net/mac80211" -m644 net/mac80211/*.h

  # https://bugs.archlinux.org/task/13146
  install -Dt "$builddir/drivers/media/i2c" -m644 drivers/media/i2c/msp3400-driver.h

  # https://bugs.archlinux.org/task/20402
  install -Dt "$builddir/drivers/media/usb/dvb-usb" -m644 drivers/media/usb/dvb-usb/*.h
  install -Dt "$builddir/drivers/media/dvb-frontends" -m644 drivers/media/dvb-frontends/*.h
  install -Dt "$builddir/drivers/media/tuners" -m644 drivers/media/tuners/*.h

  # https://bugs.archlinux.org/task/71392
  install -Dt "$builddir/drivers/iio/common/hid-sensors" -m644 drivers/iio/common/hid-sensors/*.h

  echo "Installing KConfig files..."
  find . -name 'Kconfig*' -exec install -Dm644 {} "$builddir/{}" \;

  echo "Installing unstripped VDSO..."
  _make O="$O" INSTALL_MOD_PATH="$pkgdir/usr" vdso_install link=

  echo "Removing unneeded architectures..."
  local arch
  for arch in "$builddir"/arch/*/; do
    [[ $arch = */${KARCH}/ ]] && continue
    echo "Removing $(basename "$arch")"
    rm -r "$arch"
  done

  echo "Removing documentation..."
  rm -r "$builddir/Documentation"

  echo "Removing broken symlinks..."
  find -L "$builddir" -type l -printf 'Removing %P\n' -delete

  echo "Removing loose objects..."
  find "$builddir" -type f -name '*.o' -printf 'Removing %P\n' -delete

  echo "Removing cmd files..."
  find "$builddir" -type f -name '*.cmd' -printf 'Removing %P\n' -delete

  echo "Stripping build tools..."
  local file
  while read -rd '' file; do
    case "$(file --no-sandbox -bi "$file")" in
      application/x-sharedlib\;*)      # Libraries (.so)
        strip -v $STRIP_SHARED "$file" ;;
      application/x-archive\;*)        # Libraries (.a)
        strip -v $STRIP_STATIC "$file" ;;
      application/x-executable\;*)     # Binaries
        strip -v $STRIP_BINARIES "$file" ;;
      application/x-pie-executable\;*) # Relocatable binaries
        strip -v $STRIP_SHARED "$file" ;;
    esac
  done < <(find "$builddir" -type f -perm -u+x ! -name vmlinux -print0)

  echo "Stripping vmlinux..."
  strip -v $STRIP_STATIC "$builddir/vmlinux"

  echo "Adding symlink..."
  mkdir -p "$pkgdir/usr/src"
  ln -sr "$builddir" "$pkgdir/usr/src/$pkgbase"

}

pkgname=("$pkgbase" "$pkgbase-headers")
for _p in "${pkgname[@]}"; do
  eval "package_$_p() {
    $(declare -f "_package${_p#$pkgbase}")
    _package${_p#$pkgbase}
  }"
done

# vim:set ts=8 sts=2 sw=2 et:
