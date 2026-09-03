# Local Memory MCP v2 — design

- **Date:** 2026-09-02
- **Scope:** `tools/openburnbar-mcp` memory toolset (`BURNBAR_MCP_TOOLSET=memory`)
- **Ask:** "Examine the BurnBar memory MCP. I want it to be state of the art at
  collecting important non-confidential information; as good as mem0.ai or
  Mixedbread. Also add an experimental mode that retains confidential info like
  keys."
- **Status:** implemented in this branch as the `tools/openburnbar-mcp/memory_engine/`
  package plus server wiring, tests, and docs.

---

## 1. Findings — what the memory MCP is today

The memory toolset advertises `burnbar_remember` / `burnbar_recall` /
`burnbar_forget` / `burnbar_audit_trail` / `burnbar_memory_analytics` /
`burnbar_memory_doctor`. Under the hood:

| Area | Today | Consequence |
|---|---|---|
| **Production reachability** | Writes go daemon-only (`daemon.memory.remember`). The running daemon rejects the Python process as a peer (`-32001 first-party code-signature verification`). Reads open `openburnbar.sqlite` directly, which is SQLCipher-encrypted; the daemon-read shim then hits the same peer gate. | **Every memory tool fails on a signed install.** `burnbar_memory_doctor` raises a traceback; `burnbar_recall` errors; `burnbar_remember` returns `DAEMON_WRITE_REJECTED`. The signed CLI bridge (`openburnbar-cli search-sql`) is read-only and is not installed here. |
| **Write gating** | `burnbar_remember` requires `OPENBURNBAR_LOCAL_MCP_ENABLE_LOCAL_WRITE=true`. The repo's own `.mcp.json` does not set it. | Memory writes are denied by default in the very config that ships `BURNBAR_MCP_TOOLSET=memory`. |
| **Extraction** | None. The tool takes one pre-written sentence. The Pensieve `memoryHook` (session-end `claude -p`) and the AgentLens in-app extractor exist but are not wired to the local MCP. | The agent has to decide what is worth remembering and call the tool once per fact. Nothing is collected automatically. |
| **Secret / PII gate** | Binary **reject** on any corpus hit, including PII classes (email, phone, IPv4). The redacted body is computed and thrown away. | "Alberto's email is x@y" is rejected. "Deploy uses a token stored in 1Password (ghp_…)" is rejected instead of redacted. This is the direct cause of "not good at collecting non-confidential information". |
| **Dedup / conflict** | ID = `sha256(project:body)`; `ON CONFLICT DO UPDATE`. `superseded_by` / `valid_to` columns exist but nothing writes them. | Rewording creates duplicates; contradictions coexist forever; no UPDATE/DELETE semantics. |
| **Retrieval** | Count of query tokens present as substrings of the body; rank = missing tokens; tie-break by `updated_at`. Per row, the entire project snapshot JSON is parsed to resolve the body (O(n²)). | No stemming, no BM25, no embeddings, no reranking, no recency or confidence weighting. Quadratic on the number of memories. |
| **Filters** | `scope`, project. | No kind/tag/entity/metadata/date/confidence filters. |
| **History / CRUD** | Label-only audit chain (tamper evidence, no content). No `get`, `list`, `update`, `history`, `forget_all`. | "What did this memory say before?" is unanswerable. Update = forget + remember with a new ID. |
| **Schema drift** | Python `ensure_schema` lacks `review_status`; the Swift daemon has it and quarantines new memories. Python recall ignores it. Python and Swift derive different memory IDs for the same body (`project+hash` vs `project:hash`). | The MCP would surface quarantined memories if it could read the daemon store, and the two writers disagree on identity. |

### Versus mem0 and Mixedbread

