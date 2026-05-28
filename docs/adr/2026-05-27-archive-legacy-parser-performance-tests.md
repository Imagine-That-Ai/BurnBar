# ADR: Archive legacy ParserTests and PerformanceTests quarantine suites

**Status:** Accepted  
**Date:** 2026-05-27

## Context

`AgentLensTests/Quarantine/Parsers/ParserTests.swift` and `AgentLensTests/Quarantine/PerformanceTests.swift` predate the current per-provider parser surface and GRDB/performance contracts. They reference removed helper types, monolithic parser internals, and legacy `XCTPerformanceMetric` APIs.

Active coverage now lives in:

- `AgentLensTests/Active/Parsers/` — per-provider parser suites aligned to current public APIs
- Targeted performance assertions in domain-specific active tests where needed

## Decision

Keep both archived suites under `AgentLensTests/Archive/` (moved from `Quarantine/` on 2026-05-27) as migration reference only. Do not compile them into `OpenBurnBarTests` until rewritten against current contracts.

Revival criteria (if ever needed):

1. Split monolithic parser cases into per-provider active files matching `AgentLensTests/Active/Parsers/` patterns.
2. Replace legacy performance metric APIs with current XCTest measurement APIs and DataStore contracts.
3. Prove with `./scripts/test-openburnbar-app.sh`.

## Consequences

- CI stays green without maintaining stale compilation targets.
- Historical test intent remains discoverable in quarantine for porting individual cases.
- No false signal from skipped/broken legacy suites in the active target.
