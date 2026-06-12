#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
results_dir="${OPENBURNBAR_QA_RESULTS_DIR:-$repo_root/qa-results}"
logs_dir="$results_dir/logs"
report_path="$results_dir/report.md"
summary_path="$results_dir/summary.json"
env_probe_path="$results_dir/environment-probe.txt"

mkdir -p "$logs_dir"

rows=()
json_entries=()
failures=0
skips=0

json_escape() {
  python3 - "$1" <<'PY'
import json
import sys
print(json.dumps(sys.argv[1]))
PY
}

add_result() {
  local test_case="$1"
  local app="$2"
  local persona="$3"
  local status="$4"
  local notes="$5"
  local marker

  case "$status" in
    PASS)
      marker=":white_check_mark: PASS"
      ;;
    SKIPPED)
      marker=":warning: SKIPPED"
      skips=$((skips + 1))
      ;;
    *)
      marker=":x: FAIL"
      failures=$((failures + 1))
      ;;
  esac

  rows+=("| $(( ${#rows[@]} + 1 )) | ${test_case} | ${app} | ${persona} | ${marker} | ${notes} |")
  json_entries+=(
    "{\"testCase\":$(json_escape "$test_case"),\"app\":$(json_escape "$app"),\"persona\":$(json_escape "$persona"),\"status\":$(json_escape "$status"),\"notes\":$(json_escape "$notes")}"
  )
}

require_env() {
  local name="$1"
  [[ -n "${!name:-}" ]]
}

write_environment_probe() {
  {
    echo "OpenBurnBar functional QA environment probe"
    echo "timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    echo "repo_root=$repo_root"
    echo "git_head=$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || echo unknown)"
    echo
    echo "tooling:"
    for tool in node npm tuistory xcodebuild droid; do
      if command -v "$tool" >/dev/null 2>&1; then
        printf "  %s=present (%s)\n" "$tool" "$(command -v "$tool")"
      else
        printf "  %s=missing\n" "$tool"
      fi
    done
    if [[ -x /usr/libexec/PlistBuddy ]]; then
      echo "  PlistBuddy=present (/usr/libexec/PlistBuddy)"
    else
      echo "  PlistBuddy=missing"
    fi
    echo
    echo "secrets:"
    for secret in FACTORY_API_KEY FIREBASE_PLIST_BASE64 FIREBASE_APP_CHECK_DEBUG_TOKEN QA_FIREBASE_EMAIL QA_FIREBASE_PASSWORD ANTHROPIC_API_KEY; do
      if require_env "$secret"; then
        printf "  %s=set\n" "$secret"
      else
        printf "  %s=unset\n" "$secret"
      fi
    done
  } > "$env_probe_path"
}

run_logged() {
  local test_case="$1"
  local app="$2"
  local persona="$3"
  local notes="$4"
  local log_name="$5"
  shift 5

  local log_path="$logs_dir/$log_name"
  echo "Running: $*" > "$log_path"
  if (cd "$repo_root" && "$@") >> "$log_path" 2>&1; then
    add_result "$test_case" "$app" "$persona" "PASS" "$notes Log: qa-results/logs/$log_name."
  else
    local exit_code=$?
    add_result "$test_case" "$app" "$persona" "FAIL" "Command exited ${exit_code}. Log: qa-results/logs/$log_name."
  fi
}

