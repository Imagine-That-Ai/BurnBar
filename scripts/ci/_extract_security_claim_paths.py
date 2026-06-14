#!/usr/bin/env python3
import pathlib
import re

text = pathlib.Path("security/threat-model/security-claims.md").read_text(encoding="utf-8")
paths = set()
for match in re.finditer(
    r"`((?:AgentLens|OpenBurnBar(?:Core|Mobile|Daemon)?|android|functions|firestore\.rules|crates)/[^`]+)`",
    text,
):
    candidate = match.group(1).split(":", 1)[0].strip()
    if any(ch in candidate for ch in "?*"):
        continue
    paths.add(candidate)

for path in sorted(paths):
    print(path)
