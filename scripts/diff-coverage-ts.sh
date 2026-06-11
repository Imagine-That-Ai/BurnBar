#!/usr/bin/env bash
# Diff coverage gate for TypeScript changes in functions/ and extensions/.
#
# Usage:
#   diff-coverage-ts.sh <base-ref>

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

base_ref="${1:-origin/main}"
threshold="${COVERAGE_THRESHOLD:-80}"

changed="$(git diff --name-only "$base_ref" HEAD -- 'functions/src/**/*.ts' 'extensions/openburnbar/src/**/*.ts' 2>/dev/null || true)"
if [[ -z "$changed" ]]; then
    echo '{"diffCoverage":{"percent":100.0,"passed":true,"surface":"typescript","method":"no_ts_changes"}}'
    exit 0
fi

# Produce real coverage for whichever packages have changed production TS.
# (|| true: the functions package sets global coverage thresholds that exit
# non-zero — this gate consumes the per-line JSON, not the global verdict.)
if echo "$changed" | grep -q '^extensions/openburnbar/'; then
    npm --prefix "$repo_root/extensions/openburnbar" run test:unit -- --coverage 2>/dev/null || true
fi
if echo "$changed" | grep -q '^functions/'; then
    npm --prefix "$repo_root/functions" run test:unit:coverage >/dev/null 2>&1 || true
fi

export BASE_REF="$base_ref"
export REPO_ROOT="$repo_root"
export COVERAGE_THRESHOLD="$threshold"

python3 <<'PY'
import json
import os
import re
import subprocess

base_ref = os.environ["BASE_REF"]
repo_root = os.environ["REPO_ROOT"]
threshold = int(os.environ["COVERAGE_THRESHOLD"])

patterns = ["functions/src/**/*.ts", "extensions/openburnbar/src/**/*.ts"]
changed = []
for pattern in patterns:
    changed.extend(subprocess.check_output(
        ["git", "diff", "--name-only", base_ref, "HEAD", "--", pattern],
        cwd=repo_root,
        text=True,
    ).splitlines())
changed = sorted(set(c.strip() for c in changed if c.strip() and not c.endswith(".d.ts")))

if not changed:
    print(json.dumps({"diffCoverage": {"percent": 100.0, "passed": True, "surface": "typescript"}}))
    raise SystemExit(0)

# Real evidence: istanbul/v8 coverage JSON from the vitest runs above. A
# stem-matched test FILE was never evidence (shared.ts is covered by
# feature-named suites like stripeWebhookOrdering.test.ts and read 0% under
# presence matching) — see DILIGENCE_REPORT_2026-06-11 finding CG-1.
coverage_paths = [
    os.path.join(repo_root, "functions", "coverage", "coverage-final.json"),
    os.path.join(repo_root, "extensions", "openburnbar", "coverage", "coverage-final.json"),
]
line_cov = {}
for cov_path in coverage_paths:
    if not os.path.isfile(cov_path):
        continue
    with open(cov_path) as fh:
        data = json.load(fh)
    for abs_path, entry in data.items():
        rel = os.path.relpath(abs_path, repo_root)
        per_line = line_cov.setdefault(rel, {})
        smap = entry.get("statementMap", {})
        counts = entry.get("s", {})
        for sid, loc in smap.items():
            start = loc.get("start", {}).get("line")
            end = loc.get("end", {}).get("line", start)
            if start is None:
                continue
            hit = int(counts.get(sid, 0)) > 0
            for ln in range(start, (end or start) + 1):
                per_line[ln] = per_line.get(ln, False) or hit

prod = [p for p in changed if "/test/" not in p and "__tests__" not in p
        and not p.endswith(".test.ts") and not p.endswith(".spec.ts")]
if not prod:
    print(json.dumps({"diffCoverage": {"percent": 100.0, "passed": True,
        "surface": "typescript", "method": "tests_only_diff"}}))
    raise SystemExit(0)

missing_evidence = [p for p in prod if p not in line_cov]
if missing_evidence:
    print(json.dumps({
        "diffCoverage": {
            "percent": 0.0,
            "passed": False,
            "threshold": threshold,
            "surface": "typescript",
            "method": "istanbul_evidence_missing",
            "missingEvidenceFor": missing_evidence[:20],
        },
    }, indent=2))
    raise SystemExit(1)

diff_out = subprocess.run(
    ["git", "diff", "-U0", base_ref, "HEAD", "--"] + prod,
    cwd=repo_root, capture_output=True, text=True,
).stdout
file_lines = {}
current = None
for line in diff_out.splitlines():
    m = re.match(r"^diff --git a/.* b/(.*)$", line)
    if m:
        current = m.group(1)
        file_lines.setdefault(current, set())
        continue
    if current and line.startswith("@@"):
        nm = re.search(r"\+(\d+)(?:,(\d+))?", line)
        if nm:
            start = int(nm.group(1))
            count = int(nm.group(2) or "1")
            file_lines[current].update(range(start, start + count))

total_exc = 0
total_hit = 0
details = []
for path in prod:
    cov = line_cov.get(path, {})
    exc = sum(1 for ln in file_lines.get(path, set()) if ln in cov)
    hit = sum(1 for ln in file_lines.get(path, set()) if cov.get(ln))
    total_exc += exc
    total_hit += hit
    details.append({"file": path, "executableLines": exc, "coveredLines": hit,
                    "percent": round(hit * 100.0 / exc, 2) if exc else 100.0})

total_pct = 100.0 if total_exc == 0 else round(total_hit * 100.0 / total_exc, 2)
passed = total_pct >= threshold
print(json.dumps({
    "diffCoverage": {
        "percent": total_pct,
        "threshold": threshold,
        "passed": passed,
        "changedFiles": len(prod),
        "changedLines": total_exc,
        "surface": "typescript",
        "method": "istanbul_line_intersection",
    },
    "details": details,
}, indent=2))
if not passed:
    raise SystemExit(1)
PY
