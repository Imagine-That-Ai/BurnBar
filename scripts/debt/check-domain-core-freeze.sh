#!/usr/bin/env bash
# Freeze the half-on Rust domain core: default mode must stay .legacy until a
# domain completes promotion AND legacy deletion. New DomainCore*Adapter.swift
# files are shrink-only against the checked-in list. Pure re-export shims
# (comments/blank lines plus a single @_exported import, e.g. the Wave 3.2
# Kernel-split shims) add no adapter surface and are exempt; any other code
# in a matching file trips the freeze.
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


def is_pure_reexport(path):
    exports = 0
    for line in Path(path).read_text().splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("//"):
            continue
        if stripped.startswith("@_exported import "):
            exports += 1
            continue
        return False
    return exports == 1


adapters = sorted(p.as_posix() for p in root.rglob("*DomainCore*Adapter.swift"))
real = [p for p in adapters if not is_pure_reexport(p)]
shims = [p for p in adapters if p not in real]
baseline = Path("budgets/domain-core-adapter-baseline.txt")
if not baseline.exists():
    baseline.write_text("\n".join(real) + ("\n" if real else ""))
    print(f"wrote {baseline} ({len(real)} adapters)")
else:
    allowed = {line for line in baseline.read_text().splitlines() if line.strip()}
    extra = [p for p in real if p not in allowed]
    if extra:
        raise SystemExit("new domain-core adapters while the crate is frozen:\n" + "\n".join(extra))
    print(f"domain-core freeze OK ({len(real)} adapters, all baselined; {len(shims)} pure re-export shims exempt)")
PY