| Capability | mem0 | Mixedbread | BurnBar local MCP (before) | After this change |
|---|---|---|---|---|
| Fact extraction from messages | LLM, ADD/UPDATE/DELETE/NONE | n/a (document store) | none | heuristic extractor + agent-supplied facts + pluggable LLM (`claude -p`, Ollama); ADD/UPDATE/NONE/DELETE with history |
| Raw mode (`infer=False`) | yes | yes (files) | n/a | `extractor="none"` |
| Dedup / supersede | LLM-decided | n/a | content-hash only | cosine + Jaccard dedup, slot-key contradiction → supersede, negation → retire |
| Vector retrieval | yes | mxbai-embed | none | Ollama embeddings (`nomic-embed-text` default, `mxbai-embed-large` supported), version-floored |
| Keyword / hybrid | BM25 where store supports | hybrid | substring count | BM25 + vector, reciprocal-rank fusion |
| Rerank | optional model | mxbai-rerank | none | deterministic salience rerank (confidence, kind, recency half-life, access reinforcement); LLM rerank left to the caller |
| Metadata filters | eq/ne/in/nin/gt/gte/lt/lte/contains | eq/in/… + facets | none | same operator set over metadata, kind, tags, entities, dates, confidence |
| History | per-memory | versions | label-only audit | per-memory before/after history (encrypted at rest) + label-only audit chain |
| Entities / graph | optional graph | n/a | none | heuristic entities + (subject, predicate, object) relations |
| Expiration / immutable | yes | n/a | none | `expires_at`, `immutable` |
| Export / import | yes | yes | none | JSON export/import, secrets excluded by default |
| Secret handling | none built in | none | reject | policy: `redact` (default) / `reject` / `retain` (experimental, encrypted vault, capability-gated) |
| Prompt-injection posture | none | none | untrusted wrapper on some reads | wrapper on every recall body + write-time injection quarantine |

---

## 2. Decision — a Python-owned memory engine with a mirror

The master plan (`docs/PROJECT_CODE_MEMORY_MASTER_PLAN.md` §5.2) says memory
writes must fail closed through the daemon. That rule assumed the local MCP
can reach the daemon. On a signed install it cannot, by design, and there is
no signed write bridge. Keeping the rule literally means the local memory MCP
stays non-functional in production.

The rule's *purpose* is that the secret gate and the audit chain cannot be
bypassed by killing the daemon. The engine preserves the purpose in-process:
every write passes the gate and appends to a hash-chained audit before it is
visible, and both live in the same SQLite transaction as the row.

So:

- The MCP owns `openburnbar-memory.sqlite` (override `OPENBURNBAR_MEMORY_DB_PATH`)
  next to the app database. This is the authority for the local memory MCP.
- Bodies and history bodies are **AES-256-GCM encrypted at rest** with a key
  the MCP owns (`openburnbar-memory.key`, mode 0600, or
  `OPENBURNBAR_MEMORY_KEY_BASE64`). Vectors and metadata are plaintext, which
  matches the app's own on-disk `VectorIndexes/` posture. There is no FTS
  table on disk: BM25 runs in Python over decrypted active bodies of one
  project, so the only plaintext derivative on disk is the vector.
- Committed, non-secret, non-quarantined memories are **mirrored** to the
  daemon ledger (`daemon.memory.remember`) through the signed
  `openburnbar-cli memory-remember` courier when installed; unsigned dev
  builds fall back to the daemon socket. Mirror status is reported per write
  and never blocks success. The daemon's content-derived ID is retained so
  `memory-forget` deletes the matching mirror rather than the Python ID. That
  ID remains as a metadata-only tombstone after local deletion until the
  daemon confirms its delete, so a transient outage is retryable.
- The daemon's own `agent_memories` body authority remains intact. Its recall
  path reuses the existing `memory_embedding_refs` and `memory_salience`
  sidecars for BM25 + NLEmbedding reciprocal-rank fusion and deterministic
  salience parity. Quarantined/rejected daemon bodies are held in the
  SQLCipher-protected `memory_quarantine_bodies` table and stay out of
  `project_memory_snapshots`; approval atomically moves a body into the
  snapshot, while rejection moves it back out. The engine is not a
  fourth *body* store in the master-plan sense: the master plan's concern was
  divergence and cloud-sync surface, and the engine store never syncs.

## 3. Module map and data model (`memory_engine/`, schema v1)

The engine is the package `tools/openburnbar-mcp/memory_engine/` with a facade
`__init__.py`. `import memory_engine as me` reaches every name the engine
exports (public and underscore-prefixed alike), so `server.py`, `eval_memory.py`,
and the tests are unaware of the split.

