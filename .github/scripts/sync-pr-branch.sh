#!/bin/bash
# Usage: sync-pr-branch.sh BASE_BRANCH [PACKAGE...]
#
# Prints the branch a sync workflow run pushes to, as branch=/scope= lines for
# $GITHUB_OUTPUT. An unscoped (scheduled) run owns BASE_BRANCH and regenerates
# it from master every time. A run scoped to named packages regenerates only
# those, so it gets its own branch and PR: pushing it to BASE_BRANCH would
# replace every other pending update there with just the named packages.
set -euo pipefail

base=${1:?base branch required}
shift
if (( $# == 0 )); then
  printf 'branch=%s\nscope=\n' "$base"
  exit 0
fi

names=()
for name in "$@"; do
  # Package directory names, as pacman allows them. Anything else is a typo
  # or an attempt to smuggle something into a ref name or PR title.
  if [[ ! $name =~ ^[a-z0-9@_+][a-z0-9@._+-]*$ ]]; then
    echo "invalid package name: $name" >&2
    exit 1
  fi
  names+=("$name")
done
mapfile -t names < <(printf '%s\n' "${names[@]}" | sort -u)

scope="${names[*]}"
slug=$(printf '%s\n' "${names[@]}" | sed 's/[^a-z0-9]\{1,\}/-/g; s/^-//; s/-$//' | paste -sd- -)
# Keep long package lists to a readable ref; the hash keeps distinct lists apart.
hash=$(printf '%s' "$scope" | sha256sum | cut -c1-10)
if [[ -z $slug ]]; then
  slug=$hash
elif (( ${#slug} > 60 )); then
  slug="${slug:0:48}"
  slug="${slug%-}-$hash"
fi
printf 'branch=%s-%s\nscope=%s\n' "$base" "$slug" "$scope"
