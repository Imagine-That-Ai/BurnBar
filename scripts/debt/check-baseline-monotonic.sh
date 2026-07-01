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
#   • FAILS if any number increased vs base — a baseline may only shrink,
#   • FAILS if a NEW numeric entry appears in an EXISTING baseline file (a
#     grandfathered entry is new debt; only a brand-new baseline FILE may add
#     entries),
#   • FAILS if a baseline number is replaced by a non-number (a stringified "20"
#     would otherwise vanish from the comparison) or is non-finite (NaN/Infinity
#     slip past every `>`/`<` check), and
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
import math
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


# ── 2. Scalar-field walker ───────────────────────────────────────────────────
# Flatten EVERY scalar leaf (numbers, strings, bools, null) to a stable path so
# the same field can be compared across revisions — recording non-numbers too is
# what lets us catch a number that was replaced by a string (a "20" that this
# gate would otherwise drop silently) or by any other non-number. Arrays of
# objects are keyed by a stable id field (path/file/name/id/key) when one is
# present so reordering never masks a per-entry bump; otherwise they fall back to
# positional indexing.
def scalar_leaves(node, prefix="", out=None):
    if out is None:
        out = {}
    if isinstance(node, dict):
        for key in sorted(node.keys()):
            scalar_leaves(node[key], f"{prefix}.{key}" if prefix else str(key), out)
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
            scalar_leaves(elem, f"{prefix}{seg}", out)
        return out
    out[prefix or "<root>"] = node  # scalar leaf: number, str, bool, or None
    return out


def is_budget_number(value):
    # A ratchetable budget number: a real int/float, never a bool (bool is an int
    # subclass). Finiteness is checked separately so NaN/Infinity are REJECTED
    # (a loud failure) rather than silently treated as "not a number".
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def load_json(text, where):
    try:
        return json.loads(text)
    except ValueError as exc:
        print(f"::warning::check-baseline-monotonic: {where} is not valid JSON ({exc}); skipping.", file=sys.stderr)
        return None


# ── 3. Compare each baseline's numbers against the base branch ───────────────
increases = []    # (file, field, base_val, cur_val) — a raise; a baseline may only shrink
decreases = []    # (file, field, base_val, cur_val) — a ratchet-down; allowed
new_fields = []   # (file, field, cur_val) — new numeric leaf in an EXISTING file; REJECTED
type_changes = []  # (file, field, base_val, cur_val) — was a number, now a non-number; REJECTED
nonfinite = []    # (file, field, base_val, cur_val) — NaN/Infinity on either side; REJECTED
new_files = []    # baseline files absent on base entirely — allowed, logged

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
    cur_leaves = scalar_leaves(cur)
    old_leaves = scalar_leaves(old)
    for field in sorted(set(old_leaves) | set(cur_leaves)):
        has_old = field in old_leaves
        has_cur = field in cur_leaves
        old_val = old_leaves.get(field)
        cur_val = cur_leaves.get(field)
        old_num = is_budget_number(old_val)
        cur_num = is_budget_number(cur_val)
        # (f) A NaN/Infinity on either side is malformed debt: NaN slips past
        # every `>`/`<` comparison, so reject it outright before comparing.
        if (old_num and not math.isfinite(old_val)) or (cur_num and not math.isfinite(cur_val)):
            nonfinite.append((bf, field, old_val, cur_val))
            continue
        if has_old and old_num:
            if not has_cur:
                continue  # numeric field removed entirely — debt paid off, allowed
            if not cur_num:
                # (e) Was a number on base, now a non-number (e.g. the string
                # "20"): the ratchet tools may still parse it, so a stringified
                # raise must not vanish. REJECT.
                type_changes.append((bf, field, old_val, cur_val))
            elif cur_val > old_val:
                increases.append((bf, field, old_val, cur_val))
            elif cur_val < old_val:
                decreases.append((bf, field, old_val, cur_val))
        elif cur_num:
            # (d) A numeric leaf ABSENT on base but present now in an EXISTING
            # baseline file is new grandfathered debt. Only a brand-new baseline
            # FILE (handled above via new_files) may introduce entries. REJECT.
            new_fields.append((bf, field, cur_val))

# A new numeric entry in an existing baseline is a debt raise for the purpose of
# the standalone rule, exactly like a bumped number.
raised = bool(increases) or bool(new_fields)
raised_files = sorted({f for f, *_ in increases} | {f for f, *_ in new_fields})
non_baseline_changed = sorted(f for f in changed if f not in baseline_set)

# ── 4. Report ────────────────────────────────────────────────────────────────
for bf in new_files:
    print(f"::notice::check-baseline-monotonic: {bf} is new (absent on {base}); allowed.")
for bf, field, old_val, cur_val in decreases:
    print(f"::notice::check-baseline-monotonic: {bf} {field} dropped {old_val} -> {cur_val} — ratchet locked in.")

failed = False

if increases:
    failed = True
    print("", file=sys.stderr)
    print("::error::check-baseline-monotonic: debt-ratchet baseline(s) were RAISED (they may only shrink):", file=sys.stderr)
    for bf, field, old_val, cur_val in increases:
        print(f"  {bf}: {field} {old_val} -> {cur_val}", file=sys.stderr)
    print("  Raising a baseline in the same PR launders new debt past the ratchet (the 797->800 bypass).", file=sys.stderr)
    print("  Pay the debt down and LOWER the baseline instead; a baseline may only decrease.", file=sys.stderr)

if new_fields:
    failed = True
    print("", file=sys.stderr)
    print("::error::check-baseline-monotonic: NEW entries were added to an EXISTING debt baseline (only a brand-new baseline file may introduce entries):", file=sys.stderr)
    for bf, field, cur_val in new_fields:
        print(f"  {bf}: {field} = {cur_val} (absent on base)", file=sys.stderr)
    print("  Seeding a grandfathered entry into an existing baseline launders new debt past the ratchet.", file=sys.stderr)
    print("  Remove the entry and pay the debt; do not pre-fund it in the baseline.", file=sys.stderr)

if type_changes:
    failed = True
    print("", file=sys.stderr)
    print("::error::check-baseline-monotonic: baseline number(s) were replaced by a non-number (a stringified value hides the raise):", file=sys.stderr)
    for bf, field, old_val, cur_val in type_changes:
        print(f"  {bf}: {field} {old_val!r} -> {cur_val!r}", file=sys.stderr)
    print("  Keep budget fields as JSON numbers so the ratchet can compare them; a string like \"20\" is not a budget.", file=sys.stderr)

if nonfinite:
    failed = True
    print("", file=sys.stderr)
    print("::error::check-baseline-monotonic: non-finite baseline number(s) (NaN/Infinity) are not valid budgets:", file=sys.stderr)
    for bf, field, old_val, cur_val in nonfinite:
        print(f"  {bf}: {field} {old_val!r} -> {cur_val!r}", file=sys.stderr)
    print("  NaN slips past every monotonicity comparison; use a finite integer budget.", file=sys.stderr)

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
elif decreases or new_files:
    print(f"✓ check-baseline-monotonic: baselines only shrank or were added vs {base}.")
else:
    print(f"✓ check-baseline-monotonic: {len(baseline_files)} baseline(s) unchanged vs {base} (or note-only edits).")
sys.exit(0)
PY