| Module | Owns |
|---|---|
| `constants.py` | header constants (env names, policies, budgets, RRF weights, `ENGINE_SCHEMA_VERSION`) — one place to tune |
| `_util.py` | `now_iso`, `sha256_hex`, `_json_dumps`, the kind/scope/tag normalizers, `_aux_strings`, expiry helpers |
| `text.py` | `tokenize`, `_stem`, `BM25`, snippet and token-budget helpers |
| `crypto.py` | `KeyRing`, the private-mode store-file helpers, `store_lock_path` |
| `embeddings.py` | providers, vector codec, provider cache |
| `gate.py` | `scan_text`, `apply_gate`, `injection_labels`, `GATE_CORPUS_AVAILABLE` |
| `extract.py` | `Fact`, `heuristic_extract`, `parse_llm_facts`, LLM extractors, entities and relations |
| `store.py` | `SCHEMA_SQL`, `open_store`, `ensure_schema`, `SCHEMA_MIGRATIONS`, `SchemaTooNew`, `audit_event`, `verify_audit_chain`, `resolve_project` |
| `filters.py` | filter validation, SQL compilation, `match_filters` |
| `engine.py` | `EngineConfig`, `ActiveMemory`, and `MemoryEngine` composed from three mixins |
| `_write.py` | `MemoryEngine`'s write path: `memorize`, `remember`, reconciliation |
| `_read.py` | read path and CRUD: `recall`, `pack`, `get`, `list`, `history`, `review`, `forget*` |
| `_admin.py` | maintenance: `doctor`, `export`, `import`, `reindex`, audit trail |

No module exceeds 1,500 lines (`tests/test_memory_engine_layout.py` enforces
it, and also that the facade exposes every name consumers reference). Mutable
module flags are read through their module at call time — inside the package
`gate.GATE_CORPUS_AVAILABLE`, never `from .gate import GATE_CORPUS_AVAILABLE` —
so monkeypatching keeps working; tests patch `me.gate.` / `me.embeddings.`.

**Versioned migrations.** `ensure_schema` gates on the version *before* it runs
any schema: it creates `engine_meta` alone (a no-op on any store that already
has it), reads the stamp, and only then applies `SCHEMA_SQL` and the pending
migrations. A store stamped newer than `ENGINE_SCHEMA_VERSION`, or stamped with
something that is not an integer, raises `SchemaTooNew` naming the stored value
and this engine's version, and its schema is left untouched (the file header may
switch to WAL mode: `PRAGMA journal_mode=WAL` runs before `ensure_schema`,
because the locked-retry logic depends on that order, so a refused store can
gain `-wal` / `-shm` sidecars) — this engine never "repairs" a schema it cannot
read, so two engine versions on one machine cannot corrupt each other's store.

`store.SCHEMA_MIGRATIONS` is an ordered tuple of `(target_version, statements)`
steps, empty today, applied in order above the stored version. Each step is one
explicit `BEGIN` / `commit` — `with conn:` does not wrap DDL under the driver's
default isolation level — so a step's statements and its version stamp land
together or not at all, and a failure leaves the store stamped at the last step
that completed. `SCHEMA_MIGRATIONS` is read and patched through
`memory_engine.store`; it is deliberately absent from the facade, because an
alias would be bound once at import and a patch on it would be silently lost.
`tests/test_store_migrations.py` pins every one of these behaviors, and
`tests/test_memory_engine_layout.py` enforces the no-alias rule.

### Schema

```
projects(project_id PK, fingerprint, display_name, primary_path, created_at, updated_at)
memories(rowid PK, id UNIQUE, project_id, scope, kind, body_cipher BLOB, body_nonce BLOB,
         key_id, body_hash, sensitivity, review_status, confidence, salience,
         access_count, last_accessed_at, immutable, expires_at, valid_from, valid_to,
         superseded_by, supersedes_json, tags_json, entities_json, metadata_json,
         source_kind, source_ref, source_hash, extractor, embedding_version,
         created_at, updated_at)
memory_vectors(memory_rowid PK, embedding_version, dimension, vector BLOB)
memory_history(seq PK, memory_id, project_id, event, actor, ts,
               before_cipher, before_nonce, after_cipher, after_nonce, key_id, meta_json)
memory_relations(id PK, project_id, memory_id, subject, predicate, object, confidence)
memory_vault(memory_id PK, project_id, secret_cipher, secret_nonce, key_id, labels_json, created_at)
memory_ingest(source_hash PK, project_id, ts, decisions_json)
memory_audit(seq PK, ts, actor, action, domain, project_id, subject_id, labels_json, prev_hash, hash)
engine_meta(key PK, value)
```

- `id` = `mem_` + 32 hex, random. Stable across updates; history tracks changes.
- `UNIQUE(project_id, scope, body_hash)` is the exact-dedup key.
- `sensitivity` ∈ `none | pii | redacted | secret`. `secret` rows have a
  redacted body in `memories` and the verbatim body in `memory_vault`.
