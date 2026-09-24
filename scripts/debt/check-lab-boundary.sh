#!/usr/bin/env bash
# Wave 3.1: Core/Lab boundary. AgentLens/Lab/** compiles ONLY when
# OPENBURNBAR_LAB is set (Lab build config); Core builds compile Lab files to
# nothing, so any unguarded Core reference to a Lab type fails the build.
# This ratchet catches mistakes early with a clear message and freezes the
# set of Core files that touch Lab: (1) every Lab Swift/ObjC++ file must carry
# a file-level `#if OPENBURNBAR_LAB` gate; (2) every non-Lab reference to a
# Lab-declared type must live in a guard-marked file; (3) the Core touchpoint
# set is shrink-only — new touchpoints need review + --update. The compiler
# remains the hard gate; this script is the early, legible one.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
baseline_path="${repo_root}/budgets/lab-boundary-baseline.json"
mode="${1:-}"
python3 - "${repo_root}" "${baseline_path}" "${mode}" <<'PY'
import json
import re
import subprocess
import sys
from pathlib import Path

repo = Path(sys.argv[1])
baseline_path = Path(sys.argv[2])
mode = sys.argv[3] if len(sys.argv) > 3 else ""
lab_dir = repo / "AgentLens/Lab"
guard = "#if OPENBURNBAR_LAB"
# Top-level declarations only (column 0): nested/member types are invisible
# outside their parent, and file-private top-level types are invisible
# outside their file, so neither can leak into Core. A Core file naming
# `PetPanel.State` still trips on the top-level `PetPanel` alternative.
decl_re = re.compile(r"^(?:@\w+\s+)*(?:public\s+|open\s+|internal\s+)?(?:final\s+)?(?:class|struct|enum|actor|protocol)\s+([A-Za-z_][A-Za-z0-9_]*)")
comment_re = re.compile(r"^\s*//")

def rg(pattern, *roots, globs=("--glob", "*.swift")):
    result = subprocess.run(
        ["rg", "-n", "--no-heading", pattern, *globs, *[str(r) for r in roots]],
        capture_output=True, text=True, cwd=repo,
    )
    return result.stdout.splitlines()

failures = []

# Rule 1: every Lab implementation file carries the file-level gate.
lab_files = sorted(lab_dir.rglob("*.swift")) + sorted(lab_dir.rglob("*.mm"))
ungated = [str(p.relative_to(repo)) for p in lab_files if guard not in p.read_text()]
if ungated:
    failures.append("Lab files missing the file-level `#if OPENBURNBAR_LAB` gate:\n" + "\n".join(ungated))

# Lab-declared nominal types (the surface Core must not touch unguarded).
symbols = set()
for path in sorted(lab_dir.rglob("*.swift")):
    for line in path.read_text().splitlines():
        match = decl_re.match(line)
        if match:
            symbols.add(match.group(1))

# Rule 2: outside Lab, references resolve only in guard-marked files.
touchpoints = set()
unguarded_refs = []
if symbols:
    alternation = r"\b(?:" + "|".join(sorted(symbols)) + r")\b"
    sym_re = re.compile(alternation)
    string_re = re.compile(r'"(?:[^"\\]|\\.)*"')
    block_comment_re = re.compile(r"/\*.*?\*/")
    for line in rg(alternation, "AgentLens", "OpenBurnBarCore",
                   "AgentLensTests", "OpenBurnBarDaemon",
                   globs=("--glob", "*.swift", "--glob", "*.mm", "--glob", "*.h")):
        # rg -n rows are path:lineno:content. DocC ``Symbol`` cross-links in
        # comments bind nothing at compile time; only code references can
        # breach the boundary.
        parts = line.split(":", 2)
        if len(parts) != 3:
            continue
        path, _, content = parts
        if comment_re.match(content):
            continue
        # String literals and /* */ blocks bind nothing (provenance labels
        # like "PetDefinition.agent.persona" name Lab types without
        # referencing them). Strip them and require a surviving code match.
        # Multiline """ strings are NOT stripped: a Lab word inside one
        # still flags, which fails noisy, never silent.
        code = string_re.sub('""', content)
        code = block_comment_re.sub("", code)
        if not sym_re.search(code):
            continue
        if path.startswith("AgentLens/Lab/") or "/AgentLens/Lab/" in path:
            continue
        rel = Path(path)
        try:
            text = (repo / rel).read_text()
        except (OSError, ValueError):
            continue
        if guard in text:
            touchpoints.add(str(rel))
        else:
            unguarded_refs.append(f"{path}: {line.split(':', 2)[-1].strip()[:100]}")
if unguarded_refs:
    failures.append(
        "non-Lab files reference Lab-declared types without an `#if OPENBURNBAR_LAB` "
        "region (guard the use-site or move it into AgentLens/Lab):\n" + "\n".join(unguarded_refs))

live = {"touchpoints": sorted(touchpoints)}
if mode == "--print-live":
    print(json.dumps(live, indent=2))
    raise SystemExit(0 if not failures else 1)
if failures:
    raise SystemExit("\n\n".join(failures))

# Rule 3: the Core touchpoint set is shrink-only.
if mode == "--update" or not baseline_path.exists():
    baseline_path.write_text(json.dumps({
        "touchpoints": sorted(touchpoints),
        "note": "Non-Lab files that reference Lab-declared types inside `#if OPENBURNBAR_LAB` regions. Shrink-only; a new Core file touching Lab needs review before --update.",
    }, indent=2) + "\n")
    print(f"wrote {baseline_path} ({len(touchpoints)} touchpoints)")
    raise SystemExit(0)

baseline = json.loads(baseline_path.read_text())
allowed = set(baseline["touchpoints"])
extra = sorted(touchpoints - allowed)
print(f"lab boundary: live={len(touchpoints)} baseline={len(allowed)}")
if extra:
    raise SystemExit("new Core files touching Lab (review, then --update):\n" + "\n".join(extra))
gone = sorted(allowed - touchpoints)
if gone:
    print("Improved: Lab touchpoints dropped: " + ", ".join(gone) + " — run --update")
print("lab boundary ratchet OK")
PY
