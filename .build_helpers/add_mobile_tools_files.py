#!/usr/bin/env python3
"""
Append the iOS mobile tool-catalog Swift sources (and matching test files)
into OpenBurnBar.xcodeproj/project.pbxproj.

Idempotent: re-running is a no-op if the file references already exist.

Modeled on `.build_helpers/add_settings_search_files.py`. Run it from any
directory; paths resolve relative to this script.
"""
from __future__ import annotations

import re
import secrets
import sys
from pathlib import Path

PBXPROJ = Path(__file__).resolve().parents[1] / "OpenBurnBar.xcodeproj/project.pbxproj"

# (relative source path, target = "app" | "tests")
NEW_SOURCES = [
    ("OpenBurnBarMobile/Services/Tools/MobileToolCatalog.swift", "app"),
    ("OpenBurnBarMobile/Services/Tools/BurnBarAtomOpenTool.swift", "app"),
    ("OpenBurnBarMobile/Services/Tools/BurnBarHermesSessionsTool.swift", "app"),
    ("OpenBurnBarMobile/Services/Tools/BurnBarRuntimeStatusTool.swift", "app"),
    ("OpenBurnBarMobileTests/Tools/MobileToolCatalogTests.swift", "tests"),
    ("OpenBurnBarMobileTests/Tools/BurnBarAtomOpenToolTests.swift", "tests"),
    ("OpenBurnBarMobileTests/Tools/HermesServiceToolUseLoopTests.swift", "tests"),
]

# Targets identified from inspection of project.pbxproj — see the OpenBurnBarMobile
# native target's `buildPhases` entry for `Sources`.
APP_SOURCES_PHASE = "989FB439884BAD69F857287F"
TESTS_SOURCES_PHASE = "2D8814837B36BCC7F8EE4D64"


def hex24() -> str:
    """Match Xcode's 24-char uppercase hex IDs."""
    return secrets.token_hex(12).upper()


