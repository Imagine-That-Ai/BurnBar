#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
work_root="$(mktemp -d "${TMPDIR:-/tmp}/openburnbar-ts-diff-coverage-test.XXXXXX")"
trap 'rm -rf "$work_root"' EXIT

make_fake_npm() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/npm" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

prefix=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i += 1)); do
  if [[ "${args[$i]}" == "--prefix" && $((i + 1)) -lt ${#args[@]} ]]; then
    prefix="${args[$((i + 1))]}"
  fi
done

if [[ "$*" == *" test:unit:coverage"* || "$*" == *" test:unit "* ]]; then
  echo "fake npm coverage log line"
  if [[ "${FAKE_NPM_MODE:-success}" == "fail-no-coverage" ]]; then
    exit 42
  fi
  mkdir -p "$prefix/coverage"
  cat > "$prefix/coverage/coverage-final.json" <<JSON
{
  "$prefix/src/example.ts": {
    "statementMap": {
      "0": { "start": { "line": 1 }, "end": { "line": 1 } }
    },
    "s": { "0": 1 }
  }
}
JSON
fi
SH
  chmod +x "$bin_dir/npm"
}

init_case_repo() {
  local repo="$work_root/repo"
  mkdir -p "$repo/scripts" "$repo/functions/src" "$repo/functions/node_modules"
  cp "$repo_root/scripts/diff-coverage-ts.sh" "$repo/scripts/diff-coverage-ts.sh"
  cat > "$repo/scripts/build-signal-envelope-contracts.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
SH
  cat > "$repo/scripts/build-entitlements.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
SH
  chmod +x "$repo/scripts/"*.sh

  (
    cd "$repo"
    git init -q
    git config user.email "ts-coverage-test@example.invalid"
    git config user.name "TS Coverage Test"
    printf 'export function answer() { return 1; }\n' > functions/src/example.ts
    git add .
    git commit -q -m "base"
    printf 'export function answer() { return 2; }\n' > functions/src/example.ts
    git add functions/src/example.ts
    git commit -q -m "runtime change"
  )
  printf '%s\n' "$repo"
}

run_gate() {
  local repo="$1"
  local mode="$2"
  local fake_bin="$work_root/fake-bin"
  make_fake_npm "$fake_bin"
  (
    cd "$repo"
    PATH="$fake_bin:$PATH" FAKE_NPM_MODE="$mode" DIFF_COVERAGE_OUTPUT="$repo/ts-diff-coverage.json" bash scripts/diff-coverage-ts.sh HEAD~1
  )
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'FAIL: %s missing %q\n%s\n' "$label" "$needle" "$haystack" >&2
    exit 1
  fi
}

assert_json_artifact() {
  local path="$1"
  local label="$2"
  python3 - "$path" "$label" <<'PY'
import json
import sys

path, label = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as fh:
    json.load(fh)
print(f"PASS: {label} is JSON-only")
PY
}

repo="$(init_case_repo)"
mkdir -p "$repo/functions/coverage"
cat > "$repo/functions/coverage/coverage-final.json" <<'JSON'
{
  "functions/src/example.ts": {
    "statementMap": {
      "0": { "start": { "line": 1 }, "end": { "line": 1 } }
    },
    "s": { "0": 1 }
  }
}
JSON

if output="$(run_gate "$repo" fail-no-coverage 2>&1)"; then
  printf 'FAIL: stale TypeScript coverage evidence was accepted\n%s\n' "$output" >&2
  exit 1
fi
assert_contains "$output" "istanbul_evidence_missing" "stale coverage rejection"
assert_json_artifact "$repo/ts-diff-coverage.json" "failure diff coverage artifact"

output="$(run_gate "$repo" success 2>&1)"
assert_contains "$output" '"passed": true' "fresh coverage acceptance"
assert_contains "$output" '"method": "istanbul_line_intersection"' "fresh coverage acceptance"
assert_json_artifact "$repo/ts-diff-coverage.json" "success diff coverage artifact"

echo "PASS: TypeScript diff coverage rejects stale evidence"
