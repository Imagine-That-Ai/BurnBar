#!/usr/bin/env bash
#
# Debt-ratchet baseline monotonicity meta-gate (remediation R-GH3).
#
# The per-metric debt ratchets (scripts/debt/check-*-budget.sh, scripts/ci/
# knip-ratchet.sh) read their budgets/*.json baselines from the WORKING TREE and
# only fail when live > baseline. Nothing stops a PR from RAISING the baseline in
# the same change (the "797 -> 800" bypass), which silently launders new debt in
# past every ratchet at once.
#
# This gate closes that hole. Against the PR's base branch it:
#   • loads every budgets/*.json and any *baseline*.json (debt baselines only;
#     test-fixture goldens are excluded) as it stood on the base,
#   • compares every numeric field (target / total / count / per-file lines …),
#   • FAILS if any number increased vs base — a baseline may only shrink, and
#   • FAILS if a raise is coupled with non-baseline source edits, because a
#     baseline change must land standalone so a reviewer can judge the debt bump
#     in isolation.
# Pure decreases pass. A brand-new baseline file (absent on base) is allowed but
# logged. This is intentionally NOT wired into CI yet.
#
# Base autodetect: origin/main, else the HEAD..origin/main merge-base, else main.
# Override with `--base <ref>` or BASE_REF=<ref> (the self-test uses this).
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

base_ref="${BASE_REF:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --base) base_ref="${2:?--base needs a ref}"; shift 2 ;;
    --base=*) base_ref="${1#--base=}"; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

resolve_ref() { git rev-parse --verify --quiet "$1^{commit}" >/dev/null 2>&1; }

# Autodetect the base only when it was not supplied. Preferring the merge-base
# keeps the comparison scoped to THIS branch's commits (so debt already on main
# is never attributed to the PR); origin/main is the fallback if histories are
# unrelated, and a local `main` covers checkouts without an `origin` remote.
if [[ -z "${base_ref}" ]]; then
  if resolve_ref origin/main; then
    base_ref="$(git merge-base HEAD origin/main 2>/dev/null || echo origin/main)"
  elif resolve_ref main; then
    base_ref="$(git merge-base HEAD main 2>/dev/null || echo main)"
  fi
fi

exec python3 - "${base_ref}" <<'PY'
import fnmatch
import json
import os
import subprocess
import sys

base = sys.argv[1] if len(sys.argv) > 1 else ""


def git(args, check=True):
    return subprocess.run(["git", *args], capture_output=True, text=True, check=check)


# ── 0. Preconditions ─────────────────────────────────────────────────────────
work_tree = git(["rev-parse", "--is-inside-work-tree"], check=False)
if work_tree.returncode != 0 or work_tree.stdout.strip() != "true":
    print("FATAL: check-baseline-monotonic must run inside a git work tree.", file=sys.stderr)
    sys.exit(2)

if not base:
    print("::notice::check-baseline-monotonic: no base ref (no origin/main or main); skipping.")
    sys.exit(0)

if git(["rev-parse", "--verify", "--quiet", f"{base}^{{commit}}"], check=False).returncode != 0:
    print(f"::notice::check-baseline-monotonic: base ref '{base}' does not resolve; skipping.")
    sys.exit(0)

# ── 1. Enumerate debt baselines in the working tree ──────────────────────────
# Debt baselines only: every budgets/*.json, plus any *baseline*.json elsewhere.
# Test-fixture goldens (retrieval replay baselines, snapshots) are NOT debt
# budgets — their numbers legitimately move with the model — so they are skipped.
EXCLUDE_DIRS = ("Fixtures/", "ReplayGoldens/", "__snapshots__/", "node_modules/", ".build/", "vendor/")


def in_scope(path):
    if any(seg in path for seg in EXCLUDE_DIRS):
        return False
    if fnmatch.fnmatch(path, "budgets/*.json"):
        return True
    return fnmatch.fnmatch(os.path.basename(path).lower(), "*baseline*.json")


tracked = git(["ls-files"]).stdout.splitlines()
untracked = git(["ls-files", "--others", "--exclude-standard"]).stdout.splitlines()
present = [p for p in dict.fromkeys(tracked + untracked) if os.path.exists(p)]
baseline_files = sorted(p for p in present if in_scope(p))
baseline_set = set(baseline_files)

# Files that differ from the base (working tree), plus brand-new untracked files.
diff = git(["diff", "--name-only", base, "--"], check=False)
changed = set(diff.stdout.splitlines()) if diff.returncode == 0 else set()
changed |= set(untracked)


