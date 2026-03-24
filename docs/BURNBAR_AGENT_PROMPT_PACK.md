# BurnBar Agent Prompt Pack

Use this pack to orchestrate the full "10x search" program with parallel agents while minimizing merge pain.

## Shared Preamble

Prepend this to every prompt:

```text
You are working in /Users/albertonunez/Developer/AgentLens on branch main.

BurnBar non-negotiables from the locked engineering review:
- Local-first authority. GRDB/SQLite is the hot-path source of truth on-device.
- Firebase/Firestore is replication, backup, shared-value infrastructure, and team/shared features. It is not the primary interactive search authority.
- Build a derived cross-artifact retrieval substrate instead of overloading conversations.
- Use one shared retrieval/intelligence service layer. Views must not own bespoke search logic.
- Use a durable local projection queue/outbox for indexing and backfills.
- Keep source artifacts first-class. Summaries and insights are derived.
- Hybrid retrieval is in scope now: lexical + semantic, lexical fallback mandatory, embedding model/version tracking mandatory, rebuild/re-embed support mandatory, evals mandatory.
- ANN is in scope now, but behind a swappable vector interface. Exact bounded rerank remains the quality baseline.
- Discover skills and agent docs only from registered roots + known patterns, not arbitrary markdown crawling.
- Materialize only stable, expensive insight rollups. Keep exploratory analysis on demand.
- Replace silent try?/print failure on critical paths with typed health/error states and degraded-mode UX.
- Split DataStore into focused DB modules over one shared DatabaseQueue.
- Shared/team skills and agent docs are in scope now, including RBAC, audit, and live collaborative editing with optimistic concurrency/conflict handling.
- Search documents must be chunked with parent linkage and offset metadata for long artifacts/transcripts.
- Well-tested code is non-negotiable: integration harness, replay/golden evals, deterministic fake embeddings in CI, migration/backfill/rebuild tests.

You are not alone in the codebase. Do not revert other people's work. Keep a minimal diff. Prefer explicit over clever. Reuse existing code and boundaries where possible. Add or update tests for your scope. If you need to touch a file outside your assigned write scope, keep it to the smallest interface-level change and call it out.

At the end, report:
1. Files changed
2. Tests run
3. Remaining risks or follow-up work
```

## Recommended Waves

- Wave 0, serial: `P00`
- Wave 1, serial foundation: `P01` -> `P02` -> `P03` -> `P04` -> `P05` -> `P06`
- Wave 2, parallel product work after Wave 1 interfaces settle: `P07`, `P08`, `P09`, `P10`, `P11`, `P12`
- Wave 3, parallel quality gates after Wave 1/2 stabilize: `P13`, `P14`, `P15`, `P16`, `P17`
- Wave 4, serial integration pass: `P18`

## P00: Architecture Spine

Owner:
- `docs/`
- interface planning only, with minimal code if needed for scaffolding notes

Depends on:
- none

Covers:
- all review decisions as an implementation map

Prompt:

```text
Read first:
- README.md
- AgentLens/Services/DataStore.swift
- AgentLens/Services/UsageAggregator.swift
- AgentLens/Services/SearchService.swift
- AgentLens/Services/ContextBuilder.swift
- AgentLens/Services/InsightEngine.swift
- AgentLens/Services/CloudSyncService.swift
- AgentLens/Views/SessionLogs/SessionLogsView.swift
- docs/BURNBAR_IMPLEMENTATION_CHECKLIST.md

Write a concrete implementation blueprint for the locked BurnBar search program. I need an engineer-facing doc that turns the review decisions into an execution map with:
- module boundaries
- data model changes
- projection pipeline
- retrieval pipeline
- team/shared artifact lifecycle
- RBAC/audit/collaboration model
- test strategy
- performance guardrails
- rollout/backfill/rebuild plan

Requirements:
- Use ASCII diagrams for the projection pipeline, retrieval pipeline, and collaboration/sync flow.
- Point to existing code we should reuse and the exact seams where new modules should attach.
- Propose file/module names consistent with this repo.
- Keep it implementation-oriented, not product-marketing prose.
- If you make any code changes, keep them minimal and doc-driven only.
```

## P01: Local Search Schema + Store Split

Owner:
- `AgentLens/Services/DB/**` or equivalent new DB modules
- `AgentLens/Services/DataStore.swift`
- targeted tests for schema/store access

Depends on:
- `P00`

Covers:
- `1B`, `8A`, `9A`