- `review_status` ∈ `approved | quarantined | rejected`. Quarantine is
  applied at write time for injection-suspect text and is excluded from
  recall unless asked for.
- `scope` is free-form; conventions: `project` (default for repo facts),
  `personal` (facts about the user, recalled in every project), anything
  else is treated like `project`.
- `kind` ∈ `fact | preference | decision | gotcha | architecture | todo |
  event | profile | relationship | procedure | note | other`.

## 4. Pipelines

### 4.1 Write (`memorize` / `remember`)

1. **Input** — `messages` (role/content), `text`, or pre-extracted `facts`.
   Whole-input `source_hash` is checked against `memory_ingest` so replaying
   the same transcript is a no-op.
2. **Extract** — `facts` if supplied (the calling agent is an LLM; this is the
   zero-cost, highest-quality path and the tool description says so). Else
   `OPENBURNBAR_MEMORY_EXTRACTOR` = `heuristic` (default) | `claude` |
   `ollama` | `none` (raw). The heuristic extractor sentence-splits, scores
   durability cues (decisions, preferences, gotchas, conventions, identifiers,
   paths, versions), drops chatter/questions/tool noise, classifies kind and
   scope, assigns confidence, and dedups within the batch. LLM extractors use
   the same JSON contract as the Pensieve hook and are mocked in tests.
3. **Gate** — the shared `secret-pattern-corpus.json` (kind-aware) plus the
   entropy branch. Secret policy `OPENBURNBAR_MEMORY_SECRET_POLICY` =
   `redact` (default) | `reject` | `retain`. PII policy
   `OPENBURNBAR_MEMORY_PII_POLICY` = `keep` (default) | `redact` | `reject`;
   SSN and card numbers are always redacted. `retain` requires the
   `memory_secret_retain` capability (`OPENBURNBAR_LOCAL_MCP_ENABLE_SECRET_RETAIN=true`,
   never granted by the operator profile) and stores the verbatim body only
   in the encrypted vault. Every decision is audited label-only.
4. **Injection screen** — sentinel patterns (`ignore previous instructions`,
   `SYSTEM:`, untrusted-wrapper and memory-pack markers, shell-pipe-to-sh…)
   quarantine the memory instead of rejecting it.
5. **Resolve** — against active memories in the same project (and personal
   scope): cosine ≥ 0.92 or Jaccard ≥ 0.75 → `NONE` (reinforce: bump
   access, merge tags/entities, max confidence); explicit `supersedes` or a
   matching `(subject, predicate)` slot with a different object → `UPDATE`
   (old row gets `valid_to`/`superseded_by`); negation phrasing against a
   matching slot → `DELETE` (retire, store nothing); else `ADD`.
6. **Store** — encrypted body, vector (if a provider is available), entities,
   relations, history row, audit row, all in one transaction.
7. **Mirror** — best-effort daemon `remember` for `ADD`/`UPDATE` of
   non-secret, approved rows; status returned.

### 4.2 Read (`recall`)

1. Load active rows for the project (+ personal scope from any project;
   `include_cross_project` widens project scope). Cache per project in
   process, invalidated by `(count, max(updated_at))`.
2. Lexical: BM25 (k1=1.2, b=0.75) over body + tags + entities with a
   code-aware tokenizer (camelCase/snake_case splitting, light stemming).
3. Semantic: cosine over vectors of the active embedding version only.
4. Fuse: reciprocal-rank fusion (k=60) of both rank lists; a memory found by
   one signal only still ranks.
5. Rerank: multiply by salience = kind weight × confidence × recency
   half-life (30d for `event`/`todo`, 365d otherwise) × access boost
   (`1 + 0.1·log2(1+access)` capped at 1.5).
6. Filter: kind, scope, tags, entities, metadata operators, since/until,
   min_confidence, sensitivity, review status, expiry, supersession. List
   filters, counts, ordering, and pagination execute in SQLite without joining
   vector blobs or decrypting rows outside the requested page. Invalid time
   bounds fail closed instead of widening recall.
7. Touch `access_count`/`last_accessed_at` on returned rows (reinforcement),
   wrap every body with the untrusted-content wrapper, return `score`,
   `matchedBy`, `why`.

