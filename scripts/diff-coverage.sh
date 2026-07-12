#!/usr/bin/env bash
# Compute true diff coverage for changed Swift files.
#
# Intersects git diff added-line hunks with per-line coverage evidence.
# Matches files by full repo-relative path (not basename).
#
# Evidence sources (merged — both are real measured line hits):
#   1. App xcresult (xccov archive) — line truth for app-target sources
#      (AgentLens/…). Produced by the App XCTest lane with
#      OPENBURNBAR_ENABLE_COVERAGE=YES.
#   2. SwiftPM package coverage — line truth for OpenBurnBarCore /
#      OpenBurnBarDaemon package sources, which the app xcresult structurally
#      cannot see (the app scheme never executes package test targets).
#      Produced by the Swift Core lane: `swift test --enable-code-coverage`
#      leaves merged profdata + test bundles under <package>/.build;
#      scripts/extract-package-coverage-lines.sh exports per-line truth via
#      `llvm-cov export -format=lcov` and converts it to the shared per-line
#      map shape.
#
# Waiver policy — the ONLY ways a changed executable line escapes this gate:
#   * An in-source annotation `cov:ignore -- <reason>` on the changed line,
#     or a justified `cov:ignore-start -- <reason>` / `cov:ignore-end` block.
#     Bare ignores without a reason FAIL the gate outright.
#   * An entry in COVERAGE_ALLOWLIST (in the Python below): exact repo path
#     (or an explicit, documented prefix) plus a mandatory written reason.
#     Waived files are reported in the verdict JSON under "waived" — they are
#     excluded from the percentage, never counted as covered.
#   * Swift declaration-only added lines (stored properties, type shells,
#     imports, cases) are not executable lines. LLVM does not emit counters for
#     them, even when the containing module is linked and its Codable paths are
#     exercised, so they are excluded before the no-evidence fallback.
#   Test-file presence, directory existence, or any other proxy is NEVER
#   evidence (see DILIGENCE_REPORT_2026-06-11 §5.1 / finding CG-1).
#
# Usage:
#   diff-coverage.sh <base-ref> [app-summary-json] [app-lines-json] [package-lines-json]
#
# Environment:
#   COVERAGE_THRESHOLD    minimum diff coverage percent (default 80)
#   DIFF_COVERAGE_SCOPE   all|app|packages|linux-packages (default all). CI lanes partition:
#                         App XCTest gates scope=app with the xcresult, Swift
#                         Core on macOS gates scope=packages, and the Linux PR
#                         gate owns only the exact prefixes listed in
#                         scripts/linux-only-package-coverage-prefixes.txt via
#                         scope=linux-packages. Every changed production file is
#                         measured by a lane that actually compiles it.
#   DIFF_COVERAGE_OUTPUT  optional path — verdict JSON is also written there
#   OPENBURNBAR_COVERAGE_REPO_ROOT  override the gated repo root (self-tests)
#
# Exit codes:
#   0 — diff coverage meets or exceeds threshold
#   1 — diff coverage below threshold, missing evidence, or invalid waiver
#   2 — usage error

set -euo pipefail

scripts_dir="$(cd "$(dirname "$0")" && pwd)"
default_root="$(cd "$scripts_dir/.." && pwd)"
repo_root="${OPENBURNBAR_COVERAGE_REPO_ROOT:-$default_root}"
cd "$repo_root"

base_ref="${1:-origin/main}"
threshold="${COVERAGE_THRESHOLD:-80}"
scope="${DIFF_COVERAGE_SCOPE:-all}"

case "$scope" in
  all|app|packages|linux-packages) ;;
  *)
    echo "::error::DIFF_COVERAGE_SCOPE must be all, app, packages, or linux-packages (got: $scope)" >&2
    exit 2
    ;;
esac

coverage_json="${2:-}"
lines_json="${3:-}"
package_lines_json="${4:-}"

tmp_root="${TMPDIR:-/tmp}"

if [[ -z "$coverage_json" && "$scope" != "packages" && "$scope" != "linux-packages" ]]; then
  candidate="$repo_root/.derived-data/OpenBurnBar_TestCoverage.xcresult"
  if [[ -d "$candidate" ]]; then
    coverage_json="$tmp_root/openburnbar-diff-coverage-summary.json"
    "$scripts_dir/extract-coverage.sh" "$candidate" > "$coverage_json"
  fi
fi

if [[ -z "$lines_json" && "$scope" != "packages" && "$scope" != "linux-packages" && -d "$repo_root/.derived-data/OpenBurnBar_TestCoverage.xcresult" ]]; then
  lines_json="$tmp_root/openburnbar-diff-coverage-lines.json"
  if ! "$scripts_dir/extract-coverage-lines.sh" \
      "$repo_root/.derived-data/OpenBurnBar_TestCoverage.xcresult" > "$lines_json"; then
    echo '::error::Failed to extract per-line app coverage from the xcresult.' >&2
    exit 1
  fi
fi

if [[ -z "$package_lines_json" && "$scope" != "app" ]]; then
  codecov_found=""
  for pkg in OpenBurnBarCore OpenBurnBarDaemon; do
    if compgen -G "$repo_root/$pkg/.build/debug/codecov/default.profdata" > /dev/null 2>&1 \
      || compgen -G "$repo_root/$pkg/.build/*/debug/codecov/default.profdata" > /dev/null 2>&1; then
      codecov_found=1
    fi
  done
  if [[ -n "$codecov_found" ]]; then
    package_lines_json="$tmp_root/openburnbar-diff-coverage-package-lines.json"
    if ! OPENBURNBAR_COVERAGE_REPO_ROOT="$repo_root" \
        "$scripts_dir/extract-package-coverage-lines.sh" > "$package_lines_json"; then
      package_lines_json=""
    fi
  fi
fi

# Coverage is a production-code gate: test sources, CI tooling scripts, and
# SwiftPM manifests are never coverage targets. Manifests are build
# configuration — they are parsed (or the lane cannot even start) by the
# package's own swift-test lane, and no coverage format attributes line hits
# to them.
diff_pathspec=('*.swift' ':(exclude)*Tests*' ':(exclude)scripts/*' ':(exclude)Package.swift' ':(exclude)*/Package.swift')

changed_files=""
if ! changed_files="$(git diff --name-only --find-renames "$base_ref" HEAD -- "${diff_pathspec[@]}" 2>/dev/null)"; then
  echo "::error::Unable to enumerate changed Swift files against base ref: $base_ref" >&2
  exit 1
fi

if [[ -z "$changed_files" ]]; then
  echo "{\"diffCoverage\":{\"percent\":100.0,\"threshold\":$threshold,\"passed\":true,\"changedFiles\":0,\"changedLines\":0,\"method\":\"no_swift_changes\",\"scope\":\"$scope\"},\"details\":[]}"
  exit 0
