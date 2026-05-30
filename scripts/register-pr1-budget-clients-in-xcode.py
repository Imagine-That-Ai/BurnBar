#!/usr/bin/env python3
"""Register PR1 budget client files in OpenBurnBar.xcodeproj (idempotent)."""
from __future__ import annotations

import hashlib
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
PROJ = REPO / "OpenBurnBar.xcodeproj/project.pbxproj"
MAC_SOURCES = "EF7D3D6CF9326CBCD20C7DF5"
MOBILE_SOURCES = "8A2E9F1C3D4B5A6E7F8091A2"  # placeholder - discover dynamically

ENTRIES = [
    ("AgentLens/Services/Media/MediaBudgetStatusStore.swift", MAC_SOURCES, "Media"),
    ("AgentLensTests/Active/ComputerUseBudgetStatusStoreTests.swift", "7223", "Active"),
    ("AgentLensTests/Active/MediaBudgetStatusStoreTests.swift", "7223", "Active"),
    ("OpenBurnBarMobile/Services/Media/MobileMediaBudgetStatusStore.swift", None, "Media"),
]


def stable_id(path: str, salt: str) -> str:
    h = hashlib.sha256(f"openburnbar-pr1:{salt}:{path}".encode()).hexdigest().upper()
    return h[:24]


def pbx_quote(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def find_mobile_sources_phase(text: str) -> str | None:
    m = re.search(
        r"([0-9A-F]{24}) /\* Sources \*/ = \{\s*isa = PBXSourcesBuildPhase;\s*buildActionMask = 2147483647;\s*files = \(\s*(?:\t\t\t\t[0-9A-F]{24} /\* OpenBurnBarMobileApp\.swift in Sources \*/,\n)?",
        text,
    )
    if not m:
        # fallback: section containing MobileMediaBudgetStatusStore target build
        for line in text.splitlines():
            if "OpenBurnBarMobileApp.swift in Sources" in line:
                # find phase id by searching backwards in file - use known pattern from grep
                break
    # Use explicit id from project if MobileMediaBudgetStatusStore registration needed
    match = re.search(
        r"([0-9A-F]{24}) /\* Sources \*/ = \{\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = \(\n\t\t\t\t[0-9A-F]{24} /\* OpenBurnBarMobileApp\.swift in Sources \*/",
        text,
    )
    return match.group(1) if match else None


def main() -> int:
    text = PROJ.read_text(encoding="utf-8")
    mobile_phase = find_mobile_sources_phase(text)
    changed = False

    for path, phase_hint, _group in ENTRIES:
        name = Path(path).name
        if name in text and f"path = {pbx_quote(name)}" in text:
            continue
        phase = phase_hint or mobile_phase
        if phase is None:
            print(f"skip {path}: no build phase", file=sys.stderr)
            continue
        if isinstance(phase, str) and len(phase) != 24:
            phase = MAC_SOURCES if "AgentLens" in path or "AgentLensTests" in path else mobile_phase
        if phase is None:
            continue

        file_id = stable_id(path, "fileref")
        build_id = stable_id(path, "buildfile")
        if file_id in text:
            continue

        file_line = (
            f"\t\t{file_id} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; "
            f"path = {pbx_quote(name)}; sourceTree = \"<group>\"; }};\n"
        )
        build_line = (
            f"\t\t{build_id} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_id} /* {name} */; }};\n"
        )
        text = text.replace(
            "/* End PBXBuildFile section */",
            f"{build_line}/* End PBXBuildFile section */",
            1,
        )
        text = text.replace(
            "/* End PBXFileReference section */",
            f"{file_line}/* End PBXFileReference section */",
            1,
        )
        text = re.sub(
            rf"({phase} /\* Sources \*/ = \{{\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = \(\n)",
            rf"\1\t\t\t\t{build_id} /* {name} in Sources */,\n",
            text,
            count=1,
        )
        changed = True
        print(f"registered {path}")

    if changed:
        PROJ.write_text(text, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
