#!/usr/bin/env python3
"""
Append the macOS Settings/Search Swift sources and the unit test target file
into the OpenBurnBar.xcodeproj/project.pbxproj.

Idempotent: re-runs are no-ops if entries already exist.
"""
from __future__ import annotations

import re
import secrets
import sys
from pathlib import Path

PBXPROJ = Path(__file__).resolve().parents[1] / "OpenBurnBar.xcodeproj/project.pbxproj"

# (relative source path, target=app|tests, parent group hint)
NEW_SOURCES = [
    ("AgentLens/Views/Settings/Search/SettingsItem.swift", "app", "Search"),
    ("AgentLens/Views/Settings/Search/SettingsManifest.swift", "app", "Search"),
    ("AgentLens/Views/Settings/Search/SettingsSearchEngine.swift", "app", "Search"),
    ("AgentLens/Views/Settings/Search/SettingsRouter.swift", "app", "Search"),
    ("AgentLens/Views/Settings/Search/SettingsSearchResultsView.swift", "app", "Search"),
    ("AgentLens/Views/Settings/Search/SettingsAnchorModifiers.swift", "app", "Search"),
    ("AgentLensTests/Active/Settings/SettingsSearchEngineTests.swift", "tests", "Settings"),
    ("AgentLensTests/Active/Settings/SettingsManifestCoverageTests.swift", "tests", "Settings"),
]


def hex24() -> str:
    # Match Xcode's 24-char uppercase hex IDs.
    return secrets.token_hex(12).upper()


