#!/usr/bin/env python3
"""Register WS4 security client files in OpenBurnBar.xcodeproj (idempotent)."""
from __future__ import annotations

import hashlib
import os
import re
import sys
from pathlib import Path, PurePosixPath

REPO = Path(os.environ.get("OPENBURNBAR_REPO", Path(__file__).resolve().parents[1]))
PROJ = Path(os.environ.get("OPENBURNBAR_XCODEPROJ", REPO / "OpenBurnBar.xcodeproj/project.pbxproj"))

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


def normalize_path(path: str) -> str:
    return str(PurePosixPath(path))


def pbx_unquote(value: str) -> str:
    value = value.strip()
    if value.startswith('"') and value.endswith('"'):
        return value[1:-1].replace('\\"', '"').replace("\\\\", "\\")
    return value


def parse_pbx_fields(body: str) -> dict[str, str]:
    return {
        match.group(1): pbx_unquote(match.group(2))
        for match in re.finditer(r'\b([A-Za-z0-9_]+) = ("(?:\\.|[^"])*"|[^;]+);', body)
    }


def parse_pbx_groups(text: str) -> tuple[dict[str, str], dict[str, str]]:
    group_paths: dict[str, str] = {}
    parent_by_child: dict[str, str] = {}
    pattern = re.compile(
        r"^\t\t([0-9A-F]{24}) /\* [^*]+ \*/ = \{\n(?P<body>.*?)^\t\t\};",
        re.MULTILINE | re.DOTALL,
    )
    for match in pattern.finditer(text):
        body = match.group("body")
        if "isa = PBXGroup;" not in body:
            continue
        group_id = match.group(1)
        fields = parse_pbx_fields(body)
        group_paths[group_id] = fields.get("path") or fields.get("name") or ""
        children_match = re.search(r"children = \(\n(?P<children>.*?)\n\s*\);", body, re.DOTALL)
        if not children_match:
            continue
        for child_id in re.findall(r"^\s*([0-9A-F]{24}) /\* .*? \*/,", children_match.group("children"), re.MULTILINE):
            parent_by_child[child_id] = group_id
    return group_paths, parent_by_child


def group_path_parts(group_id: str | None, group_paths: dict[str, str], parent_by_child: dict[str, str]) -> list[str]:
    parts: list[str] = []
    seen: set[str] = set()
    current = group_id
    while current and current not in seen:
        seen.add(current)
        path = group_paths.get(current)
        if path:
            parts.append(path)
        current = parent_by_child.get(current)
    return list(reversed(parts))


def resolved_file_refs_by_path(text: str) -> dict[str, list[str]]:
    group_paths, parent_by_child = parse_pbx_groups(text)
    refs: dict[str, list[str]] = {}
    pattern = re.compile(
        r"^\s*([0-9A-F]{24}) /\* ([^*]+) \*/ = \{isa = PBXFileReference; (?P<body>.*?)\};",
        re.MULTILINE,
    )
    for match in pattern.finditer(text):
        file_ref_id, comment = match.group(1), match.group(2)
        fields = parse_pbx_fields(match.group("body"))
        raw_path = fields.get("path") or fields.get("name") or comment
        source_tree = fields.get("sourceTree", "<group>")
        if source_tree == "SOURCE_ROOT":
            resolved = raw_path
        else:
            parts = group_path_parts(parent_by_child.get(file_ref_id), group_paths, parent_by_child)
            parts.append(raw_path)
            resolved = "/".join(parts)
        refs.setdefault(normalize_path(resolved), []).append(file_ref_id)
    return refs


def build_file_ids_for_file_ref(text: str, file_ref_id: str) -> list[str]:
    pattern = re.compile(
        rf"^\s*([0-9A-F]{{24}}) /\* .*? in Sources \*/ = "
        rf"\{{isa = PBXBuildFile; fileRef = {re.escape(file_ref_id)} /\* .*? \*/; \}};",
        re.MULTILINE,
    )
    return [match.group(1) for match in pattern.finditer(text)]


