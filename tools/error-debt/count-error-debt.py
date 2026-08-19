#!/usr/bin/env python3
"""Shared error-debt counters for CI gates and TECH_DEBT_METRICS.md."""

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


def is_excluded_path(path: pathlib.Path) -> bool:
    return any(part in EXCLUDED_PATH_SEGMENTS for part in path.parts)


def count_empty_catches(repo_root: pathlib.Path) -> dict[str, int]:
    """Count empty catch blocks in AgentLens and OpenBurnBarDaemon."""
    count = 0
    agent_lens = 0
    daemon = 0
    pattern = re.compile(r"catch\s*\{([^}]*)\}")

    for label, base in (("agent_lens", repo_root / "AgentLens"), ("daemon", repo_root / "OpenBurnBarDaemon")):
        subtotal = 0
        if not base.exists():
            continue
        for path in base.rglob("*.swift"):
            if is_excluded_path(path.relative_to(repo_root)):
                continue
            try:
                text = path.read_text(encoding="utf-8")
            except OSError:
                continue
            for match in pattern.finditer(text):
                body = match.group(1)
                stripped = re.sub(r"//[^\n]*", "", body).strip()
                if not stripped:
                    subtotal += 1
        if label == "agent_lens":
            agent_lens = subtotal
        else:
            daemon = subtotal
        count += subtotal

    return {"total": count, "agent_lens": agent_lens, "daemon": daemon}


# A `try?` occurrence: the Swift keyword `try` followed by `?`, NOT the `try?`
# substring inside an identifier doing optional chaining (`entry?`, `registry?`,
# `auditEntry?`, `CacheEntry?`, `retry?`). The leading word boundary excludes
# those; the negative lookahead on `-ok` excludes the `try?-ok` justification
# token so a tag comment can never inflate the count.
TRY_OPTIONAL_OCCURRENCE = re.compile(r"\btry\?(?!-ok)")
# The justification token that marks an intentional, reviewed best-effort
# optionality. Written as `// try?-ok(<reason>)` on the same source line as the
# `try?` (preferred) or on the line immediately above it.
TRY_OPTIONAL_TAG = "try?-ok("


def strip_line_comment(line: str) -> str:
    """Return the code portion of a Swift line, dropping a trailing `//` comment.

    Tracks string state so a `//` inside a string literal (e.g. a URL like
    ``"https://…"``) is preserved. This keeps a `try?` mentioned only in prose —
    a doc comment or an inline explanation — from being miscounted as executable
    debt; only `try?` in actual code counts.
    """
    in_string = False
    escaped = False
    for index, char in enumerate(line):
        if escaped:
            escaped = False
        elif char == "\\":
            escaped = True
        elif char == '"':
            in_string = not in_string
        elif char == "/" and not in_string and index + 1 < len(line) and line[index + 1] == "/":
            return line[:index]
    return line


def count_untagged_try_optional_in_text(text: str) -> tuple[int, int]:
    """Return (untagged, tagged) `try?` counts for one Swift source string.

    Only `try?` in **code** is counted — a `try?` appearing solely in a comment
    is never executable and never debt. A code `try?` is *tagged* when a
    ``try?-ok(<reason>)`` token appears on its own line or the line immediately
    above it. Tagged sites are intentional best-effort reads that have been
    reviewed and justified; only untagged code sites count as debt, which lets
    the ratchet drive the untagged total to zero without forcing
    genuinely-optional reads into `do/catch`.
    """
    untagged = 0
    tagged = 0
    lines = text.split("\n")
    for index, line in enumerate(lines):
        hits = len(TRY_OPTIONAL_OCCURRENCE.findall(strip_line_comment(line)))
        if hits == 0:
            continue
        previous = lines[index - 1] if index > 0 else ""
        if TRY_OPTIONAL_TAG in line or TRY_OPTIONAL_TAG in previous:
            tagged += hits
        else:
            untagged += hits
    return untagged, tagged


