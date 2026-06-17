# Project Code Memory SOTA Remediation Master Plan

**Date:** 2026-06-17  
**Status:** Master remediation plan after adversarial audit dedupe  
**Decision:** Harden the shipped spine, then extend it. Do not redesign from scratch.  
**Primary owner:** OpenBurnBar daemon / MCP code-memory surface  
**Related source plan:** `docs/PROJECT_CODE_MEMORY_MASTER_PLAN.md`  
**Specialist inputs:** `docs/reviews/PROJECT_CODE_MEMORY_AUDIT_SPECIALIST_*.md` and `docs/reviews/PROJECT_CODE_MEMORY_ADVERSARIAL_AUDIT_2026-06-17.md`

---

## 1. Executive Verdict

Project Code Memory is pointed in the right direction: local-first indexing, project partitioning, fail-closed write intent, blob-SHA staleness checks, label-only audit, and a stateless parser helper are exactly the trust primitives a serious agent memory system needs.

It is not ready to be marketed as production-grade code intelligence until the hardening backlog below lands. The current implementation has three systemic problems that explain most specialist findings:

1. **Runtime authority is split.** Swift daemon and Python MCP both implement schema, indexing, search, chunking, audit hashing, project identity, and confidence evidence. They already diverge.
2. **Retrieval quality is overstated.** The Python "semantic" leg is deterministic hash noise, Swift is FTS-only, references and call edges are lexical, and stale suppression is silent.
3. **Trust boundaries need to become enforceable.** Swift returns raw code chunks, some Python read tools open read-write handles, hosted code tools are registered before the code asset threat-model gate is complete, stock daemon builds do not activate SQLCipher, and subprocess/LSP execution lacks a strong policy boundary.

The fix is not to replace the feature. The fix is to make the daemon the canonical production engine, reduce Python to MCP transport plus tests/load harnesses, move schema ownership into the canonical migration system, and add a frontier retrieval/indexing layer in phases.

The target is:

> **A local-first, agent-native code intelligence layer that can index a repo once, update it incrementally, return verifiable code context with untrusted-content boundaries, explain every confidence tier, assemble structural repo maps, search with real sparse+dense retrieval when available, and optionally sync sealed code memory only after a code-specific threat model passes.**

---

## 2. Product Vision

Project Code Memory should make OpenBurnBar the durable memory and source-truth layer for coding agents.

The user should be able to point BurnBar at a workspace and expect:

- `burnbar_index_project` builds a trustworthy local code index without leaking secrets or freezing the daemon.
- `burnbar_search_code` finds exact, fuzzy, path, symbol, and natural-language intent matches with citations and source freshness.
- `burnbar_context_pack` returns compact, token-aware, source-backed context that an agent can use without mistaking retrieved code for system instructions.
- `burnbar_get_symbol`, `burnbar_find_references`, and `burnbar_call_graph` expose honest tier evidence: lexical, static tree-sitter, SCIP, or exact LSP.
- `burnbar_explore` gives a repo-map style overview, not just a flat hit list.
- `burnbar_memory_doctor` tells the user whether the index is current, encrypted, parser-backed, stale, degraded, or missing proof gates.
- Hosted code memory remains disabled until code is explicitly added as a new asset class in the Remote MCP/Pensieve threat model.

The product stance is:

- **Local-first by default.** Code stays on the Mac unless the user opts into hosted code sync through a separate, high-friction path.
- **Trust before cleverness.** Do not return confident answers from stale, fake-semantic, or unverified tiers.
- **Every tier is falsifiable.** A response should say exactly why it believes a symbol/reference/search hit is current.
- **Agents get structured evidence, not vibes.** Every context pack is a cited evidence bundle with provenance, hashes, rank features, and untrusted-content wrapping.
- **The architecture must accept frontier upgrades.** AST chunking, SCIP import, real local embeddings, vector indexes, rerankers, and LSP pools must fit without reworking the MCP surface again.

---

## 3. Source-Backed Dedupe

The audits contain many duplicates. This table collapses them into the workstreams that matter.

