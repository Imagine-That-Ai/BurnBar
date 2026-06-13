#!/usr/bin/env python3
"""Register PR1 budget client files in OpenBurnBar.xcodeproj (idempotent)."""
from __future__ import annotations

import hashlib
import re
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
PROJ = REPO / "OpenBurnBar.xcodeproj/project.pbxproj"

MAC_APP_SOURCES = "EF7D3D6CF9326CBCD20C7DF5"
MAC_TESTS_SOURCES = "E35F1758B10CAD71B485DA35"
MOBILE_APP_SOURCES = "989FB439884BAD69F857287F"
MAC_MEDIA_GROUP = "8D1E07F4A588FA070F6F8494"
MOBILE_MEDIA_GROUP = "BFFDEA97568D36B83610F51D"
ACTIVE_TESTS_GROUP = "7223"  # wrong - need real id

# Active group id from pbxproj (AgentLensTests/Active)
ACTIVE_TESTS_GROUP = None  # discovered below

ENTRIES: list[tuple[str, str, str | None]] = [
    ("AgentLens/Services/Media/MediaBudgetStatusStore.swift", MAC_APP_SOURCES, MAC_MEDIA_GROUP),
    (
        "AgentLensTests/Active/ComputerUseBudgetStatusStoreTests.swift",
        MAC_TESTS_SOURCES,
        "E35F1758B10CAD71B485DA35_ACTIVE",  # placeholder
    ),
    (
        "AgentLensTests/Active/MediaBudgetStatusStoreTests.swift",
        MAC_TESTS_SOURCES,
        "E35F1758B10CAD71B485DA35_ACTIVE",
    ),
    (
        "OpenBurnBarMobile/Services/Media/MobileMediaBudgetStatusStore.swift",
        MOBILE_APP_SOURCES,
        MOBILE_MEDIA_GROUP,
    ),
]


def stable_id(path: str, salt: str) -> str:
    h = hashlib.sha256(f"openburnbar-pr1:{salt}:{path}".encode()).hexdigest().upper()
    return h[:24]


def pbx_quote(value: str) -> str:
    if re.match(r"^[A-Za-z0-9_./-]+$", value):
        return value
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def find_active_tests_group(text: str) -> str:
    m = re.search(
        r"([0-9A-F]{24}) /\* Active \*/ = \{\s*isa = PBXGroup;\s*children = \(",
        text,
    )
    if not m:
        raise RuntimeError("AgentLensTests/Active group not found")
    return m.group(1)


def insert_into_group(text: str, group_id: str, file_ref_line: str, file_name: str) -> str:
    needle = f"{file_ref_line.split()[0]} /* {file_name} */,"
    if needle in text:
        return text
    pattern = re.compile(
        rf"({re.escape(group_id)}\s*/\*\s*Active\s*\*/\s*=\s*\{{[^}}]*?children\s*=\s*\(\n)"
        if "Active" in text[text.find(group_id) : text.find(group_id) + 200]
        else rf"({re.escape(group_id)}\s*/\*\s*Media\s*\*/\s*=\s*\{{[^}}]*?children\s*=\s*\(\n)",
        re.DOTALL,
    )
    # Generic: match group by id only
    pattern = re.compile(
        rf"({re.escape(group_id)}[^=]*=\s*\{{[^}}]*?children\s*=\s*\(\n)(.*?)(\n\s*\);)",
        re.DOTALL,
    )
    m = pattern.search(text)
    if not m:
        raise RuntimeError(f"PBXGroup {group_id} not found")
    if file_name in m.group(2):
        return text
    return text[: m.start()] + m.group(1) + m.group(2) + f"\t\t\t\t{needle}\n" + m.group(3) + text[m.end() :]


def insert_into_phase(text: str, phase_id: str, build_line: str, file_name: str) -> str:
    needle = f"{build_line.split()[0]} /* {file_name} in Sources */,"
    if needle in text:
        return text
    pattern = re.compile(
        rf"({re.escape(phase_id)}\s*/\*\s*Sources\s*\*/\s*=\s*\{{[^}}]*?files\s*=\s*\(\n)(.*?)(\n\s*\);)",
        re.DOTALL,
    )
    m = pattern.search(text)
    if not m:
        raise RuntimeError(f"Sources phase {phase_id} not found")
    if file_name in m.group(2) and "in Sources */," in m.group(2):
        return text
    return text[: m.start()] + m.group(1) + m.group(2) + f"\t\t\t\t{needle}\n" + m.group(3) + text[m.end() :]


def main() -> int:
    text = PROJ.read_text(encoding="utf-8")
    active_group = find_active_tests_group(text)
    changed = False

    for path, phase_id, group_hint in ENTRIES:
        name = Path(path).name
        if f"/* {name} */ = {{isa = PBXFileReference" in text:
            print(f"skip existing: {path}")
            continue

        group_id = active_group if "AgentLensTests" in path else group_hint
        if group_id is None or group_id.endswith("_ACTIVE"):
            group_id = active_group if "AgentLensTests" in path else group_hint

        file_id = stable_id(path, "fileref")
        build_id = stable_id(path, "buildfile")
        file_line = (
            f"\t\t{file_id} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; "
            f"path = {pbx_quote(name)}; sourceTree = \"<group>\"; }};\n"
        )
        build_line = (
            f"\t\t{build_id} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_id} /* {name} */; }};\n"
        )
        text = text.replace("/* End PBXBuildFile section */", build_line + "/* End PBXBuildFile section */", 1)
        text = text.replace("/* End PBXFileReference section */", file_line + "/* End PBXFileReference section */", 1)
        group_ref = f"{file_id} /* {name} */,"
        text = insert_into_group(text, str(group_id), group_ref, name)
        text = insert_into_phase(text, phase_id, build_line.strip(), name)
        changed = True
        print(f"registered {path}")

    if changed:
        PROJ.write_text(text, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
