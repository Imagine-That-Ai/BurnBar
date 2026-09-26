#!/usr/bin/env bash
# check-design-tokens.sh — DESIGN.md palette must match the shipped tokens (wave 4).
#
# Two invariants:
#   1. Every `Color.adaptive(...)` token in AgentLens/Theme/DesignSystem.swift
#      has a DESIGN.md row (in the Color System section) whose hex set is
#      exactly {dark, light} (+ editorial when the token has one).
#   2. DesignSystemTokens light/dark constants mirror the DesignSystem.swift
#      literals they shadow (both render live on different surfaces),
#      except the known hermesAureate divergence (mac gold vs unified
#      gunmetal — unification open, documented in DESIGN.md).
set -euo pipefail
cd "$(dirname "$0")/../.."

python3 - <<'PY'
import re
import sys

SRC = "AgentLens/Theme/DesignSystem.swift"
TOKENS = "OpenBurnBarCore/Sources/OpenBurnBarUI/SharedModels/DesignSystemTokens.swift"
DOC = "DESIGN.md"

# (token, variant) pairs whose DesignSystem.swift literal intentionally differs
# from the DesignSystemTokens constant. Documented in DESIGN.md; unification open.
MIRROR_EXEMPT = {("hermesAureate", "Light"), ("hermesAureate", "Dark")}

src = open(SRC).read()
consts = dict(
    re.findall(r'public static let (\w+)\s*=\s*"([0-9A-Fa-f]{6,8})"', open(TOKENS).read())
)

adaptive_re = re.compile(r"static let (\w+)\s*=\s*Color\.adaptive\(([^)]*)\)")
tokens = {}
for name, args in adaptive_re.findall(src):
    light = re.search(r'light:\s*"([0-9A-Fa-f]{6})"', args)
    dark = re.search(r'dark:\s*"([0-9A-Fa-f]{6})"', args)
    if not light or not dark:
        print(f"FAIL: {SRC}: token {name} lacks a light/dark hex", file=sys.stderr)
        sys.exit(1)
    editorial = None
    ed = re.search(r'editorial:\s*(?:"([0-9A-Fa-f]{6,8})"|DesignSystemTokens\.(\w+))', args)
    if ed:
        editorial = ed.group(1) or consts.get(ed.group(2))
        if editorial is None:
            print(f"FAIL: {SRC}: token {name} references unknown {ed.group(2)}", file=sys.stderr)
            sys.exit(1)
    tokens[name] = (light.group(1).upper(), dark.group(1).upper(),
                    editorial.upper() if editorial else None)

failures = []

# Invariant 2: token-constant mirror.
for name, (light, dark, _) in sorted(tokens.items()):
    for variant, value in (("Light", light), ("Dark", dark)):
        const = f"{name}{variant}"
        if const not in consts:
            continue  # frost/glacier/abyss/surfaceMuted have no shared constants
        if (name, variant) in MIRROR_EXEMPT:
            continue
        if consts[const].upper() != value:
            failures.append(
                f"mirror: {TOKENS} {const}={consts[const]} != {SRC} {name} {variant.lower()}={value}"
            )

# Invariant 1: doc rows match shipped hexes (Color System section only).
lines = open(DOC).read().splitlines()
start = next(i for i, line in enumerate(lines) if line.startswith("## Color System"))
end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("## ")), len(lines))
section = lines[start:end]
hex_re = re.compile(r"#([0-9A-Fa-f]{6,8})\b")
for name, (light, dark, editorial) in sorted(tokens.items()):
    expected = {light, dark} | ({editorial} if editorial else set())
    rows = [
        (i + 1, line)
        for i, line in enumerate(section, start=start)
        if line.startswith("|") and f"`{name}`" in line
    ]
    if not rows:
        failures.append(f"doc: no DESIGN.md row for `{name}` (expected {sorted(expected)})")
        continue
    for lineno, row in rows:
        found = {m.upper() for m in hex_re.findall(row)}
        if found != expected:
            failures.append(
                f"doc: DESIGN.md:{lineno} row for `{name}` has {sorted(found)}, "
                f"shipped is {sorted(expected)}"
            )

if failures:
    print(f"FAIL: {len(failures)} design-token drift(s):", file=sys.stderr)
    for failure in failures:
        print(f"  {failure}", file=sys.stderr)
    sys.exit(1)
print(f"Design tokens OK: {len(tokens)} shipped tokens match DESIGN.md.")
PY
