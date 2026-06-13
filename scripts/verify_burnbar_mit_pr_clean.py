#!/usr/bin/env python3
"""BurnBar MIT PR cleanliness scan — the Nous/Hermes upstream boundary gate.

BurnBar's product tree is AGPL-3.0-only and carries the official Signal
libsignal lane. Contributions we send upstream to MIT projects (hermes-agent)
must stay MIT-clean: no AGPL lane files, no official libsignal npm dependency,
no libsignal/SPQR references, and no marketing overclaims smuggled into the
permissive lane. This scanner proves a PR (or the working tree) is clean.

What it blocks, per file changed against ``--base``:
  * AGPL Signal-lane paths riding along (Vendor/libsignal, libsignal-bridge…)
  * the official libsignal npm dependency (@signalapp/libsignal-client)
  * libsignal / SPQR / SparsePostQuantumRatchet / AGPL references
  * a post-quantum recovery claim, or Signal-grade/-quality/-class/Protocol
    overclaims — the MIT lane gets "MIT-compatible encrypted gateway
    hardening only", never Signal-lane claims

What it allows: plain references to Signal the messenger (an adapter list
naming "Signal" is normal and fine).

Usage:
  python scripts/verify_burnbar_mit_pr_clean.py --base origin/main
  python scripts/verify_burnbar_mit_pr_clean.py --base origin/main --include-working-tree

Exit 0 = clean; exit 1 = violations listed on stderr. CI: the
"Nous/Hermes MIT upstream boundary" job in .github/workflows/license-posture.yml.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

# Paths that may NEVER appear in an MIT upstream PR — the AGPL Signal lane.
BLOCKED_PATH_PREFIXES: tuple[str, ...] = (
    "Vendor/libsignal/",
    "packages/libsignal-bridge/",
    "packages/libsignal-protocol/",
    "third_party/libsignal/",
    "LICENSES/",
)

# The scanner and its tests legitimately contain the banned tokens as pattern
# literals; nothing else is exempt.
SELF_PATHS: tuple[str, ...] = (
    "scripts/verify_burnbar_mit_pr_clean.py",
    "tests/test_burnbar_mit_pr_clean.py",
)


@dataclass(frozen=True)
class Rule:
    name: str
    pattern: re.Pattern[str]


CONTENT_RULES: tuple[Rule, ...] = (
    Rule(
        "official libsignal npm dependency",
        re.compile(r"@signalapp/libsignal-client", re.IGNORECASE),
    ),
    Rule("libsignal reference", re.compile(r"\blibsignal\b", re.IGNORECASE)),
    Rule(
        "Signal post-quantum ratchet reference",
        re.compile(r"\bSPQR\b|SparsePostQuantumRatchet", re.IGNORECASE),
    ),
    Rule("AGPL license reference", re.compile(r"\bAGPL\b", re.IGNORECASE)),
    Rule(
        "post-quantum recovery claim",
        re.compile(r"post[- ]?quantum\s+recovery", re.IGNORECASE),
    ),
    Rule(
        "MIT-lane Signal overclaim",
        re.compile(r"Signal[- ](?:grade|quality|class)\b|Signal\s+Protocol", re.IGNORECASE),
    ),
)


@dataclass(frozen=True)
class Violation:
    path: str
    line: int
    rule: str
    excerpt: str

    def __str__(self) -> str:  # pragma: no cover - formatting only
        return f"{self.path}:{self.line}: {self.rule}: {self.excerpt.strip()[:120]}"


def scan_text(path: str, text: str) -> list[Violation]:
    """Pure content scan for one file. Plain 'Signal' (the messenger) passes."""
    violations: list[Violation] = []
    for lineno, line in enumerate(text.splitlines(), start=1):
        for rule in CONTENT_RULES:
            if rule.pattern.search(line):
                violations.append(Violation(path, lineno, rule.name, line))
    return violations


def scan_path(path: str) -> list[Violation]:
    if any(path.startswith(prefix) for prefix in BLOCKED_PATH_PREFIXES):
        return [Violation(path, 0, "AGPL Signal-lane path in MIT upstream PR", path)]
    return []


def _git(repo: Path, *args: str) -> list[str]:
    out = subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True).stdout
    return [line for line in out.splitlines() if line.strip()]


def collect_changed_files(repo: Path, base: str, include_working_tree: bool) -> list[str]:
    """Files changed vs the merge-base with ``base``; optionally the working tree.

    Working-tree mode adds staged + unstaged changes AND untracked files
    (``git ls-files --others --exclude-standard``) so nothing rides along
    unnoticed before it is even committed.
    """
    files: dict[str, None] = {}
    for path in _git(repo, "diff", "--name-only", "--diff-filter=d", f"{base}...HEAD"):
        files.setdefault(path)
    if include_working_tree:
        for path in _git(repo, "diff", "--name-only", "--diff-filter=d", "HEAD"):
            files.setdefault(path)
        for path in _git(repo, "ls-files", "--others", "--exclude-standard"):
            files.setdefault(path)
    return [path for path in files if path not in SELF_PATHS]


def scan_repo(repo: Path, base: str, include_working_tree: bool) -> list[Violation]:
    violations: list[Violation] = []
    for rel in collect_changed_files(repo, base, include_working_tree):
        violations.extend(scan_path(rel))
        file_path = repo / rel
        if not file_path.is_file():
            continue
        try:
            text = file_path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue  # binary or unreadable — path rules already applied
        violations.extend(scan_text(rel, text))
    return violations


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="BurnBar MIT PR cleanliness scan")
    parser.add_argument("--base", default="origin/main", help="base ref to diff against")
    parser.add_argument(
        "--include-working-tree",
        action="store_true",
        help="also scan staged/unstaged changes and untracked files",
    )
    parser.add_argument("--repo", default=".", help="repository root to scan (default: current directory)")
    args = parser.parse_args(argv)

    violations = scan_repo(Path(args.repo).resolve(), args.base, args.include_working_tree)
    if violations:
        print("FAIL: BurnBar MIT PR cleanliness scan found AGPL/Signal-lane material:", file=sys.stderr)
        for violation in violations:
            print(f"  - {violation}", file=sys.stderr)
        return 1
    print("PASS: BurnBar MIT PR cleanliness scan — the MIT upstream lane is clean.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