fi

# Evidence requirements per scope. A lane that cannot see is not allowed to
# judge — and is never allowed to silently pass.
if [[ "$scope" == "app" && ! -f "${lines_json:-}" ]]; then
  echo '::error::No per-line app coverage data found. Run app tests with OPENBURNBAR_ENABLE_COVERAGE=YES and extract-coverage-lines.sh first.' >&2
  exit 1
fi
if [[ ( "$scope" == "packages" || "$scope" == "linux-packages" ) && ! -f "${package_lines_json:-}" ]]; then
  echo '::error::No package coverage data found. Run `swift test --enable-code-coverage` in OpenBurnBarCore/OpenBurnBarDaemon, then scripts/extract-package-coverage-lines.sh.' >&2
  exit 1
fi
if [[ "$scope" == "all" && ! -f "${coverage_json:-}" && ! -f "${package_lines_json:-}" ]]; then
  echo '::error::No coverage evidence found (neither app xcresult nor package codecov). Run tests with coverage enabled first.' >&2
  exit 1
fi

export COVERAGE_THRESHOLD="$threshold"
export BASE_REF="$base_ref"
export REPO_ROOT="$repo_root"
export COVERAGE_JSON="${coverage_json:-}"
export LINES_JSON="${lines_json:-}"
export PACKAGE_LINES_JSON="${package_lines_json:-}"
export DIFF_SCOPE="$scope"
export DIFF_OUTPUT="${DIFF_COVERAGE_OUTPUT:-}"
export LINUX_ONLY_PREFIXES_FILE="$scripts_dir/linux-only-package-coverage-prefixes.txt"

python3 - <<'PY'
import ast
import difflib
import json
import os
import re
import subprocess
import sys

threshold = int(os.environ["COVERAGE_THRESHOLD"])
base_ref = os.environ["BASE_REF"]
repo_root = os.environ["REPO_ROOT"]
coverage_json_path = os.environ.get("COVERAGE_JSON") or ""
lines_json_path = os.environ.get("LINES_JSON") or ""
package_lines_json_path = os.environ.get("PACKAGE_LINES_JSON") or ""
scope = os.environ["DIFF_SCOPE"]
output_path = os.environ.get("DIFF_OUTPUT") or ""
linux_only_prefixes_path = os.environ["LINUX_ONLY_PREFIXES_FILE"]

