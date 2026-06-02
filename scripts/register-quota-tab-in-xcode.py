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
import os
import sys
import re
from pathlib import Path, PurePosixPath

REPO = Path(os.environ.get("OPENBURNBAR_REPO", Path(__file__).resolve().parents[1]))
PROJ = Path(os.environ.get("OPENBURNBAR_XCODEPROJ", REPO / "OpenBurnBar.xcodeproj/project.pbxproj"))

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


def parse_pbx_groups(contents: str) -> tuple[dict[str, str], dict[str, str]]:
    group_paths: dict[str, str] = {}
    parent_by_child: dict[str, str] = {}
    pattern = re.compile(
        r"^\t\t([0-9A-F]{24}) /\* [^*]+ \*/ = \{\n(?P<body>.*?)^\t\t\};",
        re.MULTILINE | re.DOTALL,
    )
    for match in pattern.finditer(contents):
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


def resolved_file_refs_by_path(contents: str) -> dict[str, list[str]]:
    group_paths, parent_by_child = parse_pbx_groups(contents)
    refs: dict[str, list[str]] = {}
    pattern = re.compile(
        r"^\s*([0-9A-F]{24}) /\* ([^*]+) \*/ = \{isa = PBXFileReference; (?P<body>.*?)\};",
        re.MULTILINE,
    )
    for match in pattern.finditer(contents):
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


def build_file_ids_for_file_ref(contents: str, file_ref_id: str) -> list[str]:
    pattern = re.compile(
        rf"^\s*([0-9A-F]{{24}}) /\* .*? in Sources \*/ = "
        rf"\{{isa = PBXBuildFile; fileRef = {re.escape(file_ref_id)} /\* .*? \*/; \}};",
        re.MULTILINE,
    )
    return [match.group(1) for match in pattern.finditer(contents)]


def source_phase_build_ids(contents: str, phase_id: str) -> set[str]:
    pattern = re.compile(
        r"(" + re.escape(phase_id) + r"\s*/\*\s*Sources\s*\*/\s*=\s*\{[^}]*?files\s*=\s*\(\n)(.*?)(\n\s*\);)",
        re.DOTALL,
    )
    match = pattern.search(contents)
    if not match:
        raise RuntimeError(f"could not find Sources phase {phase_id}")
    return set(re.findall(r"^\s*([0-9A-F]{24}) /\* .*? in Sources \*/,", match.group(2), re.MULTILINE))


def find_existing_file_ref_id(contents: str, path: str, phase_id: str) -> str | None:
    candidates = resolved_file_refs_by_path(contents).get(normalize_path(path), [])
    if not candidates:
        return None
    phase_ids = source_phase_build_ids(contents, phase_id)
    for file_ref_id in candidates:
        if any(build_id in phase_ids for build_id in build_file_ids_for_file_ref(contents, file_ref_id)):
            return file_ref_id
    return candidates[0]


def source_phase_build_id_for_file_ref(contents: str, phase_id: str, file_ref_id: str) -> str | None:
    phase_ids = source_phase_build_ids(contents, phase_id)
    return next(
        (build_id for build_id in build_file_ids_for_file_ref(contents, file_ref_id) if build_id in phase_ids),
        None,
    )


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
        existing_file_ref_id = find_existing_file_ref_id(contents, path, MAC_SOURCES_PHASE)
        if existing_file_ref_id and source_phase_build_id_for_file_ref(contents, MAC_SOURCES_PHASE, existing_file_ref_id):
            print(f"already registered: {path}")
            continue
        file_ref_id = existing_file_ref_id or stable_id(path, "fileref")
        build_file_id = stable_id(path, "buildfile")
        if existing_file_ref_id is None:
            file_ref_lines.append(
                f"\t\t{file_ref_id} /* {file_name} */ = {{isa = PBXFileReference; "
                f"lastKnownFileType = sourcecode.swift; name = {file_name}; "
                f"path = {path}; sourceTree = SOURCE_ROOT; }};"
            )
        existing_build_file_ids = build_file_ids_for_file_ref(contents, file_ref_id)
        if existing_build_file_ids:
            build_file_id = existing_build_file_ids[0]
        else:
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
