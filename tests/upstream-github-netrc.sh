#!/bin/bash
# github_api_netrc with the real curl against a local server: a hook's plain
# curl sends the job's token to api.github.com, no other host gets it, a
# redirect off api.github.com drops it, an explicit Authorization header
# still wins, and without a token nothing changes.
set -euo pipefail
ROOT=$(realpath "${BASH_SOURCE[0]%/*}/..")
source "$ROOT/helpers/upstream-github.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

# Logs "<Host> <Authorization or ->" per request. /redirect sends the client
# to example.com; everything else answers 200.
port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
cat > "$T/server.py" <<'PY'
import http.server, sys

log = open(sys.argv[2], "a", buffering=1)

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        log.write(f"{self.headers.get('Host')} {self.headers.get('Authorization') or '-'}\n")
        if self.path == "/redirect":
            self.send_response(302)
            self.send_header("Location", "http://example.com/landed")
        else:
            self.send_response(200)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *args):
        pass

http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
PY
python3 -I "$T/server.py" "$port" "$T/requests" >/dev/null 2>&1 &
server=$!
trap 'kill "$server" 2>/dev/null; rm -rf "$T"' EXIT
for _ in {1..50}; do
  curl --noproxy '*' -fsS -o /dev/null "http://127.0.0.1:$port/" 2>/dev/null && break
  sleep 0.1
done

# Hooks use plain curl; --connect-to sends both host names to the server.
hook_curl() {
  curl --noproxy '*' -fsS -o /dev/null --connect-to "api.github.com:80:127.0.0.1:$port" \
    --connect-to "example.com:80:127.0.0.1:$port" "$@"
}
last() { tail -n "${1:-1}" "$T/requests"; }

mkdir "$T/none"
(
  unset CURL_HOME
  UPSTREAM_GITHUB_TOKEN= github_api_netrc "$T/none"
  [[ -z ${CURL_HOME:-} ]] || fail "an empty token still set CURL_HOME"
)
[[ -z $(ls -A "$T/none") ]] && pass "no token, no netrc" || fail "files: $(ls -A "$T/none")"

mkdir -m 700 "$T/auth"
UPSTREAM_GITHUB_TOKEN=job-token github_api_netrc "$T/auth"
[[ ${CURL_HOME:-} == "$T/auth" ]] && pass "CURL_HOME points at the run's directory" || fail "CURL_HOME=${CURL_HOME:-}"
[[ $(stat -c %a "$T/auth/netrc") == "600" ]] && pass "the netrc is private to the run's user" \
  || fail "netrc mode $(stat -c %a "$T/auth/netrc")"

basic="Basic $(printf 'x-access-token:job-token' | base64)"

hook_curl http://api.github.com/repos/owner/repo/releases
[[ $(last) == "api.github.com $basic" ]] && pass "a hook's plain curl authenticates to the API" || fail "request: $(last)"

hook_curl http://example.com/
[[ $(last) == "example.com -" ]] && pass "another host gets no token" || fail "request: $(last)"

hook_curl -L http://api.github.com/redirect
[[ $(last 2) == "api.github.com $basic"$'\n'"example.com -" ]] \
  && pass "a redirect off the API drops the token" || fail "requests: $(last 2)"

hook_curl --config - http://api.github.com/ <<<'header = "Authorization: Bearer job-token"'
[[ $(last) == "api.github.com Bearer job-token" ]] \
  && pass "an explicit Authorization header still wins" || fail "request: $(last)"

(
  unset CURL_HOME
  hook_curl http://api.github.com/
)
[[ $(last) == "api.github.com -" ]] && pass "without the curlrc the API call is anonymous" || fail "request: $(last)"
