# User Testing

Testing surface guidance for BurnBar validation. BurnBar has two major subsystems: the **account switcher** and the **exact-first token accounting & hybrid indexing system**. This document covers validation surfaces for both.

---

## Part I: Token Accounting & Indexing (Current Mission)

### Validation Surface

#### Surface T1: Token ingestion and extraction invariants (primary)
- Scope: exact-first precedence, provider-specific parser behavior (Codex, Factory, Claude, Kimi, Hermes, Cursor), fallback gating, reasoning/cache bucket integrity, source identity preservation.
- Tools: `xcodebuild test` scoped parser tests (`CLIBridgeTests`, `CursorConnectorTests`, `TokenUsageProvenanceTests`).
- Key assertions: `VAL-TOKEN-001` through `VAL-TOKEN-012`.

#### Surface T2: Persistence, provenance, and checkpoint behavior (primary)
- Scope: row-level provenance, canonical precedence guard, checkpoint/watermark advancement, corruption recovery, remote sync semantics.
- Tools: `xcodebuild test` (`TokenAccountingPrecedenceTests`, `RemoteSyncWatermarkTests`) + `sqlite3` schema/row queries.
- Key assertions: `VAL-PERSIST-001` through `VAL-PERSIST-014`.

#### Surface T3: Reconciliation and backfill (primary)
- Scope: deterministic/idempotent reconciliation, multi-source baseline, cost-only drift guard, source-scoped cleanup, 7-day backfill window, monotonic cursor, live ingestion coexistence.
- Tools: `xcodebuild test` (`BackfillSchedulerTests`, `MultiSourceReconciliationTests`) + `sqlite3` evidence.
- Key assertions: `VAL-PERSIST-006`–`008`, `VAL-PERSIST-012`–`013`, `VAL-CROSS-003`–`004`.

#### Surface T4: Hybrid incremental indexing (primary)
- Scope: event-driven enqueue, burst dedup, gap repair, chunk diff persistence, embedding efficiency, pagination coverage, stale job handling, failure degradation.
- Tools: `xcodebuild test` (`ProjectionPipelineServiceTests`) + `scripts/test-openburnbar-retrieval-evals.sh`.
- Key assertions: `VAL-INDEX-001` through `VAL-INDEX-013`.

#### Surface T5: Cross-area flows (primary)
- Scope: exact-first upgrade propagation, refresh cost boundedness, backfill/live coexistence, provenance-aware reporting, datastore auditability, convergence parity, atomic visibility.
- Tools: `xcodebuild test` (`CrossSurfaceUpgradeTests`) + `sqlite3` audit queries.
- Key assertions: `VAL-CROSS-001` through `VAL-CROSS-011`.

#### Surface T6: Datastore evidence queries (supplementary)
- Scope: dedupe verification, precedence ordering, source identity, checkpoint state, reconciliation artifacts.
- Tools: `sqlite3` direct queries against the app database.
- Example queries:
  - Duplicate check: `SELECT provider,sessionId,model,COALESCE(sourceDeviceId,''),COUNT(*) FROM token_usage GROUP BY 1,2,3,4 HAVING COUNT(*)>1;`
  - Source identity: `SELECT usageSource,COUNT(*) FROM token_usage GROUP BY usageSource;`
  - Reconciliation cleanup: `SELECT usageSource,sessionId FROM token_usage WHERE sessionId LIKE 'api-reconcile-%' LIMIT 20;`
  - Schema verification: `PRAGMA table_info(token_usage);`

### Validation Concurrency (Token Accounting)

Conservative profile per mission guidelines:
- When Xcode tests run: **max 1 concurrent heavy validator**
- Lightweight validators (Swift package tests, lint): **up to 2 concurrent**
- `sqlite3` evidence queries: **up to 2 concurrent** (read-only)
- Avoid mixed heavy parallelism to keep compute stable

### Token Accounting Test Targets

