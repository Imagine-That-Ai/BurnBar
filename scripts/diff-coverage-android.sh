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
  "android/app/src/main/java/com/openburnbar/BurnBarApplication.kt": "Android Application lifecycle composition: Firebase, WorkManager, media wiring, and process startup require framework/instrumented coverage; extracted registries and route/controller logic remain JVM-covered. Firebase App Check provider selection is additionally fail-closed through BuildConfig.DEBUG and verified by release compilation, artifact inspection, and Firebase contract tests.",
  "android/app/src/main/java/com/openburnbar/BurnBarApplicationMediaControlSections.kt": "Application-level media-control wiring crosses Android services and retained process state; unit-testable transport/coordinator logic remains covered separately.",
  "android/app/src/main/java/com/openburnbar/BurnBarApplicationStartupSections.kt": "Application startup orchestration depends on Android process lifecycle, Firebase initialization, and notification/service registration; owned helpers remain covered by focused JVM tests.",
  "android/app/src/main/java/com/openburnbar/MainActivityE2EComputerUseActions.kt": "Debug E2E activity hooks are Android intent/UI glue exercised by instrumented flows, not local JVM line attribution.",
  "android/app/src/main/java/com/openburnbar/MainActivityE2EComputerUseStreamSetup.kt": "Debug E2E stream setup is Android activity/intent integration glue; protocol and transport behavior remain covered by JVM/unit tests.",
  "android/app/src/main/java/com/openburnbar/MainActivity.kt": "Living Themes adds Android deep-link activity routing at the host lifecycle boundary; URI parsing and fallback selection are isolated in LivingThemeIntent and covered by JVM tests, while Activity launch dispatch requires instrumented coverage.",
  "android/app/src/main/java/com/openburnbar/data/budget/BudgetNotificationCenter.kt": "Android notification/PendingIntent presentation boundary: redacted notification content is JVM-covered by BudgetNotificationCenterTest, while explicit-intent construction and NotificationManager delivery require framework/instrumented coverage.",
  "android/app/src/main/java/com/openburnbar/data/assistants/CLIAgentMissionDispatcher.kt": "Firebase Functions mission-dispatch integration: callable transport, auth context, and cloud error mapping require Firebase emulator/instrumented coverage; the seal/canonical payload logic remains covered by mobile and cloud tests.",
  "android/app/src/main/java/com/openburnbar/data/cloud/AndroidCloudVaultRevocationRotation.kt": "CloudVault revocation/rotation orchestration crosses Firestore transactions, trusted-device state, and Android crypto providers; pure crypto helpers remain JVM-covered, while live rotation requires emulator/instrumented coverage.",
  "android/app/src/main/java/com/openburnbar/data/computeruse/AgentWatchControlFrameReceiver.kt": "Agent-watch control-frame receiver is lifecycle and stream integration glue around Android runtime callbacks; frame signing/canonicalization logic remains covered in JVM tests.",
  "android/app/src/main/java/com/openburnbar/data/computeruse/ComputerUseSecurityCallableClient.kt": "Firebase Functions security callable client: transport and App Check/authenticated callable behavior require Firebase emulator/instrumented coverage; request models remain covered by contract tests.",
  "android/app/src/main/java/com/openburnbar/data/computeruse/ComputerUseSessionGrantNotificationCenter.kt": "Android notification/PendingIntent presentation boundary: challenge validation and receiver behavior are JVM-covered, while notification manager delivery requires framework/instrumented coverage.",
  "android/app/src/main/java/com/openburnbar/data/computeruse/ForegroundFragmentActivityTracker.kt": "FragmentActivity foreground tracking depends on Android lifecycle callbacks; call sites and foreground gating are covered through receiver/registrar tests and instrumented UI flows.",
  "android/app/src/main/java/com/openburnbar/data/computeruse/RemoteUnlockSavedCredentialStore.kt": "Android Keystore/EncryptedSharedPreferences credential persistence cannot execute faithfully under local JVM JaCoCo; it is an Android-framework storage boundary requiring instrumented coverage.",
  "android/app/src/main/java/com/openburnbar/data/hermes/relay/HermesCompositeRelayTransport.kt": "Composite relay selection is integration glue over Firestore/iroh transports; the concrete iroh transport and retained-pool behavior remain covered by JVM tests.",
  "android/app/src/main/java/com/openburnbar/data/models/generated/IrohPairingModels.kt": "Generated schema mirror from shared pairing contracts; source-of-truth drift is guarded by schema sync and consumer contract tests rather than local line coverage.",
  "android/app/src/main/java/com/openburnbar/data/stores/AccountStore.kt": "FirebaseAuth-backed singleton access boundary; behavior depends on Firebase SDK runtime and is covered by higher-level account lifecycle tests.",
  "android/app/src/main/java/com/openburnbar/data/stores/AuthStore.kt": "FirebaseAuth-backed singleton access boundary; behavior depends on Firebase SDK runtime and is covered by higher-level auth lifecycle tests.",
  "android/app/src/main/java/com/openburnbar/data/stores/DevicesStore.kt": "Firestore listener store with snapshot lifecycle, coroutine cancellation, and Firebase SDK types; it needs emulator/instrumented coverage rather than local JVM line attribution.",
  "android/app/src/main/java/com/openburnbar/data/stores/UserStore.kt": "Firestore/Firebase user-store singleton access boundary; behavior depends on Firebase SDK runtime and is covered by higher-level account lifecycle tests.",
  "android/app/src/main/java/com/openburnbar/menubar/MenuBarService.kt": "Foreground Service notification boundary: explicit-component tap PendingIntents and NotificationManager delivery are Android framework entry points that local JVM JaCoCo cannot execute; instrumented flows exercise the live notification.",
  "android/app/src/main/java/com/openburnbar/menubar/MenuBarTileService.kt": "Quick Settings TileService is an Android framework entry point; tile lifecycle and the explicit launch PendingIntent require instrumented coverage.",
  "android/app/src/main/java/com/openburnbar/services/media/MediaSessionForegroundService.kt": "Foreground media Service notification boundary: CallStyle notification and explicit launch PendingIntent construction require framework/instrumented coverage.",
  "android/app/src/main/java/com/openburnbar/services/media/MercuryFcmService.kt": "FirebaseMessagingService push entry point: incoming-call full-screen notification and explicit accept/decline PendingIntent construction require framework/instrumented coverage.",
  "android/app/src/main/java/com/openburnbar/services/media/MercuryFcmServiceSupport.kt": "FCM notification presentation glue: agent-reply Intent/NotificationCompat/RemoteInput construction depends on Android framework types unavailable to local JVM JaCoCo, and thread/call routing resolution requires the Firebase SDK runtime; delivery is exercised through instrumented push flows.",
  "android/app/src/main/java/com/openburnbar/ui/computeruse/ComputerUseAgentWatchScreen.kt": "Compose screen rendering and interaction surface; JVM unit coverage cannot prove recomposition/layout behavior, while presentation helpers remain covered by local tests.",
  "android/app/src/main/java/com/openburnbar/ui/hermes/AssistantsScreen.kt": "Compose navigation/rendering wrapper; local JVM coverage cannot prove recomposition/layout, while backing stores and formatting helpers are tested.",
  "android/app/src/main/java/com/openburnbar/ui/hermes/HermesView.kt": "Compose navigation/rendering wrapper; local JVM coverage cannot prove recomposition/layout, while backing stores and formatting helpers are tested.",
  "android/app/src/main/java/com/openburnbar/ui/media/PairedMacControlsScreenSections.kt": "Compose rendering section for paired-device controls; interaction/layout coverage belongs to instrumented UI, while transport/control models remain unit-tested.",
  "android/app/src/main/java/com/openburnbar/ui/media/PairedMacControlsScreenSupport.kt": "Compose/UI support layer for paired-device controls; presentation behavior requires instrumented UI coverage and model/control logic remains JVM-covered.",
  "android/app/src/main/java/com/openburnbar/ui/media/ScreenShareViewerScreenMainSections.kt": "Compose screen-share viewer effect glue: auto-type open/close decisions are extracted into ScreenShareAutoTypeFollowPolicy and JVM-covered by ScreenShareAutoTypeFollowPolicyTest; the remaining LaunchedEffect recomposition/state wiring requires instrumented Compose coverage (ScreenShareViewerDockTest).",
  "android/app/src/main/java/com/openburnbar/ui/media/ScreenShareViewerScreenSections.kt": "Compose screen-share viewer rendering sections: remote-keyboard dismiss decisions are extracted into shouldDismissRemoteKeyboardCapture and JVM-covered; IME visibility via WindowInsets.isImeVisible and LaunchedEffect wiring need a real window, so they require instrumented Compose coverage (ScreenShareViewerDockTest).",
  "android/app/src/main/java/com/openburnbar/ui/navigation/BurnBarNavHost.kt": "Compose navigation host wiring; route graph rendering requires instrumented UI coverage, while route selection helpers are covered separately.",
  "android/app/src/main/java/com/openburnbar/ui/navigation/BurnBarNavHostSections.kt": "Compose navigation section wiring; route graph rendering requires instrumented UI coverage, while route selection helpers are covered separately.",
  "android/app/src/main/java/com/openburnbar/ui/pulse/PulseViewSections.kt": "Compose rendering wrapper; local JVM coverage cannot prove recomposition/layout, while backing data and formatting helpers are tested.",
  "android/app/src/main/java/com/openburnbar/ui/square/HermesSquareScreenSections.kt": "Compose rendering wrapper; local JVM coverage cannot prove recomposition/layout, while backing data and formatting helpers are tested.",
  "android/openburnbar-iroh-relay/src/main/java/com/openburnbar/irohrelay/Generated/HermesRealtimeRelayGeneratedTypes.kt": "Generated relay schema mirror from shared Hermes wire contracts; drift is covered by schema/vector tests and consumers rather than local line attribution.",
  "android/openburnbar-iroh-relay/src/main/java/com/openburnbar/irohrelay/OpenBurnBarIrohFfiBridge.kt": "Reflection bridge over the optional UniFFI native AAR; availability and fallback are covered by transport tests, while real UniFFI calls require native AAR/instrumented coverage.",
  "android/app/src/main/java/com/openburnbar/ui/components/MobileKernelBackdrop.kt": "Compose Canvas backdrop rendering depends on Android graphics and frame-clock behavior; catalog identity and selection logic remain JVM-covered, while pixel output and recomposition require screenshot or instrumented coverage.",
  "android/app/src/main/java/com/openburnbar/ui/computeruse/ComputerUseAgentWatchScreen.kt": "Compose screen rendering and interaction surface; JVM unit coverage cannot prove recomposition/layout behavior, while presentation helpers remain covered by local tests.",
  "android/app/src/main/java/com/openburnbar/ui/settings/SettingsRootScreenThemeSections.kt": "Settings integration is a Compose navigation and rendering boundary; catalog order and persisted kernel resolution are JVM-covered, while click routing and layout require instrumented Compose coverage.",
  "android/app/src/main/java/com/openburnbar/wallpaper/livingthemes/LivingThemePreviewView.kt": "TextureView surface lifecycle and GLES renderer ownership require a real Android SurfaceTexture; theme and FPS contracts are JVM-covered, while pause, resize, and release behavior require instrumented coverage.",
  "android/app/src/main/java/com/openburnbar/wallpaper/livingthemes/LivingThemeWallpaperService.kt": "WallpaperService engine visibility and surface callbacks are Android framework entry points unavailable to local JVM tests; selection parsing is JVM-covered and service rendering is verified on physical Android hardware.",
  "android/app/src/main/java/com/openburnbar/wallpaper/livingthemes/LivingThemesActivity.kt": "Living Themes is a Compose Activity that launches the system wallpaper picker; catalog and deep-link contracts are JVM-covered, while layout, ActivityManager capability checks, and system intent recovery require instrumented coverage.",
  "android/app/src/main/java/com/openburnbar/wallpaper/livingthemes/ShaderKernelRenderer.kt": "EGL, GLES3 shader compilation, Android asset loading, and native-window swap behavior require a device graphics driver and cannot execute under local JVM JaCoCo; all 42 shader assets are contract-verified and compiled on physical Android hardware."
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
  $0 != "android/app/src/main/java/com/openburnbar/ui/tokens/PensieveTokens.kt" &&
  $0 !~ /^android\/(burnbar-remote|openburnbar-domain-core|openburnbar-iroh-relay)\/src\/main\/java\/uniffi\//