def source_phase_build_ids(text: str, phase_id: str) -> set[str]:
    pattern = re.compile(
        rf"({re.escape(phase_id)}\s*/\*\s*Sources\s*\*/\s*=\s*\{{[^}}]*?files\s*=\s*\(\n)(.*?)(\n\s*\);)",
        re.DOTALL,
    )
    match = pattern.search(text)
    if not match:
        raise RuntimeError(f"Sources phase {phase_id} not found")
    return set(re.findall(r"^\s*([0-9A-F]{24}) /\* .*? in Sources \*/,", match.group(2), re.MULTILINE))


def source_phase_build_id_for_file_ref(text: str, phase_id: str, file_ref_id: str) -> str | None:
    phase_ids = source_phase_build_ids(text, phase_id)
    return next(
        (build_id for build_id in build_file_ids_for_file_ref(text, file_ref_id) if build_id in phase_ids),
        None,
    )


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


def insert_into_group(text: str, group_id: str, file_ref_id: str, file_name: str) -> str:
    needle = f"{file_ref_id} /* {file_name} */,"
    if needle in text:
        return text
    pattern = re.compile(
        rf"({re.escape(group_id)}[^=]*=\s*\{{[^}}]*?children\s*=\s*\(\n)(.*?)(\n\s*\);)",
        re.DOTALL,
    )
    m = pattern.search(text)
    if not m:
        raise RuntimeError(f"PBXGroup {group_id} not found")
    children = m.group(2)
    separator = "" if children.endswith("\n") else "\n"
    return text[: m.start()] + m.group(1) + children + separator + f"\t\t\t\t{needle}" + m.group(3) + text[m.end() :]


def insert_into_phase(text: str, phase_id: str, build_id: str, file_name: str) -> str:
    needle = f"{build_id} /* {file_name} in Sources */,"
    if needle in text:
        return text
    pattern = re.compile(
        rf"({re.escape(phase_id)}\s*/\*\s*Sources\s*\*/\s*=\s*\{{[^}}]*?files\s*=\s*\(\n)(.*?)(\n\s*\);)",
        re.DOTALL,
    )
    m = pattern.search(text)
    if not m:
        raise RuntimeError(f"Sources phase {phase_id} not found")
    files = m.group(2)
    separator = "" if files.endswith("\n") else "\n"
    return text[: m.start()] + m.group(1) + files + separator + f"\t\t\t\t{needle}" + m.group(3) + text[m.end() :]


def find_existing_file_id(text: str, path: str, phase_id: str) -> str | None:
    candidates = resolved_file_refs_by_path(text).get(normalize_path(path), [])
    if not candidates:
        return None
    phase_ids = source_phase_build_ids(text, phase_id)
    for file_ref_id in candidates:
        if any(build_id in phase_ids for build_id in build_file_ids_for_file_ref(text, file_ref_id)):
            return file_ref_id
    return candidates[0]


def main() -> int:
    text = PROJ.read_text(encoding="utf-8")
    mobile_services = find_mobile_services_group(text)
    changed = False

    for path, phase_id, group_hint, source_root_path in ENTRIES:
        name = Path(path).name
        group_id = mobile_services if group_hint is None else group_hint
        existing_file_id = find_existing_file_id(text, path, phase_id)
        before_entry = text
        file_id = existing_file_id or stable_id(path, "fileref")
        build_id = stable_id(path, "buildfile")
        if existing_file_id is None:
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
            changed = True
        existing_build_ids = build_file_ids_for_file_ref(text, file_id)
        if existing_build_ids:
            build_id = existing_build_ids[0]
        build_line = (
            f"\t\t{build_id} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_id} /* {name} */; }};\n"
        )
        if not existing_build_ids:
            text = text.replace("/* End PBXBuildFile section */", build_line + "/* End PBXBuildFile section */", 1)
            changed = True
        updated = insert_into_group(text, str(group_id), file_id, name)
        changed = changed or updated != text
        text = updated
        if source_phase_build_id_for_file_ref(text, phase_id, file_id) is None:
            updated = insert_into_phase(text, phase_id, build_id, name)
            changed = changed or updated != text
            text = updated
        if text == before_entry:
            print(f"already registered: {path}")
        else:
            print(f"registered {path}")

    if changed:
        PROJ.write_text(text, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