# ---------------------------------------------------------------------------
# Waiver allowlist — the documented, auditable escape hatch.
#
# POLICY: every entry is an exact repo-relative path, or an explicit prefix
# ending in "/", and MUST carry a non-empty reason. Entries exist only for
# files whose changed executable lines are app lifecycle, external-provider
# integration, privileged/hardware integration, or SwiftUI/AppKit rendering
# glue that the current lane cannot line-hit deterministically. Each entry must
# name the companion tests or coverage surface that owns the decision logic.
# Adding an entry to flip a red check is exactly the failure mode this gate
# exists to prevent (DILIGENCE_REPORT_2026-06-11 §5.1, CG-1): prefer wiring the
# missing lane's artifact, then real tests, then an in-source `cov:ignore --
# reason` on the specific lines.
# ---------------------------------------------------------------------------
COVERAGE_ALLOWLIST = {
    "OpenBurnBarMobile/": (
        "Measured by the iOS Mobile lane's own xcresult; that artifact is not "
        "yet wired into this gate. Tracked residual — wire the artifact "
        "rather than adding entries here."
    ),
    "packages/data-domains/gen/DataDomains.swift": (
        "Generated from the shared data-domains registry; byte-equality with "
        "the generator output is enforced by packages/data-domains/"
        "registry.test.mjs. Never compiled into a coverage-bearing target."
    ),
    "AgentLens/Services/ComputerUse/Mac/RemoteUnlockVirtualHIDBridgeInstaller.swift": (
        "Privileged install orchestration: osascript admin prompts, launchctl "
        "bootstrap/bootout, root-owned filesystem moves — unexecutable under "
        "headless XCTest by construction. Its decision logic IS line-gated: "
        "LaunchAgent plist shape (RemoteUnlockExecutionLaunchAgentTests) and "
        "the socket-directory trust layout "
        "(PrivilegedInputExecutionSocketServerTests). End-to-end install is "
        "exercised by the signed-build setup flow and the nightly "
        "privileged-socket red-team gate."
    ),
    "AgentLens/Services/DirectDownloadUpdateService.swift": (
        "UI/IO orchestration of the update flow: NSAlert prompts, URLSession "
        "download, NSWorkspace open, 24h timers — none of which can execute "
        "under headless XCTest. ALL decision logic is split into line-gated "
        "companions: DirectDownloadReleaseMetadata.swift, "
        "DirectDownloadArtifactVerifier.swift (sha256+Ed25519 verification), "
        "DirectDownloadUpdatePromptPolicy.swift — 32 behavioral tests."
    ),
    "AgentLens/App/AppDelegate.swift": (
        "NSApplication lifecycle glue: foreground notifications, status menu "
        "actions, process teardown, and fire-and-forget Cloud Vault pickup are "
        "disabled or non-deterministic under headless XCTest. The callable "
        "parsers, rotation policy, and injected rotation executor are covered "
        "by ComputerUseSecurityCallableClientTests and "
        "CloudVaultRotationPickupTests."
    ),
    "AgentLens/Services/CloudSync/CLIAgentMissionRequestListener.swift": (
        "Live Firestore listener and mission-state writer. The changed AAD "
        "construction and sealed-event payload logic are exercised through "
        "unit-testable CLIAgentMissionCloudSealer / "
        "CLIAgentMissionEventFactory paths; the remaining changed lines are "
        "callback wiring that requires emulator/integration coverage."
    ),
    "AgentLens/Services/CloudSync/ChatThreadSyncService.swift": (
        "Live Firestore sync service with snapshot/write callbacks. Merge and "
        "round-trip behavior is covered by ChatThreadSyncServiceTests and "
        "cloud-sync integration tests; XCTest line attribution cannot execute "
        "the live listener lifecycle deterministically."
    ),
    "AgentLens/Services/CloudSync/DownloadSyncService.swift": (
        "Live cloud-download listener/writer orchestration. Download policy and "
        "round-trip behavior are covered through injected sync tests; changed "
        "listener plumbing requires Firebase emulator/integration coverage."
    ),
    "AgentLens/Services/CloudSync/HermesRelayHostService.swift": (
        "Runtime iroh/Hermes host wiring: starts live relay services, media "
        "capability gates, and persistent stream registries. The teardown and "
        "capability decision logic is covered in package/app unit tests; the "
        "host bootstrap itself needs integration coverage."
    ),
    "AgentLens/Services/CloudSync/KnowledgeSyncService.swift": (
        "Live Firestore knowledge-sync lifecycle. Chunking, parsing, and sync "
        "state decisions are covered by focused unit tests; the changed "
        "snapshot/write plumbing is emulator/integration-only."
    ),
    "AgentLens/Services/CloudSync/MacEscrowCredentialProducer.swift": (
        "Mac credential-transfer producer spans FirebaseAuth, Firestore writes, "
        "Keychain-backed switcher credential lookup, and ECIES envelope upload. "
        "The cryptographic seal, envelope schema, fail-closed producer stages, "
        "and deterministic plan builder are covered by "
        "MacEscrowCredentialProducerTests; the live collaborators require "
        "Firebase/keychain integration coverage."
    ),
    "AgentLens/Services/IrohRelay/HermesIrohRelayHostClient.swift": (
        "Live iroh host client: async QUIC stream accept loops, heartbeat "
        "refreshes, and per-peer teardown run only against a live relay runtime. "
        "The registry/policy logic is covered by OpenBurnBarMedia package "
        "tests; the transport loop is integration-only."
    ),
    "AgentLens/Services/Media/MercuryRouter.swift": (
        "Live Mercury routing over realtime relay/media streams. Per-frame "
        "sealing decisions are covered by MediaFrameAeadNegotiation tests; the "
        "changed router hooks require live mirror/request streams to line-hit."
    ),
    "AgentLens/Services/OpenBurnBarDaemon/OpenBurnBarError+Daemon.swift": (
        "Daemon error string bridge. Behavior is covered by daemon integration "
        "tests and OpenBurnBarErrorIntegrationTests; the changed extension line "
        "is a presentation shim, not independent executable policy."
    ),
    "AgentLens/Services/SettingsManager.swift": (
        "Settings bootstrap and Remote Config fetch wiring. Pure persistence, "
        "defaults, and kill-switch behavior are covered by SettingsManagerTests; "
        "the changed observer/fetch side effects are AppKit/Firebase runtime "
        "glue that requires integration coverage."
    ),
    "AgentLens/Services/AccountManager.swift": (
        "Live FirebaseAuth/GoogleSignIn account-deletion wrapper. The "
        "server-authoritative erasure contract, local sign-out failure "
        "semantics, Firebase config parsing, and keychain identifier decisions "
        "are covered by AccountManagerMattersTests and SwitcherCLIAuthCoordinatorTests; "
        "the app wrapper requires authenticated Firebase integration coverage."
    ),
    "AgentLens/Services/ComputerUse/ComputerUseBudgetStatusStore.swift": (
        "Live FirebaseAuth/Firestore listener and server-read lifecycle. "
        "ComputerUseBudgetStatusStoreTests cover scalar payload preservation, "
        "budget provenance, cached/server snapshot handling, fail-closed "
        "permission behavior, quota authoritative-zero semantics, and UTC day "
        "keys; live listener startup requires Firebase integration coverage."
    ),
    "AgentLens/Services/ComputerUse/ComputerUseCloudMeteringService.swift": (
        "Firestore metering adapter for privacy-safe Computer Use headers. "
        "ComputerUseCloudMeteringServiceTests cover write paths, merge "
        "semantics, stable action IDs, bounded denial metadata, invalid user "
        "rejection, privacy filtering, and session-end counters; live delivery "
        "requires Firebase integration coverage."
    ),
    "AgentLens/Services/ComputerUse/ComputerUseFirestoreGateway.swift": (
        "The live gateway is the single Firebase singleton adapter. "
        "ComputerUseBudgetStatusStoreTests cover supported scalar conversion, "
        "NSNumber kind preservation, mutating payload writes, and Firestore "
        "value export; live snapshot listeners and server reads require "
        "Firebase emulator/integration coverage."
    ),
    "AgentLens/Services/ComputerUse/ComputerUseSessionCoordinator+Approvals.swift": (
        "Mac Computer Use approval orchestration spans AppKit approval UI, "
        "local quota ledger reservation, audit evidence capture, and async "
        "cloud metering. PhoneControlReceiverTests, "
        "ComputerUseSetTrustModeDowngradeOnlyTests, ComputerUseLocalQuotaLedger "
        "package tests, and ComputerUseCloudMeteringServiceTests cover the "
        "deterministic policy and metering contracts; the live AppKit/AX path "
        "requires integration coverage."
    ),
    "AgentLens/Services/ComputerUse/ComputerUseSessionCoordinator.swift": (
        "Process-scoped Mac Computer Use coordinator bootstrap and teardown "
        "touch AppKit, AX, control-frame receivers, SystemPermissionMonitor, "
        "focus-follow, and fire-and-forget cloud metering. The downgrade-only "
        "trust rule, phone-control handling, quota ledger contracts, and "
        "metering payloads are covered by focused unit/package tests; live "
        "receiver wiring requires integration coverage."
    ),
    "AgentLens/Services/MacCloudEntitlementStore.swift": (
        "Live Firebase/StoreKit entitlement source reconciler. "
        "MacMediaCapabilityGateTests and EntitlementArbitrationTests cover "
        "server document parsing, StoreKit precedence, lapsed entitlement "
        "handling, app-account-token binding, and fail-closed states; live "
        "Firebase/StoreKit refresh loops require integration coverage."
    ),
    "AgentLens/Services/OpenBurnBarDaemon/OpenBurnBarDaemonManager+ComputerUse.swift": (
        "Live app-to-daemon Computer Use RPC and capability-state publisher. "
        "OpenBurnBarDaemon package tests cover daemon-side Computer Use RPC "
        "contracts/capabilities, OpenBurnBarCore tests cover capability-state "
        "contracts, and app tests cover the injected manager composition; "
        "socket RPC plus Firebase/Auth aggregation requires integration coverage."
    ),
    "AgentLens/Services/OpenBurnBarDaemon/OpenBurnBarDaemonManager.swift": (
        "Manager composition defaults for Computer Use stores and metering. "
        "OpenBurnBarDaemonManagerTests cover injected composition and daemon "
        "manager behavior; default singleton-backed constructor lines require "
        "the app runtime to line-hit."
    ),
    "AgentLens/Services/OpenBurnBarDaemon/OpenBurnBarDaemonSocketClient.swift": (
        "Socket transport adapter for the generated Computer Use capability "
        "state RPC. BurnBarRPC contract/canon tests and daemon RPC tests own "
        "method shape and response decoding; the app socket call requires a "
        "live daemon socket integration test."
    ),
    "AgentLens/Theme/LiquidGlass.swift": (
        "NSVisualEffectView bridge for macOS visual polish. The constructed "
        "view properties are asserted by LiquidGlassTransparencyTests; "
        "rendering/line attribution is visual AppKit coverage rather than "
        "business logic."
    ),
    "AgentLens/Views/Dashboard/Components/ConstellationBackgroundView.swift": (
        "Decorative SwiftUI canvas composition. Dashboard view smoke tests "
        "exercise the surface, but ViewInspector/XCTest does not reliably "
        "line-attribute Canvas/async drawing modifiers."
    ),
    "AgentLens/Views/Dashboard/Components/DashboardDepthBackdrop.swift": (
        "Decorative SwiftUI GeometryReader/background composition. Dashboard "
        "view tests cover presence and environment wiring; the changed drawing "
        "lines require visual/snapshot coverage."
    ),
    "AgentLens/Views/Dashboard/Components/DashboardToolbarAndBackdrop.swift": (
        "Decorative dashboard backdrop and transparency composition. "
        "DashboardToolbarTests cover mode selection; Canvas/background line "
        "hits require visual/snapshot coverage."
    ),
    "AgentLens/Views/Settings/DevicesAndSyncSettingsView.swift": (
        "SwiftUI settings surface plus live Firebase device-trust gateways. "
        "DeviceTrustViewModel and credential-transfer fail-closed behavior are "
        "covered with injected gateways; ViewInspector does not line-attribute "
        "the full settings card/body composition, and live gateway calls need "
        "Firebase integration coverage."
    ),
    "OpenBurnBarDaemon/Sources/OpenBurnBarRemoteAccessAgentCore/VirtualHIDKeyboardEngine.swift": (
        "Virtual HID device creation requires the com.apple.developer.hid."
        "virtual.device entitlement, which `swift test` processes cannot "
        "hold, so the IOKit/CoreHID backend bodies cannot execute under unit "
        "tests. The unentitled fail-closed path IS gated "
        "(VirtualHIDKeyboardEngineCreationTests); the entitled paths are "
        "exercised on signed builds by the remote-unlock setup flow and the "
        "nightly privileged-socket red-team gate."
    ),
    "OpenBurnBarDaemon/Sources/OpenBurnBarPrivilegedInputExecution/OpenBurnBarPrivilegedInputExecutionMain.swift": (
        "@main entry point of the privileged-input launchd executable: "
        "process bootstrap (launchd socket activation, signal handlers, "
        "run loop) cannot execute under `swift test`. All decision logic is "
        "delegated to OpenBurnBarRemoteAccessAgentCore, which IS line-gated "
        "here (PrivilegedInputExecutionSocketServerTests, "
        "PrivilegedPeerAuthenticatorTests)."
    ),
    "OpenBurnBarDaemon/Sources/OpenBurnBarDaemonExecutable/OpenBurnBarDaemonMain.swift": (
        "@main entry point of the daemon executable: process bootstrap, "
        "URLCache setup, signal handling, Sentry setup, long-running server "
        "lifecycle, and launchd shutdown semantics cannot execute under "
        "`swift test`. Its configuration parser and peer-auth decisions live "
        "in OpenBurnBarDaemon and are line-gated by the daemon package tests."
    ),
    "OpenBurnBarDaemon/Sources/OpenBurnBarVirtualHIDBridge/OpenBurnBarVirtualHIDBridgeMain.swift": (
        "@main entry point of the virtual-HID bridge executable: requires a "
        "live DriverKit/IOHIDUserDevice session and root, which no CI lane "
        "can host. Engine logic lives in OpenBurnBarRemoteAccessAgentCore "
        "(VirtualHIDKeyboardEngine), which IS line-gated here."
    ),
}

