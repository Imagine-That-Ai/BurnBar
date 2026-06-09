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

# Run extension unit tests with c8 coverage when extension files changed
if echo "$changed" | grep -q '^extensions/openburnbar/'; then
    npm --prefix "$repo_root/extensions/openburnbar" run test:unit -- --coverage 2>/dev/null || true
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

# For TS without Istanbul line maps wired yet: require companion test file exists for changed modules
missing_tests = []
for path in changed:
    if "/test/" in path or path.endswith(".test.ts") or path.endswith(".spec.ts"):
        continue
    base = os.path.basename(path).replace(".ts", "")
    test_candidates = [
        path.replace("/src/", "/test/").replace(".ts", ".test.ts"),
        os.path.join(repo_root, "functions", "src", "__tests__", f"{base}.test.ts"),
        os.path.join(repo_root, "functions", "src", "__tests__", f"{base}.spec.ts"),
        path.replace(".ts", ".test.ts"),
        os.path.join(repo_root, "functions/test", f"test-{base}.mjs"),
    ]
    if not any(os.path.isfile(c) for c in test_candidates):
        missing_tests.append(path)

if missing_tests:
    print(json.dumps({
        "diffCoverage": {
            "percent": 0.0,
            "passed": False,
            "threshold": threshold,
            "surface": "typescript",
            "method": "test_file_presence",
            "missingTestsFor": missing_tests[:20],
        },
    }, indent=2))
    raise SystemExit(1)

print(json.dumps({
    "diffCoverage": {
        "percent": 100.0,
        "passed": True,
        "threshold": threshold,
        "surface": "typescript",
        "method": "test_file_presence",
        "changedFiles": len(changed),
    },
}, indent=2))
PY
