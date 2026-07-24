#!/usr/bin/env python3
"""Register the Charts gallery overhaul files in the Xcode project.

Mirrors the group-based registration of neighboring files: each new file
joins the same PBXGroup as a named sibling (path = filename, sourceTree =
"<group>") and is appended to the target's Sources build phase.

Idempotent — already-registered files are skipped.
"""

from __future__ import annotations
import hashlib
import re
import sys
from pathlib import Path

REPO = Path("/Users/albertonunez/Documents/Developer/BurnBar")
PROJ = REPO / "OpenBurnBar.xcodeproj/project.pbxproj"

APP_SOURCES_PHASE = "EF7D3D6CF9326CBCD20C7DF5"      # OpenBurnBar
TEST_SOURCES_PHASE = "E35F1758B10CAD71B485DA35"     # OpenBurnBarTests

# (new file basename, sibling already in the right group, sources phase)
ENTRIES = [
    ("ChartsAppearance.swift", "ChartKind.swift", APP_SOURCES_PHASE),
    ("ChartsHeroView.swift", "ChartsPageView.swift", APP_SOURCES_PHASE),
    ("ChartsCustomizeSheet.swift", "ChartsPageView.swift", APP_SOURCES_PHASE),
    ("ChartKitInteraction.swift", "ChartKitLine.swift", APP_SOURCES_PHASE),
    ("ChartsAppearanceTests.swift", "ChartsPageLayoutTests.swift", TEST_SOURCES_PHASE),
]


def stable_id(name: str, salt: str) -> str:
    h = hashlib.sha256(f"openburnbar-charts-gallery:{salt}:{name}".encode()).hexdigest().upper()
    return h[:24]


def main() -> int:
    if not PROJ.exists():
        print(f"pbxproj not found at {PROJ}", file=sys.stderr)
        return 2
    contents = PROJ.read_text()

    file_ref_lines: list[str] = []
    build_file_lines: list[str] = []
    # phase_id -> [build file lines]
    phase_lines: dict[str, list[str]] = {}
    # group_id -> [file ref lines]
    group_lines: dict[str, list[str]] = {}

    for file_name, sibling, phase_id in ENTRIES:
        if f"/* {file_name} */ = {{isa = PBXFileReference;" in contents:
            print(f"already registered: {file_name}")
            continue

        # Locate the sibling's fileRef id.
        sibling_refs = re.findall(
            r"([0-9A-F]{24}) /\* " + re.escape(sibling) + r" \*/ = \{isa = PBXFileReference;",
            contents,
        )
        if not sibling_refs:
            print(f"sibling not found: {sibling}", file=sys.stderr)
            return 3
        sibling_ref = sibling_refs[0]

        # Locate the group whose children contain the sibling fileRef.
        group_match = re.search(
            r"([0-9A-F]{24}) /\* [^*]+ \*/ = \{\s*isa = PBXGroup;[^}]*?children = \([^}]*?"
            + re.escape(sibling_ref),
            contents,
            re.DOTALL,
        )
        if not group_match:
            print(f"group containing {sibling} not found", file=sys.stderr)
            return 4
        group_id = group_match.group(1)

        file_ref_id = stable_id(file_name, "fileref")
        build_file_id = stable_id(file_name, "buildfile")

        file_ref_lines.append(
            f"\t\t{file_ref_id} /* {file_name} */ = {{isa = PBXFileReference; "
            f"lastKnownFileType = sourcecode.swift; path = {file_name}; sourceTree = \"<group>\"; }};"
        )
        build_file_lines.append(
            f"\t\t{build_file_id} /* {file_name} in Sources */ = "
            f"{{isa = PBXBuildFile; fileRef = {file_ref_id} /* {file_name} */; }};"
        )
        phase_lines.setdefault(phase_id, []).append(
            f"\t\t\t\t{build_file_id} /* {file_name} in Sources */,"
        )
        group_lines.setdefault(group_id, []).append(
            f"\t\t\t\t{file_ref_id} /* {file_name} */,"
        )
        print(f"registering: {file_name} (group of {sibling}, phase {phase_id})")

    if not file_ref_lines:
        print("nothing to add — all files already registered")
        return 0

    marker = "/* End PBXFileReference section */"
    contents = contents.replace(marker, "\n".join(file_ref_lines) + "\n\t\t" + marker, 1)

    marker = "/* End PBXBuildFile section */"
    contents = contents.replace(marker, "\n".join(build_file_lines) + "\n\t\t" + marker, 1)

    for group_id, lines in group_lines.items():
        # Insert right after the group's `children = (` opening line.
        pattern = re.compile(
            r"(" + re.escape(group_id) + r" /\* [^*]+ \*/ = \{\s*isa = PBXGroup;[^}]*?children = \(\n)",
            re.DOTALL,
        )
        m = pattern.search(contents)
        if not m:
            print(f"group {group_id} children block not found", file=sys.stderr)
            return 5
        contents = contents[: m.end(1)] + "\n".join(lines) + "\n" + contents[m.end(1):]

    for phase_id, lines in phase_lines.items():
        pattern = re.compile(
            r"(" + re.escape(phase_id) + r"\s*/\*\s*Sources\s*\*/\s*=\s*\{[^}]*?files\s*=\s*\(\n)",
            re.DOTALL,
        )
        m = pattern.search(contents)
        if not m:
            print(f"sources phase {phase_id} not found", file=sys.stderr)
            return 6
        contents = contents[: m.end(1)] + "\n".join(lines) + "\n" + contents[m.end(1):]

    PROJ.write_text(contents)
    print(f"registered {len(file_ref_lines)} files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