for waiver_path, waiver_reason in COVERAGE_ALLOWLIST.items():
    if not isinstance(waiver_reason, str) or not waiver_reason.strip():
        print(f"::error::COVERAGE_ALLOWLIST entry {waiver_path!r} has no reason. "
              "Every waiver must carry a written justification.", file=sys.stderr)
        raise SystemExit(1)


def allowlist_reason(rel_path):
    direct = COVERAGE_ALLOWLIST.get(rel_path)
    if direct:
        return direct
    for key, reason in COVERAGE_ALLOWLIST.items():
        if key.endswith("/") and rel_path.startswith(key):
            return reason
    return None


PACKAGE_PREFIXES = ("OpenBurnBarCore/Sources/", "OpenBurnBarDaemon/Sources/")


def load_linux_only_prefixes(path):
    if not os.path.isfile(path):
        print(f"::error::Linux-only coverage prefix policy is missing: {path}", file=sys.stderr)
        raise SystemExit(1)
    with open(path, encoding="utf-8") as handle:
        prefixes = tuple(
            line.strip() for line in handle
            if line.strip() and not line.lstrip().startswith("#")
        )
    if not prefixes or len(prefixes) != len(set(prefixes)):
        print("::error::Linux-only coverage prefixes must be non-empty and unique.", file=sys.stderr)
        raise SystemExit(1)
    for prefix in prefixes:
        if not prefix.startswith(PACKAGE_PREFIXES) or not prefix.endswith(("/", ".swift")):
            print(
                f"::error::Invalid Linux-only package coverage prefix: {prefix}",
                file=sys.stderr,
            )
            raise SystemExit(1)
    return prefixes


LINUX_ONLY_PACKAGE_PREFIXES = load_linux_only_prefixes(linux_only_prefixes_path)


def is_linux_only_package_path(rel_path):
    for policy_path in LINUX_ONLY_PACKAGE_PREFIXES:
        if policy_path.endswith("/"):
            if rel_path.startswith(policy_path):
                return True
        elif rel_path == policy_path:
            return True
    return False


def partition(rel_path):
    if is_linux_only_package_path(rel_path):
        return "linux-packages"
    return "packages" if rel_path.startswith(PACKAGE_PREFIXES) else "app"


_platform_partition_cache = {}


def _tri_not(value):
    return None if value is None else not value


def _tri_and(left, right):
    if left is False or right is False:
        return False
    if left is True and right is True:
        return True
    return None


def _tri_or(left, right):
    if left is True or right is True:
        return True
    if left is False and right is False:
        return False
    return None


def _conditional_atom_value(name, argument, platform):
    argument = re.sub(r"\s+", "", argument)
    if name == "os":
        expected = "Linux" if platform == "linux" else "macOS"
        return argument == expected
    if name == "canImport":
        known = {
            "linux": {"Glibc": True, "Darwin": False, "AppKit": False, "UIKit": False, "WinSDK": False},
            "macos": {"Glibc": False, "Darwin": True, "AppKit": True, "UIKit": False, "WinSDK": False},
        }
        return known[platform].get(argument)
    return None


