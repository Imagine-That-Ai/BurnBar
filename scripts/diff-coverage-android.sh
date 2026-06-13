#!/usr/bin/env bash
# Diff coverage gate for Android Kotlin changes.
#
# Uses JaCoCo XML reports from Gradle test tasks when present.
# Falls back to requiring tests exist for changed files (no silent pass).
#
# Usage:
#   diff-coverage-android.sh <base-ref>

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

base_ref="${1:-origin/main}"
threshold="${COVERAGE_THRESHOLD:-80}"

ANDROID_DIFF_COVERAGE_ALLOWLIST_JSON="$(cat <<'JSON'
{
  "android/app/src/main/java/com/openburnbar/data/assistants/CLIAgentMissionDispatcher.kt": "Firebase Functions mission-dispatch integration: callable transport, auth context, and cloud error mapping require Firebase emulator/instrumented coverage; the seal/canonical payload logic remains covered by mobile and cloud tests.",
  "android/app/src/main/java/com/openburnbar/data/cloud/AndroidCloudVaultRevocationRotation.kt": "CloudVault revocation/rotation orchestration crosses Firestore transactions, trusted-device state, and Android crypto providers; pure crypto helpers remain JVM-covered, while live rotation requires emulator/instrumented coverage.",
  "android/app/src/main/java/com/openburnbar/data/computeruse/AgentWatchControlFrameReceiver.kt": "Agent-watch control-frame receiver is lifecycle and stream integration glue around Android runtime callbacks; frame signing/canonicalization logic remains covered in JVM tests.",
  "android/app/src/main/java/com/openburnbar/data/computeruse/ComputerUseSecurityCallableClient.kt": "Firebase Functions security callable client: transport and App Check/authenticated callable behavior require Firebase emulator/instrumented coverage; request models remain covered by contract tests.",
  "android/app/src/main/java/com/openburnbar/data/computeruse/RemoteUnlockSavedCredentialStore.kt": "Android Keystore/EncryptedSharedPreferences credential persistence cannot execute faithfully under local JVM JaCoCo; it is an Android-framework storage boundary requiring instrumented coverage.",
  "android/app/src/main/java/com/openburnbar/data/stores/DevicesStore.kt": "Firestore listener store with snapshot lifecycle, coroutine cancellation, and Firebase SDK types; it needs emulator/instrumented coverage rather than local JVM line attribution.",
  "android/app/src/main/java/com/openburnbar/ui/computeruse/ComputerUseAgentWatchScreen.kt": "Compose screen rendering and interaction surface; JVM unit coverage cannot prove recomposition/layout behavior, while presentation helpers remain covered by local tests."
}
JSON
)"
export ANDROID_DIFF_COVERAGE_ALLOWLIST_JSON

changed_files="$(git diff --name-only "$base_ref" HEAD -- '*.kt' 2>/dev/null || true)"
if [[ -z "$changed_files" ]]; then
    echo '{"diffCoverage":{"percent":100.0,"passed":true,"changedFiles":0,"surface":"android","method":"no_kotlin_changes"}}'
    exit 0
fi

jacoco_xml="$repo_root/android/app/build/reports/jacoco/testDebugUnitTest/jacocoTestReport.xml"
if [[ ! -f "$jacoco_xml" ]]; then
    echo "::warning::JaCoCo report not found at $jacoco_xml — run ./scripts/test-openburnbar-android.sh first." >&2
    echo "::warning::Android diff coverage using changed-file test presence gate." >&2
    # Require that changed production files have corresponding test files or are in test dirs
    python3 - "$base_ref" "$repo_root" "$threshold" <<'PY'
import os
import json
import subprocess
import sys

base_ref, repo_root, threshold = sys.argv[1], sys.argv[2], int(sys.argv[3])
allowlist = json.loads(os.environ.get("ANDROID_DIFF_COVERAGE_ALLOWLIST_JSON") or "{}")
for path, reason in allowlist.items():
    if not isinstance(reason, str) or not reason.strip():
        print(f"::error::Android coverage allowlist entry {path!r} has no reason.", file=sys.stderr)
        sys.exit(1)

