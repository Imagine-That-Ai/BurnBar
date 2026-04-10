# Architecture

BurnBar is a macOS menu bar app with two major subsystems that share infrastructure but operate on distinct domains. This document covers **both** the account switcher and the token accounting / hybrid indexing system.

---

## Subsystem A: Account Switcher

### Scope
Native BurnBar multi-account switcher for fast profile-based switching across:
- Browser targets: Chrome, Safari
- CLI targets: Codex, Claude, OpenCode

Security model is strict: **no credential scraping/import**, metadata-only profile switching.

### Core Components

#### 1) Profile Registry + Persistence
- Canonical local store for switcher profiles.
- Profile types:
  - Browser profile (`chrome` or `safari`)
  - CLI profile (`codex`, `claude`, `opencode`)
- Persists non-secret launch metadata only (labels, target type, profile reference, options).
- Tracks active profile state and last-used metadata deterministically.

#### 2) Switch Orchestrator
- Single boundary for all switch actions.
- Enforces invariants:
  - Exactly one active profile per domain.
  - Deterministic state transitions (`idle -> switching -> success|failure`).
  - No split-brain state under rapid inputs (serialized/coalesced actions).

#### 3) Launch Adapters
- **Browser launcher adapter** — launches explicit app target (Chrome/Safari) using selected profile reference. Allowlisted arguments only. Never touches cookie/session/auth files.
- **CLI launcher adapter** — resolves trusted executable for Codex/Claude/OpenCode. Builds explicit argv and allowlisted env. No shell interpolation.

#### 4) UI Surfaces
- **Settings**: full profile management (create/edit/delete/activate, validation, boundary copy).
- **Dashboard**: quick switch and launch actions with clear status/recovery.
- **Menu bar popover**: fastest compact switch flow, keyboard/mouse parity, deterministic feedback.

#### 5) Cross-Surface State Synchronization
- Shared observable active-profile state consumed by Settings, Dashboard, and Popover.
- Navigation handoffs preserve active context.
- App relaunch restores active profile consistently on all three surfaces.

### Switcher Data Flow
1. User creates/edits profile in Settings.
2. Profile store validates and persists metadata-only record.
3. Active profile changes are published through switch orchestrator.
4. Dashboard/Popover render updated active state.
5. Launch action uses currently active profile and dispatches to browser/CLI adapter.
6. Adapter returns success/failure with typed diagnostics; UI shows actionable feedback.

### Switcher Security and Safety Invariants
- No cookie/session import path exists in UI or API.
- No raw OAuth credentials/tokens/passwords in plaintext profile storage.
- Browser and CLI launch logs are redacted and secret-safe.
- Browser profile/session/auth files are never mutated by switcher flows.
- CLI launches enforce trusted executable resolution, argv hardening, and env allowlisting.

---

## Subsystem B: Exact-First Token Accounting & Hybrid Indexing

### Scope
Track token usage and cost across AI coding agents (Claude Code, Factory Droid, Codex, Kimi, MiniMax, Cursor, etc.) with exact-first ingestion, auditable provenance, deterministic reconciliation, throttled historical backfill, and hybrid incremental indexing.

### Core Components

#### 1) Token Ingestion & Persistence
- **Provider-specific parsers**: extract token counts from provider logs/wire payloads (Codex, Factory, Claude, Kimi, Hermes, Cursor, etc.).
- **Exact-first precedence**: exact payload values (`input`, `output`, `reasoning`, `cacheRead`, `cacheCreation`) are always preserved. Provider-specific high-precision fallback estimation runs only when all exact buckets are absent/zero.
- **Canonical dedupe key**: `(provider, sessionId, model, sourceDeviceId)`. Repeated ingestion of the same key updates one canonical row — no duplicates.
- **Provenance metadata**: each row persists `provenanceMethod` (exact/estimate/tokenizer), `confidence`, and `estimatorVersion` fields for full auditability.
- **Precedence guard**: lower-confidence writes cannot replace exact canonical rows. Late exact arrivals promote prior estimated rows deterministically.
- **Source identity**: `usageSource` enum (`provider_log`, `in_app_chat`, `cursor_bridge`, `daemon`, `billing_api`) is preserved across all ingestion paths.

#### 2) Checkpoint & Watermark System
- **Parser checkpoint/high-watermark**: advances only after successful ingestion transaction commit. Resume from checkpoint is gap-free and duplicate-free.
- **Remote sync watermark**: advances only after durable success for the current sync scope. Account-aware and collection-safe.
- **Cache corruption recovery**: if parser signature/checkpoint cache is missing or corrupted, recovery reprocesses safely.