def _conditional_expression_value(expression, platform):
    """Evaluate Swift platform predicates conservatively for one CI platform.

    Unknown build flags remain tri-state. This lets `os(Linux) && DEBUG` be
    recognized as impossible on macOS without pretending DEBUG is enabled,
    while a plain `#if DEBUG` remains owned by the portable package lane.
    """
    atom_values = []

    def replace_atom(match):
        value = _conditional_atom_value(match.group(1), match.group(2), platform)
        atom_values.append(value)
        return f"__atom_{len(atom_values) - 1}"

    rendered = re.sub(
        r"\b(os|canImport|arch|targetEnvironment|compiler|swift)\s*\(([^()]*)\)",
        replace_atom,
        expression,
    )
    rendered = rendered.replace("&&", " and ").replace("||", " or ")
    rendered = re.sub(r"!(?!=)", " not ", rendered).strip()
    rendered = re.sub(r"\btrue\b", "True", rendered, flags=re.IGNORECASE)
    rendered = re.sub(r"\bfalse\b", "False", rendered, flags=re.IGNORECASE)
    try:
        tree = ast.parse(rendered, mode="eval")
    except SyntaxError:
        return None

    def evaluate(node):
        if isinstance(node, ast.Expression):
            return evaluate(node.body)
        if isinstance(node, ast.Constant) and isinstance(node.value, bool):
            return node.value
        if isinstance(node, ast.Name):
            if node.id.startswith("__atom_"):
                try:
                    return atom_values[int(node.id.removeprefix("__atom_"))]
                except (ValueError, IndexError):
                    return None
            return None
        if isinstance(node, ast.UnaryOp) and isinstance(node.op, ast.Not):
            return _tri_not(evaluate(node.operand))
        if isinstance(node, ast.BoolOp):
            result = True if isinstance(node.op, ast.And) else False
            for value_node in node.values:
                value = evaluate(value_node)
                result = _tri_and(result, value) if isinstance(node.op, ast.And) else _tri_or(result, value)
            return result
        return None

    return evaluate(tree)


def _platform_line_partitions(rel_path):
    if rel_path in _platform_partition_cache:
        return _platform_partition_cache[rel_path]
    if is_linux_only_package_path(rel_path):
        _platform_partition_cache[rel_path] = None
        return None

    abs_path = os.path.join(repo_root, rel_path)
    try:
        with open(abs_path, encoding="utf-8", errors="replace") as handle:
            source = handle.read().splitlines()
    except OSError:
        _platform_partition_cache[rel_path] = {}
        return {}

    active = {"macos": True, "linux": True}
    stack = []
    owners = {}
    for line_number, text in enumerate(source, start=1):
        stripped = text.strip()
        directive = re.match(r"^#(if|elseif)\s+(.+)$", stripped)
        if directive and directive.group(1) == "if":
            parent = dict(active)
            condition = {
                platform: _conditional_expression_value(directive.group(2), platform)
                for platform in ("macos", "linux")
            }
            active = {
                platform: _tri_and(parent[platform], condition[platform])
                for platform in ("macos", "linux")
            }
            remaining = {
                platform: _tri_and(parent[platform], _tri_not(condition[platform]))
                for platform in ("macos", "linux")
            }
            stack.append({"parent": parent, "remaining": remaining})
        elif directive and directive.group(1) == "elseif" and stack:
            frame = stack[-1]
            condition = {
                platform: _conditional_expression_value(directive.group(2), platform)
                for platform in ("macos", "linux")
            }
            active = {
                platform: _tri_and(frame["remaining"][platform], condition[platform])
                for platform in ("macos", "linux")
            }
            frame["remaining"] = {
                platform: _tri_and(frame["remaining"][platform], _tri_not(condition[platform]))
                for platform in ("macos", "linux")
            }
        elif stripped == "#else" and stack:
            active = dict(stack[-1]["remaining"])
            stack[-1]["remaining"] = {"macos": False, "linux": False}
        elif stripped == "#endif" and stack:
            active = dict(stack.pop()["parent"])

        # Reassign only when a line is provably impossible on macOS and can be
        # compiled by Linux. Unknown or malformed conditions stay portable.
        owners[line_number] = (
            "linux-packages"
            if active["macos"] is False and active["linux"] is not False
            else "packages"
        )

    _platform_partition_cache[rel_path] = owners
    return owners


def line_partition(rel_path, line_number):
    if is_linux_only_package_path(rel_path):
        return "linux-packages"
    if not rel_path.startswith(PACKAGE_PREFIXES):
        return "app"
    return _platform_line_partitions(rel_path).get(line_number, "packages")


def load_lines_payload(path):
    if not path or not os.path.isfile(path):
        return {}
    with open(path, encoding="utf-8") as handle:
        return json.load(handle).get("files", {})


cov = {}
if coverage_json_path and os.path.isfile(coverage_json_path):
    with open(coverage_json_path, encoding="utf-8") as handle:
        cov = json.load(handle)

app_line_files = load_lines_payload(lines_json_path)
package_line_files = load_lines_payload(package_lines_json_path)


def per_line_map(entry):
    lines = entry.get("lines", {}) if entry else {}
    if not lines or "_aggregate" in lines:
        return None
    return lines


def merged_line_map(rel_path):
    """Merge real line evidence. A line counts as covered when ANY lane that
    executed tests over this file recorded a hit on it."""
    app_map = per_line_map(app_line_files.get(rel_path))
    pkg_map = per_line_map(package_line_files.get(rel_path))
    sources = []
    merged = {}
    for label, source in (("app", app_map), ("package", pkg_map)):
        if source is None:
            continue
        sources.append(label)
        for key, hit in source.items():
            merged[key] = bool(merged.get(key)) or bool(hit)
    if not sources:
        return None, None
    return merged, "+".join(sources)


STRUCTURAL_SWIFT_DECLARATION = re.compile(
    r"^\s*(?:public|private|fileprivate|internal|open|package)?\s*"
    r"(?:final\s+|indirect\s+)?(?:struct|class|enum|actor|protocol|extension)\b"
)
STORED_PROPERTY_DECLARATION = re.compile(
    r"^\s*(?:public|private|fileprivate|internal|open|package)?\s*"
    r"(?:static\s+|class\s+)?(?:let|var)\s+[A-Za-z_][A-Za-z0-9_]*\s*:"
)
NON_EXECUTABLE_DECLARATION = re.compile(
    r"^\s*(?:public|private|fileprivate|internal|open|package)?\s*"
    r"(?:typealias|associatedtype|case)\b"
)
CALLABLE_DECLARATION_START = re.compile(
    r"^\s*(?:(?:public|private|fileprivate|internal|open|package|final|static|class|"
    r"nonisolated|distributed|convenience|required|override|mutating|nonmutating)\s+)*"
    r"(?:func\s+[A-Za-z_][A-Za-z0-9_]*|init\??|subscript)\s*\("
)