Prompt:

```text
Read first:
- AgentLens/Services/DataStore.swift
- AgentLens/Models/ConversationRecord.swift
- project.yml

Refactor the database layer so BurnBar has a real retrieval substrate instead of a conversations-only search path.

Deliver:
- Split DataStore responsibilities into focused DB modules over one shared DatabaseQueue.
- Add migrations and store APIs for a derived search corpus, including tables equivalent to:
  - search_documents
  - search_chunks
  - projection_jobs / outbox
  - embedding_models / embedding_versions
  - retrieval/index health
- Keep source-of-truth artifacts separate from derived search state.
- Preserve existing conversation and token storage behavior.
- Add typed data models and explicit repository methods instead of pushing more logic into one giant DataStore file.

Rules:
- Minimize diff outside the DB layer.
- Add migration tests or store tests for new tables and indexes.
- Do not build UI here.
- Leave clean seams for projection, retrieval, and rebuild flows.
```

## P02: Artifact Discovery + Source Ingest

Owner:
- artifact discovery/import services
- settings hooks for registered roots and known patterns
- tests for discovery boundaries

Depends on:
- `P01`

Covers:
- `4A`, `6A`, part of `11A`

Prompt:

```text
Read first:
- AgentLens/Services/UsageAggregator.swift
- AgentLens/Services/DataStore.swift or the new DB modules from P01
- existing settings/privacy/indexing code

Implement bounded artifact discovery and source ingestion for skills and agent docs.

Deliver:
- Discovery from registered roots only.
- Known pattern matching for skills and agent docs such as SKILL.md, AGENTS.md, and any repo-specific equivalents already present.
- Source-record upsert/delete flow that emits projection jobs instead of indexing inline.
- Clear opt-in/opt-out handling and path provenance.
- Tests proving BurnBar does not crawl arbitrary markdown outside approved roots/patterns.

Rules:
- Reuse existing provider/CLI ingestion boundaries where possible.
- Treat discovered files as source artifacts, not derived summaries.
- No silent failures; discovery problems must surface through typed health/error state.
```

## P03: Durable Projection Queue + Chunking Pipeline

Owner:
- projection job runner
- chunking/projector logic
- rebuild/replay plumbing

Depends on:
- `P01`, `P02`

Covers:
- `3A`, `16A`, part of `15A`

Prompt:

```text
Read first:
- the DB/search modules from P01
- AgentLens/Services/UsageAggregator.swift
- AgentLens/Services/ContextBuilder.swift

Build the durable local projection pipeline for all searchable artifacts.

Deliver:
- A projection queue/outbox with durable job states, retries, resume-on-restart, and idempotent processing.
- Projectors for conversations, skills, and agent docs that generate search_documents and bounded search_chunks.
- Chunk metadata with parent linkage, source type, offsets/ranges, timestamps, and projection version.
- Rebuild and selective reproject entrypoints.
- Tests for crash recovery, duplicate suppression, delete handling, and deterministic chunking.

Rules:
- Do not do inline indexing inside refresh loops.
- Keep the queue local-first and fast.
- Expose enough health data for degraded-mode UI later.
```

## P04: Shared Hybrid Retrieval Service

Owner:
- retrieval service layer
- shared search result model
- ranking/filtering/snippet assembly

Depends on:
- `P01`, `P03`

Covers:
- `5B`, `8A`, `17A`

Prompt:

```text
Read first:
- AgentLens/Services/SearchService.swift
- AgentLens/Services/DataStore.swift or replacement modules
- AgentLens/Views/Chat/ChatSessionController.swift
- AgentLens/Views/SessionLogs/SessionLogsView.swift

Replace the thin search wrapper with a real shared retrieval service.

Deliver:
- A shared retrieval API for all search consumers.
- Hybrid retrieval with lexical candidate generation, semantic/vector support, bounded candidate sets, exact rerank, and lexical fallback.
- Stable result/snippet/filter models that can represent conversations, skills, and agent docs.
- Query-time filters for provider, project, artifact type, date range, ownership/visibility, and source.
- Tests for lexical wins, semantic rescue, empty-query behavior, and filter correctness.

Rules:
- Exact bounded rerank is the correctness baseline.
- Keep interfaces explicit and testable.
- No UI implementation in this prompt beyond minimal adapter changes if necessary.
```

## P05: ANN Backend + Vector Index Management

Owner:
- vector backend abstraction
- ANN implementation
- embedding/version management and rebuilds

