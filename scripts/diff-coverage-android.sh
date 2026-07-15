#!/usr/bin/env bash
# Diff coverage gate for Android Kotlin changes.
#
# Uses JaCoCo XML reports from Gradle test tasks. Production changes never
# fall back to test-file presence because presence is not coverage evidence.
#
# Usage:
#   diff-coverage-android.sh <base-ref>

set -euo pipefail

default_root="$(cd "$(dirname "$0")/.." && pwd)"
repo_root="${OPENBURNBAR_COVERAGE_REPO_ROOT:-$default_root}"
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

changed_files="$(git diff --name-only --diff-filter=ACMR "$base_ref" HEAD -- '*.kt' 2>/dev/null || true)"
if [[ -z "$changed_files" ]]; then
    echo '{"diffCoverage":{"percent":100.0,"passed":true,"changedFiles":0,"surface":"android","method":"no_kotlin_changes"}}'
    exit 0
fi

production_changed="$(printf '%s\n' "$changed_files" | awk '
  /\/src\/main\// &&
  $0 !~ /^android\/macrobenchmark\// &&
  $0 !~ /^android\/(burnbar-remote|openburnbar-domain-core|openburnbar-iroh-relay)\/src\/main\/java\/uniffi\//
')"
if [[ -z "$production_changed" ]]; then
    echo '{"diffCoverage":{"percent":100.0,"passed":true,"changedFiles":0,"surface":"android","method":"no_production_kotlin"}}'
    exit 0
fi

jacoco_xml="${ANDROID_JACOCO_XML:-$repo_root/android/app/build/reports/jacoco/testDebugUnitTest/jacocoTestReport.xml}"
if [[ ! -f "$jacoco_xml" ]]; then
    echo "::error::JaCoCo report not found at $jacoco_xml. Run :app:jacocoTestReport before gating production Kotlin changes." >&2
    exit 1
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
    ["git", "diff", "--name-only", "--diff-filter=ACMR", base_ref, "HEAD", "--", "*.kt"],
    cwd=repo_root,
    text=True,
).splitlines()
changed = [c.strip() for c in changed if c.strip() and "/src/main/" in c]
# android/macrobenchmark is on-device benchmark tooling (instrumented-only module, no JVM unit-test source set).
changed = [c for c in changed if not c.startswith("android/macrobenchmark/")]
# These three UniFFI trees are generated from Rust APIs and covered by binding drift/ABI gates.
generated_uniffi_prefixes = (
    "android/burnbar-remote/src/main/java/uniffi/",
    "android/openburnbar-domain-core/src/main/java/uniffi/",
    "android/openburnbar-iroh-relay/src/main/java/uniffi/",
)
changed = [c for c in changed if not c.startswith(generated_uniffi_prefixes)]
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

if not changed:
    print(json.dumps({
        "diffCoverage": {
            "percent": 100.0,
            "threshold": threshold,
            "passed": True,
            "changedFiles": 0,
            "changedLines": 0,
            "surface": "android",
            "method": "all_changes_waived",
        },
        "details": [],
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

# Build a package-qualified coverage map. JaCoCo sourcefile names are not
# unique: different packages and modules routinely contain Foo.kt. The
# package/name key must resolve to exactly one changed repo path.
coverage = {}
for package in root.iter("package"):
    package_name = (package.get("name") or "").strip("/")
    for sf in package.iter("sourcefile"):
        name = sf.get("name")
        key = f"{package_name}/{name}" if package_name else name
        if key in coverage:
            print(f"::error::JaCoCo contains duplicate source identity {key!r}.")
            raise SystemExit(1)
        lines = {}
        for line_el in sf.iter("line"):
            ln = int(line_el.get("nr"))
            mi = int(line_el.get("mi", "0"))
            ci = int(line_el.get("ci", "0"))
            if mi + ci > 0:
                lines[ln] = ci > 0
        coverage[key] = lines

def source_identity(rel_path):
    match = re.search(r"/src/main/(?:java|kotlin)/(.*)$", rel_path)
    return match.group(1) if match else None

changed_by_identity = {}
for rel_path in changed:
    identity = source_identity(rel_path)
    if not identity:
        print(f"::error::Cannot derive Kotlin source identity from {rel_path!r}.")
        raise SystemExit(1)
    changed_by_identity.setdefault(identity, []).append(rel_path)

ambiguous = {
    identity: paths
    for identity, paths in changed_by_identity.items()
    if len(paths) != 1
}
if ambiguous:
    print("::error::JaCoCo source identities map to multiple changed repo paths: " + json.dumps(ambiguous, sort_keys=True))
    raise SystemExit(1)

total_exc = 0
total_hit = 0
details = []
missing_evidence = []
for rel_path in changed:
    identity = source_identity(rel_path)
    line_cov = coverage.get(identity)
    changed_lines = set(file_blocks.get(rel_path, []))
    if line_cov is None:
        missing_evidence.append(rel_path)
        details.append({
            "file": rel_path,
            "executableLines": 0,
            "coveredLines": 0,
            "percent": 0.0,
            "method": "no_jacoco_source",
            "sourceIdentity": identity,
        })
        continue
    exc = sum(1 for ln in changed_lines if ln in line_cov)
    hit = sum(1 for ln in changed_lines if line_cov.get(ln))
    pct = round(hit * 100.0 / exc, 2) if exc > 0 else 0.0
    entry = {
        "file": rel_path,
        "executableLines": exc,
        "coveredLines": hit,
        "percent": pct,
        "method": "jacoco_line_intersection",
        "sourceIdentity": identity,
    }
    if changed_lines and exc == 0:
        entry["method"] = "no_changed_line_evidence"
        missing_evidence.append(rel_path)
    total_exc += exc
    total_hit += hit
    details.append(entry)

total_pct = 0.0 if total_exc <= 0 else round(total_hit * 100.0 / total_exc, 2)
passed = not missing_evidence and total_exc > 0 and total_pct >= threshold
print(json.dumps({
    "diffCoverage": {
        "percent": total_pct,
        "threshold": threshold,
        "passed": passed,
        "changedFiles": len(details),
        "changedLines": total_exc,
        "missingEvidenceFiles": len(missing_evidence),
        "surface": "android",
        "method": "jacoco_line_intersection",
    },
    "details": details,
    "missingEvidence": missing_evidence,
    "waived": waived,
}, indent=2))
if not passed:
    raise SystemExit(1)
PY
