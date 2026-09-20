#!/usr/bin/env bash
# Freeze the half-on Rust domain core: default mode must stay .legacy until a
# domain completes promotion AND legacy deletion. New DomainCore*Adapter.swift
# files are shrink-only against the checked-in list.
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 - <<'PY'
from pathlib import Path
root = Path("OpenBurnBarCore/Sources")
text = (root / "OpenBurnBarDomainCoreRuntime/DomainCoreBuildProfile.swift").read_text()
if ".legacy" not in text:
    raise SystemExit("DomainCoreBuildProfile must keep a .legacy default until one domain is promoted")
if "modes[domain] ?? .legacy" not in text and "?? .legacy" not in text:
    raise SystemExit("DomainCoreBuildProfileResolver.mode must default to .legacy")
adapters = sorted(p.as_posix() for p in root.rglob("*DomainCore*Adapter.swift"))
baseline = Path("budgets/domain-core-adapter-baseline.txt")
if not baseline.exists():
    baseline.write_text("\n".join(adapters) + ("\n" if adapters else ""))
    print(f"wrote {baseline} ({len(adapters)} adapters)")
else:
    allowed = {line for line in baseline.read_text().splitlines() if line.strip()}
    extra = [p for p in adapters if p not in allowed]
    if extra:
        raise SystemExit("new domain-core adapters while the crate is frozen:\n" + "\n".join(extra))
    print(f"domain-core freeze OK ({len(adapters)} adapters, all baselined)")
PY