')"
if [[ -z "$production_changed" ]]; then
    echo '{"diffCoverage":{"percent":100.0,"passed":true,"changedFiles":0,"surface":"android","method":"no_production_kotlin"}}'
    exit 0
fi

jacoco_xmls=()
jacoco_xml_env="${ANDROID_JACOCO_XMLS:-${ANDROID_JACOCO_XML:-}}"
if [[ -n "$jacoco_xml_env" ]]; then
    IFS=':' read -r -a jacoco_xmls <<< "$jacoco_xml_env"
else
    while IFS= read -r report; do
        jacoco_xmls+=("$report")
    done < <(find "$repo_root/android" -path '*/build/reports/jacoco/testDebugUnitTest/jacocoTestReport.xml' -type f | sort)
fi
if [[ "${#jacoco_xmls[@]}" -eq 0 ]]; then
    echo "::error::No JaCoCo reports found. Run affected Android module jacocoTestReport tasks before gating production Kotlin changes." >&2
    exit 1
fi
for jacoco_xml in "${jacoco_xmls[@]}"; do
    if [[ ! -f "$jacoco_xml" ]]; then
        echo "::error::JaCoCo report not found at $jacoco_xml. Run affected Android module jacocoTestReport tasks before gating production Kotlin changes." >&2
        exit 1
    fi
