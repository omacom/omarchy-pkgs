#!/usr/bin/env python3
"""Check whether the running UPower daemon applies the critical action."""

import subprocess
import sys


def main() -> int:
    command = [
        "busctl",
        "--system",
        "call",
        "org.freedesktop.UPower",
        "/org/freedesktop/UPower",
        "org.freedesktop.UPower",
        "GetCriticalAction",
    ]
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    if result.returncode:
        detail = result.stderr.strip() or f"busctl exited with status {result.returncode}"
        print(f"cannot read running UPower critical action: {detail}", file=sys.stderr)
        return 1

    actual = result.stdout.strip()
    if actual != 's "PowerOff"':
        print(
            f'running UPower critical action is {actual or "empty"}, expected s "PowerOff"',
            file=sys.stderr,
        )
        return 1

    print("running UPower critical action is PowerOff")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
