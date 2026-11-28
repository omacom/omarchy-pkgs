#!/bin/bash
set -euo pipefail
package_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
exec python3 -m unittest discover -s "$package_dir/tests"
