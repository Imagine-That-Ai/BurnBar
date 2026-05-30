# Background

Context and rationale behind key engineering decisions in OpenBurnBar.

## Pages

| Page | Contents |
|------|----------|
| [Design decisions](design-decisions.md) | Local-first, GRDB, daemon-first, UniFFI, XcodeGen, Hermes dual-backend |

## Key documents

| Document | What it covers |
|----------|----------------|
| [AGENTS.md](../../AGENTS.md) | Agent contract — repo workflow, test expectations, scope rules |
| [docs/OPENBURNBAR_RELEASE_ARCHITECTURE.md](../../docs/OPENBURNBAR_RELEASE_ARCHITECTURE.md) | State ownership table, release planes (local / sync / cloud) |
| [docs/THREAT_MODEL.md](../../docs/THREAT_MODEL.md) | STRIDE threat model, trust boundaries, mitigations |
| [docs/TECH_DEBT_STRATEGY.md](../../docs/TECH_DEBT_STRATEGY.md) | Phased remediation roadmap |
| [docs/TECH_DEBT_METRICS.md](../../docs/TECH_DEBT_METRICS.md) | Automated trend snapshot (updated by CI) |

## Architecture ADRs

Five canonical ADRs in `docs/architecture/`:

| ADR | Decision |
|-----|----------|
| [001-naming-conventions.md](../../docs/architecture/001-naming-conventions.md) | `*Service`, `*Store`, `*Actor`, `*Client` suffix contract |
| [002-actor-boundaries.md](../../docs/architecture/002-actor-boundaries.md) | `@MainActor`, Swift actors, I/O placement |
| [003-error-handling.md](../../docs/architecture/003-error-handling.md) | Typed errors, structured logging, user-visible failures |
| [004-schema-canon.md](../../docs/architecture/004-schema-canon.md) | TypeSpec → `types.ts` → generated Swift & Kotlin |
| [005-sync-ownership.md](../../docs/architecture/005-sync-ownership.md) | Local SQLite vs Firestore vs iCloud planes |

## Tech debt

Run `./scripts/ci/update-tech-debt-metrics.sh` before monthly debt reviews. Commit updated `docs/TECH_DEBT_METRICS.md` when baselines shift intentionally. Long-lived stale test suites go under `AgentLensTests/Quarantine/` and are not compiled by default.
