# User Testing

Testing surface guidance for token-accounting accuracy and indexing-efficiency validation.

---

## Validation Surface

### Surface A: Swift/Xcode Contract Tests (Primary)
- Scope: token extraction precedence, provenance persistence, checkpoint/watermark safety, reconciliation determinism, indexing behavior.
- Tools: `xcodebuild test`, `swift test`, `sqlite3`.
- Notes: This mission is mostly non-UI correctness and compute-behavior oriented; assertions are validated primarily through deterministic tests and datastore evidence.

### Surface B: Retrieval/Projection Replay (Secondary)
- Scope: projection/index consistency and retrieval parity under incremental updates and reconciliation.
- Tools: scoped `xcodebuild test` replay suites.

### Surface C: Reporting Contracts
- Scope: provenance/confidence output visibility and filtered aggregate parity after upgrades/reconciliation.
- Tools: `xcodebuild test` reporting contract tests + datastore checks.

## Validation Concurrency

User-approved conservative profile:
- Heavy validators (any Xcode test run): **max 1 concurrent**
- Lightweight validators (`swift test`, `swiftlint`, small DB checks): **max 2 concurrent**
- Avoid mixed heavy parallel runs to reduce CPU/memory pressure and keep results deterministic.

## Evidence Expectations
- Persist command outputs from scoped tests.
- Include concrete datastore evidence (`sqlite3` query results) for precedence/idempotency assertions.
- For efficiency assertions, include counters/logs showing incremental path usage and no accidental full rebuilds.