| Master finding | Duplicate audit themes | Verification status | Source evidence |
|---|---|---:|---|
| Runtime/schema authority split | Swift/Python divergence, raw SQLite schema, parity gaps, project ID mismatch | Verified | Swift bootstraps schema directly in `BurnBarProjectCodeMemoryStore.swift:1018`; Python defines schema in `project_code_memory.py:300`; Swift project ID is `proj_` + 16 hex chars while Python is 32 hex chars in `project_code_memory.py:171` and Swift `BurnBarProjectCodeMemoryStore.swift:1986` |
| Unwrapped / weak untrusted content boundary | Swift raw chunks, Python wrapper only, prompt injection risk | Verified | Swift `contextPack` appends raw `text` in `BurnBarProjectCodeMemoryStore.swift:638`; Python wraps snippets in `project_code_memory.py:114`, `:2143`, `:2186` |
| Fake semantic ranking | deterministic embedding, vector RRF noise, Swift/Python search mismatch | Verified | `EMBEDDING_MODEL = "deterministic-fake-embedding"` and `deterministic_embedding` in `project_code_memory.py:23`, `:513`; Python fuses it via RRF at `:2132`; Swift search is FTS-only in `BurnBarProjectCodeMemoryStore.swift:1758` |
| Full reindex and polling watcher | no file delta, no FSEvents, subprocess-per-file | Verified | Swift deletes all project rows before index at `BurnBarProjectCodeMemoryStore.swift:407`; watcher polls at `:554`; helper process is spawned per file in `BurnBarProjectCodeMemoryStore+Helpers.swift:256` |
| Expensive query-time freshness checks | `isCurrentBlob` reads and hashes files per candidate | Verified | `BurnBarProjectCodeMemoryStore+Helpers.swift:503` reads the file and recomputes the git blob SHA |
| Lexical reference/call-graph noise | identifier token flood, substring call matching, comment/string scans | Verified | `identifierTokens` collects any ASCII token length >= 3 at `BurnBarProjectCodeMemoryStore+Helpers.swift:368`; call edge uses `line.contains("\(target.name)(")` at `BurnBarProjectCodeMemoryStore.swift:1647` |
| Silent stale suppression | stale hits disappear instead of returning degraded status | Verified | Swift `searchCode`, `getSymbol`, `findReferences`, and `callGraph` compact-map/filter stale rows without response metadata in `BurnBarProjectCodeMemoryStore.swift:630`, `:667`, `:689`, `:743`; Python also drops stale rows in `project_code_memory.py:2130`, `:2213`, `:2254` |
| Secret scanner and gitignore are shallow | bypassable regexes, incomplete ignore semantics, no entropy/backstop | Verified | Swift scanner has fixed regexes at `BurnBarProjectCodeMemoryStore+Helpers.swift:55`; gitignore drops negations at `:458`; Python scanner mirrors fixed regexes at `project_code_memory.py:86` |
| SQLCipher inactive in stock daemon | plaintext DB at rest unless codec linked | Verified | `BurnBarDaemonDatabaseCipher.swift:19` states stock SQLite has no codec and `isCipherAvailable()` returns false; apply-key is a no-op if unavailable at `:138` |
| Hosted code surface exists before code threat-model gate | hosted code read tools registered | Verified | `services/hosted-mcp/src/toolRegistry.ts:220` registers `burnbar_search_code`; `:251` registers `burnbar_get_code_document` |
| Python MCP read handles are read-write | read tools use `_connect_rw` despite a stale comment | Verified | `_connect_ro` exists at `server.py:168`, but code read tools use `_connect_rw` at `server.py:1684`, `:1700`, `:1730`, `:1741`, `:1754`, `:1767`, `:1778`, `:1807` |
| Test/CI proof gaps | no parity test, load test not gated, schema doc weak, no daemon RPC e2e | Verified by specialist reports and file inventory | `scripts/ci/project-code-memory-load-test.py` exists; no workflow match was reported by the specialist; schema verifier references only known files in `scripts/ci/verify-sqlite-schema-doc.mjs` |

Nuanced decisions:

- **Do not "fix" Swift by adding the current Python hash embedding.** The correct near-term fix is to remove the fake semantic leg from production ranking and expose `semanticAvailable: false` until a real local embedder is present.
- **Do not strip code comments to mitigate prompt injection.** Code must remain byte-faithful for review. The mitigation is structured untrusted wrapping, provenance, hash evidence, and prompt contracts. Any optional "instruction-marker neutralization" must be opt-in and clearly marked as a transformed view.
- **Do not enable hosted code memory just because sealed hosted memory exists.** Code has different leakage, IP, and secret risk. Hosted code needs its own threat model and launch gate.
- **Do not treat `SQLCipher` code paths as complete while the daemon links stock SQLite.** The migration code is useful but the production dependency decision is still open.

---

## 4. Target Architecture

### 4.1 One Production Engine

The Swift daemon becomes the canonical production engine for:

- schema migrations,
- local indexing,
- watch mode,
- retrieval,
- stale/current checks,
- audit writes,
- secret gates,
- SQLCipher enforcement,
- parser/LSP process policy,
- MCP/RPC response contracts.

Python keeps:

- MCP stdio transport,
- daemon RPC client,
- read-only compatibility reads only when the daemon explicitly exposes a read snapshot or when running local developer diagnostics,
- tests, fixtures, and load harnesses.

