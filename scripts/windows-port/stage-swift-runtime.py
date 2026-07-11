#!/usr/bin/env python3
"""Stage a Windows Swift DLL and its non-system dependency closure."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys


DEPENDENCY_LINE = re.compile(r"^\s*([A-Za-z0-9_.+-]+\.dll)\s*$", re.IGNORECASE)
SYSTEM_LIBRARIES = {
    "advapi32.dll",
    "bcrypt.dll",
    "bcryptprimitives.dll",
    "cabinet.dll",
    "combase.dll",
    "crypt32.dll",
    "dbghelp.dll",
    "gdi32.dll",
    "imm32.dll",
    "iphlpapi.dll",
    "kernel32.dll",
    "msvcrt.dll",
    "ntdll.dll",
    "ole32.dll",
    "oleaut32.dll",
    "rpcrt4.dll",
    "secur32.dll",
    "shell32.dll",
    "shlwapi.dll",
    "user32.dll",
    "userenv.dll",
    "version.dll",
    "winhttp.dll",
    "winmm.dll",
    "ws2_32.dll",
}


def parse_dependencies(output: str) -> list[str]:
    names: list[str] = []
    seen: set[str] = set()
    for line in output.splitlines():
        match = DEPENDENCY_LINE.match(line)
        if match is None:
            continue
        name = match.group(1)
        key = name.casefold()
        if key not in seen:
            seen.add(key)
            names.append(name)
    return names


def is_system_library(name: str) -> bool:
    lowered = name.casefold()
    return lowered in SYSTEM_LIBRARIES or lowered.startswith("api-ms-win-") or lowered.startswith("ext-ms-win-")


def find_case_insensitive(name: str, search_paths: list[Path]) -> Path | None:
    key = name.casefold()
    for directory in search_paths:
        if not directory.is_dir():
            continue
        try:
            for candidate in directory.iterdir():
                if candidate.is_file() and candidate.name.casefold() == key:
                    return candidate
        except OSError:
            continue
    return None


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def stage(
    engine: Path,
    destination: Path,
    search_paths: list[Path],
    dumpbin: str,
) -> dict[str, object]:
    if not engine.is_file():
        raise ValueError(f"engine DLL does not exist: {engine}")

    ordered_paths: list[Path] = []
    path_keys: set[str] = set()
    for path in [engine.parent, *search_paths]:
        resolved = path.resolve()
        key = str(resolved).casefold()
        if key not in path_keys:
            path_keys.add(key)
            ordered_paths.append(resolved)

    destination.mkdir(parents=True, exist_ok=True)
    queue = [engine.resolve()]
    queued = {engine.name.casefold()}
    staged: list[Path] = []

    while queue:
        source = queue.pop(0)
        target = destination / source.name
        shutil.copy2(source, target)
        staged.append(target)

        completed = subprocess.run(
            [dumpbin, "/DEPENDENTS", str(source)],
            check=True,
            capture_output=True,
            text=True,
        )
        for dependency in parse_dependencies(completed.stdout):
            key = dependency.casefold()
            if key in queued or is_system_library(dependency):
                continue
            resolved = find_case_insensitive(dependency, ordered_paths)
            if resolved is None:
                raise ValueError(f"could not resolve non-system dependency {dependency} required by {source.name}")
            queued.add(key)
            queue.append(resolved)

    files = [
        {
            "fileName": path.name,
            "sha256": sha256(path),
            "sizeBytes": path.stat().st_size,
        }
        for path in sorted(staged, key=lambda item: item.name.casefold())
    ]
    manifest: dict[str, object] = {
        "schemaVersion": 1,
        "engine": engine.name,
        "files": files,
    }
    (destination / "native-engine-manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return manifest


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--engine", required=True, type=Path)
    parser.add_argument("--destination", required=True, type=Path)
    parser.add_argument("--search-path", action="append", default=[], type=Path)
    parser.add_argument("--dumpbin", default=shutil.which("dumpbin") or "dumpbin")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    environment_paths = [Path(value) for value in os.environ.get("PATH", "").split(os.pathsep) if value]
    try:
        manifest = stage(
            args.engine,
            args.destination,
            [*args.search_path, *environment_paths],
            args.dumpbin,
        )
    except (OSError, subprocess.CalledProcessError, ValueError) as error:
        print(f"stage-swift-runtime: {error}", file=sys.stderr)
        return 1
    print(f"stage-swift-runtime: staged {len(manifest['files'])} DLLs to {args.destination}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
