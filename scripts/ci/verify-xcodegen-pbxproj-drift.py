#!/usr/bin/env python3
"""Fail closed on semantic Xcode project drift while tolerating PBX object IDs.

XcodeGen can regenerate stable project content with different 24-character PBX
object identifiers. Those identifiers are implementation details. The rest of
the pbxproj is the contract: sources, targets, build phases, settings,
entitlements, package products, and shell scripts must already match the
generated project.
"""

from __future__ import annotations

import difflib
import re
import sys
from pathlib import Path


PBX_ID = re.compile(r"\b[A-F0-9]{24}\b")


def canonical_pbxproj(path: Path) -> list[str]:
    text = path.read_text(encoding="utf-8", errors="replace").replace("\r\n", "\n")
    # Replace generated PBX object ids everywhere, including references. This
    # preserves line-level project semantics while ignoring meaningless ID churn.
    text = PBX_ID.sub("<PBXID>", text)
    return text.splitlines(keepends=True)


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(
            "usage: verify-xcodegen-pbxproj-drift.py <committed.pbxproj> <generated.pbxproj>",
            file=sys.stderr,
        )
        return 2

    committed_path = Path(argv[1])
    generated_path = Path(argv[2])
    committed = canonical_pbxproj(committed_path)
    generated = canonical_pbxproj(generated_path)

    if committed == generated:
        print("project.pbxproj semantic content is in sync; PBX object ID churn ignored.")
        return 0

    print("project.pbxproj semantic drift detected after normalizing PBX object IDs.", file=sys.stderr)
    print(
        "".join(
            difflib.unified_diff(
                committed,
                generated,
                fromfile=str(committed_path),
                tofile=str(generated_path),
                n=3,
            )
        ),
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
