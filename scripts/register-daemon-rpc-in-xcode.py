#!/usr/bin/env python3
"""Register OpenBurnBarDaemon RPC extension files in OpenBurnBar.xcodeproj (idempotent)."""

from __future__ import annotations

import hashlib
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
PROJ = REPO / "OpenBurnBar.xcodeproj/project.pbxproj"
DAEMON_SOURCES_PHASE = "137235B3719724E24A2C431E"
DAEMON_SOURCES_GROUP = "5FA17595EB355C9E729FAE16"
RPC_DIR = REPO / "OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/RPC"
EXTRA_DAEMON_SOURCES = [
    "OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/ComputerUse/BurnBarCLIAuditVerify.swift",
]


def stable_id(path: str, salt: str) -> str:
    h = hashlib.sha256(f"openburnbar-daemon-rpc:{salt}:{path}".encode()).hexdigest().upper()
    return h[:24]


def pbx_quote(value: str) -> str:
    if re.match(r"^[A-Za-z0-9_./-]+$", value):
        return value
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def main() -> int:
    if not PROJ.exists():
        print(f"missing {PROJ}", file=sys.stderr)
        return 2

    paths = sorted(
        {f"OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/RPC/{p.name}" for p in RPC_DIR.glob("*.swift")}
        | set(EXTRA_DAEMON_SOURCES)
    )
    if not paths:
        print(f"no RPC sources under {RPC_DIR}", file=sys.stderr)
        return 2

    contents = PROJ.read_text()
    file_ref_lines: list[str] = []
    build_file_lines: list[str] = []
    group_lines: list[str] = []
    phase_lines: list[str] = []

    for path in paths:
        file_name = Path(path).name
        if f"/* {file_name} */ = {{isa = PBXFileReference" in contents:
            print(f"skip existing file ref: {path}")
            continue
        if f"/* {file_name} in Sources */ = {{isa = PBXBuildFile" in contents:
            print(f"skip existing build file: {path}")
            continue

        file_ref_id = stable_id(path, "fileref")
        build_file_id = stable_id(path, "buildfile")
        daemon_prefix = "OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/"
        if not path.startswith(daemon_prefix):
            raise RuntimeError(f"unexpected daemon source path: {path}")
        rel_path = path[len(daemon_prefix) :]
        file_ref_lines.append(
            f"\t\t{file_ref_id} /* {file_name} */ = {{isa = PBXFileReference; "
            f'lastKnownFileType = sourcecode.swift; path = {pbx_quote(rel_path)}; sourceTree = "<group>"; }};'
        )
        build_file_lines.append(
            f"\t\t{build_file_id} /* {file_name} in Sources */ = "
            f"{{isa = PBXBuildFile; fileRef = {file_ref_id} /* {file_name} */; }};"
        )
        if f"/* {file_name} in Sources */," not in contents:
            group_lines.append(f"\t\t\t\t{file_ref_id} /* {file_name} */,")
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

    if group_lines:
        pattern = re.compile(
            r"("
            + re.escape(DAEMON_SOURCES_GROUP)
            + r"\s*/\*\s*OpenBurnBarDaemon\s*\*/\s*=\s*\{[^}]*?children\s*=\s*\(\n)(.*?)(\n\s*\);)",
            re.DOTALL,
        )
        m = pattern.search(contents)
        if not m:
            raise RuntimeError("OpenBurnBarDaemon Sources group not found")
        head, body, tail = m.group(1), m.group(2), m.group(3)
        contents = contents[: m.start()] + head + body + "\n" + "\n".join(group_lines) + tail + contents[m.end() :]

    if phase_lines:
        pattern = re.compile(
            r"("
            + re.escape(DAEMON_SOURCES_PHASE)
            + r"\s*/\*\s*Sources\s*\*/\s*=\s*\{[^}]*?files\s*=\s*\(\n)(.*?)(\n\s*\);)",
            re.DOTALL,
        )
        m = pattern.search(contents)
        if not m:
            raise RuntimeError("OpenBurnBarDaemon Sources phase not found")
        head, body, tail = m.group(1), m.group(2), m.group(3)
        contents = contents[: m.start()] + head + body + "\n" + "\n".join(phase_lines) + tail + contents[m.end() :]

    PROJ.write_text(contents)
    print(f"daemon RPC pbxproj: registered {len(file_ref_lines)} files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
