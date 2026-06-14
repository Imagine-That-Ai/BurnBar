#!/usr/bin/env python3
"""Count executable Swift `Task.detached` debt.

The debt dashboard cares about real unstructured tasks, not prose that mentions
the API while explaining a migration. This scanner strips Swift comments and
string literals before counting so warning comments do not keep retired debt
alive in TECH_DEBT_METRICS.md.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys


EXCLUDED_PATH_SEGMENTS = {
    ".build",
    ".build-codex",
    ".derived-data",
    ".git",
    ".swiftpm",
    "Carthage",
    "DerivedData",
    "Pods",
    "build",
    "checkouts",
}

TASK_DETACHED = re.compile(r"\bTask\s*\.\s*detached\b")


def is_excluded_path(path: pathlib.Path) -> bool:
    return any(part in EXCLUDED_PATH_SEGMENTS for part in path.parts)


def swift_files(path: pathlib.Path) -> list[pathlib.Path]:
    if path.is_file():
        return [path] if path.suffix == ".swift" else []
    if not path.is_dir():
        return []
    return sorted(candidate for candidate in path.rglob("*.swift") if not is_excluded_path(candidate))


def _raw_string_hash_count(text: str, index: int) -> int | None:
    """Return raw-string hash count when `index` starts a Swift string delimiter."""
    cursor = index
    while cursor < len(text) and text[cursor] == "#":
        cursor += 1
    if cursor < len(text) and text[cursor] == '"':
        return cursor - index
    if index < len(text) and text[index] == '"':
        return 0
    return None


def strip_swift_comments_and_strings(text: str) -> str:
    """Replace comments and string literals with spaces while preserving newlines.

    This is intentionally a lexical scanner, not a Swift parser. It handles the
    comment/string forms that affect false-positive debt counts: line comments,
    nested block comments, normal strings, raw strings, multiline strings, and
    raw multiline strings.
    """
    out: list[str] = []
    i = 0
    n = len(text)

    while i < n:
        char = text[i]
        nxt = text[i + 1] if i + 1 < n else ""

        if char == "/" and nxt == "/":
            i += 2
            while i < n and text[i] != "\n":
                i += 1
            continue

        if char == "/" and nxt == "*":
            i += 2
            depth = 1
            while i < n and depth > 0:
                if text[i] == "\n":
                    out.append("\n")
                    i += 1
                elif i + 1 < n and text[i] == "/" and text[i + 1] == "*":
                    depth += 1
                    i += 2
                elif i + 1 < n and text[i] == "*" and text[i + 1] == "/":
                    depth -= 1
                    i += 2
                else:
                    i += 1
            continue

        hash_count = _raw_string_hash_count(text, i)
        if hash_count is not None:
            quote_index = i + hash_count
            multiline = text.startswith('"""', quote_index)
            delimiter = ('"""' if multiline else '"') + ("#" * hash_count)
            i = quote_index + (3 if multiline else 1)

            while i < n:
                if text[i] == "\n":
                    out.append("\n")
                    i += 1
                    continue
                if text.startswith(delimiter, i):
                    i += len(delimiter)
                    break
                if not multiline and hash_count == 0 and text[i] == "\\":
                    i += 2
                else:
                    i += 1
            continue

        out.append(char)
        i += 1

    return "".join(out)


def count_task_detached_in_text(text: str) -> int:
    return len(TASK_DETACHED.findall(strip_swift_comments_and_strings(text)))


def count_task_detached(repo_root: pathlib.Path, paths: list[pathlib.Path]) -> dict[str, object]:
    total = 0
    files: list[dict[str, object]] = []

    for raw in paths:
        path = raw if raw.is_absolute() else repo_root / raw
        for source in swift_files(path):
            try:
                text = source.read_text(encoding="utf-8")
            except OSError:
                continue
            count = count_task_detached_in_text(text)
            if count:
                total += count
                try:
                    rel = source.relative_to(repo_root)
                except ValueError:
                    rel = source
                files.append({"path": str(rel), "count": count})

    return {"total": total, "files": files}


def main() -> int:
    parser = argparse.ArgumentParser(description="Count executable Swift Task.detached debt.")
    parser.add_argument("--repo-root", type=pathlib.Path, default=pathlib.Path.cwd())
    parser.add_argument(
        "--path",
        action="append",
        type=pathlib.Path,
        default=None,
        help="Swift file or directory to scan. Defaults to AgentLens/Services.",
    )
    parser.add_argument("--format", choices=("json", "text"), default="json")
    args = parser.parse_args()

    repo_root = args.repo_root.resolve()
    paths = args.path or [pathlib.Path("AgentLens/Services")]
    payload = {"taskDetached": count_task_detached(repo_root, paths)}

    if args.format == "text":
        result = payload["taskDetached"]
        assert isinstance(result, dict)
        print(f"task_detached total={result['total']}")
        for item in result["files"]:
            print(f"{item['path']}: {item['count']}")
    else:
        json.dump(payload, sys.stdout, indent=2)
        sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
