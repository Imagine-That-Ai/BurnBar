#!/usr/bin/env python3
"""One-shot helper that registers the new Computer Use Swift files in
the OpenBurnBar Xcode project. Mac files go into the OpenBurnBar
target's Sources phase (EF7D3D6CF9326CBCD20C7DF5); iOS files go into
the OpenBurnBarMobile target's Sources phase (989FB439884BAD69F857287F).

Each file becomes:
  * one PBXFileReference (declares the file on disk via SOURCE_ROOT)
  * one PBXBuildFile (links the file ref to a build phase)
  * one entry in the Sources phase's `files = ( ... )` block.

Idempotent: re-runs detect existing entries by path and skip.
"""
from __future__ import annotations
import hashlib
import sys
import re
from pathlib import Path

REPO = Path("/Users/albertonunez/Documents/Windsurf/BurnBar")
PROJ = REPO / "OpenBurnBar.xcodeproj/project.pbxproj"

MAC_SOURCES_PHASE = "EF7D3D6CF9326CBCD20C7DF5"
IOS_SOURCES_PHASE = "989FB439884BAD69F857287F"

MAC_FILES = [
    "AgentLens/Services/ComputerUse/AgentWatchActionPublisher.swift",
    "AgentLens/Services/ComputerUse/AgentWatchHUDSession.swift",
    "AgentLens/Services/ComputerUse/ComputerUseDaemonApprovalPresenter.swift",
    "AgentLens/Services/ComputerUse/ComputerUseRemoteConfigNotifications.swift",
    "AgentLens/Services/ComputerUse/ComputerUseSessionCoordinator.swift",
    "AgentLens/Services/ComputerUse/ComputerUsePanicHaltCoordinator.swift",
    "AgentLens/Services/ComputerUse/MacActionDispatcher.swift",
    "AgentLens/Services/ComputerUse/Mac/MacAccessibilityInspector.swift",
    "AgentLens/Services/ComputerUse/Mac/MacComputerUseDenyRegions.swift",
    "AgentLens/Services/ComputerUse/Mac/MacInputController.swift",
    "AgentLens/Services/ComputerUse/Mac/MacScreenshotService.swift",
    "AgentLens/Services/ComputerUse/PhoneControlAuthorityValidator.swift",
    "AgentLens/Services/ComputerUse/PhoneControlReceiver.swift",
    "AgentLens/Services/OpenBurnBarDaemon/OpenBurnBarDaemonManager+ComputerUse.swift",
    "AgentLens/Views/ComputerUse/ComputerUseApprovalSheet.swift",
    "AgentLens/Views/ComputerUse/ComputerUseSettingsView.swift",
    "AgentLens/Views/ComputerUse/ComputerUseSessionPanel.swift",
    "AgentLens/Views/ComputerUse/ComputerUseScopeRuleEditor.swift",
    "AgentLens/Views/ComputerUse/ComputerUseSetupWizard.swift",
]
IOS_FILES = [
    "OpenBurnBarMobile/Services/ComputerUse/AgentWatchOverlayCoordinator.swift",
    "OpenBurnBarMobile/Services/ComputerUse/AgentWatchReceiver.swift",
    "OpenBurnBarMobile/Services/ComputerUse/AgentWatchState.swift",
    "OpenBurnBarMobile/Services/ComputerUse/ComputerUseSessionState.swift",
    "OpenBurnBarMobile/Services/ComputerUse/PhoneControlAuthorityIssuer.swift",
    "OpenBurnBarMobile/Services/ComputerUse/PhoneControlSender.swift",
    "OpenBurnBarMobile/Views/ComputerUse/AgentActionTimelineSheet.swift",
    "OpenBurnBarMobile/Views/ComputerUse/AgentWatchScreen.swift",
    "OpenBurnBarMobile/Views/ComputerUse/AgentWatchView.swift",
    "OpenBurnBarMobile/Views/ComputerUse/ComputerUseDeviceSheet.swift",
    "OpenBurnBarMobile/Views/ComputerUse/ComputerUseTrustModeBadge.swift",
    "OpenBurnBarMobile/Views/ComputerUse/PhoneControlOptionSheet.swift",
]