done
jacoco_xmls_joined="$(IFS=:; printf '%s' "${jacoco_xmls[*]}")"

export BASE_REF="$base_ref"
export REPO_ROOT="$repo_root"
export JACOCO_XMLS="$jacoco_xmls_joined"
export COVERAGE_THRESHOLD="$threshold"

python3 <<'PY'
import json
import os
import re
import subprocess
import xml.etree.ElementTree as ET

base_ref = os.environ["BASE_REF"]
repo_root = os.environ["REPO_ROOT"]
jacoco_xmls = [p for p in os.environ["JACOCO_XMLS"].split(os.pathsep) if p]
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
# Style Dictionary owns this exact compile-time-constant file; token drift gates
# validate the generator output, while JaCoCo cannot instrument const vals.
generated_source_paths = {
    "android/app/src/main/java/com/openburnbar/ui/tokens/PensieveTokens.kt",
}
changed = [c for c in changed if c not in generated_source_paths]
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

# Build a package-qualified coverage map. JaCoCo sourcefile names are not
# unique: different packages and modules routinely contain Foo.kt. The
# package/name key must resolve to exactly one changed repo path.
coverage = {}
for jacoco_xml in jacoco_xmls:
    tree = ET.parse(jacoco_xml)
    root = tree.getroot()
    for package in root.iter("package"):
        package_name = (package.get("name") or "").strip("/")
        for sf in package.iter("sourcefile"):
            name = sf.get("name")
            key = f"{package_name}/{name}" if package_name else name
            lines = coverage.setdefault(key, {})
            for line_el in sf.iter("line"):
                ln = int(line_el.get("nr"))
                mi = int(line_el.get("mi", "0"))
                ci = int(line_el.get("ci", "0"))
                if mi + ci > 0:
                    lines[ln] = lines.get(ln, False) or ci > 0

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
    # A deletion-only diff (no added lines in the -U0 hunk) has zero
    # executable lines to cover.  Report it as deletion_only and skip
    # the JaCoCo lookup — there is nothing to instrument or attest.
    if not changed_lines:
        details.append({
            "file": rel_path,
            "executableLines": 0,
            "coveredLines": 0,
            "percent": 100.0,
            "method": "deletion_only",
            "sourceIdentity": identity,
        })
        continue
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
# When every changed file is deletion-only (total_exc == 0) there are no
# executable lines to gate; the run passes trivially as long as no file
# is missing evidence.
passed = not missing_evidence and (total_exc > 0 and total_pct >= threshold or total_exc == 0)
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
