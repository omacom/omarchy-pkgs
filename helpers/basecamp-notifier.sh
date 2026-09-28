# Send notifications to Basecamp Campfire via chatbot
#
# Two destinations, so release traffic does not drown the repository chat:
#
#   OMARCHY_RELEASE_CHATBOT_URL  release activity (starts, publishes, failures)
#   BASECAMP_CHATBOT_URL         everything else, and the fallback when the
#                                release URL is unset
#
# Each is the full chatbot lines URL from Basecamp, e.g.
#   https://3.basecamp.com/<account>/integrations/<key>/buckets/<project>/chats/<chat>/lines
#
# With neither set, notifications are silently skipped.

release_chatbot_url() {
  echo "${OMARCHY_RELEASE_CHATBOT_URL:-${BASECAMP_CHATBOT_URL:-}}"
}

notify_basecamp() {
  local content="$1"
  # NOT named BASECAMP_CHATBOT_URL: bash locals are visible to called
  # functions, so declaring that name here would shadow the global that
  # release_chatbot_url falls back to — and every notification would silently
  # go nowhere for anyone who has only the legacy variable set.
  local url
  url=$(release_chatbot_url)

  if [[ -z "$url" ]]; then
    return 0
  fi

  curl -s -o /dev/null \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg content "$content" '{content: $content}')" \
    "$url" 2>/dev/null || true
}

basecamp_html_escape() {
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

basecamp_strip_ansi() {
  sed -E $'s/\x1B\\[[0-9;?]*[ -/]*[@-~]//g'
}

basecamp_format_log_tail_html() {
  local log_file="$1"
  local lines="${2:-25}"

  [[ -n "$log_file" && -f "$log_file" ]] || return 0

  tail -n "$lines" "$log_file" 2>/dev/null |
    tr -d '\r' |
    basecamp_strip_ansi |
    basecamp_html_escape |
    sed ':a;N;$!ba;s/\n/<br>/g'
}

notify_error() {
  local title="$1"
  local details="${2:-}"
  local log_file="${OMARCHY_LOG_FILE:-${LOG_FILE:-}}"
  local log_tail_lines="${BASECAMP_LOG_TAIL_LINES:-25}"
  local log_tail=""

  local content="🔴 <strong>${title}</strong>"
  if [[ -n "$details" ]]; then
    content+="<br>${details}"
  fi

  log_tail=$(basecamp_format_log_tail_html "$log_file" "$log_tail_lines")
  if [[ -n "$log_tail" ]]; then
    content+="<br><br><strong>Last ${log_tail_lines} log lines:</strong><br><code>${log_tail}</code>"
  fi

  notify_basecamp "$content"
}


# Human-friendly elapsed time: "8m 12s", "45s", "1h 4m".
format_duration() {
  local seconds="${1:-0}"
  if ((seconds >= 3600)); then
    printf '%dh %dm' $((seconds / 3600)) $(((seconds % 3600) / 60))
  elif ((seconds >= 60)); then
    printf '%dm %ds' $((seconds / 60)) $((seconds % 60))
  else
    printf '%ds' "$seconds"
  fi
}

notify_start() {
  local title="$1"
  local details="${2:-}"

  local content="🔨 <strong>${title}</strong>"
  [[ -n "$details" ]] && content+="<br>${details}"
  notify_basecamp "$content"
}

notify_success() {
  local title="$1"
  local details="${2:-}"

  local content="✅ <strong>${title}</strong>"
  [[ -n "$details" ]] && content+="<br>${details}"
  notify_basecamp "$content"
}

notify_info() {
  local title="$1"
  local details="${2:-}"

  local content="📦 <strong>${title}</strong>"
  [[ -n "$details" ]] && content+="<br>${details}"
  notify_basecamp "$content"
}

# "name-1.2.3-1-x86_64.pkg.tar.zst" -> "name 1.2.3-1". Package file names put
# the architecture last and the pkgrel before it, so peel from the right.
package_file_label() {
  local file="$1" stem arch rest rel name_version version name
  stem="${file%.pkg.tar.*}"
  arch="${stem##*-}"
  rest="${stem%-*}"
  rel="${rest##*-}"
  name_version="${rest%-*}"
  version="${name_version##*-}"
  name="${name_version%-*}"
  printf '%s %s-%s' "$name" "$version" "$rel"
}

# Packages sitting in a build-output directory, newest build first. Excludes
# signatures and the scratch database the builder keeps alongside them.
built_package_files() {
  local dir="$1"
  [[ -d "$dir" ]] || return 0
  find "$dir" -maxdepth 1 -name '*.pkg.tar.*' ! -name '*.sig' -printf '%f\n' 2>/dev/null |
    grep -v '^omarchy-build\.' | sort
}

# An HTML list of built packages, capped so a 60-package rebuild does not
# produce an unreadable wall of text in chat.
format_package_list_html() {
  local files="$1"
  local limit="${2:-25}"
  local count shown=0 line out=""

  count=$(grep -c '' <<<"$files")
  [[ -z "$files" ]] && count=0
  ((count == 0)) && return 0

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    ((shown >= limit)) && break
    out+="<br>• $(package_file_label "$line" | basecamp_html_escape)"
    shown=$((shown + 1))
  done <<<"$files"

  if ((count > shown)); then
    out+="<br>• …and $((count - shown)) more"
  fi
  echo "$out"
}