| Target | Scope | Typical Command |
|--------|-------|-----------------|
| `CLIBridgeTests` | Provider parser contracts | `-only-testing:"OpenBurnBarTests/CLIBridgeTests"` |
| `CursorConnectorTests` | Cursor normalization/extraction | `-only-testing:"OpenBurnBarTests/CursorConnectorTests"` |
| `TokenAccountingPrecedenceTests` | Canonical precedence guard | `-only-testing:"OpenBurnBarTests/TokenAccountingPrecedenceTests"` |
| `TokenUsageProvenanceTests` | Provenance/source identity | `-only-testing:"OpenBurnBarTests/TokenUsageProvenanceTests"` |
| `BackfillSchedulerTests` | Backfill window/cursor/idempotency | `-only-testing:"OpenBurnBarTests/BackfillSchedulerTests"` |
| `MultiSourceReconciliationTests` | Reconciliation drift/cost/cleanup | `-only-testing:"OpenBurnBarTests/MultiSourceReconciliationTests"` |
| `CrossSurfaceUpgradeTests` | Cross-area exact upgrade flows | `-only-testing:"OpenBurnBarTests/CrossSurfaceUpgradeTests"` |
| `ProjectionPipelineServiceTests` | Indexing/chunk/embedding efficiency | `-only-testing:"OpenBurnBarTests/ProjectionPipelineServiceTests"` |
| `RemoteSyncWatermarkTests` | Remote watermark scope/safety | `-only-testing:"OpenBurnBarTests/RemoteSyncWatermarkTests"` |

### Flow Validator Guidance: m4-reconciliation-xcode

- Scope: token-accounting reconciliation/backfill hardening assertions for milestone `m4-reconciliation-backfill-hardening`:
  - `VAL-PERSIST-006`, `VAL-PERSIST-007`, `VAL-PERSIST-008`, `VAL-PERSIST-012`, `VAL-PERSIST-013`
  - `VAL-CROSS-003`, `VAL-CROSS-004`, `VAL-CROSS-005`, `VAL-CROSS-006`, `VAL-CROSS-010`
- Isolation boundary:
  - Read/write only assigned flow report path under `.factory/validation/m4-reconciliation-backfill-hardening/user-testing/flows/`.
  - Save evidence only under the assigned mission evidence folder.
  - Do not modify application source code during validation.
- Execution constraints:
  - Heavy `xcodebuild` runs are serialized (`max 1` concurrent heavy validator).
  - Use signing-off flags:
    - `CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' DEVELOPMENT_TEAM=''`
- Preferred scoped commands:
  - `xcodebuild test -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination "platform=macOS,arch=arm64" -only-testing:"OpenBurnBarTests/BackfillSchedulerTests" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' DEVELOPMENT_TEAM=''`
  - `xcodebuild test -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination "platform=macOS,arch=arm64" -only-testing:"OpenBurnBarTests/MultiSourceReconciliationTests" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' DEVELOPMENT_TEAM=''`
  - `xcodebuild test -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination "platform=macOS,arch=arm64" -only-testing:"OpenBurnBarTests/CrossSurfaceUpgradeTests" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' DEVELOPMENT_TEAM=''`
- Supplemental evidence commands:
  - `sqlite3 "$HOME/Library/Application Support/OpenBurnBar/OpenBurnBar.sqlite" "SELECT usageSource, COUNT(*) FROM token_usage WHERE usageSource='billing_api' GROUP BY usageSource;"`

---

## Part II: Account Switcher

### Validation Surface

#### Surface A: Native macOS UI flows (primary)
- Scope: Settings, Dashboard, and Popover switcher behavior (management, switching, status/error/empty states, accessibility).
- Tools: `xcodebuild test` (UI/integration tests), scoped test targets.

#### Surface B: Launch orchestration contracts (primary)
- Scope: Browser launch (Chrome/Safari), CLI launch (Codex/Claude/OpenCode), typed errors, race handling, safety constraints.
- Tools: `swift test`, scoped `xcodebuild test`, command-level smoke checks.

#### Surface C: Cross-surface flows (primary)
- Scope: create in Settings -> use in Dashboard/Popover, global active-state consistency, relaunch persistence, cross-surface switch+launch chains.
- Tools: `xcodebuild test` integration/UI + event/log inspection.

#### Surface D: Security and persistence checks (primary)
- Scope: metadata-only persistence, no cookie/session import, no plaintext secret leakage, log redaction.
- Tools: `swift test`, file/storage inspection commands, log scans.

### Validation Concurrency (Switcher)

User-approved profile: **max concurrent validators = 4**

Recommended scheduling:
- Heavy validators (`xcodebuild test`): **max 1 concurrent**
- Medium validators (`swift test` package suites): **max 1 concurrent**
- Lightweight smoke/log/storage checks: **up to 2 concurrent**

### Flow Validator Guidance

- Run from repo root (`/Users/dewclaw/Documents/Projects/BurnBar`).
- Keep validator artifacts in `.factory/validation/<milestone>/user-testing/`.
- Include signing-off flags for Xcode runs when needed:
  - `CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' DEVELOPMENT_TEAM=''`
