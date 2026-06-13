#!/usr/bin/env python3
"""Apply the critic-pass fixes (1 minor + nits) atomically."""
import os, json
TM = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EV = os.path.join(TM, "_evidence")

def patch(path, pairs):
    s = open(path).read(); n = 0
    for a, b in pairs:
        if a in s: s = s.replace(a, b); n += 1
        else: print("  !! not found in", os.path.basename(path), ":", a[:60])
    open(path, "w").write(s); print("patched", os.path.basename(path), n, "edits")

# 1) trust-boundaries.md: T-SC-06 Low -> Med (canonical Medium)
patch(os.path.join(TM, "trust-boundaries.md"),
      [("(`T-SC-06` Low).", "(`T-SC-06` Med).")])

# 2) security-claims.md + _claims.json: C1 serializeHermesGatewayEvent off-by-11 (start 1233 -> 1222)
patch(os.path.join(TM, "security-claims.md"),
      [("hermesGateway.ts:1233-1268", "hermesGateway.ts:1222-1268")])
cj = os.path.join(EV, "_claims.json")
s = open(cj).read().replace("hermesGateway.ts:1233-1268", "hermesGateway.ts:1222-1268")
open(cj, "w").write(s); print("patched _claims.json (C1 citation)")

# 3) privacy-threat-model.md: disambiguate duplicate LINDDUN letters (D/D, N/N)
patch(os.path.join(TM, "privacy-threat-model.md"), [
    ("### 11.2.N — Non-repudiation", "### 11.2.N1 — Non-repudiation"),
    ("### 11.2.D — Detecting", "### 11.2.D1 — Detecting"),
    ("### 11.2.D — Disclosure", "### 11.2.D2 — Disclosure"),
    ("### 11.2.N — Non-compliance", "### 11.2.N2 — Non-compliance"),
])

# 4) abuse-cases.md: add diagram-convention note
patch(os.path.join(TM, "abuse-cases.md"),
      [("prescribes the tests and mitigations.\n",
        "prescribes the tests and mitigations.\n\n> **Diagram convention:** the attack trees below are intentionally rendered as ASCII for legibility and diff-stability — they are not Mermaid. Every other diagram-bearing file in this package uses Mermaid; this file deliberately does not.\n")])
print("done")
