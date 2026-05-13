#!/usr/bin/env python3
"""
Wire the CLI agent mirror sources + tests into OpenBurnBar.xcodeproj.

Idempotent. Same pattern as `add_mobile_tools_files.py`.
"""
from __future__ import annotations

import re
import secrets
import sys
from pathlib import Path

PBXPROJ = Path(__file__).resolve().parents[1] / "OpenBurnBar.xcodeproj/project.pbxproj"

# (relative source path, target = "macapp" | "mobileapp" | "tests-mobile" | "tests-macapp")
NEW_SOURCES = [
    ("AgentLens/Services/CloudSync/CLIAgentSessionMirror.swift", "macapp"),
    ("OpenBurnBarMobile/Services/CLIAgentChatReader.swift", "mobileapp"),
    ("OpenBurnBarMobile/Views/CLIAgents/CLIAgentConversationListView.swift", "mobileapp"),
    ("OpenBurnBarMobile/Views/CLIAgents/CLIAgentTranscriptView.swift", "mobileapp"),
    ("OpenBurnBarMobileTests/CLIAgents/CLIAgentSessionCodecTests.swift", "tests-mobile"),
    ("OpenBurnBarMobileTests/CLIAgents/CLIAgentChatReaderTests.swift", "tests-mobile"),
    ("AgentLensTests/Active/CLIAgentSessionMirrorTests.swift", "tests-macapp"),
]

# Identified by inspecting project.pbxproj:
#   - OpenBurnBar (macOS app)     -> Sources phase EF7D3D6CF9326CBCD20C7DF5
#   - OpenBurnBarMobile           -> Sources phase 989FB439884BAD69F857287F
#   - OpenBurnBarMobileTests      -> Sources phase 2D8814837B36BCC7F8EE4D64
#   - OpenBurnBarTests (macOS)    -> resolved at runtime by buildPhases lookup
TARGET_PHASES = {
    "macapp": "EF7D3D6CF9326CBCD20C7DF5",
    "mobileapp": "989FB439884BAD69F857287F",
    "tests-mobile": "2D8814837B36BCC7F8EE4D64",
}


def hex24() -> str:
    return secrets.token_hex(12).upper()


def resolve_macos_tests_phase(text: str) -> str | None:
    # Find the OpenBurnBarTests native target and pull its Sources phase id.
    pattern = re.compile(
        r"isa = PBXNativeTarget;[^}]*?name = OpenBurnBarTests;",
        re.DOTALL,
    )
    match = pattern.search(text)
    if not match:
        return None
    window = text[: match.end()]
    phases = re.findall(
        r"buildPhases = \(\s*([0-9A-F]{24}) /\* Sources \*/",
        window,
    )
    return phases[-1] if phases else None


def insert_into_phase(text: str, phase_id: str, marker: str) -> str | None:
    pattern = re.compile(
        re.escape(phase_id)
        + r" /\* Sources \*/ = \{\s*\n"
        + r"(?:\s*[a-zA-Z]+ = [^;]+;\s*\n)*?"
        + r"\s*files = \(\s*\n",
    )
    match = pattern.search(text)
    if not match:
        return None
    insertion_point = match.end()
    return text[:insertion_point] + marker + text[insertion_point:]


def insert_into_group(text: str, group_id: str, child_marker: str) -> str:
    """Add a child entry into the given PBXGroup's children list."""
    pattern = re.compile(
        re.escape(group_id)
        + r" /\* [^*]+ \*/ = \{\s*\n\s*isa = PBXGroup;\s*\n\s*children = \(\s*\n",
    )
    return pattern.sub(lambda m: m.group(0) + child_marker, text, count=1)