def main() -> int:
    text = PBXPROJ.read_text(encoding="utf-8")

    # Identify target build phases.
    # OpenBurnBar app target sources: EF7D3D6CF9326CBCD20C7DF5
    # Look up the tests target sources by scanning for OpenBurnBarTests build configuration.
    app_phase_id = "EF7D3D6CF9326CBCD20C7DF5"

    # Find the OpenBurnBarTests native target and pull its first build phase id.
    tests_match = re.search(
        r"isa = PBXNativeTarget;[^}]*?\"OpenBurnBarTests\"[^}]*?buildPhases = \(\s*([0-9A-F]{24}) /\* Sources \*/",
        text,
        re.DOTALL,
    )
    if not tests_match:
        # Alternate format
        m = re.search(
            r"PBXNativeTarget \"OpenBurnBarTests\"[^}]*?buildPhases = \(\s*([0-9A-F]{24})",
            text,
            re.DOTALL,
        )
        tests_phase_id = m.group(1) if m else None
    else:
        tests_phase_id = tests_match.group(1)

    if tests_phase_id is None:
        # Fall back: look for the line `name = OpenBurnBarTests;` and scan upward for buildPhases.
        m = re.search(r"name = OpenBurnBarTests;", text)
        if m:
            window = text[: m.start()]
            phase_match = re.findall(r"buildPhases = \(\s*([0-9A-F]{24}) /\* Sources \*/", window)
            if phase_match:
                tests_phase_id = phase_match[-1]
    if tests_phase_id is None:
        print("ERROR: could not locate OpenBurnBarTests Sources build phase", file=sys.stderr)
        return 1

    print(f"app sources phase: {app_phase_id}")
    print(f"tests sources phase: {tests_phase_id}")

    # Resolve the Search group inside Settings, the Settings group inside AgentLensTests/Active.
    def find_group(path_marker: str) -> str | None:
        m = re.search(
            r"([0-9A-F]{24}) /\* "
            + re.escape(path_marker)
            + r" \*/ = \{\s*isa = PBXGroup;",
            text,
        )
        return m.group(1) if m else None

    # The Settings group on macOS side uses the same name as iOS — disambiguate by ID.
    settings_macos_group = "0A8EDB295C2AC9A2D59F2DCA"  # AgentLens/Views/Settings

    # Helpers to insert
    new_file_refs: list[str] = []
    new_build_files: list[str] = []
    search_group_children: list[str] = []
    settings_group_added_children: list[str] = []
    tests_settings_group_id: str | None = None
    search_group_id: str | None = None

    # Lookup or assign group IDs.
    # We materialize a single Search group hanging off the macOS Settings group.
    if "/* Search */ = {" in text and "/* SettingsItem.swift */ = {" in text:
        # already wired
        print("Already integrated, nothing to do.")
        return 0

    search_group_id = hex24()
    tests_settings_group_id = hex24()

    # Build per-file entries.
    settings_search_children_ids: list[str] = []
    tests_settings_children_ids: list[str] = []

    for rel_path, target, group_hint in NEW_SOURCES:
        file_ref_id = hex24()
        build_file_id = hex24()
        filename = Path(rel_path).name
        new_file_refs.append(
            f"\t\t{file_ref_id} /* {filename} */ = "
            f"{{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {filename}; sourceTree = \"<group>\"; }};\n"
        )
        new_build_files.append(
            f"\t\t{build_file_id} /* {filename} in Sources */ = "
            f"{{isa = PBXBuildFile; fileRef = {file_ref_id} /* {filename} */; }};\n"
        )

        if target == "app":
            settings_search_children_ids.append((file_ref_id, filename))
        else:
            tests_settings_children_ids.append((file_ref_id, filename))

        # Insert build entry into the right sources phase
        marker = f"\t\t\t{build_file_id} /* {filename} in Sources */,\n"
        anchor = (
            f"{app_phase_id} /* Sources */ = {{"
            if target == "app"
            else f"{tests_phase_id} /* Sources */ = {{"
        )
        text = text.replace(
            anchor,
            anchor + marker,
            1,
        )

    # Build PBXFileReference inserts.
    fileref_section_marker = "/* End PBXFileReference section */"
    text = text.replace(
        fileref_section_marker,
        "".join(new_file_refs) + fileref_section_marker,
    )

    # Build PBXBuildFile inserts.
    buildfile_section_marker = "/* End PBXBuildFile section */"
    text = text.replace(
        buildfile_section_marker,
        "".join(new_build_files) + buildfile_section_marker,
    )

    # Add the new Search group inside the macOS Settings group.
    search_group_children_str = "\n".join(
        f"\t\t\t\t{rid} /* {fname} */," for rid, fname in settings_search_children_ids
    )
    search_group_block = (
        f"\t\t{search_group_id} /* Search */ = {{\n"
        f"\t\t\tisa = PBXGroup;\n"
        f"\t\t\tchildren = (\n{search_group_children_str}\n\t\t\t);\n"
        f"\t\t\tpath = Search;\n"
        f"\t\t\tsourceTree = \"<group>\";\n"
        f"\t\t}};\n"
    )

    # Insert before "/* End PBXGroup section */"
    group_section_marker = "/* End PBXGroup section */"
    text = text.replace(
        group_section_marker,
        search_group_block + group_section_marker,
    )

    # Add the Search group as a child of the macOS Settings group.
    settings_group_open = f"{settings_macos_group} /* Settings */ = {{"
    insertion = f"\t\t\t\t{search_group_id} /* Search */,\n"
    pattern = (
        re.escape(settings_group_open)
        + r"\s*\n\s*isa = PBXGroup;\s*\n\s*children = \(\s*\n"
    )
    text = re.sub(
        pattern,
        lambda m: m.group(0) + insertion,
        text,
        count=1,
    )

    # Tests Settings group inside AgentLensTests/Active
    # Find AgentLensTests/Active group id.
    active_group_match = re.search(
        r"([0-9A-F]{24}) /\* Active \*/ = \{\s*isa = PBXGroup;",
        text,
    )
    if not active_group_match:
        print("ERROR: could not locate AgentLensTests/Active group", file=sys.stderr)
        return 1
    active_group_id = active_group_match.group(1)

    tests_settings_children_str = "\n".join(
        f"\t\t\t\t{rid} /* {fname} */," for rid, fname in tests_settings_children_ids
    )
    tests_settings_group_block = (
        f"\t\t{tests_settings_group_id} /* Settings */ = {{\n"
        f"\t\t\tisa = PBXGroup;\n"
        f"\t\t\tchildren = (\n{tests_settings_children_str}\n\t\t\t);\n"
        f"\t\t\tpath = Settings;\n"
        f"\t\t\tsourceTree = \"<group>\";\n"
        f"\t\t}};\n"
    )
    text = text.replace(
        group_section_marker,
        tests_settings_group_block + group_section_marker,
    )

    # Hook the tests Settings group into Active.
    active_open = f"{active_group_id} /* Active */ = {{"
    insertion = f"\t\t\t\t{tests_settings_group_id} /* Settings */,\n"
    pattern = (
        re.escape(active_open)
        + r"\s*\n\s*isa = PBXGroup;\s*\n\s*children = \(\s*\n"
    )
    text = re.sub(
        pattern,
        lambda m: m.group(0) + insertion,
        text,
        count=1,
    )

    PBXPROJ.write_text(text, encoding="utf-8")
    print("Updated", PBXPROJ)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
