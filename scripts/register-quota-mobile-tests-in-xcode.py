#!/usr/bin/env python3
"""Register QuotaStoreOrderTests.swift in the OpenBurnBarMobileTests target and group.
"""
from __future__ import annotations
import hashlib
import sys
import re
from pathlib import Path

REPO = Path("/Users/albertonunez/Documents/Windsurf/BurnBar")
PROJ = REPO / "OpenBurnBar.xcodeproj/project.pbxproj"

MOBILE_TESTS_SOURCES_PHASE = "2D8814837B36BCC7F8EE4D64"
MOBILE_TESTS_GROUP_ID = "ADEFB03BCBA21A308A3E93DE"
PATH_IN_PROJ = "QuotaStoreOrderTests.swift" # inside the OpenBurnBarMobileTests group (which has path = OpenBurnBarMobileTests)

def stable_id(path: str, salt: str) -> str:
    h = hashlib.sha256(f"openburnbar-quota-mobile-tests:{salt}:{path}".encode()).hexdigest().upper()
    return h[:24]

def main() -> int:
    if not PROJ.exists():
        print(f"pbxproj not found at {PROJ}", file=sys.stderr)
        return 2
    contents = PROJ.read_text()

    if f"path = {PATH_IN_PROJ};" in contents:
        print(f"already registered: {PATH_IN_PROJ}")
        return 0

    file_ref_id = stable_id(PATH_IN_PROJ, "fileref")
    build_file_id = stable_id(PATH_IN_PROJ, "buildfile")

    file_ref_line = (
        f"\t\t{file_ref_id} /* {PATH_IN_PROJ} */ = {{isa = PBXFileReference; "
        f"lastKnownFileType = sourcecode.swift; path = {PATH_IN_PROJ}; sourceTree = \"<group>\"; }};"
    )
    build_file_line = (
        f"\t\t{build_file_id} /* {PATH_IN_PROJ} in Sources */ = "
        f"{{isa = PBXBuildFile; fileRef = {file_ref_id} /* {PATH_IN_PROJ} */; }};"
    )
    phase_line = (
        f"\t\t\t\t{build_file_id} /* {PATH_IN_PROJ} in Sources */,"
    )
    group_child_line = (
        f"\t\t\t\t{file_ref_id} /* {PATH_IN_PROJ} */,"
    )

    # 1. Inject into PBXFileReference section
    marker = "/* End PBXFileReference section */"
    contents = contents.replace(marker, file_ref_line + "\n\t\t" + marker, 1)

    # 2. Inject into PBXBuildFile section
    marker = "/* End PBXBuildFile section */"
    contents = contents.replace(marker, build_file_line + "\n\t\t" + marker, 1)

    # 3. Inject into the mobile test sources build phase (2D8814837B36BCC7F8EE4D64)
    pattern = re.compile(
        r"(" + re.escape(MOBILE_TESTS_SOURCES_PHASE) + r"\s*/\*\s*Sources\s*\*/\s*=\s*\{[^}]*?files\s*=\s*\(\n)(.*?)(\n\s*\);)",
        re.DOTALL,
    )
    m = pattern.search(contents)
    if not m:
        print("could not find Sources phase 2D8814837B36BCC7F8EE4D64", file=sys.stderr)
        return 1
    head, body, tail = m.group(1), m.group(2), m.group(3)
    new_body = body + "\n" + phase_line
    contents = contents[: m.start()] + head + new_body + tail + contents[m.end():]

    # 4. Inject into the group ADEFB03BCBA21A308A3E93DE children
    pattern_group = re.compile(
        r"(" + re.escape(MOBILE_TESTS_GROUP_ID) + r"\s*/\*\s*OpenBurnBarMobileTests\s*\*/\s*=\s*\{[^}]*?children\s*=\s*\(\n)(.*?)(\n\s*\);)",
        re.DOTALL,
    )
    m_group = pattern_group.search(contents)
    if not m_group:
        print("could not find Group ADEFB03BCBA21A308A3E93DE", file=sys.stderr)
        return 1
    g_head, g_body, g_tail = m_group.group(1), m_group.group(2), m_group.group(3)
    new_g_body = g_body + "\n" + group_child_line
    contents = contents[: m_group.start()] + g_head + new_g_body + g_tail + contents[m_group.end():]

    PROJ.write_text(contents)
    print("successfully registered QuotaStoreOrderTests.swift in OpenBurnBarMobileTests target!")
    return 0

if __name__ == "__main__":
    sys.exit(main())