Python must not own production writes, schema evolution, or independent ranking semantics. Direct Python indexing can remain behind a `PCM_DEV_HARNESS=1` style guard for benchmarks and golden-fixture generation, but it is not a shipping path.

### 4.2 Canonical Schema Ownership

Move Project Code Memory schema into the canonical database migration path and generate `docs/SCHEMA_SQLITE.sql` from the real schema.

Schema families:

- `pcm_projects`: stable project identity, aliases, roots, git remotes, git common-dir, created/last-seen timestamps.
- `pcm_file_manifest`: project ID, path, file ID, blob SHA, content hash, size, mtime, language, ignored reason, secret labels, parser tier, last indexed.
- `pcm_chunks`: AST-aware chunks with byte offsets, line spans, symbol ownership, content hash, token count, source version.
- `pcm_symbols`: definitions/declarations with range, kind, language, tier evidence, blob SHA, parser version.
- `pcm_references`: source-to-symbol references with tier evidence, confidence, and stale policy.
- `pcm_call_edges`: call graph edges with caller/callee symbol IDs, confidence, direction, and hop metadata.
- `pcm_rank_features`: sparse/dense/path/symbol/PageRank/test-cost features per chunk/symbol.
- `pcm_index_events`: label-only audit and index lifecycle records.
- `pcm_diagnostics_cache`: diagnostics populated by LSP/test runners, not a passive empty table.
- `pcm_project_snapshots`: repo-map summaries and context-pack summaries keyed by project/version.

Migration rule:

- Raw `CREATE TABLE IF NOT EXISTS` bootstrap is allowed only as a compatibility bridge during migration.
- New columns/tables land through the canonical migrator first.
- CI compares table names, columns, types, indexes, foreign keys, FTS virtual-table definitions, and constraints.

### 4.3 Stable Project Identity

Current Swift and Python project IDs differ and both are path-derived. The v2 model:

- Persist a generated `project_uuid` the first time a repo is indexed.
- Attach aliases for canonical root path, git common-dir path, normalized remote URLs, bundle/workspace IDs, and user-provided display names.
- Compute `projectID = "proj_" + sha256(project_uuid).prefix(32)` for local rows.
- For hosted sync, compute `projectHmac = HMAC(vaultKey, project_uuid || git_remote_fingerprint)` and never upload raw paths/remotes.
- On repo move/rename, resolve aliases before creating a new project.
- On deliberate fork/copy, let `doctor` show possible aliases and require explicit merge/split.

### 4.4 Indexer Pipeline

The production indexer should be a file-incremental pipeline:

1. Resolve project identity and git state.
2. Enumerate with standards-compliant ignore semantics:
   - `.gitignore`,
   - nested `.gitignore`,
   - `.git/info/exclude`,
   - user/global gitignore,
   - negation,
   - anchored patterns,
   - globstar.
3. Build a manifest diff keyed by path, size, mtime, blob SHA, and content hash.
4. For unchanged files, keep chunks/symbols/references.
5. For changed files, parse and chunk outside the DB write transaction.
6. Write each changed-file unit transactionally:
   - delete old chunks/symbols/outbound refs,
   - insert new chunks/symbols,
   - recompute outbound refs,
   - enqueue inbound-ref repair for symbols affected by name/path changes.
7. Delete removed files and all dependent rows.
8. Rebuild project-level graph/rank summaries incrementally.
9. Run bounded vacuum/compaction based on real freelist/page metrics, not a blind `incremental_vacuum(256)`.

The watcher should use FSEvents on macOS and include `.git/HEAD`, refs, and index changes. Polling remains a fallback for unsupported environments and tests.

### 4.5 Parser Service

The Rust parser helper should become a long-lived daemon-owned service:

- JSONL stdin/stdout protocol remains.
- The daemon owns timeouts, process lifecycle, sandbox policy, and kill-on-stall.
- Batch parse requests are supported to avoid process-per-file overhead.
- The parser returns:
  - parse status,
  - `hasParseError`,
  - recovered symbols,
  - structural chunk candidates,
  - definition/reference tags,
  - parser/grammar versions,
  - blob-SHA evidence.
- Tree-sitter incremental parsing is used where a cached tree exists; cold parse remains supported.
- Unsupported languages fall back honestly to regex with `shaMatch: false`, or to SCIP/LSP if configured.

Language strategy:

| Tier | Languages | Purpose |
|---|---|---|
| P0 | Swift, TypeScript/TSX, Python | Current tree-sitter tier, hardened |
| P1 | Rust, Go, Kotlin, Java, JavaScript, C/C++/Objective-C | Match indexed extension set |
| P2 | Markdown, YAML, JSON, SQL, Shell, Ruby, C# | Docs/config/codebase context |
| P3 | SCIP importers for mature ecosystems | Precision frontier |