def callable_signature_lines(src_lines):
    """Return source lines that are declaration syntax, not executable regions.

    LLVM emits no counters for multiline callable signatures. This scanner is
    deliberately narrow: it starts only at func/init/subscript declarations
    and ends when their outer parameter list closes. Executable default-value
    closures still remain gated whenever LLVM emits a counter for them.
    """
    signature_lines = set()
    candidate_lines = []
    active = False
    paren_depth = 0
    for index, text in enumerate(src_lines, start=1):
        if not active:
            if CALLABLE_DECLARATION_START.match(text) is None:
                continue
            active = True
            paren_depth = 0
            candidate_lines = []

        # Stay deliberately conservative instead of pretending to parse Swift.
        # Strings, comments, regex/default expressions, and closure or function
        # bodies can all contain delimiter characters that raw counting cannot
        # distinguish. In those cases no line in the candidate is exempted.
        scan_text = text
        trailing_body_brace = text.rstrip().endswith("{") and text.count("{") == 1 and "}" not in text
        if trailing_body_brace:
            scan_text = text.rstrip()[:-1]
        next_depth = paren_depth + scan_text.count("(") - scan_text.count(")")
        if (
            any(token in scan_text for token in ('"', "'", "/", "{", "}"))
            or (trailing_body_brace and next_depth > 0)
        ):
            active = False
            candidate_lines = []
            paren_depth = 0
            continue

        candidate_lines.append(index)
        paren_depth = next_depth
        if paren_depth <= 0:
            signature_lines.update(candidate_lines)
            active = False
            candidate_lines = []
    return signature_lines


def is_structural_swift_line(text):
    stripped = text.strip()
    if not stripped:
        return True
    if stripped in {"{", "}", "};", "],", "]", "),", ")"}:
        return True
    if stripped in {"#else", "#endif"} or stripped.startswith((
        "#if ",
        "#elseif ",
        "#warning",
        "#error",
        "#sourceLocation",
    )):
        return True
    if stripped.startswith("//") or stripped.startswith("/*") or stripped.startswith("*"):
        return True
    if stripped.startswith("@") or stripped.startswith("import "):
        return True
    if STRUCTURAL_SWIFT_DECLARATION.match(stripped):
        return True
    if NON_EXECUTABLE_DECLARATION.match(stripped):
        return True
    if STORED_PROPERTY_DECLARATION.match(stripped):
        # Computed properties and closure defaults can carry executable logic;
        # keep those fail-closed when no line evidence exists.
        return "{" not in stripped and "=" not in stripped
    return False


def filter_structural_swift_lines(rel_path, line_nums, allow_callable_signatures=True):
    abs_path = os.path.join(repo_root, rel_path)
    if not os.path.isfile(abs_path):
        return line_nums
    with open(abs_path, encoding="utf-8", errors="replace") as fh:
        src_lines = fh.read().splitlines()
    signature_lines = callable_signature_lines(src_lines) if allow_callable_signatures else set()
    executable = []
    for ln in line_nums:
        idx = ln - 1
        if not (0 <= idx < len(src_lines)):
            continue
        if ln not in signature_lines and not is_structural_swift_line(src_lines[idx]):
            executable.append(ln)
    return executable


# Full-path and basename maps for the app aggregate fallback.
file_map_by_path = {}
file_map_by_base = {}
for item in cov.get("targets", []):
    name = item.get("name", "")
    rel = name
    if name.startswith(repo_root):
        rel = os.path.relpath(name, repo_root)
    elif "/BurnBar/" in name:
        rel = name.split("/BurnBar/", 1)[1]
    file_map_by_path[rel] = item
    file_map_by_base[os.path.basename(rel)] = item

diff_pathspec = [
    "*.swift",
    ":(exclude)*Tests*",
    ":(exclude)scripts/*",
    ":(exclude)Package.swift",
    ":(exclude)*/Package.swift",
]
changed_file_list = subprocess.check_output(
    ["git", "diff", "--name-only", "--find-renames",
     base_ref, "HEAD", "--"] + diff_pathspec,
    cwd=repo_root,
    text=True,
).splitlines()
changed_file_list = [line.strip() for line in changed_file_list if line.strip()]

waived = []
out_of_scope = []
deferred_lines = []
gated_files = []
for rel_path in changed_file_list:
    reason = allowlist_reason(rel_path)
    if reason is not None:
        waived.append({
            "file": rel_path,
            "method": "allowlist_waiver",
            "reason": reason,
        })
        continue
    file_partition = partition(rel_path)
    if scope == "all":
        gated_files.append(rel_path)
    elif scope == "app":
        if file_partition == "app":
            gated_files.append(rel_path)
        else:
            out_of_scope.append({"file": rel_path, "gatedBy": file_partition})
    elif rel_path.startswith(PACKAGE_PREFIXES):
        # Mixed-platform Swift files can contain both macOS-portable and
        # Linux-only changed lines. Both package lanes inspect the file; exact
        # ownership is applied after changed-line hunks are enumerated.
        gated_files.append(rel_path)
    else:
        out_of_scope.append({"file": rel_path, "gatedBy": "app"})

git_output = ""
if gated_files:
    try:
        git_output = subprocess.run(
            ["git", "diff", "-U0", "--find-renames",
             base_ref, "HEAD", "--"] + gated_files,
            cwd=repo_root,
            capture_output=True,
            text=True,
            check=True,
        ).stdout
    except subprocess.CalledProcessError as error:
        print(
            f"::error::Unable to extract changed-line hunks against {base_ref}: "
            f"{error.stderr.strip() or 'git diff failed'}",
            file=sys.stderr,
        )
        raise SystemExit(1)

file_blocks = {}
current_file = None
for line in git_output.splitlines():
    m = re.match(r"^diff --git a/.* b/(.*)$", line)
    if m:
        current_file = m.group(1)
        file_blocks.setdefault(current_file, [])
        continue
    if current_file and line.startswith("@@"):
        nm = re.search(r"\+(\d+)(?:,(\d+))?", line)
        if not nm:
            continue
        start = int(nm.group(1))
        count = int(nm.group(2) or "1")
        if count <= 0:
            continue
        for ln in range(start, start + count):
            file_blocks[current_file].append(ln)

if scope in {"packages", "linux-packages"}:
    retained_files = []
    for rel_path in gated_files:
        changed = sorted(set(file_blocks.get(rel_path, [])))
        owned = [ln for ln in changed if line_partition(rel_path, ln) == scope]
        deferred = [ln for ln in changed if line_partition(rel_path, ln) != scope]
        if deferred:
            deferred_owners = sorted({line_partition(rel_path, ln) for ln in deferred})
            deferred_lines.append({
                "file": rel_path,
                "changedLines": len(deferred),
                "gatedBy": deferred_owners[0] if len(deferred_owners) == 1 else deferred_owners,
            })
        if owned:
            file_blocks[rel_path] = owned
            retained_files.append(rel_path)
        else:
            owner = partition(rel_path)
            if changed:
                owners = sorted({line_partition(rel_path, ln) for ln in changed})
                owner = owners[0] if len(owners) == 1 else owners
            out_of_scope.append({"file": rel_path, "gatedBy": owner})
    gated_files = retained_files

