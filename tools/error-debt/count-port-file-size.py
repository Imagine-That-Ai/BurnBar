#!/usr/bin/env python3
"""Cross-platform port file-size debt counter (Kotlin / Rust / TypeScript).

The Swift file-size ratchet (count-swift-file-size.py) drove the macOS/iOS god
files to zero, but the newer ports had no equivalent — so the Linux Tauri
backend and Android UI already carry hand-written files larger than anything
left in Swift, with nothing stopping further growth (diligence 2026-07-12).
This counter is the port-side analogue: list production Kotlin/Rust/TS files
over a target so a shrink-only CI gate can freeze the current giants and block
new ones. Generated bindings (UniFFI, etc.) are sized by their emitter, not by
hand, and are excluded.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import sys

# (glob-root, extension) pairs. Kept explicit so a stray extension elsewhere in
# the monorepo can't silently widen the gate.
LANGUAGE_ROOTS = (
    ("android", ".kt"),
    ("apps", ".rs"),
    ("crates", ".rs"),
    ("apps", ".ts"),
    ("apps", ".tsx"),
)

EXCLUDED_PATH_SEGMENTS = {
    ".build",
    ".git",
    ".gradle",
    "build",
    "checkouts",
    "dist",
    "node_modules",
    "target",
    # Generated FFI bindings (UniFFI emits into `uniffi/<crate>/…`).
    "uniffi",
}


def _is_excluded(rel: pathlib.Path) -> bool:
    parts = rel.parts
    if any(part in EXCLUDED_PATH_SEGMENTS for part in parts):
        return True
    # Test sources are allowed to be large (fixtures, table-driven cases); the
    # Swift ratchet excludes them too.
    if any(part == "test" or part == "tests" or part.endswith("Tests") for part in parts):
        return True
    name = rel.name
    if ".generated." in name or name.endswith(".g.kt") or name.endswith(".g.ts"):
        return True
    return False


def count_oversized(repo_root: pathlib.Path, target: int) -> dict:
    seen: dict[str, int] = {}
    for root, ext in LANGUAGE_ROOTS:
        base = repo_root / root
        if not base.exists():
            continue
        for path in base.rglob(f"*{ext}"):
            rel = path.relative_to(repo_root)
            if _is_excluded(rel):
                continue
            try:
                with path.open(encoding="utf-8", errors="ignore") as handle:
                    lines = sum(1 for _ in handle)
            except OSError:
                continue
            if lines > target:
                seen[str(rel)] = lines
    files = [{"path": p, "lines": n} for p, n in seen.items()]
    files.sort(key=lambda f: (-f["lines"], f["path"]))
    return {"target": target, "total": len(files), "files": files}


def main() -> int:
    parser = argparse.ArgumentParser(
        description="OpenBurnBar port (Kotlin/Rust/TS) file-size debt counter",
    )
    parser.add_argument("--repo-root", type=pathlib.Path, default=pathlib.Path.cwd())
    parser.add_argument("--target", type=int, default=2000, help="line-count threshold (exclusive)")
    parser.add_argument("--format", choices=("json", "text"), default="json")
    args = parser.parse_args()

    payload = count_oversized(args.repo_root.resolve(), args.target)
    if args.format == "text":
        print(f"port_file_size target={payload['target']} over_target={payload['total']}")
        for f in payload["files"]:
            print(f"  {f['lines']:>6}  {f['path']}")
    else:
        json.dump(payload, sys.stdout, indent=2)
        sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