### 4.6 Retrieval Engine

Retrieval is a layered ranker. Every layer must expose rank features in debug/doctor mode.

Required layers:

- **Sparse lexical:** FTS5 BM25, path/title boosts, exact symbol boosts, phrase boosts, extension/language filters.
- **Symbol graph:** definition proximity, reference count, caller/callee relevance, current file/session affinity.
- **Repo map:** PageRank or personalized PageRank over definition/reference graph, inspired by Aider-style repository maps.
- **Freshness:** current blob, current branch/ref, index age, stale ratio.
- **Context packing:** token-aware budget, whole-symbol chunks, neighbor chunks, test/source pairing, imports/callees/dependencies.

Dense retrieval:

- Disabled until a real embedding provider is configured.
- The current deterministic hash vector can remain only as a content fingerprint or test determinism fixture. It must not be marketed or fused as semantic rank.
- First shipping real path should be local and optional:
  - MLX/ONNX model for on-device code embeddings, or
  - a small bundled/local-download embedder with explicit storage and privacy UX.
- Vector search should use `sqlite-vec` or a sidecar vector store only after benchmarking storage, load time, and query latency.
- If a cloud/API embedder is ever offered, it must be opt-in and cannot be the default local-first path.

RRF policy:

- Use RRF only across real, useful rankers.
- `bm25 + fake-vector` is forbidden.
- RRF output should include component ranks in debug mode.
- No dense-only candidate should be returned unless it passes a relevance threshold and source freshness.

### 4.7 Code Intelligence Precision

Precision tiers:

| Tier | Meaning | Allowed source |
|---|---|---|
| `lexical_fallback` | Regex/token match only | Regex fallback, no parse evidence |
| `static_tree_sitter` | Parsed current blob with tree-sitter | Parser response blob SHA matches current file |
| `static_tree_sitter_degraded` | Parser recovered partial info or parse errors | Parser returned errors or unsupported features |
| `scip_index` | Offline precise index | Valid SCIP index for current commit/blob |
| `exact_lsp` | Live language server response | Allowlisted LSP responded within timeout for current file |

Rules:

- `shaMatch` is false for lexical fallback.
- Exact LSP commands must be allowlisted, schema-validated, timeout-bounded, and user-visible in `doctor`.
- SCIP is preferred over live LSP for batch precision because it is deterministic and indexable.
- Call graph and references are marked lexical until SCIP/LSP evidence exists.
- Swift `callGraph(depth:)` must actually honor depth or the parameter must be removed.

### 4.8 Untrusted Content Boundary

All returned source text is untrusted content.

Required wrapper contract:

- Every `snippet`, `contextPack`, and body text field from code memory is wrapped.
- Wrapper includes:
  - source tool,
  - project ID,
  - file path,
  - chunk ID,
  - blob SHA,
  - content hash,
  - warning that content is data, not instructions.
- The wrapper must be robust against XML/Markdown breakouts by escaping delimiter-like sequences or using a length-prefixed envelope.
- The response includes `trustSignal.untrustedContentWrapped = true`.
- Tests cover Swift and Python paths.

Do not mutate code by default. If an agent wants a sanitized view, return it as a separate transformed field with provenance.

### 4.9 Security And Privacy

Production gates:

- SQLCipher codec linked and verified for release builds, or product explicitly labels DB-at-rest as plaintext and blocks sensitive code indexing. The desired state is SQLCipher active.
- Shared secret scanner corpus used by Swift, Python, and hosted ingestion.
- Scanner includes:
  - provider token regexes,
  - Terraform `.tfvars`,
  - Kubernetes secret manifests,
  - OpenSSH/private key variants,
  - `.npmrc`, `.pypirc`, package-manager tokens,
  - GitLab, Vault, SendGrid, webhook URLs,
  - entropy backstop for long high-entropy strings,
  - base64/hex decoding pass with bounded expansion,
  - multiline string reconstruction.
- Scanner output is label-only. Never audit or log matched secret values.
- `gitleaks` or `trufflehog` can be supported as optional pre-index hooks, but built-in protection must not depend on them.
- Standards-compliant gitignore is mandatory before serious indexing.
- Hosted code tools are feature-flagged off until threat docs are updated and tests prove sealed-only behavior.
- Local rate limiting protects code and memory RPCs from runaway agents.
- LSP/helper subprocesses have allowlists, timeouts, resource caps, and structured degradation.

### 4.10 Hosted Code Sync

Hosted code sync is not part of local v1 hardening.

It can ship only after:

