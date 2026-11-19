#!/bin/bash
# Run as root in a disposable Arch/Omarchy builder container, never on the host.
# Usage: tests/markov-bin-install.sh <markov-bin package> [old markov package]
set -euo pipefail
package=${1:?package required}
old=${2:-}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
chown builder:builder "$work"
cd "$work"
printf 'keep me\n' > user-workflow.yaml
# Local prototypes are unsigned. Source signatures are checked by makepkg;
# the distribution signs the final package during its publication workflow.
cp /etc/pacman.conf "$work/pacman.conf"
sed -i 's/^LocalFileSigLevel.*/LocalFileSigLevel = Never/' "$work/pacman.conf"
pacman_local() { pacman --config "$work/pacman.conf" "$@"; }
if [[ -n $old ]]; then
  pacman_local -U --noconfirm "$old"
  markov --version
  cp /usr/share/markov/examples/quickstart.yaml .
  runuser -u builder -- markov run quickstart.yaml
  sha256sum markov-state.db quickstart-report.md user-workflow.yaml > preserved.sha256
  # The conflict must be explicit; this recipe intentionally has no replaces.
  # Accept only pacman's request to remove the conflicting first-party package.
  printf 'y\ny\n' | pacman_local -U "$package"
  if pacman -Qq | grep -Fxq markov; then echo "old provider remains" >&2; exit 1; fi
  sha256sum --check preserved.sha256
else
  pacman_local -U --noconfirm "$package"
fi
pacman -Q markov-bin
pacman -T 'markov>=0.2.2'
markov --version | grep -F '0.2.2'
cp /usr/share/markov/examples/quickstart.yaml .
runuser -u builder -- markov validate quickstart.yaml
runuser -u builder -- markov run quickstart.yaml
grep -F 'Cache warm after 3 rounds' quickstart-report.md
bash -n /usr/share/bash-completion/completions/markov
test -s /usr/share/zsh/site-functions/_markov
test -s /usr/share/fish/vendor_completions.d/markov.fish
test -f /usr/share/man/man1/markov.1.gz
gzip -dc /usr/share/man/man1/markov.1.gz | groff -man -Tutf8 > "$work/manual.txt"
grep -q MARKOV "$work/manual.txt"
for notice in LICENSE THIRD_PARTY_LICENSES.txt license-inventory.json; do
  test -s "/usr/share/licenses/markov-bin/$notice"
done
sha256sum markov-state.db quickstart-report.md user-workflow.yaml > preserved.sha256
pacman -R --noconfirm markov-bin
sha256sum --check preserved.sha256
hash -r
if command -v markov; then echo "engine remains after removal" >&2; exit 1; fi
printf 'PASS: install/provider/quickstart/completions/notices/removal/preserved user data\n'