def count_try_optional_services(repo_root: pathlib.Path) -> dict[str, int]:
    """Count untagged `try?` occurrences under AgentLens/Services.

    Only untagged sites count toward the debt budget; sites carrying a
    ``try?-ok(<reason>)`` justification are reported separately as ``tagged``.
    """
    services = repo_root / "AgentLens" / "Services"
    if not services.exists():
        return {"total": 0, "tagged": 0}

    untagged_total = 0
    tagged_total = 0
    for path in services.rglob("*.swift"):
        if is_excluded_path(path.relative_to(repo_root)):
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except OSError:
            continue
        untagged, tagged = count_untagged_try_optional_in_text(text)
        untagged_total += untagged
        tagged_total += tagged

    return {"total": untagged_total, "tagged": tagged_total}


# A cast of a value read out of a GRDB `Row` through the **untyped** subscript.
# `row["c"]` hands back the raw SQLite *storage* value — `Int64` for INTEGER,
# `Double` for REAL, `String` for TEXT — so `as? Int`, `as? Bool` and `as? Date`
# can never succeed, and `as? Double` fails on any INTEGER column (`SUM()`,
# `COUNT()`, a `CASE WHEN` projection). The cast yields nil, the `?? default`
# beside it absorbs it, and the column silently reads as its default forever.
# The typed subscript (`let x: Int = row["c"] ?? 0`) converts across storage
# classes and is the only correct spelling.
#
# `as? String` is deliberately absent: TEXT storage *is* `String`, so that cast
# is sound and idiomatic in hundreds of places.
#
# Telling a GRDB row apart from a JSON or Firestore dictionary matters, because
# both spell the read `x["key"]` and the cast is *correct* on a dictionary. The
# receiver is therefore recognised two ways, and a site counts if either fires:
#
#   1. Its name is row-shaped (`row`, `ftsRow`, `rows`, …).
#   2. It was bound from a `Row.fetch*` call somewhere in the same file, whatever
#      the local name. Real GRDB rows in this repo are also called `mapping`,
#      `columns`, `existing` and `statements`, and a name-only heuristic hands
#      every one of them a free pass through an assert-zero gate.
#
# The row reference itself is matched in every spelling the access takes: bare
# (`row["c"]`), optional chain (`row?["c"]`), collection element (`rows[0]["c"]`,
# `rows[index]["c"]`), and member of a collection (`rows.first?["c"]`).
GRDB_ROW_CAST = re.compile(
    r"\b(\w+)"                        # receiver, validated by the caller
    r"(?:\.\w+)?"                     # .first, .last
    r"\s*(?:\[[^\[\]\"]*\])?"         # [0], [index]
    r"\s*\??"                         # optional chain
    r"\s*\[\s*\"[^\"]+\"\s*\]\s*as\?\s*"
    r"(Int|Int8|Int16|Int32|Int64|UInt|UInt8|UInt16|UInt32|UInt64"
    r"|Bool|Double|Float|Date|NSNumber|Decimal)\b"
)
# A receiver whose own name says it holds a row.
GRDB_ROW_NAME = re.compile(r"^\w*[Rr]ows?$")
# `let mapping = …`, `guard let existing = …`, `var columns: Row? = …`
GRDB_BINDING = re.compile(r"\b(?:let|var)\s+(\w+)\s*(?::[^=]+?)?=")
# The call that proves the bound value is a GRDB row.
GRDB_ROW_FETCH = re.compile(r"\bRow\s*\.\s*fetch(?:One|All|Cursor)\b")
# A fetch is often a few lines below its binding, inside a `read { db in … }`
# block. Scanning ahead stops at the next binding so a later fetch is never
# attributed to an earlier, unrelated name.
GRDB_BINDING_LOOKAHEAD = 6
# Justification token for a reviewed, genuinely-correct untyped cast, written
# `// grdb-row-ok(<reason>)` on the same line or the line immediately above.
GRDB_ROW_CAST_TAG = "grdb-row-ok("


def grdb_row_identifiers(lines: list[str]) -> set[str]:
    """Names bound from a `Row.fetch*` call anywhere in one Swift source."""
    identifiers: set[str] = set()
    for index, line in enumerate(lines):
        binding = GRDB_BINDING.search(strip_line_comment(line))
        if binding is None:
            continue
        window = [line]
        for offset in range(1, GRDB_BINDING_LOOKAHEAD + 1):
            if index + offset >= len(lines):
                break
            following = lines[index + offset]
            if GRDB_BINDING.search(strip_line_comment(following)):
                break
            window.append(following)
        if GRDB_ROW_FETCH.search("\n".join(window)):
            identifiers.add(binding.group(1))
    return identifiers


