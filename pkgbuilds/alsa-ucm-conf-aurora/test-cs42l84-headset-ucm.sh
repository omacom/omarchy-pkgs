#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
conf="${CONF:-$here/Headphones.conf}"
fixture="${FIXTURE:-$here/m5-card1-mixer-names.txt}"
mapfile -t csets < <(grep -oE "name='[^']+'" "$conf" | sed "s/name='//;s/'$//")
for e in "Jack ADC PGA Capture Volume" "Jack ADC Preamp Capture Volume" "Jack DAC Playback Volume"; do
  grep -qF "$e" "$conf" && csets+=("$e")
done
[[ -r "$fixture" ]] || { echo "no fixture"; exit 1; }
missing=0
for n in "${csets[@]}"; do
  grep -qxF "$n" "$fixture" || { echo "MISSING $n"; missing=$((missing+1)); }
done
[[ $missing -eq 0 ]] || exit 1
echo PASS