- `docs/REMOTE_MCP_THREAT_MODEL.md` adds source code as a new asset class.
- `docs/PENSIEVE.md` evaluates geometry leakage for code, not just prose.
- Hosted code tool registration is behind an explicit remote feature flag.
- Upload path is device-driven and sealed before egress.
- The server sees no plaintext source, raw paths, raw project names, raw remotes, or raw symbols unless a separate explicit setting allows it.
- Forget is hard-delete with receipt, not just label/retire.
- Embedding-version upgrades are device-driven re-embed/re-cloak flows.
- CI proves hosted code responses are sealed-only and local-decrypt-only.

---

## 5. Implementation Plan

### Phase 0: Freeze Risk And Make The Plan True

Goal: Prevent the current feature from accumulating new risk while hardening starts.

Deliverables:

- Add this plan to docs and link it from the audit report.
- Add a short status note to `docs/PROJECT_CODE_MEMORY_MASTER_PLAN.md`: local phases exist, remediation plan now governs production readiness.
- Gate hosted code tools behind an explicit disabled-by-default feature flag.
- Add a `PROJECT_CODE_MEMORY_PRODUCTION_READY=false` status in `doctor` until P0/P1 blockers pass.
- Add tracking checklist to a GitHub issue or local plan if project uses an issue workflow.

Acceptance:

- Hosted code search/doc tools cannot be issued unless the flag is enabled.
- `doctor` clearly says hardening is incomplete.

### Phase 1: Ship-Blocking Trust Fixes

Goal: Stop misleading agents and close obvious security gaps without major architecture churn.

Deliverables:

- Port untrusted-content wrapper to Swift `searchCode` and `contextPack`.
- Return stale-index degradation:
  - Track stale candidates vs. returned candidates.
  - If stale ratio >= 50 percent, return `status: "degraded"`, `code: "STALE_INDEX"`, index age, commit/blob evidence, and reindex hint.
- Remove deterministic embedding from production ranking:
  - Python `search_code` becomes BM25/path/symbol rank only unless a real embedding provider is active.
  - Response includes `semanticAvailable: false`.
  - Rename constants to `DETERMINISTIC_FINGERPRINT_MODEL` or move to tests.
- Make Python code read tools use `_connect_ro`.
- Add Swift process timeout for static parser and exact-LSP helper; degrade instead of hanging the DB queue.
- Fix Swift lexical evidence: `shaMatch: false`.
- Fix Swift call-edge matching with word-boundary regex and support common call syntaxes.
- Improve Swift reference builder:
  - keyword/stopword exclusion,
  - declaration-line skip,
  - word-boundary matching,
  - comment/string-literal best-effort skip where cheap.
- Add `.vscode`, `.serena`, `.venv`, `target`, and `Vendor` parity to Swift ignored directories, or document why each differs.
- Add `agent_memories_fts` read path to Swift recall if still unwired.
- Add structured logs for index start/end, parser fallback, secret rejection, stale degradation, budget rejection, and LSP disable/degrade.

Acceptance tests:

- Swift context pack wraps malicious comments.
- Python and Swift search do not return fake-semantic-only unrelated results.
- Stale edit returns degraded status instead of empty success.
- `rerun()` does not call-edge-match `run()`.
- Lexical fallback has `shaMatch: false`.
- Parser helper that sleeps beyond timeout degrades without hanging.
- Python read tools open SQLite in `mode=ro`.

### Phase 2: Canonicalize Runtime And Schema

Goal: Remove the dual-implementation time bomb.

Deliverables:

- Move schema creation into canonical migrations.
- Keep raw bootstrap only for migration compatibility, with deprecation comments and test coverage.
- Generate `docs/SCHEMA_SQLITE.sql` from live schema.
- Add schema verifier for columns, types, indexes, constraints, FTS definitions.
- Define `ProjectIdentityV2` and project alias migration.
- Define one canonical chunking algorithm shared by Swift and Python tests:
  - AST-boundary when parser is available,
  - newline/line-boundary fallback with overlap,
  - deterministic chunk IDs from content hash and range.
- Define one audit hash format including `seq`.
- Make Python MCP a daemon RPC client for production writes and optionally production reads.
- Keep Python direct helper APIs only under dev/test harness flags.
- Add shared golden fixtures:
  - small Swift/TS/Python repo,
  - repo with deleted/renamed files,
  - repo with secrets,
  - repo with gitignore negation/globstar,
  - repo with malformed syntax,
  - repo with substring call false positives.

Acceptance tests:

- Swift/Python fixture parity for project ID, chunk IDs/counts, symbol counts, reference counts, audit shape, and stale response shape.
- Schema verifier fails on a removed column/index/constraint.
- Python direct write path is blocked outside dev harness.

### Phase 3: Incremental Indexer And Watcher

Goal: Make watch mode viable on real repositories.

Deliverables:

