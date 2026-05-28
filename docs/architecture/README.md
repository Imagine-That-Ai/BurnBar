# Architecture decision records

Canonical ADRs for cross-cutting engineering choices. Each record captures **context**, **decision**, and **consequences** so refactors stay aligned with the daemon-first, local-first product spine described in [OPENBURNBAR_RELEASE_ARCHITECTURE.md](../OPENBURNBAR_RELEASE_ARCHITECTURE.md).

Agent workflow: see [AGENTS.md](../../AGENTS.md) — search before building; ADRs are the review gate for naming, isolation, errors, schema, and sync.

| ADR | Topic |
|-----|--------|
| [001-naming-conventions.md](001-naming-conventions.md) | `*Service`, `*Store`, `*Actor`, `*Client` boundaries |
| [002-actor-boundaries.md](002-actor-boundaries.md) | `@MainActor`, actors, and I/O placement |
| [003-error-handling.md](003-error-handling.md) | Typed errors, logging, and user-visible failure modes |
| [004-schema-canon.md](004-schema-canon.md) | TypeSpec / `types.ts` / generated Swift & Kotlin |
| [005-sync-ownership.md](005-sync-ownership.md) | Local SQLite vs Firestore vs iCloud planes |

Related operational docs:

- [Observability contract](../OBSERVABILITY.md) — trace fields and structured logging
- [SLO runbook](../runbooks/slos.md) — latency, availability, error budgets, alert paths
- [Tech debt strategy](../TECH_DEBT_STRATEGY.md) — phased remediation roadmap
- [Tech debt metrics](../TECH_DEBT_METRICS.md) — automated trend snapshot (CI-updated)

Legacy unnumbered filenames (`naming-conventions.md`, etc.) redirect here for bookmarks.