- Prefer scoped commands tied to assertion IDs before broader suites.
- Respect protected local ports: `5000`, `7000`, `8642`, `11434`.
- For browser launch verification, use non-destructive app checks/smokes (`open -Ra`, targeted open commands) and pair with launcher invocation assertions.

### Evidence Expectations (Switcher)

- Command outputs with exit codes for each assertion group.
- UI evidence (snapshots/interaction traces) for Settings/Dashboard/Popover assertions.
- Launch invocation traces (target app/executable, profile ID, argv/env-allowlist evidence).
- Persistence/log evidence proving metadata-only storage and secret-safe logging.

### Flow Validator Guidance: xcodebuild-ui

- Scope: Settings switcher user-surface assertions (`VAL-SETTINGS-*`).
- Isolation boundary: read/write only `.factory/validation/core-engine/user-testing/flows/` and mission evidence folder assigned in prompt.
- Run only scoped UI/integration tests:
  - `xcodebuild test -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination "platform=macOS,arch=arm64" -only-testing:"OpenBurnBarTests/SwitcherSettingsUITests" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' DEVELOPMENT_TEAM=''`
- Do not start/stop unrelated services; no port/process mutations.

### Flow Validator Guidance: launch-contracts

- Scope: browser + CLI launch and security assertions (`VAL-BROWSER-*`, `VAL-CLI-*`).
- Isolation boundary: same repository only; no writes outside assigned flow report/evidence outputs.
- Preferred commands:
  - `xcodebuild test -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination "platform=macOS,arch=arm64" -only-testing:"OpenBurnBarTests/SwitcherBrowserLaunchTests" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' DEVELOPMENT_TEAM=''`
  - `xcodebuild test -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination "platform=macOS,arch=arm64" -only-testing:"OpenBurnBarTests/SwitcherCLILaunchTests" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' DEVELOPMENT_TEAM=''`
  - `open -Ra "Safari" && open -Ra "Google Chrome"`
- Keep logs/evidence secret-safe (no credential/token dumps).

### Flow Validator Guidance: fast-surfaces-ui

- Scope: Dashboard + Popover quick-switch user-surface assertions for milestone `fast-surfaces` (`VAL-DASH-*`, `VAL-POPOVER-*`).
- Isolation boundary:
  - Read/write only the assigned flow report under `.factory/validation/fast-surfaces/user-testing/flows/`.
  - Save evidence only under the assigned mission evidence folder.
  - Do not modify application source code during validation.
- Execution constraints:
  - Use scoped xcode tests tied to assigned assertions only.
  - Keep to one heavy `xcodebuild test` process at a time across all validators.
  - Use signing-off flags when needed:
    - `CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' DEVELOPMENT_TEAM=''`
- Allowed verification commands:
  - `xcodebuild test -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination "platform=macOS,arch=arm64" -only-testing:"OpenBurnBarTests/SwitcherDashboardUITests" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' DEVELOPMENT_TEAM=''`
  - `xcodebuild test -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination "platform=macOS,arch=arm64" -only-testing:"OpenBurnBarTests/SwitcherPopoverUITests" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' DEVELOPMENT_TEAM=''`
- Evidence note:
  - For `.xcresult` JSON extraction on current Xcode CLT, prefer `xcrun xcresulttool get object --legacy --path <bundle> --format json` over deprecated `get` forms.

### Crossflow UI seam reliability notes (integration-hardening)

- For `SwitcherCrossFlowTests`, avoid relying only on view-local `@State` profile collections in debug seams. Use store-backed fallback seams for active-indicator getters so assertions remain deterministic after reload/hydration paths.
- In tests that call `testTriggerSelectAndSwitch`, follow with `testTriggerReload` before asserting rendered indicator seams when view-local state may be stale; this aligns assertions with persisted active-profile state used by Dashboard/Popover test seams.

---

## Shared Cross-Subsystem Guidance

### General Evidence Standards

- Command outputs with exit codes for each assertion group.
- Datastore evidence queries (`sqlite3`) for persistence/precedence/checkpoint assertions.
- No credential/token dumps in any evidence output.

### Derived-Data Isolation

Test scripts use per-invocation derived-data isolation (unique `.derived-data/ci-*` directories) to prevent cleanup/build-db race conditions between consecutive validator runs.

### Validation Commands (from services.yaml)

| Command | Description |
|---------|-------------|
| `scripts/test-openburnbar-swift.sh` | Swift package tests |
| `scripts/test-openburnbar-app.sh` | Full app test suite |
| `scripts/test-openburnbar-retrieval-evals.sh` | Retrieval/projection correctness |
| `swift test --package-path OpenBurnBarCore` | Core package tests only |
