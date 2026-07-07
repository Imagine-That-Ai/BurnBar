#!/usr/bin/env bash
#
# Windows-port architecture-honesty gate: the storage architecture (WPD-0005).
#
# The Windows Engine CI lane compiles a storage-pruned Engine subset — it sets
# OPENBURNBAR_DAEMON_LINUX_BOUNDARY_BUILD=1, which the SwiftPM manifests read to
# drop GRDB-SQLCipher + the OpenBurnBarData storage target from the Windows
# package graph. Per WPD-0005 (docs/windows-port/decisions/
# 0005-windows-storage-architecture.md) that prune is PERMANENT ARCHITECTURE,
# not a waived parity gap: on Windows the Swift Engine is compute-only and the
# C# seam (windows/storage/) owns persistence — "the Engine computes, the shell
# persists". This gate keeps that decision honest:
#
#   • Every workflow that sets the boundary flag to a truthy value MUST be named
#     in WPD-0005's machine-read block. A new pruned lane cannot hide behind the
#     architecture decision without being written into it.
#   • The C# storage seam's test project MUST exist and contain tests — an
#     architecture claim with nothing behind it fails the gate.
#   • A missing WPD file, a malformed machine-read block, or a non-`accepted`
#     status is a hard failure.
#
# Fail-closed on all of the above. (This gate replaced the storage-prune WAIVER
# gate, verify-windows-storage-prune-waiver.sh, when WPD-0005 turned the waived
# gap into a decided architecture — same honesty, no expiry, because decisions
# are allowed to be permanent; waivers were not.)
#
# Overridable for the self-test twin:
#   WINDOWS_STORAGE_WORKFLOWS_DIR  (default: .github/workflows)
#   WINDOWS_STORAGE_WPD_DOC        (default: docs/windows-port/decisions/0005-windows-storage-architecture.md)
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

exec python3 - <<'PY'
import os
import re
import sys
from pathlib import Path

FLAG = "OPENBURNBAR_DAEMON_LINUX_BOUNDARY_BUILD"
WORKFLOWS_DIR = Path(os.environ.get("WINDOWS_STORAGE_WORKFLOWS_DIR", ".github/workflows"))
WPD_DOC = Path(
    os.environ.get(
        "WINDOWS_STORAGE_WPD_DOC",
        "docs/windows-port/decisions/0005-windows-storage-architecture.md",
    )
)
BEGIN = re.compile(r"^\s*<!--\s*BEGIN:windows-storage-architecture\s*-->\s*$")
END = re.compile(r"^\s*<!--\s*END:windows-storage-architecture\s*-->\s*$")

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
    print("windows-storage-architecture: FAIL", file=sys.stderr)
    print(message, file=sys.stderr)
    sys.exit(1)


def strip_quotes(value):
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        return value[1:-1]
    return value


# ── 1. Find every workflow that sets the boundary flag truthy ─────────────────
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