`recall_pack` builds a token-budgeted prompt block from the same ranking
(mirrors the app's `MemoryRecallBudget`) and wraps the complete block as
untrusted retrieved data. Pack boundary markers are also write-time injection
sentinels, preventing stored text from forging an early footer.

## 5. Tool surface (memory toolset)

Kept (semantics upgraded, signatures backward-compatible):
`burnbar_remember`, `burnbar_recall`, `burnbar_forget`, `burnbar_audit_trail`,
`burnbar_memory_analytics`, `burnbar_memory_doctor`.

New: `burnbar_memorize`, `burnbar_recall_pack`, `burnbar_memory_get`,
`burnbar_memory_list`, `burnbar_memory_update`, `burnbar_memory_history`,
`burnbar_memory_review`, `burnbar_forget_all`, `burnbar_memory_entities`,
`burnbar_memory_relations`, `burnbar_memory_export`, `burnbar_memory_import`,
`burnbar_memory_reindex`.

Capabilities: `memory_write` (new; on when `local_write`, operator profile,
`OPENBURNBAR_LOCAL_MCP_ENABLE_MEMORY_WRITE=true`, or when
`BURNBAR_MCP_TOOLSET=memory` and the env is not explicitly `false`),
`memory_secret_retain` (new; explicit env only), `sensitive_read` (export,
`include_secrets`).

External extractors receive the transcript only after both secret and the
configured PII policy have run. `redact` removes detected PII before the
subprocess or loopback request; `reject` withholds the transcript entirely.
Quarantined write decisions are returned through the same untrusted-data
wrapper as read results.

Write scopes are strict (`auto | project | personal`). Non-approved facts may
be retained for review but have no authority to supersede or retire approved
rows. Idempotent ingest receipts are written only for terminal batches; replay
hydrates committed decisions from the encrypted row so a previously failed
daemon mirror can be retried safely.

## 6. Deliberate contract changes

- `burnbar_remember` no longer fails closed when the daemon is unreachable. It
  succeeds locally (gated, audited, encrypted) and reports the mirror outcome.
  Tests that asserted `DAEMON_WRITE_REQUIRED` are re-scoped to assert the
  mirror status and the daemon method name.
- Memory writes are on by default for the `memory` toolset.
- `burnbar_memory_doctor` never raises; unreachable daemon / encrypted store
  become structured findings.
- `burnbar_forget` mirrors to the daemon only with the daemon's own id
  (recorded on the row when the mirror write was accepted); a row that was
  never mirrored reports `mirror.status: skipped` instead of a bogus forget.
  Failed daemon deletes keep a metadata-only tombstone and are retried by a
  later `burnbar_forget`; the tombstone clears only after daemon confirmation.
- The daemon mirror intentionally excludes expiring rows until its RPC schema
  can enforce expiry. Personal-memory reinforcement uses the memory owner's
  project path and retires a prior daemon copy before replacement.
- `all_projects=true` exports are diagnostic archives, not a flattening import
  format. Project-scoped exports remain portable; multi-project imports fail
  closed to preserve ownership boundaries.
- Memories in the daemon-owned `agent_memories` store are imported into the
  engine store once per project on first recall/list (`legacyMigration`), so
  an upgrade does not make earlier memories disappear from MCP recall.
  Unavailable or capability-disabled attempts are not cached and retry on the
  next read.

### 6.1 Review hardening (Codex + Cursor security review of PR #2485)

Every finding is pinned by a test in `tests/test_memory_engine_hardening.py`:

- Plaintext columns never hold bodies or secrets: reinforcement history keeps
  a hash and labels (the gated incoming text goes to the encrypted column),
  the ingest replay table keeps event/id metadata only, and tags, entities,
  metadata, and `source_ref` pass the same gate as the body.
- Daemon mirror calls use the gated `sourceRef`, never the caller's raw source
  string, and pending daemon forgets remain retryable after local deletion.
- Recall packs are wrapped as untrusted content and their boundary markers are
  screened on write; transient legacy-migration failures are retried.
- Encoded secrets (base64 / hex) are redacted at their surface span; secrets
  visible only in a joined or continued view are refused under `redact`
  (and the body is withheld under `retain`).
- External extractors receive a gated transcript or nothing; the tool's
  `extractor` argument needs `memory_llm_extract` (plus `spawn_process` for
  `claude`) unless the operator configured that extractor in the env.
- Key publication is atomic (temp file + hard link), so concurrent first
  runs cannot truncate each other's key; WAL / SHM sidecars are mode 0600.
- Lifecycle: expired duplicates reactivate, rejected duplicates stay hidden,
  edits that collide with another active body return `DUPLICATE_BODY`,
  rejected updates are committed to the audit chain, a failed re-embedding
  drops the stale vector, personal-scope conflicts reconcile across projects,
  the recall cache stamp includes reinforcement fields, and the first pack
  item is truncated to the token budget.
- MCP wiring: snippets are wrapped like bodies, explicit empty lists clear
  patch fields, malformed JSON arguments return `INVALID_JSON_ARGUMENT`,
  ingest idempotency is per project, and exports re-import with their
  `expiresAt` / `sourceRef`.
- The untrusted-content boundary covers tags, entities, metadata keys/values,
  `sourceRef`, history metadata, entity lists, and extracted relations as well
  as memory bodies. Injection sentinels in any persisted free-form field
  quarantine the row; default read surfaces hide it, while explicit review
  reads return shape-preserving wrappers. A read-time scan also quarantines
  legacy rows whose stored status predates this gate.
- Supersession and confirmed bulk deletion retire corresponding daemon mirrors;
  update, review, and import writes reconcile them too. Failed remote deletes
  retain metadata-only tombstones with the mirrored body hash, so body-changing
  updates retire the previous content-derived id before publishing a
  replacement and can resume safely after interruption. Scoped reindexing
  purges stale vectors only for that project, transient Ollama startup misses
  are retried without an MCP restart, and malformed filter shapes fail closed
  instead of widening a query.

Round 2 (`tests/test_memory_engine_hardening_round2.py`):

- The audit-chain head is read under `BEGIN IMMEDIATE`, and key publication
  is serialized with an advisory lock, so concurrent MCP processes cannot
  break the chain or replace each other's key. Opening the store no longer
  leaves an implicit write transaction open.
- Injection screening covers tags, entities, metadata, and `source_ref`;
  the mirror receives the gated `sourceRef`; pack sentinels are injection
  sentinels and are neutralized inside pack lines; the pack budget covers
  the envelope (floor 192 tokens).
- A failed daemon-side forget leaves a tombstone that later calls retry;
  a fact that reverts to a retired statement reactivates that row; retain
  mode rotates the vault on duplicate redacted bodies; forgetting a memory
  invalidates the ingest receipts that named it; imports keep `rejected`;
  update history records every mutable field; doctor reports the store it
  opened; relations include personal memories from other projects; legacy
  migration retries non-terminal outcomes.
- Daemon (Swift): the BM25 document keeps `sourcePath`, and semantic recall
  reads only the candidates' vectors.

Round 3 (`tests/test_memory_engine_hardening_round3.py`):

- Missing or corrupt keys fail closed for populated stores; concurrent
  duplicate insertion is serialized; embedding work happens before the write
  lock; cache stamps observe vectors added by another process.
- Ingest identity covers scope, tags, metadata, extractor and provenance;
  invalid expirations are rejected; lexical recall indexes `sourceRef`; packs
  reinforce only returned rows; historical imports skip retired rows; immutable
  memories are never reported as superseded.
- Mirror cleanup covers reconciliation `DELETE` events and reinforcement that
  moves a row into quarantine. Only approved imports mirror, daemon deletes
  must confirm `localDeleted`, and retry tombstones retain the original project
  path. Exported content is wrapped at the MCP boundary.
- Legacy migration paginates past 2,000 rows, the launcher rejects pre-3.11
  venvs, and daemon salience reads bind only the current recall candidates.

### 6.2 Post-merge launch-readiness audit

Pinned by `tests/test_memory_engine_post_merge_audit.py`,
`tests/test_mcp_stdio_smoke.py`, and two new cases in
`bootstrap-memory.test.sh`:

- A brand-new store opened by several MCP clients at once is initialized
  under the same advisory lock the key file uses, with a bounded retry
  underneath; before this, 9 of 40 simultaneous first opens failed with
  `database is locked`.
- `bootstrap-memory.sh` serializes venv creation with an atomic `mkdir` lock
  (reclaimed when its owner died) and can install into a venv that has no
  `pip` (`uv venv`, `python -m venv --without-pip`) via `ensurepip`, then `uv`.
  The repo's own `.mcp.json` entry failed on a `uv`-made venv before this.
- Review decisions read the row under `BEGIN IMMEDIATE`, and
  `expected_updated_at` refuses a decision on a body the reviewer never saw.
- Bulk delete is bound to the previewed rows through `selectionToken`.
- Every filter operator validates its operand shape (`INVALID_FILTER` instead
  of a SQLite type error), on `list` and `recall` alike.
- Mirror updates re-read the row and let the newer write own the mirror.
- A real stdio JSON-RPC session (initialize, tools/list, tools/call) is part
  of the suite, not only an import check.

## 7. Automatic collection

The engine's job is to collect durable, non-confidential information. Until now
nothing collected unless an agent chose to call `burnbar_memorize`. A Claude
Code `SessionEnd` hook closes that gap by routing every session transcript
through the same tool wrapper — same gate, same encryption, same audit chain,
same daemon-mirror behavior. Nothing about the write path is special-cased for
the hook.

- `tools/openburnbar-mcp/memorize_transcript.py` — the CLI. `--hook-stdin`
  reads Claude Code's payload (`session_id`, `transcript_path`, `cwd`,
  `reason`); the flag form (`--transcript`, `--project`, `--session-id`,
  `--reason`, `--budget-seconds`) runs it by hand. It keeps `user` /
  `assistant` prose only — string content or `text` blocks; tool use, tool
  results, thinking, summaries, `isMeta` lines, malformed lines, and Claude
  Code wrapper tags (`<system-reminder>`, `<command-*>`, `<local-command-*>`)
  are dropped — then keeps the tail within 400 messages / 200,000 characters
  and calls `burnbar_memorize(messages=…, source_kind="session",
  source_ref="claude-code:<session_id>", metadata={hook, reason, sessionId})`.
  The transcript format is documented as internal, so parsing is lenient by
  contract: it never raises on a shape it does not recognize.

