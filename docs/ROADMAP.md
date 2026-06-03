# Roadmap

This roadmap reflects OpenBurnBar's current product direction: from local-first agent metering into a local-first memory, retrieval, and workflow system for AI-assisted development.

## Shipped Foundation

- Local-first usage tracking across supported providers
- Conversation/session ingestion and summaries
- Menu bar app, dashboard, chat panel, and insight surfaces
- Optional Firebase sync with sealed chat/session domains; raw iCloud session mirroring disabled until sealed archive support exists
- OpenBurnBar daemon plus Cursor / VS Code extension shell

## Now

### 1. Unified Search Substrate

- Build a derived cross-artifact search corpus instead of conversation-only search
- Index conversations, transcripts, skills, and agent docs
- Add a durable local projection queue with rebuild and backfill support
- Chunk long artifacts with parent linkage and offset metadata
- Split the database layer into focused modules over one shared `DatabaseQueue`

### 2. State-of-the-Art Retrieval

- Ship one shared retrieval service for Chat, Session Logs, context packs, and future drafting flows
- Add hybrid lexical + semantic retrieval with mandatory lexical fallback
- Track embedding model versions and support re-embed / rebuild flows
- Add an ANN backend behind a swappable vector interface with exact rerank as the quality baseline
- Replace silent failures with typed health and degraded-mode UX

### 3. Reuse Prior Work

- Let users draft and refine skills from retrieved prior conversations
- Let users draft and refine `AGENTS.md` and related agent instructions from indexed work
- Keep authored artifacts searchable by feeding them back into the same indexing system

## Next

### 4. Team Knowledge Product

- Shared team library for skills and agent docs
- Local-first cache plus Firebase-backed replication for shared artifacts
- RBAC, visibility filtering, and audit events
- Live collaborative editing with conflict handling and revision history

### 5. Workflow Intelligence

- Materialized insight rollups for stable, high-value workflow patterns
- Better "where did I leave off?" recovery across agents and devices
- Actionable recommendations based on repeated work, context switching, and retrieval behavior

### 6. Product Quality and Trust

- Integration harness for indexing, retrieval, sync, and collaboration flows
- Replay and golden evals for retrieval quality and authoring flows
- Migration, backfill, rebuild, and recovery test coverage
- Performance guardrails for large corpora and long transcripts

### 7. Mission-Control Maturity

- Move controller state from partial mirror/fallback into real ingestion from OpenBurnBar activity
- Add project registry and scheduled review automation
- Launch real review runs from controller commands and UI actions
- Deepen question workflow, auto-takeover, and mission execution linkage
- Ship the connector/browser control plane and operator CLI over the daemon

## Later

### 8. Organization-Level Memory

- Shared memory and insight views across teams and projects
- Better promotion paths from personal artifacts into shared team knowledge
- Search and insight experiences tuned for managers, leads, and platform teams

### 9. Proactive Workflow Improvement

- Stronger workflow coaching based on historical patterns
- Better reuse suggestions before users re-solve a problem from scratch
- More adaptive context assembly for in-app and extension-side assistant flows

### 10. Wider Ecosystem Coverage

- More parser implementations and source integrations where they materially improve the memory graph
- Better provider billing, quota, and model metadata where it improves trust and decision quality

## Not On The Roadmap

- Cloud-only search as the primary product path
- Arbitrary filesystem crawling outside registered roots and known patterns
- Team collaboration without permissions, audit, and conflict handling
- Vanity dashboards that do not improve real developer workflows