# ── 2. Parse WPD-0005's machine-read block (fail-closed on malformed) ─────────
def parse_wpd():
    if not WPD_DOC.exists():
        return None
    try:
        doc = WPD_DOC.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        fatal(f"cannot read {WPD_DOC}: {exc}")
    begins = [i for i, ln in enumerate(doc) if BEGIN.match(ln)]
    ends = [i for i, ln in enumerate(doc) if END.match(ln)]
    if not begins and not ends:
        return None
    if len(begins) != 1 or len(ends) != 1 or ends[0] <= begins[0]:
        fail(
            f"{WPD_DOC} must contain exactly one BEGIN:windows-storage-architecture "
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
            fail(f"{WPD_DOC}: malformed block line (expected 'key: value'): {line!r}")
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


wpd = parse_wpd()

# ── 3. Decide ─────────────────────────────────────────────────────────────────
if not pruning:
    print("windows-storage-architecture: PASS")
    print(
        f"  No workflow sets {FLAG} to a truthy value under {WORKFLOWS_DIR}/ — "
        "no lane compiles the storage-pruned Engine subset."
    )
    if wpd is not None and wpd["workflows"]:
        print(
            f"  NOTICE: {WPD_DOC} still lists pruning workflows in its machine-read "
            "block but no lane sets the flag anymore — revisit WPD-0005 (the "
            "compute-only Engine premise may have changed) and trim the block."
        )
    sys.exit(0)

pruning_list = "\n".join(f"    - {pruning[name]}" for name in sorted(pruning))

if wpd is None:
    fail(
        f"{len(pruning)} workflow(s) set {FLAG} to a truthy value (storage boundary "
        f"flag active — Engine compiled without the storage target):\n"
        f"{pruning_list}\n\n"
        f"but the governing architecture decision is missing or has no machine-read "
        f"block:\n  {WPD_DOC}\n\n"
        "Per WPD-0005 the prune is only honest while that decision record exists "
        "and names every flag-setting workflow. Restore the WPD (with its "
        "BEGIN/END:windows-storage-architecture block) or stop setting the flag."
    )

fields = wpd["fields"]

status = fields.get("status", "").lower()
if status != "accepted":
    fail(
        f"{WPD_DOC}: the boundary flag is set but the architecture status is "
        f"{status!r}, not 'accepted'. Either the decision was withdrawn (then "
        "un-prune storage / remove the flag) or the block is wrong — fix one."
    )

named = {Path(w).name for w in wpd["workflows"]}
missing = sorted(name for name in pruning if name not in named)
if missing:
    missing_list = "\n".join(f"    - {pruning[name]}" for name in missing)
    fail(
        f"{WPD_DOC}: these workflows set {FLAG} but the WPD-0005 machine-read "
        f"block does not name them:\n"
        f"{missing_list}\n\n"
        "Add each to the block's 'workflows:' list (which means consciously "
        "extending the architecture decision to that lane) or stop setting the "
        "flag there. A new pruned lane must not hide behind the existing decision."
    )

storage_tests_raw = fields.get("storage-tests", "")
if not storage_tests_raw:
    fail(
        f"{WPD_DOC}: the machine-read block is missing 'storage-tests:' — the gate "
        "cannot verify the C# storage seam is tested. Name the test project dir "
        "(e.g. windows/storage/OpenBurnBar.Storage.Tests)."
    )
storage_tests = Path(storage_tests_raw)
if not storage_tests.is_dir():
    fail(
        f"{WPD_DOC}: 'storage-tests' names {storage_tests_raw}, but that directory "
        "does not exist. The architecture claim (C# seam owns storage) is hollow "
        "without its test project — restore the tests or reopen the decision."
    )
has_csproj = any(storage_tests.glob("*.csproj"))
has_tests = any(storage_tests.rglob("*Tests.cs"))
if not (has_csproj and has_tests):
    fail(
        f"{storage_tests_raw} exists but does not look like a test project "
        f"(*.csproj found: {has_csproj}; *Tests.cs found: {has_tests}). "
        "The C# storage seam must stay tested for the compute-only Engine "
        "architecture to hold."
    )

# Non-fatal: flag block entries that no longer correspond to a pruning workflow.
stale = sorted(w for w in wpd["workflows"] if Path(w).name not in pruning)
print("windows-storage-architecture: PASS")
print(
    f"  {len(pruning)} boundary-flag workflow(s) named by WPD-0005 "
    f"({WPD_DOC}, status: accepted):"
)
for name in sorted(pruning):
    print(f"    - {pruning[name]}")
print(f"  C# storage seam tests present: {storage_tests_raw}")
if stale:
    print("  NOTICE: WPD-0005 block lists workflows that no longer set the flag:")
    for entry in stale:
        print(f"    - {entry}")
    print("  Trim them from the block to keep the decision record exact.")
sys.exit(0)
PY