- Add file manifest diff keyed by blob SHA, mtime, size, and content hash.
- Skip unchanged blobs.
- Delete removed/renamed files and dependent rows.
- Recompute changed-file references and inbound impacted references.
- Add mtime/size/blob cache for query freshness.
- Replace polling watcher with FSEvents on macOS.
- Watch `.git/HEAD`, refs, and index metadata.
- Add parser batching or long-lived parser process.
- Move parse/chunk work outside long DB write transactions.
- Add bounded compaction policy using page count/freelist metrics.
- Make storage budget include index overhead, FTS overhead, and vector overhead.

Acceptance metrics:

- Single-file edit in a 10k-file repo reindexes only that file plus impacted references.
- Warm incremental update target: p95 under 2 seconds for normal source files.
- Warm search target: p95 under 150 ms for 100k chunks with no dense model.
- Query freshness check avoids full file reads for unchanged mtime/size.
- Watcher test has deterministic synchronization, no fixed sleep.

### Phase 4: AST Chunks, Repo Map, And Ranking

Goal: Make the feature feel powerful, not just safe.

Deliverables:

- AST-aware chunking:
  - function/class/type chunks,
  - bounded merged chunks for small adjacent symbols,
  - import/header chunks,
  - fallback line chunks with overlap.
- Repo map:
  - build graph from definitions/references/imports/calls,
  - compute PageRank and personalized PageRank,
  - expose `burnbar_explore` structural overview,
  - include top symbols, dependencies, and likely entry points.
- Ranking features:
  - BM25,
  - exact symbol/path boost,
  - definition boost,
  - repo-map centrality,
  - current session/touched-file boost,
  - token-cost/session-spend boost where privacy-safe and local,
  - freshness penalty,
  - diagnostics/test-failure boost.
- Context pack:
  - whole-symbol inclusion,
  - caller/callee neighbors,
  - imports/config/tests,
  - token budget measured by tokenizer approximation or model-specific tokenizer when available,
  - citations per chunk.

Acceptance metrics:

- Retrieval eval set exists with precision@1, precision@5, MRR, stale false-positive rate, and context-pack token waste.
- Natural-language "where is X handled?" queries beat FTS-only baseline.
- Context packs include complete function/class bodies when within budget.
- Repo map returns a useful project overview without a search query.

### Phase 5: Real Local Embeddings

Goal: Add actual semantic retrieval without compromising local-first posture.

Deliverables:

- Choose local embedding provider:
  - MLX/ONNX first for macOS,
  - explicit model download/cache path,
  - no network during indexing unless the user opted into an external provider.
- Add embedding model registry and version floor.
- Add vector storage:
  - benchmark `sqlite-vec` vs. sidecar store,
  - support quantized vectors if quality holds,
  - cap storage per project,
  - migration and re-embed protocol.
- Dense retrieval enabled only when:
  - model present,
  - vectors current for embedding version,
  - vector query passes threshold,
  - source blob current.
- RRF fuses BM25, dense, path/symbol, and repo-map ranks.
- Add optional reranker after initial retrieval if it stays within latency budget.

Acceptance metrics:

- Fake deterministic vectors cannot influence ranking.
- Dense retrieval improves NL eval precision@5 by a measured threshold over lexical baseline.
- Re-embed after model-version bump is resumable and observable in `doctor`.
- Query returns `semanticAvailable`, `embeddingModel`, `embeddingVersion`, and fallback reason.

### Phase 6: Precision Intelligence

Goal: Move from lexical approximations to precise code navigation where available.

Deliverables:

- SCIP import path:
  - import `.scip` indexes,
  - map occurrences to `pcm_symbols` and `pcm_references`,
  - validate index commit/blob,
  - expose `confidenceTier: scip_index`.
- Exact LSP pool:
  - schema-validated command config,
  - allowlist,
  - per-language timeout,
  - persistent session pool,
  - diagnostics producer,
  - code action/test discovery hooks where safe.
- Call graph:
  - exact edges from SCIP/LSP where available,
  - lexical fallback marked honestly,
  - depth-aware traversal in Swift and Python.
- Test-aware context:
  - discover likely tests for a symbol/file,
  - surface test commands, not auto-run by default unless a later tool explicitly supports it.

Acceptance metrics:

- Exact reference tests for Swift/TS/Python fixtures.
- Malformed code returns degraded parser tier, not false exactness.
- LSP command injection tests pass.
- Diagnostics cache is populated or the tool reports unavailable with reason.

### Phase 7: Hosted Code Sync, Only After Threat Model

Goal: Optional cloud portability without weakening local trust.

Deliverables:

