# Packet P-17 (DRAFT): fill/verify OpenBurnBarEngine umbrella
STATE: QUEUED
LANE: Integrator          DEPENDS-ON: S0, P-01/P-12 (LogParsers), P-13 (Quota), P-14 (VectorKit), P-05 (Hermes), P-06 (Pretext)
BASELINE-TOUCHING: none

The Engine umbrella source (`OpenBurnBarEngine/OpenBurnBarEngine.swift`) already exists
from S0 with `@_exported import` of {Kernel, LogParsers, Quota, VectorKit, Hermes,
Pretext}. This packet is the VERIFICATION gate that Engine re-exposes everything the
daemon consumes today, AFTER those leaf targets are populated by their move packets. It
may be a no-op PR (if S0's umbrella is already complete) or add missing `@_exported`
lines if a daemon-consumed leaf was added.

## Scope
- If the daemon needs a symbol not yet re-exported by Engine, add the missing
  `@_exported import <LeafTarget>` line to `OpenBurnBarEngine.swift`. The leaf must
  already be an Engine DEPENDENCY in Package.swift (S0 declared Kernel/LogParsers/Quota/
  VectorKit/Hermes/Pretext). Adding a NEW Engine dependency is a manifest change —
  integrator-only, document it.
- CRITICAL: Engine must NOT `@_exported import OpenBurnBarCore` and Core must NOT
  re-export Engine (no `EngineReexport.swift` in Core). Verify no circular edge.

## Validation
- `swift build --target OpenBurnBarEngine`
- Link-graph proof: `swift build --target OpenBurnBarEngine` then confirm OpenBurnBarUI
  / Views are NOT in Engine's transitive closure (dump-package + grep, or the daemon
  link map at S17).
- V1–V11 as applicable. Title: "P-17: verify/complete OpenBurnBarEngine umbrella
  (UI-free)". A1–A6.
