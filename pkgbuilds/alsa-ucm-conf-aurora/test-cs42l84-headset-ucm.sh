#!/usr/bin/env bash
set -euo pipefail
docdir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
installed_conf=/usr/share/alsa/ucm2/conf.d/macaudio/cs42l84/Headphones.conf
if [[ -z "${CONF:-}" ]]; then
  if [[ -r "$installed_conf" ]]; then
    conf="$installed_conf"
  elif [[ -r "$docdir/cs42l84-k114-headphones.conf" ]]; then
    conf="$docdir/cs42l84-k114-headphones.conf"
  else
    conf="$docdir/Headphones.conf"
  fi
else
  conf="$CONF"
fi
fixture="${FIXTURE:-$docdir/m5-card1-mixer-names.fixture}"
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