- `tools/openburnbar-mcp/hooks/claude-code-session-end.sh` — the hook command.
  Honors the `OPENBURNBAR_MEMORY_SESSION_HOOK` kill switch before doing
  anything, picks `OPENBURNBAR_MEMORY_PYTHON` or the venv interpreter
  (bootstrapping quietly when it is missing), pipes the payload through, and
  always exits 0.

**Provenance.** A stored row keeps both halves of where it came from. The
heuristic extractor stamps each fact with the position of the message it was
taken from (`m3`), which names nothing outside its own batch, so the write path
prefixes the caller's reference: a hook write lands as
`sourceRef = "claude-code:<session_id>#m3"`. A fact carrying a real reference of
its own — an LLM extractor, or caller-supplied `facts` — keeps it untouched, and
a `memorize` call with no `source_ref` still stores the bare marker. The ingest
receipt keys on the caller's inputs and not on the stored refs, so idempotency
is unaffected. Provenance is not content: `source_ref` is kept out of the token
set that decides near-duplicate similarity, so naming a batch never merges the
facts inside it. It stays in the lexical index (`ActiveMemory.recall_tokens`), so
a memory captured from `docs/release/runbook.md` is still findable by that path.

**Never blocks session end.** A hook cannot block, so failure is not an option
the CLI takes: it enforces its own 20-second deadline with `signal.setitimer`
(macOS has no `timeout(1)`), reports one JSON status line on stdout, and exits 0
in every case except a usage error. Statuses are `memorized`,
`already_ingested`, `skipped_disabled`, `skipped_missing_transcript`,
`skipped_empty`, `timeout`, and `error`. `server` (and therefore FastMCP) is
imported lazily, so the kill switch and a missing transcript cost nothing.