- Disable-by-default feature flag remains until this phase is complete.
- Threat model and Pensieve docs updated for code asset class.
- Device-side seal, cloak, upload, search, decrypt, re-embed, forget flows.
- Hard-delete cloud forget with receipt.
- Hosted rate limits and entitlement scopes specific to code.
- Public docs explain exactly what leaves the device.

Acceptance metrics:

- Hosted code e2e proves server sees no plaintext code/path/symbol by default.
- Local-decrypt shim required for body retrieval.
- Geometry leakage risk accepted in writing with code-specific mitigations.
- Hosted code can be disabled globally through Remote Config/feature flag.

---

## 6. Implementation Checklist

### Ship Blockers

- [x] Swift snippets/context packs wrapped as untrusted content.
- [x] Swift/Python stale-index degraded status implemented.
- [x] Deterministic fake embedding removed from production ranking.
- [x] Python code read tools use read-only SQLite handles or daemon RPC reads.
- [x] Swift static parser and exact-LSP subprocesses have timeouts.
- [x] Hosted code tools gated off by default.
- [x] Swift lexical fallback sets `shaMatch: false`.
- [x] Swift call/reference matching uses word boundaries and declaration-line skips.
- [x] Shared secret scanner corpus started and wired to Swift/Python.
- [x] SQLCipher release dependency decision made and enforced.
- [x] `doctor` reports parser availability, DB encryption state, stale index state, hosted-code flag, schema version, and semantic availability.

### Canonicalization

- [x] GRDB/canonical migrations own PCM schema.
- [x] Raw bootstrap marked compatibility-only.
- [x] Schema doc generated or strictly verified against live schema.
- [x] Project ID v2 and path aliasing implemented.
- [x] Python production writes go through daemon RPC only.
- [x] Shared parity fixtures committed.
- [x] Swift/Python parity tests added.
- [x] Audit hash format unified and includes sequence number.
- [x] Chunker unified across runtime tests.

### Indexing And Performance

- [x] File manifest table added.
- [x] Delta index skips unchanged blobs.
- [x] Removed/renamed files prune all dependent rows.
- [x] FSEvents watcher implemented.
- [x] `.git/HEAD` and refs watched.
- [x] Parser service supports batch or long-lived JSONL mode.
- [x] Freshness cache avoids per-candidate full file reads.
- [x] Storage budget includes FTS/vector overhead.
- [x] Compaction policy based on freelist/page metrics.
- [x] Load test wired to nightly or pre-release CI.

### Retrieval Quality

- [x] AST-aware chunks implemented for Swift/TS/Python.
- [x] Repo map generated and exposed through `explore`.
- [x] Rank features stored/explainable.
- [x] Context pack includes complete symbols when possible.
- [x] Token budget estimation improved.
- [x] Retrieval eval suite added.
- [x] Real local embedding provider selected.
- [x] Vector index benchmark completed.
- [x] Dense retrieval enabled only with real current embeddings.
- [x] Optional reranker evaluated against latency budget.

### Code Intelligence

- [x] Static parser language coverage expanded or indexed extension set narrowed.
- [x] SCIP import ADR written.
- [x] SCIP import implemented for at least one ecosystem.
- [x] LSP command schema and allowlist implemented.
- [x] Persistent LSP pool implemented.
- [x] Diagnostics producer implemented.
- [x] Swift `callGraph(depth:)` honors depth.
- [x] Exact reference tests added.
- [x] Degraded parser tiers tested.

### Security And Privacy

- [x] Entropy/base64/hex secret scanner pass.
- [x] Terraform/Kubernetes/package-manager/webhook/Vault/GitLab/SendGrid patterns.
- [x] Standards-compliant gitignore parser.
- [x] `.git/info/exclude` and global gitignore support.
- [x] Local rate limiting for code/memory RPCs.
- [x] LSP/helper resource caps.
- [x] Code-memory telemetry review gate.
- [x] Retention and forget policy documented.
- [x] Hosted code threat model completed before enablement.
- [x] Hosted code sealed-only CI proofs.

### DX And Documentation

- [x] MCP setup builds or verifies Rust parser helper.
- [x] README tools table fixed.
- [x] Hermes skill documents Project Code Memory tools.
- [x] `docs/PENSIEVE.md` adds code asset-class section when hosted sync starts.
- [x] `docs/REMOTE_MCP_THREAT_MODEL.md` adds code asset-class section when hosted sync starts.
- [x] `docs/SCHEMA_SQLITE.sql` updated with PCM schema.
- [x] `CHANGELOG.md` notes production readiness gates when implementation lands.
- [x] Operator runbook includes reindex, reset, compaction, parser, SQLCipher, and hosted-code-disable steps.

---

## 7. Proof Gates

No phase is done until its proof gate passes.

### Unit

