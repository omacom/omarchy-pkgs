#!/usr/bin/python3
# SPDX-License-Identifier: MIT
"""Read Chrome's user flags as arguments, without evaluating shell code."""
import os
from pathlib import Path
import shlex
import sys


def main():
    config = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config")
    path = config / "chrome-flags.conf"
    try:
        # The file replaces CHROME_USER_FLAGS, as in the old launcher.
        # Shell quotes group arguments; substitutions and globs stay literal.
        source = path.read_text() if path.is_file() else os.environ.get("CHROME_USER_FLAGS", "")
        flags = shlex.split(source, comments=True, posix=True)
    except (OSError, ValueError) as error:
        sys.exit(f"Cannot read Chrome flags: {error}")
    launcher = "/opt/google/chrome/google-chrome"
    os.execv(launcher, [launcher, *flags, *sys.argv[1:]])


if __name__ == "__main__":
    main()