Depends on:
- `P03`, `P04`

Covers:
- `5B`, `17A`, `T1C`

Prompt:

```text
Read first:
- retrieval/projection modules from P03/P04
- any existing embedding or model-provider code in the repo

Implement the vector side of BurnBar retrieval with a swappable ANN backend.

Deliver:
- A vector index interface with at least one ANN implementation and one exact/bounded fallback path.
- Embedding model/version tracking tied to projected chunks.
- Re-embed and vector-index rebuild flows.
- Deterministic fake-embedding support for CI.
- Tests and/or benchmarks showing ANN candidate generation can be swapped without changing the final quality baseline when exact rerank is enabled.

Rules:
- ANN is in scope, but it must not become the only path.
- Lexical fallback must keep search usable during embedding outages or rebuilds.
- Make failure modes explicit and observable.
```

## P06: Health, Errors, and Degraded-Mode UX Plumbing

Owner:
- health/error models
- critical-path UX state for indexing/retrieval failures
- replacement of silent try?/print behavior on owned paths

Depends on:
- `P01` through `P05`

Covers:
- `10A`

Prompt:

```text
Read first:
- AgentLens/Services/SearchService.swift
- AgentLens/Services/UsageAggregator.swift
- any settings/indexing/privacy UI already in the app

Implement typed health/error state and degraded-mode UX for the new search/indexing system.

Deliver:
- Explicit health models for parser/import, projection queue, embedding/vector pipeline, and rebuild status.
- Removal of silent critical-path failures such as try?/print on search/indexing paths you touch.
- User-visible degraded-mode messaging for "index stale", "semantic unavailable", "rebuild in progress", and "cloud/shared features unavailable".
- Tests for health-state transitions and degraded-mode behavior.

Rules:
- Prefer clear partial-service behavior over all-or-nothing failure.
- Keep error handling explicit and plumbed through service boundaries.
```

## P07: Consumer Parity Across Chat, Session Logs, and Context

Owner:
- `AgentLens/Views/Chat/**`
- `AgentLens/Views/SessionLogs/**`
- `AgentLens/Services/ContextBuilder.swift`
- `AgentLens/Views/Chat/InsightBriefCard.swift`

Depends on:
- `P04`, `P06`

Covers:
- `8A`

Prompt:

```text
Read first:
- AgentLens/Views/Chat/ChatSessionController.swift
- AgentLens/Views/SessionLogs/SessionLogsView.swift
- AgentLens/Services/ContextBuilder.swift
- AgentLens/Views/Chat/InsightBriefCard.swift
- retrieval/health modules from prior prompts

Make all existing BurnBar consumers use the shared retrieval/intelligence layer instead of bespoke local logic.

Deliver:
- Chat search backed by the shared retrieval service.
- Session Logs search/filtering backed by the same retrieval path, removing local substring divergence.
- ContextBuilder and insight brief inputs shifted onto shared retrieval/intelligence seams where appropriate.
- Tests proving parity for the same query across Chat and Session Logs.

Rules:
- Do not leave duplicate search logic in views.
- Keep UX behavior coherent with degraded-mode states from P06.
```

## P08: Draft/Refine Skills and Agent Docs

Owner:
- skill/agent-doc authoring flows
- retrieval-backed drafting/refinement prompts
- indexing integration for saved artifacts

Depends on:
- `P02`, `P03`, `P04`, `P07`

Covers:
- the product goal around creating/refining skills and agent docs

Prompt:

```text
Read first:
- existing chat/context/assistant flows
- artifact discovery/projector modules from P02/P03
- retrieval modules from P04

Build retrieval-backed draft/refine flows for skills and agent docs.

Deliver:
- A service boundary for "draft skill", "refine skill", "draft AGENTS.md", and "refine AGENTS.md" using retrieved prior work as context.
- Save/update flows that turn authored artifacts into source records and enqueue reprojection.
- Clear provenance so the user can tell which prior work informed a draft.
- Tests for save -> project -> searchable round-trip and basic prompt-context correctness.

Rules:
- Keep prompts/context bounded and explicit.
- Reuse the shared retrieval layer; do not invent a second context-building path.
- If UI is added, keep it minimal and aligned with existing BurnBar patterns.
```

## P09: Materialized Workflow Insight Rollups

Owner:
- insight rollup services
- freshness tracking
- insight consumers if needed

Depends on:
- `P03`, `P04`, `P07`

