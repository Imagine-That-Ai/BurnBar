# Architecture

## Mission Scope
This mission hardens token accounting and indexing so token totals are exact-first, fallback estimates are explicit and auditable, and indexing work scales with deltas instead of full rescans.

## Core Components

### Ingestion Layer
- Provider parsers and bridges produce token usage events from local logs, sqlite snapshots, in-app chat, daemon, cursor bridge, and provider APIs.
- Ingestion output is normalized into a canonical usage key: `(provider, sessionId, model, sourceDeviceId)`.

### Canonical Usage Persistence
- `token_usage` is the canonical store for usage rows.
- Canonical rows carry provenance metadata (method/confidence/estimator version) and support deterministic precedence (exact over estimate).
- Upsert semantics enforce idempotency and controlled promotion (estimate -> exact).
- `usageSource` remains explicit (`provider_log`, `in_app_chat`, `cursor_bridge`, `daemon`, `billing_api`) even when rows converge on one canonical key.

### Checkpoint and Sync State
- Parser checkpoint/high-watermark state tracks incremental progress and restart safety.
- Remote download watermark state controls cloud-sync ingestion windows and must only advance on durable success.

### Reconciliation Layer
- Supplemental usage reconciliation aligns local canonical usage with API-derived totals.
- Backfill operates in throttled windows (7 days/run) to keep compute bounded.
- Reconciliation is deterministic and idempotent after convergence.
- Cleanup is source-safe (reconciliation-owned rows only) and must not delete non-reconciliation usage.
- Cost-only drift handling is explicit (persist correction or explicit deferred marker by policy).

### Projection and Search Indexing
- Conversation projection pipeline materializes search/index artifacts.
- Event-driven updates enqueue affected scopes.
- Scheduled reconciliation/repair addresses missed events.
- Indexing and embedding paths skip unchanged work where hashes/versions prove no delta.
- Stale-source-version jobs are explicit no-ops.
- Lease recovery and retries are idempotent (no duplicate write side effects).
- Rebuild/re-embed paths must paginate to full corpus completion.
- If semantic embedding fails, lexical retrieval continuity is preserved and degradation is surfaced.

### Reporting Layer
- Dashboard/API aggregates read canonical usage.
- Reporting must remain consistent with canonical precedence outcomes and expose provenance-aware confidence semantics.

## Data Flow (High-Level)
1. Source events arrive from parsers/bridges/APIs.
2. Extract/normalize usage into canonical shape.
3. Apply precedence and persist canonical token rows.
4. Advance checkpoints/watermarks only after durable success.
5. Trigger incremental projection/indexing for changed scopes.
6. Run scheduled reconciliation/backfill to repair drift.
7. Surface corrected totals and provenance-aware metadata in reporting.

## Precedence and Conflict Rules
- Primary ordering: `exact` > `derived-exact` (normalized from exact totals) > `high-confidence estimate` > `lower-confidence estimate`.
- For same confidence class, newer authoritative evidence wins deterministically by configured tie-break policy.
- Late exact arrivals promote prior estimates to exact canonical rows.
- Remote correction behavior is explicit and deterministic for duplicate logical keys.
- Fallback estimation is allowed only when exact buckets are unavailable; normalization from exact totals is not fallback.

## Commit/Visibility Boundary
- Required ordering for ingestion writes: persist canonical row(s) -> commit transaction -> advance checkpoint/watermark -> enqueue downstream work.
- On failure before commit, checkpoint/watermark must not advance and downstream/reporting surfaces must not expose partial state.

## Architectural Invariants
- Exact-first: exact token data always wins over lower-confidence estimates.
- Idempotent ingestion: replaying the same source does not create duplicates.
- Deterministic canonical selection: same inputs produce same canonical rows.
- Bounded work: unchanged data should not trigger full rescans/reindex by default.
- Safe recovery: failures do not advance progress markers and do not lose data.
- Observable confidence: exact vs fallback origin is auditable.
- Tokenizer fallback path is feature-flagged, default-off, and non-blocking.
