#!/usr/bin/env python3
"""Register WS4 security client files in OpenBurnBar.xcodeproj (idempotent)."""
from __future__ import annotations

import hashlib
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
PROJ = REPO / "OpenBurnBar.xcodeproj/project.pbxproj"

MAC_APP_SOURCES = "EF7D3D6CF9326CBCD20C7DF5"
MOBILE_APP_SOURCES = "989FB439884BAD69F857287F"
MAC_COMPUTER_USE_GROUP = "807EA2A44840AE8817195B5C"
MOBILE_COMPUTER_USE_GROUP = "8606CDB4AC37DF143210CC5B"
MAC_SERVICES_GROUP = "CAE317316D164FEB48D73BB8"
MOBILE_SERVICES_GROUP = "A1F07B613D17D4ACDE2921A3"

ENTRIES: list[tuple[str, str, str | None, str | None]] = [
    ("AgentLens/Services/AppCheckAttestationMonitor.swift", MAC_APP_SOURCES, MAC_SERVICES_GROUP, None),
    (
        "OpenBurnBarMobile/Services/ComputerUse/ComputerUseSecurityCallableClient.swift",
        MOBILE_APP_SOURCES,
        MOBILE_COMPUTER_USE_GROUP,
        "OpenBurnBarMobile/Services/ComputerUse/ComputerUseSecurityCallableClient.swift",
    ),
    (
        "OpenBurnBarMobile/Services/AppCheckAttestationMonitor.swift",
        MOBILE_APP_SOURCES,
        None,
        None,
    ),
]


def stable_id(path: str, salt: str) -> str:
    h = hashlib.sha256(f"openburnbar-ws4:{salt}:{path}".encode()).hexdigest().upper()
    return h[:24]


def pbx_quote(value: str) -> str:
    if re.match(r"^[A-Za-z0-9_./-]+$", value):
        return value
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def entry_exists(text: str, path: str, name: str, source_root_path: str | None) -> bool:
    if source_root_path:
        return (
            f"/* {name} */ = {{isa = PBXFileReference" in text
            and f"path = {pbx_quote(source_root_path)};" in text
            and "sourceTree = SOURCE_ROOT;" in text
        )
    return f"/* {name} */ = {{isa = PBXFileReference" in text and f"path = {pbx_quote(name)};" in text


def insert_into_group(text: str, group_id: str, file_ref_line: str, file_name: str) -> str:
    needle = f"{file_ref_line.split()[0]} /* {file_name} */,"
    if needle in text:
        return text
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
    changed = False

    for path, phase_id, group_hint, source_root_path in ENTRIES:
        name = Path(path).name
        if entry_exists(text, path, name, source_root_path):
            print(f"skip existing: {path}")
            continue

        group_id = MOBILE_SERVICES_GROUP if group_hint is None else group_hint
        file_id = stable_id(path, "fileref")
        build_id = stable_id(path, "buildfile")
        if source_root_path:
            file_line = (
                f"\t\t{file_id} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; "
                f'name = {name}; path = {pbx_quote(source_root_path)}; sourceTree = SOURCE_ROOT; }};\n'
            )
        else:
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
