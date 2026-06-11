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
#   * An in-source annotation `cov:ignore -- <reason>` on the changed line.
#     A bare `cov:ignore` without a reason FAILS the gate outright.
#   * An entry in COVERAGE_ALLOWLIST (in the Python below): exact repo path
#     (or an explicit, documented prefix) plus a mandatory written reason.
#     Waived files are reported in the verdict JSON under "waived" — they are
#     excluded from the percentage, never counted as covered.
#   Test-file presence, directory existence, or any other proxy is NEVER
#   evidence (see DILIGENCE_REPORT_2026-06-11 §5.1 / finding CG-1).
#
# Usage:
#   diff-coverage.sh <base-ref> [app-summary-json] [app-lines-json] [package-lines-json]
#
# Environment:
#   COVERAGE_THRESHOLD    minimum diff coverage percent (default 80)
#   DIFF_COVERAGE_SCOPE   all|app|packages (default all). CI lanes partition:
#                         App XCTest gates scope=app with the xcresult, Swift
#                         Core gates scope=packages with package coverage, so
#                         every changed production file is measured by the
#                         lane that actually executes its tests.
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
  all|app|packages) ;;
  *)
    echo "::error::DIFF_COVERAGE_SCOPE must be all, app, or packages (got: $scope)" >&2
    exit 2
    ;;
esac

coverage_json="${2:-}"
lines_json="${3:-}"
package_lines_json="${4:-}"

tmp_root="${TMPDIR:-/tmp}"

if [[ -z "$coverage_json" && "$scope" != "packages" ]]; then
  candidate="$repo_root/.derived-data/OpenBurnBar_TestCoverage.xcresult"
  if [[ -d "$candidate" ]]; then
    coverage_json="$tmp_root/openburnbar-diff-coverage-summary.json"
    "$scripts_dir/extract-coverage.sh" "$candidate" > "$coverage_json"
  fi
fi

if [[ -z "$lines_json" && "$scope" != "packages" && -d "$repo_root/.derived-data/OpenBurnBar_TestCoverage.xcresult" ]]; then
  lines_json="$tmp_root/openburnbar-diff-coverage-lines.json"
  "$scripts_dir/extract-coverage-lines.sh" "$repo_root/.derived-data/OpenBurnBar_TestCoverage.xcresult" > "$lines_json" 2>/dev/null || lines_json=""
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
if ! changed_files="$(git diff --name-only "$base_ref" HEAD -- "${diff_pathspec[@]}" 2>/dev/null)"; then
  changed_files=""
fi

if [[ -z "$changed_files" ]]; then
  echo "{\"diffCoverage\":{\"percent\":100.0,\"threshold\":$threshold,\"passed\":true,\"changedFiles\":0,\"changedLines\":0,\"method\":\"no_swift_changes\",\"scope\":\"$scope\"},\"details\":[]}"
  exit 0
fi

# Evidence requirements per scope. A lane that cannot see is not allowed to
# judge — and is never allowed to silently pass.
if [[ "$scope" == "app" && ! -f "${coverage_json:-}" ]]; then
  echo '::error::No app coverage data found. Run app tests with OPENBURNBAR_ENABLE_COVERAGE=YES first.' >&2
  exit 1
fi
if [[ "$scope" == "packages" && ! -f "${package_lines_json:-}" ]]; then
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

python3 - <<'PY'
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

# ---------------------------------------------------------------------------
# Waiver allowlist — the documented, auditable escape hatch.
#
# POLICY: every entry is an exact repo-relative path, or an explicit prefix
# ending in "/", and MUST carry a non-empty reason. Entries exist only for
# files that structurally cannot produce line coverage in any lane wired into
# this gate. Adding an entry to flip a red check is exactly the failure mode
# this gate exists to prevent (DILIGENCE_REPORT_2026-06-11 §5.1, CG-1):
# prefer wiring the missing lane's artifact, then real tests, then an
# in-source `cov:ignore -- reason` on the specific lines.
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
    "AgentLens/Services/DirectDownloadUpdateService.swift": (
        "UI/IO orchestration of the update flow: NSAlert prompts, URLSession "
        "download, NSWorkspace open, 24h timers — none of which can execute "
        "under headless XCTest. ALL decision logic is split into line-gated "
        "companions: DirectDownloadReleaseMetadata.swift, "
        "DirectDownloadArtifactVerifier.swift (sha256+Ed25519 verification), "
        "DirectDownloadUpdatePromptPolicy.swift — 32 behavioral tests."
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


def partition(rel_path):
    return "packages" if rel_path.startswith(PACKAGE_PREFIXES) else "app"


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
    ["git", "diff", "--name-only", base_ref, "HEAD", "--"] + diff_pathspec,
    cwd=repo_root,
    text=True,
).splitlines()
changed_file_list = [line.strip() for line in changed_file_list if line.strip()]

waived = []
out_of_scope = []
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
    if scope != "all" and file_partition != scope:
        out_of_scope.append({"file": rel_path, "gatedBy": file_partition})
        continue
    gated_files.append(rel_path)

git_output = ""
if gated_files:
    git_output = subprocess.run(
        ["git", "diff", "-U0", base_ref, "HEAD", "--"] + gated_files,
        cwd=repo_root,
        capture_output=True,
        text=True,
    ).stdout

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

# In-source waivers: `cov:ignore -- <reason>` on a changed line excludes that
# line. A bare `cov:ignore` without a justification is a gate FAILURE — an
# unexplained waiver is indistinguishable from a silenced gate.
COV_IGNORE_VALID = re.compile(r"cov:ignore\s*--\s*\S")
cov_ignore_lines = {}
cov_ignore_violations = []
for rel_path, line_nums in file_blocks.items():
    abs_path = os.path.join(repo_root, rel_path)
    if not os.path.isfile(abs_path):
        continue
    with open(abs_path, encoding="utf-8", errors="replace") as fh:
        src_lines = fh.read().splitlines()
    for ln in line_nums:
        idx = ln - 1  # 0-based index
        if not (0 <= idx < len(src_lines)):
            continue
        text = src_lines[idx]
        if "cov:ignore" not in text:
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

total_exc = 0
total_hit = 0
details = []

for rel_path in gated_files:
    changed_lines = sorted(set(file_blocks.get(rel_path, [])))
    ignore = cov_ignore_lines.get(rel_path, set())
    changed_lines = [ln for ln in changed_lines if ln not in ignore]
    if not changed_lines:
        continue

    line_cov, line_source = merged_line_map(rel_path)

    if line_cov is not None:
        method = f"line_level({line_source})"
        exc = 0
        hit = 0
        for ln in changed_lines:
            key = str(ln)
            if key not in line_cov:
                continue
            exc += 1
            if line_cov[key]:
                hit += 1
    else:
        cov_item = file_map_by_path.get(rel_path) or file_map_by_base.get(os.path.basename(rel_path))
        if not cov_item:
            # No lane produced any measurement for this file: every changed
            # line counts as uncovered. There is no presence-based escape.
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
}
rendered = json.dumps(output, indent=2)
print(rendered)
if output_path:
    with open(output_path, "w", encoding="utf-8") as handle:
        handle.write(rendered + "\n")
if not passed and total_exc > 0:
    sys.exit(1)
PY
