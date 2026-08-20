#!/usr/bin/env python3
"""Strips references to a named, no-longer-present source group from a pbxproj.

Intended for throwaway *verification copies* of `OpenBurnBar.xcodeproj` when a
concurrent agent has deleted sources but left their project entries behind, so a
build can be validated without editing the shared project file.

Usage:
    strip-missing-refs-from-pbxproj.py <path-to-project.pbxproj> <token> [...]

Removes, for each token:
  * PBXBuildFile / PBXFileReference lines mentioning it
  * Sources-phase and group-child lines mentioning it
  * whole PBXGroup blocks whose comment is exactly the token
"""

from __future__ import annotations

import re
import sys
from pathlib import Path


def strip(contents: str, token: str) -> tuple[str, int]:
    group_open = re.compile(r"^\t\t[0-9A-F]{24} /\* " + re.escape(token) + r" \*/ = \{$")
    kept: list[str] = []
    removed = 0
    skipping_group = False

    for line in contents.splitlines():
        if skipping_group:
            removed += 1
            if line.strip() == "};":
                skipping_group = False
            continue
        if group_open.match(line):
            skipping_group = True
            removed += 1
            continue
        if token in line:
            removed += 1
            continue
        kept.append(line)

    return "\n".join(kept) + "\n", removed


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    target = Path(argv[1])
    if not target.exists():
        print(f"pbxproj not found at {target}", file=sys.stderr)
        return 2
    contents = target.read_text()
    total = 0
    for token in argv[2:]:
        contents, removed = strip(contents, token)
        print(f"removed {removed} lines mentioning {token}")
        total += removed
    target.write_text(contents)
    return 0 if total else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