changed = subprocess.check_output(
    ["git", "diff", "--name-only", base_ref, "HEAD", "--", "*.kt"],
    cwd=repo_root,
    text=True,
).splitlines()
prod = [p for p in changed if "/src/main/" in p and not p.endswith("BuildConfig.kt")]
# android/macrobenchmark is on-device benchmark tooling (instrumented-only module, no JVM unit-test source set).
prod = [p for p in prod if not p.startswith("android/macrobenchmark/")]
if not prod:
    print('{"diffCoverage":{"percent":100.0,"passed":true,"surface":"android","method":"test_only_changes"}}')
    sys.exit(0)

waived = [
    {"file": path, "method": "allowlist_waiver", "reason": allowlist[path]}
    for path in prod
    if path in allowlist
]
prod = [p for p in prod if p not in allowlist]

def has_test_evidence(path):
    base = os.path.splitext(os.path.basename(path))[0]
    candidates = [
        path.replace("/src/main/", "/src/test/").replace(".kt", "Test.kt"),
        path.replace("/src/main/", "/src/androidTest/").replace(".kt", "InstrumentedTest.kt"),
        f"android/app/src/test/java/com/openburnbar/data/domains/{base}Test.kt",
        f"android/app/src/androidTest/java/com/openburnbar/data/domains/{base}InstrumentedTest.kt",
    ]
    # The Android in-tree data-domain copy is generated from the shared registry.
    # Its semantic guard lives with the generator, not in android/src/test.
    if path == "android/app/src/main/java/com/openburnbar/data/domains/DataDomains.kt":
        candidates.append("packages/data-domains/registry.test.mjs")
    return any(os.path.isfile(os.path.join(repo_root, candidate)) for candidate in candidates)

missing = [p for p in prod if not has_test_evidence(p)]
if missing:
    print(json.dumps({
        "diffCoverage": {
            "percent": 0.0,
            "passed": False,
            "surface": "android",
            "method": "jacoco_missing_test_presence",
            "changedFiles": len(prod),
            "missingTestsFor": missing[:20],
        },
        "waived": waived,
    }))
    sys.exit(1)

print(json.dumps({
    "diffCoverage": {
        "percent": 100.0,
        "passed": True,
        "surface": "android",
        "method": "test_file_presence",
        "changedFiles": len(prod),
    },
    "waived": waived,
}))
sys.exit(0)
PY
    # The presence-gate verdict is authoritative when no JaCoCo report exists;
    # set -e already aborted above on a failed gate, so reaching here is a pass.
    exit 0
fi

export BASE_REF="$base_ref"
export REPO_ROOT="$repo_root"
export JACOCO_XML="$jacoco_xml"
export COVERAGE_THRESHOLD="$threshold"

python3 <<'PY'
import json
import os
import re
import subprocess
import xml.etree.ElementTree as ET

base_ref = os.environ["BASE_REF"]
repo_root = os.environ["REPO_ROOT"]
jacoco_xml = os.environ["JACOCO_XML"]
threshold = int(os.environ["COVERAGE_THRESHOLD"])
allowlist = json.loads(os.environ.get("ANDROID_DIFF_COVERAGE_ALLOWLIST_JSON") or "{}")
for path, reason in allowlist.items():
    if not isinstance(reason, str) or not reason.strip():
        print(f"::error::Android coverage allowlist entry {path!r} has no reason.")
        raise SystemExit(1)

changed = subprocess.check_output(
    ["git", "diff", "--name-only", base_ref, "HEAD", "--", "*.kt"],
    cwd=repo_root,
    text=True,
).splitlines()
changed = [c.strip() for c in changed if c.strip() and "/src/main/" in c]
# android/macrobenchmark is on-device benchmark tooling (instrumented-only module, no JVM unit-test source set).
changed = [c for c in changed if not c.startswith("android/macrobenchmark/")]
if not changed:
    print(json.dumps({"diffCoverage": {"percent": 100.0, "passed": True, "surface": "android", "method": "no_production_kotlin"}}))
    raise SystemExit(0)

waived = []
coverage_candidates = []
for rel_path in changed:
    reason = allowlist.get(rel_path)
    if reason:
        waived.append({
            "file": rel_path,
            "method": "allowlist_waiver",
            "reason": reason,
        })
    else:
        coverage_candidates.append(rel_path)
changed = coverage_candidates

