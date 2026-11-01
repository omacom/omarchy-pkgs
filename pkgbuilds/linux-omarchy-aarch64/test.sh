#!/bin/bash
set -euo pipefail

package_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
python "$package_dir/test_package.py" "${PACKAGE_RECIPE_DIR:-$package_dir}"

kernel_source=${1:-${KERNEL_SOURCE:-}}
if [[ -z $kernel_source ]]; then
  echo 'SKIP compiled function tests: pass the prepared kernel source directory (makepkg check() does this).'
  exit 0
fi
for test in "$package_dir"/test_*.py; do
  [[ $test = */test_package.py ]] && continue
  python "$test" "$kernel_source"
done
