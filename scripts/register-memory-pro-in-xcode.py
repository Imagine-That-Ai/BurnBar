#!/usr/bin/env python3
"""Register the Memory Pro (cloud models) Swift files in OpenBurnBar.xcodeproj (idempotent).

Group and build-phase ids are the ones sibling files already live in; re-running
is a no-op once every file is referenced.
"""

from __future__ import annotations

import hashlib
import re
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
PROJ = REPO / "OpenBurnBar.xcodeproj/project.pbxproj"

MAC_APP_SOURCES = "EF7D3D6CF9326CBCD20C7DF5"
MAC_TESTS_SOURCES = "E35F1758B10CAD71B485DA35"
GROUP_VIEWS_MEMORY = "99A9AF4E6C043A1FC02E49B1"
GROUP_VIEWS_SETTINGS = "0A8EDB295C2AC9A2D59F2DCA"
GROUP_SETTINGS_STORES = "171C53BAD98F012A9FB69F57"
GROUP_DAEMON = "E0616A35AA485D19D7E8D8AF"
GROUP_TESTS_SECURITY = "D08BECD4AFCA8B6F7DC47816"
GROUP_TESTS_ACTIVE = "91C83F5D0742CEBA8BFE87BC"
# The daemon is compiled by an Xcode target with explicit file references (Core is a package).
DAEMON_SOURCES_PHASE = "137235B3719724E24A2C431E"
DAEMON_SOURCES_GROUP = "5FA17595EB355C9E729FAE16"
DAEMON_TESTS_PHASE = "388DE9763AC41E4ABF9DF50F"
DAEMON_TESTS_GROUP = "7CA58C9A163630EAFB9ED74E"
DAEMON_MEMORY_GROUP = "__daemon_memory__"  # resolved at run time: the `Memory` child group of the daemon sources

DAEMON_ENTRIES: list[tuple[str, str, str]] = [
    (
        "OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/Memory/BurnBarMembershipFreshness.swift",
        DAEMON_SOURCES_PHASE,
        DAEMON_MEMORY_GROUP,
    ),
    (
        "OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/Memory/BurnBarGatewayScopedTokenStore.swift",
        DAEMON_SOURCES_PHASE,
        DAEMON_MEMORY_GROUP,
    ),
    (
        "OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/Memory/BurnBarMemoryModelPolicy.swift",
        DAEMON_SOURCES_PHASE,
        DAEMON_MEMORY_GROUP,
    ),
    (
        "OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/Memory/BurnBarMemoryEgressLogStore.swift",
        DAEMON_SOURCES_PHASE,
        DAEMON_MEMORY_GROUP,
    ),
    (
        "OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/Memory/BurnBarMemoryEgressEnforcer.swift",
        DAEMON_SOURCES_PHASE,
        DAEMON_MEMORY_GROUP,
    ),
    (
        "OpenBurnBarDaemon/Tests/OpenBurnBarDaemonTests/BurnBarMembershipFreshnessTests.swift",
        DAEMON_TESTS_PHASE,
        DAEMON_TESTS_GROUP,
    ),
    (
        "OpenBurnBarDaemon/Tests/OpenBurnBarDaemonTests/BurnBarGatewayScopedTokenStoreTests.swift",
        DAEMON_TESTS_PHASE,
        DAEMON_TESTS_GROUP,
    ),
    (
        "OpenBurnBarDaemon/Tests/OpenBurnBarDaemonTests/BurnBarMemoryModelPolicyTests.swift",
        DAEMON_TESTS_PHASE,
        DAEMON_TESTS_GROUP,
    ),
    (
        "OpenBurnBarDaemon/Tests/OpenBurnBarDaemonTests/BurnBarMemoryEgressLogStoreTests.swift",
        DAEMON_TESTS_PHASE,
        DAEMON_TESTS_GROUP,
    ),
    (
        "OpenBurnBarDaemon/Tests/OpenBurnBarDaemonTests/BurnBarMemoryEgressEnforcerTests.swift",
        DAEMON_TESTS_PHASE,
        DAEMON_TESTS_GROUP,
    ),
    (
        "OpenBurnBarDaemon/Tests/OpenBurnBarDaemonTests/OpenBurnBarHTTPGatewayServerMemoryEgressTests.swift",
        DAEMON_TESTS_PHASE,
        DAEMON_TESTS_GROUP,
    ),
]

