#!/usr/bin/env python3
"""Register new test files in OpenBurnBarTests target.

Same pattern as `register-quota-tab-in-xcode.py` but targets the test
sources phase (E35F1758B10CAD71B485DA35).
"""
from __future__ import annotations
import hashlib
import sys
import re
from pathlib import Path

REPO = Path("/Users/albertonunez/Documents/Windsurf/BurnBar")
PROJ = REPO / "OpenBurnBar.xcodeproj/project.pbxproj"

TESTS_SOURCES_PHASE = "E35F1758B10CAD71B485DA35"

TEST_FILES = [
    "AgentLensTests/Active/UI/QuotaWorkspaceViewModelTests.swift",
]


def stable_id(path: str, salt: str) -> str:
    h = hashlib.sha256(f"openburnbar-quota-tests:{salt}:{path}".encode()).hexdigest().upper()
    return h[:24]


def main() -> int:
    if not PROJ.exists():
        print(f"pbxproj not found at {PROJ}", file=sys.stderr)
        return 2
    contents = PROJ.read_text()

    file_ref_lines: list[str] = []
    build_file_lines: list[str] = []
    phase_lines: list[str] = []

    for path in TEST_FILES:
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
        phase_lines.append(
            f"\t\t\t\t{build_file_id} /* {file_name} in Sources */,"
        )

    if not (file_ref_lines or build_file_lines or phase_lines):
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

    inject_into_phase(TESTS_SOURCES_PHASE, phase_lines)

    PROJ.write_text(contents)
    print(f"registered {len(file_ref_lines)} file refs, "
          f"{len(build_file_lines)} build files, "
          f"{len(phase_lines)} phase entries")
    return 0


if __name__ == "__main__":
    sys.exit(main())