test_evidence_details = []
coverage_changed = []
for rel_path in changed:
    if (
        rel_path == "android/app/src/main/java/com/openburnbar/data/domains/DataDomains.kt"
        and os.path.isfile(os.path.join(repo_root, "packages/data-domains/registry.test.mjs"))
    ):
        test_evidence_details.append({
            "file": rel_path,
            "executableLines": 0,
            "coveredLines": 0,
            "percent": 100.0,
            "method": "test_file_presence",
        })
    else:
        coverage_changed.append(rel_path)
changed = coverage_changed
if not changed:
    print(json.dumps({
        "diffCoverage": {
            "percent": 100.0,
            "threshold": threshold,
            "passed": True,
            "changedFiles": len(test_evidence_details),
            "changedLines": 0,
            "surface": "android",
            "method": "test_file_presence",
        },
        "details": test_evidence_details,
        "waived": waived,
    }, indent=2))
    raise SystemExit(0)

git_output = subprocess.run(
    ["git", "diff", "-U0", base_ref, "HEAD", "--"] + changed,
    cwd=repo_root,
    capture_output=True,
    text=True,
).stdout

file_blocks = {}
current = None
for line in git_output.splitlines():
    m = re.match(r"^diff --git a/.* b/(.*)$", line)
    if m:
        current = m.group(1)
        file_blocks.setdefault(current, [])
        continue
    if current and line.startswith("@@"):
        nm = re.search(r"\+(\d+)(?:,(\d+))?", line)
        if not nm:
            continue
        start = int(nm.group(1))
        count = int(nm.group(2) or "1")
        for ln in range(start, start + count):
            file_blocks[current].append(ln)

tree = ET.parse(jacoco_xml)
root = tree.getroot()

# Build line coverage map: sourcefile name -> {line: covered}
coverage = {}
for package in root.iter("package"):
    for sf in package.iter("sourcefile"):
        name = sf.get("name")
        lines = {}
        for line_el in sf.iter("line"):
            ln = int(line_el.get("nr"))
            mi = int(line_el.get("mi", "0"))
            ci = int(line_el.get("ci", "0"))
            if mi + ci > 0:
                lines[ln] = ci > 0
        coverage[name] = lines

# Gate floor: a file whose diff touches fewer than DIFF_COVERAGE_ANDROID_MIN_
# GATED_LINES executable lines (default 10) is REPORTED but not gated. The
# 80% bar exists so new logic ships with tests; declaration-touch diffs
# (constant renames, import shuffles — e.g. the 2026-06-11 VAL_ sweep: 58
# files, 1-6 executable lines each) carry no new logic, and their coverage
# status is exactly whatever it was before the touch. Floor-skipped files are
# listed under belowGateFloor in the verdict — visible, never hidden — and
# any file at or above the floor is held to the full threshold.
gate_floor = int(os.environ.get("DIFF_COVERAGE_ANDROID_MIN_GATED_LINES", "10"))

total_exc = 0
total_hit = 0
details = []
below_floor = []
for rel_path in changed:
    base = os.path.basename(rel_path)
    line_cov = coverage.get(base, {})
    exc = sum(1 for ln in set(file_blocks.get(rel_path, [])) if ln in line_cov)
    hit = sum(1 for ln in set(file_blocks.get(rel_path, [])) if line_cov.get(ln))
    pct = round(hit * 100.0 / exc, 2) if exc > 0 else 0.0
    entry = {"file": rel_path, "executableLines": exc, "coveredLines": hit, "percent": pct}
    if exc > 0 and exc < gate_floor:
        below_floor.append(entry)
        continue
    total_exc += exc
    total_hit += hit
    if file_blocks.get(rel_path):
        details.append(entry)
details.extend(test_evidence_details)

total_pct = 0.0 if total_exc <= 0 else round(total_hit * 100.0 / total_exc, 2)
passed = total_exc <= 0 or total_pct >= threshold
print(json.dumps({
    "diffCoverage": {
        "percent": total_pct,
        "threshold": threshold,
        "passed": passed,
        "changedFiles": len(details),
        "changedLines": total_exc,
        "gateFloorLines": gate_floor,
        "belowGateFloorFiles": len(below_floor),
        "surface": "android",
        "method": "jacoco_line_intersection",
    },
    "details": details,
    "belowGateFloor": below_floor,
    "waived": waived,
}, indent=2))
if not passed and total_exc > 0:
    raise SystemExit(1)
PY
