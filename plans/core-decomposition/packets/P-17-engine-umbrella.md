# Packet P-17: verify/complete OpenBurnBarEngine umbrella (UI-free)
STATE: DONE (verified — Engine builds, closure is UI-free)
LANE: Integrator          DEPENDS-ON: S0, P-01/P-12 (LogParsers), P-13 (Quota), P-14 (VectorKit), P-05 (Hermes), P-06 (Pretext)
BASELINE-TOUCHING: none

The Engine umbrella source (`OpenBurnBarEngine/OpenBurnBarEngine.swift`) already exists
from S0 with `@_exported import` of {Kernel, LogParsers, Quota, VectorKit, Hermes,
Pretext}. This packet is the VERIFICATION gate that Engine re-exposes everything the
daemon consumes today, AFTER those leaf targets are populated by their move packets.

## Verification result (2026-07-13)
Each `@_exported` leaf was checked against its live Sources:
- Kernel — populated (139 swift files). ✅
- LogParsers — populated (27 swift files). ✅
- VectorKit — populated (9 swift files). ✅
- Hermes — populated (7 swift files). ✅
- Pretext — populated (2 swift files + Resources bundle). ✅
- **Quota — NOT extracted.** Only `ModuleMarker.swift` remains; the P-13 Quota move
  packet was reverted (Quota stayed entangled with LogParser/SQLite/utils in
  OpenBurnBarCore per the structural-remediation program). The `@_exported import
  OpenBurnBarQuota` line re-exposes no usable symbol yet — it is a valid forward
  declaration that lights up automatically when Quota is moved. **The daemon consumes
  ZERO Quota types** (verified: no `ProviderQuota*`/`Quota*` references in
  `OpenBurnBarDaemon/Sources`), so the empty re-export does not affect the S17 repoint.
  The Engine source comment now records this honestly.

## Changes
- `OpenBurnBarEngine/OpenBurnBarEngine.swift` — replaced the stale "S0 markers" comment
  with the true per-leaf verification status (Quota still marker-only, and why it is
  harmless). No `@_exported` line added or removed: the umbrella already matched the
  daemon's real consumption.
- `scripts/debt/check-engine-closure-ui-purity.sh` — new reproducible proof. Derives
  the Engine transitive closure from `swift package dump-package` and asserts (a) no
  UI-carrying target (UI/Core/Insights/TextExpansion/LaunchServices) is reachable and
  (b) no closure file imports SwiftUI/AppKit. Complements the per-target assert-zero in
  `check-core-ui-purity-budget.sh` with a closure-level guarantee.

## Validation (all green)
- `swift build --target OpenBurnBarEngine` → Build complete (52s).
- `bash scripts/debt/check-engine-closure-ui-purity.sh` → Engine closure = 9 targets
  {Engine, FirestoreModels, Hermes, Kernel, LogParsers, Pretext, Quota, SQLiteReader,
  VectorKit}, zero SwiftUI/AppKit, no UI target reachable.
- `bash scripts/debt/check-core-ui-purity-budget.sh` → OK (all pure targets clean).
- No circular edge: Engine does not `import OpenBurnBarCore`; Core does not re-export
  Engine.
