# OpenBurnBar — Project Code Memory & Agent Memory · Master Plan

**Goal:** Deliver total-memory capability parity *inside* BurnBar — durable agent memory plus project code search/symbols/context-packing exposed over MCP and CLI — **BurnBar-native**, reusing the daemon, the SQLite hybrid-retrieval substrate, the sealed/local-decrypt model, and the capability/scope auth that already ship. Do **not** vendor total-memory's server, Postgres, pgvector, Qdrant, Tantivy, Neo4j, Ollama, or JWT tenant model.

| | |
|---|---|
| **Status** | Implemented for Phases 0-3; Phase 4 static parser implemented; exact LSP and hosted code sync remain later opt-ins |
| **Date** | 2026-06-15 |
| **Author** | Drafted by Claude from a Codex strategy + a 9-agent source-verification pass |
| **Supersedes** | The Codex "Revised Strategy: BurnBar-Native Total-Memory Parity" (folds in its confirmed parts, corrects its refuted parts) |
| **Authoritative refs** | `docs/OPENBURNBAR_SEARCH_ARCHITECTURE_SPINE.md`, `docs/PENSIEVE.md`, `docs/HOSTED_REMOTE_MCP.md`, `docs/REMOTE_MCP_THREAT_MODEL.md`, `docs/SCHEMA_SQLITE.sql` (CI-checked by `scripts/ci/verify-sqlite-schema-doc.mjs`). |

---

> **Production-readiness update (2026-06-17):** local Project Code Memory tools
> exist, but `docs/reviews/PROJECT_CODE_MEMORY_MASTER_REMEDIATION_PLAN_2026-06-17.md`
> now governs the production-readiness bar. Current daemon/MCP responses must
> report `PROJECT_CODE_MEMORY_PRODUCTION_READY=false` / `productionReady=false`
> until the remediation plan's trust, schema, incremental indexing, retrieval
> quality, SQLCipher, hosted-code threat-model, and proof-gate work is complete.
> Hosted code search/document tools remain disabled by default.
>
> **Hardening landed (2026-06-17):** snippets/context packs are wrapped as
> untrusted code, fake semantic ranking is disabled for project code, stale
> indexes degrade explicitly, Python read tools are read-only, hosted code tools
> are disabled by default, Swift/Python share a checked-in secret-scanner corpus,
> Git worktrees use Git's exclude-standard semantics for nested ignore,
> negation, and globstar behavior, manifest-backed delta indexing skips
> unchanged files and prunes removed files, Git fingerprint-backed Project ID v2
> preserves identity across moved checkout paths, audit hashes use a unified
> sequence-bound v2 payload, per-query freshness caches avoid repeated stale
> candidate file reads, and Swift call graph traversal now honors bounded `depth`.

## 0. Confidence & how to read this

The underlying *strategy* (extract capabilities, not architecture) is **confirmed correct** at source. Three of the plan's load-bearing claims were independently re-verified true (search substrate exists, sealed/local-decrypt is real, total-memory's symbol tier is a lexical stub). One foundational claim was **refuted** (the 15 tools are not greenfield; the Python MCP has no daemon-RPC client) and is corrected here. The biggest value in this document is **§5 (cross-cutting invariants)** and **§4 (the honest parity matrix)** — they encode the systemic problems the original plan never tested for.

Read in order: §1 thesis → §2 prerequisites → §3 non-goals → §4 parity matrix → §5 invariants → §6 data model → §7 phased work → §8–11 mechanics → §12 tests → §13 gates.

**Implementation note (2026-06-15):** the BurnBar-native path landed without
vendoring total-memory infrastructure. Memory/code MCP writes fail closed unless
the daemon accepts the RPC; direct SQLite helpers remain only as test/load-harness
library APIs. Project Code Memory is local-only by default. The optional Phase 4
Tree-sitter tier shipped as the stateless Rust helper in
`crates/project-code-static-parser`; `exact_lsp` and hosted code sync are still
future opt-ins and must not be claimed by current responses.

---

## 1. Thesis

**Reconcile + extend, not greenfield.** BurnBar already ships ~9 of the 15 total-memory tools in some form. The work is to *unify* them under parity names, fill the genuine gaps (code symbols/refs/call-graph/diagnostics, analytics, explore), and harden the cross-cutting invariants — **not** to re-implement shipped systems or stand up a third parallel memory store.

Three pillars, all already true in the codebase and to be **preserved**:

