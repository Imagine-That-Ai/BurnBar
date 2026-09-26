#!/usr/bin/env bash
# Freeze check for Daemon RPC methods catalog (BurnBarRPCMethod.generated.swift).
#
# Part of Tech Debt Remediation Program (Item #8): prevents unversioned, untyped
# RPC additions to the v1 protocol without TypeSpec / schema-sync generation and
# contract version negotiation.
#
# Wave 3.6 moved the `BurnBarRPCMethod` enum into the TypeSpec-generated file;
# the protocol version constants stayed in BurnBarRPCContracts.swift, so the
# check reads cases from the generated file and versions from the hand file.
#
# Baseline: budgets/rpc-methods-baseline.json
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
baseline_path="${repo_root}/budgets/rpc-methods-baseline.json"
contracts_file="${repo_root}/OpenBurnBarCore/Sources/OpenBurnBarKernel/Contracts/BurnBarRPCContracts.swift"
methods_file="${repo_root}/OpenBurnBarCore/Sources/OpenBurnBarKernel/Contracts/BurnBarRPCMethod.generated.swift"
mode="${1:-}"

python3 - "${contracts_file}" "${baseline_path}" "${mode}" "${methods_file}" <<'PY'
import json
import re
import sys
from pathlib import Path

contracts_path = Path(sys.argv[1])
baseline_path = Path(sys.argv[2])
mode = sys.argv[3] if len(sys.argv) > 3 else ""
methods_path = Path(sys.argv[4]) if len(sys.argv) > 4 else contracts_path

if not contracts_path.exists():
    print(f"::error::Contracts file not found: {contracts_path}", file=sys.stderr)
    sys.exit(1)
if not methods_path.exists():
    print(f"::error::Methods file not found: {methods_path}", file=sys.stderr)
    sys.exit(1)

lines = methods_path.read_text(encoding="utf-8").splitlines()
cases = []
in_enum = False
for line in lines:
    if "enum BurnBarRPCMethod" in line:
        in_enum = True
        continue
    if in_enum:
        m = re.search(r"case\s+(\w+)\s*=\s*\"([^\"]+)\"", line)
        if m:
            cases.append({"caseName": m.group(1), "methodString": m.group(2)})
        elif line.strip() == "}" or ("public" in line and "enum" in line):
            if line.strip() == "}":
                break

current_match = re.search(r"public static let current = (\d+)", contracts_path.read_text(encoding="utf-8"))
supported_match = re.search(r"public static let supported = \[([^\]]+)\]", contracts_path.read_text(encoding="utf-8"))
current = int(current_match.group(1)) if current_match else 1
supported = [int(part.strip()) for part in supported_match.group(1).split(",") if part.strip()] if supported_match else [1]
if 2 not in supported:
    print("::error::BurnBarProtocolVersion.supported must include 2 (N-1 negotiation).", file=sys.stderr)
    sys.exit(1)

live = {
    "protocolVersion": current,
    "supported": supported,
    "totalMethods": len(cases),
    "methods": sorted(cases, key=lambda x: x["methodString"]),
}

if mode == "--print-live":
    print(json.dumps(live, indent=2))
    sys.exit(0)

if not baseline_path.exists():
    print(f"::error::Missing RPC methods baseline: {baseline_path}", file=sys.stderr)
    print("Run scripts/debt/check-rpc-method-freeze.sh --print-live and check in the baseline.", file=sys.stderr)
    sys.exit(1)

baseline = json.loads(baseline_path.read_text(encoding="utf-8"))

live_methods = {m["methodString"]: m["caseName"] for m in live["methods"]}
base_methods = {m["methodString"]: m["caseName"] for m in baseline["methods"]}

added = set(live_methods.keys()) - set(base_methods.keys())
removed = set(base_methods.keys()) - set(live_methods.keys())
renamed = []
for k in set(live_methods.keys()) & set(base_methods.keys()):
    if live_methods[k] != base_methods[k]:
        renamed.append((k, base_methods[k], live_methods[k]))

print(f"Daemon RPC method freeze check: live={len(live_methods)} baseline={len(base_methods)}")

if added or removed or renamed:
    if added:
        print(f"::error::Found {len(added)} unversioned RPC method additions (protocol v1 is frozen):", file=sys.stderr)
        for m in sorted(added):
            print(f"  + {live_methods[m]} = \"{m}\"", file=sys.stderr)
    if removed:
        print(f"::error::Found {len(removed)} removed RPC methods:", file=sys.stderr)
        for m in sorted(removed):
            print(f"  - {base_methods[m]} = \"{m}\"", file=sys.stderr)
    if renamed:
        print(f"::error::Found {len(renamed)} renamed cases:", file=sys.stderr)
        for m, old_case, new_case in renamed:
            print(f"  * {m}: {old_case} -> {new_case}", file=sys.stderr)
    sys.exit(1)

print("Daemon RPC method freeze OK (method table frozen; protocol v2 is in supported).")
PY