ENTRIES: list[tuple[str, str, str]] = [
    ("AgentLens/Services/Settings/Stores/MemoryCloudProviderID.swift", MAC_APP_SOURCES, GROUP_SETTINGS_STORES),
    ("AgentLens/Services/OpenBurnBarDaemon/MemoryCloudProviderAvailability.swift", MAC_APP_SOURCES, GROUP_DAEMON),
    ("AgentLens/Services/OpenBurnBarDaemon/OpenBurnBarDaemonManager+MemoryEgress.swift", MAC_APP_SOURCES, GROUP_DAEMON),
    ("AgentLens/Services/OpenBurnBarDaemon/OpenBurnBarDaemonManager+Membership.swift", MAC_APP_SOURCES, GROUP_DAEMON),
    ("AgentLens/Views/Memory/MemoryCloudModelsConsentSheet.swift", MAC_APP_SOURCES, GROUP_VIEWS_MEMORY),
    ("AgentLens/Views/Settings/MemoryCloudModelsSection.swift", MAC_APP_SOURCES, GROUP_VIEWS_SETTINGS),
    ("AgentLensTests/Active/Security/MemoryCloudModelsSettingsTests.swift", MAC_TESTS_SOURCES, GROUP_TESTS_SECURITY),
    ("AgentLensTests/Active/MemoryCloudModelsPolicyHandoffTests.swift", MAC_TESTS_SOURCES, GROUP_TESTS_ACTIVE),
    ("AgentLensTests/Active/MemoryConsentSheetCopyTests.swift", MAC_TESTS_SOURCES, GROUP_TESTS_ACTIVE),
]


def stable_id(path: str, salt: str) -> str:
    digest = hashlib.sha256(f"openburnbar-memory-pro:{salt}:{path}".encode()).hexdigest().upper()
    return digest[:24]


def pbx_quote(value: str) -> str:
    if re.match(r"^[A-Za-z0-9_./-]+$", value):
        return value
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def insert_child(text: str, group_id: str, needle: str) -> str:
    pattern = re.compile(
        rf"({re.escape(group_id)} /\* [^*]* \*/ = \{{\s*isa = PBXGroup;\s*children = \(\n)(.*?)(\n\s*\);)",
        re.DOTALL,
    )
    match = pattern.search(text)
    if not match:
        raise RuntimeError(f"PBXGroup {group_id} not found")
    if needle in match.group(2):
        return text
    return (
        text[: match.start()]
        + match.group(1)
        + match.group(2)
        + f"\n\t\t\t\t{needle}"
        + match.group(3)
        + text[match.end() :]
    )


def insert_build_file(text: str, phase_id: str, needle: str) -> str:
    pattern = re.compile(
        rf"({re.escape(phase_id)} /\* Sources \*/ = \{{\s*isa = PBXSourcesBuildPhase;.*?files = \(\n)(.*?)(\n\s*\);)",
        re.DOTALL,
    )
    match = pattern.search(text)
    if not match:
        raise RuntimeError(f"Sources phase {phase_id} not found")
    if needle in match.group(2):
        return text
    return (
        text[: match.start()]
        + match.group(1)
        + match.group(2)
        + f"\n\t\t\t\t{needle}"
        + match.group(3)
        + text[match.end() :]
    )


def resolve_daemon_memory_group(text: str) -> str | None:
    """The `Memory` PBXGroup that is a child of the daemon sources group."""
    parent = re.search(
        rf"{DAEMON_SOURCES_GROUP} /\* [^*]* \*/ = \{{\s*isa = PBXGroup;\s*children = \((.*?)\);", text, re.DOTALL
    )
    if not parent:
        raise RuntimeError("daemon sources group not found")
    for child_id in re.findall(r"([0-9A-F]{24}) /\* Memory \*/,", parent.group(1)):
        if re.search(rf"{child_id} /\* Memory \*/ = \{{\s*isa = PBXGroup;", text):
            return child_id
    return None  # no `Memory` group yet: register under the daemon sources group with a `Memory/` path


def main() -> int:
    text = PROJ.read_text(encoding="utf-8")
    original = text
    memory_group = resolve_daemon_memory_group(text)
    for path, phase_id, group_id in DAEMON_ENTRIES + ENTRIES:
        relative = Path(path).name
        if group_id == DAEMON_MEMORY_GROUP:
            if memory_group is None:
                group_id = DAEMON_SOURCES_GROUP
                relative = "Memory/" + relative
            else:
                group_id = memory_group
        if not (REPO / path).exists():
            raise SystemExit(f"missing file: {path}")
        name = Path(path).name
        if f"/* {name} */ = {{isa = PBXFileReference" in text:
            print(f"skip existing: {path}")
            continue
        file_id = stable_id(path, "fileref")
        build_id = stable_id(path, "buildfile")
        file_line = (
            f"\t\t{file_id} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; "
            f'path = {pbx_quote(relative)}; sourceTree = "<group>"; }};\n'
        )
        build_line = (
            f"\t\t{build_id} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_id} /* {name} */; }};\n"
        )
        text = text.replace("/* End PBXBuildFile section */", build_line + "/* End PBXBuildFile section */", 1)
        text = text.replace("/* End PBXFileReference section */", file_line + "/* End PBXFileReference section */", 1)
        text = insert_child(text, group_id, f"{file_id} /* {name} */,")
        text = insert_build_file(text, phase_id, f"{build_id} /* {name} in Sources */,")
        print(f"registered {path}")
    if text != original:
        PROJ.write_text(text, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
