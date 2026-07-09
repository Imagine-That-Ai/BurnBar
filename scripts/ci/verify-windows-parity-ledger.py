#!/usr/bin/env python3
"""Windows parity ledger honesty gate (Phase 0 / Wave 1).

Fails closed when:
  * the ledger is missing / unparseable
  * any row uses a forbidden status (including legacy ``Authored``)
  * any macOS primary / required route lacks a mapping row
  * any Real row lacks ≥1 existing test path and ≥1 existing evidence file
  * any Real row's evidence or certification references still say PLACEHOLDER
  * any Real row's blocking_paths contain anti-false-green tokens

Usage:
  python3 scripts/ci/verify-windows-parity-ledger.py
  python3 scripts/ci/verify-windows-parity-ledger.py --ledger PATH --repo-root PATH
  python3 scripts/ci/verify-windows-parity-ledger.py --production

Environment overrides (for self-tests):
  WINDOWS_PARITY_LEDGER   path to ledger YAML
  WINDOWS_PARITY_REPO     repo root
  WINDOWS_PARITY_BUNDLE   certification bundle path (optional override)
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from collections import Counter
from pathlib import Path
from typing import Any

try:
    import yaml
except ImportError:  # pragma: no cover — PyYAML is in repo CI images; fail clearly if missing
    print("FATAL: PyYAML is required (pip install pyyaml)", file=sys.stderr)
    sys.exit(2)

VALID_STATUSES = frozenset({"Real", "Substituted", "DeferredApproved", "Blocked"})
FORBIDDEN_STATUSES = frozenset(
    {
        "Authored",
        "authored",
        "AUTHORIED",
        "InFlight",
        "in flight",
        "Partial",
        "TODO",
        "Planned",
        "Skeleton",
        "Stub",
        "Demo",
        "Sample",
    }
)

# Precision-matched anti-false-green patterns for Real-row production paths.
# Bare domain words (e.g. enum case Unavailable) are intentionally excluded.
FORBIDDEN_TOKEN_PATTERNS: list[tuple[re.Pattern[str], str]] = [
    (re.compile(r"\bSampleModeEnabled\b"), "SampleModeEnabled"),
    (re.compile(r"\b\w*SampleData\w*\b"), "SampleData"),
    (re.compile(r"\b\w*DemoHost\w*\b"), "DemoHost"),
    (re.compile(r"\bMockAttestationProducer\b"), "MockAttestationProducer"),
    (re.compile(r"\bdev-host\b", re.IGNORECASE), "dev-host"),
    (
        re.compile(
            r"\bStub(?:CliStream|Page|Host|Stream|Factory|Driver)?\b|SurfaceStub(?:Page)?"
        ),
        "Stub",
    ),
    (
        re.compile(r"\bSettingsPlaceholderPage\b|\bPlaceholderCard\b|\bPLACEHOLDER\b"),
        "Placeholder",
    ),
    (
        re.compile(
            r"(?:dev-host|CI|Windows-runner|WS-D|adapter|host|XamlCompiler)-deferred"
            r"|\bdev-host/CI-deferred\b",
            re.IGNORECASE,
        ),
        "deferred",
    ),
    (re.compile(r"\bUnavailableChatStreamDriver\b"), "Unavailable"),
]

PLACEHOLDER_SCREENSHOT = re.compile(
    r"PLACEHOLDER\s+`?screenshots/|PLACEHOLDER\s+`screenshots/",
    re.IGNORECASE,
)
PLACEHOLDER_CELL = re.compile(r"\bPLACEHOLDER\b")

TEXT_SUFFIXES = {
    ".cs",
    ".swift",
    ".md",
    ".yml",
    ".yaml",
    ".json",
    ".txt",
    ".ps1",
    ".sh",
    ".xaml",
    ".props",
    ".targets",
    ".csproj",
}


def fatal(msg: str) -> None:
    print(f"FATAL: {msg}", file=sys.stderr)
    sys.exit(2)


def fail(messages: list[str]) -> None:
    print("windows-parity-ledger: FAIL", file=sys.stderr)
    for m in messages:
        print(f"  - {m}", file=sys.stderr)
    sys.exit(1)


def load_ledger(path: Path) -> dict[str, Any]:
    if not path.is_file():
        fatal(f"ledger not found: {path}")
    try:
        data = yaml.safe_load(path.read_text(encoding="utf-8"))
    except Exception as exc:  # noqa: BLE001 — surface parse errors as FATAL
        fatal(f"cannot parse YAML ledger {path}: {exc}")
    if not isinstance(data, dict):
        fatal(f"ledger root must be a mapping: {path}")
    return data


def resolve_path(repo: Path, rel: str) -> Path:
    p = Path(rel)
    return p if p.is_absolute() else (repo / p)


def path_exists(repo: Path, rel: str) -> bool:
    return resolve_path(repo, rel).exists()


def iter_scan_files(root: Path) -> list[Path]:
    if root.is_file():
        return [root]
    if not root.is_dir():
        return []
    out: list[Path] = []
    for dirpath, dirnames, filenames in os.walk(root):
        # skip build outputs
        dirnames[:] = [d for d in dirnames if d not in {"bin", "obj", ".git", "node_modules"}]
        for name in filenames:
            p = Path(dirpath) / name
            if p.suffix.lower() in TEXT_SUFFIXES or p.name in {"Dockerfile", "Makefile"}:
                out.append(p)
    return out


def scan_file_for_tokens(path: Path) -> list[tuple[str, int, str]]:
    """Return list of (token_name, line_no, line_text)."""
    try:
        text = path.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return []
    hits: list[tuple[str, int, str]] = []
    lines = text.splitlines()
    for i, line in enumerate(lines, 1):
        # Skip pure markdown table separator noise? still scan — tokens shouldn't appear there.
        for pattern, name in FORBIDDEN_TOKEN_PATTERNS:
            if pattern.search(line):
                hits.append((name, i, line.strip()[:160]))
                break  # one hit per line is enough
    return hits


def collect_token_hits(repo: Path, rel_paths: list[str]) -> list[str]:
    messages: list[str] = []
    for rel in rel_paths:
        root = resolve_path(repo, rel)
        if not root.exists():
            messages.append(f"blocking path missing: {rel}")
            continue
        for f in iter_scan_files(root):
            for token, line_no, line in scan_file_for_tokens(f):
                try:
                    shown = f.relative_to(repo).as_posix()
                except ValueError:
                    shown = f.as_posix()
                messages.append(
                    f"Real-row forbidden token {token!r} in {shown}:{line_no}: {line}"
                )
    return messages


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--repo-root",
        default=os.environ.get("WINDOWS_PARITY_REPO", ""),
        help="Repository root (default: cwd / auto-detect from script location)",
    )
    parser.add_argument(
        "--ledger",
        default=os.environ.get("WINDOWS_PARITY_LEDGER", ""),
        help="Path to WINDOWS_PARITY_LEDGER.yml",
    )
    parser.add_argument(
        "--bundle",
        default=os.environ.get("WINDOWS_PARITY_BUNDLE", ""),
        help="Optional override for certification bundle path",
    )
    parser.add_argument(
        "--production",
        action="store_true",
        help="Production parity mode: also fail if certification bundle still contains PLACEHOLDER cells",
    )
    args = parser.parse_args(argv)

    if args.repo_root:
        repo = Path(args.repo_root).resolve()
    else:
        # scripts/ci/thisfile → repo root
        repo = Path(__file__).resolve().parents[2]

    ledger_path = (
        Path(args.ledger).resolve()
        if args.ledger
        else repo / "docs/windows-port/WINDOWS_PARITY_LEDGER.yml"
    )
    data = load_ledger(ledger_path)

    errors: list[str] = []
    rows = data.get("rows")
    if not isinstance(rows, list) or not rows:
        fail([f"{ledger_path}: 'rows' must be a non-empty list"])

    # ── status + shape ──────────────────────────────────────────────────────
    ids: set[str] = set()
    status_counts: Counter[str] = Counter()
    macos_mapped: set[str] = set()

    for idx, row in enumerate(rows):
        if not isinstance(row, dict):
            errors.append(f"rows[{idx}]: expected mapping")
            continue
        rid = row.get("id")
        if not rid or not isinstance(rid, str):
            errors.append(f"rows[{idx}]: missing string 'id'")
            continue
        if rid in ids:
            errors.append(f"duplicate row id: {rid}")
        ids.add(rid)

        status = row.get("status")
        if not isinstance(status, str):
            errors.append(f"{rid}: missing string 'status'")
            continue
        if status in FORBIDDEN_STATUSES or status not in VALID_STATUSES:
            errors.append(
                f"{rid}: illegal status {status!r} "
                f"(allowed: {sorted(VALID_STATUSES)}; Authored is never parity)"
            )
            continue
        status_counts[status] += 1

        macos_route = row.get("macos_route")
        if isinstance(macos_route, str) and macos_route.strip():
            macos_mapped.add(macos_route.strip())

        for field in ("macos_capability", "windows_route", "windows_capability", "owner_lane"):
            if not isinstance(row.get(field), str) or not row.get(field).strip():
                errors.append(f"{rid}: missing string '{field}'")

        evidence = row.get("evidence") or []
        tests = row.get("tests") or []
        blocking = row.get("blocking_paths") or row.get("blocking") or []
        if not isinstance(evidence, list) or not isinstance(tests, list) or not isinstance(blocking, list):
            errors.append(f"{rid}: evidence/tests/blocking_paths must be lists")
            continue

        if status == "Real":
            if not evidence:
                errors.append(f"{rid}: Real row requires ≥1 evidence path")
            if not tests:
                errors.append(f"{rid}: Real row requires ≥1 test path")
            if not blocking:
                errors.append(f"{rid}: Real row requires ≥1 blocking_paths entry for token scan")

            for e in evidence:
                if not isinstance(e, str):
                    errors.append(f"{rid}: evidence entry must be string")
                    continue
                if "PLACEHOLDER" in e:
                    errors.append(f"{rid}: evidence path must not contain PLACEHOLDER: {e}")
                ep = resolve_path(repo, e)
                if not ep.is_file():
                    errors.append(f"{rid}: Real evidence file missing: {e}")
                else:
                    try:
                        etext = ep.read_text(encoding="utf-8", errors="ignore")
                    except OSError as exc:
                        errors.append(f"{rid}: cannot read evidence {e}: {exc}")
                    else:
                        if PLACEHOLDER_CELL.search(etext):
                            errors.append(
                                f"{rid}: Real evidence file must not contain PLACEHOLDER: {e}"
                            )

            for t in tests:
                if not isinstance(t, str):
                    errors.append(f"{rid}: test entry must be string")
                    continue
                if not path_exists(repo, t):
                    errors.append(f"{rid}: Real test path missing: {t}")

            # Token scan production paths
            rels = [b for b in blocking if isinstance(b, str)]
            for msg in collect_token_hits(repo, rels):
                errors.append(f"{rid}: {msg}")

    # ── primary / required route coverage ───────────────────────────────────
    primary = data.get("macos_primary_routes") or []
    required = data.get("macos_required_routes") or []
    if not isinstance(primary, list) or not primary:
        errors.append("macos_primary_routes must be a non-empty list")
    else:
        for route in primary:
            if route not in macos_mapped:
                errors.append(
                    f"macOS primary route {route!r} has no ledger mapping "
                    f"(DashboardMainRoute.primarySections coverage required)"
                )
    if isinstance(required, list):
        for route in required:
            if route not in macos_mapped:
                errors.append(f"macOS required route {route!r} has no ledger mapping")

    # ── certification bundle placeholder policy ─────────────────────────────
    bundle_rel = args.bundle or data.get("certification_bundle") or ""
    bundle_path = resolve_path(repo, bundle_rel) if bundle_rel else None
    if bundle_path is not None and bundle_path.is_file():
        btext = bundle_path.read_text(encoding="utf-8", errors="ignore")
        # Always fail on screenshot PLACEHOLDER path claims (false G5 evidence).
        if PLACEHOLDER_SCREENSHOT.search(btext):
            errors.append(
                f"{bundle_rel}: still contains PLACEHOLDER screenshot path claims — "
                "replace with honest blocked wording (no fake paths)"
            )
        if args.production and PLACEHOLDER_CELL.search(btext):
            errors.append(
                f"{bundle_rel}: --production forbids any PLACEHOLDER cell in the certification bundle"
            )
    elif bundle_rel:
        errors.append(f"certification bundle missing: {bundle_rel}")

    # ── report ──────────────────────────────────────────────────────────────
    print("windows-parity-ledger: scan")
    print(f"  ledger: {ledger_path}")
    print(f"  rows:   {len(rows)}")
    print("  status histogram:")
    for name in ("Real", "Substituted", "DeferredApproved", "Blocked"):
        print(f"    {name}: {status_counts.get(name, 0)}")
    extra = {k: v for k, v in status_counts.items() if k not in VALID_STATUSES}
    if extra:
        print(f"    (illegal): {extra}")

    if errors:
        # de-dupe while preserving order
        seen: set[str] = set()
        uniq: list[str] = []
        for e in errors:
            if e not in seen:
                seen.add(e)
                uniq.append(e)
        fail(uniq)

    print("windows-parity-ledger: PASS")
    print(
        "  All Real rows have tests + evidence; no Authored statuses; "
        "macOS primary routes mapped; Real blocking paths clean of false-green tokens."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
