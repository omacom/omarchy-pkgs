#!/bin/bash
# Create the controller droplet with plain curl. Run from a laptop, once.
#
#   DIGITALOCEAN_TOKEN=... GITHUB_TOKEN=... DO_SSH_KEYS='[123]' ci/controller-box/create.sh [branch]
#
# The DO token given here is baked into the box's env file, so it must be the
# token for the account that should pay for builder droplets.
set -euo pipefail
here=$(dirname "$0")
: "${DIGITALOCEAN_TOKEN:?}" "${GITHUB_TOKEN:?}"
REPO=${REPO:-omacom/omarchy-pkgs}
BRANCH=${1:-master}
REGION=${REGION:-ric1}
NAME=${NAME:-omarchy-controller}
if [[ $BRANCH == -* || $BRANCH == HEAD ]] || ! git check-ref-format "refs/heads/$BRANCH" >/dev/null 2>&1; then
  echo "BRANCH must be a valid git branch name" >&2
  exit 1
fi
ws=$'[ \t\r\n]*'
key_re='([1-9][0-9]*|"[[:xdigit:]]{2}(:[[:xdigit:]]{2}){15}")'
keys_re="^${ws}\[${ws}${key_re}(${ws},${ws}${key_re})*${ws}\]${ws}$"
validate_do_keys() {
  if ! [[ $2 =~ $keys_re ]]; then
    echo "$1 must be a non-empty JSON array of DigitalOcean SSH key IDs or fingerprints" >&2
    exit 1
  fi
  jq -ce . <<<"$2"
}
if [[ ${DO_SSH_KEYS+set} != set && ${SSH_KEYS+set} != set ]]; then
  echo "DO_SSH_KEYS must be a non-empty JSON array of DigitalOcean SSH key IDs or fingerprints" >&2
  exit 1
fi
do_ssh_keys_json=""
if [[ ${DO_SSH_KEYS+set} == set ]]; then
  do_ssh_keys_json=$(validate_do_keys DO_SSH_KEYS "$DO_SSH_KEYS")
fi
if [[ ${SSH_KEYS+set} == set ]]; then
  controller_ssh_keys_json=$(validate_do_keys SSH_KEYS "$SSH_KEYS")
else
  controller_ssh_keys_json=$do_ssh_keys_json
fi

sed_escape() { printf '%s' "$1" | sed 's/[\\&|]/\\&/g'; }
render_cloud_init() {
  sed -e "s|^ssh_authorized_keys: __SSH_KEYS_JSON__\$|ssh_authorized_keys: $(sed_escape "$1")|" \
      -e "s|^    content: __ENV_B64__\$|    content: $2|" \
      -e "s|^  - git clone --depth 1 --branch __BRANCH__ __REPO_URL__ /opt/omarchy-pkgs\$|  - $(sed_escape "$3")|" \
      "$here/cloud-init.yaml"
}
template_check=$(render_cloud_init "" "" "")
if grep -Eq '^[[:space:]]*([^#[:space:]].*)?__[A-Z0-9_]+__' <<<"$template_check"; then
  echo "unsubstituted placeholder in cloud-init.yaml" >&2
  exit 1
fi

# Public keys authorized for root, fetched from each operator's GitHub keys.
# Override with ADMIN_GITHUB_USERS.
ADMIN_GITHUB_USERS=${ADMIN_GITHUB_USERS:-ryanrhughes dhh emirb}
ssh_keys_raw=""
for u in $ADMIN_GITHUB_USERS; do
  user_keys=$(curl -fsS "https://github.com/$u.keys")
  [[ $user_keys =~ [^[:space:]] ]] || { echo "no ssh keys fetched for $u" >&2; exit 1; }
  ssh_keys_raw+="$user_keys"$'\n'
done
ssh_keys_json=$(jq -Rsc 'split("\n") | map(sub("\\r$"; "") | select(test("\\S"))) | select(length > 0)' <<<"$ssh_keys_raw")
[[ -n $ssh_keys_json ]] || { echo "no ssh keys fetched for $ADMIN_GITHUB_USERS" >&2; exit 1; }

clone_cmd=$(jq -nc --arg branch "$BRANCH" --arg url "https://github.com/$REPO.git" \
  '["git","clone","--depth","1","--branch",$branch,$url,"/opt/omarchy-pkgs"]')

sed_args=(
  -e "s|^DIGITALOCEAN_TOKEN=.*|DIGITALOCEAN_TOKEN=$(sed_escape "$DIGITALOCEAN_TOKEN")|"
  -e "s|^GITHUB_TOKEN=.*|GITHUB_TOKEN=$(sed_escape "$GITHUB_TOKEN")|"
  -e "s|^REPO=.*|REPO=$(sed_escape "$REPO")|"
  -e "s|^SSH_KEYS_JSON=.*|SSH_KEYS_JSON=$(sed_escape "$ssh_keys_json")|"
)
if [[ -n $do_ssh_keys_json ]]; then
  sed_args+=(-e "s|^DO_SSH_KEYS=.*|DO_SSH_KEYS=$do_ssh_keys_json|")
fi
env_file=$(sed "${sed_args[@]}" "$here/controller.env.example")
env_b64=$(printf '%s\n' "$env_file" | base64 -w0)
userdata=$(render_cloud_init "$ssh_keys_json" "$env_b64" "$clone_cmd")
body=$(jq -n --arg name "$NAME" --arg region "$REGION" --arg ud "$userdata" --argjson keys "$controller_ssh_keys_json" \
  '{name:$name, region:$region, size:"s-1vcpu-1gb", image:"ubuntu-24-04-x64", tags:["omarchy-controller"], user_data:$ud, ssh_keys:$keys}')

# Refuse to create a second one.
existing=$(curl -fsS -H "Authorization: Bearer $DIGITALOCEAN_TOKEN" \
  "https://api.digitalocean.com/v2/droplets?tag_name=omarchy-controller" | jq '.droplets | length')
if (( existing > 0 )); then echo "a controller droplet already exists" >&2; exit 1; fi

curl -fsS -H "Authorization: Bearer $DIGITALOCEAN_TOKEN" -H "Content-Type: application/json" \
  -X POST -d "$body" https://api.digitalocean.com/v2/droplets | jq -r '"created \(.droplet.name) id=\(.droplet.id)"'