**Idempotent.** `memorize` keys an ingest receipt on the content hash of the
transcript and project, so replaying a session (`--resume`, a re-fired hook, a
manual re-run) returns `code: ALREADY_INGESTED`, surfaced by the CLI as
`already_ingested`, and adds no memories.

**Opt-in, not shared.** The repo's `.claude/settings.json` is not modified; the
README carries the `SessionEnd` snippet (`timeout: 30`) for a user- or
project-local settings file, along with the privacy statement and the two
environment variables (`OPENBURNBAR_MEMORY_SESSION_HOOK=off`,
`OPENBURNBAR_MEMORY_SESSION_HOOK_LOG=<file>`).

## 8. Follow-up closure and remaining non-goals

- The signed write bridge and daemon-side ranking parity are included: the
  CLI exposes typed stdin-JSON `memory-remember` / `memory-forget` couriers,
  and daemon recall uses the same BM25, weighted RRF, salience, recency, and
  access-reinforcement semantics as the Python engine.
- A learned reranker. The deterministic salience rerank is honest and
  testable; a cross-encoder can slot behind `rerank()` later.
- Cloud sync of engine memories. The engine store is local-only.

## 9. Verification

- `pytest tests/` in `tools/openburnbar-mcp` (new `test_memory_engine.py` and
  `test_memory_engine_hardening.py`, updated server tests).