write_report() {
  local verdict
  if [[ "$failures" -gt 0 ]]; then
    verdict="Functional QA found ${failures} failing required check(s)."
  elif [[ "$skips" -gt 0 ]]; then
    verdict="Functional QA passed required checks with ${skips} optional check(s) skipped."
  else
    verdict="Functional QA passed all required checks."
  fi

  {
    echo "## QA Report"
    echo
    echo "| # | Test Case | App | Persona | Result | Notes |"
    echo "|---|-----------|-----|---------|--------|-------|"
    for row in "${rows[@]}"; do
      echo "$row"
    done
    echo
    echo "### Summary"
    echo
    echo "$verdict"
    echo
    echo "### What was verified"
    echo
    echo "- Firebase/App Check CI config can be decoded, validated, and injected into the macOS and iOS resource plists without printing secret values."
    echo "- Dedicated QA auth credentials are present for authenticated flows."
    echo "- Extension operator flows execute through the real extension unit and extension-host smoke surface."
    echo "- Environment evidence is attached at \`qa-results/environment-probe.txt\` and command logs are under \`qa-results/logs/\`."
    echo
    echo "<details>"
    echo "<summary>Screenshots & Evidence</summary>"
    echo
    echo "No screenshots are expected for this deterministic CI smoke. The extension-host run exercises a live temporary workspace through the VS Code extension host."
    echo
    echo "\`\`\`text"
    sed 's/`/'"'"'/g' "$env_probe_path"
    echo "\`\`\`"
    echo
    echo "</details>"
  } > "$report_path"

  {
    echo "{"
    echo "  \"failures\": $failures,"
    echo "  \"skips\": $skips,"
    echo "  \"results\": ["
    local index=0
    local total=${#json_entries[@]}
    for entry in "${json_entries[@]}"; do
      index=$((index + 1))
      if [[ "$index" -lt "$total" ]]; then
        echo "    $entry,"
      else
        echo "    $entry"
      fi
    done
    echo "  ]"
    echo "}"
  } > "$summary_path"
}

write_environment_probe

missing_required=()
for env_name in FACTORY_API_KEY FIREBASE_PLIST_BASE64 FIREBASE_APP_CHECK_DEBUG_TOKEN QA_FIREBASE_EMAIL QA_FIREBASE_PASSWORD; do
  if ! require_env "$env_name"; then
    missing_required+=("$env_name")
  fi
done

if [[ "${#missing_required[@]}" -eq 0 ]]; then
  add_result "Required QA credential preflight" "qa" "operator" "PASS" "Required CI-only QA credentials are present; values are intentionally not logged."
else
  add_result "Required QA credential preflight" "qa" "operator" "FAIL" "Missing required environment variable(s): ${missing_required[*]}. Values were not logged."
fi

if require_env ANTHROPIC_API_KEY; then
  add_result "Provider-backed deep agent flow readiness" "agent/Hermes" "operator" "PASS" "ANTHROPIC_API_KEY is present for provider-backed follow-up flows."
else
  add_result "Provider-backed deep agent flow readiness" "agent/Hermes" "operator" "SKIPPED" "ANTHROPIC_API_KEY is not set; deterministic CI smoke does not require it."
fi

if require_env FIREBASE_PLIST_BASE64 && require_env FIREBASE_APP_CHECK_DEBUG_TOKEN; then
  run_logged \
    "Firebase/App Check config injection" \
    "macOS+iOS app" \
    "qa-auth" \
    "Decoded and injected Firebase plist plus App Check debug token into app resources." \
    "firebase-config.log" \
    bash scripts/ci/inject-firebase-config.sh
else
  add_result "Firebase/App Check config injection" "macOS+iOS app" "qa-auth" "FAIL" "FIREBASE_PLIST_BASE64 and FIREBASE_APP_CHECK_DEBUG_TOKEN are required for this check."
fi

if [[ -d "$repo_root/extensions/openburnbar/node_modules" ]]; then
  add_result "Extension dependency readiness" "extension" "operator" "PASS" "extensions/openburnbar/node_modules exists from the workflow install step."
else
  run_logged \
    "Extension dependency readiness" \
    "extension" \
    "operator" \
    "Installed extension dependencies for QA smoke." \
    "extension-npm-ci.log" \
    npm --prefix extensions/openburnbar ci
fi

run_logged \
  "Extension mission parity and operator convergence" \
  "VS Code extension" \
  "operator" \
  "Ran assertion-tagged unit tests and extension-host workspace integration." \
  "extension-host-smoke.log" \
  bash scripts/test-openburnbar-extension-host.sh

write_report

if [[ "$failures" -gt 0 ]]; then
  echo "Functional QA failed. See $report_path"
  exit 1
fi

echo "Functional QA passed. See $report_path"