1. **Local-first authority.** The daemon's SQLite is the source of truth: FTS5 lexical (`search_chunks_fts`) + vector blobs (`chunk_embeddings`) + RRF hybrid fusion + `CrossEncoderReranker`, driven by a leased/retryable `projection_jobs` pipeline. `OpenBurnBarDatabase.swift:471-647` (`v14_local_search_substrate`), `OpenBurnBarIndexedSearchService.swift`.
2. **Sealed-by-default cloud.** Hosted MCP returns only ciphertext + opaque metadata and **never decrypts**; plaintext assembly happens in the local decrypt shim. `services/hosted-mcp/src/knowledge.ts:9-10`, `search.ts:34-36`, `tools/openburnbar-mcp-remote/src/decrypt.ts`.
3. **Capability/scope auth, per-uid.** Local MCP uses operator-capability gates; hosted MCP uses an Ed25519 token (`sub/aud/scopes/entitlement_family/grant_mode/jti`) with per-client grant + Firestore rate limits. No tenant/org concept. `auth.ts`, `entitlements.ts`, `rateLimits.ts`.

**Definition of "100% parity"** for this plan: every *user-facing capability total-memory actually ships today* has a BurnBar implementation or an explicit, documented non-goal classification — at total-memory's **real** implementation tier (lexical symbols, cached diagnostics), not its roadmap. Exceeding that tier is **Phase 4 (beyond-parity)**, separately budgeted.

---

## 2. Prerequisites (must land before any parity code)

### 2.1 Fix the data-lifecycle debt (BLOCKER)
The plan writes code chunks — far bulkier than conversation text — into exactly the substrate that already has a critical lifecycle bug. Per `audits/2026-06/TECH_DEBT_AUDIT_2026-06-11.md` (T7, item 148):
- `INSERT OR REPLACE` bypasses FTS delete triggers → **1.94M orphaned rows, ~11.5 GB of a 14.3 GB DB** holding ~41 MB of logical text.
- `projection_jobs` is **99.9% dead rows, never reaped** (`ProjectionStore.swift`).
- Retention purge is a **no-op stub**.

Code indexing amplifies all three. **Required before Phase 2:** correct FTS delete-trigger semantics (no orphan on re-chunk), implement `projection_jobs` reaping, and make retention real. Verify with a DB-size regression test (index → re-index → row counts return to baseline).

### 2.2 Land on a clean branch, reserve identifiers
Do **not** build on `security/run-09-privacy-invariants-hardening`. It adds its own migrations and touches the same exhaustive RPC switches; co-mingling a net-new privacy surface (code indexing) onto a privacy-*hardening* branch dilutes its review. Sequence: merge run-09 first → branch `feature/project-code-memory` from updated `main` → reserve migration numbers (v49+) and RPC method names in a short registry note to avoid collisions. Clean the dirty `Vendor/libsignal` + untracked `.codex/` first.

### 2.3 Regenerate the schema doc
`docs/SCHEMA_SQLITE.sql` self-declared "generated from migration history" but listed only ~9 of ~20+ tables — it **omitted the entire search substrate** (`search_documents/search_chunks/chunk_embeddings/embedding_versions/embedding_models/projection_jobs/retrieval_health`). It misled the original analysis. Regenerate it from the live migrator before any C2 table work, and add a CI check that fails on divergence. Mark the six retrieval tables **REUSE, not CREATE**.

Implementation status: regenerated and now guarded by
`scripts/ci/verify-sqlite-schema-doc.mjs` in fast feedback.

### 2.4 Confirm the source-redaction artifact
The review sandbox masks vector-index identifiers as the token `ln` (e.g. `migrator: ln`, `Vectorln`). Confirm this is environment redaction, not committed corruption, before touching `OpenBurnBarDatabase.swift` / vector code.

---

## 3. Non-goals ledger (parity items that are *not features* here)

total-memory is multi-tenant hosted SaaS; a large slice of its surface exists only to isolate tenants and back a server-side vector/graph store. These are **explicitly out of scope** — chasing them adds attack surface and config for zero user value:

| total-memory feature | Why it's a non-goal | BurnBar equivalent |
|---|---|---|
| JWT `tenant_id` / `iss` claims | No tenant/org concept; isolation is `sub=uid` | Per-uid namespacing + per-project partition (§5.1) |
| Postgres + pgvector | — | SQLite `chunk_embeddings` + RRF |
| Qdrant | — | `chunk_embeddings` blobs + `search_chunks_fts` |
| Neo4j | total-memory's graph path is **unpopulated** (no writes to `symbols/references_map/call_edges`) — nothing to match | Local symbol tables (§6.2), lexical call-graph |
| Ollama (`qwen3-embedding/reranker`) | — | BurnBar deterministic embedder + `CrossEncoderReranker` |
| Tantivy BM25 | — | FTS5 (`search_chunks_fts`) |
| Per-**tenant** rate-limit buckets | Single-user/per-uid | One Pro-bearer limit (hosted), none (local) |
| admin-JWT `/admin/diagnostics` HTTP endpoint | Local daemon needs no HTTP admin plane | Operator-gated diagnostics RPC (§7.4) |

