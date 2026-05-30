# Reference

Technical reference for OpenBurnBar configuration, schemas, protocols, and dependencies.

## Pages

| Page | Contents |
|------|----------|
| [Configuration](configuration.md) | Environment variables, feature flags, app settings, daemon config |
| [Data models](data-models.md) | Firestore schema, SQLite tables, Android model mapping |
| [Dependencies](dependencies.md) | Key libraries by platform (Swift, Kotlin, TypeScript, Rust) |
| [Daemon RPC surface](rpc-surface.md) | JSON-RPC 2.0 methods, socket protocol, auth |

## Quick links

- Canonical Firestore schema: `functions/src/types/legacy.ts`
- Schema sync check: `./tools/schema-sync/check-drift.sh`
- ADRs: `docs/architecture/`
- SLO runbook: `docs/runbooks/slos.md`
