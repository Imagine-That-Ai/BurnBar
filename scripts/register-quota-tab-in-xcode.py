#!/usr/bin/env python3
"""One-shot helper that registers the new Quota workspace + Burn Rail
context pill Swift files in the OpenBurnBar Xcode project. All files go
into the OpenBurnBar target's Sources phase (EF7D3D6CF9326CBCD20C7DF5).

Same registration shape as
`scripts/register-computer-use-in-xcode.py`:
  * one PBXFileReference (declares the file on disk via SOURCE_ROOT)
  * one PBXBuildFile (links the file ref to a build phase)
  * one entry in the Sources phase's `files = ( ... )` block.

Idempotent: re-runs detect existing entries by path and skip.
"""
from __future__ import annotations
import hashlib
import sys
import re
from pathlib import Path

REPO = Path("/Users/albertonunez/Documents/Windsurf/BurnBar")
PROJ = REPO / "OpenBurnBar.xcodeproj/project.pbxproj"

MAC_SOURCES_PHASE = "EF7D3D6CF9326CBCD20C7DF5"

MAC_FILES = [
    "AgentLens/Views/Dashboard/Quota/QuotaWorkspaceViewModel.swift",
    "AgentLens/Views/Dashboard/Quota/QuotaArcDial.swift",
    "AgentLens/Views/Dashboard/Quota/SubscriptionCard.swift",
    "AgentLens/Views/Dashboard/Quota/SubscriptionConstellationHero.swift",
    "AgentLens/Views/Dashboard/Quota/QuotaResetAtlas.swift",
    "AgentLens/Views/Dashboard/Quota/QuotaFilterRail.swift",
    "AgentLens/Views/Dashboard/Quota/QuotaEmptyState.swift",
    "AgentLens/Views/Dashboard/Quota/QuotaWorkspaceView.swift",
]


def stable_id(path: str, salt: str) -> str:
    h = hashlib.sha256(f"openburnbar-quota:{salt}:{path}".encode()).hexdigest().upper()
    return h[:24]


def main() -> int:
    if not PROJ.exists():
        print(f"pbxproj not found at {PROJ}", file=sys.stderr)
        return 2
    contents = PROJ.read_text()

    file_ref_lines: list[str] = []
    build_file_lines: list[str] = []
    mac_phase_lines: list[str] = []

    for path in MAC_FILES:
        file_name = Path(path).name
        if f"path = {path};" in contents:
            print(f"already registered: {path}")
            continue
        file_ref_id = stable_id(path, "fileref")
        build_file_id = stable_id(path, "buildfile")
        file_ref_lines.append(
            f"\t\t{file_ref_id} /* {file_name} */ = {{isa = PBXFileReference; "
            f"lastKnownFileType = sourcecode.swift; name = {file_name}; "
            f"path = {path}; sourceTree = SOURCE_ROOT; }};"
        )
        build_file_lines.append(
            f"\t\t{build_file_id} /* {file_name} in Sources */ = "
            f"{{isa = PBXBuildFile; fileRef = {file_ref_id} /* {file_name} */; }};"
        )
        mac_phase_lines.append(
            f"\t\t\t\t{build_file_id} /* {file_name} in Sources */,"
        )

    if not (file_ref_lines or build_file_lines or mac_phase_lines):
        print("nothing to add — all files already registered")
        return 0

    if file_ref_lines:
        marker = "/* End PBXFileReference section */"
        injection = "\n".join(file_ref_lines) + "\n\t\t" + marker
        contents = contents.replace(marker, injection, 1)

    if build_file_lines:
        marker = "/* End PBXBuildFile section */"
        injection = "\n".join(build_file_lines) + "\n\t\t" + marker
        contents = contents.replace(marker, injection, 1)

    def inject_into_phase(phase_id: str, lines: list[str]):
        nonlocal contents
        if not lines:
            return
        pattern = re.compile(
            r"(" + re.escape(phase_id) + r"\s*/\*\s*Sources\s*\*/\s*=\s*\{[^}]*?files\s*=\s*\(\n)(.*?)(\n\s*\);)",
            re.DOTALL,
        )
        m = pattern.search(contents)
        if not m:
            raise RuntimeError(f"could not find Sources phase {phase_id}")
        head, body, tail = m.group(1), m.group(2), m.group(3)
        new_body = body + "\n" + "\n".join(lines)
        contents = contents[: m.start()] + head + new_body + tail + contents[m.end():]

    inject_into_phase(MAC_SOURCES_PHASE, mac_phase_lines)

    PROJ.write_text(contents)
    print(f"registered {len(file_ref_lines)} file refs, "
          f"{len(build_file_lines)} build files, "
          f"{len(mac_phase_lines)} mac-phase entries")
    return 0


if __name__ == "__main__":
    sys.exit(main())