Covers:
- `7A`

Prompt:

```text
Read first:
- AgentLens/Services/InsightEngine.swift
- AgentLens/Views/Chat/InsightBriefCard.swift
- retrieval/projection modules from earlier prompts

Refactor BurnBar insights so stable, expensive workflow insights are materialized while exploratory analysis stays on demand.

Deliver:
- A rollup pipeline or store for stable insight snapshots derived from indexed/searchable state.
- Freshness metadata and invalidation rules tied to ingest/projection.
- Minimal consumer updates so insight surfaces can tell the difference between fresh, stale, rebuilding, and unavailable.
- Tests for freshness and stale-state behavior.

Rules:
- Do not recompute everything on every render.
- Keep experimental or ad hoc analysis out of the materialized path.
```

## P10: Team/Shared Library Sync

Owner:
- shared artifact sync layer
- Firestore integration for shared skills/docs metadata and content
- local cache representation for shared artifacts

Depends on:
- `P02`, `P03`, `P04`

Covers:
- `2A`, `T2C`

Prompt:

```text
Read first:
- AgentLens/Services/CloudSyncService.swift
- AgentLens/Services/ICloudSessionMirrorService.swift
- local artifact/search modules from prior prompts

Implement the shared/team library sync path for skills and agent docs, keeping BurnBar local-first.

Deliver:
- Local-first shared-artifact cache/state with Firestore replication and fetch/update flows.
- Shared artifact schemas and sync code for content, metadata, revision identifiers, and workspace/team ownership.
- Clear offline behavior: local search remains fast; shared/team state degrades explicitly when cloud is unavailable.
- Tests around sync serialization/deserialization and local/cloud divergence handling.

Rules:
- Do not make cloud the serving path for interactive search.
- Shared artifacts should still land in the local retrieval substrate.
```

## P11: RBAC, Visibility, and Audit Events

Owner:
- permission model
- visibility filtering
- audit trail persistence and query hooks

Depends on:
- `P04`, `P10`

Covers:
- `T3C`

Prompt:

```text
Read first:
- retrieval modules from P04
- cloud/shared modules from P10
- any existing Firebase auth/account code

Build team-grade access control, visibility filtering, and durable audit events for shared artifacts.

Deliver:
- A permission model covering personal, shared, workspace/team, and role-based visibility.
- Retrieval-time enforcement so unauthorized artifacts never leak into search, drafts, or insights.
- Audit events for create, update, share, permission change, rebuild, and conflict-resolution actions.
- Tests for visibility enforcement and audit emission.

Rules:
- Enforcement must live in service/retrieval boundaries, not only in views.
- If a user loses access, cached snippets/results must disappear or become inaccessible cleanly.
```

## P12: Live Collaborative Editing

Owner:
- shared artifact revision model
- optimistic concurrency/conflict handling
- collaboration-related sync logic

Depends on:
- `P10`, `P11`

Covers:
- `18B`

Prompt:

```text
Read first:
- shared-artifact sync code from P10
- RBAC/audit code from P11

Implement live collaborative editing for shared skills and agent docs from day one.

Deliver:
- A revision/concurrency model for shared artifacts with optimistic concurrency and explicit conflict detection.
- Merge/retry or revision-fork behavior that never silently overwrites teammate changes.
- Audit integration for edits and conflict outcomes.
- User-facing state for "remote update arrived", "your edit conflicted", and "resolved version saved".
- Tests for concurrent edit races, stale writes, and recovery outcomes.

Rules:
- Do not ship silent last-write-wins.
- Keep the model defensible for offline/laggy clients.
```

## P13: Integration Test Harness

Owner:
- `AgentLensTests/**`
- reusable harness utilities

Depends on:
- `P01` through `P06` interfaces mostly settled

Covers:
- `12A`

Prompt:

```text
Read first:
- existing tests in AgentLensTests
- project.yml
- the new search/indexing modules from previous prompts

Build a proper BurnBar integration harness for the search program.

Deliver:
- Temp DB/file-root harness utilities.
- Fake clock, fake embedder, and fixture builders for conversations, skills, and shared artifacts.
- Harness helpers for queue execution, reprojection, rebuild, and degraded-state assertions.
- CI-friendly deterministic behavior.

Rules:
- Do not depend on real cloud services or real embedding providers in default CI tests.
- Make this harness easy for the other test prompts to reuse.
```

## P14: Replay / Golden Retrieval and Authoring Evals