- Secret scanner adversarial corpus.
- Gitignore semantics corpus.
- Chunker golden fixtures.
- Prompt-injection wrapper tests in Swift and Python.
- Stale-index degradation tests.
- Parser timeout/degradation tests.
- SQLCipher availability/enforcement tests.
- Audit-chain tamper tests.

### Integration

- End-to-end daemon RPC for every code tool.
- Python MCP to daemon RPC path.
- Swift/Python parity on shared fixtures.
- Hosted code feature-flag denial.
- FSEvents watcher deterministic reindex test.
- Project alias/rename tests.

### Performance

- Cold index benchmark on synthetic and BurnBar-sized repos.
- Single-file delta benchmark.
- Query p50/p95/p99 for search, symbol, references, call graph, context pack.
- DB size multiplier before/after delete/reindex/compact.
- Parser process count and timeout budget.

### Retrieval Evaluation

- Exact symbol lookup precision@1.
- Path query precision@5.
- NL code intent precision@5.
- Reference precision sampled by fixture.
- Call graph precision sampled by fixture.
- Stale false-positive rate.
- Context-pack completeness and token waste.

### Security

- Secret-in-source rejection.
- Encoded/fragmented secret rejection.
- Symlink escape.
- Path traversal.
- LSP command injection.
- Read-only Python SQLite handles for read tools.
- Hosted sealed-only response proofs.
- No plaintext secret values in logs/audit.

---

## 8. Recommended Sequence

1. **This week:** Phase 0 and Phase 1. These are production blockers and are mostly localized.
2. **Next 1-2 weeks:** Phase 2 and Phase 3. This removes the split-brain runtime and makes indexing viable.
3. **Following 2-4 weeks:** Phase 4 and Phase 5. This is where the feature becomes frontier-grade for agents.
4. **After retrieval/indexing are stable:** Phase 6. Add precise code intelligence via SCIP/LSP.
5. **Only after threat-model signoff:** Phase 7 hosted code sync.

The implementation should land as a sequence of reviewable PRs, but the acceptance bar is the whole system: no production-ready claim until ship blockers, canonicalization, proof gates, docs, and CI are complete.

---

## 9. External Design Anchors Checked

These are not dependencies to blindly vendor; they define the frontier shape this plan is aligning to.

- Tree-sitter is an incremental parsing library suitable for efficient source-tree updates: https://tree-sitter.github.io/
- SCIP is a language-agnostic code intelligence protocol for precise definition/reference/index data: https://scip-code.org/
- Sourcegraph introduced SCIP to improve code navigation over LSIF-style workflows: https://sourcegraph.com/blog/announcing-scip
- Aider's repo map uses concise structural context from important classes/functions/signatures: https://aider.chat/docs/repomap.html
- LlamaIndex CodeSplitter is an AST/tree-sitter-aware code splitting pattern: https://developers.llamaindex.ai/python/examples/node_parsers/code_splitter_chunking/
- SQLite FTS5 is the local sparse search foundation and provides BM25 ranking: https://sqlite.org/fts5.html
- `sqlite-vec` is a local SQLite vector-search option to benchmark before adopting: https://github.com/asg017/sqlite-vec
- OpenAI embeddings documentation confirms learned embeddings are numeric semantic representations with model-specific dimensions, unlike deterministic hashes: https://developers.openai.com/api/docs/guides/embeddings
- Git's gitignore docs define negation and other semantics the hand-rolled parser currently omits: https://git-scm.com/docs/gitignore
- Apple FSEvents provides directory hierarchy change notifications and should replace polling on macOS: https://developer.apple.com/documentation/coreservices/file_system_events
- SQLCipher exposes `PRAGMA cipher_version` as the runtime proof that the codec is active: https://www.zetetic.net/sqlcipher/sqlcipher-api/

---

## 10. Definition Of Done

Project Code Memory is production-ready when all of these are true:

- A malicious source comment cannot be returned to an agent without an explicit untrusted-content envelope.
- A stale index cannot look like an empty successful result.
- Fake embeddings cannot influence ranking.
- Swift and Python cannot produce incompatible production writes or schema mutations.
- The schema is owned by canonical migrations and verified in CI.
- The indexer updates changed files incrementally and prunes deleted files.
- Parser/LSP helpers cannot hang the daemon or execute unvalidated commands.
- Local code index storage is encrypted in release builds or the product blocks sensitive-code indexing with an explicit warning.
- Hosted code tools are disabled until the code asset threat model passes.
- Retrieval quality is measured against fixtures and improves over FTS-only when dense retrieval is enabled.
- The docs, setup, `doctor`, tests, and CI all tell the same truth.

That is the bar for "SOTA" here: not just more algorithms, but a code memory system that is precise, fast, private, observable, and honest enough for autonomous agents to rely on.
