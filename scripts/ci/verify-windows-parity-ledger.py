#!/usr/bin/env python3
"""Windows parity ledger honesty gate (Phase 0 / Wave 1).

Fails closed when:
  * the ledger is missing / unparseable
  * its declared row count or status histogram is stale
  * any row uses a forbidden status (including legacy ``Authored``)
  * any macOS primary / required route lacks a mapping row
  * any Real row lacks ≥1 existing evidence file (non-empty, marked) and
    ≥1 existing test-shaped path
  * any Real row lacks ≥1 production-prefix blocking path with scannable text
  * any Real-row production blocking path contains anti-false-green tokens
  * any DeferredApproved row lacks revive_trigger + existing evidence
  * certification bundle reintroduces PLACEHOLDER screenshot path claims

Usage:
  python3 scripts/ci/verify-windows-parity-ledger.py
  python3 scripts/ci/verify-windows-parity-ledger.py --ledger PATH --repo-root PATH
  python3 scripts/ci/verify-windows-parity-ledger.py --production

Environment overrides (for self-tests):
  WINDOWS_PARITY_LEDGER   path to ledger YAML
  WINDOWS_PARITY_REPO     repo root
  WINDOWS_PARITY_BUNDLE   certification bundle path (optional override)

PyYAML is required. CI jobs must ``pip install 'pyyaml>=6,<7'`` explicitly —
do not assume the runner image ships it.
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
except ImportError:  # pragma: no cover
    print(
        "FATAL: PyYAML is required. Install with: python3 -m pip install 'pyyaml>=6,<7'",
        file=sys.stderr,
    )
    sys.exit(2)

VALID_STATUSES = frozenset({"Real", "Substituted", "DeferredApproved", "Blocked"})
FORBIDDEN_STATUSES = frozenset(
    {
        "Authored",
        "authored",
        "AUTHORED",
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
# Bare domain words (e.g. enum case Unavailable, prose "none are deferred") are
# intentionally excluded — see docs/windows-port/WINDOWS_PARITY_LEDGER.md.
FORBIDDEN_TOKEN_PATTERNS: list[tuple[re.Pattern[str], str]] = [
    (re.compile(r"\bSampleModeEnabled\b"), "SampleModeEnabled"),
    (re.compile(r"\b\w*SampleData\w*\b"), "SampleData"),
    (re.compile(r"\b\w*DemoHost\w*\b"), "DemoHost"),
    (re.compile(r"\bMockAttestationProducer\b"), "MockAttestationProducer"),
    (re.compile(r"\bdev-host\b", re.IGNORECASE), "dev-host"),
    # Stub production substitutes: bare Stub type, Stub*, IStub*, SurfaceStub*.
    # Bare "Stub" is intentional — class Stub / type Stub is a false-green smell
    # on Real rows. Does not match Stubborn (capital after Stub required for compounds;
    # bare \bStub\b still matches identifier Stub only).
    (re.compile(r"\bStub\b|\bStub[A-Z]\w*\b|\bIStub\w*\b|\bSurfaceStub\w*\b"), "Stub"),
    (
        re.compile(r"\bSettingsPlaceholderPage\b|\bPlaceholderCard\b|\bPLACEHOLDER\b"),
        "Placeholder",
    ),
    # Compound deferral markers only (not prose "none are deferred").
    (
        re.compile(
            r"(?:dev-host|CI|Windows-runner|WS-D|adapter|host|XamlCompiler)-deferred"
            r"|\bdev-host/CI-deferred\b",
            re.IGNORECASE,
        ),
        "deferred",
    ),
    # Production unavailable substitutes — not domain enums like SourceKind.Unavailable.
    (
        re.compile(r"\bUnavailable(?:ChatStreamDriver|Host|Source|Driver|Service|Client)\b"),
        "Unavailable",
    ),
]

PLACEHOLDER_SCREENSHOT = re.compile(
    r"PLACEHOLDER\s+`?screenshots/",
    re.IGNORECASE,
)
PLACEHOLDER_CELL = re.compile(r"\bPLACEHOLDER\b")

# Blocking paths must include ≥1 entry under these production prefixes.
PRODUCTION_PREFIXES = (
    "windows/",
    "OpenBurnBarCore/",
    "packages/",
    "crates/",
)

# Evidence / docs paths are never token-scanned (honest non-claims would false-fail).
SKIP_TOKEN_SCAN_PREFIXES = (
    "docs/",
    "scripts/ci/",
)

CODE_SUFFIXES = {
    ".cs",
    ".swift",
    ".xaml",
    ".props",
    ".targets",
    ".csproj",
    ".fs",
    ".rs",
    ".ts",
    ".tsx",
    ".js",
    ".mjs",
    ".c",
    ".h",
    ".cpp",
    ".hpp",
}

TEXT_SUFFIXES = CODE_SUFFIXES | {
    ".md",
    ".yml",
    ".yaml",
    ".json",
    ".txt",
    ".ps1",
    ".sh",
}

EVIDENCE_MIN_CHARS = 200
EVIDENCE_REQUIRED_MARKERS = ("Ledger row:", "What this proves")


def fatal(msg: str) -> None:
    print(f"FATAL: {msg}", file=sys.stderr)
    sys.exit(2)


def fail(messages: list[str]) -> None:
    print("windows-parity-ledger: FAIL", file=sys.stderr)
    for m in messages:
        print(f"  - {m}", file=sys.stderr)
    sys.exit(1)


def normalize_rel(rel: str) -> str:
    """Normalize ledger path strings to forward-slash, repo-relative form.

    Does **not** strip leading ``..`` segments — those are rejected by
    :func:`confine_rel`. Only collapses backslashes and a single optional
    ``./`` prefix.
    """
    s = rel.strip().replace("\\", "/")
    while s.startswith("./"):
        s = s[2:]
    return s


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


def confine_rel(repo: Path, rel: str) -> tuple[str | None, str | None]:
    """Return (normalized_rel, error). Reject absolute paths and `..` escape."""
    if not isinstance(rel, str) or not rel.strip():
        return None, "path must be a non-empty string"
    raw = rel.strip()
    if raw.startswith("/") or re.match(r"^[A-Za-z]:[/\\]", raw):
        return None, f"absolute paths are forbidden: {rel}"
    norm = normalize_rel(raw)
    if not norm or norm == ".":
        return None, f"empty path after normalize: {rel}"
    parts = Path(norm).parts
    if ".." in parts:
        return None, f"path escape '..' is forbidden: {rel}"
    # Resolve and confirm under repo (catches symlink escapes when present).
    candidate = (repo / norm).resolve()
    try:
        candidate.relative_to(repo.resolve())
    except ValueError:
        return None, f"path escapes repo root: {rel}"
    return norm, None


def is_production_prefix(norm: str) -> bool:
    return any(norm == p.rstrip("/") or norm.startswith(p) for p in PRODUCTION_PREFIXES)


def skip_token_scan(norm: str) -> bool:
    return any(norm == p.rstrip("/") or norm.startswith(p) for p in SKIP_TOKEN_SCAN_PREFIXES)


def is_test_tree_path(norm: str) -> bool:
    """True when the path lives in a test project/tree (not production code).

    Used to deny Real production-prefix *credit* for ``windows/tests/…`` and
    ``*.Tests`` projects so a Real row cannot satisfy blocking_paths with only
    test sources. Does **not** treat Sources/*Parity harnesses as test trees.
    """
    parts = Path(norm).parts
    for part in parts:
        if part in {"tests", "Tests", "Fixtures", "AgentLensTests", "__tests__"}:
            return True
        # e.g. OpenBurnBar.Storage.Tests
        if part.endswith(".Tests"):
            return True
    name = Path(norm).name
    if re.search(r"Tests?\.(cs|swift|py|sh|mjs|ts|tsx)$", name, re.I):
        return True
    if name.endswith(".test.sh") or name.endswith(".test.mjs") or name.endswith(".test.py"):
        return True
    return False


def is_test_path(norm: str) -> bool:
    """Heuristic: path must look like a test harness for the Real *tests* field."""
    if is_test_tree_path(norm):
        return True
    name = Path(norm).name
    if re.search(r"Parity\.(swift|cs)$", name):
        return True
    if "golden" in name.lower() and name.endswith((".json", ".jsonl", ".txt")):
        return True
    return False


def counts_as_production_blocking(norm: str) -> bool:
    """Production-prefix path that is not a test tree — eligible for Real credit."""
    return is_production_prefix(norm) and not is_test_tree_path(norm)


def iter_scan_files(root: Path, *, code_only: bool = False) -> list[Path]:
    suffixes = CODE_SUFFIXES if code_only else TEXT_SUFFIXES
    if root.is_file():
        if root.suffix.lower() in suffixes or root.name in {"Dockerfile", "Makefile"}:
            return [root]
        return []
    if not root.is_dir():
        return []
    out: list[Path] = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in {"bin", "obj", ".git", "node_modules"}]
        for name in filenames:
            p = Path(dirpath) / name
            if p.suffix.lower() in suffixes or p.name in {"Dockerfile", "Makefile"}:
                out.append(p)
    return out


def scan_file_for_tokens(path: Path) -> tuple[list[tuple[str, int]], str | None]:
    """Return (hits as (token, line_no), read_error)."""
    try:
        text = path.read_text(encoding="utf-8", errors="ignore")
    except OSError as exc:
        return [], f"cannot read for token scan: {path}: {exc}"
    hits: list[tuple[str, int]] = []
    for i, line in enumerate(text.splitlines(), 1):
        for pattern, name in FORBIDDEN_TOKEN_PATTERNS:
            if pattern.search(line):
                hits.append((name, i))
                break
    return hits, None


def collect_token_hits(repo: Path, rel_paths: list[str]) -> list[str]:
    """Token-scan production blocking paths. Skip docs/evidence. Fail closed on OSError."""
    messages: list[str] = []
    for rel in rel_paths:
        norm, err = confine_rel(repo, rel)
        if err:
            messages.append(f"blocking path invalid: {err}")
            continue
        assert norm is not None
        if skip_token_scan(norm):
            # Evidence/docs listed in blocking_paths are ignored for tokens
            # (still counted for existence / production-prefix rules separately).
            continue
        root = repo / norm
        if not root.exists():
            messages.append(f"blocking path missing: {norm}")
            continue
        files = iter_scan_files(root, code_only=False)
        # Prefer scanning code-like files; if only non-code text, still scan.
        code_files = [f for f in files if f.suffix.lower() in CODE_SUFFIXES]
        scan_files = code_files if code_files else files
        if root.is_dir() and not scan_files:
            messages.append(f"blocking path has zero scannable text files: {norm}")
            continue
        if root.is_file() and not scan_files:
            messages.append(f"blocking path is not a scannable text file: {norm}")
            continue
        for f in scan_files:
            hits, read_err = scan_file_for_tokens(f)
            if read_err:
                messages.append(read_err)
                continue
            try:
                shown = f.relative_to(repo).as_posix()
            except ValueError:
                shown = f.as_posix()
            for token, line_no in hits:
                # Log path + line + token only — never dump full source lines
                # (avoids leaking secrets/snippets into CI logs).
                messages.append(f"Real-row forbidden token {token!r} in {shown}:{line_no}")
    return messages


def validate_evidence_file(repo: Path, rid: str, rel: str) -> list[str]:
    errors: list[str] = []
    norm, err = confine_rel(repo, rel)
    if err:
        return [f"{rid}: evidence path invalid: {err}"]
    assert norm is not None
    if "PLACEHOLDER" in norm:
        errors.append(f"{rid}: evidence path must not contain PLACEHOLDER: {norm}")
    ep = repo / norm
    if not ep.is_file():
        errors.append(f"{rid}: Real evidence file missing: {norm}")
        return errors
    try:
        etext = ep.read_text(encoding="utf-8", errors="ignore")
    except OSError as exc:
        errors.append(f"{rid}: cannot read evidence {norm}: {exc}")
        return errors
    stripped = etext.strip()
    if not stripped:
        errors.append(f"{rid}: Real evidence file is empty: {norm}")
        return errors
    # Primary evidence under docs/windows-port/evidence/ must be substantive + marked.
    if norm.startswith("docs/windows-port/evidence/"):
        if len(stripped) < EVIDENCE_MIN_CHARS:
            errors.append(f"{rid}: Real evidence file too short (<{EVIDENCE_MIN_CHARS} non-whitespace chars): {norm}")
        for marker in EVIDENCE_REQUIRED_MARKERS:
            if marker not in etext:
                errors.append(f"{rid}: Real evidence missing required marker {marker!r}: {norm}")
    elif len(stripped) < 40:
        errors.append(f"{rid}: Real evidence file too short: {norm}")
    if PLACEHOLDER_CELL.search(etext):
        errors.append(f"{rid}: Real evidence file must not contain PLACEHOLDER: {norm}")
    return errors


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
        repo = Path(__file__).resolve().parents[2]

    if args.ledger:
        ledger_path = Path(args.ledger).resolve()
    else:
        ledger_path = repo / "docs/windows-port/WINDOWS_PARITY_LEDGER.yml"
    data = load_ledger(ledger_path)

    errors: list[str] = []
    rows = data.get("rows")
    if not isinstance(rows, list) or not rows:
        fail([f"{ledger_path}: 'rows' must be a non-empty list"])

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
                f"{rid}: illegal status {status!r} (allowed: {sorted(VALID_STATUSES)}; Authored is never parity)"
            )
            continue
        status_counts[status] += 1

        macos_route = row.get("macos_route")
        if isinstance(macos_route, str) and macos_route.strip():
            macos_mapped.add(macos_route.strip())

        for field in ("macos_capability", "windows_route", "windows_capability", "owner_lane"):
            val = row.get(field)
            if not isinstance(val, str) or not val.strip():
                errors.append(f"{rid}: missing string '{field}'")

        evidence = row.get("evidence") or []
        tests = row.get("tests") or []
        blocking = row.get("blocking_paths") or row.get("blocking") or []
        if not isinstance(evidence, list) or not isinstance(tests, list) or not isinstance(blocking, list):
            errors.append(f"{rid}: evidence/tests/blocking_paths must be lists")
            continue

        # ── DeferredApproved: revive_trigger + existing evidence ────────────
        if status == "DeferredApproved":
            revive = row.get("revive_trigger")
            if not isinstance(revive, str) or not revive.strip():
                errors.append(f"{rid}: DeferredApproved row requires non-empty 'revive_trigger'")
            if not evidence:
                errors.append(f"{rid}: DeferredApproved row requires ≥1 evidence path")
            for e in evidence:
                if not isinstance(e, str):
                    errors.append(f"{rid}: evidence entry must be string")
                    continue
                norm, err = confine_rel(repo, e)
                if err:
                    errors.append(f"{rid}: evidence path invalid: {err}")
                    continue
                assert norm is not None
                if not (repo / norm).is_file():
                    errors.append(f"{rid}: DeferredApproved evidence file missing: {norm}")

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
                errors.extend(validate_evidence_file(repo, rid, e))

            test_ok = 0
            for t in tests:
                if not isinstance(t, str):
                    errors.append(f"{rid}: test entry must be string")
                    continue
                norm, err = confine_rel(repo, t)
                if err:
                    errors.append(f"{rid}: test path invalid: {err}")
                    continue
                assert norm is not None
                if not (repo / norm).exists():
                    errors.append(f"{rid}: Real test path missing: {norm}")
                    continue
                if not is_test_path(norm):
                    errors.append(
                        f"{rid}: Real test path is not test-shaped "
                        f"(need *Tests*, windows/tests/, Fixtures, *Parity*, golden): {norm}"
                    )
                    continue
                test_ok += 1
            if tests and test_ok == 0 and all(isinstance(t, str) for t in tests):
                # individual errors already recorded; ensure at least one test-shaped
                pass
            elif evidence and tests and test_ok == 0:
                errors.append(f"{rid}: Real row requires ≥1 test-shaped path")

            # Production-prefix + scannable blocking paths (test trees do not count)
            prod_count = 0
            rels_for_scan: list[str] = []
            for b in blocking:
                if not isinstance(b, str):
                    errors.append(f"{rid}: blocking_paths entry must be string")
                    continue
                norm, err = confine_rel(repo, b)
                if err:
                    errors.append(f"{rid}: blocking path invalid: {err}")
                    continue
                assert norm is not None
                rels_for_scan.append(norm)
                root = repo / norm
                if not root.exists():
                    errors.append(f"{rid}: blocking path missing: {norm}")
                    continue
                if counts_as_production_blocking(norm):
                    prod_count += 1
                    files = iter_scan_files(root, code_only=False)
                    if root.is_dir() and not files:
                        errors.append(f"{rid}: production blocking dir has zero scannable text files: {norm}")
                    if root.is_file() and root.suffix.lower() not in TEXT_SUFFIXES:
                        errors.append(f"{rid}: production blocking file is not scannable text: {norm}")
                elif is_production_prefix(norm) and is_test_tree_path(norm):
                    # Still token-scan test paths if listed, but they earn no credit.
                    pass
            if blocking and prod_count == 0:
                errors.append(
                    f"{rid}: Real row requires ≥1 non-test production blocking_paths "
                    f"entry under {list(PRODUCTION_PREFIXES)} "
                    f"(docs-only and test trees such as windows/tests/ cannot satisfy Real)"
                )

            for msg in collect_token_hits(repo, rels_for_scan):
                errors.append(f"{rid}: {msg}")

    # ── declared summary must match the rows ─────────────────────────────────
    declared_row_count = data.get("declared_row_count")
    if isinstance(declared_row_count, bool) or not isinstance(declared_row_count, int):
        errors.append("declared_row_count must be an integer")
    elif declared_row_count != len(rows):
        errors.append(
            f"declared_row_count is stale: declared {declared_row_count}, actual {len(rows)}"
        )

    declared_histogram = data.get("declared_status_histogram")
    if not isinstance(declared_histogram, dict):
        errors.append("declared_status_histogram must be a mapping")
    else:
        declared_keys = set(declared_histogram)
        if declared_keys != set(VALID_STATUSES):
            errors.append(
                "declared_status_histogram must contain exactly "
                f"{sorted(VALID_STATUSES)}; got {sorted(str(key) for key in declared_keys)}"
            )
        for status in sorted(VALID_STATUSES):
            declared = declared_histogram.get(status)
            if isinstance(declared, bool) or not isinstance(declared, int) or declared < 0:
                errors.append(
                    f"declared_status_histogram.{status} must be a non-negative integer"
                )
                continue
            actual = status_counts.get(status, 0)
            if declared != actual:
                errors.append(
                    f"declared_status_histogram.{status} is stale: "
                    f"declared {declared}, actual {actual}"
                )

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
    if bundle_rel:
        bnorm, berr = confine_rel(repo, str(bundle_rel))
        if berr:
            errors.append(f"certification bundle path invalid: {berr}")
        else:
            assert bnorm is not None
            bundle_path = repo / bnorm
            if bundle_path.is_file():
                try:
                    btext = bundle_path.read_text(encoding="utf-8", errors="ignore")
                except OSError as exc:
                    errors.append(f"cannot read certification bundle {bnorm}: {exc}")
                else:
                    if PLACEHOLDER_SCREENSHOT.search(btext):
                        errors.append(
                            f"{bnorm}: still contains PLACEHOLDER screenshot path claims — "
                            "replace with honest blocked wording (no fake paths)"
                        )
                    if args.production and PLACEHOLDER_CELL.search(btext):
                        errors.append(f"{bnorm}: --production forbids any PLACEHOLDER cell in the certification bundle")
            else:
                errors.append(f"certification bundle missing: {bnorm}")

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