def stable_id(path: str, salt: str) -> str:
    """24-char uppercase hex ID derived from path + salt so re-runs
    produce the same IDs."""
    h = hashlib.sha256(f"openburnbar-cu:{salt}:{path}".encode()).hexdigest().upper()
    return h[:24]


def pbx_quote(value: str) -> str:
    """Quote PBX scalar strings when the path contains characters that
    old-style pbxproj syntax does not accept bare, such as `+`."""
    if re.match(r"^[A-Za-z0-9_./-]+$", value):
        return value
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def main() -> int:
    if not PROJ.exists():
        print(f"pbxproj not found at {PROJ}", file=sys.stderr)
        return 2
    contents = PROJ.read_text()

    file_ref_lines: list[str] = []
    build_file_lines: list[str] = []
    mac_phase_lines: list[str] = []
    ios_phase_lines: list[str] = []

    def register(path: str, phase: str):
        nonlocal contents
        file_name = Path(path).name
        quoted_path = pbx_quote(path)
        # Skip if already registered (search for fileRef path).
        if f"path = {path};" in contents or f"path = {quoted_path};" in contents:
            print(f"already registered: {path}")
            return
        if f" /* {file_name} */ = {{isa = PBXFileReference" in contents and \
           (f"path = {path};" in contents or f"path = {quoted_path};" in contents):
            print(f"already registered (name match): {path}")
            return
        file_ref_id = stable_id(path, "fileref")
        build_file_id = stable_id(path, "buildfile")
        file_ref_lines.append(
            f"\t\t{file_ref_id} /* {file_name} */ = {{isa = PBXFileReference; "
            f"lastKnownFileType = sourcecode.swift; name = {pbx_quote(file_name)}; "
            f"path = {pbx_quote(path)}; sourceTree = SOURCE_ROOT; }};"
        )
        build_file_lines.append(
            f"\t\t{build_file_id} /* {file_name} in Sources */ = "
            f"{{isa = PBXBuildFile; fileRef = {file_ref_id} /* {file_name} */; }};"
        )
        line = f"\t\t\t\t{build_file_id} /* {file_name} in Sources */,"
        if phase == "mac":
            mac_phase_lines.append(line)
        else:
            ios_phase_lines.append(line)

    for path in MAC_FILES:
        register(path, "mac")
    for path in IOS_FILES:
        register(path, "ios")

    if not (file_ref_lines or build_file_lines or mac_phase_lines or ios_phase_lines):
        print("nothing to add — all 12 files already registered")
        return 0

    # 1. Append PBXFileReference entries to the PBXFileReference section.
    if file_ref_lines:
        marker = "/* End PBXFileReference section */"
        injection = "\n".join(file_ref_lines) + "\n\t\t" + marker
        contents = contents.replace(marker, injection, 1)

    # 2. Append PBXBuildFile entries to the PBXBuildFile section.
    if build_file_lines:
        marker = "/* End PBXBuildFile section */"
        injection = "\n".join(build_file_lines) + "\n\t\t" + marker
        contents = contents.replace(marker, injection, 1)

    # 3. Insert into each target's Sources files list. We append our
    #    lines just before the closing `);` of the matching phase block.
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
    inject_into_phase(IOS_SOURCES_PHASE, ios_phase_lines)

    PROJ.write_text(contents)
    print(f"registered {len(file_ref_lines)} file refs, "
          f"{len(build_file_lines)} build files, "
          f"{len(mac_phase_lines)} mac-phase entries, "
          f"{len(ios_phase_lines)} ios-phase entries")
    return 0


if __name__ == "__main__":
    sys.exit(main())
