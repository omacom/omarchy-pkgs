#!/bin/bash
# Usage: auto-merge-action.sh PR ENABLE WITHDRAW
#
# Turns auto-merge-pr.cjs's decision into the one write auto-merge-pr.yml
# needs, from the PR's live auto-merge state: enable on a PR that qualifies
# and is not armed, withdraw from one that no longer qualifies and is armed,
# otherwise none. Prints action=<enable|withdraw|none> last, and appends it to
# $GITHUB_OUTPUT when set. A failed lookup fails the script, so it never
# reads as "not armed". Needs GH_TOKEN and GITHUB_REPOSITORY.
set -euo pipefail

pr=${1:?PR required}
enable=${2:?ENABLE required}
withdraw=${3:?WITHDRAW required}
repo=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}
# Only a PR number exactly as a person types it: gh reads anything else as a
# branch name.
[[ $pr =~ ^[1-9][0-9]*$ ]] || { echo "auto-merge-action.sh: not a PR number: $pr" >&2; exit 2; }

armed=$(gh pr view "$pr" -R "$repo" --json autoMergeRequest --jq '.autoMergeRequest != null')
action=none
if [[ $enable == true && $armed != true ]]; then
  action=enable
elif [[ $withdraw == true && $armed == true ]]; then
  action=withdraw
fi
echo "#$pr: $action"
if [[ -n ${GITHUB_OUTPUT:-} ]]; then echo "action=$action" >> "$GITHUB_OUTPUT"; fi
echo "action=$action"
