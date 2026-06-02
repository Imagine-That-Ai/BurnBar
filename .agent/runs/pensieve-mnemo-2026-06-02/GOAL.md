# Pensieve — Personal Knowledge Memory (E2EE per-member semantic memory)

Goal ID: `pensieve-mnemo-2026-06-02`
Started: 2026-06-02T12:33:04Z
Parent goal: none
Mode: full
Ledger path: `.agent/runs/pensieve-mnemo-2026-06-02/`

## Objective

Implement the Pensieve plan: productize the maintainer mem0 flow into a per-paying-member end-to-end-encrypted semantic memory across backend, MCP, client bridge, daemon, mobile/desktop UX, and Ultra tier.

## Goal Mode Coupling

When creating or updating the matching `/goal`, include this ledger pointer in the goal objective:

`Maintain the agent-owned ledger at /Users/albertonunez/Documents/Windsurf/BurnBar/.agent/runs/pensieve-mnemo-2026-06-02/ and keep implementation-notes.html current at checkpoints, before compaction, and before final handoff.`

## Source plan

`/Users/albertonunez/.claude/plans/swarm-brief-paste-swift-kernighan.md` (Pensieve — Personal Knowledge Memory, BurnBar Cloud Pro). 9 dependency-ordered phases; Milestone-1 = phases 1–4 + minimal phase-7 UX.

## Finishing Criteria

Code-complete + verified (agent-buildable):
- [done] **P1 Chunker parity** — `scripts/lib/verbatim-chunker.mjs` extracted; `mem0-sync.mjs` imports it; golden+unit test 10/10 byte-identical vs committed manifest; zero-write reconcile; CI job `chunker-parity`.
- [done] **P2 Crypto/embed primitives** — `tools/openburnbar-mcp-remote/src/embed.ts` (bge-small-en-v1.5 lazy embedder + vault-key Householder-product cloak); 9/9 cloaking tests (cosine/ranking/norm preserved, key-isolated, genuine mixing). *(TS in `src/`, not `lib/` — see decisions.)*
- [done] **P3 Backend store & isolation** — `knowledgeMemory.ts` (commit/configure/delete/purge, Cloud Pro gate, 384-dim cloaked-vector + sealed validation, FieldValue.vector writes, tier caps via aggregates, idempotent); `firestore.rules` owner-only; `firestore.indexes.json` 4 vector indexes; `knowledge:read` scope ×3 sites; index.ts exports. tsc+lint clean, vitest 12/12.
- [done] **P4 MCP query surface** — `burnbar_search_knowledge`+`get_knowledge_document` in toolRegistry, `knowledge.ts` (Firestore findNearest), `knowledgeVector.ts` (types+cosine+in-memory store), rate buckets; shim `src/knowledge.ts` (embed+cloak+decrypt+post-filter). hosted-mcp 28/28, shim 40/40. *(Firestore vectors, not pgvector — see decisions.)*
- [partial] **P5 Ingestion** — DONE+verified: `knowledgeSync.ts` `onKnowledgeRepoPush` webhook (HMAC, enqueue-only) + connect/disconnect + `reconcileKnowledgeMemoryDaily` (tsc+lint clean). [incomplete]: `KnowledgeSyncService.swift`, `PensieveKnowledgeWatcher.swift` (native, not compilable here).
- [done] **P6 Chat-derived BYO hook** — `seal.ts` + `memoryHook.ts` (extract via user's `claude -p`, redact, dedup, embed+cloak+seal, queue; `installMemoryHook`) + CLI `memory install|run|sync`. 11/11 tests.
- [incomplete] **P7 Client UX** — native iOS/macOS/Android (no Xcode/Gradle; conflicts with in-flight branch). Specs in docs/PENSIEVE.md.
- [done] **P8 Ultra tier** — `burnbar_ultra` entitlement + helpers, reconciler Ultra→mirror(proMax), Ultra SKUs (config+legacy+rules ×3 allowlists), limit branching. appstore 48/48 (+Ultra assertions). *(tierCogs COGS + client isActiveUltra deferred — see decisions.)*
- [done] **P9 Security & docs** — 8-case `test-hosted-mcp-security.sh` (bash -n clean); `docs/PENSIEVE.md` with DPA-not-needed note.
- [done] Ledger kept current at every checkpoint.

Blocked-on-external (not agent-buildable; documented in docs/PENSIEVE.md):
- [done→N/A] ~~Cloud SQL pgvector~~ — ELIMINATED by the Firestore-vector pivot.
- [blocked] **App Store Connect / Google Play** Ultra SKUs (`com.openburnbar.ultra.monthly` / `.annual`).
- [blocked] **GitHub App** (contents-read) for the repo dirty signal.
- [blocked] Deploy `firestore.indexes.json` + functions + hosted-mcp.

## Escape-hatch invocations
- PRD-vs-repo: shim source is TS in `src/` (plan said `lib/*.js`) → followed repo.
- Residual open decision #1: chose Firestore vector search over pgvector (strictly better here).
- Native layer left `[incomplete]` rather than ship unverifiable code into a conflicting working tree.

## Escape Hatch

Pause, ask the user, or mark a scoped item `[blocked]` / `[incomplete]` if:
- validation contradicts the goal
- the goal requires a scope change
- the agent is looping without measurable progress
- the next step risks deleting or rewriting durable memory
- the PRD and actual repo disagree
- the ledger itself contaminates validation