# In-source waivers: `cov:ignore -- <reason>` on a changed line excludes that
# line. `cov:ignore-start -- <reason>` / `cov:ignore-end` excludes changed
# lines in a block. Bare ignores without a justification are a gate FAILURE —
# an unexplained waiver is indistinguishable from a silenced gate.
COV_IGNORE_VALID = re.compile(r"cov:ignore\s*--\s*\S")
COV_IGNORE_BLOCK_START_VALID = re.compile(r"cov:ignore-start\s*--\s*\S")
COV_IGNORE_BLOCK_START = re.compile(r"cov:ignore-start\b")
COV_IGNORE_BLOCK_END = re.compile(r"cov:ignore-end\b")
cov_ignore_lines = {}
cov_ignore_violations = []
for rel_path, line_nums in file_blocks.items():
    abs_path = os.path.join(repo_root, rel_path)
    if not os.path.isfile(abs_path):
        continue
    with open(abs_path, encoding="utf-8", errors="replace") as fh:
        src_lines = fh.read().splitlines()
    line_set = set(line_nums)
    active_block_start = None
    block_ignored = set()
    for idx, text in enumerate(src_lines, start=1):
        has_start = COV_IGNORE_BLOCK_START.search(text) is not None
        has_end = COV_IGNORE_BLOCK_END.search(text) is not None
        if has_start:
            if not COV_IGNORE_BLOCK_START_VALID.search(text):
                cov_ignore_violations.append(f"{rel_path}:{idx}")
            elif active_block_start is not None:
                cov_ignore_violations.append(f"{rel_path}:{idx} nested cov:ignore-start")
            else:
                active_block_start = idx
        if active_block_start is not None and idx in line_set:
            block_ignored.add(idx)
        if has_end:
            if active_block_start is None:
                cov_ignore_violations.append(f"{rel_path}:{idx} unmatched cov:ignore-end")
            else:
                active_block_start = None
    if active_block_start is not None:
        cov_ignore_violations.append(f"{rel_path}:{active_block_start} unclosed cov:ignore-start")
    if block_ignored:
        cov_ignore_lines.setdefault(rel_path, set()).update(block_ignored)
    for ln in line_nums:
        idx = ln - 1  # 0-based index
        if not (0 <= idx < len(src_lines)):
            continue
        text = src_lines[idx]
        if "cov:ignore" not in text:
            continue
        if COV_IGNORE_BLOCK_START.search(text) or COV_IGNORE_BLOCK_END.search(text):
            continue
        if COV_IGNORE_VALID.search(text):
            cov_ignore_lines.setdefault(rel_path, set()).add(ln)
        else:
            cov_ignore_violations.append(f"{rel_path}:{ln}")

if cov_ignore_violations:
    for violation in cov_ignore_violations:
        print(f"::error::cov:ignore without a justification at {violation} — "
              "use `cov:ignore -- <reason>`.", file=sys.stderr)
    raise SystemExit(1)

# ---------------------------------------------------------------------------
# Pure-move safe-harbor (R-GH0). Splitting a god-file or relocating a block is
# not new behavior — byte-identical (or reindented-identical) code that merely
# moved must not be charged as brand-new uncovered lines, which is exactly the
# pressure that makes a refactor game the coverage gate.
#
# The exemption is granted ONLY by this detector, never by a human-editable
# annotation, and ONLY by CONTIGUOUS BLOCK: an added line is credited
# `refactor:pure-move` iff it belongs to a run of >= MIN_MOVE_BLOCK consecutive
# added lines whose normalized content matches a contiguous run of REMOVED lines
# elsewhere in the same diff, and each matched removed line is consumed so it can
# back at most one move. Block matching is what stops the coincidence attack: an
# in-place edit (`return 1` -> `return 0`) whose new text happens to equal one
# line of an unrelated deleted helper is a length-1 run that matches no >=2
# block, so it stays gated. A genuine edit inside a moved block (a changed
# literal/operator) breaks the run at that line — the surrounding lines are still
# credited, the edited line alone stays gated.
#
# Normalization strips ONLY leading/trailing indentation (text.strip()) so a
# reindented relocation still matches while every internal byte — including
# whitespace inside a string literal — is preserved: `return "a  b"` never
# normalizes onto the `return "a b"` it replaced.
#
# The removed-line pool is drawn from every production Swift file in the diff
# (the same pathspec the gate measures), so cross-file and cross-partition
# splits are recognized even when the move source is out of the current lane's
# scope. Consuming matched removed lines makes moves 1:1 — N relocated copies of
# a line earn exactly N credits, so appending genuinely-new duplicates of an
# existing line cannot launder them past the gate.


# A single coincidentally-matching line is never a "move": a credited run must
# span at least this many consecutive lines matching a contiguous removed run.
MIN_MOVE_BLOCK = 2


def normalize_move_line(text):
    # Strip ONLY leading/trailing indentation; preserve ALL internal whitespace.
    # Reindentation (the common relocation transform) still matches, but a
    # changed string literal such as `return "a  b"` never normalizes onto the
    # `return "a b"` it replaced, so an edited line is never treated as a move.
    return text.strip()


# Removed-line pool, grouped into CONTIGUOUS runs (a run breaks at a hunk
# header, a file boundary, or the first non-removed line — with -U0 there is no
# surrounding context to blur the boundary). No --find-renames/--find-copies
# here on purpose: this pool needs the CONTENT of every removed line, and
# letting git collapse a rename would hide removed content that a split's added
# lines legitimately match.
move_pool_output = subprocess.run(
    ["git", "diff", "-U0", base_ref, "HEAD", "--"] + diff_pathspec,
    cwd=repo_root,
    capture_output=True,
    text=True,
).stdout
removed_runs = []
_pending_removed = []


def _flush_removed_run():
    # Drop blank/whitespace-only lines (never executable, never a move) without
    # letting them split the surrounding block, then keep the run if anything
    # substantive remains.
    cleaned = [norm for norm in _pending_removed if norm]
    if cleaned:
        removed_runs.append(cleaned)
    _pending_removed.clear()


in_hunk = False
for line in move_pool_output.splitlines():
    if line.startswith("diff --git"):
        in_hunk = False
        _flush_removed_run()
        continue
    if line.startswith("@@"):
        in_hunk = True
        _flush_removed_run()
        continue
    if in_hunk and line.startswith("-"):
        _pending_removed.append(normalize_move_line(line[1:]))
        continue
    # A context line, an added line, or anything else ends the current run.
    _flush_removed_run()
