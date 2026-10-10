#!/bin/bash

# latest_artifact <repository> <label>: emit the newest unexpired artifact as
# JSON, or null for a successful empty lookup. Any lookup failure is nonzero.
latest_artifact() (
  local repository=$1 label=$2 response
  response=$(mktemp) || return 1
  trap 'rm -f "$response"' EXIT
  # curl retries transient HTTP errors and timeouts with 1, 2, 4 second
  # backoff. A file keeps partial/retried responses out of the JSON stream.
  if ! curl -fsS --retry 3 --retry-max-time 120 --connect-timeout 10 --max-time 30 \
    -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" \
    -o "$response" \
    "https://api.github.com/repos/$repository/actions/artifacts?name=$label&per_page=5"; then
    echo "::error::$label: artifact discovery request failed" >&2
    return 1
  fi
  jq -cs '
    if length != 1 then error("expected one artifact response") else .[0] end
    | if (.artifacts | type) != "array" then error("expected artifacts array") else . end
    | if all(.artifacts[]; (.expired | type) == "boolean") then .
      else error("expected artifact expiry flags") end
    | [.artifacts[] | select(.expired | not)]
    | if all(.[]; (.created_at | type) == "string"
        and (.expires_at | type) == "string"
        and (.archive_download_url | type) == "string"
        and (.workflow_run.id | type) == "number") then .
      else error("incomplete artifact metadata") end
    | sort_by(.created_at) | last
  ' "$response" || { echo "::error::$label: invalid artifact discovery response" >&2; return 1; }
)
