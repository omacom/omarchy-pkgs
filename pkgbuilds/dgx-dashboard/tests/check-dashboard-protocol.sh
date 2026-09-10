#!/bin/bash
set -eu
# Native integration test. Run inside a transient service, never against the
# production bus or credential store:
# sudo systemd-run --wait --pipe --collect -p TemporaryFileSystem=/etc/dgx-dashboard \
#   -p PrivateTmp=yes /usr/bin/bash "$PWD/tests/check-dashboard-protocol.sh"
[[ $(findmnt -n -o TARGET,FSTYPE -T /etc/dgx-dashboard) =~ ^/etc/dgx-dashboard[[:space:]]+tmpfs$ ]] || {
  echo 'This test requires a private tmpfs mounted at /etc/dgx-dashboard' >&2
  exit 1
}
probe=$(mktemp -d /tmp/dgx-dashboard-probe.XXXXXX)
trap 'rm -rf "$probe"' EXIT
cat > "$probe/apt" <<'SH'
#!/bin/sh
case "$*" in
  update) exit 0 ;;
  'list --upgradable') printf 'Listing...\nspark-probe/arch-test 2:3.0-2 aarch64 [upgradable from: 2:2.0-1]\n' ;;
  'dist-upgrade -s') printf 'Inst spark-probe (2:3.0-2 arch-test [aarch64])\n' ;;
  *) exit 1 ;;
esac
SH
cat > "$probe/apt-cache" <<'SH'
#!/bin/sh
[ "$*" = 'show spark-probe' ] || exit 1
printf 'Package: spark-probe\nVersion: 2:3.0-2\nSize: 4096\nDescription: Isolated protocol fixture\n'
SH
chmod +x "$probe/apt" "$probe/apt-cache"
cat > "$probe/check.py" <<'PYTEST'
import json, pathlib, sys
line = pathlib.Path(sys.argv[1]).read_text()
assert line.startswith("s "), line
data = json.loads(json.loads(line[2:]))
rows = data["packageUpdates"]
assert len(rows) == 1, rows
assert rows[0] == {"name": "spark-probe", "currentVersion": "2:2.0-1", "availableVersion": "2:3.0-2", "description": "Isolated protocol fixture", "size": "4.0 kB"}, rows
print("PASS: vendor D-Bus API preserves update versions, description and size")
PYTEST
export DASHBOARD_PROTOCOL_PROBE="$probe"
dbus-run-session -- bash -c '
  export DBUS_SYSTEM_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS"
  export PATH="$DASHBOARD_PROTOCOL_PROBE:/usr/bin"
  /opt/nvidia/dgx-dashboard/dashboard-admin > "$DASHBOARD_PROTOCOL_PROBE/admin.log" 2>&1 &
  child=$!
  trap '\''kill "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true'\'' EXIT
  for attempt in {1..30}; do
    if busctl --address="$DBUS_SESSION_BUS_ADDRESS" call com.nvidia.dgx.dashboard.admin1 /com/nvidia/dgx/dashboard/admin com.nvidia.dgx.dashboard.admin1 GetUpdatesList > "$DASHBOARD_PROTOCOL_PROBE/result" 2>/dev/null; then
      python3 "$DASHBOARD_PROTOCOL_PROBE/check.py" "$DASHBOARD_PROTOCOL_PROBE/result" || exit 1
      exit 0
    fi
    sleep 1
  done
  exit 1
'
