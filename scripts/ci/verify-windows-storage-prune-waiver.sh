#!/usr/bin/env bash
#
# Windows-port parity-honesty gate: the storage-prune waiver.
#
# The Windows Engine CI lane compiles a PRUNED Engine subset — it sets
# OPENBURNBAR_DAEMON_LINUX_BOUNDARY_BUILD=1, which the SwiftPM manifests read to
# drop GRDB-SQLCipher + the OpenBurnBarData storage target from the Windows
# package graph. That prune is a real parity GAP, not parity. This gate makes the
# gap impossible to hide:
#
#   • While ANY workflow prunes storage (sets the boundary flag to a truthy
#     value), a well-formed, non-expired, `active` waiver MUST exist in
#     docs/windows-port/STORAGE_PRUNE_WAIVER.md, and it MUST name every pruning
#     workflow. Otherwise this check FAILS — "storage is pruned" can never
#     silently masquerade as parity.
#   • When the un-pruning lane lands the real Windows storage story (removes the
#     flag, or sets it to 0/false), the gate passes with NO waiver required and
#     reminds you to retire the waiver so it cannot rot into a permanent amnesty.
#
# Fail-closed: a missing / malformed / expired / non-active waiver, or a pruning
# workflow the waiver does not name, is a hard failure.
#
# Overridable for the self-test twin:
#   WINDOWS_PRUNE_WORKFLOWS_DIR  (default: .github/workflows)
#   WINDOWS_PRUNE_WAIVER_DOC     (default: docs/windows-port/STORAGE_PRUNE_WAIVER.md)
#   WINDOWS_PRUNE_NOW            (default: today, ISO YYYY-MM-DD; for expiry tests)
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

exec python3 - <<'PY'
import datetime
import os
import re
import sys
from pathlib import Path

FLAG = "OPENBURNBAR_DAEMON_LINUX_BOUNDARY_BUILD"
WORKFLOWS_DIR = Path(os.environ.get("WINDOWS_PRUNE_WORKFLOWS_DIR", ".github/workflows"))
WAIVER_DOC = Path(
    os.environ.get("WINDOWS_PRUNE_WAIVER_DOC", "docs/windows-port/STORAGE_PRUNE_WAIVER.md")
)
BEGIN = re.compile(r"^\s*<!--\s*BEGIN:windows-storage-prune-waiver\s*-->\s*$")
END = re.compile(r"^\s*<!--\s*END:windows-storage-prune-waiver\s*-->\s*$")

# A truthy assignment = pruning. Anything not explicitly falsy (including a GitHub
# Actions ${{ ... }} expression) is treated as pruning, so the gate fails closed.
FALSY = {"0", "false", "no", "off", "", '""', "''"}
# Matches the flag as a YAML env value (`FLAG: "1"`) or a shell assignment
# (`FLAG=1` / `export FLAG=true`), with optional quotes and a trailing comment.
ASSIGN = re.compile(
    r"\b" + re.escape(FLAG) + r"\s*[:=]\s*"
    r"""(?P<val>"[^"]*"|'[^']*'|\S+?)\s*(?:#.*)?$"""
)


def fatal(message):
    print(f"FATAL: {message}", file=sys.stderr)
    sys.exit(2)


def fail(message):
    print("windows-storage-prune-waiver: FAIL", file=sys.stderr)
    print(message, file=sys.stderr)
    sys.exit(1)


def strip_quotes(value):
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        return value[1:-1]
    return value


# ── 1. Find every workflow that prunes storage ────────────────────────────────
if not WORKFLOWS_DIR.is_dir():
    fatal(f"workflows dir not found: {WORKFLOWS_DIR}")

pruning = {}  # basename -> repo-relative path (as text)
for path in sorted(WORKFLOWS_DIR.rglob("*")):
    if path.suffix.lower() not in {".yml", ".yaml"} or not path.is_file():
        continue
    try:
        lines = path.read_text(encoding="utf-8", errors="ignore").splitlines()
    except OSError as exc:
        fatal(f"cannot read {path}: {exc}")
    for raw in lines:
        match = ASSIGN.search(raw)
        if not match:
            continue
        value = strip_quotes(match.group("val")).strip().lower()
        if value not in FALSY:
            pruning[path.name] = path.as_posix()
            break

