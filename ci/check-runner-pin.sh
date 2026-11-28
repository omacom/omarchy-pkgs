#!/bin/bash
# Verify the pinned GitHub Actions runner linux-x64 tarball SHA-256 in
# ci/runner-cloud-init.yaml against the upstream release asset digest.
#
# Always validates that exactly one valid RUNNER_VERSION and RUNNER_SHA256
# assignment exists. Skips the release API call only when a known base commit
# (PR parent or push before-SHA) has the exact same pin.
set -euo pipefail

extract_pin() {
  sed -n -E 's/^[[:space:]]*RUNNER_(VERSION|SHA256)=/\1=/p'
}

ver_count=$(grep -Ec '^[[:space:]]*RUNNER_VERSION=' ci/runner-cloud-init.yaml || true)
sha_count=$(grep -Ec '^[[:space:]]*RUNNER_SHA256=' ci/runner-cloud-init.yaml || true)
cur=$(extract_pin < ci/runner-cloud-init.yaml)
ver=$(sed -n 's/^VERSION=//p' <<< "$cur")
sha=$(sed -n 's/^SHA256=//p' <<< "$cur")

[[ $ver_count == 1 && $sha_count == 1 && $ver =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && $sha =~ ^[0-9a-f]{64}$ ]] || {
  echo "::error file=ci/runner-cloud-init.yaml::invalid RUNNER_VERSION ($ver) or RUNNER_SHA256 ($sha)"
  exit 1
}

base=""
if [[ ${GITHUB_EVENT_NAME:-} == pull_request ]]; then
  base="HEAD^1"
elif [[ ${GITHUB_EVENT_NAME:-} == push && -n ${PUSH_BEFORE:-} && ! $PUSH_BEFORE =~ ^0+$ ]]; then
  base="$PUSH_BEFORE"
  if ! git cat-file -e "${base}^{commit}" 2>/dev/null; then
    git fetch --no-tags --depth=1 origin "$base" 2>/dev/null || true
  fi
fi

if [[ -n $base ]] && git cat-file -e "${base}^{commit}" 2>/dev/null; then
  old=$(git show "${base}:ci/runner-cloud-init.yaml" 2>/dev/null | extract_pin || true)
  if [[ $cur == "$old" ]]; then
    echo "runner tarball pin unchanged"
    exit 0
  fi
fi

asset="actions-runner-linux-x64-$ver.tar.gz"
digest=$(gh api "repos/actions/runner/releases/tags/v$ver" \
  | jq -r --arg name "$asset" '.assets[] | select(.name == $name) | .digest // empty')
[[ -n $digest ]] || {
  echo "::error file=ci/runner-cloud-init.yaml::missing digest for $asset in actions/runner release v$ver"
  exit 1
}
[[ $digest == "sha256:$sha" ]] || {
  echo "::error file=ci/runner-cloud-init.yaml::RUNNER_SHA256 ($sha) does not match actions/runner v$ver ($digest)"
  exit 1
}
