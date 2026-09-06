#!/usr/bin/env bash
# Engine-umbrella transitive-closure UI-purity proof (core-decomposition P-17/S16).
#
# The security payoff of the decomposition is that the privileged binaries
# (daemon, CLI, parity execs) link OpenBurnBarEngine instead of the SwiftUI/AppKit
# OpenBurnBarCore monolith, and therefore gain NO transitive path to the
# presentation layer (OpenBurnBarUI / OpenBurnBarInsights / OpenBurnBarTextExpansion
# / OpenBurnBarLaunchServices).
#
# check-core-ui-purity-budget.sh asserts-zero SwiftUI/AppKit per *named* target.
# This script proves the complementary invariant: the set of targets reachable
# from OpenBurnBarEngine in the RESOLVED dependency graph is EXACTLY the UI-free
# engine leaves — i.e. no UI-carrying target ever sneaks into Engine's closure via
# a new manifest edge. It derives the closure from `swift package dump-package`
# (authoritative manifest), then greps every closure target's Sources for
# `import SwiftUI` / `import AppKit`.
#
# Exit 0 (pass) iff:
#   - the Engine closure contains none of the known UI-carrying targets, AND
#   - no file under any closure target imports SwiftUI or AppKit.
#
# TOOLCHAIN: resolved through scripts/lib/swift-toolchain.sh, never bare `swift`
# from PATH. A swiftly (or otherwise non-Xcode) `swift` earlier on PATH compiles
# the manifest against a mismatched SDK and fails every run; this script used to
# swallow that stderr and exit 1 with no output, which read as a real invariant
# breach. Any dump-package failure now prints the toolchain and the raw stderr.
#
# Usage: scripts/debt/check-engine-closure-ui-purity.sh
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
core_pkg="${repo_root}/OpenBurnBarCore"

# shellcheck source=../lib/swift-toolchain.sh
source "${repo_root}/scripts/lib/swift-toolchain.sh"
obb_swift_init || exit 1

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/engine-closure-ui-purity.XXXXXX")"
trap 'rm -rf "${work_dir}"' EXIT
dump_path="${work_dir}/dump-package.json"
dump_err="${work_dir}/dump-package.err"

dump_failed=0
(cd "${core_pkg}" && "${OBB_SWIFT}" package dump-package) \
  >"${dump_path}" 2>"${dump_err}" || dump_failed=$?

if [[ "${dump_failed}" -ne 0 || ! -s "${dump_path}" ]]; then
  if [[ "${dump_failed}" -ne 0 ]]; then
    echo "FAIL: 'swift package dump-package' exited ${dump_failed} in ${core_pkg}." >&2
  else
    echo "FAIL: 'swift package dump-package' produced no output in ${core_pkg}." >&2
  fi
  echo "      toolchain: ${OBB_SWIFT} (resolved via ${OBB_SWIFT_SOURCE})" >&2
  echo "      This is a TOOLCHAIN failure, not a UI-purity breach." >&2
  echo "      ---------------- swift stderr ----------------" >&2
  cat "${dump_err}" >&2
  echo "      -------------- end swift stderr --------------" >&2
  echo "      If the toolchain above is not the active Xcode's swift, either" >&2
  echo "      run under 'DEVELOPER_DIR=\$(xcode-select -p)' or set" >&2
  echo "      OPENBURNBAR_SWIFT to the swift you want this check to use." >&2
  exit 1
fi

python3 - "${core_pkg}/Sources" "${dump_path}" <<'PY'
import json, os, re, sys

sources_root = sys.argv[1]
dump_path = sys.argv[2]
with open(dump_path, encoding="utf-8") as fh:
    pkg = json.load(fh)
targets = {t['name']: t for t in pkg['targets']}

# UI-carrying targets that must NEVER appear in Engine's transitive closure.
UI_TARGETS = {
    "OpenBurnBarUI",
    "OpenBurnBarCore",
    "OpenBurnBarInsights",
    "OpenBurnBarTextExpansion",
    "OpenBurnBarLaunchServices",
}

def internal_deps(name):
    out = []
    for d in targets[name].get('dependencies', []):
        for key in ('byName', 'target'):
            if key in d and d[key] and d[key][0] in targets:
                out.append(d[key][0])
    return out

# BFS the closure from OpenBurnBarEngine.
seen, stack = set(), ['OpenBurnBarEngine']
while stack:
    n = stack.pop()
    if n in seen:
        continue
    seen.add(n)
    stack.extend(internal_deps(n))

closure = sorted(seen)
print("Engine transitive closure (internal targets):")
for t in closure:
    print(f"  {t}")

failed = False

leaked = sorted(seen & UI_TARGETS)
if leaked:
    failed = True
    print(f"\nFAIL: UI-carrying target(s) reached from OpenBurnBarEngine: {leaked}")

import_re = re.compile(
    r'^\s*(?:@_?\w+(?:\([^)]*\))?\s+)*import\s+'
    r'(?:(?:class|struct|enum|protocol|typealias|func|var|let)\s+)?'
    r'(SwiftUI|AppKit)(?:\b|\.)'
)
for t in closure:
    root = targets[t].get('path') or os.path.join("Sources", t)
    abs_root = os.path.join(os.path.dirname(sources_root), root) if not os.path.isabs(root) else root
    if not os.path.isdir(abs_root):
        abs_root = os.path.join(sources_root, t)
    if not os.path.isdir(abs_root):
        continue
    for dirpath, _dirs, files in os.walk(abs_root):
        for f in files:
            if not f.endswith(".swift"):
                continue
            p = os.path.join(dirpath, f)
            with open(p, encoding="utf-8") as fh:
                for line in fh:
                    m = import_re.match(line)
                    if m:
                        failed = True
                        print(f"\nFAIL: {t} imports {m.group(1)} in {os.path.relpath(p, os.path.dirname(sources_root))}")

if failed:
    print("\nEngine closure is NOT UI-free.")
    sys.exit(1)

print(f"\nOK: Engine closure = {len(closure)} target(s), zero SwiftUI/AppKit, no UI target reachable.")
PY
