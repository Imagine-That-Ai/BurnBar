# Archived test suites

Stale or environmental XCTest sources that do **not** compile against current `OpenBurnBarTests` contracts. Kept for migration reference only.

Revival workflow:

1. Port cases to `AgentLensTests/Active/` using current public or `@testable` APIs.
2. Prove with `./scripts/test-openburnbar-app.sh`.
3. Delete the archived source once fully ported.

See **[QUARANTINE_MANIFEST.md](../Quarantine/QUARANTINE_MANIFEST.md)** for per-test owners, reasons, and revival criteria.

Legacy parser/performance monoliths: [docs/adr/2026-05-27-archive-legacy-parser-performance-tests.md](../../docs/adr/2026-05-27-archive-legacy-parser-performance-tests.md).
