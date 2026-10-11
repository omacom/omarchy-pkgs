#!/bin/bash
# Exercise scriptlets against disposable paths without installed Omarchy
# helpers, real sudo policy, package transactions, or administrator privileges.
set -euo pipefail
root=$(cd -- "${BASH_SOURCE[0]%/*}/.." && pwd)
python3 - "$root" <<'PY'
from pathlib import Path
import os
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix="settings-sudo-lifecycle-") as temporary:
  scratch = Path(temporary)
  for name in ("omarchy-settings", "omarchy-settings-dev"):
    target = scratch / name
    for directory in ("etc/sudoers.d", "etc/tmpfiles.d", "run/lock", "bin"):
      (target / directory).mkdir(parents=True, exist_ok=True)
    source = (root / "pkgbuilds" / name / (name + ".install")).read_text()
    source = source.replace("/etc", str(target / "etc")).replace("/run", str(target / "run"))
    for command in ("stat", "rm"):
      source = source.replace("/usr/bin/" + command, str(target / "bin" / command))
    scriptlet = target / "scriptlet"
    scriptlet.write_text(source)
    (target / "bin/stat").write_text('''#!/bin/bash
path=${@: -1}
mode=$(/usr/bin/stat -Lc '%a' -- "$path") || exit
owner=0
[[ $path != "${TEST_BAD_PATH:-}" ]] || owner=1000
printf '%s %s\\n' "$owner" "$mode"
''')
    (target / "bin/rm").write_text('''#!/bin/bash
for path in "$@"; do
  [[ $path != "${TEST_DELETE_FAIL:-}" ]] || exit 1
done
exec /usr/bin/rm "$@"
''')
    for binary in (target / "bin").iterdir():
      binary.chmod(0o755)
    environment = dict(os.environ, TEST_ROOT=str(target), TEST_SCRIPTLET=str(scriptlet), TEST_PACKAGE=name)
    subprocess.run(["bash", "-euo", "pipefail", "-c", r'''
source "$TEST_SCRIPTLET"
_etc_overrides_apply() { :; }
rule="$TEST_ROOT/etc/sudoers.d/99-omarchy-nopasswd-1000"
legacy="$TEST_ROOT/etc/sudoers.d/99-omarchy-nopasswd-alice"
permanent="$TEST_ROOT/etc/sudoers.d/99-omarchy-permanent-nopasswd-1000"
unrelated="$TEST_ROOT/etc/sudoers.d/administrator"
blocker="$TEST_ROOT/run/omarchy-sudo-passwordless-package-removing"
lock="$TEST_ROOT/run/lock/omarchy-sudo-passwordless.lock"
boot="$TEST_ROOT/etc/tmpfiles.d/omarchy-nopasswd-sudo.conf"
write_boot() { printf 'r! %s/etc/sudoers.d/99-omarchy-nopasswd-*\n' "$TEST_ROOT" >"$boot"; }
expect_failure() { if "$@"; then echo "unexpected success: $*" >&2; exit 1; fi; }
pass() { printf 'ok - %s: %s\n' "$TEST_PACKAGE" "$1"; }
write_boot
printf 'alice ALL=(ALL) NOPASSWD: ALL\n' >"$legacy"
printf 'alice ALL=(ALL) NOTAFTER=20990101000000Z NOPASSWD: ALL\n' >"$rule"
printf 'alice ALL=(ALL) NOPASSWD: ALL\n' >"$permanent"
printf 'admin ALL=(ALL) ALL\n' >"$unrelated"
pre_remove
post_remove
[[ ! -e $rule && ! -e $legacy && -f $blocker && -f $permanent && -f $unrelated ]]
post_install
[[ ! -e $blocker && -f $permanent && -f $unrelated ]]
pass 'legacy cleanup and completion need no installed helper and preserve permanent/admin policies'

: >"$rule"
TEST_DELETE_FAIL="$rule" expect_failure pre_upgrade
[[ -f $rule && -f $blocker ]]
TEST_DELETE_FAIL="$rule" expect_failure post_upgrade
[[ -f $rule && -f $blocker ]]
post_upgrade
[[ ! -e $rule && ! -e $blocker ]]
pass 'failed pre/post cleanup retains the blocker until a successful retry'

: >"$rule"
(set -f; GLOBIGNORE='*' post_upgrade)
[[ ! -e $rule && ! -e $blocker ]]
pass 'inherited glob settings cannot hide temporary policy'

printf 'invalid boot cleanup\n' >"$boot"
expect_failure post_install
[[ -f $blocker ]]
rm "$boot"
expect_failure post_install
[[ -f $blocker ]]
write_boot
post_install
[[ ! -e $blocker ]]
pass 'missing or malformed boot cleanup prevents publication from resuming'

: >"$rule"
TEST_BAD_PATH="$TEST_ROOT/run/lock" expect_failure pre_remove
[[ -f $blocker && -f $rule ]]
post_install
[[ ! -e $blocker && ! -e $rule ]]
pass 'untrusted lock directories fail with publication blocked'

printf 'preserve target\n' >"$TEST_ROOT/target"
ln -s "$TEST_ROOT/target" "$blocker"
expect_failure pre_remove
[[ $(cat "$TEST_ROOT/target") == 'preserve target' && -L $blocker ]]
rm "$blocker" "$lock"
ln -s "$TEST_ROOT/target" "$lock"
expect_failure post_install
[[ $(cat "$TEST_ROOT/target") == 'preserve target' && -L $lock && -f $blocker ]]
rm "$lock"
post_install
pass 'linked marker and lock files are rejected without touching their targets'

mv "$TEST_ROOT/etc/sudoers.d" "$TEST_ROOT/policy-outside"
: >"$TEST_ROOT/policy-outside/99-omarchy-nopasswd-1000"
ln -s "$TEST_ROOT/policy-outside" "$TEST_ROOT/etc/sudoers.d"
expect_failure post_install
[[ -f $blocker && -f $TEST_ROOT/policy-outside/99-omarchy-nopasswd-1000 ]]
rm "$TEST_ROOT/etc/sudoers.d"
mv "$TEST_ROOT/policy-outside" "$TEST_ROOT/etc/sudoers.d"
post_install
pass 'linked policy directories are not traversed'

_etc_overrides_apply() { return 1; }
expect_failure post_install
[[ -f $blocker ]]
_etc_overrides_apply() { :; }
TEST_DELETE_FAIL="$blocker" expect_failure post_install
[[ -f $blocker ]]
post_install
[[ ! -e $blocker && -f $permanent && -f $unrelated ]]
pass 'failed install or marker deletion never reports successful recovery'

# Initial image construction has boot defaults but no runtime helper, sudo
# policy directory, or systemd-created lock directory yet.
mv "$TEST_ROOT/etc/sudoers.d" "$TEST_ROOT/saved-policy"
rm -rf "$TEST_ROOT/run/lock"
post_install
[[ -d $TEST_ROOT/run/lock && ! -e $blocker && ! -e $TEST_ROOT/etc/sudoers.d ]]
mv "$TEST_ROOT/saved-policy" "$TEST_ROOT/etc/sudoers.d"
[[ -f $permanent && -f $unrelated ]]
pass 'bootstrap with no policy or runtime lock directory completes without a helper'
'''], env=environment, check=True)
PY
