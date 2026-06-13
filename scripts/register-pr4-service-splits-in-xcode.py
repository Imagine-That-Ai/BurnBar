#!/usr/bin/env python3
"""Register PR4 service split files in OpenBurnBar.xcodeproj (idempotent)."""

from __future__ import annotations

import hashlib
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
PROJ = REPO / "OpenBurnBar.xcodeproj/project.pbxproj"
MAC_SOURCES_PHASE = "EF7D3D6CF9326CBCD20C7DF5"

ADD_PATHS = [
    "AgentLens/Services/ProjectionPipeline/ProjectionPipelineService.swift",
    "AgentLens/Services/ProjectionPipeline/ProjectionPipelineService+Jobs.swift",
    "AgentLens/Services/ProjectionPipeline/ProjectionPipelineService+Projection.swift",
    "AgentLens/Services/ProjectionPipeline/ProjectionPipelineService+Health.swift",
    "AgentLens/Services/Search/SearchService.swift",
    "AgentLens/Services/Search/SearchService+Factory.swift",
    "AgentLens/Services/Search/SearchService+Retrieval.swift",
    "AgentLens/Services/Search/SearchService+Ranking.swift",
    "AgentLens/Services/Search/SearchService+Health.swift",
    "AgentLens/Services/DataStore/ConversationStore+CRUD.swift",
    "AgentLens/Services/DataStore/ConversationStore+CloudSync.swift",
    "AgentLens/Services/DataStore/ConversationStore+Chat.swift",
    "AgentLens/Services/DataStore/ConversationStore+FTS.swift",
    "AgentLens/Services/DataStore/ConversationStore+TranscriptScan.swift",
]

REMOVE_ROOT_PATHS = {
    "AgentLens/Services/ProjectionPipelineService.swift",
    "AgentLens/Services/SearchService.swift",
}


def stable_id(path: str, salt: str) -> str:
    h = hashlib.sha256(f"openburnbar-pr4:{salt}:{path}".encode()).hexdigest().upper()
    return h[:24]


def pbx_quote(value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def remove_root_monolith_refs(contents: str) -> str:
    for path in REMOVE_ROOT_PATHS:
        name = Path(path).name
        # Drop PBXBuildFile + Sources phase entry for root monoliths.
        contents = re.sub(
            rf"\t\t[0-9A-F]{{24}} /\* {re.escape(name)} in Sources \*/ = {{isa = PBXBuildFile; fileRef = [0-9A-F]{{24}} /\* {re.escape(name)} \*/; }};\n",
            "",
            contents,
        )
        contents = re.sub(
            rf"\t\t\t\t[0-9A-F]{{24}} /\* {re.escape(name)} in Sources \*/,\n",
            "",
            contents,
        )
        # Drop file reference if it only pointed at Services root (not subfolder).
        contents = re.sub(
            rf"\t\t[0-9A-F]{{24}} /\* {re.escape(name)} \*/ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {re.escape(name)}; sourceTree = \"<group>\"; }};\n",
            "",
            contents,
        )
        # Remove from Services group children list.
        contents = re.sub(
            rf"\t\t\t\t[0-9A-F]{{24}} /\* {re.escape(name)} \*/,\n",
            "",
            contents,
        )
    return contents


def main() -> int:
    if not PROJ.exists():
        print(f"missing {PROJ}", file=sys.stderr)
        return 2

    contents = PROJ.read_text()
    contents = remove_root_monolith_refs(contents)

    file_ref_lines: list[str] = []
    build_file_lines: list[str] = []
    phase_lines: list[str] = []

    for path in ADD_PATHS:
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
            + re.escape(MAC_SOURCES_PHASE)
            + r"\s*/\*\s*Sources\s*\*/\s*=\s*\{[^}]*?files\s*=\s*\(\n)(.*?)(\n\s*\);)",
            re.DOTALL,
        )
        m = pattern.search(contents)
        if not m:
            raise RuntimeError("mac Sources phase not found")
        head, body, tail = m.group(1), m.group(2), m.group(3)
        contents = contents[: m.start()] + head + body + "\n" + "\n".join(phase_lines) + tail + contents[m.end() :]

    PROJ.write_text(contents)
    print(
        f"PR4 pbxproj: added {len(file_ref_lines)} refs, removed root monolith refs for {len(REMOVE_ROOT_PATHS)} files"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
