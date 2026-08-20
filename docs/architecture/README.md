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
| [007-ops-notification-plane.md](007-ops-notification-plane.md) | GCP Monitoring + Sentry + deploy gates |
| [008-remote-control-engine.md](008-remote-control-engine.md) | Iroh-first remote desktop, media, and remote-control engine |
| [010-project-code-static-parser.md](010-project-code-static-parser.md) | Stateless local Tree-sitter helper for Project Code Memory |
| [011-stripe-redirect-url-validation.md](011-stripe-redirect-url-validation.md) | Exact-loopback + optional origin allowlist for Stripe redirects |
| [014-shared-rust-domain-core.md](014-shared-rust-domain-core.md) | Pure duplicated business logic shared through Rust adapters |
| [015-adaptive-backdrop-foreground.md](015-adaptive-backdrop-foreground.md) | Rendered-frame contrast sampling and semantic foregrounds for macOS and Linux |
| [015-windows-tpm-app-check.md](015-windows-tpm-app-check.md) | Windows lower-trust TPM custom App Check and verifier boundary |

Related operational docs:

- [Observability contract](../OBSERVABILITY.md) — trace fields and structured logging
- [SLO runbook](../runbooks/slos.md) — latency, availability, error budgets, alert paths
- [Tech debt strategy](../TECH_DEBT_STRATEGY.md) — phased remediation roadmap
- [Tech debt metrics](../TECH_DEBT_METRICS.md) — automated trend snapshot (CI-updated)

Legacy unnumbered filenames (`naming-conventions.md`, etc.) redirect here for bookmarks.