def main() -> int:
    text = PBXPROJ.read_text(encoding="utf-8")

    # Idempotency check: if any of the new filenames is already wired
    # (PBXFileReference present), assume the whole set is wired and bail.
    sentinel_basenames = [Path(p).name for p, _ in NEW_SOURCES]
    if all(f"/* {name} */ = {{isa = PBXFileReference;" in text for name in sentinel_basenames):
        print("All target files already wired into pbxproj; nothing to do.")
        return 0

    # Generate stable group IDs for the new app + tests directories.
    tools_app_group_id = hex24()
    tools_tests_group_id = hex24()

    app_children: list[tuple[str, str]] = []
    tests_children: list[tuple[str, str]] = []

    new_file_refs: list[str] = []
    new_build_files: list[str] = []

    for rel_path, target in NEW_SOURCES:
        filename = Path(rel_path).name
        if f"/* {filename} */ = {{isa = PBXFileReference;" in text:
            # File already wired — skip duplicate insertion but keep the
            # group children list reflecting reality on disk.
            existing = re.search(
                rf"([0-9A-F]{{24}}) /\* {re.escape(filename)} \*/ = "
                r"\{\s*isa = PBXFileReference;",
                text,
            )
            file_ref_id = existing.group(1) if existing else hex24()
        else:
            file_ref_id = hex24()
            build_file_id = hex24()
            new_file_refs.append(
                f"\t\t{file_ref_id} /* {filename} */ = "
                f"{{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; "
                f"path = {filename}; sourceTree = \"<group>\"; }};\n"
            )
            new_build_files.append(
                f"\t\t{build_file_id} /* {filename} in Sources */ = "
                f"{{isa = PBXBuildFile; fileRef = {file_ref_id} /* {filename} */; }};\n"
            )
            phase_id = (
                APP_SOURCES_PHASE if target == "app" else TESTS_SOURCES_PHASE
            )
            marker = f"\t\t\t\t{build_file_id} /* {filename} in Sources */,\n"
            # Insert into the build phase's `files = (` list, not next to the
            # opening brace of the PBXSourcesBuildPhase dictionary.
            pattern = re.compile(
                re.escape(phase_id)
                + r" /\* Sources \*/ = \{\s*\n"
                + r"(?:\s*[a-zA-Z]+ = [^;]+;\s*\n)*?"
                + r"\s*files = \(\s*\n",
            )
            match = pattern.search(text)
            if not match:
                print(
                    f"ERROR: could not locate Sources phase {phase_id} `files = (` list for {filename}",
                    file=sys.stderr,
                )
                return 1
            insertion_point = match.end()
            text = text[:insertion_point] + marker + text[insertion_point:]

        if target == "app":
            app_children.append((file_ref_id, filename))
        else:
            tests_children.append((file_ref_id, filename))

    # Splice new PBXFileReference + PBXBuildFile entries.
    if new_file_refs:
        text = text.replace(
            "/* End PBXFileReference section */",
            "".join(new_file_refs) + "/* End PBXFileReference section */",
        )
    if new_build_files:
        text = text.replace(
            "/* End PBXBuildFile section */",
            "".join(new_build_files) + "/* End PBXBuildFile section */",
        )

    # Add the Tools group inside OpenBurnBarMobile/Services. We locate the
    # Services group by searching for its `path = Services;` entry — there
    # can be more than one Services group across the project, so we pin it
    # to the OpenBurnBarMobile branch by demanding the surrounding context
    # match a mobile-side file we know lives in that group.
    if "/* Tools */ = {" not in text or tools_app_group_id not in text:
        # Locate the Services group containing PiService.swift (mobile only).
        services_group_match = re.search(
            r"([0-9A-F]{24}) /\* Services \*/ = \{\s*\n\s*isa = PBXGroup;\s*\n"
            r"\s*children = \(\s*\n([^)]*?PiService\.swift[^)]*?)\);",
            text,
        )
        if not services_group_match:
            print("ERROR: could not locate OpenBurnBarMobile/Services group", file=sys.stderr)
            return 1
        services_group_id = services_group_match.group(1)

        children_str = "\n".join(
            f"\t\t\t\t{rid} /* {fname} */," for rid, fname in app_children
        )
        tools_group_block = (
            f"\t\t{tools_app_group_id} /* Tools */ = {{\n"
            f"\t\t\tisa = PBXGroup;\n"
            f"\t\t\tchildren = (\n{children_str}\n\t\t\t);\n"
            f"\t\t\tpath = Tools;\n"
            f"\t\t\tsourceTree = \"<group>\";\n"
            f"\t\t}};\n"
        )
        text = text.replace(
            "/* End PBXGroup section */",
            tools_group_block + "/* End PBXGroup section */",
        )

        # Insert the Tools group as a child of Services.
        services_open = f"{services_group_id} /* Services */ = {{"
        insertion = f"\t\t\t\t{tools_app_group_id} /* Tools */,\n"
        pattern = (
            re.escape(services_open)
            + r"\s*\n\s*isa = PBXGroup;\s*\n\s*children = \(\s*\n"
        )
        text = re.sub(pattern, lambda m: m.group(0) + insertion, text, count=1)

    # Add the Tools group inside OpenBurnBarMobileTests.
    if (
        f"{tools_tests_group_id} /* Tools */"
        not in text
    ):
        tests_group_match = re.search(
            r"([0-9A-F]{24}) /\* OpenBurnBarMobileTests \*/ = \{\s*\n\s*isa = PBXGroup;",
            text,
        )
        if not tests_group_match:
            print(
                "ERROR: could not locate OpenBurnBarMobileTests root group",
                file=sys.stderr,
            )
            return 1
        tests_root_group_id = tests_group_match.group(1)

        children_str = "\n".join(
            f"\t\t\t\t{rid} /* {fname} */," for rid, fname in tests_children
        )
        tools_tests_block = (
            f"\t\t{tools_tests_group_id} /* Tools */ = {{\n"
            f"\t\t\tisa = PBXGroup;\n"
            f"\t\t\tchildren = (\n{children_str}\n\t\t\t);\n"
            f"\t\t\tpath = Tools;\n"
            f"\t\t\tsourceTree = \"<group>\";\n"
            f"\t\t}};\n"
        )
        text = text.replace(
            "/* End PBXGroup section */",
            tools_tests_block + "/* End PBXGroup section */",
        )

        tests_open = f"{tests_root_group_id} /* OpenBurnBarMobileTests */ = {{"
        insertion = f"\t\t\t\t{tools_tests_group_id} /* Tools */,\n"
        pattern = (
            re.escape(tests_open)
            + r"\s*\n\s*isa = PBXGroup;\s*\n\s*children = \(\s*\n"
        )
        text = re.sub(pattern, lambda m: m.group(0) + insertion, text, count=1)

    PBXPROJ.write_text(text, encoding="utf-8")
    print("Updated", PBXPROJ)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
