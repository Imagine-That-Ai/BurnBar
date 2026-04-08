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

## Flow Validator Guidance: Swift/Xcode Contract Tests

- Isolation boundary: run from repo root (`/Users/dewclaw/Documents/Projects/BurnBar`) and keep all temporary outputs under `.factory/validation/<milestone>/user-testing/` and mission `evidence/` folders.
- Treat `xcodebuild test` as heavy: run only one flow validator that executes Xcode tests at a time.
- In validator environments, include signing-off flags for Xcode tests (`CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' DEVELOPMENT_TEAM=''`) to avoid entitlement signing failures.
- Prefer scoped test commands tied to assigned assertion IDs; do not run unrelated full-suite commands unless required to unblock a scoped failure.
- If a flow validator needs derived data, use a group-specific path (for example `.derived-data/user-testing-<group-id>`) to avoid cross-run collisions.
- Do not modify or stop local services on protected ports (`5000`, `7000`, `8642`, `11434`).
- Record concrete evidence (command output snippets, failing/passing test names, SQL query output) in the group report and evidence directory.

## Evidence Expectations
- Persist command outputs from scoped tests.
- Include concrete datastore evidence (`sqlite3` query results) for precedence/idempotency assertions.
- For efficiency assertions, include counters/logs showing incremental path usage and no accidental full rebuilds.
