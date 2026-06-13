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
# Deps are installed here when absent: this gate runs in lanes (e.g. the
# macOS App XCTest job) that never npm ci these packages themselves, and a
# silent vitest no-op would fail closed as missing evidence.
# (|| true on the runs: the functions package sets global coverage
# thresholds that exit non-zero — this gate consumes the per-line JSON,
# not the global verdict.)
if echo "$changed" | grep -q '^extensions/openburnbar/'; then
    [[ -d "$repo_root/extensions/openburnbar/node_modules" ]] || npm ci --prefix "$repo_root/extensions/openburnbar"
    npm --prefix "$repo_root/extensions/openburnbar" run test:unit -- --coverage 2>/dev/null || true
fi
if echo "$changed" | grep -q '^functions/'; then
    [[ -d "$repo_root/functions/node_modules" ]] || npm ci --prefix "$repo_root/functions"
    bash "$repo_root/scripts/build-signal-envelope-contracts.sh"
    bash "$repo_root/scripts/build-entitlements.sh"
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
repo_root_real = os.path.realpath(repo_root)
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
    package_root = os.path.realpath(os.path.dirname(os.path.dirname(cov_path)))
    with open(cov_path) as fh:
        data = json.load(fh)
    for raw_path, entry in data.items():
        cov_file = raw_path.removeprefix("file://").replace("\\", "/")
        if os.path.isabs(cov_file):
            rel = os.path.relpath(os.path.realpath(cov_file), repo_root_real)
        elif cov_file.startswith(("functions/", "extensions/")):
            rel = cov_file
        else:
            rel = os.path.relpath(os.path.realpath(os.path.join(package_root, cov_file)), repo_root_real)
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

def normalized_code(lines):
    meaningful = []
    in_block_comment = False
    for raw in lines:
        text = raw.strip()
        if in_block_comment:
            if "*/" in text:
                in_block_comment = False
                text = text.split("*/", 1)[1].strip()
            else:
                continue
        if text.startswith("/*"):
            if "*/" in text:
                text = text.split("*/", 1)[1].strip()
            else:
                in_block_comment = True
                continue
        if not text or text.startswith("//") or text.startswith("*"):
            continue
        meaningful.append(text)
    return re.sub(r"\s+", "", "".join(meaningful))

def type_only_lines(path):
    full_path = os.path.join(repo_root, path)
    if not os.path.isfile(full_path):
        return set()
    with open(full_path, encoding="utf-8") as fh:
        lines = fh.read().splitlines()

    excluded = set()
    block_comment = False
    in_type_import = False
    in_type_decl = False
    type_brace_depth = 0

    for idx, raw in enumerate(lines, start=1):
        stripped = raw.strip()

        if block_comment:
            excluded.add(idx)
            if "*/" in stripped:
                block_comment = False
            continue
        if stripped.startswith("/*"):
            excluded.add(idx)
            if "*/" not in stripped:
                block_comment = True
            continue
        if stripped.startswith("//") or stripped.startswith("*"):
            excluded.add(idx)
            continue

        if in_type_import:
            excluded.add(idx)
            if ";" in stripped or re.search(r"\}\s+from\s+", stripped):
                in_type_import = False
            continue

        if in_type_decl:
            excluded.add(idx)
            type_brace_depth += stripped.count("{") - stripped.count("}")
            if type_brace_depth <= 0 and (";" in stripped or "}" in stripped):
                in_type_decl = False
                type_brace_depth = 0
            continue

        if re.match(r"^(import|export)\s+type\b", stripped):
            excluded.add(idx)
            if ";" not in stripped and not re.search(r"\}\s+from\s+", stripped):
                in_type_import = True
            continue

        if re.match(r"^(export\s+)?(interface|type)\s+\w+", stripped):
            excluded.add(idx)
            type_brace_depth = stripped.count("{") - stripped.count("}")
            if stripped.startswith("type ") or stripped.startswith("export type "):
                if ";" not in stripped:
                    in_type_decl = True
            elif type_brace_depth > 0:
                in_type_decl = True
            continue

    return excluded

def runtime_line(text):
    stripped = text.strip()
    if not stripped:
        return False
    if stripped.startswith("//") or stripped.startswith("/*") or stripped.startswith("*"):
        return False
    if stripped in {"{", "}", "};", "});", "};)", ");", ","}:
        return False
    if re.match(r"^(import|export)\s+type\b", stripped):
        return False
    return True

diff_out = subprocess.run(
    ["git", "diff", "-U0", base_ref, "HEAD", "--"] + prod,
    cwd=repo_root, capture_output=True, text=True,
).stdout

hunks_by_file = {}
current = None
current_hunk = None
old_line = 0
new_line = 0
for line in diff_out.splitlines():
    m = re.match(r"^diff --git a/.* b/(.*)$", line)
    if m:
        current = m.group(1)
        hunks_by_file.setdefault(current, [])
        current_hunk = None
        continue
    if current and line.startswith("@@"):
        nm = re.search(r"-(\d+)(?:,\d+)? \+(\d+)(?:,\d+)?", line)
        if nm:
            old_line = int(nm.group(1))
            new_line = int(nm.group(2))
        current_hunk = {"added": [], "removed": []}
        hunks_by_file[current].append(current_hunk)
        continue
    if not current or current_hunk is None or line.startswith("+++") or line.startswith("---"):
        continue
    if line.startswith("+"):
        current_hunk["added"].append((new_line, line[1:]))
        new_line += 1
    elif line.startswith("-"):
        current_hunk["removed"].append(line[1:])
        old_line += 1
    else:
        old_line += 1
        new_line += 1

file_lines = {}
for path in prod:
    excluded = type_only_lines(path)
    executable = set()
    for hunk in hunks_by_file.get(path, []):
        added_text = [text for _, text in hunk["added"]]
        if normalized_code(added_text) == normalized_code(hunk["removed"]):
            continue
        for line_no, text in hunk["added"]:
            if line_no in excluded:
                continue
            if runtime_line(text):
                executable.add(line_no)
    if executable:
        file_lines[path] = executable

prod_with_runtime_changes = [p for p in prod if file_lines.get(p)]
if not prod_with_runtime_changes:
    print(json.dumps({
        "diffCoverage": {
            "percent": 100.0,
            "threshold": threshold,
            "passed": True,
            "changedFiles": len(prod),
            "changedLines": 0,
            "surface": "typescript",
            "method": "no_runtime_ts_lines",
        },
        "details": [],
    }, indent=2))
    raise SystemExit(0)

missing_evidence = [p for p in prod_with_runtime_changes if p not in line_cov]
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

total_exc = 0
total_hit = 0
details = []
for path in prod_with_runtime_changes:
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
        "changedFiles": len(prod_with_runtime_changes),
        "changedLines": total_exc,
        "surface": "typescript",
        "method": "istanbul_line_intersection",
    },
    "details": details,
}, indent=2))
if not passed:
    raise SystemExit(1)
PY