`aud` **does** port (checked at `auth.ts:174`); `iss`/`tenant_id` do **not**. "100% parity" here means **capability parity, deployment-model-appropriate**.

---

## 4. The honest parity matrix

Legend: **EXISTS** = ship today, wire to parity name · **EXTEND** = substrate exists, add a code/source dimension · **NEW** = genuinely greenfield · tier = total-memory's *real* shipped tier.

### 4.1 The 15 MCP tools
| Parity tool | BurnBar today | State | total-memory tier | Action |
|---|---|---|---|---|
| `remember` | Pensieve `memoryHook.ts` (extract→redact→dedup→seal→commit); `project_memory_snapshots` (`OpenBurnBarDatabase.swift:1361`, v39) | **EXISTS** | implemented | Front-end over Pensieve + snapshots; **no new plaintext store** |
| `recall` | `burnbar_semantic_search_conversations` + cloud variant + Pensieve `search_knowledge` | **EXISTS** | pgvector→ILIKE | Router/superset over the 3, by source filter + scope (`MemoryScope: all/personal_only/shared_only`, `DataStoreTypes.swift:213`) |
| `context_pack` | Shipped ContextPack XML exporter (`ContextPackExportTests.swift`) | **EXISTS** | implemented | Reuse exporter; add token-budget accounting |
| `search_code` | `OpenBurnBarIndexedSearchService` (FTS+vector+RRF+rerank) | **EXTEND** | RRF k=60, BM25 primary | Add a `code` `SearchSourceKind` |
| `index_project` | `ProjectionPipeline` enqueue (`ProjectionJobType`) | **EXTEND** | implemented | Add code source kind + walker |
| `index_status` | hosted `burnbar_list_search_index_status` + `ProjectionPipelineHealthModels` | **EXTEND** | implemented | Back with `countProjectionJobs` + health |
| `forget` | Pensieve dedup-retire | **EXTEND** | Delete+Redact | Two-phase cross-tier delete (§5.8) |
| `doctor` | `openburnbar mcp doctor` (Node shim) | **EXISTS** | implemented | Add memory/code checks |
| `audit_trail` | `unified_audit_log` hash-chain (`auditLog.ts`) | **EXTEND** | implemented | Add `memory.*` actions, label-only |
| `get_symbol` | — | **NEW** | **lexical stub** (`vec![]` LSP) | Lexical tier over FTS (Phase 2) |
| `find_references` | — | **NEW** | **lexical stub** | Lexical tier (Phase 2) |
| `call_graph` | — | **NEW** | **lexical / empty Neo4j** | Lexical tier, honestly labeled (Phase 2) |
| `diagnostics` | — | **NEW** | **cached cargo/eslint JSON** | Cached-file reads (Phase 2) |
| `memory_analytics` | — | **NEW** | implemented | Aggregate over memory store (Phase 1) |
| `explore` | — | **NEW** | implemented (auto-index+search+pack) | Compose index+search+pack (Phase 2) |

**Only 6 tools are genuinely net-new**, four of which match a *lexical stub*. The greenfield perception was an artifact of the stale schema doc.