#### 3) Reconciliation
- **Deterministic & idempotent**: two reconciliation runs over identical input state produce identical output; rerun after convergence produces no material changes.
- **Multi-source baseline**: supplemental API reconciliation uses canonical multi-source baseline (all local ingestion sources) to prevent source-blind over/under-correction.
- **Cost-only drift guard**: cost drift without positive token deltas uses epsilon-safe thresholding to avoid phantom micro-corrections from floating-point residue.
- **Source-scoped cleanup**: cleanup of prior API-reconciliation rows is constrained by source semantics (`billing_api`), never deleting non-reconciliation rows.
- **Cross-source precedence**: overlapping parser/API windows respect confidence ordering — higher-confidence wins, no double counting.

#### 4) Backfill
- **Throttled 7-day window**: each scheduled backfill run processes at most 7 days of historical data.
- **Monotonic cursor**: backfill cursor progresses monotonically across runs with no regressions or overlaps. Equal-timestamp advances are idempotent; backward movement is strictly rejected.
- **Live ingestion coexistence**: backfill does not regress or duplicate newer exact rows. Conflict-resolution keeps live ingestion exact-first.
- **Commit-coupled advancement**: cursor advances only after durable persistence success.

#### 5) Hybrid Incremental Indexing
- **Event-driven enqueue**: committed source mutations enqueue indexing work only for affected conversations/documents.
- **Burst deduplication**: rapid repeated updates collapse to one effective indexing unit for the latest state.
- **Gap repair**: scheduled reconciliation detects and re-indexes only stale gaps, not blanket full rebuild.
- **Chunk diff persistence**: unchanged chunks are skipped; partial edits only rewrite impacted chunks. Embedding reuse for unchanged `(content_hash, embedding_model_version)` pairs.
- **Full-corpus pagination**: rebuild/re-embed operations paginate with deterministic tie-breakers to cover corpora larger than a single batch.
- **Failure degradation**: embedding failure preserves lexical continuity without silent data loss.
- **Stale job handling**: stale source-version jobs no-op without writes. Lease-recovery avoids duplicate write side effects.

### Token Accounting Data Flow
1. Provider log/wire events are parsed by provider-specific parsers.
2. Exact token buckets are extracted when present; fallback estimation runs only for exact-missing cases.
3. Canonical dedupe key determines insert vs. update with precedence guard.
4. Provenance metadata (method, confidence, version) is persisted per row.
5. Checkpoint advances only after commit.
6. Scheduled reconciliation detects drift, repairs gaps, and corrects costs using canonical multi-source baseline.
7. Backfill fills historical gaps in 7-day monotonic windows alongside live ingestion.
8. Indexing pipeline processes only changed scope, skipping unchanged chunks/embeddings.

### Token Accounting Invariants
- **Exact-first policy is mandatory**: exact data always outranks estimates.
- **Normalization is not fallback**: deriving `input/output` from `total_tokens` is normalization, not fallback mode.
- **Deterministic & idempotent ingestion**: same logical key produces same canonical outcome.
- **Checkpoint safety**: no partial visibility on pre-commit failure.
- **Backfill isolation**: 7-day window, monotonic cursor, no live-regression.
- **Indexing efficiency**: unchanged work is skipped; small deltas stay incremental.

---

## Shared Infrastructure

### Datastore
- SQLite via GRDB for all persistence (token_usage, conversations, search artifacts, projection queue, checkpoints).
- Schema migrations are additive; backward-compatible reads are preserved.

### Validation Surfaces
- **Swift package tests** (`swift test --package-path OpenBurnBarCore`) for core logic.
- **Xcode integration tests** (`xcodebuild test -only-testing:"OpenBurnBarTests/..."`) for app-level contracts.
- **Datastore evidence** (`sqlite3` queries) for precedence, dedupe, and checkpoint assertions.
- **Retrieval evals** (`scripts/test-openburnbar-retrieval-evals.sh`) for projection/retrieval correctness.
- **App test suite** (`scripts/test-openburnbar-app.sh`) for full integration gate.

### Port Boundaries
- Reserved helper port range: `3190-3199` (token-accounting mission).
- Off-limits: `5000`, `7000`, `8642`, `11434`.

### Test Infrastructure
- Per-invocation derived-data isolation to prevent cleanup/build-db race conditions.
- Scoped test targets by area (e.g., `BackfillSchedulerTests`, `MultiSourceReconciliationTests`, `CrossSurfaceUpgradeTests`, `ProjectionPipelineServiceTests`, `CLIBridgeTests`, `CursorConnectorTests`, `TokenAccountingPrecedenceTests`, `TokenUsageProvenanceTests`).