# ── 2. Parse the waiver block (fail-closed on malformed) ──────────────────────
def parse_waiver():
    if not WAIVER_DOC.exists():
        return None
    try:
        doc = WAIVER_DOC.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        fatal(f"cannot read {WAIVER_DOC}: {exc}")
    begins = [i for i, ln in enumerate(doc) if BEGIN.match(ln)]
    ends = [i for i, ln in enumerate(doc) if END.match(ln)]
    if not begins and not ends:
        return None
    if len(begins) != 1 or len(ends) != 1 or ends[0] <= begins[0]:
        fail(
            f"{WAIVER_DOC} must contain exactly one BEGIN:windows-storage-prune-waiver "
            "and one END marker, BEGIN first."
        )
    fields = {}
    workflows = []
    in_workflows = False
    for raw in doc[begins[0] + 1:ends[0]]:
        line = raw.rstrip()
        if not line.strip():
            continue
        if in_workflows and line.lstrip().startswith("-"):
            workflows.append(line.lstrip()[1:].strip())
            continue
        in_workflows = False
        if ":" not in line:
            fail(f"{WAIVER_DOC}: malformed waiver line (expected 'key: value'): {line!r}")
        key, _, value = line.partition(":")
        key = key.strip()
        value = value.strip()
        if key == "workflows":
            in_workflows = True
            if value:
                workflows.append(value)
        else:
            fields[key] = value
    return {"fields": fields, "workflows": workflows}


waiver = parse_waiver()

# ── 3. Decide ─────────────────────────────────────────────────────────────────
if not pruning:
    print("windows-storage-prune-waiver: PASS")
    print(
        f"  No workflow sets {FLAG} to a truthy value under {WORKFLOWS_DIR}/ — "
        "storage is NOT pruned in CI, so nothing can masquerade as parity."
    )
    if waiver and waiver["fields"].get("status", "").lower() == "active":
        print(
            f"  NOTICE: {WAIVER_DOC} still carries an active waiver but no lane "
            "prunes storage anymore — delete the waiver to retire the amnesty."
        )
    sys.exit(0)

pruning_list = "\n".join(f"    - {pruning[name]}" for name in sorted(pruning))

if waiver is None:
    fail(
        f"{len(pruning)} workflow(s) set {FLAG} to a truthy value (storage PRUNED):\n"
        f"{pruning_list}\n\n"
        "That is a parity GAP, not parity. Either:\n"
        f"  (a) un-prune storage (remove {FLAG} / set it to 0), or\n"
        f"  (b) document the gap with an active, unexpired waiver block in\n"
        f"      {WAIVER_DOC} that names every pruning workflow above.\n"
        "See that file's header for the required block format."
    )

fields = waiver["fields"]

status = fields.get("status", "").lower()
if status != "active":
    fail(
        f"{WAIVER_DOC}: storage is pruned but the waiver status is "
        f"{status!r}, not 'active'. Set 'status: active' or un-prune storage."
    )

now_raw = os.environ.get("WINDOWS_PRUNE_NOW")
try:
    now = (
        datetime.date.fromisoformat(now_raw)
        if now_raw
        else datetime.date.today()
    )
except ValueError:
    fatal(f"WINDOWS_PRUNE_NOW is not an ISO date: {now_raw!r}")

expires_raw = fields.get("expires", "")
try:
    expires = datetime.date.fromisoformat(expires_raw)
except ValueError:
    fail(
        f"{WAIVER_DOC}: 'expires' must be an ISO date (YYYY-MM-DD); got {expires_raw!r}."
    )
if expires < now:
    fail(
        f"{WAIVER_DOC}: the storage-prune waiver EXPIRED on {expires} (today is {now}).\n"
        "The parity gap is back on the table: either land the un-prune lane or, if "
        "the gap is still deliberate, bump 'expires' with a fresh acknowledgment."
    )

named = {Path(w).name for w in waiver["workflows"]}
missing = sorted(name for name in pruning if name not in named)
if missing:
    missing_list = "\n".join(f"    - {pruning[name]}" for name in missing)
    fail(
        f"{WAIVER_DOC}: these workflows prune storage but the waiver does not name them:\n"
        f"{missing_list}\n\n"
        "Add each to the waiver's 'workflows:' list (or un-prune it). A new pruned "
        "lane must not hide behind an existing waiver."
    )

# Non-fatal: flag waiver entries that no longer correspond to a pruning workflow.
stale = sorted(w for w in waiver["workflows"] if Path(w).name not in pruning)
print("windows-storage-prune-waiver: PASS")
print(
    f"  {len(pruning)} pruning workflow(s) covered by an active waiver "
    f"(expires {expires}):"
)
for name in sorted(pruning):
    print(f"    - {pruning[name]}")
if stale:
    print("  NOTICE: waiver lists workflows that no longer prune storage:")
    for entry in stale:
        print(f"    - {entry}")
    print("  Trim them from the waiver once the un-prune lane has fully landed.")
sys.exit(0)
PY