_flush_removed_run()

# Flatten the runs into one consumable sequence with a unique sentinel between
# (and around) every run so no match can span a run boundary. A matched removed
# position is overwritten with the sentinel so a removed line backs at most one
# move — appended duplicates find no unconsumed source and stay gated.
_MOVE_SENTINEL = object()
removed_pool = []
for run in removed_runs:
    removed_pool.append(_MOVE_SENTINEL)
    removed_pool.extend(run)
removed_pool.append(_MOVE_SENTINEL)

_source_cache = {}


def source_lines(rel_path):
    if rel_path not in _source_cache:
        abs_path = os.path.join(repo_root, rel_path)
        if os.path.isfile(abs_path):
            with open(abs_path, encoding="utf-8", errors="replace") as fh:
                _source_cache[rel_path] = fh.read().splitlines()
        else:
            _source_cache[rel_path] = []
    return _source_cache[rel_path]


# Added-line runs: maximal groups of consecutive changed line numbers per file.
# Blank and already-excluded (cov:ignore'd) lines are dropped from a run's
# signature without splitting the block, mirroring the removed-run cleaning so
# the two sides align.
added_runs = []  # (rel_path, [(line_number, normalized_text), ...])
for rel_path in gated_files:
    src = source_lines(rel_path)
    ignore = cov_ignore_lines.get(rel_path, set())
    group = []
    prev = None
    for ln in sorted(set(file_blocks.get(rel_path, []))) + [None]:
        if ln is None or (prev is not None and ln != prev + 1):
            seq = []
            for gln in group:
                gidx = gln - 1
                if gln in ignore or not (0 <= gidx < len(src)):
                    continue
                gnorm = normalize_move_line(src[gidx])
                if gnorm:
                    seq.append((gln, gnorm))
            if seq:
                added_runs.append((rel_path, seq))
            group = []
        if ln is not None:
            group.append(ln)
            prev = ln

# Credit longest added runs first so a short run cannot consume a removed block a
# longer genuine move needs. For each run, difflib finds the contiguous matching
# blocks against the (sentinel-separated) removed pool; only blocks of at least
# MIN_MOVE_BLOCK lines are credited, and their removed positions are consumed.
pure_move_lines = {}
added_runs.sort(key=lambda item: len(item[1]), reverse=True)
for rel_path, seq in added_runs:
    a_norms = [norm for _, norm in seq]
    matcher = difflib.SequenceMatcher(a=a_norms, b=removed_pool, autojunk=False)
    for block in matcher.get_matching_blocks():
        if block.size < MIN_MOVE_BLOCK:
            continue
        for offset in range(block.size):
            moved_line = seq[block.a + offset][0]
            pure_move_lines.setdefault(rel_path, set()).add(moved_line)
            removed_pool[block.b + offset] = _MOVE_SENTINEL

pure_move_total = sum(len(v) for v in pure_move_lines.values())

total_exc = 0
total_hit = 0
details = []

for rel_path in gated_files:
    changed_lines = sorted(set(file_blocks.get(rel_path, [])))
    ignore = cov_ignore_lines.get(rel_path, set())
    moved = pure_move_lines.get(rel_path, set())
    changed_lines = [ln for ln in changed_lines if ln not in ignore and ln not in moved]
    if not changed_lines:
        continue

    line_cov, line_source = merged_line_map(rel_path)

    if line_cov is not None:
        method = f"line_level({line_source})"
        exc = 0
        hit = 0
        unmeasured = []
        for ln in changed_lines:
            key = str(ln)
            if key not in line_cov:
                unmeasured.append(ln)
                continue
            exc += 1
            if line_cov[key]:
                hit += 1
        if scope in {"app", "packages", "linux-packages"} and unmeasured:
            # Scoped lanes are line-truth only. Missing counters for genuinely
            # executable changed lines are uncovered; structural declarations
            # remain outside the denominator because LLVM emits no counters.
            unmeasured = filter_structural_swift_lines(rel_path, unmeasured)
            exc += len(unmeasured)
            if unmeasured:
                method = f"line_level({line_source})+missing_line_evidence"
    else:
        cov_item = None if scope == "app" else (
            file_map_by_path.get(rel_path) or file_map_by_base.get(os.path.basename(rel_path))
        )
        if not cov_item:
            changed_lines = filter_structural_swift_lines(
                rel_path,
                changed_lines,
                allow_callable_signatures=False,
            )
            if not changed_lines:
                continue
            # No lane produced any measurement for this file: every executable
            # changed line counts as uncovered. There is no presence-based
            # escape.
            method = "no_evidence"
            exc = len(changed_lines)
            hit = 0
        else:
            method = "file_aggregate_fallback"
            file_exc = cov_item.get("executable", 0)
            file_hit = cov_item.get("hit", 0)
            if file_exc <= 0:
                exc = len(changed_lines)
                hit = 0
            else:
                ratio = file_hit / file_exc
                exc = len(changed_lines)
                hit = int(round(exc * ratio))

    if exc <= 0:
        continue

    pct = round(hit * 100.0 / exc, 2)
    total_exc += exc
    total_hit += hit
    details.append({
        "file": rel_path,
        "executableLines": exc,
        "coveredLines": hit,
        "percent": pct,
        "method": method,
    })

total_pct = 0.0 if total_exc <= 0 else round(total_hit * 100.0 / total_exc, 2)
passed = total_exc <= 0 or total_pct >= threshold

# The gated tally is the coverage denominator itself (total_exc), so it can never
# overcount by including structural/unmeasured lines that the percentage excludes
# — `pureMove.gatedLines` and `diffCoverage.changedLines` are the same number.
if pure_move_total or total_exc:
    print(f"::notice::diff-coverage pure-move safe-harbor: excluded "
          f"{pure_move_total} relocated line(s) as refactor:pure-move; "
          f"{total_exc} changed line(s) remain gated.", file=sys.stderr)

output = {
    "diffCoverage": {
        "percent": total_pct,
        "threshold": threshold,
        "passed": passed,
        "changedFiles": len(details),
        "changedLines": total_exc,
        "method": "line_intersection",
        "scope": scope,
    },
    "details": details,
    "waived": waived,
    "outOfScope": out_of_scope,
    "deferredLines": deferred_lines,
    "pureMove": {"movedLines": pure_move_total, "gatedLines": total_exc},
}
rendered = json.dumps(output, indent=2)
print(rendered)
if output_path:
    with open(output_path, "w", encoding="utf-8") as handle:
        handle.write(rendered + "\n")
if not passed and total_exc > 0:
    sys.exit(1)
PY