def main() -> int:
    text = PBXPROJ.read_text(encoding="utf-8")

    # Idempotency check
    sentinel = "CLIAgentSessionMirror.swift"
    if f"/* {sentinel} */ = {{isa = PBXFileReference;" in text:
        print("CLI mirror files already wired into pbxproj; nothing to do.")
        return 0

    tests_macapp_phase = resolve_macos_tests_phase(text)
    if tests_macapp_phase is None:
        print("ERROR: could not locate OpenBurnBarTests Sources phase", file=sys.stderr)
        return 1
    phases = dict(TARGET_PHASES)
    phases["tests-macapp"] = tests_macapp_phase

    new_file_refs: list[str] = []
    new_build_files: list[str] = []
    mac_files: list[tuple[str, str]] = []           # CLI mirror source on Mac
    mobile_files: list[tuple[str, str]] = []        # iOS reader + views
    mobile_test_files: list[tuple[str, str]] = []   # iOS tests
    mac_test_files: list[tuple[str, str]] = []      # macOS tests

    for rel_path, target in NEW_SOURCES:
        filename = Path(rel_path).name
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
        phase_id = phases[target]
        marker = f"\t\t\t\t{build_file_id} /* {filename} in Sources */,\n"
        next_text = insert_into_phase(text, phase_id, marker)
        if next_text is None:
            print(f"ERROR: could not splice Sources phase {phase_id} for {filename}", file=sys.stderr)
            return 1
        text = next_text

        if target == "macapp":
            mac_files.append((file_ref_id, filename))
        elif target == "mobileapp":
            mobile_files.append((file_ref_id, filename))
        elif target == "tests-mobile":
            mobile_test_files.append((file_ref_id, filename))
        elif target == "tests-macapp":
            mac_test_files.append((file_ref_id, filename))

    text = text.replace(
        "/* End PBXFileReference section */",
        "".join(new_file_refs) + "/* End PBXFileReference section */",
    )
    text = text.replace(
        "/* End PBXBuildFile section */",
        "".join(new_build_files) + "/* End PBXBuildFile section */",
    )

    # Locate the AgentLens/Services/CloudSync group by searching for a known
    # member (CloudSyncService is in the parent Services group; the CloudSync
    # subgroup contains ConversationSyncService).
    cloudsync_match = re.search(
        r"([0-9A-F]{24}) /\* CloudSync \*/ = \{\s*\n\s*isa = PBXGroup;\s*\n"
        r"\s*children = \(\s*\n([^)]*?ConversationSyncService\.swift[^)]*?)\);",
        text,
    )
    if not cloudsync_match:
        print("ERROR: could not locate AgentLens/Services/CloudSync group", file=sys.stderr)
        return 1
    cloudsync_group_id = cloudsync_match.group(1)
    mac_children_str = "\n".join(
        f"\t\t\t\t{rid} /* {fname} */," for rid, fname in mac_files
    )
    text = insert_into_group(text, cloudsync_group_id, mac_children_str + "\n")

    # New iOS Services entry (reader). We hang it next to the existing Tools
    # group, off OpenBurnBarMobile/Services (path = Services on the mobile branch).
    mobile_services_match = re.search(
        r"([0-9A-F]{24}) /\* Services \*/ = \{\s*\n\s*isa = PBXGroup;\s*\n"
        r"\s*children = \(\s*\n([^)]*?PiService\.swift[^)]*?)\);",
        text,
    )
    if not mobile_services_match:
        print("ERROR: could not locate OpenBurnBarMobile/Services group", file=sys.stderr)
        return 1
    mobile_services_group_id = mobile_services_match.group(1)
    reader_files = [f for f in mobile_files if f[1] == "CLIAgentChatReader.swift"]
    view_files = [f for f in mobile_files if f[1] != "CLIAgentChatReader.swift"]
    reader_children_str = "\n".join(
        f"\t\t\t\t{rid} /* {fname} */," for rid, fname in reader_files
    )
    if reader_children_str:
        text = insert_into_group(text, mobile_services_group_id, reader_children_str + "\n")

    # New iOS Views group: OpenBurnBarMobile/Views/CLIAgents.
    cli_views_group_id = hex24()
    view_children_str = "\n".join(
        f"\t\t\t\t{rid} /* {fname} */," for rid, fname in view_files
    )
    cli_views_block = (
        f"\t\t{cli_views_group_id} /* CLIAgents */ = {{\n"
        f"\t\t\tisa = PBXGroup;\n"
        f"\t\t\tchildren = (\n{view_children_str}\n\t\t\t);\n"
        f"\t\t\tpath = CLIAgents;\n"
        f"\t\t\tsourceTree = \"<group>\";\n"
        f"\t\t}};\n"
    )
    text = text.replace(
        "/* End PBXGroup section */",
        cli_views_block + "/* End PBXGroup section */",
    )

    # Add the new CLIAgents group as a child of OpenBurnBarMobile/Views.
    mobile_views_match = re.search(
        r"([0-9A-F]{24}) /\* Views \*/ = \{\s*\n\s*isa = PBXGroup;\s*\n"
        r"\s*children = \(\s*\n([^)]*?Hermes[^)]*?)\);",
        text,
    )
    if not mobile_views_match:
        print("ERROR: could not locate OpenBurnBarMobile/Views group", file=sys.stderr)
        return 1
    mobile_views_group_id = mobile_views_match.group(1)
    text = insert_into_group(
        text,
        mobile_views_group_id,
        f"\t\t\t\t{cli_views_group_id} /* CLIAgents */,\n",
    )

    # New iOS test group: OpenBurnBarMobileTests/CLIAgents.
    cli_tests_group_id = hex24()
    test_children_str = "\n".join(
        f"\t\t\t\t{rid} /* {fname} */," for rid, fname in mobile_test_files
    )
    cli_tests_block = (
        f"\t\t{cli_tests_group_id} /* CLIAgents */ = {{\n"
        f"\t\t\tisa = PBXGroup;\n"
        f"\t\t\tchildren = (\n{test_children_str}\n\t\t\t);\n"
        f"\t\t\tpath = CLIAgents;\n"
        f"\t\t\tsourceTree = \"<group>\";\n"
        f"\t\t}};\n"
    )
    text = text.replace(
        "/* End PBXGroup section */",
        cli_tests_block + "/* End PBXGroup section */",
    )
    mobile_tests_root_match = re.search(
        r"([0-9A-F]{24}) /\* OpenBurnBarMobileTests \*/ = \{\s*\n\s*isa = PBXGroup;",
        text,
    )
    if not mobile_tests_root_match:
        print("ERROR: could not locate OpenBurnBarMobileTests root group", file=sys.stderr)
        return 1
    mobile_tests_root_id = mobile_tests_root_match.group(1)
    text = insert_into_group(
        text,
        mobile_tests_root_id,
        f"\t\t\t\t{cli_tests_group_id} /* CLIAgents */,\n",
    )

    # Mac tests file: drop into the AgentLensTests/Active group. Find it
    # by searching for the existing Active group.
    if mac_test_files:
        active_match = re.search(
            r"([0-9A-F]{24}) /\* Active \*/ = \{\s*\n\s*isa = PBXGroup;",
            text,
        )
        if not active_match:
            print("ERROR: could not locate AgentLensTests/Active group", file=sys.stderr)
            return 1
        active_group_id = active_match.group(1)
        mac_test_children_str = "".join(
            f"\t\t\t\t{rid} /* {fname} */,\n" for rid, fname in mac_test_files
        )
        text = insert_into_group(text, active_group_id, mac_test_children_str)

    PBXPROJ.write_text(text, encoding="utf-8")
    print("Updated", PBXPROJ)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
