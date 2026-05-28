# ADR 004: Schema canon and drift control

**Status:** Accepted (Phase 6 governance, 2026-05-27)  
**Scope:** Firestore, Cloud Functions, macOS, iOS, Android

## Context

Firestore document shapes were originally hand-maintained in `functions/src/types.ts` while clients duplicated models in Swift and Kotlin. Drift caused silent decode failures (`@IgnoreExtraProperties` masked missing fields) and blocked collaboration features.

## Decision

### Canon chain

```text
tools/schema-sync/typespec/*.tsp
        │ emit
        ├── functions/src/types.ts (+ generated sections)
        ├── OpenBurnBarCore/Sources/OpenBurnBarFirestoreModels/*.swift
        └── android/.../generated/*Models.kt
        │
        └── CI: ./tools/schema-sync/check-drift.sh
```

**Ownership:**

| Artifact | Owner | Change process |
|----------|-------|----------------|
| TypeSpec sources | Platform / backend | Edit `.tsp` → run emitters → commit all generated outputs |
| `functions/src/types.ts` | Cloud Functions | Generated blocks + legacy hand types during migration; new collections start in TypeSpec |
| Swift `*Models.swift` | macOS / iOS | Generated only; extend via computed properties in hand-written wrappers |
| Kotlin `generated/*` | Android | Generated only; `@PropertyName` for Firestore key drift |
| Firestore rules + indexes | Backend | Must match emitted field names; rules tests in CI |

### Rules

1. **Never edit generated files by hand** except through the emit pipeline (see [AGENTS.md](../../AGENTS.md) Android section).
2. **Legacy `types.ts` interfaces** remain until their TypeSpec module ships; track LOC in [TECH_DEBT_METRICS.md](../TECH_DEBT_METRICS.md) as migration progress.
3. **Rollups and usage** — Cloud Functions write five rollup docs (`today`, `7d`, `30d`, `90d`, `all_time`); clients merge windows locally (Android `mergeWindowDocs()`).
4. **Breaking changes** — require version bump in TypeSpec `@doc`, changelog entry, and coordinated mobile minimum version if decode requires new fields.

## Consequences

- PRs that touch Firestore shapes without schema-sync output fail CI.
- Android Firestore worker skill (`.factory/skills/android-firestore-worker/`) automates parity checks against canon.
- Hosted MCP and Computer Use ops docs reference the same collection names as emitted models.

## References

- [Technical readiness — schema](../TECHNICAL_READINESS.md)
- [Provider data reference](../PROVIDER_USAGE_DATA_REFERENCE.md)
- [Schema sync tooling](../../tools/schema-sync/check-drift.sh)
- [001-naming-conventions.md](001-naming-conventions.md)
- [005-sync-ownership.md](005-sync-ownership.md)
