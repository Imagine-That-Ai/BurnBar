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
# Usage: scripts/debt/check-engine-closure-ui-purity.sh
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
core_pkg="${repo_root}/OpenBurnBarCore"

dump="$(cd "${core_pkg}" && swift package dump-package 2>/dev/null)"

python3 - "${core_pkg}/Sources" <<PY
import json, os, re, sys

sources_root = sys.argv[1]
pkg = json.loads('''${dump}''')
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

import_re = re.compile(r'^\s*(?:@_?\w+(?:\([^)]*\))?\s+)*import\s+(SwiftUI|AppKit)\b')
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
