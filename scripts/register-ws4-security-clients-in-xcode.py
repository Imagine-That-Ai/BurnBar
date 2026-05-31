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
MOBILE_SERVICES_GROUP = "C72135BF239EDFD1288EDB35"  # placeholder, discovered below

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
        "OpenBurnBarMobile/Services/AppCheckAttestationMonitor.swift",
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


def find_mobile_services_group(text: str) -> str:
    child_marker = f"{MOBILE_COMPUTER_USE_GROUP} /* ComputerUse */"
    lines = text.splitlines()
    child_line = next(
        (index for index, line in enumerate(lines) if child_marker in line and " = {" not in line),
        None,
    )
    if child_line is None:
        raise RuntimeError("OpenBurnBarMobile Services/ComputerUse child not found")

    group_start = None
    for index in range(child_line, -1, -1):
        if "/* Services */ = {" in lines[index]:
            group_start = index
            break
    if group_start is None:
        raise RuntimeError("OpenBurnBarMobile/Services group start not found")

    group_end = None
    for index in range(child_line, len(lines)):
        if lines[index].strip() == "};":
            group_end = index
            break
    if group_end is None:
        raise RuntimeError("OpenBurnBarMobile/Services group end not found")

    group_lines = lines[group_start : group_end + 1]
    if not any("path = Services;" in line for line in group_lines):
        raise RuntimeError("OpenBurnBarMobile/Services group path not found")

    header = group_lines[0].split(" = {", 1)[0]
    m = re.search(r"([0-9A-F]{24}) /\* Services \*/$", header)
    if not m:
        raise RuntimeError("OpenBurnBarMobile/Services group id not found")
    return m.group(1)


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


def find_existing_file_id(text: str, name: str, source_root_path: str | None) -> str | None:
    for line in text.splitlines():
        if f"/* {name} */ = {{isa = PBXFileReference;" not in line:
            continue
        if source_root_path and f"path = {pbx_quote(source_root_path)};" not in line:
            continue
        if source_root_path is None and f"path = {pbx_quote(name)};" not in line:
            continue
        return line.strip().split(" ", 1)[0]
    return None


def main() -> int:
    text = PROJ.read_text(encoding="utf-8")
    mobile_services = find_mobile_services_group(text)
    changed = False

    for path, phase_id, group_hint, source_root_path in ENTRIES:
        name = Path(path).name
        group_id = mobile_services if group_hint is None else group_hint
        file_id = find_existing_file_id(text, name, source_root_path) or stable_id(path, "fileref")
        build_id = stable_id(path, "buildfile")
        if file_id == stable_id(path, "fileref"):
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
            text = text.replace("/* End PBXFileReference section */", file_line + "/* End PBXFileReference section */", 1)
        build_line = (
            f"\t\t{build_id} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_id} /* {name} */; }};\n"
        )
        if build_id not in text:
            text = text.replace("/* End PBXBuildFile section */", build_line + "/* End PBXBuildFile section */", 1)
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