### 4.2 Ops surface (total-memory ships these; the plan must not silently drop them)
| Capability | total-memory | BurnBar action |
|---|---|---|
| operational diagnostics | `/admin/diagnostics` + `operational_diagnostics` (16th handler): schema version, projection/outbox backlog, rate-limit state, store sizes | Operator-gated **RPC** (not HTTP): back with `ProjectionPipelineHealthModels` + `countProjectionJobs` |
| liveness vs readiness | `/livez` + `/healthz` alias + `/readyz` (backend-probing) | Daemon liveness/readiness split; `memory healthcheck` defaults to liveness |
| rate limiting | enforced per-tenant + anonymous on `/mcp` | Hosted: **register an explicit `rateLimits.ts` bucket per new code tool** (the `metadata:standard` 120/min fallback at `rateLimits.ts:15` is a footgun) |
| tracing | OTLP export wired + UUIDv7 `trace_id` on every response | Add `trace_id` to the tool-response shape (circuit-breaker can stay decorative — total-memory's is always-Closed) |
| privileged-tool gate | `forget/index_project/index_status/explore/doctor` admin-gated | Pin the same set operator-gated; rest = standard scope |
| installer cleanup | `remove_semble_serena` helper | Mirror in the installer |

### 4.3 CLI (three surfaces, not one)
`serve` = `OpenBurnBarDaemonExecutable` · `stdio` = Python FastMCP (`server.py`) · `install`/`doctor`/`login` = Node `openburnbar-mcp-remote` (already targets codex/claude/droid/kimi/forge). **New Swift CLI arms only:** `search`, `recall`, `index`, `config`, `healthcheck`. `auth` = existing `OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN` env (not a subcommand). `migrate` = existing GRDB migrator. `config validate` does not exist upstream — it's `serve --check-config`. **cursor** is the only genuinely new installer target.

---

## 5. Cross-cutting invariants (the systemic spine — must hold across every tool)

These are the loopholes the original plan never closed. Each is a hard requirement with a test in §12.

### 5.1 Project scoping is a first-class partition key — 🔴 BLOCKER
Nothing today isolates repo A's symbols/memories from repo B's (`source_artifacts.projectPath` is nullable + unindexed; Pensieve isolates only on `uid`). Without this, `recall`/`search_code`/`context_pack` **fuse proprietary code across repos by default** — a correctness *and* privacy hole.
- **`project_id` (non-null, indexed)** on every code authority table **and** durable memory row.
- A **required** filter threaded through every `memory.recall` / `code.*` / `context_pack` RPC. Default = active project only; cross-project is an explicit opt-in flag.
- Sealed cloud rows carry a vault-keyed **`projectHmac`** (analogous to `slugHmac`).
- Test: index two repos, recall/search cannot surface the other's chunks (§12).

### 5.2 Fail-CLOSED write path
`server.py` has **no daemon-RPC client** — writes go direct-to-SQLite via `_connect_rw`; the one socket precedent (`burnbar_usage_ledger.py:310`) **fails open** (local write even on daemon *reject*, `:404-410`). Build a shared daemon-RPC socket client (port `_try_record_via_daemon_socket`) and make all memory/code **write** tools (`memory.remember/forget`, `code.indexProject`) **fail-closed**: on daemon-unreachable *or* daemon-deny → error, **never** fall back to `_connect_rw`. Otherwise the secret gate (§5.3) and audit (§5.4) are bypassable by killing the daemon. Reads stay daemon-or-SQLite.

### 5.3 Secret/PII scan at write time (extend, don't port)
BurnBar's scanner already exists: `functions/src/logging.ts:16-44` `SCRUB_PATTERNS` (OpenAI/Anthropic/Stripe/GitHub/Google/Slack/xAI keys, JWT, email, IPv4, CC) + `ClientTelemetrySanitizer.swift:8-24`. It runs only at log/telemetry emission, never at write. **Do not port `secret_guard.rs`** (Rust dep for ~7 extra classes = churn). Instead:
- Lift the patterns into **one shared scanner module**; add the 7 missing classes (AWS AKIA, PEM blocks, DB-URIs-with-creds, generic `key=value≥32`, `.env` assignment, US SSN, US phone) + a `describe_*`-style **label-only** output for audit.
- Wire a **pre-persistence gate** at the daemon `memory.remember` / `code.indexProject` boundary (mirrors total-memory `remember.rs:83-88`). Reject or redact; emit label-only audit evidence.
- Run it on **every code chunk pre-seal**, not just chat memory.

### 5.4 Audit is a label-only hash chain (reuse, don't fork)
Mirror `functions/src/callables/auditLog.ts`: `AuditEventCore {seq, ts, actor, action, domain, prevHash, hash}` SHA-256 chain, server-write-only, no plaintext field. Extend `AUDIT_ACTIONS` with `memory.remember/forget/secret_rejected/code.index`. Store only `describe_*` labels (e.g. "GitHub PAT detected"), never the matched substring — preserving the no-plaintext invariant. The daemon-local memory audit replicates this shape in SQLite (it can't reuse the cloud Firestore log directly).

### 5.5 Sealed-by-default; CODE is a new asset class → LOCAL-ONLY default — 🔴 HIGH
Neither `SearchSourceKind` (conversation/skill_doc/agent_doc/shared_artifact) nor Pensieve `sourceKind` (repo_docs/notes/chat_memory) ingests code today; the threat model reasons about transcripts/usage-metadata only. Pensieve's **documented, risk-accepted** cloak leakage — full pairwise cosine/k-NN geometry + cross-tenant cosine≈0.77 "same-item" signal, computable **without the key** (`PENSIEVE.md:99-114`) — was accepted for *prose*, not code (live secrets, IP, structural fingerprinting).
- **Default code indexes to LOCAL-ONLY.** The `projection_jobs` substrate fully supports this.
- Hosted code sync is a **separate, louder opt-in**, gated behind: (a) a code `SearchSourceKind` + Pensieve `sourceKind`, (b) the §5.3 scan on every chunk pre-seal, (c) a `REMOTE_MCP_THREAT_MODEL.md` + `PENSIEVE.md` update adding code as a new asset class and re-evaluating the leakage (consider raising Householder reflection count toward `dim` per `PENSIEVE.md:107` before code ships).
- Any hosted code-pack tool reuses the `decryptMode: local_decrypt_shim` discriminator + the `search.ts:34-36` shim-required empty-result guard, and asserts it returns no field not prefixed `sealed`.

### 5.6 Confidence tiers are earned at query time, never decorative
`exact_lsp` only if a live LSP responded within timeout for the **current** buffer; `static_tree_sitter` only if the file's blob SHA matches what was parsed; else degrade to `lexical_fallback`. Emit the tier + its evidence (LSP-responded / SHA-match) in the response and audit, so tiers are falsifiable. (total-memory's always-"Closed" circuit-breaker is the anti-pattern to avoid.)

### 5.7 Git-staleness is modeled, not ignored
Code memory with no commit/blob dimension returns confidently-wrong locations after branch switch/rebase/force-push — *worse* than an honest lexical stub.
- Stamp every code artifact/symbol/reference with the **git blob SHA** (and commit SHA) it was extracted from.
- At query time, validate the symbol's blob SHA against the working-tree blob; on mismatch, downgrade to `lexical_fallback` or suppress.
- Treat `.git/HEAD` + `.git/refs` changes as a reindex trigger (not just FSEvents on source files).

### 5.8 Cross-tier `forget` is verifiable
`forget` must hard-delete from **both** local SQLite and the sealed cloud. The cloud path today is async *soft*-retire — a "forgotten" chunk's geometry lingers and is server-observable. Define a two-phase audited delete: (1) hard-delete local rows + label-only audit event; (2) device-authed cloud delete-by-`slugHmac`/`projectHmac` callable that **hard**-deletes the sealed row + cloaked vector, with a receipt + tombstone. Bound cloud-deletion latency; surface pending forgets in `doctor`. Test: forgotten chunk unrecoverable from both tiers.

### 5.9 Embedding-version floor + sealed re-embed protocol
The server can't re-embed cloaked vectors (never sees plaintext). On embedding-version bump, old sealed rows strand → silent recall rot. Locally, reuse the `reembed` `ProjectionJobType`. For the cloud: a **device-driven backfill** — the shim re-embeds + re-cloaks + re-seals affected artifacts from local plaintext, re-uploads, then the server version-purges stale rows. Pin `embeddingModelVersion` as a **hard query floor** for code so a mixed-version index can never return cross-version garbage.

### 5.10 Storage caps + transactional consistency
A single local SQLite has no cap (total-memory uses Qdrant precisely to avoid this). Define per-project max artifacts/symbols, LRU/age eviction of references + embeddings, periodic `incremental_vacuum`, a storage budget surfaced in `doctor`/diagnostics. Decide whether code embeddings share `chunk_embeddings` or a separate file-backed store so a large code corpus can't degrade conversation search. **Consistency:** each file's reindex (symbol delete+insert, inbound/outbound reference rewrite, call-edge recompute) commits in **one** transaction; query RPCs open a deferred/WAL-snapshot read so they never observe a partial reindex.

---

## 6. Data model

### 6.1 Reuse (do NOT re-create — `OpenBurnBarDatabase.swift` v14)
`search_documents`, `search_chunks`, `search_chunks_fts`, `chunk_embeddings`, `embedding_models`, `embedding_versions`, `projection_jobs`, `retrieval_health`, `parser_checkpoints`, `source_artifacts`, `project_memory_snapshots` (v39).

### 6.2 New authority tables (migrations v49+; all carry `project_id` non-null + index)
Illustrative — finalize against the live migrator:
- `agent_memories` — `id, project_id, kind, scope, confidence, body_ref (sealed-envelope ref / dedupHash), tags, source_path, valid_from, valid_to, superseded_by, created_at`. *Stores a sealed envelope reference keyed by the existing `dedupHash`, not plaintext — it is a local index over Pensieve/snapshot memory, not a third store (see §7.1).*
- `memory_audit` — the §5.4 hash-chain shape, daemon-local.
- `code_artifacts` — `id, project_id, file_path, blob_sha, commit_sha, lang, mtime, indexed_at` (§5.7).
- `code_symbols` — `id, project_id, artifact_id, blob_sha, name, kind, range, confidence_tier`.
- `code_references` — `id, project_id, from_artifact_id, to_symbol_id, range, blob_sha, confidence_tier`.
- `code_call_edges` — `id, project_id, caller_symbol_id, callee_symbol_id, confidence_tier`.
- `code_diagnostics_cache` — `id, project_id, file_path, tool, payload_ref, blob_sha, cached_at`.
- `code_index_checkpoints` — extend/parallel `parser_checkpoints` for code high-watermark resume.

### 6.3 Enum extensions (verify at `DataStoreTypes.swift`)
- `SearchSourceKind` (:23): add `code` (and possibly `code_symbol`).
- `ProjectionJobType` (:30): add `index_code` / `reproject_code` (or reuse `project`/`reproject` with a code source kind — decide in §16).
- Reuse `ProjectionJobStatus`, `EmbeddingDistanceMetric`, `RetrievalHealthStatus`, `MemoryScope` (:213), index-status enum (:394) as-is.

### 6.4 Sealed cloud deltas (only if hosted code sync is opted in — §5.5)
Add a code `sourceKind` to the Pensieve schema; rows carry `projectHmac`, `embeddingModelVersion` (hard floor), and support hard delete-by-`slugHmac`/`projectHmac`.

---

## 7. Phased work breakdown

Each phase ends at an **acceptance gate** (§13). Phases 0–3 = parity; Phase 4 = beyond-parity.

### Phase 0 — Foundations & prerequisites
- §2.1 data-lifecycle fix (FTS triggers, projection reaping, retention) + DB-size regression test.
- §2.3 regenerate `SCHEMA_SQLITE.sql` + CI divergence check.
- Shared **secret scanner module** (§5.3) + tests against a shared corpus.
- Shared **daemon-RPC socket client** for `server.py` (§5.2), fail-closed semantics defined.
- §5.1 `project_id` partition design + the active-project resolution rule.
- ADR: "Why BurnBar does not vendor Postgres/Qdrant/Neo4j/Tantivy/Ollama/JWT" (the non-goals ledger, §3).

### Phase 1 — Agent Memory (reconcile + extend)
- RPC: `memory.remember`, `memory.recall`, `memory.forget`, `memory.auditTrail`, `memory.analytics`.
- `remember` → routes through Pensieve `memoryHook` (sealed/dedup/confidence) + `project_memory_snapshots`; writes a sealed-envelope reference into `agent_memories` (local index, §6.2). **No plaintext durable-memories table.**
- Hermes / CLI-bridge chat memory is part of this same Phase-1 agent-memory lane, not a new store: the app writes `source_kind='chat'` rows into the unified `agent_memories` sealed-reference authority, while daemon Project Code Memory remains `source_kind='code'`. The companion integrity tables are `memory_provenance`, `memory_extraction_jobs`, `memory_embedding_refs`, and `memory_source_tombstones`; all preserve the same sealed-body discipline.
- PR-0 for the chat-memory backend reconciles this plan with `docs/MEMORY_BACKEND_PLAN.md`: the vestigial body-bearing `agent_memories_fts` table is dropped by the app migrator (`v51a_drop_body_fts`) and remains absent from daemon bootstrap and `docs/SCHEMA_SQLITE.sql`. Memory lexical recall may use redacted metadata only; raw fact bodies never enter persistent FTS, audit, logs, or cloud fields.
- `recall` → router/superset over `semantic_search_conversations` + cloud variant + Pensieve `search_knowledge`, by `source` + `MemoryScope` + `project_id`; reuses `_active_deterministic_embedding` (`server.py:971`).
- `forget` → §5.8 two-phase cross-tier delete.
- `context_pack` → reuse the shipped ContextPack exporter + token-budget accounting.
- `memory_analytics` → aggregate over `agent_memories`/snapshots.
- All writes via fail-closed RPC (§5.2), through the secret gate (§5.3), audited label-only (§5.4).
- App GRDB migrations are the source of truth for the shared SQLite schema; `scripts/ci/verify-sqlite-schema-doc.mjs` must read the app migrator, daemon bootstrap, and Python MCP bootstrap, then compare the final schema after historical drops against `docs/SCHEMA_SQLITE.sql`.
- MCP tool names: `burnbar_remember/recall/forget/context_pack/audit_trail/memory_analytics` (decide alias strategy, §16).

### Phase 2 — Code Memory, lexical tier (TRUE PARITY)
- RPC: `code.indexProject`, `code.search`, `code.contextPack`, `code.getSymbol`, `code.findReferences`, `code.callGraph`, `code.diagnostics`, `code.indexStatus`, `code.explore`.
- `indexProject` → a repo walker (`.gitignore`-aware) enqueues `projection_jobs` for a `code` source kind; chunks → `search_documents/search_chunks/search_chunks_fts` + `chunk_embeddings`; stamps `blob_sha`/`commit_sha` (§5.7). Per-chunk secret scan pre-persist (§5.3).
- `search`/`contextPack` → thin wrappers over `OpenBurnBarIndexedSearchService` (FTS+vector+RRF) + `CrossEncoderReranker`, scoped by `project_id`.
- `getSymbol`/`findReferences`/`callGraph` → **lexical tier** over FTS, `confidence_tier = lexical_fallback`, honestly labeled. This *matches* total-memory.
- `diagnostics` → read cached `cargo check`/`eslint`/`swiftc` JSON from disk (cached-file tier).
- `indexStatus` → `countProjectionJobs` + `ProjectionPipelineHealthModels`, `project_id`-scoped.
- `explore` → compose index+search+pack.
- A code FSEvents watcher (extend `PensieveKnowledgeWatcher`'s `DispatchSource` pattern) → `enqueueSelectiveReproject` for code; watch `.git/HEAD`+refs (§5.7).
- Storage caps + transactional reindex (§5.10).
- **Default LOCAL-ONLY** (§5.5).

### Phase 3 — Ops, CLI, installer parity
- Operator-gated `diagnostics` RPC (§4.2): schema version, projection backlog/oldest-age, rate-limit state, store sizes.
- Daemon liveness/readiness split; `memory healthcheck` → liveness.
- `trace_id` on every tool response.
- New Swift CLI arms (`search/recall/index/config/healthcheck`) in `OpenBurnBarCLI+Memory.swift` (respect the 2000-line budget; `OpenBurnBarCLI.swift` is 932 lines).
- Installer: add `cursor` to the `ClientKind` union (`installers.ts`); mirror `remove_semble_serena`; verify idempotent/dry-run/preserve-unrelated invariants.
- Hosted: register explicit `rateLimits.ts` buckets + scopes (e.g. `code:read`) per new hosted tool; extend `issueRemoteMcpGrant` allowlist.

### Phase 4 — BEYOND PARITY (optional, separate ADR + budget)
- `static_tree_sitter` symbol/definition extraction via the **stateless Rust helper** (stdin/stdout JSONL, no DB/net/auth) for a **small** language set first (Swift, TS, Python). `confidence_tier = static_tree_sitter`, SHA-gated (§5.6).
- Later, per-language opt-in `exact_lsp` (sourcekit-lsp/gopls/rust-analyzer/pyright/tsserver/jdtls/clangd) — pooled, timeout-gated. **Do not** claim to exceed total-memory's call-graph until type-aware resolution exists.
- Hosted code sync (only after the §5.5 threat-model gate).

---

## 8. Daemon RPC registration — the 4-site checklist (per method)
Adding a method is clean-additive but **multi-site** and compiler/test-enforced. For each new `memory.*`/`code.*` method:
1. `BurnBarRPCMethod` enum (`OpenBurnBarCore/.../Contracts/BurnBarRPCContracts.swift:12`).
2. `BurnBarRPCCapability.capability(for:)` total switch (`BurnBarRPCCapability.swift:46`) — add `.memory` / `.code` capability cases.
3. Dispatch switch (`OpenBurnBarDaemonServer.swift:480`) → new handler extension `RPC/BurnBarDaemonServer+RPCMemory.swift` / `+RPCCode.swift`.
4. `BurnBarDaemonSocketRPCCoverage` map (contract-test-enforced).
5. **Capability profiles** (`BurnBarPeerCapabilityProfile.full/readOnly/runClient`, :107-121): place **write** methods in a write-scoped profile and **reads** in `readOnly` — never default into `.full`, or hosted/read-only peers get write/index agency (breaks §5.1/§5.5 scoping).
Plus request/response structs. None of the four files is near the 2000-line budget if handlers/contracts stay modular.

## 9. CLI surface map
See §4.3. Owners stay put; only `search/recall/index/config/healthcheck` are new Swift arms.

## 10. Hosted auth wiring
Per new hosted tool: declare `requiredScopes` + `costClass` in `toolRegistry.ts`; register an explicit `rateLimits.ts` bucket (no `metadata:standard` fallback); add the scope to `issueRemoteMcpGrant` allowlist so existing clients aren't silently granted it. Keep code indexes per-uid (no tenant). `aud` checked; `iss`/`tenant_id` N/A.

## 11. Security & threat-model deltas
- Update `REMOTE_MCP_THREAT_MODEL.md` + `PENSIEVE.md`: add **code** as a new asset class; re-evaluate cloak geometry leakage for code; document local-only default.
- New ADR for the stateless Rust helper boundary (no DB/net/auth; daemon owns persistence; secret gate at the RPC boundary, never in the helper).
- The secret gate, label-only audit, fail-closed writes, and cross-tier forget are all security-test-gated (§12).

---

## 12. Test & proof plan
**Swift (daemon/core):** migrations v49+; memory CRUD/supersession/forget/redact; audit hash-chain shape; project-scoping; projection ingestion of code; retrieval ranking; context-pack budgets; RPC capability/coverage contracts; transactional reindex consistency.
**Scanner:** shared corpus — every pattern class (incl. the 7 new) blocks; clean text passes; `describe_*` emits labels not values.
**Python/TS MCP:** tool-registry parity; schemas; capability gates; **fail-closed on daemon-deny** (no SQLite fallback for writes); hosted sealed-only; local-decrypt shim.
**Security (adversarial, the loophole tests):**
- two-repo **bleed**: index A + B, recall/search/context_pack for A never returns B (§5.1).
- **fail-closed**: kill/deny daemon → `remember`/`indexProject` error, nothing written (§5.2).
- **forget unrecoverable** from both local + sealed cloud (§5.8).
- **branch-switch staleness**: checkout other branch → stale symbols downgrade/suppress (§5.7).
- **embedding-version rot**: bump version → no cross-version garbage; backfill restores recall (§5.9).
- secret-in-source rejected pre-seal; symlink escape; hidden files; oversized repo; no plaintext in audit.
**E2E:** temp repo → index → search_code → get_symbol → find_references → context_pack → remember → recall → forget → audit_trail.
**Load:** index a large monorepo (100k+ symbols); assert storage cap/eviction + query latency + no conversation-search regression.
**Docs gate:** regenerate `SCHEMA_SQLITE.sql`; update spine/Pensieve/threat-model/changelog; CI divergence check green.

## 13. Acceptance gates (definition of done)
- **Phase 0:** DB-size regression passes; schema doc regenerated + CI check green; scanner + fail-closed client merged with tests.
- **Phase 1:** all 6 memory tools route through existing stores (no third store); fail-closed + secret-gate + label-only audit proven; two-repo memory bleed test green.
- **Phase 2:** 9 code tools at honest tiers; staleness + storage-cap + consistency tests green; local-only enforced.
- **Phase 3:** ops/CLI/installer parity; rate-limit buckets registered; cursor installer idempotent.
- **Phase 4 (if pursued):** tier verification (§5.6) proven; threat-model gate passed before any hosted code sync.
- **Parity ledger:** every total-memory user-facing capability is EXISTS/EXTEND/NEW **or** documented NON-GOAL — zero silent omissions.

## 14. Effort & sequencing (honest)
- Phase 0: ~3–5 days (the data-lifecycle fix is the long pole).
- Phase 1: ~3–5 days (mostly wiring + the cross-tier forget contract).
- Phase 2: ~1.5–2.5 weeks (walker, code source kind, lexical symbol tier, watcher, caps, consistency).
- Phase 3: ~3–5 days.
- Phase 4: **separate, multi-week per language tier** — not part of the parity estimate. The original "1–2 weeks code indexing" is honest only for Phases 0–2 *excluding* tree-sitter/LSP.

## 15. Residual risk register
| Risk | Mitigation |
|---|---|
| Code corpus bloats local SQLite | §5.10 caps/eviction + separate store decision + load test |
| Hosted code geometry leakage | §5.5 local-only default + threat-model gate |
| Mislabeled-high-confidence symbols | §5.6 query-time tier verification |
| Migration/switch collisions | §2.2 land post-run-09, reserve ids |
| Three memory stores diverge | §7.1 single sealed-envelope index, no plaintext store |

## 16. Open decisions (need Alberto's call — defaults chosen, change if wanted)
1. **`remember` backing store** *(default: by kind — durable/project facts → `project_memory_snapshots`; personal/cross-project → Pensieve sealed knowledge; `agent_memories` is the local index over both; Hermes/CLI chat facts use the same authority table with `source_kind='chat'` rather than a sibling body store)*.
2. **Hosted code sync** *(default: LOCAL-ONLY for v1; hosted is Phase 4 behind the threat-model gate)*.
3. **Phase 4 language set & order** *(default: Swift → TS → Python)*.
4. **Tool naming** *(default: BurnBar-native `burnbar_*` names with total-memory names as documented aliases, so existing agent configs work)*.
5. **`ProjectionJobType`** *(default: reuse `project`/`reproject` + a `code` source kind rather than new job types)*.

---

*Verification provenance: tool inventory, CLI, installers, storage, and tiers confirmed against `total-memory-mcp` source; BurnBar substrate, sealed model, auth, scanner, and audit confirmed against the live tree (9-agent pass, three high-stakes verdicts independently re-verified). `docs/SCHEMA_SQLITE.sql` is now a CI-checked schema reference; keep it synchronized with the live migrator/schema sources.*