Owner:
- eval fixtures and replay suites
- deterministic retrieval baselines

Depends on:
- `P04`, `P05`, `P08`, `P13`

Covers:
- `13A`, `14A`

Prompt:

```text
Read first:
- docs/BURNBAR_IMPLEMENTATION_CHECKLIST.md
- test harness from P13
- retrieval and authoring modules from prior prompts

Add replay/golden eval coverage for the new retrieval and drafting system.

Deliver:
- Golden suites for lexical wins, semantic rescue, degraded-mode fallback, and filter correctness.
- Deterministic fake-embedding evals in main CI.
- Separate smoke coverage for real provider/embedding integration if the repo supports it.
- If authoring flows exist, add draft/refine eval cases for skills and agent docs with expected grounding behavior.

Rules:
- Keep goldens stable and debuggable.
- Compare ANN-backed flows against the exact-rerank baseline, not against hand-wavy expectations.
```

## P15: Migration, Backfill, Rebuild, and Recovery Tests

Owner:
- migration and recovery tests
- rebuild/re-embed test coverage

Depends on:
- `P01`, `P03`, `P05`, `P10`, `P13`

Covers:
- `15A`

Prompt:

```text
Read first:
- DB modules from P01
- projection/vector modules from P03/P05
- shared/cloud modules from P10
- test harness from P13

Add the safety-net tests for schema evolution and long-term operability.

Deliver:
- Old DB -> migrated schema tests.
- Projection backfill tests.
- Embedding backfill and model-version transition tests.
- Rebuild/re-embed recovery tests after interruption or partial failure.
- Shared/cloud compatibility tests where local and replicated state interact.

Rules:
- These tests should prove we can upgrade real users without losing search quality or corrupting shared state.
- Prefer fixture-based realism over tiny toy cases.
```

## P16: Performance Benchmarks and Guardrails

Owner:
- search/indexing benchmark code
- performance instrumentation

Depends on:
- `P03`, `P04`, `P05`, `P13`

Covers:
- `16A`, `17A`

Prompt:

```text
Read first:
- projection/retrieval/vector modules from earlier prompts
- test harness from P13

Add concrete performance guardrails for the BurnBar search system.

Deliver:
- Benchmarks or performance-focused tests for projection throughput, query latency, ANN candidate generation, exact rerank, and memory behavior on long transcripts/artifacts.
- Thresholds or assertions where practical.
- Instrumentation hooks or lightweight metrics that will help catch regressions later.

Rules:
- Focus on realistic corpus sizes and chunk counts.
- Prove that local-first interactive search stays fast even with the broader corpus.
```

## P17: Docs, ASCII Diagrams, and Inline Maintenance

Owner:
- `README.md`
- `docs/**`
- inline comments/ASCII diagrams in touched services/tests

Depends on:
- most implementation prompts landed or at least stabilized

Covers:
- required diagrams, maintenance guidance, rollout clarity

Prompt:

```text
Read first:
- docs/BURNBAR_AGENT_PROMPT_PACK.md
- the architecture blueprint from P00
- all merged implementation changes from the search program

Update the docs and inline diagrams so the implementation is explainable and maintainable.

Deliver:
- README/doc updates for the new retrieval architecture, local-first/shared split, rebuild/re-embed behavior, and team/shared artifact model.
- ASCII diagrams in docs and inline comments where the projection pipeline, retrieval pipeline, or collaboration flow would otherwise be hard to reason about.
- Notes for operators/developers on health states, rebuild triggers, and test/eval entrypoints.

Rules:
- Do not leave stale diagrams behind.
- Keep the writing concrete and operational.
```

## P18: Final Integration and Stabilization

Owner:
- cross-module glue
- compile/test stabilization
- minimal follow-up fixes only

Depends on:
- all prior prompts

Covers:
- final system coherence

Prompt:

```text
Read first:
- the merged output of all prior prompts
- project.yml
- README.md

Do the final integration pass for the BurnBar search program.

Deliver:
- Resolve compile/test breakage across the new DB, retrieval, UI, shared, and test layers.
- Remove any temporary seams or duplicated adapters left behind by parallel implementation.
- Ensure the final system still honors the locked review decisions exactly.
- Run the broadest relevant test pass you can and report what still needs manual verification.

Rules:
- This is not a refactor-for-fun pass. Fix integration problems and obvious duplication only.
- Do not silently narrow scope or punt accepted features.
```