def count_grdb_row_casts_in_text(text: str) -> tuple[int, int, list[tuple[int, str]]]:
    """Return (untagged, tagged, offending sites) for one Swift source string.

    A site is *tagged* when a ``grdb-row-ok(<reason>)`` token appears on its own
    line or the line immediately above. Casts appearing only inside a comment are
    prose describing the hazard, not the hazard itself.
    """
    untagged = 0
    tagged = 0
    offenders: list[tuple[int, str]] = []
    lines = text.split("\n")
    bound_rows = grdb_row_identifiers(lines)
    for index, line in enumerate(lines):
        hits = sum(
            1
            for match in GRDB_ROW_CAST.finditer(strip_line_comment(line))
            if GRDB_ROW_NAME.match(match.group(1)) or match.group(1) in bound_rows
        )
        if hits == 0:
            continue
        previous = lines[index - 1] if index > 0 else ""
        if GRDB_ROW_CAST_TAG in line or GRDB_ROW_CAST_TAG in previous:
            tagged += hits
        else:
            untagged += hits
            offenders.append((index + 1, line.strip()))
    return untagged, tagged, offenders


# First-party Swift roots. Named explicitly rather than walking the repo so a
# nested agent worktree under `.claude/` — a second checkout of this very
# repository, at whatever commit that agent is on — can never be counted as
# live source.
GRDB_SCAN_ROOTS = ("AgentLens", "AgentLensTests", "OpenBurnBarCore", "OpenBurnBarDaemon")


def count_grdb_row_casts(repo_root: pathlib.Path) -> dict[str, object]:
    """Count untyped GRDB row casts to non-String types across the Swift tree.

    Only files that `import GRDB` are scanned, and only code is counted — a cast
    quoted in a comment is documentation, not debt.
    """
    untagged_total = 0
    tagged_total = 0
    sites: list[str] = []

    paths: list[pathlib.Path] = []
    for root in GRDB_SCAN_ROOTS:
        base = repo_root / root
        if base.exists():
            paths.extend(base.rglob("*.swift"))

    for path in sorted(paths):
        relative = path.relative_to(repo_root)
        if is_excluded_path(relative):
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except OSError:
            continue
        if "import GRDB" not in text:
            continue

        untagged, tagged, offenders = count_grdb_row_casts_in_text(text)
        untagged_total += untagged
        tagged_total += tagged
        sites.extend(f"{relative}:{line_number}: {line}" for line_number, line in offenders)

    return {"total": untagged_total, "tagged": tagged_total, "sites": sites}


def main() -> int:
    parser = argparse.ArgumentParser(description="OpenBurnBar error-debt counters")
    parser.add_argument("--repo-root", type=pathlib.Path, default=pathlib.Path.cwd())
    parser.add_argument(
        "--metric",
        choices=("empty-catch", "try-optional", "grdb-row-cast", "all"),
        default="all",
    )
    parser.add_argument("--format", choices=("json", "text"), default="json")
    args = parser.parse_args()
    repo_root = args.repo_root.resolve()

    payload: dict[str, object] = {}
    if args.metric in ("empty-catch", "all"):
        payload["emptyCatch"] = count_empty_catches(repo_root)
    if args.metric in ("try-optional", "all"):
        payload["tryOptional"] = count_try_optional_services(repo_root)
    if args.metric in ("grdb-row-cast", "all"):
        payload["grdbRowCast"] = count_grdb_row_casts(repo_root)

    if args.format == "text":
        if "emptyCatch" in payload:
            ec = payload["emptyCatch"]
            assert isinstance(ec, dict)
            print(f"empty_catch total={ec['total']} agent_lens={ec['agent_lens']} daemon={ec['daemon']}")
        if "tryOptional" in payload:
            to = payload["tryOptional"]
            assert isinstance(to, dict)
            print(f"try_optional total={to['total']} tagged={to.get('tagged', 0)}")
        if "grdbRowCast" in payload:
            gr = payload["grdbRowCast"]
            assert isinstance(gr, dict)
            print(f"grdb_row_cast total={gr['total']} tagged={gr.get('tagged', 0)}")
    else:
        json.dump(payload, sys.stdout, indent=2)
        sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