# ── 2. Numeric-field walker ──────────────────────────────────────────────────
# Flatten every numeric leaf to a stable path so the same field can be compared
# across revisions. Arrays of objects are keyed by a stable id field (path/file/
# name/id/key) when one is present so reordering never masks a per-entry bump;
# otherwise they fall back to positional indexing.
def numeric_leaves(node, prefix="", out=None):
    if out is None:
        out = {}
    if isinstance(node, bool):
        return out  # bool is an int subclass; never a budget number
    if isinstance(node, (int, float)):
        out[prefix or "<root>"] = node
        return out
    if isinstance(node, dict):
        for key in sorted(node.keys()):
            numeric_leaves(node[key], f"{prefix}.{key}" if prefix else str(key), out)
        return out
    if isinstance(node, list):
        id_field = None
        if node and all(isinstance(e, dict) for e in node):
            for cand in ("path", "file", "name", "id", "key"):
                vals = [e.get(cand) for e in node]
                if all(isinstance(v, str) and v for v in vals) and len(set(vals)) == len(vals):
                    id_field = cand
                    break
        for i, elem in enumerate(node):
            seg = f"[{id_field}={elem[id_field]}]" if id_field is not None else f"[{i}]"
            numeric_leaves(elem, f"{prefix}{seg}", out)
    return out


def load_json(text, where):
    try:
        return json.loads(text)
    except ValueError as exc:
        print(f"::warning::check-baseline-monotonic: {where} is not valid JSON ({exc}); skipping.", file=sys.stderr)
        return None


# ── 3. Compare each baseline's numbers against the base branch ───────────────
increases = []   # (file, field, base_val, cur_val)
decreases = []   # (file, field, base_val, cur_val)
new_fields = []  # (file, field, cur_val) — present now, absent on base
new_files = []   # baseline files absent on base entirely

for bf in baseline_files:
    try:
        cur = load_json(open(bf, encoding="utf-8").read(), bf)
    except OSError as exc:
        print(f"::warning::check-baseline-monotonic: cannot read {bf} ({exc}); skipping.", file=sys.stderr)
        continue
    if cur is None:
        continue
    shown = git(["show", f"{base}:{bf}"], check=False)
    if shown.returncode != 0:
        new_files.append(bf)  # missing at base — allowed, logged below
        continue
    old = load_json(shown.stdout, f"{base}:{bf}")
    if old is None:
        continue
    cur_leaves = numeric_leaves(cur)
    old_leaves = numeric_leaves(old)
    for field, cur_val in cur_leaves.items():
        if field not in old_leaves:
            new_fields.append((bf, field, cur_val))
        elif cur_val > old_leaves[field]:
            increases.append((bf, field, old_leaves[field], cur_val))
        elif cur_val < old_leaves[field]:
            decreases.append((bf, field, old_leaves[field], cur_val))

raised = bool(increases)
raised_files = sorted({f for f, *_ in increases})
non_baseline_changed = sorted(f for f in changed if f not in baseline_set)

# ── 4. Report ────────────────────────────────────────────────────────────────
for bf in new_files:
    print(f"::notice::check-baseline-monotonic: {bf} is new (absent on {base}); allowed.")
for bf, field, cur_val in new_fields:
    print(f"::notice::check-baseline-monotonic: {bf} adds {field}={cur_val} (absent on base); allowed.")
for bf, field, old_val, cur_val in decreases:
    print(f"::notice::check-baseline-monotonic: {bf} {field} dropped {old_val} -> {cur_val} — ratchet locked in.")

failed = False

if raised:
    failed = True
    print("", file=sys.stderr)
    print("::error::check-baseline-monotonic: debt-ratchet baseline(s) were RAISED (they may only shrink):", file=sys.stderr)
    for bf, field, old_val, cur_val in increases:
        print(f"  {bf}: {field} {old_val} -> {cur_val}", file=sys.stderr)
    print("  Raising a baseline in the same PR launders new debt past the ratchet (the 797->800 bypass).", file=sys.stderr)
    print("  Pay the debt down and LOWER the baseline instead; a baseline may only decrease.", file=sys.stderr)

if raised and non_baseline_changed:
    failed = True
    print("", file=sys.stderr)
    print("::error::check-baseline-monotonic: the baseline bump is NOT standalone — it also edits non-baseline files:", file=sys.stderr)
    for f in non_baseline_changed:
        print(f"  {f}", file=sys.stderr)
    print(f"  Raised baseline file(s): {', '.join(raised_files)}", file=sys.stderr)
    print("  Land baseline changes in their own PR so the debt bump is reviewable in isolation.", file=sys.stderr)

if failed:
    sys.exit(1)

if not baseline_files:
    print("✓ check-baseline-monotonic: no debt baselines present.")
elif decreases or new_files or new_fields:
    print(f"✓ check-baseline-monotonic: baselines only shrank or were added vs {base}.")
else:
    print(f"✓ check-baseline-monotonic: {len(baseline_files)} baseline(s) unchanged vs {base} (or note-only edits).")
sys.exit(0)
PY