- `swift test --package-path OpenBurnBarDaemon --filter BurnBarCLITests` and
  `--filter BurnBarProjectCodeMemoryStoreTests`.
- `ruff check` and `ruff format --check` per `ruff.toml` (py311 target).
- `eval_memory.py` — recall@k / MRR on a 40-fact, 25-query gold set, lexical vs
  hybrid, run against the local Ollama `nomic-embed-text` model.
- `tests/test_memorize_transcript.py` — transcript parsing, tail trimming, the
  gated end-to-end hook payload (secret redacted, replay adds nothing), the kill
  switch, a missing transcript, the deadline, and the hook script itself.

### 9.1 Evaluation — the measured numbers

`eval_memory.py` has three modes. Retrieval is the default; the other two make
extraction quality and gate coverage measurable rather than assumed.

| Mode | Command | Measured 2026-09-02 |
|---|---|---|
| Retrieval | `eval_memory.py --provider auto` | hybrid R@5 0.90, MRR 0.678 (`nomic-embed-text`) |
| Extraction | `eval_memory.py --extraction --provider none` | recall **0.667** (20/30), precision 1.0, 1 fact over 7 empty conversations, 0 leaks |
| Gate | `eval_memory.py --gate` | 25 shapes, all detected raw; 4 encoding gaps |

The extraction gold set is `tools/openburnbar-mcp/eval/extraction_gold.json`:
36 realistic developer conversations of two to six messages covering decisions,
preferences, architecture facts, procedures, constraints, ownership and bug
root causes, plus seven that carry nothing durable (greetings, a traceback,
tool output, an ephemeral test run). Three conversations paste a credential;
their `forbidden` prefixes must never reach an extracted fact. Credential-shaped
literals are never committed — the gold set writes `{{secret:<shape>}}` and the
eval expands it from `eval_memory.SECRET_SHAPES`, a `random.Random(20260902)`
generator shared with `tests/test_gate_adversarial.py`.

`tests/test_eval_extraction.py` pins `RECALL_FLOOR = 0.65` — the measurement
rounded down to a multiple of 0.05 — together with `leaks == 0` and
`emptyCaseFacts <= 2`. The floor only moves up. Precision saturates at 1.0
because the heuristic extractor is conservative (it fires on about one sentence
per conversation, or none), so recall and the empty-case count carry the signal;
the ten misses are architecture and constraint statements phrased without one of
the extractor's cue words.

`tests/test_gate_adversarial.py` holds each of those 25 shapes to the policy
contract across eight caller-controlled placements — prose (middle and end), a
key/value line, a fenced code block, a tag, an entity, a metadata value and a
source ref. Under `redact` the verbatim token appears in no write result, `get`,
`list`, `recall` body or snippet, `pack`, `export`, `history` or audit trail, and
not in the store's raw bytes including an un-checkpointed `-wal`; under `reject`
the write is refused with `SECRET_DETECTED` and no row lands; under `retain` a
body secret is returned only by the encrypted vault while the indexable body and
the file bytes do not carry it, and an auxiliary field — which has no vault — is
redacted instead of retained, so it reaches no surface at all. Auxiliary fields
are gated on their raw, pre-normalization form — the write paths carry the
caller's tags uncased as far as `gate_aux_fields` and normalize what it returns —
so an AWS access key id written as a tag is refused or dropped exactly like one
written in the body.

The Twilio `SK<32 hex>` shape that this suite reported missing is now in the
shared corpus (`twilio-api-key`), detected raw and under all three encodings.

**The corpus has three consumers, and a bump touches all of them.** Two copies
are committed and kept byte-identical:
`tools/project-code-memory/secret-pattern-corpus.json` (loaded by the Python MCP
via `project_code_memory._load_secret_corpus`) and
`OpenBurnBarCore/Sources/OpenBurnBarKernel/Resources/secret-pattern-corpus.json`
(loaded by the Swift kernel and daemon through `MemorySecretPIIGate`, and
embedded as a resource by the C# `OpenBurnBar.App.MemorySearch` Windows app,
whose `MemorySecretPIIGateTests` pins the `version` string literally and runs
under the PR gate's `dotnet test`). When the `version` field changes, update
both JSON copies **and** that C# assertion —
`grep -rn "corpus-v<n>"` across *all* file types, not just Python and Swift.
