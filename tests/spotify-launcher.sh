#!/bin/bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
mkdir -p "$test_tmp/home/.config" "$test_tmp/config with spaces"

# Run the real wrapper, replacing only its absolute executable path.
cat > "$test_tmp/capture" <<'SH'
#!/bin/bash
if (( $# )); then
  printf '%s\0' "$@" > "$SPOTIFY_TEST_ARGS"
else
  : > "$SPOTIFY_TEST_ARGS"
fi
exit 37
SH
chmod +x "$test_tmp/capture"
sed "s|^exec /opt/spotify/spotify |exec $test_tmp/capture |" \
  "$ROOT/pkgbuilds/spotify/spotify.sh" > "$test_tmp/spotify"

failures=0
check() {
  local name=$1 mode=$2 content=$3 status=0
  shift 3
  local config="$test_tmp/config with spaces"
  local -a environment=(env -u XDG_CONFIG_HOME "HOME=$test_tmp/home"
    "SPOTIFY_TEST_ARGS=$test_tmp/actual")
  rm -f "$test_tmp/home/.config/spotify-flags.conf" "$config/spotify-flags.conf"
  case $mode in
    explicit) environment+=("XDG_CONFIG_HOME=$config") ;;
    unset) config="$test_tmp/home/.config" ;;
    empty) config="$test_tmp/home/.config"; environment+=(XDG_CONFIG_HOME=) ;;
  esac
  if [[ $content != absent ]]; then
    printf '%s' "$content" > "$config/spotify-flags.conf"
  fi
  # The extra CLI arguments must follow configured arguments, including an empty one.
  printf '%s\0' "$@" --cli 'cli argument with spaces' '' > "$test_tmp/expected"
  rm -f "$test_tmp/actual"
  (cd "$test_tmp" && "${environment[@]}" bash "$test_tmp/spotify" \
    --cli 'cli argument with spaces' '') > "$test_tmp/stdout" 2> "$test_tmp/stderr" || status=$?
  if [[ $status == 37 ]] && cmp -s "$test_tmp/expected" "$test_tmp/actual" && [[ ! -e $test_tmp/evaluated ]]; then
    echo "PASS: $name"
  else
    echo "FAIL: $name (status $status)"
    echo 'Expected / actual argument bytes:'
    od -An -tx1 "$test_tmp/expected" "$test_tmp/actual"
    failures=$((failures + 1))
  fi
}

check 'no flags file' explicit absent
check 'empty file' explicit ''
check 'comments only' explicit $'# first\n# second\n'
check 'blank and whitespace-only lines' explicit $'\n--first\n\n \t \n--second\n\n' --first --second
check 'indented comments' explicit $'  # spaces\n\t# tab\n--first\n' --first
check 'separate flags' explicit $'--disable-gpu\n--no-zygote\n' --disable-gpu --no-zygote
check 'final line without newline' explicit $'--first\n--last' --first --last
check 'one argument per line, preserving whitespace' explicit $'  --value=two words  \n--disable-gpu --no-zygote\n' \
  '  --value=two words  ' '--disable-gpu --no-zygote'
literal=$'--quoted="two words"\n--path=C:\\music\\file\n--hash=value#literal\n$HOME\n$(touch evaluated)\n*\n; touch evaluated;\n'
# shellcheck disable=SC2016 # These expressions must remain literal arguments.
check 'literal quotes, backslashes, hash and shell metacharacters' explicit "$literal" \
  '--quoted="two words"' '--path=C:\music\file' '--hash=value#literal' \
  '$HOME' '$(touch evaluated)' '*' '; touch evaluated;'
check 'unset XDG_CONFIG_HOME fallback' unset $'--fallback\n' --fallback
check 'empty XDG_CONFIG_HOME fallback' empty $'--fallback\n' --fallback

if (( failures )); then
  echo "$failures Spotify launcher case(s) failed"
  exit 1
fi
echo 'All 11 Spotify launcher cases passed'
