#!/usr/bin/env python3
"""Register receipts files in OpenBurnBar.xcodeproj (idempotent)."""

from __future__ import annotations

import hashlib
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
PROJ = REPO / "OpenBurnBar.xcodeproj/project.pbxproj"
MAC_SOURCES_PHASE = "EF7D3D6CF9326CBCD20C7DF5"
TESTS_SOURCES_PHASE = "E35F1758B10CAD71B485DA35"

APP_PATHS = [
    "AgentLens/Services/Settings/Stores/ReceiptSettings.swift",
    "AgentLens/Services/Receipts/ReceiptAccomplishmentSynthesizer.swift",
    "AgentLens/Services/Receipts/ReceiptQualityAuditor.swift",
    "AgentLens/Services/Receipts/CLISessionCloseMonitor.swift",
    "AgentLens/Services/DataStore/OpenBurnBarDatabase+MigrationV66.swift",
    "AgentLens/Views/Receipts/ReceiptAudioPlayer.swift",
    "AgentLens/Views/Receipts/ReceiptMiniFlyoutPopover.swift",
    "AgentLens/Views/Settings/ReceiptSettingsView.swift",
    "AgentLens/App/ReceiptFlyoutController.swift",
]

TEST_PATHS = [
    "AgentLensTests/Active/ReceiptSessionAccomplishmentsAndQualityTests.swift",
]


def stable_id(path: str, salt: str) -> str:
    h = hashlib.sha256(f"openburnbar-receipts:{salt}:{path}".encode()).hexdigest().upper()
    return h[:24]


def pbx_quote(value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def add_files_to_phase(contents: str, paths: list[str], phase_id: str) -> str:
    file_ref_lines: list[str] = []
    build_file_lines: list[str] = []
    phase_lines: list[str] = []

    for path in paths:
        file_name = Path(path).name
        if f" /* {file_name} */ = {{isa = PBXFileReference" in contents:
            print(f"skip existing file ref: {path}")
            continue
        if f"path = {pbx_quote(path)};" in contents:
            print(f"skip existing path ref: {path}")
            continue

        file_ref_id = stable_id(path, "fileref")
        build_file_id = stable_id(path, "buildfile")
        quoted_path = pbx_quote(path)
        file_ref_lines.append(
            f"\t\t{file_ref_id} /* {file_name} */ = {{isa = PBXFileReference; "
            f"lastKnownFileType = sourcecode.swift; name = {pbx_quote(file_name)}; "
            f"path = {quoted_path}; sourceTree = SOURCE_ROOT; }};"
        )
        build_file_lines.append(
            f"\t\t{build_file_id} /* {file_name} in Sources */ = "
            f"{{isa = PBXBuildFile; fileRef = {file_ref_id} /* {file_name} */; }};"
        )
        phase_lines.append(f"\t\t\t\t{build_file_id} /* {file_name} in Sources */,")

    if file_ref_lines:
        marker = "/* End PBXFileReference section */"
        if marker not in contents:
            raise RuntimeError("PBXFileReference section end marker not found")
        contents = contents.replace(marker, "\n".join(file_ref_lines) + "\n" + marker, 1)

    if build_file_lines:
        marker = "/* End PBXBuildFile section */"
        if marker not in contents:
            raise RuntimeError("PBXBuildFile section end marker not found")
        contents = contents.replace(marker, "\n".join(build_file_lines) + "\n" + marker, 1)

    if phase_lines:
        pattern = re.compile(
            r"("
            + re.escape(phase_id)
            + r"\s*/\*\s*Sources\s*\*/\s*=\s*\{[^}]*?files\s*=\s*\(\n)(.*?)(\n\s*\);)",
            re.DOTALL,
        )
        m = pattern.search(contents)
        if not m:
            raise RuntimeError(f"Sources phase {phase_id} not found")
        head, body, tail = m.group(1), m.group(2), m.group(3)
        contents = contents[: m.start()] + head + body + "\n" + "\n".join(phase_lines) + tail + contents[m.end() :]

    return contents


def main() -> int:
    if not PROJ.exists():
        print(f"missing {PROJ}", file=sys.stderr)
        return 2

    contents = PROJ.read_text()
    contents = add_files_to_phase(contents, APP_PATHS, MAC_SOURCES_PHASE)
    contents = add_files_to_phase(contents, TEST_PATHS, TESTS_SOURCES_PHASE)
    PROJ.write_text(contents)
    print("Successfully registered receipt files in OpenBurnBar.xcodeproj")
    return 0


if __name__ == "__main__":
    sys.exit(main())
