#!/usr/bin/python3
# SPDX-License-Identifier: MIT
"""Read Chrome's user flags as arguments, without evaluating shell code."""
import os
from pathlib import Path
import shlex
import sys


def user_flags(source):
    # Comments start at unquoted token boundaries; URL fragments stay literal.
    text = []
    quote = None
    escaped = False
    token = False
    comment = False
    for char in source:
        if comment:
            if char != "\n":
                continue
            comment = False
        if escaped:
            escaped = False
        elif quote:
            if char == quote:
                quote = None
            elif char == "\\" and quote == '"':
                escaped = True
        elif char == "#" and not token:
            comment = True
            continue
        elif char in " \t\r\n":
            token = False
        else:
            token = True
            if char in "'\"":
                quote = char
            elif char == "\\":
                escaped = True
        text.append(char)
    # Validate quotes/escapes and group argv without evaluating shell code.
    return shlex.split("".join(text), comments=False, posix=True)


def main():
    config = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config")
    path = config / "chrome-flags.conf"
    try:
        # The file replaces CHROME_USER_FLAGS, as in the old launcher.
        # Shell quotes group arguments; substitutions and globs stay literal.
        source = path.read_text() if path.is_file() else os.environ.get("CHROME_USER_FLAGS", "")
        flags = user_flags(source)
    except (OSError, ValueError) as error:
        sys.exit(f"Cannot read Chrome flags: {error}")
    launcher = "/opt/google/chrome/google-chrome"
    os.execv(launcher, [launcher, *flags, *sys.argv[1:]])


if __name__ == "__main__":
    main()
