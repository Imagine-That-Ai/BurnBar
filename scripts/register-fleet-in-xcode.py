#!/usr/bin/env python3
"""Register Live Agent Fleet app Swift files in OpenBurnBar.xcodeproj (idempotent)."""

from __future__ import annotations

import hashlib
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
PROJ = REPO / "OpenBurnBar.xcodeproj/project.pbxproj"
MAC_SOURCES_PHASE = "EF7D3D6CF9326CBCD20C7DF5"

MAC_FILES = [
    "AgentLens/Services/Fleet/BurnBarFleetClientError.swift",
    "AgentLens/Services/Fleet/BurnBarFleetDeliveryRunner.swift",
    "AgentLens/Services/Fleet/BurnBarFleetDirectiveChannel.swift",
    "AgentLens/Services/Fleet/FleetChatOpenPolicy.swift",
    "AgentLens/Services/Fleet/FleetFormatting.swift",
    "AgentLens/Services/Fleet/FleetService.swift",
    "AgentLens/Models/AgentProvider+Fleet.swift",
    "AgentLens/Views/Dashboard/Fleet/FleetAgentCardViews.swift",
    "AgentLens/Views/Dashboard/Fleet/FleetView.swift",
    "AgentLens/Views/Dashboard/Fleet/FleetViewModel.swift",
    "AgentLens/Views/Dashboard/Fleet/FleetWatchControlViews.swift",
]


def stable_id(path: str, salt: str) -> str:
    digest = hashlib.sha256(f"openburnbar-fleet:{salt}:{path}".encode()).hexdigest().upper()
    return digest[:24]


def main() -> int:
    contents = PROJ.read_text()
    file_ref_lines: list[str] = []
    build_file_lines: list[str] = []
    mac_phase_lines: list[str] = []

    for path in MAC_FILES:
        file_name = Path(path).name
        if f"path = {path};" in contents or f"/* {file_name} */ = {{isa = PBXFileReference" in contents:
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
        mac_phase_lines.append(f"\t\t\t\t{build_file_id} /* {file_name} in Sources */,")

    if not (file_ref_lines or build_file_lines or mac_phase_lines):
        print("nothing to add — all files already registered")
        return 0

    if file_ref_lines:
        marker = "/* End PBXFileReference section */"
        contents = contents.replace(marker, "\n".join(file_ref_lines) + "\n\t\t" + marker, 1)
    if build_file_lines:
        marker = "/* End PBXBuildFile section */"
        contents = contents.replace(marker, "\n".join(build_file_lines) + "\n\t\t" + marker, 1)

    if mac_phase_lines:
        pattern = re.compile(
            r"(" + re.escape(MAC_SOURCES_PHASE) + r"\s*/\*\s*Sources\s*\*/\s*=\s*\{[^}]*?files\s*=\s*\(\n)(.*?)(\n\s*\);)",
            re.DOTALL,
        )
        match = pattern.search(contents)
        if not match:
            raise RuntimeError(f"could not find Sources phase {MAC_SOURCES_PHASE}")
        contents = (
            contents[: match.start()]
            + match.group(1)
            + match.group(2)
            + "\n"
            + "\n".join(mac_phase_lines)
            + match.group(3)
            + contents[match.end() :]
        )

    PROJ.write_text(contents)
    print(
        f"registered {len(file_ref_lines)} file refs, "
        f"{len(build_file_lines)} build files, "
        f"{len(mac_phase_lines)} mac-phase entries"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
